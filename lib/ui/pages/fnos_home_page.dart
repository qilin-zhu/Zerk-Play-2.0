import 'dart:async';
import 'dart:math';
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import '../../app/app_services.dart';
import '../../core/fnos/fnos_client.dart';
import '../../core/fnos/fnos_item.dart';
import '../../l10n/l10n.dart';
import '../focus/focus_zone.dart';
import '../focus/tv_focusable.dart';
import '../theme/tokens.dart';
import '../widgets/backdrop.dart';
import '../widgets/common.dart';
import '../widgets/media_row.dart';
import 'hero.dart' show HeroInfo, HeroPanel, formatRuntime;
import 'fnos_cards.dart';
import 'fnos_collections_page.dart' show FnOsMediaDb;

/// Landing page for 飞牛影视 (fnOS trimemedia) sessions, matching the fnOS web
/// home: a pinned full-width hero carousel of random resources that initially
/// shows the entire 16:9 backdrop; its height shrinks (with progressive blur)
/// by the scroll offset until it is fully gone, then the continue-watching
/// row and one poster row per media library follow.
class FnOsHomePage extends StatefulWidget {
  const FnOsHomePage({super.key});

  @override
  State<FnOsHomePage> createState() => _FnOsHomePageState();
}

class _FnOsHomePageState extends State<FnOsHomePage> {
  static const _slideCount = 8;
  static const _slideInterval = Duration(seconds: 8);

  List<FnOsItem> _resume = const [];
  List<FnOsMediaDb>? _libs;
  final _libItems = <String, List<FnOsItem>>{};
  bool _rowsDone = false;
  String? _error;
  bool _busy = false;

  // Hero carousel state. `_slides` is a random pool of resources; the hero
  // shows the current slide whenever no card is focused, and auto-advances.
  List<FnOsItem>? _slides;
  int _slideIndex = 0;
  Timer? _autoTimer;
  String? _focusedGuid;
  bool _carouselHold = false;
  final _scrollOffset = ValueNotifier(0.0);
  double _fullH = 1;
  final _hero = Debounced<HeroInfo?>(null);
  final _details = <String, Map<String, Object?>>{};

  FnosClient get _client => AppServicesScope.read(context).janus.fnos!;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _reload());
    _autoTimer = Timer.periodic(_slideInterval, (_) => _autoAdvance());
  }

  @override
  void dispose() {
    _autoTimer?.cancel();
    _scrollOffset.dispose();
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
      _slides = null;
      _slideIndex = 0;
    });
    _focusedGuid = null;
    _hero.value = null;
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
      unawaited(_loadSlides(client));
      unawaited(_loadLibraryRows(client, libs));
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _busy = false;
      });
    }
  }

  /// Picks a random pool of resources for the hero carousel and fetches their
  /// details (backdrops/overview) one by one, upgrading the visible slide as
  /// each arrives.
  Future<void> _loadSlides(FnosClient client) async {
    try {
      final data = await client.itemList(pageSize: 60, page: 1, types: const ['Movie', 'TV', 'Directory', 'Video', 'LiveChannel']);
      final list = data is List ? data : data is Map ? data['list'] as List? ?? const [] : const [];
      final pool = [for (final e in list) if (e is Map) FnOsItem.from(e)]..shuffle(Random.secure());
      if (!mounted) return;
      setState(() => _slides = pool.take(_slideCount).toList());
      _showSlide(immediate: true);
      for (final s in _slides!) {
        if (!mounted) return;
        try {
          final raw = await client.itemDetail(s.guid);
          final map = raw is Map ? Map<String, Object?>.from(raw) : null;
          if (map == null || !mounted) return;
          _details[s.guid] = map;
          if (_focusedGuid == null && _currentSlide?.guid == s.guid) _hero.set(_fullInfo(s, map));
        } catch (e) {
          debugPrint('[fnos] slide detail ${s.guid}: $e');
        }
      }
    } catch (e) {
      debugPrint('[fnos] slides: $e');
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
      } catch (e) {
        debugPrint('[fnos] home row ${db.title}: $e');
        if (!mounted) return;
        setState(() => _libItems[db.guid] = const []);
      }
    }
    if (mounted) setState(() => _rowsDone = true);
  }

  FnOsItem? get _currentSlide {
    final s = _slides;
    if (s == null || s.isEmpty) return null;
    return s[_slideIndex % s.length];
  }

  void _autoAdvance() {
    if (!mounted || _focusedGuid != null || _carouselHold || _slides == null || _slides!.length < 2) return;
    if (_scrollOffset.value > _fullH * 0.3) return;
    setState(() => _slideIndex = (_slideIndex + 1) % _slides!.length);
    _showSlide();
  }

  void _stepSlide(int delta) {
    final s = _slides;
    if (s == null || s.isEmpty || _focusedGuid != null) return;
    setState(() => _slideIndex = (_slideIndex + delta + s.length) % s.length);
    _showSlide(immediate: true);
  }

  String? _s(Map m, String key) {
    final v = m[key]?.toString();
    return v == null || v.isEmpty || v == '0' ? null : v;
  }

  Uri? _posterBackdrop(FnOsItem item) {
    final path = item.posterPath;
    return path == null ? null : Uri.parse(_client.imageUrl(path, width: 1280));
  }

  HeroInfo _infoFor(FnOsItem item) {
    final cached = _details[item.guid];
    return cached == null ? _basicInfo(item) : _fullInfo(item, cached);
  }

  HeroInfo _basicInfo(FnOsItem item) => HeroInfo(
        key: item.guid,
        title: item.displayTitle,
        backdrop: _posterBackdrop(item),
        meta: [?item.subtitle],
        rating: double.tryParse(item.voteAverage ?? ''),
      );

  HeroInfo _fullInfo(FnOsItem item, Map<String, Object?> map) {
    final l10n = context.l10n;
    final backdrop = _s(map, 'backdrops');
    final seasons = (map['number_of_seasons'] as num?)?.toInt() ?? item.numberOfSeasons ?? 0;
    final episodes = (map['number_of_episodes'] as num?)?.toInt() ?? item.numberOfEpisodes ?? 0;
    final duration = (map['duration'] as num?)?.toInt() ?? item.duration ?? 0;
    return HeroInfo(
      key: item.guid,
      title: item.displayTitle,
      backdrop: backdrop == null ? _posterBackdrop(item) : Uri.parse(_client.imageUrl(backdrop, width: 1280)),
      meta: [
        ?item.subtitle,
        if (seasons > 1) l10n.seasonCount(seasons),
        if (seasons <= 1 && episodes > 0) l10n.episodeCount(episodes),
        if (duration > 0 && item.kind != 'tv') formatRuntime(l10n, Duration(seconds: duration)),
      ],
      rating: double.tryParse(item.voteAverage ?? ''),
      overview: _s(map, 'overview'),
    );
  }

  void _showSlide({bool immediate = false}) {
    if (_focusedGuid != null) return;
    final slide = _currentSlide;
    if (slide == null) return;
    _hero.set(_infoFor(slide), immediate: immediate);
  }

  void _focusFnos(FnOsItem item, {bool immediate = false}) {
    _focusedGuid = item.guid;
    _hero.set(_infoFor(item), immediate: immediate);
    unawaited(_heroDetail(item));
  }

  void _clearFocus() {
    if (_focusedGuid == null) return;
    _focusedGuid = null;
    _showSlide();
  }

  Future<void> _heroDetail(FnOsItem item) async {
    final cached = _details[item.guid];
    if (cached != null) {
      _maybeShowFullInfo(item, cached);
      return;
    }
    try {
      final raw = await _client.itemDetail(item.guid);
      final map = raw is Map ? Map<String, Object?>.from(raw) : null;
      if (map == null || !mounted) return;
      _details[item.guid] = map;
      _maybeShowFullInfo(item, map);
    } catch (e) {
      debugPrint('[fnos] hero detail ${item.guid}: $e');
    }
  }

  void _maybeShowFullInfo(FnOsItem item, Map<String, Object?> map) {
    final isFocused = _focusedGuid == item.guid;
    final isSlide = _focusedGuid == null && _currentSlide?.guid == item.guid;
    if (isFocused || isSlide) _hero.set(_fullInfo(item, map));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final libs = _libs;
    final resume = _resume;
    final width = MediaQuery.sizeOf(context).width;
    _fullH = width * 9 / 16;
    return Stack(children: [
      // Rows scroll under the collapsing hero: the content starts one full
      // backdrop-height down, so the first row always sits right below the
      // hero's shrinking bottom edge.
      Positioned.fill(
        child: FocusZone(
          debugLabel: 'fnos-content',
          child: NotificationListener<ScrollNotification>(
            onNotification: (n) {
              if ((_scrollOffset.value - n.metrics.pixels).abs() > 0.5) {
                _scrollOffset.value = n.metrics.pixels;
              }
              return false;
            },
            child: CustomScrollView(
              slivers: [
                SliverPadding(padding: EdgeInsets.only(bottom: _fullH)),
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
                        onFocusOut: _clearFocus,
                      ),
                    ),
                  ),
                // A library with no browsable items (e.g. an empty folder
                // library) contributes no row at all.
                for (final db in libs!)
                  if (_libItems[db.guid] == null || _libItems[db.guid]!.isNotEmpty)
                    SliverToBoxAdapter(child: _libRow(db)),
                const SliverPadding(padding: EdgeInsets.only(bottom: 160)),
              ],
            ),
          ),
        ),
      ),
      // Pinned hero: full 16:9 backdrop height at rest, shrinking 1:1 with the
      // scroll offset, blurred progressively, gone completely at fullH.
      Positioned(
        left: 0,
        right: 0,
        top: 0,
        child: ValueListenableBuilder(
          valueListenable: _scrollOffset,
          builder: (context, offset, _) {
            final h = (_fullH - offset).clamp(0.0, _fullH);
            if (h <= 0) return const SizedBox.shrink();
            return _heroSection(h, offset / _fullH);
          },
        ),
      ),
      if (_busy && libs == null)
        const Positioned(
          left: contentLeft,
          top: 90,
          child: SizedBox(width: 40, height: 40, child: CircularProgressIndicator(strokeWidth: 3)),
        ),
      if (_error != null)
        Positioned(
          left: contentLeft,
          top: 90,
          right: 120,
          child: _message(l10n.fnosLoadFailed(_error!), l10n.tryAgain, _reload),
        )
      else if (_rowsDone &&
          libs != null &&
          resume.isEmpty &&
          !libs.any((db) => _libItems[db.guid] == null || _libItems[db.guid]!.isNotEmpty))
        Positioned(
          left: contentLeft,
          top: 90,
          right: 120,
          child: _message(l10n.fnosEmpty, l10n.tryAgain, _reload),
        ),
    ]);
  }

  /// `h` is the current (shrinking) hero height, `c` the collapse progress
  /// 0..1. The backdrop is laid out at the FULL height and top-anchored, so
  /// the section crops it from the bottom as it shrinks.
  Widget _heroSection(double h, double c) {
    return SizedBox(
      height: h,
      child: ClipRect(
        child: Stack(fit: StackFit.expand, children: [
          Positioned(
            left: 0,
            right: 0,
            top: 0,
            height: _fullH,
            child: ImageFiltered(
              enabled: c > 0.02,
              imageFilter: ImageFilter.blur(sigmaX: 8 * c, sigmaY: 8 * c),
              child: ValueListenableBuilder(
                valueListenable: _hero,
                builder: (_, info, _) => Backdrop(url: info?.backdrop, headers: _client.imageHeaders),
              ),
            ),
          ),
          if (c < 0.6) ...[
            Opacity(
              opacity: (1 - c / 0.6).clamp(0.0, 1.0),
              child: Stack(fit: StackFit.expand, children: [
                Positioned(
                  left: contentLeft,
                  right: 560,
                  bottom: 40,
                  child: ValueListenableBuilder(valueListenable: _hero, builder: (_, info, _) => HeroPanel(info: info)),
                ),
                Positioned(
                  left: 16,
                  top: h * 0.42,
                  child: _HeroArrow(icon: Icons.chevron_left_rounded, onSelect: () => _stepSlide(-1), onHold: _setHold),
                ),
                Positioned(
                  right: 16,
                  top: h * 0.42,
                  child: _HeroArrow(icon: Icons.chevron_right_rounded, onSelect: () => _stepSlide(1), onHold: _setHold),
                ),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 14,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      for (final (i, _) in (_slides ?? const <FnOsItem>[]).indexed)
                        AnimatedContainer(
                          duration: Zm.fast,
                          width: i == _slideIndex % (_slides?.length ?? 1) ? 30 : 12,
                          height: 4,
                          margin: const EdgeInsets.symmetric(horizontal: 4),
                          decoration: BoxDecoration(
                            color: i == _slideIndex % (_slides?.length ?? 1) ? Colors.white : Colors.white.withValues(alpha: 0.35),
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                    ],
                  ),
                ),
              ]),
            ),
          ],
        ]),
      ),
    );
  }

  void _setHold(bool v) {
    _carouselHold = v;
    if (v) _clearFocus();
  }

  Widget _libRow(FnOsMediaDb db) {
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
                onFocusOut: _clearFocus,
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

/// Circular prev/next control of the hero carousel.
class _HeroArrow extends StatelessWidget {
  const _HeroArrow({required this.icon, required this.onSelect, required this.onHold});

  final IconData icon;
  final VoidCallback onSelect;
  final ValueChanged<bool> onHold;

  @override
  Widget build(BuildContext context) {
    return TvFocusable(
      autofocus: false,
      onFocusChange: onHold,
      onSelect: onSelect,
      builder: (context, focused) => Container(
        width: 52,
        height: 52,
        decoration: BoxDecoration(
          color: focused ? Colors.white.withValues(alpha: 0.9) : Colors.white.withValues(alpha: 0.25),
          shape: BoxShape.circle,
        ),
        child: Icon(icon, size: 34, color: focused ? Colors.black : Colors.white),
      ),
    );
  }
}
