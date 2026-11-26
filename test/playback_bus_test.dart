import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zerk_play/core/emby/models/emby_item.dart';
import 'package:zerk_play/core/windows/native_window.dart';
import 'package:zerk_play/playback/playback_bus.dart';
import 'package:zerk_play/playback/player_backend.dart';

final class _FakePlayer implements PlayerBackend {
  final _state = ValueNotifier(const PlayerState(position: Duration(seconds: 10), duration: Duration(minutes: 45)));
  final _events = StreamController<PlayerEvent>.broadcast();
  final osdCalls = <String>[];
  bool closed = false;

  @override
  ValueListenable<PlayerState> get state => _state;

  @override
  Stream<PlayerEvent> get events => _events.stream;

  @override
  bool get selectsFileTracks => false;

  @override
  bool get streamSubtitles => false;

  @override
  String? get textSubtitleFormat => null;

  @override
  Future<void> open() async {}

  @override
  void load(Uri url, {Duration? start, int? audioOrdinal, int? subtitleOrdinal, String? dolbyVision, Map<String, String>? headers, String? mimeType}) {}

  @override
  void selectTrack(String type, String? id) {}

  @override
  void addSubtitle(Uri url, {required String format, required String title, String? language}) {}

  @override
  void osd(String command, Object? data) => osdCalls.add(command);

  @override
  void setPaused(bool paused) => _state.value = PlayerState(
        position: _state.value.position,
        duration: _state.value.duration,
        paused: paused,
      );

  @override
  void seek(Duration position) => _state.value = PlayerState(position: position, duration: _state.value.duration);

  @override
  bool get adjustsSpeed => true;

  @override
  void setSpeed(double speed) {}

  @override
  void setSubtitleScale(double scale) {}

  @override
  Future<double?> matchRefreshRate(double fps) async => null;

  @override
  Future<DisplayHdrStatus> displayHdr() async => const DisplayHdrStatus();

  @override
  Future<void> close() async => closed = true;

  void emit(PlayerEvent e) => _events.add(e);
}

final class _FakeSession implements PlaybackCommands {
  _FakeSession(this.item);

  EmbyItem? item;
  int nextCalls = 0;
  int exitCalls = 0;

  @override
  EmbyItem? get playingItem => item;

  @override
  Future<void> nextEpisode() async => nextCalls++;

  @override
  Future<void> exitPlayback() async => exitCalls++;
}

void main() {
  final item = EmbyItem(id: 'e1', name: 'Pilot', type: 'Episode', seriesName: 'Show');

  late _FakePlayer player;
  late _FakeSession session;

  setUp(() {
    player = _FakePlayer();
    session = _FakeSession(item);
    PlaybackBus.attach(player, item, commands: session);
  });

  tearDown(() => PlaybackBus.detach());

  test('next and stop go to the session, not to the mpv osd panel', () {
    expect(PlaybackBus.next(), isTrue);
    expect(PlaybackBus.stop(), isTrue);

    expect(session.nextCalls, 1);
    expect(session.exitCalls, 1);
    // The bug this guards: osd('next') only renders a next-up card in the Lua
    // panel, it never reaches the session's handler.
    expect(player.osdCalls, isEmpty);
  });

  test('pause, seek and volume still hit the backend directly', () {
    expect(PlaybackBus.pause(), isTrue);
    expect(player.state.value.paused, isTrue);
    expect(PlaybackBus.resume(), isTrue);
    expect(player.state.value.paused, isFalse);

    expect(PlaybackBus.seekBy(const Duration(seconds: 30)), isTrue);
    expect(player.state.value.position, const Duration(seconds: 40));
  });

  test('publish follows the session when it switches episode', () {
    session.item = EmbyItem(id: 'e2', name: 'Second', type: 'Episode', seriesName: 'Show');
    PlaybackBus.publish();
    expect(PlaybackBus.current.value?.id, 'e2');
    expect(PlaybackBus.current.value?.label, 'Show · Second');
  });

  test('without a session, next and stop report false instead of doing nothing', () {
    PlaybackBus.detach();
    PlaybackBus.attach(_FakePlayer(), item);
    expect(PlaybackBus.active, isTrue);
    expect(PlaybackBus.next(), isFalse);
    expect(PlaybackBus.stop(), isFalse);
  });
}
