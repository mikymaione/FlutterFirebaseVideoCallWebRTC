import 'package:flutter/material.dart';
import 'package:flutter_firebase_video_call_webrtc/video_render_view.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:flutter_firebase_video_call_webrtc/signaling.dart';
import 'package:flutter_firebase_video_call_webrtc/grid_layout_calculator.dart';

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
    final allRenderers = <Widget>[];

    if (localRenderOk) {
      allRenderers.add(
        VideoRendererView(
          renderer: localRenderer,
          loading: false,
          mirror: !signaling.isScreenSharing(),
        ),
      );
    }

    for (final entry in remoteRenderers.entries) {
      allRenderers.add(
        VideoRendererView(
          renderer: entry.value,
          loading: remoteRenderersLoading[entry.key] ?? true,
        ),
      );
    }

    final isLandscape = MediaQuery.of(context).size.width > MediaQuery.of(context).size.height;
    final layout = GridLayoutCalculator.calculate(allRenderers.length, isLandscape: isLandscape);
    final columns = layout.columns;
    final rows = layout.rows;

    return LayoutBuilder(
      builder: (context, constraints) {
        final itemWidth = constraints.maxWidth / columns;
        final itemHeight = constraints.maxHeight / rows;

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

              // Griglia fissa senza scroll
              Expanded(
                child: Center(
                  child: SizedBox(
                    width: itemWidth * columns,
                    height: itemHeight * rows,
                    child: GridView.builder(
                      physics: const NeverScrollableScrollPhysics(),
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: columns,
                        childAspectRatio: itemWidth / itemHeight,
                      ),
                      itemCount: allRenderers.length,
                      itemBuilder: (context, index) {
                        return SizedBox(
                          width: itemWidth,
                          height: itemHeight,
                          child: allRenderers[index],
                        );
                      },
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
