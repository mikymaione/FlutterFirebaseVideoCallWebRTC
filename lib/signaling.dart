import 'dart:async';
import 'dart:collection';
import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:uuid/uuid.dart';

typedef ErrorCallback = void Function(String error);
typedef PeerCallback = void Function(String peerUuid, String displayName);
typedef StreamStateCallback = void Function(String peerUuid, String displayName, MediaStream? stream);
typedef ConnectionClosedCallback = RTCVideoRenderer Function();

class Signaling {
  MediaStream? _localStream, _shareStream;
  StreamStateCallback? onAddRemoteStream, onAddLocalStream;
  PeerCallback? onRemoveRemoteStream, onConnectionLoading, onConnectionConnected, onConnectionError;
  ErrorCallback? onGenericError;

  // key is uuid, values are peer connection object and user defined display name string
  final Map<String, RTCPeerConnection> _peerConnections = {};
  final _peerBanned = HashSet<String>();

  static const collectionVideoCall = 'videoCall';
  static const tableConnectionParamsFor = 'connectionParamsFor';
  static const tablePeers = 'peers';
  static const tableSdp = 'sdp';
  static const tableIce = 'ice';

  final String localDisplayName;
  String? _localUuid, _appointmentId;

  StreamSubscription? _listenerSdp, _listenerIce;

  Signaling({required this.localDisplayName});

  // my Coturn server
  final _iceServers = {
    'iceServers': [
      {
        'urls': [
          'stun:94.177.160.139:3478'
        ],
      },
      {
        'urls': [
          'turn:94.177.160.139:3478?transport=udp',
          'turn:94.177.160.139:3478?transport=tcp',
        ],
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

        return cams.length;
      } catch (e) {
        // camera not accessible, like for screen sharing or other problems
        onGenericError?.call('Error: $e');
        return 0;
      }
    }
  }

  bool isJoined() {
    return _appointmentId != null;
  }

  Future<void> switchCamera() async {
    if (!kIsWeb && _localStream != null) {
      await Helper.switchCamera(_localStream!.getVideoTracks().first);
    }
  }

  bool isMicMuted() {
    return !isMicEnabled();
  }

  bool isMicEnabled() {
    if (_localStream != null) {
      return _localStream!.getAudioTracks().first.enabled;
    }

    return true;
  }

  bool isScreenSharing() {
    return _shareStream != null;
  }

  Future<void> stopScreenSharing() async {
    if (_shareStream != null) {
      for (final track in _shareStream!.getTracks()) {
        await track.stop();
      }

      await _shareStream?.dispose();
      _shareStream = null;
    }

    await _replaceStream(_localStream!);
  }

  Future<void> screenSharing() async {
    _shareStream = await navigator.mediaDevices.getDisplayMedia({
      'audio': false,
      'video': {
        'cursor': 'always',
      },
    });

    await _replaceStream(_shareStream!);
  }

  void muteMic() {
    if (_localStream != null) {
      _localStream!.getAudioTracks()[0].enabled = !isMicEnabled();
    }
  }

  Future<void> hangUp(bool updateLocalVideo) async {
    await _listenerSdp?.cancel();
    await _listenerIce?.cancel();

    _listenerSdp = null;
    _listenerIce = null;

    await stopScreenSharing();

    if (updateLocalVideo) {
      onAddLocalStream?.call('', localDisplayName, null);

      if (_localStream != null) {
        for (final track in _localStream!.getTracks()) {
          await track.stop();
        }

        await _localStream!.dispose();
        _localStream = null;
      }
    }

    for (final pc in _peerConnections.values) {
      await _closePeerConnection(pc);
    }

    _peerConnections.clear();
    _peerBanned.clear();

    await _clearAllFirebaseData();

    _appointmentId = null;
  }

  Future<void> join(String appointmentId) async {
    _appointmentId = appointmentId;
    _localUuid = const Uuid().v1();

    if (_localStream == null) {
      throw Exception('You can not start a call without the webcam opened');
    }

    final peers = await FirebaseFirestore.instance
        .collection(
          collectionVideoCall,
        )
        .doc(_appointmentId)
        .collection(tablePeers)
        .where(
          'uuid',
          isNotEqualTo: _localUuid, // exclude my self
        )
        .get();

    for (final peer in peers.docs) {
      await _helloEveryone(peer.data());
    }

    // add my self to peers list
    await _writePeer({
      'uuid': _localUuid,
      'displayName': localDisplayName,
      'created': FieldValue.serverTimestamp(),
    });

    _startListenSdp();
  }

  void _startListenIce() {
    // WebRTC ICE
    _listenerIce ??= FirebaseFirestore.instance
        .collection(
          collectionVideoCall,
        )
        .doc(_appointmentId)
        .collection(tableConnectionParamsFor)
        .doc(_localUuid)
        .collection(tableIce)
        .orderBy('created')
        .snapshots()
        .listen(
      (snapshot) {
        for (final ice in snapshot.docs) {
          _manageIce(ice.data());
        }
      },
    );
  }

  void _startListenSdp() {
    // WebRTC SDP
    _listenerSdp ??= FirebaseFirestore.instance
        .collection(
          collectionVideoCall,
        )
        .doc(_appointmentId)
        .collection(tableConnectionParamsFor)
        .doc(_localUuid)
        .collection(tableSdp)
        .orderBy('created')
        .snapshots()
        .listen(
      (snapshot) {
        for (final sdp in snapshot.docs) {
          _manageSdp(sdp.data());
        }
      },
    );
  }

  Future<void> _helloEveryone(Map<String, dynamic> peerData) async {
    final String peerId = peerData['uuid'];
    final String displayName = peerData['displayName'];

    if (_peerConnections.containsKey(peerId)) {
      throw Exception('Peer $peerId already exists!');
    } else {
      final pc = await _createPeerConnection(peerId, displayName);
      await _createdDescription(pc, await pc.createOffer(), peerId, 'offer');
    }
  }

  Future<RTCPeerConnection> _createPeerConnection(String fromPeerId, String displayName) async {
    if (kDebugMode) {
      print('Create PeerConnection with configuration: $_iceServers');
    }

    final pc = await createPeerConnection(_iceServers);

    _peerConnections.putIfAbsent(fromPeerId, () => pc);

    pc.onIceCandidate = (event) => _gotIceCandidate(event, fromPeerId, displayName);
    pc.onTrack = (event) => _gotRemoteStream(event, fromPeerId, displayName);
    pc.onIceConnectionState = (event) => _checkConnectionState(event, fromPeerId, displayName);

    for (final track in _localStream!.getTracks()) {
      await pc.addTrack(track, _localStream!);
    }

    return pc;
  }

  Future<void> _manageSdp(Map<String, dynamic> receivedMsg) async {
    if (receivedMsg.containsKey('sdp')) {
      final String fromPeerId = receivedMsg['uuid'];
      final String displayName = receivedMsg['displayName'];
      final sdp = receivedMsg['sdp'];
      final sdpType = receivedMsg['sdpType'];

      if (!_peerBanned.contains(fromPeerId)) {
        try {
          if ('offer' == sdpType) {
            // peer A that was in room, receive an Offer from peer B, and send an Answer

            if (!_peerConnections.containsKey(fromPeerId)) {
              final pc = await _createPeerConnection(fromPeerId, displayName);

              await pc.setRemoteDescription(RTCSessionDescription(sdp['sdp'], sdp['type']));

              await _createdDescription(pc, await pc.createAnswer(), fromPeerId, 'answer');
              _startListenIce();
            }
          } else if ('answer' == sdpType) {
            // peer B enter room, that sent an Offer to peer A receive an Answer from peer A
            final pc = _peerConnections[fromPeerId];

            if (pc?.getRemoteDescription() != null) {
              switch (pc?.signalingState) {
                case RTCSignalingState.RTCSignalingStateStable:
                case RTCSignalingState.RTCSignalingStateClosed:
                  break;

                default:
                  await pc?.setRemoteDescription(RTCSessionDescription(sdp['sdp'], sdp['type']));
                  _startListenIce();
                  break;
              }
            }
          }
        } catch (sdpE) {
          onGenericError?.call('Error in SDP routine from $displayName: $sdpE');
        }
      }
    }
  }

  Future<void> _manageIce(Map<String, dynamic> receivedMsg) async {
    if (receivedMsg.containsKey('ice')) {
      final String fromPeerId = receivedMsg['uuid'];
      final String displayName = receivedMsg['displayName'];
      final ice = receivedMsg['ice'];

      if (!_peerBanned.contains(fromPeerId)) {
        try {
          if (_peerConnections.containsKey(fromPeerId)) {
            final pc = _peerConnections[fromPeerId]!;

            await pc.addCandidate(RTCIceCandidate(ice['candidate'], ice['sdpMid'], ice['sdpMLineIndex']));
          } else {
            throw Exception('Received ICE candidate, but $displayName have not a peer connection');
          }
        } catch (iceE) {
          onGenericError?.call('Error in ICE routine from $displayName: $iceE');
        }
      }
    }
  }

  Future<void> _createdDescription(RTCPeerConnection pc, RTCSessionDescription description, String destinationPeerId, String sdpType) async {
    if (kDebugMode) {
      print('create description $sdpType, for peer $destinationPeerId');
    }

    await pc.setLocalDescription(description);

    final sdp = {
      'uuid': _localUuid,
      'displayName': localDisplayName,
      'created': FieldValue.serverTimestamp(),
      'sdpType': sdpType,
      'sdp': description.toMap(),
    };

    await FirebaseFirestore.instance
        .collection(
          collectionVideoCall,
        )
        .doc(_appointmentId)
        .collection(tableConnectionParamsFor)
        .doc(destinationPeerId)
        .collection(tableSdp)
        .add(sdp);
  }

  void _checkConnectionState(RTCIceConnectionState state, String peerUuid, String displayName) {
    if (!_peerBanned.contains(peerUuid)) {
      if (kDebugMode) {
        print('connection with peer $displayName: $state');
      }

      switch (state) {
        case RTCIceConnectionState.RTCIceConnectionStateNew:
        case RTCIceConnectionState.RTCIceConnectionStateChecking:
          onConnectionLoading?.call(peerUuid, displayName);
          break;

        case RTCIceConnectionState.RTCIceConnectionStateConnected:
        case RTCIceConnectionState.RTCIceConnectionStateCompleted:
          onConnectionConnected?.call(peerUuid, displayName);
          break;

        case RTCIceConnectionState.RTCIceConnectionStateFailed:
          _peerBanned.add(peerUuid);

          onConnectionError?.call(peerUuid, displayName);

          _removePeer(peerUuid, displayName);
          break;

        case RTCIceConnectionState.RTCIceConnectionStateDisconnected:
        case RTCIceConnectionState.RTCIceConnectionStateClosed:
          _removePeer(peerUuid, displayName);
          break;

        default:
          break;
      }
    }
  }

  Future<void> _closePeerConnection(RTCPeerConnection pc) async {
    await pc.close();
    await pc.dispose();
  }

  Future<void> _removePeer(String peerUuid, String displayName) async {
    if (_peerConnections.containsKey(peerUuid)) {
      await _closePeerConnection(_peerConnections[peerUuid]!);

      _peerConnections.remove(peerUuid);

      onRemoveRemoteStream?.call(peerUuid, displayName);
    }
  }

  void _gotRemoteStream(RTCTrackEvent event, String peerUuid, String displayName) {
    if (!_peerBanned.contains(peerUuid)) {
      if (kDebugMode) {
        print('got remote stream, peer $displayName');
      }

      onAddRemoteStream?.call(peerUuid, displayName, event.streams[0]);
    }
  }

  Future<void> _gotIceCandidate(RTCIceCandidate iceCandidate, String peerUuid, String displayName) async {
    if (!_peerBanned.contains(peerUuid)) {
      if (kDebugMode) {
        print('got ice candidate, peer $displayName');
      }

      if (iceCandidate.candidate?.isNotEmpty ?? false) {
        final ice = {
          'uuid': _localUuid,
          'displayName': localDisplayName,
          'created': FieldValue.serverTimestamp(),
          'ice': iceCandidate.toMap(),
        };

        await FirebaseFirestore.instance
            .collection(
              collectionVideoCall,
            )
            .doc(_appointmentId)
            .collection(tableConnectionParamsFor)
            .doc(peerUuid)
            .collection(tableIce)
            .add(ice);
      }
    }
  }

  Future<void> reOpenUserMedia() async {
    if (_localStream == null) {
      await openUserMedia();
    }
  }

  Future<void> openUserMedia() async {
    _localStream = await navigator.mediaDevices.getUserMedia({
      'audio': true,
      'video': {
        'facingMode': 'user', // front camera
      }
    });

    if ((_localStream?.getVideoTracks().length ?? 0) == 0) {
      throw Exception('There are no video tracks');
    } else {
      if (kDebugMode) {
        print('Video tracks: ${_localStream?.getVideoTracks().length}');
      }
    }

    if ((_localStream?.getAudioTracks().length ?? 0) == 0) {
      throw Exception('There are no audio tracks');
    } else {
      if (kDebugMode) {
        print('Audio tracks: ${_localStream?.getAudioTracks().length}');
      }
    }

    onAddLocalStream?.call('', localDisplayName, _localStream!);
  }

  Future<void> _writePeer(Map<String, dynamic> msg) async {
    await FirebaseFirestore.instance
        .collection(
          collectionVideoCall,
        )
        .doc(_appointmentId)
        .collection(tablePeers)
        .add(msg);
  }

  Future<void> _clearAllFirebaseData() async {
    // remove me from peers
    await FirebaseFirestore.instance
        .collection(collectionVideoCall)
        .doc(_appointmentId)
        .collection(tablePeers)
        .where(
          'uuid',
          isEqualTo: _localUuid,
        )
        .get()
        .then(
      (snapshot) async {
        for (final peer in snapshot.docs) {
          await peer.reference.delete();
        }
      },
    );

    // remove all params for me
    final docRef = await FirebaseFirestore.instance
        .collection(
          collectionVideoCall,
        )
        .doc(_appointmentId)
        .collection(tableConnectionParamsFor)
        .doc(_localUuid)
        .get();

    await docRef.reference.delete();
  }

  Future<void> _replaceStream(MediaStream stream) async {
    final track = stream.getVideoTracks().first;

    for (final pc in _peerConnections.values) {
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

    onAddLocalStream?.call(_localUuid!, localDisplayName, stream);
  }
}
