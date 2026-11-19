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

  static Future<AppUpdate?> check() async {
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
