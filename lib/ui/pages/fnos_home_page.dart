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
import '../widgets/backdrop.dart';
import '../widgets/common.dart';
import '../widgets/media_row.dart';
import '../widgets/net_image.dart';
import 'hero.dart' show HeroInfo, HeroPanel, formatRuntime;
import 'fnos_item_page.dart';

/// Landing page for 飞牛影视 (fnOS trimemedia) sessions: hero backdrop panel
/// on top (updates as focus moves), continue-watching row from play/list and a
/// poster wall of everything else.
class FnOsHomePage extends StatefulWidget {
  const FnOsHomePage({super.key});

  @override
  State<FnOsHomePage> createState() => _FnOsHomePageState();
}

class _FnOsHomePageState extends State<FnOsHomePage> {
  List<FnOsItem>? _items;
  List<FnOsItem> _resume = const [];
  String? _error;
  bool _busy = false;
  bool _heroSet = false;
  final _hero = Debounced<HeroInfo?>(null);
  final _details = <String, Map<String, Object?>>{};

  FnosClient get _client => AppServicesScope.read(context).janus.fnos!;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _reload());
  }

  @override
  void dispose() {
    _hero.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final client = _client;
      final items = <FnOsItem>[];
      for (var page = 1; page <= 6; page++) {
        final data = await client.itemList(pageSize: 60, page: page);
        final list = _rawList(data);
        if (list.isEmpty) break;
        items.addAll([for (final e in list) if (e is Map) FnOsItem.from(e)]);
        final total = data is Map ? (data['total'] as num?)?.toInt() ?? 0 : 0;
        if (items.length >= total) break;
      }
      final resume = <FnOsItem>[];
      try {
        final played = await client.playList();
        if (played is List) {
          resume.addAll([for (final e in played) if (e is Map) FnOsItem.from(e)]);
        }
      } catch (e) {
        debugPrint('[fnos] play/list: $e');
      }
      if (!mounted) return;
      setState(() {
        _items = items;
        _resume = [for (final r in resume) if (r.isResumable) r];
        _busy = false;
      });
      if (!_heroSet && items.isNotEmpty) {
        _heroSet = true;
        _focusFnos(items.first, immediate: true);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _busy = false;
      });
    }
  }

  static List _rawList(Object? data) {
    if (data is List) return data;
    if (data is Map) return data['list'] as List? ?? const [];
    return const [];
  }

  String? _s(Map m, String key) {
    final v = m[key]?.toString();
    return v == null || v.isEmpty || v == '0' ? null : v;
  }

  void _focusFnos(FnOsItem item, {bool immediate = false}) {
    _hero.set(
      HeroInfo(
        key: item.guid,
        title: item.displayTitle,
        meta: [?item.subtitle],
        rating: double.tryParse(item.voteAverage ?? ''),
      ),
      immediate: immediate,
    );
    unawaited(_heroDetail(item));
  }

  Future<void> _heroDetail(FnOsItem item) async {
    final cached = _details[item.guid];
    if (cached != null) {
      _heroFromDetail(item, cached);
      return;
    }
    try {
      final raw = await _client.itemDetail(item.guid);
      final map = raw is Map ? Map<String, Object?>.from(raw) : null;
      if (map == null || !mounted) return;
      _details[item.guid] = map;
      _heroFromDetail(item, map);
    } catch (e) {
      debugPrint('[fnos] hero detail ${item.guid}: $e');
    }
  }

  void _heroFromDetail(FnOsItem item, Map<String, Object?> map) {
    final l10n = context.l10n;
    final backdrop = _s(map, 'backdrops');
    if (backdrop == null) return;
    final seasons = (map['number_of_seasons'] as num?)?.toInt() ?? item.numberOfSeasons ?? 0;
    final episodes = (map['number_of_episodes'] as num?)?.toInt() ?? item.numberOfEpisodes ?? 0;
    final duration = (map['duration'] as num?)?.toInt() ?? item.duration ?? 0;
    final overview = _s(map, 'overview');
    _hero.set(
      HeroInfo(
        key: item.guid,
        title: item.displayTitle,
        backdrop: Uri.parse(_client.imageUrl(backdrop, width: 1280)),
        meta: [
          ?item.subtitle,
          if (seasons > 1) l10n.seasonCount(seasons),
          if (seasons <= 1 && episodes > 0) l10n.episodeCount(episodes),
          if (duration > 0 && item.type != 'tv') formatRuntime(l10n, Duration(seconds: duration)),
        ],
        rating: double.tryParse(item.voteAverage ?? ''),
        overview: overview,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final items = _items;
    final columns = AppServicesScope.of(context).settings.posterSize.columns;
    final cardW = posterGridCardWidth(MediaQuery.sizeOf(context).width, columns);
    final height = MediaQuery.sizeOf(context).height;
    final heroHeight = height * 0.44;
    final resume = _resume;
    return Scaffold(
      body: Stack(children: [
        Positioned.fill(
          child: ValueListenableBuilder(
            valueListenable: _hero,
            builder: (_, info, _) => Backdrop(url: info?.backdrop, headers: _client.imageHeaders),
          ),
        ),
        Positioned(
          left: contentLeft,
          top: 0,
          height: heroHeight,
          right: 560,
          child: Align(
            alignment: Alignment.bottomLeft,
            child: Padding(
              padding: const EdgeInsets.only(bottom: 24),
              child: ValueListenableBuilder(valueListenable: _hero, builder: (_, info, _) => HeroPanel(info: info)),
            ),
          ),
        ),
        Positioned(
          top: 60,
          right: 120,
          child: FocusZone(
            debugLabel: 'fnos-header-actions',
            child: Row(children: [
              TvButton(
                label: _busy ? l10n.fnosRefreshing : l10n.tryAgain,
                icon: Icons.refresh_rounded,
                onSelect: _reload,
              ),
              const SizedBox(width: 16),
              TvButton(
                label: l10n.signOut,
                icon: Icons.logout_rounded,
                onSelect: () => AppServicesScope.read(context).signOut(),
              ),
            ]),
          ),
        ),
        if (_error != null)
          Positioned(
            left: contentLeft,
            top: heroHeight,
            right: 120,
            child: _message(l10n.fnosLoadFailed(_error!), l10n.tryAgain, _reload),
          )
        else if (items != null && items.isEmpty)
          Positioned(
            left: contentLeft,
            top: heroHeight,
            right: 120,
            child: _message(l10n.fnosEmpty, l10n.tryAgain, _reload),
          )
        else
          Positioned.fill(
            top: heroHeight,
            child: FocusZone(
              debugLabel: 'fnos-content',
              child: CustomScrollView(
                slivers: [
                  if (resume.isNotEmpty)
                    SliverToBoxAdapter(
                      child: MediaRow(
                        title: l10n.continueWatching,
                        height: Zs.landscapeWidth * 0.5625 + 76,
                        itemCount: resume.length,
                        itemBuilder: (context, i) => _ResumeCard(
                          item: resume[i],
                          width: Zs.landscapeWidth,
                          onFocus: () => _focusFnos(resume[i]),
                        ),
                      ),
                    ),
                  SliverPadding(
                    padding: EdgeInsets.fromLTRB(contentLeft, resume.isEmpty ? 16 : 0, 120, 160),
                    sliver: SliverGrid(
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: columns,
                        mainAxisSpacing: 26,
                        crossAxisSpacing: Zs.cardGap,
                        childAspectRatio: cardW / (cardW * 1.5 + 70),
                      ),
                      delegate: SliverChildBuilderDelegate(
                        (context, i) {
                          if (items == null) return SkeletonBox(width: cardW, height: cardW * 1.5);
                          final data = items[i];
                          return _FnosCard(item: data, onFocus: () => _focusFnos(data), autofocus: i == 0 && resume.isEmpty);
                        },
                        childCount: items?.length ?? 14,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
      ]),
    );
  }

  Widget _message(String text, String action, VoidCallback onSelect) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          ConstrainedBox(constraints: const BoxConstraints(maxWidth: 900), child: Text(text, style: Zt.body)),
          const SizedBox(height: 24),
          TvButton(label: action, icon: Icons.refresh_rounded, onSelect: onSelect),
        ],
      );
}

class _FnosCard extends StatelessWidget {
  const _FnosCard({required this.item, this.onFocus, this.autofocus = false});

  final FnOsItem item;
  final VoidCallback? onFocus;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    final client = AppServicesScope.read(context).janus.fnos;
    final path = item.posterPath;
    final width = posterGridCardWidth(MediaQuery.sizeOf(context).width, AppServicesScope.of(context).settings.posterSize.columns);
    final height = width * 1.5;
    return TvFocusable(
      autofocus: autofocus,
      onFocusChange: (f) => f ? onFocus?.call() : null,
      onSelect: () => Navigator.of(context).push(
        tvRoute(FnOsItemPage(guid: item.guid, seed: item), name: 'fnos:${item.guid}'),
      ),
      builder: (context, focused) => SizedBox(
        width: width,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          FocusFrame(
            focused: focused,
            child: SizedBox(
              width: width,
              height: height,
              child: Stack(fit: StackFit.expand, children: [
                NetImage(
                  url: path == null || client == null ? null : Uri.parse(client.imageUrl(path, width: 400)),
                  headers: client?.imageHeaders,
                  width: width,
                  fallback: TitleArt(title: item.displayTitle, icon: item.icon),
                ),
                if (item.watched)
                  Positioned(
                    top: 10,
                    right: 10,
                    child: Container(
                      width: 34,
                      height: 34,
                      decoration: BoxDecoration(color: Zc.success.withValues(alpha: 0.9), shape: BoxShape.circle),
                      child: const Icon(Icons.check_rounded, size: 22, color: Colors.white),
                    ),
                  ),
              ]),
            ),
          ),
          const SizedBox(height: 12),
          Text(item.displayTitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: Zt.label.copyWith(fontSize: 22)),
          if (item.subtitle != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(item.subtitle!, style: Zt.caption.copyWith(fontSize: 18, color: Zc.textFaint)),
            ),
        ]),
      ),
    );
  }
}

/// Continue-watching card: landscape still with a progress strip.
class _ResumeCard extends StatelessWidget {
  const _ResumeCard({required this.item, required this.width, this.onFocus});

  final FnOsItem item;
  final double width;
  final VoidCallback? onFocus;

  @override
  Widget build(BuildContext context) {
    final client = AppServicesScope.read(context).janus.fnos;
    final path = item.posterPath;
    final imageH = width * 0.5625;
    final l10n = context.l10n;
    return TvFocusable(
      onFocusChange: (f) => f ? onFocus?.call() : null,
      onSelect: () => unawaited(playFnOs(context, item)),
      builder: (context, focused) => SizedBox(
        width: width,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          FocusFrame(
            focused: focused,
            child: SizedBox(
              width: width,
              height: imageH,
              child: Stack(fit: StackFit.expand, children: [
                NetImage(
                  url: path == null || client == null ? null : Uri.parse(client.imageUrl(path, width: 760)),
                  headers: client?.imageHeaders,
                  width: width,
                  fallback: TitleArt(title: item.displayTitle, icon: item.icon),
                ),
                if (item.progress != null)
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: ProgressStrip(item.progress!, height: 5),
                  ),
                Positioned(
                  top: 10,
                  left: 10,
                  child: Pill(l10n.keepWatching),
                ),
              ]),
            ),
          ),
          const SizedBox(height: 12),
          Text(item.displayTitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: Zt.label.copyWith(fontSize: 22)),
          if (item.subtitle != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(item.subtitle!, style: Zt.caption.copyWith(fontSize: 18, color: Zc.textFaint)),
            ),
        ]),
      ),
    );
  }
}
