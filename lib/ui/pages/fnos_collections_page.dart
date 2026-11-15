import 'package:flutter/material.dart';

import '../../app/app_services.dart';
import '../../core/fnos/fnos_client.dart';
import '../../l10n/l10n.dart';
import '../core/navigation.dart';
import '../focus/focus_zone.dart';
import '../focus/tv_focusable.dart';
import '../theme/tokens.dart';
import '../widgets/common.dart';
import '../widgets/media_row.dart';
import '../widgets/net_image.dart';
import 'fnos_library_page.dart';

/// One row of mediadb/list: guid, title, posters, category.
final class FnOsMediaDb {
  FnOsMediaDb.from(Map raw)
      : guid = raw['guid']?.toString() ?? '',
        title = raw['title']?.toString() ?? '',
        category = raw['category']?.toString() ?? '',
        posters = [
          for (final p in (raw['posters'] as List? ?? const []))
            if (p != null) p.toString(),
        ];

  final String guid;
  final String title;
  final String category;
  final List<String> posters;

  String? get poster => posters.isEmpty ? null : posters.first;
}

/// fnOS media libraries (the analog of Emby collections): covers from
/// mediadb/list; tapping opens the library's contents.
class FnOsCollectionsPage extends StatefulWidget {
  const FnOsCollectionsPage({super.key});

  @override
  State<FnOsCollectionsPage> createState() => _FnOsCollectionsPageState();
}

class _FnOsCollectionsPageState extends State<FnOsCollectionsPage> {
  List<FnOsMediaDb>? _dbs;
  String? _error;
  bool _busy = false;

  FnosClient get _client => AppServicesScope.read(context).janus.fnos!;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _reload());
  }

  Future<void> _reload() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final raw = await _client.mediaDbList();
      if (!mounted) return;
      setState(() {
        _dbs = [for (final e in (raw is List ? raw : const [])) if (e is Map) FnOsMediaDb.from(e)];
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
    final dbs = _dbs;
    return Material(
      color: Zc.background,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
          padding: EdgeInsets.only(left: contentLeft, top: 70, right: 120, bottom: 26),
          child: Text(l10n.navLibrary, style: Zt.headline),
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
              : dbs != null && dbs.isEmpty
                  ? Padding(
                      padding: EdgeInsets.only(left: contentLeft, top: 40, right: 120),
                      child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 900), child: Text(l10n.fnosEmpty, style: Zt.body)),
                    )
                  : FocusZone(
                      debugLabel: 'fnos-collections',
                      child: GridView.builder(
                        clipBehavior: Clip.none,
                        padding: EdgeInsets.fromLTRB(contentLeft, 16, 120, 140),
                        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                          maxCrossAxisExtent: 420,
                          mainAxisSpacing: 30,
                          crossAxisSpacing: Zs.cardGap,
                          childAspectRatio: 2.1,
                        ),
                        itemCount: dbs?.length ?? 4,
                        itemBuilder: (context, i) {
                          if (dbs == null) return const SkeletonBox();
                          final db = dbs[i];
                          return _LibraryCard(db: db, client: _client);
                        },
                      ),
                    ),
        ),
      ]),
    );
  }
}

class _LibraryCard extends StatelessWidget {
  const _LibraryCard({required this.db, required this.client});

  final FnOsMediaDb db;
  final FnosClient client;

  @override
  Widget build(BuildContext context) {
    final poster = db.poster;
    return TvFocusable(
      autofocus: true,
      onSelect: () => Navigator.of(context).push(
        tvRoute(
          FnOsLibraryPage(kind: FnOsLibraryKind.favorites, title: db.title, ancestorGuid: db.guid),
          name: 'fnos-lib:${db.guid}',
        ),
      ),
      builder: (context, focused) => Container(
        decoration: BoxDecoration(
          color: focused ? Zc.surfaceTop : Zc.surface,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: focused ? Colors.white : Zc.outline, width: focused ? 2.5 : 1.2),
        ),
        padding: const EdgeInsets.all(18),
        child: Row(children: [
          SizedBox(
            width: 110,
            height: 158,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: NetImage(
                url: poster == null ? null : Uri.parse(client.imageUrl(poster, width: 220)),
                headers: client.imageHeaders,
                fallback: TitleArt(title: db.title, icon: Icons.video_library_rounded),
              ),
            ),
          ),
          const SizedBox(width: 20),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(db.title, style: Zt.title, maxLines: 1, overflow: TextOverflow.ellipsis),
              if (db.category.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(db.category, style: Zt.caption.copyWith(fontSize: 20, color: Zc.textFaint)),
                ),
            ]),
          ),
        ]),
      ),
    );
  }
}
