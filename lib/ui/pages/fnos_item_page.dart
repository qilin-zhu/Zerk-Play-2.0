import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/app_services.dart';
import '../../core/fnos/fnos_client.dart';
import '../../core/fnos/fnos_item.dart';
import '../../l10n/l10n.dart';
import '../../playback/fnos_playback.dart' show playFnOs;
import '../core/navigation.dart';
import '../focus/focus_zone.dart';
import '../focus/tv_focusable.dart';
import '../theme/tokens.dart';
import '../widgets/common.dart';
import '../widgets/media_row.dart';
import '../widgets/net_image.dart';

/// Detail page for a trimemedia item: raw `item/{guid}` plus cast, stream
/// info, and season/episode lists. Episodes play directly through the fnOS
/// playback session; movies and videos get a play button.
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

  FnosClient get _client => AppServicesScope.read(context).janus.fnos!;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _reload());
  }

  String? _s(Map m, String key) {
    final v = m[key]?.toString();
    return v == null || v.isEmpty || v == '0' ? null : v;
  }

  String _guid(Map m) => m['guid']?.toString() ?? '';

  Future<void> _reload() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final client = _client;
      final detail = await client.itemDetail(widget.guid);
      final map = detail is Map ? Map<String, Object?>.from(detail) : <String, Object?>{};
      final type = (map['type']?.toString() ?? widget.seed?.type ?? '').toLowerCase();
      final seasons = <Map<String, Object?>>[];
      if (type == 'tv') {
        final raw = await client.seasonList(widget.guid);
        final list = raw is List ? raw : raw is Map ? raw['list'] as List? ?? const [] : const [];
        seasons.addAll([for (final e in list) if (e is Map) Map<String, Object?>.from(e)]);
      }
      if (!mounted) return;
      setState(() {
        _detail = map;
        _seasons = seasons;
        _busy = false;
      });

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

  Future<void> _loadPersons() async {
    try {
      final raw = await _client.personList(widget.guid);
      final list = raw is Map ? raw['list'] as List? ?? const [] : raw is List ? raw : const [];
      if (!mounted) return;
      setState(() {
        _persons = [for (final e in list) if (e is Map) Map<String, Object?>.from(e)];
      });
    } catch (e) {
      debugPrint('[fnos] persons: $e');
    }
  }

  Future<void> _loadStreams() async {
    try {
      final raw = await _client.streamList(widget.guid);
      final map = raw is Map ? Map<String, Object?>.from(raw) : null;
      if (map == null || !mounted) return;
      setState(() => _streams = map);
    } catch (e) {
      debugPrint('[fnos] stream list: $e');
    }
  }

  Future<void> _loadEpisodes(String guid) async {
    setState(() => _seasonGuid = guid);
    try {
      final raw = await _client.episodeList(guid);
      final list = raw is List ? raw : raw is Map ? raw['list'] as List? ?? const [] : const [];
      if (!mounted) return;
      setState(() {
        _episodes = [for (final e in list) if (e is Map) Map<String, Object?>.from(e)];
      });
    } catch (e) {
      debugPrint('[fnos] episode list $guid: $e');
      if (!mounted) return;
      setState(() => _episodes = const []);
    }
  }

  FnOsItem _itemOf(Map m) => FnOsItem.from(m);

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final detail = _detail;
    final type = (detail == null ? widget.seed?.type : detail['type']?.toString())?.toLowerCase() ?? '';
    final playable = type == 'movie' || type == 'video' || type == 'episode';
    return Scaffold(
      body: _error != null
          ? Padding(
              padding: EdgeInsets.only(left: contentLeft, top: 100, right: 120),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(l10n.couldNotLoadDetails(_error!), style: Zt.body),
                const SizedBox(height: 24),
                TvButton(label: l10n.tryAgain, icon: Icons.refresh_rounded, onSelect: _reload),
              ]),
            )
          : ListView(
              padding: EdgeInsets.only(bottom: 140),
              children: [
                _header(context, detail, playable),
                const SizedBox(height: 30),
                if (detail == null)
                  Padding(
                    padding: EdgeInsets.only(left: contentLeft, top: 30, right: 120),
                    child: const LinearProgressIndicator(minHeight: 3),
                  )
                else ...[
                  if (detail['overview']?.toString().isNotEmpty == true)
                    Padding(
                      padding: EdgeInsets.only(left: contentLeft, top: 6, right: 140),
                      child: Text(detail['overview']!.toString(), style: Zt.body.copyWith(height: 1.5)),
                    ),
                  if (_streams != null) ...[
                    const SizedBox(height: 30),
                    _mediaInfo(context),
                  ],
                  if (_persons.isNotEmpty) ...[
                    const SizedBox(height: 30),
                    _cast(context),
                  ],
                  if (_seasons.length > 1) ...[
                    const SizedBox(height: 36),
                    Padding(
                      padding: EdgeInsets.only(left: contentLeft, right: 120),
                      child: FocusZone(
                        debugLabel: 'fnos-seasons',
                        child: Wrap(spacing: 16, runSpacing: 16, children: [
                          for (final s in _seasons)
                            TvButton(
                              label: l10n.seasonNumber((s['season_number'] as num?)?.toInt() ?? 0),
                              primary: _seasonGuid == _guid(s),
                              icon: Icons.movie_filter_outlined,
                              onSelect: () => _loadEpisodes(_guid(s)),
                            ),
                        ]),
                      ),
                    ),
                  ],
                  if (_episodes.isNotEmpty) ...[
                    const SizedBox(height: 36),
                    Padding(
                      padding: EdgeInsets.only(left: contentLeft, right: 120, bottom: 14),
                      child: Text(l10n.episodes, style: Zt.title),
                    ),
                    FocusZone(
                      debugLabel: 'fnos-episodes',
                      child: Padding(
                        padding: EdgeInsets.only(left: contentLeft, right: 120),
                        child: Column(children: [
                          for (final e in _episodes) _episodeRow(context, e),
                        ]),
                      ),
                    ),
                  ],
                  if ((type == 'tv' || type == 'episode') && _seasons.isEmpty && _episodes.isEmpty && !_busy)
                    Padding(
                      padding: EdgeInsets.only(left: contentLeft, top: 8, right: 120),
                      child: Text(l10n.fnosEpisodesEmpty, style: Zt.body.copyWith(color: Zc.textFaint)),
                    ),
                ],
              ],
            ),
    );
  }

  String _meta(L10n l10n, Map<String, Object?> map, FnOsItem? seed) {
    final parts = <String>[];
    final date = (map['release_date'] ?? seed?.releaseDate)?.toString();
    if (date != null && date.length >= 4) parts.add(date.substring(0, 4));
    final vote = (map['vote_average'] ?? seed?.voteAverage)?.toString();
    if (vote != null && vote.isNotEmpty && vote != '0') parts.add('★ $vote');
    final seasons = (map['number_of_seasons'] as num?)?.toInt() ?? seed?.numberOfSeasons ?? 0;
    final episodes = (map['number_of_episodes'] as num?)?.toInt() ?? seed?.numberOfEpisodes ?? 0;
    if (seasons > 1) parts.add(l10n.seasonNumber(seasons));
    if (episodes > 0 && seasons > 0) parts.add(l10n.episodeCount(episodes));
    final duration = (map['duration'] as num?)?.toInt() ?? seed?.duration ?? 0;
    if (duration > 0 && seasons == 0) {
      final mins = duration ~/ 60;
      parts.add(mins >= 60 ? l10n.runtimeHoursMinutes(mins ~/ 60, mins % 60) : l10n.runtimeMinutes(mins));
    }
    return parts.join('  ·  ');
  }

  Widget _header(BuildContext context, Map<String, Object?>? detail, bool playable) {
    final client = _client;
    final seed = widget.seed;
    final title = detail == null
        ? (seed?.displayTitle ?? '')
        : ((detail['type']?.toString().toLowerCase() == 'episode' && (detail['tv_title']?.toString().isNotEmpty ?? false))
            ? detail['tv_title']!.toString()
            : detail['title']?.toString() ?? seed?.displayTitle ?? '');
    final backdrop = _s(detail ?? const {}, 'backdrops');
    final poster = _s(detail ?? const {}, 'posters') ?? seed?.posterPath;
    final watched = detail != null
        ? (detail['watched']?.toString() == '1' || detail['is_watched']?.toString() == '1')
        : (seed?.watched ?? false);
    final l10n = context.l10n;
    return Stack(
      alignment: Alignment.bottomLeft,
      children: [
        SizedBox(
          width: double.infinity,
          height: 420,
          child: Stack(fit: StackFit.expand, children: [
            NetImage(
              url: backdrop != null
                  ? Uri.parse(client.imageUrl(backdrop, width: 1200))
                  : poster != null
                      ? Uri.parse(client.imageUrl(poster, width: 1200))
                      : null,
              headers: client.imageHeaders,
              fallback: const SizedBox.shrink(),
            ),
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [
                  Color(0x66000000),
                  Color(0x00000000),
                  Zc.background,
                ], stops: [0, 0.55, 1]),
              ),
            ),
          ]),
        ),
        Padding(
          padding: EdgeInsets.only(left: contentLeft, right: 120, bottom: 24),
          child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
            if (poster != null)
              SizedBox(
                width: 150,
                height: 225,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(14),
                  child: NetImage(
                    url: Uri.parse(client.imageUrl(poster, width: 300)),
                    headers: client.imageHeaders,
                    fallback: const SizedBox.shrink(),
                  ),
                ),
              ),
            if (poster != null) const SizedBox(width: 26),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Flexible(child: Text(title, style: Zt.display.copyWith(fontSize: 44), maxLines: 2, overflow: TextOverflow.ellipsis)),
                  if (watched) ...[
                    const SizedBox(width: 14),
                    const Icon(Icons.check_circle_rounded, color: Zc.success, size: 34),
                  ],
                ]),
                if (detail != null) ...[
                  const SizedBox(height: 10),
                  Text(_meta(l10n, detail, seed), style: Zt.caption.copyWith(fontSize: 22, color: Zc.textMuted)),
                ],
                if (playable && detail != null) ...[
                  const SizedBox(height: 20),
                  FocusZone(
                    debugLabel: 'fnos-detail-actions',
                    child: TvButton(
                      label: l10n.play,
                      icon: Icons.play_arrow_rounded,
                      primary: true,
                      onSelect: () => unawaited(playFnOs(context, _itemOf(detail))),
                    ),
                  ),
                ],
              ]),
            ),
          ]),
        ),
      ],
    );
  }

  /// Media stream info from stream/list: resolution, codec, audio/subtitles.
  Widget _mediaInfo(BuildContext context) {
    final streams = _streams;
    if (streams == null) return const SizedBox.shrink();
    final videos = [for (final v in (streams['video_streams'] as List? ?? const [])) if (v is Map) v];
    final audios = [for (final v in (streams['audio_streams'] as List? ?? const [])) if (v is Map) v];
    final subs = [for (final v in (streams['subtitle_streams'] as List? ?? const [])) if (v is Map) v];
    final l10n = context.l10n;
    final lines = <String>[];
    if (videos.isNotEmpty) {
      final v = videos.first;
      final res = _s(v, 'resolution_type');
      final codec = _s(v, 'codec_name');
      final profile = _s(v, 'profile');
      final w = (v['width'] as num?)?.toInt() ?? 0;
      final h = (v['height'] as num?)?.toInt() ?? 0;
      final range = _s(v, 'color_range_type');
      final parts = [
        if (res != null) res,
        if (w > 0 && h > 0) '$w×$h',
        if (codec != null) codec.toUpperCase(),
        if (profile != null) profile,
        if (range != null) range,
      ];
      if (parts.isNotEmpty) lines.add('${l10n.infoVideo}: ${parts.join('  ·  ')}');
    }
    if (audios.isNotEmpty) {
      final codecs = {
        for (final a in audios)
          if (_s(a, 'codec_name') != null) _s(a, 'codec_name')!.toUpperCase(),
      };
      if (codecs.isNotEmpty) lines.add('${l10n.audio}: ${codecs.join(' / ')}  (${l10n.episodeCount(audios.length)})');
    }
    if (subs.isNotEmpty) lines.add('${l10n.subtitles}: ${l10n.episodeCount(subs.length)}');
    if (lines.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: EdgeInsets.only(left: contentLeft, right: 140),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(l10n.playbackInfo, style: Zt.title),
        const SizedBox(height: 10),
        for (final line in lines)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text(line, style: Zt.body.copyWith(fontSize: 20)),
          ),
      ]),
    );
  }

  /// Cast and crew row: avatar, name, and the character or job.
  Widget _cast(BuildContext context) {
    final client = _client;
    final persons = _persons;
    if (persons.isEmpty) return const SizedBox.shrink();
    return MediaRow(
      title: context.l10n.castAndCrew,
      height: 250,
      itemCount: persons.length,
      itemBuilder: (context, i) {
        final p = persons[i];
        final name = _s(p, 'name') ?? _s(p, 'original_name') ?? '';
        final job = _s(p, 'job') ?? '';
        final role = job == 'Actor' ? _s(p, 'role') : job;
        final profile = _s(p, 'profile_path');
        return SizedBox(
          width: 120,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(
              width: 110,
              height: 150,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: NetImage(
                  url: profile == null ? null : Uri.parse(client.imageUrl(profile, width: 220)),
                  headers: client.imageHeaders,
                  fallback: TitleArt(title: name, icon: Icons.person_outline_rounded),
                ),
              ),
            ),
            const SizedBox(height: 10),
            Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: Zt.label.copyWith(fontSize: 19)),
            if (role != null && role.isNotEmpty)
              Text(role, maxLines: 1, overflow: TextOverflow.ellipsis, style: Zt.caption.copyWith(fontSize: 17)),
          ]),
        );
      },
    );
  }

  Widget _episodeRow(BuildContext context, Map<String, Object?> episode) {
    final client = _client;
    final l10n = context.l10n;
    final s = (episode['season_number'] as num?)?.toInt() ?? 0;
    final e = (episode['episode_number'] as num?)?.toInt() ?? 0;
    final title = episode['title']?.toString() ?? '';
    final current = _guid(episode) == widget.guid;
    final watched = episode['watched']?.toString() == '1' || episode['is_watched']?.toString() == '1';
    final poster = _s(episode, 'poster');
    return TvFocusable(
      onSelect: () => unawaited(playFnOs(context, _itemOf(episode))),
      builder: (context, focused) => Container(
        margin: const EdgeInsets.only(bottom: 14),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: focused ? Zc.surfaceTop : Zc.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: focused ? Colors.white : Zc.outline, width: focused ? 2.5 : 1.2),
        ),
        child: Row(children: [
          SizedBox(
            width: 150,
            height: 84,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: NetImage(
                url: poster == null ? null : Uri.parse(client.imageUrl(poster, width: 300)),
                headers: client.imageHeaders,
                fallback: const SizedBox.shrink(),
              ),
            ),
          ),
          const SizedBox(width: 18),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(
                s > 0 || e > 0 ? l10n.playEpisode('S$s E$e') : title,
                style: Zt.label.copyWith(fontSize: 20, color: Zc.textFaint),
              ),
              if (title.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(title, style: Zt.body.copyWith(fontSize: 24), maxLines: 1, overflow: TextOverflow.ellipsis),
                ),
            ]),
          ),
          if (current)
            Padding(
              padding: const EdgeInsets.only(left: 10),
              child: Pill(l10n.nowShowing),
            )
          else if (watched)
            const Padding(
              padding: EdgeInsets.only(left: 10),
              child: Icon(Icons.check_rounded, color: Zc.success, size: 26),
            ),
        ]),
      ),
    );
  }
}
