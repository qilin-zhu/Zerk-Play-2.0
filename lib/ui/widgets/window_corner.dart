import 'package:flutter/material.dart';

import 'wall_clock.dart';

/// Size of the top-right corner strip: three 54 px glyphs, 40 px tall, plus the
/// 1 px border the capsule draws on each side.
const double kWindowCornerWidth = 164;
const double kWindowCornerHeight = 40;

/// How much of the corner, measured from its right edge, answers to the pointer
/// while the buttons are hidden.
///
/// Only the clock's own footprint: a pointer crossing the artwork in the corner
/// should not pop three buttons over the poster.
///
/// The widget itself stays [kWindowCornerWidth] wide at all times, even though
/// only this much of it notices the pointer. Shrinking the hover box instead
/// would put the capsule's three 54 px buttons under a 100 px constraint (a
/// RenderFlex overflow), and hovering the buttons would then take them out of
/// the hit-test path below that box, rebuilding the clock and flickering.
const double _clockHitWidth = 84;

/// Left edge of the region that wakes the capsule, in corner-local coordinates.
const double _clockHitLeft = kWindowCornerWidth - _clockHitWidth;

const Duration _fade = Duration(milliseconds: 150);

/// The top-right corner of the frameless window: a 24-hour clock that swaps
/// for the minimise / restore / close capsule while the pointer is in it.
///
/// Rest state is the clock. Three grey glyphs parked over every poster were the
/// loudest thing on screen and read as desktop furniture, not as a media wall;
/// the time belongs in that corner anyway. Hover is what keeps the buttons
/// reachable — a frameless window has no OS buttons left, so they cannot be
/// removed entirely, only hidden.
class WindowCorner extends StatefulWidget {
  const WindowCorner({
    super.key,
    required this.maximized,
    required this.fullScreen,
    required this.onMinimize,
    required this.onToggleMaximize,
    required this.onClose,
    this.showClock = true,
  });

  final bool maximized;
  final bool fullScreen;
  final VoidCallback onMinimize;
  final VoidCallback onToggleMaximize;
  final VoidCallback onClose;

  /// The player OSD draws its own clock while a video is up, so the corner one
  /// stands down instead of printing a second time twice as high. The buttons
  /// still wake on hover: that is the only way out of a frameless full screen.
  final bool showClock;

  @override
  State<WindowCorner> createState() => _WindowCornerState();
}

class _WindowCornerState extends State<WindowCorner> {
  bool _revealed = false;

  void _set(bool on) {
    if (_revealed == on) return;
    setState(() => _revealed = on);
  }

  /// The capsule wakes only over the clock; once awake it stays up anywhere in
  /// the corner, so moving from the clock onto a glyph cannot dismiss it.
  void _maybeReveal(Offset local) {
    if (_revealed || local.dx < _clockHitLeft) return;
    _set(true);
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: kWindowCornerWidth,
      height: kWindowCornerHeight,
      child: MouseRegion(
        // The whole corner is the hover surface, but the left part of it is
        // ignored for waking (see [_maybeReveal]) — that is the difference
        // between "the clock is a target" and "a button pops up whenever the
        // pointer crosses the artwork up here".
        onEnter: (e) => _maybeReveal(e.localPosition),
        onHover: (e) => _maybeReveal(e.localPosition),
        onExit: (_) => _set(false),
        child: Stack(
          alignment: Alignment.centerRight,
          children: [
            // Plain clock, no plate behind it: the corner should read as
            // part of the artwork rather than as another floating box.
            Positioned.fill(
              child: IgnorePointer(
                child: AnimatedOpacity(
                  opacity: _revealed || !widget.showClock ? 0 : 1,
                  duration: _fade,
                  curve: Curves.easeOut,
                  child: const Align(
                    alignment: Alignment.centerRight,
                    child: Padding(
                      padding: EdgeInsets.only(right: 12),
                      // Same widget, same shadow as the clock the player OSD
                      // draws, so the corner does not change character between
                      // the media wall and a video.
                      child: WallClock(size: 18, shadow: true),
                    ),
                  ),
                ),
              ),
            ),
            IgnorePointer(
              ignoring: !_revealed,
              child: AnimatedOpacity(
                opacity: _revealed ? 1 : 0,
                duration: _fade,
                curve: Curves.easeOut,
                child: _Capsule(
                  maximized: widget.maximized,
                  fullScreen: widget.fullScreen,
                  onMinimize: widget.onMinimize,
                  onToggleMaximize: widget.onToggleMaximize,
                  onClose: widget.onClose,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The translucent pill of the reference design: three glyphs, no dividers.
class _Capsule extends StatelessWidget {
  const _Capsule({
    required this.maximized,
    required this.fullScreen,
    required this.onMinimize,
    required this.onToggleMaximize,
    required this.onClose,
  });

  final bool maximized;
  final bool fullScreen;
  final VoidCallback onMinimize;
  final VoidCallback onToggleMaximize;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: kWindowCornerHeight,
      decoration: BoxDecoration(
        color: const Color(0x99000000),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0x1AFFFFFF)),
        boxShadow: const [BoxShadow(color: Color(0x4D000000), blurRadius: 14, offset: Offset(0, 3))],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _ChromeButton(icon: Icons.remove, onTap: onMinimize, leftmost: true),
          _ChromeButton(
            // Full screen and a maximised window are both "filling the screen",
            // so they offer the same glyph and the same way back. A separate
            // close-fullscreen icon made the capsule look like a different set
            // of buttons depending on how the window was opened.
            icon: fullScreen || maximized ? Icons.filter_none : Icons.crop_square,
            onTap: onToggleMaximize,
          ),
          _ChromeButton(icon: Icons.close, onTap: onClose, danger: true, rightmost: true),
        ],
      ),
    );
  }
}

class _ChromeButton extends StatefulWidget {
  const _ChromeButton({
    required this.icon,
    required this.onTap,
    this.danger = false,
    this.leftmost = false,
    this.rightmost = false,
  });

  final IconData icon;
  final VoidCallback onTap;

  /// Close turns red on hover, like the system button does.
  final bool danger;

  /// The outer buttons round their outer corner so the hover fill follows the
  /// capsule instead of poking out of it.
  final bool leftmost;

  final bool rightmost;

  @override
  State<_ChromeButton> createState() => _ChromeButtonState();
}

class _ChromeButtonState extends State<_ChromeButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final danger = widget.danger;
    final bg = _hover ? (danger ? const Color(0xFFC0392B) : const Color(0x24FFFFFF)) : Colors.transparent;
    final fg = _hover && danger ? Colors.white : const Color(0xCCFFFFFF);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeOut,
          width: 54,
          height: kWindowCornerHeight,
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.horizontal(
              left: Radius.circular(widget.leftmost ? 20 : 0),
              right: Radius.circular(widget.rightmost ? 20 : 0),
            ),
          ),
          child: Icon(widget.icon, size: 17, color: fg),
        ),
      ),
    );
  }
}
