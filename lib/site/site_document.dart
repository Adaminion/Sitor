// 2026-09-25
// HTML page model: finds editable texts/pictures and writes edits back
// surgically (every byte outside an edited range is preserved).
// Pure Dart (package:html with generateSpans) — must run on the VM for tests.

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
    throw UnimplementedError();
  }

  /// The exact HTML this document was parsed from.
  final String source;

  /// All editable fields, document order.
  List<SiteField> get fields => throw UnimplementedError();

  /// Sections in document order.
  List<LayoutBlock> get layout => throw UnimplementedError();

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
    throw UnimplementedError();
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
    throw UnimplementedError();
  }
}
