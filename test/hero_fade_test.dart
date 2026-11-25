import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zerk_play/ui/widgets/hero_ambience.dart';

/// The poster and the page behind it must meet without a step.
///
/// This renders the real composition - a bright artwork masked with
/// [heroFadeMask] over the tinted wash - and walks down a column of pixels. The
/// bug this guards against was a one-pixel bright line: the fade ended in an
/// opaque colour that no longer matched the page behind it, so the last row of
/// the artwork survived as a step.
void main() {
  testWidgets('hero artwork dissolves into the wash without a step', (tester) async {
    const wash = Color(0xFF10302C);   // dark teal, the tint of some artwork
    const artwork = Color(0xFF88DDCC); // bright artwork
    const heroH = 240.0;
    const totalH = 400.0;
    const width = 40.0;
    final key = GlobalKey();

    await tester.pumpWidget(Directionality(
      textDirection: TextDirection.ltr,
      child: Center(
        child: RepaintBoundary(
          key: key,
          child: SizedBox(
            width: width,
            height: totalH,
            child: Stack(fit: StackFit.expand, children: [
              const ColoredBox(color: wash),
              Positioned(
                left: 0,
                right: 0,
                top: 0,
                height: heroH,
                child: ClipRect(
                  child: ShaderMask(
                    blendMode: BlendMode.dstIn,
                    shaderCallback: (rect) =>
                        heroFadeMask(height: heroH, fadeHeight: 140).createShader(rect),
                    child: const ColoredBox(color: artwork),
                  ),
                ),
              ),
            ]),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    late ByteData raw;
    late int stride;
    await tester.runAsync(() async {
      final image = await boundary.toImage();
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      raw = data!;
      stride = image.width * 4;
      image.dispose();
    });

    // Luminance of the pixel column at the middle of the box, row by row.
    final middle = (width / 2).round() * 4;
    double lum(int y) {
      final i = y * stride + middle;
      return (raw.getUint8(i) * 0.3 + raw.getUint8(i + 1) * 0.59 + raw.getUint8(i + 2) * 0.11);
    }

    // The artwork must actually be there at the top and gone at its bottom edge.
    expect(lum(4), greaterThan(150), reason: 'artwork should be intact at the top');
    expect((lum(heroH.toInt() - 1) - lum(heroH.toInt() + 2)).abs(), lessThan(2),
        reason: 'the row just above the cut must already match the page behind it');

    // And no row anywhere in the dissolve may jump: that is the visible line.
    var worst = 0.0;
    for (var y = 1; y < totalH.toInt(); y++) {
      final step = (lum(y) - lum(y - 1)).abs();
      if (step > worst) worst = step;
    }
    expect(worst, lessThan(6), reason: 'adjacent rows must not step (worst: $worst)');
  });
}
