import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../../core/host.dart';
import '../../core/log/app_log.dart';
import '../../core/windows/native_window.dart';
import 'window_corner.dart';

/// Height of the invisible drag strip along the top edge of the window.
const double kWindowDragBarHeight = 32;

/// Window chrome for the frameless desktop shell: an invisible drag strip along
/// the top edge plus the top-right corner (see [WindowCorner] — a 24-hour clock
/// that swaps for the minimise / restore / close capsule on hover).
///
/// It is installed above the Navigator (see `ZerkApp.builder`) so every screen
/// has it, including the sign-in and onboarding pages that live outside the
/// app shell; without that a frameless window could not be moved or closed
/// there. The drag strip is pointless in full screen (moving a monitor-sized
/// window goes nowhere) and would only swallow clicks meant for the page, so it
/// is dropped there; the corner stays, because a frameless full-screen window
/// has no OS buttons and hover over the clock would otherwise be the only thing
/// left, with nothing to hover onto.
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
    AppLog.write('[win] frameless chrome (drag bar 32, clock corner)');
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
          child: WindowCorner(
            maximized: _maximized,
            fullScreen: _fullScreen,
            onMinimize: () => windowManager.minimize(),
            onToggleMaximize: _fullScreen ? _leaveFullScreen : _toggleMaximize,
            onClose: () => windowManager.close(),
          ),
        ),
      ],
    );
  }
}
