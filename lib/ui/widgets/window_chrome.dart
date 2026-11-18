import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../../core/host.dart';
import '../../core/log/app_log.dart';

/// Height of the invisible drag strip along the top edge of the window.
const double kWindowDragBarHeight = 32;

/// Window chrome for the frameless desktop shell: an invisible drag strip along
/// the top edge plus a floating capsule with minimise / restore / close.
///
/// It is installed above the Navigator (see `ZerkApp.builder`) so every screen
/// has it, including the sign-in and onboarding pages that live outside the
/// app shell; without that a frameless window could not be moved or closed
/// there. Both parts disappear in full screen, where the strip would only
/// swallow clicks meant for the page.
class WindowChromeLayer extends StatefulWidget {
  const WindowChromeLayer({super.key});

  @override
  State<WindowChromeLayer> createState() => _WindowChromeLayerState();
}

class _WindowChromeLayerState extends State<WindowChromeLayer> with WindowListener {
  bool _fullScreen = false;
  bool _maximized = false;

  @override
  void initState() {
    super.initState();
    if (!Host.isWindows) return;
    windowManager.addListener(this);
    AppLog.write('[win] frameless chrome (drag bar 32, capsule)');
    _sync();
  }

  Future<void> _sync() async {
    final full = await windowManager.isFullScreen();
    final max = await windowManager.isMaximized();
    if (!mounted || (full == _fullScreen && max == _maximized)) return;
    setState(() {
      _fullScreen = full;
      _maximized = max;
    });
  }

  @override
  void dispose() {
    if (Host.isWindows) windowManager.removeListener(this);
    super.dispose();
  }

  @override
  void onWindowEnterFullScreen() => setState(() => _fullScreen = true);

  @override
  void onWindowLeaveFullScreen() => setState(() => _fullScreen = false);

  @override
  void onWindowMaximize() => setState(() => _maximized = true);

  @override
  void onWindowUnmaximize() => setState(() => _maximized = false);

  Future<void> _toggleMaximize() async {
    if (await windowManager.isMaximized()) {
      await windowManager.unmaximize();
    } else {
      await windowManager.maximize();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!Host.isWindows || _fullScreen) return const SizedBox.shrink();
    return Stack(
      children: [
        // Opaque on purpose: a drag that started on the page underneath (a row
        // or poster drag) would fight the window move.
        Positioned(
          left: 0,
          top: 0,
          right: 0,
          height: kWindowDragBarHeight,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onPanStart: (_) => windowManager.startDragging(),
            onDoubleTap: _toggleMaximize,
            child: const SizedBox.expand(),
          ),
        ),
        Positioned(
          top: 12,
          right: 16,
          child: _Capsule(maximized: _maximized, onToggleMaximize: _toggleMaximize),
        ),
      ],
    );
  }
}

/// The translucent pill of the reference design: three glyphs, no dividers.
class _Capsule extends StatelessWidget {
  const _Capsule({required this.maximized, required this.onToggleMaximize});

  final bool maximized;
  final VoidCallback onToggleMaximize;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 40,
      decoration: BoxDecoration(
        color: const Color(0x99000000),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0x1AFFFFFF)),
        boxShadow: const [BoxShadow(color: Color(0x4D000000), blurRadius: 14, offset: Offset(0, 3))],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _ChromeButton(icon: Icons.remove, onTap: () => windowManager.minimize(), leftmost: true),
          _ChromeButton(
            icon: maximized ? Icons.filter_none : Icons.crop_square,
            onTap: onToggleMaximize,
          ),
          _ChromeButton(
            icon: Icons.close,
            onTap: () => windowManager.close(),
            danger: true,
            rightmost: true,
          ),
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
          height: 40,
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
