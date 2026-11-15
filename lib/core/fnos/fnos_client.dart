import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

/// Client for the trimemedia API that 飞牛影视 (fnOS) serves.
///
/// The signatures mirror FlyNarwhal's `AuthInterceptor`, which mirrors the
/// official web client: every request carries an `Authx` header whose sign is
/// `md5(apiKey_path_nonce_timestamp_dataMd5_apiSecret)`, where `dataMd5` is the
/// md5 of the exact body that goes out. Both strings were verified against a
/// live server: a correct sign answers `{"code":0,...}`, a missing one answers
/// `{"code":5000,"msg":"invalid sign"}`.
///
/// Endpoint shapes follow FlyNarwhal (verified against real servers): list-like
/// reads (mediadb/list, item/{guid}, season/list/{guid}, episode/list/{guid},
/// search/list?q=, play/list) are GETs with the guid in the path, while
/// item/list, play/info, stream and play/record are POSTs with a JSON body.
final class FnosClient {
  FnosClient({required String baseUrl, String? token, http.Client? client})
      : base = _trimBase(baseUrl),
        _token = token,
        _client = client ?? http.Client();

  static const apiKey = 'NDzZTVxnRKP8Z0jXg1VAMonaG8akvh';
  static const apiSecret = '16CCEB3D-AB42-077D-36A1-F355324E4237';
  static const _trimClient = 'web';
  static const _trimClientVersion = '616';
  static const _userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36';

  final String base;
  String? _token;
  String? _cookie;
  final http.Client _client;

  static String _trimBase(String url) {
    var s = url.trim();
    while (s.endsWith('/')) {
      s = s.substring(0, s.length - 1);
    }
    return s;
  }

  String? get token => _token;

  void updateToken(String? token) => _token = token;

  String? get cookie => _cookie;

  set cookie(String? value) => _cookie = (value == null || value.isEmpty) ? null : value;

  /// Headers the trimemedia image endpoint (`sys/img`) needs. FlyNarwhal sends
  /// the session cookie plus the raw token in `Authorization`; images fail on a
  /// real server without them.
  Map<String, String> get imageHeaders => {
        'User-Agent': _userAgent,
        if (_token != null && _token!.isNotEmpty) 'Authorization': _token!,
        if (_cookie != null && _cookie!.isNotEmpty) 'Cookie': _cookie!,
      };

  /// `path` is the API path exactly as it appears after the host, because the
  /// server signs the path as received.
  String _authx(String path, String dataJson) {
    final nonce = 100000 + Random.secure().nextInt(900000);
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final dataMd5 = md5.convert(utf8.encode(dataJson)).toString();
    final source = [apiKey, path, '$nonce', '$timestamp', dataMd5, apiSecret].join('_');
    final sign = md5.convert(utf8.encode(source)).toString();
    return 'nonce=$nonce&timestamp=$timestamp&sign=$sign';
  }

  Map<String, String> _headers(String path, String dataJson) => {
        'Accept': 'application/json',
        'User-Agent': _userAgent,
        'x-trim-client': _trimClient,
        'x-trim-client-version': _trimClientVersion,
        'Authx': _authx(path, dataJson),
        if (_token != null && _token!.isNotEmpty) 'Authorization': _token!,
        if (_cookie != null && _cookie!.isNotEmpty) 'Cookie': _cookie!,
      };

  /// `{code: 0, msg, data}` on success; anything else throws [FnosException].
  Future<Object?> _call(String method, String path, {Map<String, Object?>? body}) async {
    final dataJson = body == null ? '' : jsonEncode(body);
    final uri = Uri.parse('$base$path');
    final request = http.Request(method, uri)
      ..headers.addAll(_headers(path, dataJson))
      ..followRedirects = false;
    if (body != null) {
      request.headers['Content-Type'] = 'application/json';
      request.bodyBytes = utf8.encode(dataJson);
    }
    final response = await _client.send(request).timeout(const Duration(seconds: 20));
    final text = await response.stream.bytesToString();

    final setCookie = response.headers['set-cookie'];
    if (setCookie != null && setCookie.isNotEmpty) {
      _cookie = _mergeCookies(_cookie, setCookie);
    }

    final decoded = jsonDecode(text);
    if (decoded is! Map) {
      throw FnosException(-1, 'unexpected response shape', null);
    }
    final code = decoded['code'];
    if (code is num && code != 0) {
      throw FnosException(code.toInt(), decoded['msg']?.toString() ?? '', decoded['data']);
    }
    return decoded['data'];
  }

  Future<Object?> get(String path, {Map<String, String>? query}) async {
    var effective = path;
    if (query != null && query.isNotEmpty) {
      final sorted = query.entries.where((e) => e.value.isNotEmpty).toList()
        ..sort((a, b) => a.key.compareTo(b.key));
      effective = '$path?${[
        for (final e in sorted) '${e.key}=${Uri.encodeQueryComponent(e.value)}',
      ].join('&')}';
    }
    return _call('GET', effective);
  }

  Future<Object?> post(String path, {Map<String, Object?>? body}) => _call('POST', path, body: body);

  /// Returns the token; the cookie is kept for later requests.
  Future<String> login(String username, String password) async {
    final data = await post('/v/api/v1/login', body: {
      'username': username,
      'password': password,
      'app_name': 'trimemedia-web',
    });
    final token = data is Map ? data['token']?.toString() : null;
    if (token == null || token.isEmpty) {
      throw FnosException(-1, 'login did not return a token', data);
    }
    _token = token;
    return token;
  }

  Future<void> logout() async {
    try {
      await post('/v/api/v1/user/logout');
    } finally {
      _token = null;
    }
  }

  /// Poster/backdrop URL. trimemedia returns server-relative media paths
  /// (e.g. `/media/poster/...`) that are served through `sys/img`, mirroring
  /// FlyNarwhal's `resolveMediaImageUrl`. Absolute URLs pass through untouched.
  String imageUrl(String path, {int? width}) {
    final trimmed = path.trim();
    if (trimmed.isEmpty) return base;
    final lower = trimmed.toLowerCase();
    if (lower.startsWith('http://') || lower.startsWith('https://')) return trimmed;
    final suffix = trimmed.contains('?') ? '' : (width != null ? '?w=${width.round()}' : '');
    if (trimmed.startsWith('/v/api/v1/sys/img')) return '$base$trimmed$suffix';
    if (trimmed.startsWith('v/api/v1/sys/img')) return '$base/$trimmed$suffix';
    final normalized = trimmed.startsWith('/') ? trimmed : '/$trimmed';
    return '$base/v/api/v1/sys/img$normalized$suffix';
  }

  Future<Object?> mediaDbList() => get('/v/api/v1/mediadb/list');

  /// Recently watched entries (GET /v/api/v1/play/list).
  Future<Object?> playList() => get('/v/api/v1/play/list');

  Future<Object?> itemList({
    String? ancestorGuid,
    String? parentGuid,
    List<String> types = const [],
    int pageSize = 50,
    int page = 1,
  }) =>
      post('/v/api/v1/item/list', body: {
        if (ancestorGuid != null && ancestorGuid.isNotEmpty) 'ancestor_guid': ancestorGuid,
        if (parentGuid != null && parentGuid.isNotEmpty) 'parent_guid': parentGuid,
        'exclude_grouped_video': 1,
        'sort_type': 'DESC',
        'sort_column': 'create_time',
        'page_size': pageSize,
        'page': page,
        'tags': {'type': types},
      });

  /// GET /v/api/v1/item/{guid}
  Future<Object?> itemDetail(String guid) => get('/v/api/v1/item/$guid');

  /// GET /v/api/v1/season/list/{guid}
  Future<Object?> seasonList(String guid) => get('/v/api/v1/season/list/$guid');

  /// GET /v/api/v1/episode/list/{guid}
  Future<Object?> episodeList(String guid) => get('/v/api/v1/episode/list/$guid');

  /// GET /v/api/v1/search/list?q={keyword}
  Future<Object?> search(String keyword, {int pageSize = 30, int page = 1}) =>
      get('/v/api/v1/search/list', query: {'q': keyword, 'page_size': '$pageSize', 'page': '$page'});

  /// Playback descriptors for an item: guids for video/audio/subtitle plus the
  /// media that `/v/api/v1/stream` turns into a playable URL.
  Future<Object?> playInfo(String itemGuid, {String? mediaGuid}) => post('/v/api/v1/play/info',
      body: {
        'item_guid': itemGuid,
        if (mediaGuid != null && mediaGuid.isNotEmpty) 'media_guid': mediaGuid,
      });

  Future<Object?> stream(String mediaGuid, {int level = 0}) =>
      post('/v/api/v1/stream', body: {'media_guid': mediaGuid, 'level': level});

  Future<Object?> playRecord(Map<String, Object?> body) => post('/v/api/v1/play/record', body: body);

  /// Direct original-file range proxy for a media guid (FlyNarwhal's
  /// `buildDirectStreamUrl`); needs [imageHeaders]-style auth on the player.
  String directStreamUrl(String mediaGuid) => '$base/v/api/v1/media/range/$mediaGuid';

  static String _mergeCookies(String? existing, String setCookie) {
    final map = <String, String>{};
    for (final part in (existing ?? '').split(';')) {
      final kv = part.trim().split('=');
      if (kv.length == 2 && kv[0].isNotEmpty) map[kv[0]] = kv[1];
    }
    for (final pair in setCookie.split(RegExp(r',(?=[^;]+?=)'))) {
      final first = pair.split(';').first.trim();
      final kv = first.split('=');
      if (kv.length >= 2 && kv[0].isNotEmpty && !map.containsKey(kv[0])) {
        map[kv[0]] = kv.sublist(1).join('=');
      }
    }
    return map.entries.map((e) => '${e.key}=${e.value}').join('; ');
  }
}

final class FnosException implements Exception {
  const FnosException(this.code, this.message, this.data);

  final int code;
  final String message;
  final Object? data;

  @override
  String toString() => '飞牛接口错误 $code: $message';
}
