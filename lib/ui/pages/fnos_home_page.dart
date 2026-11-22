import 'dart:async';
import 'dart:math';

import 'package:flutter/gestures.dart' show PointerScrollEvent, PointerSignalEvent;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/app_services.dart';
import '../../core/fnos/fnos_client.dart';
import '../../core/fnos/fnos_item.dart';
import '../../core/fnos/fnos_playback_bus.dart';
import '../../core/log/app_log.dart';
import '../../l10n/l10n.dart';
import '../core/input_mode.dart';
import '../core/navigation.dart';
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
import 'fnos_item_page.dart';

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
  /// page is at rest: the whole continue-watching row (its title plus a 16:9
  /// card and the caption under it) has to fit, so the same row is never rebased
  /// by the focus reveal when the D-pad walks right inside it.
  static const _rowTitleH = 50.0;
  static const _resumeRowH = Zs.landscapeWidth * 0.5625 + 76;
  static const _rowPeek = _rowTitleH + _resumeRowH + 12;

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

  /// Guards the continue-watching refetch against an out-of-order response
  /// (two playbacks finishing back-to-back, or a refresh racing [_reload]).
  int _resumeToken = 0;
  List<FnOsMediaDb>? _libs;
  final _libItems = <String, List<FnOsItem>>{};
  bool _rowsDone = false;
  String? _error;
  bool _busy = false;

  /// Hero carousel: a random pool of resources that advances every
  /// [_slideInterval]. Pointing at (or focusing) a card pauses it and shows
  /// that resource instead; it only starts again once the poster itself is
  /// hovered or focused — see [_pinSlide] and [_resumeFromHero].
  List<FnOsItem>? _slides;
  int _slideIndex = 0;
  Timer? _slideTimer;

  /// Set while the hero shows a card the user picked: the carousel is parked
  /// until the poster area is selected again.
  bool _pinned = false;
  FnOsItem? _pinnedItem;

  /// `margin: 0` + `keepVisible` so focusing a card that is already (mostly) on
  /// screen never touches the page scroll. Left/Right inside a row must not
  /// move the page at all: it used to scroll (the default policy snaps the view
  /// to the leading edge for a card ending above the viewport's bottom), which
  /// shrank the pinned poster and dragged its text up on every key press.
  final _scroll = RevealController(margin: 0, keepVisible: true);
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

  /// Hero interaction: one focusable anchor (keyboard) plus a pointer layer
  /// (click opens the shown resource). The arrows are mouse-only, so they have
  /// no focus nodes at all.
  final _heroNode = FocusNode(debugLabel: 'fnos-hero');

  /// True while the D-pad is on the hero (see [_pageKeys]).
  bool get _heroHolding => _heroNode.hasFocus;

  /// Keyboard focus on the poster: only the plate behind the info text changes.
  final _heroFocus = ValueNotifier<bool>(false);

  /// Mouse over the poster: reveals the carousel arrows.
  final _heroHover = ValueNotifier<bool>(false);

  /// Arrows are visible while the hero is focused by the D-pad or hovered.
  late final Listenable _arrows = Listenable.merge([_heroFocus, _heroHover]);

  /// Height of the invisible focus anchor pinned to the top of the page. The
  /// anchor is always mounted, even when the poster has been scrolled away, so
  /// Up from a row always has a target to return to.
  static const _heroFocusH = 44.0;

  /// Left edge of the arrows: just right of the collapsed rail, which keeps them
  /// clear of the info card (`contentLeft`).
  static const _arrowLeft = 88.0;

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
    AppLog.write('[fnos] home build hero-v10 (no indicator dots, random carousel)');
    HardwareKeyboard.instance.addHandler(_watchKey);
    // The shell keeps this page alive in an Offstage, so initState runs once:
    // a finished playback has to poke the row itself or the poster keeps the
    // position it had when the app started.
    FnosPlaybackBus.revision.addListener(_onPlaybackEnded);
    WidgetsBinding.instance.addPostFrameCallback((_) => _reload());
  }

  /// Global watcher for the pin policy: a card's own key handler consumes the
  /// arrows it uses, so the page-level handler never sees them. This one sees
  /// every press and only records the time.
  bool _watchKey(KeyEvent event) {
    if (event is! KeyUpEvent) _lastKeyMs = DateTime.now().millisecondsSinceEpoch;
    return false;
  }

  @override
  void dispose() {
    FnosPlaybackBus.revision.removeListener(_onPlaybackEnded);
    HardwareKeyboard.instance.removeHandler(_watchKey);
    _slideTimer?.cancel();
    _scroll.dispose();
    _scrollOffset.dispose();
    _heroImage.dispose();
    _hero.dispose();
    _heroNode.dispose();
    _heroFocus.dispose();
    _heroHover.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    if (_busy) return;
    _slideTimer?.cancel();
    // Any refetch already in flight is now stale.
    _resumeToken++;
    setState(() {
      _busy = true;
      _error = null;
      _resume = const [];
      _libs = null;
      _rowsDone = false;
      _libItems.clear();
      _slides = null;
      _slideIndex = 0;
      _pinned = false;
      _pinnedItem = null;
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

  void _onPlaybackEnded() {
    if (!mounted) return;
    unawaited(_refreshResume());
  }

  /// Refetches only the continue-watching row after a playback session ends.
  /// A full [_reload] would also reroll the hero carousel and rebuild every
  /// library row just because one poster's progress changed.
  Future<void> _refreshResume() async {
    if (_busy) return;
    final token = ++_resumeToken;
    try {
      final played = await _client.playList();
      if (!mounted || token != _resumeToken) return;
      if (played is! List) return;
      final resume = [
        for (final e in played)
          if (e is Map) FnOsItem.from(e),
      ].where((r) => r.isResumable).toList();
      setState(() => _resume = resume);
      AppLog.write('[fnos] resume refreshed: ${resume.length} entries');
    } catch (e) {
      debugPrint('[fnos] resume refresh: $e');
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
      _scheduleSlide();
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

  /// What the poster shows: the resource the user pointed at while a card holds
  /// the interaction, otherwise the carousel's current slide.
  FnOsItem? get _currentSlide {
    if (_pinned) return _pinnedItem;
    final s = _slides;
    if (s == null || s.isEmpty) return null;
    return s[_slideIndex % s.length];
  }

  /// One-shot chain instead of a periodic timer: a pin cancels it, so the
  /// countdown always restarts from the moment the poster is selected again.
  void _scheduleSlide() {
    _slideTimer?.cancel();
    _slideTimer = Timer(_slideInterval, _onSlideTick);
  }

  /// Advances the carousel. It stays parked while a card is pinned (the user
  /// picked it explicitly) and while the poster has been scrolled mostly away.
  void _onSlideTick() {
    if (!mounted) return;
    final slides = _slides;
    if (slides == null || slides.length < 2) return;
    if (_fullH > 0 && _scrollOffset.value > _fullH * 0.5) {
      _scheduleSlide();
      return;
    }
    if (_pinned) return; // waiting for the poster area to be selected
    _slideIndex = (_slideIndex + 1) % slides.length;
    _showSlide();
    _scheduleSlide();
  }

  /// Keyboard focus on a card pins it, but only when the D-pad caused it: the
  /// page hands the focus to the first card by itself while loading, and that
  /// must not park the carousel before the user has touched anything.
  void _pinFromKey(FnOsItem item) {
    if (DateTime.now().millisecondsSinceEpoch - _lastKeyMs > 900) return;
    _pinSlide(item);
  }

  /// A card was hovered or focused: show that resource and park the carousel.
  void _pinSlide(FnOsItem item) {
    _slideTimer?.cancel();
    if (_pinned && _pinnedItem?.guid == item.guid) return;
    _pinned = true;
    _pinnedItem = item;
    _showSlide(immediate: true);
    unawaited(_ensureDetail(item));
  }

  /// The poster area is hovered or has the D-pad focus: restart the countdown,
  /// so the carousel picks up with the next slide after [_slideInterval].
  void _resumeFromHero() {
    if (!_pinned) return;
    _pinned = false;
    _pinnedItem = null;
    _scheduleSlide();
  }

  /// Details are fetched lazily: a card only carries the list payload, and the
  /// overview/backdrop of a pinned resource is worth one request.
  Future<void> _ensureDetail(FnOsItem item) async {
    if (_details.containsKey(item.guid)) return;
    try {
      final raw = await _client.itemDetail(item.guid);
      final map = raw is Map ? Map<String, Object?>.from(raw) : null;
      if (map == null || !mounted) return;
      _details[item.guid] = map;
      if (_pinned && _pinnedItem?.guid == item.guid) _publish(_infoFor(item), immediate: true);
    } catch (e) {
      debugPrint('[fnos] pin detail ${item.guid}: $e');
    }
  }

  void _stepSlide(int delta) {
    final s = _slides;
    if (s == null || s.length < 2) return;
    // Stepping by hand leaves the pinned resource and rejoins the carousel.
    final shown = _currentSlide;
    final from = shown == null ? _slideIndex : s.indexOf(shown);
    _pinned = false;
    _pinnedItem = null;
    _slideIndex = ((from < 0 ? _slideIndex : from) + delta + s.length) % s.length;
    _showSlide(immediate: true);
    _scheduleSlide();
  }

  /// Opens the detail page of the resource the poster is showing, exactly like
  /// tapping its card in a row.
  void _openSlide() {
    final slide = _currentSlide;
    if (slide == null) return;
    Navigator.of(context).push(
      tvRoute(FnOsItemPage(guid: slide.guid, seed: slide), name: 'fnos:${slide.guid}'),
    );
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

  /// Throttled trail of the page offset, so a log shows what moved the home.
  int _lastLogMs = 0;
  double _lastLogPx = 0;

  void _logScroll(double pixels) {
    final now = DateTime.now().millisecondsSinceEpoch;
    if ((pixels - _lastLogPx).abs() < 4) return;
    if (now - _lastLogMs < 120) return;
    _lastLogMs = now;
    _lastLogPx = pixels;
    AppLog.write('[fnos] scroll px=${pixels.round()}');
  }

  /// Separate throttle for the notifications we now refuse, so a log still
  /// proves they arrived (and from which axis) without flooding it.
  int _lastSkipMs = 0;

  void _logSkip(ScrollNotification n) {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastSkipMs < 400) return;
    _lastSkipMs = now;
    AppLog.write('[fnos] skip ${n.metrics.axisDirection.name} d=${n.depth} px=${n.metrics.pixels.round()}');
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final libs = _libs;
    final resume = _resume;

    // ---- poster geometry ---------------------------------------------------
    final size = MediaQuery.sizeOf(context);
    // Full-bleed: the rail is a translucent overlay drawn on top of the page, so
    // the artwork starts at x = 0 and runs underneath it.
    final fullW = size.width.clamp(320.0, 4096.0);
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

    // `_pageKeys` is the safety net for Up: directional traversal refuses to
    // pick the hero when a row hangs off the top edge, and then the page would
    // neither scroll nor select the poster.
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: _pageKeys,
      child: Stack(children: [
      // Poster layer (bottom): pinned and full-bleed, cropped from the bottom as
      // the page scrolls.
      Positioned(
        left: 0,
        top: 0,
        right: 0,
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
            // Each row is a horizontal ListView nested *inside* this page's own
            // viewport, so its scroll notifications bubble up to this very
            // listener. Writing their `metrics.pixels` -- a horizontal offset,
            // several hundred px -- into the poster offset shrank the pinned
            // poster by that amount and dragged its text upwards on every
            // Left/Right key press ("the background turns into the poster wall
            // and scrolls up"). Only the page's own vertical viewport is
            // allowed to move the poster.
            final ad = n.metrics.axisDirection;
            final vertical = ad == AxisDirection.down || ad == AxisDirection.up;
            if (!vertical || n.depth != 0) {
              _logSkip(n);
              return false;
            }
            _lastScrollMs = DateTime.now().millisecondsSinceEpoch;
            if ((_scrollOffset.value - n.metrics.pixels).abs() > 0.5) {
              _scrollOffset.value = n.metrics.pixels;
              _logScroll(n.metrics.pixels);
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
                        itemBuilder: (context, i) => _pinArea(
                          resume[i],
                          FnOsResumeCard(
                            item: resume[i],
                            width: Zs.landscapeWidth,
                            onFocus: () => _pinFromKey(resume[i]),
                          ),
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
              // The poster is clickable and the carousel arrows float above it.
              // They live in the top layer so the rows still paint over the
              // poster's bottom edge. The keyboard anchor is a separate, always
              // mounted widget: the clickable area disappears once the poster
              // scrolls away, and losing the only focus node of this zone made
              // Up from a row a no-op.
              ValueListenableBuilder<double>(
                valueListenable: _scrollOffset,
                builder: (context, offset, _) {
                  final h = (fullH - offset).clamp(0.0, fullH);
                  final c = (offset / fullH).clamp(0.0, 1.0);
                  // The pointer layer stops where the first row begins, so it
                  // never swallows clicks meant for the cards below.
                  final hitH = (_rowTop - offset).clamp(0.0, h);
                  final arrowsOn = h > 120 && c < 0.6;
                  final panelBottom = h - _overlap - 22;
                  final arrowTop = min(h * 0.40, panelBottom - 175).clamp(16.0, max(16.0, h - 52)).toDouble();
                  return Stack(children: [
                    if (hitH > 24)
                      Positioned(
                        left: 0,
                        top: 0,
                        right: 0,
                        height: max(hitH, arrowsOn ? arrowTop + 52 : 0.0),
                        child: MouseRegion(
                          onEnter: (_) {
                            _heroHover.value = true;
                            // Selecting the poster restarts the carousel: ten
                            // seconds later it moves on to the next slide.
                            _resumeFromHero();
                          },
                          onExit: (_) => _heroHover.value = false,
                          child: Stack(children: [
                            Positioned(left: 0, top: 0, right: 0, height: hitH, child: _heroPointer()),
                            if (arrowsOn) ..._arrowLayer(arrowTop),
                          ]),
                        ),
                      ),
                    Positioned(
                      left: 0,
                      top: 0,
                      right: 0,
                      // When the poster is on screen this covers it, so Down
                      // still reaches the first row; once it is scrolled away a
                      // thin strip at the top remains for Up to land on.
                      height: max(hitH, _heroFocusH),
                      child: _heroFocusTarget(),
                    ),
                  ]);
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
      ]),
    );
  }

  /// Up must always be able to come back to the poster. Directional traversal
  /// scores the row zone against the hero anchor, so a row hanging off the top
  /// edge can leave the hero unreachable (nothing above it, so the key did
  /// nothing: neither the page scrolled nor the poster got selected). When the
  /// normal move finds no target, focus the hero directly and let
  /// [_scrollToPoster] bring the page back.
  KeyEventResult _pageKeys(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent || event.logicalKey != LogicalKeyboardKey.arrowUp) {
      return KeyEventResult.ignored;
    }
    if (_heroHolding) return KeyEventResult.ignored;
    if (ZoneNavigator.move(TraversalDirection.up)) return KeyEventResult.handled;
    if (!_heroNode.canRequestFocus) return KeyEventResult.ignored;
    _heroNode.requestFocus();
    return KeyEventResult.handled;
  }

  /// Mouse-only layer over the poster: a click opens the shown resource and a
  /// drag scrolls the page (the scroll view is a sibling underneath, so it
  /// cannot see the gesture itself).
  Widget _heroPointer() {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _openSlide,
      onVerticalDragUpdate: (d) {
        if (!_scroll.hasClients) return;
        final p = _scroll.position;
        _scroll.jumpTo((p.pixels - d.delta.dy).clamp(0.0, p.maxScrollExtent));
      },
      child: const SizedBox.expand(),
    );
  }

  /// Keyboard target of the hero. It is always mounted (see the caller), which
  /// is what lets Up from a row return to the poster at any scroll offset.
  /// Pointer events are ignored so it never steals a click from the cards.
  Widget _heroFocusTarget() {
    return IgnorePointer(
      child: FocusZone(
        debugLabel: 'fnos-hero',
        child: TvFocusable(
          focusNode: _heroNode,
          reveal: false,
          onSelect: _openSlide,
          onFocusChange: (f) {
            _heroFocus.value = f;
            // The D-pad landing on the poster restarts the carousel, exactly
            // like hovering it: ten seconds later it advances to the next one.
            if (f) _resumeFromHero();
            // The poster is not inside the scroll view, so nothing brings it
            // back into view when the D-pad returns to it from a row.
            if (f && !InputMode.isPointer) _scrollToPoster();
          },
          onKey: (event) {
            if (event is! KeyDownEvent) return KeyEventResult.ignored;
            final key = event.logicalKey;
            if (key == LogicalKeyboardKey.arrowDown) {
              _leaveHeroDown();
              return KeyEventResult.handled;
            }
            // Left/Right switch slides while the poster holds the focus; the
            // arrows themselves are mouse-only now.
            if (key == LogicalKeyboardKey.arrowLeft) {
              _stepSlide(-1);
              return KeyEventResult.handled;
            }
            if (key == LogicalKeyboardKey.arrowRight) {
              _stepSlide(1);
              return KeyEventResult.handled;
            }
            return KeyEventResult.ignored;
          },
          // The focus frame is gone: the plate behind the info text (see
          // [_heroPoster]) is the only focus indicator.
          builder: (context, focused) => const SizedBox.expand(),
        ),
      ),
    );
  }

  /// Prev/next circles. They only exist for the mouse: no focus node, no zone,
  /// and hidden until the hero is hovered or selected with the D-pad.
  List<Widget> _arrowLayer(double top) {
    return [
      Positioned(
        left: _arrowLeft,
        right: 16,
        top: top,
        height: 52,
        child: AnimatedBuilder(
          animation: _arrows,
          builder: (context, child) {
            final on = _heroFocus.value || _heroHover.value;
            return IgnorePointer(
              ignoring: !on,
              child: AnimatedOpacity(
                opacity: on ? 1 : 0,
                duration: Zm.fast,
                curve: Zm.curve,
                child: child,
              ),
            );
          },
          child: Row(children: [
            _HeroArrow(icon: Icons.chevron_left_rounded, onTap: () => _stepSlide(-1)),
            const Spacer(),
            _HeroArrow(icon: Icons.chevron_right_rounded, onTap: () => _stepSlide(1)),
          ]),
        ),
      ),
    ];
  }

  /// Down from the poster must reach the first row.
  void _leaveHeroDown() => ZoneNavigator.move(TraversalDirection.down);

  /// Brings the pinned poster back to its resting size when the D-pad lands on
  /// it, since it lives outside the scroll view and `revealFocused` cannot.
  void _scrollToPoster() {
    if (!_scroll.hasClients) return;
    final p = _scroll.position;
    if (p.pixels <= 0.5) return;
    p.animateTo(0, duration: const Duration(milliseconds: 280), curve: Curves.easeOutCubic);
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
          // `contentLeft` keeps it aligned with the row titles and cards; the
          // focus indicator is the plate behind this text, not a ring.
          Positioned(
            left: contentLeft - 20,
            right: 220,
            bottom: _overlap + 22,
            child: Opacity(
              opacity: fadeOut,
              child: Align(
                alignment: Alignment.bottomLeft,
                child: IgnorePointer(
                  child: ValueListenableBuilder<bool>(
                    valueListenable: _heroFocus,
                    builder: (_, focused, child) => AnimatedContainer(
                      duration: Zm.fast,
                      curve: Zm.curve,
                      padding: const EdgeInsets.fromLTRB(20, 14, 24, 10),
                      decoration: BoxDecoration(
                        // No ring at all: the focus indicator is the translucent
                        // plate behind the text.
                        color: focused ? const Color(0x59000000) : Colors.transparent,
                        borderRadius: BorderRadius.circular(18),
                      ),
                      child: child,
                    ),
                    child: panel,
                  ),
                ),
              ),
            ),
          ),

        ]),
      ),
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
            : _pinArea(
                items[i],
                FnOsPosterCard(item: items[i], width: w, onFocus: () => _pinFromKey(items[i])),
              ),
      ),
    );
  }

  /// Wraps a card so pointing at it also pins the poster — the mouse and the
  /// D-pad must behave the same way here. `onHover` instead of `onEnter`: a
  /// card that merely appears under a still pointer (page load, a row growing)
  /// must not steal the poster, and the scroll guard keeps a wheel scroll from
  /// flicking through the artwork.
  Widget _pinArea(FnOsItem item, Widget child) {
    return MouseRegion(
      onHover: (_) {
        if (DateTime.now().millisecondsSinceEpoch - _lastScrollMs < 350) return;
        _pinSlide(item);
      },
      child: child,
    );
  }

  /// Last page scroll tick, used by [_pinArea] to ignore hover noise.
  int _lastScrollMs = 0;

  /// Last key press seen by this page: a card only pins the poster when the
  /// D-pad brought the focus there (see [_pinFromKey]).
  int _lastKeyMs = 0;

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

/// Circular prev/next control of the hero carousel. Mouse only: the D-pad
/// switches slides while the poster itself holds the focus.
class _HeroArrow extends StatelessWidget {
  const _HeroArrow({required this.icon, required this.onTap});

  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: 52,
          height: 52,
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.22),
            shape: BoxShape.circle,
          ),
          child: Icon(icon, size: 34, color: Colors.white),
        ),
      ),
    );
  }
}
