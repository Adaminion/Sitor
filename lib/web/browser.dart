// 2026-09-25
// All browser interop (package:web, dart:ui_web) lives here. Web-only.
import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui_web' as ui_web;

import 'package:flutter/widgets.dart';
import 'package:web/web.dart' as web;

/// Base URL of the running app (document.baseURI), e.g.
/// https://example.com/sitor/ — resolve `api.php` against it.
Uri get appBaseUri => Uri.parse(web.document.baseURI);

bool _dropsBlocked = false;

/// Call once at startup: stop the browser from navigating to a file that is
/// dropped anywhere outside a drop target (which would lose all edits).
void preventWindowFileDrops() {
  if (_dropsBlocked) return;
  _dropsBlocked = true;
  // No stopPropagation: FileDropZone listens on the same window.
  void block(web.Event event) {
    final types = (event as web.DragEvent).dataTransfer?.types.toDart;
    final hasFiles = types?.any((t) => t.toDart == 'Files') ?? false;
    final target = event.target;
    final isTextInput =
        target != null &&
        (target.instanceOfString('HTMLInputElement') ||
            target.instanceOfString('HTMLTextAreaElement'));
    if (hasFiles || !isTextInput) event.preventDefault();
  }

  web.window.addEventListener('dragover', block.toJS);
  web.window.addEventListener('drop', block.toJS);
}

JSFunction? _beforeUnload;

/// While [enabled], closing/reloading the tab asks "Leave site?".
void setLeaveWarning(bool enabled) {
  if (enabled && _beforeUnload == null) {
    _beforeUnload = ((web.Event event) {
      event.preventDefault();
      (event as web.BeforeUnloadEvent).returnValue =
          'You have changes that are not uploaded yet.';
    }).toJS;
    web.window.addEventListener('beforeunload', _beforeUnload);
  } else if (!enabled && _beforeUnload != null) {
    web.window.removeEventListener('beforeunload', _beforeUnload);
    _beforeUnload = null;
  }
}

/// Small key/value store (localStorage), failures swallowed (returns null).
String? loadSetting(String key) {
  try {
    return web.window.localStorage.getItem(key);
  } catch (_) {
    return null;
  }
}

void saveSetting(String key, String? value) {
  try {
    final storage = web.window.localStorage;
    if (value == null) {
      storage.removeItem(key);
    } else {
      storage.setItem(key, value);
    }
  } catch (_) {}
}

class PickedFile {
  const PickedFile({
    required this.name,
    required this.bytes,
    required this.mimeType,
  });
  final String name;
  final Uint8List bytes;
  final String mimeType;
}

/// Opens the browser file dialog for one image
/// (accept: .jpg,.jpeg,.png,.gif,.webp). null if cancelled.
Future<PickedFile?> pickImageFile() {
  final completer = Completer<PickedFile?>();
  final input = web.document.createElement('input') as web.HTMLInputElement
    ..type = 'file'
    ..accept = '.jpg,.jpeg,.png,.gif,.webp'
    ..setAttribute('style', 'display:none');

  void finish(PickedFile? result, [Object? error]) {
    if (completer.isCompleted) return;
    input.remove();
    if (error != null) {
      completer.completeError(error);
    } else {
      completer.complete(result);
    }
  }

  Future<void> read(web.File file) async {
    try {
      final buffer = await file.arrayBuffer().toDart;
      finish(
        PickedFile(
          name: file.name,
          bytes: buffer.toDart.asUint8List(),
          mimeType: file.type.isEmpty ? 'application/octet-stream' : file.type,
        ),
      );
    } catch (_) {
      finish(null, ImageFormatException('Could not read this file.'));
    }
  }

  input.addEventListener(
    'change',
    ((web.Event _) {
      final file = input.files?.item(0);
      if (file == null) {
        finish(null);
      } else {
        read(file);
      }
    }).toJS,
  );
  input.addEventListener('cancel', ((web.Event _) => finish(null)).toJS);
  web.document.body?.appendChild(input);
  // Must stay synchronous up to here: click() needs the user gesture.
  input.click();
  return completer.future;
}

class PreparedImage {
  const PreparedImage({
    required this.fileName,
    required this.bytes,
    required this.mimeType,
    required this.width,
    required this.height,
  });

  /// Name to upload under, extension matching [bytes] (e.g. `IMG_1234.jpg`).
  final String fileName;
  final Uint8List bytes;
  final String mimeType;
  final int width;
  final int height;
}

class ImageFormatException implements Exception {
  ImageFormatException(this.message);
  final String message;
  @override
  String toString() => message;
}

const _unreadableImage =
    'This file is not a picture the browser can read. Please use JPG or PNG.';

/// Decodes with the browser (createImageBitmap). If the image is larger than
/// [maxDimension] on either side, or bigger than [keepIfUnderBytes], it is
/// redrawn on a canvas (white background) scaled to fit [maxDimension] and
/// encoded as JPEG quality 0.85. Otherwise the original bytes are kept.
/// Throws [ImageFormatException] with a friendly message ("This file is not
/// a picture the browser can read. Please use JPG or PNG.") on failure.
Future<PreparedImage> prepareImage(
  String name,
  Uint8List bytes, {
  int maxDimension = 2400,
  int keepIfUnderBytes = 1500000,
}) async {
  if (bytes.isEmpty) throw ImageFormatException(_unreadableImage);
  final sniffed = _sniffImageMime(bytes);
  final web.ImageBitmap bitmap;
  try {
    bitmap = await web.window
        .createImageBitmap(_blob(bytes, sniffed ?? ''))
        .toDart;
  } catch (_) {
    throw ImageFormatException(_unreadableImage);
  }
  try {
    final w = bitmap.width;
    final h = bitmap.height;
    if (w <= 0 || h <= 0) throw ImageFormatException(_unreadableImage);
    final base = _safeBaseName(name);

    // Keep only formats the server accepts (checked by magic bytes).
    if (sniffed != null &&
        w <= maxDimension &&
        h <= maxDimension &&
        bytes.length <= keepIfUnderBytes) {
      return PreparedImage(
        fileName: '$base.${_extensionFor(sniffed)}',
        bytes: bytes,
        mimeType: sniffed,
        width: w,
        height: h,
      );
    }

    final scale = math.min(1.0, maxDimension / math.max(w, h));
    final tw = math.max(1, (w * scale).round());
    final th = math.max(1, (h * scale).round());
    final canvas = web.document.createElement('canvas') as web.HTMLCanvasElement
      ..width = tw
      ..height = th;
    final ctx = canvas.getContext('2d') as web.CanvasRenderingContext2D?;
    if (ctx == null) throw ImageFormatException(_unreadableImage);
    ctx
      ..fillStyle = '#ffffff'.toJS
      ..fillRect(0, 0, tw, th)
      ..imageSmoothingEnabled = true
      ..imageSmoothingQuality = 'high'
      ..drawImage(bitmap, 0, 0, tw, th);
    final jpeg = await _canvasToJpeg(canvas);
    final out = (await jpeg.arrayBuffer().toDart).toDart.asUint8List();
    canvas
      ..width = 0
      ..height = 0;
    return PreparedImage(
      fileName: '$base.jpg',
      bytes: out,
      mimeType: 'image/jpeg',
      width: tw,
      height: th,
    );
  } on ImageFormatException {
    rethrow;
  } catch (_) {
    throw ImageFormatException(_unreadableImage);
  } finally {
    bitmap.close();
  }
}

Future<web.Blob> _canvasToJpeg(web.HTMLCanvasElement canvas) {
  final completer = Completer<web.Blob>();
  canvas.toBlob(
    ((web.Blob? blob) {
      if (blob == null) {
        completer.completeError(ImageFormatException(_unreadableImage));
      } else {
        completer.complete(blob);
      }
    }).toJS,
    'image/jpeg',
    0.85.toJS,
  );
  return completer.future;
}

String? _sniffImageMime(Uint8List b) {
  bool at(int offset, List<int> signature) {
    if (b.length < offset + signature.length) return false;
    for (var i = 0; i < signature.length; i++) {
      if (b[offset + i] != signature[i]) return false;
    }
    return true;
  }

  if (at(0, const [0xFF, 0xD8, 0xFF])) return 'image/jpeg';
  if (at(0, const [0x89, 0x50, 0x4E, 0x47])) return 'image/png';
  if (at(0, const [0x47, 0x49, 0x46, 0x38])) return 'image/gif';
  if (at(0, const [0x52, 0x49, 0x46, 0x46]) &&
      at(8, const [0x57, 0x45, 0x42, 0x50])) {
    return 'image/webp';
  }
  return null;
}

String _extensionFor(String mime) => switch (mime) {
  'image/jpeg' => 'jpg',
  'image/png' => 'png',
  'image/gif' => 'gif',
  'image/webp' => 'webp',
  _ => 'jpg',
};

/// File name without folder and extension, reduced to `[A-Za-z0-9_-]`.
String _safeBaseName(String name) {
  var base = name.split(RegExp(r'[\\/]')).last;
  final dot = base.lastIndexOf('.');
  if (dot > 0) base = base.substring(0, dot);
  base = base
      .replaceAll(RegExp(r'[^A-Za-z0-9_-]+'), '-')
      .replaceAll(RegExp(r'-{2,}'), '-')
      .replaceAll(RegExp(r'^[-_]+|[-_]+$'), '');
  if (base.length > 60) base = base.substring(0, 60);
  return base.isEmpty ? 'picture' : base;
}

web.Blob _blob(Uint8List bytes, String mimeType) => web.Blob(
  <JSAny>[bytes.toJS].toJS,
  web.BlobPropertyBag(type: mimeType),
);

/// URL.createObjectURL for in-memory bytes (used in the preview iframe).
String createBlobUrl(Uint8List bytes, String mimeType) =>
    web.URL.createObjectURL(_blob(bytes, mimeType));

void revokeBlobUrl(String url) {
  try {
    web.URL.revokeObjectURL(url);
  } catch (_) {}
}

/// Triggers a browser download of [bytes] as [fileName].
void saveBytesAsFile(
  Uint8List bytes,
  String fileName, {
  String mimeType = 'application/octet-stream',
}) {
  final url = createBlobUrl(bytes, mimeType);
  final anchor = web.document.createElement('a') as web.HTMLAnchorElement
    ..href = url
    ..download = fileName
    ..setAttribute('style', 'display:none');
  web.document.body?.appendChild(anchor);
  anchor.click();
  anchor.remove();
  Timer(const Duration(seconds: 30), () => revokeBlobUrl(url));
}

void openInNewTab(String url) {
  web.window.open(url, '_blank');
}

/// Put this into the preview document's <head> (via
/// SiteDocument.renderPreview extraHead). It:
/// - intercepts link clicks: `#id` links scroll inside the preview, all other
///   links do nothing (preview never navigates away);
/// - blocks dragover/drop default (dropping a file on the preview must not
///   open it);
/// - on click of an element with `data-sitor-field` (closest), posts
///   `{sitor:'field', id:<int>}` to window.parent;
/// - defines `window.sitorFocus(id)`: scrollIntoView({block:'center'}) the
///   element with that data-sitor-field and flash an outline for ~1.5 s.
const String previewHeadInjection = r'''
<style>
[data-sitor-field]{cursor:pointer}
[data-sitor-field]:hover{outline:2px dashed rgba(255,152,0,.9);outline-offset:3px}
[data-sitor-field].sitor-flash{outline:3px solid #ff9800 !important;outline-offset:3px}
img[data-sitor-field]:hover,img[data-sitor-field].sitor-flash{outline-offset:-3px !important}
</style>
<script>
(function () {
  var d = document, flashEl = null, flashTimer = 0;
  function post(msg) {
    try { window.parent.postMessage(msg, '*'); } catch (e) {}
  }
  d.addEventListener('click', function (e) {
    var t = e.target;
    if (!t || !t.closest) return;
    var link = t.closest('a[href],area[href]');
    if (link) {
      e.preventDefault();
      var href = link.getAttribute('href') || '';
      if (href.charAt(0) === '#') {
        var id = href.slice(1), el = null;
        try { id = decodeURIComponent(id); } catch (x) {}
        if (id) el = d.getElementById(id) || d.getElementsByName(id)[0];
        if (el) el.scrollIntoView({behavior: 'smooth', block: 'start'});
        else if (!id || id === 'top') window.scrollTo({top: 0, behavior: 'smooth'});
      }
    }
    var field = t.closest('[data-sitor-field]');
    if (field) {
      var n = parseInt(field.getAttribute('data-sitor-field'), 10);
      if (!isNaN(n)) post({sitor: 'field', id: n});
    }
  }, true);
  d.addEventListener('submit', function (e) { e.preventDefault(); }, true);
  function block(e) { e.preventDefault(); }
  window.addEventListener('dragover', block);
  window.addEventListener('drop', block);
  window.sitorFocus = function (id) {
    var n = parseInt(id, 10);
    if (isNaN(n)) return false;
    var el = d.querySelector('[data-sitor-field="' + n + '"]');
    if (!el) return false;
    try { el.scrollIntoView({behavior: 'smooth', block: 'center'}); }
    catch (x) { el.scrollIntoView(); }
    if (flashEl) flashEl.classList.remove('sitor-flash');
    clearTimeout(flashTimer);
    flashEl = el;
    el.classList.add('sitor-flash');
    flashTimer = setTimeout(function () {
      el.classList.remove('sitor-flash');
      flashEl = null;
    }, 1500);
    return true;
  };
  d.addEventListener('DOMContentLoaded', function () { post({sitor: 'ready'}); });
})();
</script>
''';

class PreviewController {
  _PreviewFrameState? _frame;

  /// Scrolls the preview to the field's element and flashes it.
  void scrollToField(int fieldId) => _frame?._focusField(fieldId);
}

/// An <iframe> showing [html] via `srcdoc`. When [html] changes the frame
/// reloads and restores its previous scroll position. Messages
/// `{sitor:'field', id}` from the frame call [onFieldClicked].
class PreviewFrame extends StatefulWidget {
  const PreviewFrame({
    super.key,
    required this.html,
    this.controller,
    this.onFieldClicked,
  });

  final String html;
  final PreviewController? controller;
  final void Function(int fieldId)? onFieldClicked;

  @override
  State<PreviewFrame> createState() => _PreviewFrameState();
}

class _PreviewFrameState extends State<PreviewFrame> {
  static int _nextViewId = 0;

  final String _viewType = 'sitor-preview-${_nextViewId++}';
  web.HTMLIFrameElement? _iframe;
  JSFunction? _onLoad;
  late final JSFunction _onMessage = _handleMessage.toJS;
  String? _shownHtml;

  /// Document not parsed yet (no 'ready' message or load event so far).
  bool _loading = false;

  /// Scroll position to restore in the next document, if [_restore].
  bool _restore = false;
  double _targetX = 0;
  double _targetY = 0;
  (double, double)? _afterReady;
  int? _pendingFocus;

  @override
  void initState() {
    super.initState();
    widget.controller?._frame = this;
    ui_web.platformViewRegistry.registerViewFactory(
      _viewType,
      (int viewId) => _createFrame(),
    );
    web.window.addEventListener('message', _onMessage);
  }

  @override
  void didUpdateWidget(PreviewFrame oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      if (oldWidget.controller?._frame == this) {
        oldWidget.controller?._frame = null;
      }
      widget.controller?._frame = this;
    }
    _show(widget.html);
  }

  @override
  void dispose() {
    if (widget.controller?._frame == this) widget.controller?._frame = null;
    web.window.removeEventListener('message', _onMessage);
    _iframe?.removeEventListener('load', _onLoad);
    _iframe = null;
    super.dispose();
  }

  web.HTMLIFrameElement _createFrame() {
    _iframe?.removeEventListener('load', _onLoad);
    final frame = web.document.createElement('iframe') as web.HTMLIFrameElement
      ..title = 'Website preview'
      ..setAttribute(
        'style',
        'width:100%;height:100%;border:none;display:block;background:#fff',
      );
    _onLoad = _handleLoad.toJS;
    frame.addEventListener('load', _onLoad);
    _iframe = frame;
    _shownHtml = null;
    _show(widget.html);
    return frame;
  }

  void _show(String html) {
    final frame = _iframe;
    if (frame == null || html == _shownHtml) return;
    // While a document is still loading its scroll position is meaningless;
    // keep the target captured before.
    if (_shownHtml != null && !_loading) {
      final pos = _scrollOf(frame);
      if (pos != null) {
        _targetX = pos.$1;
        _targetY = pos.$2;
        _restore = true;
      }
    }
    _shownHtml = html;
    _loading = true;
    _afterReady = null;
    frame.srcdoc = html.toJS;
  }

  (double, double)? _scrollOf(web.HTMLIFrameElement frame) {
    try {
      final win = frame.contentWindow;
      return win == null ? null : (win.scrollX, win.scrollY);
    } catch (_) {
      return null;
    }
  }

  void _scrollTo(double x, double y) {
    try {
      _iframe?.contentWindow?.scrollTo(
        web.ScrollToOptions(left: x, top: y, behavior: 'instant'),
      );
    } catch (_) {}
  }

  void _handleMessage(web.Event event) {
    final win = _iframe?.contentWindow;
    final message = event as web.MessageEvent;
    final source = message.source;
    if (win == null || source == null || !source.strictEquals(win).toDart) {
      return;
    }
    final Object? data;
    try {
      data = message.data.dartify();
    } catch (_) {
      return;
    }
    if (data is! Map) return;
    switch (data['sitor']) {
      case 'field':
        final id = data['id'];
        if (id is num && id.isFinite && mounted) {
          widget.onFieldClicked?.call(id.toInt());
        }
      case 'ready':
        _handleReady();
    }
  }

  /// DOMContentLoaded in the frame: restore early to avoid a jump from the
  /// top; the load event corrects it once images have their size.
  void _handleReady() {
    _loading = false;
    if (_applyPendingFocus()) return;
    final frame = _iframe;
    if (_restore && frame != null) {
      _scrollTo(_targetX, _targetY);
      _afterReady = _scrollOf(frame);
    }
  }

  void _handleLoad(web.Event _) {
    _loading = false;
    if (_applyPendingFocus()) return;
    final frame = _iframe;
    if (_restore && frame != null) {
      // Skip if the user has scrolled since the early restore.
      if (_afterReady == null || _scrollOf(frame) == _afterReady) {
        _scrollTo(_targetX, _targetY);
      }
      _restore = false;
    }
  }

  bool _applyPendingFocus() {
    final id = _pendingFocus;
    if (id == null) return false;
    _pendingFocus = null;
    _restore = false;
    _callFocus(id);
    return true;
  }

  void _focusField(int id) {
    if (_iframe == null || _loading) {
      _pendingFocus = id;
    } else {
      _callFocus(id);
    }
  }

  void _callFocus(int id) {
    try {
      _iframe?.contentWindow?.callMethod<JSAny?>('sitorFocus'.toJS, id.toJS);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) => HtmlElementView(viewType: _viewType);
}
