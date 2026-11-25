abstract final class Release {
  /// 版本的唯一来源：CI 用 --dart-define=APP_VERSION 注入（与 pubspec 的
  /// version: 前半段一致），tag / 显示名都从这里派生。
  /// 没注入时（本地裸 flutter run）回退到这个默认值，发版前记得与 pubspec 同步。
  static const version = String.fromEnvironment('APP_VERSION', defaultValue: '2.10.11');
  static const tag = 'v$version';
  static String get name => 'Zerk Play $version';
  static const repository = 'qilin-zhu/Zerk-Play-2.0';
  static const hub = String.fromEnvironment('ZERK_HUB_URL', defaultValue: 'https://zerk.digital');
}
