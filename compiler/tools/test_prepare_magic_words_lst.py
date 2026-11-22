import copy
import unittest
from unittest.mock import patch

import prepare_magic_words as legacy
import prepare_magic_words_int as int_magic
import prepare_magic_words_language as prior
import prepare_magic_words_lst as magic
import test_prepare_magic_words_language as fixtures


class LstMagicWordCaptureTests(unittest.TestCase):
    wiki = 'arwiktionary'
    date = '20261001'
    setUp = fixtures.LanguageMagicWordCaptureTests.setUp
    contents = fixtures.LanguageMagicWordCaptureTests.contents

    def response(self):
        data = fixtures.LanguageMagicWordCaptureTests.response(self)
        data['query']['magicwords'].extend([
            {'name': 'lst', 'case-sensitive': False, 'aliases': ['#section', '#قسم']},
            {'name': 'lstx', 'case-sensitive': False, 'aliases': ['section-x']},
            {'name': 'lsth', 'case-sensitive': False, 'aliases': ['section-h']},
        ])
        return data

    def fixture(self, name='capture', data=None):
        root, source = fixtures.LanguageMagicWordCaptureTests.fixture(self, name, data)
        output = root / prior.DERIVED_DIRECTORY
        prior.derive_snapshot(source, output)
        return root, output

    def derived(self):
        root, source = self.fixture()
        output = root / magic.DERIVED_DIRECTORY
        manifest, _ = magic.derive_snapshot(source, output)
        blobs = {name: legacy.read_regular(output / name) for name in magic.ARTIFACTS}
        return root, source, output, manifest, blobs

    def test_projection_adds_only_captured_lst_aliases_and_preserves_prior_rows(self):
        for flag in (False, True):
            data = self.response()
            data['query']['magicwords'][-3]['case-sensitive'] = flag
            old, count = prior.render_snapshot(data, self.wiki, self.date, 'ar')
            new, rows = magic.render_snapshot(data, self.wiki, self.date, 'ar')
            self.assertEqual([row for row in new.splitlines() if not row.startswith(b'lst\t')], old.splitlines())
            for alias in ('#section', '#قسم'):
                self.assertIn(('lst\t' + str(int(flag)) + '\t' + alias + '\n').encode(), new)
            self.assertNotIn(b'lst\t0\tlst\n', new)
            self.assertNotIn(b'lstx\t', new)
            self.assertNotIn(b'lsth\t', new)
            self.assertEqual(rows, count + 2)
            data['query']['magicwords'].reverse()
            self.assertEqual(magic.render_snapshot(data, self.wiki, self.date, 'ar'), (new, rows))

    def test_absent_extension_is_not_invented_and_malformed_facts_fail(self):
        data = self.response()
        data['query']['magicwords'] = [word for word in data['query']['magicwords'] if word['name'] != 'lst']
        self.assertEqual(magic.render_snapshot(data, self.wiki, self.date, 'ar'),
                         prior.render_snapshot(data, self.wiki, self.date, 'ar'))
        cases = []
        data = self.response()
        data['query']['magicwords'].append(copy.deepcopy(data['query']['magicwords'][-3]))
        cases.append(data)
        for aliases in ([], '', [None], [''], ['bad\talias'], ['bad\nalias'], ['bad\x85alias'], ['x' * 1025]):
            data = self.response(); data['query']['magicwords'][-3]['aliases'] = aliases; cases.append(data)
        for flag in (1, None, 'false'):
            data = self.response(); data['query']['magicwords'][-3]['case-sensitive'] = flag; cases.append(data)
        for i, data in enumerate(cases):
            with self.subTest(case=i), self.assertRaises(ValueError):
                magic.render_snapshot(data, self.wiki, self.date, 'ar')

    def test_offline_derivation_preserves_original_generations_and_reuses_exact_output(self):
        root, source = self.fixture()
        predecessors = [root / 'magic-words', root / legacy.DERIVED_DIRECTORY,
                        root / int_magic.DERIVED_DIRECTORY, source]
        before = [self.contents(path) for path in predecessors]
        with patch.object(legacy, 'fetch_response', side_effect=AssertionError('Network forbidden')):
            output = root / magic.DERIVED_DIRECTORY
            manifest, created = magic.derive_snapshot(source, output)
            self.assertTrue(created)
            self.assertEqual((manifest['version'], manifest['profile']), (5, magic.PROFILE))
            self.assertEqual(len(manifest['artifacts']), 11)
            self.assertEqual(set(manifest['artifacts']), magic.ARTIFACTS)
            old = prior.validate_snapshot(source)
            for key in ('retrieved_utc', 'source_url', 'raw_sha256', 'content_language', 'temporal_scope'):
                self.assertEqual(manifest[key], old[key])
            self.assertEqual((output / magic.SOURCE_MANIFEST).read_bytes(), (source / 'magic-words.manifest.json').read_bytes())
            self.assertEqual((output / magic.SOURCE_TSV).read_bytes(), (source / 'magic-words.tsv').read_bytes())
            frozen = self.contents(output)
            self.assertEqual(magic.derive_snapshot(source, output), (manifest, False))
            self.assertEqual(self.contents(output), frozen)
        for path, expected in zip(predecessors, before):
            self.assertEqual(self.contents(path), expected)
            self.assertEqual(magic.validate_snapshot(path), prior.validate_snapshot(path))
        self.assertEqual(magic.selected_snapshot_root(root), output)
        self.assertEqual(magic.capture_artifacts(output, manifest),
                         dict(manifest['artifacts'], **{'magic-words.manifest.json': legacy.digest((output / 'magic-words.manifest.json').read_bytes())}))

    def test_rebound_output_or_embedded_prior_capture_cannot_invent_aliases(self):
        _, _, _, original, blobs = self.derived()
        for target in ('magic-words.tsv', magic.SOURCE_TSV):
            changed = dict(blobs)
            changed[target] = changed[target].replace(b'INT:', b'INVENTED:')
            manifest = copy.deepcopy(original)
            manifest['artifacts'][target] = legacy.digest(changed[target])
            if target == 'magic-words.tsv':
                manifest['output_sha256'] = legacy.digest(changed[target]); manifest['output_bytes'] = len(changed[target])
            else:
                manifest['source_capture']['output_sha256'] = legacy.digest(changed[target])
            with self.subTest(target=target), self.assertRaises(ValueError):
                magic.validate_capture(manifest, changed)
        for target in (prior.SOURCE_TSV, magic.SOURCE_MANIFEST, 'magic-words.raw.json'):
            changed = dict(blobs); changed[target] += b' '
            manifest = copy.deepcopy(original); manifest['artifacts'][target] = legacy.digest(changed[target])
            with self.subTest(target=target), self.assertRaises(ValueError):
                magic.validate_capture(manifest, changed)

    def test_producer_time_and_requested_edition_remain_strict(self):
        _, source, output, original, blobs = self.derived()
        for key, value in [('generator_sha256', '0' * 64), ('dependency_sha256', {}),
                           ('source_capture', {}), ('content_language', 'en'),
                           ('derived_utc', '2026-10-04T06:00:00+00:00')]:
            manifest = copy.deepcopy(original); manifest[key] = value
            with self.subTest(field=key), self.assertRaises(ValueError):
                magic.validate_capture(manifest, blobs)
        for wiki, date in [('enwiktionary', self.date), (self.wiki, '20260901')]:
            with self.subTest(wiki=wiki, date=date), self.assertRaises(ValueError):
                magic.validate_snapshot(output, wiki, date)
        changed = dict(blobs); changed.pop(magic.SOURCE_TSV)
        with self.assertRaises(ValueError):
            magic.validate_capture(original, changed)
        with self.assertRaisesRegex(ValueError, 'authenticated language'):
            magic.derive_snapshot(source.parent / int_magic.DERIVED_DIRECTORY, self.root / 'invalid')

    def test_present_invalid_new_generation_never_falls_back(self):
        for kind in ('empty', 'symlink', 'language-profile'):
            root, source = self.fixture(kind)
            with self.assertRaisesRegex(ValueError, 'Missing required LST'):
                magic.selected_snapshot_root(root)
            output = root / magic.DERIVED_DIRECTORY
            if kind == 'empty':
                output.mkdir()
            elif kind == 'symlink':
                output.symlink_to(source.resolve(), target_is_directory=True)
            else:
                prior.derive_snapshot(root / int_magic.DERIVED_DIRECTORY, output)
            with self.subTest(kind=kind), self.assertRaises(ValueError):
                magic.selected_snapshot_root(root)

    def test_changed_source_cannot_reuse_existing_lst_generation(self):
        root, source = self.fixture('first'); output = root / magic.DERIVED_DIRECTORY
        magic.derive_snapshot(source, output)
        data = self.response(); data['query']['magicwords'][-3]['aliases'].append('#actual-new')
        _, other = self.fixture('second', data)
        with self.assertRaisesRegex(ValueError, 'different language'):
            magic.derive_snapshot(other, output)

    def test_builder_dispatches_v5_and_pins_all_artifacts_without_changing_v4(self):
        import build_wiktionaries as builder
        _, source, output, manifest, _ = self.derived()
        snapshots = {'magic-words': output / 'magic-words.tsv'}
        self.assertIs(builder.auxiliary_capture_helper('magic-words', snapshots['magic-words']), magic)
        self.assertIs(builder.auxiliary_capture_helper('magic-words', source / 'magic-words.tsv'), prior)
        hashes = builder.verified_auxiliary_hashes(snapshots, self.wiki, self.date)
        captures, artifacts = builder.auxiliary_capture_identities(snapshots, self.wiki, self.date)
        self.assertEqual(hashes, {'magic-words': manifest['output_sha256']})
        destination = self.root / 'pinned'; destination.mkdir()
        pinned = builder.pinned_auxiliary_snapshots(snapshots, hashes, destination, captures, artifacts)
        self.assertEqual(magic.validate_snapshot(pinned['magic-words'], self.wiki, self.date), manifest)
        self.assertEqual({p.name for p in destination.iterdir()}, magic.ARTIFACTS | {'magic-words.manifest.json'})
        for name in magic.ARTIFACTS | {'magic-words.manifest.json'}:
            self.assertEqual((destination / name).read_bytes(), (output / name).read_bytes())
        self.assertEqual(builder.verified_auxiliary_hashes({'magic-words': source / 'magic-words.tsv'}, self.wiki, self.date),
                         {'magic-words': prior.validate_snapshot(source)['output_sha256']})


if __name__ == '__main__':
    unittest.main()
