import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../app/app_services.dart';
import '../core/fnos/fnos_client.dart';
import '../core/fnos/fnos_item.dart';
import '../core/host.dart';
import '../l10n/l10n.dart';
import 'kept_display.dart';
import 'platform_player.dart';
import 'player_backend.dart';
import 'player_settings.dart';

/// Lightweight playback session for 飞牛影视 (fnOS trimemedia).
///
/// Mirrors the parts of PlaybackSession a fnOS server can support:
/// `play/info` resolves the media guid and resume position, the original file
/// streams through `media/range/{media_guid}` with the session headers (the
/// same route FlyNarwhal uses for direct play), and progress goes to
/// `play/record`. The player UI and danmaku matching come from the shared
/// PlayerOsdRoute that the backend pushes on open().
final class FnOsPlayback {
  FnOsPlayback({
    required this.client,
    required this.navigator,
    required this.settings,
    required this.l10n,
    this.acceptInvalidCertificates = false,
    required this.deviceId,
  });

  final FnosClient client;
  final NavigatorState navigator;
  final PlayerSettings settings;
  final L10n l10n;
  final bool acceptInvalidCertificates;
  final String deviceId;

  final _done = Completer<void>();
  PlayerBackend? _backend;
  StreamSubscription<PlayerEvent>? _eventsSub;
  Timer? _progressTimer;
  bool _reportedStart = false;
  bool _finishing = false;
  bool _ended = false;

  FnOsItem? _item;
  String _itemGuid = '';
  String _mediaGuid = '';
  String _videoGuid = '';
  String _audioGuid = '';
  String? _subtitleGuid;
  int _durationHint = 0;

  /// Runs one playback and completes when the player is dismissed.
  Future<void> play(FnOsItem item) async {
    _item = item;
    final backend = createPlayer(
      navigator: navigator,
      settings: settings,
      acceptInvalidCertificates: acceptInvalidCertificates,
      l10n: l10n,
    );
    _backend = backend;
    _eventsSub = backend.events.listen(_onEvent);
    backend.state.addListener(_onState);
    await backend.open();
    backend.osd('config', {
      'seekForward': settings.seekForwardSeconds,
      'seekBack': settings.seekBackSeconds,
      'scope': settings.scopeScreen,
      'autoCrop': settings.autoCrop,
      'defaultAspect': settings.defaultAspect,
      'anamorphic': settings.anamorphic,
      'autoSkipIntro': settings.skipIntroAutomatically,
    });
    _osdState('loading', item);
    _progressTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      final s = backend.state.value;
      if (s.duration > Duration.zero) _report(s.position.inSeconds);
    });

    try {
      final info = await client.playInfo(item.guid);
      final map = info is Map ? info : <String, Object?>{};
      final mediaGuid = _s(map, 'media_guid') ?? '';
      final videoGuid = _s(map, 'video_guid') ?? mediaGuid;
      if (mediaGuid.isEmpty && videoGuid.isEmpty) {
        throw FnosException(-1, 'play info did not contain a media guid', info);
      }
      _itemGuid = _s(map, 'guid') ?? item.guid;
      _mediaGuid = mediaGuid.isNotEmpty ? mediaGuid : videoGuid;
      _videoGuid = videoGuid;
      _audioGuid = _s(map, 'audio_guid') ?? '';
      _subtitleGuid = _s(map, 'subtitle_guid');
      _durationHint = (((map['item'] as Map?)?['duration'] ?? map['duration']) as num?)?.toInt() ?? 0;
      final ts = (map['ts'] as num?)?.toInt() ?? 0;

      final url = client.directStreamUrl(_mediaGuid);
      debugPrint('[fnos] play ${item.displayTitle} media=$_mediaGuid start=$ts');
      // The web player opens a stream session before serving media/range; do
      // the same so the server has the media registered. Failures are fine —
      // direct play works against FlyNarwhal without it too.
      try {
        await client.stream(_mediaGuid);
      } catch (e) {
        debugPrint('[fnos] stream session: $e');
      }
      backend.load(
        Uri.parse(url),
        start: ts > 0 ? Duration(seconds: ts) : null,
        headers: client.imageHeaders,
      );
    } catch (e) {
      debugPrint('[fnos] play failed: $e');
      backend.osd('state', {
        'phase': 'error',
        'title': item.displayTitle,
        'message': '$e',
      });
    }
    return _done.future;
  }

  String? _s(Map m, String key) {
    final v = m[key]?.toString();
    return v == null || v.isEmpty ? null : v;
  }

  void _osdState(String phase, FnOsItem item, {String? message}) {
    final subtitle = item.subtitle;
    _backend?.osd('state', {
      'phase': phase,
      'title': item.displayTitle,
      'subtitle': ?subtitle,
      'message': ?message,
    });
  }

  void _onEvent(PlayerEvent event) {
    final backend = _backend;
    if (backend == null) return;
    switch (event) {
      case PlayerLoaded():
        final item = _item;
        if (item != null) _osdState('playing', item);
        _report(backend.state.value.position.inSeconds);
      case PlayerLoadError(:final message):
        final item = _item;
        if (item != null) _osdState('error', item, message: message ?? '');
      case PlayerOsdEvent(:final name):
        if (name == 'back') unawaited(_finish());
      case PlayerShutdown():
        unawaited(_finish());
    }
  }

  void _onState() {
    final s = _backend?.state.value;
    if (s == null) return;
    if (s.ended && !_ended) {
      _ended = true;
      _report(s.duration.inSeconds > 0 ? s.duration.inSeconds : s.position.inSeconds);
      unawaited(_finish());
    }
  }

  /// fnOS play/record (mirrors FlyNarwhal's PlayRecordRequest).
  Future<void> _report(int ts) async {
    if (_mediaGuid.isEmpty || ts < 0) return;
    final duration = _backend?.state.value.duration.inSeconds ?? 0;
    final effectiveDuration = duration > 0 ? duration : _durationHint;
    _reportedStart = true;
    try {
      await client.playRecord({
        'item_guid': _itemGuid,
        'media_guid': _mediaGuid,
        'video_guid': _videoGuid,
        'audio_guid': _audioGuid,
        if (_subtitleGuid != null && _subtitleGuid!.isNotEmpty) 'subtitle_guid': _subtitleGuid,
        'resolution': '',
        'bitrate': 0,
        'ts': ts,
        'duration': effectiveDuration,
        'play_link': '/v/api/v1/media/range/$_mediaGuid',
        'device_id': deviceId,
        'direct_link_audio_index': -1,
        'lan': 'zh-CN',
        'device_name': Host.isAndroid ? 'Android TV' : Host.isLinux ? 'Linux' : 'Windows',
      });
    } catch (e) {
      debugPrint('[fnos] record failed: $e');
    }
  }

  Future<void> _finish() async {
    if (_finishing) return;
    _finishing = true;
    _progressTimer?.cancel();
    final backend = _backend;
    final s = backend?.state.value;
    if (!_ended && s != null && s.position > Duration.zero && _reportedStart) {
      await _report(s.position.inSeconds);
    }
    await KeptDisplay.restore().timeout(const Duration(milliseconds: 800), onTimeout: () {});
    await backend?.close();
    _eventsSub?.cancel();
    if (!_done.isCompleted) _done.complete();
  }
}

/// Launches fnOS playback from a UI context.
Future<void> playFnOs(BuildContext context, FnOsItem item) async {
  final services = AppServicesScope.read(context);
  final client = services.janus.fnos;
  if (client == null) return;
  final navigator = Navigator.of(context, rootNavigator: true);
  final l10n = context.l10n;
  final acceptInvalid = services.settings.acceptInvalidCertificates;
  final settings = await PlayerSettings.load();
  final deviceId = await services.janus.getDeviceId();
  final playback = FnOsPlayback(
    client: client,
    navigator: navigator,
    settings: settings,
    l10n: l10n,
    acceptInvalidCertificates: acceptInvalid,
    deviceId: deviceId,
  );
  unawaited(playback.play(item));
}
