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

  StreamSubscription? listenerConnectionParams, listenerPeers;

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
    listenerPeers?.cancel();

    localVideo.srcObject!.getTracks().forEach((track) => track.stop());

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

    // New Peers
    FirebaseFirestore.instance
        .collection(
          collectionVideoCall,
        )
        .doc(appointmentId)
        .collection(tablePeers)
        .where(
          'uuid',
          isNotEqualTo: localUuid, // exclude my self
        )
        .snapshots()
        .listen(
          (snapshot) => snapshot.docs.forEach(
            (peer) => _newPeerJoin(peer.data()),
          ),
        );

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
      'dest': 'all',
      'uuid': localUuid,
      'displayName': localDisplayName,
    });
  }

  Future<void> _newPeerJoin(Map<String, dynamic> receivedMsg) async {
    final String uuid = receivedMsg['uuid'];
    final String dest = receivedMsg['dest'];

    /*
    localUuid = A & dest = All & uuid = B
      => peerConnections[B] = new PC
      => request an offer from the new comer(dest = B, uuid = A)

    localUuid = B & dest = B & uuid = A
      => peerConnections[A] = new PC
      => request an offer from the new comer(dest = A, uuid = B)

    localUuid = A & dest = A & uuid = B
      => peerConnections[A] = new PC
      => request an offer from the new comer

    */

    // Ignore messages that are not for us
    if ('all' == dest) {
      if (peerConnections.containsKey(uuid)) {
        throw Exception('Peer $uuid already exists!');
      } else {
        // set up peer connection object for a newcomer peer
        if (kDebugMode) {
          print('_newPeer: $uuid');
        }

        final pc = await createPeerConnection(iceServers);

        peerConnections.putIfAbsent(uuid, () => pc);

        pc.onIceCandidate = (event) => _gotIceCandidate(event, uuid);
        pc.onTrack = (event) => _gotRemoteStream(event, uuid);
        pc.onIceConnectionState = (event) => _checkPeerDisconnect(event, uuid);

        pc.addStream(localStream!);

        // request an offer from the new comer
        await _writePeer({
          'dest': uuid,
          'uuid': localUuid,
          'displayName': localDisplayName,
        });
      }
    } else if (localUuid == dest) {
      if (peerConnections.containsKey(uuid)) {
        // initiate call if we are the newcomer peer
        final pc = peerConnections[uuid]!;

        await _createdDescription(pc, await pc.createOffer(), uuid);
      } else {
        throw Exception('Peer $uuid not exists!');
      }
    }
  }

  Future<void> _receivedConnectionParams(Map<String, dynamic> receivedMsg) async {
    final String uuid = receivedMsg['uuid'];
    final ice = receivedMsg['ice'];
    final sdp = receivedMsg['sdp'];

    if (peerConnections.containsKey(uuid)) {
      final pc = peerConnections[uuid]!;

      if (sdp != null) {
        await pc.setRemoteDescription(RTCSessionDescription(sdp['sdp'], sdp['type']));

        // Only create answers in response to offers
        if ('offer' == sdp['type']) {
          await _createdDescription(pc, await pc.createAnswer(), uuid);
        }
      } else if (ice != null) {
        await pc.addCandidate(RTCIceCandidate(ice['candidate'], ice['sdpMid'], ice['sdpMLineIndex']));
      }
    } else {
      throw Exception('Peer $uuid not exists!');
    }
  }

  Future<void> _createdDescription(RTCPeerConnection pc, RTCSessionDescription description, String peerUuid) async {
    if (kDebugMode) {
      print('got description, peer $peerUuid');
    }

    await pc.setLocalDescription(description);

    await _writeParamsToDb(peerUuid, {
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
