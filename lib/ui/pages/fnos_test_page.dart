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
/// This is a diagnostic before the real integration: it runs login → library
/// list → items → play info → stream against a live server and prints what came
/// back, so the response shapes are verified before anything is mapped onto the
/// player.
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
      _say('   ok (${stopwatch.elapsedMilliseconds} ms)');

      _say('2. mediadb/list');
      final dbs = await client.mediaDbList();
      _say('   ${_clip(dbs, 500)}');
      String? dbGuid;
      if (dbs is List && dbs.isNotEmpty) {
        final first = dbs.first;
        if (first is Map) dbGuid = first['guid']?.toString();
        _say('   ${l10n.fnosLibrariesFound(dbs.length.toString())}');
      }

      _say('3. item/list');
      final items = await client.itemList(ancestorGuid: dbGuid, pageSize: 10);
      String? itemGuid;
      if (items is List) {
        _say('   ${l10n.fnosItemsFound(items.length.toString())}');
        final first = items.isNotEmpty ? items.first : null;
        _say('   ${_clip(first, 500)}');
        if (first is Map) itemGuid = first['guid']?.toString();
      } else {
        _say('   ${_clip(items, 300)}');
      }

      if (itemGuid == null) {
        _say(l10n.fnosNoItem);
        return;
      }

      _say('4. play/info');
      final info = await client.playInfo(itemGuid);
      _say('   ${_clip(info, 700)}');

      String? mediaGuid;
      if (info is Map) {
        mediaGuid = info['media_guid']?.toString() ?? info['mediaGuid']?.toString();
      }

      if (mediaGuid == null || mediaGuid.isEmpty) {
        _say(l10n.fnosNoMedia);
        return;
      }

      _say('5. stream');
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
