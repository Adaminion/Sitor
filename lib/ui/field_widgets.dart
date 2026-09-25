// 2026-09-25
// Editors for one text or picture on the page.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../site/site_document.dart';
import '../web/browser.dart';
import '../web/drop_zone.dart';
import 'common.dart';
import 'editor_controller.dart';

const _singleLineTags = {'title', 'a', 'option', 'button'};

TextStyle _styleFor(int level) => switch (level) {
  1 => const TextStyle(fontSize: 24, fontWeight: FontWeight.w700, height: 1.2),
  2 => const TextStyle(fontSize: 19, fontWeight: FontWeight.w700, height: 1.25),
  4 => const TextStyle(fontSize: 13),
  _ => const TextStyle(fontSize: 15, height: 1.4),
};

class _FieldHeader extends StatelessWidget {
  const _FieldHeader({required this.label, required this.changed, this.onUndo});

  final String label;
  final bool changed;
  final VoidCallback? onUndo;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      height: 30,
      child: Row(
        children: [
          Flexible(
            child: Text(
              label,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          if (changed) ...[
            const SizedBox(width: 6),
            const Text(
              'changed',
              style: TextStyle(
                fontSize: 11,
                color: copper,
                fontWeight: FontWeight.w600,
              ),
            ),
            const Spacer(),
            IconButton(
              tooltip: 'Undo my change',
              onPressed: onUndo,
              icon: const Icon(Icons.undo, size: 18),
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints.tightFor(width: 30, height: 30),
            ),
          ],
        ],
      ),
    );
  }
}

/// Soft copper glow while the field is being pointed at from the preview.
class _Highlight extends StatelessWidget {
  const _Highlight({required this.on, required this.child});

  final bool on;
  final Widget child;

  @override
  Widget build(BuildContext context) => AnimatedContainer(
    duration: const Duration(milliseconds: 250),
    padding: const EdgeInsets.all(4),
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(8),
      color: on ? copper.withValues(alpha: 0.12) : Colors.transparent,
    ),
    child: child,
  );
}

class TextFieldEditor extends StatelessWidget {
  const TextFieldEditor({
    super.key,
    required this.field,
    required this.controller,
    required this.editor,
    required this.focusNode,
    this.highlighted = false,
  });

  final SiteField field;
  final TextEditingController controller;
  final EditorController editor;
  final FocusNode focusNode;
  final bool highlighted;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final singleLine =
        _singleLineTags.contains(field.tag) && !field.original.contains('\n');
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: controller,
      builder: (context, value, _) {
        final changed = value.text != field.original;
        return _Highlight(
          on: highlighted,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _FieldHeader(
                label: field.label,
                changed: changed,
                onUndo: () => editor.undoText(field.id),
              ),
              TextField(
                controller: controller,
                focusNode: focusNode,
                style: _styleFor(field.level),
                minLines: 1,
                maxLines: singleLine ? 1 : null,
                inputFormatters: singleLine
                    ? [
                        FilteringTextInputFormatter.deny(
                          RegExp(r'[\r\n]+'),
                          replacementString: ' ',
                        ),
                      ]
                    : null,
                decoration: InputDecoration(
                  isDense: true,
                  filled: true,
                  fillColor: changed
                      ? const Color(0xFFFFF6EC)
                      : scheme.surfaceContainerLowest,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 12,
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderSide: changed
                        ? const BorderSide(color: copper, width: 2)
                        : BorderSide(color: scheme.outlineVariant),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderSide: BorderSide(color: scheme.primary, width: 2),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class ImageFieldEditor extends StatefulWidget {
  const ImageFieldEditor({
    super.key,
    required this.field,
    required this.editor,
    required this.dropEnabled,
    this.highlighted = false,
    this.onTap,
  });

  final SiteField field;
  final EditorController editor;

  /// Must be false while another screen covers the editor.
  final bool dropEnabled;
  final bool highlighted;
  final VoidCallback? onTap;

  @override
  State<ImageFieldEditor> createState() => _ImageFieldEditorState();
}

class _ImageFieldEditorState extends State<ImageFieldEditor> {
  bool _dragOver = false;
  bool _busy = false;

  void _setDragOver(bool v) {
    if (_dragOver != v && mounted) setState(() => _dragOver = v);
  }

  Future<void> _useFile(String name, Future<Uint8List> Function() read) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final bytes = await read();
      final prepared = await prepareImage(name, bytes);
      if (!mounted) return;
      widget.editor.replaceImage(widget.field.id, prepared);
    } on ImageFormatException catch (e) {
      showMessage(e.message);
    } catch (_) {
      showMessage(
        'Sorry, that picture could not be used. Please try a JPG or PNG file.',
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _onDrop(PickedFile file) {
    _setDragOver(false);
    if (!widget.dropEnabled) return;
    _useFile(file.name, () async => file.bytes);
  }

  Future<void> _pick() async {
    final PickedFile? file;
    try {
      file = await pickImageFile();
    } catch (e) {
      showMessage(errorText(e));
      return;
    }
    if (file == null) return;
    await _useFile(file.name, () async => file!.bytes);
  }

  @override
  Widget build(BuildContext context) {
    final field = widget.field;
    final editor = widget.editor;
    final replaced = editor.imageFor(field.id);
    final scheme = Theme.of(context).colorScheme;

    final Widget picture = replaced != null
        ? Image.memory(
            replaced.image.bytes,
            fit: BoxFit.cover,
            gaplessPlayback: true,
            errorBuilder: (_, _, _) => _brokenPicture(scheme),
          )
        : Image.network(
            editor.page.siteBase.resolve(field.original).toString(),
            fit: BoxFit.cover,
            errorBuilder: (_, _, _) => _brokenPicture(scheme),
          );

    return FileDropZone(
      onHover: (v) => _setDragOver(v && widget.dropEnabled),
      onFile: _onDrop,
      child: _Highlight(
        on: widget.highlighted,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _FieldHeader(
              label: field.label,
              changed: replaced != null,
              onUndo: () => editor.undoImage(field.id),
            ),
            GestureDetector(
              onTap: widget.onTap,
              child: MouseRegion(
                cursor: SystemMouseCursors.click,
                child: Container(
                  height: 120,
                  clipBehavior: Clip.antiAlias,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                      color: replaced != null ? copper : scheme.outlineVariant,
                      width: replaced != null ? 3 : 1,
                    ),
                  ),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      picture,
                      if (_dragOver)
                        ColoredBox(
                          color: copper.withValues(alpha: 0.85),
                          child: const Center(
                            child: Text(
                              'Drop to replace',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 17,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ),
                      if (_busy)
                        const ColoredBox(
                          color: Color(0x99FFFFFF),
                          child: Center(child: CircularProgressIndicator()),
                        ),
                    ],
                  ),
                ),
              ),
            ),
            if ((field.alt ?? '').isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  field.alt!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
            const SizedBox(height: 6),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                onPressed: _busy ? null : _pick,
                icon: const Icon(Icons.photo_library_outlined, size: 18),
                label: const Text('Replace picture…'),
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size(0, 38),
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  textStyle: const TextStyle(fontSize: 14),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _brokenPicture(ColorScheme scheme) => ColoredBox(
    color: scheme.surfaceContainerHighest,
    child: Icon(Icons.image_outlined, color: scheme.outline, size: 36),
  );
}
