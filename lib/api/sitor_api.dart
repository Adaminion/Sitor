// 2026-09-25
// Client for sitor/api.php (see docs/CONTRACT.md).
import 'dart:typed_data';

/// Thrown for any failed call. [message] is human readable (shown to the
/// user as-is). [status] is the HTTP status (0 = network failure).
class ApiException implements Exception {
  ApiException(this.message, {this.status = 0});
  final String message;
  final int status;
  bool get isAuth => status == 401;
  bool get isConflict => status == 409;
  @override
  String toString() => message;
}

class BackupInfo {
  const BackupInfo({
    required this.name,
    required this.time,
    required this.size,
    required this.reason,
  });
  final String name;

  /// Server time of the backup (from unix seconds), in local time zone.
  final DateTime time;
  final int size;

  /// "before-publish" | "before-restore" | "manual" (or anything else).
  final String reason;

  /// "Before upload", "Before restore", "Manual backup", else [reason].
  String get reasonLabel => throw UnimplementedError();
}

class LoadedPage {
  const LoadedPage({
    required this.page,
    required this.html,
    required this.version,
    required this.siteBase,
  });
  final String page;

  /// Decoded (utf-8) page HTML.
  final String html;
  final String version;

  /// Absolute URL of the site root, ending with '/'
  /// (`site_base` resolved against the api.php URL).
  final Uri siteBase;
}

class SitorApi {
  /// [endpoint] = absolute URL of api.php.
  SitorApi(this.endpoint);

  final Uri endpoint;

  /// Password sent as `X-Sitor-Key`. Set by [login].
  String? key;

  /// Verifies [password] (GET login). On success stores it in [key].
  Future<void> login(String password) => throw UnimplementedError();

  Future<LoadedPage> load() => throw UnimplementedError();

  /// Uploads one image; returns its path relative to site root
  /// (e.g. `media/hero-20260925-141203.jpg`).
  Future<String> uploadImage(String fileName, Uint8List bytes) =>
      throw UnimplementedError();

  /// Backs up the live site, then writes [html]. Returns the new version.
  Future<String> publish(String html, String baseVersion) =>
      throw UnimplementedError();

  Future<List<BackupInfo>> listBackups() => throw UnimplementedError();

  Future<BackupInfo> backupNow() => throw UnimplementedError();

  /// Restores backup [name] (server backs up the current site first).
  Future<void> restore(String name) => throw UnimplementedError();

  Future<Uint8List> downloadBackup(String name) => throw UnimplementedError();

  Future<Uint8List> downloadCurrent() => throw UnimplementedError();
}
