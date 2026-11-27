import 'package:flutter/material.dart';

import 'wall_clock.dart';

/// Size of the top-right corner strip: three 54 px glyphs, 40 px tall, plus the
/// 1 px border the capsule draws on each side.
const double kWindowCornerWidth = 164;
const double kWindowCornerHeight = 40;

/// How much of the corner answers to the pointer while the buttons are hidden.
///
/// Not a width, a shape: the clock's own box (see `_WindowCornerState.build`).
/// A pointer crossing the artwork in the corner should not pop three buttons
/// over the poster, so the wake area must be the clock and nothing else — and
/// it must be measured, not guessed. A fixed "rightmost N px" window looked
/// right and was wrong: at 24 px the digits start left of the guess, so the
/// left half of the time did nothing when hovered.
///
/// The corner itself stays [kWindowCornerWidth] wide at all times. Shrinking
/// the box instead would put the capsule's three 54 px buttons under a ~100 px
/// constraint (a RenderFlex overflow), and the buttons would then fall out of
/// the hit-test path below that box.
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

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: kWindowCornerWidth,
      height: kWindowCornerHeight,
      child: MouseRegion(
        // Only dismisses. Waking is the clock's own job (it knows where it is,
        // the corner does not) — and this one must stay the ancestor of the
        // capsule rather than a sibling of it: a hit test stops at the first
        // child that takes the pointer, so a region below the buttons would
        // leave the path the moment the pointer landed on a glyph, collapse
        // the capsule under the cursor and flash.
        onExit: (_) => _set(false),
        child: Stack(
          alignment: Alignment.centerRight,
          children: [
            // Plain clock, no plate behind it: the corner should read as
            // part of the artwork rather than as another floating box.
            Positioned.fill(
              child: Align(
                alignment: Alignment.centerRight,
                // Align fills the corner but is not hit-testable itself, so the
                // region below is exactly the glyphs — the wake area is measured
                // by layout instead of guessed as "the rightmost N pixels".
                child: MouseRegion(
                  onEnter: (_) => _set(true),
                  child: IgnorePointer(
                    child: AnimatedOpacity(
                      opacity: _revealed || !widget.showClock ? 0 : 1,
                      duration: _fade,
                      curve: Curves.easeOut,
                      // The chrome is mounted above the Navigator, so the
                      // ambient text style here is `MaterialApp`'s fallback —
                      // monospace, w900, with a double yellow underline ("put
                      // your text in a Material"). Left alone the clock inherits
                      // exactly that: the two yellow lines under the digits were
                      // this, not a shadow. A clean base style is cheaper than
                      // dragging a Material into the corner just to reset its
                      // typography.
                      child: const DefaultTextStyle(
                        style: TextStyle(decoration: TextDecoration.none),
                        child: Padding(
                          padding: EdgeInsets.only(right: 12),
                          // Same widget, same shadow as the clock the player OSD
                          // draws, so the corner does not change character
                          // between the media wall and a video.
                          child: WallClock(size: 24, shadow: true),
                        ),
                      ),
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
