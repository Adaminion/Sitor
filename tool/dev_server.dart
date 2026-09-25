// 2026-09-25
// Local stand-in for web/api.php (there is no PHP on the dev machine) that
// also serves the built app and a scratch copy of the site:
//
//   dart run tool/dev_server.dart [--port 8080] [--key test]
//       [--site website/current] [--app build/web] [--reset]
//
//   /sitor/api.php  -> same HTTP API as web/api.php (docs/CONTRACT.md)
//   /sitor/...      -> files from --app
//   everything else -> the site copy in .sitor_dev/site
//
// --site is copied once into .sitor_dev/site and never modified. Backups go
// to .sitor_dev/backups. --reset deletes .sitor_dev and starts over.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:archive/archive.dart';

const _usage = '''
Usage: dart run tool/dev_server.dart [options]
  --port <n>      port to listen on (default 8080)
  --key <text>    editor password (default "test"; "" = not configured)
  --site <dir>    website to copy into .sitor_dev/site (default website/current)
  --app <dir>     app served at /sitor/ (default build/web)
  --keep-backups <n>  keep only the newest n backups (default 0 = all)
  --reset         delete .sitor_dev first''';

const _page = 'index.html';
const _siteBase = '../';
// Folder name of the editor inside the site root in production.
const _editorDir = 'sitor';
const _maxUpload = 20 * 1024 * 1024;
const _maxBody = 40 * 1024 * 1024;
const _conflict =
    'The website was changed by someone else since you opened the editor. '
    'Reload the editor.';
const _damaged = 'The backup file is damaged or is not a ZIP file.';
const _notConfigured =
    r'Sitor is not configured yet: set $SITOR_PASSWORD in sitor/config.php';

const _methods = {
  'ping': 'GET',
  'login': 'GET',
  'load': 'GET',
  'upload': 'POST',
  'publish': 'POST',
  'backups': 'GET',
  'backup': 'POST',
  'restore': 'POST',
  'download': 'GET',
  'download_current': 'GET',
};

const _contentTypes = {
  'html': 'text/html; charset=utf-8',
  'htm': 'text/html; charset=utf-8',
  'js': 'text/javascript; charset=utf-8',
  'mjs': 'text/javascript; charset=utf-8',
  'wasm': 'application/wasm',
  'json': 'application/json; charset=utf-8',
  'map': 'application/json; charset=utf-8',
  'css': 'text/css; charset=utf-8',
  'txt': 'text/plain; charset=utf-8',
  'png': 'image/png',
  'jpg': 'image/jpeg',
  'jpeg': 'image/jpeg',
  'gif': 'image/gif',
  'webp': 'image/webp',
  'svg': 'image/svg+xml',
  'ico': 'image/x-icon',
  'zip': 'application/zip',
  'otf': 'font/otf',
  'ttf': 'font/ttf',
  'woff': 'font/woff',
  'woff2': 'font/woff2',
  'symbols': 'application/octet-stream',
};

/// Expected failure: HTTP [status] + human readable [message].
class _Fail implements Exception {
  _Fail(this.status, this.message);
  final int status;
  final String message;
}

Never _die(String message) {
  stderr.writeln(message);
  exit(64);
}

Future<void> main(List<String> args) async {
  final opts = {
    'port': '8080',
    'key': 'test',
    'site': 'website/current',
    'app': 'build/web',
    'keep-backups': '0',
  };
  var reset = false;
  for (var i = 0; i < args.length; i++) {
    final a = args[i];
    if (a == '--reset') {
      reset = true;
      continue;
    }
    if (a == '-h' || a == '--help') {
      stdout.writeln(_usage);
      return;
    }
    final eq = a.indexOf('=');
    final name = a.startsWith('--')
        ? a.substring(2, eq < 0 ? a.length : eq)
        : '';
    if (!opts.containsKey(name)) _die('Unknown option: $a\n$_usage');
    if (eq >= 0) {
      opts[name] = a.substring(eq + 1);
    } else if (i + 1 < args.length) {
      opts[name] = args[++i];
    } else {
      _die('Missing value for $a');
    }
  }
  final port = int.tryParse(opts['port']!) ?? _die('Bad --port');
  final keep =
      int.tryParse(opts['keep-backups']!) ?? _die('Bad --keep-backups');
  final source = Directory(opts['site']!);
  final app = Directory(opts['app']!);
  if (!source.existsSync()) _die('Site folder not found: ${source.path}');
  if (!app.existsSync()) {
    stderr.writeln(
      'Warning: app folder ${app.path} not found '
      '(run "flutter build web" first).',
    );
  }

  final root = Directory('.sitor_dev').absolute;
  if (reset && root.existsSync()) root.deleteSync(recursive: true);
  final site = Directory(_join(root.path, 'site'));
  if (!site.existsSync()) {
    final tmp = Directory(_join(root.path, 'site.tmp'));
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    _copyDir(source, tmp);
    tmp.renameSync(site.path);
    stdout.writeln('Copied ${source.path} -> ${site.path}');
  }

  final dev = _DevServer(
    site: site,
    backups: Directory(_join(root.path, 'backups')),
    app: app.absolute,
    key: opts['key']!,
    keepBackups: keep,
  );
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
  server.autoCompress = false;
  stdout.writeln('Sitor dev server: http://localhost:$port/sitor/');
  stdout.writeln('Password (X-Sitor-Key): "${dev.key}"');
  stdout.writeln('Site copy: ${site.path}');
  await for (final req in server) {
    unawaited(dev.handle(req));
  }
}

void _copyDir(Directory from, Directory to) {
  to.createSync(recursive: true);
  for (final e in from.listSync(followLinks: false)) {
    final target = '${to.path}${Platform.pathSeparator}${_basename(e.path)}';
    if (e is Directory) {
      _copyDir(e, Directory(target));
    } else if (e is File) {
      e.copySync(target);
    }
  }
}

String _basename(String path) => path.split(RegExp(r'[\\/]')).last;

String _join(String dir, String rel) =>
    [dir, ...rel.split('/')].join(Platform.pathSeparator);

String _two(int n) => n.toString().padLeft(2, '0');

/// PHP date('Y-m-d_H-i-s').
String _stamp(DateTime t) =>
    '${t.year}-${_two(t.month)}-${_two(t.day)}_'
    '${_two(t.hour)}-${_two(t.minute)}-${_two(t.second)}';

/// PHP date('Ymd-His').
String _compactStamp(DateTime t) =>
    '${t.year}${_two(t.month)}${_two(t.day)}-'
    '${_two(t.hour)}${_two(t.minute)}${_two(t.second)}';

final _random = math.Random();
String _uniq() =>
    List.generate(16, (_) => _random.nextInt(16).toRadixString(16)).join();

class _DevServer {
  _DevServer({
    required this.site,
    required this.backups,
    required this.app,
    required this.key,
    required this.keepBackups,
  });

  final Directory site;
  final Directory backups;
  final Directory app;
  final String key;

  /// Like `$SITOR_KEEP_BACKUPS`: 0 = keep all.
  final int keepBackups;

  Future<void> _lock = Future.value();

  /// Runs [f] after every previously serialized call finished.
  Future<T> _serialized<T>(Future<T> Function() f) {
    final result = _lock.then((_) => f());
    _lock = result.then((_) {}, onError: (_) {});
    return result;
  }

  Future<void> handle(HttpRequest req) async {
    final res = req.response;
    res.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
    res.headers.set('X-Content-Type-Options', 'nosniff');
    try {
      final path = req.uri.path;
      if (path == '/sitor/api.php') {
        await _api(req);
      } else if (path == '/sitor') {
        final q = req.uri.hasQuery ? '?${req.uri.query}' : '';
        await _plain(req, 301, 'Moved', location: '/sitor/$q');
      } else if (path.startsWith('/sitor/')) {
        await _static(req, app, req.uri.pathSegments.skip(1).toList(), true);
      } else {
        await _static(req, site, req.uri.pathSegments, false);
      }
    } catch (e, st) {
      stderr.writeln('$e\n$st');
      try {
        await _plain(req, 500, 'Server error: $e');
      } catch (_) {}
    }
    stdout.writeln('${req.method} ${req.uri} -> ${res.statusCode}');
  }

  Future<void> _plain(
    HttpRequest req,
    int status,
    String text, {
    String? location,
  }) async {
    final res = req.response;
    res.statusCode = status;
    if (location != null) res.headers.set(HttpHeaders.locationHeader, location);
    res.headers.contentType = ContentType.text;
    res.write(text);
    await res.close();
  }

  // ------------------------------------------------------------ static files

  Future<void> _static(
    HttpRequest req,
    Directory root,
    List<String> segments,
    bool isApp,
  ) async {
    await req.drain<void>();
    if (req.method != 'GET' && req.method != 'HEAD') {
      req.response.headers.set('Allow', 'GET, HEAD');
      return _plain(req, 405, 'Method not allowed');
    }
    final wantsDir = segments.isEmpty || segments.last.isEmpty;
    final segs = segments.where((s) => s.isNotEmpty).toList();
    for (final s in segs) {
      if (s.startsWith('.') || s.contains(RegExp(r'[\\/:\x00]'))) {
        return _plain(req, 404, 'Not found');
      }
    }
    if (isApp &&
        ((segs.isNotEmpty && segs.first == 'backups') ||
            (segs.isNotEmpty && segs.last.toLowerCase().endsWith('.php')))) {
      return _plain(req, 403, 'Forbidden');
    }
    var path = [root.path, ...segs].join(Platform.pathSeparator);
    if (wantsDir || Directory(path).existsSync()) {
      if (!wantsDir) {
        final q = req.uri.hasQuery ? '?${req.uri.query}' : '';
        return _plain(req, 301, 'Moved', location: '${req.uri.path}/$q');
      }
      path = '$path${Platform.pathSeparator}index.html';
    }
    final file = File(path);
    if (!file.existsSync()) return _plain(req, 404, 'Not found');
    final bytes = await file.readAsBytes();
    final name = _basename(path);
    final dot = name.lastIndexOf('.');
    final ext = dot < 0 ? '' : name.substring(dot + 1).toLowerCase();
    final res = req.response;
    res.headers.set(
      HttpHeaders.contentTypeHeader,
      _contentTypes[ext] ?? 'application/octet-stream',
    );
    res.contentLength = bytes.length;
    if (req.method == 'GET') res.add(bytes);
    await res.close();
  }

  // ------------------------------------------------------------------- API

  Future<void> _api(HttpRequest req) async {
    try {
      final (body, tooBig) = await _readBody(req);
      final action = req.uri.queryParameters['action'] ?? '';
      final method = _methods[action];
      if (method == null) throw _Fail(400, 'Unknown action.');
      if (req.method != method) {
        req.response.headers.set('Allow', method);
        throw _Fail(405, 'Method not allowed.');
      }
      if (action == 'ping') {
        return _json(req, 200, {'ok': true, 'app': 'sitor', 'version': 1});
      }
      if (key.trim().isEmpty) throw _Fail(500, _notConfigured);
      if (!_sameKey(key, req.headers['x-sitor-key']?.first ?? '')) {
        await Future<void>.delayed(const Duration(seconds: 1));
        throw _Fail(401, 'Wrong password');
      }
      switch (action) {
        case 'login':
          _pageFile();
          // Mirrors the value PHP reports; package:archive does the work here.
          return _json(req, 200, {
            'ok': true,
            'page': _page,
            'zip': 'ZipArchive',
          });
        case 'load':
          final data = await _pageFile().readAsBytes();
          return _json(req, 200, {
            'ok': true,
            'page': _page,
            'html_b64': base64Encode(data),
            'version': _md5Hex(data),
            'site_base': _siteBase,
          });
        case 'upload':
          return _json(req, 200, await _upload(req, body, tooBig));
        case 'publish':
          if (tooBig) throw _Fail(400, 'The request is too big.');
          return _json(req, 200, await _publish(_jsonBody(body)));
        case 'backups':
          return _json(req, 200, {'ok': true, 'backups': _listBackups()});
        case 'backup':
          final info = await _serialized(() => _createBackup('manual'));
          return _json(req, 200, {'ok': true, 'backup': info});
        case 'restore':
          if (tooBig) throw _Fail(400, 'The request is too big.');
          return _json(req, 200, await _restore(_jsonBody(body)));
        case 'download':
          final name = req.uri.queryParameters['name'] ?? '';
          final file = _backupFile(name);
          return _zip(req, await file.readAsBytes(), name);
        case 'download_current':
          return _zip(
            req,
            await _zipSite(),
            'website-${_stamp(DateTime.now())}.zip',
          );
      }
    } on _Fail catch (e) {
      await _json(req, e.status, {'ok': false, 'error': e.message});
    } catch (e, st) {
      stderr.writeln('$e\n$st');
      await _json(req, 500, {'ok': false, 'error': 'Server error: $e'});
    }
  }

  /// The whole body, or empty + true once it exceeds [_maxBody].
  Future<(Uint8List, bool)> _readBody(HttpRequest req) async {
    final b = BytesBuilder(copy: false);
    var over = false;
    await for (final chunk in req) {
      if (over) continue;
      if (b.length + chunk.length > _maxBody) {
        over = true;
        b.clear();
      } else {
        b.add(chunk);
      }
    }
    return (b.takeBytes(), over);
  }

  Future<void> _json(HttpRequest req, int status, Map<String, Object?> data) {
    final res = req.response;
    final bytes = utf8.encode(jsonEncode(data));
    res.statusCode = status;
    res.headers.set(
      HttpHeaders.contentTypeHeader,
      'application/json; charset=utf-8',
    );
    res.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
    res.contentLength = bytes.length;
    res.add(bytes);
    return res.close();
  }

  Future<void> _zip(HttpRequest req, List<int> bytes, String fileName) {
    final res = req.response;
    res.statusCode = 200;
    res.headers.set(HttpHeaders.contentTypeHeader, 'application/zip');
    res.headers.set('Content-Disposition', 'attachment; filename="$fileName"');
    res.contentLength = bytes.length;
    res.add(bytes);
    return res.close();
  }

  Map<String, dynamic> _jsonBody(Uint8List body) {
    Object? data;
    try {
      data = jsonDecode(utf8.decode(body));
    } catch (_) {}
    if (data is! Map<String, dynamic>) {
      throw _Fail(400, 'Invalid request (expected a JSON object).');
    }
    return data;
  }

  File _pageFile() {
    final f = File(_join(site.path, _page));
    if (!f.existsSync()) {
      throw _Fail(500, 'The page $_page was not found in the website folder.');
    }
    return f;
  }

  Future<Map<String, Object?>> _upload(
    HttpRequest req,
    Uint8List data,
    bool tooBig,
  ) async {
    var name = (req.uri.queryParameters['name'] ?? '').replaceFirst(
      RegExp(r'^.*[/\\]'),
      '',
    );
    if (name.trim().isEmpty) throw _Fail(400, 'Missing file name.');
    final dot = name.lastIndexOf('.');
    final ext = dot < 0 ? '' : name.substring(dot + 1).toLowerCase();
    var stem = dot < 0 ? name : name.substring(0, dot);
    if (!const ['jpg', 'jpeg', 'png', 'gif', 'webp'].contains(ext)) {
      throw _Fail(400, 'Only JPG, PNG, GIF and WEBP pictures can be uploaded.');
    }
    if (tooBig || data.length > _maxUpload) {
      throw _Fail(400, 'The picture is too big (max 20 MB).');
    }
    if (data.isEmpty) throw _Fail(400, 'The uploaded file is empty.');
    // The stored extension follows the actual content (jpeg -> jpg).
    final type = _imageType(data);
    if (type.isEmpty) {
      throw _Fail(400, 'This file is not a JPG, PNG, GIF or WEBP picture.');
    }
    // PHP strtolower only folds ASCII; everything else becomes '-' anyway.
    stem = stem
        .replaceAllMapped(RegExp('[A-Z]'), (m) => m[0]!.toLowerCase())
        .replaceAll(RegExp('[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    if (stem.length > 40) {
      stem = stem.substring(0, 40).replaceAll(RegExp(r'-+$'), '');
    }
    if (stem.isEmpty) stem = 'picture';
    return _serialized(() async {
      final media = Directory(_join(site.path, 'media'));
      media.createSync(recursive: true);
      final base = '$stem-${_compactStamp(DateTime.now())}';
      var file = '$base.$type';
      for (var i = 2; File(_join(media.path, file)).existsSync(); i++) {
        file = '$base-$i.$type';
      }
      await _writeFile(File(_join(media.path, file)), data);
      return {'ok': true, 'path': 'media/$file'};
    });
  }

  Future<Map<String, Object?>> _publish(Map<String, dynamic> req) async {
    final b64 = req['html_b64'];
    if (b64 is! String) throw _Fail(400, 'Missing page data (html_b64).');
    final html = _decodeBase64(b64);
    if (html == null) throw _Fail(400, 'The page data is not valid base64.');
    if (html.isEmpty) throw _Fail(400, 'Refusing to save an empty page.');
    final base = req['base_version'];
    if (base is! String) throw _Fail(400, 'Missing base_version.');
    return _serialized(() async {
      final page = _pageFile();
      if (_md5Hex(await page.readAsBytes()) != base) {
        throw _Fail(409, _conflict);
      }
      final backup = await _createBackup('before-publish');
      await _writeFile(page, html);
      return {'ok': true, 'version': _md5Hex(html), 'backup': backup};
    });
  }

  Future<Map<String, Object?>> _restore(Map<String, dynamic> req) async {
    final zipFile = _backupFile(req['name']);
    return _serialized(() async {
      final bytes = await zipFile.readAsBytes();
      final Archive archive;
      try {
        // Garbage decodes to an empty archive; PHP reports it as damaged.
        if (bytes.length < 22 || bytes[0] != 0x50 || bytes[1] != 0x4B) {
          throw const FormatException();
        }
        archive = ZipDecoder().decodeBytes(bytes);
      } catch (_) {
        throw _Fail(400, _damaged);
      }
      // Validate every entry before touching anything.
      var files = 0;
      for (final f in archive) {
        if (!_entryOk(f.name)) {
          throw _Fail(
            400,
            'The backup contains an unsafe file name (${f.name}). '
            'Nothing was restored.',
          );
        }
        if (f.isFile) files++;
      }
      if (files == 0) {
        throw _Fail(400, 'The backup is empty. Nothing was restored.');
      }
      final backup = await _createBackup('before-restore', prune: false);
      for (final f in archive) {
        final rel = f.name.endsWith('/')
            ? f.name.substring(0, f.name.length - 1)
            : f.name;
        final target = _join(site.path, rel);
        if (!f.isFile) {
          Directory(target).createSync(recursive: true);
          continue;
        }
        final data = f.readBytes();
        if (data == null) throw _Fail(400, _damaged);
        final out = File(target);
        out.parent.createSync(recursive: true);
        await _writeFile(out, data);
      }
      _prune();
      final page = File(_join(site.path, _page));
      return {
        'ok': true,
        'version': page.existsSync() ? _md5Hex(await page.readAsBytes()) : '',
        'backup': backup,
      };
    });
  }

  // --------------------------------------------------------------- backups

  bool _isBackupName(Object? name) =>
      name is String &&
      RegExp(r'^[A-Za-z0-9_.-]+\.zip$').hasMatch(name) &&
      !name.startsWith('.');

  File _backupFile(Object? name) {
    if (!_isBackupName(name)) throw _Fail(400, 'Invalid backup name.');
    final f = File(_join(backups.path, name as String));
    if (!f.existsSync()) throw _Fail(404, 'Backup not found.');
    return f;
  }

  String _reason(String name) {
    final m = RegExp(
      r'^\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}_([a-z]+(?:-[a-z]+)*)(?:-\d+)?\.zip$',
    ).firstMatch(name);
    return m == null ? 'other' : m[1]!;
  }

  int _seq(String name) {
    final m = RegExp(r'-(\d+)\.zip$').firstMatch(name);
    return m == null ? 1 : int.parse(m[1]!);
  }

  Map<String, Object> _info(String name) {
    final stat = File(_join(backups.path, name)).statSync();
    return {
      'name': name,
      'time': stat.modified.millisecondsSinceEpoch ~/ 1000,
      'size': stat.size,
      'reason': _reason(name),
    };
  }

  /// Newest first.
  List<Map<String, Object>> _listBackups() {
    if (!backups.existsSync()) return [];
    final out = [
      for (final e in backups.listSync())
        if (e is File &&
            _isBackupName(_basename(e.path)) &&
            !_basename(e.path).startsWith('tmp-'))
          _info(_basename(e.path)),
    ];
    out.sort((a, b) {
      final ta = a['time'] as int, tb = b['time'] as int;
      if (ta != tb) return tb - ta;
      final na = a['name'] as String, nb = b['name'] as String;
      final sa = _seq(na), sb = _seq(nb);
      if (sa != sb) return sb - sa;
      return nb.compareTo(na);
    });
    return out;
  }

  void _prune() {
    if (keepBackups <= 0) return;
    final list = _listBackups();
    for (var i = keepBackups; i < list.length; i++) {
      File(_join(backups.path, list[i]['name'] as String)).deleteSync();
    }
  }

  void _ensureBackupDir() {
    backups.createSync(recursive: true);
    final ht = File(_join(backups.path, '.htaccess'));
    if (!ht.existsSync()) {
      ht.writeAsStringSync(
        '<IfModule mod_authz_core.c>\n  Require all denied\n</IfModule>\n'
        '<IfModule !mod_authz_core.c>\n  Order allow,deny\n  Deny from all\n'
        '</IfModule>\n',
      );
    }
    final index = File(_join(backups.path, 'index.html'));
    if (!index.existsSync()) index.writeAsStringSync('');
  }

  /// Site-relative paths of every file a backup contains, sorted like PHP.
  List<String> _siteFiles() {
    final out = <String>[];
    void walk(Directory dir, String rel) {
      final entries = dir.listSync(followLinks: false)
        ..sort((a, b) => _basename(a.path).compareTo(_basename(b.path)));
      for (final e in entries) {
        final name = _basename(e.path);
        if (name.startsWith('.') || name == 'cgi-bin') continue;
        final childRel = rel.isEmpty ? name : '$rel/$name';
        if (e is Directory) {
          if (rel.isEmpty && name == _editorDir) continue;
          if (e.absolute.path == backups.path) continue;
          walk(e, childRel);
        } else if (e is File) {
          out.add(childRel);
        }
      }
    }

    walk(site, '');
    return out;
  }

  Future<Uint8List> _zipSite() async {
    final archive = Archive();
    for (final rel in _siteFiles()) {
      final f = File(_join(site.path, rel));
      archive.addFile(
        ArchiveFile.bytes(rel, await f.readAsBytes())
          ..lastModTime = f.statSync().modified.millisecondsSinceEpoch ~/ 1000,
      );
    }
    return ZipEncoder().encodeBytes(archive);
  }

  /// Zips the site into the backups folder. Caller serializes.
  Future<Map<String, Object>> _createBackup(
    String reason, {
    bool prune = true,
  }) async {
    _ensureBackupDir();
    final zip = await _zipSite();
    final base = '${_stamp(DateTime.now())}_$reason';
    var name = '$base.zip';
    for (var i = 2; File(_join(backups.path, name)).existsSync(); i++) {
      name = '$base-$i.zip';
    }
    final tmp = File(_join(backups.path, 'tmp-${_uniq()}.zip'));
    try {
      await tmp.writeAsBytes(zip, flush: true);
      await tmp.rename(_join(backups.path, name));
    } catch (_) {
      if (tmp.existsSync()) tmp.deleteSync();
      rethrow;
    }
    if (prune) _prune();
    return _info(name);
  }

  /// Safe relative entry name that does not land in the editor folder.
  bool _entryOk(String name) {
    if (name.isEmpty ||
        name.startsWith('/') ||
        name.contains('\\') ||
        name.contains(RegExp('[\x00-\x1f\x7f]')) ||
        RegExp('^[A-Za-z]:').hasMatch(name)) {
      return false;
    }
    final path = name.endsWith('/') ? name.substring(0, name.length - 1) : name;
    if (path.isEmpty) return false;
    for (final seg in path.split('/')) {
      if (seg.isEmpty || seg.startsWith('.')) return false;
    }
    final lower = path.toLowerCase();
    return lower != _editorDir && !lower.startsWith('$_editorDir/');
  }
}

/// Temp file + rename; falls back to a direct write.
Future<void> _writeFile(File file, List<int> data) async {
  final tmp = File(_join(file.parent.path, '.sitor-tmp-${_uniq()}'));
  try {
    await tmp.writeAsBytes(data, flush: true);
    await tmp.rename(file.path);
  } catch (_) {
    try {
      if (tmp.existsSync()) tmp.deleteSync();
    } catch (_) {}
    await file.writeAsBytes(data, flush: true);
  }
}

String _imageType(Uint8List d) {
  bool starts(List<int> magic, [int at = 0]) {
    if (d.length < at + magic.length) return false;
    for (var i = 0; i < magic.length; i++) {
      if (d[at + i] != magic[i]) return false;
    }
    return true;
  }

  if (starts([0xFF, 0xD8, 0xFF])) return 'jpg';
  if (starts([0x89, 0x50, 0x4E, 0x47])) return 'png';
  if (starts(ascii.encode('GIF8'))) return 'gif';
  if (starts(ascii.encode('RIFF')) && starts(ascii.encode('WEBP'), 8)) {
    return 'webp';
  }
  return '';
}

/// Like PHP base64_decode($s, true): whitespace ignored, anything outside
/// the standard alphabet rejected.
Uint8List? _decodeBase64(String s) {
  final t = s.replaceAll(RegExp(r'\s'), '');
  if (!RegExp(r'^[A-Za-z0-9+/]*={0,2}$').hasMatch(t) || t.length % 4 == 1) {
    return null;
  }
  try {
    return base64.decode(base64.normalize(t));
  } on FormatException {
    return null;
  }
}

bool _sameKey(String a, String b) {
  final x = utf8.encode(a), y = utf8.encode(b);
  var diff = x.length ^ y.length;
  for (var i = 0; i < x.length; i++) {
    diff |= x[i] ^ (i < y.length ? y[i] : 0);
  }
  return diff == 0;
}

/// MD5 hex digest (RFC 1321), same as PHP md5() / md5_file().
String _md5Hex(List<int> input) {
  const s = [
    7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, //
    5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
    4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
    6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21,
  ];
  final k = List<int>.generate(
    64,
    (i) => (math.sin(i + 1).abs() * 4294967296).floor() & 0xffffffff,
  );
  const mask = 0xffffffff;
  final n = input.length;
  final padded = Uint8List(((n + 8) ~/ 64 + 1) * 64)
    ..setRange(0, n, input)
    ..[n] = 0x80;
  final bd = ByteData.sublistView(padded);
  final bits = n * 8;
  bd.setUint32(padded.length - 8, bits & mask, Endian.little);
  bd.setUint32(padded.length - 4, (bits ~/ 0x100000000) & mask, Endian.little);

  var a0 = 0x67452301, b0 = 0xefcdab89, c0 = 0x98badcfe, d0 = 0x10325476;
  for (var off = 0; off < padded.length; off += 64) {
    var a = a0, b = b0, c = c0, d = d0;
    for (var i = 0; i < 64; i++) {
      int f, g;
      if (i < 16) {
        f = (b & c) | (~b & d);
        g = i;
      } else if (i < 32) {
        f = (d & b) | (~d & c);
        g = (5 * i + 1) % 16;
      } else if (i < 48) {
        f = b ^ c ^ d;
        g = (3 * i + 5) % 16;
      } else {
        f = c ^ (b | ~d);
        g = (7 * i) % 16;
      }
      f = (f + a + k[i] + bd.getUint32(off + g * 4, Endian.little)) & mask;
      a = d;
      d = c;
      c = b;
      b = (b + (((f << s[i]) | (f >> (32 - s[i]))) & mask)) & mask;
    }
    a0 = (a0 + a) & mask;
    b0 = (b0 + b) & mask;
    c0 = (c0 + c) & mask;
    d0 = (d0 + d) & mask;
  }
  final out = ByteData(16)
    ..setUint32(0, a0, Endian.little)
    ..setUint32(4, b0, Endian.little)
    ..setUint32(8, c0, Endian.little)
    ..setUint32(12, d0, Endian.little);
  return [
    for (var i = 0; i < 16; i++)
      out.getUint8(i).toRadixString(16).padLeft(2, '0'),
  ].join();
}
