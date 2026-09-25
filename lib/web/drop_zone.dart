// 2026-09-25
// Drop zones for files dragged in from the OS. Replaces desktop_drop, whose
// web plugin crashes on drags that aren't plain files (e.g. an image dragged
// from another browser tab) and can't be exercised by synthetic events.
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:web/web.dart' as web;

import 'browser.dart';

/// Calls [onFile] with the first file dropped onto [child], and [onHover]
/// while a file drag is over it.
class FileDropZone extends StatefulWidget {
  const FileDropZone({
    super.key,
    required this.child,
    required this.onFile,
    this.onHover,
  });

  final Widget child;
  final void Function(PickedFile file) onFile;
  final void Function(bool hovering)? onHover;

  @override
  State<FileDropZone> createState() => _FileDropZoneState();
}

class _FileDropZoneState extends State<FileDropZone> {
  static final _zones = <_FileDropZoneState>[];
  static _FileDropZoneState? _hovered;
  static bool _listening = false;

  @override
  void initState() {
    super.initState();
    _zones.add(this);
    _listen();
  }

  @override
  void dispose() {
    _zones.remove(this);
    if (_hovered == this) _hovered = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;

  bool _contains(Offset point) {
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) return false;
    if (!(box.localToGlobal(Offset.zero) & box.size).contains(point)) {
      return false;
    }
    // A zone scrolled out of its list's viewport is not under the pointer.
    final viewport = context
        .findAncestorStateOfType<ScrollableState>()
        ?.context
        .findRenderObject();
    return viewport is! RenderBox ||
        !viewport.hasSize ||
        (viewport.localToGlobal(Offset.zero) & viewport.size).contains(point);
  }

  static _FileDropZoneState? _zoneAt(web.DragEvent e) {
    final point = Offset(e.clientX.toDouble(), e.clientY.toDouble());
    for (final zone in _zones.reversed) {
      if (zone.mounted && zone._contains(point)) return zone;
    }
    return null;
  }

  static void _setHovered(_FileDropZoneState? zone) {
    if (_hovered == zone) return;
    final previous = _hovered;
    _hovered = zone;
    if (previous != null && previous.mounted) {
      previous.widget.onHover?.call(false);
    }
    zone?.widget.onHover?.call(true);
  }

  static bool _hasFiles(web.DragEvent e) {
    final types = e.dataTransfer?.types.toDart ?? const <JSString>[];
    return types.any((t) => t.toDart == 'Files');
  }

  static void _listen() {
    if (_listening) return;
    _listening = true;
    web.window.addEventListener(
      'dragover',
      ((web.DragEvent e) {
        e.preventDefault();
        if (!_hasFiles(e)) return;
        final zone = _zoneAt(e);
        e.dataTransfer?.dropEffect = zone == null ? 'none' : 'copy';
        _setHovered(zone);
      }).toJS,
    );
    web.window.addEventListener(
      'dragleave',
      ((web.DragEvent e) {
        // Null when the pointer leaves the window; the preview iframe
        // swallows further dragover events, so clear on entering it too.
        final to = e.relatedTarget;
        if (to == null || to.isA<web.HTMLIFrameElement>()) _setHovered(null);
      }).toJS,
    );
    web.window.addEventListener(
      'drop',
      ((web.DragEvent e) {
        e.preventDefault();
        final zone = _zoneAt(e);
        _setHovered(null);
        final files = e.dataTransfer?.files;
        if (zone == null || files == null || files.length == 0) return;
        final file = files.item(0)!;
        file.arrayBuffer().toDart.then((buffer) {
          if (!zone.mounted) return;
          zone.widget.onFile(
            PickedFile(
              name: file.name,
              bytes: Uint8List.view(buffer.toDart),
              mimeType: file.type,
            ),
          );
        });
      }).toJS,
    );
  }
}
