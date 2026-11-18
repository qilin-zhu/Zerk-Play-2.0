import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/app_services.dart';
import '../../app/saved_servers.dart';
import '../../core/emby/server_kind.dart';
import '../../l10n/l10n.dart';
import '../focus/focus_zone.dart';
import '../focus/tv_focusable.dart';
import '../theme/tokens.dart';

/// The sidebar's server switcher: everything this device has signed in to,
/// newest first, plus an entry point for adding another one.
///
/// Tapping a row signs in with the remembered credentials. That runs through
/// [AppServices.signIn], so the entry is re-stamped as the most recent one and
/// the app root swaps to a fresh shell for the new session.
class ServerMenuPanel extends StatefulWidget {
  const ServerMenuPanel({
    super.key,
    required this.currentKey,
    required this.onClose,
    required this.onAdd,
    this.width = 460,
    this.height = 720,
  });

  /// [SavedServer.serverKey] of the session that is open right now, so it can
  /// be marked and not signed in to twice.
  final String? currentKey;

  /// Dismisses the panel (after a successful switch, or on Escape).
  final VoidCallback onClose;

  /// Opens the manual sign-in form in "add server" mode.
  final VoidCallback onAdd;

  final double width;
  final double height;

  @override
  State<ServerMenuPanel> createState() => _ServerMenuPanelState();
}

class _ServerMenuPanelState extends State<ServerMenuPanel> {
  bool _manage = false;
  String? _busyId;
  String? _error;

  Future<void> _signIn(SavedServer server) async {
    if (_busyId != null) return;
    if (server.serverKey == widget.currentKey) {
      widget.onClose();
      return;
    }
    setState(() {
      _busyId = server.id;
      _error = null;
    });
    final services = AppServicesScope.read(context);
    try {
      await services.signIn(
        server: server.url,
        kind: server.kind,
        username: server.username,
        password: server.password,
      );
      if (mounted) widget.onClose();
    } catch (e) {
      debugPrint('[servers] sign in failed: $e');
      if (!mounted) return;
      setState(() {
        _busyId = null;
        _error = _describe(context.l10n, e);
      });
    }
  }

  static String _describe(L10n l10n, Object e) {
    final s = '$e';
    if (s.contains('401')) return l10n.errorWrongCredentials;
    if (s.contains('SocketException') || s.contains('Connection') || s.contains('TimeoutException')) {
      return l10n.errorUnreachable;
    }
    return s;
  }

  @override
  Widget build(BuildContext context) {
    final services = AppServicesScope.read(context);
    // The saved list is its own notifier: forgetting an entry (or the delayed
    // name lookup finishing) must redraw the panel without a whole app notify.
    return ListenableBuilder(
      listenable: services.servers,
      builder: (context, _) => _panel(context, services.servers.items),
    );
  }

  Widget _panel(BuildContext context, List<SavedServer> servers) {
    final l10n = context.l10n;
    return FocusZone(
      debugLabel: 'servers',
      autofocus: true,
      child: Container(
        width: widget.width,
        height: widget.height,
        padding: const EdgeInsets.fromLTRB(22, 20, 22, 18),
        decoration: BoxDecoration(
          color: const Color(0xF213131B),
          borderRadius: BorderRadius.circular(28),
          border: Border.all(color: Zc.outline, width: 1.5),
          boxShadow: const [BoxShadow(color: Color(0xAA000000), blurRadius: 60, offset: Offset(0, 24))],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(l10n.serversTitle, style: Zt.headline.copyWith(fontSize: 30)),
                const Spacer(),
                TvFocusable(
                  onSelect: () {
                    setState(() {
                      _manage = !_manage;
                      _error = null;
                    });
                  },
                  builder: (context, focused) => AnimatedContainer(
                    duration: Zm.fast,
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      color: focused ? Colors.white : Zc.surfaceHigh,
                      shape: BoxShape.circle,
                      border: Border.all(color: focused ? Colors.white : Zc.outline, width: 1.5),
                    ),
                    child: Icon(
                      _manage ? Icons.check_rounded : Icons.settings_rounded,
                      size: 26,
                      color: focused ? Zc.background : Zc.textMuted,
                    ),
                  ),
                ),
              ],
            ),
            if (_manage)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text(l10n.serversManageHint, style: Zt.caption.copyWith(fontSize: 16)),
              ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(_error!, style: Zt.caption.copyWith(fontSize: 16, color: Zc.danger)),
              ),
            const SizedBox(height: 14),
            Expanded(
              child: servers.isEmpty
                  ? _Empty(l10n: l10n)
                  : ListView.separated(
                      padding: const EdgeInsets.only(bottom: 4),
                      itemCount: servers.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 4),
                      itemBuilder: (context, i) {
                        final server = servers[i];
                        return _ServerRow(
                          server: server,
                          current: server.serverKey == widget.currentKey,
                          busy: _busyId == server.id,
                          dimmed: _busyId != null && _busyId != server.id,
                          manage: _manage,
                          onSelect: () => _signIn(server),
                          onForget: () {
                            setState(() => _error = null);
                            unawaited(AppServicesScope.read(context).servers.forget(server));
                          },
                        );
                      },
                    ),
            ),
            const SizedBox(height: 14),
            TvFocusable(
              onSelect: widget.onAdd,
              builder: (context, focused) => AnimatedContainer(
                duration: Zm.fast,
                height: 62,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: focused ? Colors.white : Zc.surfaceHigh,
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: focused ? Colors.white : Zc.outline, width: focused ? 2 : 1.5),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.add_rounded, size: 28, color: focused ? Zc.background : Zc.text),
                    const SizedBox(width: 12),
                    Text(l10n.serversAdd,
                        style: Zt.label.copyWith(fontSize: 22, color: focused ? Zc.background : Zc.text)),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.l10n});

  final L10n l10n;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.dns_rounded, size: 46, color: Zc.textFaint.withValues(alpha: 0.5)),
          const SizedBox(height: 14),
          Text(l10n.serversEmpty, style: Zt.label.copyWith(fontSize: 20, color: Zc.textMuted)),
          const SizedBox(height: 8),
          Text(l10n.serversEmptyHint, textAlign: TextAlign.center, style: Zt.caption.copyWith(fontSize: 16)),
        ],
      ),
    );
  }
}

class _ServerRow extends StatelessWidget {
  const _ServerRow({
    required this.server,
    required this.current,
    required this.busy,
    required this.dimmed,
    required this.manage,
    required this.onSelect,
    required this.onForget,
  });

  final SavedServer server;
  final bool current;
  final bool busy;
  final bool dimmed;
  final bool manage;
  final VoidCallback onSelect;
  final VoidCallback onForget;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final color = _kindColor(server.kind);
    return Opacity(
      opacity: dimmed ? 0.45 : 1,
      child: TvFocusable(
        onSelect: onSelect,
        builder: (context, focused) => AnimatedContainer(
          duration: Zm.fast,
          height: 92,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            color: focused ? Colors.white.withValues(alpha: 0.11) : Colors.transparent,
            borderRadius: BorderRadius.circular(18),
          ),
          child: Row(
            children: [
              Container(
                width: 54,
                height: 54,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [color, Color.lerp(color, Colors.black, 0.25)!],
                  ),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: const Icon(Icons.play_arrow_rounded, size: 30, color: Colors.white),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            server.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Zt.label.copyWith(fontSize: 22, fontWeight: FontWeight.w700),
                          ),
                        ),
                        if (current) ...[
                          const SizedBox(width: 10),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                            decoration: BoxDecoration(
                              color: Zc.accent.withValues(alpha: 0.22),
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: Text(l10n.serversCurrent,
                                style: Zt.caption.copyWith(fontSize: 14, color: Zc.accentSoft)),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 5),
                    Text(
                      '${server.kind.label} · ${server.username} · ${_ago(l10n, server.lastUsed)}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Zt.caption.copyWith(fontSize: 16),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              if (busy)
                const SizedBox(
                  width: 26,
                  height: 26,
                  child: CircularProgressIndicator(strokeWidth: 2.5, color: Zc.textMuted),
                )
              else if (manage)
                TvFocusable(
                  onSelect: onForget,
                  builder: (context, focused) => Container(
                    width: 46,
                    height: 46,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: focused ? Zc.danger.withValues(alpha: 0.24) : Colors.transparent,
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Icon(Icons.delete_outline_rounded, size: 26, color: Zc.danger),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  static String _ago(L10n l10n, DateTime at) {
    final days = DateTime.now().difference(at).inDays;
    if (days <= 0) return l10n.serversWatchedToday;
    if (days == 1) return l10n.serversWatchedYesterday;
    return l10n.serversWatchedDaysAgo(days);
  }
}

Color _kindColor(ServerKind kind) => switch (kind) {
      ServerKind.emby => const Color(0xFF52B54B),
      ServerKind.jellyfin => const Color(0xFFA65CD2),
      ServerKind.fnos => const Color(0xFF3B82F6),
    };
