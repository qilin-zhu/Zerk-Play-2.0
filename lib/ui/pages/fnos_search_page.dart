import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/app_services.dart';
import '../../core/fnos/fnos_client.dart';
import '../../core/fnos/fnos_item.dart';
import '../../core/fnos/fnos_title_index.dart';
import '../../core/host.dart';
import '../../core/log/app_log.dart';
import '../../core/text/pinyin.dart';
import '../../l10n/l10n.dart';
import '../focus/focus_zone.dart';
import '../theme/tokens.dart';
import '../widgets/media_row.dart';
import '../widgets/tv_keyboard.dart';
import 'fnos_cards.dart';

/// fnOS keyword search (GET search/list?q=), laid out like the Emby search:
/// a pill input with the loading spinner inside, the shared virtual keyboard
/// below it, then the result grid.
///
/// trimemedia matches whole Chinese words only, so the two things people
/// actually type — pinyin initials (`bbjx`) and part of a title (`步步`) — came
/// back empty. Those are matched locally against [FnosTitleIndex] and merged
/// with the server's answer, so the grid shows whatever either side found.
class FnOsSearchPage extends StatefulWidget {
  const FnOsSearchPage({super.key});

  @override
  State<FnOsSearchPage> createState() => _FnOsSearchPageState();
}

class _FnOsSearchPageState extends State<FnOsSearchPage> {
  final _controller = TextEditingController();
  final _field = FocusNode(debugLabel: 'fnos-search-field');
  Timer? _debounce;
  String _query = '';
  String? _error;
  bool _busy = false;

  /// What the server answered for the current term and what the local index
  /// matched, kept apart so one landing never wipes the other.
  List<FnOsItem> _remote = const [];
  List<FnOsItem> _local = const [];
  bool _settled = false;

  /// One request at a time, newest term last. trimemedia's search is a single
  /// keyword call, but it is not instant on a large library and the keyboard
  /// fires one per keystroke: without this the requests pile up and the answer
  /// for an old term can land after the one for the term on screen.
  bool _inflight = false;
  String? _queued;

  FnosClient get _client => AppServicesScope.read(context).janus.fnos!;

  /// Server hits first — they carry the full metadata — then the index hits the
  /// server could not find, without duplicates.
  List<FnOsItem> get _results {
    if (!_settled && _remote.isEmpty && _local.isEmpty) return const [];
    final seen = {for (final r in _remote) r.guid};
    return [..._remote, for (final l in _local) if (seen.add(l.guid)) l];
  }

  @override
  void initState() {
    super.initState();
    // Start the title crawl immediately: it runs in the background, a page at a
    // time, and the first search almost always lands on a partly built index.
    final index = FnosTitleIndex.of(_client);
    _index = index;
    index.revision.addListener(_refreshLocal);
  }

  FnosTitleIndex? _index;

  @override
  void dispose() {
    _index?.revision.removeListener(_refreshLocal);
    _refreshTimer?.cancel();
    _debounce?.cancel();
    _controller.dispose();
    _field.dispose();
    super.dispose();
  }

  /// The index grew: re-run the match for whatever is on screen. This is what
  /// makes a search started on a cold index fill itself in.
  ///
  /// Coalesced, because a page of 100 entries ticks the revision every ~140 ms
  /// and each match walks the whole index.
  Timer? _refreshTimer;

  void _refreshLocal() {
    _refreshTimer?.cancel();
    _refreshTimer = Timer(const Duration(milliseconds: 350), () {
      final q = _query;
      final index = _index;
      if (!mounted || q.isEmpty || index == null) return;
      final hits = index.find(q);
      if (hits.length == _local.length) return;
      setState(() => _local = hits);
    });
  }

  void _onChanged(String text) {
    _debounce?.cancel();
    final q = text.trim();
    if (q.isEmpty) {
      setState(() {
        _query = '';
        _remote = const [];
        _local = const [];
        _error = null;
        _busy = false;
        _settled = false;
      });
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 450), () => _search(q));
  }

  Future<void> _search(String raw) async {
    final q = cleanQuery(raw);
    if (q.isEmpty || q == _query) return;
    _query = q;
    setState(() {
      _remote = const [];
      _local = const [];
      _error = null;
      _busy = true;
      _settled = false;
    });
    // The local index answers from memory in microseconds; the server's own
    // search takes 6-8 s for a Chinese keyword and then usually answers with
    // nothing, so it is only asked when the index has no answer at all.
    _matchLocal(q);
    if (_local.isNotEmpty) {
      _queued = null;
      setState(() {
        _busy = false;
        _settled = true;
      });
      return;
    }
    if (_inflight) {
      _queued = q;
      return;
    }
    _inflight = true;
    var term = q;
    try {
      while (true) {
        final started = DateTime.now();
        try {
          final raw = await _client.search(term).timeout(const Duration(seconds: 30));
          final list = raw is List ? raw : raw is Map ? raw['list'] as List? ?? const [] : const [];
          // `Person` entries are cast, not media: they open onto nothing, and
          // they are most of what the server answers for a short query.
          final items = [
            for (final e in list)
              if (e is Map) FnOsItem.from(e),
          ].where((i) => i.kind != 'person').toList();
          AppLog.write('[fnos] search "$term" -> ${items.length} in '
              '${DateTime.now().difference(started).inMilliseconds} ms');
          if (!mounted) return;
          if (term == _query) setState(() => _remote = items);
        } catch (e) {
          if (mounted && term == _query) setState(() => _error = '$e');
        }
        final next = _queued;
        _queued = null;
        if (next == null || next == term) break;
        term = next;
      }
    } finally {
      _inflight = false;
      if (mounted) {
        setState(() {
          _busy = false;
          _settled = true;
        });
      }
    }
  }

  /// Pinyin initials and partial titles, matched against the account's own
  /// titles. Synchronous: the index is a plain in-memory scan, and the crawl
  /// that fills it ticks [FnosTitleIndex.revision] when it has more.
  void _matchLocal(String q) {
    final index = _index;
    if (index == null) return;
    final hits = index.find(q);
    if (hits.isEmpty) {
      if (_local.isNotEmpty) setState(() => _local = const []);
      return;
    }
    AppLog.write('[fnos] local match "$q": ${hits.length} of ${index.length}');
    setState(() => _local = hits);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final results = _results;
    final columns = AppServicesScope.of(context).settings.posterSize.columns;
    final cardW = posterGridCardWidth(MediaQuery.sizeOf(context).width, columns);
    return Material(
      color: Zc.background,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
          padding: const EdgeInsets.only(left: contentLeft, top: 70, right: 600, bottom: 28),
          child: FocusZone(
            debugLabel: 'fnos-search-field',
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
                      autocorrect: false,
                      enableSuggestions: false,
                      onChanged: _onChanged,
                      onSubmitted: (v) {
                        _search(v.trim());
                        ZoneNavigator.move(TraversalDirection.down);
                      },
                      style: Zt.title.copyWith(fontWeight: FontWeight.w500),
                      cursorColor: Zc.accent,
                      decoration: InputDecoration(
                        border: InputBorder.none,
                        hintText: l10n.searchHint,
                        hintStyle: Zt.title.copyWith(color: Zc.textFaint, fontWeight: FontWeight.w400),
                      ),
                    ),
                  ),
                  if (_busy) const SizedBox(width: 26, height: 26, child: CircularProgressIndicator(strokeWidth: 3)),
                ]),
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(left: contentLeft, bottom: 30),
          child: TvKeyboard(controller: _controller, onChanged: _onChanged),
        ),
        Expanded(
          child: _error != null
              ? Padding(
                  padding: EdgeInsets.only(left: contentLeft, top: 10, right: 120),
                  child: Text(l10n.fnosLoadFailed(_error!), style: Zt.body),
                )
              : _query.isEmpty
                  ? Padding(
                      padding: EdgeInsets.only(left: contentLeft, top: 10, right: 120),
                      child: Text(l10n.searchHint, style: Zt.body.copyWith(color: Zc.textFaint)),
                    )
                  : results.isEmpty
                      ? Padding(
                          padding: EdgeInsets.only(left: contentLeft, top: 10, right: 120),
                          // "No results" is only honest once the index has been
                          // crawled to the end: before that the page is still
                          // filling in and the text would flash on every search.
                          child: Text(_settled && (_index?.complete ?? true) ? l10n.noResultsFor(_query) : '',
                              style: Zt.body.copyWith(color: Zc.textFaint)),
                        )
                      : FocusZone(
                      debugLabel: 'fnos-search-results',
                      child: GridView.builder(
                        clipBehavior: Clip.none,
                        padding: EdgeInsets.fromLTRB(contentLeft, 8, 120, 140),
                        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: columns,
                          mainAxisSpacing: 26,
                          crossAxisSpacing: Zs.cardGap,
                          childAspectRatio: cardW / (cardW * 1.5 + 70),
                        ),
                        itemCount: results.length,
                        itemBuilder: (context, i) => Align(
                          alignment: Alignment.topLeft,
                          child: FnOsPosterCard(item: results[i], width: cardW, autofocus: i == 0),
                        ),
                      ),
                    ),
        ),
      ]),
    );
  }
}
