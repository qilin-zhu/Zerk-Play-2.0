import 'dart:async';

import 'package:flutter/foundation.dart';

import '../media3/osd_model.dart';
import 'danmaku_api.dart';
import 'danmaku_settings.dart';
import 'danmaku_source.dart';
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

  /// Called after every automatic attempt so the player can say what happened.
  /// Silence is the worst outcome here: an empty screen looks like a bug.
  void Function(DanmakuStatus status, int count)? onResult;

  /// Raw comments, kept for backends that draw danmaku themselves. On Windows
  /// the whole player UI belongs to the mpv Lua OSD, so Flutter never gets a
  /// chance to paint over the video.
  List<DanmakuComment> comments = const [];

  /// Fired whenever the set of comments a backend should draw changes.
  VoidCallback? onData;

  bool _started = false;
  bool _disposed = false;
  DanmakuApi? _api;

  bool get enabled => settings.enabled;

  bool get configured => settings.usableSources.isNotEmpty;

  /// Whether the overlay should paint anything.
  bool get rendering => enabled && visible && store.isNotEmpty;

  int get count => store.count;

  int get offsetMs => settings.offsetMs;

  /// The source the comments actually came from, for the panel.
  DanmakuSource? matchedSource;

  String get host => matchedSource?.host ?? (settings.usableSources.isEmpty ? '' : settings.usableSources.first.host);

  List<DanmakuComment> at(int second) => store.at(second);

  DanmakuSource? get _firstSource => settings.usableSources.isEmpty ? null : settings.usableSources.first;

  DanmakuApi? get _client {
    final source = _firstSource;
    if (source == null) return null;
    return _api ??= DanmakuApi.of(source);
  }

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
  ///
  /// Emby renders the code as `S1 · E5`, so a naive `S\d+E\d+` misses it and
  /// the request goes out with the bare show name. That matches the wrong
  /// title: `玫瑰战争` alone resolves to a 2025 film called `玫瑰`, not to the
  /// series' fifth episode.
  String _query() {
    final title = _model.title.trim();
    if (title.isEmpty) return '';
    final subtitle = _model.subtitle;

    String pad(String digits) => digits.padLeft(2, '0');

    final code = RegExp(r'S\s*(\d{1,3})\W*E\s*(\d{1,4})', caseSensitive: false).firstMatch(subtitle);
    if (code != null) {
      return '$title S${pad(code.group(1)!)}E${pad(code.group(2)!)}';
    }

    // Some servers only show "第 5 集".
    final chinese = RegExp(r'第\s*(\d{1,4})\s*集').firstMatch(subtitle);
    if (chinese != null) {
      final season = RegExp(r'S\s*(\d{1,3})', caseSensitive: false).firstMatch(subtitle)?.group(1) ?? '1';
      return '$title S${pad(season)}E${pad(chinese.group(1)!)}';
    }

    return title;
  }

  /// Walks the source list in the user's priority order: the first one that has
  /// comments for this episode wins, later ones are never asked.
  Future<void> _match(String name) async {
    status = DanmakuStatus.matching;
    error = null;
    _notify();

    for (final source in settings.usableSources) {
      if (_disposed) return;
      final api = DanmakuApi.of(source);
      try {
        final result = await api.match(name);
        final id = result.episodeId;
        if (id == null) continue;
        final list = await api.comments(id);
        if (list.isEmpty) continue;
        if (_disposed) return;
        matchedSource = source;
        matchedTitle = result.title ?? name;
        comments = list;
        store.replaceAll(list);
        status = DanmakuStatus.ready;
        _notify();
        onData?.call();
        onResult?.call(status, store.count);
        return;
      } catch (e) {
        error = '$e';
      } finally {
        api.close();
      }
    }

    if (_disposed) return;
    store.clear();
    comments = const [];
    status = DanmakuStatus.empty;
    matchedSource = null;
    _notify();
    onResult?.call(status, 0);
    onData?.call();
  }

  Future<void> _apply(int episodeId) async {
    final api = _client;
    if (api == null) return;
    final list = await api.comments(episodeId);
    if (_disposed) return;
    comments = list;
    store.replaceAll(list);
    status = store.isEmpty ? DanmakuStatus.empty : DanmakuStatus.ready;
    _notify();
    onData?.call();
  }

  /// Turns the feature on or off without leaving the player.
  Future<void> setEnabled(bool value) async {
    settings = settings.copyWith(enabled: value);
    await settings.save();
    if (!value) {
      store.clear();
      comments = const [];
      status = DanmakuStatus.off;
      _started = false;
      _notify();
      onData?.call();
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
    matchedSource = null;
    if (!settings.enabled) {
      status = DanmakuStatus.off;
      _notify();
      return;
    }
    _maybeMatch();
    _notify();
  }

  Future<List<DanmakuAnime>> search(String keyword) async {
    final api = _client;
    if (api == null) return const [];
    try {
      return await api.searchAnime(keyword);
    } catch (e) {
      error = '$e';
      return const [];
    }
  }

  Future<List<DanmakuEpisode>> episodes(DanmakuAnime anime) async {
    final api = _client;
    if (api == null) return const [];
    try {
      return await api.episodes(anime.id);
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
