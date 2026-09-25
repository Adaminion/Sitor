// 2026-09-25
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html;
import 'package:sitor/site/site_document.dart';

void main() {
  final source = File('website/current/index.html').readAsStringSync();
  late SiteDocument doc;
  setUp(() => doc = SiteDocument.parse(source));

  int idOf(String tag, String original) =>
      doc.fields.firstWhere((f) => f.tag == tag && f.original == original).id;

  List<int> leafIds(LayoutBlock b) => b.type == BlockType.field
      ? [b.fieldId]
      : [for (final c in b.children) ...leafIds(c)];

  group('real page', () {
    test('render without edits returns the source exactly', () {
      expect(doc.render(), source);
      expect(doc.render(texts: {}, images: {}), source);
    });

    test('fields', () {
      final f = doc.fields;
      for (var i = 0; i < f.length; i++) {
        expect(f[i].id, i);
      }
      expect(f[0].tag, 'title');
      expect(f[0].original, 'ALCOR General Construction · New Jersey');
      expect(f[0].label, 'Browser tab title');
      expect(f[0].level, 4);

      final h1 = f[idOf('h1', 'We build the house you mean to keep.')];
      expect(h1.label, 'Big headline');
      expect(h1.level, 1);
      expect(h1.kind, FieldKind.text);

      expect(
        f.where((x) => x.original == 'New Jersey\n609 977 9935').length,
        1,
      );
      final contact = f[idOf('p', 'New Jersey\n609 977 9935')];
      expect(contact.label, 'Paragraph');

      final images = f.where((x) => x.kind == FieldKind.image).toList();
      expect(images.length, RegExp(r'<img\b').allMatches(source).length);
      expect(images.map((x) => x.original).toList(), [
        'hero.jpg',
        'kitchen.jpg',
        'bath.jpg',
        'living.jpg',
        'basement.jpg',
        'deck.jpg',
        'kitchen.jpg',
        'roofing.jpg',
        'windows.jpg',
        'door.jpg',
        'team.jpg',
        'neighborhood.jpg',
      ]);
      expect(
        images.every((x) => x.label == 'Picture' && x.tag == 'img'),
        isTrue,
      );
      expect(images.first.alt, 'Renovated New Jersey home at dusk');
      expect(images.every((x) => x.level == 3), isTrue);

      for (final m in ['Work', 'Services', 'Approach', 'Contact']) {
        final item = f[idOf('a', m)];
        expect(item.label, 'Menu item', reason: m);
        expect(item.level, 4);
      }
      expect(f[idOf('a', 'Alcor')].label, 'Link text');
      expect(f[idOf('a', 'Request a visit')].label, 'Link text');
      expect(f[idOf('div', 'About')].label, 'Small text');
      expect(f[idOf('h2', 'Family owned. Start to finish.')].label, 'Headline');
      expect(f[idOf('h2', 'Family owned. Start to finish.')].level, 2);
      expect(f[idOf('span', 'Renovate')].label, 'Headline');
      expect(f[idOf('small', 'Roofing')].label, 'Small text');
      expect(f[idOf('span', 'Kitchen, New Jersey')].label, 'Caption');
      expect(f[idOf('span', 'Alcor General Construction')].level, 4);
      expect(f[idOf('p', 'General Construction · New Jersey')].level, 3);
      expect(
        f.any(
          (x) => x.original.startsWith(
            'Interior and exterior '
            'renovations — kitchens',
          ),
        ),
        isTrue,
      );
      // Nothing from <style>/<meta>.
      expect(f.any((x) => x.original.contains('{')), isFalse);
      // title 1, nav 5, hero 3, about 3, work 6, services 8, approach 2,
      // contact 2, footer 2.
      expect(f.where((x) => x.kind == FieldKind.text).length, 32);
    });

    test('layout', () {
      final l = doc.layout;
      expect(l.map((s) => s.title).toList(), [
        'Page',
        'Top menu',
        'Top banner',
        'About',
        'Work',
        'Services',
        'Approach',
        'Contact',
        'Footer',
      ]);
      expect(l.every((s) => s.type == BlockType.section), isTrue);
      expect(leafIds(l[0]), [0]);

      // Every field exactly once, in document order.
      final all = [for (final s in l) ...leafIds(s)];
      expect(all, List.generate(doc.fields.length, (i) => i));

      void checkShape(LayoutBlock b) {
        switch (b.type) {
          case BlockType.section:
          case BlockType.column:
            expect(b.children, isNotEmpty);
            for (final c in b.children) {
              expect(c.type, anyOf(BlockType.field, BlockType.row));
            }
          case BlockType.row:
            expect(b.children.length, greaterThanOrEqualTo(2));
            for (final c in b.children) {
              expect(c.type, BlockType.column);
            }
          case BlockType.field:
            expect(b.children, isEmpty);
        }
        b.children.forEach(checkShape);
      }

      l.forEach(checkShape);

      final menu = l[1];
      expect(menu.children.length, 2);
      expect(menu.children[0].type, BlockType.field);
      expect(doc.fields[menu.children[0].fieldId].original, 'Alcor');
      expect(menu.children[1].type, BlockType.row);
      expect(menu.children[1].children.length, 4);
      expect(
        menu.children[1].children
            .map((c) => doc.fields[leafIds(c).single].original)
            .toList(),
        ['Work', 'Services', 'Approach', 'Contact'],
      );

      final work = l[4];
      expect(work.children.map((c) => c.type).toList(), [
        BlockType.field,
        BlockType.row,
        BlockType.row,
      ]);
      expect(work.children[1].children.length, 3);
      expect(work.children[2].children.length, 2);
      expect(leafIds(work.children[1].children[0]).length, 2); // img + caption

      final services = l[5];
      expect(services.children.length, 1);
      expect(services.children[0].type, BlockType.row);
      expect(services.children[0].children.length, 4);
      expect(leafIds(services.children[0].children[0]).length, 3);

      final banner = l[2];
      expect(banner.children.every((c) => c.type == BlockType.field), isTrue);
      expect(banner.children.length, 4);

      final footer = l[8];
      expect(footer.children.length, 1);
      expect(footer.children[0].type, BlockType.row);
      expect(footer.children[0].children.length, 2);
    });

    test('text edit is escaped', () {
      final id = idOf('h1', 'We build the house you mean to keep.');
      final out = doc.render(texts: {id: 'A & B <c>'});
      expect(
        out,
        source.replaceFirst(
          '>We build the house you mean to keep.<',
          '>A &amp; B &lt;c&gt;<',
        ),
      );
      expect(SiteDocument.parse(out).fields[id].original, 'A & B <c>');
    });

    test('multi-line text uses the original <br /> spelling', () {
      final id = idOf('p', 'New Jersey\n609 977 9935');
      final out = doc.render(
        texts: {id: 'New Jersey\n609 977 9935\nMon–Fri 7–5'},
      );
      expect(
        out,
        source.replaceFirst(
          '<p>New Jersey<br />609 977 9935</p>',
          '<p>New Jersey<br />609 977 9935<br />Mon–Fri 7–5</p>',
        ),
      );
      // Windows line endings from a text box behave the same.
      expect(
        doc.render(texts: {id: 'New Jersey\r\n609 977 9935\r\nMon–Fri 7–5'}),
        out,
      );
    });

    test('image edit changes only that src value', () {
      final kitchens = doc.fields
          .where(
            (f) => f.kind == FieldKind.image && f.original == 'kitchen.jpg',
          )
          .toList();
      expect(kitchens.length, 2);
      final out = doc.render(images: {kitchens[1].id: 'media/new-kitchen.jpg'});
      const needle = 'src="kitchen.jpg"';
      final at = source.indexOf(needle, source.indexOf(needle) + 1);
      expect(
        out,
        source.replaceRange(
          at,
          at + needle.length,
          'src="media/new-kitchen.jpg"',
        ),
      );
      final again = SiteDocument.parse(out);
      expect(again.fields[kitchens[0].id].original, 'kitchen.jpg');
      expect(again.fields[kitchens[1].id].original, 'media/new-kitchen.jpg');
    });

    test('image src is attribute-escaped', () {
      final id = doc.fields.firstWhere((f) => f.kind == FieldKind.image).id;
      final out = doc.render(images: {id: 'a&b "c" <d>.jpg'});
      expect(
        out,
        source.replaceFirst(
          'src="hero.jpg"',
          'src="a&amp;b &quot;c&quot; &lt;d&gt;.jpg"',
        ),
      );
      expect(SiteDocument.parse(out).fields[id].original, 'a&b "c" <d>.jpg');
    });

    test('many edits at once, around multi-byte characters', () {
      final about = doc.fields.firstWhere(
        (f) => f.tag == 'p' && f.original.startsWith('Interior'),
      );
      final footerNj = doc.fields.lastWhere((f) => f.original == 'New Jersey');
      final hero = doc.fields.firstWhere((f) => f.kind == FieldKind.image);
      final team = doc.fields.firstWhere((f) => f.original == 'team.jpg');
      final out = doc.render(
        texts: {
          0: 'ALCOR · Sitor — test',
          about.id: 'Kitchens — baths · decks.',
          footerNj.id: 'NJ & NY',
        },
        images: {hero.id: 'media/hero-2.jpg', team.id: 'media/team 2.jpg'},
      );
      var expected = source
          .replaceFirst(
            '<title>ALCOR General Construction · New Jersey</title>',
            '<title>ALCOR · Sitor — test</title>',
          )
          .replaceFirst('src="hero.jpg"', 'src="media/hero-2.jpg"')
          .replaceFirst('src="team.jpg"', 'src="media/team 2.jpg"')
          .replaceFirst(
            '    <span>New Jersey</span>\n  </footer>',
            '    <span>NJ &amp; NY</span>\n  </footer>',
          );
      final aboutStart = expected.indexOf('<p>Interior');
      final aboutEnd = expected.indexOf('</p>', aboutStart);
      expected = expected.replaceRange(
        aboutStart,
        aboutEnd,
        '<p>Kitchens — baths · decks.',
      );
      expect(out, expected);

      final again = SiteDocument.parse(out);
      expect(again.fields.length, doc.fields.length);
      expect(again.fields[0].original, 'ALCOR · Sitor — test');
      expect(again.fields[about.id].original, 'Kitchens — baths · decks.');
      expect(again.fields[footerNj.id].original, 'NJ & NY');
      expect(again.fields[hero.id].original, 'media/hero-2.jpg');
    });

    test('unknown ids, wrong kinds and unchanged values are ignored', () {
      final img = doc.fields.firstWhere((f) => f.kind == FieldKind.image).id;
      expect(
        doc.render(
          texts: {999: 'x', -1: 'y', img: 'not text'},
          images: {0: 'x.jpg', 999: 'y.jpg'},
        ),
        source,
      );
      expect(
        doc.render(
          texts: {
            for (final f in doc.fields)
              if (f.kind == FieldKind.text) f.id: f.original,
          },
          images: {
            for (final f in doc.fields)
              if (f.kind == FieldKind.image) f.id: f.original,
          },
        ),
        source,
      );
    });

    test('renderPreview', () {
      const extra = '<script>/*SITOR*/</script>';
      const base = '<base href="https://example.com/site/">';
      final out = doc.renderPreview(
        baseHref: 'https://example.com/site/',
        extraHead: extra,
      );
      expect(out.indexOf(base), out.indexOf('<head>') + '<head>'.length);
      expect(out, contains('$extra</head>'));

      final dom = html.parse(out);
      final marked = dom.querySelectorAll('[data-sitor-field]');
      expect(marked.length, doc.fields.length);
      for (var i = 0; i < marked.length; i++) {
        expect(marked[i].attributes['data-sitor-field'], '$i');
        expect(marked[i].localName, doc.fields[i].tag);
      }

      // Stripping the injections gives back the source.
      final stripped = out
          .replaceFirst(base, '')
          .replaceFirst(extra, '')
          .replaceAll(RegExp(r' data-sitor-field="\d+"'), '');
      expect(stripped, source);

      // Same fields when re-parsed.
      expect(
        SiteDocument.parse(out).fields.map((f) => f.original).toList(),
        doc.fields.map((f) => f.original).toList(),
      );
    });

    test('renderPreview applies edits too', () {
      final h1 = idOf('h1', 'We build the house you mean to keep.');
      final hero = doc.fields.firstWhere((f) => f.kind == FieldKind.image).id;
      final out = doc.renderPreview(
        texts: {h1: 'Hello\nthere'},
        images: {hero: 'media/x.jpg'},
        baseHref: '../',
      );
      expect(
        out,
        contains(
          '<h1 data-sitor-field="$h1" class="display">'
          'Hello<br />there</h1>',
        ),
      );
      expect(out, contains('<img data-sitor-field="$hero" src="media/x.jpg"'));
      expect(out, contains('<head><base href="../">'));
    });
  });

  group('robustness', () {
    const odd = [
      '',
      '<',
      '<<<>>>',
      '</p>',
      'just text',
      '<p>Hello</p>',
      '<!DOCTYPE html><p>Hi</p>',
      '<p>Hi <b>there</b></p>',
      '<p>unclosed<p>closed</p>',
      '<ul><li>one<li>two</ul>',
      '<h1>mismatch</h2><p>ok</p>',
      '<svg><title>x</title><text>y</text></svg><p>z</p>',
      '<script>var a = "<p>x</p>";</script><p>y</p>',
      '<template><p>t</p></template><noscript><p>n</p></noscript>',
      '<p><!-- c -->text</p>',
      '<p>a<br>b<br/>c</p>',
      '<img><img src><img src=""><img alt=x src = "c.jpg" />',
      '<table><tr><td>cell</td><p>stray</p></table>',
      '<b>x<p>y</b>z</p>',
      '<p>😀 emoji</p><p>after 😀</p>',
      '﻿<!doctype html><html><head><title></title></head><body></body></html>',
      '<textarea><p>no</p></textarea><title>late</title>',
    ];

    for (final s in odd) {
      test('never throws: ${s.length > 40 ? s.substring(0, 40) : s}', () {
        final d = SiteDocument.parse(s);
        expect(d.render(), s);
        final allText = {
          for (final f in d.fields)
            if (f.kind == FieldKind.text) f.id: '${f.original}!',
        };
        final allImg = {
          for (final f in d.fields)
            if (f.kind == FieldKind.image) f.id: 'n.jpg',
        };
        final edited = d.render(texts: allText, images: allImg);
        final again = SiteDocument.parse(edited);
        expect(again.fields.length, d.fields.length);
        for (final f in again.fields) {
          expect(
            f.original,
            f.kind == FieldKind.text ? allText[f.id] : allImg[f.id],
          );
        }
        final p = d.renderPreview(baseHref: 'b/', extraHead: '<i></i>');
        expect(p, contains('<base href="b/">'));
        expect(
          d.layout.expand(leafIds).toList()..sort(),
          List.generate(d.fields.length, (i) => i),
        );
      });
    }

    test('no <head>: injections go first (after doctype)', () {
      final d = SiteDocument.parse('<p>Hello</p>');
      expect(d.fields.single.original, 'Hello');
      expect(d.layout.single.title, 'Page content');
      expect(
        d.renderPreview(baseHref: 'x/', extraHead: '<i></i>'),
        '<base href="x/"><i></i><p data-sitor-field="0">Hello</p>',
      );
      expect(
        SiteDocument.parse(
          '<!DOCTYPE html>\n<p>Hi</p>',
        ).renderPreview(baseHref: 'x/'),
        '<!DOCTYPE html><base href="x/">\n<p data-sitor-field="0">Hi</p>',
      );
    });

    test('uppercase tags', () {
      const s =
          '<HTML><HEAD><TITLE>T &amp; U</TITLE></HEAD><BODY>'
          '<H1 CLASS="x">Big</H1><IMG SRC="a.jpg" ALT="A"><P>One<BR>Two</P>'
          '</BODY></HTML>';
      final d = SiteDocument.parse(s);
      expect(d.fields.map((f) => f.original).toList(), [
        'T & U',
        'Big',
        'a.jpg',
        'One\nTwo',
      ]);
      expect(d.fields.map((f) => f.tag).toList(), ['title', 'h1', 'img', 'p']);
      expect(d.fields[1].label, 'Big headline');
      expect(d.fields[2].alt, 'A');
      expect(
        d.render(texts: {0: 'X & Y', 3: 'A\nB'}, images: {2: 'b.jpg'}),
        '<HTML><HEAD><TITLE>X &amp; Y</TITLE></HEAD><BODY>'
        '<H1 CLASS="x">Big</H1><IMG SRC="b.jpg" ALT="A"><P>A<BR>B</P>'
        '</BODY></HTML>',
      );
      expect(
        d.renderPreview(baseHref: 'z/', extraHead: 'E'),
        contains('<HEAD><base href="z/"><TITLE data-sitor-field="0">'),
      );
      expect(
        d.renderPreview(baseHref: 'z/', extraHead: 'E'),
        contains('</TITLE>E</HEAD>'),
      );
    });

    test('entities are decoded; whitespace around content kept', () {
      const s =
          '<p>Tom &amp; Jerry&nbsp;show</p>\n<div>\n    Hello\n    '
          'world\n  </div>';
      final d = SiteDocument.parse(s);
      expect(d.fields[0].original, 'Tom & Jerry show');
      expect(d.fields[1].original, 'Hello world');
      expect(
        d.render(texts: {1: 'Bye'}),
        '<p>Tom &amp; Jerry&nbsp;show</p>\n<div>\n    Bye\n  </div>',
      );
      expect(d.render(texts: {0: 'Tom & Jerry show'}), s);
    });

    test('inline markup: p is not a field, b is', () {
      final d = SiteDocument.parse('<p>Hi <b>there</b></p>');
      expect(d.fields.single.tag, 'b');
      expect(d.fields.single.original, 'there');
      expect(d.render(texts: {0: 'you'}), '<p>Hi <b>you</b></p>');
    });

    test('unclosed <p> is skipped, the closed one works', () {
      final d = SiteDocument.parse('<p>unclosed<p>closed</p>');
      expect(d.fields.map((f) => f.original).toList(), ['closed']);
      expect(d.render(texts: {0: 'done'}), '<p>unclosed<p>done</p>');
    });

    test('CRLF line endings keep offsets right', () {
      const s =
          '<html>\r\n<head>\r\n<title>T—x</title>\r\n</head>\r\n'
          '<body>\r\n<p>a\r\nb</p>\r\n<img src="z.jpg">\r\n'
          '<span>é</span>\r\n</body></html>';
      final d = SiteDocument.parse(s);
      expect(d.fields.map((f) => f.original).toList(), [
        'T—x',
        'a b',
        'z.jpg',
        'é',
      ]);
      expect(
        d.render(texts: {0: 'New—t', 1: 'c\nd', 3: 'ü'}, images: {2: 'q.jpg'}),
        '<html>\r\n<head>\r\n<title>New—t</title>\r\n</head>\r\n'
        '<body>\r\n<p>c<br />d</p>\r\n<img src="q.jpg">\r\n'
        '<span>ü</span>\r\n</body></html>',
      );
      expect(
        d.renderPreview(baseHref: 'b/', extraHead: 'E'),
        '<html>\r\n<head><base href="b/">\r\n'
        '<title data-sitor-field="0">T—x</title>\r\nE</head>\r\n'
        '<body>\r\n<p data-sitor-field="1">a\r\nb</p>\r\n'
        '<img data-sitor-field="2" src="z.jpg">\r\n'
        '<span data-sitor-field="3">é</span>\r\n</body></html>',
      );
    });

    test('src quoting variants', () {
      const s =
          "<img src='a.jpg'><img src=b.jpg><img alt=x src = \"c.jpg\" />"
          '<img SRC="d.jpg"/>';
      final d = SiteDocument.parse(s);
      expect(d.fields.map((f) => f.original).toList(), [
        'a.jpg',
        'b.jpg',
        'c.jpg',
        'd.jpg',
      ]);
      expect(
        d.render(images: {0: 'n0', 1: 'n1', 2: 'n2', 3: 'n3'}),
        '<img src="n0"><img src="n1"><img alt=x src = "n2" />'
        '<img SRC="n3"/>',
      );
    });

    test('rows vs stacks', () {
      const s =
          '<section id="team-and-crew"><p>One</p><p>Two</p>'
          '<div class="col"><h3>A</h3><p>a</p></div>'
          '<div class="col"><h3>B</h3><p>b</p></div></section>'
          '<div><span>x</span><span>y</span></div>';
      final d = SiteDocument.parse(s);
      expect(d.layout.map((b) => b.title).toList(), [
        'Team And Crew',
        'Section 2',
      ]);
      final sec = d.layout[0];
      expect(sec.children.map((c) => c.type).toList(), [
        BlockType.field,
        BlockType.field,
        BlockType.row,
      ]);
      expect(sec.children[2].children.length, 2);
      expect(d.layout[1].children.single.type, BlockType.row);
    });

    test('wrappers are unwrapped, loose fields grouped', () {
      const s =
          '<h1>Loose</h1><main><header><nav><a href="#">Home</a></nav>'
          '<h1>Hi</h1></header><section class="x-y"><p>Body</p></section>'
          '</main><p>End</p>';
      final d = SiteDocument.parse(s);
      expect(d.layout.map((b) => b.title).toList(), [
        'Page content',
        'Top banner',
        'X Y',
        'Page content',
      ]);
      expect(d.layout[1].children.length, 2);
    });
  });
}
