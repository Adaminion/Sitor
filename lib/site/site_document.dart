// 2026-09-25
// HTML page model: finds editable texts/pictures and writes edits back
// surgically (every byte outside an edited range is preserved).
// Pure Dart (package:html with generateSpans) — must run on the VM for tests.
import 'package:html/dom.dart';
import 'package:html/parser.dart';

enum FieldKind { text, image }

/// One editable thing on the page.
class SiteField {
  const SiteField({
    required this.id,
    required this.kind,
    required this.label,
    required this.tag,
    required this.original,
    required this.level,
    this.alt,
  });

  /// Index in document order, 0..fields.length-1. `fields[id].id == id`.
  final int id;
  final FieldKind kind;

  /// Friendly label for a non-technical user: "Browser tab title",
  /// "Big headline" (h1), "Headline" (h2..h6 / .display), "Paragraph" (p),
  /// "Link text" (a), "Menu item" (a inside nav li), "Small text" (small,
  /// .label), "Caption" (figure span/figcaption), "Text" (anything else),
  /// "Picture" (img).
  final String label;

  /// Lower-case tag name, e.g. `h1`, `p`, `img`, `title`.
  final String tag;

  /// text: decoded plain text; whitespace runs ([ \t\r\n\f]) collapsed to one
  /// space and trimmed per line; each `<br>` becomes '\n'.
  /// image: the original `src` attribute value, verbatim (e.g. `hero.jpg`).
  final String original;

  /// Visual weight hint for the editor: 1 = huge (h1), 2 = headline
  /// (h2..h6 or class contains `display`), 3 = normal, 4 = small (small,
  /// .label, nav, footer, title). Images: 3.
  final int level;

  /// Image only: `alt` attribute (display only).
  final String? alt;
}

enum BlockType { section, row, column, field }

/// Layout tree mirroring the page's visual structure for the left pane.
///
/// - `section`: a top-level block of <body> (nav/header/section/footer/...),
///   plus a first pseudo-section "Page" holding the <title> field if present.
///   Children are laid out vertically: `field` and `row` blocks only.
/// - `row`: siblings that sit side by side on the page. Children are
///   `column` blocks only (>= 2).
/// - `column`: one cell of a row. Children: `field` and `row` blocks, vertical.
/// - `field`: leaf pointing at [fieldId].
///
/// Row rule: an element with >= 2 element children that contain fields (or
/// are fields), all of the same tag name (e.g. figure x3, li x4, a.svc x4,
/// footer span x2) becomes a row, one column per such child. Vertical
/// containers nested in vertical containers are flattened (no empty or
/// single-purpose nesting). Sections without any field are omitted.
class LayoutBlock {
  const LayoutBlock({
    required this.type,
    this.title = '',
    this.fieldId = -1,
    this.children = const [],
  });

  final BlockType type;

  /// Sections only: friendly name. header -> "Top banner", nav -> "Top menu",
  /// footer -> "Footer"; otherwise title-cased id (unless id is `top`),
  /// else first class, else "Section N". e.g. "About", "Work", "Contact".
  final String title;

  /// Field blocks only, else -1.
  final int fieldId;
  final List<LayoutBlock> children;
}

class SiteDocument {
  SiteDocument._(this.source);

  /// Parses [html]. Never throws on odd-but-valid HTML.
  factory SiteDocument.parse(String html) {
    final doc = SiteDocument._(html);
    doc._headStart = _afterDoctype(html);
    try {
      _Builder(doc).run();
    } catch (_) {
      // Something unexpected: fall back to an empty (but safe) model.
      doc._fields.clear();
      doc._locs.clear();
      doc._layout = const [];
      doc._headStart = _afterDoctype(html);
      doc._headEnd = null;
    }
    return doc;
  }

  /// The exact HTML this document was parsed from.
  final String source;

  final List<SiteField> _fields = [];
  final List<_Loc> _locs = [];
  List<LayoutBlock> _layout = const [];

  /// Where `<base>` goes: end of the `<head>` start tag (or document start).
  int _headStart = 0;

  /// Start of `</head>`, when present and reliable.
  int? _headEnd;

  /// All editable fields, document order.
  List<SiteField> get fields => List.unmodifiable(_fields);

  /// Sections in document order.
  List<LayoutBlock> get layout => _layout;

  /// HTML with edits applied.
  ///
  /// [texts]: fieldId -> new plain text ('\n' = line break -> `<br />`).
  /// Text is HTML-escaped (&, <, >). Leading/trailing whitespace of the
  /// original inner range is preserved around the new content.
  /// [images]: fieldId -> new `src` value (attribute-escaped: & " < >).
  /// Entries equal to the original value, or for unknown ids / wrong kind,
  /// are ignored. With no effective edits the result == [source] exactly.
  String render({
    Map<int, String> texts = const {},
    Map<int, String> images = const {},
  }) {
    final splices = _editSplices(texts, images);
    return splices.isEmpty ? source : _apply(splices);
  }

  /// Like [render], for the preview iframe only:
  /// - inserts `<base href="[baseHref]">` right after the `<head ...>` start
  ///   tag (so relative css/img/js resolve against the live site);
  /// - inserts [extraHead] right before `</head>`;
  /// - adds ` data-sitor-field="<id>"` to the start tag of every field's
  ///   element (text element or img).
  /// If there is no <head>, inserts both at the very start of the document.
  String renderPreview({
    Map<int, String> texts = const {},
    Map<int, String> images = const {},
    required String baseHref,
    String extraHead = '',
  }) {
    // Inserts go first so they precede a replacement starting at the same
    // offset (see _apply).
    final splices = <_Splice>[
      _Splice(_headStart, _headStart, '<base href="${_escAttr(baseHref)}">'),
      if (extraHead.isNotEmpty)
        _Splice(_headEnd ?? _headStart, _headEnd ?? _headStart, extraHead),
      for (var i = 0; i < _locs.length; i++)
        _Splice(_locs[i].nameEnd, _locs[i].nameEnd, ' data-sitor-field="$i"'),
      ..._editSplices(texts, images),
    ];
    return _apply(splices);
  }

  List<_Splice> _editSplices(Map<int, String> texts, Map<int, String> images) {
    final out = <_Splice>[];
    texts.forEach((id, value) {
      if (id < 0 || id >= _fields.length) return;
      final f = _fields[id];
      if (f.kind != FieldKind.text) return;
      final v = value.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
      if (v == f.original) return;
      final loc = _locs[id];
      final raw = source.substring(loc.innerStart, loc.innerEnd);
      final lead = _leadWs.firstMatch(raw)![0]!;
      final trail = _trailWs.firstMatch(raw.substring(lead.length))![0]!;
      final lines = v.split('\n').map(_escText);
      final body = lines.join(f.tag == 'title' ? ' ' : loc.br);
      out.add(_Splice(loc.innerStart, loc.innerEnd, '$lead$body$trail'));
    });
    images.forEach((id, value) {
      if (id < 0 || id >= _fields.length) return;
      final f = _fields[id];
      if (f.kind != FieldKind.image || value == f.original) return;
      final loc = _locs[id];
      final v = _escAttr(value);
      out.add(
        _Splice(loc.valueStart, loc.valueEnd, loc.wholeAttr ? 'src="$v"' : v),
      );
    });
    return out;
  }

  /// Applies non-overlapping splices (offsets into [source]) in one pass.
  /// At equal offsets, earlier list entries come first.
  String _apply(List<_Splice> splices) {
    final order = List.generate(splices.length, (i) => i)
      ..sort((a, b) {
        final c = splices[a].start.compareTo(splices[b].start);
        return c != 0 ? c : a.compareTo(b);
      });
    final out = StringBuffer();
    var cursor = 0;
    for (final i in order) {
      final s = splices[i];
      if (s.start < cursor || s.end < s.start || s.end > source.length) {
        continue;
      }
      out
        ..write(source.substring(cursor, s.start))
        ..write(s.text);
      cursor = s.end;
    }
    out.write(source.substring(cursor));
    return out.toString();
  }

  static int _afterDoctype(String html) =>
      _doctype.matchAsPrefix(html)?.end ?? 0;
}

final _doctype = RegExp(r'﻿?\s*<!doctype[^>]*>', caseSensitive: false);
final _leadWs = RegExp(r'^[ \t\r\n\f]*');
final _trailWs = RegExp(r'[ \t\r\n\f]*$');
final _wsRun = RegExp(r'[ \t\r\n\f]+');
final _brTag = RegExp(r'<br\b[^>]*>', caseSensitive: false);
final _anyTag = RegExp(r'<[A-Za-z/!?]');

String _escText(String s) =>
    s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');

String _escAttr(String s) => _escText(s).replaceAll('"', '&quot;');

class _Splice {
  const _Splice(this.start, this.end, this.text);
  final int start;
  final int end;
  final String text;
}

/// Where a field lives in the original source.
class _Loc {
  const _Loc.text(this.nameEnd, this.innerStart, this.innerEnd, this.br)
    : valueStart = -1,
      valueEnd = -1,
      wholeAttr = false;

  const _Loc.image(this.nameEnd, this.valueStart, this.valueEnd, this.wholeAttr)
    : innerStart = -1,
      innerEnd = -1,
      br = '';

  /// End of the tag name in the start tag (insert point for attributes).
  final int nameEnd;
  final int innerStart;
  final int innerEnd;

  /// Line break spelling used when writing text.
  final String br;

  /// Image: range replaced by the new value, or by a whole `src="..."`
  /// attribute when [wholeAttr].
  final int valueStart;
  final int valueEnd;
  final bool wholeAttr;
}

const _skipped = {
  'script',
  'style',
  'noscript',
  'template',
  'textarea',
  'svg',
  'math',
  'iframe',
  'noframes',
  'xmp',
  'plaintext',
};
const _headings = {'h2', 'h3', 'h4', 'h5', 'h6'};
const _blockText = {
  'p',
  'div',
  'li',
  'dt',
  'dd',
  'blockquote',
  'pre',
  'address',
  'figcaption',
  'title',
  'h1',
  'h2',
  'h3',
  'h4',
  'h5',
  'h6',
};
const _sectioning = {
  'section',
  'header',
  'footer',
  'nav',
  'article',
  'main',
  'aside',
};

class _Builder {
  _Builder(this.doc) : src = doc.source {
    // package:html folds CRLF into LF before computing offsets; map back.
    if (src.contains('\r')) {
      final m = <int>[];
      for (var i = 0; i < src.length; i++) {
        if (src.codeUnitAt(i) == 0x0A &&
            i > 0 &&
            src.codeUnitAt(i - 1) == 0x0D) {
          continue;
        }
        m.add(i);
      }
      m.add(src.length);
      map = m;
    }
  }

  final SiteDocument doc;
  final String src;
  List<int>? map;
  final fieldOf = Map<Element, int>.identity();
  final hasMemo = Map<Element, bool>.identity();

  int o(int n) {
    final m = map;
    if (m == null) return n;
    return m[n.clamp(0, m.length - 1)];
  }

  void run() {
    final dom = HtmlParser(src, generateSpans: true).parse();

    final head = dom.head;
    if (head != null) {
      final st = _startTag(head);
      if (st != null) {
        doc._headStart = st.$3;
        final e = _endTagStart(head, st.$3);
        if (e != null) doc._headEnd = e;
      }
      for (final t in head.children) {
        if (t.localName == 'title') {
          _guard(() => _textField(t));
          break;
        }
      }
    }
    final headTitle = doc._fields.isNotEmpty;
    final bodyKids = dom.body?.children ?? const <Element>[];
    bodyKids.forEach(_walk);

    final sections = <LayoutBlock>[];
    if (headTitle) {
      sections.add(
        const LayoutBlock(
          type: BlockType.section,
          title: 'Page',
          children: [LayoutBlock(type: BlockType.field, fieldId: 0)],
        ),
      );
    }
    final bodySections = <LayoutBlock>[];
    final loose = <LayoutBlock>[];
    void flush() {
      if (loose.isEmpty) return;
      bodySections.add(
        LayoutBlock(
          type: BlockType.section,
          title: 'Page content',
          children: List.of(loose),
        ),
      );
      loose.clear();
    }

    void top(Element e) {
      final id = fieldOf[e];
      if (id != null) {
        loose.add(LayoutBlock(type: BlockType.field, fieldId: id));
      } else if (!_has(e)) {
        return;
      } else if (_isWrapper(e)) {
        e.children.forEach(top);
      } else {
        flush();
        bodySections.add(
          LayoutBlock(
            type: BlockType.section,
            title: _sectionTitle(e, bodySections.length + 1),
            children: _blocks(e),
          ),
        );
      }
    }

    bodyKids.forEach(top);
    flush();
    doc._layout = List.unmodifiable([...sections, ...bodySections]);
  }

  void _guard(void Function() f) {
    try {
      f();
    } catch (_) {
      // Skip this element; it just won't be editable.
    }
  }

  void _walk(Element e) {
    final tag = e.localName;
    if (tag == null || _skipped.contains(tag)) return;
    if (tag == 'img') {
      if (e.attributes.containsKey('src')) _guard(() => _imageField(e));
      return;
    }
    if (_isTextCandidate(e)) {
      final before = doc._fields.length;
      _guard(() => _textField(e));
      if (doc._fields.length > before) return;
    }
    for (final c in e.children) {
      _walk(c);
    }
  }

  bool _isTextCandidate(Element e) {
    if (e.nodes.isEmpty) return false;
    for (final n in e.nodes) {
      if (n is Text) continue;
      if (n is Element && n.localName == 'br') continue;
      return false;
    }
    return _plainText(e).trim().isNotEmpty;
  }

  /// Decoded text: `<br>` -> '\n', whitespace collapsed and trimmed per line.
  String _plainText(Element e) {
    final lines = <String>[];
    var buf = StringBuffer();
    for (final n in e.nodes) {
      if (n is Text) {
        buf.write(n.data);
      } else {
        lines.add(buf.toString());
        buf = StringBuffer();
      }
    }
    lines.add(buf.toString());
    return lines
        .map(
          (l) => l
              .replaceAll(_wsRun, ' ')
              .replaceAll(_leadWs, '')
              .replaceAll(_trailWs, ''),
        )
        .join('\n');
  }

  void _textField(Element e) {
    final st = _startTag(e);
    if (st == null) return;
    final (_, nameEnd, innerStart) = st;
    final innerEnd = _endTagStart(e, innerStart);
    if (innerEnd == null) return;
    final raw = src.substring(innerStart, innerEnd);
    // Source must hold nothing but text and <br>s, or splicing is unsafe.
    if (_anyTag.hasMatch(raw.replaceAll(_brTag, ''))) return;
    final original = _plainText(e);
    if (original.trim().isEmpty) return;
    final id = doc._fields.length;
    doc._fields.add(
      SiteField(
        id: id,
        kind: FieldKind.text,
        label: _label(e),
        tag: e.localName!,
        original: original,
        level: _level(e),
      ),
    );
    doc._locs.add(
      _Loc.text(
        nameEnd,
        innerStart,
        innerEnd,
        _brTag.firstMatch(raw)?[0] ?? '<br />',
      ),
    );
    fieldOf[e] = id;
  }

  void _imageField(Element e) {
    final st = _startTag(e);
    if (st == null) return;
    final (a, nameEnd, b) = st;
    final range = _srcFromSpans(e, a, b) ?? _scanSrc(a, b);
    if (range == null) return;
    final id = doc._fields.length;
    doc._fields.add(
      SiteField(
        id: id,
        kind: FieldKind.image,
        label: 'Picture',
        tag: 'img',
        original: e.attributes['src'] ?? '',
        level: 3,
        alt: e.attributes['alt'],
      ),
    );
    doc._locs.add(_Loc.image(nameEnd, range.$1, range.$2, range.$3));
    fieldOf[e] = id;
  }

  /// (start, nameEnd, end) of [e]'s start tag in the original source.
  (int, int, int)? _startTag(Element e) {
    final s = e.sourceSpan;
    final tag = e.localName;
    if (s == null || tag == null) return null;
    final a = o(s.start.offset), b = o(s.end.offset);
    if (a < 0 || b > src.length || b - a < 2) return null;
    if (src.codeUnitAt(a) != 0x3C || src.codeUnitAt(b - 1) != 0x3E) {
      return null;
    }
    var i = a + 1;
    while (i < b - 1 && !_nameEnds(src.codeUnitAt(i))) {
      i++;
    }
    if (src.substring(a + 1, i).toLowerCase() != tag) return null;
    return (a, i, b);
  }

  /// Start of [e]'s end tag in the original source, if reliably known.
  int? _endTagStart(Element e, int innerStart) {
    final tag = e.localName!;
    final re = RegExp('</${RegExp.escape(tag)}[\\s/>]', caseSensitive: false);
    final s = e.endSourceSpan;
    if (s != null) {
      final a = o(s.start.offset);
      if (a < innerStart || a >= src.length) return null;
      return re.matchAsPrefix(src, a) != null ? a : null;
    }
    // RCDATA elements get no end span from package:html.
    if (tag == 'title') {
      final m = re.allMatches(src, innerStart);
      return m.isEmpty ? null : m.first.start;
    }
    return null;
  }

  (int, int, bool)? _srcFromSpans(Element e, int a, int b) {
    final vs = e.attributeValueSpans?['src'];
    if (vs != null) {
      final x = o(vs.start.offset), y = o(vs.end.offset);
      if (x > a &&
          y < b &&
          x <= y &&
          src.codeUnitAt(x - 1) == 0x22 &&
          src.codeUnitAt(y) == 0x22) {
        return (x, y, false);
      }
    }
    final as = e.attributeSpans?['src'];
    if (as != null) {
      final x = o(as.start.offset), y = o(as.end.offset);
      if (x > a &&
          y < b &&
          x + 3 <= y &&
          src.substring(x, x + 3).toLowerCase() == 'src') {
        return (x, y, true);
      }
    }
    return null;
  }

  /// Manual scan of the start tag [a, b) for the first `src` attribute.
  (int, int, bool)? _scanSrc(int a, int b) {
    bool ws(int c) =>
        c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0C || c == 0x0D;
    var i = a + 1;
    while (i < b && !_nameEnds(src.codeUnitAt(i))) {
      i++;
    }
    while (i < b) {
      while (i < b && (ws(src.codeUnitAt(i)) || src.codeUnitAt(i) == 0x2F)) {
        i++;
      }
      if (i >= b || src.codeUnitAt(i) == 0x3E) return null;
      final nameStart = i;
      while (i < b) {
        final c = src.codeUnitAt(i);
        if (ws(c) || c == 0x2F || c == 0x3E || (c == 0x3D && i > nameStart)) {
          break;
        }
        i++;
      }
      final name = src.substring(nameStart, i).toLowerCase();
      var j = i;
      while (j < b && ws(src.codeUnitAt(j))) {
        j++;
      }
      var end = i;
      int? vStart, vEnd;
      var quote = 0;
      if (j < b && src.codeUnitAt(j) == 0x3D) {
        j++;
        while (j < b && ws(src.codeUnitAt(j))) {
          j++;
        }
        final q = j < b ? src.codeUnitAt(j) : 0;
        if (q == 0x22 || q == 0x27) {
          final close = src.indexOf(String.fromCharCode(q), j + 1);
          if (close < 0 || close >= b) return null;
          quote = q;
          vStart = j + 1;
          vEnd = close;
          j = close + 1;
        } else {
          vStart = j;
          while (j < b && !ws(src.codeUnitAt(j)) && src.codeUnitAt(j) != 0x3E) {
            j++;
          }
          vEnd = j;
        }
        end = j;
      }
      if (name == 'src') {
        return quote == 0x22 ? (vStart!, vEnd!, false) : (nameStart, end, true);
      }
      i = end > i ? end : i;
    }
    return null;
  }

  bool _has(Element e) =>
      hasMemo[e] ??= fieldOf.containsKey(e) || e.children.any(_has);

  bool _isWrapper(Element e) =>
      (e.localName == 'main' || e.localName == 'div') &&
      e.children.any((c) => _sectioning.contains(c.localName) && _has(c));

  List<LayoutBlock> _blocks(Element e) {
    final id = fieldOf[e];
    if (id != null) return [LayoutBlock(type: BlockType.field, fieldId: id)];
    final kids = e.children.where(_has).toList();
    final out = <LayoutBlock>[];
    for (var i = 0; i < kids.length;) {
      final key = _rowKey(kids[i]);
      var j = i + 1;
      while (key != null && j < kids.length && _rowKey(kids[j]) == key) {
        j++;
      }
      if (j - i >= 2) {
        out.add(
          LayoutBlock(
            type: BlockType.row,
            children: [
              for (final k in kids.sublist(i, j))
                LayoutBlock(type: BlockType.column, children: _blocks(k)),
            ],
          ),
        );
      } else {
        out.addAll(_blocks(kids[i]));
      }
      i = j;
    }
    return out;
  }

  /// Consecutive siblings with the same non-null key sit side by side:
  /// inline-ish fields of one tag (footer spans), or containers of one tag
  /// and first class (figure.plate, li, a.svc). Block-level text and mixed
  /// runs stay vertical (stacked paragraphs, label + grid).
  String? _rowKey(Element e) {
    final tag = e.localName;
    if (fieldOf.containsKey(e)) {
      return _blockText.contains(tag) ? null : 'field:$tag';
    }
    return 'box:$tag.${_firstClass(e)}';
  }

  String _sectionTitle(Element e, int n) {
    switch (e.localName) {
      case 'header':
        return 'Top banner';
      case 'nav':
        return 'Top menu';
      case 'footer':
        return 'Footer';
    }
    final id = (e.attributes['id'] ?? '').trim();
    if (id.isNotEmpty && id.toLowerCase() != 'top') return _titleCase(id);
    final cls = _firstClass(e);
    if (cls.isNotEmpty) return _titleCase(cls);
    return 'Section $n';
  }

  String _label(Element e) {
    final tag = e.localName;
    if (tag == 'title') return 'Browser tab title';
    if (tag == 'h1') return 'Big headline';
    if (_headings.contains(tag) || e.classes.contains('display')) {
      return 'Headline';
    }
    if (tag == 'small' || e.classes.contains('label')) return 'Small text';
    if (tag == 'a') {
      return _inside(e, 'li') && _inside(e, 'nav') ? 'Menu item' : 'Link text';
    }
    if (tag == 'p') return 'Paragraph';
    if (tag == 'figcaption' ||
        (tag == 'span' && e.parent?.localName == 'figure')) {
      return 'Caption';
    }
    return 'Text';
  }

  int _level(Element e) {
    final tag = e.localName;
    if (tag == 'h1') return 1;
    if (_headings.contains(tag) || e.classes.contains('display')) return 2;
    if (tag == 'small' ||
        tag == 'title' ||
        e.classes.contains('label') ||
        _inside(e, 'nav') ||
        _inside(e, 'footer')) {
      return 4;
    }
    return 3;
  }
}

bool _nameEnds(int c) =>
    c == 0x20 ||
    c == 0x09 ||
    c == 0x0A ||
    c == 0x0C ||
    c == 0x0D ||
    c == 0x2F ||
    c == 0x3E;

bool _inside(Element e, String tag) {
  for (var p = e.parent; p != null; p = p.parent) {
    if (p.localName == tag) return true;
  }
  return false;
}

String _firstClass(Element e) {
  final c = (e.attributes['class'] ?? '').trim();
  return c.isEmpty ? '' : c.split(_wsRun).first;
}

String _titleCase(String s) => s
    .split(RegExp(r'[-_\s]+'))
    .where((w) => w.isNotEmpty)
    .map((w) => w[0].toUpperCase() + w.substring(1))
    .join(' ');
