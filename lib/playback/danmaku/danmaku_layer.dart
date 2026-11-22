import 'package:canvas_danmaku/canvas_danmaku.dart';
import 'package:flutter/material.dart';

import '../media3/osd_model.dart';
import 'danmaku_session.dart';
import 'danmaku_settings.dart';

/// Paints the comments over the video, driven by the player clock.
///
/// Sits between the video surface and the OSD controls, so it behaves the same
/// on the mpv backend (a native child window under the Flutter view) and on the
/// Media3 backend.
///
/// Layout mirrors the mpv Lua overlay (`dm_layout` in `zerk_osd.lua`): three
/// independent bands — top, scrolling, bottom — each sized in whole lines from
/// the settings. `canvas_danmaku` builds its track list out of the box height
/// of whatever rectangle it is given, so every band is its own [DanmakuScreen]
/// and the line limits fall out of the geometry instead of being ignored.
class DanmakuLayer extends StatefulWidget {
  const DanmakuLayer({super.key, required this.model, required this.session});

  final OsdModel model;
  final DanmakuSession session;

  @override
  State<DanmakuLayer> createState() => _DanmakuLayerState();
}

class _DanmakuLayerState extends State<DanmakuLayer> {
  DanmakuController<Object?>? _scroll;
  DanmakuController<Object?>? _top;
  DanmakuController<Object?>? _bottom;

  /// Vertical space a band keeps free for the subtitle area at the bottom, the
  /// same 8% the mpv overlay reserves.
  static const _bottomMargin = 0.08;

  String _optionSignature = '';

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
        for (final c in _controllers) {
          c?.pause();
        }
      }
      return;
    }
    if (_paused) {
      _paused = false;
      for (final c in _controllers) {
        c?.resume();
      }
    }

    final position = state.position;
    // A jump means the user seeked: the canvas is full of comments that belong
    // to a timeline we are no longer on.
    if ((position - _lastPosition).abs() > const Duration(seconds: 2)) {
      _clear();
      _lastSecond = -1;
    }
    _lastPosition = position;

    final second = (position.inMilliseconds - widget.session.offsetMs) ~/ 1000;
    if (second < 0 || second == _lastSecond) return;
    _lastSecond = second;
    _emit(second);
  }

  Iterable<DanmakuController<Object?>?> get _controllers => [_scroll, _top, _bottom];

  void _clear() {
    for (final c in _controllers) {
      c?.clear();
    }
  }

  void _emit(int second) {
    for (final comment in widget.session.at(second)) {
      final type = _type(comment.mode);
      final controller = switch (type) {
        DanmakuItemType.top => _top,
        DanmakuItemType.bottom => _bottom,
        _ => _scroll,
      };
      controller?.addDanmaku(
        DanmakuContentItem<Object?>(
          comment.text,
          color: Color(0xFF000000 | (comment.color & 0xFFFFFF)),
          type: type,
        ),
      );
    }
  }

  static DanmakuItemType _type(int mode) => switch (mode) {
        4 => DanmakuItemType.bottom,
        5 => DanmakuItemType.top,
        _ => DanmakuItemType.scroll,
      };

  /// Font size plus the configured gap: the library derives its track pitch
  /// from `fontSize * lineHeight`, so folding the gap into the multiplier keeps
  /// one band a whole number of lines tall.
  static double _pitch(DanmakuSettings s) => s.fontSize + s.lineGap;

  DanmakuOption _buildOption(DanmakuSettings s) {
    final pitch = _pitch(s);
    return DanmakuOption(
      fontSize: s.fontSize,
      // FontWeight.values[4] is w500 (the library's default); bold jumps to
      // w700 like the mpv overlay's `\b1`.
      fontWeight: s.bold ? 6 : 4,
      opacity: s.opacity,
      area: 1,
      duration: 12,
      lineHeight: pitch / s.fontSize,
      strokeWidth: 1.6,
      // The bands are already laid out above the subtitle strip.
      safeArea: false,
    );
  }

  /// Applies a changed option to the live controllers (settings load
  /// asynchronously after the first build).
  void _syncOption(DanmakuOption option, DanmakuSettings s) {
    final signature = '${s.fontSize}/${s.lineGap}/${s.opacity}/${s.bold}';
    if (signature == _optionSignature) return;
    final first = _optionSignature.isEmpty;
    _optionSignature = signature;
    if (first) return; // the screens are created with this option already
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      for (final c in _controllers) {
        c?.updateOption(option);
      }
    });
  }

  Widget _screen(
    String band,
    void Function(DanmakuController<Object?>) assign,
    DanmakuOption option,
  ) =>
      DanmakuScreen<Object?>(
        // Stable identity: adding the top/bottom band must not re-create the
        // scrolling controller and wipe the comments already on screen.
        key: ValueKey('danmaku:$band'),
        createdController: (controller) {
          assign(controller);
          if (_paused) controller.pause();
        },
        option: option,
      );

  @override
  Widget build(BuildContext context) {
    if (!widget.session.rendering) return const SizedBox.shrink();
    final settings = widget.session.settings;
    final option = _buildOption(settings);
    _syncOption(option, settings);

    return LayoutBuilder(
      builder: (context, constraints) {
        final height = constraints.maxHeight;
        if (!height.isFinite || height <= 0) return const SizedBox.shrink();

        final pitch = _pitch(settings);
        // +1px absorbs the float error in the library's
        // `floor(height / textHeight)`, which would otherwise give n-1 tracks.
        double band(int lines) => lines > 0 ? lines * pitch + 1 : 0;
        final topH = band(settings.topLines);
        final scrollH = band(settings.scrollLines);
        final bottomH = band(settings.bottomLines);
        final margin = height * _bottomMargin;

        // Keep the scrolling band inside the space the top band leaves over:
        // an over-tall setting must never push comments off screen.
        final available = height - margin - topH;
        final scrollBand = scrollH.clamp(0.0, available < 0 ? 0.0 : available);

        return Stack(
          children: [
            if (topH > 0)
              Positioned(
                left: 0,
                right: 0,
                top: 0,
                height: topH,
                child: _screen('top', (c) => _top = c, option),
              ),
            Positioned(
              left: 0,
              right: 0,
              top: topH,
              height: scrollBand,
              child: _screen('scroll', (c) => _scroll = c, option),
            ),
            if (bottomH > 0)
              Positioned(
                left: 0,
                right: 0,
                bottom: margin,
                height: bottomH,
                child: _screen('bottom', (c) => _bottom = c, option),
              ),
          ],
        );
      },
    );
  }
}
