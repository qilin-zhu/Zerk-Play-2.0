import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../core/log/app_log.dart';
import '../playback/playback_bus.dart';
import '../ui/core/navigation.dart';
import '../ui/core/playback_launcher.dart';
import 'app_services.dart';
import 'hub_link.dart';

/// 小爱语音控制的客户端一半。
///
/// 它不停地向 hub 长轮询「有没有要执行的指令」，同时隔几秒上报一次在放什么。
/// 之所以让客户端主动出网：电视在客厅 NAT 后面，NAS 连不进去。
///
/// 指令只有十来个，全部落到 [PlaybackBus]；唯一需要应用外壳的是「搜索并播放」，
/// 走 [_search] —— 那一步要用 navigator 的 context 才能起播。
final class HubControl {
  HubControl._();

  static final HubControl instance = HubControl._();

  static const _pollWait = 25;

  bool _running = false;
  Timer? _reportTimer;
  int _failures = 0;

  bool get running => _running;

  /// 最近一次指令的说明，设置页用来确认链路通不通。
  static final ValueNotifier<String> lastEvent = ValueNotifier<String>('');

  void start() {
    if (_running) return;
    _running = true;
    unawaited(_loop());
    _reportTimer ??= Timer.periodic(const Duration(seconds: 4), (_) => unawaited(_report()));
    debugPrint('[hub] control: started');
  }

  void stop() {
    _running = false;
    _reportTimer?.cancel();
    _reportTimer = null;
  }

  /// hub 换码 / 退出登录后重启轮询，避免拿着旧 token 一直 401。
  void restart() {
    stop();
    _failures = 0;
    start();
  }

  Uri? _endpoint(String suffix, [Map<String, String>? query]) {
    final base = HubLink.base;
    if (base == null) return null;
    var path = base.path;
    while (path.endsWith('/')) {
      path = path.substring(0, path.length - 1);
    }
    return base.replace(path: '$path$suffix', queryParameters: query, fragment: null);
  }

  Future<void> _loop() async {
    while (_running) {
      final uri = _endpoint('/api/app/control/poll', {'wait': '$_pollWait'});
      final token = HubLink.controlToken;
      if (uri == null || token == null) {
        await Future<void>.delayed(const Duration(seconds: 10));
        continue;
      }
      try {
        final res = await http
            .get(uri, headers: {'X-Hub-Token': token, 'accept': 'application/json'})
            .timeout(const Duration(seconds: _pollWait + 20));
        if (res.statusCode == 401) {
          // 令牌失效：重新兑换一次同步码就能拿到新的，失败就别刷屏。
          AppLog.write('[hub] control: token rejected, re-linking');
          _failures = 0;
          await Future<void>.delayed(const Duration(seconds: 15));
          unawaited(HubLink.refresh().catchError((Object e) {
            debugPrint('[hub] control: re-link failed: $e');
            return null;
          }));
          continue;
        }
        if (res.statusCode != 200) {
          await _backoff();
          continue;
        }
        _failures = 0;
        final body = jsonDecode(utf8.decode(res.bodyBytes));
        final cmd = body is Map ? body['cmd'] : null;
        if (cmd is Map) {
          await _exec(cmd);
        }
      } catch (e) {
        await _backoff();
      }
    }
  }

  Future<void> _backoff() async {
    _failures = (_failures + 1).clamp(0, 5);
    final wait = [2, 3, 5, 10, 20, 30][_failures];
    await Future<void>.delayed(Duration(seconds: wait));
  }

  Future<void> _exec(Map cmd) async {
    final action = '${cmd['action'] ?? ''}';
    final arg = '${cmd['arg'] ?? ''}';
    var ok = false;
    String? note;
    try {
      switch (action) {
        case 'pause':
          ok = PlaybackBus.pause();
        case 'resume':
          ok = PlaybackBus.resume();
        case 'toggle':
          ok = PlaybackBus.toggle();
        case 'stop':
          ok = PlaybackBus.stop();
        case 'next':
          ok = PlaybackBus.next();
        case 'prev':
          ok = PlaybackBus.previous();
        case 'forward':
          ok = PlaybackBus.seekBy(Duration(seconds: int.tryParse(arg) ?? 30));
        case 'back':
          ok = PlaybackBus.seekBy(Duration(seconds: -(int.tryParse(arg) ?? 10)));
        case 'seek':
          ok = PlaybackBus.seekTo(Duration(seconds: int.tryParse(arg) ?? 0));
        case 'volume':
          ok = _volume(arg);
        case 'status':
          ok = PlaybackBus.active;
        case 'search':
        case 'play':
          ok = await _search(arg);
        default:
          note = '不认识的指令 $action';
      }
    } catch (e) {
      note = '$e';
      AppLog.write('[hub] control: $action failed: $e');
    }
    final text = note ?? (ok ? '已执行 $action${arg.isEmpty ? '' : ' $arg'}' : '当前没有在播放，$action 无效');
    lastEvent.value = text;
    AppLog.write('[hub] control: $text');
    unawaited(_report());
  }

  bool _volume(String arg) {
    final s = PlaybackBus.current.value;
    if (s == null) return false;
    final v = arg.startsWith('+') || arg.startsWith('-')
        ? s.volume + (int.tryParse(arg) ?? 0)
        : (int.tryParse(arg) ?? s.volume.toInt());
    return PlaybackBus.setVolume(v.toDouble());
  }

  /// 搜索片名并开播。这条路必须用 navigator 的 context 才能起播放页，
  /// 所以放在客户端做而不是 hub 直接下发一个播放 URL。
  Future<bool> _search(String query) async {
    final q = query.trim();
    if (q.isEmpty) return false;
    final ctx = DoubleBack.navigator?.currentContext;
    if (ctx == null || !ctx.mounted) {
      lastEvent.value = '界面还没准备好，稍后再试';
      return false;
    }
    final services = AppServicesScope.read(ctx);

    // 已经在放别的：先退出来，playItem 遇到正在播放会直接返回。
    if (playbackActive) {
      PlaybackBus.stop();
      for (var i = 0; i < 24 && playbackActive; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
    }
    if (playbackActive) {
      lastEvent.value = '上一个播放还没退出，稍后再试';
      return false;
    }

    final page = await services.catalog.query(
      types: const ['Movie', 'Series'],
      searchTerm: q,
      limit: 20,
      sortBy: 'SortName',
    );
    if (page.items.isEmpty) {
      lastEvent.value = '没搜到「$q」';
      return false;
    }
    if (!ctx.mounted) {
      lastEvent.value = '界面已切换，放弃这次播放';
      return false;
    }
    final hit = page.items.first;
    lastEvent.value = '播放 ${hit.name}';
    unawaited(playItem(ctx, hit).catchError((Object e) {
      AppLog.write('[hub] control: play "${hit.name}" failed: $e');
      return null;
    }));
    // 给播放页一点时间把 PlaybackBus 挂起来，状态上报才准。
    for (var i = 0; i < 40 && !PlaybackBus.active; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    return PlaybackBus.active;
  }

  Future<void> _report() async {
    final uri = _endpoint('/api/app/control/state');
    final token = HubLink.controlToken;
    if (uri == null || token == null) return;
    final snap = PlaybackBus.current.value;
    final body = <String, Object?>{
      'token': token,
      if (snap != null) ...snap.toJson() else 'playing': false,
    };
    try {
      await http
          .post(uri, headers: {'content-type': 'application/json'}, body: jsonEncode(body))
          .timeout(const Duration(seconds: 8));
    } catch (_) {
      // 上报失败不影响播放，下一轮再来。
    }
  }
}
