import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/app_services.dart';
import '../../core/fnos/fnos_client.dart';
import '../../core/fnos/fnos_item.dart';
import '../../l10n/l10n.dart';
import '../../playback/fnos_playback.dart' show playFnOs;
import '../core/navigation.dart';
import '../focus/tv_focusable.dart';
import '../theme/tokens.dart';
import '../widgets/common.dart';
import '../widgets/media_row.dart';
import '../widgets/net_image.dart';
import 'fnos_item_page.dart';

/// Shared poster card for all fnOS pages (home wall, libraries, search).
class FnOsPosterCard extends StatelessWidget {
  const FnOsPosterCard({super.key, required this.item, this.width, this.onFocus, this.onFocusOut, this.autofocus = false});

  final FnOsItem item;
  final double? width;
  final VoidCallback? onFocus;
  final VoidCallback? onFocusOut;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    final client = AppServicesScope.read(context).janus.fnos;
    final path = item.posterPath;
    final w = width ?? posterGridCardWidth(MediaQuery.sizeOf(context).width, AppServicesScope.of(context).settings.posterSize.columns);
    final height = w * 1.5;
    return TvFocusable(
      autofocus: autofocus,
      onFocusChange: (f) {
        if (f) {
          onFocus?.call();
        } else {
          onFocusOut?.call();
        }
      },
      onSelect: () => Navigator.of(context).push(
        tvRoute(FnOsItemPage(guid: item.guid, seed: item), name: 'fnos:${item.guid}'),
      ),
      builder: (context, focused) => SizedBox(
        width: w,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          FocusFrame(
            focused: focused,
            child: SizedBox(
              width: w,
              height: height,
              child: Stack(fit: StackFit.expand, children: [
                NetImage(
                  url: path == null || client == null ? null : Uri.parse(client.imageUrl(path, width: 400)),
                  headers: client?.imageHeaders,
                  width: w,
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
          Text(item.displayTitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: Zt.label.copyWith(fontSize: 22)),
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

/// Continue-watching card: landscape still with a progress strip. Tapping
/// plays immediately.
class FnOsResumeCard extends StatelessWidget {
  const FnOsResumeCard({super.key, required this.item, required this.width, this.onFocus, this.onFocusOut});

  final FnOsItem item;
  final double width;
  final VoidCallback? onFocus;
  final VoidCallback? onFocusOut;

  @override
  Widget build(BuildContext context) {
    final client = AppServicesScope.read(context).janus.fnos;
    final path = item.posterPath;
    final imageH = width * 0.5625;
    final l10n = context.l10n;
    return TvFocusable(
      onFocusChange: (f) {
        if (f) {
          onFocus?.call();
        } else {
          onFocusOut?.call();
        }
      },
      onSelect: () => unawaited(playFnOs(context, item)),
      builder: (context, focused) => SizedBox(
        width: width,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          FocusFrame(
            focused: focused,
            child: SizedBox(
              width: width,
              height: imageH,
              child: Stack(fit: StackFit.expand, children: [
                NetImage(
                  url: path == null || client == null ? null : Uri.parse(client.imageUrl(path, width: 760)),
                  headers: client?.imageHeaders,
                  width: width,
                  fallback: TitleArt(title: item.displayTitle, icon: item.icon),
                ),
                if (item.progress != null)
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: ProgressStrip(item.progress!, height: 5),
                  ),
                Positioned(
                  top: 10,
                  left: 10,
                  child: Pill(l10n.keepWatching),
                ),
              ]),
            ),
          ),
          const SizedBox(height: 12),
          Text(item.displayTitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: Zt.label.copyWith(fontSize: 22)),
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
