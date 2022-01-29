import 'package:allyfewebrtc/firebase_options.dart';
import 'package:allyfewebrtc/signaling.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
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
  final _localRenderer = RTCVideoRenderer();
  final _remoteRenderer = RTCVideoRenderer();
  final _textEditingController = TextEditingController(text: '');
  final _signaling = Signaling();

  @override
  void initState() {
    _localRenderer.initialize();
    _remoteRenderer.initialize();

    _signaling.onAddRemoteStream = ((stream) {
      _remoteRenderer.srcObject = stream;
      setState(() {});
    });

    super.initState();
  }

  @override
  void dispose() {
    _localRenderer.dispose();
    _remoteRenderer.dispose();
    super.dispose();
  }

  Flex view({required List<Widget> children}) {
    final isLandscape = MediaQuery.of(context).size.width > MediaQuery.of(context).size.height;
    return isLandscape ? Row(children: children) : Column(children: children);
  }

  void _hangUp() {
    setState(() {
      _signaling.hangUp(_localRenderer);
      _textEditingController.text = '';
    });
  }

  Future<void> _createRoom() async {
    await _signaling.openUserMedia(_localRenderer, _remoteRenderer);

    final _roomId = await _signaling.createRoom(_remoteRenderer);

    setState(() => _textEditingController.text = _roomId);
  }

  Future<void> _joinRoom() async {
    await _signaling.openUserMedia(_localRenderer, _remoteRenderer);
    _signaling.joinRoom(_textEditingController.text);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("WebRTC")),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
      floatingActionButton: Wrap(
        spacing: 15,
        children: [
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
          if (_signaling.isLocalStreamOk()) ...[
            FutureBuilder<int>(
              future: _signaling.cameraCount(),
              initialData: 0,
              builder: (context, snap) => FloatingActionButton(
                tooltip: 'Switch camera',
                backgroundColor: Colors.blueGrey,
                child: const Icon(Icons.switch_camera),
                onPressed: (snap.data ?? 0) > 1 ? () => _signaling.switchCamera() : null,
              ),
            ),
            FloatingActionButton(
              tooltip: _signaling.isMicMuted() ? 'Un-mute mic' : 'Mute mic',
              backgroundColor: Colors.brown,
              child: _signaling.isMicMuted() ? const Icon(Icons.mic_outlined) : const Icon(Icons.mic_off),
              onPressed: () => _signaling.muteMic(),
            ),
          ],
          FloatingActionButton(
            tooltip: 'Hangup',
            backgroundColor: Colors.red,
            child: const Icon(Icons.call_end),
            onPressed: () => _hangUp(),
          ),
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
                  child: TextFormField(controller: _textEditingController),
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
                  if (_signaling.localStream != null) ...[
                    Expanded(
                      child: Container(
                        margin: const EdgeInsets.all(8.0),
                        child: RTCVideoView(_localRenderer, mirror: true),
                      ),
                    ),
                  ],
                  if (_signaling.remoteStream != null) ...[
                    Expanded(
                      child: Container(
                        margin: const EdgeInsets.all(8.0),
                        child: RTCVideoView(_remoteRenderer),
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
