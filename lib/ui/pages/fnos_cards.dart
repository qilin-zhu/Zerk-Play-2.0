import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/app_services.dart';
import '../../core/fnos/fnos_item.dart';
import '../../l10n/l10n.dart';
import '../../playback/fnos_playback.dart' show playFnOs;
import '../core/navigation.dart';
import '../focus/tv_focusable.dart';
import '../theme/tokens.dart';
import '../widgets/cards.dart' show PlayCircle;
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

/// Continue-watching card: landscape still with a progress strip.
///
/// Selecting it opens the item's detail page, exactly like every other poster
/// in the app; playback starts from the button in the page (or from the play
/// circle that appears while the card has the focus), so the viewer always
/// lands somewhere the resume position is visible before it starts.
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
                if (focused)
                  Center(
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => unawaited(playFnOs(context, item)),
                      child: PlayCircle(),
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

/// 16:9 episode / season card, the fnOS twin of `LandscapeCard`: same frame,
/// same scale on focus, same caption metrics and the same progress strip, so a
/// fnOS detail page and an Emby one read identically.
class FnOsLandscapeCard extends StatelessWidget {
  const FnOsLandscapeCard({
    super.key,
    required this.item,
    this.title,
    this.subtitle,
    this.onSelect,
    this.onPlay,
    this.onFocus,
    this.autofocus = false,
    this.width = Zs.landscapeWidth,
    this.focusNode,
  });

  final FnOsItem item;
  final String? title;
  final String? subtitle;
  final VoidCallback? onSelect;
  final VoidCallback? onPlay;
  final VoidCallback? onFocus;
  final bool autofocus;
  final double width;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    final client = AppServicesScope.read(context).janus.fnos;
    final path = item.posterPath;
    final height = width * 9 / 16;
    return TvFocusable(
      autofocus: autofocus,
      focusNode: focusNode,
      onSelect: onSelect,
      onFocusChange: (f) => f ? onFocus?.call() : null,
      builder: (context, focused) => SizedBox(
        width: width,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          FocusFrame(
            focused: focused,
            scale: 1.06,
            child: SizedBox(
              width: width,
              height: height,
              child: Stack(fit: StackFit.expand, children: [
                NetImage(
                  url: path == null || client == null ? null : Uri.parse(client.imageUrl(path, width: 640)),
                  headers: client?.imageHeaders,
                  width: width,
                  fallback: TitleArt(title: item.title, subtitle: item.subtitle, icon: Icons.play_circle_outline),
                ),
                if (item.watched)
                  const Positioned(
                    top: 10,
                    right: 10,
                    child: Icon(Icons.check_circle_rounded, size: 26, color: Zc.success),
                  ),
                if (focused && onSelect != null)
                  Center(
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: onPlay ?? onSelect,
                      child: PlayCircle(),
                    ),
                  ),
                if (item.progress != null)
                  Positioned(left: 0, right: 0, bottom: 0, child: ProgressStrip(item.progress!, height: 6)),
              ]),
            ),
          ),
          const SizedBox(height: 14),
          Text(title ?? item.displayTitle, maxLines: 1, overflow: TextOverflow.ellipsis,
              style: Zt.label.copyWith(color: focused ? Zc.text : Zc.textMuted)),
          if (subtitle != null) Text(subtitle!, maxLines: 1, overflow: TextOverflow.ellipsis, style: Zt.caption),
        ]),
      ),
    );
  }
}

/// Circular head shot for the cast row, matching `CastRow`'s geometry (150 wide,
/// 140 circle, name + role) that the Emby details page uses.
class FnOsPersonCard extends StatelessWidget {
  const FnOsPersonCard({super.key, required this.name, this.role, this.photo, this.headers});

  final String name;
  final String? role;

  /// Absolute image URI for the head shot, already resolved for the fnOS host.
  final Uri? photo;

  /// Session headers for that URI. trimemedia serves every picture through
  /// `sys/img`, which answers 401 to an anonymous request - without these the
  /// head shot never loads and the card silently falls back to initials.
  final Map<String, String>? headers;

  @override
  Widget build(BuildContext context) {
    return TvFocusable(
      onSelect: null,
      builder: (context, focused) => SizedBox(
        width: 150,
        child: Column(children: [
          AnimatedScale(
            scale: focused ? 1.08 : 1,
            duration: Zm.normal,
            curve: Curves.easeOutBack,
            child: Container(
              width: 140,
              height: 140,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: focused ? Colors.white : Colors.transparent, width: 3),
                color: Zc.surfaceHigh,
              ),
              clipBehavior: Clip.antiAlias,
              child: NetImage(
                url: photo,
                headers: headers,
                width: 140,
                fallback: Center(child: Text(_initials(name), style: Zt.headline.copyWith(color: Zc.textFaint))),
              ),
            ),
          ),
          const SizedBox(height: 14),
          Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center,
              style: Zt.label.copyWith(fontSize: 19, color: focused ? Zc.text : Zc.textMuted)),
          Text(role ?? '', maxLines: 1, overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center, style: Zt.caption.copyWith(fontSize: 16)),
        ]),
      ),
    );
  }

  static String _initials(String name) =>
      name.split(' ').where((p) => p.isNotEmpty).take(2).map((p) => p[0]).join().toUpperCase();
}
