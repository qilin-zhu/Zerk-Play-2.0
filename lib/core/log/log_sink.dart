import 'dart:async';
import 'dart:io';
import 'dart:ui' show PlatformDispatcher;

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Append-only log file.
///
/// The buffered lines are pushed to disk through a **synchronous** file handle.
/// The previous version wrote through an [IOSink] and `await`ed `flush()`: when
/// that future did not complete, the sink stayed "flushing" for the rest of the
/// session, every later line was parked in memory and the file on disk stayed at
/// zero bytes - a release build that produced no log at all while the app was
/// still clearly running. A synchronous handle cannot get stuck like that, and a
/// failed write is reported once instead of wedging the channel.
final class LogSink {
  LogSink._(this.directory, this.file, this._out);

  static const _keep = 12;

  /// Ceiling for the in-memory buffer: a runaway writer must not eat the
  /// process memory while the disk is unavailable.
  static const _maxBuffered = 256 * 1024;

  final String directory;
  final String file;

  final RandomAccessFile? _out;
  Timer? _timer;
  final _pending = StringBuffer();
  Object? _lastFailure;

  static Future<LogSink> open() async {
    final dir = Directory(p.join((await getApplicationSupportDirectory()).path, 'logs'));
    await dir.create(recursive: true);
    _prune(dir);
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    final name = 'zerkplay-${now.year}${two(now.month)}${two(now.day)}-${two(now.hour)}${two(now.minute)}${two(now.second)}.log';
    final path = p.join(dir.path, name);
    RandomAccessFile? out;
    try {
      out = File(path).openSync(mode: FileMode.append);
    } catch (_) {
      out = null;
    }
    return LogSink._(dir.path, path, out);
  }

  static void _prune(Directory dir) {
    try {
      for (final prefix in const ['zerkplay-', 'mpv-']) {
        final files = dir.listSync().whereType<File>().where((f) => p.basename(f.path).startsWith(prefix)).toList()
          ..sort((a, b) => b.path.compareTo(a.path));
        for (final f in files.skip(_keep)) {
          f.deleteSync();
        }
      }
    } catch (_) {}
  }

  void add(String line) {
    _pending.write(line);
    _pending.write('\n');
    if (_pending.length >= _maxBuffered) {
      _flushNow();
      return;
    }
    _timer ??= Timer(const Duration(milliseconds: 400), () {
      _timer = null;
      _flushNow();
    });
  }

  Future<void> flush() async => _flushNow();

  void _flushNow() {
    _timer?.cancel();
    _timer = null;
    final out = _out;
    if (out == null || _pending.isEmpty) return;
    final text = _pending.toString();
    _pending.clear();
    try {
      out.writeStringSync(text);
      out.flushSync();
      _lastFailure = null;
    } catch (e) {
      // Report once, then keep the text for the next attempt so a transient
      // failure does not silently swallow the session's log.
      if (!identical(e, _lastFailure)) {
        _lastFailure = e;
        stderr.writeln('[log] write failed: $e');
      }
      if (_pending.length < _maxBuffered) _pending.write(text);
    }
  }

  Future<void> reveal() async {
    await flush();
    if (Platform.isWindows) await Process.start('explorer.exe', [directory]);
    if (Platform.isLinux) await Process.start('xdg-open', [directory]);
  }

  String sidePath(String prefix) {
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return p.join(directory, '$prefix-${now.year}${two(now.month)}${two(now.day)}-${two(now.hour)}${two(now.minute)}${two(now.second)}.log');
  }

  static Future<List<String>> systemInfo() async {
    final lines = <String>[
      'os: ${Platform.operatingSystem} ${Platform.operatingSystemVersion}',
      'cpus: ${Platform.numberOfProcessors}  locale: ${Platform.localeName}  dart: ${Platform.version.split(' ').first}',
      'exe: ${Platform.resolvedExecutable}',
      for (final d in PlatformDispatcher.instance.displays)
        'display ${d.id}: ${d.size.width.round()}x${d.size.height.round()} px, scale ${d.devicePixelRatio}, ${d.refreshRate.toStringAsFixed(2)} Hz',
    ];
    if (!Platform.isWindows) return lines;
    final fonts = p.join(Platform.environment['WINDIR'] ?? r'C:\Windows', 'Fonts');
    lines.add('icon fonts: Segoe Fluent Icons ${File(p.join(fonts, 'SegoeIcons.ttf')).existsSync() ? 'yes' : 'NO'}, '
        'Segoe MDL2 Assets ${File(p.join(fonts, 'segmdl2.ttf')).existsSync() ? 'yes' : 'NO'}');
    final mpv = File(p.join(p.dirname(Platform.resolvedExecutable), 'libmpv-2.dll'));
    lines.add('libmpv-2.dll: ${mpv.existsSync() ? '${mpv.lengthSync()} bytes, ${mpv.lastModifiedSync().toIso8601String()}' : 'MISSING'}');
    try {
      final r = await Process.run('powershell', [
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        r'Get-CimInstance Win32_VideoController | ForEach-Object { "gpu: $($_.Name), driver $($_.DriverVersion), $($_.VideoModeDescription), $($_.CurrentRefreshRate) Hz" }; '
            r'Get-CimInstance Win32_Processor | ForEach-Object { "cpu: $($_.Name.Trim())" }; '
            r'"ram: {0:N1} GB" -f ((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB); '
            r'$o = Get-CimInstance Win32_OperatingSystem; "windows: $($o.Caption) $($o.Version) build $($o.BuildNumber)"',
      ]).timeout(const Duration(seconds: 8));
      lines.addAll((r.stdout as String).split(RegExp(r'\r?\n')).map((l) => l.trim()).where((l) => l.isNotEmpty));
    } catch (e) {
      lines.add('hardware query failed: $e');
    }
    return lines;
  }
}
