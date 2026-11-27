import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zerk_play/l10n/l10n.dart';
import 'package:zerk_play/ui/widgets/wall_clock.dart';
import 'package:zerk_play/ui/widgets/window_corner.dart';

/// The corner rests as a 24-hour clock and only shows the window buttons while
/// the pointer is in it.
///
/// The bug this guards against is a window that cannot be closed: the buttons
/// are painted all the time but wrapped in an [IgnorePointer] that never turns
/// off, so they look present and swallow nothing. Tapping the glyph's position
/// is what tells "hidden" from "there but dead".
void main() {
  Future<Rect> pumpCorner(
    WidgetTester tester, {
    required VoidCallback onMinimize,
    required VoidCallback onToggleMaximize,
    required VoidCallback onClose,
    bool showClock = true,
  }) async {
    await tester.pumpWidget(MaterialApp(
      // Same localisation wiring as the app: the clock formats through intl
      // with the UI locale, so it needs the delegates loaded.
      locale: const Locale('zh'),
      supportedLocales: L10n.supportedLocales,
      localizationsDelegates: L10n.localizationsDelegates,
      // Mounted the way the app does it — in `builder`, above the Navigator.
      // There the ambient text style is MaterialApp's fallback (monospace,
      // w900, double yellow underline), and a Scaffold here would hide that.
      builder: (context, child) => Align(
        alignment: Alignment.topRight,
        child: WindowCorner(
          maximized: false,
          fullScreen: false,
          showClock: showClock,
          onMinimize: onMinimize,
          onToggleMaximize: onToggleMaximize,
          onClose: onClose,
        ),
      ),
      home: const SizedBox.shrink(),
    ));
    await tester.pumpAndSettle();
    return tester.getRect(find.byType(WindowCorner));
  }

  /// Centre of the capsule's rightmost glyph, in screen coordinates.
  Offset closeSpot(Rect corner) => Offset(corner.right - 27, corner.center.dy);

  /// Somewhere on the digits themselves.
  Offset clockSpot(Rect corner) => Offset(corner.right - 40, corner.center.dy);

  double opacityAround(WidgetTester tester, Finder child) {
    final f = find.ancestor(of: child, matching: find.byType(AnimatedOpacity));
    return tester.widget<AnimatedOpacity>(f.first).opacity;
  }

  testWidgets('rest state is a 24-hour clock, buttons are inert', (tester) async {
    var minimized = 0, toggled = 0, closed = 0;
    final corner = await pumpCorner(
      tester,
      onMinimize: () => minimized++,
      onToggleMaximize: () => toggled++,
      onClose: () => closed++,
    );

    // HH:mm, no AM/PM and no locale day period.
    final clock = find.textContaining(RegExp(r'^\d{2}:\d{2}$'));
    expect(clock, findsOneWidget);
    final now = DateTime.now();
    expect(
      tester.widget<Text>(clock).data,
      '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}',
    );
    expect(opacityAround(tester, clock), 1);

    // The style that actually reaches the paragraph: mounted above the
    // Navigator, a bare Text inherits MaterialApp's fallback and comes out in
    // monospace with a double yellow underline under the digits.
    final ambient = DefaultTextStyle.of(tester.element(find.byType(WindowCorner))).style;
    expect(ambient.fontFamily, 'monospace',
        reason: 'the corner must be mounted where the app mounts it, above the Navigator');
    final rich = tester.widget<RichText>(
      find.descendant(of: find.byType(WallClock), matching: find.byType(RichText)),
    );
    final style = rich.text.style!;
    expect(style.decoration, TextDecoration.none, reason: 'no underline, single or double');
    expect(style.fontFamily, isNot('monospace'), reason: 'the corner is not a fallback text');
    expect(style.fontSize, 24);

    // The capsule is still laid out (it has to fade out), but a click on it
    // must not reach a button.
    expect(opacityAround(tester, find.byIcon(Icons.close)), 0);
    await tester.tapAt(closeSpot(corner));
    await tester.pumpAndSettle();
    expect(closed, 0);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('hover swaps the clock for live buttons, leaving hides them', (tester) async {
    var minimized = 0, toggled = 0, closed = 0;
    final corner = await pumpCorner(
      tester,
      onMinimize: () => minimized++,
      onToggleMaximize: () => toggled++,
      onClose: () => closed++,
    );

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);

    // Somewhere on the digits, not merely on the corner: that distinction is
    // the whole point of the wake area being the clock's own box.
    await mouse.moveTo(clockSpot(corner));
    await tester.pumpAndSettle();
    final clock = find.textContaining(RegExp(r'^\d{2}:\d{2}$'));
    expect(opacityAround(tester, clock), 0, reason: 'the clock makes way for the buttons');
    expect(opacityAround(tester, find.byIcon(Icons.close)), 1);

    // Sliding from the clock onto a glyph must not drop the capsule: the
    // buttons sit on top of the clock, so the clock loses the pointer there.
    await mouse.moveTo(Offset(corner.left + 27, corner.center.dy));
    await tester.pumpAndSettle();
    expect(opacityAround(tester, find.byIcon(Icons.close)), 1, reason: 'stays up over the glyph');

    await tester.tapAt(closeSpot(corner));
    await tester.pumpAndSettle();
    expect(closed, 1);

    await tester.tapAt(Offset(corner.left + 20, corner.center.dy));
    await tester.pumpAndSettle();
    expect(minimized, 1);

    await tester.tapAt(corner.center);
    await tester.pumpAndSettle();
    expect(toggled, 1);

    // Off the corner entirely: back to the clock, buttons inert again.
    await mouse.moveTo(Offset(20, corner.bottom + 200));
    await tester.pumpAndSettle();
    expect(opacityAround(tester, clock), 1);
    expect(opacityAround(tester, find.byIcon(Icons.close)), 0);
    await tester.tapAt(closeSpot(corner));
    await tester.pumpAndSettle();
    expect(closed, 1);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('hovering just left of the clock does not pop the buttons', (tester) async {
    var closed = 0;
    final corner = await pumpCorner(
      tester,
      onMinimize: () {},
      onToggleMaximize: () {},
      onClose: () => closed++,
    );

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);

    // Inside the capsule's footprint but outside the clock: a pointer crossing
    // the artwork there used to be enough to summon three glyphs.
    await mouse.moveTo(Offset(corner.left + 20, corner.center.dy));
    await tester.pumpAndSettle();
    expect(opacityAround(tester, find.byIcon(Icons.close)), 0);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('during playback the clock stands down, the buttons still open', (tester) async {
    var closed = 0;
    final corner = await pumpCorner(
      tester,
      onMinimize: () {},
      onToggleMaximize: () {},
      onClose: () => closed++,
      showClock: false,
    );

    // The player OSD has its own clock; two of them at once is worse than none.
    expect(opacityAround(tester, find.textContaining(RegExp(r'^\d{2}:\d{2}$'))), 0);

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(clockSpot(corner));
    await tester.pumpAndSettle();
    await tester.tapAt(closeSpot(corner));
    await tester.pumpAndSettle();
    expect(closed, 1, reason: 'a frameless full screen still has to be closable');

    await tester.pumpWidget(const SizedBox());
  });
}
