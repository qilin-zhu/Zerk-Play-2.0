import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

/// Client for the trimemedia API that 飞牛影视 (fnOS) serves.
///
/// The signatures mirror FlyNarwhal's `AuthInterceptor`, which mirrors the
/// official web client: every request carries an `Authx` header whose sign is
/// `md5(apiKey_path_nonce_timestamp_dataMd5_apiSecret)`, where `dataMd5` is
/// the md5 of the JSON body for POSTs, the sorted `k=v` query string (raw
/// values) for GETs with parameters, and of the empty string otherwise. The
/// signed path never includes the query string.
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

  /// The browser User-Agent the web player uses. Cloud links resolved by the
  /// NAS are meant to be fetched by a browser, so any request that goes to a
  /// provider host has to keep this identity.
  static String get webUserAgent => _userAgent;

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

  /// dataMd5 for the Authx sign. Mirrors FlyNarwhal's `_buildDataJsonMd5`:
  /// POSTs hash the JSON body, GETs hash the sorted `k=v` parameter string
  /// with **raw (unencoded) values**, and no parameters at all hash the empty
  /// string. The query string itself is never part of the signed path — the
  /// server rejects that with `{code: 5000, invalid sign}`.
  String _dataMd5(Map<String, Object?>? body, Map<String, String>? query) {
    if (body != null) return md5.convert(utf8.encode(jsonEncode(body))).toString();
    if (query != null && query.isNotEmpty) {
      final sorted = query.entries.where((e) => e.value.isNotEmpty).toList()
        ..sort((a, b) => a.key.compareTo(b.key));
      final params = [for (final e in sorted) '${e.key}=${e.value}'].join('&');
      return md5.convert(utf8.encode(params)).toString();
    }
    return md5.convert(utf8.encode('')).toString();
  }

  /// `path` is the bare API path (no query string); the server signs the path
  /// as received, and query parameters only enter the sign through [_dataMd5].
  String _authx(String path, String dataMd5) {
    final nonce = 100000 + Random.secure().nextInt(900000);
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final source = [apiKey, path, '$nonce', '$timestamp', dataMd5, apiSecret].join('_');
    final sign = md5.convert(utf8.encode(source)).toString();
    return 'nonce=$nonce&timestamp=$timestamp&sign=$sign';
  }

  Map<String, String> _headers(String path, String dataMd5) => {
        'Accept': 'application/json',
        'User-Agent': _userAgent,
        'x-trim-client': _trimClient,
        'x-trim-client-version': _trimClientVersion,
        'Authx': _authx(path, dataMd5),
        if (_token != null && _token!.isNotEmpty) 'Authorization': _token!,
        if (_cookie != null && _cookie!.isNotEmpty) 'Cookie': _cookie!,
      };

  /// `{code: 0, msg, data}` on success; anything else throws [FnosException].
  Future<Object?> _call(String method, String path,
      {Map<String, Object?>? body, Map<String, String>? query}) async {
    final dataMd5 = _dataMd5(body, query);
    var uri = Uri.parse('$base$path');
    if (query != null && query.isNotEmpty) {
      uri = uri.replace(queryParameters: {
        for (final e in query.entries)
          if (e.value.isNotEmpty) e.key: e.value,
      });
    }
    final request = http.Request(method, uri)
      ..headers.addAll(_headers(path, dataMd5))
      ..followRedirects = false;
    if (body != null) {
      request.headers['Content-Type'] = 'application/json';
      request.bodyBytes = utf8.encode(jsonEncode(body));
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

  Future<Object?> get(String path, {Map<String, String>? query}) =>
      _call('GET', path, query: query);

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

  /// Cast and crew of an item (POST /v/api/v1/person/list/{guid}, `{}` body).
  Future<Object?> personList(String guid) => post('/v/api/v1/person/list/$guid', body: {});

  /// Stream descriptors (GET /v/api/v1/stream/list/{guid}): video/audio/
  /// subtitle streams plus files, used for the media info section.
  Future<Object?> streamList(String guid) => get('/v/api/v1/stream/list/$guid');

  /// GET /v/api/v1/search/list?q={keyword} — the verified shape (FlyNarwhal)
  /// sends only the keyword; paging parameters are not part of this endpoint.
  Future<Object?> search(String keyword) =>
      get('/v/api/v1/search/list', query: {'q': keyword});

  /// Favorited items (POST /v/api/v1/favorite/list, same query as item/list).
  Future<Object?> favoriteList({
    String? ancestorGuid,
    List<String> types = const [],
    int pageSize = 50,
    int page = 1,
  }) =>
      post('/v/api/v1/favorite/list', body: {
        if (ancestorGuid != null && ancestorGuid.isNotEmpty) 'ancestor_guid': ancestorGuid,
        'exclude_grouped_video': 1,
        'sort_type': 'DESC',
        'sort_column': 'create_time',
        'page_size': pageSize,
        'page': page,
        'tags': {'type': types},
      });

  /// Playback descriptors for an item: guids for video/audio/subtitle plus the
  /// media that `/v/api/v1/stream` turns into a playable URL.
  Future<Object?> playInfo(String itemGuid, {String? mediaGuid}) => post('/v/api/v1/play/info',
      body: {
        'item_guid': itemGuid,
        if (mediaGuid != null && mediaGuid.isNotEmpty) 'media_guid': mediaGuid,
      });

  /// Stream session for a media guid. The server is picky about the body —
  /// verified against a real server: `level` must be 1, `ip` must be
  /// md5(token) and `header` must carry the client User-Agent, or it answers
  /// `Invalid Params`. The response carries the cloud/STRM playback info
  /// (cloud_storage_info, direct_link_qualities, provider header).
  Future<Object?> stream(String mediaGuid) => post('/v/api/v1/stream', body: {
        'media_guid': mediaGuid,
        'ip': md5.convert(utf8.encode(_token ?? '')).toString(),
        'level': 1,
        'header': {'User-Agent': [_userAgent]},
      });

  Future<Object?> playRecord(Map<String, Object?> body) => post('/v/api/v1/play/record', body: body);

  /// Direct original-file range proxy for a media guid (FlyNarwhal's
  /// `buildDirectStreamUrl`); needs [imageHeaders]-style auth on the player.
  /// Cloud media passes [directLinkQualityIndex] so the backend selects the
  /// matching CDN link server-side (the web player's URL shape).
  String directStreamUrl(String mediaGuid, {int? directLinkQualityIndex}) {
    final index = directLinkQualityIndex;
    if (index == null || index < 0) return '$base/v/api/v1/media/range/$mediaGuid';
    return '$base/v/api/v1/media/range/$mediaGuid?direct_link_quality_index=$index';
  }

  /// `/wp/m3u8` proxy for 115 Pan m3u8 qualities (web player's
  /// `R2.getM3u8Url`): the original CDN m3u8 is encoded into `originalUrl`
  /// so the NAS rewrites segment URLs to stay reachable.
  String wpM3u8Url(String qualityUrl, {int? audioTrackIndex}) {
    final uri = Uri.parse(qualityUrl);
    final proxied = uri.replace(queryParameters: {
      ...uri.queryParameters,
      if (audioTrackIndex != null && audioTrackIndex >= 0) 'audio_track': '$audioTrackIndex',
    });
    return '$base/v/api/v1/wp/m3u8?originalUrl=${Uri.encodeComponent(proxied.toString())}';
  }

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
