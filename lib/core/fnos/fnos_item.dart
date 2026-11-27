import 'package:flutter/material.dart';

/// One entry of trimemedia's `item/list` / `episode/list` / `play/list`
/// responses, parsed defensively: the server's field set varies by type
/// (movie / tv / episode / video / folder).
final class FnOsItem {
  FnOsItem.from(Map raw)
      : guid = raw['guid']?.toString() ?? '',
        title = raw['title']?.toString() ?? '',
        tvTitle = raw['tv_title']?.toString() ?? '',
        parentGuid = raw['parent_guid']?.toString() ?? '',
        type = raw['type']?.toString() ?? '',
        poster = raw['poster']?.toString(),
        posterList = [
          for (final p in (raw['poster_list'] as List? ?? const []))
            if (p != null) p.toString(),
        ],
        seasonNumber = (raw['season_number'] as num?)?.toInt(),
        episodeNumber = (raw['episode_number'] as num?)?.toInt(),
        numberOfSeasons = (raw['number_of_seasons'] as num?)?.toInt(),
        numberOfEpisodes = (raw['number_of_episodes'] as num?)?.toInt(),
        releaseDate = raw['release_date']?.toString(),
        voteAverage = raw['vote_average']?.toString(),
        watched = raw['watched']?.toString() == '1' || raw['is_watched']?.toString() == '1',
        ts = (raw['ts'] as num?)?.toInt(),
        duration = (raw['duration'] as num?)?.toInt(),
        runtime = (raw['runtime'] as num?)?.toInt();

  final String guid;
  final String title;
  final String tvTitle;
  final String parentGuid;
  final String type;
  final String? poster;
  final List<String> posterList;
  final int? seasonNumber;
  final int? episodeNumber;
  final int? numberOfSeasons;
  final int? numberOfEpisodes;
  final String? releaseDate;
  final String? voteAverage;
  final bool watched;
  final int? ts;

  /// Seconds, as `play/list` reports the watched position.
  final int? duration;

  /// Minutes. `item/list` and `item/{guid}` both carry it, while `duration`
  /// comes back as 0 for most movies - the hero's runtime line reads this one.
  final int? runtime;

  /// trimemedia types are capitalized (`Movie`, `TV`, `Episode`, `Video`).
  String get kind => type.toLowerCase();

  String? get posterPath {
    final p = poster?.trim();
    if (p != null && p.isNotEmpty && p != '0') return p;
    if (posterList.isNotEmpty) return posterList.first;
    return null;
  }

  /// Episodes carry the show title in `tv_title`; use it as the grid title
  /// (mirrors FlyNarwhal's buildPlayDetailTitle).
  String get displayTitle {
    final t = tvTitle.trim();
    if (kind == 'episode' && t.isNotEmpty) return t;
    final own = title.trim();
    if (own.isNotEmpty) return own;
    return t;
  }

  String? get subtitle {
    if (kind == 'episode') {
      final s = seasonNumber ?? 0;
      final e = episodeNumber ?? 0;
      if (s > 0 || e > 0) return 'S$s E$e';
      return null;
    }
    final date = releaseDate?.trim();
    return date != null && date.length >= 4 ? date.substring(0, 4) : null;
  }

  /// Resume position in seconds when this entry comes from play/list.
  bool get isResumable {
    final d = duration ?? 0;
    final p = ts ?? 0;
    return p > 0 && (d <= 0 || p < d - 10);
  }

  double? get progress {
    final d = duration ?? 0;
    final p = ts ?? 0;
    if (d <= 0 || p <= 0) return null;
    return (p / d).clamp(0.0, 1.0);
  }

  IconData get icon => switch (kind) {
        'tv' => Icons.tv_rounded,
        'episode' => Icons.smart_display_outlined,
        'directory' => Icons.folder_outlined,
        _ => Icons.movie_outlined,
      };
}
