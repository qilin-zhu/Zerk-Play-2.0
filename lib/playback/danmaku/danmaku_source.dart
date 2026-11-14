/// One place comments can come from.
///
/// The order of the list is the priority: matching asks the first source, and
/// only moves on when that one has nothing for this episode.
final class DanmakuSource {
  const DanmakuSource({
    required this.id,
    required this.name,
    required this.server,
    this.appId = '',
    this.appSecret = '',
    this.builtIn = false,
  });

  /// Stable across renames, used to key edits.
  final String id;

  /// Empty for the built-in source, which is named by the UI in the current
  /// language instead of being frozen into the saved settings.
  final String name;

  /// May carry a path: `danmu_api` serves everything under its token.
  final String server;

  /// The dandanplay API is signed, so a source needs both or it cannot be
  /// called at all.
  final String appId;
  final String appSecret;

  final bool builtIn;

  String get baseUrl => server.trim().replaceAll(RegExp(r'/+$'), '');

  bool get configured => baseUrl.isNotEmpty;

  bool get signed => appId.trim().isNotEmpty && appSecret.trim().isNotEmpty;

  /// A built-in source only works when the build carries credentials.
  bool get usable => configured && (!builtIn || signed);

  String get host {
    final uri = Uri.tryParse(baseUrl);
    return uri == null ? baseUrl : '${uri.host}:${uri.port}';
  }

  DanmakuSource copyWith({String? name, String? server, String? appId, String? appSecret}) => DanmakuSource(
        id: id,
        name: name ?? this.name,
        server: server ?? this.server,
        appId: appId ?? this.appId,
        appSecret: appSecret ?? this.appSecret,
        builtIn: builtIn,
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'name': name,
        'server': server,
        if (appId.isNotEmpty) 'appId': appId,
        if (appSecret.isNotEmpty) 'appSecret': appSecret,
        if (builtIn) 'builtIn': true,
      };

  static DanmakuSource? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id']?.toString();
    if (id == null || id.isEmpty) return null;
    return DanmakuSource(
      id: id,
      name: raw['name']?.toString() ?? '',
      server: raw['server']?.toString() ?? '',
      appId: raw['appId']?.toString() ?? '',
      appSecret: raw['appSecret']?.toString() ?? '',
      builtIn: raw['builtIn'] == true,
    );
  }
}

/// The public dandanplay network.
///
/// Its API is signed — unsigned calls come back 403, there is no anonymous
/// route — so the build has to carry a pair of developer credentials. Register
/// an application once at https://www.dandanplay.com/open.html, paste the two
/// values here, and no user ever has to fill anything in.
const kDandanplayAppId = '';
const kDandanplayAppSecret = '';

const kDandanplaySource = DanmakuSource(
  id: 'dandanplay',
  name: '',
  server: 'https://api.dandanplay.net',
  appId: kDandanplayAppId,
  appSecret: kDandanplayAppSecret,
  builtIn: true,
);
