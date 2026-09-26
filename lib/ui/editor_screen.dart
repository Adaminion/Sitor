// 2026-09-26
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../site/site_document.dart';
import '../web/browser.dart';
import 'common.dart';
import 'editor_controller.dart';
import 'field_widgets.dart';
import 'publish_screen.dart';

/// Keep in step with `version:` in pubspec.yaml.
const _version = '1.0.0';

/// Rows are shown side by side only if every cell gets at least this width.
const _minCellWidth = 140.0;

class EditorScreen extends StatefulWidget {
  const EditorScreen({super.key, required this.controller});

  /// Owned (and disposed) by this screen.
  final EditorController controller;

  @override
  State<EditorScreen> createState() => _EditorScreenState();
}

class _EditorScreenState extends State<EditorScreen> {
  final _preview = PreviewController();
  final _scroll = ScrollController();
  final Map<int, GlobalKey> _keys = {};
  final Map<int, FocusNode> _focus = {};
  final Set<int> _keysUsed = {};
  bool _phone = false;
  bool _dropEnabled = true;
  int? _flashId;
  Timer? _flashTimer;

  /// Field focused because it was clicked in the preview (no echo back).
  int? _focusFromPreview;

  EditorController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    // Multiline text fields on web swallow Ctrl+Enter before Shortcuts see it.
    HardwareKeyboard.instance.addHandler(_onKey);
  }

  bool _onKey(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    final enter =
        event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.numpadEnter;
    final keyboard = HardwareKeyboard.instance;
    if (!enter || !(keyboard.isControlPressed || keyboard.isMetaPressed)) {
      return false;
    }
    if (!(ModalRoute.of(context)?.isCurrent ?? false)) return false;
    _apply();
    return true;
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    _flashTimer?.cancel();
    for (final n in _focus.values) {
      n.dispose();
    }
    _scroll.dispose();
    c.dispose();
    super.dispose();
  }

  FocusNode _focusFor(int id) => _focus.putIfAbsent(id, () {
    final node = FocusNode(debugLabel: 'field $id');
    node.addListener(() {
      if (!node.hasFocus) return;
      if (_focusFromPreview == id) {
        _focusFromPreview = null;
        return;
      }
      _showInPreview(id);
    });
    return node;
  });

  void _showInPreview(int id) {
    try {
      _preview.scrollToField(id);
    } catch (_) {
      // Preview not ready yet; nothing to point at.
    }
  }

  void _onPreviewClicked(int id) {
    if (id < 0 || id >= c.doc.fields.length) return;
    final ctx = _keys[id]?.currentContext;
    if (ctx == null) return;
    Scrollable.ensureVisible(
      ctx,
      alignment: 0.25,
      duration: const Duration(milliseconds: 350),
      curve: Curves.easeOut,
    );
    _flashTimer?.cancel();
    setState(() => _flashId = id);
    _flashTimer = Timer(const Duration(milliseconds: 1600), () {
      if (mounted) setState(() => _flashId = null);
    });
    if (c.doc.fields[id].kind == FieldKind.text) {
      final node = _focusFor(id);
      if (!node.hasFocus) {
        _focusFromPreview = id;
        node.requestFocus();
      }
    }
  }

  void _apply() {
    if (!c.hasUnappliedChanges) {
      showMessage('The preview already shows all your changes.');
    }
    c.apply();
  }

  Future<void> _openPublish() async {
    FocusScope.of(context).unfocus();
    setState(() => _dropEnabled = false);
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => PublishScreen(controller: c)),
    );
    if (mounted) setState(() => _dropEnabled = true);
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      autofocus: true,
      child: ListenableBuilder(
        listenable: c,
        builder: (context, _) => Scaffold(
          appBar: _appBar(context),
          body: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(flex: 5, child: _fieldsPane(context)),
              const VerticalDivider(width: 1, thickness: 1),
              Expanded(flex: 6, child: _previewPane(context)),
            ],
          ),
          bottomNavigationBar: _footer(context),
        ),
      ),
    );
  }

  Widget _footer(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return Container(
      height: 36,
      padding: const EdgeInsets.symmetric(horizontal: 20),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: Border(
          top: BorderSide(color: theme.colorScheme.outlineVariant),
        ),
      ),
      child: Row(
        children: [
          Text('Sitor $_version', style: muted),
          const Spacer(),
          TextButton(
            onPressed: () => openInNewTab('mailto:support@adaminion.com'),
            child: const Text('support@adaminion.com'),
          ),
          TextButton(
            onPressed: () => openInNewTab('https://adaminion.com'),
            child: const Text('adaminion.com'),
          ),
        ],
      ),
    );
  }

  PreferredSizeWidget _appBar(BuildContext context) {
    final theme = Theme.of(context);
    final wide = MediaQuery.sizeOf(context).width >= 1000;
    final count = c.changeCount;
    return AppBar(
      toolbarHeight: 76,
      titleSpacing: 20,
      backgroundColor: theme.colorScheme.surface,
      surfaceTintColor: Colors.transparent,
      shape: Border(
        bottom: BorderSide(color: theme.colorScheme.outlineVariant),
      ),
      title: Row(
        children: [
          const Icon(Icons.edit_note, color: copper, size: 34),
          const SizedBox(width: 10),
          Flexible(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'SITOR - the awesomest webSIte ediTOR !!!',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
                Text(
                  'Page: ${c.page.page}',
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
      actions: [
        if (wide)
          Text(
            count == 0
                ? 'No changes yet'
                : '$count unsaved change${count == 1 ? '' : 's'}',
            style: TextStyle(
              fontSize: 15,
              color: count == 0 ? theme.colorScheme.onSurfaceVariant : copper,
              fontWeight: count == 0 ? FontWeight.w400 : FontWeight.w600,
            ),
          ),
        const SizedBox(width: 16),
        Tooltip(
          message: 'Show my changes in the preview (Ctrl+Enter)',
          child: FilledButton.icon(
            onPressed: _apply,
            icon: const Icon(Icons.visibility, size: 24),
            label: const Text('APPLY'),
            style: FilledButton.styleFrom(
              backgroundColor: copper,
              foregroundColor: Colors.white,
              minimumSize: const Size(170, 56),
              textStyle: const TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w800,
                letterSpacing: 1.5,
              ),
            ),
          ),
        ),
        const SizedBox(width: 12),
        FilledButton.tonalIcon(
          onPressed: _openPublish,
          icon: const Icon(Icons.cloud_upload_outlined),
          label: Text(wide ? 'Upload & backups…' : 'Upload/backups…'),
          style: FilledButton.styleFrom(minimumSize: const Size(0, 56)),
        ),
        const SizedBox(width: 20),
      ],
    );
  }

  // ---- left pane -----------------------------------------------------------

  Widget _fieldsPane(BuildContext context) {
    final theme = Theme.of(context);
    _keysUsed.clear();
    return ColoredBox(
      color: theme.colorScheme.surfaceContainerLow,
      child: Scrollbar(
        controller: _scroll,
        thumbVisibility: true,
        child: SingleChildScrollView(
          controller: _scroll,
          padding: const EdgeInsets.fromLTRB(16, 16, 20, 48),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 0, 4, 12),
                child: Text(
                  'Click any text below and change it. To change a picture, '
                  'drag a photo from your computer onto it. Press APPLY to '
                  'see your changes on the right.',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              for (final section in c.doc.layout) _section(context, section),
            ],
          ),
        ),
      ),
    );
  }

  Widget _section(BuildContext context, LayoutBlock section) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      elevation: 0,
      color: theme.colorScheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: theme.colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              section.title.toUpperCase(),
              style: const TextStyle(
                fontSize: 12,
                letterSpacing: 1.6,
                fontWeight: FontWeight.w700,
                color: copper,
              ),
            ),
            const SizedBox(height: 8),
            _vertical(context, section.children),
          ],
        ),
      ),
    );
  }

  Widget _block(BuildContext context, LayoutBlock b) => switch (b.type) {
    BlockType.field => _field(b.fieldId),
    BlockType.row => _row(context, b.children),
    BlockType.column || BlockType.section => _vertical(context, b.children),
  };

  Widget _vertical(BuildContext context, List<LayoutBlock> children) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      for (var i = 0; i < children.length; i++) ...[
        if (i > 0) const SizedBox(height: 10),
        _block(context, children[i]),
      ],
    ],
  );

  /// Side-by-side cells, like a table; wraps into fewer per line if narrow.
  Widget _row(BuildContext context, List<LayoutBlock> cells) {
    final border = Theme.of(context).colorScheme.outlineVariant;
    // Build the cells once, outside LayoutBuilder, so field keys stay unique.
    final built = [
      for (final cell in cells)
        DecoratedBox(
          decoration: BoxDecoration(
            border: Border.all(color: border),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: _block(context, cell),
          ),
        ),
    ];
    return LayoutBuilder(
      builder: (context, box) {
        final n = built.length;
        var perLine = n;
        if (n * _minCellWidth > box.maxWidth) {
          perLine = box.maxWidth >= 2 * _minCellWidth ? 2 : 1;
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var i = 0; i < n; i += perLine) ...[
              if (i > 0) const SizedBox(height: 8),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (var j = 0; j < perLine; j++) ...[
                    if (j > 0) const SizedBox(width: 8),
                    Expanded(
                      child: i + j < n ? built[i + j] : const SizedBox(),
                    ),
                  ],
                ],
              ),
            ],
          ],
        );
      },
    );
  }

  Widget _field(int id) {
    final fields = c.doc.fields;
    if (id < 0 || id >= fields.length) return const SizedBox();
    final f = fields[id];
    final Widget editor = f.kind == FieldKind.text
        ? TextFieldEditor(
            field: f,
            controller: c.textFor(id),
            editor: c,
            focusNode: _focusFor(id),
            highlighted: _flashId == id,
          )
        : ImageFieldEditor(
            field: f,
            editor: c,
            dropEnabled: _dropEnabled,
            highlighted: _flashId == id,
            onTap: () => _showInPreview(id),
          );
    // A GlobalKey may appear only once; guard against a repeated field.
    if (!_keysUsed.add(id)) return editor;
    return KeyedSubtree(
      key: _keys.putIfAbsent(id, GlobalKey.new),
      child: editor,
    );
  }

  // ---- right pane ----------------------------------------------------------

  Widget _previewPane(BuildContext context) {
    final theme = Theme.of(context);
    final stale = c.hasUnappliedChanges;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Material(
          color: theme.colorScheme.surface,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                const Icon(Icons.web, size: 20),
                const SizedBox(width: 8),
                const Text(
                  'Preview',
                  style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
                ),
                const SizedBox(width: 12),
                if (stale)
                  Flexible(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xFFFFE9CC),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: const Text(
                        'Press APPLY to see your latest changes',
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          color: Color(0xFF7A3E12),
                        ),
                      ),
                    ),
                  ),
                const Spacer(),
                SegmentedButton<bool>(
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment(
                      value: false,
                      icon: Icon(Icons.computer),
                      label: Text('Computer'),
                    ),
                    ButtonSegment(
                      value: true,
                      icon: Icon(Icons.smartphone),
                      label: Text('Phone'),
                    ),
                  ],
                  selected: {_phone},
                  onSelectionChanged: (s) => setState(() => _phone = s.first),
                ),
              ],
            ),
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: ColoredBox(
            color: const Color(0xFFE6E0D6),
            // Same widget structure in both modes so the frame is kept.
            child: Padding(
              padding: _phone
                  ? const EdgeInsets.symmetric(vertical: 16)
                  : EdgeInsets.zero,
              child: Align(
                alignment: Alignment.topCenter,
                child: SizedBox(
                  width: _phone ? 390 : double.infinity,
                  height: double.infinity,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      border: Border.all(
                        color: _phone ? Colors.black54 : Colors.transparent,
                      ),
                    ),
                    child: PreviewFrame(
                      html: c.previewHtml,
                      controller: _preview,
                      onFieldClicked: _onPreviewClicked,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
