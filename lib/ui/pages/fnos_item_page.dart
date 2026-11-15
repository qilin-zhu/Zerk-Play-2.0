import 'package:flutter/material.dart';

import '../../app/app_services.dart';
import '../../core/fnos/fnos_client.dart';
import '../../l10n/l10n.dart';
import '../core/navigation.dart';
import '../focus/focus_zone.dart';
import '../focus/tv_focusable.dart';
import '../theme/tokens.dart';
import '../widgets/common.dart';
import '../widgets/media_row.dart';
import '../widgets/net_image.dart';
import 'fnos_home_page.dart';

/// Detail page for a trimemedia item: raw `item/{guid}` plus season and
/// episode lists. Playback joins in a later step once the play/info → stream
/// chain has been verified against a real account.
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
  String? _seasonGuid;
  String? _error;
  bool _busy = false;

  FnosClient get _client => AppServicesScope.read(context).janus.fnos!;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _reload());
  }

  String? _s(Map<String, Object?> m, String key) {
    final v = m[key]?.toString();
    return v == null || v.isEmpty ? null : v;
  }

  String _guid(Map<String, Object?> m) => m['guid']?.toString() ?? '';

  Future<void> _reload() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final client = _client;
      final detail = await client.itemDetail(widget.guid);
      final map = detail is Map ? detail.cast<String, Object?>() : <String, Object?>{};
      final seasons = <Map<String, Object?>>[];
      if ((map['type']?.toString() ?? '') == 'tv') {
        final raw = await client.seasonList(widget.guid);
        if (raw is List) {
          seasons.addAll([for (final e in raw) if (e is Map) e.cast<String, Object?>()]);
        }
      }
      if (!mounted) return;
      setState(() {
        _detail = map;
        _seasons = seasons;
        _busy = false;
      });
      if (seasons.length == 1) {
        await _loadEpisodes(_guid(seasons.first));
      } else if (seasons.isEmpty && (map['type']?.toString() ?? '') == 'episode') {
        // An episode opened directly: show its siblings from the parent season.
        final parent = widget.seed?.parentGuid ?? _s(map, 'parent_guid') ?? '';
        if (parent.isNotEmpty) await _loadEpisodes(parent);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _busy = false;
      });
    }
  }

  Future<void> _loadEpisodes(String guid) async {
    setState(() => _seasonGuid = guid);
    try {
      final raw = await _client.episodeList(guid);
      final list = raw is List
          ? raw
          : raw is Map ? raw['list'] as List? ?? const [] : const [];
      if (!mounted) return;
      setState(() {
        _episodes = [for (final e in list) if (e is Map) e.cast<String, Object?>()];
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _episodes = const []);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final detail = _detail;
    final type = detail == null ? widget.seed?.type : detail['type']?.toString() ?? '';
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
                _header(context, detail),
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
                  if (type == 'tv' && _seasons.isNotEmpty && _episodes.isEmpty && !_busy)
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
    final episodes = (map['number_of_episodes'] as num?)?.toInt() ?? 0;
    if (seasons > 1) parts.add(l10n.seasonNumber(seasons));
    if (episodes > 0) parts.add(l10n.episodeCount(episodes));
    return parts.join('  ·  ');
  }

  Widget _header(BuildContext context, Map<String, Object?>? detail) {
    final client = _client;
    final seed = widget.seed;
    final title = detail == null
        ? (seed?.displayTitle ?? '')
        : ((detail['type']?.toString() == 'episode' && (detail['tv_title']?.toString().isNotEmpty ?? false))
            ? detail['tv_title']!.toString()
            : detail['title']?.toString() ?? seed?.displayTitle ?? '');
    final backdrop = detail?['backdrops']?.toString();
    final poster = (detail?['posters'] ?? seed?.posterPath)?.toString();
    final watched = detail != null
        ? (detail['watched']?.toString() == '1' || detail['is_watched']?.toString() == '1')
        : (seed?.watched ?? false);
    return Stack(
      alignment: Alignment.bottomLeft,
      children: [
        SizedBox(
          width: double.infinity,
          height: 420,
          child: Stack(fit: StackFit.expand, children: [
            NetImage(
              url: (backdrop == null || backdrop.isEmpty || backdrop == '0') && poster != null && poster.isNotEmpty
                  ? Uri.parse(client.imageUrl(poster, width: 1200))
                  : backdrop != null && backdrop.isNotEmpty && backdrop != '0'
                      ? Uri.parse(client.imageUrl(backdrop, width: 1200))
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
            if (poster != null && poster.isNotEmpty)
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
            if (poster != null && poster.isNotEmpty) const SizedBox(width: 26),
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
                  Text(_meta(context.l10n, detail, seed), style: Zt.caption.copyWith(fontSize: 22, color: Zc.textMuted)),
                ],
              ]),
            ),
          ]),
        ),
      ],
    );
  }

  Widget _episodeRow(BuildContext context, Map<String, Object?> episode) {
    final client = _client;
    final l10n = context.l10n;
    final s = (episode['season_number'] as num?)?.toInt() ?? 0;
    final e = (episode['episode_number'] as num?)?.toInt() ?? 0;
    final title = episode['title']?.toString() ?? '';
    final current = _guid(episode) == widget.guid;
    final watched = episode['watched']?.toString() == '1';
    final poster = episode['poster']?.toString();
    return TvFocusable(
      onSelect: () {
        // Playback arrives with the fnOS player round; for now opening an
        // episode re-opens its own detail.
        Navigator.of(context).push(tvRouteItem(episode));
      },
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
                url: poster == null || poster.isEmpty || poster == '0' ? null : Uri.parse(client.imageUrl(poster, width: 300)),
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

  Route<void> tvRouteItem(Map<String, Object?> episode) =>
      tvRoute(FnOsItemPage(guid: _guid(episode), seed: FnOsItem.from(episode)), name: 'fnos:${_guid(episode)}');
}
