import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

import '../theme/tokens.dart';
import 'net_image.dart';

/// The wash behind the rows: the artwork that is on the hero right now,
/// stretched over the whole page and blurred, seen through a dark scrim.
///
/// The page used to end in flat `Zc.background`, so a poster full of green sat
/// on top of a black sheet and the cut edge between them read as a bright
/// hairline. Now the black is only the top of this layer - the colour of the
/// artwork bleeds down the page as a deep tint of itself.
class HeroAmbience extends StatelessWidget {
  const HeroAmbience({super.key, required this.url, this.headers});

  final Uri? url;
  final Map<String, String>? headers;

  /// How much of the blurred artwork survives the scrim at the bottom of the
  /// page. Kept low: the rows and their captions are drawn on top of this.
  static const _scrim = Color(0xB80B0B12);

  @override
  Widget build(BuildContext context) {
    final u = url;
    return RepaintBoundary(
      child: Stack(fit: StackFit.expand, children: [
        // Painted first and in the same colour the hero's own bottom fade ends
        // on, so the two layers meet without a visible step even while the
        // artwork is still loading.
        const ColoredBox(color: Zc.background),
        if (u != null)
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 900),
            switchInCurve: Curves.easeOut,
            switchOutCurve: Curves.easeIn,
            // Both children stay on screen for the length of the cross-fade;
            // the plain layout would centre-stack them at the artwork's own
            // size instead of filling the page.
            layoutBuilder: (current, previous) =>
                Stack(fit: StackFit.expand, children: [...previous, ?current]),
            child: _Blurred(key: ValueKey(u), url: u, headers: headers),
          ),
        // Opaque background at the very top (that is where the hero's fade
        // ends), loosening into the tint further down the page.
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              stops: [0.0, 0.20, 0.55, 1.0],
              colors: [Zc.background, Color(0xF00B0B12), Color(0xC40B0B12), _scrim],
            ),
          ),
        ),
      ]),
    );
  }
}

class _Blurred extends StatelessWidget {
  const _Blurred({super.key, required this.url, this.headers});

  final Uri url;
  final Map<String, String>? headers;

  @override
  Widget build(BuildContext context) {
    return ClipRect(
      child: ImageFiltered(
        // Wide enough that no detail survives - only the colour survives - and
        // cheap enough for a TV box: it is inside a RepaintBoundary and only
        // repaints when the artwork changes.
        imageFilter: ui.ImageFilter.blur(sigmaX: 26, sigmaY: 26, tileMode: TileMode.decal),
        child: Transform.scale(
          // Overscan: a blur this wide pulls the artwork's own edges inward and
          // would otherwise leave a dark vignette at the page edges.
          scale: 1.24,
          child: NetImage(
            url: url,
            headers: headers,
            fit: BoxFit.cover,
            fadeDuration: Duration.zero,
            // No fallback: the scrim above is already the right colour, and a
            // title card blown up to a page-wide blur is not a background.
            fallback: const SizedBox.shrink(),
          ),
        ),
      ),
    );
  }
}
