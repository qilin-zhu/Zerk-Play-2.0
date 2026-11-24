import 'dart:async';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import 'app/app_services.dart';
import 'core/host.dart';
import 'core/log/app_log.dart';
import 'core/log/perf_bench.dart';
import 'playback/kept_display.dart';
import 'playback/media3/media3_smoke.dart';
import 'playback/mpv/mpv_backend.dart';
import 'playback/player_settings.dart';
import 'playback/player_smoke.dart';
import 'core/windows/native_window.dart';
import 'l10n/l10n.dart';
import 'ui/core/gamepad.dart';
import 'ui/core/input_mode.dart';
import 'ui/core/navigation.dart';
import 'ui/core/system_keyboard.dart';
import 'ui/core/tv_scale.dart';
import 'ui/core/ui_sounds.dart';
import 'ui/focus/focus_zone.dart';
import 'ui/pages/onboarding_page.dart';
import 'ui/pages/sign_in_page.dart';
import 'ui/shell/shell.dart';
import 'ui/widgets/image_disk_cache.dart';
import 'ui/widgets/window_chrome.dart';
import 'ui/theme/tokens.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  await AppLog.init();
  AppLog.captureBuildErrors();
  AppLog.watchFrames();
  WidgetsBinding.instance.addPostFrameCallback((_) => AppLog.mark('first frame'));
  if (Host.isWindows) await _initWindow();
  final services = await AppServices.create();
  if (Host.isDesktop && services.settings.startFullScreen) {
    debugPrint('[app] starting in full screen');
    // Bounded: a window-manager call that never answers must not keep the app
    // from painting its first frame, which reads as a black window.
    await NativeWindow.setFullScreen(true).timeout(const Duration(seconds: 3), onTimeout: () {
      AppLog.write('[app] full screen: no answer in 3 s, carrying on windowed');
    });
  }
  unawaited(UiSounds.load());
  unawaited(_pruneImageCache());
  Gamepad.start();
  SystemBack.install();
  SystemKeyboard.install();
  final tabArg = args.where((a) => a.startsWith('--tab=')).map((a) => a.substring(6)).firstOrNull;
  final initialTab = ShellTab.values.where((t) => t.name == tabArg).firstOrNull ?? ShellTab.home;
  AppLog.mark('services ready');
  runApp(AppServicesScope(
    services: services,
    child: ZerkApp(
      initialTab: initialTab,
      bench: args.contains('--bench'),
      playerSmoke: args.contains('--player-smoke'),
      trailerSmoke: args.contains('--trailer-smoke'),
    ),
  ));
}

/// Image cache housekeeping, in the background: forgets entries that are not
/// images (0-byte files left by an interrupted write, an XML/JSON error page, a
/// placeholder SVG) and keeps the folder under [_imageCacheBudget].
///
/// A poisoned entry used to survive every restart: the file existed, so it
/// counted as a cache hit, the decoder threw `Invalid image data`, and the card
/// fell back to its title card for ever. That is the "posters turned into text
/// and refresh does not help" report.
Future<void> _pruneImageCache() async {
  const budget = 320 << 20;
  try {
    final s = await pruneImageCache(maxBytes: budget);
    if (s.removed > 0 || s.bytes > budget) {
      AppLog.write('[image] cache pruned: removed=${s.removed} kept=${s.kept} '
          '${(s.bytes / (1 << 20)).round()} MB');
    }
  } catch (e) {
    AppLog.write('[image] cache prune failed: $e');
  }
}

Future<void> _initWindow() async {
  await windowManager.ensureInitialized();
  await windowManager.waitUntilReadyToShow(
    const WindowOptions(
      title: 'Zerk Play',
      size: Size(1600, 900),
      minimumSize: Size(960, 540),
      center: true,
      backgroundColor: Zc.background,
      // Frameless: no OS title bar and no system buttons. WindowChromeLayer
      // draws a drag strip and the capsule on top of every route. `hidden`
      // only drops WS_CAPTION, so the window stays resizable from its edges.
      titleBarStyle: TitleBarStyle.hidden,
      windowButtonVisibility: false,
    ),
    () async {
      await windowManager.setTitleBarStyle(TitleBarStyle.hidden, windowButtonVisibility: false);
      await windowManager.setResizable(true);
      await windowManager.show();
      await windowManager.focus();
    },
  );
}

class ZerkApp extends StatefulWidget {
  const ZerkApp({
    super.key,
    this.initialTab = ShellTab.home,
    this.bench = false,
    this.playerSmoke = false,
    this.trailerSmoke = false,
  });

  final ShellTab initialTab;

  final bool bench;

  final bool playerSmoke;

  final bool trailerSmoke;

  @override
  State<ZerkApp> createState() => _ZerkAppState();
}

class _ZerkAppState extends State<ZerkApp> {
  final _navigator = GlobalKey<NavigatorState>();
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    DoubleBack.navigator = _navigator;
    _lifecycle = AppLifecycleListener(
      onStateChange: (s) => debugPrint('[app] lifecycle ${s.name}'),
      onResume: () {
        if (mounted) AppServicesScope.read(context).checkHub();
      },
      onExitRequested: () async {
        debugPrint('[app] exit requested');
        // Quitting must not hang: handing the display back (HDR and refresh
        // rate) can sit for seconds, and closing the window does not wait for
        // it at all. Bound both so the button behaves like the window.
        await KeptDisplay.restore().timeout(const Duration(milliseconds: 500), onTimeout: () {});
        await AppLog.flush().timeout(const Duration(milliseconds: 300), onTimeout: () {});
        return AppExitResponse.exit;
      },
    );
    final route = WidgetsBinding.instance.platformDispatcher.defaultRouteName;
    if (Host.isAndroid && route.startsWith('/dev-player')) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => runMedia3Smoke(_navigator.currentState!, subtitleBackground: route == '/dev-player-box'),
      );
    }
    if (Host.isDesktop && widget.playerSmoke) {
      WidgetsBinding.instance.addPostFrameCallback((_) => runPlayerSmoke(MpvBackend(
            navigator: _navigator.currentState!,
            settings: const PlayerSettings(),
            l10n: lookupL10n(const Locale('en')),
          )));
    }
    if (widget.trailerSmoke) {
      WidgetsBinding.instance.addPostFrameCallback((_) => runTrailerSmoke(_navigator.currentState!));
    }
    if (widget.bench || route == '/dev-bench') unawaited(PerfBench.run(_navigator));
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final services = AppServicesScope.of(context);
    final signedIn = services.isSignedIn;
    return MaterialApp(
      title: 'Zerk Play',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      locale: Locale(services.settings.resolvedUiLanguage),
      supportedLocales: L10n.supportedLocales,
      localizationsDelegates: L10n.localizationsDelegates,
      navigatorKey: _navigator,
      navigatorObservers: [LogNavigatorObserver()],
      builder: (context, child) => InputModeDetector(
        child: TvScale(
          child: CallbackShortcuts(
            bindings: {
              const SingleActivator(LogicalKeyboardKey.f11): () => unawaited(NativeWindow.toggleFullScreen()),
            },
            child: BackKeys(
              navigatorKey: _navigator,
              child: ZoneNavigation(
                // The window is frameless, so the drag strip and the
                // minimise/close capsule are painted above every route: the
                // sign-in and onboarding screens are not inside the shell.
                child: Stack(
                  children: [
                    Positioned.fill(child: child ?? const SizedBox.shrink()),
                    const Positioned.fill(child: WindowChromeLayer()),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
      home: !signedIn
          ? const SignInPage()
          : !services.settings.onboarded
              ? const OnboardingPage(key: ValueKey('onboarding'))
              // Keyed by the session: the sidebar switches servers without
              // leaving the shell, and every page under it caches the previous
              // server's rows and libraries. A new key throws that state away.
              : Shell(
                  key: ValueKey(
                      'shell:${services.janus.session.kind.name}:${services.janus.session.serverUrl}:${services.janus.session.userId}'),
                  initialTab: widget.initialTab,
                ),
    );
  }
}
