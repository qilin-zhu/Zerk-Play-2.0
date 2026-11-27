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
import '../widgets/hero_ambience.dart';
import '../widgets/media_row.dart';
import '../widgets/net_image.dart';
import '../widgets/rows_scroll_view.dart';
import 'hero.dart' show HeroInfo, HeroPanel, formatRuntime;
import 'fnos_cards.dart';
import 'fnos_collections_page.dart' show FnOsMediaDb;
import 'fnos_item_page.dart';

/// Landing page for 飞牛影视 (fnOS trimemedia) sessions.
///
/// The stage is the same one the Emby home uses, deliberately: a full-bleed
/// 16:9 poster pinned to the top that never moves, one row of media on screen at
/// a time, and the artwork washed behind the whole page. The two homes are
/// supposed to be the same product - only the API underneath differs - so the
/// geometry, the arrow alignment, the text placement and the carousel policy
/// are copied from [HomePage] rather than rediscovered here.
///
/// Rows page by index, never by free scrolling: the D-pad and the mouse wheel
/// both just move to the next row, and the row that owns the focus is the only
/// one painted. The poster therefore stays exactly where it is while the reader
/// walks down the page.
class FnOsHomePage extends StatefulWidget {
  const FnOsHomePage({super.key});

  @override
  State<FnOsHomePage> createState() => _FnOsHomePageState();
}

enum _RowKind { resume, library }

/// One row of the page. Instances are built once per [_FnOsHomePageState._reload]
/// and reused for the life of that load, so the [GlobalKey]s hanging off them
/// (layout anchor, focus zone) survive every rebuild.
class _Row {
  _Row.resume()
      : kind = _RowKind.resume,
        db = null;

  _Row.library(this.db) : kind = _RowKind.library;

  final _RowKind kind;
  final FnOsMediaDb? db;
}

class _FnOsHomePageState extends State<FnOsHomePage> {
  static const _slideCount = 8;
  static const _slideInterval = Duration(seconds: 10);

  /// One carousel draw: a page of the library. Small enough that a random page
  /// is a genuine slice of the collection instead of "the whole library".
  static const _slidePageSize = 24;

  /// Random pages fetched on top of page 1. trimemedia only sorts by
  /// `create_time`, so the only way to draw from the whole collection is to
  /// walk to other pages; two extra pages give the shuffle something to work
  /// with without turning the draw into eight round-trips.
  static const _slideExtraPages = 2;

  /// Title block of a row: 18 px bottom padding + the text line.
  static const _rowTitleH = 48.0;

  /// Rendered height of a row's card area. The poster row keeps the slack the
  /// focus scale and the caption need; the continue-watching row is 16:9.
  static const _resumeRowH = Zs.landscapeWidth * 0.5625 + 96;
  static const _posterRowH = Zs.posterWidth * 1.5 + 100;

  /// Cap for the gradient that dissolves the poster's bottom edge into the page
  /// background.
  static const _maxFade = 320.0;

  /// Height of the invisible focus anchor pinned to the top of the page. The
  /// anchor is always mounted, so Up from a row always has a target even when
  /// the poster is partly covered by the row slot.
  static const _heroFocusH = 44.0;

  static const _heroArrowSize = 52.0;

  /// Arrows and hero text line up with the row titles and cards instead of
  /// floating left of them: the left circle is the first thing on the artwork
  /// and the title starts right after it.
  static const _arrowLeft = contentLeft;
  static const _heroTextLeft = _arrowLeft + _heroArrowSize + 14;

  List<FnOsItem> _resume = const [];

  /// Guards the continue-watching refetch against an out-of-order response
  /// (two playbacks finishing back-to-back, or a refresh racing [_reload]).
  int _resumeToken = 0;
  List<FnOsMediaDb>? _libs;
  List<_Row>? _rows;
  final _libItems = <String, List<FnOsItem>>{};
  bool _rowsDone = false;
  String? _error;
  bool _busy = false;

  /// Index of the only row that is on screen. Everything else stays mounted -
  /// so its focus nodes and horizontal offset survive - but paints nothing.
  int _activeRow = 0;

  /// One anchor per row, used to measure the heights that decide how far the
  /// list has to travel to bring that row into the slot.
  final _rowAnchors = <_Row, GlobalKey>{};

  /// Focus zone of each row. Up/Down between rows is decided here by row
  /// index, so the D-pad can never wander off to the side rail from a row that
  /// has a neighbour above it.
  final _rowZoneKeys = <_Row, GlobalKey>{};

  /// Hero carousel: a pool drawn randomly across the whole library that
  /// advances every [_slideInterval]. Pointing at (or focusing) a card pauses
  /// it and shows that resource instead; the poster being hovered or focused
  /// starts it again - see [_pinSlide] and [_resumeFromHero].
  List<FnOsItem>? _slides;
  int _slideIndex = 0;
  Timer? _slideTimer;

  /// Bumped on every carousel fetch, so a reply from a draw that started before
  /// a reload cannot put the previous library's posters back on the hero.
  int _carouselToken = 0;

  /// Set while the hero shows a card the user picked: the carousel is parked
  /// until the poster area is selected again.
  bool _pinned = false;
  FnOsItem? _pinnedItem;

  /// `margin: 0` + `keepVisible` so focusing a card that is already (mostly) on
  /// screen never touches the page scroll. Left/Right inside a row must not
  /// move the page at all.
  final _scroll = RevealController(margin: 0, keepVisible: true);

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

  /// Keyboard focus on the poster: only the shade gets a step darker.
  final _heroFocus = ValueNotifier<bool>(false);

  /// Mouse over the poster: reveals the carousel arrows.
  final _heroHover = ValueNotifier<bool>(false);

  /// Arrows are visible while the hero is focused by the D-pad or hovered.
  late final Listenable _arrows = Listenable.merge([_heroFocus, _heroHover]);

  /// Last page movement, used to ignore hover events caused by cards moving
  /// under a still pointer.
  int _lastScrollMs = 0;

  /// Last key press seen by this page: a card only pins the poster when the
  /// D-pad brought the focus there (see [_focusKey]).
  int _lastKeyMs = 0;

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
    AppLog.write('[fnos] home build hero-v11 (emby stage, one row at a time)');
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
    _carouselToken++;
    setState(() {
      _busy = true;
      _error = null;
      _resume = const [];
      _libs = null;
      _rows = null;
      _rowsDone = false;
      _libItems.clear();
      _rowAnchors.clear();
      _rowZoneKeys.clear();
      _activeRow = 0;
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
        _rows = _buildRows(libs);
        _busy = false;
      });
      unawaited(_loadCarousel(client));
      unawaited(_loadLibraryRows(client, libs));
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _busy = false;
      });
    }
  }

  /// Resume row first, then one row per library. Built once per load so the
  /// keys hanging off the [_Row]s survive the rebuilds that follow.
  List<_Row> _buildRows(List<FnOsMediaDb> libs) => [
        _Row.resume(),
        for (final db in libs) _Row.library(db),
      ];

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

  /// Fills the carousel from a fresh random draw across the whole library.
  ///
  /// trimemedia sorts by `create_time DESC` and nothing else, so page 1 is
  /// "what was added last" - a fixed window that barely changes between
  /// launches. Shuffling only that window (the old behaviour) put the same
  /// handful of titles on the poster every time, which read as a cached image.
  /// The draw therefore walks to other pages of the library as well, then
  /// shuffles the union, exactly like the Emby home's `SortBy=Random`.
  Future<void> _loadCarousel(FnosClient client) async {
    final token = ++_carouselToken;
    try {
      const types = ['Movie', 'TV'];
      final first = await client.itemList(pageSize: _slidePageSize, page: 1, types: types);
      final total = first is Map ? (first['total'] as num?)?.toInt() ?? 0 : 0;
      final pages = max(1, (total / _slidePageSize).ceil());
      final lists = <List<Object?>>[_listOf(first)];
      final picked = <int>{1};
      final rnd = Random.secure();
      for (var i = 0; i < _slideExtraPages && pages > 1; i++) {
        final page = 1 + rnd.nextInt(pages);
        if (!picked.add(page)) continue;
        try {
          final more = _listOf(await client.itemList(pageSize: _slidePageSize, page: page, types: types));
          if (more.isNotEmpty) lists.add(more);
        } catch (e) {
          // A server that will not go past page 1 still gets a carousel.
          AppLog.write('[fnos] carousel page $page/$pages: $e');
        }
      }
      final seen = <String>{};
      final all = <FnOsItem>[
        for (final list in lists)
          for (final e in list)
            if (e is Map)
              if (seen.add('${e['guid'] ?? e['name']}')) FnOsItem.from(e),
      ];
      if (!mounted || token != _carouselToken) return;
      // The poster is a frame of the artwork, so an entry with no picture at
      // all would be a grey plate; entries that have one are preferred, and a
      // library where nothing does still rotates.
      final withArt = [for (final i in all) if (i.posterPath != null) i];
      final pool = (withArt.length >= 2 ? withArt : all)..shuffle(rnd);
      if (pool.length < 2) {
        AppLog.write('[fnos] carousel: random draw left ${pool.length}');
        return;
      }
      AppLog.write('[fnos] carousel: ${pool.length} of $total over $pages pages, first ${pool.first.displayTitle}');
      _setSlides(pool, immediate: true);
      // Real 16:9 backdrops come from the detail endpoint, one request per
      // slide; the visible one is upgraded as soon as its reply lands.
      for (final s in _slides ?? const <FnOsItem>[]) {
        if (!mounted || token != _carouselToken) return;
        if (_details.containsKey(s.guid)) continue;
        try {
          final raw = await client.itemDetail(s.guid);
          final map = raw is Map ? Map<String, Object?>.from(raw) : null;
          if (map == null || !mounted || token != _carouselToken) return;
          _rememberDetail(s.guid, map);
          if (_currentSlide?.guid == s.guid) _publish(_fullInfo(s, map), immediate: true);
        } catch (e) {
          debugPrint('[fnos] slide detail ${s.guid}: $e');
        }
      }
    } catch (e) {
      debugPrint('[fnos] carousel: $e');
      AppLog.write('[fnos] carousel failed: $e');
    }
  }

  static List<Object?> _listOf(Object? data) =>
      data is List ? data : data is Map ? (data['list'] as List?) ?? const [] : const [];

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

  // ---- carousel -----------------------------------------------------------

  /// Cuts the pool down to [_slideCount], starts the rotation and shows its
  /// first entry - unless a card is parked on the poster, in which case the
  /// pool is swapped in silently and takes over once the pointer leaves.
  void _setSlides(List<FnOsItem> pool, {required bool immediate}) {
    _slides = pool.take(_slideCount).toList();
    _slideIndex = 0;
    _scheduleSlide();
    if (_pinned) return;
    _showSlide(immediate: immediate);
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
  /// picked it explicitly) and restarts from a fresh draw at the end of the
  /// pool instead of replaying the same eight posters.
  void _onSlideTick() {
    if (!mounted) return;
    final slides = _slides;
    if (slides == null || slides.length < 2) return;
    if (_pinned) return; // waiting for the poster area to be selected
    if (_slideIndex + 1 >= slides.length) {
      // Scheduled first: if the draw fails, the old pool simply starts over.
      _scheduleSlide();
      unawaited(_loadCarousel(_client));
      return;
    }
    _slideIndex++;
    _showSlide();
    _scheduleSlide();
  }

  /// Keyboard focus on a card pins it, but only when the D-pad caused it: the
  /// page hands the focus to the first card by itself while loading, and that
  /// must not park the carousel before the user has touched anything.
  void _focusKey(FnOsItem item) {
    if (DateTime.now().millisecondsSinceEpoch - _lastKeyMs > 900) return;
    _pinSlide(item);
  }

  /// Mouse hover on a card pins the poster, unless the page is moving: a card
  /// sliding under a still pointer must not flicker the artwork.
  void _hoverCard(FnOsItem item) {
    if (DateTime.now().millisecondsSinceEpoch - _lastScrollMs < 350) return;
    _pinSlide(item);
  }

  /// A card was hovered or focused: show that resource and park the carousel.
  void _pinSlide(FnOsItem item) {
    if (_pinned && _pinnedItem?.guid == item.guid) return;
    _slideTimer?.cancel();
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

  /// Keeps the detail cache bounded. The pool rolls over every eight slides and
  /// every hovered card asks for its own payload, so without a cap the map would
  /// hold every detail this session has ever shown; the pinned one is what the
  /// panel is reading right now, so it stays.
  void _rememberDetail(String guid, Map<String, Object?> map) {
    if (_details.length > 160) _details.removeWhere((k, _) => k != _pinnedItem?.guid && k != guid);
    _details[guid] = map;
  }

  /// Details are fetched lazily: a card only carries the list payload, and the
  /// overview/backdrop of a pinned resource is worth one request.
  Future<void> _ensureDetail(FnOsItem item) async {
    if (_details.containsKey(item.guid)) return;
    try {
      final raw = await _client.itemDetail(item.guid);
      final map = raw is Map ? Map<String, Object?>.from(raw) : null;
      if (map == null || !mounted) return;
      _rememberDetail(item.guid, map);
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
    _slideIndex = (((from < 0 ? _slideIndex : from) + delta) % s.length + s.length) % s.length;
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
    // trimemedia reports `runtime` in minutes; `duration` is seconds and comes
    // back as 0 for most movies, so it cannot be the only source.
    final seconds = (map['duration'] as num?)?.toInt() ?? item.duration ?? 0;
    final minutes = (map['runtime'] as num?)?.toInt() ?? item.runtime ?? 0;
    final runtime = seconds > 0 ? Duration(seconds: seconds) : minutes > 0 ? Duration(minutes: minutes) : null;
    final genres = [
      for (final g in (map['genres'] as List? ?? const [])) g?.toString() ?? '',
    ].where((g) => g.isNotEmpty).take(3).join(', ');
    return HeroInfo(
      key: item.guid,
      title: item.displayTitle,
      backdrop: backdrop == null ? _posterBackdrop(item) : Uri.parse(_client.imageUrl(backdrop, width: 1280)),
      meta: [
        ?item.subtitle,
        if (seasons > 1) l10n.seasonCount(seasons),
        if (seasons <= 1 && episodes > 0) l10n.episodeCount(episodes),
        if (runtime != null && item.kind != 'tv') formatRuntime(l10n, runtime),
        if (genres.isNotEmpty) genres,
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

  // ---- rows ---------------------------------------------------------------

  double _peekOf(_Row row) =>
      _rowTitleH + (row.kind == _RowKind.resume ? _resumeRowH : _posterRowH) + Zs.rowGap;

  /// Whether this row can be the one on screen: the continue-watching row only
  /// when something is actually resumable, a library row while it is loading
  /// (its skeleton counts) or once it holds items.
  bool _rowShows(_Row row) {
    if (row.kind == _RowKind.resume) return _resume.isNotEmpty;
    final items = _libItems[row.db!.guid];
    return items == null || items.isNotEmpty;
  }

  /// The row to show: [_activeRow] when it is still there and still has
  /// something in it, otherwise the first row that does. Rows resolve out of
  /// order, so the active one going empty has to hand over instead of leaving
  /// the page blank.
  int _activeRowFor(List<_Row> rows) {
    if (rows.isEmpty) return 0;
    final start = _activeRow.clamp(0, rows.length - 1);
    if (_rowShows(rows[start])) return start;
    for (var i = 0; i < rows.length; i++) {
      if (_rowShows(rows[i])) return i;
    }
    return start;
  }

  /// One row of the page. Only [active] paints and takes the pointer; the rest
  /// keep their state (focus nodes, horizontal scroll) but are invisible, which
  /// is what lets the poster stay fixed while the reader moves down.
  Widget _rowSlot(_Row row, int i, int active) {
    final on = i == active;
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onFocusChange: (f) {
        if (!f || _activeRow == i) return;
        setState(() => _activeRow = i);
        WidgetsBinding.instance.addPostFrameCallback((_) => _pinActiveRow());
      },
      child: IgnorePointer(
        ignoring: !on,
        child: AnimatedOpacity(
          opacity: on ? 1 : 0,
          duration: Zm.normal,
          curve: Zm.curve,
          child: KeyedSubtree(
            key: _rowAnchors.putIfAbsent(row, () => GlobalKey()),
            child: _buildRow(row, autofocus: on),
          ),
        ),
      ),
    );
  }

  /// Scrolls the list just enough to put the active row in the slot. Heights
  /// come from the laid-out rows themselves, so a row that is still a skeleton
  /// is measured as it is.
  void _pinActiveRow() {
    final rows = _rows;
    if (rows == null || !mounted || !_scroll.hasClients) return;
    final active = _activeRowFor(rows);
    var target = 0.0;
    for (var i = 0; i < active; i++) {
      final box = _rowAnchors[rows[i]]?.currentContext?.findRenderObject();
      if (box is RenderBox) target += box.size.height;
    }
    final p = _scroll.position;
    if (!p.hasContentDimensions) return;
    target = target.clamp(0.0, p.maxScrollExtent);
    if ((p.pixels - target).abs() < 0.5) return;
    p.animateTo(target, duration: const Duration(milliseconds: 280), curve: Curves.easeOutCubic);
  }

  /// Mouse wheel: the next/previous row. Driven by the focus, exactly like the
  /// D-pad, because the rows themselves never scroll freely.
  void _moveRow(int delta) {
    final rows = _rows;
    if (rows == null || rows.isEmpty) return;
    final active = _activeRowFor(rows);
    var i = active + delta;
    while (i >= 0 && i < rows.length && !_rowShows(rows[i])) {
      i += delta;
    }
    if (i < 0 || i >= rows.length) return;
    _focusRow(rows[i]);
  }

  /// Hands the keyboard to [row], keeping the row's own remembered card so the
  /// reader comes back to the item they left on.
  void _focusRow(_Row row) {
    final key = _rowZoneKeys[row];
    final zone = key == null ? null : FocusZone.nodeOf(key);
    if (zone == null) return;
    final i = _rows?.indexOf(row) ?? -1;
    if (i >= 0 && i != _activeRow) setState(() => _activeRow = i);
    ZoneNavigator.enter(zone);
    WidgetsBinding.instance.addPostFrameCallback((_) => _pinActiveRow());
  }

  /// Up must always be able to come back to the poster, and Down must never
  /// hand the D-pad to the floating rail. Up/Down between rows is resolved by
  /// row index, never by directional traversal: only one row is painted at a
  /// time and the rail sits over their left edge, which is exactly the
  /// situation where the geometric search picks a rail icon.
  KeyEventResult _pageKeys(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    final up = key == LogicalKeyboardKey.arrowUp;
    final down = key == LogicalKeyboardKey.arrowDown;
    if (!up && !down) return KeyEventResult.ignored;
    if (_heroNode.hasFocus) return KeyEventResult.ignored;
    final rows = _rows;
    if (rows == null || rows.isEmpty) return KeyEventResult.ignored;
    final active = _activeRowFor(rows);
    final step = up ? -1 : 1;
    var i = active + step;
    while (i >= 0 && i < rows.length && !_rowShows(rows[i])) {
      i += step;
    }
    if (i >= 0 && i < rows.length) {
      _focusRow(rows[i]);
      return KeyEventResult.handled;
    }
    if (!up) return KeyEventResult.handled;
    if (!_heroNode.canRequestFocus) return KeyEventResult.ignored;
    _heroNode.requestFocus();
    return KeyEventResult.handled;
  }

  /// Safety net for mouse wheels / trackpads: one notch means "next row" /
  /// "previous row", exactly like the D-pad.
  void _onPointerSignal(PointerSignalEvent e) {
    if (e is! PointerScrollEvent) return;
    if (e.scrollDelta.dy.abs() < 1) return;
    _moveRow(e.scrollDelta.dy > 0 ? 1 : -1);
  }

  // ---- build --------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final libs = _libs;
    final rows = _rows ?? const <_Row>[];

    // ---- poster geometry ---------------------------------------------------
    final size = MediaQuery.sizeOf(context);
    // Full-bleed: the rail is a translucent overlay drawn on top of the page, so
    // the artwork starts at x = 0 and runs underneath it.
    final fullW = size.width.clamp(320.0, 4096.0);
    final fullH = fullW * 9 / 16;
    _fullH = fullH;
    // The poster never moves; only the row slot does, and its distance from the
    // bottom edge comes from the row that is currently in it.
    final active = _activeRowFor(rows);
    // Before the rows exist the slot still has to be reserved: laying the text
    // out against the bottom edge and then shoving it up 80 px when the first
    // row arrives is a jump you see on every load.
    final peek = rows.isEmpty ? _rowTitleH + _posterRowH + Zs.rowGap : _peekOf(rows[active]);
    _rowTop = (size.height - peek).clamp(0.0, fullH);
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

    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: _pageKeys,
      child: ColoredBox(
        // Below the poster the rows sit on plain background, and that has to be
        // painted even while they load — the ambience layer is only a tint of it.
        color: Zc.background,
        child: Stack(fit: StackFit.expand, children: [
          // Ambience layer (bottom): the artwork that is on the poster right
          // now, blurred and stretched behind the whole page.
          Positioned.fill(
            child: ValueListenableBuilder<Uri?>(
              valueListenable: _heroImage,
              builder: (_, url, _) => HeroAmbience(url: url, headers: _imageHeaders(_client)),
            ),
          ),
          // Poster layer: pinned and full-bleed, cropped only by the fade.
          Positioned(
            left: 0,
            top: 0,
            right: 0,
            child: _heroPoster(fullH, posterImage, posterPanel),
          ),
          // Content layer (top): transparent, so the rows paint over the
          // poster's bottom edge.
          Positioned.fill(
            child: NotificationListener<ScrollNotification>(
              onNotification: (n) {
                // Each row is a horizontal ListView nested *inside* this page's
                // own viewport, so its scroll notifications bubble up here too.
                // Only the page's own vertical viewport may touch the hover
                // guard.
                final ad = n.metrics.axisDirection;
                final vertical = ad == AxisDirection.down || ad == AxisDirection.up;
                if (!vertical || n.depth != 0) return false;
                _lastScrollMs = DateTime.now().millisecondsSinceEpoch;
                return false;
              },
              child: Listener(
                onPointerSignal: _onPointerSignal,
                child: Stack(fit: StackFit.expand, children: [
                  RowsScrollView(
                    controller: _scroll,
                    // Paged by [_moveRow], never by dragging: the row slot has
                    // to stay where it is.
                    physics: const NeverScrollableScrollPhysics(),
                    // Slack under the last row so it can reach the slot too.
                    bottom: size.height,
                    top: _rowTop,
                    children: [
                      for (final (i, row) in rows.indexed) _rowSlot(row, i, active),
                    ],
                  ),
                  _heroOverlay(fullH),
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
          else if (_rowsDone && libs != null && !rows.any(_rowShows))
            Positioned(
              left: contentLeft,
              top: 90,
              right: 120,
              child: _message(l10n.fnosEmpty, l10n.tryAgain, _reload),
            ),
        ]),
      ),
    );
  }

  /// `h` is the poster height, which is now constant: the artwork is a fixed
  /// backdrop and the rows move over it.
  ///
  /// The dissolve is a mask on the artwork itself (`BlendMode.dstIn`), not a
  /// sheet of background colour painted over it. Masking to transparent lets
  /// the ambience show through, so the poster and the page are one continuous
  /// surface and the artwork colours the whole screen.
  Widget _heroPoster(double h, Widget image, Widget panel) {
    final fadeH = min(_maxFade, h * 0.62);
    final fade = heroFadeMask(height: h, fadeHeight: fadeH);
    return SizedBox(
      height: h,
      child: ClipRect(
        child: Stack(fit: StackFit.expand, children: [
          Positioned.fill(
            // The mask is a saveLayer, and a saveLayer whose bottom edge lands
            // on the visible cut can leave a one-pixel row of its own. Two
            // extra pixels hang below the clip, so the layer's edge is outside
            // the picture and only a plain clip is left at the cut.
            child: OverflowBox(
              alignment: Alignment.topCenter,
              minHeight: h + 2,
              maxHeight: h + 2,
              child: ShaderMask(
                blendMode: BlendMode.dstIn,
                shaderCallback: (rect) => fade.createShader(rect),
                child: Stack(fit: StackFit.expand, children: [
                  Positioned(left: 0, right: 0, top: 0, height: _fullH, child: image),
                ]),
              ),
            ),
          ),
          // The shade sits on the artwork itself, not on the text: a pair of
          // full-bleed gradients that die out well inside the frame, so the
          // darkening belongs to the picture instead of being a box drawn
          // behind the type.
          Positioned.fill(
            child: IgnorePointer(
              child: ValueListenableBuilder<bool>(
                valueListenable: _heroFocus,
                builder: (_, focused, _) => _heroShade(focused),
              ),
            ),
          ),
          // Info overlaid on the poster's bottom-left, right after the prev
          // arrow and above the overlapping row.
          Positioned(
            left: _heroTextLeft,
            right: 220,
            bottom: _overlap + 22,
            child: IgnorePointer(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(0, 16, 40, 12),
                child: panel,
              ),
            ),
          ),
        ]),
      ),
    );
  }

  /// Darkness under the hero text, painted across the whole artwork.
  ///
  /// Two full-bleed gradients: one rising from the bottom edge, one sweeping in
  /// from the left. Both reach zero opacity well before the opposite side, so
  /// the result reads as the poster's own dark corner - no edge, corner or fill
  /// the eye can recognise as "a box behind the text".
  Widget _heroShade(bool focused) {
    return AnimatedContainer(
      duration: Zm.normal,
      curve: Zm.curve,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: focused
              ? const [Color(0xC7000000), Color(0xAD000000), Color(0x00000000)]
              : const [Color(0xB3000000), Color(0x99000000), Color(0x00000000)],
          stops: const [0, 0.34, 0.80],
        ),
      ),
      child: AnimatedContainer(
        duration: Zm.normal,
        curve: Zm.curve,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.centerLeft,
            end: Alignment.centerRight,
            colors: focused
                ? const [Color(0xA6000000), Color(0x00000000)]
                : const [Color(0x8C000000), Color(0x00000000)],
            stops: const [0, 0.62],
          ),
        ),
        child: const SizedBox.expand(),
      ),
    );
  }

  /// Click layer over the artwork, the hover arrows and the keyboard anchor.
  Widget _heroOverlay(double fullH) {
    final hitH = _rowTop.clamp(0.0, fullH);
    final arrowsOn = fullH > 120;
    final panelBottom = fullH - _overlap - 22;
    final arrowTop = min(fullH * 0.40, panelBottom - 175).clamp(16.0, max(16.0, fullH - 52)).toDouble();
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
              // Selecting the poster restarts the carousel: ten seconds later
              // it moves on to the next slide.
              _resumeFromHero();
            },
            onExit: (_) => _heroHover.value = false,
            child: Stack(children: [
              Positioned(left: 0, top: 0, right: 0, height: hitH, child: _heroPointer()),
              if (arrowsOn) ..._arrowLayer(arrowTop),
            ]),
          ),
        ),
      // Always mounted: the click layer is clipped by the row slot, and without
      // this the hero zone would lose its only focus node.
      Positioned(
        left: 0,
        top: 0,
        right: 0,
        height: max(hitH, _heroFocusH),
        child: _heroFocusTarget(),
      ),
    ]);
  }

  /// Mouse-only layer over the poster: a click opens the shown resource.
  Widget _heroPointer() {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _openSlide,
      child: const SizedBox.expand(),
    );
  }

  /// Keyboard target of the hero. It is always mounted, which is what lets Up
  /// from a row return to the poster at any time. Pointer events are ignored so
  /// it never steals a click from the cards.
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
            // like hovering it.
            if (f) _resumeFromHero();
            // Nothing scrolls any more, so there is no poster to bring back;
            // the anchor is only here to receive Up and confirm.
            if (f && !InputMode.isPointer) _scrollToPoster();
          },
          onKey: (event) {
            if (event is! KeyDownEvent) return KeyEventResult.ignored;
            final key = event.logicalKey;
            if (key == LogicalKeyboardKey.arrowDown) {
              // Down from the poster enters the row that is on screen, by
              // index - see [_pageKeys] for why geometry cannot be trusted.
              final rows = _rows;
              if (rows != null && rows.isNotEmpty) _focusRow(rows[_activeRowFor(rows)]);
              return KeyEventResult.handled;
            }
            // Left/Right switch slides while the poster holds the focus; the
            // arrows themselves are mouse-only.
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
          // The focus frame is gone: the shade over the artwork is the only
          // focus indicator.
          builder: (context, focused) => const SizedBox.expand(),
        ),
      ),
    );
  }

  /// Prev/next circles. They only exist for the mouse: no focus node, no zone,
  /// and hidden until the poster is hovered or selected with the D-pad.
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

  /// The poster is fixed now, so landing on it has nothing to bring back. Kept
  /// as a named step so the focus wiring reads the same as the Emby home's.
  void _scrollToPoster() {}

  // ---- row content --------------------------------------------------------

  /// [autofocus] is true for the row that is on screen, so the D-pad has a
  /// starting card even when the first row of the list is empty (an empty
  /// continue-watching row is not painted at all, and row 0 would then be a
  /// `SizedBox` with nothing in it).
  Widget _buildRow(_Row row, {required bool autofocus}) {
    if (row.kind == _RowKind.resume) {
      final resume = _resume;
      if (resume.isEmpty) return const SizedBox.shrink();
      return Padding(
        padding: const EdgeInsets.only(bottom: Zs.rowGap),
        child: MediaRow(
          title: context.l10n.continueWatching,
          height: _resumeRowH,
          arrowLeft: contentLeft,
          zoneKey: _rowZoneKeys.putIfAbsent(row, () => GlobalKey()),
          itemCount: resume.length,
          itemBuilder: (context, i) => MouseRegion(
            // Pointing at a card must pin the poster exactly like focusing it
            // with the D-pad does. onHover (not onEnter): a card that merely
            // appears under a still pointer must not steal the poster.
            onHover: (_) => _hoverCard(resume[i]),
            child: Padding(
              padding: const EdgeInsets.only(top: 14),
              child: FnOsResumeCard(
                item: resume[i],
                width: Zs.landscapeWidth,
                autofocus: autofocus && i == 0,
                onFocus: () => _focusKey(resume[i]),
              ),
            ),
          ),
        ),
      );
    }
    final db = row.db!;
    final items = _libItems[db.guid];
    return Padding(
      padding: const EdgeInsets.only(bottom: Zs.rowGap),
      child: MediaRow(
        title: db.title,
        height: _posterRowH,
        arrowLeft: contentLeft,
        zoneKey: _rowZoneKeys.putIfAbsent(row, () => GlobalKey()),
        itemCount: items == null ? 8 : items.length,
        itemBuilder: (context, i) => MouseRegion(
          onHover: items == null ? null : (_) => _hoverCard(items[i]),
          child: Padding(
            padding: const EdgeInsets.only(top: 14),
            child: items == null
                ? const SkeletonBox(width: Zs.posterWidth, height: Zs.posterWidth * 1.5)
                : FnOsPosterCard(
                    item: items[i],
                    width: Zs.posterWidth,
                    autofocus: autofocus && i == 0,
                    onFocus: () => _focusKey(items[i]),
                  ),
          ),
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
