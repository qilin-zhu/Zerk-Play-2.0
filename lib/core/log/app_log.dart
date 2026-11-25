import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import '../host.dart';
import 'log_sink.dart';

abstract final class AppLog {
  static const appVersion = '2.10.14+54';

  static LogSink? _sink;
  static DebugPrintCallback? _console;

  static final _sinceStart = Stopwatch()..start();
  static final _marked = <String>{};

  static void mark(String step) {
    if (_marked.add(step)) write('[startup] $step after ${_sinceStart.elapsedMilliseconds} ms');
  }

  static String? get directory => _sink?.directory;

  static String? get file => _sink?.file;

  static Future<void> init() async {
    _sinceStart.elapsed;
    _console = debugPrint;
    debugPrint = (message, {wrapWidth}) {
      if (message != null) write(message);
      if (!kReleaseMode) _console!(message, wrapWidth: wrapWidth);
    };
    final previousFlutterError = FlutterError.onError;
    FlutterError.onError = (details) {
      write('[error] Flutter: ${details.exceptionAsString()}\n'
          '  context: ${details.context?.toDescription() ?? '-'}  library: ${details.library ?? '-'}\n${details.stack ?? ''}');
      previousFlutterError?.call(details);
    };
    PlatformDispatcher.instance.onError = (error, stack) {
      write('[error] uncaught: $error\n$stack');
      return true;
    };
    try {
      _sink = await LogSink.open();
    } catch (e) {
      _console?.call('[log] could not open the log file: $e');
    }
    write('[app] Zerk Play $appVersion (${kReleaseMode ? 'release' : kProfileMode ? 'profile' : 'debug'})');
    if (_sink != null) write('[log] writing to ${_sink!.file}');
    unawaited(LogSink.systemInfo().then((lines) {
      for (final line in lines) {
        write('[system] $line');
      }
    }));
  }

  /// Paints widget / layout errors on screen instead of the bare dark rectangle
  /// a release build shows by default.
  ///
  /// That rectangle is indistinguishable from an empty page: the "Emby home is
  /// completely black" report was a thrown exception whose text and stack only
  /// existed in a log that had stopped working. From now on the message is on
  /// the screen *and* in the log, so the next one is a one-look diagnosis.
  static void captureBuildErrors() {
    ErrorWidget.builder = (details) {
      final text = details.exceptionAsString();
      write('[error] widget: $text\n'
          '  context: ${details.context?.toDescription() ?? '-'}  library: ${details.library ?? '-'}\n${details.stack ?? ''}');
      return ErrorPanel(message: text);
    };
  }

  static void write(String message) {
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    final stamp = '${two(now.hour)}:${two(now.minute)}:${two(now.second)}.${now.millisecond.toString().padLeft(3, '0')}';
    final sink = _sink;
    if (sink == null) {
      if (kReleaseMode) _console?.call('$stamp $message');
      return;
    }
    sink.add('$stamp $message');
    if (Host.isAndroid && kReleaseMode) _console?.call(message);
  }

  static Future<void> flush() async => _sink?.flush();

  static Future<void> openFolder() async => _sink?.reveal();

  static String? sidePath(String prefix) => _sink?.sidePath(prefix);

  static String _where = 'start';
  static int _slowFrames = 0, _frames = 0;
  static Duration _worst = Duration.zero;
  static Timer? _frameReport;

  static set where(String value) {
    _where = value;
    write('[nav] now on $value');
  }

  static String get where => _where;

  static void watchFrames() {
    SchedulerBinding.instance.addTimingsCallback((timings) {
      for (final t in timings) {
        _frames++;
        final total = t.totalSpan;
        if (total > const Duration(milliseconds: 17)) _slowFrames++;
        if (total > _worst) _worst = total;
        if (total > const Duration(milliseconds: 34)) {
          write('[jank] ${total.inMilliseconds} ms frame on $_where '
              '(build ${t.buildDuration.inMilliseconds} ms, raster ${t.rasterDuration.inMilliseconds} ms, '
              'vsync wait ${t.vsyncOverhead.inMilliseconds} ms)');
        }
      }
    });
    _frameReport = Timer.periodic(const Duration(seconds: 10), (_) {
      if (_frames > 0) {
        write('[frames] last 10 s: $_frames frames, $_slowFrames over 16 ms, worst ${_worst.inMilliseconds} ms ($_where)');
      }
      _frames = _slowFrames = 0;
      _worst = Duration.zero;
    });
  }

  @visibleForTesting
  static void stopWatchingFrames() => _frameReport?.cancel();
}

/// Stand-in for a widget that failed to build: no theme, no services, no
/// localization, because whatever broke may have taken those with it.
class ErrorPanel extends StatelessWidget {
  const ErrorPanel({super.key, required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final shown = message.length > 900 ? '${message.substring(0, 900)}…' : message;
    return Directionality(
      textDirection: TextDirection.ltr,
      child: ColoredBox(
        color: const Color(0xFF16090D),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(32, 96, 32, 32),
          child: Align(
            alignment: Alignment.topLeft,
            child: SingleChildScrollView(
              child: DefaultTextStyle(
                style: const TextStyle(color: Color(0xFFFFC9C9), fontSize: 15, height: 1.45),
                child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                  DefaultTextStyle(
                    style: const TextStyle(color: Color(0xFFFF7B7B), fontSize: 20, fontWeight: FontWeight.w700, height: 1.4),
                    child: const Text('This screen failed to render'),
                  ),
                  const SizedBox(height: 14),
                  Text(shown),
                  const SizedBox(height: 18),
                  const DefaultTextStyle(
                    style: TextStyle(color: Color(0xFF9A8080), fontSize: 14, height: 1.5),
                    child: Text('The full stack is in the log: Settings → About → open log folder.\n'
                        'Report it with the file name, it is timestamped.'),
                  ),
                ]),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class LogNavigatorObserver extends NavigatorObserver {
  static String _name(Route<dynamic>? r) => r == null ? '-' : (r.settings.name ?? r.runtimeType.toString());

  void _shown(String what, Route<dynamic>? route) {
    final watch = Stopwatch()..start();
    AppLog.where = _name(route);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      AppLog.write('[nav] $what ${_name(route)}: first frame after ${watch.elapsedMilliseconds} ms');
    });
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) => _shown('push', route);

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    AppLog.write('[nav] pop ${_name(route)}');
    _shown('back to', previousRoute);
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) => _shown('replace ${_name(oldRoute)} with', newRoute);

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) => AppLog.write('[nav] removed ${_name(route)}');
}
