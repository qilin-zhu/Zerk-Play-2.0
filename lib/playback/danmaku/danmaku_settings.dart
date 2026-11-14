import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'danmaku_source.dart';

/// Danmaku preferences, kept apart from [PlayerSettings] because the feature is
/// optional and carries its own source list.
final class DanmakuSettings {
  const DanmakuSettings({
    this.enabled = false,
    this.sources = const [kDandanplaySource],
    this.offsetMs = 0,
    this.opacity = 1.0,
    this.scale = 1.0,
    this.speed = 1.0,
    this.syncSpeed = true,
    this.bold = false,
    this.scrollLines = 5,
    this.topLines = 1,
    this.bottomLines = 3,
    this.lineGap = 4,
    this.rememberManual = true,
  });

  final bool enabled;

  /// In priority order: the first source with comments for the episode wins.
  final List<DanmakuSource> sources;

  /// Shifts the timeline; releases differ in how much lead-in they have.
  final int offsetMs;

  final double opacity;
  final double scale;
  final double speed;
  final bool syncSpeed;
  final bool bold;

  final int scrollLines;
  final int topLines;
  final int bottomLines;

  /// Pixels between lines.
  final int lineGap;

  /// Remember the episode picked by hand for the next playback.
  final bool rememberManual;

  List<DanmakuSource> get usableSources => [
        for (final s in sources)
          if (s.usable) s,
      ];

  bool get usable => enabled && usableSources.isNotEmpty;

  DanmakuSettings copyWith({
    bool? enabled,
    List<DanmakuSource>? sources,
    int? offsetMs,
    double? opacity,
    double? scale,
    double? speed,
    bool? syncSpeed,
    bool? bold,
    int? scrollLines,
    int? topLines,
    int? bottomLines,
    int? lineGap,
    bool? rememberManual,
  }) =>
      DanmakuSettings(
        enabled: enabled ?? this.enabled,
        sources: sources ?? this.sources,
        offsetMs: offsetMs ?? this.offsetMs,
        opacity: opacity ?? this.opacity,
        scale: scale ?? this.scale,
        speed: speed ?? this.speed,
        syncSpeed: syncSpeed ?? this.syncSpeed,
        bold: bold ?? this.bold,
        scrollLines: scrollLines ?? this.scrollLines,
        topLines: topLines ?? this.topLines,
        bottomLines: bottomLines ?? this.bottomLines,
        lineGap: lineGap ?? this.lineGap,
        rememberManual: rememberManual ?? this.rememberManual,
      );

  Map<String, Object?> toJson() => {
        'enabled': enabled,
        'sources': [for (final s in sources) s.toJson()],
        'offsetMs': offsetMs,
        'opacity': opacity,
        'scale': scale,
        'speed': speed,
        'syncSpeed': syncSpeed,
        'bold': bold,
        'scrollLines': scrollLines,
        'topLines': topLines,
        'bottomLines': bottomLines,
        'lineGap': lineGap,
        'rememberManual': rememberManual,
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

    var sources = <DanmakuSource>[
      for (final raw in (j['sources'] as List? ?? const [])) ?DanmakuSource.fromJson(raw),
    ];

    if (sources.isEmpty) {
      // Settings written before sources existed carried a single server.
      final legacy = pick('server', '');
      sources = [
        kDandanplaySource,
        if (legacy.trim().isNotEmpty)
          DanmakuSource(
            id: 'custom',
            name: '',
            server: legacy,
            appId: pick('appId', ''),
            appSecret: pick('appSecret', ''),
          ),
      ];
    }

    return DanmakuSettings(
      enabled: pick('enabled', d.enabled),
      sources: sources,
      offsetMs: pick('offsetMs', d.offsetMs),
      opacity: pick('opacity', d.opacity).clamp(0.2, 1.0).toDouble(),
      scale: pick('scale', d.scale).clamp(0.6, 1.8).toDouble(),
      speed: pick('speed', d.speed).clamp(0.5, 2.0).toDouble(),
      syncSpeed: pick('syncSpeed', d.syncSpeed),
      bold: pick('bold', d.bold),
      scrollLines: pick('scrollLines', d.scrollLines).clamp(1, 12),
      topLines: pick('topLines', d.topLines).clamp(0, 4),
      bottomLines: pick('bottomLines', d.bottomLines).clamp(0, 4),
      lineGap: pick('lineGap', d.lineGap).clamp(0, 16),
      rememberManual: pick('rememberManual', d.rememberManual),
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
