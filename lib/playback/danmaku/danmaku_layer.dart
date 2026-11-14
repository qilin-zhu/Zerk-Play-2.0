import 'dart:async';

import 'package:canvas_danmaku/canvas_danmaku.dart';
import 'package:flutter/material.dart';

import '../media3/osd_model.dart';
import 'danmaku_api.dart';
import 'danmaku_settings.dart';
import 'danmaku_store.dart';

/// Draws bullet comments over the video, driven by the player clock.
///
/// Sits between the video surface and the OSD controls, so it works the same on
/// the mpv backend (a native child window under the Flutter view) and on the
/// Media3 backend.
///
/// Nothing is downloaded unless danmaku is switched on in the settings.
class DanmakuLayer extends StatefulWidget {
  const DanmakuLayer({super.key, required this.model});

  final OsdModel model;

  @override
  State<DanmakuLayer> createState() => _DanmakuLayerState();
}

class _DanmakuLayerState extends State<DanmakuLayer> {
  final _store = DanmakuStore();

  DanmakuSettings _settings = const DanmakuSettings();
  DanmakuController<Object?>? _controller;

  Timer? _ticker;
  bool _paused = false;
  bool _requested = false;
  bool _disposed = false;

  Duration _lastPosition = Duration.zero;
  int _lastSecond = -1;

  @override
  void initState() {
    super.initState();
    widget.model.state.addListener(_tick);
    widget.model.addListener(_onModelChanged);
    unawaited(_load());
  }

  @override
  void dispose() {
    _disposed = true;
    _ticker?.cancel();
    widget.model.state.removeListener(_tick);
    widget.model.removeListener(_onModelChanged);
    super.dispose();
  }

  Future<void> _load() async {
    final settings = await DanmakuSettings.load();
    if (_disposed || !mounted) return;
    setState(() => _settings = settings);
    if (settings.usable) {
      _ticker ??= Timer.periodic(const Duration(seconds: 1), (_) => _tick());
      _maybeFetch();
    }
  }

  void _onModelChanged() => _maybeFetch();

  void _maybeFetch() {
    if (_requested || !_settings.usable) return;
    final query = _query();
    if (query.isEmpty) return;
    _requested = true;
    unawaited(_fetch(query));
  }

  /// Prefer `Series S01E02` — dandanplay matches on normalised names, and the
  /// episode code lives in the OSD subtitle for episodes.
  String _query() {
    final title = widget.model.title.trim();
    if (title.isEmpty) return '';
    final code = RegExp(r'S\d{1,4}\s*E\d{1,4}', caseSensitive: false)
        .firstMatch(widget.model.subtitle)
        ?.group(0);
    if (code == null) return title;
    return '$title ${code.toUpperCase().replaceAll(RegExp(r'\s+'), '')}';
  }

  Future<void> _fetch(String query) async {
    final api = DanmakuApi(
      server: _settings.server,
      appId: _settings.appId,
      appSecret: _settings.appSecret,
    );
    try {
      final comments = await api.forFile(query);
      if (_disposed || !mounted) return;
      _store.replaceAll(comments);
      setState(() {});
    } finally {
      api.close();
    }
  }

  void _tick() {
    if (!mounted || !_settings.enabled) return;
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

    final second = (position.inMilliseconds - _settings.offsetMs) ~/ 1000;
    if (second < 0 || second == _lastSecond) return;
    _lastSecond = second;
    _emit(second);
  }

  void _emit(int second) {
    final controller = _controller;
    if (controller == null) return;
    for (final comment in _store.at(second)) {
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
    if (!_settings.enabled) return const SizedBox.shrink();
    return DanmakuScreen<Object?>(
      createdController: (controller) {
        _controller = controller;
        if (_paused) controller.pause();
      },
      option: DanmakuOption(
        fontSize: _settings.fontSize,
        opacity: _settings.opacity,
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
