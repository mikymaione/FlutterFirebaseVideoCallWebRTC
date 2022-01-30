import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

typedef StreamStateCallback = void Function(MediaStream stream);
typedef ConnectionClosedCallback = RTCVideoRenderer Function();

class Signaling {
  Map<String, dynamic> configuration = {
    'iceServers': [
      {
        //'urls': ['stun:stun1.l.google.com:19302', 'stun:stun2.l.google.com:19302']

        // STUNTMAN Version 1.2. - an open source STUN server and client code by john selbie. Compliant with the latest RFCs including 5389, 5769, and 5780. Also includes backwards compatibility for RFC 3489.
        // https://github.com/jselbie/stunserver
        'urls': ['stun:77.81.230.199:3478']
      }
    ]
  };

  RTCPeerConnection? peerConnection;
  MediaStream? localStream;
  MediaStream? remoteStream;
  String? roomId;
  String? currentRoomText;
  StreamStateCallback? onAddRemoteStream;

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

  Future<String> createRoom(RTCVideoRenderer remoteRenderer) async {
    final db = FirebaseFirestore.instance;
    final roomRef = db.collection('rooms').doc();

    print('Create PeerConnection with configuration: $configuration');

    peerConnection = await createPeerConnection(configuration);

    registerPeerConnectionListeners();

    localStream?.getTracks().forEach((track) {
      peerConnection?.addTrack(track, localStream!);
    });

    // Code for collecting ICE candidates below
    var callerCandidatesCollection = roomRef.collection('callerCandidates');

    peerConnection?.onIceCandidate = (RTCIceCandidate candidate) {
      print('Got candidate: ${candidate.toMap()}');
      callerCandidatesCollection.add(candidate.toMap());
    };
    // Finish Code for collecting ICE candidate

    // Add code for creating a room
    final offer = await peerConnection!.createOffer();
    await peerConnection!.setLocalDescription(offer);
    print('Created offer: $offer');

    final roomWithOffer = {'offer': offer.toMap()};

    await roomRef.set(roomWithOffer);
    final roomId = roomRef.id;
    print('New room created with SDK offer. Room ID: $roomId');
    currentRoomText = 'Current room is $roomId - You are the caller!';
    // Created a Room

    peerConnection?.onTrack = (RTCTrackEvent event) {
      print('Got remote track: ${event.streams[0]}');

      event.streams[0].getTracks().forEach(
        (track) {
          print('Add a track to the remoteStream $track');
          remoteStream?.addTrack(track);
        },
      );
    };

    // Listening for remote session description below
    roomRef.snapshots().listen(
      (snapshot) async {
        print('Got updated room: ${snapshot.data()}');

        final data = snapshot.data() as Map<String, dynamic>;
        if (peerConnection?.getRemoteDescription() != null && data['answer'] != null) {
          final answer = RTCSessionDescription(
            data['answer']['sdp'],
            data['answer']['type'],
          );

          print("Someone tried to connect");
          await peerConnection?.setRemoteDescription(answer);
        }
      },
    );
    // Listening for remote session description above

    // Listen for remote Ice candidates below
    roomRef.collection('calleeCandidates').snapshots().listen(
      (snapshot) {
        for (final change in snapshot.docChanges) {
          if (change.type == DocumentChangeType.added) {
            final data = change.doc.data() as Map<String, dynamic>;
            print('Got new remote ICE candidate: ${jsonEncode(data)}');

            peerConnection!.addCandidate(
              RTCIceCandidate(
                data['candidate'],
                data['sdpMid'],
                data['sdpMLineIndex'],
              ),
            );
          }
        }
      },
    );
    // Listen for remote ICE candidates above

    return roomId;
  }

  Future<void> joinRoom(String roomId) async {
    final db = FirebaseFirestore.instance;
    final roomRef = db.collection('rooms').doc(roomId);
    final roomSnapshot = await roomRef.get();
    print('Got room ${roomSnapshot.exists}');

    if (roomSnapshot.exists) {
      print('Create PeerConnection with configuration: $configuration');
      peerConnection = await createPeerConnection(configuration);

      registerPeerConnectionListeners();

      localStream?.getTracks().forEach((track) {
        peerConnection?.addTrack(track, localStream!);
      });

      // Code for collecting ICE candidates below
      var calleeCandidatesCollection = roomRef.collection('calleeCandidates');
      peerConnection!.onIceCandidate = (RTCIceCandidate candidate) {
        if (candidate == null) {
          print('onIceCandidate: complete!');
          return;
        }
        print('onIceCandidate: ${candidate.toMap()}');
        calleeCandidatesCollection.add(candidate.toMap());
      };
      // Code for collecting ICE candidate above

      peerConnection?.onTrack = (RTCTrackEvent event) {
        print('Got remote track: ${event.streams[0]}');
        event.streams[0].getTracks().forEach((track) {
          print('Add a track to the remoteStream: $track');
          remoteStream?.addTrack(track);
        });
      };

      // Code for creating SDP answer below
      final data = roomSnapshot.data() as Map<String, dynamic>;
      print('Got offer $data');

      final offer = data['offer'];
      await peerConnection?.setRemoteDescription(
        RTCSessionDescription(offer['sdp'], offer['type']),
      );

      final answer = await peerConnection!.createAnswer();
      print('Created Answer $answer');

      await peerConnection!.setLocalDescription(answer);

      final roomWithAnswer = {
        'answer': {'type': answer.type, 'sdp': answer.sdp}
      };

      await roomRef.update(roomWithAnswer);
      // Finished creating SDP answer

      // Listening for remote ICE candidates below
      roomRef.collection('callerCandidates').snapshots().listen(
        (snapshot) {
          for (final document in snapshot.docChanges) {
            final data = document.doc.data() as Map<String, dynamic>;
            print(data);
            print('Got new remote ICE candidate: $data');
            peerConnection!.addCandidate(
              RTCIceCandidate(
                data['candidate'],
                data['sdpMid'],
                data['sdpMLineIndex'],
              ),
            );
          }
        },
      );
    }
  }

  Future<void> openUserMedia(RTCVideoRenderer localVideo, RTCVideoRenderer remoteVideo) async {
    final stream = await navigator.mediaDevices.getUserMedia({'video': true, 'audio': true});

    localVideo.srcObject = stream;
    localStream = stream;

    remoteVideo.srcObject = await createLocalMediaStream('key');
  }

  Future<void> hangUp(RTCVideoRenderer localVideo) async {
    localVideo.srcObject!.getTracks().forEach((track) => track.stop());

    if (remoteStream != null) {
      remoteStream!.getTracks().forEach((track) => track.stop());
    }

    if (peerConnection != null) peerConnection!.close();

    if (roomId != null) {
      final db = FirebaseFirestore.instance;
      final roomRef = db.collection('rooms').doc(roomId);
      final calleeCandidates = await roomRef.collection('calleeCandidates').get();

      for (var document in calleeCandidates.docs) {
        document.reference.delete();
      }

      final callerCandidates = await roomRef.collection('callerCandidates').get();
      for (var document in callerCandidates.docs) {
        document.reference.delete();
      }

      await roomRef.delete();
    }

    localStream!.dispose();
    remoteStream?.dispose();

    localStream = null;
    remoteStream = null;
  }

  void registerPeerConnectionListeners() {
    peerConnection?.onIceGatheringState = (RTCIceGatheringState state) {
      print('ICE gathering state changed: $state');
    };

    peerConnection?.onConnectionState = (RTCPeerConnectionState state) {
      print('Connection state change: $state');
    };

    peerConnection?.onSignalingState = (RTCSignalingState state) {
      print('Signaling state change: $state');
    };

    peerConnection?.onIceGatheringState = (RTCIceGatheringState state) {
      print('ICE connection state change: $state');
    };

    peerConnection?.onAddStream = (MediaStream stream) {
      print("Add remote stream");
      onAddRemoteStream?.call(stream);
      remoteStream = stream;
    };
  }
}
