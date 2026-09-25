// 2026-09-25
// Editing state: live edits (text controllers, replaced pictures) plus the
// "applied" snapshot that the preview shows.
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../api/sitor_api.dart';
import '../site/site_document.dart';
import '../web/browser.dart';

class ReplacedImage {
  const ReplacedImage(this.image, this.blobUrl);
  final PreparedImage image;
  final String blobUrl;
}

class EditorController extends ChangeNotifier {
  EditorController._(this.api);

  /// Loads the live page; throws [ApiException] on failure.
  static Future<EditorController> open(SitorApi api) async {
    final c = EditorController._(api);
    try {
      await c.reload();
    } catch (_) {
      c.dispose();
      rethrow;
    }
    return c;
  }

  final SitorApi api;

  late LoadedPage _page;
  late SiteDocument _doc;
  final Map<int, TextEditingController> _texts = {};
  final Map<int, ReplacedImage> _images = {};
  Map<int, String> _appliedTexts = const {};
  Map<int, String> _appliedImages = const {};

  /// Blob urls no longer edited but maybe still shown in the preview.
  final Set<String> _retiredBlobs = {};
  String _previewHtml = '';
  bool _leaveWarning = false;
  bool _disposed = false;

  LoadedPage get page => _page;
  SiteDocument get doc => _doc;
  String get previewHtml => _previewHtml;

  TextEditingController textFor(int id) => _texts[id]!;
  ReplacedImage? imageFor(int id) => _images[id];

  /// fieldId -> edited text, only for fields that differ from the original.
  Map<int, String> get currentTexts => {
    for (final e in _texts.entries)
      if (e.value.text != _doc.fields[e.key].original) e.key: e.value.text,
  };

  Map<int, String> get _currentImageUrls => {
    for (final e in _images.entries) e.key: e.value.blobUrl,
  };

  List<int> get changedTextIds => currentTexts.keys.toList()..sort();
  List<int> get changedImageIds => _images.keys.toList()..sort();
  int get changeCount => currentTexts.length + _images.length;
  bool get hasChanges => changeCount > 0;

  /// True when the preview does not show the latest edits yet.
  bool get hasUnappliedChanges =>
      !mapEquals(currentTexts, _appliedTexts) ||
      !mapEquals(_currentImageUrls, _appliedImages);

  /// Fetches the live page and throws away all edits.
  Future<void> reload() async {
    final page = await api.load();
    final doc = SiteDocument.parse(page.html);
    if (_disposed) return;
    _page = page;
    _doc = doc;

    final old = _texts.values.toList();
    for (final c in old) {
      c.removeListener(_changed);
    }
    _texts.clear();
    for (final f in doc.fields) {
      if (f.kind == FieldKind.text) {
        _texts[f.id] = TextEditingController(text: f.original)
          ..addListener(_changed);
      }
    }
    // Text fields may still hold the old controllers until the next frame.
    if (old.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        for (final c in old) {
          c.dispose();
        }
      });
    }

    _dropAllImages();
    _appliedTexts = const {};
    _appliedImages = const {};
    _renderPreview();
    _changed();
  }

  /// Shows the current edits in the preview.
  void apply() {
    _appliedTexts = currentTexts;
    _appliedImages = _currentImageUrls;
    _renderPreview();
    for (final url in _retiredBlobs.toList()) {
      if (!_appliedImages.containsValue(url)) {
        revokeBlobUrl(url);
        _retiredBlobs.remove(url);
      }
    }
    notifyListeners();
  }

  void undoText(int id) {
    final c = _texts[id];
    if (c != null) c.text = _doc.fields[id].original;
  }

  void replaceImage(int id, PreparedImage image) {
    if (_disposed) return;
    final url = createBlobUrl(image.bytes, image.mimeType);
    final old = _images[id];
    _images[id] = ReplacedImage(image, url);
    if (old != null) _retire(old.blobUrl);
    _changed();
  }

  void undoImage(int id) {
    final old = _images.remove(id);
    if (old == null) return;
    _retire(old.blobUrl);
    _changed();
  }

  void _retire(String url) {
    if (_appliedImages.containsValue(url)) {
      _retiredBlobs.add(url);
    } else {
      revokeBlobUrl(url);
    }
  }

  void _dropAllImages() {
    for (final r in _images.values) {
      revokeBlobUrl(r.blobUrl);
    }
    for (final url in _retiredBlobs) {
      revokeBlobUrl(url);
    }
    _images.clear();
    _retiredBlobs.clear();
  }

  void _renderPreview() {
    _previewHtml = _doc.renderPreview(
      texts: _appliedTexts,
      images: _appliedImages,
      baseHref: _page.siteBase.toString(),
      extraHead: previewHeadInjection,
    );
  }

  void _changed() {
    if (_disposed) return;
    final has = hasChanges;
    if (has != _leaveWarning) {
      _leaveWarning = has;
      setLeaveWarning(has);
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    for (final c in _texts.values) {
      c.removeListener(_changed);
      c.dispose();
    }
    _texts.clear();
    _dropAllImages();
    if (_leaveWarning) setLeaveWarning(false);
    super.dispose();
  }
}
