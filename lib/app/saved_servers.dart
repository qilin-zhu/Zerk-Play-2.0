import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../core/emby/server_kind.dart';
import '../core/storage/local_store.dart';

/// One server the app has signed in to before, kept so the sidebar can offer a
/// one-tap sign-in later.
///
/// The password is stored obfuscated (XOR + base64), not encrypted: there is no
/// key store on Android TV or Windows that would survive a reinstall anyway, so
/// the OS user profile stays the trust boundary — the same one the stored
/// session token already relies on.
@immutable
final class SavedServer {
  const SavedServer({
    required this.url,
    required this.kind,
    required this.username,
    required this.password,
    required this.name,
    required this.lastUsed,
  });

  /// Base URL the login was made against, e.g. `http://192.168.1.10:8096`.
  final String url;
  final ServerKind kind;
  final String username;
  final String password;

  /// The server's own `ServerName` when it answered, the host otherwise.
  final String name;

  final DateTime lastUsed;

  /// Stable identity: the same account on the same server is one entry.
  String get id => '${kind.name}|${normalize(url)}|$username';

  /// Identity without the account: which server is open, whichever user.
  String get serverKey => keyOf(url, kind);

  static String keyOf(String url, ServerKind kind) => '${kind.name}|${normalize(url)}';

  String get host {
    final uri = Uri.tryParse(url);
    final authority = uri?.authority ?? '';
    return authority.isEmpty ? url : authority;
  }

  static String normalize(String value) => value.trim().toLowerCase().replaceAll(RegExp(r'/+$'), '');

  SavedServer copyWith({String? name, String? password, DateTime? lastUsed}) => SavedServer(
        url: url,
        kind: kind,
        username: username,
        password: password ?? this.password,
        name: name ?? this.name,
        lastUsed: lastUsed ?? this.lastUsed,
      );

  Map<String, Object?> toJson() => {
        'url': url,
        'kind': kind.name,
        'username': username,
        'password': _Scramble.encode(password),
        'name': name,
        'lastUsed': lastUsed.millisecondsSinceEpoch,
      };

  static SavedServer? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final url = raw['url']?.toString().trim() ?? '';
    if (url.isEmpty) return null;
    final username = raw['username']?.toString() ?? '';
    final name = raw['name']?.toString().trim() ?? '';
    final last = raw['lastUsed'];
    return SavedServer(
      url: url,
      kind: ServerKind.parse(raw['kind']?.toString()),
      username: username,
      password: _Scramble.decode(raw['password']?.toString() ?? ''),
      name: name.isEmpty ? (Uri.tryParse(url)?.authority ?? url) : name,
      lastUsed: DateTime.fromMillisecondsSinceEpoch(last is num ? last.toInt() : 0),
    );
  }
}

/// The servers remembered on this device, newest first.
///
/// Everything that signs in funnels through [AppServices.signIn], so recording
/// here is enough for the sidebar list to stay in sync with whatever the user
/// actually used — the sync code, the manual form and the menu itself.
final class SavedServers extends ChangeNotifier {
  SavedServers(this._store);

  static const _key = 'servers.saved';

  final LocalStore _store;
  List<SavedServer> _items = const [];

  List<SavedServer> get items => _items;

  bool get isEmpty => _items.isEmpty;

  Future<void> load() async {
    final raw = await _store.getString(_key);
    if (raw == null || raw.trim().isEmpty) return;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return;
      final parsed = <SavedServer>[for (final e in decoded) ?SavedServer.fromJson(e)];
      parsed.sort(_newestFirst);
      _items = List.unmodifiable(parsed);
    } catch (e) {
      debugPrint('[servers] could not read the saved list: $e');
    }
  }

  /// Adds or updates an entry and marks it as the most recently used one.
  Future<void> remember({
    required String url,
    required ServerKind kind,
    required String username,
    required String password,
    String? name,
  }) async {
    final host = Uri.tryParse(url)?.authority ?? '';
    final entry = SavedServer(
      url: url,
      kind: kind,
      username: username,
      password: password,
      name: (name == null || name.trim().isEmpty) ? (host.isEmpty ? url : host) : name.trim(),
      lastUsed: DateTime.now(),
    );
    await _write([..._items.where((s) => s.id != entry.id), entry]);
  }

  /// Replaces the display name of an entry (the server's own name arrives from
  /// `/System/Info/Public` after the login already finished).
  Future<void> rename(String id, String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;
    final current = _items.where((s) => s.id == id).firstOrNull;
    if (current == null || current.name == trimmed) return;
    await _write([for (final s in _items) s.id == id ? s.copyWith(name: trimmed) : s]);
  }

  Future<void> forget(SavedServer server) async {
    if (!_items.any((s) => s.id == server.id)) return;
    await _write([..._items.where((s) => s.id != server.id)]);
  }

  Future<void> _write(List<SavedServer> items) async {
    _items = List.unmodifiable(items..sort(_newestFirst));
    notifyListeners();
    await _store.setString(_key, jsonEncode([for (final s in _items) s.toJson()]));
  }

  static int _newestFirst(SavedServer a, SavedServer b) => b.lastUsed.compareTo(a.lastUsed);
}

/// Keeps the passwords out of `shared_preferences` in plain text. Not a
/// security boundary: anyone who can read the file can reproduce the key.
abstract final class _Scramble {
  static const _key = 'zerk-play/servers';

  static String encode(String value) {
    if (value.isEmpty) return '';
    final bytes = utf8.encode(value);
    final out = Uint8List(bytes.length);
    for (var i = 0; i < bytes.length; i++) {
      out[i] = bytes[i] ^ _key.codeUnitAt(i % _key.length);
    }
    return base64Encode(out);
  }

  static String decode(String value) {
    if (value.isEmpty) return '';
    try {
      final bytes = base64Decode(value);
      final out = Uint8List(bytes.length);
      for (var i = 0; i < bytes.length; i++) {
        out[i] = bytes[i] ^ _key.codeUnitAt(i % _key.length);
      }
      return utf8.decode(out);
    } catch (_) {
      return '';
    }
  }
}
