import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

class VideoRendererView extends StatelessWidget {
  final RTCVideoRenderer renderer;
  final bool loading;
  final bool mirror;

  const VideoRendererView({
    super.key,
    required this.renderer,
    required this.loading,
    this.mirror = false,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        margin: const EdgeInsets.all(4),
        child: loading
            ? const Center(
                child: CircularProgressIndicator(),
              )
            : RTCVideoView(
                renderer,
                mirror: mirror,
              ),
      ),
    );
  }
}
