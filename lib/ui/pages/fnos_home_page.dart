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
import 'fnos_item_page.dart';

/// One entry of trimemedia's `item/list` response, parsed defensively: the
/// server's field set varies by type (movie / tv / episode / video / folder).
final class FnOsItem {
  FnOsItem.from(Map raw)
      : guid = raw['guid']?.toString() ?? '',
        title = raw['title']?.toString() ?? '',
        tvTitle = raw['tv_title']?.toString() ?? '',
        parentGuid = raw['parent_guid']?.toString() ?? '',
        type = raw['type']?.toString() ?? '',
        poster = raw['poster']?.toString(),
        posterList = [
          for (final p in (raw['poster_list'] as List? ?? const []))
            if (p != null) p.toString(),
        ],
        seasonNumber = (raw['season_number'] as num?)?.toInt(),
        episodeNumber = (raw['episode_number'] as num?)?.toInt(),
        numberOfSeasons = (raw['number_of_seasons'] as num?)?.toInt(),
        releaseDate = raw['release_date']?.toString(),
        voteAverage = raw['vote_average']?.toString(),
        watched = raw['watched']?.toString() == '1',
        duration = (raw['duration'] as num?)?.toInt();

  final String guid;
  final String title;
  final String tvTitle;
  final String parentGuid;
  final String type;
  final String? poster;
  final List<String> posterList;
  final int? seasonNumber;
  final int? episodeNumber;
  final int? numberOfSeasons;
  final String? releaseDate;
  final String? voteAverage;
  final bool watched;
  final int? duration;

  String? get posterPath {
    final p = poster?.trim();
    if (p != null && p.isNotEmpty) return p;
    if (posterList.isNotEmpty) return posterList.first;
    return null;
  }

  /// Episodes carry the show title in `tv_title`; use it as the grid title
  /// (mirrors FlyNarwhal's buildPlayDetailTitle).
  String get displayTitle {
    final t = tvTitle.trim();
    return (type == 'episode' && t.isNotEmpty) ? t : (title.trim().isEmpty ? tvTitle.trim() : title.trim());
  }

  String? get subtitle {
    if (type == 'episode') {
      final s = seasonNumber ?? 0;
      final e = episodeNumber ?? 0;
      if (s > 0 || e > 0) return 'S$s E$e';
      return null;
    }
    final date = releaseDate?.trim();
    return date != null && date.length >= 4 ? date.substring(0, 4) : null;
  }

  IconData get icon => switch (type) {
        'tv' => Icons.tv_rounded,
        'episode' => Icons.smart_display_outlined,
        'directory' => Icons.folder_outlined,
        _ => Icons.movie_outlined,
      };
}

/// Landing page for 飞牛影视 (fnOS trimemedia) sessions: a poster wall of
/// everything the server has, straight from `item/list`.
class FnOsHomePage extends StatefulWidget {
  const FnOsHomePage({super.key});

  @override
  State<FnOsHomePage> createState() => _FnOsHomePageState();
}

class _FnOsHomePageState extends State<FnOsHomePage> {
  List<FnOsItem>? _items;
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
      final client = _client;
      final items = <FnOsItem>[];
      for (var page = 1; page <= 6; page++) {
        final data = await client.itemList(pageSize: 60, page: page);
        final list = _rawList(data);
        if (list.isEmpty) break;
        items.addAll([for (final e in list) if (e is Map) FnOsItem.from(e.cast<String, Object?>())]);
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

  static List _rawList(Object? data) {
    if (data is List) return data;
    if (data is Map) return data['list'] as List? ?? const [];
    return const [];
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final items = _items;
    final columns = AppServicesScope.of(context).settings.posterSize.columns;
    return Scaffold(
      body: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
          padding: EdgeInsets.only(left: contentLeft, top: 70, right: 120, bottom: 26),
          child: Row(children: [
            Text(l10n.fnosHomeTitle, style: Zt.headline),
            const SizedBox(width: 18),
            if (items != null && items.isNotEmpty) Text('${items.length}', style: Zt.title.copyWith(color: Zc.textFaint)),
            const Spacer(),
            FocusZone(
              debugLabel: 'fnos-header-actions',
              child: Row(children: [
                TvButton(
                  label: _busy ? l10n.fnosRefreshing : l10n.tryAgain,
                  icon: Icons.refresh_rounded,
                  onSelect: _reload,
                ),
                const SizedBox(width: 16),
                TvButton(
                  label: l10n.signOut,
                  icon: Icons.logout_rounded,
                  onSelect: () => AppServicesScope.read(context).signOut(),
                ),
              ]),
            ),
          ]),
        ),
        Expanded(
          child: _error != null
              ? _message(l10n.fnosLoadFailed(_error!), l10n.tryAgain, _reload)
              : items != null && items.isEmpty
                  ? _message(l10n.fnosEmpty, l10n.tryAgain, _reload)
                  : LayoutBuilder(builder: (context, box) {
                      final cardW = posterGridCardWidth(box.maxWidth, columns);
                      return FocusZone(
                        debugLabel: 'fnos-grid',
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
                            final data = items[i];
                            return Align(
                              alignment: Alignment.topLeft,
                              child: LayoutBuilder(
                                builder: (context, inner) =>
                                    _FnosCard(item: data, width: inner.maxWidth, autofocus: i == 0),
                              ),
                            );
                          },
                        ),
                      );
                    }),
        ),
      ]),
    );
  }

  Widget _message(String text, String action, VoidCallback onSelect) => Padding(
        padding: EdgeInsets.only(left: contentLeft, top: 40, right: 120),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          ConstrainedBox(constraints: const BoxConstraints(maxWidth: 900), child: Text(text, style: Zt.body)),
          const SizedBox(height: 24),
          TvButton(label: action, icon: Icons.refresh_rounded, onSelect: onSelect),
        ]),
      );
}

class _FnosCard extends StatelessWidget {
  const _FnosCard({required this.item, required this.width, this.autofocus = false});

  final FnOsItem item;
  final double width;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    final client = AppServicesScope.read(context).janus.fnos;
    final path = item.posterPath;
    final height = width * 1.5;
    return TvFocusable(
      autofocus: autofocus,
      onSelect: () => Navigator.of(context).push(
        tvRoute(FnOsItemPage(guid: item.guid, seed: item), name: 'fnos:${item.guid}'),
      ),
      builder: (context, focused) => SizedBox(
        width: width,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          FocusFrame(
            focused: focused,
            child: SizedBox(
              width: width,
              height: height,
              child: Stack(fit: StackFit.expand, children: [
                NetImage(
                  url: path == null || client == null ? null : Uri.parse(client.imageUrl(path, width: 400)),
                  headers: client?.imageHeaders,
                  width: width,
                  fallback: TitleArt(title: item.displayTitle, icon: item.icon),
                ),
                if (item.watched)
                  Positioned(
                    top: 10,
                    right: 10,
                    child: Container(
                      width: 34,
                      height: 34,
                      decoration: BoxDecoration(color: Zc.success.withValues(alpha: 0.9), shape: BoxShape.circle),
                      child: const Icon(Icons.check_rounded, size: 22, color: Colors.white),
                    ),
                  ),
              ]),
            ),
          ),
          const SizedBox(height: 12),
          Text(item.displayTitle,
              maxLines: 1, overflow: TextOverflow.ellipsis, style: Zt.label.copyWith(fontSize: 22)),
          if (item.subtitle != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(item.subtitle!, style: Zt.caption.copyWith(fontSize: 18, color: Zc.textFaint)),
            ),
        ]),
      ),
    );
  }
}
