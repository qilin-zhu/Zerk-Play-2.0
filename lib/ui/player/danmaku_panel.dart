import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../playback/danmaku/danmaku_api.dart';
import '../../playback/danmaku/danmaku_session.dart';
import '../widgets/setting_rows.dart';
import '../widgets/side_panel.dart';

/// The danmaku panel that hangs off the player controls.
///
/// Mirrors the layout people know from other players: what was matched, a
/// show/hide switch, manual search, and turning the feature off.
Future<void> showDanmakuPanel(
  BuildContext context,
  DanmakuSession session, {
  required void Function(String text) toast,
}) async {
  final l10n = context.l10n;

  if (!session.enabled) {
    final turnOn = await showSidePanel<String>(
      context,
      title: l10n.danmakuHeader,
      header: l10n.danmakuDisabledHint,
      options: [PanelOption(value: 'on', title: l10n.danmakuTurnOn, icon: Icons.forum_rounded)],
    );
    if (turnOn == 'on') await session.setEnabled(true);
    return;
  }

  final chosen = await showSidePanel<String>(
    context,
    title: l10n.danmakuHeader,
    header: _header(l10n, session),
    options: [
      PanelOption(
        value: 'visible',
        title: session.visible ? l10n.danmakuHide : l10n.danmakuShow,
        icon: session.visible ? Icons.visibility_off_rounded : Icons.visibility_rounded,
      ),
      PanelOption(value: 'search', title: l10n.danmakuSearch, icon: Icons.search_rounded),
      PanelOption(value: 'reload', title: l10n.danmakuReload, icon: Icons.refresh_rounded),
      PanelOption(value: 'off', title: l10n.danmakuTurnOff, icon: Icons.power_settings_new_rounded),
    ],
  );
  if (!context.mounted) return;

  switch (chosen) {
    case 'visible':
      session.setVisible(!session.visible);
    case 'search':
      await _search(context, session, toast);
    case 'reload':
      toast(l10n.danmakuSearching);
      await session.rematch();
    case 'off':
      await session.setEnabled(false);
  }
}

String? _header(L10n l10n, DanmakuSession session) {
  if (!session.configured) return l10n.danmakuNotConfigured;
  return switch (session.status) {
    DanmakuStatus.off => l10n.danmakuDisabledHint,
    DanmakuStatus.matching => l10n.danmakuSearching,
    DanmakuStatus.ready => [
        ?session.matchedTitle,
        l10n.danmakuCount(session.count),
      ].join(' · '),
    DanmakuStatus.empty => l10n.danmakuEmpty,
    DanmakuStatus.failed => l10n.danmakuFailed,
  };
}

Future<void> _search(
  BuildContext context,
  DanmakuSession session,
  void Function(String text) toast,
) async {
  final l10n = context.l10n;
  final keyword = await showTextInputDialog(
    context,
    title: l10n.danmakuSearch,
    initial: session.query,
    hint: l10n.danmakuSearchHint,
    action: l10n.danmakuSearch,
  );
  if (!context.mounted) return;
  final typed = (keyword ?? '').trim();
  if (typed.isEmpty) return;

  toast(l10n.danmakuSearching);
  final animes = await session.search(typed);
  if (!context.mounted) return;
  if (animes.isEmpty) {
    toast(l10n.danmakuSearchEmpty);
    return;
  }

  final anime = await showSidePanel<DanmakuAnime>(
    context,
    title: l10n.danmakuSearch,
    options: [
      for (final a in animes)
        PanelOption(
          value: a,
          title: a.title,
          subtitle: [a.kind, if (a.episodeCount != null) l10n.danmakuEpisodeCount(a.episodeCount!)]
              .whereType<String>()
              .join(' · '),
        ),
    ],
  );
  if (anime == null || !context.mounted) return;

  toast(l10n.danmakuSearching);
  final episodes = await session.episodes(anime);
  if (!context.mounted) return;
  if (episodes.isEmpty) {
    toast(l10n.danmakuSearchEmpty);
    return;
  }

  final episode = await showSidePanel<DanmakuEpisode>(
    context,
    title: anime.title,
    options: [for (final e in episodes) PanelOption(value: e, title: e.title)],
  );
  if (episode == null) return;

  final loaded = await session.loadEpisode(episode);
  toast(loaded ? l10n.danmakuLoaded(session.count) : l10n.danmakuEmpty);
}
