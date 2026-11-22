import copy
import contextlib
import io
import json
from pathlib import Path
import shutil
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch

import prepare_magic_words as magic


class MagicWordCaptureTests(unittest.TestCase):
    wiki = 'arwiktionary'
    date = '20261001'

    def response(self):
        words = [{'name': name, 'case-sensitive': True, 'aliases': [name.upper()]}
                 for name in sorted(magic.SUPPORTED)]
        next(row for row in words if row['name'] == 'pagename')['aliases'] += ['اسم_الصفحة']
        return {'query': {'general': {'wikiid': self.wiki, 'lang': 'ar'}, 'magicwords': words}}

    def parser_response(self):
        data = self.response()
        data['query']['magicwords'] += [{'name': name, 'aliases': [name]}
                                       for name in sorted(magic.PARSER_FUNCTIONS)]
        for row in data['query']['magicwords']:
            if row['name'] == 'invoke':
                row.update({'case-sensitive': True, 'aliases': ['استدعاء', 'invoke']})
            if row['name'] == 'len': row['aliases'].append('#ziman')
            if row['name'] == 'uc': row['aliases'].append('大寫：')
            if row['name'] == 'defaultsort': row['aliases'].append('ترتيب_افتراضي:')
            if row['name'] == 'formatdate': row['aliases'].append('dateformat')
        return data

    def prepare(self, root):
        root.mkdir()
        raw = magic.document({'query': {'general': {'wikiid': self.wiki, 'lang': 'ar'}}})
        (root / 'namespace-siteinfo.raw.json').write_bytes(raw)
        (root / 'capture.complete.json').write_bytes(magic.document(dict(wiki=self.wiki,
            date=self.date, artifacts={'namespace-siteinfo.raw.json': magic.digest(raw)})))
        return root

    def fetcher(self, data=None):
        raw = magic.document(data or self.response())
        def fetch(url):
            return raw, dict(source_url=url, response_url=url, status=200,
                started_utc='2026-10-05T06:00:00+00:00', retrieved_utc='2026-10-05T06:00:01+00:00',
                raw_sha256=magic.digest(raw), raw_bytes=len(raw))
        return fetch

    def capture(self, root):
        return magic.capture_snapshot(self.prepare(root), self.wiki, self.date, fetcher=self.fetcher())

    def rebind(self, root, name, body):
        """Model changed artifacts with self-consistent hashes, not only corruption."""
        path = root / name
        path.chmod(0o644)
        path.write_bytes(body)
        manifest_path = root / 'magic-words.manifest.json'
        manifest = json.loads(manifest_path.read_bytes())
        manifest['artifacts'][name] = magic.digest(body)
        if name == 'magic-words.raw.json':
            manifest['raw_sha256'] = magic.digest(body)
        if name == 'magic-words.tsv':
            manifest.update(output_sha256=magic.digest(body), output_bytes=len(body))
        manifest_path.chmod(0o644)
        manifest_path.write_bytes(magic.document(manifest))

    def test_exact_aliases_and_case_flags_survive_without_normalization(self):
        data = self.response()
        word = next(row for row in data['query']['magicwords'] if row['name'] == 'pagename')
        word['aliases'] += ['اسم الصفحة', 'PAGENAME']
        del word['case-sensitive']
        output, rows = magic.render_snapshot(data, self.wiki, self.date, 'ar')
        self.assertTrue(output.startswith(b'# wikidict-magic-words-v1\n# wiki\tarwiktionary\n'))
        self.assertIn('pagename\t0\tاسم_الصفحة\n'.encode(), output)
        self.assertIn('pagename\t0\tاسم الصفحة\n'.encode(), output)
        self.assertEqual(output.count(b'pagename\t0\tPAGENAME\n'), 1)
        self.assertEqual(rows, 23)

    def test_capture_replays_and_reuse_does_not_fetch_or_rewrite(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / 'capture'
            manifest, created = self.capture(root)
            self.assertTrue(created)
            output = root / 'magic-words'
            before = {p.name: (p.read_bytes(), p.stat().st_mtime_ns) for p in output.iterdir()}
            self.assertEqual(magic.validate_snapshot(output / 'magic-words.tsv'), manifest)
            fetch = Mock(side_effect=AssertionError('No network on reuse'))
            reused, created = magic.capture_snapshot(root, self.wiki, self.date, fetcher=fetch)
            self.assertFalse(created)
            self.assertEqual(reused, manifest)
            self.assertEqual(before, {p.name: (p.read_bytes(), p.stat().st_mtime_ns) for p in output.iterdir()})
            fetch.assert_not_called()
            self.assertEqual(manifest['temporal_scope'], 'current-at-retrieval')
            self.assertNotEqual(manifest['retrieved_utc'][:10].replace('-', ''), manifest['date'])

    def test_partial_api_responses_and_identity_drift_do_not_publish(self):
        cases = []
        for key in ('error', 'warnings', 'continue'):
            data = self.response(); data[key] = {'reason': 'partial'}; cases.append(data)
        data = self.response(); data['query']['general']['wikiid'] = 'enwiktionary'; cases.append(data)
        data = self.response(); data['query']['general']['lang'] = 'en'; cases.append(data)
        data = self.response(); data['query']['magicwords'].pop(); cases.append(data)
        for i, data in enumerate(cases):
            with self.subTest(case=i), tempfile.TemporaryDirectory() as tmp:
                root = self.prepare(Path(tmp) / 'capture')
                with self.assertRaises(ValueError):
                    magic.capture_snapshot(root, self.wiki, self.date, fetcher=self.fetcher(data))
                self.assertFalse((root / 'magic-words').exists())

    def test_invalid_aliases_flags_and_duplicate_canonical_ids_are_rejected(self):
        for alias in ('', 'bad\talias', 'bad\nname', 'bad\x85name', 'x' * 1025):
            with self.subTest(alias=repr(alias)):
                data = self.response(); data['query']['magicwords'][0]['aliases'] = [alias]
                with self.assertRaises(ValueError): magic.render_snapshot(data, self.wiki, self.date, 'ar')
        for flag in ('', 1, None):
            with self.subTest(flag=flag):
                data = self.response(); data['query']['magicwords'][0]['case-sensitive'] = flag
                with self.assertRaises(ValueError): magic.render_snapshot(data, self.wiki, self.date, 'ar')
        data = self.response(); data['query']['magicwords'].append(copy.deepcopy(data['query']['magicwords'][0]))
        with self.assertRaises(ValueError): magic.render_snapshot(data, self.wiki, self.date, 'ar')

    def test_welsh_and_armenian_overlaps_preserve_both_canonical_rows(self):
        for wiki, lang, first, second, alias in (
                ('cywiktionary', 'cy', 'namespace', 'namespacee', 'NAMESPACE'),
                ('hywiktionary', 'hy', 'fullpagename', 'subjectspace', 'ARTICLESPACE')):
            with self.subTest(wiki=wiki):
                data = self.response()
                data['query']['general'] = {'wikiid': wiki, 'lang': lang}
                for row in data['query']['magicwords']:
                    if row['name'] in (first, second) and alias not in row['aliases']:
                        row['aliases'].append(alias)
                output, rows = magic.render_snapshot(data, wiki, self.date, lang)
                self.assertIn((first + '\t1\t' + alias + '\n').encode(), output)
                self.assertIn((second + '\t1\t' + alias + '\n').encode(), output)
                data['query']['magicwords'].reverse()
                self.assertEqual(magic.render_snapshot(data, wiki, self.date, lang), (output, rows))

    def test_tsv_cannot_be_changed_even_with_rebound_hashes(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / 'capture'; self.capture(root); output = root / 'magic-words'
            original = (output / 'magic-words.tsv').read_bytes()
            self.rebind(output, 'magic-words.tsv', original.replace('اسم_الصفحة'.encode(), b'INVENTED_ALIAS'))
            with self.assertRaisesRegex(ValueError, 'replay'):
                magic.validate_snapshot(output, self.wiki, self.date)

    def test_request_origin_and_time_are_part_of_offline_verification(self):
        for field, value in (('source_url', 'https://example.test/'),
                             ('response_url', 'https://example.test/w/api.php'),
                             ('response_url', 'https://ar.wiktionary.org:444/w/api.php'),
                             ('status', 503), ('started_utc', '2026-10-05T07:00:00+00:00'),
                             ('retrieved_utc', '2026-10-05T06:00:01')):
            with self.subTest(field=field, value=value), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp) / 'capture'; self.capture(root); output = root / 'magic-words'
                request = json.loads((output / 'magic-words.request.json').read_bytes()); request[field] = value
                self.rebind(output, 'magic-words.request.json', magic.document(request))
                with self.assertRaises(ValueError): magic.validate_snapshot(output, self.wiki, self.date)

    def test_missing_provenance_and_symlinks_are_not_reusable(self):
        for mode in ('missing', 'symlink', 'directory', 'manifest'):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp) / 'capture'; self.capture(root); output = root / 'magic-words'
                path = output / 'magic-words.raw.json'
                if mode == 'directory':
                    moved = root / 'moved'; output.rename(moved); output.symlink_to(moved, target_is_directory=True)
                elif mode == 'manifest':
                    (output / 'magic-words.manifest.json').unlink()
                else:
                    raw = path.read_bytes(); path.unlink()
                    if mode == 'symlink':
                        outside = root / 'outside.json'; outside.write_bytes(raw); path.symlink_to(outside)
                fetch = Mock(side_effect=AssertionError('Must not replace corrupt capture'))
                with self.assertRaises(ValueError):
                    magic.capture_snapshot(root, self.wiki, self.date, fetcher=fetch)
                fetch.assert_not_called()

    def test_edition_date_and_pinned_namespace_remain_bound(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / 'capture'; self.capture(root); output = root / 'magic-words'
            for wiki, date in (('enwiktionary', self.date), (self.wiki, '20260901')):
                with self.subTest(wiki=wiki, date=date), self.assertRaises(ValueError):
                    magic.validate_snapshot(output, wiki, date)
            raw = json.loads((root / 'namespace-siteinfo.raw.json').read_bytes())
            raw['query']['general']['lang'] = 'en'
            (root / 'namespace-siteinfo.raw.json').write_bytes(magic.document(raw))
            with self.assertRaisesRegex(ValueError, 'namespace capture'):
                magic.capture_snapshot(root, self.wiki, self.date, fetcher=self.fetcher())

    def test_duplicate_json_keys_cannot_hide_identity(self):
        with self.assertRaisesRegex(ValueError, 'Duplicate JSON key'):
            magic.parse_json(b'{"wiki":"enwiktionary","wiki":"arwiktionary"}')

    def test_capture_table_fits_the_native_registry_bound(self):
        data = self.response()
        for index, row in enumerate(data['query']['magicwords'][:2]):
            row['aliases'] = [str(index) + '-' + str(i) + 'x' * 900 for i in range(600)]
        with self.assertRaisesRegex(ValueError, 'native registry limit'):
            magic.render_snapshot(data, self.wiki, self.date, 'ar')

    def test_expanded_profile_preserves_parser_aliases_and_counts_only_present_ids(self):
        data = self.parser_response()
        original, _ = magic.render_snapshot(data, self.wiki, self.date, 'ar')
        self.assertEqual(magic.canonical_word_count(original), 21)
        output, _ = magic.render_snapshot(data, self.wiki, self.date, 'ar', magic.PARSER_PROFILE)
        self.assertTrue(output.startswith(b'# wikidict-magic-words-v2\n'))
        self.assertEqual(magic.canonical_word_count(output), 54)
        for row in ('invoke\t1\tاستدعاء\n', 'len\t0\t#ziman\n', 'uc\t0\t大寫：\n',
                    'defaultsort\t0\tترتيب_افتراضي:\n', 'formatdate\t0\tdateformat\n'):
            self.assertIn(row.encode(), output)
        words = data['query']['magicwords']
        data['query']['magicwords'] = [row for row in words if row['name'] in magic.SUPPORTED | {'invoke', 'if'}]
        data['query']['magicwords'].append({'name': 'unsupported-function', 'aliases': ['NEVER']})
        output, _ = magic.render_snapshot(data, self.wiki, self.date, 'ar', magic.PARSER_PROFILE)
        self.assertEqual(magic.canonical_word_count(output), 23)
        self.assertNotIn(b'NEVER', output)
        data['query']['magicwords'] = [row for row in data['query']['magicwords'] if row['name'] != 'pagename']
        with self.assertRaisesRegex(ValueError, 'Incomplete supported title'):
            magic.render_snapshot(data, self.wiki, self.date, 'ar', magic.PARSER_PROFILE)

    def test_offline_derivation_preserves_original_observation_and_reuses_without_fetch(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = self.prepare(Path(tmp) / 'capture')
            original, _ = magic.capture_snapshot(root, self.wiki, self.date, fetcher=self.fetcher(self.parser_response()))
            source, output = root / 'magic-words', root / magic.DERIVED_DIRECTORY
            before = {p.name: (p.read_bytes(), p.stat().st_mtime_ns) for p in source.iterdir()}
            with patch.object(magic, 'fetch_response', side_effect=AssertionError('Offline only')) as fetch:
                derived, created = magic.derive_snapshot(source, output)
                self.assertTrue(created)
                derived_before = {p.name: (p.read_bytes(), p.stat().st_mtime_ns) for p in output.iterdir()}
                reused, created = magic.derive_snapshot(source / 'magic-words.tsv', output, self.wiki, self.date)
                self.assertFalse(created)
                self.assertEqual(reused, derived)
                self.assertEqual(derived_before, {p.name: (p.read_bytes(), p.stat().st_mtime_ns) for p in output.iterdir()})
                fetch.assert_not_called()
            self.assertEqual(before, {p.name: (p.read_bytes(), p.stat().st_mtime_ns) for p in source.iterdir()})
            self.assertEqual(magic.validate_snapshot(source), original)
            self.assertEqual(magic.validate_snapshot(output), derived)
            self.assertEqual(derived['version'], 2)
            self.assertEqual(derived['profile'], magic.PARSER_PROFILE)
            self.assertEqual(derived['canonical_words'], 54)
            self.assertEqual(derived['retrieved_utc'], original['retrieved_utc'])
            self.assertEqual(derived['raw_sha256'], original['raw_sha256'])
            self.assertGreaterEqual(magic.timestamp(derived['derived_utc']), magic.timestamp(original['retrieved_utc']))
            self.assertEqual((output / magic.SOURCE_MANIFEST).read_bytes(), before['magic-words.manifest.json'][0])
            self.assertEqual((output / magic.SOURCE_TSV).read_bytes(), before['magic-words.tsv'][0])
            for name in magic.ARTIFACTS - {'magic-words.tsv'}:
                self.assertEqual((output / name).read_bytes(), before[name][0])

    def test_derived_capture_requires_source_evidence_and_exact_replay_of_both_outputs(self):
        for mode in ('missing-source-manifest', 'missing-source-tsv', 'output', 'source-output', 'timestamp', 'count'):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as tmp:
                root = self.prepare(Path(tmp) / 'capture')
                magic.capture_snapshot(root, self.wiki, self.date, fetcher=self.fetcher(self.parser_response()))
                output = root / magic.DERIVED_DIRECTORY
                magic.derive_snapshot(root / 'magic-words', output)
                if mode.startswith('missing-'):
                    (output / (magic.SOURCE_MANIFEST if mode.endswith('manifest') else magic.SOURCE_TSV)).unlink()
                elif mode == 'output':
                    raw = (output / 'magic-words.tsv').read_bytes().replace('استدعاء'.encode(), b'INVENTED')
                    self.rebind(output, 'magic-words.tsv', raw)
                elif mode == 'source-output':
                    raw = (output / magic.SOURCE_TSV).read_bytes().replace('اسم_الصفحة'.encode(), b'INVENTED')
                    self.rebind(output, magic.SOURCE_TSV, raw)
                    original = json.loads((output / magic.SOURCE_MANIFEST).read_bytes())
                    original['artifacts']['magic-words.tsv'] = magic.digest(raw)
                    original.update(output_sha256=magic.digest(raw), output_bytes=len(raw))
                    self.rebind(output, magic.SOURCE_MANIFEST, magic.document(original))
                    manifest = json.loads((output / 'magic-words.manifest.json').read_bytes())
                    manifest['source_capture'].update(output_sha256=magic.digest(raw),
                        manifest_sha256=magic.digest(magic.document(original)))
                    (output / 'magic-words.manifest.json').write_bytes(magic.document(manifest))
                else:
                    path = output / 'magic-words.manifest.json'
                    manifest = json.loads(path.read_bytes())
                    if mode == 'timestamp': manifest['derived_utc'] = '2026-10-01T00:00:00+00:00'
                    else: manifest['canonical_words'] = 21
                    path.chmod(0o644); path.write_bytes(magic.document(manifest))
                with self.assertRaises(ValueError): magic.validate_snapshot(output)

    def test_projection_version_pairs_and_recursive_derivations_are_rejected(self):
        for version, profile in ((1, magic.PARSER_PROFILE), (2, None), (2, magic.TITLE_PROFILE), (3, magic.PARSER_PROFILE)):
            with self.subTest(version=version, profile=profile), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp) / 'capture'; self.capture(root)
                source, output = root / 'magic-words', root / magic.DERIVED_DIRECTORY
                magic.derive_snapshot(source, output)
                with self.assertRaisesRegex(ValueError, 'original v1'):
                    magic.derive_snapshot(output, root / 'recursive')
                self.assertFalse((root / 'recursive').exists())
                path = output / 'magic-words.manifest.json'
                manifest = json.loads(path.read_bytes()); manifest.update(version=version, profile=profile)
                path.chmod(0o644); path.write_bytes(magic.document(manifest))
                with self.assertRaisesRegex(ValueError, 'version/profile'):
                    magic.validate_snapshot(output)

    def test_derivation_refuses_corrupt_or_different_original_capture(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / 'capture'; self.capture(root)
            source, output = root / 'magic-words', root / magic.DERIVED_DIRECTORY
            magic.derive_snapshot(source, output)
            other = self.prepare(Path(tmp) / 'other')
            data = self.response(); data['query']['general']['sitename'] = 'different observation'
            magic.capture_snapshot(other, self.wiki, self.date, fetcher=self.fetcher(data))
            with self.assertRaisesRegex(ValueError, 'different source'):
                magic.derive_snapshot(other / 'magic-words', output)
            raw = (source / 'magic-words.tsv').read_bytes().replace('اسم_الصفحة'.encode(), b'INVENTED')
            self.rebind(source, 'magic-words.tsv', raw)
            with self.assertRaisesRegex(ValueError, 'replay'):
                magic.derive_snapshot(source, root / 'corrupt-source-output')
            self.assertFalse((root / 'corrupt-source-output').exists())

    def test_new_projection_directory_never_silently_falls_back_to_old_capture(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / 'capture'; self.capture(root)
            self.assertEqual(magic.selected_snapshot_root(root), root / 'magic-words')
            output = root / magic.DERIVED_DIRECTORY; output.mkdir()
            with self.assertRaises(ValueError): magic.selected_snapshot_root(root)
            output.rmdir(); output.symlink_to(root / 'missing', target_is_directory=True)
            with self.assertRaises(ValueError): magic.selected_snapshot_root(root)
            output.unlink(); shutil.copytree(root / 'magic-words', output)
            with self.assertRaisesRegex(ValueError, 'requires the parser profile'):
                magic.selected_snapshot_root(root)

    def test_source_replacement_during_derivation_does_not_publish(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / 'capture'; self.capture(root)
            source, output = root / 'magic-words', root / magic.DERIVED_DIRECTORY
            real_render = magic.render_snapshot
            def replace_source(data, wiki, date, content_language, profile=magic.TITLE_PROFILE):
                result = real_render(data, wiki, date, content_language, profile)
                if profile == magic.PARSER_PROFILE:
                    path = source / 'magic-words.raw.json'
                    path.chmod(0o644); path.write_bytes(path.read_bytes() + b' ')
                return result
            with patch.object(magic, 'render_snapshot', side_effect=replace_source):
                with self.assertRaisesRegex(ValueError, 'Source capture changed'):
                    magic.derive_snapshot(source, output)
            self.assertFalse(output.exists())

    def test_additional_function_records_are_validated_only_by_expanded_projection(self):
        cases = []
        for field, value in (('aliases', ['bad\talias']), ('case-sensitive', 1)):
            data = self.parser_response()
            next(row for row in data['query']['magicwords'] if row['name'] == 'invoke')[field] = value
            cases.append(data)
        data = self.parser_response()
        data['query']['magicwords'].append(copy.deepcopy(next(row for row in data['query']['magicwords'] if row['name'] == 'invoke')))
        cases.append(data)
        for data in cases:
            with self.subTest(data=data), tempfile.TemporaryDirectory() as tmp:
                root = self.prepare(Path(tmp) / 'capture')
                magic.capture_snapshot(root, self.wiki, self.date, fetcher=self.fetcher(data))
                with self.assertRaises(ValueError):
                    magic.derive_snapshot(root / 'magic-words', root / magic.DERIVED_DIRECTORY)
                self.assertFalse((root / magic.DERIVED_DIRECTORY).exists())

    def test_manifest_cli_derives_and_verifies_offline_with_explicit_profile(self):
        with tempfile.TemporaryDirectory() as tmp:
            project = Path(tmp)
            root = self.prepare(project / 'capture')
            magic.capture_snapshot(root, self.wiki, self.date, fetcher=self.fetcher(self.parser_response()))
            manifest = project / 'manifest.json'
            manifest.write_bytes(magic.document({'auxiliary_capture_roots': {self.wiki: 'capture'}}))
            argv = ['prepare_magic_words.py', '--manifest', str(manifest), '--project', str(project), '--derive-existing']
            with patch.object(magic, 'fetch_response', side_effect=AssertionError('Offline only')) as fetch:
                for extra in ([], ['--verify']):
                    with patch.object(sys, 'argv', argv + extra), contextlib.redirect_stdout(io.StringIO()):
                        self.assertEqual(magic.main(), 0)
                output = root / magic.DERIVED_DIRECTORY
                shutil.rmtree(output); shutil.copytree(root / 'magic-words', output)
                with patch.object(sys, 'argv', argv + ['--verify']), contextlib.redirect_stdout(io.StringIO()):
                    self.assertEqual(magic.main(), 1)
                fetch.assert_not_called()


if __name__ == '__main__':
    unittest.main()
