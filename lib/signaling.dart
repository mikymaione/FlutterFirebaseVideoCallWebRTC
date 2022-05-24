import 'dart:async';
import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:uuid/uuid.dart';

typedef StringCallback = void Function(String peerUuid);
typedef StreamStateCallback = void Function(String peerUuid, MediaStream stream);
typedef ConnectionClosedCallback = RTCVideoRenderer Function();

class Signaling {
  MediaStream? localStream;
  StreamStateCallback? onAddRemoteStream, onAddLocalStream;
  StringCallback? onRemoveRemoteStream;

  // key is uuid, values are peer connection object and user defined display name string
  final Map<String, RTCPeerConnection> peerConnections = {};

  static const collectionVideoCall = 'videoCall';
  static const tableConnectionParams = 'connectionParams';
  static const tableConnectionParamsFor = 'connectionParamsFor';
  static const tablePeers = 'peers';

  final localUuid = const Uuid().v1();
  final localDisplayName = getRandomString(20);

  final appointmentId = 'UoCaFPedwvAKZPFdmaqc';

  StreamSubscription? listenerConnectionParams;

  static const _chars = 'AaBbCcDdEeFfGgHhIiJjKkLlMmNnOoPpQqRrSsTtUuVvWwXxYyZz1234567890';
  static final _rnd = Random();

  static String getRandomString(int length) => String.fromCharCodes(Iterable.generate(length, (index) => _chars.codeUnitAt(_rnd.nextInt(_chars.length))));

  final iceServers = {
    'iceServers': [
      {
        // coturn server
        'urls': ['turn:80.211.89.209:3478'],
        'username': 'coturn',
        'credential': 'coturn',
      },
    ]
  };

  Future<int> cameraCount() async {
    final cams = await Helper.cameras;
    return cams.length;
  }

  bool isLocalStreamOk() {
    return localStream != null;
  }

  void switchCamera() {
    if (localStream != null) {
      Helper.switchCamera(localStream!.getVideoTracks()[0]);
    }
  }

  bool isMicMuted() {
    return !isMicEnabled();
  }

  bool isMicEnabled() {
    if (localStream != null) {
      return localStream!.getAudioTracks()[0].enabled;
    }

    return true;
  }

  void muteMic() {
    if (localStream != null) {
      localStream!.getAudioTracks()[0].enabled = !isMicEnabled();
    }
  }

  Future<void> hangUp(RTCVideoRenderer localVideo) async {
    listenerConnectionParams?.cancel();

    localVideo.srcObject = null;

    localStream?.getTracks().forEach((track) => track.stop());
    localStream?.dispose();
    localStream = null;

    peerConnections.forEach((uuid, pc) => pc.close());

    // remove me from peers
    await FirebaseFirestore.instance
        .collection(collectionVideoCall)
        .doc(appointmentId)
        .collection(tablePeers)
        .where(
          'uuid',
          isEqualTo: localUuid,
        )
        .get()
        .then(
          (snapshot) => snapshot.docs.forEach(
            (peer) async => await peer.reference.delete(),
          ),
        );
  }

  Future<void> join() async {
    await _openUserMedia();

    final peers = await FirebaseFirestore.instance
        .collection(
          collectionVideoCall,
        )
        .doc(appointmentId)
        .collection(tablePeers)
        .where(
          'uuid',
          isNotEqualTo: localUuid, // exclude my self
        )
        .get();

    for (final peer in peers.docs) {
      await _connectTo(peer.data(), true);
    }

    // WebRTC connection params for me
    listenerConnectionParams = FirebaseFirestore.instance
        .collection(
          collectionVideoCall,
        )
        .doc(appointmentId)
        .collection(tableConnectionParamsFor)
        .doc(localUuid)
        .collection(tableConnectionParams)
        .snapshots()
        .listen(
          (snapshot) => snapshot.docs.forEach(
            (params) => _receivedConnectionParams(params.data()),
          ),
        );

    // add my self to peers list
    await _writePeer({
      'uuid': localUuid,
      'displayName': localDisplayName,
    });
  }

  Future<void> _connectTo(Map<String, dynamic> receivedMsg, bool startOffer) async {
    final String fromPeerId = receivedMsg['uuid'];

    if (peerConnections.containsKey(fromPeerId)) {
      if (kDebugMode) {
        print('Peer $fromPeerId already exists!');
      }
    } else {
      // set up peer connection object for a newcomer peer
      if (kDebugMode) {
        print('_newPeer: $fromPeerId');
      }

      final pc = await createPeerConnection(iceServers);

      peerConnections.putIfAbsent(fromPeerId, () => pc);

      pc.onIceCandidate = (event) => _gotIceCandidate(event, fromPeerId);
      pc.onTrack = (event) => _gotRemoteStream(event, fromPeerId);
      pc.onIceConnectionState = (event) => _checkPeerDisconnect(event, fromPeerId);

      pc.addStream(localStream!);

      if (startOffer) {
        if (kDebugMode) {
          print('createOffer from $localUuid to $fromPeerId');
        }

        await _createdDescription(pc, await pc.createOffer(), fromPeerId);
      }
    }
  }

  Future<void> _receivedConnectionParams(Map<String, dynamic> receivedMsg) async {
    final String fromPeerId = receivedMsg['uuid'];

    if (!peerConnections.containsKey(fromPeerId)) {
      await _connectTo(receivedMsg, false);
    }

    final pc = peerConnections[fromPeerId]!;

    if (receivedMsg.containsKey('sdp')) {
      final sdp = receivedMsg['sdp'];

      await pc.setRemoteDescription(RTCSessionDescription(sdp['sdp'], sdp['type']));

      // Only create answers in response to offers
      if ('offer' == sdp['type']) {
        if (kDebugMode) {
          print('createAnswer from $localUuid to $fromPeerId');
        }

        await _createdDescription(pc, await pc.createAnswer(), fromPeerId);
      }
    } else if (receivedMsg.containsKey('ice')) {
      final ice = receivedMsg['ice'];

      await pc.addCandidate(RTCIceCandidate(ice['candidate'], ice['sdpMid'], ice['sdpMLineIndex']));
    }
  }

  Future<void> _createdDescription(RTCPeerConnection pc, RTCSessionDescription description, String destinationPeerId) async {
    if (kDebugMode) {
      print('got description, peer $destinationPeerId');
    }

    await pc.setLocalDescription(description);

    await _writeParamsToDb(destinationPeerId, {
      'uuid': localUuid,
      'sdp': description.toMap(),
    });
  }

  void _checkPeerDisconnect(RTCIceConnectionState event, String peerUuid) {
    final state = peerConnections[peerUuid]?.iceConnectionState;

    if (kDebugMode) {
      print('connection with peer $peerUuid $state');
    }

    switch (state) {
      case RTCIceConnectionState.RTCIceConnectionStateFailed:
      case RTCIceConnectionState.RTCIceConnectionStateDisconnected:
      case RTCIceConnectionState.RTCIceConnectionStateClosed:
        peerConnections.remove(peerUuid);
        onRemoveRemoteStream?.call(peerUuid);
        break;

      default:
        break;
    }
  }

  void _gotRemoteStream(RTCTrackEvent event, String peerUuid) {
    if (kDebugMode) {
      print('got remote stream, peer $peerUuid');
    }

    onAddRemoteStream?.call(peerUuid, event.streams[0]);
  }

  Future<void> _gotIceCandidate(RTCIceCandidate event, String peerUuid) async {
    if (kDebugMode) {
      print('got ice candidate, peer $peerUuid');
    }

    if (event.candidate != null) {
      await _writeParamsToDb(peerUuid, {
        'uuid': localUuid,
        'ice': event.toMap(),
      });
    }
  }

  Future<void> _openUserMedia() async {
    localStream = await navigator.mediaDevices.getUserMedia({'video': true, 'audio': true});
    onAddLocalStream?.call(localUuid, localStream!);
  }

  Future<void> _writeParamsToDb(String dest, Map<String, dynamic> msg) async {
    await FirebaseFirestore.instance
        .collection(
          collectionVideoCall,
        )
        .doc(appointmentId)
        .collection(tableConnectionParamsFor)
        .doc(dest)
        .collection(tableConnectionParams)
        .add(msg);
  }

  Future<void> _writePeer(Map<String, dynamic> msg) async {
    await FirebaseFirestore.instance
        .collection(
          collectionVideoCall,
        )
        .doc(appointmentId)
        .collection(tablePeers)
        .add(msg);
  }
}
