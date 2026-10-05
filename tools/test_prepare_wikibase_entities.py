import contextlib
import copy
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import Mock, patch
import urllib.parse

import prepare_wikibase_entities as entities


def entity(entity_id, **fields):
    kind = {'L': 'lexeme', 'Q': 'item', 'P': 'property'}[entity_id[0]]
    value = dict(pageid=1, ns=146 if kind == 'lexeme' else 0, title=entity_id,
                 lastrevid=100, modified='2026-10-05T09:00:00Z', id=entity_id,
                 type=kind, claims={}, labels={}, descriptions={}, aliases={}, sitelinks={})
    if kind == 'lexeme':
        value.update(lemmas={'ar': {'language': 'ar', 'value': 'كتب'}},
                     language='Q13955', lexicalCategory='Q24905', forms=[], senses=[])
    value.update(fields)
    return value


def claim(target, rank='normal'):
    return dict(rank=rank, mainsnak=dict(snaktype='value', datatype='wikibase-lexeme' if target[0] == 'L' else 'wikibase-item',
        datavalue=dict(type='wikibase-entityid', value={'id': target})), qualifiers={})


class WikibaseCaptureTests(unittest.TestCase):
    wiki = 'arwiktionary'
    date = '20261001'

    def prepare(self, root, ids=('L1',)):
        root.mkdir()
        raw = entities.document({'query': {'general': {'wikiid': self.wiki, 'lang': 'ar'}}})
        (root / 'namespace-siteinfo.raw.json').write_bytes(raw)
        (root / 'capture.complete.json').write_bytes(entities.document(dict(wiki=self.wiki, date=self.date,
            artifacts={'namespace-siteinfo.raw.json': entities.digest(raw)})))
        seeds = root / 'seeds.json'
        seeds.write_bytes(entities.document(dict(schema='wikidict-wikibase-seeds-v1',
            wiki=self.wiki, date=self.date, reason='Pinned fixture literal entity IDs', ids=list(ids))))
        return seeds

    def data(self):
        return {
            'L1': entity('L1', claims={'P5920': [claim('L2')], 'P9295': [claim('Q3')],
                                      'P5186': [claim('Q999')]},
                forms=[{'id': 'L1-F1', 'representations': {'ar': {'language': 'ar', 'value': 'كتابة'}},
                        'grammaticalFeatures': ['Q1350145'], 'claims': {}}]),
            'L2': entity('L2', lemmas={'ar': {'language': 'ar', 'value': 'ك ت ب'}},
                         claims={'P5920': [claim('L888')]}),
            'Q3': entity('Q3', labels={'mul': {'language': 'mul', 'value': 'shared'},
                                      'en': {'language': 'en', 'value': 'English label'}},
                         descriptions={'en': {'language': 'en', 'value': 'English description'}}),
        }

    def fetcher(self, data=None, transform=None):
        records = data if data is not None else self.data()
        calls = []
        def fetch(url):
            params = urllib.parse.parse_qs(urllib.parse.urlsplit(url).query)
            ids = params['ids'][0].split('|')
            mode = 'terms' if 'languages' in params else 'full'
            calls.append((mode, ids))
            values = {}
            for requested in ids:
                full = copy.deepcopy(records.get(requested))
                if full is None:
                    values[requested] = {'id': requested, 'missing': True}
                    continue
                if full['id'] != requested:
                    full['redirects'] = {'from': requested, 'to': full['id']}
                if mode == 'terms':
                    result = {key: full[key] for key in ('id', 'lastrevid', 'modified', 'redirects') if key in full}
                    for field in ('labels', 'descriptions'):
                        selected = next((full.get(field, {}).get(lang) for lang in ('ar', 'mul', 'en')
                                         if full.get(field, {}).get(lang)), None)
                        result[field] = {'ar': dict(selected, **{'for-language': 'ar'})} if selected else {}
                    full = result
                values[requested] = full
            result = {'success': 1, 'entities': values}
            if transform:
                result = transform(result, mode, ids)
            raw = entities.document(result)
            return raw, dict(source_url=url, response_url=url, status=200,
                started_utc='2026-10-05T09:01:00+00:00', retrieved_utc='2026-10-05T09:01:01+00:00',
                raw_bytes=len(raw), raw_sha256=entities.digest(raw))
        fetch.calls = calls
        return fetch

    def capture(self, root, ids=('L1',), fetcher=None):
        seeds = self.prepare(root, ids)
        with contextlib.redirect_stdout(io.StringIO()):
            result = entities.capture_snapshot(root, self.wiki, self.date, seeds, fetcher=fetcher or self.fetcher())
        return result, seeds

    def rebind(self, root, name, raw):
        path = root / name
        path.chmod(0o644)
        path.write_bytes(raw)
        for snapshot in entities.NAMES:
            p = root / (snapshot + '.manifest.json')
            manifest = json.loads(p.read_bytes())
            manifest['artifacts'][name] = entities.digest(raw)
            if name == snapshot + '.tsv':
                manifest.update(output_sha256=entities.digest(raw), output_bytes=len(raw))
            p.chmod(0o644)
            p.write_bytes(entities.document(manifest))

    def test_complete_lexeme_payload_and_only_proven_one_hop_dependencies(self):
        with tempfile.TemporaryDirectory() as tmp:
            fetch = self.fetcher()
            (manifest, created), _ = self.capture(Path(tmp) / 'capture', fetcher=fetch)
            self.assertTrue(created)
            self.assertEqual(manifest['seed_count'], 1)
            self.assertEqual(manifest['entity_count'], 3)
            self.assertEqual(fetch.calls, [('full', ['L1']), ('full', ['L2', 'Q3']), ('terms', ['Q3'])])
            root = Path(tmp) / 'capture' / entities.DIRECTORY
            rows = [line.split('\t') for line in (root / 'wikibase-entities.tsv').read_text().splitlines() if not line.startswith('#')]
            payload = json.loads(next(row[3] for row in rows if row[0] == 'L1'))
            self.assertEqual(payload['schemaVersion'], 2)
            self.assertEqual(payload['forms'][0]['representations']['ar']['value'], 'كتابة')
            self.assertEqual(payload['forms'][0]['claims'], {})
            self.assertEqual(payload['claims']['P5920'][0]['qualifiers'], {})
            self.assertNotIn('labels', payload)
            self.assertNotIn('lastrevid', payload)
            self.assertNotIn('forms', json.loads(next(row[3] for row in rows if row[0] == 'L2')))
            term_rows = [line.split('\t') for line in (root / 'wikibase-entity-terms.tsv').read_text().splitlines() if not line.startswith('#')]
            terms = json.loads(next(row[3] for row in term_rows if row[0] == 'Q3'))
            self.assertEqual(terms['label'], {'value': 'shared', 'language': 'mul'})
            self.assertEqual(terms['description'], {'value': 'English description', 'language': 'en'})
            self.assertNotIn('for-language', terms['label'])
            self.assertEqual(entities.validate_snapshot(root), manifest)

    def test_explicit_missing_and_verified_redirect_are_distinct_from_uncaptured(self):
        with tempfile.TemporaryDirectory() as tmp:
            data = {'L1': entity('L9')}
            (manifest, _), _ = self.capture(Path(tmp) / 'capture', ('L1', 'L404'), self.fetcher(data))
            self.assertEqual(manifest['missing_count'], 1)
            text = (Path(tmp) / 'capture' / entities.DIRECTORY / 'wikibase-entities.tsv').read_text()
            self.assertIn('L1\tE\tL9\t', text)
            self.assertIn('L404\tM\t\t\n', text)
            self.assertNotIn('L999\t', text)

    def test_reuse_and_verification_are_offline_and_immutable(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / 'capture'
            (manifest, _), seeds = self.capture(root)
            output = root / entities.DIRECTORY
            before = {p.name: (p.read_bytes(), p.stat().st_mtime_ns) for p in output.iterdir()}
            fetch = Mock(side_effect=AssertionError('No API on reuse'))
            self.assertEqual(entities.capture_snapshot(root, self.wiki, self.date, seeds, fetcher=fetch), (manifest, False))
            self.assertEqual(entities.validate_snapshot(output), manifest)
            self.assertEqual(set(entities.capture_artifacts(output)), set(before))
            self.assertEqual(before, {p.name: (p.read_bytes(), p.stat().st_mtime_ns) for p in output.iterdir()})
            fetch.assert_not_called()
            self.assertEqual(manifest['temporal_scope'], 'current-at-retrieval')
            self.assertNotEqual(manifest['retrieved_utc'][:10].replace('-', ''), manifest['date'])

    def test_partial_missing_or_error_response_does_not_publish(self):
        cases = (
            lambda result, mode, ids: {'success': 1, 'entities': {}},
            lambda result, mode, ids: dict(result, warnings={'unexpected': 'partial'}),
            lambda result, mode, ids: dict(result, error={'code': 'maxlag'}),
        )
        for transform in cases:
            with self.subTest(transform=transform), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp) / 'capture'
                seeds = self.prepare(root)
                with self.assertRaises(ValueError), contextlib.redirect_stdout(io.StringIO()):
                    entities.capture_snapshot(root, self.wiki, self.date, seeds, fetcher=self.fetcher(transform=transform))
                partial = root / entities.DIRECTORY
                self.assertFalse((partial / 'wikibase-entities.manifest.json').exists())
                self.assertTrue((partial / 'wikibase-request-000001.raw.json').is_file())
                with self.assertRaises(ValueError):
                    entities.validate_snapshot(partial)

    def test_default_terms_revision_drift_is_rejected(self):
        def drift(result, mode, ids):
            if mode == 'terms':
                result['entities']['Q3']['lastrevid'] += 1
            return result
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaisesRegex(ValueError, 'changed'):
                self.capture(Path(tmp) / 'capture', fetcher=self.fetcher(transform=drift))

    def test_redirect_without_proof_and_duplicate_json_keys_are_rejected(self):
        raw = entities.document({'success': 1, 'entities': {'L1': entity('L9')}})
        with self.assertRaisesRegex(ValueError, 'redirect'):
            entities.response_records(raw, ['L1'], 'full')
        with self.assertRaisesRegex(ValueError, 'Duplicate'):
            entities.parse_json(b'{"entities":{},"entities":{}}')
        with self.assertRaises(ValueError):
            entities.parse_json(b'{"x":NaN}')

    def test_snapshot_tampering_is_rejected_even_after_hashes_are_rebound(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.capture(Path(tmp) / 'capture')
            root = Path(tmp) / 'capture' / entities.DIRECTORY
            name = 'wikibase-entities.tsv'
            self.rebind(root, name, (root / name).read_bytes().replace('كتابة'.encode(), 'غير'.encode()))
            with self.assertRaisesRegex(ValueError, 'replay'):
                entities.validate_snapshot(root)

    def test_missing_provenance_or_pair_manifest_is_rejected(self):
        for name in ('wikibase-request-000001.raw.json', 'wikibase-entity-terms.manifest.json'):
            with self.subTest(name=name), tempfile.TemporaryDirectory() as tmp:
                self.capture(Path(tmp) / 'capture')
                root = Path(tmp) / 'capture' / entities.DIRECTORY
                (root / name).unlink()
                with self.assertRaises(ValueError):
                    entities.validate_snapshot(root)

    def test_foreign_identity_wrong_profile_and_unsafe_artifact_are_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.capture(Path(tmp) / 'capture')
            root = Path(tmp) / 'capture' / entities.DIRECTORY
            with self.assertRaises(ValueError):
                entities.validate_snapshot(root, 'dewiktionary', self.date)
            p = root / 'wikibase-entities.manifest.json'
            record = json.loads(p.read_bytes())
            record['profile'] = 'guessed-profile'
            p.chmod(0o644)
            p.write_bytes(entities.document(record))
            with self.assertRaises(ValueError):
                entities.validate_snapshot(root)

    def test_seed_schema_counts_and_closure_bound_are_enforced(self):
        with tempfile.TemporaryDirectory() as tmp:
            with patch.object(entities, 'MAX_ENTITIES', 2), self.assertRaisesRegex(ValueError, 'closure'):
                self.capture(Path(tmp) / 'capture')
        with self.assertRaises(ValueError):
            entities.seed_ids({'schema': 'wikidict-wikibase-seeds-v1', 'wiki': self.wiki,
                'date': self.date, 'reason': 'literal', 'ids': ['L1', 'L1']}, self.wiki, self.date)
        with self.assertRaises(ValueError):
            entities.valid_id('l1')

    def test_literal_seed_dump_is_bound_to_namespace_capture(self):
        source = dict(wiki=self.wiki, date=self.date, name='dump.xml.bz2',
                      url='https://dumps.wikimedia.org/example', size=123, sha1='a' * 40)
        proof = dict(schema='wikidict-arabic-wikibase-direct-seed-audit-v1', dump=source,
            dump_sha1_verified=True, mainspace_entity_ids=['L1'], mainspace_entity_count=1,
            mainspace_invocation_count=1, all_namespace_proofs=[dict(namespace_id=0,
                source_sha256='b' * 64, page_id='1', revision_id='2', entity_id='L1',
                argument='L1', invocation='{{صندوق معلومات فعل|L1}}')])
        self.assertEqual(entities.validate_seed_source(proof, {'source_xml': source}, self.wiki, self.date), ['L1'])
        changed = dict(source, sha1='c' * 40)
        with self.assertRaisesRegex(ValueError, 'source differs'):
            entities.validate_seed_source(proof, {'source_xml': changed}, self.wiki, self.date)

    def test_changed_request_query_and_conflicting_alias_revisions_are_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.capture(Path(tmp) / 'capture')
            root = Path(tmp) / 'capture' / entities.DIRECTORY
            name = 'wikibase-request-000001.request.json'
            receipt = json.loads((root / name).read_bytes())
            receipt['source_url'] += '&languages=en'
            self.rebind(root, name, entities.document(receipt))
            with self.assertRaisesRegex(ValueError, 'URL'):
                entities.validate_snapshot(root)
        with tempfile.TemporaryDirectory() as tmp:
            data = {'L1': entity('L9'), 'L2': entity('L9', lastrevid=101)}
            with self.assertRaisesRegex(ValueError, 'Conflicting revisions'):
                self.capture(Path(tmp) / 'capture', ('L1', 'L2'), self.fetcher(data))

    def test_unknown_entity_type_invalid_revision_and_oversize_are_rejected(self):
        full = entity('L1')
        for field, value in (('type', 'item'), ('lastrevid', 0), ('modified', 'yesterday')):
            invalid = dict(full, **{field: value})
            with self.subTest(field=field), self.assertRaises(ValueError):
                entities.response_records(entities.document({'success': 1, 'entities': {'L1': invalid}}), ['L1'], 'full')
        with patch.object(entities, 'MAX_ENTITY_BYTES', 16), self.assertRaises(ValueError):
            entities.response_records(entities.document({'success': 1, 'entities': {'L1': full}}), ['L1'], 'full')



    def test_verified_replay_reuses_exact_bytes_but_returns_fresh_manifests(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / 'capture'
            self.capture(root)
            folder = root / entities.DIRECTORY
            entities._VALIDATED_REPLAY_KEYS.clear()
            with patch.object(entities, 'replay', wraps=entities.replay) as replay:
                first = entities.validate_snapshot(folder / 'wikibase-entities.tsv', self.wiki, self.date)
                original = copy.deepcopy(first)
                first['artifacts'].clear()
                first['content_language'] = 'caller mutation'
                second = entities.validate_snapshot(folder / 'wikibase-entities.tsv', self.wiki, self.date)
                other = entities.validate_snapshot(folder / 'wikibase-entity-terms.tsv', self.wiki, self.date)
                self.assertEqual(second, original)
                self.assertEqual(other['name'], 'wikibase-entity-terms')
                self.assertEqual(replay.call_count, 1)

    def test_verified_replay_still_reads_and_hashes_every_bound_artifact(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / 'capture'
            self.capture(root)
            folder = root / entities.DIRECTORY
            manifest = entities.validate_snapshot(folder)
            raw_path = folder / next(name for name in manifest['artifacts']
                                     if name.endswith('.raw.json') and name.startswith('wikibase-request-'))
            raw_path.chmod(0o644)
            raw_path.write_bytes(raw_path.read_bytes() + b' ')
            with self.assertRaisesRegex(ValueError, 'Changed entity capture artifact'):
                entities.validate_snapshot(folder)

    def test_rebound_raw_response_cannot_reuse_an_older_replay(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / 'capture'
            self.capture(root)
            folder = root / entities.DIRECTORY
            manifest = entities.validate_snapshot(folder)
            row = next(row for row in manifest['requests'] if row['mode'] == 'full')
            raw = json.loads((folder / row['response']).read_bytes())
            raw['entities']['L1']['lemmas']['ar']['value'] = 'changed lemma'
            changed = entities.document(raw)
            self.rebind(folder, row['response'], changed)
            request = json.loads((folder / row['request']).read_bytes())
            request.update(raw_sha256=entities.digest(changed), raw_bytes=len(changed))
            self.rebind(folder, row['request'], entities.document(request))
            with patch.object(entities, 'replay', wraps=entities.replay) as replay:
                with self.assertRaisesRegex(ValueError, 'Entity projection differs from exact offline replay'):
                    entities.validate_snapshot(folder)
                self.assertEqual(replay.call_count, 1)

    def test_rebound_projection_and_paired_manifest_cannot_reuse_replay(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / 'capture'
            self.capture(root)
            folder = root / entities.DIRECTORY
            entities.validate_snapshot(folder)
            name = 'wikibase-entity-terms.tsv'
            self.rebind(folder, name, (folder / name).read_bytes() + b'forged\t{}\n')
            with self.assertRaisesRegex(ValueError, 'Entity projection differs from exact offline replay'):
                entities.validate_snapshot(folder / 'wikibase-entities.tsv')

    def test_reused_capture_keeps_identity_and_symlink_checks(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / 'capture'
            self.capture(root)
            folder = root / entities.DIRECTORY
            manifest = entities.validate_snapshot(folder)
            with self.assertRaisesRegex(ValueError, 'edition/date mismatch'):
                entities.validate_snapshot(folder, 'enwiktionary', self.date)
            raw_path = folder / next(name for name in manifest['artifacts']
                                     if name.endswith('.raw.json') and name.startswith('wikibase-request-'))
            copied = root / 'same-bytes.json'
            copied.write_bytes(raw_path.read_bytes())
            raw_path.chmod(0o644)
            raw_path.unlink()
            raw_path.symlink_to(copied.resolve())
            with self.assertRaisesRegex(ValueError, 'Missing, unsafe or oversized'):
                entities.validate_snapshot(folder)

    def test_verified_replay_respects_changed_entity_bounds(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / 'capture'
            self.capture(root)
            folder = root / entities.DIRECTORY
            entities.validate_snapshot(folder)
            for bound in ('MAX_ENTITIES', 'MAX_ENTITY_BYTES'):
                with self.subTest(bound=bound), patch.object(entities, bound, 1):
                    with self.assertRaises(ValueError):
                        entities.validate_snapshot(folder)

if __name__ == '__main__':
    unittest.main()
