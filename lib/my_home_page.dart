import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_firebase_video_call_webrtc/signaling.dart';
import 'package:flutter_firebase_video_call_webrtc/snack_msg.dart';
import 'package:flutter_firebase_video_call_webrtc/webrtc_body.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

typedef ExecuteCallback = void Function();
typedef ExecuteFutureCallback = Future<void> Function();

class MyHomePage extends StatefulWidget {
  const MyHomePage({super.key});

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  static const _chars = 'AaBbCcDdEeFfGgHhIiJjKkLlMmNnOoPpQqRrSsTtUuVvWwXxYyZz1234567890';
  static final _rnd = Random();

  static String getRandomString(int length) =>
      String.fromCharCodes(Iterable.generate(length, (index) => _chars.codeUnitAt(_rnd.nextInt(_chars.length))));

  final signaling = Signaling(localDisplayName: getRandomString(20));

  final localRenderer = RTCVideoRenderer();
  final Map<String, RTCVideoRenderer> remoteRenderers = {};
  final Map<String, bool?> remoteRenderersLoading = {};

  final roomIdController = TextEditingController();

  bool localRenderOk = false;
  bool error = false;

  @override
  void initState() {
    super.initState();

    roomIdController.addListener(() {
      if (mounted) {
        setState(() {
          //
        });
      }
    });

    signaling.onAddLocalStream = (peerUuid, displayName, stream) {
      setState(() {
        localRenderer.srcObject = stream;
        localRenderOk = stream != null;
      });
    };

    signaling.onAddRemoteStream = (peerUuid, displayName, stream) async {
      final remoteRenderer = RTCVideoRenderer();
      await remoteRenderer.initialize();
      remoteRenderer.srcObject = stream;

      setState(() => remoteRenderers[peerUuid] = remoteRenderer);
    };

    signaling.onRemoveRemoteStream = (peerUuid, displayName) {
      if (remoteRenderers.containsKey(peerUuid)) {
        remoteRenderers[peerUuid]!.srcObject = null;
        remoteRenderers[peerUuid]!.dispose();

        setState(() {
          remoteRenderers.remove(peerUuid);
          remoteRenderersLoading.remove(peerUuid);
        });
      }
    };

    signaling.onConnectionConnected = (peerUuid, displayName) {
      setState(() => remoteRenderersLoading[peerUuid] = false);
    };

    signaling.onConnectionLoading = (peerUuid, displayName) {
      setState(() => remoteRenderersLoading[peerUuid] = true);
    };

    signaling.onConnectionError = (peerUuid, displayName) {
      SnackMsg.showError(context, 'Connection failed with $displayName');
      error = true;
    };

    signaling.onGenericError = (errorText) {
      SnackMsg.showError(context, errorText);
      error = true;
    };

    final uri = Uri.base;
    final roomIdFromUrl = uri.queryParameters['roomId'] ?? '';
    roomIdController.text = roomIdFromUrl;

    initCamera();
  }

  @override
  void dispose() {
    localRenderer.dispose();
    roomIdController.dispose();

    disposeRemoteRenderers();

    super.dispose();
  }

  Future<void> initCamera() async {
    await localRenderer.initialize();
    await doTry(runAsync: () => signaling.openUserMedia());
  }

  void disposeRemoteRenderers() {
    for (final remoteRenderer in remoteRenderers.values) {
      remoteRenderer.dispose();
    }

    remoteRenderers.clear();
  }

  Future<void> doTry({ExecuteCallback? runSync, ExecuteFutureCallback? runAsync, ExecuteCallback? onError}) async {
    try {
      runSync?.call();
      await runAsync?.call();
    } catch (e) {
      if (mounted) {
        SnackMsg.showError(context, 'Error: $e');
      }

      onError?.call();
    }
  }

  Future<void> reJoin() async {
    await hangUp(false);
    await join();
  }

  Future<void> join() async {
    setState(() => error = false);

    await signaling.reOpenUserMedia();
    await signaling.join(roomIdController.text);
  }

  Future<void> hangUp(bool exit) async {
    setState(() {
      error = false;

      if (exit) {
        roomIdController.text = '';
      }
    });

    await signaling.hangUp(exit);

    setState(() {
      disposeRemoteRenderers();
    });
  }

  bool isMicMuted() {
    try {
      return signaling.isMicMuted();
    } catch (e) {
      SnackMsg.showError(context, 'Error: $e');
      return true;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'WebRTC - [MAIONE MIKΨ]',
        ),
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
      floatingActionButton: FutureBuilder<int>(
        future: signaling.cameraCount(),
        initialData: 0,
        builder: (context, cameraCountSnap) => Wrap(
          spacing: 15,
          children: [
            if (roomIdController.text.length > 2) ...[
              FloatingActionButton(
                tooltip: 'Share room link',
                backgroundColor: Colors.blueAccent,
                child: const Icon(Icons.share),
                onPressed: () async {
                  final roomUrl = 'https://mikymaione.github.io/webrtc.github.io?roomId=${roomIdController.text}';

                  final shareText = '''
Join my WebRTC room

Room ID: ${roomIdController.text}
Link: $roomUrl
''';

                  await Clipboard.setData(
                    ClipboardData(
                      text: shareText,
                    ),
                  );

                  if (mounted) {
                    SnackMsg.showInfo(context, 'Room link copied to clipboard!');
                  }
                },
              ),
            ],
            if (!localRenderOk) ...[
              FloatingActionButton(
                tooltip: 'Open camera',
                backgroundColor: Colors.redAccent,
                child: const Icon(Icons.videocam_off_outlined),
                onPressed: () async => await doTry(
                  runAsync: () => signaling.reOpenUserMedia(),
                ),
              ),
            ],
            if (roomIdController.text.length > 2) ...[
              if (error) ...[
                FloatingActionButton(
                  tooltip: 'Retry call',
                  backgroundColor: Colors.green,
                  child: const Icon(Icons.add_call),
                  onPressed: () async => await doTry(
                    runAsync: () => join(),
                    onError: () => hangUp(false),
                  ),
                ),
              ],
              if (localRenderOk && signaling.isJoined()) ...[
                FloatingActionButton(
                  tooltip: signaling.isScreenSharing() ? 'Change screen sharing' : 'Start screen sharing',
                  backgroundColor: signaling.isScreenSharing() ? Colors.amber : Colors.grey,
                  child: const Icon(Icons.screen_share_outlined),
                  onPressed: () async => await doTry(
                    runAsync: () => signaling.screenSharing(),
                  ),
                ),
                if (signaling.isScreenSharing()) ...[
                  FloatingActionButton(
                    tooltip: 'Stop screen sharing',
                    backgroundColor: Colors.redAccent,
                    child: const Icon(Icons.stop_screen_share_outlined),
                    onPressed: () => signaling.stopScreenSharing(),
                  ),
                ],
                if (cameraCountSnap.hasData && cameraCountSnap.requireData > 1) ...[
                  FloatingActionButton(
                    tooltip: 'Switch camera',
                    backgroundColor: Colors.grey,
                    child: const Icon(Icons.switch_video_outlined),
                    onPressed: () async => await doTry(
                      runAsync: () => signaling.switchCamera(),
                    ),
                  )
                ],
                FloatingActionButton(
                  tooltip: isMicMuted() ? 'Un-mute mic' : 'Mute mic',
                  backgroundColor: isMicMuted() ? Colors.redAccent : Colors.grey,
                  child: isMicMuted() ? const Icon(Icons.mic_off) : const Icon(Icons.mic_outlined),
                  onPressed: () => doTry(
                    runSync: () => setState(() => signaling.muteMic()),
                  ),
                ),
                FloatingActionButton(
                  tooltip: 'Hangup',
                  backgroundColor: Colors.red,
                  child: const Icon(Icons.call_end),
                  onPressed: () => hangUp(false),
                ),
                FloatingActionButton(
                  tooltip: 'Exit',
                  backgroundColor: Colors.red,
                  child: const Icon(Icons.exit_to_app),
                  onPressed: () => hangUp(true),
                ),
              ] else ...[
                FloatingActionButton(
                  tooltip: 'Start call',
                  backgroundColor: Colors.green,
                  child: const Icon(Icons.call),
                  onPressed: () async => await doTry(
                    runAsync: () => join(),
                    onError: () => hangUp(false),
                  ),
                ),
              ],
            ],
          ],
        ),
      ),
      body: WebRTCBody(
        controller: roomIdController,
        localRenderOk: localRenderOk,
        remoteRenderers: remoteRenderers,
        remoteRenderersLoading: remoteRenderersLoading,
        localRenderer: localRenderer,
        signaling: signaling,
      ),
    );
  }
}
