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

/// What a fnOS library page lists.
enum FnOsLibraryKind {
  movies(<String>['Movie']),
  shows(<String>['TV']),
  favorites(<String>[]);

  const FnOsLibraryKind(this.types);

  final List<String> types;
}

/// A paged poster wall backed by item/list (movies / shows), favorite/list
/// (favorites) or an ancestor guid (a media library from mediadb/list).
class FnOsLibraryPage extends StatefulWidget {
  const FnOsLibraryPage({super.key, required this.kind, this.title, this.ancestorGuid, this.items});

  final FnOsLibraryKind kind;
  final String? title;
  final String? ancestorGuid;

  /// Preloaded items (search results, collection content); skips fetching.
  final List<FnOsItem>? items;

  @override
  State<FnOsLibraryPage> createState() => _FnOsLibraryPageState();
}

class _FnOsLibraryPageState extends State<FnOsLibraryPage> {
  List<FnOsItem>? _items;
  String? _error;
  bool _busy = false;

  FnosClient get _client => AppServicesScope.read(context).janus.fnos!;

  @override
  void initState() {
    super.initState();
    if (widget.items == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _reload());
    }
  }

  Future<void> _reload() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final client = _client;
      final items = <FnOsItem>[];
      for (var page = 1; page <= 10; page++) {
        final Object? data;
        if (widget.ancestorGuid != null && widget.ancestorGuid!.isNotEmpty) {
          data = await client.itemList(ancestorGuid: widget.ancestorGuid, pageSize: 60, page: page);
        } else if (widget.kind == FnOsLibraryKind.favorites) {
          data = await client.favoriteList(pageSize: 60, page: page);
        } else {
          data = await client.itemList(types: widget.kind.types, pageSize: 60, page: page);
        }
        final list = data is List ? data : data is Map ? data['list'] as List? ?? const [] : const [];
        if (list.isEmpty) break;
        items.addAll([for (final e in list) if (e is Map) FnOsItem.from(e)]);
        final total = data is Map ? (data['total'] as num?)?.toInt() ?? 0 : 0;
        if (items.length >= total) break;
      }
      if (!mounted) return;
      setState(() {
        _items = items;
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
    final items = widget.items ?? _items;
    final columns = AppServicesScope.of(context).settings.posterSize.columns;
    final cardW = posterGridCardWidth(MediaQuery.sizeOf(context).width, columns);
    final title = widget.title ??
        switch (widget.kind) {
          FnOsLibraryKind.movies => l10n.movies,
          FnOsLibraryKind.shows => l10n.shows,
          FnOsLibraryKind.favorites => l10n.favorites,
        };
    return Material(
      color: Zc.background,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
          padding: EdgeInsets.only(left: contentLeft, top: 70, right: 120, bottom: 26),
          child: Row(children: [
            Text(title, style: Zt.headline),
            const SizedBox(width: 18),
            if (items != null && items.isNotEmpty) Text('${items.length}', style: Zt.title.copyWith(color: Zc.textFaint)),
          ]),
        ),
        Expanded(
          child: _error != null
              ? Padding(
                  padding: EdgeInsets.only(left: contentLeft, top: 40, right: 120),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    ConstrainedBox(constraints: const BoxConstraints(maxWidth: 900), child: Text(l10n.fnosLoadFailed(_error!), style: Zt.body)),
                    const SizedBox(height: 24),
                    TvButton(label: l10n.tryAgain, icon: Icons.refresh_rounded, onSelect: _reload),
                  ]),
                )
              : items != null && items.isEmpty
                  ? Padding(
                      padding: EdgeInsets.only(left: contentLeft, top: 40, right: 120),
                      child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 900), child: Text(l10n.fnosEmpty, style: Zt.body)),
                    )
                  : FocusZone(
                      debugLabel: 'fnos-library',
                      child: GridView.builder(
                        clipBehavior: Clip.none,
                        padding: EdgeInsets.fromLTRB(contentLeft, 16, 120, 140),
                        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: columns,
                          mainAxisSpacing: 26,
                          crossAxisSpacing: Zs.cardGap,
                          childAspectRatio: cardW / (cardW * 1.5 + 70),
                        ),
                        itemCount: items?.length ?? 14,
                        itemBuilder: (context, i) {
                          if (items == null) return SkeletonBox(width: cardW, height: cardW * 1.5);
                          return Align(
                            alignment: Alignment.topLeft,
                            child: FnOsPosterCard(item: items[i], width: cardW, autofocus: i == 0),
                          );
                        },
                      ),
                    ),
        ),
      ]),
    );
  }
}
