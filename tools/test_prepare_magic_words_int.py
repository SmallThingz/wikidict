import copy
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import prepare_magic_words as legacy
import prepare_magic_words_int as magic


class IntMagicWordCaptureTests(unittest.TestCase):
    wiki = 'bgwiktionary'
    date = '20261001'

    def response(self):
        return {'query': {'general': {'wikiid': self.wiki, 'lang': 'bg'},
            'magicwords': [
                *[{'name': name, 'case-sensitive': False, 'aliases': [name.upper()]}
                  for name in sorted(legacy.SUPPORTED | legacy.PARSER_FUNCTIONS)],
                {'name': 'int', 'case-sensitive': False, 'aliases': ['ВЪТР:', 'INT:']},
            ]}}

    def fixture(self, root, data=None):
        root.mkdir()
        namespace = legacy.document({'query': {'general': {'wikiid': self.wiki, 'lang': 'bg'}}})
        (root / 'namespace-siteinfo.raw.json').write_bytes(namespace)
        (root / 'capture.complete.json').write_bytes(legacy.document({
            'wiki': self.wiki, 'date': self.date,
            'artifacts': {'namespace-siteinfo.raw.json': legacy.digest(namespace)}}))
        raw = legacy.document(self.response() if data is None else data)
        def fetch(url):
            return raw, dict(source_url=url, response_url=url, status=200,
                started_utc='2026-10-05T06:00:00+00:00',
                retrieved_utc='2026-10-05T06:00:01+00:00',
                raw_sha256=legacy.digest(raw), raw_bytes=len(raw))
        # The only capture call is a hermetic fixture with injected saved bytes.
        with patch.object(legacy, 'fetch_response', side_effect=AssertionError('Network forbidden')):
            legacy.capture_snapshot(root, self.wiki, self.date, fetcher=fetch)
        return root / 'magic-words'

    def contents(self, root):
        return {p.name: (p.read_bytes(), p.stat().st_mtime_ns) for p in root.iterdir()}

    def blobs(self, root):
        return {name: legacy.read_regular(root / name) for name in magic.ARTIFACTS}

    def test_exact_int_aliases_extend_legacy_rows_without_normalization(self):
        data = self.response()
        base, base_count = legacy.render_snapshot(data, self.wiki, self.date, 'bg', legacy.PARSER_PROFILE)
        output, count = magic.render_snapshot(data, self.wiki, self.date, 'bg')
        self.assertEqual(output.splitlines()[:4], base.splitlines()[:4])
        self.assertEqual([row for row in output.splitlines() if not row.startswith(b'int\t')],
                         base.splitlines())
        self.assertIn('int\t0\tВЪТР:\n'.encode(), output)
        self.assertIn(b'int\t0\tINT:\n', output)
        self.assertNotIn(b'int\t0\tint\n', output)
        self.assertEqual(count, base_count + 2)
        data['query']['magicwords'].reverse()
        self.assertEqual(magic.render_snapshot(data, self.wiki, self.date, 'bg'), (output, count))

    def test_missing_duplicate_or_malformed_int_facts_are_rejected(self):
        cases = []
        data = self.response(); data['query']['magicwords'].pop(); cases.append(data)
        data = self.response(); data['query']['magicwords'].append(copy.deepcopy(data['query']['magicwords'][-1])); cases.append(data)
        for aliases in ([], '', [None], [''], ['bad\talias'], ['bad\nalias'], ['bad\x85alias'], ['x' * 1025]):
            data = self.response(); data['query']['magicwords'][-1]['aliases'] = aliases; cases.append(data)
        for flag in (1, None, 'false'):
            data = self.response(); data['query']['magicwords'][-1]['case-sensitive'] = flag; cases.append(data)
        for i, data in enumerate(cases):
            with self.subTest(case=i), self.assertRaises(ValueError):
                magic.render_snapshot(data, self.wiki, self.date, 'bg')

    def test_derivation_preserves_both_old_generations_and_reuses_exact_source(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp) / 'auxiliary'
            source = self.fixture(root)
            old_derived = root / legacy.DERIVED_DIRECTORY
            legacy.derive_snapshot(source, old_derived)
            before_v1, before_v2 = self.contents(source), self.contents(old_derived)
            output = root / magic.DERIVED_DIRECTORY
            with patch.object(legacy, 'fetch_response', side_effect=AssertionError('No network')):
                manifest, created = magic.derive_snapshot(source, output, self.wiki, self.date)
                self.assertTrue(created)
                self.assertEqual(manifest['version'], 3)
                self.assertEqual(manifest['profile'], magic.PROFILE)
                self.assertEqual(manifest['dependency_sha256'], {'prepare_magic_words.py': magic.LEGACY_SHA256})
                self.assertEqual(set(manifest['artifacts']), legacy.DERIVED_ARTIFACTS)
                self.assertEqual(magic.validate_snapshot(output / 'magic-words.tsv'), manifest)
                before_new = self.contents(output)
                reused, created = magic.derive_snapshot(source, output)
                self.assertFalse(created)
                self.assertEqual(reused, manifest)
                self.assertEqual(self.contents(output), before_new)
            self.assertEqual(self.contents(source), before_v1)
            self.assertEqual(self.contents(old_derived), before_v2)
            self.assertEqual(magic.selected_snapshot_root(root), output)

    def test_legacy_validation_and_selection_keep_original_contract(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp) / 'auxiliary'
            source = self.fixture(root)
            self.assertEqual(magic.validate_snapshot(source), legacy.validate_snapshot(source))
            self.assertEqual(magic.selected_snapshot_root(root), source)
            derived = root / legacy.DERIVED_DIRECTORY
            legacy.derive_snapshot(source, derived)
            self.assertEqual(magic.validate_snapshot(derived), legacy.validate_snapshot(derived))
            self.assertEqual(magic.selected_snapshot_root(root), derived)

    def test_incomplete_or_symlink_new_directory_never_falls_back(self):
        for kind in ('empty', 'symlink', 'legacy-profile'):
            with self.subTest(kind=kind), tempfile.TemporaryDirectory() as temp:
                root = Path(temp) / 'auxiliary'
                source = self.fixture(root)
                old = root / legacy.DERIVED_DIRECTORY
                legacy.derive_snapshot(source, old)
                new = root / magic.DERIVED_DIRECTORY
                if kind == 'empty':
                    new.mkdir()
                elif kind == 'symlink':
                    new.symlink_to(old, target_is_directory=True)
                else:
                    legacy.derive_snapshot(source, new)
                with self.assertRaises(ValueError):
                    magic.selected_snapshot_root(root)

    def test_rebound_output_cannot_invent_an_int_alias(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp) / 'auxiliary'
            source = self.fixture(root)
            output = root / magic.DERIVED_DIRECTORY
            manifest, _ = magic.derive_snapshot(source, output)
            blobs = self.blobs(output)
            blobs['magic-words.tsv'] = blobs['magic-words.tsv'].replace(b'int\t0\tINT:', b'int\t0\tINVENTED:')
            manifest = copy.deepcopy(manifest)
            manifest['artifacts']['magic-words.tsv'] = legacy.digest(blobs['magic-words.tsv'])
            manifest['output_sha256'] = legacy.digest(blobs['magic-words.tsv'])
            manifest['output_bytes'] = len(blobs['magic-words.tsv'])
            with self.assertRaisesRegex(ValueError, 'replay'):
                magic.validate_capture(manifest, blobs, self.wiki, self.date)

    def test_producer_dependency_time_and_original_v1_are_bound(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp) / 'auxiliary'
            source = self.fixture(root)
            output = root / magic.DERIVED_DIRECTORY
            original, _ = magic.derive_snapshot(source, output)
            blobs = self.blobs(output)
            for field, value in (
                    ('generator_sha256', '0' * 64),
                    ('dependency_sha256', {'prepare_magic_words.py': '0' * 64}),
                    ('source_capture', {}),
                    ('content_language', 'en'),
                    ('retrieved_utc', '2026-10-05T06:00:02+00:00'),
                    ('derived_utc', '2026-10-04T06:00:00+00:00')):
                with self.subTest(field=field):
                    manifest = copy.deepcopy(original); manifest[field] = value
                    with self.assertRaises(ValueError):
                        magic.validate_capture(manifest, blobs)
            changed = dict(blobs)
            changed[legacy.SOURCE_TSV] = changed[legacy.SOURCE_TSV].replace(b'PAGENAME', b'INVENTED')
            manifest = copy.deepcopy(original)
            manifest['artifacts'][legacy.SOURCE_TSV] = legacy.digest(changed[legacy.SOURCE_TSV])
            manifest['source_capture']['output_sha256'] = legacy.digest(changed[legacy.SOURCE_TSV])
            with self.assertRaises(ValueError):
                magic.validate_capture(manifest, changed)
            for wiki, date in (('enwiktionary', self.date), (self.wiki, '20260901')):
                with self.subTest(wiki=wiki, date=date), self.assertRaises(ValueError):
                    magic.validate_snapshot(output, wiki, date)

    def test_only_original_v1_can_derive_and_changed_source_cannot_reuse(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp) / 'first'
            source = self.fixture(root)
            old = root / legacy.DERIVED_DIRECTORY
            legacy.derive_snapshot(source, old)
            with self.assertRaisesRegex(ValueError, 'original v1'):
                magic.derive_snapshot(old, root / 'invalid')
            output = root / magic.DERIVED_DIRECTORY
            magic.derive_snapshot(source, output)
            data = self.response()
            data['query']['magicwords'][-1]['aliases'].append('captured-new-alias:')
            other = self.fixture(Path(temp) / 'second', data)
            with self.assertRaisesRegex(ValueError, 'different original'):
                magic.derive_snapshot(other, output)


    def test_builder_verifies_and_pins_all_v3_artifacts_and_retains_v2(self):
        import build_wiktionaries as b
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp) / 'auxiliary'
            source = self.fixture(root)
            old_derived = root / legacy.DERIVED_DIRECTORY
            legacy.derive_snapshot(source, old_derived)
            before_v1, before_v2 = self.contents(source), self.contents(old_derived)
            output = root / magic.DERIVED_DIRECTORY
            manifest, created = magic.derive_snapshot(source, output, self.wiki, self.date)
            self.assertTrue(created)
            snapshots = {'magic-words': output / 'magic-words.tsv'}
            hashes = b.verified_auxiliary_hashes(snapshots, self.wiki, self.date)
            manifests, artifacts = b.auxiliary_capture_identities(snapshots, self.wiki, self.date)
            self.assertEqual(hashes, {'magic-words': manifest['output_sha256']})
            self.assertEqual(set(manifests), {'magic-words'})
            self.assertEqual(set(artifacts), {'magic-words'})
            destination = Path(temp) / 'pinned'
            destination.mkdir()
            pinned = b.pinned_auxiliary_snapshots(snapshots, hashes, destination, manifests, artifacts)
            self.assertEqual(pinned, {'magic-words': destination / 'magic-words.tsv'})
            self.assertEqual(magic.validate_snapshot(pinned['magic-words'], self.wiki, self.date), manifest)
            self.assertEqual(b.verified_auxiliary_hashes(pinned, self.wiki, self.date), hashes)
            self.assertEqual(b.auxiliary_capture_identities(pinned, self.wiki, self.date),
                             (manifests, artifacts))
            inventory = magic.ARTIFACTS | {'magic-words.manifest.json'}
            self.assertEqual(len(magic.ARTIFACTS), 7)
            self.assertEqual({p.name for p in destination.iterdir()}, inventory)
            for filename in inventory:
                with self.subTest(filename=filename):
                    self.assertEqual((destination / filename).read_bytes(), (output / filename).read_bytes())
            self.assertEqual(self.contents(source), before_v1)
            self.assertEqual(self.contents(old_derived), before_v2)
            self.assertEqual(magic.validate_snapshot(old_derived, self.wiki, self.date),
                             legacy.validate_snapshot(old_derived, self.wiki, self.date))

if __name__ == '__main__':
    unittest.main()
