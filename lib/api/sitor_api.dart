// 2026-09-25
// Client for sitor/api.php (see docs/CONTRACT.md).
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

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
  String get reasonLabel => switch (reason) {
    'before-publish' => 'Before upload',
    'before-restore' => 'Before restore',
    'manual' => 'Manual backup',
    _ => reason,
  };
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

  final http.Client _client = http.Client();

  static const _timeout = Duration(minutes: 3);
  static const _transferTimeout = Duration(minutes: 15);

  /// Verifies [password] (GET login). On success stores it in [key].
  Future<void> login(String password) async {
    // Browsers cannot put such characters into a header; it cannot match.
    if (password.isEmpty || password.codeUnits.any((c) => c > 0xFF)) {
      throw ApiException('Wrong password', status: 401);
    }
    await _json('GET', 'login', key: password);
    key = password;
  }

  Future<LoadedPage> load() async {
    final data = await _json('GET', 'load');
    final String html;
    try {
      html = utf8.decode(base64.decode(_string(data, 'html_b64')));
    } on FormatException {
      throw ApiException(
        'The page on the server is not UTF-8 text, so it cannot be edited '
        'safely.',
        status: 200,
      );
    }
    final siteBaseValue = data['site_base'];
    var siteBase = endpoint.resolve(
      siteBaseValue is String && siteBaseValue.isNotEmpty
          ? siteBaseValue
          : '../',
    );
    if (!siteBase.path.endsWith('/')) {
      siteBase = siteBase.replace(path: '${siteBase.path}/');
    }
    return LoadedPage(
      page: data['page']?.toString() ?? 'index.html',
      html: html,
      version: _string(data, 'version'),
      siteBase: siteBase,
    );
  }

  /// Uploads one image; returns its path relative to site root
  /// (e.g. `media/hero-20260925-141203.jpg`).
  Future<String> uploadImage(String fileName, Uint8List bytes) async {
    final data = await _json(
      'POST',
      'upload',
      query: {'name': fileName},
      body: bytes,
      contentType: 'application/octet-stream',
      timeout: _transferTimeout,
    );
    return _string(data, 'path');
  }

  /// Backs up the live site, then writes [html]. Returns the new version.
  Future<String> publish(String html, String baseVersion) async {
    final data = await _postJson('publish', {
      'html_b64': base64.encode(utf8.encode(html)),
      'base_version': baseVersion,
    });
    return _string(data, 'version');
  }

  Future<List<BackupInfo>> listBackups() async {
    final data = await _json('GET', 'backups');
    final list = data['backups'];
    if (list is! List) throw _unexpected(200);
    final backups = [
      for (final item in list)
        if (item is Map) _backup(item),
    ];
    backups.sort((a, b) => b.time.compareTo(a.time));
    return backups;
  }

  Future<BackupInfo> backupNow() async {
    final data = await _postJson('backup', const {});
    final backup = data['backup'];
    if (backup is! Map) throw _unexpected(200);
    return _backup(backup);
  }

  /// Restores backup [name] (server backs up the current site first).
  Future<void> restore(String name) async {
    await _postJson('restore', {'name': name});
  }

  Future<Uint8List> downloadBackup(String name) =>
      _download('download', {'name': name});

  Future<Uint8List> downloadCurrent() => _download('download_current', {});

  // --- internals ---

  Future<Map<String, dynamic>> _postJson(
    String action,
    Map<String, Object?> body,
  ) => _json(
    'POST',
    action,
    body: utf8.encode(jsonEncode(body)),
    contentType: 'application/json; charset=utf-8',
  );

  Future<Map<String, dynamic>> _json(
    String method,
    String action, {
    Map<String, String> query = const {},
    List<int>? body,
    String? contentType,
    String? key,
    Duration timeout = _timeout,
  }) async {
    final response = await _send(
      method,
      action,
      query: query,
      body: body,
      contentType: contentType,
      key: key,
      timeout: timeout,
    );
    final data = _decodeJson(response);
    if (data == null) throw _statusError(response.statusCode);
    final ok = data['ok'] == true;
    if (ok && response.statusCode >= 200 && response.statusCode < 300) {
      return data;
    }
    final error = data['error'];
    throw ApiException(
      error is String && error.trim().isNotEmpty
          ? error
          : _statusError(response.statusCode).message,
      status: response.statusCode,
    );
  }

  Future<Uint8List> _download(String action, Map<String, String> query) async {
    final response = await _send(
      'GET',
      action,
      query: query,
      timeout: _transferTimeout,
    );
    final type = response.headers['content-type'] ?? '';
    if (response.statusCode == 200 && !type.contains('json')) {
      return response.bodyBytes;
    }
    final data = _decodeJson(response);
    final error = data?['error'];
    if (error is String && error.trim().isNotEmpty) {
      throw ApiException(error, status: response.statusCode);
    }
    throw _statusError(response.statusCode);
  }

  Future<http.Response> _send(
    String method,
    String action, {
    Map<String, String> query = const {},
    List<int>? body,
    String? contentType,
    String? key,
    required Duration timeout,
  }) async {
    final uri = endpoint.replace(
      queryParameters: {
        ...endpoint.queryParameters,
        'action': action,
        ...query,
      },
    );
    final request = http.Request(method, uri);
    final password = key ?? this.key;
    if (password != null) request.headers['X-Sitor-Key'] = password;
    if (contentType != null) request.headers['Content-Type'] = contentType;
    if (body != null) request.bodyBytes = body;
    try {
      final streamed = await _client.send(request).timeout(timeout);
      return await http.Response.fromStream(streamed).timeout(timeout);
    } on TimeoutException {
      throw ApiException(
        'The server did not answer in time. Please try again.',
      );
    } catch (_) {
      throw ApiException(
        'Could not reach the server. Check the internet connection and try '
        'again.',
      );
    }
  }

  static Map<String, dynamic>? _decodeJson(http.Response response) {
    try {
      final data = jsonDecode(utf8.decode(response.bodyBytes));
      return data is Map<String, dynamic> ? data : null;
    } catch (_) {
      return null;
    }
  }

  static String _string(Map<String, dynamic> data, String field) {
    final value = data[field];
    if (value is String) return value;
    throw _unexpected(200);
  }

  static BackupInfo _backup(Map<dynamic, dynamic> json) {
    int toInt(Object? v) =>
        v is num ? v.toInt() : int.tryParse(v?.toString() ?? '') ?? 0;
    return BackupInfo(
      name: json['name']?.toString() ?? '',
      time: DateTime.fromMillisecondsSinceEpoch(toInt(json['time']) * 1000),
      size: toInt(json['size']),
      reason: json['reason']?.toString() ?? '',
    );
  }

  static ApiException _unexpected(int status) => ApiException(
    'The server sent an unexpected answer (HTTP $status). Check that the '
    'editor files (api.php) are installed and PHP is enabled.',
    status: status,
  );

  /// For error responses that are not our JSON (firewall page, 404, PHP
  /// fatal error...).
  static ApiException _statusError(int status) {
    final message = switch (status) {
      401 => 'Wrong password',
      403 || 406 =>
        'The server refused the request (HTTP $status). The hosting firewall '
            'may be blocking it.',
      404 =>
        'The editor\'s server script (api.php) was not found (HTTP 404).',
      409 =>
        'The website was changed by someone else since you opened the '
            'editor. Reload the editor.',
      413 => 'The file is too large for the server (HTTP 413).',
      >= 500 =>
        'The server had an internal error (HTTP $status). Please try again '
            'later.',
      >= 200 && < 300 => _unexpected(status).message,
      _ => 'The server answered with an error (HTTP $status).',
    };
    return ApiException(message, status: status);
  }
}
