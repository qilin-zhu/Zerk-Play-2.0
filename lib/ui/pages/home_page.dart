import 'dart:async';
import 'dart:math';

import 'package:flutter/gestures.dart' show PointerScrollEvent, PointerSignalEvent;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/app_services.dart';
import '../../core/emby/models/emby_item.dart';
import '../../data/catalog_api.dart';
import '../../data/recommendations.dart';
import '../../data/seerr_api.dart';
import '../../data/taste_profile.dart';
import '../../data/title_tags.dart';
import '../../core/log/app_log.dart';
import '../../l10n/l10n.dart';
import '../core/artwork.dart';
import '../core/input_mode.dart';
import '../core/playback_launcher.dart';
import '../focus/focus_zone.dart';
import '../focus/tv_focusable.dart';
import '../theme/tokens.dart';
import '../widgets/backdrop.dart';
import '../widgets/cards.dart';
import '../widgets/cinema_loader.dart';
import '../widgets/common.dart';
import '../widgets/media_row.dart';
import '../widgets/net_image.dart';
import '../widgets/rows_scroll_view.dart';
import '../widgets/mixed_cards.dart';
import '../widgets/mood_shelf.dart';
import '../widgets/trailer.dart';
import 'hero.dart';
import 'title_extras.dart';
import 'routes.dart';

enum _Kind {
  cards,

  continueWatching,
  collections,

  moods,

  /// "My Media": one tile per library, straight from the server's view list.
  myMedia,

  /// One row of the latest additions of a single library.
  library,
}

class _Row {
  _Row(this.title, this.load, {this.style = CardStyle.poster, this.kind = _Kind.cards, this.recommends = true});

  String Function(L10n) title;

  final Future<MixedItems> Function() load;
  final CardStyle style;
  final _Kind kind;

  final bool recommends;
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  static final firstLoad = ValueNotifier(true);

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _hero = Debounced<HeroInfo?>(null);

  /// Same policy as the fnOS home: a sideways move inside a row must not touch
  /// the page, and a row that is already (mostly) visible must not either.
  final _scroll = RevealController(margin: 0, keepVisible: true);

  /// Vertical offset of the page only; row notifications are filtered out.
  final _scrollOffset = ValueNotifier<double>(0);

  /// Keyboard target of the hero, plus the two flags that drive its plate and
  /// the hover arrows.
  final _heroNode = FocusNode(debugLabel: 'emby-hero');
  final _heroFocus = ValueNotifier<bool>(false);
  final _heroHover = ValueNotifier<bool>(false);
  late final Listenable _arrows = Listenable.merge([_heroFocus, _heroHover]);

  /// What the poster is showing right now (an [EmbyItem] or a [SeerrMedia]), so
  /// a click on the artwork can open it and Left/Right can walk the row.
  Object? _shown;

  /// Hero carousel, same policy as the fnOS home: a random pool of the loaded
  /// resources that advances every [_slideInterval]. Pointing at (or focusing)
  /// a card pins that resource and parks the carousel; the poster being
  /// hovered/focused resumes it. See [_focusData] and [_resumeFromHero].
  List<(Object, HeroInfo)>? _slides;
  int _slideIndex = 0;
  Timer? _slideTimer;
  bool _pinned = false;
  Object? _pinnedItem;

  static const _slideInterval = Duration(seconds: 10);
  static const _slideCount = 8;

  /// Last time the page scrolled, used to ignore hover events caused by cards
  /// moving under a still pointer.
  int _lastScrollMs = 0;

  /// Last key press seen by this page: a card only pins the poster when the
  /// D-pad brought the focus there (see [_focusKey]).
  int _lastKeyMs = 0;

  double _fullH = 1;
  double _rowTop = 1;
  double _overlap = 0;

  /// Title block of a row: 18 px bottom padding + the text line.
  static const _rowTitleH = 48.0;

  /// Top of the library layout: leaves room for the rail mark and the clock.
  static const _libraryHomeTop = 88.0;
  static const _maxFade = 320.0;
  static const _heroFocusH = 44.0;
  static const _arrowLeft = 88.0;
  static const _bottomFade = LinearGradient(
    begin: Alignment.bottomCenter,
    end: Alignment.topCenter,
    stops: [0.0, 0.35, 0.7, 1.0],
    colors: [Zc.background, Color(0xCC0B0B12), Color(0x550B0B12), Color(0x000B0B12)],
  );
  List<_Row>? _rows;
  final _data = <_Row, Future<MixedItems>>{};

  final _allowed = <_Row>{};
  int _loading = 0;
  static const _parallelRows = 3;

  final _resolved = <_Row, MixedItems>{};

  bool _loaded = false;
  bool _showLoader = false;

  Future<TasteProfile>? _taste;

  Future<List<TitleTag>>? _tasteTags;

  AppServices? _services;
  String _pickedCollections = '';

  /// Which of the two homes is on screen. Mirrors
  /// [AppSettings.homeRecommendationTheme]; when it is off the page is the
  /// web-like library layout (continue watching, my media, one row per library)
  /// and none of the poster machinery below applies.
  bool _libraryLayout = false;

  /// Libraries of the server, only loaded for the library layout.
  List<LibraryView>? _views;
  bool _viewsRequested = false;

  _Row? _myListRow;
  String _myListKeys = '';

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_rows == null) {
      AppLog.write('[emby] home build poster-v2 (random carousel, pin on card, resume on hero)');
      _rows = _buildRows(AppServicesScope.read(context));
      _allowFirstRows();
      _scroll.addListener(_onScroll);
      _awaitFirstRows();
    }
    if (_services == null) {
      _services = AppServicesScope.read(context);
      _services!.libraryChanged.addListener(refresh);
      _services!.profiles.addListener(_onProfile);
      _pickedCollections = _collectionsKey(_services!);
      _services!.addListener(_onServices);
    }
  }

  static List<(String, String)> _collections(AppServices s) =>
      s.isSignedIn ? s.settings.homeCollectionsOf(s.janus.session.userId) : const [];

  static String _collectionsKey(AppServices s) => [for (final (id, _) in _collections(s)) id].join(',');

  void _onServices() {
    if (!mounted) return;
    final s = _services!;
    final key = _collectionsKey(s);
    final layout = !s.settings.homeRecommendationTheme;
    if (key == _pickedCollections && layout == _libraryLayout) return;
    _pickedCollections = key;
    _slideTimer?.cancel();
    _slides = null;
    setState(() {
      _rows = _buildRows(s);
      _data.clear();
      _resolved.clear();
      _allowFirstRows();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _pump());
  }

  void _onProfile() {
    final keys = [for (final e in _services!.profiles.profile?.list ?? const []) e.key].join(',');
    if (keys == _myListKeys) return;
    _myListKeys = keys;
    final row = _myListRow;
    if (row != null && mounted) setState(() => _data.remove(row));
  }

  void _allowFirstRows() {
    _allowed.clear();
    // The library home is short (a handful of rows) and every row is visible
    // almost at once, so they are all allowed immediately.
    if (_libraryLayout) {
      _allowed.addAll(_rows!);
      return;
    }
    _allowed.addAll(_rows!.take(6).where((r) => !r.recommends && r.kind != _Kind.moods));
  }

  void _pump({int upTo = -1}) {
    final rows = _rows!;
    var changed = false;
    for (var i = 0; i < rows.length && i <= upTo; i++) {
      changed |= _allowed.add(rows[i]);
    }
    if (_loaded) {
      for (final r in rows) {
        if (_loading >= _parallelRows) break;
        if (_allowed.add(r)) {
          changed = true;
          if (!_data.containsKey(r)) _loading++;
          _load(r, counted: true);
        }
      }
    }
    if (changed && mounted) setState(() {});
  }

  void _onScroll() {
    final offset = _scroll.hasClients ? _scroll.offset : 0.0;
    final upTo = (offset + MediaQuery.sizeOf(context).height * 2) ~/ 320;
    if (upTo >= 0 && _rows!.take(upTo + 1).any((r) => !_allowed.contains(r))) _pump(upTo: upTo);
  }

  void _awaitFirstRows() {
    if (!AppServicesScope.read(context).isSignedIn) {
      _loaded = true;
      HomePage.firstLoad.value = false;
      return;
    }
    final first = _rows!
        .where((r) => r.kind == _Kind.continueWatching || (r.kind == _Kind.cards && !r.recommends))
        .take(2);
    Timer(const Duration(milliseconds: 400), () {
      if (mounted && !_loaded && AppServicesScope.read(context).isSignedIn) setState(() => _showLoader = true);
    });
    Future.wait(first.map((r) => _load(r).catchError((Object _) => const <Object>[])))
        .timeout(const Duration(seconds: 45), onTimeout: () => const [])
        .whenComplete(() {
      AppLog.mark('home rows loaded');
      HomePage.firstLoad.value = false;
      if (mounted) setState(() => _loaded = true);
      _pump();
    });
  }

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_watchKey);
  }

  /// Global watcher for the pin policy. A card's own key handler consumes the
  /// arrows it uses, so the page-level handler never sees them; this one sees
  /// every press and only records the time.
  bool _watchKey(KeyEvent event) {
    if (event is! KeyUpEvent) _lastKeyMs = DateTime.now().millisecondsSinceEpoch;
    return false;
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_watchKey);
    _services?.libraryChanged.removeListener(refresh);
    _services?.profiles.removeListener(_onProfile);
    _services?.removeListener(_onServices);
    _hero.dispose();
    _slideTimer?.cancel();
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    _scrollOffset.dispose();
    _heroNode.dispose();
    _heroFocus.dispose();
    _heroHover.dispose();
    super.dispose();
  }

  void refresh() {
    _slideTimer?.cancel();
    _pinned = false;
    _pinnedItem = null;
    _slides = null;
    _slideIndex = 0;
    setState(() {
      _data.clear();
      _taste = null;
      _tasteTags = null;
      _allowFirstRows();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _pump());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Future.wait(_data.values.map((f) => f.catchError((Object _) => const <Object>[]))).whenComplete(() {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          final focus = FocusManager.instance.primaryFocus;
          if (focus == null || focus.context == null || !focus.context!.mounted) _focusFirstCard();
        });
      });
    });
  }

  void _focusFirstCard() {
    final ctx = context;
    final scope = FocusScope.of(ctx);
    for (final n in scope.descendants) {
      if (n is ZoneScopeNode && n.items.isNotEmpty) {
        ZoneNavigator.enter(n);
        return;
      }
    }
  }

  Future<TasteProfile> _profile(AppServices s) => _taste ??= TasteProfile.load(s.catalog).catchError((Object e) {
        debugPrint('[home] taste profile: $e');
        return const TasteProfile();
      });

  Future<List<TitleTag>> _tags(AppServices s) => _tasteTags ??= () async {
        final tags = s.titleTags;
        if (tags == null) return const <TitleTag>[];
        return tags.taste(await _profile(s));
      }()
          .catchError((Object e) {
        debugPrint('[home] taste tags: $e');
        return const <TitleTag>[];
      });

  List<_Row> _buildRows(AppServices s) {
    // The setting decides the whole shape of the page, not just a row or two:
    // "recommendation theme" is the poster carousel plus the taste rows, the
    // other one is Emby's own web home.
    _libraryLayout = !s.settings.homeRecommendationTheme;
    return _libraryLayout ? _buildLibraryRows(s) : _buildThemeRows(s);
  }

  /// Web-like home: continue watching, the library tiles, then the latest
  /// additions of each library. No poster, no recommendation machinery.
  List<_Row> _buildLibraryRows(AppServices s) {
    if (_views == null) _requestViews(s);
    final c = s.catalog;
    final libraries = [
      for (final v in _views ?? const <LibraryView>[])
        if (_isMediaLibrary(v)) v,
    ];
    return [
      _Row((l) => l.continueWatching, () => c.continueWatching(), kind: _Kind.continueWatching, recommends: false),
      if (libraries.isNotEmpty)
        _Row((l) => l.myMedia, () async => List<Object>.of(libraries), kind: _Kind.myMedia, recommends: false),
      for (final view in libraries)
        _Row(
          (_) => view.name,
          () => c.latest(parentId: view.id, limit: 24),
          kind: _Kind.library,
          style: view.collectionType == 'tvshows' ? CardStyle.landscape : CardStyle.poster,
          recommends: false,
        ),
    ];
  }

  /// Only the libraries this player can actually show: music / books shelves
  /// would be empty rows. A view without a collection type holds mixed content
  /// and stays.
  static bool _isMediaLibrary(LibraryView v) => switch (v.collectionType) {
        'movies' || 'tvshows' || 'mixed' || 'boxsets' || 'homevideos' || 'musicvideos' => true,
        _ => v.collectionType == null,
      };

  void _requestViews(AppServices s) {
    if (_viewsRequested) return;
    _viewsRequested = true;
    s.catalog.views().then((views) {
      if (!mounted) return;
      setState(() {
        _views = views;
        _rows = _buildLibraryRows(_services ?? s);
        _data.clear();
        _resolved.clear();
        _allowFirstRows();
      });
      WidgetsBinding.instance.addPostFrameCallback((_) => _pump());
    }).catchError((Object e) {
      debugPrint('[home] library views: $e');
    });
  }

  List<_Row> _buildThemeRows(AppServices s) {
    final c = s.catalog;
    final seerr = s.seerr;
    final r = s.recommender;
    Future<MixedItems> items(Future<ItemPage> page) async => (await page).items;

    return [
      _Row((l) => l.continueWatching, () => c.continueWatching(), kind: _Kind.continueWatching, recommends: false),
      for (final (id, name) in _collections(s))
        _Row((l) => name,
            () => items(c.query(parentId: id, recursive: false, sortBy: 'PremiereDate,ProductionYear,SortName', limit: 100)),
            recommends: false),
      _myListRow = _Row((l) => l.myList, s.myList, recommends: false),
      _because(s, (t) => t.recentMovies, 0),
      _Row((l) => l.latestMovies, () => c.latest(types: ['Movie']), recommends: false),
      if (r.tmdb != null) _Row((l) => l.moodShelfTitle, () async => const [], kind: _Kind.moods, recommends: false),
      _Row((l) => l.latestShows, () => c.latest(types: ['Episode', 'Series']), style: CardStyle.landscape, recommends: false),
      if (seerr != null)
        _Row((l) => l.trendingThisWeek, () => r.mixed((p) => seerr.trending(page: p, timeWindow: 'week'), limit: 10),
            style: CardStyle.ranked),
      _Row((l) => l.recommendedForYou, () => _forYou(s), style: CardStyle.spotlight),
      _starring(s, 0),
      _likeTag(s, 0),
      _Row((l) => l.collections, () => c.allCollections(recent: true, limit: 20), kind: _Kind.collections, recommends: false),
      _because(s, (t) => t.recentSeries, 0, style: CardStyle.landscape),
      _Row((l) => l.topRatedMovies, () => items(c.query(types: ['Movie'], sortBy: 'CommunityRating', descending: true, minCommunityRating: 7, limit: 24))),
      _directedBy(s, 0),
      _likeTag(s, 1, style: CardStyle.landscape),
      _because(s, (t) => t.recentMovies, 1, style: CardStyle.landscape),
      _Row((l) => l.yourFavorites,
          () => items(c.query(types: ['Movie', 'Series'], filters: 'IsFavorite', sortBy: 'Random', limit: 30)),
          style: CardStyle.landscape, recommends: false),
      _starring(s, 1, style: CardStyle.landscape),
      _moreGenre(s, 0),
      _likeTag(s, 2),
      _Row((l) => l.recentlyReleased, () => items(c.query(types: ['Movie'], sortBy: 'PremiereDate', descending: true, limit: 24))),
      _because(s, (t) => t.recentSeries, 1),
      _Row((l) => l.topRatedShows, () => items(c.query(types: ['Series'], sortBy: 'CommunityRating', descending: true, minCommunityRating: 7, limit: 24)),
          style: CardStyle.landscape),
      _starring(s, 2),
      _moreGenre(s, 1, style: CardStyle.landscape),
      _likeTag(s, 3),
      _Row((l) => l.somethingUnseen, () => items(c.query(types: ['Movie'], sortBy: 'Random', filters: 'IsUnplayed', limit: 24))),
      if (seerr != null)
        _Row((l) => l.popularToRequest, () async {
          final (movies, shows) = await (
            r.requestable((p) => r.discover(SeerrMediaType.movie, page: p, voteCountGte: 200), limit: 20),
            r.requestable((p) => r.discover(SeerrMediaType.tv, page: p, voteCountGte: 100), limit: 20),
          ).wait;
          return _interleave(movies, shows);
        }),
    ];
  }

  static List<Object> _interleave(List<Object> a, List<Object> b) => [
        for (var i = 0; i < a.length || i < b.length; i++) ...[if (i < a.length) a[i], if (i < b.length) b[i]],
      ];

  _Row _because(AppServices s, List<EmbyItem> Function(TasteProfile) pick, int index, {CardStyle style = CardStyle.poster}) {
    late final _Row row;
    return row = _Row((l) => '', () async {
      final seeds = pick(await _profile(s));
      if (seeds.length <= index) return const [];
      final seed = await s.catalog.localize(seeds[index]);
      row.title = (l) => l.becauseYouWatched(seed.name);
      final seerr = s.seerr;
      final tmdbId = seed.tmdbId;
      final MixedItems items;
      if (seerr != null && tmdbId != null) {
        items = await s.recommender.mixed(
            (p) => seerr.recommendations(tmdbId, seed.isSeries ? SeerrMediaType.tv : SeerrMediaType.movie, page: p),
            pages: 2,
            hidePlayed: true);
      } else {
        items = [for (final i in await s.catalog.similar(seed.id, limit: 24)) if (!i.isPlayed) i];
      }
      return [for (final i in items) if (i is! EmbyItem || i.id != seed.id) i];
    }, style: style);
  }

  _Row _likeTag(AppServices s, int index, {CardStyle style = CardStyle.poster}) {
    late final _Row row;
    return row = _Row((l) => '', () async {
      final l10n = context.l10n;
      final said = <String>{};
      final tags = [
        for (final t in await _tags(s))
          if (tagRowTitle(l10n, t) case final title? when said.add(title)) t,
      ];
      if (tags.length <= index) return const [];
      final tag = tags[index];
      row.title = (l) => tagRowTitle(l, tag) ?? tagLabel(l, tag);
      final r = s.recommender;
      final (movies, shows) = await (
        r.tagged(tag, SeerrMediaType.movie, hidePlayed: true),
        r.tagged(tag, SeerrMediaType.tv, hidePlayed: true),
      ).wait;
      final all = _interleave(movies, shows);
      return all.length < 4 ? const [] : all.take(40).toList();
    }, style: style);
  }

  _Row _starring(AppServices s, int index, {CardStyle style = CardStyle.poster}) {
    late final _Row row;
    return row = _Row((l) => '', () async {
      final actors = (await _profile(s)).actors;
      if (actors.length <= index) return const [];
      final person = actors[index].person;
      row.title = (l) => l.starring(person.name);
      return _personWork(s, person, types: const ['Movie', 'Series']);
    }, style: style);
  }

  _Row _directedBy(AppServices s, int index, {CardStyle style = CardStyle.poster}) {
    late final _Row row;
    return row = _Row((l) => '', () async {
      final directors = (await _profile(s)).directors;
      if (directors.length <= index) return const [];
      final person = directors[index].person;
      row.title = (l) => l.directedBy(person.name);
      return _personWork(s, person, types: const ['Movie'], movieCreditsOnly: true);
    }, style: style);
  }

  static Future<MixedItems> _personWork(AppServices s, Person person,
      {required List<String> types, bool movieCreditsOnly = false}) async {
    final c = s.catalog;
    final seerr = s.seerr;
    final (library, details) = await (
      c.query(personIds: person.id, types: types, filters: 'IsUnplayed', sortBy: 'CommunityRating', descending: true, limit: 40),
      seerr == null ? Future<EmbyItem?>.value() : c.item(person.id).then<EmbyItem?>((v) => v, onError: (Object _) => null),
    ).wait;
    final requestable = <SeerrMedia>[];
    final tmdbId = details?.tmdbId;
    if (seerr != null && tmdbId != null) {
      try {
        final credits = await seerr.personCredits(tmdbId, name: person.name);
        final kept = [
          for (final m in credits)
            if (RecommendationFilter.keep(m) && (m.voteCount ?? 0) >= 50 && (!movieCreditsOnly || !m.isTv)) m,
        ].take(40).toList();
        requestable.addAll((await s.recommender.resolve(kept)).whereType<SeerrMedia>());
      } catch (e) {
        debugPrint('[home] credits of ${person.name}: $e');
      }
    }
    final all = <Object>[...library.items, ...requestable.take(24)];
    return all.length < 4 ? const [] : all;
  }

  _Row _moreGenre(AppServices s, int index, {CardStyle style = CardStyle.poster}) {
    late final _Row row;
    return row = _Row((l) => '', () async {
      final genres = (await _profile(s)).genres;
      if (genres.length <= index) return const [];
      final genre = genres[index].genre;
      row.title = (l) => l.moreGenre(lowerFirst(genre));
      final page = await s.catalog.query(
          types: ['Movie', 'Series'], genres: [genre], filters: 'IsUnplayed', sortBy: 'Random', minCommunityRating: 6.5, limit: 30);
      return page.items;
    }, style: style);
  }

  Future<MixedItems> _forYou(AppServices s) async {
    final genres = (await _profile(s)).genres.take(3).map((g) => g.genre).toList();
    final page = await s.catalog.query(
      types: ['Movie', 'Series'],
      genres: genres.isEmpty ? null : genres,
      filters: 'IsUnplayed',
      sortBy: 'Random',
      minCommunityRating: 7,
      limit: 12,
    );
    return [for (final i in page.items) if (s.catalog.backdrop(i) != null) i];
  }

  Future<MixedItems> _load(_Row row, {bool counted = false}) => _data.putIfAbsent(row, () async {
        if (!counted) _loading++;
        try {
          var items = await row.load();
          if (row.recommends) items = [for (final i in items) if (i.keptInRecommendations) i];
          _resolved[row] = items;
          _startCarousel();
          return items;
        } finally {
          _loading--;
          scheduleMicrotask(() => mounted ? _pump() : null);
        }
      });

  HeroInfo _heroInfoOf(Object data) {
    final l10n = context.l10n;
    return data is EmbyItem
        ? HeroInfo.fromItem(l10n, AppServicesScope.read(context), data)
        : HeroInfo.fromRequest(l10n, data as SeerrMedia);
  }

  void _publishItem(Object data, HeroInfo info, {bool immediate = false}) {
    _shown = data;
    _hero.set(info, immediate: immediate);
  }

  /// A card was hovered or focused: show that resource and park the carousel.
  void _focusData(Object data, {bool immediate = false}) {
    // The library home has no poster to pin; its rows also carry bare library
    // folders, which the hero cannot describe.
    if (_libraryLayout) return;
    if (_pinned && identical(_pinnedItem, data)) return;
    _slideTimer?.cancel();
    _pinned = true;
    _pinnedItem = data;
    final info = _heroInfoOf(data);
    _publishItem(data, info, immediate: immediate);
  }

  /// Builds the carousel pool from what the rows have loaded so far, shuffled
  /// once so every visit starts on a different resource. Called after each row
  /// resolves: the first two items are enough, later rows are ignored.
  void _startCarousel() {
    if (!mounted || _libraryLayout) return;
    if (_slides != null) return;
    final rows = _rows;
    if (rows == null) return;
    final seen = <String>{};
    final pool = <(Object, HeroInfo)>[];
    for (final row in rows) {
      if (row.kind == _Kind.moods) continue;
      for (final item in _resolved[row] ?? const <Object>[]) {
        final info = _heroInfoOf(item);
        if (!seen.add(info.key)) continue;
        pool.add((item, info));
      }
    }
    if (pool.length < 2) return;
    pool.shuffle(Random());
    _slides = pool.take(_slideCount).toList();
    _slideIndex = 0;
    final (data, info) = _slides!.first;
    _publishItem(data, info, immediate: true);
    _scheduleSlide();
  }

  void _scheduleSlide() {
    _slideTimer?.cancel();
    _slideTimer = Timer(_slideInterval, _onSlideTick);
  }

  void _onSlideTick() {
    if (!mounted) return;
    final slides = _slides;
    if (slides == null || slides.length < 2) return;
    // Same policy as the fnOS home: no rotation while the poster is mostly
    // scrolled away, and none while the user is browsing a card.
    if (_fullH > 0 && _scrollOffset.value > _fullH * 0.5) {
      _scheduleSlide();
      return;
    }
    if (_pinned) return;
    _slideIndex = (_slideIndex + 1) % slides.length;
    final (data, info) = slides[_slideIndex];
    _publishItem(data, info);
    _scheduleSlide();
  }

  /// Mouse hover on a card pins the poster, unless the page is scrolling: a
  /// card sliding under a still pointer must not flicker the artwork.
  void _hoverCard(Object data) {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastScrollMs < 350) return;
    _focusData(data);
  }

  /// Keyboard focus on a card pins it, but only when the D-pad caused it: the
  /// page puts the focus on the first card by itself right after loading, and
  /// that must not park the carousel before the user has touched anything.
  void _focusKey(Object data) {
    if (DateTime.now().millisecondsSinceEpoch - _lastKeyMs > 900) return;
    _focusData(data);
  }

  /// The poster area is hovered or has the D-pad focus: after ten seconds the
  /// carousel takes over again and moves on to the next resource.
  void _resumeFromHero() {
    if (!_pinned) return;
    _pinned = false;
    _pinnedItem = null;
    _scheduleSlide();
  }

  Future<void> _play(EmbyItem item) => playItem(context, item);

  @override
  Widget build(BuildContext context) {
    if (_libraryLayout) return _buildLibraryHome(context);
    final rows = _rows!;
    final size = MediaQuery.sizeOf(context);
    // Same stage as the fnOS home: a full-bleed 16:9 poster pinned to the top,
    // cropped from the bottom as the page scrolls, with the first row peeking
    // over its lower edge.
    final fullW = size.width.clamp(320.0, 4096.0);
    final fullH = fullW * 9 / 16;
    _fullH = fullH;
    _rowTop = (size.height - _rowPeek(rows)).clamp(0.0, fullH);
    _overlap = (fullH - _rowTop).clamp(0.0, fullH);

    final posterImage = ValueListenableBuilder<HeroInfo?>(
      valueListenable: _hero,
      builder: (_, info, _) => Backdrop(url: info?.backdrop, scrims: false),
    );
    final posterPanel = ValueListenableBuilder<HeroInfo?>(
      valueListenable: _hero,
      builder: (_, info, _) => HeroPanel(info: info),
    );

    return Focus(
      // Up from the topmost row must always reach the poster; see [_pageKeys].
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: _pageKeys,
      child: Stack(children: [
        // Poster layer (bottom): pinned and full-bleed.
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
        // Content layer (top): transparent, so the wheel scrolls from anywhere
        // and the rows paint over the poster's bottom edge.
        Positioned.fill(
          child: NotificationListener<ScrollNotification>(
            onNotification: (n) {
              // Every row is a horizontal ListView nested inside this page's
              // viewport, so its notifications bubble up here too. Feeding
              // their horizontal pixels into the poster offset would shove the
              // artwork around on a plain Left/Right press.
              final ad = n.metrics.axisDirection;
              final vertical = ad == AxisDirection.down || ad == AxisDirection.up;
              if (!vertical || n.depth != 0) return false;
              _lastScrollMs = DateTime.now().millisecondsSinceEpoch;
              if ((_scrollOffset.value - n.metrics.pixels).abs() > 0.5) {
                _scrollOffset.value = n.metrics.pixels;
              }
              return false;
            },
            child: Listener(
              onPointerSignal: _onPointerSignal,
              child: Stack(fit: StackFit.expand, children: [
                CardTrailers(
                  child: RowsScrollView(
                    controller: _scroll,
                    top: _rowTop,
                    children: [for (final (i, row) in rows.indexed) _buildRow(row, first: i == 0)],
                  ),
                ),
                ValueListenableBuilder<double>(
                  valueListenable: _scrollOffset,
                  builder: (context, offset, _) => _heroOverlay(fullH, offset),
                ),
              ]),
            ),
          ),
        ),
        _firstLoadOverlay(context),
      ]),
    );
  }

  /// The library home: a plain stack of rows under the header, exactly like the
  /// web client draws it, with no poster behind them.
  Widget _buildLibraryHome(BuildContext context) {
    final rows = _rows!;
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      child: Stack(children: [
        Positioned.fill(
          child: NotificationListener<ScrollNotification>(
            onNotification: (n) {
              _lastScrollMs = DateTime.now().millisecondsSinceEpoch;
              return false;
            },
            child: RowsScrollView(
              controller: _scroll,
              top: _libraryHomeTop,
              children: [for (final (i, row) in rows.indexed) _buildRow(row, first: i == 0)],
            ),
          ),
        ),
        _firstLoadOverlay(context),
      ]),
    );
  }

  /// First-load veil, shared by both layouts: without it the page flashes an
  /// empty stack of rows before the server answers.
  Widget _firstLoadOverlay(BuildContext context) {
    if (!_showLoader || !AppServicesScope.of(context).isSignedIn) return const SizedBox.shrink();
    return Positioned.fill(
      child: IgnorePointer(
        ignoring: _loaded,
        child: AnimatedOpacity(
          opacity: _loaded ? 0 : 1,
          duration: const Duration(milliseconds: 900),
          curve: Curves.easeInOut,
          onEnd: () {
            if (_loaded && mounted) setState(() => _showLoader = false);
          },
          child: const CinemaLoader(),
        ),
      ),
    );
  }
  /// Height taken by the first row that actually renders: its title plus the
  /// card block. The rows start exactly that far from the bottom edge, so the
  /// very first row is always fully visible instead of being clipped.
  double _rowPeek(List<_Row> rows) {
    _Row? first;
    for (final r in rows) {
      if (r.kind == _Kind.moods || !_allowed.contains(r)) continue;
      final items = _resolved[r];
      if (items == null || items.isNotEmpty) {
        first = r;
        break;
      }
    }
    if (first == null) return 0;
    final areaH = switch (first.kind) {
      _Kind.collections => 560 * 0.42 + 44,
      _Kind.continueWatching || _Kind.myMedia => cardAreaHeight(CardStyle.landscape),
      _ => cardAreaHeight(first.style),
    };
    return _rowTitleH + areaH + Zs.rowGap;
  }

  /// Poster composition: the artwork is laid out at the full height and
  /// top-anchored, so the clip crops it from the bottom; a gradient dissolves
  /// the cut edge, and the info card sits on the artwork's bottom-left.
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
          Positioned(
            left: contentLeft - 20,
            right: 220,
            bottom: _overlap + 22,
            child: Opacity(
              opacity: fadeOut,
              child: Align(
                alignment: Alignment.bottomLeft,
                child: IgnorePointer(
                  // No ring: the translucent plate behind the text is the
                  // only focus indicator, exactly like the fnOS home.
                  child: ValueListenableBuilder<bool>(
                    valueListenable: _heroFocus,
                    builder: (_, focused, child) => AnimatedContainer(
                      duration: Zm.fast,
                      curve: Zm.curve,
                      padding: const EdgeInsets.fromLTRB(20, 14, 24, 10),
                      decoration: BoxDecoration(
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

  /// Click/drag layer over the artwork, the hover arrows and the keyboard
  /// anchor. Rebuilt on every scroll tick, so it stays cheap.
  Widget _heroOverlay(double fullH, double offset) {
    final h = (fullH - offset).clamp(0.0, fullH);
    final c = (offset / fullH).clamp(0.0, 1.0);
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
              // Selecting the poster restarts the carousel: ten seconds later
              // it moves on to the next resource.
              _resumeFromHero();
            },
            onExit: (_) => _heroHover.value = false,
            child: Stack(children: [
              Positioned(left: 0, top: 0, right: 0, height: hitH, child: _heroPointer()),
              if (arrowsOn) ..._arrowLayer(arrowTop),
            ]),
          ),
        ),
      // Always mounted: the click layer disappears once the poster scrolls
      // away, and without this the hero zone would have no focus node at all.
      Positioned(
        left: 0,
        top: 0,
        right: 0,
        height: max(hitH, _heroFocusH),
        child: _heroFocusTarget(),
      ),
    ]);
  }

  /// Mouse-only layer over the poster: a click opens the shown resource and a
  /// drag scrolls the page (the scroll view is a sibling underneath).
  Widget _heroPointer() {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _openShown,
      onVerticalDragUpdate: (d) {
        if (!_scroll.hasClients) return;
        final p = _scroll.position;
        _scroll.jumpTo((p.pixels - d.delta.dy).clamp(0.0, p.maxScrollExtent));
      },
      child: const SizedBox.expand(),
    );
  }

  /// Keyboard target of the hero. Mounted for the whole life of the page so Up
  /// can return to the poster at any scroll offset; pointer events are ignored
  /// so it never steals a click from the cards.
  Widget _heroFocusTarget() {
    return IgnorePointer(
      child: FocusZone(
        debugLabel: 'emby-hero',
        child: TvFocusable(
          focusNode: _heroNode,
          reveal: false,
          onSelect: _openShown,
          onFocusChange: (f) {
            _heroFocus.value = f;
            // The D-pad landing on the poster restarts the carousel, exactly
            // like hovering it.
            if (f) _resumeFromHero();
            if (f && !InputMode.isPointer) _scrollToPoster();
          },
          onKey: (event) {
            if (event is! KeyDownEvent) return KeyEventResult.ignored;
            final key = event.logicalKey;
            if (key == LogicalKeyboardKey.arrowDown) {
              ZoneNavigator.move(TraversalDirection.down);
              return KeyEventResult.handled;
            }
            // Left/Right switch what the poster shows, exactly like fnOS; the
            // arrows are mouse-only.
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
          builder: (context, focused) => const SizedBox.expand(),
        ),
      ),
    );
  }

  /// Prev/next circles. Mouse only: no focus node, no zone, and hidden until
  /// the poster is hovered or selected with the D-pad.
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

  /// Up must always be able to come back to the poster: directional traversal
  /// rejects a hero whose centre is not above the row zone's centre, so when
  /// the first row hangs off the top edge the key used to do nothing at all.
  KeyEventResult _pageKeys(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent || event.logicalKey != LogicalKeyboardKey.arrowUp) {
      return KeyEventResult.ignored;
    }
    if (_heroNode.hasFocus) return KeyEventResult.ignored;
    if (ZoneNavigator.move(TraversalDirection.up)) return KeyEventResult.handled;
    if (!_heroNode.canRequestFocus) return KeyEventResult.ignored;
    _heroNode.requestFocus();
    return KeyEventResult.handled;
  }

  /// Brings the pinned poster back to its resting size when the D-pad lands on
  /// it, since it lives outside the scroll view and `revealFocused` cannot.
  void _scrollToPoster() {
    if (!_scroll.hasClients) return;
    final p = _scroll.position;
    if (p.pixels <= 0.5) return;
    p.animateTo(0, duration: const Duration(milliseconds: 280), curve: Curves.easeOutCubic);
  }

  /// Safety net for mouse wheels / trackpads: `Scrollable` normally consumes the
  /// pointer signal itself, so this only kicks in when it does not.
  void _onPointerSignal(PointerSignalEvent e) {
    if (e is! PointerScrollEvent || !_scroll.hasClients) return;
    final p = _scroll.position;
    if (!p.hasContentDimensions) return;
    _scroll.jumpTo((p.pixels + e.scrollDelta.dy).clamp(0.0, p.maxScrollExtent));
  }

  /// Left/Right walk the carousel pool, rolling forward from whatever is on
  /// screen; a pinned resource that is not part of the pool starts the walk
  /// from the slide behind it.
  void _stepSlide(int delta) {
    final slides = _slides;
    if (slides == null || slides.length < 2) return;
    final current = slides.indexWhere((s) => identical(s.$1, _shown));
    final from = current < 0 ? _slideIndex : current;
    _slideIndex = ((from + delta) % slides.length + slides.length) % slides.length;
    _pinned = false;
    _pinnedItem = null;
    final (data, info) = slides[_slideIndex];
    _publishItem(data, info, immediate: true);
    _scheduleSlide();
  }

  void _openShown() {
    final data = _shown;
    if (data is EmbyItem) openItem(context, data);
  }

  Widget _buildRow(_Row row, {required bool first}) {
    if (row.kind == _Kind.moods) {
      if (!_allowed.contains(row)) return const SizedBox.shrink();
      return MoodShelf(
        favoriteGenres: _profile(AppServicesScope.read(context)).then((t) => [for (final g in t.genres) g.genre]),
        onFocusHero: (info) => _hero.set(info),
      );
    }
    return FutureBuilder<MixedItems>(
      future: _allowed.contains(row) ? _load(row) : null,
      initialData: _resolved[row],
      builder: (context, snap) {
        final (cardW, areaH) = switch (row.kind) {
          _Kind.collections => (560.0, 560 * 0.42 + 44),
          _Kind.continueWatching || _Kind.myMedia => (Zs.landscapeWidth, cardAreaHeight(CardStyle.landscape)),
          _ => (cardWidth(row.style), cardAreaHeight(row.style)),
        };
        if (snap.data == null && !snap.hasError) {
          return Padding(
            padding: const EdgeInsets.only(bottom: Zs.rowGap),
            child: SkeletonRow(cardWidth: cardW, cardHeight: areaH - 100),
          );
        }
        final items = snap.data ?? const [];
        if (snap.hasError) debugPrint('[home] ${row.title(context.l10n)}: ${snap.error}');
        if (items.isEmpty) return const SizedBox.shrink();

        return Padding(
          padding: const EdgeInsets.only(bottom: Zs.rowGap),
          child: MediaRow(
            title: row.title(context.l10n),
            height: areaH,
            gap: switch ((row.kind, row.style)) {
              (_Kind.collections, _) => 28,
              (_, CardStyle.ranked) => 8,
              (_, CardStyle.spotlight) => 30,
              _ => Zs.cardGap,
            },
            itemCount: items.length,
            itemBuilder: (context, i) => MouseRegion(
              // Pointing at a card must pin the poster exactly like focusing it
              // with the D-pad does. onHover (not onEnter): a card that merely
              // appears under a still pointer must not steal the poster.
              onHover: (_) => _hoverCard(items[i]),
              child: Padding(
                padding: const EdgeInsets.only(top: 14),
                child: _card(row, items[i], rank: i + 1, autofocus: first && i == 0),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _card(_Row row, Object data, {required int rank, required bool autofocus}) {
    if (row.kind == _Kind.myMedia && data is LibraryView) {
      return _LibraryCard(view: data, autofocus: autofocus, onFocus: () => _focusKey(data), onSelect: () => openLibrary(context, data));
    }
    if (row.kind == _Kind.collections && data is EmbyItem) {
      return CollectionCard(item: data, autofocus: autofocus, onFocus: () => _focusKey(data), onSelect: () => openItem(context, data));
    }
    if (row.kind == _Kind.continueWatching && data is EmbyItem) {
      final item = data;
      final remaining = item.resumePosition == null || item.runtime == null
          ? null
          : formatRuntime(context.l10n, item.runtime! - item.resumePosition!);
      return LandscapeCard(
        item: item,
        autofocus: autofocus,
        title: item.isEpisode ? item.seriesName ?? item.name : item.name,
        subtitle: item.isEpisode
            ? [item.episodeCode, item.name].whereType<String>().join('  ')
            : remaining != null
                ? context.l10n.timeLeft(remaining)
                : item.productionYear?.toString(),
        preferEpisodeStill: false,
        onFocus: () => _focusKey(item),
        onSelect: () => openItem(context, item),
        onMenu: () => _play(item),
        onPlay: () => _play(item),
      );
    }
    if (row.style == CardStyle.landscape && data is EmbyItem && data.isEpisode) {
      return LandscapeCard(
        item: data,
        autofocus: autofocus,
        title: data.seriesName ?? data.name,
        subtitle: [data.episodeCode, data.name].whereType<String>().join('  '),
        onFocus: () => _focusKey(data),
        onSelect: () => openItem(context, data),
        onPlay: () => _play(data),
      );
    }
    return mixedCard(context, data, style: row.style, rank: rank, autofocus: autofocus, onFocus: () => _focusKey(data));
  }
}

/// A "My Media" tile: the library's own artwork with its name on a scrim, the
/// way the web client draws the folder shortcuts on its home screen.
class _LibraryCard extends StatelessWidget {
  const _LibraryCard({required this.view, this.autofocus = false, this.onFocus, this.onSelect});

  final LibraryView view;
  final bool autofocus;
  final VoidCallback? onFocus;
  final VoidCallback? onSelect;

  static const _width = Zs.landscapeWidth;
  static const _height = _width * 9 / 16;

  @override
  Widget build(BuildContext context) {
    final catalog = AppServicesScope.read(context).catalog;
    return TvFocusable(
      autofocus: autofocus,
      onSelect: onSelect,
      onFocusChange: (f) => f ? onFocus?.call() : null,
      builder: (context, focused) => SizedBox(
        width: _width,
        child: FocusFrame(
          focused: focused,
          child: SizedBox(
            width: _width,
            height: _height,
            child: Stack(fit: StackFit.expand, children: [
              NetImage(
                url: catalog.image(view.id, ImageKind.primary, tag: view.imageTag, width: (_width * 1.6).round()),
                width: _width,
                height: _height,
                fallback: TitleArt(title: view.name, icon: _icon(view)),
              ),
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: Container(
                  padding: const EdgeInsets.fromLTRB(18, 30, 18, 14),
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.bottomCenter,
                      end: Alignment.topCenter,
                      colors: [Color(0xE6000000), Color(0x00000000)],
                    ),
                  ),
                  child: Text(
                    view.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Zt.title.copyWith(fontWeight: FontWeight.w700),
                  ),
                ),
              ),
            ]),
          ),
        ),
      ),
    );
  }

  static IconData _icon(LibraryView view) => switch (view.collectionType) {
        'tvshows' => Icons.tv_rounded,
        'movies' => Icons.movie_outlined,
        'boxsets' => Icons.collections_bookmark_outlined,
        'musicvideos' => Icons.music_video_outlined,
        'homevideos' => Icons.videocam_outlined,
        _ => Icons.video_library_outlined,
      };
}

/// Circular prev/next control of the hero. Mouse only: the D-pad switches what
/// the poster shows while the poster itself holds the focus.
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
