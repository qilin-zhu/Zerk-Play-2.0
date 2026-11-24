import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import '../host.dart';
import '../log/app_log.dart';

final class DisplayHdrStatus {
  const DisplayHdrStatus({this.supported = false, this.enabled = false});

  final bool supported;

  final bool enabled;
}

abstract final class NativeWindow {
  static const _channel = MethodChannel('zerk/window');

  /// True while the window covers a whole monitor, whichever way it was asked
  /// for: the startup setting, F11, the capsule or the player. The chrome and
  /// the playback backend read this instead of polling window_manager, because
  /// on Windows full screen is ours.
  static final ValueNotifier<bool> fullScreen = ValueNotifier<bool>(false);

  /// On Windows the runner owns full screen (see `FlutterWindow::SetFullScreen`
  /// in `windows/runner/flutter_window.cpp`).
  ///
  /// window_manager's version cannot cover the monitor correctly for this
  /// window: the title bar is hidden rather than frameless, so the plugin's
  /// entry path calls SetAsFrameless() and then shrinks the client area by the
  /// work-area offset on every WM_NCCALCSIZE (a strip of desktop along the
  /// bottom), and its exit path restores the old frame without activating the
  /// window, which left the app behind the desktop and deaf to the mouse.
  static Future<bool> isFullScreen() async {
    if (Host.isWindows) return fullScreen.value;
    if (!Host.isDesktop) return false;
    return windowManager.isFullScreen();
  }

  static Future<void> setFullScreen(bool fullscreen) async {
    if (!Host.isDesktop) return;
    if (Host.isWindows) {
      final bool ok;
      try {
        ok = await _channel.invokeMethod<bool>('setFullScreen', fullscreen) ?? false;
      } on PlatformException catch (e) {
        AppLog.write('[win] setFullScreen($fullscreen): ${e.code} ${e.message}');
        return;
      }
      if (!ok) {
        AppLog.write('[win] setFullScreen($fullscreen): runner refused');
        return;
      }
      fullScreen.value = fullscreen;
      AppLog.write('[win] full screen ${fullscreen ? 'on' : 'off'}');
      return;
    }
    await windowManager.setFullScreen(fullscreen);
    fullScreen.value = fullscreen;
  }

  static Future<bool> toggleFullScreen() async {
    final fs = !(await isFullScreen());
    await setFullScreen(fs);
    return fs;
  }

  static Future<DisplayHdrStatus> hdrStatus() async {
    if (!Host.isWindows) return const DisplayHdrStatus();
    try {
      final m = await _channel.invokeMapMethod<String, bool>('hdrStatus');
      return DisplayHdrStatus(supported: m?['supported'] ?? false, enabled: m?['enabled'] ?? false);
    } on PlatformException {
      return const DisplayHdrStatus();
    }
  }

  static Future<bool> setHdr(bool enabled) async {
    if (!Host.isWindows) return false;
    try {
      return await _channel.invokeMethod<bool>('setHdr', enabled) ?? false;
    } on PlatformException {
      return false;
    }
  }

  static Future<bool> waitForHdr(bool enabled, {Duration timeout = const Duration(seconds: 4)}) async {
    final end = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(end)) {
      if ((await hdrStatus()).enabled == enabled) return true;
      await Future<void>.delayed(const Duration(milliseconds: 150));
    }
    return false;
  }
}
