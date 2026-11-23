import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../app/app_services.dart';
import '../core/fnos/fnos_client.dart';
import '../core/fnos/fnos_item.dart';
import '../core/fnos/fnos_playback_bus.dart';
import '../core/fnos/quark_cdn_proxy.dart';
import '../core/host.dart';
import '../l10n/l10n.dart';
import 'kept_display.dart';
import 'language.dart';
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
  QuarkCdnProxy? _cdnProxy;
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
  /// Which transport the current attempt uses (`nas`, `cdn`, `cdn+proxy`,
  /// `nas-m3u8`) — surfaced in the error text so a screenshot from a TV is
  /// enough to tell where the failure happened.
  String _link = 'nas';
  /// Last target handed to the backend, kept so a failure can be re-read.
  String? _curUrl;
  Map<String, String> _curHeaders = const {};
  String? _curMime;
  String _trackSignature = '';

  /// Target to try when the primary one fails to produce a frame. Cloud links
  /// hand out a CDN URL that may be expired, geo-blocked or served without the
  /// headers ExoPlayer sends; the NAS proxy re-resolves the same media on the
  /// server, so it is the natural second attempt.
  String? _retryUrl;
  Map<String, String> _retryHeaders = const {};
  String? _retryMime;
  bool _retried = false;
  int _resumeSeconds = 0;

  void _startWatchdog(FnOsItem item) {
    final backend = _backend;
    if (backend == null) return;
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
  }

  /// Arms the NAS-proxy fallback used when the primary target fails.
  ///
  /// A cloud quality link can be expired, blocked for this network, or served
  /// with requirements ExoPlayer does not meet, and the user only sees a dead
  /// player. `media/range` re-resolves the same media on the NAS, so it is the
  /// natural second attempt; local files already use it and skip this.
  void _prepareRetry(Object? streamData, String url, String? mimeHint) {
    _retryUrl = null;
    if (streamData is! Map) return;
    if (url.contains('/v/api/v1/media/range/')) return;
    final cloud = streamData['cloud_storage_info'];
    final type = cloud is Map ? (cloud['cloud_storage_type'] as num?)?.toInt() : null;
    if (type == null || type == 0) return;
    final headers = {...client.imageHeaders};
    final header = streamData['header'];
    if (header is Map && header.isNotEmpty) headers['X-Wp-Header'] = jsonEncode(header);
    _retryUrl = client.directStreamUrl(_mediaGuid, directLinkQualityIndex: 0);
    _retryHeaders = headers;
    _retryMime = mimeHint;
  }

  /// Runs one playback and completes when the player is dismissed.
  ///
  /// [fromStart] ignores the server-side resume position, for the "从头播放"
  /// button next to the resume one.
  Future<void> play(FnOsItem item, {bool fromStart = false}) async {
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
      final ts = fromStart ? 0 : ((map['ts'] as num?)?.toInt() ?? 0);

      // Default play shape: the NAS media/range proxy for local files. The
      // stream call may resolve a cloud/STRM link that replaces it.
      var url = client.directStreamUrl(_mediaGuid);
      var playHeaders = client.imageHeaders;
      String? mimeHint;
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
          // Media3 decides between HLS and progressive from the URL extension,
          // and the proxied playlist URL has none.
          if (resolved.isHls) mimeHint = 'application/x-mpegURL';
          if (resolved.cdnUpstream != null) {
            final proxy = QuarkCdnProxy(
              upstream: resolved.cdnUpstream!,
              upstreamHeaders: resolved.cdnHeaders,
            );
            try {
              final proxied = await proxy.start();
              // Ask the loopback server for the first bytes before handing the
              // URL to the player: on a TV the only feedback is an error
              // string, so a proxy that cannot even serve the container head
              // is treated as broken and the NAS proxy takes over.
              final check = await proxy.selfCheck();
              debugPrint('[fnos] quark cdn proxy self-check: $check');
              if (!check.startsWith('ok')) {
                throw StateError('proxy self-check failed: $check');
              }
              _cdnProxy = proxy;
              url = proxied.toString();
              playHeaders = const {};
              _link = 'cdn+proxy';
              debugPrint('[fnos] quark cdn proxy: $url (upstream ${resolved.cdnUpstream!.host})');
            } catch (e) {
              await proxy.stop();
              // The parallel-range proxy failed to start or cannot serve the
              // stream: fall back to the NAS media/range proxy, slow but
              // playable.
              url = client.directStreamUrl(_mediaGuid, directLinkQualityIndex: 0);
              playHeaders = {...client.imageHeaders};
              _link = 'nas';
              final header = streamData['header'];
              if (header is Map && header.isNotEmpty) {
                playHeaders['X-Wp-Header'] = jsonEncode(header);
              }
              debugPrint('[fnos] quark cdn proxy failed: $e — NAS proxy fallback');
            }
          }
          debugPrint('[fnos] resolved cloud type=${resolved.cloudType} url=${Uri.parse(url).host}');
        }
      }
      // fnOS answers `media/range` with an HLS playlist — not the original
      // bytes — whenever the file cannot be served as-is (container or codec it
      // will not remux). The `is_m3u8` flag on the cloud link says nothing
      // about that, so the response shape is checked before the player is
      // pointed at it. Media3 only recognises a playlist from the URL
      // extension, and `media/range/{guid}` has none: every progressive
      // extractor then rejects the `#EXTM3U` text with
      // PARSING_CONTAINER_UNSUPPORTED. mpv hides this on desktop because
      // ffmpeg sniffs the playlist itself.
      if (mimeHint == null && _cdnProxy == null) {
        // The loopback proxy already proved it carries container bytes, so it
        // never needs this extra round trip.
        mimeHint = await _sniffMime(url, playHeaders);
        if (mimeHint != null) {
          debugPrint('[fnos] sniffed $mimeHint for ${Uri.parse(url).path}');
        }
      }
      debugPrint('[fnos] load $_link ${Uri.parse(url).host}${Uri.parse(url).path} '
          'mime=$mimeHint headers=${playHeaders.keys.toList()..sort()}');
      _resumeSeconds = ts;
      _prepareRetry(streamData, url, mimeHint);
      _curUrl = url;
      _curHeaders = playHeaders;
      _curMime = mimeHint;
      backend.load(
        Uri.parse(url),
        start: ts > 0 ? Duration(seconds: ts) : null,
        headers: playHeaders,
        mimeType: mimeHint,
      );
      // mpv errors surface as PlayerLoadError; if nothing happens at all
      // (command rejected, network silently stuck) fail visibly instead of
      // spinning forever.
      _startWatchdog(item);
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
  /// - Quark (4): raw CDN link through the local parallel-range proxy
  ///   (per-connection CDN throttling makes everything else starve).
  /// - Baidu (1) / m3u8 / unknown providers: NAS proxy with the quality
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
      // Local files carry no cloud entry at all (type 0 or absent): they play
      // through the media/range proxy, so there is nothing to resolve here.
      // A real cloud provider without a resolved link cannot play at all —
      // fail visibly instead of letting the media/range proxy 404.
      if (type == 0) return null;
      throw FnosException(-1, '网盘媒体未返回可播放链接（类型 $type）', streamData);
    }
    final isM3u8 = quality?['is_m3u8'] == true;
    final header = streamData['header'];
    // The provider header values are lists on the wire (e.g. "User-Agent":
    // ["Mozilla/5.0 …"]) — flatten them into plain header strings.
    String flatten(Object? v) => v is List ? v.map((e) => '$e').join(', ') : '$v';
    final providerHeaders = <String, String>{
      if (header is Map)
        for (final e in header.entries)
          if (e.value != null) e.key.toString(): flatten(e.value),
    };
    // Provider hosts expect the browser identity that resolved the link, and
    // the stream response usually carries only a Cookie.
    if (!providerHeaders.keys.any((k) => k.toLowerCase() == 'user-agent')) {
      providerHeaders['User-Agent'] = FnosClient.webUserAgent;
    }

    // Direct CDN playback: never attach NAS credentials to a foreign host.
    final directPlay = type == 9001 || type == 2 || type == 5 || (type == 3 && !isM3u8);
    if (directPlay) {
      _link = 'cdn';
      return _ResolvedStream(type, link, providerHeaders, _stripOrigin(link), isHls: isM3u8);
    }
    if (type == 3) {
      // 115 m3u8: proxy so segment URLs stay on the NAS.
      final url = client.wpM3u8Url(link);
      _link = 'nas-m3u8';
      return _ResolvedStream(type, url, {...client.imageHeaders, ...providerHeaders},
          _stripOrigin(url), isHls: true);
    }
    if (type == 4 && !isM3u8) {
      // Quark: the CDN throttles every TCP connection (measured ~0.09 MB/s on
      // the file head vs ~6 MB/s mid-file on the same URL), so the NAS proxy
      // and a plain direct link both starve 4K playback to a black screen.
      // Play the raw CDN link through the local parallel-range proxy instead
      // (mirrors FlyNarwhal's CDN 分段直连, on by default there).
      return _ResolvedStream(type, '', const {}, _stripOrigin(link),
          cdnUpstream: Uri.tryParse(link), cdnHeaders: providerHeaders);
    }
    // NAS proxy with the quality index (Baidu/Quark/fallbacks).
    final url = client.directStreamUrl(_mediaGuid, directLinkQualityIndex: 0);
    final headers = {...client.imageHeaders};
    if (providerHeaders.isNotEmpty) {
      headers['X-Wp-Header'] = jsonEncode(header is Map ? header : providerHeaders);
    }
    _link = 'nas';
    return _ResolvedStream(type, url, headers, _stripOrigin(url), isHls: isM3u8);
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

  /// Reports a playlist hint for [url] when the server answers with an HLS
  /// manifest instead of media bytes.
  ///
  /// 飞牛's `media/range` endpoint serves an HLS playlist for anything it will
  /// not hand out verbatim (MKV/TrueHD/unsupported codecs), with no file
  /// extension and no `is_m3u8` flag to announce it. Reading the first bytes
  /// is the only reliable way to tell Media3 which media source to build.
  Future<String?> _sniffMime(String url, Map<String, String> headers) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 6)
      ..badCertificateCallback =
          acceptInvalidCertificates ? (_, _, _) => true : null;
    try {
      final req = await client.getUrl(Uri.parse(url));
      req.headers.set(HttpHeaders.rangeHeader, 'bytes=0-63');
      headers.forEach(req.headers.set);
      final res = await req.close().timeout(const Duration(seconds: 6));
      if (res.statusCode >= 400) return null;
      final buf = <int>[];
      await for (final chunk in res.timeout(const Duration(seconds: 6))) {
        buf.addAll(chunk);
        if (buf.length >= 64) break;
      }
      final text = String.fromCharCodes(buf).trimLeft();
      if (text.startsWith('#EXTM3U')) return 'application/x-mpegURL';
      return null;
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  /// Shows the failure, with what the transport actually served for that URL.
  ///
  /// A container error from Media3 says nothing about *why* it could not parse
  /// the stream, and on a TV the message string is the only artefact a user
  /// can send back — so the same request is replayed once and its status,
  /// content type and first bytes are appended. A `1a45dfa3` (mkv) or
  /// `000000..ftyp` head with HTTP 206 means the data is fine and the failure
  /// is inside the decoder; an HTML/JSON head means the link handed out the
  /// wrong thing.
  Future<void> _fail(FnOsItem item, String? message) async {
    final url = _curUrl;
    final detail = url == null ? 'no url' : await _inspectHead(url, _curHeaders);
    final text = '[$_link] ${message ?? ''}\n$detail';
    debugPrint('[fnos] playback failed: $text');
    if (_finishing) return;
    _osdState('error', item, message: text);
  }

  Future<String> _inspectHead(String url, Map<String, String> headers) async {    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 8)
      ..badCertificateCallback =
          acceptInvalidCertificates ? (_, _, _) => true : null;
    try {
      final req = await client.getUrl(Uri.parse(url));
      req.headers.set(HttpHeaders.rangeHeader, 'bytes=0-31');
      headers.forEach(req.headers.set);
      final res = await req.close().timeout(const Duration(seconds: 10));
      final buf = <int>[];
      await for (final chunk in res.timeout(const Duration(seconds: 10))) {
        buf.addAll(chunk);
        if (buf.length >= 32) break;
      }
      final hex =
          buf.take(32).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      final ascii = String.fromCharCodes(
          buf.take(16).map((b) => b >= 32 && b < 127 ? b : 0x2e));
      return 'http=${res.statusCode} ctype=${res.headers.contentType} '
          'mime=$_curMime head=$hex ($ascii)';
    } catch (e) {
      return 'inspect failed: $e';
    } finally {
      client.close(force: true);
    }
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
        if (item == null) return;
        if (_retryNas(item)) return;
        // The error text is all a TV user can see, so it carries the transport
        // that failed: `nas` (media/range), `cdn` (provider link) or
        // `cdn+proxy` (loopback parallel-range proxy).
        unawaited(_fail(item, message));
      case PlayerOsdEvent(:final name, :final arg):
        switch (name) {
          case 'back':
            unawaited(_finish());
          case 'audio':
            // The picker ids are the backend's own track ids; keep them as-is.
            backend.selectTrack('audio', arg);
          case 'sub':
            // '-1' is the picker's "off" entry; null disables the text track.
            backend.selectTrack('sub', arg == null || arg == '-1' ? null : arg);
        }
      case PlayerShutdown():
        unawaited(_finish());
    }
  }

  /// One automatic retry through the NAS proxy; returns false when there is
  /// nothing left to try (the caller then shows the error).
  bool _retryNas(FnOsItem item) {
    final url = _retryUrl;
    final backend = _backend;
    if (_retried || url == null || backend == null || _finishing) return false;
    _retried = true;
    _retryUrl = null;
    debugPrint('[fnos] primary target failed, retrying via NAS proxy');
    _playLink = _stripOrigin(url);
    _link = 'nas';
    _curUrl = url;
    _curHeaders = _retryHeaders;
    _curMime = _retryMime;
    _osdState('loading', item);
    backend.load(
      Uri.parse(url),
      start: _resumeSeconds > 0 ? Duration(seconds: _resumeSeconds) : null,
      headers: _retryHeaders,
      mimeType: _retryMime,
    );
    _startWatchdog(item);
    return true;
  }

  void _onState() {
    final s = _backend?.state.value;
    if (s == null) return;
    _pushTracks();
    if (s.ended && !_ended) {
      _ended = true;
      _report(s.duration.inSeconds > 0 ? s.duration.inSeconds : s.position.inSeconds);
      unawaited(_finish());
    }
  }

  /// Publishes the audio/subtitle picker for backends that expose their track
  /// list (Media3 on Android). fnOS never says which streams a file has — the
  /// container does — so the entries come from the running player. The mpv
  /// backend draws its own OSD and ignores these, exactly like before.
  void _pushTracks() {
    final backend = _backend;
    final tracks = backend?.state.value.tracks;
    if (backend == null || tracks == null) return;
    final signature = tracks.map((t) => '${t.id}|${t.selected}').join(',');
    if (signature == _trackSignature) return;
    _trackSignature = signature;
    List<Map<String, Object?>> of(String type, String fallback) {
      final list = tracks.where((t) => t.type == type && !t.external).toList();
      return [
        for (final (i, t) in list.indexed)
          {
            'id': t.id,
            'label': _trackLabel(t, fallback, i + 1),
            'detail': _trackDetail(t),
            'selected': t.selected,
          },
      ];
    }

    backend.osd('tracks', {
      'audio': of('audio', l10n.audio),
      'subs': of('sub', l10n.subtitles),
    });
  }

  String _trackLabel(PlayerTrack t, String fallback, int number) {
    final title = t.label?.trim() ?? '';
    if (title.isNotEmpty) return title;
    final code = normalizeLanguage(t.language);
    if (code.isNotEmpty) {
      final name = languageNames[code];
      if (name != null && name.isNotEmpty) return name;
    }
    return '$fallback $number';
  }

  String _trackDetail(PlayerTrack t) {
    final parts = <String>[];
    final codec = _codecName(t.codec);
    if (codec.isNotEmpty) parts.add(codec);
    if (t.type == 'audio') {
      final ch = _channelName(t.channels);
      if (ch != null) parts.add(ch);
    }
    return parts.join('  ·  ');
  }

  static String _codecName(String? raw) {
    final c = (raw ?? '').toLowerCase();
    if (c.isEmpty) return '';
    return switch (c) {
      'truehd' => 'Dolby TrueHD',
      'eac3' || 'ec-3' => 'E-AC-3',
      'ac3' => 'AC-3',
      'dts' || 'dca' => 'DTS',
      'aac' || 'mp4a-latm' => 'AAC',
      'flac' => 'FLAC',
      'opus' => 'Opus',
      'vorbis' => 'Vorbis',
      'mpeg' || 'mp3' => 'MP3',
      'subrip' || 'srt' => 'SRT',
      'ssa' || 'ass' => 'ASS',
      'pgs' || 'pgssub' => 'PGS',
      'vobsub' || 'dvdsub' => 'VobSub',
      'webvtt' || 'vtt' => 'WebVTT',
      'ttml' || 'mp4text' || 'mov_text' => 'TTML',
      _ when c.startsWith('pcm') => 'PCM',
      _ => c.toUpperCase(),
    };
  }

  static String? _channelName(int? channels) => switch (channels) {
        1 => 'Mono',
        2 => 'Stereo',
        3 => '2.1',
        6 => '5.1',
        7 => '6.1',
        8 => '7.1',
        final n? when n > 0 => '$n ch',
        _ => null,
      };

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
    try {
      await _cdnProxy?.stop();
    } catch (e) {
      debugPrint('[fnos] cdn proxy stop: $e');
    }
    _cdnProxy = null;
    await backend?.close();
    _eventsSub?.cancel();
    // The final position went to play/record above, so the server's play/list
    // is current: tell the home page to refetch its continue-watching row
    // instead of waiting for the next login.
    FnosPlaybackBus.notifyEnded();
    if (!_done.isCompleted) _done.complete();
  }
}

/// One resolved playback target from the `/stream` response.
final class _ResolvedStream {
  const _ResolvedStream(this.cloudType, this.url, this.headers, this.playLink,
      {this.cdnUpstream, this.cdnHeaders = const {}, this.isHls = false});

  final int cloudType;
  final String url;
  final Map<String, String> headers;
  final String playLink;

  /// The target is an HLS playlist, whatever the URL looks like.
  final bool isHls;

  /// Non-null for Quark: [url] must be replaced by the local parallel-range
  /// proxy serving [cdnUpstream] with [cdnHeaders].
  final Uri? cdnUpstream;
  final Map<String, String> cdnHeaders;
}

/// Launches fnOS playback from a UI context. [fromStart] starts at 0 instead of
/// the position the server reports for this item.
Future<void> playFnOs(BuildContext context, FnOsItem item, {bool fromStart = false}) async {
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
  unawaited(playback.play(item, fromStart: fromStart));
}
