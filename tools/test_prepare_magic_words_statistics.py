import copy
import unittest
from unittest.mock import patch

import prepare_magic_words as legacy
import prepare_magic_words_lst as prior
import prepare_magic_words_statistics as magic
import test_prepare_magic_words_lst as fixtures


class StatisticsMagicWordCaptureTests(unittest.TestCase):
    wiki = 'arwiktionary'
    date = '20261001'
    setUp = fixtures.LstMagicWordCaptureTests.setUp
    contents = fixtures.LstMagicWordCaptureTests.contents

    def response(self):
        data = fixtures.LstMagicWordCaptureTests.response(self)
        data['query']['magicwords'].extend(
            {'name': name, 'case-sensitive': bool(i % 2),
             'aliases': [name.upper(), 'عدد-' + str(i)]}
            for i, name in enumerate(sorted(magic.STATISTICS)))
        return data

    def fixture(self, name='capture', data=None):
        root, source = fixtures.LstMagicWordCaptureTests.fixture(self, name, data)
        output = root / prior.DERIVED_DIRECTORY
        prior.derive_snapshot(source, output)
        return root, output

    def derived(self):
        root, source = self.fixture()
        output = root / magic.DERIVED_DIRECTORY
        manifest, _ = magic.derive_snapshot(source, output)
        blobs = {name: legacy.read_regular(output / name) for name in magic.ARTIFACTS}
        return root, source, output, manifest, blobs

    def test_all_seven_captured_aliases_preserve_every_selected_lst_parser_row(self):
        data = self.response()
        old, old_count = prior.render_snapshot(data, self.wiki, self.date, 'ar')
        new, count = magic.render_snapshot(data, self.wiki, self.date, 'ar')
        stats = {name.encode() for name in magic.STATISTICS}
        self.assertEqual([row for row in new.splitlines() if row.split(b'\t')[0] not in stats], old.splitlines())
        for i, name in enumerate(sorted(magic.STATISTICS)):
            for alias in (name.upper(), 'عدد-' + str(i)):
                self.assertIn((name + '\t' + str(i % 2) + '\t' + alias + '\n').encode(), new)
            self.assertNotIn((name + '\t0\t' + name + '\n').encode(), new)
        self.assertEqual(count, old_count + 14)
        for marker in (b'int\t', b'language\t', b'lst\t'):
            self.assertIn(marker, new)
        self.assertNotIn(b':R\n', new)
        data['query']['magicwords'].reverse()
        self.assertEqual(magic.render_snapshot(data, self.wiki, self.date, 'ar'), (new, count))

    def test_absent_statistics_are_not_invented_and_legacy_render_is_byte_exact(self):
        data = self.response()
        plain = copy.deepcopy(data)
        plain['query']['magicwords'] = [w for w in plain['query']['magicwords'] if w['name'] not in magic.STATISTICS]
        self.assertEqual(prior.render_snapshot(data, self.wiki, self.date, 'ar'),
                         prior.render_snapshot(plain, self.wiki, self.date, 'ar'))
        self.assertEqual(magic.render_snapshot(plain, self.wiki, self.date, 'ar'),
                         prior.render_snapshot(plain, self.wiki, self.date, 'ar'))
        plain['query']['magicwords'].append({'name': 'numberofuncaptured', 'aliases': ['NOT-INVENTED']})
        self.assertNotIn(b'NOT-INVENTED', magic.render_snapshot(plain, self.wiki, self.date, 'ar')[0])

    def test_duplicate_and_malformed_selected_statistics_refuse(self):
        cases = []
        data = self.response(); data['query']['magicwords'].append(copy.deepcopy(data['query']['magicwords'][-1])); cases.append(data)
        for aliases in ([], '', [None], [''], ['bad\talias'], ['bad\nalias'], ['bad\x85alias'], ['x' * 1025]):
            data = self.response(); data['query']['magicwords'][-1]['aliases'] = aliases; cases.append(data)
        for flag in (1, None, 'false'):
            data = self.response(); data['query']['magicwords'][-1]['case-sensitive'] = flag; cases.append(data)
        for i, data in enumerate(cases):
            with self.subTest(case=i), self.assertRaises(ValueError):
                magic.render_snapshot(data, self.wiki, self.date, 'ar')

    def test_offline_derivation_preserves_all_five_predecessors_and_exact_reuse(self):
        root, source = self.fixture()
        predecessors = [p for p in root.iterdir() if p.is_dir()]
        before = {p: self.contents(p) for p in predecessors}
        with patch.object(legacy, 'fetch_response', side_effect=AssertionError('Network forbidden')):
            output = root / magic.DERIVED_DIRECTORY
            manifest, created = magic.derive_snapshot(source, output)
            self.assertTrue(created)
            self.assertEqual((manifest['version'], manifest['profile']), (6, magic.PROFILE))
            self.assertEqual(set(manifest['artifacts']), magic.ARTIFACTS)
            self.assertEqual(len(magic.ARTIFACTS), 13)
            self.assertEqual((output / magic.SOURCE_MANIFEST).read_bytes(), (source / 'magic-words.manifest.json').read_bytes())
            self.assertEqual((output / magic.SOURCE_TSV).read_bytes(), (source / 'magic-words.tsv').read_bytes())
            frozen = self.contents(output)
            self.assertEqual(magic.derive_snapshot(source, output), (manifest, False))
            self.assertEqual(self.contents(output), frozen)
        for path in predecessors:
            self.assertEqual(self.contents(path), before[path])
            self.assertEqual(magic.validate_snapshot(path), prior.validate_snapshot(path))
        self.assertEqual(magic.selected_snapshot_root(root), output)

    def test_present_invalid_statistics_generation_never_falls_back(self):
        for kind in ('empty', 'symlink', 'lst-profile'):
            root, source = self.fixture(kind)
            self.assertEqual(magic.selected_snapshot_root(root), source)
            output = root / magic.DERIVED_DIRECTORY
            if kind == 'empty': output.mkdir()
            elif kind == 'symlink': output.symlink_to(source.resolve(), target_is_directory=True)
            else:
                for p in source.iterdir():
                    output.mkdir(exist_ok=True)
                    (output / p.name).write_bytes(p.read_bytes())
            with self.subTest(kind=kind), self.assertRaises(ValueError):
                magic.selected_snapshot_root(root)
        with self.assertRaisesRegex(ValueError, 'Missing required LST'):
            magic.selected_snapshot_root(self.root)

    def test_rebound_tsv_or_embedded_lst_cannot_invent_captured_aliases(self):
        _, _, _, original, blobs = self.derived()
        for target in ('magic-words.tsv', magic.SOURCE_TSV):
            changed = dict(blobs); changed[target] = changed[target].replace(b'INT:', b'INVENTED:')
            manifest = copy.deepcopy(original); manifest['artifacts'][target] = legacy.digest(changed[target])
            if target == 'magic-words.tsv':
                manifest['output_sha256'] = legacy.digest(changed[target]); manifest['output_bytes'] = len(changed[target])
            else: manifest['source_capture']['output_sha256'] = legacy.digest(changed[target])
            with self.subTest(target=target), self.assertRaises(ValueError): magic.validate_capture(manifest, changed)
        changed = dict(blobs)
        changed['magic-words.tsv'] = changed['magic-words.tsv'].replace(b'NUMBEROFARTICLES', b'INVENTEDARTICLES')
        manifest = copy.deepcopy(original)
        manifest['artifacts']['magic-words.tsv'] = manifest['output_sha256'] = legacy.digest(changed['magic-words.tsv'])
        manifest['output_bytes'] = len(changed['magic-words.tsv'])
        with self.assertRaisesRegex(ValueError, 'replay'): magic.validate_capture(manifest, changed)

    def test_producer_time_requested_identity_and_complete_artifacts_remain_strict(self):
        _, _, output, original, blobs = self.derived()
        for key, value in [('generator_sha256', '0' * 64), ('dependency_sha256', {}),
                           ('source_capture', {}), ('content_language', 'en'),
                           ('derived_utc', '2026-10-04T06:00:00+00:00')]:
            manifest = copy.deepcopy(original); manifest[key] = value
            with self.subTest(field=key), self.assertRaises(ValueError): magic.validate_capture(manifest, blobs)
        for wiki, date in [('enwiktionary', self.date), (self.wiki, '20260901')]:
            with self.subTest(wiki=wiki, date=date), self.assertRaises(ValueError): magic.validate_snapshot(output, wiki, date)
        changed = dict(blobs); changed.pop(magic.SOURCE_TSV)
        with self.assertRaises(ValueError): magic.validate_capture(original, changed)

    def test_only_authenticated_full_lst_source_can_derive_or_reuse(self):
        root, source = self.fixture('first'); output = root / magic.DERIVED_DIRECTORY
        magic.derive_snapshot(source, output)
        with self.assertRaisesRegex(ValueError, 'authenticated LST'):
            magic.derive_snapshot(root / prior.prior.DERIVED_DIRECTORY, self.root / 'invalid')
        data = self.response(); data['query']['magicwords'][-1]['aliases'].append('ACTUAL-NEW')
        _, other = self.fixture('second', data)
        with self.assertRaisesRegex(ValueError, 'different LST'):
            magic.derive_snapshot(other, output)

    def test_normal_builder_dispatches_and_pins_complete_v6_without_changing_v5(self):
        import build_wiktionaries as builder
        _, source, output, manifest, _ = self.derived()
        self.assertIs(builder.auxiliary_capture_helper('magic-words', output / 'magic-words.tsv'), magic)
        self.assertIs(builder.auxiliary_capture_helper('magic-words', source / 'magic-words.tsv'), prior)
        snapshots = {'magic-words': output / 'magic-words.tsv'}
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
