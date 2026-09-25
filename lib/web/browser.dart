// 2026-09-25
// All browser interop (package:web, dart:ui_web) lives here. Web-only.
import 'dart:typed_data';

import 'package:flutter/widgets.dart';

/// Base URL of the running app (document.baseURI), e.g.
/// https://example.com/sitor/ — resolve `api.php` against it.
Uri get appBaseUri => throw UnimplementedError();

/// Call once at startup: stop the browser from navigating to a file that is
/// dropped anywhere outside a drop target (which would lose all edits).
void preventWindowFileDrops() => throw UnimplementedError();

/// While [enabled], closing/reloading the tab asks "Leave site?".
void setLeaveWarning(bool enabled) => throw UnimplementedError();

/// Small key/value store (localStorage), failures swallowed (returns null).
String? loadSetting(String key) => throw UnimplementedError();
void saveSetting(String key, String? value) => throw UnimplementedError();

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
Future<PickedFile?> pickImageFile() => throw UnimplementedError();

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
}) => throw UnimplementedError();

/// URL.createObjectURL for in-memory bytes (used in the preview iframe).
String createBlobUrl(Uint8List bytes, String mimeType) =>
    throw UnimplementedError();
void revokeBlobUrl(String url) => throw UnimplementedError();

/// Triggers a browser download of [bytes] as [fileName].
void saveBytesAsFile(
  Uint8List bytes,
  String fileName, {
  String mimeType = 'application/octet-stream',
}) => throw UnimplementedError();

void openInNewTab(String url) => throw UnimplementedError();

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
const String previewHeadInjection = '';

class PreviewController {
  /// Scrolls the preview to the field's element and flashes it.
  void scrollToField(int fieldId) => throw UnimplementedError();
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
  State<PreviewFrame> createState() => throw UnimplementedError();
}
