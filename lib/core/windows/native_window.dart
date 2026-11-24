import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import '../host.dart';

final class DisplayHdrStatus {
  const DisplayHdrStatus({this.supported = false, this.enabled = false});

  final bool supported;

  final bool enabled;
}

abstract final class NativeWindow {
  static const _channel = MethodChannel('zerk/window');

  /// Full screen is owned by window_manager, not by a bare SetWindowPos.
  ///
  /// The window is frameless with a hidden title bar, and window_manager keeps
  /// an 8 px resize border around such a window while it is windowed - that is
  /// how the edges stay draggable. Its WM_NCCALCSIZE hook only drops that
  /// border when its own full-screen flag is set, so resizing the window from
  /// here left the Flutter view 8 px short on the left, the right and the
  /// bottom: an otherwise full-height window with a strip of desktop on both
  /// sides. Going through window_manager keeps the state and the geometry in
  /// one place, and the floating window controls hide themselves too.
  static Future<bool> isFullScreen() async {
    if (!Host.isDesktop) return false;
    return windowManager.isFullScreen();
  }

  static Future<void> setFullScreen(bool fullscreen) async {
    if (Host.isDesktop) await windowManager.setFullScreen(fullscreen);
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
