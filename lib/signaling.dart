import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

typedef StreamStateCallback = void Function(MediaStream stream);
typedef ConnectionClosedCallback = RTCVideoRenderer Function();

class Signaling {
  RTCPeerConnection? peerConnection;
  MediaStream? localStream;
  MediaStream? remoteStream;
  String? roomId;
  String? currentRoomText;
  StreamStateCallback? onAddRemoteStream;

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

  Future<String> createRoom(RTCVideoRenderer remoteRenderer) async {
    final db = FirebaseFirestore.instance;
    final roomRef = db.collection('rooms').doc();

    if (kDebugMode) {
      print('Create PeerConnection with configuration: $iceServers');
    }

    peerConnection = await createPeerConnection(iceServers);

    registerPeerConnectionListeners();

    localStream?.getTracks().forEach((track) {
      peerConnection?.addTrack(track, localStream!);
    });

    // Code for collecting ICE candidates below
    final callerCandidatesCollection = roomRef.collection('callerCandidates');

    peerConnection?.onIceCandidate = (candidate) {
      if (kDebugMode) {
        print('Got candidate: ${candidate.toMap()}');
      }
      callerCandidatesCollection.add(candidate.toMap());
    };
    // Finish Code for collecting ICE candidate

    // Add code for creating a room
    final offer = await peerConnection!.createOffer();
    await peerConnection!.setLocalDescription(offer);
    if (kDebugMode) {
      print('Created offer: $offer');
    }

    final roomWithOffer = {'offer': offer.toMap()};

    await roomRef.set(roomWithOffer);
    final roomId = roomRef.id;

    if (kDebugMode) {
      print('New room created with SDK offer. Room ID: $roomId');
    }

    currentRoomText = 'Current room is $roomId - You are the caller!';
    // Created a Room

    peerConnection?.onTrack = (event) {
      if (kDebugMode) {
        print('Got remote track: ${event.streams[0]}');
      }

      event.streams[0].getTracks().forEach(
        (track) {
          if (kDebugMode) {
            print('Add a track to the remoteStream $track');
          }
          remoteStream?.addTrack(track);
        },
      );
    };

    // Listening for remote session description below
    roomRef.snapshots().listen(
      (snapshot) async {
        if (kDebugMode) {
          print('Got updated room: ${snapshot.data()}');
        }

        final data = snapshot.data() as Map<String, dynamic>;
        if (peerConnection?.getRemoteDescription() != null && data['answer'] != null) {
          final answer = RTCSessionDescription(
            data['answer']['sdp'],
            data['answer']['type'],
          );

          if (kDebugMode) {
            print("Someone tried to connect");
          }
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
            if (kDebugMode) {
              print('Got new remote ICE candidate: ${jsonEncode(data)}');
            }

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

    if (kDebugMode) {
      print('Got room ${roomSnapshot.exists}');
    }

    if (roomSnapshot.exists) {
      if (kDebugMode) {
        print('Create PeerConnection with configuration: $iceServers');
      }
      peerConnection = await createPeerConnection(iceServers);

      registerPeerConnectionListeners();

      localStream?.getTracks().forEach((track) {
        peerConnection?.addTrack(track, localStream!);
      });

      // Code for collecting ICE candidates below
      final calleeCandidatesCollection = roomRef.collection('calleeCandidates');
      peerConnection!.onIceCandidate = (candidate) {
        if (kDebugMode) {
          print('onIceCandidate: ${candidate.toMap()}');
        }

        calleeCandidatesCollection.add(candidate.toMap());
      };
      // Code for collecting ICE candidate above

      peerConnection?.onTrack = (event) {
        if (kDebugMode) {
          print('Got remote track: ${event.streams[0]}');
        }

        event.streams[0].getTracks().forEach((track) {
          if (kDebugMode) {
            print('Add a track to the remoteStream: $track');
          }

          remoteStream?.addTrack(track);
        });
      };

      // Code for creating SDP answer below
      final data = roomSnapshot.data() as Map<String, dynamic>;
      if (kDebugMode) {
        print('Got offer $data');
      }

      final offer = data['offer'];
      await peerConnection?.setRemoteDescription(
        RTCSessionDescription(offer['sdp'], offer['type']),
      );

      final answer = await peerConnection!.createAnswer();
      if (kDebugMode) {
        print('Created Answer $answer');
      }

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

            if (kDebugMode) {
              print(data);
              print('Got new remote ICE candidate: $data');
            }

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

      for (final document in calleeCandidates.docs) {
        document.reference.delete();
      }

      final callerCandidates = await roomRef.collection('callerCandidates').get();
      for (final document in callerCandidates.docs) {
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
    peerConnection?.onIceGatheringState = (state) {
      if (kDebugMode) {
        print('ICE gathering state changed: $state');
      }
    };

    peerConnection?.onConnectionState = (state) {
      if (kDebugMode) {
        print('Connection state change: $state');
      }
    };

    peerConnection?.onSignalingState = (state) {
      if (kDebugMode) {
        print('Signaling state change: $state');
      }
    };

    peerConnection?.onIceGatheringState = (state) {
      if (kDebugMode) {
        print('ICE connection state change: $state');
      }
    };

    peerConnection?.onAddStream = (stream) {
      if (kDebugMode) {
        print("Add remote stream");
      }

      onAddRemoteStream?.call(stream);
      remoteStream = stream;
    };
  }
}
