import 'dart:convert';

import 'package:flutter/material.dart';

import '../../core/fnos/fnos_client.dart';
import '../../l10n/l10n.dart';
import '../focus/focus_zone.dart';
import '../theme/tokens.dart';
import '../widgets/setting_rows.dart';
import '../widgets/common.dart';

/// Connection test for 飞牛影视 (trimemedia on fnOS).
///
/// Diagnostic: it runs login → items → item detail → season/episode lists →
/// play info → stream against a live server and prints what came back, so the
/// response shapes stay verifiable while the fnOS pages are built out.
class FnosTestPage extends StatefulWidget {
  const FnosTestPage();

  @override
  State<FnosTestPage> createState() => FnosTestPageState();
}

class FnosTestPageState extends State<FnosTestPage> {
  String _host = '';
  String _user = '';
  String _pass = '';
  String _log = '';
  bool _running = false;

  void _say(String line) => setState(() => _log = '$_log$line\n');

  String _clip(Object? raw, [int max = 600]) {
    final text = const JsonEncoder.withIndent('  ').convert(raw);
    return text.length <= max ? text : '${text.substring(0, max)}…';
  }

  Future<void> _run() async {
    if (_running) return;
    setState(() {
      _running = true;
      _log = '';
    });
    final l10n = context.l10n;
    try {
      if (_host.isEmpty) {
        _say(l10n.fnosHostRequired);
        return;
      }
      final client = FnosClient(baseUrl: _host);

      _say('1. ${l10n.fnosStepLogin}');
      final stopwatch = Stopwatch()..start();
      await client.login(_user, _pass);
      _say('   ok (${stopwatch.elapsedMilliseconds} ms), cookie: ${client.cookie == null ? 'none' : 'yes'}');

      _say('2. item/list');
      final items = await client.itemList(pageSize: 10, page: 1);
      final list = items is Map ? items['list'] as List? ?? const [] : items is List ? items : const [];
      _say('   ${l10n.fnosItemsFound(list.length.toString())}');
      if (list.isEmpty) {
        _say(l10n.fnosNoItem);
        return;
      }
      final first = list.first as Map;
      _say('   ${_clip(first, 500)}');
      final itemGuid = first['guid']?.toString();
      if (itemGuid == null || itemGuid.isEmpty) {
        _say(l10n.fnosNoItem);
        return;
      }

      _say('3. item/{guid}');
      final detail = await client.itemDetail(itemGuid);
      _say('   ${_clip(detail, 400)}');
      final type = detail is Map ? detail['type']?.toString() ?? '' : '';

      if (type == 'tv') {
        _say('4. season/list/{guid}');
        final seasons = await client.seasonList(itemGuid);
        final seasonList = seasons is List ? seasons : const [];
        _say('   ${_clip(seasons is List && seasons.isNotEmpty ? seasons.first : seasons, 300)}');
        if (seasonList.isNotEmpty) {
          final seasonGuid = (seasonList.first as Map)['guid']?.toString();
          if (seasonGuid != null && seasonGuid.isNotEmpty) {
            _say('5. episode/list/{seasonGuid}');
            final episodes = await client.episodeList(seasonGuid);
            final epList = episodes is List ? episodes : episodes is Map ? episodes['list'] as List? ?? const [] : const [];
            _say('   ${l10n.fnosItemsFound(epList.length.toString())}');
            _say('   ${_clip(epList.isNotEmpty ? epList.first : episodes, 300)}');
          }
        }
      }

      _say('6. play/info');
      final info = await client.playInfo(itemGuid);
      _say('   ${_clip(info, 700)}');

      String? mediaGuid;
      if (info is Map) {
        for (final key in ['media_guid', 'mediaGuid', 'video_guid', 'videoGuid']) {
          final v = info[key]?.toString();
          if (v != null && v.isNotEmpty) {
            mediaGuid = v;
            break;
          }
        }
        if (mediaGuid == null) {
          for (final value in info.values) {
            if (value is Map) {
              for (final key in ['media_guid', 'guid', 'video_guid']) {
                final v = value[key]?.toString();
                if (v != null && v.isNotEmpty) {
                  mediaGuid = v;
                  break;
                }
              }
            }
            if (mediaGuid != null) break;
          }
        }
      }

      if (mediaGuid == null || mediaGuid.isEmpty) {
        _say(l10n.fnosNoMedia);
        return;
      }

      _say('7. stream');
      final stream = await client.stream(mediaGuid);
      _say('   ${_clip(stream, 700)}');
      _say(l10n.fnosDone);
    } catch (e) {
      _say('${l10n.fnosFailed}: $e');
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Padding(
      padding: const EdgeInsets.only(left: 120, top: 90, right: 120),
      child: SizedBox(
        width: 1100,
        child: FocusZone(
          debugLabel: 'settings-fnos-test',
          autofocus: true,
          child: ListView(padding: const EdgeInsets.only(bottom: 120), children: [
            Text(l10n.fnosTest, style: Zt.headline),
            const SizedBox(height: 12),
            Text(l10n.fnosTestIntro, style: Zt.body),
            const SizedBox(height: 30),
            SettingTextRow(
              title: l10n.fnosHost,
              value: _host,
              hint: 'http://192.168.31.18:5666',
              onChanged: (v) => setState(() => _host = v.trim()),
            ),
            SettingTextRow(title: l10n.fnosUsername, value: _user, onChanged: (v) => setState(() => _user = v.trim())),
            SettingTextRow(
              title: l10n.fnosPassword,
              value: _pass,
              obscure: true,
              onChanged: (v) => setState(() => _pass = v),
            ),
            TvButton(
              label: _running ? l10n.fnosRunning : l10n.fnosRun,
              icon: Icons.play_arrow_rounded,
              primary: true,
              autofocus: true,
              onSelect: _run,
            ),
            const SizedBox(height: 24),
            if (_log.isNotEmpty)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(color: Zc.surfaceTop, borderRadius: BorderRadius.circular(16)),
                child: Text(_log, style: Zt.body.copyWith(fontSize: 20, height: 1.4)),
              ),
          ]),
        ),
      ),
    );
  }
}
