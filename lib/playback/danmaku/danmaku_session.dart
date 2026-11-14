import 'dart:async';

import 'package:flutter/foundation.dart';

import '../media3/osd_model.dart';
import 'danmaku_api.dart';
import 'danmaku_settings.dart';
import 'danmaku_store.dart';

enum DanmakuStatus {
  /// Switched off in the settings.
  off,

  /// Looking the title up on the server.
  matching,

  /// Comments are loaded.
  ready,

  /// Nothing matched — the user can still search by hand.
  empty,

  /// The server could not be reached, or answered with something unusable.
  failed,
}

/// Everything the danmaku feature needs while a video is playing: the config,
/// the comments, and the state the panel shows.
///
/// One instance per playback, shared by the overlay and the OSD panel.
class DanmakuSession extends ChangeNotifier {
  DanmakuSession(this._model) {
    _model.addListener(_onTitleChanged);
  }

  final OsdModel _model;
  final DanmakuStore store = DanmakuStore();

  DanmakuSettings settings = const DanmakuSettings();
  DanmakuStatus status = DanmakuStatus.off;

  /// What the server matched, e.g. `【qq】玫瑰战争 第5集`.
  String? matchedTitle;

  /// Shown in the panel when something went wrong.
  String? error;

  /// The name we asked the server about.
  String query = '';

  bool visible = true;

  bool _started = false;
  bool _disposed = false;
  DanmakuApi? _api;

  bool get enabled => settings.enabled;

  bool get configured => settings.baseUrl.isNotEmpty;

  /// Whether the overlay should paint anything.
  bool get rendering => enabled && visible && store.isNotEmpty;

  int get count => store.count;

  int get offsetMs => settings.offsetMs;

  String get host {
    final uri = Uri.tryParse(settings.baseUrl);
    return uri == null ? settings.baseUrl : '${uri.host}:${uri.port}';
  }

  List<DanmakuComment> at(int second) => store.at(second);

  DanmakuApi get _client => _api ??= DanmakuApi(
        server: settings.baseUrl,
        appId: settings.appId,
        appSecret: settings.appSecret,
      );

  @override
  void dispose() {
    _disposed = true;
    _model.removeListener(_onTitleChanged);
    _api?.close();
    super.dispose();
  }

  Future<void> init() async {
    settings = await DanmakuSettings.load();
    if (_disposed) return;
    _notify();
    if (settings.enabled) _maybeMatch();
  }

  void _onTitleChanged() => _maybeMatch();

  void _maybeMatch() {
    if (_started || _disposed || !settings.enabled || !configured) return;
    final name = _query();
    if (name.isEmpty) return;
    _started = true;
    query = name;
    unawaited(_match(name));
  }

  /// Prefer `Series S01E02` — the server matches on normalised names, and the
  /// episode code lives in the OSD subtitle for episodes.
  String _query() {
    final title = _model.title.trim();
    if (title.isEmpty) return '';
    final code = RegExp(r'S\d{1,4}\s*E\d{1,4}', caseSensitive: false).firstMatch(_model.subtitle)?.group(0);
    if (code == null) return title;
    return '$title ${code.toUpperCase().replaceAll(RegExp(r'\s+'), '')}';
  }

  Future<void> _match(String name) async {
    status = DanmakuStatus.matching;
    error = null;
    _notify();
    try {
      final result = await _client.match(name);
      if (_disposed) return;
      final id = result.episodeId;
      if (id == null) {
        store.clear();
        status = DanmakuStatus.empty;
        _notify();
        return;
      }
      matchedTitle = result.title ?? name;
      await _apply(id);
    } catch (e) {
      if (_disposed) return;
      status = DanmakuStatus.failed;
      error = '$e';
      _notify();
    }
  }

  Future<void> _apply(int episodeId) async {
    final comments = await _client.comments(episodeId);
    if (_disposed) return;
    store.replaceAll(comments);
    status = store.isEmpty ? DanmakuStatus.empty : DanmakuStatus.ready;
    _notify();
  }

  /// Turns the feature on or off without leaving the player.
  Future<void> setEnabled(bool value) async {
    settings = settings.copyWith(enabled: value);
    await settings.save();
    if (!value) {
      store.clear();
      status = DanmakuStatus.off;
      _started = false;
      _notify();
      return;
    }
    _started = false;
    _maybeMatch();
    _notify();
  }

  void setVisible(bool value) {
    visible = value;
    _notify();
  }

  /// Re-runs the automatic match, after the user fixed the address for example.
  Future<void> rematch() async {
    settings = await DanmakuSettings.load();
    _started = false;
    store.clear();
    matchedTitle = null;
    if (!settings.enabled) {
      status = DanmakuStatus.off;
      _notify();
      return;
    }
    _maybeMatch();
    _notify();
  }

  Future<List<DanmakuAnime>> search(String keyword) async {
    if (!configured) return const [];
    try {
      return await _client.searchAnime(keyword);
    } catch (e) {
      error = '$e';
      return const [];
    }
  }

  Future<List<DanmakuEpisode>> episodes(DanmakuAnime anime) async {
    if (!configured) return const [];
    try {
      return await _client.episodes(anime.id);
    } catch (e) {
      error = '$e';
      return const [];
    }
  }

  /// Manual pick from the search panel.
  Future<bool> loadEpisode(DanmakuEpisode episode) async {
    status = DanmakuStatus.matching;
    matchedTitle = episode.title;
    _notify();
    try {
      await _apply(episode.id);
      return store.isNotEmpty;
    } catch (e) {
      if (_disposed) return false;
      status = DanmakuStatus.failed;
      error = '$e';
      _notify();
      return false;
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }
}
