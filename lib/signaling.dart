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
  StringCallback? onRemoveRemoteStream, onConnectionLoading, onConnectionConnected, onConnectionError, onGenericError;

  // key is uuid, values are peer connection object and user defined display name string
  final Map<String, RTCPeerConnection> peerConnections = {};

  static const collectionVideoCall = 'videoCall';
  static const tableConnectionParams = 'connectionParams';
  static const tableConnectionParamsFor = 'connectionParamsFor';
  static const tablePeers = 'peers';

  final String localDisplayName;
  String? localUuid, appointmentId;

  StreamSubscription? listenerConnectionParams;

  Signaling({required this.localDisplayName});

  final iceServers = {
    'iceServers': [
      {
        // google stun
        'urls': ['stun:stun1.l.google.com:19302'],
      },
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
      return localStream!.getAudioTracks().first.enabled;
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
      localStream!.getAudioTracks()[0].enabled = !isMicEnabled();
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
    localUuid = const Uuid().v1();

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
      await _helloEveryone(peer.data());
    }

    // add my self to peers list
    await _writePeer({
      'uuid': localUuid,
      'displayName': localDisplayName,
      'created': FieldValue.serverTimestamp(),
    });

    // WebRTC connection params for me
    listenerConnectionParams = FirebaseFirestore.instance
        .collection(
          collectionVideoCall,
        )
        .doc(appointmentId)
        .collection(tableConnectionParamsFor)
        .doc(localUuid)
        .collection(tableConnectionParams)
        .orderBy('created')
        .snapshots()
        .listen(
          (snapshot) => snapshot.docs.forEach(
            (params) => _receivedConnectionParams(params.data()),
          ),
        );
  }

  Future<void> _helloEveryone(Map<String, dynamic> peerData) async {
    final String peerId = peerData['uuid'];

    if (peerConnections.containsKey(peerId)) {
      throw Exception('Peer $peerId already exists!');
    } else {
      final pc = await _createPeerConnection(peerId);
      await _createdDescription(pc, await pc.createOffer(), peerId, 'offer');
    }
  }

  Future<RTCPeerConnection> _createPeerConnection(String fromPeerId) async {
    if (kDebugMode) {
      print('Create PeerConnection with configuration: $iceServers');
    }

    final pc = await createPeerConnection(iceServers);

    peerConnections.putIfAbsent(fromPeerId, () => pc);

    pc.onIceCandidate = (event) => _gotIceCandidate(event, fromPeerId);
    pc.onTrack = (event) => _gotRemoteStream(event, fromPeerId);
    pc.onIceConnectionState = (event) => _checkConnectionState(event, fromPeerId);

    for (final track in localStream!.getTracks()) {
      await pc.addTrack(track, localStream!);
    }

    return pc;
  }

  Future<void> _manageSdp(Map<String, dynamic> receivedMsg) async {
    final String fromPeerId = receivedMsg['uuid'];
    //final String displayName = receivedMsg['displayName'];
    final sdp = receivedMsg['sdp'];
    final sdpType = receivedMsg['sdpType'];

    if ('offer' == sdpType) {
      if (!peerConnections.containsKey(fromPeerId)) {
        final pc = await _createPeerConnection(fromPeerId);

        await pc.setRemoteDescription(RTCSessionDescription(sdp['sdp'], sdp['type']));

        await _createdDescription(pc, await pc.createAnswer(), fromPeerId, 'answer');
      }
    } else if ('answer' == sdpType) {
      final pc = peerConnections[fromPeerId];

      if (pc?.getRemoteDescription() != null) {
        switch (pc?.signalingState) {
          case RTCSignalingState.RTCSignalingStateStable:
          case RTCSignalingState.RTCSignalingStateClosed:
            break;

          default:
            await pc?.setRemoteDescription(RTCSessionDescription(sdp['sdp'], sdp['type']));
            break;
        }
      }
    }
  }

  Future<void> _manageIce(Map<String, dynamic> receivedMsg) async {
    final String fromPeerId = receivedMsg['uuid'];
    final String displayName = receivedMsg['displayName'];
    final ice = receivedMsg['ice'];

    if (peerConnections.containsKey(fromPeerId)) {
      final pc = peerConnections[fromPeerId]!;

      await pc.addCandidate(RTCIceCandidate(ice['candidate'], ice['sdpMid'], ice['sdpMLineIndex']));
    } else {
      throw Exception('Received ICE candidate, but $displayName have not a peer connection');
    }
  }

  Future<void> _receivedConnectionParams(Map<String, dynamic> receivedMsg) async {
    if (receivedMsg.containsKey('sdp')) {
      try {
        await _manageSdp(receivedMsg);
      } catch (sdpE) {
        onGenericError?.call('Error in SDP routine: $sdpE');
      }
    } else if (receivedMsg.containsKey('ice')) {
      try {
        await _manageIce(receivedMsg);
      } catch (iceE) {
        onGenericError?.call('Error in ICE routine: $iceE');
      }
    } else {
      final String displayName = receivedMsg['displayName'];
      onGenericError?.call('I have received a strange message from $displayName: $receivedMsg');
    }
  }

  Future<void> _createdDescription(RTCPeerConnection pc, RTCSessionDescription description, String destinationPeerId, String sdpType) async {
    if (kDebugMode) {
      print('create description $sdpType, for peer $destinationPeerId');
    }

    await pc.setLocalDescription(description);

    await _writeParamsToDb(destinationPeerId, {
      'uuid': localUuid,
      'displayName': localDisplayName,
      'sdpType': sdpType,
      'sdp': description.toMap(),
      'created': FieldValue.serverTimestamp(),
    });
  }

  void _checkConnectionState(RTCIceConnectionState state, String peerUuid) {
    //final state = peerConnections[peerUuid]?.iceConnectionState;
    if (kDebugMode) {
      print('connection with peer $peerUuid $state');
    }

    switch (state) {
      case RTCIceConnectionState.RTCIceConnectionStateNew:
      case RTCIceConnectionState.RTCIceConnectionStateChecking:
        onConnectionLoading?.call(peerUuid);
        break;

      case RTCIceConnectionState.RTCIceConnectionStateConnected:
      case RTCIceConnectionState.RTCIceConnectionStateCompleted:
        onConnectionConnected?.call(peerUuid);
        break;

      case RTCIceConnectionState.RTCIceConnectionStateFailed:
        onConnectionError?.call(peerUuid);
        break;

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
        'displayName': localDisplayName,
        'ice': event.toMap(),
        'created': FieldValue.serverTimestamp(),
      });
    }
  }

  Future<void> _openUserMedia() async {
    localStream = await navigator.mediaDevices.getUserMedia({'video': true, 'audio': true});

    if ((localStream?.getVideoTracks().length ?? 0) == 0) {
      throw Exception('There are no video tracks');
    } else {
      if (kDebugMode) {
        print('Video tracks: ${localStream?.getVideoTracks().length}');
      }
    }

    if ((localStream?.getAudioTracks().length ?? 0) == 0) {
      throw Exception('There are no audio tracks');
    } else {
      if (kDebugMode) {
        print('Audio tracks: ${localStream?.getAudioTracks().length}');
      }
    }

    onAddLocalStream?.call(localUuid!, localStream!);
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

    onAddLocalStream?.call(localUuid!, stream);
  }
}
