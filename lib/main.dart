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
  final localRenderer = RTCVideoRenderer();
  final remoteRenderer = RTCVideoRenderer();
  final textEditingController = TextEditingController(text: '');
  final signaling = Signaling();

  @override
  void initState() {
    localRenderer.initialize();
    remoteRenderer.initialize();

    signaling.onAddRemoteStream = ((stream) {
      remoteRenderer.srcObject = stream;
      setState(() {});
    });

    super.initState();
  }

  @override
  void dispose() {
    localRenderer.dispose();
    remoteRenderer.dispose();
    super.dispose();
  }

  Flex view({required List<Widget> children}) {
    final isLandscape = MediaQuery.of(context).size.width > MediaQuery.of(context).size.height;
    return isLandscape ? Row(children: children) : Column(children: children);
  }

  void _hangUp() {
    setState(() {
      signaling.hangUp(localRenderer);
      textEditingController.text = '';
    });
  }

  Future<void> _createRoom() async {
    await signaling.openUserMedia(localRenderer, remoteRenderer);

    final _roomId = await signaling.createRoom(remoteRenderer);

    setState(() => textEditingController.text = _roomId);
  }

  Future<void> _joinRoom() async {
    await signaling.openUserMedia(localRenderer, remoteRenderer);
    signaling.joinRoom(textEditingController.text);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("WebRTC")),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
      floatingActionButton: Wrap(
        spacing: 15,
        children: [
          if (!signaling.isLocalStreamOk()) ...[
            FloatingActionButton(
              tooltip: 'Create room',
              backgroundColor: Colors.cyan,
              child: const Icon(Icons.video_call),
              onPressed: () => _createRoom(),
            ),
            FloatingActionButton(
              tooltip: 'Join room',
              child: const Icon(Icons.add_call),
              backgroundColor: Colors.green,
              onPressed: () => _joinRoom(), // Add roomId
            ),
          ] else ...[
            FutureBuilder<int>(
              future: signaling.cameraCount(),
              initialData: 0,
              builder: (context, snap) => FloatingActionButton(
                tooltip: 'Switch camera',
                backgroundColor: Colors.blueGrey,
                child: const Icon(Icons.switch_camera),
                onPressed: (snap.data ?? 0) > 1 ? () => signaling.switchCamera() : null,
              ),
            ),
            FloatingActionButton(
              tooltip: signaling.isMicMuted() ? 'Un-mute mic' : 'Mute mic',
              backgroundColor: Colors.brown,
              child: signaling.isMicMuted() ? const Icon(Icons.mic_outlined) : const Icon(Icons.mic_off),
              onPressed: () => signaling.muteMic(),
            ),
            FloatingActionButton(
              tooltip: 'Hangup',
              backgroundColor: Colors.red,
              child: const Icon(Icons.call_end),
              onPressed: () => _hangUp(),
            ),
          ],
        ],
      ),
      body: Column(
        children: [
          // room
          Container(
            margin: const EdgeInsets.all(8.0),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Text("Room ID: "),
                Flexible(
                  child: TextFormField(controller: textEditingController),
                )
              ],
            ),
          ),

          // video call
          Expanded(
            child: Container(
              margin: const EdgeInsets.all(8.0),
              child: view(
                children: [
                  if (signaling.localStream != null) ...[
                    Expanded(
                      child: Container(
                        margin: const EdgeInsets.all(8.0),
                        child: RTCVideoView(localRenderer, mirror: true),
                      ),
                    ),
                  ],
                  if (signaling.remoteStream != null) ...[
                    Expanded(
                      child: Container(
                        margin: const EdgeInsets.all(8.0),
                        child: RTCVideoView(remoteRenderer),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
