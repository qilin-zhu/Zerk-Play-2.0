import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Danmaku (bullet comment) preferences.
///
/// Kept apart from [PlayerSettings] on purpose: danmaku is optional, most users
/// never touch it, and it carries its own server credentials.
final class DanmakuSettings {
  const DanmakuSettings({
    this.enabled = false,
    this.server = defaultServer,
    this.appId = '',
    this.appSecret = '',
    this.offsetMs = 0,
    this.opacity = 0.9,
    this.fontSize = 22,
  });

  /// The public dandanplay API. A self hosted `danmu_api` instance speaks the
  /// same protocol and needs no credentials at all.
  static const defaultServer = 'https://api.dandanplay.net';

  final bool enabled;

  final String server;

  /// dandanplay developer credentials. Empty means "no signing", which is what
  /// a self hosted server expects.
  final String appId;
  final String appSecret;

  /// Shifts the danmaku timeline. Different releases have different lead-ins,
  /// so this is the difference between usable and useless.
  final int offsetMs;

  final double opacity;
  final double fontSize;

  bool get hasCredentials => appId.trim().isNotEmpty && appSecret.trim().isNotEmpty;

  String get baseUrl => server.trim().replaceAll(RegExp(r'/+$'), '');

  bool get usable => enabled && baseUrl.isNotEmpty;

  DanmakuSettings copyWith({
    bool? enabled,
    String? server,
    String? appId,
    String? appSecret,
    int? offsetMs,
    double? opacity,
    double? fontSize,
  }) =>
      DanmakuSettings(
        enabled: enabled ?? this.enabled,
        server: server ?? this.server,
        appId: appId ?? this.appId,
        appSecret: appSecret ?? this.appSecret,
        offsetMs: offsetMs ?? this.offsetMs,
        opacity: opacity ?? this.opacity,
        fontSize: fontSize ?? this.fontSize,
      );

  Map<String, Object?> toJson() => {
        'enabled': enabled,
        'server': server,
        'appId': appId,
        'appSecret': appSecret,
        'offsetMs': offsetMs,
        'opacity': opacity,
        'fontSize': fontSize,
      };

  factory DanmakuSettings.fromJson(Map<String, dynamic> j) {
    const d = DanmakuSettings();
    T pick<T>(String key, T fallback) {
      final v = j[key];
      if (v is T) return v;
      if (T == double && v is num) return v.toDouble() as T;
      if (T == int && v is num) return v.toInt() as T;
      return fallback;
    }

    return DanmakuSettings(
      enabled: pick('enabled', d.enabled),
      server: pick('server', d.server),
      appId: pick('appId', d.appId),
      appSecret: pick('appSecret', d.appSecret),
      offsetMs: pick('offsetMs', d.offsetMs),
      opacity: pick('opacity', d.opacity).clamp(0.2, 1.0).toDouble(),
      fontSize: pick('fontSize', d.fontSize).clamp(12.0, 48.0).toDouble(),
    );
  }

  static const _key = 'danmaku.settings.v1';

  static Future<DanmakuSettings> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null) return const DanmakuSettings();
    try {
      return DanmakuSettings.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return const DanmakuSettings();
    }
  }

  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode(toJson()));
  }
}
