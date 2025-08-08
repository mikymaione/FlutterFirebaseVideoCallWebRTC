import 'package:flutter/material.dart';
import 'package:flutter_firebase_video_call_webrtc/signaling.dart';
import 'package:flutter_firebase_video_call_webrtc/video_render_view.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

class WebRTCBody extends StatelessWidget {
  final String roomId;
  final bool localRenderOk;
  final Map<String, RTCVideoRenderer> remoteRenderers;
  final Map<String, bool?> remoteRenderersLoading;
  final RTCVideoRenderer localRenderer;
  final ValueChanged<String> onRoomIdChanged;
  final Signaling signaling;

  const WebRTCBody({
    super.key,
    required this.roomId,
    required this.localRenderOk,
    required this.remoteRenderers,
    required this.remoteRenderersLoading,
    required this.localRenderer,
    required this.onRoomIdChanged,
    required this.signaling,
  });

  @override
  Widget build(BuildContext context) {
    final isLandscape = MediaQuery.of(context).size.width > MediaQuery.of(context).size.height;

    return Container(
      margin: const EdgeInsets.all(8.0),
      child: Column(
        children: [
          // Room ID input
          Container(
            margin: const EdgeInsets.all(8.0),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Text("Join room ID: "),
                Flexible(
                  child: TextFormField(
                    initialValue: roomId,
                    onChanged: onRoomIdChanged,
                  ),
                ),
              ],
            ),
          ),

          // Streaming views
          Expanded(
            child: isLandscape
                ? Row(children: _buildVideoViews())
                : Column(children: _buildVideoViews()),
          ),
        ],
      ),
    );
  }

  List<Widget> _buildVideoViews() {
    final List<Widget> views = [];

    if (localRenderOk) {
      views.add(
        VideoRendererView(
          renderer: localRenderer,
          loading: false,
          mirror: !signaling.isScreenSharing(),
        ),
      );
    }

    for (final entry in remoteRenderers.entries) {
      views.add(
        VideoRendererView(
          renderer: entry.value,
          loading: remoteRenderersLoading[entry.key] ?? true,
        ),
      );
    }

    return views;
  }
}
