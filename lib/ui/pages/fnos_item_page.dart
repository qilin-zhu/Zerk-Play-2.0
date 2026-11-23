import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/app_services.dart';
import '../../core/emby/models/media_source.dart';
import '../../core/fnos/fnos_client.dart';
import '../../core/fnos/fnos_item.dart';
import '../../l10n/l10n.dart';
import '../../playback/fnos_playback.dart' show playFnOs;
import '../../playback/versions.dart';
import '../core/navigation.dart';
import '../focus/focus_zone.dart';
import '../theme/tokens.dart';
import '../widgets/backdrop.dart';
import '../widgets/common.dart';
import '../widgets/media_badges.dart';
import '../widgets/media_row.dart';
import '../widgets/rows_scroll_view.dart';
import 'details_parts.dart' show OverviewText, SynopsisButton, endsAt, overviewIsLong, pageLeft;
import 'fnos_cards.dart';
import 'hero.dart' show formatRuntime;

/// Detail page for a trimemedia item: `item/{guid}` plus cast, stream info and
/// the season/episode lists.
///
/// The layout is deliberately the same one [DetailsPage] uses for Emby and
/// Jellyfin — full-bleed drifting backdrop, title block at [pageLeft] starting a
/// fifth of the way down, overview beside it, one row of action buttons, the
/// episode row as 16:9 cards, then cast and a single tech line. Only the data
/// source differs: trimemedia carries no logos, media sources or user data
/// flags, so the stream list is folded into a [MediaSourceInfo] to feed the
/// same badges, and the resume position comes from the item's `ts`/`duration`.
class FnOsItemPage extends StatefulWidget {
  const FnOsItemPage({super.key, required this.guid, this.seed});

  final String guid;
  final FnOsItem? seed;

  @override
  State<FnOsItemPage> createState() => _FnOsItemPageState();
}

class _FnOsItemPageState extends State<FnOsItemPage> {
  Map<String, Object?>? _detail;
  List<Map<String, Object?>> _seasons = const [];
  List<Map<String, Object?>> _episodes = const [];
  List<Map<String, Object?>> _persons = const [];
  Map<String, Object?>? _streams;
  String? _seasonGuid;
  String? _error;
  bool _busy = false;

  final _scroll = RevealController(mode: RevealMode.minimal, margin: 140);
  final _playNode = FocusNode(debugLabel: 'fnos-play');
  final _episodeNode = FocusNode(debugLabel: 'fnos-episode-current');
  bool _episodeFocusPending = true;

  FnosClient? get _client => AppServicesScope.read(context).janus.fnos;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _reload());
  }

  @override
  void dispose() {
    _scroll.dispose();
    _playNode.dispose();
    _episodeNode.dispose();
    super.dispose();
  }

  String? _s(Map m, String key) {
    final v = m[key]?.toString();
    return v == null || v.isEmpty || v == '0' ? null : v;
  }

  String _guid(Map m) => m['guid']?.toString() ?? '';

  int _int(Map m, String key) => (m[key] as num?)?.toInt() ?? 0;

  static List<Map> _maps(Object? raw) =>
      raw is List ? [for (final e in raw) if (e is Map) e] : const [];

  Future<void> _reload() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final client = _client;
      if (client == null) throw StateError('no fnOS session');
      final detail = await client.itemDetail(widget.guid);
      final map = detail is Map ? Map<String, Object?>.from(detail) : <String, Object?>{};
      final type = (map['type']?.toString() ?? widget.seed?.type ?? '').toLowerCase();
      final seasons = <Map<String, Object?>>[];
      if (type == 'tv') {
        final raw = await client.seasonList(widget.guid);
        seasons.addAll([for (final e in _maps(raw)) Map<String, Object?>.from(e)]);
      }
      if (!mounted) return;
      setState(() {
        _detail = map;
        _seasons = seasons;
        _busy = false;
      });
      _focusPlay();

      // Cast and stream details load in the background; failures stay silent.
      unawaited(_loadPersons());
      if (type == 'movie' || type == 'video' || type == 'episode') {
        unawaited(_loadStreams());
      }

      if (seasons.length == 1) {
        await _loadEpisodes(_guid(seasons.first));
      } else if (seasons.isEmpty) {
        // A season-less tv item may still answer episode/list with every
        // episode; an opened episode shows its siblings from the parent.
        final parent = widget.seed?.parentGuid ?? _s(map, 'parent_guid') ?? '';
        if (type == 'episode' && parent.isNotEmpty) {
          await _loadEpisodes(parent);
        } else if (type == 'tv') {
          await _loadEpisodes(widget.guid);
        }
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _busy = false;
      });
    }
  }

  /// Same entry point as an Emby detail page: the play button takes the focus
  /// unless this page was opened on one episode, in which case the poster of
  /// that episode does (see [_focusCurrentEpisode]).
  void _focusPlay() {
    if (_isEpisode) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _playNode.canRequestFocus) _playNode.requestFocus();
    });
  }

  bool get _isEpisode => (_detail?['type']?.toString() ?? widget.seed?.type ?? '').toLowerCase() == 'episode';

  /// Cast of the item.
  ///
  /// trimemedia files the people with the title, not with the episode: asking
  /// `person/list` for an episode guid answers with an empty list (or with the
  /// names but no head shots), which is why an episode page used to have no
  /// cast row at all. The season and the show are asked in turn and the first
  /// answer that actually carries pictures wins.
  Future<void> _loadPersons() async {
    final client = _client;
    if (client == null) return;
    final detail = _detail ?? const <String, Object?>{};
    final seen = <String>{};
    final candidates = [
      widget.guid,
      _s(detail, 'ancestor_guid'),
      _s(detail, 'parent_guid'),
      widget.seed?.parentGuid,
    ].whereType<String>().where((g) => g.isNotEmpty && seen.add(g)).toList();
    var chosen = const <Map<String, Object?>>[];
    for (final guid in candidates) {
      final list = await _personsOf(client, guid);
      if (list.isEmpty) continue;
      final withPhotos = list.any((p) => _s(p, 'profile_path') != null);
      if (chosen.isEmpty || withPhotos) chosen = list;
      if (withPhotos) break;
    }
    if (!mounted || chosen.isEmpty) return;
    setState(() => _persons = chosen);
  }

  Future<List<Map<String, Object?>>> _personsOf(FnosClient client, String guid) async {
    try {
      final raw = await client.personList(guid);
      final list = raw is Map ? raw['list'] as List? ?? const [] : raw is List ? raw : const [];
      return [for (final e in _maps(list)) Map<String, Object?>.from(e)];
    } catch (e) {
      debugPrint('[fnos] persons $guid: $e');
      return const [];
    }
  }

  Future<void> _loadStreams() async {
    final client = _client;
    if (client == null) return;
    try {
      final raw = await client.streamList(widget.guid);
      final map = raw is Map ? Map<String, Object?>.from(raw) : null;
      if (map == null || !mounted) return;
      setState(() => _streams = map);
    } catch (e) {
      debugPrint('[fnos] stream list: $e');
    }
  }

  Future<void> _loadEpisodes(String guid) async {
    final client = _client;
    if (client == null) return;
    setState(() => _seasonGuid = guid);
    try {
      final raw = await client.episodeList(guid);
      final list = raw is List ? raw : raw is Map ? raw['list'] as List? ?? const [] : const [];
      if (!mounted) return;
      setState(() {
        _episodes = [for (final e in _maps(list)) Map<String, Object?>.from(e)];
      });
      if (_episodeFocusPending) {
        _episodeFocusPending = false;
        WidgetsBinding.instance.addPostFrameCallback((_) => _focusCurrentEpisode());
      }
    } catch (e) {
      debugPrint('[fnos] episode list $guid: $e');
      if (!mounted) return;
      setState(() => _episodes = const []);
    }
  }

  List<Map<String, Object?>> _orderedEpisodes(bool descending) {
    int numOf(Map<String, Object?> m, String key) => (m[key] as num?)?.toInt() ?? 0;
    final indexed = _episodes.indexed.toList()
      ..sort((a, b) {
        final bySeason = numOf(a.$2, 'season_number').compareTo(numOf(b.$2, 'season_number'));
        if (bySeason != 0) return bySeason;
        final byEpisode = numOf(a.$2, 'episode_number').compareTo(numOf(b.$2, 'episode_number'));
        return byEpisode != 0 ? byEpisode : a.$1.compareTo(b.$1);
      });
    final ordered = [for (final (_, e) in indexed) e];
    return descending ? ordered.reversed.toList() : ordered;
  }

  Future<void> _toggleEpisodeOrder() async {
    final s = AppServicesScope.read(context);
    final next = !s.settings.episodesDescending;
    debugPrint('[fnos] episode order -> ${next ? 'descending' : 'ascending'}');
    await s.updateSettings(s.settings.copyWith(episodesDescending: next));
    if (!mounted) return;
    // Sorting is a request about the row, not about the button: once the cards
    // have moved, the focus goes back to the episode the viewer was on.
    WidgetsBinding.instance.addPostFrameCallback((_) => _focusCurrentEpisode());
  }

  /// Puts focus on the card of the episode this page was opened on; the whole
  /// season can be 200 entries long, so starting at the first one means
  /// scrolling past all of them.
  void _focusCurrentEpisode() {
    if (!mounted) return;
    final target = _episodeNode.context;
    if (target == null || !_episodeNode.canRequestFocus) return;
    _episodeNode.requestFocus();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && target.mounted) revealFocused(target);
    });
  }

  FnOsItem _itemOf(Map m) => FnOsItem.from(m);

  /// Resume position in seconds, from the item itself (`ts`) with the list
  /// payload as fallback when the page was opened from a card.
  int get _resumeSeconds {
    final ts = _detail == null ? 0 : _int(_detail!, 'ts');
    final start = ts > 0 ? ts : (widget.seed?.ts ?? 0);
    if (start <= 0) return 0;
    final d = _durationSeconds;
    // Emby hides the resume button once the file is essentially over.
    return d > 0 && start >= d - 10 ? 0 : start;
  }

  int get _durationSeconds {
    final fromDetail = _detail == null ? 0 : _int(_detail!, 'duration');
    if (fromDetail > 0) return fromDetail;
    return widget.seed?.duration ?? 0;
  }

  /// trimemedia has no `MediaSources`; the stream list describes the same file
  /// in its own words. Folding it into [MediaSourceInfo] lets the details page
  /// use the very same badges and summary line as the Emby one.
  MediaSourceInfo? get _sourceInfo {
    final streams = _streams;
    if (streams == null) return null;
    final list = <MediaStream>[];
    var index = 0;
    MediaStream convert(Map raw, MediaStreamType type) => MediaStream(
          index: index++,
          type: type,
          codec: _s(raw, 'codec_name'),
          profile: _s(raw, 'profile'),
          language: _s(raw, 'language'),
          title: _s(raw, 'title') ?? _s(raw, 'display_title'),
          displayTitle: _s(raw, 'display_title'),
          channels: (raw['channels'] as num?)?.toInt(),
          channelLayout: _s(raw, 'channel_layout'),
          bitRate: (raw['bit_rate'] as num?)?.toInt(),
          width: (raw['width'] as num?)?.toInt(),
          height: (raw['height'] as num?)?.toInt(),
          videoRange: _rangeHint(raw),
          extendedVideoType: _rangeHint(raw),
        );
    for (final v in _maps(streams['video_streams'])) {
      list.add(convert(v, MediaStreamType.video));
    }
    for (final a in _maps(streams['audio_streams'])) {
      list.add(convert(a, MediaStreamType.audio));
    }
    for (final s in _maps(streams['subtitle_streams'])) {
      list.add(convert(s, MediaStreamType.subtitle));
    }
    if (list.isEmpty) return null;
    final files = _maps(streams['file_stream']);
    final file = files.isEmpty ? const <Object?, Object?>{} : files.first;
    final name = _s(file, 'file_name') ?? _s(file, 'path') ?? _s(_detail ?? const {}, 'file_name');
    return MediaSourceInfo(
      id: '',
      streams: list,
      chapters: const [],
      container: _containerOf(name),
      size: (file['size'] as num?)?.toInt(),
      path: name,
    );
  }

  /// HDR/Dolby Vision hint. trimemedia names the transfer differently across
  /// versions, so every plausible key is tried and only the recognised values
  /// are used — a plain 8-bit file simply yields null.
  static String? _rangeHint(Map raw) {
    for (final key in const ['color_transfer_type', 'color_range_type', 'hdr_type', 'dynamic_range', 'dolby_vision']) {
      final value = raw[key]?.toString().toLowerCase();
      if (value == null || value.isEmpty || value == '0' || value == 'false') continue;
      if (value.contains('dovi') || value.contains('dolby')) return 'DolbyVision';
      if (value.contains('hdr10+') || value.contains('hdr10plus')) return 'Hdr10Plus';
      if (value.contains('hlg')) return 'HyperLogGamma';
      if (value.contains('hdr')) return 'Hdr10';
    }
    return null;
  }

  static String? _containerOf(String? name) {
    if (name == null) return null;
    final dot = name.lastIndexOf('.');
    if (dot < 0 || dot == name.length - 1) return null;
    return name.substring(dot + 1).toUpperCase();
  }

  Future<void> _play({bool fromStart = false}) async {
    final detail = _detail;
    if (detail == null) return;
    await playFnOs(context, _itemOf(detail), fromStart: fromStart);
  }

  void _openEpisode(Map<String, Object?> episode) {
    final guid = _guid(episode);
    if (guid.isEmpty || guid == widget.guid) return;
    Navigator.of(context).pushReplacement(
      tvRoute(FnOsItemPage(guid: guid, seed: _itemOf(episode)), name: 'fnos:$guid'),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final s = AppServicesScope.of(context);
    final client = _client;
    final size = MediaQuery.sizeOf(context);
    final detail = _detail;
    final seed = widget.seed;
    final heading = detail == null ? seed?.displayTitle ?? '' : _heading(detail);
    final backdropPath = _s(detail ?? const {}, 'backdrops') ?? seed?.posterPath;
    final backdrop = backdropPath == null || client == null
        ? null
        : Uri.parse(client.imageUrl(backdropPath, width: 1920));

    if (_error != null && detail == null) {
      return Stack(children: [
        Positioned.fill(child: Backdrop(url: backdrop, headers: client?.imageHeaders)),
        Padding(
          padding: EdgeInsets.only(left: pageLeft, top: size.height * 0.2),
          child: _errorView(l10n),
        ),
      ]);
    }

    final source = _sourceInfo;
    final version = source == null ? null : VersionInfo(source);
    final resume = _resumeSeconds > 0 ? Duration(seconds: _resumeSeconds) : null;
    final duration = _durationSeconds > 0 ? Duration(seconds: _durationSeconds) : null;
    final type = (detail?['type']?.toString() ?? seed?.type ?? '').toLowerCase();
    final playable = type == 'movie' || type == 'video' || type == 'episode';
    final watched = detail == null
        ? (seed?.watched ?? false)
        : (detail['watched']?.toString() == '1' || detail['is_watched']?.toString() == '1');
    final overview = _s(detail ?? const {}, 'overview') ?? _s(detail ?? const {}, 'overviews');
    final episodes = _orderedEpisodes(s.settings.episodesDescending);
    final currentIndex = episodes.indexWhere((e) => _guid(e) == widget.guid);
    final parentGuid = detail == null ? null : _s(detail, 'parent_guid');

    return Stack(children: [
      Positioned.fill(child: Backdrop(url: backdrop, headers: client?.imageHeaders, drift: true)),
      if (detail == null)
        const _Loading()
      else
        PageScrollView(
          controller: _scroll,
          padding: EdgeInsets.only(top: size.height * 0.2, bottom: 120),
          children: [
            Padding(
              padding: const EdgeInsets.only(left: pageLeft, right: 700),
              child: _titleBlock(l10n, detail, heading, version, duration, resume, watched),
            ),
            const SizedBox(height: 22),
            if (overview != null)
              Padding(
                padding: const EdgeInsets.only(left: pageLeft, right: 760),
                child: OverviewText(title: heading, text: overview),
              ),
            const SizedBox(height: 34),
            Padding(
              padding: const EdgeInsets.only(left: pageLeft, right: 120),
              child: FocusZone(
                debugLabel: 'actions',
                revealsTop: true,
                child: Wrap(spacing: 18, runSpacing: 18, children: [
                  if (playable)
                    TvButton(
                      focusNode: _playNode,
                      label: resume != null
                          ? l10n.resumeTimeLeft(formatRuntime(l10n, (duration ?? resume) - resume) ?? '')
                          : l10n.play,
                      icon: Icons.play_arrow_rounded,
                      primary: true,
                      onSelect: _play,
                    ),
                  if (playable && resume != null)
                    TvButton(
                      label: l10n.fromBeginning,
                      icon: Icons.replay_rounded,
                      onSelect: () => _play(fromStart: true),
                    ),
                  if (overviewIsLong(overview)) SynopsisButton(title: heading, text: overview!),
                  if (_isEpisode && parentGuid != null && parentGuid.isNotEmpty)
                    TvButton(
                      label: l10n.goToSeries,
                      icon: Icons.tv_rounded,
                      collapsed: true,
                      onSelect: () => Navigator.of(context).pushReplacement(
                        tvRoute(FnOsItemPage(guid: parentGuid), name: 'fnos:$parentGuid'),
                      ),
                    ),
                ]),
              ),
            ),
            if (_seasons.length > 1) ...[
              const SizedBox(height: 46),
              Padding(
                padding: const EdgeInsets.only(left: pageLeft, bottom: 18),
                child: Text(l10n.seasons, style: Zt.rowTitle),
              ),
              Padding(
                padding: const EdgeInsets.only(left: pageLeft, right: 120),
                child: FocusZone(
                  debugLabel: 'fnos-seasons',
                  child: Wrap(spacing: 16, runSpacing: 16, children: [
                    for (final season in _seasons)
                      TvButton(
                        label: l10n.seasonNumber((season['season_number'] as num?)?.toInt() ?? 0),
                        icon: Icons.movie_filter_outlined,
                        primary: _seasonGuid == _guid(season),
                        onSelect: () => unawaited(_loadEpisodes(_guid(season))),
                      ),
                  ]),
                ),
              ),
            ],
            const SizedBox(height: 60),
            if (episodes.length > 1) ...[
              MediaRow(
                // Flipping the order moves every card to the opposite end of
                // the row. Rebuilding the row re-anchors it on the current
                // episode through initialIndex, the same way opening the page
                // does, instead of leaving the viewer staring at episode one.
                key: ValueKey('fnos-episodes-${s.settings.episodesDescending}'),
                left: pageLeft,
                title: _seasonTitle(l10n),
                height: Zs.landscapeWidth * 9 / 16 + 90,
                itemCount: episodes.length,
                itemExtent: Zs.landscapeWidth + Zs.cardGap,
                initialIndex: currentIndex < 0 ? null : currentIndex,
                trailingTitle: FocusZone(
                  debugLabel: 'fnos-episode-order',
                  child: RowTitleButton(
                    label: s.settings.episodesDescending ? l10n.episodesDescending : l10n.episodesAscending,
                    icon: Icons.swap_vert_rounded,
                    onSelect: () => unawaited(_toggleEpisodeOrder()),
                  ),
                ),
                itemBuilder: (context, i) {
                  final e = episodes[i];
                  final current = _guid(e) == widget.guid;
                  // On an episode page the focus lands on that episode; a tv
                  // page has no play button of its own, so it goes to the
                  // first episode instead of leaving the page unfocused.
                  final focusNode = current || (!playable && i == 0) ? _episodeNode : null;
                  final number = (e['episode_number'] as num?)?.toInt() ?? 0;
                  final title = e['title']?.toString() ?? '';
                  final length = (e['duration'] as num?)?.toInt() ?? 0;
                  return Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: FnOsLandscapeCard(
                      item: _itemOf(e),
                      title: '$number. $title',
                      subtitle: current
                          ? l10n.nowShowing
                          : length > 0
                              ? formatRuntime(l10n, Duration(seconds: length))
                              : null,
                      focusNode: focusNode,
                      onSelect: () => _openEpisode(e),
                      onPlay: () => unawaited(playFnOs(context, _itemOf(e))),
                    ),
                  );
                },
              ),
              const SizedBox(height: Zs.rowGap),
            ],
            if (_persons.isNotEmpty) CastPeopleRow(persons: _persons, client: client),
            if (version != null) _techInfo(version, source!),
          ],
        ),
    ]);
  }

  /// Big title, with the episode line and the meta/badges rows of an Emby
  /// details page. trimemedia ships no logo art, so the text title is used the
  /// same way [TitleBlock] falls back to it.
  Widget _titleBlock(L10n l10n, Map detail, String heading, VersionInfo? version, Duration? duration,
      Duration? resume, bool watched) {
    final type = detail['type']?.toString().toLowerCase() ?? '';
    final isEpisode = type == 'episode';
    final season = (detail['season_number'] as num?)?.toInt() ?? 0;
    final episode = (detail['episode_number'] as num?)?.toInt() ?? 0;
    final own = detail['title']?.toString() ?? '';
    final code = season > 0 || episode > 0 ? 'S$season E$episode' : null;
    final year = _s(detail, 'release_date');
    final vote = double.tryParse(detail['vote_average']?.toString() ?? '');
    return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      Text(heading, maxLines: 2, overflow: TextOverflow.ellipsis, style: Zt.display),
      if (isEpisode && own.isNotEmpty) ...[
        const SizedBox(height: 14),
        Text([code, own].whereType<String>().join('  ·  '), style: Zt.title),
      ],
      const SizedBox(height: 16),
      MetaLine(
        [
          if (year != null && year.length >= 4) year.substring(0, 4),
          formatRuntime(l10n, duration),
          endsAt(l10n, duration, position: resume),
        ],
        leading: [if (vote != null && vote > 0) RatingPill(vote)],
        trailing: [if (watched) const Icon(Icons.check_circle_rounded, size: 24, color: Zc.success)],
      ),
      if (version != null) ...[
        const SizedBox(height: 14),
        MediaBadges(version),
      ],
    ]);
  }

  String _heading(Map detail) {
    final seed = widget.seed;
    if (detail['type']?.toString().toLowerCase() == 'episode') {
      final tv = _s(detail, 'tv_title');
      if (tv != null) return tv;
    }
    return _s(detail, 'title') ?? seed?.displayTitle ?? '';
  }

  String _seasonTitle(L10n l10n) => _s(
        _seasons.firstWhere(
          (season) => _guid(season) == _seasonGuid,
          orElse: () => const {},
        ),
        'title',
      ) ??
      l10n.episodes;

  Widget _techInfo(VersionInfo version, MediaSourceInfo source) {
    final line = [version.summary, ?version.bitrate, ?source.container].where((e) => e.isNotEmpty).join('   ·   ');
    return Padding(
      padding: const EdgeInsets.only(left: pageLeft, top: 50, right: 120),
      child: Text(line, style: Zt.caption),
    );
  }

  Widget _errorView(L10n l10n) => Padding(
        padding: const EdgeInsets.only(right: 120),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(l10n.couldNotLoadTitle, style: Zt.headline),
          const SizedBox(height: 12),
          Text('$_error', style: Zt.body, maxLines: 3),
          const SizedBox(height: 30),
          FocusZone(
            child: TvButton(label: l10n.tryAgain, icon: Icons.refresh_rounded, autofocus: true, onSelect: _reload),
          ),
        ]),
      );
}

/// Cast row with the geometry of the Emby one: a circle head shot, the name
/// under it and the character (or job) below that.
class CastPeopleRow extends StatelessWidget {
  const CastPeopleRow({super.key, required this.persons, required this.client});

  final List<Map<String, Object?>> persons;
  final FnosClient? client;

  String? _s(Map m, String key) {
    final v = m[key]?.toString();
    return v == null || v.isEmpty || v == '0' ? null : v;
  }

  @override
  Widget build(BuildContext context) {
    // trimemedia writes the job in whatever language the metadata came in
    // ("Actor", "actor", "演员"), so nothing is dropped for having an
    // unexpected label: the director is pulled to the front - like on the Emby
    // page - and everyone else follows in server order.
    final directors = <Map<String, Object?>>[];
    final rest = <Map<String, Object?>>[];
    for (final p in persons) {
      final job = (p['job']?.toString() ?? '').toLowerCase();
      (job == 'director' ? directors : rest).add(p);
    }
    final shown = [...directors.take(1), ...rest].take(25).toList();
    if (shown.isEmpty) return const SizedBox.shrink();
    return MediaRow(
      left: pageLeft,
      title: context.l10n.castAndCrew,
      height: 260,
      itemCount: shown.length,
      itemBuilder: (context, i) {
        final p = shown[i];
        final job = _s(p, 'job') ?? '';
        final lower = job.toLowerCase();
        final role = switch (lower) {
          '' || 'actor' || 'actress' => _s(p, 'role'),
          'director' => context.l10n.director,
          _ => job,
        };
        final profile = _s(p, 'profile_path');
        final name = _s(p, 'name') ?? _s(p, 'original_name') ?? '';
        return FnOsPersonCard(
          name: name,
          role: role,
          photo: profile == null || client == null
              ? null
              : Uri.parse(client!.imageUrl(profile, width: 280)),
          headers: client?.imageHeaders,
        );
      },
    );
  }
}

class _Loading extends StatelessWidget {
  const _Loading();

  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.sizeOf(context).height * 0.2;
    return Padding(
      padding: EdgeInsets.only(left: pageLeft, top: top),
      child: const Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SkeletonBox(width: 520, height: 120),
        SizedBox(height: 24),
        SkeletonBox(width: 420, height: 28, radius: 6),
        SizedBox(height: 24),
        SkeletonBox(width: 900, height: 90, radius: 8),
      ]),
    );
  }
}
