import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../../core/host.dart';
import '../../core/log/app_log.dart';
import '../../core/windows/native_window.dart';

/// Height of the invisible drag strip along the top edge of the window.
const double kWindowDragBarHeight = 32;

/// Window chrome for the frameless desktop shell: an invisible drag strip along
/// the top edge plus a floating capsule with minimise / restore / close.
///
/// It is installed above the Navigator (see `ZerkApp.builder`) so every screen
/// has it, including the sign-in and onboarding pages that live outside the
/// app shell; without that a frameless window could not be moved or closed
/// there. The drag strip is pointless in full screen (moving a monitor-sized
/// window goes nowhere) and would only swallow clicks meant for the page, so it
/// is dropped there; the capsule stays, because a frameless full-screen window
/// has no OS buttons and the three glyphs would otherwise be the only way in or
/// out of the app gone.
class WindowChromeLayer extends StatefulWidget {
  const WindowChromeLayer({super.key});

  @override
  State<WindowChromeLayer> createState() => _WindowChromeLayerState();
}

class _WindowChromeLayerState extends State<WindowChromeLayer> with WindowListener {
  bool _fullScreen = NativeWindow.fullScreen.value;
  bool _maximized = false;

  @override
  void initState() {
    super.initState();
    if (!Host.isWindows) return;
    windowManager.addListener(this);
    // Full screen on Windows is set by the runner, not by window_manager, so
    // the plugin's enter/leave events never fire here; the notifier does.
    NativeWindow.fullScreen.addListener(_onFullScreenChanged);
    AppLog.write('[win] frameless chrome (drag bar 32, capsule)');
    _sync();
  }

  void _onFullScreenChanged() {
    if (!mounted) return;
    setState(() => _fullScreen = NativeWindow.fullScreen.value);
  }

  Future<void> _sync() async {
    final max = await windowManager.isMaximized();
    if (!mounted || max == _maximized) return;
    setState(() => _maximized = max);
  }

  @override
  void dispose() {
    if (Host.isWindows) {
      windowManager.removeListener(this);
      NativeWindow.fullScreen.removeListener(_onFullScreenChanged);
    }
    super.dispose();
  }

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
    await _sync();
  }

  /// The capsule's middle glyph in full screen: leave it instead of toggling
  /// maximise, which means nothing on an already monitor-sized window.
  Future<void> _leaveFullScreen() => NativeWindow.setFullScreen(false);

  @override
  Widget build(BuildContext context) {
    if (!Host.isWindows) return const SizedBox.shrink();
    return Stack(
      children: [
        if (!_fullScreen)
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
          child: _Capsule(
            maximized: _maximized,
            fullScreen: _fullScreen,
            onToggleMaximize: _fullScreen ? _leaveFullScreen : _toggleMaximize,
          ),
        ),
      ],
    );
  }
}

/// The translucent pill of the reference design: three glyphs, no dividers.
class _Capsule extends StatelessWidget {
  const _Capsule({required this.maximized, required this.fullScreen, required this.onToggleMaximize});

  final bool maximized;
  final bool fullScreen;
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
            // Full screen and a maximised window are both "filling the screen",
            // so they offer the same glyph and the same way back. A separate
            // close-fullscreen icon made the capsule look like a different set
            // of buttons depending on how the window was opened.
            icon: fullScreen || maximized ? Icons.filter_none : Icons.crop_square,
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
