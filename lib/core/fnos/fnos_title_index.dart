import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/log/app_log.dart';
import '../text/pinyin.dart';
import 'fnos_client.dart';
import 'fnos_item.dart';

/// Every title the account can play, indexed for the searches trimemedia
/// cannot serve.
///
/// Measured against a real server, `search/list` is not usable here: a Chinese
/// keyword takes 6-8 s and then answers with an empty list (its own timeout),
/// letters answer in 50 ms, and pinyin is not supported at all. So the app lists
/// the libraries itself and matches locally — `bbjx` and a partial `步步` both
/// work that way, and the results do not depend on the server's search index.
///
/// The crawl is deliberately gentle: one request at a time, a short pause
/// between pages, a page is 100 entries and takes ~0.1 s, so the whole account
/// (a few thousand entries on this server) is covered in well under a minute.
/// [revision] ticks as pages land, so an open search page can refine what it is
/// showing instead of waiting for the end.
final class FnosTitleIndex {
  FnosTitleIndex._();

  /// Compact copies of the server's own payloads: everything a poster card
  /// needs, without keeping a decoded object graph per entry.
  final List<Map<String, Object?>> _raw = [];
  final List<String> _titles = [];
  final List<String> _initials = [];
  final List<String> _letters = [];
  final Set<String> _guids = {};

  /// Bumped after every page, and at the end.
  final ValueNotifier<int> revision = ValueNotifier(0);

  bool get complete => _done;
  bool _done = false;
  bool _running = false;
  int get length => _raw.length;

  static final _cache = <String, FnosTitleIndex>{};
  static final _builds = <String, Future<void>>{};

  /// The index for [client]'s server. The first call starts the crawl in the
  /// background; callers use whatever is already there and listen to
  /// [revision] for the rest.
  static FnosTitleIndex of(FnosClient client) {
    final index = _cache.putIfAbsent(client.base, FnosTitleIndex._new);
    if (!index._running && !index._done) {
      index._running = true;
      _builds[client.base] = index._build(client).whenComplete(() => index._running = false);
    }
    return index;
  }

  static FnosTitleIndex _new() => FnosTitleIndex._();

  static void clear() {
    _cache.clear();
    _builds.clear();
  }

  /// Everything the query matches, best first.
  List<FnOsItem> find(String query, {int limit = 40}) {
    final key = pinyinKey(query);
    final plain = cleanQuery(query).toLowerCase();
    if (key.isEmpty && plain.isEmpty) return const [];
    final ranked = <(int, int)>[];
    for (var i = 0; i < _raw.length; i++) {
      final title = _titles[i];
      final exact = plain.isNotEmpty && title.contains(plain);
      final rank = key.isEmpty ? 0 : _rank(i, key);
      if (!exact && rank == 0) continue;
      // A title that *is* the query, then one that starts with it, then any hit.
      final score = title == plain ? 0 : (exact || rank == 1 ? 1 : 2);
      ranked.add((score, i));
    }
    ranked.sort((a, b) => a.$1 != b.$1 ? a.$1.compareTo(b.$1) : a.$2.compareTo(b.$2));
    return [for (final e in ranked.take(limit)) FnOsItem.from(_raw[e.$2])];
  }

  int _rank(int i, String key) {
    if (_initials[i].startsWith(key) || _letters[i].startsWith(key)) return 1;
    if (_initials[i].contains(key) || _letters[i].contains(key)) return 2;
    return 0;
  }

  Future<void> _build(FnosClient client) async {
    final clock = Stopwatch()..start();
    const types = ['Movie', 'TV', 'Directory', 'Video', 'LiveChannel'];
    var requests = 0;
    try {
      // The account's own entries first: one call, ~100 ms, and it is the part a
      // viewer actually opens.
      requests += await _crawl(client, null, types);
      final dbs = await client.mediaDbList().timeout(const Duration(seconds: 6));
      for (final raw in (dbs is List ? dbs : const [])) {
        if (raw is! Map) continue;
        final guid = raw['guid']?.toString();
        if (guid == null || guid.isEmpty) continue;
        requests += await _crawl(client, guid, types);
        if (clock.elapsed > const Duration(seconds: 150)) {
          AppLog.write('[fnos] title index: stopped at the time budget');
          break;
        }
      }
    } catch (e) {
      AppLog.write('[fnos] title index stopped: $e');
    }
    _done = true;
    _running = false;
    revision.value++;
    AppLog.write('[fnos] title index: ${_raw.length} entries in '
        '${clock.elapsedMilliseconds} ms ($requests requests)');
  }

  /// One library, page by page until the server stops returning entries.
  Future<int> _crawl(FnosClient client, String? ancestor, List<String> types) async {
    var requests = 0;
    for (var page = 1; page <= 60; page++) {
      List<FnOsItem> items;
      List<Map<String, Object?>> raw;
      try {
        final data = await client
            .itemList(ancestorGuid: ancestor, pageSize: 100, page: page, types: types)
            .timeout(const Duration(seconds: 20));
        final list = data is List ? data : data is Map ? data['list'] as List? ?? const [] : const [];
        raw = [for (final e in list) if (e is Map) Map<String, Object?>.from(e)];
        items = [for (final e in raw) FnOsItem.from(e)];
      } catch (e) {
        // A library that times out keeps whatever earlier pages delivered.
        debugPrint('[fnos] index page ${ancestor ?? 'own'} $page: $e');
        break;
      }
      requests++;
      var added = 0;
      for (var i = 0; i < items.length; i++) {
        final item = items[i];
        if (item.guid.isEmpty || item.kind == 'person') continue;
        if (!_guids.add(item.guid)) continue;
        final title = item.displayTitle;
        _raw.add(raw[i]);
        _titles.add(title.toLowerCase());
        final key = TitleKey(title);
        _initials.add(key.initials);
        _letters.add(key.letters);
        added++;
      }
      if (added > 0) revision.value++;
      if (items.length < 100) break;
      // Gentle on a NAS that is also serving playback.
      await Future<void>.delayed(const Duration(milliseconds: 40));
    }
    return requests;
  }
}
