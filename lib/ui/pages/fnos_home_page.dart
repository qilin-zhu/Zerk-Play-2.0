import 'dart:async';
import 'dart:math';

import 'package:flutter/gestures.dart' show PointerScrollEvent, PointerSignalEvent;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/app_services.dart';
import '../../core/fnos/fnos_client.dart';
import '../../core/fnos/fnos_item.dart';
import '../../l10n/l10n.dart';
import '../core/tv_scale.dart';
import '../focus/focus_zone.dart';
import '../focus/tv_focusable.dart';
import '../theme/tokens.dart';
import '../widgets/backdrop.dart';
import '../widgets/common.dart';
import '../widgets/media_row.dart';
import '../widgets/net_image.dart';
import 'hero.dart' show HeroInfo, HeroPanel, formatRuntime;
import 'fnos_cards.dart';
import 'fnos_collections_page.dart' show FnOsMediaDb;

/// Landing page for 飞牛影视 (fnOS trimemedia) sessions:
///   * a pinned 16:9 hero carousel of random resources that rotates every 10 s,
///   * starting right of the rail, with prev/next buttons painted on the poster
///     (also reachable with the D-pad, Left/Right switches slides),
///   * title/meta/overview overlaid on its bottom-left,
///   * a soft dissolve of its bottom edge into the page background, and
///   * continue-watching / library rows that overlap its bottom edge so rows and
///     carousel are visible together.
///
/// The scroll layer is transparent and sits on top, so the wheel scrolls from
/// anywhere and the rows paint over the poster.
class FnOsHomePage extends StatefulWidget {
  const FnOsHomePage({super.key});

  @override
  State<FnOsHomePage> createState() => _FnOsHomePageState();
}

class _FnOsHomePageState extends State<FnOsHomePage> {
  static const _slideCount = 8;
  static const _slideInterval = Duration(seconds: 10);

  /// Vertical room kept for the first row at the bottom of the viewport when the
  /// page is at rest, so a row is always visible next to the poster.
  static const _rowPeek = 216.0;

  /// Cap for the gradient that dissolves the poster's bottom edge into the page
  /// background (shorter posters use a proportionally shorter fade).
  static const _maxFade = 320.0;

  static const _bottomFade = LinearGradient(
    begin: Alignment.bottomCenter,
    end: Alignment.topCenter,
    stops: [0.0, 0.35, 0.7, 1.0],
    colors: [Zc.background, Color(0xCC0B0B12), Color(0x550B0B12), Color(0x000B0B12)],
  );

  List<FnOsItem> _resume = const [];
  List<FnOsMediaDb>? _libs;
  final _libItems = <String, List<FnOsItem>>{};
  bool _rowsDone = false;
  String? _error;
  bool _busy = false;

  // Hero carousel: a random pool of resources, auto-advancing every 10 s.
  List<FnOsItem>? _slides;
  int _slideIndex = 0;
  Timer? _autoTimer;
  final _scroll = ScrollController();
  final _scrollOffset = ValueNotifier(0.0);

  /// Panel text (title/meta/overview) of the current slide.
  final _hero = Debounced<HeroInfo?>(null);

  /// Backdrop actually painted. It only changes once the new image has been
  /// decoded, so a slide change never shows an empty (black) frame.
  final _heroImage = ValueNotifier<Uri?>(null);
  int _imageToken = 0;

  final _details = <String, Map<String, Object?>>{};

  /// Poster geometry, refreshed on every build.
  double _fullH = 1;
  double _overlap = 0;
  double _rowTop = 1;

  /// Cached image headers: a fresh map on every build would give
  /// `NetImageProvider` a new cache key and reload the poster on every frame.
  FnosClient? _headersOwner;
  Map<String, String> _headers = const {};

  FnosClient get _client => AppServicesScope.read(context).janus.fnos!;

  Map<String, String> _imageHeaders(FnosClient client) {
    if (!identical(_headersOwner, client)) {
      _headersOwner = client;
      _headers = Map<String, String>.unmodifiable(client.imageHeaders);
    }
    return _headers;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _reload());
    _autoTimer = Timer.periodic(_slideInterval, (_) => _autoAdvance());
  }

  @override
  void dispose() {
    _autoTimer?.cancel();
    _scroll.dispose();
    _scrollOffset.dispose();
    _heroImage.dispose();
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
    _hero.value = null;
    _heroImage.value = null;
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

  /// Picks a random pool of resources for the hero and fetches their details
  /// (backdrops/overview) one by one, upgrading the visible slide as each
  /// arrives.
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
          if (_currentSlide?.guid == s.guid) _publish(_fullInfo(s, map), immediate: true);
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

  /// Rotates the hero every [_slideInterval] whatever holds the focus; it only
  /// pauses once the poster has been scrolled mostly away.
  void _autoAdvance() {
    if (!mounted) return;
    final slides = _slides;
    if (slides == null || slides.length < 2) return;
    if (_fullH > 0 && _scrollOffset.value > _fullH * 0.5) return;
    setState(() => _slideIndex = (_slideIndex + 1) % slides.length);
    _showSlide();
  }

  void _stepSlide(int delta) {
    final s = _slides;
    if (s == null || s.length < 2) return;
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
    final slide = _currentSlide;
    if (slide == null) return;
    _publish(_infoFor(slide), immediate: immediate);
  }

  /// Publishes the panel text right away but swaps the backdrop only after the
  /// image has been decoded, so the hero never blinks through a black frame.
  void _publish(HeroInfo? info, {bool immediate = false}) {
    _hero.set(info, immediate: immediate);
    final url = info?.backdrop;
    if (url == null || url == _heroImage.value) return;
    final token = ++_imageToken;
    final headers = _imageHeaders(_client);
    final width = (MediaQuery.sizeOf(context).width * TvScale.decodeRatio(context)).round();
    unawaited(_preload(url, token, headers, width));
  }

  Future<void> _preload(Uri url, int token, Map<String, String> headers, int width) async {
    try {
      await precacheImage(NetImageProvider(url, decodeWidth: width, headers: headers), context);
    } catch (e) {
      debugPrint('[fnos] precache $url: $e');
    }
    if (!mounted || token != _imageToken) return;
    if (_heroImage.value != url) _heroImage.value = url;
  }

  /// Safety net for mouse wheels / trackpads: `Scrollable` normally consumes the
  /// pointer signal itself (the resolver keeps the first handler), so this only
  /// kicks in when it does not, which keeps the page scrollable in every case.
  void _onPointerSignal(PointerSignalEvent e) {
    if (e is! PointerScrollEvent || !_scroll.hasClients) return;
    final p = _scroll.position;
    if (!p.hasContentDimensions) return;
    _scroll.jumpTo((p.pixels + e.scrollDelta.dy).clamp(0.0, p.maxScrollExtent));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final libs = _libs;
    final resume = _resume;

    // ---- poster geometry ---------------------------------------------------
    final size = MediaQuery.sizeOf(context);
    const railW = Zs.railCollapsed;
    final fullW = (size.width - railW).clamp(320.0, 4096.0);
    final fullH = fullW * 9 / 16;
    _fullH = fullH;
    // Where the first row starts, and how much of the poster it covers.
    _rowTop = (size.height - _rowPeek).clamp(0.0, fullH);
    _overlap = (fullH - _rowTop).clamp(0.0, fullH);

    // Built once per build(): the scroll layer below reuses these very same
    // widget instances, so scrolling never rebuilds or re-decodes the poster.
    final posterImage = ValueListenableBuilder<Uri?>(
      valueListenable: _heroImage,
      builder: (_, url, _) => Backdrop(url: url, headers: _imageHeaders(_client), scrims: false),
    );
    final posterPanel = ValueListenableBuilder<HeroInfo?>(
      valueListenable: _hero,
      builder: (_, info, _) => HeroPanel(info: info),
    );

    return Stack(children: [
      // Poster layer (bottom): pinned, cropped from the bottom as it scrolls.
      Positioned(
        left: railW,
        top: 0,
        width: fullW,
        child: ValueListenableBuilder<double>(
          valueListenable: _scrollOffset,
          builder: (context, offset, _) {
            final h = (fullH - offset).clamp(0.0, fullH);
            if (h <= 0.5) return const SizedBox.shrink();
            return _heroPoster(h, (offset / fullH).clamp(0.0, 1.0), posterImage, posterPanel);
          },
        ),
      ),
      // Content layer (top): transparent, so the wheel/trackpad scrolls from
      // anywhere (even over the poster) and the rows paint over its bottom.
      Positioned.fill(
        child: NotificationListener<ScrollNotification>(
          onNotification: (n) {
            if ((_scrollOffset.value - n.metrics.pixels).abs() > 0.5) {
              _scrollOffset.value = n.metrics.pixels;
            }
            return false;
          },
          child: Listener(
            onPointerSignal: _onPointerSignal,
            child: Stack(fit: StackFit.expand, children: [
              CustomScrollView(
                controller: _scroll,
                physics: const ClampingScrollPhysics(),
                slivers: [
                  // Explicit spacer: an empty SliverPadding contributes no
                  // scroll extent, which would leave the page unscrollable.
                  SliverToBoxAdapter(child: SizedBox(height: _rowTop)),
                  if (resume.isNotEmpty)
                    SliverToBoxAdapter(
                      child: MediaRow(
                        title: l10n.continueWatching,
                        height: Zs.landscapeWidth * 0.5625 + 76,
                        itemCount: resume.length,
                        itemBuilder: (context, i) => FnOsResumeCard(
                          item: resume[i],
                          width: Zs.landscapeWidth,
                        ),
                      ),
                    ),
                  // A library with no browsable items (e.g. an empty folder
                  // library) contributes no row at all.
                  for (final db in libs ?? const <FnOsMediaDb>[])
                    if (_libItems[db.guid] == null || _libItems[db.guid]!.isNotEmpty)
                      SliverToBoxAdapter(child: _libRow(db)),
                  const SliverToBoxAdapter(child: SizedBox(height: 160)),
                ],
              ),
              // Carousel buttons float above the scroll view so they stay
              // clickable while the poster's bottom is covered by rows. They sit
              // in their own focus zone, a sibling of the rows' zones, so the
              // D-pad can walk from here down into the first row.
              ValueListenableBuilder<double>(
                valueListenable: _scrollOffset,
                builder: (context, offset, _) {
                  final h = (fullH - offset).clamp(0.0, fullH);
                  final c = (offset / fullH).clamp(0.0, 1.0);
                  if (h <= 0.5 || c >= 0.6) return const SizedBox.shrink();
                  return Positioned(
                    left: railW + 16,
                    right: 16,
                    top: h * 0.40,
                    height: 52,
                    child: Opacity(
                      opacity: (1 - c / 0.6).clamp(0.0, 1.0),
                      child: FocusZone(
                        debugLabel: 'fnos-hero-arrows',
                        child: Row(children: [
                          _HeroArrow(icon: Icons.chevron_left_rounded, onSelect: () => _stepSlide(-1), onStep: _stepSlide),
                          const Spacer(),
                          _HeroArrow(icon: Icons.chevron_right_rounded, onSelect: () => _stepSlide(1), onStep: _stepSlide),
                        ]),
                      ),
                    ),
                  );
                },
              ),
            ]),
          ),
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

  /// `h` is the current poster height, `c` the collapse progress. The image is
  /// laid out at the full height and top-anchored, so [ClipRect] crops it from
  /// the bottom as the page scrolls; a gradient then dissolves the cut edge into
  /// the page background instead of ending on a hard line.
  Widget _heroPoster(double h, double c, Widget image, Widget panel) {
    final fadeOut = (1 - c * 1.7).clamp(0.0, 1.0);
    final fadeH = min(_maxFade, h * 0.62);
    return SizedBox(
      height: h,
      child: ClipRect(
        child: Stack(fit: StackFit.expand, children: [
          Positioned(left: 0, right: 0, top: 0, height: _fullH, child: image),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            height: fadeH,
            child: const IgnorePointer(child: DecoratedBox(decoration: BoxDecoration(gradient: _bottomFade))),
          ),
          // Info overlaid on the poster's bottom-left, above the overlapping row.
          Positioned(
            left: 56,
            right: 220,
            bottom: _overlap + 34,
            child: Opacity(opacity: fadeOut, child: Align(alignment: Alignment.bottomLeft, child: panel)),
          ),
          // Indicator dots, right above the overlapping row.
          Positioned(
            left: 0,
            right: 0,
            bottom: _overlap + 12,
            child: Opacity(opacity: fadeOut, child: _dots()),
          ),
        ]),
      ),
    );
  }

  Widget _dots() {
    final slides = _slides ?? const <FnOsItem>[];
    final active = slides.isEmpty ? -1 : _slideIndex % slides.length;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        for (final (i, _) in slides.indexed)
          AnimatedContainer(
            duration: Zm.fast,
            width: i == active ? 30 : 12,
            height: 4,
            margin: const EdgeInsets.symmetric(horizontal: 4),
            decoration: BoxDecoration(
              color: i == active ? Colors.white : Colors.white.withValues(alpha: 0.35),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
      ],
    );
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
            : FnOsPosterCard(item: items[i], width: w),
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

/// Circular prev/next control of the hero carousel. Left/Right on the D-pad
/// switches slides while it holds the focus, Down falls through to the rows.
class _HeroArrow extends StatelessWidget {
  const _HeroArrow({required this.icon, required this.onSelect, required this.onStep});

  final IconData icon;
  final VoidCallback onSelect;

  /// -1 for the previous slide, +1 for the next one.
  final ValueChanged<int> onStep;

  @override
  Widget build(BuildContext context) {
    return TvFocusable(
      autofocus: false,
      onSelect: onSelect,
      onKey: (event) {
        if (event is KeyDownEvent || event is KeyRepeatEvent) {
          if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
            onStep(-1);
            return KeyEventResult.handled;
          }
          if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
            onStep(1);
            return KeyEventResult.handled;
          }
        }
        return KeyEventResult.ignored;
      },
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
