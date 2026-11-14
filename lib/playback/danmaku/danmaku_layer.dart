import 'dart:async';

import 'package:canvas_danmaku/canvas_danmaku.dart';
import 'package:flutter/material.dart';

import '../media3/osd_model.dart';
import 'danmaku_session.dart';

/// Paints the comments over the video, driven by the player clock.
///
/// Sits between the video surface and the OSD controls, so it behaves the same
/// on the mpv backend (a native child window under the Flutter view) and on the
/// Media3 backend.
class DanmakuLayer extends StatefulWidget {
  const DanmakuLayer({super.key, required this.model, required this.session});

  final OsdModel model;
  final DanmakuSession session;

  @override
  State<DanmakuLayer> createState() => _DanmakuLayerState();
}

class _DanmakuLayerState extends State<DanmakuLayer> {
  DanmakuController<Object?>? _controller;

  bool _paused = false;
  bool _wasRendering = false;
  Duration _lastPosition = Duration.zero;
  int _lastSecond = -1;

  @override
  void initState() {
    super.initState();
    widget.model.state.addListener(_tick);
    widget.session.addListener(_onSession);
  }

  @override
  void dispose() {
    widget.model.state.removeListener(_tick);
    widget.session.removeListener(_onSession);
    super.dispose();
  }

  void _onSession() {
    // Data arriving mid-playback builds the canvas for the first time, so the
    // second we are already on has never been fed.
    final rendering = widget.session.rendering;
    if (rendering && !_wasRendering) _lastSecond = -1;
    _wasRendering = rendering;
    if (mounted) setState(() {});
  }

  void _tick() {
    if (!mounted || !widget.session.rendering) return;
    final state = widget.model.state.value;

    if (state.paused) {
      if (!_paused) {
        _paused = true;
        _controller?.pause();
      }
      return;
    }
    if (_paused) {
      _paused = false;
      _controller?.resume();
    }

    final position = state.position;
    // A jump means the user seeked: the canvas is full of comments that belong
    // to a timeline we are no longer on.
    if ((position - _lastPosition).abs() > const Duration(seconds: 2)) {
      _controller?.clear();
      _lastSecond = -1;
    }
    _lastPosition = position;

    final second = (position.inMilliseconds - widget.session.offsetMs) ~/ 1000;
    if (second < 0 || second == _lastSecond) return;
    _lastSecond = second;
    _emit(second);
  }

  void _emit(int second) {
    final controller = _controller;
    if (controller == null) return;
    for (final comment in widget.session.at(second)) {
      controller.addDanmaku(
        DanmakuContentItem<Object?>(
          comment.text,
          color: Color(0xFF000000 | (comment.color & 0xFFFFFF)),
          type: _type(comment.mode),
        ),
      );
    }
  }

  static DanmakuItemType _type(int mode) => switch (mode) {
        4 => DanmakuItemType.bottom,
        5 => DanmakuItemType.top,
        _ => DanmakuItemType.scroll,
      };

  @override
  Widget build(BuildContext context) {
    if (!widget.session.rendering) return const SizedBox.shrink();
    final settings = widget.session.settings;
    return DanmakuScreen<Object?>(
      createdController: (controller) {
        _controller = controller;
        if (_paused) controller.pause();
      },
      option: DanmakuOption(
        fontSize: settings.fontSize,
        opacity: settings.opacity,
        // Keep clear of the subtitle band at the bottom.
        area: 0.7,
        duration: 12,
        lineHeight: 1.35,
        strokeWidth: 1.6,
        safeArea: true,
      ),
    );
  }
}
