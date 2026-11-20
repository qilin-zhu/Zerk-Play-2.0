import 'dart:async';
import 'dart:convert';

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
  Timer? _loadWatchdog;
  bool _loaded = false;
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
  String _playLink = '';

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

      // Default play shape: the NAS media/range proxy for local files. The
      // stream call may resolve a cloud/STRM link that replaces it.
      var url = client.directStreamUrl(_mediaGuid);
      var playHeaders = client.imageHeaders;
      _playLink = '/v/api/v1/media/range/$_mediaGuid';

      debugPrint('[fnos] play ${item.displayTitle} media=$_mediaGuid start=$ts');
      // The web player opens a stream session before serving media/range; the
      // response also carries the cloud/STRM playback info (cloud_storage_info,
      // direct_link_qualities, provider header). Local files tolerate a failed
      // stream call; cloud-backed ones need it for the resolved URL.
      Object? streamData;
      try {
        streamData = await client.stream(_mediaGuid);
      } catch (e) {
        debugPrint('[fnos] stream session: $e');
      }
      if (streamData is Map) {
        final resolved = _resolveStreamUrl(streamData);
        if (resolved != null) {
          url = resolved.url;
          playHeaders = resolved.headers;
          _playLink = resolved.playLink;
          debugPrint('[fnos] resolved cloud type=${resolved.cloudType} url=${Uri.parse(url).host}');
        }
      }
      backend.load(
        Uri.parse(url),
        start: ts > 0 ? Duration(seconds: ts) : null,
        headers: playHeaders,
      );
      // mpv errors surface as PlayerLoadError; if nothing happens at all
      // (command rejected, network silently stuck) fail visibly instead of
      // spinning forever.
      _loadWatchdog?.cancel();
      _loadWatchdog = Timer(const Duration(seconds: 30), () {
        if (!_loaded && !_finishing) {
          debugPrint('[fnos] load watchdog fired');
          backend.osd('state', {
            'phase': 'error',
            'title': item.displayTitle,
            'message': '无法连接飞牛的媒体流（30 秒无响应）',
          });
        }
      });
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

  /// Picks the playable URL for cloud-backed media from the `/stream`
  /// response, mirroring FlyNarwhal's `getDirectPlayLink` matrix:
  ///
  /// - STRM (9001): the NAS already resolved the .strm content into a playable
  ///   URL, so play it directly — the web player never routes STRM through the
  ///   media/range proxy.
  /// - Aliyun (2) / 123 (5) / 115 non-m3u8 (3): play the raw CDN link directly.
  /// - 115 m3u8: rewrite through the /wp/m3u8 proxy.
  /// - Baidu (1) / Quark (4) / unknown providers: NAS proxy with the quality
  ///   index so the server selects the matching CDN link.
  ///
  /// Direct CDN requests carry only the provider headers from the stream
  /// response (`header`); NAS-proxied ones carry NAS auth plus the provider
  /// headers in `X-Wp-Header`. Returns null for plain local files.
  _ResolvedStream? _resolveStreamUrl(Map streamData) {
    final cloud = streamData['cloud_storage_info'];
    final type = cloud is Map ? (cloud['cloud_storage_type'] as num?)?.toInt() : null;
    if (type == null) return null;
    final qualities = streamData['direct_link_qualities'];
    final quality = qualities is List && qualities.isNotEmpty && qualities.first is Map
        ? qualities.first as Map
        : null;
    final link = quality?['url']?.toString() ?? '';
    if (link.isEmpty) {
      // Cloud-backed media without a usable resolved link cannot play at all
      // — fail visibly instead of letting the media/range proxy 404.
      throw FnosException(-1, '网盘媒体未返回可播放链接（类型 $type）', streamData);
    }
    final isM3u8 = quality?['is_m3u8'] == true;
    final header = streamData['header'];
    final providerHeaders = <String, String>{
      if (header is Map)
        for (final e in header.entries)
          if (e.value != null) e.key.toString(): e.value!.toString(),
    };

    // Direct CDN playback: never attach NAS credentials to a foreign host.
    final directPlay = type == 9001 || type == 2 || type == 5 || (type == 3 && !isM3u8);
    if (directPlay) {
      return _ResolvedStream(type, link, providerHeaders, _stripOrigin(link));
    }
    if (type == 3) {
      // 115 m3u8: proxy so segment URLs stay on the NAS.
      final url = client.wpM3u8Url(link);
      return _ResolvedStream(type, url, {...client.imageHeaders, ...providerHeaders},
          _stripOrigin(url));
    }
    // NAS proxy with the quality index (Baidu/Quark/fallbacks).
    final url = client.directStreamUrl(_mediaGuid, directLinkQualityIndex: 0);
    final headers = {...client.imageHeaders};
    if (providerHeaders.isNotEmpty) {
      headers['X-Wp-Header'] = jsonEncode(header is Map ? header : providerHeaders);
    }
    return _ResolvedStream(type, url, headers, _stripOrigin(url));
  }

  /// Drops the `scheme://host[:port]` prefix so the recorded play link stays
  /// relative for fnOS, matching what the web player persists.
  static String _stripOrigin(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme) return url;
    return uri.hasQuery ? '${uri.path}?${uri.query}' : uri.path;
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
        _loaded = true;
        _loadWatchdog?.cancel();
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
        'play_link': _playLink,
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
    _loadWatchdog?.cancel();
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

/// One resolved playback target from the `/stream` response.
final class _ResolvedStream {
  const _ResolvedStream(this.cloudType, this.url, this.headers, this.playLink);

  final int cloudType;
  final String url;
  final Map<String, String> headers;
  final String playLink;
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
