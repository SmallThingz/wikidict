import bz2
import hashlib
import json
import tempfile
import unittest
from contextlib import closing
from pathlib import Path
from xml.etree import ElementTree as ET

from source_definition_audit import SourceDefinitions, compiled_emphasis, compiled_line, definitions, localized_language_codes, simple_line, source_line


class SourceDefinitionTests(unittest.TestCase):
    def test_source_boundaries(self):
        text = '==English==\n===Noun===\n# [[cat|cats]]\n#: Example\n## subsense\n# [[self]]\n==Unknown==\n# stray meaning'
        self.assertEqual(list(definitions(text, 'self', {'English'})), [
            ('English', 3, '#', 'cats', ((0, 4, 'cat'),), None),
            ('English', 5, '##', 'subsense', (), None),
        ])
        for prefix in ('{{header}}', '<nowiki>', '{|', '__TOC__'):
            self.assertEqual(list(definitions(prefix + '\n' + text, 'self', {'English'})), [])
        self.assertEqual(list(definitions(text + '\n# ________________', 'self', {'English'})),
                         list(definitions(text, 'self', {'English'})))

    def test_localized_name_requires_one_owner_across_registry_sections(self):
        header = '# wikidict-language-registry-v2\n# mediawiki\n'
        raw = header + 'aa\tOne\taa\nfr\tfrançais\tFrench\n# iso-639-3\nzz\tTwo\tOne\n'
        self.assertEqual(localized_language_codes(raw.encode()), {'français': 'fr'})

    def test_source_index_keeps_order_and_origin_across_insert_batches(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            dump = root / 'wiki-date-pages-meta-current.xml.bz2'
            xml = ET.Element('mediawiki')
            for number, body in enumerate(('{{ignored}}', '==French==\n' + '# sense\n' * 257,
                                           '==French==\n# final'), 1):
                page = ET.SubElement(xml, 'page')
                ET.SubElement(page, 'title').text = str(number)
                ET.SubElement(page, 'ns').text = '0'
                ET.SubElement(page, 'id').text = str(number)
                revision = ET.SubElement(page, 'revision')
                ET.SubElement(revision, 'id').text = str(number + 4)
                ET.SubElement(revision, 'text').text = body
            compressed = bz2.compress(ET.tostring(xml))
            dump.write_bytes(compressed)
            member = ['wiki', 'date', dump.name, len(compressed), hashlib.sha1(compressed).hexdigest()]
            (root / 'complete.json').write_text(json.dumps(dict(edition='wiki', date='date', build_inputs=dict(files=[member]))))
            (root / 'languages.tsv').write_text('heading\nFrench\n')
            with closing(SourceDefinitions('', root, [dump])) as audit:
                rows = audit.db.execute('SELECT page,revision,line FROM sense ORDER BY rowid').fetchall()
            self.assertEqual(rows, [('2', '6', n) for n in range(2, 259)] + [('3', '7', 2)])

    def test_links_bind_each_visible_range_with_its_own_destination(self):
        expected = simple_line('A [[猫|cat]] or [[mačka|cat]].', 'other')
        self.assertEqual(expected, ('A cat or cat.', ((2, 5, '猫'), (9, 12, 'mačka'))))
        spans = [dict(kind='text', text='  A '), dict(kind='link', text='cat', target='猫'),
                 dict(kind='text', text=' or '), dict(kind='link', text='cat', target='mačka'), dict(kind='text', text='. ')]
        self.assertEqual(compiled_line(spans), expected)
        spans[1], spans[3] = spans[3], spans[1]
        self.assertNotEqual(compiled_line(spans), expected)
        for source in ('A [[cat]]s.', '[[other]], [[cat]]', '[[cat]] and [[broken', "[[cat|''cat'']]", '[[cat#part|cat]]'):
            self.assertIsNone(simple_line(source, 'other'))

    def test_literal_apostrophes_preserve_text_and_link_positions(self):
        text = "Liquidu trasparente chì si trova in a natura e ch'hè necissariu par a vita."
        self.assertEqual(simple_line(text, 'acqua'), (text, ()))
        self.assertEqual(simple_line("l'[[eau]]", 'mot'), ("l'eau", ((2, 5, 'eau'),)))
        # The target is an opaque page title, while the visible label is prose.
        self.assertEqual(simple_line("[[O''Neill|O'Neill]]", 'surname'),
                         ("O'Neill", ((0, 7, "O''Neill"),)))
        for marked in ("a ''word''", "'''bold'''", "[[word|''label'']]", "unclosed ''word"):
            self.assertIsNone(simple_line(marked, 'other'))

    def test_whitespace_inside_a_link_label_remains_part_of_the_action(self):
        source = '[[ഖചിതം| ചിത്രഖചിതമായ]] [[ആഭരണം]]'
        spans = [dict(kind='text', text='  '), dict(kind='link', target='ഖചിതം', text=' ചിത്രഖചിതമായ'),
                 dict(kind='text', text=' '), dict(kind='link', target='ആഭരണം', text='ആഭരണം'),
                 dict(kind='text', text='   ')]
        self.assertEqual(compiled_line(spans), simple_line(source, 'cameo'))
        spans[1]['text'] = spans[1]['text'].lstrip()
        spans[0]['text'] += ' '
        self.assertNotEqual(compiled_line(spans), simple_line(source, 'cameo'))
        source = "''[[word|word ]]''"
        spans = [dict(kind='link', target='word', text='word ', italic=True), dict(kind='text', text='   ')]
        self.assertEqual((*compiled_line(spans), compiled_emphasis(spans)), source_line(source, 'other'))

    def test_numbered_bare_url_must_be_an_external_link_to_its_own_text(self):
        url = 'https://tuludictionary.in/dictionary/cgi-bin/web/frame.html'
        expected = simple_line(url, 'word')
        self.assertEqual(compiled_line([dict(kind='external_link', text=url, target=url)]), expected)
        self.assertNotEqual(compiled_line([dict(kind='text', text=url)]), expected)
        self.assertNotEqual(compiled_line([dict(kind='link', text=url, target=url)]), expected)
        self.assertIsNone(compiled_line([dict(kind='external_link', text=url, target=url + '/elsewhere')]))

    def test_emphasis_uses_visible_unicode_offsets_and_preserves_link_targets(self):
        self.assertEqual(source_line("[[këmbë|këmbë]] (''skaj'')", 'foot'),
                         ('këmbë (skaj)', ((0, 5, 'këmbë'),), (7, 11, 'italic')))
        self.assertEqual(source_line("'''[[حاسد]]''' کی جمع", 'حساد'),
                         ('حاسد کی جمع', ((0, 4, 'حاسد'),), (0, 4, 'bold')))
        for invalid in ("[[cat|''cat'']]", "''a'''", "''a'' and ''b''", "'''''x'''''", "''' '''"):
            self.assertIsNone(source_line(invalid, 'other'))
        spans = [dict(text='  a '), dict(text='猫', italic=True), dict(text='s', italic=True), dict(text='! ')]
        self.assertEqual(compiled_emphasis(spans), (2, 4, 'italic'))
        self.assertIsNone(compiled_emphasis([*spans, dict(text='another run', italic=True)]))
        spans[2]['bold'] = True
        self.assertIsNone(compiled_emphasis(spans))

    def test_real_dump_hash_owner_definition_actions_and_order(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            dump = root / 'wiki-date-pages-meta-current1.xml-p1p3.bz2'
            xml = ET.fromstring('<mediawiki><page><title>word</title><id>1</id><ns>0</ns>'
                                '<revision><id>2</id><text/></revision></page></mediawiki>')
            xml.find('page/revision/text').text = "==French==\n# first\n# [[second]]\n# first\n# prose\n# ''[[chat]]''\n## kitten\n##: example\n##* quotation\n### young kitten"
            dump.write_bytes(bz2.compress(ET.tostring(xml)))
            checksum = hashlib.sha1(dump.read_bytes()).hexdigest()
            member = ['wiki', 'date', dump.name, dump.stat().st_size, checksum]
            manifest = dict(edition='wiki', date='date', build_inputs=dict(files=[member]))
            (root / 'complete.json').write_text(json.dumps(manifest))
            (root / 'languages.tsv').write_text('heading\nFrench\n')
            with self.assertRaisesRegex(ValueError, 'exactly once'):
                SourceDefinitions('', root, [dump, dump])

            def block(kind, display, span_kind='text', **fields):
                return dict(kind=kind, list_path='#', spans=[dict(kind=span_kind, text=display, **fields)])

            blocks = [block('definition', 'first'), block('definition', 'second', 'link', target='second'),
                      block('example', 'first'), block('definition', 'prose', 'external_link', target='elsewhere'),
                      block('definition', 'prose', inline_action_group={'spans': [dict(kind='link', text='hidden', target='wrong')]}),
                      block('definition', 'chat', 'link', target='chat', bold=True),
                      block('definition', 'kitten'), block('definition', 'young kitten')]
            with closing(SourceDefinitions('', root, [dump])) as audit:
                self.assertTrue(audit.has_definitions)
                record = dict(kind='language', title='word', language='English', sections=[dict(blocks=blocks)])
                audit.observe(record)
                self.assertEqual(audit.report()['matched'], 0)
                record['language'] = 'French'
                audit.observe(record)
                report = audit.report()
                self.assertEqual((report['eligible'], report['matched']), (7, 2))
                self.assertEqual([row['line'] for row in report['examples']], [4, 5, 6, 7, 10])
                self.assertEqual(report['examples'][2]['emphasis'], [0, 4, 'italic'])
                self.assertEqual([row['list_path'] for row in report['examples'][-2:]], ['##', '###'])
            with closing(SourceDefinitions('', root, [dump])) as audit:
                # Plain source prose must not match either a spurious style or
                # a combination outside the supported single-emphasis shape.
                first = blocks[0]['spans'][0]
                first.update(bold=True)
                blocks[1]['spans'][0].update(bold=True, italic=True)
                audit.observe(record)
                self.assertEqual(audit.report()['matched'], 0)
                first.update(bold=False)
                blocks[1]['spans'][0].update(bold=False, italic=False)
                audit.observe(record)
                self.assertEqual(audit.report()['matched'], 2)
            registry = root / 'language-registry.tsv'
            registry.write_text('# wikidict-language-registry-v2\n# mediawiki\nfr\tFrench\tFrançais\n')
            manifest['build_inputs']['auxiliary_snapshot_sha256'] = {
                'language-registry': hashlib.sha256(registry.read_bytes()).hexdigest()}
            (root / 'complete.json').write_text(json.dumps(manifest))
            (root / 'languages.tsv').write_text('heading\nUnclassified\n')
            with closing(SourceDefinitions('', root, [dump], registry)) as audit:
                record['language_code'] = 'en'
                audit.observe(record)
                self.assertEqual((audit.report()['eligible'], audit.report()['matched']), (7, 0))
                self.assertIsNone(audit.report()['matched_example'])
                record.update(language='Français', language_code='fr')
                audit.observe(record)
                self.assertEqual(audit.report()['matched'], 2)
                self.assertEqual(audit.report()['matched_example'], dict(exact_title='word', owner_heading='Français',
                                 visible_definition_witness='first', page='1', revision='2', line=2))
                blocks[-3]['spans'][0].update(bold=False, italic=True)
                audit.observe(record)
                self.assertEqual(audit.report()['matched'], 3)
                blocks[-2]['list_path'], blocks[-1]['list_path'] = '##', '###'
                audit.observe(record)
                self.assertEqual(audit.report()['matched'], 5)
            registry.write_text(registry.read_text() + '\n')
            with closing(SourceDefinitions('', root, [dump])) as audit:
                self.assertFalse(audit.has_definitions)
                self.assertEqual(audit.report()['dump_sha1'], {dump.name: checksum})
            with self.assertRaisesRegex(ValueError, 'registry differs'):
                SourceDefinitions('', root, [dump], registry)
            member[-1] = '0' * 40
            (root / 'complete.json').write_text(json.dumps(manifest))
            with self.assertRaisesRegex(ValueError, 'SHA-1 differs'):
                SourceDefinitions('', root, [dump])
