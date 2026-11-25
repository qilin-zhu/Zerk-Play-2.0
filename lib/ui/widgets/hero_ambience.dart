import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

import '../theme/tokens.dart';
import 'net_image.dart';

/// The mask that dissolves the hero artwork towards its bottom edge.
///
/// White where the artwork stays whole, transparent where it is gone; applied
/// with `BlendMode.dstIn` it erases the artwork instead of painting a colour
/// over it. That difference is the whole point: a painted sheet can only end in
/// the one colour it was painted with, and the page behind it is a tint of the
/// artwork, so the two always meet in a visible step.
///
/// [height] is the artwork's *visible* height and [fadeHeight] how much of it is
/// spent dissolving, so the fade stays anchored to the edge on screen while the
/// page scrolls.
LinearGradient heroFadeMask({required double height, required double fadeHeight}) {
  final from = height <= 0 ? 0.0 : ((height - fadeHeight) / height).clamp(0.0, 1.0);
  return LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    // Non-linear: the artwork stays whole for most of its height, then a soft
    // shoulder, then nothing. A straight 1 → 0 ramp reads as a gradient band.
    stops: [0.0, from, from + (1 - from) * 0.45, from + (1 - from) * 0.78, 1.0],
    colors: const [Color(0xFFFFFFFF), Color(0xFFFFFFFF), Color(0xB8FFFFFF), Color(0x5CFFFFFF), Color(0x00FFFFFF)],
  );
}

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

  /// How much of the blurred artwork survives the scrim. Kept dark: the rows and
  /// their captions are drawn on top of this.
  ///
  /// The artwork's own dissolve happens just above this layer's middle, so the
  /// wash has to be *tinted* there already - a near-black top would give the
  /// poster something flat to fade into and the seam would be back, just as a
  /// dark band instead of a bright line.
  static const _scrim = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    stops: [0.0, 0.22, 0.62, 1.0],
    colors: [Color(0xDE0B0B12), Color(0xCC0B0B12), Color(0xB40B0B12), Color(0xA00B0B12)],
  );

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
        // A dark wash with the artwork's colour in it, from the top of the page
        // all the way down. Uniform enough that the poster's own dissolve has
        // nothing to step against.
        const DecoratedBox(decoration: BoxDecoration(gradient: _scrim)),
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
