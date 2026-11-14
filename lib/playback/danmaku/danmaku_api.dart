import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

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

/// Minimal client for the dandanplay open API (also served by `danmu_api`).
///
/// Docs: https://doc.dandanplay.com/open/ — the two calls that matter are
/// `POST /api/v2/match` (file name / hash -> episode id) and
/// `GET /api/v2/comment/{episodeId}`.
final class DanmakuApi {
  DanmakuApi({
    required this.server,
    this.appId = '',
    this.appSecret = '',
    http.Client? client,
  }) : _client = client ?? http.Client();

  final String server;
  final String appId;
  final String appSecret;
  final http.Client _client;

  static const _timeout = Duration(seconds: 10);

  String get _base => server.trim().replaceAll(RegExp(r'/+$'), '');

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

  /// Everything the store needs for a playback, or an empty list.
  ///
  /// [fileName] should look like `Some Show S01E02`: dandanplay matches far
  /// better on a normalised name than on a release-style file name.
  Future<List<DanmakuComment>> forFile(String fileName) async {
    if (_base.isEmpty) return const [];
    final episodeId = await _matchEpisode(fileName);
    if (episodeId == null) return const [];
    return _comments(episodeId);
  }

  Future<int?> _matchEpisode(String fileName) async {
    const path = '/api/v2/match';
    try {
      final res = await _client
          .post(
            Uri.parse('$_base$path'),
            headers: {..._headers(path), 'content-type': 'application/json'},
            body: jsonEncode({
              'fileName': fileName,
              // We stream from the media server and never see the file, so a
              // real hash is impossible. An all-zero hash matches nothing and
              // the server falls back to the file name, which is what we want.
              'fileHash': '00000000000000000000000000000000',
              'fileSize': 0,
              'matchMode': 'hashAndFileName',
            }),
          )
          .timeout(_timeout);
      if (res.statusCode != 200) return null;
      final body = jsonDecode(utf8.decode(res.bodyBytes));
      if (body is! Map || body['isMatched'] != true) return null;
      final matches = body['matches'];
      if (matches is! List || matches.isEmpty) return null;
      for (final m in matches) {
        if (m is Map && m['episodeId'] is num) return (m['episodeId'] as num).toInt();
      }
    } catch (e) {
      _log('match failed', e);
    }
    return null;
  }

  Future<List<DanmakuComment>> _comments(int episodeId) async {
    final path = '/api/v2/comment/$episodeId';
    try {
      final uri = Uri.parse('$_base$path').replace(queryParameters: {
        'withRelated': 'true',
        'chConvert': '1',
      });
      final res = await _client.get(uri, headers: _headers(path)).timeout(_timeout);
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

  /// `p` is "start, mode, colour, user", the rest of the payload is `m`.
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
