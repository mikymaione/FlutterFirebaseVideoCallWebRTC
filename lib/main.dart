import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_firebase_video_call_webrtc/firebase_options.dart';
import 'package:flutter_firebase_video_call_webrtc/signaling.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: "WebRTC",
      theme: ThemeData(primarySwatch: Colors.orange),
      home: const MyHomePage(),
    );
  }
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({Key? key}) : super(key: key);

  @override
  _MyHomePageState createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  final signaling = Signaling();

  final localRenderer = RTCVideoRenderer();
  final Map<String, RTCVideoRenderer> remoteRenderers = {};

  bool localRendererInitialized = false;

  @override
  void initState() {
    super.initState();

    signaling.onAddLocalStream = (peerUuid, stream) async {
      if (!localRendererInitialized) {
        await localRenderer.initialize();
        localRendererInitialized = true;
      }

      setState(() => localRenderer.srcObject = stream);
    };

    signaling.onAddRemoteStream = (peerUuid, stream) async {
      final remoteRenderer = RTCVideoRenderer();
      await remoteRenderer.initialize();
      remoteRenderer.srcObject = stream;

      setState(() => remoteRenderers.putIfAbsent(peerUuid, () => remoteRenderer));
    };

    signaling.onRemoveRemoteStream = (peerUuid) {
      if (remoteRenderers.containsKey(peerUuid)) {
        remoteRenderers[peerUuid]!.srcObject = null;
        remoteRenderers[peerUuid]!.dispose();

        setState(() => remoteRenderers.remove(peerUuid));
      }
    };
  }

  @override
  void dispose() {
    localRenderer.dispose();

    disposeRemoteRenderers();

    super.dispose();
  }

  void disposeRemoteRenderers() {
    for (final remoteRenderer in remoteRenderers.values) {
      remoteRenderer.dispose();
    }

    remoteRenderers.clear();
  }

  Flex view({required List<Widget> children}) {
    final isLandscape = MediaQuery.of(context).size.width > MediaQuery.of(context).size.height;
    return isLandscape ? Row(children: children) : Column(children: children);
  }

  void hangUp() {
    setState(() {
      signaling.hangUp(localRenderer);
      disposeRemoteRenderers();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("WebRTC")),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
      floatingActionButton: FutureBuilder<int>(
        future: signaling.cameraCount(),
        initialData: 0,
        builder: (context, cameraCountSnap) => Wrap(
          spacing: 15,
          children: [
            if (!signaling.isLocalStreamOk()) ...[
              FloatingActionButton(
                tooltip: 'Join room',
                child: const Icon(Icons.add_call),
                backgroundColor: Colors.green,
                onPressed: () => signaling.join(),
              ),
            ] else ...[
              FloatingActionButton(
                tooltip: signaling.isScreenSharing() ? 'Change screen sharing' : 'Start screen sharing',
                backgroundColor: Colors.amber,
                child: const Icon(Icons.screen_share_outlined),
                onPressed: () => signaling.screenSharing(),
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
                  backgroundColor: Colors.blueGrey,
                  child: const Icon(Icons.switch_camera),
                  onPressed: () => signaling.switchCamera(),
                )
              ],
              FloatingActionButton(
                tooltip: signaling.isMicMuted() ? 'Un-mute mic' : 'Mute mic',
                backgroundColor: signaling.isMicMuted() ? Colors.brown : Colors.redAccent,
                child: signaling.isMicMuted() ? const Icon(Icons.mic_outlined) : const Icon(Icons.mic_off),
                onPressed: () => signaling.muteMic(),
              ),
              FloatingActionButton(
                tooltip: 'Hangup',
                backgroundColor: Colors.red,
                child: const Icon(Icons.call_end),
                onPressed: () => hangUp(),
              ),
            ],
          ],
        ),
      ),
      body: Container(
        margin: const EdgeInsets.all(8.0),
        child: view(
          children: [
            if (localRenderer.srcObject != null) ...[
              Expanded(
                child: Container(
                  margin: const EdgeInsets.all(8.0),
                  child: RTCVideoView(localRenderer, mirror: true),
                ),
              ),
            ],
            for (final remoteRenderer in remoteRenderers.values) ...[
              if (true == remoteRenderer.srcObject?.active) ...[
                Expanded(
                  child: Container(
                    margin: const EdgeInsets.all(8.0),
                    child: RTCVideoView(remoteRenderer),
                  ),
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }
}
