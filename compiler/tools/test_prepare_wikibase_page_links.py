import gzip
import hashlib
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import urllib.parse

import prepare_wikibase_page_links as p
import build_wiktionaries as b


class PageLinksTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.wiki, self.date = 'testwiktionary', '20261001'
        self.folder = self.root / self.wiki / self.date
        self.folder.mkdir(parents=True)
        self.workspace = self.root / 'work'
        self.workspace.mkdir()
        self.namespace = self.root / 'namespace-registry.tsv'
        self.namespace.write_text(
            '# wikidict-namespace-registry-v1\n# wiki\ttestwiktionary\n# dump-date\t20261001\n'
            '# content-language\ten\n'
            '0\t\t\tfirst-letter\t0\t1\t0\t\tmain\tdictionary_entries\n'
            '4\tProject\tProject\tfirst-letter\t1\t0\t0\t\tcompile_only\tstandard_build_input\n')
        self.items = []

    def sql(self, table, columns, values):
        def quoted(value):
            if value is None:
                return 'NULL'
            if isinstance(value, int):
                return str(value)
            return "'" + value.replace('\\', '\\\\').replace("'", "\\'") + "'"
        text = 'CREATE TABLE `' + table + '` (\n'
        text += ''.join('  `' + field + '` text,\n' for field in columns)
        text += ') ENGINE=InnoDB;\n'
        if values:
            text += 'INSERT INTO `' + table + '` VALUES '
            text += ','.join('(' + ','.join(map(quoted, row)) + ')' for row in values) + ';\n'
        name = self.wiki + '-' + self.date + '-' + table + '.sql.gz'
        path = self.folder / name
        path.write_bytes(gzip.compress(text.encode(), mtime=0))
        item = dict(wiki=self.wiki, date=self.date, name=name,
                    url='https://dumps.wikimedia.org/' + self.wiki + '/' + self.date + '/' + name,
                    size=path.stat().st_size, sha1=hashlib.sha1(path.read_bytes()).hexdigest())
        self.items = [old for old in self.items if old['name'] != name] + [item]
        return path

    def properties(self, values=()):
        return self.sql('page_props', ['pp_page', 'pp_propname', 'pp_value', 'pp_sortkey'],
                        [(key, prop, value, None) for key, prop, value in values])

    def pages(self, values=((7, 0, 'Example'),)):
        return self.sql('page', ['page_id', 'page_namespace', 'page_title'], values)

    def observe(self, key=7, title='Example', entity=None):
        source = self.folder / (self.wiki + '-' + self.date + '-page_props.sql.gz')
        out = self.root / 'observed'
        out.mkdir()
        params = p.expected_params(self.wiki, title)
        url = 'https://www.wikidata.org/w/api.php?' + urllib.parse.urlencode(params)
        request = dict(method='GET', url=url, params=params, wiki=self.wiki, date=self.date,
                       page_id=key, title=title,
                       inputs=dict(namespace=dict(sha256=p.digest(self.namespace.read_bytes())),
                                   page_props=dict(sha256=p.digest(source.read_bytes()))))
        result = {'-1':dict(site=self.wiki, title=title, missing='')} if entity is None else {entity:dict(id=entity)}
        raw = p.document(dict(entities=result, success=1))
        receipt = dict(url=url, final_url=url, status=200, outcome='passed', source_guard=True,
                       started_utc='2026-10-05T19:00:00+00:00', ended_utc='2026-10-05T19:00:01+00:00',
                       result_entity_id=entity, response=dict(sha256=p.digest(raw), bytes=len(raw)))
        (out / 'request.json').write_bytes(p.document(request))
        (out / 'response.raw.json').write_bytes(raw)
        (out / 'http-receipt.json').write_bytes(p.document(receipt))
        return p.create_supplement([out], self.items, self.namespace, self.root / 'capture')

    def prepare(self, supplement=None):
        return p.prepare_from_dumps(self.items, self.root, self.namespace, self.workspace, supplement)

    def test_wire_distinguishes_explicit_negative_from_absent_coverage(self):
        raw = p.wire({9:None, 2:'Q2147483647'})
        self.assertEqual(raw, p.HEADER + b'2\tQ2147483647\n9\t-\n# end\t2\n')
        values = p.read_wire(raw)
        self.assertIsNone(values[9])
        self.assertNotIn(3, values)

    def test_wire_rejects_malformed_order_duplicates_bounds_and_truncation(self):
        invalid = [
            b'2\tQ1\n1\tQ2\n# end\t2\n',
            b'2\tQ1\n2\tQ1\n# end\t2\n',
            b'0\tQ1\n# end\t1\n',
            b'01\tQ1\n# end\t1\n',
            b'1\tQ2147483648\n# end\t1\n',
            b'1\tQ01\n# end\t1\n',
            b'1\t\n# end\t1\n',
            b'1\tQ1\n',
            b'1\tQ1\n# end\t0\n',
            b'# end\t0\ntrailing\n',
        ]
        for body in invalid:
            with self.subTest(body=body), self.assertRaises(ValueError):
                p.read_wire(p.HEADER + body)
        with self.assertRaises(ValueError):
            p.read_wire(p.wire({1:'Q1'})[:-1])

    def test_sql_retains_all_positive_rows_without_inventing_negatives(self):
        self.properties([(9, 'wikibase_item', 'Q2'), (7, 'defaultsort', 'Example'),
                         (2, 'wikibase_item', 'Q1')])
        output = self.prepare()
        self.assertEqual(p.read_wire(output.read_bytes()), {2:'Q1', 9:'Q2'})
        self.assertNotIn(7, p.read_wire(output.read_bytes()))
        proof = json.loads((output.parent / 'complete.json').read_bytes())
        self.assertEqual((proof['source_rows'], proof['sql_positive_rows'], proof['explicit_negative_rows']), (3, 2, 0))

    def test_complete_empty_sql_has_zero_covered_rows(self):
        self.properties()
        self.assertEqual(self.prepare().read_bytes(), p.HEADER + b'# end\t0\n')

    def test_xml_only_custom_input_does_not_install_false_provider(self):
        self.assertIsNone(p.prepare_from_dumps([dict(wiki=self.wiki, date=self.date, name='dump.xml')],
                                             self.root, self.namespace, self.workspace))

    def test_duplicate_or_invalid_positive_sql_fails(self):
        for values in [[(1, 'wikibase_item', 'Q1'), (1, 'wikibase_item', 'Q2')],
                       [(1, 'wikibase_item', 'Q2147483648')],
                       [(1, 'wikibase_item', None)]]:
            with self.subTest(values=values):
                self.properties(values)
                with self.assertRaises(ValueError):
                    self.prepare()

    def test_truncated_sql_never_creates_completion(self):
        path = self.properties([(1, 'wikibase_item', 'Q1')])
        path.write_bytes(gzip.compress(gzip.decompress(path.read_bytes()).rstrip()[:-1], mtime=0))
        self.items[0].update(size=path.stat().st_size, sha1=hashlib.sha1(path.read_bytes()).hexdigest())
        with self.assertRaises(ValueError):
            self.prepare()
        self.assertFalse((self.workspace / 'derived-page-links/complete.json').exists())

    def test_verified_cache_reuses_projection_without_sql_reparse(self):
        self.properties([(2, 'wikibase_item', 'Q1')])
        output = self.prepare()
        before = output.stat().st_mtime_ns
        with patch.object(p, 'rows', side_effect=AssertionError('unexpected SQL replay')):
            self.assertEqual(self.prepare(), output)
        self.assertEqual(output.stat().st_mtime_ns, before)

    def test_changed_sql_is_rejected_before_derived_cache_reuse(self):
        path = self.properties([(2, 'wikibase_item', 'Q1')])
        self.prepare()
        raw = bytearray(path.read_bytes())
        raw[-1] ^= 1
        path.write_bytes(raw)
        with self.assertRaisesRegex(ValueError, 'Unverified page-link SQL input'):
            self.prepare()

    def test_atomic_sql_replacement_during_hash_is_rejected(self):
        path = self.properties([(2, 'wikibase_item', 'Q1')])
        original = hashlib.sha1
        replaced = []
        class SwappingHash:
            def __init__(inner):inner.hash = original()
            def update(inner, chunk):
                inner.hash.update(chunk)
                if not replaced:
                    other = path.with_name('replacement.gz')
                    other.write_bytes(path.read_bytes())
                    os.replace(other, path)
                    replaced.append(True)
            def hexdigest(inner):return inner.hash.hexdigest()
        with patch.object(p.hashlib, 'sha1', SwappingHash):
            with self.assertRaisesRegex(ValueError, 'changed while hashing'):
                self.prepare()
        self.assertTrue(replaced)

    def test_changed_projection_is_rebuilt_from_verified_sql(self):
        self.properties([(2, 'wikibase_item', 'Q1')])
        output = self.prepare()
        output.write_bytes(p.wire({2:None}))
        self.assertEqual(p.read_wire(self.prepare().read_bytes()), {2:'Q1'})

    def test_exact_negative_supplement_adds_only_its_observed_page(self):
        self.properties([(2, 'wikibase_item', 'Q1')])
        self.pages()
        supplement = self.observe()
        output = self.prepare(supplement)
        self.assertEqual(p.read_wire(output.read_bytes()), {2:'Q1', 7:None})
        self.assertNotIn(8, p.read_wire(output.read_bytes()))
        with patch.object(p, 'rows', side_effect=AssertionError('unexpected replay')):
            self.assertEqual(self.prepare(supplement), output)

    def test_positive_sql_precedes_repository_fallback(self):
        self.properties([(7, 'wikibase_item', 'Q1')])
        self.pages()
        output = self.prepare(self.observe())
        self.assertEqual(p.read_wire(output.read_bytes()), {7:'Q1'})
        self.assertEqual(json.loads((output.parent/'complete.json').read_bytes())['repository_rows_shadowed_by_sql'], [7])

    def test_repository_title_must_match_pinned_page_id(self):
        self.properties()
        self.pages(((7, 0, 'Different'),))
        supplement = self.observe()
        with self.assertRaisesRegex(ValueError, 'pinned page ID/title'):
            self.prepare(supplement)

    def test_unknown_supplement_page_id_is_not_negative_coverage(self):
        self.properties()
        self.pages(((8, 0, 'Example'),))
        with self.assertRaisesRegex(ValueError, 'page ID absent'):
            self.prepare(self.observe())

    def test_localized_namespace_and_underscores_bind_exact_title(self):
        self.properties()
        self.pages(((7, 4, 'Example_page'),))
        output = self.prepare(self.observe(title='Project:Example page', entity='Q42'))
        self.assertEqual(p.read_wire(output.read_bytes()), {7:'Q42'})

    def test_capture_replay_rejects_mutated_raw_response_even_if_inventory_rehashed(self):
        self.properties()
        self.pages()
        supplement = self.observe()
        manifest_path = supplement.with_name(p.NAME + '.manifest.json')
        manifest = p.parse(manifest_path.read_bytes())
        name = p.NAME + '.0001.raw.json'
        raw = p.document(dict(entities={'Q42':dict(id='Q42')}, success=1))
        supplement.with_name(name).write_bytes(raw)
        manifest['artifacts'][name] = p.digest(raw)
        manifest_path.write_bytes(p.document(manifest))
        with self.assertRaisesRegex(ValueError, 'HTTP receipt changed'):
            p.validate_snapshot(supplement)

    def test_capture_rejects_wrong_namespace_and_different_sql_date(self):
        self.properties()
        self.pages()
        supplement = self.observe()
        with self.assertRaises(ValueError):
            p.validate_snapshot(supplement, 'otherwiktionary', self.date)
        self.items[0]['sha1'] = '0'*40
        with self.assertRaisesRegex(ValueError, 'another selected SQL input'):
            self.prepare(supplement)

    def test_pinned_supplement_preserves_full_replay_and_runtime_override(self):
        self.properties()
        self.pages()
        supplement = self.observe()
        snapshots = {p.NAME:supplement}
        hashes = b.verified_auxiliary_hashes(snapshots, self.wiki, self.date)
        pinned = b.pinned_auxiliary_snapshots(snapshots, hashes, self.root/'pins')
        self.assertEqual(p.capture_artifacts(pinned[p.NAME]), p.capture_artifacts(supplement))
        derived = self.prepare(supplement)
        argv = b.pipeline_snapshot_args(self.namespace, pinned, derived)
        pos = argv.index('--wikibase-page-links-snapshot')
        self.assertEqual(argv[pos+1], str(derived))
        self.assertEqual(pinned[p.NAME].read_bytes(), supplement.read_bytes())

    def test_expander_reuse_checks_derived_bytes_instead_of_supplement_projection(self):
        root = self.root/'expander'
        target = root/'.bundle-expander'
        target.mkdir(parents=True)
        (root/'.incomplete').write_text('expander ready')
        for name in ('page-index.tsv', 'dict-bundle-expander', 'namespace-registry.tsv'):
            (target/name).write_bytes(b'fixture')
        raw = p.wire({1:'Q1', 7:None})
        (target/(p.NAME+'.tsv')).write_bytes(raw)
        original = {p.NAME:'a'*64}
        self.assertTrue(b.expander_ready(root, original, None, p.digest(raw)))
        self.assertFalse(b.expander_ready(root, {}, None, None))
        (target/(p.NAME+'.tsv')).write_bytes(p.wire({7:None}))
        self.assertFalse(b.expander_ready(root, original, None, p.digest(raw)))


if __name__ == '__main__':
    unittest.main()
