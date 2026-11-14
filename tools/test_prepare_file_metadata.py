import gzip
import hashlib
import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock
from urllib.parse import parse_qs, urlsplit

import prepare_file_metadata as metadata


WIKI = 'arwiktionary'
DATE = '20261001'


def registry_bytes(media_case='case-sensitive', file_case='case-sensitive'):
    return (
        '# wikidict-namespace-registry-v1\n'
        '# wiki\tarwiktionary\n'
        '# dump-date\t20261001\n'
        '# content-language\tar\n'
        f'-2\tميديا\tMedia\t{media_case}\t0\t0\t1\twikitext\tcompile_only\tvirtual\tAudio\n'
        '0\t\t\tcase-sensitive\t0\t1\t0\twikitext\tmain\tentries\n'
        f'6\tملف\tFile\t{file_case}\t0\t0\t0\twikitext\tsupplemental\tfile\tImage\n'
        '10\tقالب\tTemplate\tfirst-letter\t1\t0\t0\twikitext\tcompile_only\ttemplate\n'
        '14\tتصنيف\tCategory\tfirst-letter\t0\t0\t0\twikitext\tcompile_only\tcategory\n'
    ).encode()


def response(*pages, **query_fields):
    return {'batchcomplete': True, 'query': dict(query_fields, pages=list(pages))}


def present_page(title, width=0, height=0, repository='shared'):
    return {
        'ns': 6, 'title': title, 'missing': True, 'known': True,
        'imagerepository': repository,
        'imageinfo': [{
            'canonicaltitle': title, 'width': width, 'height': height,
            'size': 1234, 'sha1': 'a' * 40, 'mime': 'audio/ogg',
            'timestamp': '2026-10-05T00:00:00Z',
            'url': 'https://upload.wikimedia.org/wikipedia/commons/a/ab/example.ogg',
        }],
    }


def absent_page(title, *, description_exists=False):
    page = {'ns': 6, 'title': title, 'imagerepository': ''}
    if description_exists:
        page['pageid'] = 123
    else:
        page['missing'] = True
    return page


class RegistryTest(unittest.TestCase):
    def test_media_file_and_pinned_aliases_share_native_file_key(self):
        registry = metadata.Registry(registry_bytes(), WIKI, DATE)
        for title in ('Media:Ru-акула.ogg', 'ميديا:Ru-акула.ogg',
                      'File:Ru-акула.ogg', 'ملف:Ru-акула.ogg',
                      'Audio:Ru-акула.ogg', 'IMAGE:Ru-акула.ogg'):
            with self.subTest(title=title):
                self.assertEqual(registry.file_title(title), 'ملف:Ru-акула.ogg')

    def test_nfc_spacing_bidi_and_leading_colon_follow_native_rules(self):
        registry = metadata.Registry(registry_bytes(), WIKI, DATE)
        self.assertEqual(
            registry.file_title(' : Media :\u200f Ru__e\u0301\u00a0cole.ogg '),
            'ملف:Ru é cole.ogg',
        )

    def test_case_sensitive_filename_is_not_folded(self):
        registry = metadata.Registry(registry_bytes(), WIKI, DATE)
        self.assertNotEqual(registry.file_title('File:Ru-акула.ogg'),
                            registry.file_title('File:ru-акула.ogg'))

    def test_media_case_rule_runs_before_file_case_rule(self):
        registry = metadata.Registry(registry_bytes(media_case='first-letter'), WIKI, DATE)
        self.assertEqual(registry.file_title('Media:example.svg'), 'ملف:Example.svg')
        self.assertEqual(registry.file_title('File:example.svg'), 'ملف:example.svg')

    def test_media_conversion_recomposes_titlecase_expansion_before_file_case(self):
        registry = metadata.Registry(registry_bytes(media_case='first-letter'), WIKI, DATE)
        # Native Media -> File runs normalizeTitle twice. Titlecasing U+0390
        # expands it, and the second NFC pass composes capital iota + diaeresis.
        self.assertEqual(registry.file_title('Media:\u0390.svg'), 'ملف:\u03aa\u0301.svg')

    def test_candidate_admission_rejects_unstable_native_key_without_reinterpreting_it(self):
        registry = metadata.Registry(registry_bytes(file_case='first-letter'), WIKI, DATE)
        original = 'File:\u0390.svg'
        native_key = registry.file_title(original)
        reloaded_key = registry.file_title(native_key)
        self.assertNotEqual(native_key, reloaded_key)
        candidates = set()
        with self.assertRaises(ValueError):
            metadata.add_candidate(candidates, original, registry, False)
        self.assertEqual(candidates, set(), 'Do not silently replace the original runtime lookup key')

    def test_first_letter_titlecase_preserves_suffix_and_wmf_override(self):
        registry = metadata.Registry(registry_bytes(file_case='first-letter'), WIKI, DATE)
        for source, expected in (('école.svg', 'École.svg'),
                                 ('ǆABC.svg', 'ǅABC.svg'),
                                 ('ßfoo.svg', 'ßfoo.svg')):
            with self.subTest(source=source):
                self.assertEqual(registry.file_title('File:' + source), 'ملف:' + expected)

    def test_file_prefix_in_filename_is_literal_after_first_prefix(self):
        registry = metadata.Registry(registry_bytes(), WIKI, DATE)
        self.assertEqual(registry.file_title('Media:File:example.svg'), 'ملف:File:example.svg')

    def test_nonfile_empty_and_wrong_registry_identity_are_rejected(self):
        registry = metadata.Registry(registry_bytes(), WIKI, DATE)
        for title in ('Template:Example', 'Example.svg', 'File:', 'Media:   '):
            with self.subTest(title=title), self.assertRaises(ValueError):
                registry.file_title(title)
        for wiki, date in (('frwiktionary', DATE), (WIKI, '20260901')):
            with self.subTest(wiki=wiki, date=date), self.assertRaises(ValueError):
                metadata.Registry(registry_bytes(), wiki, date)


class ClassificationTest(unittest.TestCase):
    def setUp(self):
        self.registry = metadata.Registry(registry_bytes(), WIKI, DATE)
        self.title = 'ملف:Ru-акула.ogg'

    def classify(self, data, titles=None):
        return metadata.classify_response(data, titles or [self.title], self.registry)

    def test_shared_file_with_missing_local_page_and_zero_dimensions_is_present(self):
        record = self.classify(response(present_page(self.title)))[self.title]
        self.assertIs(record['exists'], True)
        self.assertEqual((record['width'], record['height']), (0, 0))
        self.assertEqual(record['repository'], 'shared')

    def test_local_file_dimensions_are_preserved(self):
        page = present_page(self.title, 640, 480, 'local')
        page.pop('missing')
        page.pop('known')
        page['pageid'] = 45
        record = self.classify(response(page))[self.title]
        self.assertIs(record['exists'], True)
        self.assertEqual((record['width'], record['height']), (640, 480))

    def test_explicit_empty_repository_is_negative_even_with_description_page(self):
        for description_exists in (False, True):
            with self.subTest(description_exists=description_exists):
                page = absent_page(self.title, description_exists=description_exists)
                record = self.classify(response(page))[self.title]
                self.assertIs(record['exists'], False)
                self.assertEqual((record['width'], record['height']), (0, 0))

    def test_missing_omitted_invalid_and_unclassified_pages_are_not_negative(self):
        cases = (
            response(),
            response({'ns': 6, 'title': self.title, 'missing': True}),
            response({'ns': 6, 'title': self.title, 'imagerepository': 'shared'}),
            response({'ns': 6, 'title': self.title, 'invalid': True, 'imagerepository': ''}),
            response({'ns': 0, 'title': self.title, 'missing': True, 'imagerepository': ''}),
            response(absent_page('ملف:Unrequested.ogg')),
        )
        for data in cases:
            with self.subTest(data=data), self.assertRaises(ValueError):
                self.classify(data)

    def test_api_error_and_warning_are_not_negative(self):
        data = response(absent_page(self.title))
        for field, value in (
            ('error', {'code': 'maxlag', 'info': 'Waiting for replication'}),
            ('warnings', {'query': {'warnings': 'Title was not processed'}}),
        ):
            with self.subTest(field=field), self.assertRaises(ValueError):
                self.classify(dict(data, **{field: value}))

    def test_response_from_different_edition_is_rejected(self):
        with self.assertRaises(ValueError):
            self.classify(response(present_page(self.title), general={'wikiid': 'frwiktionary'}))

    def test_malformed_query_and_general_containers_are_rejected(self):
        for value in (None, [], 'not an object', 42):
            for data in ({'query': value}, response(present_page(self.title), general=value)):
                with self.subTest(data=data), self.assertRaises(ValueError):
                    self.classify(data)

    def test_equivalent_native_keys_with_same_dimensions_but_different_file_hash_conflict(self):
        alias = 'File:Ru-акула.ogg'
        first, second = present_page(self.title), present_page(alias)
        second['imageinfo'][0]['canonicaltitle'] = self.title
        second['imageinfo'][0]['sha1'] = 'b' * 40
        with self.assertRaises(ValueError):
            self.classify(response(first, second), [self.title, alias])

    def test_hidden_suppressed_and_missing_file_metadata_are_not_positive(self):
        for field in ('filehidden', 'suppressed', 'filemissing'):
            page = present_page(self.title)
            page['imageinfo'][0][field] = True
            with self.subTest(field=field), self.assertRaises(ValueError):
                self.classify(response(page))

    def test_dimensions_require_explicit_unsigned_integers(self):
        for field in ('width', 'height'):
            for value in (-1, 2**32, True, 1.5, '10', None):
                page = present_page(self.title)
                page['imageinfo'][0][field] = value
                with self.subTest(field=field, value=value), self.assertRaises(ValueError):
                    self.classify(response(page))
            page = present_page(self.title)
            del page['imageinfo'][0][field]
            with self.subTest(field=field, missing=True), self.assertRaises(ValueError):
                self.classify(response(page))

    def test_normalization_and_redirect_preserve_original_native_lookup_key(self):
        requested = 'File:Old_name.ogg'
        normalized = 'ملف:Old name.ogg'
        target = 'ملف:New name.ogg'
        data = response(
            present_page(target, 12, 34),
            normalized=[{'from': requested, 'to': normalized}],
            redirects=[{'from': normalized, 'to': target}],
        )
        records = self.classify(data, [requested])
        self.assertEqual(set(records), {normalized})
        self.assertIs(records[normalized]['exists'], True)
        self.assertEqual((records[normalized]['width'], records[normalized]['height']), (12, 34))

    def test_duplicate_pages_conflicting_mappings_and_redirect_cycles_are_rejected(self):
        a, b = 'ملف:A.ogg', 'ملف:B.ogg'
        cases = (
            response(present_page(self.title), absent_page(self.title)),
            response(present_page(a), present_page(b), redirects=[
                {'from': self.title, 'to': a}, {'from': self.title, 'to': b}]),
            response(absent_page(self.title), redirects=[
                {'from': self.title, 'to': a}, {'from': a, 'to': self.title}]),
        )
        for data in cases:
            with self.subTest(data=data), self.assertRaises(ValueError):
                self.classify(data)

    def test_multiple_image_revisions_are_not_silently_combined(self):
        page = present_page(self.title)
        page['imageinfo'].append(dict(page['imageinfo'][0], width=99))
        with self.assertRaises(ValueError):
            self.classify(response(page))

    def test_current_file_metadata_allows_older_revision_continuation(self):
        data = response(present_page(self.title))
        data['continue'] = {'iistart': '2020-01-01T00:00:00Z', 'continue': '||'}
        self.assertIs(self.classify(data)[self.title]['exists'], True)

    def test_unrelated_continuation_is_rejected(self):
        data = response(present_page(self.title))
        data['continue'] = {'gapcontinue': 'Incomplete_page_set', 'continue': '||'}
        with self.assertRaises(ValueError):
            self.classify(data)

    def test_empty_or_contradictory_imageinfo_is_not_classified(self):
        for repository, info in (('shared', []), ('shared', {}),
                                 ('', present_page(self.title)['imageinfo'])):
            page = {'ns': 6, 'title': self.title, 'imagerepository': repository,
                    'imageinfo': info}
            with self.subTest(repository=repository, info=info), self.assertRaises(ValueError):
                self.classify(response(page))

    def test_render_is_sorted_four_column_tsv_with_explicit_negative_zeroes(self):
        a, b = 'ملف:A.ogg', 'ملف:B.ogg'
        records = self.classify(response(absent_page(b), present_page(a, 12, 34)), [b, a])
        rows = [line for line in metadata.render(records).decode().split('\n')
                if line and not line.startswith('#')]
        self.assertEqual(rows, [a + '\t1\t12\t34', b + '\t0\t0\t0'])


class BatchingTest(unittest.TestCase):
    def test_encoded_unicode_request_size_splits_batches_without_losing_titles(self):
        titles = ['ملف:' + 'я' * 40 + str(number) + '.ogg' for number in range(80)]
        self.assertGreater(len(metadata.query_url(WIKI, titles[:50]).encode('ascii')), metadata.MAX_URL)
        batches = list(metadata.title_batches(WIKI, titles, 50))
        self.assertEqual([title for batch in batches for title in batch], titles)
        self.assertTrue(all(1 <= len(batch) <= 50 for batch in batches))
        self.assertTrue(all(len(metadata.query_url(WIKI, batch).encode('ascii')) <= metadata.MAX_URL
                            for batch in batches))
        self.assertGreater(len(batches), 2)

    def test_configured_title_count_limit_still_applies(self):
        titles = [f'ملف:File{number}.svg' for number in range(17)]
        batches = list(metadata.title_batches(WIKI, titles, 7))
        self.assertEqual([len(batch) for batch in batches], [7, 7, 3])
        self.assertEqual([title for batch in batches for title in batch], titles)


class CaptureTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='file-metadata-test-', dir='.tmp')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.namespace_path = self.root / 'namespace-registry.tsv'
        self.namespace_path.write_bytes(registry_bytes())
        self.registry = metadata.Registry(registry_bytes(), WIKI, DATE)
        self.seed_path = self.root / 'titles.txt'
        self.seed_path.write_text('Media:Ru-акула.ogg\n', encoding='utf-8')
        self.args = SimpleNamespace(
            wiki=WIKI, date=DATE, namespace_registry=self.namespace_path,
            output=self.root / 'capture', log=[], titles=[self.seed_path], sql=[],
            dumpstatus=None, russian_variants=True, batch_size=50, delay=1.0,
            wall_seconds=1800,
        )
        self.calls = []
        self.responses = []

    def transport(self, url, timeout):
        self.assertGreater(timeout, 0)
        parts = urlsplit(url)
        self.assertEqual(parts.scheme, 'https')
        self.assertEqual(parts.netloc, 'ar.wiktionary.org')
        query = parse_qs(parts.query)
        titles = query.get('titles', [''])[0].split('|')
        self.assertTrue(titles and all(titles))
        self.assertEqual(query.get('prop'), ['imageinfo'])
        self.calls.append(titles)
        pages, normalized = [], []
        for title in titles:
            native = self.registry.file_title(title)
            if title != native:
                normalized.append({'from': title, 'to': native})
            page = present_page(native) if native == 'ملف:Ru-акула.ogg' else absent_page(native)
            pages.append(page)
        data = response(*pages, general={'wikiid': WIKI})
        if normalized:
            data['query']['normalized'] = normalized
        raw = json.dumps(data, ensure_ascii=False).encode()
        self.responses.append(raw)
        return 200, {'Content-Type': 'application/json'}, raw

    def capture(self, transport=None):
        return metadata.capture(self.args, transport=transport or self.transport, sleep=lambda seconds: None)

    def sql_seed(self, table='image'):
        field = 'img_name' if table == 'image' else 'il_to'
        raw = (f'CREATE TABLE `{table}` (\n'
               f'  `{field}` varbinary(255) NOT NULL\n'
               ');\n'
               f"INSERT INTO `{table}` VALUES ('Ru-акула.ogg'),('Other_image.svg');\n").encode()
        path = self.root / f'{WIKI}-{DATE}-{table}.sql.gz'
        compressed = gzip.compress(raw, mtime=0)
        path.write_bytes(compressed)
        status = {'jobs': {table + 'table': {'status': 'done', 'files': {path.name: {
            'size': len(compressed), 'sha1': hashlib.sha1(compressed).hexdigest(),
            'url': f'/{WIKI}/{DATE}/{path.name}',
        }}}}}
        return path, status

    def test_capture_seeds_russian_variants_and_verifies_offline(self):
        self.args.batch_size = 2
        manifest = self.capture()
        queried = [self.registry.file_title(title) for batch in self.calls for title in batch]
        self.assertCountEqual(queried, ['ملف:Ru-акула.ogg', 'ملف:Ru-акула.oga', 'ملف:Ru акула.ogg'])
        self.assertTrue(all(len(batch) <= 2 for batch in self.calls))
        self.assertEqual(len(queried), len(set(queried)))
        self.assertEqual(metadata.verify(self.args.output), manifest)
        for filename in ('file-metadata.tsv', 'file-metadata.manifest.json', 'file-metadata.complete.json'):
            self.assertTrue((self.args.output / filename).is_file(), filename)
        rows = (self.args.output / 'file-metadata.tsv').read_text().splitlines()
        self.assertIn('ملف:Ru-акула.ogg\t1\t0\t0', rows)
        self.assertIn('ملف:Ru-акула.oga\t0\t0\t0', rows)
        self.assertIn('ملف:Ru акула.ogg\t0\t0\t0', rows)

    def test_log_seed_forms_deduplicate_to_one_requested_key_without_variants(self):
        log = self.root / 'build.log'
        log.write_text(
            'warning: file metadata snapshot unavailable: title=Media:Ru-акула.ogg\n'
            'warning: file metadata missing: title=ملف:Ru-акула.ogg\n'
            'unrelated title=File:Not a missing metadata probe.svg\n', encoding='utf-8')
        self.args.log = [log]
        self.args.titles = []
        self.args.russian_variants = False
        self.capture()
        self.assertEqual([self.registry.file_title(t) for batch in self.calls for t in batch],
                         ['ملف:Ru-акула.ogg'])

    def test_pinned_sql_candidates_capture_and_replay_offline(self):
        path, status = self.sql_seed()
        status_path = self.root / 'dumpstatus.json'
        status_path.write_text(json.dumps(status))
        self.args.sql = [path]
        self.args.titles = []
        self.args.dumpstatus = status_path
        self.args.russian_variants = False
        manifest = self.capture()
        self.assertCountEqual([title for batch in self.calls for title in batch],
                              ['ملف:Ru-акула.ogg', 'ملف:Other image.svg'])
        self.assertEqual(metadata.verify(self.args.output), manifest)

    def test_sql_requires_pinned_sha1_size_url_and_complete_job(self):
        for table in ('image', 'imagelinks'):
            path, status = self.sql_seed(table)
            titles = set()
            metadata.seed_sql(path, status, titles, self.registry, False)
            self.assertEqual(titles, {'ملف:Ru-акула.ogg', 'ملف:Other image.svg'})
            for field, value in (('sha1', '0' * 40), ('size', 0), ('url', '/wrong/date.sql.gz'),
                                 ('status', 'in-progress')):
                invalid = json.loads(json.dumps(status))
                job = invalid['jobs'][table + 'table']
                (job if field == 'status' else job['files'][path.name])[field] = value
                candidates = set()
                with self.subTest(table=table, field=field), self.assertRaises(ValueError):
                    metadata.seed_sql(path, invalid, candidates, self.registry, False)
                self.assertEqual(candidates, set(), 'Reject unverified SQL before admitting candidates')

    def test_offline_verification_rejects_tsv_and_raw_evidence_tampering(self):
        self.capture()
        output = self.args.output / 'file-metadata.tsv'
        original = output.read_bytes()
        output.write_bytes(original + 'ملف:Forged.ogg\t0\t0\t0\n'.encode())
        with self.assertRaises(ValueError):
            metadata.verify(self.args.output)
        output.write_bytes(original)
        raw_paths = [path for path in self.args.output.rglob('*')
                     if path.is_file() and path.read_bytes() in self.responses]
        self.assertTrue(raw_paths, 'Capture must retain exact raw API response bytes')
        raw_paths[0].write_bytes(b'{}\n')
        with self.assertRaises(ValueError):
            metadata.verify(self.args.output)

    def test_compact_manifest_pins_separate_evidence_and_rejects_tampering(self):
        manifest = self.capture()
        raw = (self.args.output / 'file-metadata.manifest.json').read_bytes()
        self.assertLessEqual(len(raw), 64 * 1024)
        reference = manifest['evidence']
        self.assertEqual(reference['path'], 'capture-evidence.json')
        path = self.args.output / reference['path']
        evidence_raw = path.read_bytes()
        self.assertEqual(reference['size'], len(evidence_raw))
        self.assertEqual(reference['sha256'], hashlib.sha256(evidence_raw).hexdigest())
        evidence = json.loads(evidence_raw)
        fields = {'namespace_registry', 'input_sources', 'dumpstatus', 'russian_variants',
                  'batches', 'artifacts'}
        self.assertEqual(set(evidence), fields)
        self.assertFalse(fields.intersection(manifest))
        self.assertNotIn('capture-evidence.json', evidence['artifacts'])
        self.assertEqual(metadata.verify(self.args.output), manifest)
        path.write_bytes(evidence_raw + b'\n')
        with self.assertRaises(ValueError):
            metadata.verify(self.args.output)

    def test_single_oversized_encoded_title_fails_before_transport(self):
        title = 'File:' + 'я' * 1500 + '.ogg'
        self.seed_path.write_text(title + '\n', encoding='utf-8')
        self.args.russian_variants = False
        with self.assertRaises(ValueError):
            self.capture()
        self.assertEqual(self.calls, [])
        for name in ('file-metadata.tsv', 'file-metadata.manifest.json', 'file-metadata.complete.json'):
            self.assertFalse((self.args.output / name).exists(), name)

    def test_invalid_response_retains_raw_evidence_but_publishes_no_final_pair(self):
        failed_raw = []
        def invalid_transport(url, timeout):
            status, headers, raw = self.transport(url, timeout)
            data = json.loads(raw)
            data['warnings'] = {'imageinfo': {'warnings': 'Incomplete upstream result'}}
            raw = json.dumps(data, ensure_ascii=False).encode()
            failed_raw.append(raw)
            return status, headers, raw
        with self.assertRaises(ValueError):
            self.capture(invalid_transport)
        for filename in ('file-metadata.tsv', 'file-metadata.manifest.json', 'file-metadata.complete.json'):
            self.assertFalse((self.args.output / filename).exists(), filename)
        self.assertTrue(any(path.is_file() and path.read_bytes() in failed_raw
                            for path in self.args.output.rglob('*')),
                        'Failed capture must retain its exact raw response')

    def test_final_replay_failure_preserves_evidence_without_final_pair(self):
        with mock.patch.object(metadata, 'verify', side_effect=ValueError('Injected final replay failure')):
            with self.assertRaisesRegex(ValueError, 'Injected final replay failure'):
                self.capture()
        for name in ('file-metadata.tsv', 'file-metadata.manifest.json', 'file-metadata.complete.json'):
            self.assertFalse((self.args.output / name).exists(), name)
        for name in ('file-metadata.tsv.unverified', 'file-metadata.manifest.json.unverified', 'failure.json'):
            self.assertTrue((self.args.output / name).is_file(), name)
        self.assertTrue(any(path.is_file() and path.read_bytes() in self.responses
                            for path in self.args.output.rglob('*')))

    def test_maxlag_and_429_retries_preserve_raw_responses_and_receipts(self):
        self.args.russian_variants = False
        sleeps, failed_raw, calls = [], [], []
        def retry_transport(url, timeout):
            calls.append(url)
            if len(calls) == 1:
                raw = b'{"error":{"code":"maxlag","info":"Waiting"}}'
                failed_raw.append(raw)
                return 200, {}, raw
            if len(calls) == 2:
                raw = b'Too many requests\n'
                failed_raw.append(raw)
                return 429, {'Retry-After': '3'}, raw
            return self.transport(url, timeout)
        manifest = metadata.capture(self.args, transport=retry_transport, sleep=sleeps.append)
        self.assertEqual(len(calls), 3)
        self.assertEqual(sleeps, [1.0, 3])
        receipts = [json.loads(path.read_bytes()) for path in sorted(
            self.args.output.glob('responses/*.receipt.json'))]
        self.assertEqual([row['accepted'] for row in receipts], [False, False, True])
        self.assertEqual(receipts[0]['api_error_code'], 'maxlag')
        self.assertEqual([row['status'] for row in receipts], [200, 429, 200])
        self.assertEqual([(self.args.output / row['response']).read_bytes() for row in receipts[:2]], failed_raw)
        self.assertEqual(metadata.verify(self.args.output), manifest)

    def test_retries_stop_after_four_attempts_without_publishing(self):
        self.args.russian_variants = False
        calls, sleeps = [], []
        def limited_transport(url, timeout):
            calls.append(url)
            return 429, {}, b'Retry later\n'
        with self.assertRaises(ValueError):
            metadata.capture(self.args, transport=limited_transport, sleep=sleeps.append)
        self.assertEqual(len(calls), 4)
        self.assertEqual(sleeps, [1.0, 2, 4])
        receipts = list(self.args.output.glob('responses/*.receipt.json'))
        self.assertEqual(len(receipts), 4)
        self.assertTrue(all(json.loads(path.read_bytes())['accepted'] is False for path in receipts))
        self.assertFalse((self.args.output / 'file-metadata.tsv').exists())
        self.assertFalse((self.args.output / 'file-metadata.manifest.json').exists())

    def test_existing_output_is_refused_without_network_or_modification(self):
        self.args.output.mkdir()
        sentinel = self.args.output / 'keep.txt'
        sentinel.write_text('existing user evidence\n')
        with self.assertRaises((ValueError, FileExistsError)):
            self.capture()
        self.assertEqual(self.calls, [])
        self.assertEqual(sentinel.read_text(), 'existing user evidence\n')


class BoundedHttpContentCodingTests(unittest.TestCase):
    url = 'https://ar.wiktionary.org/w/api.php?action=query'

    def http_response(self, body, coding=None, *, status=200, url=None, retry_after=None):
        import io
        from email.message import Message
        response = io.BytesIO(body)
        response.url = url or self.url
        response.status = status
        response.headers = Message()
        response.headers['Content-Type'] = 'application/json'
        response.headers['Content-Length'] = str(len(body))
        if coding is not None:
            response.headers['Content-Encoding'] = coding
        if retry_after is not None:
            response.headers['Retry-After'] = retry_after
        return response

    def test_gzip_negotiation_preserves_identity_and_original_json_bytes(self):
        raw = b'{"value": "unchanged JSON whitespace"}\n'
        for coding, body in ((None, raw), ('identity', raw), ('gzip', gzip.compress(raw, mtime=0))):
            with self.subTest(coding=coding):
                response = self.http_response(body, coding)
                with mock.patch.object(metadata.urllib.request, 'urlopen', return_value=response) as opened:
                    status, headers, actual = metadata.get_response(self.url, 7)
                self.assertEqual((status, actual), (200, raw))
                self.assertEqual(headers['Content-Length'], str(len(body)))
                request = opened.call_args.args[0]
                self.assertEqual(request.full_url, self.url)
                self.assertEqual(request.get_header('Accept-encoding'), 'gzip')
                self.assertEqual(request.get_header('User-agent'), metadata.AGENT)
                self.assertEqual(opened.call_args.kwargs, {'timeout': 7})
                self.assertTrue(response.closed)

    def test_gzip_decoded_cap_keeps_exact_oversized_prefix_and_wire_cap(self):
        limit = 1024
        raw = b'x' * (limit * 100)
        response = self.http_response(gzip.compress(raw, mtime=0), 'gzip')
        with mock.patch.object(metadata, 'MAX_RESPONSE', limit), \
                mock.patch.object(metadata.urllib.request, 'urlopen', return_value=response):
            self.assertEqual(metadata.get_response(self.url, 7)[2], raw[:limit+1])
        response = self.http_response(b'x' * (limit+2), 'gzip')
        with mock.patch.object(metadata, 'MAX_RESPONSE', limit), \
                mock.patch.object(metadata.urllib.request, 'urlopen', return_value=response):
            with self.assertRaisesRegex(ValueError, 'Oversized encoded'):
                metadata.get_response(self.url, 7)
        self.assertTrue(response.closed)

    def test_corrupt_truncated_or_unknown_coding_never_returns_accepted_json(self):
        valid = gzip.compress(b'{"ok":true}', mtime=0)
        corrupt = valid[:-8] + bytes([valid[-8] ^ 1]) + valid[-7:]
        for body, coding in ((valid[:-1], 'gzip'), (corrupt, 'gzip'), (b'{}', 'br'),
                             (valid, 'gzip,gzip'), (valid+b'junk', 'gzip')):
            with self.subTest(coding=coding, size=len(body)):
                response = self.http_response(body, coding)
                with mock.patch.object(metadata.urllib.request, 'urlopen', return_value=response):
                    with self.assertRaises(ValueError):
                        metadata.get_response(self.url, 7)
                self.assertTrue(response.closed)
        response = self.http_response(gzip.compress(b'{', mtime=0)+gzip.compress(b'}', mtime=0), 'gzip')
        with mock.patch.object(metadata.urllib.request, 'urlopen', return_value=response):
            self.assertEqual(metadata.get_response(self.url, 7)[2], b'{}')

    def test_redirect_endpoint_check_and_compressed_http_errors_remain(self):
        import urllib.error
        raw = b'{"error":{"code":"ratelimited"}}'
        coded = gzip.compress(raw, mtime=0)
        response = self.http_response(coded, 'gzip', status=429, retry_after='2')
        error = urllib.error.HTTPError(self.url, 429, 'rate limited', response.headers, response)
        with mock.patch.object(metadata.urllib.request, 'urlopen', side_effect=error):
            status, headers, actual = metadata.get_response(self.url, 7)
        self.assertEqual((status, headers['Retry-After'], actual), (429, '2', raw))
        self.assertTrue(response.closed)
        response = self.http_response(coded, 'gzip', url='https://other.example/w/api.php')
        with mock.patch.object(metadata.urllib.request, 'urlopen', return_value=response):
            with self.assertRaisesRegex(ValueError, 'Unexpected API redirect endpoint'):
                metadata.get_response(self.url, 7)
        self.assertTrue(response.closed)

    def test_normal_v1_v2_retry_receipts_archive_decoded_bytes_and_actual_coding(self):
        import time
        import prepare_file_metadata_v2 as v2
        registry = metadata.Registry(registry_bytes(), WIKI, DATE)
        title = 'File:Example.svg'
        native = registry.file_title(title)
        page = present_page(native, 100, 80)
        page['imageinfo'][0].update(mime='image/svg+xml', mediatype='DRAWING')
        data = response(page, general={'wikiid': WIKI}, normalized=[{'from':title, 'to':native}])
        raw = json.dumps(data, ensure_ascii=False).encode()
        coded = gzip.compress(raw, mtime=0)
        error_raw = b'{"error":{"code":"ratelimited"}}'
        for producer in (metadata, v2):
            with self.subTest(producer=producer.__name__), tempfile.TemporaryDirectory(dir='.tmp') as temporary:
                root = Path(temporary)
                url = producer.query_url(WIKI, [title])
                responses = [self.http_response(gzip.compress(error_raw, mtime=0), 'gzip', status=429,
                                                url=url, retry_after='2'),
                             self.http_response(coded, 'gzip', url=url)]
                sleeps = []
                with mock.patch.object(metadata.urllib.request, 'urlopen', side_effect=responses) as opened:
                    records, batch = producer.request_batch(root, 1, [title], registry,
                        metadata.get_response, sleeps.append, time.monotonic()+60, 1)
                self.assertEqual(opened.call_count, 2)
                self.assertEqual(sleeps, [2])
                self.assertTrue(records[native]['exists'])
                receipt = json.loads((root/batch['accepted_receipt']).read_bytes())
                self.assertEqual(receipt['headers']['content-encoding'], 'gzip')
                self.assertEqual(receipt['headers']['content-length'], str(len(coded)))
                self.assertEqual(receipt['response_bytes'], len(raw))
                self.assertEqual(receipt['response_sha256'], hashlib.sha256(raw).hexdigest())
                self.assertEqual((root/receipt['response']).read_bytes(), raw)
                if producer is v2:
                    with mock.patch.object(metadata.urllib.request, 'urlopen', side_effect=AssertionError('offline')):
                        self.assertEqual(v2.verified_batch(root, batch, WIKI, {p.name for p in root.iterdir()}),
                                         ([title], raw))


class OriginalSpacingRegistry(metadata.Registry):
    """The pre-change normalizer is the independent paired result/cost oracle."""
    def spacing(self, text):
        raw = text.encode('utf-8')
        if len(raw) > 4096 or '\0' in text:
            raise ValueError('Invalid or oversized file title')
        count = self.nfc_lib.utf8proc_decompose(raw, len(raw), None, 0, 10)
        if count < 0 or count > 16384:
            raise ValueError('Cannot normalize file title')
        storage = (metadata.ctypes.c_int32 * (count + 1))()
        if self.nfc_lib.utf8proc_decompose(raw, len(raw), storage, count, 10) != count:
            raise ValueError('Unicode normalization failed')
        length = self.nfc_lib.utf8proc_reencode(storage, count, 10)
        if length < 0 or length >= metadata.ctypes.sizeof(storage):
            raise ValueError('Unicode normalization failed')
        normalized = metadata.ctypes.string_at(storage, length).decode('utf-8')
        result, pending = [], False
        for char in normalized:
            if char in metadata.BIDI:
                continue
            if char in metadata.SPACES:
                pending = bool(result)
            else:
                if pending:
                    result.append(' ')
                result.append(char); pending = False
        return ''.join(result)


class SpacingKernelTests(unittest.TestCase):
    def registries(self):
        raw = registry_bytes(media_case='first-letter', file_case='first-letter')
        return (metadata.Registry(raw, WIKI, DATE), OriginalSpacingRegistry(raw, WIKI, DATE), raw)

    @staticmethod
    def outcome(function, value):
        try:
            return ('value', function(value))
        except (ValueError, UnicodeError, TypeError, AttributeError) as error:
            return ('error', type(error).__name__, str(error))

    def test_explicit_spacing_unicode_boundaries_equal_original(self):
        current, original, raw = self.registries()
        held = (raw, dict(current.aliases), {key: dict(value) for key, value in current.specs.items()})
        for separator in sorted(metadata.SPACES):
            for value, expected in ((separator, ''), ('A' + separator + 'B', 'A B'),
                                    (separator + 'A' + separator * 3 + 'B' + separator, 'A B')):
                with self.subTest(separator=ord(separator), value=value):
                    self.assertEqual(current.spacing(value), expected)
                    self.assertEqual(current.spacing(value), original.spacing(value))
        for bidi in sorted(metadata.BIDI):
            for value, expected in (('A' + bidi + 'B', 'AB'), (' _A\t' + bidi + '_B ', 'A B'),
                                    (bidi + '\u1100\u1161\u11a8' + bidi, '\uac01')):
                with self.subTest(bidi=ord(bidi), value=value):
                    self.assertEqual(current.spacing(value), expected)
                    self.assertEqual(current.spacing(value), original.spacing(value))
        # These characters are not members of the explicit MediaWiki space set.
        # Generic Unicode whitespace splitting would incorrectly change several.
        for character in ('\v', '\f', '\x1c', '\x1d', '\x1e', '\x1f', '\u0085', '\u200b', '\u2060', '\ufeff'):
            self.assertNotIn(character, metadata.SPACES | metadata.BIDI)
            value = 'A' + character + 'B'
            self.assertEqual(current.spacing(value), value)
            self.assertEqual(current.spacing(value), original.spacing(value))
        cases = ('', 'e\u0301', '\u1100\u1161\u11a8', '\u03b9\u0308\u0301',
                 '\u0627\u0654', 'a' * 4096, '\u00e9' * 2048, ' ' * 4096,
                 'a' * 4097, '\u00e9' * 2049, 'a\0b', '\ud800')
        for value in cases:
            with self.subTest(length=len(value), prefix=repr(value[:12])):
                self.assertEqual(self.outcome(current.spacing, value), self.outcome(original.spacing, value))
        self.assertEqual(current.spacing('e\u0301'), '\u00e9')
        self.assertEqual(held, (raw, current.aliases, current.specs))

    def test_file_keys_and_native_normalization_failures_equal_original(self):
        current, original, raw = self.registries()
        cases = ('File:e\u0301cole.svg', ' : Media :\u200f Ru__e\u0301\u00a0cole.ogg ',
                 'Media:\u0390.svg', 'File:\u0390.svg', 'File:\u00dffoo.svg',
                 'IMAGE:Japanese_\u74f6_\u1100\u1161\u11a8.svg', 'Audio:Ru-\u0430\u043a\u0443\u043b\u0430.ogg',
                 'File:File:example.svg', 'File:A\vB.svg', 'File:A\u0085B.svg',
                 'Template:Example', 'Example.svg', 'File:', 'Media:   ',
                 'File:A|B.svg', 'File:A\0B.svg', 'File:' + 'x' * 4096, None, 4)
        for value in cases:
            with self.subTest(value=repr(value)[:100]):
                self.assertEqual(self.outcome(current.file_title, value), self.outcome(original.file_title, value))
        failures = (([-1], 0), ([16385], 0), ([1, 0], 0), ([1, 1], -1), ([1, 1], 8))
        for decompositions, length in failures:
            outcomes = []
            for registry in (current, original):
                library = SimpleNamespace(
                    utf8proc_decompose=mock.Mock(side_effect=list(decompositions)),
                    utf8proc_reencode=mock.Mock(return_value=length))
                with mock.patch.object(registry, 'nfc_lib', library):
                    outcomes.append(self.outcome(registry.spacing, 'A'))
            self.assertEqual(outcomes[0], outcomes[1])
            self.assertEqual(outcomes[0][0], 'error')
        self.assertEqual(raw, registry_bytes(media_case='first-letter', file_case='first-letter'))
        self.assertEqual(current.aliases, original.aliases)
        self.assertEqual(current.specs, original.specs)

    def test_report_paired_unprofiled_spacing_and_file_title_task_cost(self):
        import sys
        import time
        self.assertIsNone(sys.getprofile(), 'Measure the ordinary call path without cProfile overhead')
        current, original, raw = self.registries()
        bodies = (
            'Example.svg', 'Ru-\u0430\u043a\u0443\u043b\u0430.ogg', 'e\u0301cole_illustration.jpg',
            'Long_filename_with_four_words_and_2026_(detail).png', '\u74f6_\u1100\u1161\u11a8.svg',
            '\u03b9\u0308\u0301_\u03b1\u03b2\u03b3.png', '\u00dffoo.svg', '\u01c6ABC.svg',
            '\u0627\u0654_\u0628\u064a\u062a.jpg', '\u05d0\u05b7_\u05d1.svg',
            'A\u00a0B\u202fC\u3000D.svg', '\u200fA_B\u202c.svg',
            'Mixed_\u30ab\u30bf\u30ab\u30ca_\u00e9_42.jpg', 'a' * 120 + '.svg',
            'No_change-required.ogg', '\u0390.svg',
        )
        titles = tuple(prefix + body for prefix in ('File:', 'Media:') for body in bodies)
        spaces = tuple(' _' + body + '\u200f\t' for body in bodies) + bodies
        inputs = (titles, spaces, raw)
        rows = []
        rounds = 256
        for operation, values in (('spacing', spaces), ('file_title', titles)):
            expected = tuple(getattr(original, operation)(value) for value in values) * rounds
            self.assertEqual(tuple(getattr(current, operation)(value) for value in values) * rounds, expected)
            for position, (label, registry) in enumerate((('baseline', original), ('candidate', current),
                                                        ('candidate', current), ('baseline', original))):
                function = getattr(registry, operation)
                wall_start = time.perf_counter_ns()
                cpu_start = time.process_time_ns()
                actual = tuple(function(value) for _ in range(rounds) for value in values)
                cpu_ns = time.process_time_ns() - cpu_start
                wall_ns = time.perf_counter_ns() - wall_start
                self.assertEqual(actual, expected)
                rows.append(dict(operation=operation, position=position, implementation=label,
                                 calls=len(values) * rounds, process_cpu_ns=cpu_ns, wall_ns=wall_ns))
        self.assertEqual(inputs, (titles, spaces, raw))
        self.assertEqual(current.aliases, original.aliases)
        self.assertEqual(current.specs, original.specs)
        print('FILE_TITLE_SPACING_PAIRED ' + json.dumps(dict(
            order='ABBA per operation', profiled=False, parity=True, input_unchanged=True,
            setup_excluded=True, whole_capture_measured=False, rows=rows), sort_keys=True), flush=True)


if __name__ == '__main__':
    unittest.main()
