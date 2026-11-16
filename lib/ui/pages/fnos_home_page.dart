import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/app_services.dart';
import '../../core/fnos/fnos_client.dart';
import '../../core/fnos/fnos_item.dart';
import '../../l10n/l10n.dart';
import '../focus/focus_zone.dart';
import '../theme/tokens.dart';
import '../widgets/backdrop.dart';
import '../widgets/common.dart';
import '../widgets/media_row.dart';
import 'hero.dart' show HeroInfo, HeroPanel, formatRuntime;
import 'fnos_cards.dart';
import 'fnos_collections_page.dart' show FnOsMediaDb;

/// Landing page for 飞牛影视 (fnOS trimemedia) sessions, matching the fnOS web
/// home: hero backdrop panel on top, continue-watching as the first row, then
/// one poster row per media library (mediadb/list), each filled progressively.
class FnOsHomePage extends StatefulWidget {
  const FnOsHomePage({super.key});

  @override
  State<FnOsHomePage> createState() => _FnOsHomePageState();
}

class _FnOsHomePageState extends State<FnOsHomePage> {
  List<FnOsItem> _resume = const [];
  List<FnOsMediaDb>? _libs;
  final _libItems = <String, List<FnOsItem>>{};
  bool _rowsDone = false;
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
      _resume = const [];
      _libs = null;
      _rowsDone = false;
      _libItems.clear();
    });
    try {
      final client = _client;
      final resume = <FnOsItem>[];
      try {
        final played = await client.playList();
        if (played is List) {
          resume.addAll([for (final e in played) if (e is Map) FnOsItem.from(e)]);
        }
      } catch (e) {
        debugPrint('[fnos] play/list: $e');
      }
      final dbsRaw = await client.mediaDbList();
      final libs = [for (final e in (dbsRaw is List ? dbsRaw : const [])) if (e is Map) FnOsMediaDb.from(e)];
      if (!mounted) return;
      setState(() {
        _resume = [for (final r in resume) if (r.isResumable) r];
        _libs = libs;
        _busy = false;
      });
      _loadLibraryRows(client, libs);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _busy = false;
      });
    }
  }

  /// Fills one poster row per library, sequentially so the rows appear one by
  /// one without hammering the server. The type filter mirrors FlyNarwhal's
  /// `libraryBrowseValues`: episodes and seasons stay out of the home rows so
  /// a TV library lists shows only.
  Future<void> _loadLibraryRows(FnosClient client, List<FnOsMediaDb> libs) async {
    for (final db in libs) {
      try {
        final data = await client.itemList(
            ancestorGuid: db.guid,
            pageSize: 24,
            page: 1,
            types: const ['Movie', 'TV', 'Directory', 'Video', 'LiveChannel']);
        final list = data is List ? data : data is Map ? data['list'] as List? ?? const [] : const [];
        final items = [for (final e in list) if (e is Map) FnOsItem.from(e)];
        if (!mounted) return;
        setState(() => _libItems[db.guid] = items);
        if (!_heroSet && items.isNotEmpty) {
          _heroSet = true;
          _focusFnos(items.first, immediate: true);
        }
      } catch (e) {
        debugPrint('[fnos] home row ${db.title}: $e');
        if (!mounted) return;
        setState(() => _libItems[db.guid] = const []);
      }
    }
    if (mounted) setState(() => _rowsDone = true);
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
          if (duration > 0 && item.kind != 'tv') formatRuntime(l10n, Duration(seconds: duration)),
        ],
        rating: double.tryParse(item.voteAverage ?? ''),
        overview: overview,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final libs = _libs;
    final resume = _resume;
    final height = MediaQuery.sizeOf(context).height;
    final heroHeight = height * 0.44;
    return Stack(children: [
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
      Positioned.fill(
        top: heroHeight,
        child: libs != null
            ? FocusZone(
                debugLabel: 'fnos-content',
                child: CustomScrollView(
                  slivers: [
                    if (resume.isNotEmpty)
                      SliverToBoxAdapter(
                        child: MediaRow(
                          title: l10n.continueWatching,
                          height: Zs.landscapeWidth * 0.5625 + 76,
                          itemCount: resume.length,
                          itemBuilder: (context, i) => FnOsResumeCard(
                            item: resume[i],
                            width: Zs.landscapeWidth,
                            onFocus: () => _focusFnos(resume[i]),
                          ),
                        ),
                      ),
                    // A library with no browsable items (e.g. an empty folder
                    // library) contributes no row at all.
                    for (final db in libs)
                      if (_libItems[db.guid] == null || _libItems[db.guid]!.isNotEmpty)
                        SliverToBoxAdapter(child: _libRow(db, firstRow: resume.isEmpty && identical(db, libs.first))),
                    const SliverPadding(padding: EdgeInsets.only(bottom: 160)),
                  ],
                ),
              )
            : (_error == null
                ? const Padding(
                    padding: EdgeInsets.only(left: contentLeft, top: 30),
                    child: SizedBox(width: 40, height: 40, child: CircularProgressIndicator(strokeWidth: 3)),
                  )
                : const SizedBox.shrink()),
      ),
      if (_error != null)
        Positioned(
          left: contentLeft,
          top: heroHeight,
          right: 120,
          child: _message(l10n.fnosLoadFailed(_error!), l10n.tryAgain, _reload),
        )
      else if (_rowsDone &&
          libs != null &&
          resume.isEmpty &&
          !libs.any((db) => _libItems[db.guid] == null || _libItems[db.guid]!.isNotEmpty))
        Positioned(
          left: contentLeft,
          top: heroHeight,
          right: 120,
          child: _message(l10n.fnosEmpty, l10n.tryAgain, _reload),
        ),
    ]);
  }

  Widget _libRow(FnOsMediaDb db, {required bool firstRow}) {
    const w = Zs.posterWidth;
    final items = _libItems[db.guid];
    return MediaRow(
      title: db.title,
      height: w * 1.5 + 90,
      itemCount: items == null ? 8 : items.length,
      itemBuilder: (context, i) => Padding(
        padding: const EdgeInsets.only(top: 12),
        child: items == null
            ? SkeletonBox(width: w, height: w * 1.5)
            : FnOsPosterCard(
                item: items[i],
                width: w,
                onFocus: () => _focusFnos(items[i]),
                autofocus: firstRow && i == 0,
              ),
      ),
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
