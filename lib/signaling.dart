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
  MediaStream? localStream, shareStream;
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

  String? appointmentId;

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
    if (isScreenSharing()) {
      return 0;
    } else {
      try {
        final cams = await Helper.cameras;

        return kIsWeb ? min(cams.length, 1) : cams.length;
      } catch (e) {
        // camera not accessibile, like for screen sharing or other problems
        print('Error: $e');
        return 0;
      }
    }
  }

  bool isLocalStreamOk() {
    return localStream != null;
  }

  Future<void> switchCamera() async {
    if (!kIsWeb && localStream != null) {
      await Helper.switchCamera(localStream!.getVideoTracks().first);
    }
  }

  bool isMicMuted() {
    return !isMicEnabled();
  }

  bool isMicEnabled() {
    if (localStream != null) {
      try {
        return localStream!.getAudioTracks().first.enabled;
      } catch (e) {
        // no audio
        print('Error: $e');
        return false;
      }
    }

    return true;
  }

  bool isScreenSharing() {
    return shareStream != null;
  }

  void stopScreenSharing() {
    shareStream?.getTracks().forEach((track) => track.stop());
    shareStream?.dispose();
    shareStream = null;

    _replaceStream(localStream!);
  }

  Future<void> screenSharing() async {
    shareStream = await navigator.mediaDevices.getDisplayMedia({
      'audio': false,
      'video': {
        'cursor': 'always',
      },
    });

    _replaceStream(shareStream!);
  }

  void muteMic() {
    if (localStream != null) {
      try {
        localStream!.getAudioTracks()[0].enabled = !isMicEnabled();
      } catch (e) {
        //cannot change
        print('Error: $e');
      }
    }
  }

  Future<void> hangUp(RTCVideoRenderer localVideo) async {
    appointmentId = null;

    listenerConnectionParams?.cancel();

    stopScreenSharing();

    localVideo.srcObject = null;

    localStream?.getTracks().forEach((track) => track.stop());
    localStream?.dispose();
    localStream = null;

    for (final pc in peerConnections.values) {
      pc.close();
      pc.dispose();
    }

    peerConnections.clear();

    await _clearAllFirebaseData();
  }

  Future<void> join(String _appointmentId) async {
    appointmentId = _appointmentId;

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

    if (kDebugMode) {
      print('Video tracks: ${localStream?.getVideoTracks().length}');
      print('Audio tracks: ${localStream?.getAudioTracks().length}');
    }

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

  Future<void> _clearAllFirebaseData() async {
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

    // remove all params for me
    await FirebaseFirestore.instance
        .collection(
          collectionVideoCall,
        )
        .doc(appointmentId)
        .collection(tableConnectionParamsFor)
        .doc(localUuid)
        .collection(tableConnectionParams)
        .get()
        .then(
          (snapshot) => snapshot.docs.forEach(
            (peer) async => await peer.reference.delete(),
          ),
        );
  }

  Future<void> _replaceStream(MediaStream stream) async {
    final track = stream.getVideoTracks().first;

    for (final pc in peerConnections.values) {
      final senders = await pc.getSenders();

      for (final s in senders) {
        if ('video' == s.track?.kind) {
          await s.replaceTrack(track);
        }
      }
    }

    if (kDebugMode) {
      print('Video tracks: ${stream.getVideoTracks().length}');
      print('Audio tracks: ${stream.getAudioTracks().length}');
    }

    onAddLocalStream?.call(localUuid, stream);
  }
}
