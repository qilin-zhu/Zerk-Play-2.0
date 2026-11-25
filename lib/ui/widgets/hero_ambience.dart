import 'dart:math';
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
///
/// [edgeClearance] pixels at the bottom are kept completely transparent. That
/// matters more than it sounds: the artwork is clipped at that edge, and a layer
/// whose last row still has a hint of image in it meets the layer below in a
/// hairline - one that only shows up at some window sizes and scroll offsets,
/// which is exactly how the "bright line under the poster" was reported. With
/// the fade finished before the cut there is nothing left to leave a line.
LinearGradient heroFadeMask({
  required double height,
  required double fadeHeight,
  double edgeClearance = 24,
}) {
  final h = height <= 0 ? 1.0 : height;
  final clear = (edgeClearance / h).clamp(0.0, 0.25);
  final end = 1.0 - clear;
  final from = ((h - fadeHeight) / h).clamp(0.0, end);
  return LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    // Non-linear: the artwork stays whole for most of its height, then a soft
    // shoulder, then nothing. A straight 1 → 0 ramp reads as a gradient band.
    stops: [0.0, from, from + (end - from) * 0.45, from + (end - from) * 0.78, end, 1.0],
    colors: const [
      Color(0xFFFFFFFF),
      Color(0xFFFFFFFF),
      Color(0xB8FFFFFF),
      Color(0x5CFFFFFF),
      Color(0x00FFFFFF),
      Color(0x00FFFFFF),
    ],
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

  /// The wash is built from a *tiny* copy of the artwork and blown up. Blurring
  /// a page-sized layer in one pass is what used to leave a one-pixel bright
  /// row: the blur surface gets split into tiles by the compositor, and the row
  /// on a tile boundary samples the wrong pixels. At 180 px there is only one
  /// tile, so there is nothing to split - and it costs a fraction of the GPU
  /// time, which matters on the TV boxes this also runs on.
  static const _base = 180.0;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      final w = constraints.maxWidth.isFinite ? constraints.maxWidth : _base;
      final h = constraints.maxHeight.isFinite ? constraints.maxHeight : _base * 9 / 16;
      final scale = max(w / _base, h / (_base * 9 / 16));
      return ClipRect(
        child: Transform.scale(
          scale: scale,
          alignment: Alignment.center,
          child: ImageFiltered(
            // Applied before the scale, so 2.4 here is ~20 px on screen.
            imageFilter: ui.ImageFilter.blur(sigmaX: 2.4, sigmaY: 2.4, tileMode: TileMode.mirror),
            child: SizedBox(
              width: _base,
              height: _base * 9 / 16,
              child: NetImage(
                url: url,
                headers: headers,
                width: _base,
                fit: BoxFit.cover,
                fadeDuration: Duration.zero,
                // No fallback: the scrim above is already the right colour, and
                // a title card blown up to a page-wide blur is not a background.
                fallback: const SizedBox.shrink(),
              ),
            ),
          ),
        ),
      );
    });
  }
}
