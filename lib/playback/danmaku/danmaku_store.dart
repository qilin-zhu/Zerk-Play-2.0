import 'danmaku_api.dart';

/// Comments bucketed by whole second.
///
/// `canvas_danmaku` animates from the moment a comment is added and knows
/// nothing about the player clock, so comments have to be handed over as
/// playback reaches them. Bucketing makes that a single map lookup per second.
final class DanmakuStore {
  final Map<int, List<DanmakuComment>> _bySecond = {};

  int _total = 0;

  /// Number of comments held, not number of occupied seconds.
  int get count => _total;

  bool get isEmpty => _total == 0;

  bool get isNotEmpty => _total > 0;

  void replaceAll(Iterable<DanmakuComment> comments) {
    _bySecond.clear();
    _total = 0;
    for (final c in comments) {
      final second = c.time.inMilliseconds ~/ 1000;
      (_bySecond[second] ??= <DanmakuComment>[]).add(c);
      _total++;
    }
  }

  void clear() {
    _bySecond.clear();
    _total = 0;
  }

  List<DanmakuComment> at(int second) => _bySecond[second] ?? const [];
}
