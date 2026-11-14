import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import 'danmaku_source.dart';

/// One bullet comment, positioned on the playback timeline.
final class DanmakuComment {
  const DanmakuComment({
    required this.time,
    required this.text,
    this.mode = 1,
    this.color = 0xFFFFFF,
  });

  /// Where it appears, counted from the start of the video.
  final Duration time;

  final String text;

  /// 1-3 scrolling, 4 bottom, 5 top.
  final int mode;

  /// 0xRRGGBB.
  final int color;
}

/// A search result (anime / show / film) from the danmaku server.
final class DanmakuAnime {
  const DanmakuAnime({
    required this.id,
    required this.title,
    this.kind,
    this.episodeCount,
  });

  final int id;
  final String title;

  /// "电视剧", "国产剧", ... whatever the source calls it.
  final String? kind;

  final int? episodeCount;
}

final class DanmakuEpisode {
  const DanmakuEpisode({required this.id, required this.title, this.number});

  final int id;
  final String title;
  final int? number;
}

/// Client for the dandanplay open API, which `danmu_api` also speaks.
///
/// Note that a `danmu_api` deployment puts everything behind its token, e.g.
/// `http://host:9321/87654321/api/v2/...`, so [server] may carry a path. If the
/// address was pasted from a browse page we fall back to the origin once, so a
/// wrong suffix costs a single extra request instead of a broken feature.
final class DanmakuApi {
  DanmakuApi({
    required this.server,
    this.appId = '',
    this.appSecret = '',
    http.Client? client,
  }) : _client = client ?? http.Client();

  factory DanmakuApi.of(DanmakuSource source) => DanmakuApi(
        server: source.baseUrl,
        appId: source.appId,
        appSecret: source.appSecret,
      );

  final String server;
  final String appId;
  final String appSecret;
  final http.Client _client;

  static const _timeout = Duration(seconds: 12);

  String _base = '';
  bool _resolved = false;

  String get base => _base.isEmpty ? server.trim().replaceAll(RegExp(r'/+$'), '') : _base;

  bool get _signed => appId.trim().isNotEmpty && appSecret.trim().isNotEmpty;

  /// `X-Signature` is base64 of the raw SHA-256 digest over
  /// `appId + timestamp + path + appSecret`, where path has no query string.
  Map<String, String> _headers(String path) {
    final headers = <String, String>{'accept': 'application/json'};
    if (!_signed) return headers;
    final timestamp = (DateTime.now().millisecondsSinceEpoch ~/ 1000).toString();
    final digest = sha256.convert(utf8.encode('${appId.trim()}$timestamp$path${appSecret.trim()}'));
    return headers
      ..['X-AppId'] = appId.trim()
      ..['X-Timestamp'] = timestamp
      ..['X-Signature'] = base64.encode(digest.bytes);
  }

  Future<http.Response> _post(String path, Object body) async {
    final sent = await _client
        .post(
          Uri.parse('${base}$path'),
          headers: {..._headers(path), 'content-type': 'application/json'},
          body: jsonEncode(body),
        )
        .timeout(_timeout);
    return _retryIfMissing(sent, path, () => _post(path, body));
  }

  Future<http.Response> _get(String path, [Map<String, String>? query]) async {
    Uri uri() {
      final u = Uri.parse('${base}$path');
      return query == null ? u : u.replace(queryParameters: query);
    }

    final sent = await _client.get(uri(), headers: _headers(path)).timeout(_timeout);
    return _retryIfMissing(sent, path, () => _get(path, query));
  }

  /// `danmu_api` serves the API under its token, so a browse-page URL 404s.
  /// Retrying against the origin costs one request and can rescue the setup.
  Future<http.Response> _retryIfMissing(
    http.Response first,
    String path,
    Future<http.Response> Function() again,
  ) async {
    if (_resolved) return first;
    _resolved = true;
    _base = base;
    if (first.statusCode != 404) return first;
    final parsed = Uri.tryParse(_base);
    if (parsed == null) return first;
    final origin = '${parsed.scheme}://${parsed.authority}';
    if (origin == _base) return first;
    _base = origin;
    try {
      return await again();
    } catch (_) {
      _base = parsed.toString();
      return first;
    }
  }

  /// Everything the store needs for a playback, or an empty list.
  ///
  /// [fileName] should look like `Some Show S01E02`: matching works far better
  /// on a normalised name than on a release-style file name.
  Future<({int? episodeId, String? title})> match(String fileName) async {
    if (base.isEmpty) return (episodeId: null, title: null);
    const path = '/api/v2/match';
    try {
      final res = await _post(path, {
        'fileName': fileName,
        // We stream from the media server and never see the file, so a real
        // hash is impossible. An all-zero hash matches nothing and the server
        // falls back to the file name, which is what we want.
        'fileHash': '00000000000000000000000000000000',
        'fileSize': 0,
        'matchMode': 'hashAndFileName',
      });
      if (res.statusCode != 200) return (episodeId: null, title: null);
      final body = jsonDecode(utf8.decode(res.bodyBytes));
      if (body is! Map || body['isMatched'] != true) return (episodeId: null, title: null);
      final matches = body['matches'];
      if (matches is! List || matches.isEmpty) return (episodeId: null, title: null);
      for (final m in matches) {
        if (m is! Map) continue;
        final id = m['episodeId'];
        if (id is! num) continue;
        final anime = m['animeTitle']?.toString();
        final episode = m['episodeTitle']?.toString();
        final label = [anime, episode].whereType<String>().where((s) => s.isNotEmpty).join(' · ');
        return (episodeId: id.toInt(), title: label.isEmpty ? null : label);
      }
    } catch (e) {
      _log('match failed', e);
    }
    return (episodeId: null, title: null);
  }

  Future<List<DanmakuAnime>> searchAnime(String keyword) async {
    if (base.isEmpty) return const [];
    const path = '/api/v2/search/anime';
    try {
      final res = await _get(path, {'keyword': keyword});
      if (res.statusCode != 200) return const [];
      final body = jsonDecode(utf8.decode(res.bodyBytes));
      final raw = body is Map ? body['animes'] : null;
      if (raw is! List) return const [];
      return [
        for (final e in raw)
          if (e is Map && e['animeId'] is num)
            DanmakuAnime(
              id: (e['animeId'] as num).toInt(),
              title: e['animeTitle']?.toString() ?? '',
              kind: e['typeDescription']?.toString(),
              episodeCount: switch (e['episodeCount']) { final num n => n.toInt(), _ => null },
            ),
      ];
    } catch (e) {
      _log('search failed', e);
      return const [];
    }
  }

  Future<List<DanmakuEpisode>> episodes(int animeId) async {
    if (base.isEmpty) return const [];
    final path = '/api/v2/bangumi/$animeId';
    try {
      final res = await _get(path);
      if (res.statusCode != 200) return const [];
      final body = jsonDecode(utf8.decode(res.bodyBytes));
      final raw = body is Map ? body['episodes'] : null;
      if (raw is! List) return const [];
      final out = <DanmakuEpisode>[];
      for (final e in raw) {
        if (e is! Map || e['episodeId'] is! num) continue;
        out.add(DanmakuEpisode(
          id: (e['episodeId'] as num).toInt(),
          title: e['episodeTitle']?.toString() ?? '',
          number: switch (e['episodeNumber']) { final num n => n.toInt(), _ => null },
        ));
      }
      return out;
    } catch (e) {
      _log('episodes failed', e);
      return const [];
    }
  }

  Future<List<DanmakuComment>> comments(int episodeId) async {
    if (base.isEmpty) return const [];
    final path = '/api/v2/comment/$episodeId';
    try {
      final res = await _get(path, {'withRelated': 'true', 'chConvert': '1'});
      if (res.statusCode != 200) return const [];
      final body = jsonDecode(utf8.decode(res.bodyBytes));
      if (body is! Map) return const [];
      final raw = body['comments'];
      if (raw is! List) return const [];
      return [
        for (final entry in raw)
          if (entry is Map) ?_parse(entry),
      ];
    } catch (e) {
      _log('comments failed', e);
      return const [];
    }
  }

  /// `p` is "start, mode, colour, user"; the rest of the payload is `m`.
  static DanmakuComment? _parse(Map<Object?, Object?> entry) {
    final text = (entry['m'] as Object?)?.toString().trim();
    final p = (entry['p'] as Object?)?.toString();
    if (text == null || text.isEmpty || text.length > 120 || p == null) return null;
    final parts = p.split(',');
    if (parts.length < 3) return null;
    final seconds = double.tryParse(parts[0]);
    if (seconds == null || seconds < 0 || !seconds.isFinite) return null;
    return DanmakuComment(
      time: Duration(milliseconds: (seconds * 1000).round()),
      text: text,
      mode: int.tryParse(parts[1].trim()) ?? 1,
      color: int.tryParse(parts[2].trim()) ?? 0xFFFFFF,
    );
  }

  static void _log(String what, Object error) {
    assert(() {
      // ignore: avoid_print
      print('[danmaku] $what: $error');
      return true;
    }());
  }

  void close() => _client.close();
}
