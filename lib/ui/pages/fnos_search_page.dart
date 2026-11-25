import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/app_services.dart';
import '../../core/fnos/fnos_client.dart';
import '../../core/fnos/fnos_item.dart';
import '../../core/host.dart';
import '../../core/log/app_log.dart';
import '../../l10n/l10n.dart';
import '../focus/focus_zone.dart';
import '../theme/tokens.dart';
import '../widgets/media_row.dart';
import '../widgets/tv_keyboard.dart';
import 'fnos_cards.dart';

/// fnOS keyword search (GET search/list?q=), laid out like the Emby search:
/// a pill input with the loading spinner inside, the shared virtual keyboard
/// below it, then the result grid.
class FnOsSearchPage extends StatefulWidget {
  const FnOsSearchPage({super.key});

  @override
  State<FnOsSearchPage> createState() => _FnOsSearchPageState();
}

class _FnOsSearchPageState extends State<FnOsSearchPage> {
  final _controller = TextEditingController();
  final _field = FocusNode(debugLabel: 'fnos-search-field');
  Timer? _debounce;
  List<FnOsItem>? _results;
  String _query = '';
  String? _error;
  bool _busy = false;

  /// One request at a time, newest term last. trimemedia's search is a single
  /// keyword call, but it is not instant on a large library and the keyboard
  /// fires one per keystroke: without this the requests pile up and the answer
  /// for an old term can land after the one for the term on screen.
  bool _inflight = false;
  String? _queued;

  FnosClient get _client => AppServicesScope.read(context).janus.fnos!;

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    _field.dispose();
    super.dispose();
  }

  void _onChanged(String text) {
    _debounce?.cancel();
    final q = text.trim();
    if (q.isEmpty) {
      setState(() {
        _results = null;
        _query = '';
        _error = null;
        _busy = false;
      });
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 450), () => _search(q));
  }

  Future<void> _search(String q) async {
    if (q.isEmpty || q == _query) return;
    _query = q;
    if (_inflight) {
      _queued = q;
      return;
    }
    _inflight = true;
    var term = q;
    try {
      while (true) {
        setState(() {
          _busy = true;
          _error = null;
        });
        final started = DateTime.now();
        try {
          final raw = await _client.search(term).timeout(const Duration(seconds: 30));
          final list = raw is List ? raw : raw is Map ? raw['list'] as List? ?? const [] : const [];
          final items = [for (final e in list) if (e is Map) FnOsItem.from(e)];
          AppLog.write('[fnos] search "$term" -> ${items.length} in '
              '${DateTime.now().difference(started).inMilliseconds} ms');
          if (!mounted) return;
          if (term == _query) setState(() => _results = items);
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
      if (mounted) setState(() => _busy = false);
    }
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
              : results == null
                  ? Padding(
                      padding: EdgeInsets.only(left: contentLeft, top: 10, right: 120),
                      child: Text(l10n.searchHint, style: Zt.body.copyWith(color: Zc.textFaint)),
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
