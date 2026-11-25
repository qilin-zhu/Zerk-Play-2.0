import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/app_services.dart';
import '../../core/emby/models/emby_item.dart';
import '../../core/host.dart';
import '../../core/log/app_log.dart';
import '../../data/catalog_api.dart';
import '../../data/recommendations.dart';
import '../../data/seerr_api.dart';
import '../../l10n/l10n.dart';
import '../focus/focus_zone.dart';
import '../theme/tokens.dart';
import '../widgets/cards.dart';
import '../widgets/media_row.dart';
import '../widgets/tv_keyboard.dart';
import 'routes.dart';

class SearchPage extends StatefulWidget {
  const SearchPage({super.key});

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  final _controller = TextEditingController();
  final _field = FocusNode(debugLabel: 'search-field');
  Timer? _debounce;
  String _query = '';

  /// Newest search wins: every part of a search carries the token it started
  /// with, and only the current one is allowed to write into the page.
  int _token = 0;

  /// Parts of the current search still running, so the spinner ends with the
  /// last of them instead of guessing.
  int _parts = 0;
  bool _searching = false;

  /// One library query at a time. A slow Emby answers a `SearchTerm` in tens of
  /// seconds, and the old code fired one per keystroke *and* one per type; the
  /// queue that made is what turned a search into a wait. Now the newest term
  /// waits for the running one and then runs alone.
  bool _inflight = false;
  String? _queued;

  List<EmbyItem> _movies = const [];
  List<EmbyItem> _shows = const [];
  List<EmbyItem> _collections = const [];
  List<SeerrMedia> _requestable = const [];

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    _field.dispose();
    super.dispose();
  }

  void _onChanged(String text) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () => _search(text.trim()));
  }

  void _partDone(int token, [VoidCallback? write]) {
    if (!mounted || token != _token) return;
    setState(() {
      write?.call();
      _parts = _parts > 0 ? _parts - 1 : 0;
      _searching = _parts > 0;
    });
  }

  Future<void> _search(String q) async {
    if (q == _query) return;
    _query = q;
    final token = ++_token;
    if (q.length < 2) {
      setState(() {
        _movies = _shows = _collections = const [];
        _requestable = const [];
        _parts = 0;
        _searching = false;
      });
      return;
    }
    final s = AppServicesScope.read(context);
    final c = s.catalog;
    // Seerr/TMDB only adds rows on top of the library hits, so it never blocks
    // them: it runs beside them and writes its rows when it lands.
    final external = s.tmdb == null && s.seerr == null
        ? null
        : s.recommender.search(q).then(s.recommender.resolve).then<MixedItems?>((v) => v, onError: (Object e) {
            debugPrint('[search] TMDB / *seerr: $e');
            return null;
          });
    setState(() {
      _parts = 1 + 1 + (external == null ? 0 : 1);
      _searching = true;
    });
    unawaited(_library(c, q, token));
    unawaited(_collectionHits(c, q, token));
    if (external != null) unawaited(_external(s, external, token));
  }

  /// Every library hit in a single request. It used to be three (Movie, Series
  /// and **Episode**) sent in parallel and joined by `Future.wait`, so the page
  /// showed nothing until the slowest one — the episode search, the most
  /// expensive of the three, since it scans every episode title in the library
  /// — came back. Split by type on this side instead: one round trip, and the
  /// rows are up as soon as it lands.
  Future<void> _library(CatalogApi c, String q, int token) async {
    if (_inflight) {
      _queued = q;
      return;
    }
    _inflight = true;
    var term = q;
    try {
      while (true) {
        final attempt = _token;
        final started = DateTime.now();
        var items = const <EmbyItem>[];
        try {
          final page = await c
              .query(types: const ['Movie', 'Series'], searchTerm: term, limit: 40, sortBy: 'SortName')
              .timeout(const Duration(seconds: 30));
          items = page.items;
        } catch (e) {
          debugPrint('[search] library "$term": $e');
        }
        final ms = DateTime.now().difference(started).inMilliseconds;
        AppLog.write('[search] "$term" -> ${items.length} library hits in $ms ms');
        if (mounted && (attempt == _token || term == _query)) {
          _partDone(attempt, () {
            final movies = [for (final i in items) if (!i.isSeries) i];
            final shows = [for (final i in items) if (i.isSeries) i];
            if (term == _query) {
              _movies = movies;
              _shows = shows;
            }
          });
        }
        final next = _queued;
        _queued = null;
        if (next == null || next == term) break;
        term = next;
      }
    } finally {
      _inflight = false;
    }
  }

  Future<void> _collectionHits(CatalogApi c, String q, int token) async {
    final collections = await _matchingCollections(c, q);
    _partDone(token, () {
      if (q == _query) _collections = collections;
    });
  }

  Future<void> _external(AppServices s, Future<MixedItems?> external, int token) async {
    final resolved = await external ?? const [];
    _partDone(token, () {
      if (token != _token) return;
      final have = {for (final i in [..._movies, ..._shows]) i.id};
      final owned = {for (final i in [..._movies, ..._shows]) ?i.tmdbId};
      final movies = [..._movies];
      final shows = [..._shows];
      for (final item in resolved.whereType<EmbyItem>()) {
        if (!have.add(item.id)) continue;
        (item.isSeries ? shows : movies).add(item);
      }
      _movies = movies;
      _shows = shows;
      _requestable = s.seerr == null
          ? const []
          : [
              for (final m in resolved.whereType<SeerrMedia>())
                if (!m.availability.isOnServer && !owned.contains(m.tmdbId)) m,
            ];
    });
  }

  static Future<List<EmbyItem>> _matchingCollections(CatalogApi c, String q) async {
    final words = _fold(q).split(' ').where((w) => w.isNotEmpty).toList();
    try {
      final all = await c.allCollections().timeout(const Duration(seconds: 8));
      return [
        for (final col in all)
          if (words.every(_fold(col.name).contains)) col,
      ].take(30).toList();
    } catch (e) {
      debugPrint('[search] collections: $e');
      return const [];
    }
  }

  static const _accents = {'ă': 'a', 'â': 'a', 'á': 'a', 'à': 'a', 'ä': 'a', 'î': 'i', 'í': 'i', 'ș': 's', 'ş': 's',
      'ț': 't', 'ţ': 't', 'é': 'e', 'è': 'e', 'ê': 'e', 'ë': 'e', 'ó': 'o', 'ö': 'o', 'ô': 'o', 'ú': 'u', 'ü': 'u', 'ñ': 'n', 'ç': 'c'};

  static String _fold(String s) =>
      s.toLowerCase().split('').map((ch) => _accents[ch] ?? ch).join().replaceAll(RegExp(r'[^a-z0-9]+'), ' ');

  @override
  Widget build(BuildContext context) {
    final nothing = _query.length >= 2 && !_searching && _movies.isEmpty && _shows.isEmpty &&
        _collections.isEmpty && _requestable.isEmpty;
    return ListView(
      padding: const EdgeInsets.only(top: 70, bottom: 140),
      children: [
        Padding(
          padding: const EdgeInsets.only(left: contentLeft, right: 600, bottom: 28),
          child: FocusZone(
            debugLabel: 'search-field',
            child: ListenableBuilder(
              listenable: _field,
              builder: (context, _) => AnimatedContainer(
                duration: Zm.fast,
                padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 6),
                decoration: BoxDecoration(
                  color: _field.hasFocus ? Zc.surfaceTop : Zc.surface,
                  borderRadius: BorderRadius.circular(40),
                  border: Border.all(color: _field.hasFocus ? Colors.white : Zc.outline, width: 2),
                ),
                child: Row(children: [
                  const Icon(Icons.search_rounded, size: 34, color: Zc.textMuted),
                  const SizedBox(width: 18),
                  Expanded(
                    child: TextField(
                      controller: _controller,
                      focusNode: _field,
                      autofocus: true,
                      keyboardType: Host.isAndroid ? TextInputType.none : null,
                      onChanged: _onChanged,
                      onSubmitted: (v) {
                        _search(v.trim());
                        ZoneNavigator.move(TraversalDirection.down);
                      },
                      style: Zt.title.copyWith(fontWeight: FontWeight.w500),
                      cursorColor: Zc.accent,
                      decoration: InputDecoration(
                        border: InputBorder.none,
                        hintText: context.l10n.searchHint,
                        hintStyle: Zt.title.copyWith(color: Zc.textFaint, fontWeight: FontWeight.w400),
                      ),
                    ),
                  ),
                  if (_searching) const SizedBox(width: 26, height: 26, child: CircularProgressIndicator(strokeWidth: 3)),
                ]),
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(left: contentLeft, bottom: 40),
          child: TvKeyboard(controller: _controller, onChanged: _onChanged),
        ),
        if (nothing)
          Padding(
            padding: const EdgeInsets.only(left: contentLeft),
            child: Text(context.l10n.noResultsFor(_query), style: Zt.body),
          ),
        if (_movies.isNotEmpty) _posterRow(context.l10n.movies, _movies),
        if (_shows.isNotEmpty) _posterRow(context.l10n.shows, _shows),
        if (_collections.isNotEmpty) _posterRow(context.l10n.collections, _collections),
        if (_requestable.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: Zs.rowGap),
            child: MediaRow(
              title: context.l10n.notInLibrary,
              trailingTitle: Text(context.l10n.requestWithSeerr, style: Zt.caption.copyWith(color: Zc.request)),
              height: Zs.posterWidth * 1.5 + 90,
              itemCount: _requestable.length,
              itemBuilder: (context, i) => Padding(
                padding: const EdgeInsets.only(top: 12),
                child: RequestPosterCard(media: _requestable[i], onSelect: () => openRequest(context, _requestable[i])),
              ),
            ),
          ),
      ],
    );
  }

  Widget _posterRow(String title, List<EmbyItem> items) => Padding(
        padding: const EdgeInsets.only(bottom: Zs.rowGap),
        child: MediaRow(
          title: title,
          trailingTitle: Text(context.l10n.inYourLibrary, style: Zt.caption.copyWith(color: Zc.accentSoft)),
          height: Zs.posterWidth * 1.5 + 90,
          itemCount: items.length,
          itemBuilder: (context, i) => Padding(
            padding: const EdgeInsets.only(top: 12),
            child: PosterCard(item: items[i], onSelect: () => openItem(context, items[i])),
          ),
        ),
      );
}
