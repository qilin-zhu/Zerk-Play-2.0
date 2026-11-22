import 'package:flutter/foundation.dart';

/// Broadcasts "a fnOS playback session ended" so that screens showing
/// server-side state can refetch it.
///
/// The shell keeps every visited tab alive in an `Offstage`, so the home page's
/// `initState` only runs once per session: without this signal the
/// continue-watching row kept showing whatever `play/list` returned the first
/// time the page was built, and only a re-login (which recreates the page) made
/// it catch up.
final class FnosPlaybackBus {
  FnosPlaybackBus._();

  /// Bumped whenever a playback session finishes — dismissed by the user, EOF,
  /// load error or shutdown. Listeners refetch `play/list` and rebuild the row.
  static final ValueNotifier<int> revision = ValueNotifier<int>(0);

  static void notifyEnded() => revision.value++;
}
