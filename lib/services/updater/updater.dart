import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show AppExitType;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../app/release.dart';
import '../../core/host.dart';

final class AppUpdate {
  const AppUpdate({required this.tag, required this.name, required this.download, required this.size});

  final String tag;
  final String name;
  final Uri download;
  final int size;
}

final class UpdateNotAllowed implements Exception {
  const UpdateNotAllowed();
}

abstract final class Updater {
  static const _channel = MethodChannel('zerk/updater');

  static const playStore = bool.fromEnvironment('PLAY_STORE');

  static bool get supported => !playStore && (Host.isWindows || Host.isAndroid);

  /// Mirror bases used for update checks and downloads when GitHub is
  /// unreachable (mainland China). Each base is prefixed onto a full GitHub
  /// URL, ghproxy style: https://ghfast.top/https://github.com/...
  /// api.github.com is not mirrored reliably, so mirror mode resolves the
  /// latest tag from the releases.atom feed, or from the redirect of the
  /// fixed latest/download URL, and downloads through the same base.
  /// Mirrors come and go: the first answer wins, the rest are fallbacks.
  static const defaultMirror = 'https://ghfast.top/';
  static const _fallbackMirrors = ['https://ghproxy.net/', 'https://gh-proxy.com/'];

  /// The asset every release carries under a version-independent name, so a
  /// mirror can resolve "latest" without knowing the version first.
  static String get _latestAssetName =>
      Host.isAndroid ? 'ZerkPlay-Public-Android.apk' : 'ZerkPlay-Public-Windows-setup.exe';

  static String get _latestAssetUrl =>
      'https://github.com/${Release.repository}/releases/latest/download/$_latestAssetName';

  static bool _isNewer(String tag) {
    final match = RegExp(r'v?(\d+)\.(\d+)\.(\d+)').firstMatch(tag);
    if (match == null) return false;
    final parts = Release.version.split('.');
    if (parts.length != 3) return false;
    for (var i = 0; i < 3; i++) {
      final remote = int.tryParse(match.group(i + 1)!);
      final local = int.tryParse(parts[i]);
      if (remote == null || local == null) return false;
      if (remote != local) return remote > local;
    }
    return false;
  }

  static bool _isOurAsset(String name) {
    if (name.startsWith('ZerkPlay-Public-')) return false; // legacy names kept only for pre-2.10.1 clients
    if (Host.isAndroid) return name.startsWith('ZerkPlay-') && name.endsWith('.apk');
    return name.startsWith('ZerkPlay-') && name.endsWith('-setup.exe');
  }

  static Future<AppUpdate?> _directCheck() async {
    final res = await http.get(
      Uri.https('api.github.com', '/repos/${Release.repository}/releases/latest'),
      headers: {'Accept': 'application/vnd.github+json'},
    ).timeout(const Duration(seconds: 15));
    if (res.statusCode == 404) return null;
    if (res.statusCode != 200) throw HttpException('GitHub answered ${res.statusCode}');
    final latest = jsonDecode(res.body) as Map<String, dynamic>;
    if (latest['draft'] == true || latest['prerelease'] == true) return null;
    final tag = latest['tag_name'] as String;
    if (!_isNewer(tag)) {
      debugPrint('[update] ${Release.tag} is up to date ($tag)');
      return null;
    }
    final asset = (latest['assets'] as List)
        .cast<Map<String, dynamic>>()
        .where((a) => _isOurAsset(a['name'] as String))
        .firstOrNull;
    if (asset == null) return null;
    final name = (latest['name'] as String?)?.trim() ?? '';
    debugPrint('[update] ${Release.tag} -> $tag');
    return AppUpdate(
      tag: tag,
      name: name.isEmpty ? tag : name,
      download: Uri.parse(asset['browser_download_url'] as String),
      size: (asset['size'] as num?)?.toInt() ?? 0,
    );
  }

  /// Resolves the latest release tag through one mirror. The atom feed lists
  /// the newest release first (we never publish prereleases, so no filtering);
  /// mirrors that do not carry it are probed with the redirect of the fixed
  /// latest/download URL, whose target names the tag.
  static Future<(String, Uri)?> _mirrorCheck(String base) async {
    final prefix = base.endsWith('/') ? base : '$base/';
    try {
      final res = await http
          .get(Uri.parse('${prefix}https://github.com/${Release.repository}/releases.atom'))
          .timeout(const Duration(seconds: 12));
      if (res.statusCode == 200) {
        final match = RegExp(r'releases/tag/(v?\d+\.\d+\.\d+)').firstMatch(res.body);
        if (match != null) return (match.group(1)!, Uri.parse('$prefix$_latestAssetUrl'));
      }
    } catch (e) {
      debugPrint('[update] atom via ${Uri.parse(prefix).host}: $e');
    }
    try {
      final req = http.Request('GET', Uri.parse('$prefix$_latestAssetUrl'))
        ..followRedirects = false
        ..headers['range'] = 'bytes=0-0';
      final res = await req.send().timeout(const Duration(seconds: 12));
      final location = res.headers['location'];
      unawaited(res.stream.listen(null).cancel());
      if (location != null) {
        final match = RegExp(r'releases/download/(v?\d+\.\d+\.\d+)/').firstMatch(location);
        if (match != null) return (match.group(1)!, Uri.parse('$prefix$_latestAssetUrl'));
      }
    } catch (e) {
      debugPrint('[update] redirect via ${Uri.parse(prefix).host}: $e');
    }
    return null;
  }

  /// [mirror] is the user-configured accelerator; empty means direct GitHub.
  /// A direct check that dies on the network silently falls back to the
  /// mirrors, so a user who never finds the setting still gets updates.
  static Future<AppUpdate?> check({String mirror = ''}) async {
    final forced = mirror.trim();
    final bases = <String>[
      if (forced.isNotEmpty) forced,
      ..._fallbackMirrors,
    ];
    Object? directError;
    if (forced.isEmpty) {
      try {
        return await _directCheck();
      } catch (e) {
        directError = e;
        debugPrint('[update] direct check failed, falling back to mirrors: $e');
      }
    }
    for (final base in bases) {
      final hit = await _mirrorCheck(base);
      if (hit == null) continue;
      final (tag, download) = hit;
      debugPrint('[update] ${Release.tag} -> $tag (via ${Uri.parse(base).host})');
      if (!_isNewer(tag)) return null;
      return AppUpdate(
        tag: tag,
        name: 'Zerk Play ${tag.startsWith('v') ? tag.substring(1) : tag}',
        download: download,
        size: 0,
      );
    }
    if (directError != null) throw directError; // surface the original direct-check error
    throw const HttpException('No update mirror answered');
  }

  static Future<File> download(AppUpdate update, {void Function(double progress)? onProgress}) async {
    final dir = Directory(p.join((await getTemporaryDirectory()).path, 'zerk_play_update'));
    if (await dir.exists()) await dir.delete(recursive: true);
    await dir.create(recursive: true);
    final file = File(p.join(dir.path, p.basename(update.download.path)));
    final client = http.Client();
    try {
      final res = await client.send(http.Request('GET', update.download));
      if (res.statusCode != 200) throw HttpException('Download answered ${res.statusCode}');
      final total = res.contentLength ?? update.size;
      final sink = file.openWrite();
      var received = 0;
      try {
        await for (final chunk in res.stream) {
          sink.add(chunk);
          received += chunk.length;
          if (total > 0) onProgress?.call(received / total);
        }
      } finally {
        await sink.close();
      }
      if (total > 0 && received != total) throw const HttpException('The download was cut short');
      debugPrint('[update] downloaded $received bytes to ${file.path}');
      return file;
    } finally {
      client.close();
    }
  }

  static Future<void> install(File file) async {
    if (Host.isAndroid) {
      if (await _channel.invokeMethod<bool>('canInstall') != true) {
        await _channel.invokeMethod('allowInstalls');
        throw const UpdateNotAllowed();
      }
      await _channel.invokeMethod('install', file.path);
      return;
    }
    await Process.start(
      file.path,
      ['/SILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/CLOSEAPPLICATIONS'],
      mode: ProcessStartMode.detached,
    );
    await ServicesBinding.instance.exitApplication(AppExitType.required);
  }
}
