import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../core/emby/server_kind.dart';
import '../core/host.dart';
import 'app_settings.dart';
import 'release.dart';

final class HubFeatures {
  const HubFeatures({
    this.requests = false,
    this.together = false,
    this.profiles = false,
    this.redownload = false,
  });

  factory HubFeatures.fromJson(Object? raw) {
    final j = raw is Map ? raw : const {};
    return HubFeatures(
      requests: j['requests'] == true,
      together: j['together'] == true,
      profiles: j['profiles'] == true,
      redownload: j['redownload'] == true,
    );
  }

  final bool requests;
  final bool together;
  final bool profiles;
  final bool redownload;
}

/// One server a code opens. The first one of [HubConfig.servers] is the primary:
/// the client logs into it and takes every non-server setting from it.
final class HubServer {
  const HubServer({
    required this.name,
    required this.url,
    required this.kind,
    this.username = '',
    this.password = '',
    this.primary = false,
  });

  factory HubServer.fromJson(Object? raw) {
    final j = raw is Map ? raw : const {};
    return HubServer(
      name: '${j['name'] ?? ''}',
      url: '${j['url'] ?? ''}',
      kind: ServerKind.parse(j['kind'] as String?),
      username: '${j['username'] ?? ''}',
      password: '${j['password'] ?? ''}',
      primary: j['primary'] == true,
    );
  }

  final String name;
  final String url;
  final ServerKind kind;
  final String username;
  final String password;
  final bool primary;

  bool get usable => url.trim().isNotEmpty;

  /// The hub only sends credentials when the owner chose to store them.
  bool get hasLogin => username.trim().isNotEmpty && password.isNotEmpty;
}

final class HubDanmakuSource {
  const HubDanmakuSource({this.name = '', this.server = '', this.appId = '', this.appSecret = ''});

  factory HubDanmakuSource.fromJson(Object? raw) {
    final j = raw is Map ? raw : const {};
    return HubDanmakuSource(
      name: '${j['name'] ?? ''}',
      server: '${j['server'] ?? ''}',
      appId: '${j['appId'] ?? ''}',
      appSecret: '${j['appSecret'] ?? ''}',
    );
  }

  final String name;
  final String server;
  final String appId;
  final String appSecret;
}

final class HubDanmaku {
  const HubDanmaku({this.enabled = false, this.sources = const []});

  factory HubDanmaku.fromJson(Object? raw) {
    final j = raw is Map ? raw : const {};
    return HubDanmaku(
      enabled: j['enabled'] == true,
      sources: [
        for (final e in (j['sources'] as List? ?? const []))
          if (e is Map) HubDanmakuSource.fromJson(e),
      ],
    );
  }

  final bool enabled;
  final List<HubDanmakuSource> sources;
}

final class HubConfig {
  HubConfig(this.json)
      : serverName = (json['server'] as Map?)?['name'] as String? ?? '',
        serverUrl = (json['server'] as Map?)?['url'] as String? ?? '',
        serverKind = ServerKind.parse((json['server'] as Map?)?['kind'] as String?),
        base = Uri.tryParse(json['hub'] as String? ?? ''),
        features = HubFeatures.fromJson(json['features']),
        refreshAfter = Duration(hours: (json['refreshHours'] as num?)?.toInt() ?? 6);

  final Map<String, Object?> json;
  final String serverName;
  final String serverUrl;
  final ServerKind serverKind;
  final Uri? base;
  final HubFeatures features;
  final Duration refreshAfter;

  /// Every server the code opens, primary first. A hub that only knows about
  /// one server still answers with `servers`, but older ones send `server`
  /// alone, so the fallback keeps them working.
  late final List<HubServer> servers = _readServers();

  /// Comment sources the owner attached to the primary server.
  late final HubDanmaku danmaku = HubDanmaku.fromJson(json['danmaku']);

  HubServer? get primary => servers.isEmpty ? null : servers.first;

  List<HubServer> _readServers() {
    final list = <HubServer>[
      for (final e in (json['servers'] as List? ?? const []))
        if (e is Map) HubServer.fromJson(e),
    ];
    final usable = [
      for (final s in list)
        if (s.usable) s,
    ];
    if (usable.isEmpty && serverUrl.trim().isNotEmpty) {
      usable.add(HubServer(name: serverName, url: serverUrl, kind: serverKind, primary: true));
    }
    return List.unmodifiable(usable);
  }

  String _text(String key) => json[key] is String ? json[key] as String : '';

  Map _map(String key) => json[key] is Map ? json[key] as Map : const {};

  AppSettings applyTo(AppSettings s) {
    final seerr = _map('seerr');
    final tv = _map('liveTv');
    final accounts = [
      for (final a in tv['xtreamAccounts'] as List? ?? const [])
        if (a is List && a.length == 2) ('${a[0]}', '${a[1]}'),
    ];
    final language = _text('metadataLanguage');
    return s.copyWith(
      tmdbApiKey: _text('tmdbApiKey'),
      mdblistApiKey: _text('mdblistApiKey'),
      metadataLanguage: s.metadataLanguage.isEmpty && language.isNotEmpty ? language : null,
      seerrUrl: seerr['enabled'] == true ? '${seerr['url']}' : '',
      seerrApiKey: seerr['enabled'] == true ? 'hub' : '',
      xtreamUrl: '${tv['xtreamUrl'] ?? ''}',
      xtreamAccounts: accounts,
      playlistUrl: '${tv['playlistUrl'] ?? ''}',
      playlistGuideUrl: '${tv['playlistGuideUrl'] ?? ''}',
      onboarded: true,
    );
  }
}

final class HubLinkException implements Exception {
  const HubLinkException(this.code, this.message);

  final String code;
  final String message;

  bool get dropsLink => code == 'revoked' || code == 'unknown-code' || code == 'inactive';

  @override
  String toString() => message;
}

abstract final class HubLink {
  static const _key = 'hub.link.v1';

  /// Kept apart from the link record: the address a device typed once should
  /// still be there after unlinking, so switching codes is a two-tap job.
  static const _addressKey = 'hub.address';

  static String get defaultHub => Release.hub;

  static HubConfig? _config;
  static String? _code;
  static String? _hub;
  static String? _address;
  static DateTime? _linkedAt;

  /// Token for the control channel (poll commands / report playback). Minted
  /// by the hub on link and kept with the cached config, so a restart does not
  /// need a new redeem.
  static String? _controlToken;

  static final changed = ValueNotifier<int>(0);

  static String? droppedMessage;

  static HubConfig? get config => _config;

  static bool get linked => _config != null;

  /// null 表示这台 hub 没有控制通道（旧版本），语音控制自动不启动。
  static String? get controlToken => _controlToken;

  static String? _readControlToken(Map config) {
    final c = config['control'];
    if (c is Map) {
      final t = c['token'];
      if (t is String && t.isNotEmpty) return t;
    }
    return null;
  }

  static Uri? get base => _config?.base;

  static HubFeatures get features => _config?.features ?? const HubFeatures();

  static String? get code => _code;

  static String get hub => _hub ?? _address ?? defaultHub;

  static Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _address = prefs.getString(_addressKey);
    final raw = prefs.getString(_key);
    if (raw == null) return;
    try {
      final j = jsonDecode(raw) as Map<String, Object?>;
      _code = j['code'] as String?;
      _hub = j['hub'] as String?;
      _linkedAt = DateTime.tryParse(j['linkedAt'] as String? ?? '');
      final config = j['config'];
      if (config is Map<String, Object?>) {
        _config = HubConfig(config);
        _controlToken = _readControlToken(config);
      }
    } catch (e) {
      debugPrint('[hub] stored link unreadable: $e');
    }
  }

  static bool get due {
    final at = _linkedAt;
    final config = _config;
    return config != null && (at == null || DateTime.now().difference(at) > config.refreshAfter);
  }

  /// Turns whatever someone typed into a hub origin: `10.0.0.5:8790` becomes
  /// `http://10.0.0.5:8790`, a trailing slash or a pre-filled `/app/zerk-hub`
  /// prefix is left alone. A bare name is assumed to be a LAN box, because
  /// self-hosted consoles almost never carry a certificate.
  static String normalize(String hub) {
    var h = hub.trim();
    if (h.isEmpty) return h;
    if (!h.contains('://')) h = '${_looksLocal(h) ? 'http' : 'https'}://$h';
    while (h.endsWith('/')) {
      h = h.substring(0, h.length - 1);
    }
    return h;
  }

  static bool _looksLocal(String bare) {
    final name = bare.split('/').first;
    if (name.startsWith('[')) return true; // IPv6 literal
    final host = name.split(':').first;
    if (host == 'localhost' || host.endsWith('.local') || host.endsWith('.lan')) return true;
    if (RegExp(r'^\d{1,3}(\.\d{1,3}){3}$').hasMatch(host)) return true;
    return name.contains(':'); // an explicit port means a private install
  }

  /// Keeps any prefix the address carries. A console served through the fnOS
  /// gateway lives under `/app/zerk-hub`, and the hub strips that itself.
  static Uri _endpoint(String hub) {
    final uri = Uri.parse(normalize(hub));
    var prefix = uri.path;
    while (prefix.endsWith('/')) {
      prefix = prefix.substring(0, prefix.length - 1);
    }
    return uri.replace(path: '$prefix/api/app/link', query: null, fragment: null);
  }

  static Future<HubConfig> redeem(String code, {String? hub}) async {
    final prefs = await SharedPreferences.getInstance();
    var device = prefs.getString('hub.deviceId');
    if (device == null) {
      device = const Uuid().v4();
      await prefs.setString('hub.deviceId', device);
    }
    final target = normalize((hub == null || hub.trim().isEmpty) ? defaultHub : hub);
    if (target.isEmpty) throw const HubLinkException('no-hub', 'Enter the hub address your server owner gave you.');
    final Uri endpoint;
    try {
      endpoint = _endpoint(target);
    } on FormatException {
      throw const HubLinkException('bad-hub', 'That console address does not look like a URL.');
    }
    if (endpoint.host.isEmpty) {
      throw const HubLinkException('bad-hub', 'That console address does not look like a URL.');
    }
    final http.Response res;
    try {
      res = await http
          .post(
            endpoint,
            headers: {'content-type': 'application/json', 'accept': 'application/json'},
            body: jsonEncode({
              'code': code,
              'device': {
                'id': device,
                'name': Host.isAndroid ? 'Android TV' : Host.isLinux ? 'Linux' : 'Windows',
                'platform': Host.isAndroid ? 'androidtv' : Host.isLinux ? 'linux' : 'windows',
                'version': Release.name,
              },
            }),
          )
          .timeout(const Duration(seconds: 20));
    } catch (e) {
      throw HubLinkException('unreachable', 'Could not reach $target. Check your connection and try again.');
    }
    Object? json;
    try {
      json = jsonDecode(utf8.decode(res.bodyBytes));
    } on FormatException {
      json = null;
    }
    if (res.statusCode != 200 || json is! Map<String, Object?>) {
      final map = json is Map ? json : const {};
      throw HubLinkException('${map['code'] ?? 'http-${res.statusCode}'}', '${map['message'] ?? 'The hub answered ${res.statusCode}.'}');
    }
    final config = HubConfig(json);
    if (config.servers.isEmpty || config.base == null) {
      throw const HubLinkException('bad-config', 'The hub sent an incomplete setup.');
    }
    debugPrint('[hub] link v2: ${config.servers.length} server(s), danmaku ${config.danmaku.sources.length}');
    _config = config;
    _controlToken = _readControlToken(json);
    _code = code;
    _hub = target;
    _address = target;
    _linkedAt = DateTime.now();
    await prefs.setString(_addressKey, target);
    await prefs.setString(_key, jsonEncode({
      'code': code,
      'hub': target,
      'linkedAt': _linkedAt!.toIso8601String(),
      'config': _stripAccounts(json),
    }));
    changed.value++;
    return config;
  }

  /// The cached payload never keeps the account the hub sent. It is already
  /// stored by the sidebar's server list (obfuscated), and a plaintext password
  /// in shared_preferences would be the weakest copy on the device.
  static Map<String, Object?> _stripAccounts(Map<String, Object?> raw) {
    final out = <String, Object?>{};
    raw.forEach((k, v) => out[k] = v);
    final list = raw['servers'];
    if (list is List) {
      out['servers'] = [for (final e in list) if (e is Map) _stripAccount(e) else e];
    }
    final single = raw['server'];
    if (single is Map) out['server'] = _stripAccount(single);
    return out;
  }

  static Map<String, Object?> _stripAccount(Map<dynamic, dynamic> src) {
    final out = <String, Object?>{};
    src.forEach((k, v) {
      final key = '$k';
      if (key != 'username' && key != 'password') out[key] = v;
    });
    return out;
  }

  static Future<HubConfig?> refresh() async {
    final code = _code;
    if (code == null) return null;
    try {
      return await redeem(code, hub: _hub ?? _address);
    } on HubLinkException catch (e) {
      debugPrint('[hub] refresh: ${e.code} ${e.message}');
      if (e.dropsLink) await unlink();
      rethrow;
    }
  }

  static Future<void> unlink() async {
    _config = null;
    _code = null;
    _hub = null;
    _linkedAt = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
    changed.value++;
  }
}
