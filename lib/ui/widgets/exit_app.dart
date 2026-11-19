import 'dart:io' show exit;
import 'dart:ui' show AppExitResponse, AppExitType;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import '../../core/host.dart';
import '../../l10n/l10n.dart';
import '../focus/focus_zone.dart';
import '../theme/tokens.dart';
import 'common.dart';

bool _exitOpen = false;

Future<void> confirmExit(BuildContext context) async {
  if (_exitOpen) return;
  _exitOpen = true;
  final bool? yes;
  try {
    yes = await showDialog<bool>(context: context, builder: (_) => const _ExitDialog());
  } finally {
    _exitOpen = false;
  }
  if (yes == true) await exitApp();
}

Future<void> exitApp() async {
  if (Host.isAndroid) {
    await SystemNavigator.pop();
    return;
  }
  // Hide the window first so it vanishes the instant the button is pressed —
  // the teardown below (engine shutdown, HDR hand-back on a helper thread) can
  // still take seconds and must not be visible. Destroy with a short timeout
  // so the engine usually exits cleanly; if it wedges (mpv still holding the
  // HDR swapchain), `exit(0)` ends the process regardless.
  try {
    await windowManager.hide();
  } catch (_) {}
  try {
    await ServicesBinding.instance
        .exitApplication(AppExitType.cancelable)
        .timeout(const Duration(milliseconds: 500), onTimeout: () => AppExitResponse.cancel);
  } catch (_) {
    // The engine may already be tearing down; fall through to the hard close.
  }
  try {
    await windowManager.destroy().timeout(const Duration(milliseconds: 800));
  } catch (_) {}
  exit(0);
}

class _ExitDialog extends StatelessWidget {
  const _ExitDialog();

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Dialog(
      backgroundColor: Zc.surfaceHigh,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Zs.radiusLarge)),
      child: SizedBox(
        width: 760,
        child: Padding(
          padding: const EdgeInsets.all(48),
          child: FocusZone(
            debugLabel: 'exit-app',
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                const Icon(Icons.power_settings_new_rounded, size: 48, color: Zc.accent),
                const SizedBox(width: 24),
                Expanded(child: Text(l10n.exitAppQuestion, style: Zt.headline.copyWith(fontSize: 40))),
              ]),
              const SizedBox(height: 20),
              Text(l10n.exitAppBody, style: Zt.body),
              const SizedBox(height: 36),
              Wrap(spacing: 18, runSpacing: 18, children: [
                TvButton(
                  label: l10n.exitConfirm,
                  icon: Icons.power_settings_new_rounded,
                  primary: true,
                  autofocus: true,
                  onSelect: () => Navigator.of(context).pop(true),
                ),
                TvButton(label: l10n.cancel, icon: Icons.close_rounded, onSelect: () => Navigator.of(context).pop(false)),
              ]),
            ]),
          ),
        ),
      ),
    );
  }
}
