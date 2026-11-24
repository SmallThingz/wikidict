"""Revision-selected exterior observations are independent of language, styles and body provenance."""
import copy
import gzip
import hashlib
import json
from pathlib import Path
import tempfile
import unittest

import page_language_snapshot as language


class RevisionExteriorTests(unittest.TestCase):
    def setUp(self):
        data = Path(__file__).with_name('testdata')
        self.namespace = data / 'hy-kheght62' / 'namespace-registry.tsv'
        # The HTML and request bytes are original. The fixture receipt headers
        # retain Date and Content-Type. The full local receipts, including the
        # original transport headers, have these SHA-256 digests in page order:
        # 4ecbe679c400ba9e50f8305c5802af01c60bfb1b415f104e8b796d08c55853ad
        # 2724701c60fa8b612a18d30ff7f0c8ce2bd28557b16f69ac5cd5102d8eb94d2a
        fixture = data / 'hy-revision-exteriors' / 'revision-exteriors.json.gz'
        self.index_bytes = gzip.decompress(fixture.read_bytes())
        self.index = json.loads(self.index_bytes)
        self.row = self.index['revision_exteriors'][0]

    def test_genuine_bodies_and_original_page_sources(self):
        data = self.namespace.parent.parent
        sources = [
            ('hy-kheght62/raw.wikitext', 'hy-kheght62/expanded.wikitext', 43532),
            ('hy-empty-audit/02.raw.wikitext', 'hy-empty-audit/02.expanded.wikitext', 46227),
        ]
        for row, (raw, expanded, prefix_end) in zip(self.index['revision_exteriors'], sources, strict=True):
            self.assertEqual(row['page']['raw_sha256'], hashlib.sha256((data / raw).read_bytes()).hexdigest())
            self.assertEqual(row['page']['expanded_sha256'], hashlib.sha256((data / expanded).read_bytes()).hexdigest())
            self.assertEqual(row['prefix_bytes'], prefix_end)
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / language.SNAPSHOT).write_bytes(self.index_bytes)
            (root / language.RAW).write_bytes(b'')
            packed = language.pack_snapshot(root / language.SNAPSHOT, self.namespace, root / 'packed',
                                            wiki='hywiktionary', date='20261001')
            manifest, members = language.validated_capture(packed, 'hywiktionary', '20261001')
            self.assertEqual(manifest['record_count'], 2)
            self.assertEqual(packed.read_bytes(), self.index_bytes)
            self.assertEqual(set(members), {language.SNAPSHOT, language.RAW, language.MANIFEST})

    def test_rejects_changed_transport_page_and_static_source(self):
        for field, value in [('final_url', 'https://hy.wiktionary.org/wiki/other'),
                             ('accepted', False), ('status', 302), ('response_bytes', 2),
                             ('response_sha256', '0' * 64), ('headers', {'Content-Type': 'application/json'})]:
            with self.subTest(field=field):
                index = copy.deepcopy(self.index)
                row = index['revision_exteriors'][0]
                receipt = json.loads(row['receipt'])
                receipt[field] = value
                row['receipt'] = json.dumps(receipt)
                with self.assertRaises(ValueError):
                    language._revision_exteriors(index)
        for field, value in [('id', 99), ('revision', 123), ('namespace', 1), ('title', 'wrong')]:
            with self.subTest(field=field):
                index = copy.deepcopy(self.index)
                index['revision_exteriors'][0]['page'][field] = value
                with self.assertRaises(ValueError):
                    language._revision_exteriors(index)
        for old, changed in [('hywiktionarymwclientpreferences', 'hzwiktionarymwclientpreferences'),
                             ('MediaWiki 1.48.0-wmf.5', 'MediaWiki 1.48.0-wmf.6'),
                             ('</html>', '</htmx>')]:
            with self.subTest(old=old):
                index = copy.deepcopy(self.index)
                row = index['revision_exteriors'][0]
                self.assertIn(old, row['response'])
                row['response'] = row['response'].replace(old, changed, 1)
                receipt = json.loads(row['receipt'])
                receipt['response_sha256'] = hashlib.sha256(row['response'].encode()).hexdigest()
                row['receipt'] = json.dumps(receipt)
                with self.assertRaises(ValueError):
                    language._revision_exteriors(index)

    def test_refuses_ambiguous_pages_boundaries_and_foreign_authority(self):
        for offset in (-1, 1):
            with self.subTest(offset=offset):
                index = copy.deepcopy(self.index)
                index['revision_exteriors'][0]['prefix_bytes'] += offset
                with self.assertRaises(ValueError):
                    language._revision_exteriors(index)
        self.index['revision_exteriors'].reverse()
        with self.assertRaises(ValueError):
            language._revision_exteriors(self.index)
        self.index['revision_exteriors'].reverse()
        self.index['records'] = [{'page': dict(self.row['page'], raw_sha256='0' * 64)}]
        with self.assertRaises(ValueError):
            language._revision_exteriors(self.index)
        self.index['records'][0]['page']['raw_sha256'] = self.row['page']['raw_sha256']
        self.assertEqual(language._revision_exteriors(self.index), 2)
        self.index['wiki'] = 'srwiktionary'
        with self.assertRaises(ValueError):
            language._revision_exteriors(self.index)
