import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/emby/models/emby_item.dart';
import 'player_backend.dart';

/// 正在播放的那一条，供外部（小爱语音控制、hub 状态上报）读取。
final class PlaybackSnapshot {
  const PlaybackSnapshot({
    required this.id,
    required this.title,
    required this.series,
    required this.kind,
    required this.position,
    required this.duration,
    required this.paused,
    required this.volume,
  });

  final String id;
  final String title;
  final String series;
  final String kind;
  final Duration position;
  final Duration duration;
  final bool paused;
  final double volume;

  Map<String, Object?> toJson() => {
        'playing': true,
        'paused': paused,
        'title': title,
        'series': series,
        'kind': kind,
        'itemId': id,
        'position': position.inMilliseconds / 1000,
        'duration': duration.inMilliseconds / 1000,
        'volume': volume,
      };

  String get label => series.isEmpty || series == title ? title : '$series · $title';
}

/// 一台正在播放的播放器。播放页打开时注册，退出时注销。
///
/// 语音控制和 hub 都只能看到这一个入口：它把「哪个 player 后端」「放的是
/// 哪一条」和「怎么暂停/跳转」收在一处，免得每个调用方各自去翻路由。
final class PlaybackBus {
  PlaybackBus._();

  static PlayerBackend? _player;
  static EmbyItem? _item;
  static PlaybackCommands? _commands;
  static StreamSubscription<PlayerEvent>? _events;
  static VoidCallback? _stateListener;

  /// null 表示当前没有在播放。
  static final ValueNotifier<PlaybackSnapshot?> current = ValueNotifier<PlaybackSnapshot?>(null);

  static bool get active => _player != null;

  static PlayerBackend? get player => _player;

  static EmbyItem? get item => _commands?.playingItem ?? _item;

  static void attach(PlayerBackend player, EmbyItem item, {PlaybackCommands? commands}) {
    detach();
    _player = player;
    _item = item;
    _commands = commands;
    void listener() => publish();
    _stateListener = listener;
    player.state.addListener(listener);
    _events = player.events.listen((e) {
      if (e is PlayerShutdown || e is PlayerLoadError) detach(player);
    });
    publish();
  }

  /// 只在「自己能作数」时才清：上一个播放会话晚于新的注销时不能把新会话清掉。
  static void detach([PlayerBackend? only]) {
    final p = _player;
    if (p == null) return;
    if (only != null && !identical(only, p)) return;
    final listener = _stateListener;
    if (listener != null) p.state.removeListener(listener);
    unawaited(_events?.cancel());
    _events = null;
    _stateListener = null;
    _player = null;
    _item = null;
    _commands = null;
    current.value = null;
  }

  static void publish() {
    final p = _player;
    final it = _commands?.playingItem ?? _item;
    if (p == null || it == null) return;
    final s = p.state.value;
    current.value = PlaybackSnapshot(
      id: it.id,
      title: it.name,
      series: it.seriesName ?? '',
      kind: it.type,
      position: s.position,
      duration: s.duration,
      paused: s.paused,
      volume: s.volume,
    );
  }

  // ---- 控制 ----

  static bool pause() {
    final p = _player;
    if (p == null) return false;
    p.setPaused(true);
    publish();
    return true;
  }

  static bool resume() {
    final p = _player;
    if (p == null) return false;
    p.setPaused(false);
    publish();
    return true;
  }

  static bool toggle() {
    final p = _player;
    if (p == null) return false;
    p.setPaused(!p.state.value.paused);
    publish();
    return true;
  }

  /// 退出播放：走会话自己的 userExit 收尾，和按遥控器返回键等价。
  static bool stop() {
    final c = _commands;
    if (c == null || _player == null) return false;
    unawaited(c.exitPlayback());
    return true;
  }

  static bool next() {
    final c = _commands;
    if (c == null || _player == null) return false;
    unawaited(c.nextEpisode());
    return true;
  }

  /// 上一集没有独立事件，退回本集开头（比什么都不做强）。
  static bool previous() {
    final p = _player;
    if (p == null) return false;
    p.seek(Duration.zero);
    publish();
    return true;
  }

  static bool seekTo(Duration position) {
    final p = _player;
    if (p == null) return false;
    final total = p.state.value.duration;
    var target = position;
    if (target < Duration.zero) target = Duration.zero;
    if (total > Duration.zero && target > total) target = total;
    p.seek(target);
    publish();
    return true;
  }

  static bool seekBy(Duration delta) {
    final p = _player;
    if (p == null) return false;
    return seekTo(p.state.value.position + delta);
  }

  static bool setVolume(double volume) {
    final p = _player;
    if (p == null) return false;
    if (p is VolumeControl) {
      (p as VolumeControl).setVolume(volume.clamp(0, 100).toDouble());
      publish();
      return true;
    }
    return false;
  }
}

/// 播放会话能做的事，播放器后端看不到的那几件。
///
/// 「下一集」和「退出」不是 [PlayerBackend] 的操作：后端的 `osd()` 只负责把
/// 内容推给 mpv 的 Lua 面板，事件是从面板经 script-message 回到 Dart 的
/// `PlayerOsdEvent`，再由 [PlaybackSession] 处置。所以从外部触发这两个动作，
/// 必须直接喊会话，不能往 `osd()` 里塞一个 'next' —— 那只会让面板显示一张
/// 空的下集卡片，什么都不会发生。
abstract interface class PlaybackCommands {
  /// 会话当前真正在放的那一条（切集后会变），用来让上报跟着更新。
  EmbyItem? get playingItem;

  /// 等价于点 OSD 上的「下一集」。没有下一集时是空操作。
  Future<void> nextEpisode();

  /// 等价于按遥控器返回键，走 userExit 收尾。
  Future<void> exitPlayback();
}

/// 后端可选能力：能直接改音量。mpv 有，Media3 走系统音量，暂不实现。
abstract interface class VolumeControl {
  void setVolume(double volume);
}
