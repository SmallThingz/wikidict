import copy
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import Mock

import prepare_magic_words as magic


class MagicWordCaptureTests(unittest.TestCase):
    wiki = 'arwiktionary'
    date = '20261001'

    def response(self):
        words = [{'name': name, 'case-sensitive': True, 'aliases': [name.upper()]}
                 for name in sorted(magic.SUPPORTED)]
        next(row for row in words if row['name'] == 'pagename')['aliases'] += ['اسم_الصفحة']
        return {'query': {'general': {'wikiid': self.wiki, 'lang': 'ar'}, 'magicwords': words}}

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


if __name__ == '__main__':
    unittest.main()
