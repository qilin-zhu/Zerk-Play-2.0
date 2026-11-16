import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/app_services.dart';
import '../../core/fnos/fnos_client.dart';
import '../../core/fnos/fnos_item.dart';
import '../../l10n/l10n.dart';
import '../focus/focus_zone.dart';
import '../theme/tokens.dart';
import '../widgets/common.dart';
import '../widgets/media_row.dart';
import 'fnos_cards.dart';

/// fnOS keyword search (GET search/list?q=), debounced while typing.
class FnOsSearchPage extends StatefulWidget {
  const FnOsSearchPage({super.key});

  @override
  State<FnOsSearchPage> createState() => _FnOsSearchPageState();
}

class _FnOsSearchPageState extends State<FnOsSearchPage> {
  final _controller = TextEditingController();
  Timer? _debounce;
  List<FnOsItem>? _results;
  String _query = '';
  String? _error;
  bool _busy = false;

  FnosClient get _client => AppServicesScope.read(context).janus.fnos!;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _focusField());
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _focusField() {
    _debounce = Timer(const Duration(milliseconds: 50), () {
      if (!mounted) return;
      FocusScope.of(context).requestFocus();
    });
  }

  void _onChanged(String value) {
    _debounce?.cancel();
    final q = value.trim();
    if (q.isEmpty) {
      setState(() {
        _results = null;
        _query = '';
        _error = null;
      });
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 450), () => _search(q));
  }

  Future<void> _search(String q) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _query = q;
      _error = null;
    });
    try {
      final raw = await _client.search(q);
      final list = raw is List ? raw : raw is Map ? raw['list'] as List? ?? const [] : const [];
      if (!mounted) return;
      setState(() {
        _results = [for (final e in list) if (e is Map) FnOsItem.from(e)];
        _busy = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _busy = false;
      });
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
          padding: EdgeInsets.only(left: contentLeft, top: 70, right: 120, bottom: 26),
          child: Text(l10n.search, style: Zt.headline),
        ),
        Padding(
          padding: EdgeInsets.only(left: contentLeft, right: 120, bottom: 20),
          child: FocusZone(
            debugLabel: 'fnos-search-field',
            child: TextField(
              controller: _controller,
              onChanged: _onChanged,
              autofocus: false,
              autocorrect: false,
              enableSuggestions: false,
              style: Zt.label.copyWith(fontSize: 26),
              cursorColor: Zc.accent,
              textInputAction: TextInputAction.search,
              onSubmitted: (v) => _search(v.trim()),
              decoration: InputDecoration(
                hintText: l10n.searchHint,
                hintStyle: Zt.caption.copyWith(fontSize: 24),
                prefixIcon: const Icon(Icons.search_rounded, size: 30),
                filled: true,
                fillColor: Zc.surface,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide(color: Zc.outline)),
                enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide(color: Zc.outline)),
                focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: const BorderSide(color: Colors.white, width: 2)),
              ),
            ),
          ),
        ),
        Expanded(
          child: _error != null
              ? Padding(
                  padding: EdgeInsets.only(left: contentLeft, top: 20, right: 120),
                  child: Text(l10n.fnosLoadFailed(_error!), style: Zt.body),
                )
              : _query.isEmpty
                  ? Padding(
                      padding: EdgeInsets.only(left: contentLeft, top: 20, right: 120),
                      child: Text(l10n.searchHint, style: Zt.body.copyWith(color: Zc.textFaint)),
                    )
                  : _busy && results == null
                      ? const Padding(
                          padding: EdgeInsets.only(left: contentLeft, top: 30),
                          child: SizedBox(width: 40, height: 40, child: CircularProgressIndicator(strokeWidth: 3)),
                        )
                      : results != null && results.isEmpty
                          ? Padding(
                              padding: EdgeInsets.only(left: contentLeft, top: 20, right: 120),
                              child: Text(l10n.noResultsFor(_query), style: Zt.body),
                            )
                          : FocusZone(
                              debugLabel: 'fnos-search-results',
                              child: GridView.builder(
                                clipBehavior: Clip.none,
                                padding: EdgeInsets.fromLTRB(contentLeft, 16, 120, 140),
                                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                                  crossAxisCount: columns,
                                  mainAxisSpacing: 26,
                                  crossAxisSpacing: Zs.cardGap,
                                  childAspectRatio: cardW / (cardW * 1.5 + 70),
                                ),
                                itemCount: results?.length ?? 0,
                                itemBuilder: (context, i) => Align(
                                  alignment: Alignment.topLeft,
                                  child: FnOsPosterCard(item: results![i], width: cardW, autofocus: i == 0),
                                ),
                              ),
                            ),
        ),
      ]),
    );
  }
}
