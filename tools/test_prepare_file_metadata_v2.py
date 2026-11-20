import copy
import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock
from urllib.parse import parse_qs, urlsplit

import build_wiktionaries as builder
import prepare_file_metadata as v1
import prepare_file_metadata_v2 as v2
from test_prepare_file_metadata import registry_bytes, present_page, absent_page, response

WIKI, DATE = 'arwiktionary', '20261001'


def present(title, mediatype='AUDIO', canonical=None):
    page = present_page(title)
    page['imageinfo'][0]['mediatype'] = mediatype
    if canonical is not None:
        page['imageinfo'][0]['canonicaltitle'] = canonical
    return page


class ClassificationTest(unittest.TestCase):
    def setUp(self):
        self.registry = v1.Registry(registry_bytes(), WIKI, DATE)

    def test_authoritative_type_and_redirect_canonical_title_not_filename_extension(self):
        data = response(present('File:Canonical.bin', canonical='File:Canonical.bin'),
                        redirects=[{'from': 'File:Alias.svg', 'to': 'File:Canonical.bin'}])
        rows = v2.classify_response(data, ['File:Alias.svg'], self.registry)
        self.assertEqual(rows['ملف:Alias.svg']['mediatype'], 'AUDIO')
        self.assertEqual(rows['ملف:Alias.svg']['canonicaltitle'], 'ملف:Canonical.bin')
        self.assertIn('ملف:Alias.svg\t1\t0\t0\tAUDIO\tملف:Canonical.bin\n', v2.render(rows).decode())

    def test_missing_and_unknown_mediatype_do_not_become_audio_or_negative(self):
        for value in (None, '', 'audio', 'NOT_A_MEDIAWIKI_TYPE', [], 1):
            with self.subTest(value=value):
                page = present('File:Example.ogg')
                if value is None:
                    del page['imageinfo'][0]['mediatype']
                else:
                    page['imageinfo'][0]['mediatype'] = value
                with self.assertRaises(ValueError):
                    v2.classify_response(response(page), ['File:Example.ogg'], self.registry)

    def test_all_exact_mediawiki_types_are_preserved(self):
        for kind in v2.MEDIATYPES:
            with self.subTest(kind=kind):
                rows = v2.classify_response(response(present('File:Example.ogg', kind)),
                                           ['File:Example.ogg'], self.registry)
                self.assertEqual(rows['ملف:Example.ogg']['mediatype'], kind)

    def test_explicit_negative_has_no_type_or_canonical_title(self):
        rows = v2.classify_response(response(absent_page('File:Missing.ogg')),
                                   ['File:Missing.ogg'], self.registry)
        self.assertEqual(v2.render(rows).decode(),
                         '# wikidict-file-metadata-v2\nملف:Missing.ogg\t0\t0\t0\t-\t-\n')

    def test_original_v1_acceptance_and_four_field_render_are_unchanged(self):
        data = response(present_page('File:Example.ogg'))
        original = copy.deepcopy(data)
        rows = v1.classify_response(data, ['File:Example.ogg'], self.registry)
        self.assertEqual(v1.render(rows).decode(), '# wikidict-file-metadata-v1\nملف:Example.ogg\t1\t0\t0\n')
        self.assertEqual(data, original)
        self.assertNotIn('mediatype', rows['ملف:Example.ogg'])
        self.assertNotIn('mediatype', v1.query_for(WIKI, ['File:Example.ogg'])['iiprop'])

    def test_v2_still_rejects_unknown_repository_and_unrequested_page(self):
        for data in (response({'ns': 6, 'title': 'File:Example.ogg'}),
                     response(present('File:Other.ogg'))):
            with self.assertRaises(ValueError):
                v2.classify_response(data, ['File:Example.ogg'], self.registry)


class CaptureReplayTest(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='file-metadata-v2-', dir='.tmp')
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.namespace = self.root / 'namespace-registry.tsv'
        self.namespace.write_bytes(registry_bytes())
        self.seed = self.root / 'titles.txt'
        self.seed.write_text('File:Example.bin\nFile:Missing.ogg\n')
        self.args = SimpleNamespace(wiki=WIKI, date=DATE, namespace_registry=self.namespace,
                    output=self.root / 'capture', titles=[self.seed], log=[], batch_size=1,
                    delay=0, wall_seconds=30)
        self.calls = []

    def transport(self, url, timeout):
        self.assertGreater(timeout, 0)
        query = parse_qs(urlsplit(url).query)
        self.assertEqual(query['iiprop'], ['size|sha1|timestamp|canonicaltitle|mediatype'])
        self.assertEqual(query['iilimit'], ['1'])
        titles = query['titles'][0].split('|')
        self.calls.append(titles)
        pages = [absent_page(t) if t.endswith('Missing.ogg') else present(t) for t in titles]
        return 200, {}, v1.encoded(response(*pages, general={'wikiid': WIKI}))

    def capture(self):
        return v2.capture(self.args, transport=self.transport, sleep=lambda _: None)

    def rewrite_index_and_manifest(self, manifest, index):
        # A coherent hash rewrite must still fail semantic replay against API bytes.
        index['artifacts'] = v2.payload(self.args.output)
        raw = v1.encoded(index)
        (self.args.output / v2.EVIDENCE).write_bytes(raw)
        manifest['evidence'].update(size=len(raw), sha256=v1.digest(raw))
        manifest_raw = v1.encoded(manifest)
        (self.args.output / v2.MANIFEST).write_bytes(manifest_raw)
        (self.args.output / v2.COMPLETE).write_bytes(v1.encoded(
            {'schema': v2.SCHEMA, 'manifest_sha256': v1.digest(manifest_raw)}))

    def test_capture_replay_and_builder_pin_keep_all_raw_artifacts(self):
        old_bytes = Path(v1.__file__).read_bytes()
        manifest = self.capture()
        self.assertEqual(len(self.calls), 2)
        self.assertEqual(v2.verify(self.args.output), manifest)
        snapshots = {'file-metadata': self.args.output / 'file-metadata.tsv',
                     'namespace-registry': self.namespace}
        hashes = builder.verified_auxiliary_hashes(snapshots, WIKI, DATE)
        capture_hashes, artifact_hashes = builder.auxiliary_capture_identities(snapshots, WIKI, DATE)
        pinned = builder.pinned_auxiliary_snapshots(snapshots, hashes, self.root / 'pinned',
                                                   capture_hashes, artifact_hashes)
        self.assertEqual(v2.validate_snapshot(pinned['file-metadata'], WIKI, DATE), manifest)
        before = v2.capture_artifacts(snapshots['file-metadata'], manifest)
        after = v2.capture_artifacts(pinned['file-metadata'], manifest)
        self.assertEqual(before, after)
        self.assertTrue(all(Path(name).name == name for name in after))
        self.assertTrue(any(name.endswith('.raw.json') for name in after))
        self.assertEqual(Path(v1.__file__).read_bytes(), old_bytes)

    def test_changed_namespace_is_rejected_by_builder(self):
        self.capture()
        self.namespace.write_bytes(self.namespace.read_bytes() + b'# changed selected registry\n')
        with self.assertRaisesRegex(ValueError, 'different namespace registry'):
            builder.verified_auxiliary_hashes({'file-metadata': self.args.output / 'file-metadata.tsv',
                                               'namespace-registry': self.namespace}, WIKI, DATE)

    def test_wrong_edition_and_date_are_rejected(self):
        self.capture()
        for wiki, date in (('enwiktionary', DATE), (WIKI, '20261002')):
            with self.assertRaisesRegex(ValueError, 'edition/date'):
                v2.validate_snapshot(self.args.output / 'file-metadata.tsv', wiki, date)

    def test_rehashed_tsv_mediatype_tamper_fails_api_replay(self):
        manifest = self.capture()
        index = v1.decode((self.args.output / v2.EVIDENCE).read_bytes())
        path = self.args.output / 'file-metadata.tsv'
        raw = path.read_bytes().replace(b'\tAUDIO\t', b'\tBITMAP\t')
        path.write_bytes(raw)
        manifest.update(output_bytes=len(raw), output_sha256=v1.digest(raw))
        self.rewrite_index_and_manifest(manifest, index)
        with self.assertRaisesRegex(ValueError, 'TSV differs'):
            v2.verify(self.args.output)

    def test_rehashed_query_without_mediatype_is_rejected(self):
        manifest = self.capture()
        index = v1.decode((self.args.output / v2.EVIDENCE).read_bytes())
        path = self.args.output / index['batches'][0]['request']
        request = v1.decode(path.read_bytes())
        request['query']['iiprop'] = 'size|sha1|timestamp|canonicaltitle'
        path.write_bytes(v1.encoded(request))
        self.rewrite_index_and_manifest(manifest, index)
        with self.assertRaisesRegex(ValueError, 'query semantics'):
            v2.verify(self.args.output)

    def test_missing_raw_evidence_and_extra_prefixed_payload_are_rejected(self):
        self.capture()
        extra = self.args.output / 'file-metadata.unrecorded.json'
        extra.write_text('{}')
        with self.assertRaisesRegex(ValueError, 'inventory'):
            v2.verify(self.args.output)
        extra.unlink()
        raw = next(self.args.output.glob('*.raw.json'))
        raw.unlink()
        with self.assertRaisesRegex(ValueError, 'inventory'):
            v2.verify(self.args.output)

    def test_unknown_type_failure_preserves_evidence_without_publication(self):
        def bad_transport(url, timeout):
            status, headers, raw = self.transport(url, timeout)
            data = v1.decode(raw)
            for page in data['query']['pages']:
                if 'imageinfo' in page:
                    page['imageinfo'][0].pop('mediatype')
            return status, headers, v1.encoded(data)
        with self.assertRaisesRegex(ValueError, 'mediatype'):
            v2.capture(self.args, transport=bad_transport, sleep=lambda _: None)
        for name in ('file-metadata.tsv', v2.MANIFEST, v2.COMPLETE):
            self.assertFalse((self.args.output / name).exists())
        self.assertTrue(list(self.args.output.glob('*.raw.json')))
        self.assertTrue((self.args.output / 'file-metadata.failure.json').exists())

    def test_builder_preserves_legacy_v1_and_rejects_unbound_v2(self):
        self.args.output.mkdir()
        path = self.args.output / 'file-metadata.tsv'
        path.write_text('# wikidict-file-metadata-v1\nFile:Example.ogg\t1\t0\t0\n')
        record = {'schema': v1.SCHEMA, 'wiki': WIKI, 'date': DATE,
                  'output_sha256': v1.digest(path.read_bytes())}
        (self.args.output / v2.MANIFEST).write_bytes(v1.encoded(record))
        self.assertIsNone(builder.auxiliary_capture_helper('file-metadata', path))
        self.assertEqual(builder.verified_auxiliary_hashes({'file-metadata': path}, WIKI, DATE),
                         {'file-metadata': record['output_sha256']})
        path.write_text('# wikidict-file-metadata-v2\n')
        with self.assertRaises(ValueError):
            builder.auxiliary_capture_helper('file-metadata', path)
        (self.args.output / v2.MANIFEST).unlink()
        with self.assertRaisesRegex(ValueError, 'requires its capture manifest'):
            builder.auxiliary_capture_helper('file-metadata', path)


    def test_historical_provenance_replays_without_restamping(self):
        manifest = self.capture()
        manifest['generator_sha256'] = 'a' * 64
        manifest['dependency_sha256'] = {key: 'b' * 64 for key in manifest['dependency_sha256']}
        index = v1.decode((self.args.output / v2.EVIDENCE).read_bytes())
        self.rewrite_index_and_manifest(manifest, index)
        before = (self.args.output / v2.MANIFEST).read_bytes()
        self.assertEqual(v2.verify(self.args.output), manifest)
        self.assertEqual((self.args.output / v2.MANIFEST).read_bytes(), before)
        self.assertNotEqual(manifest['generator_sha256'], v2.producer()['generator_sha256'])
        path = self.args.output / 'file-metadata.tsv'
        path.write_bytes(path.read_bytes().replace(b'\tAUDIO\t', b'\tVIDEO\t'))
        manifest.update(output_bytes=path.stat().st_size, output_sha256=v1.digest(path.read_bytes()))
        self.rewrite_index_and_manifest(manifest, index)
        with self.assertRaisesRegex(ValueError, 'TSV differs'):
            v2.verify(self.args.output)

    def test_malformed_or_missing_producer_roles_rejected(self):
        manifest = self.capture()
        for bad in ({**manifest, 'generator_sha256': 'not-a-hash'},
                    {**manifest, 'dependency_sha256': {}},
                    {**manifest, 'dependency_sha256': {**manifest['dependency_sha256'], '../foreign': 'a' * 64}}):
            with self.subTest(provenance=bad):
                with self.assertRaisesRegex(ValueError, 'producer provenance'):
                    v2.validate_provenance(bad)


# Synthetic ancestor identity; actual resumes authenticate their selected receipts.
ANCESTOR = v1.digest(b'synthetic closed ancestor collector')
import sys
from unittest.mock import patch

def enc(value):
    return (json.dumps(value, ensure_ascii=False, indent=2) + '\n').encode()


def descriptor(path):
    raw = path.read_bytes()
    return {'path': str(path), 'bytes': len(raw), 'sha256': v2.digest(raw)}


class ResumeTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='file-metadata-resume-', dir='.tmp')
        self.root = Path(self.tmp.name)
        self.source = self.root / 'closed-source'
        self.source.mkdir()
        self.output = self.root / 'successor'
        self.seed = self.root / 'titles.txt'
        self.namespace = self.root / 'namespace.tsv'
        raw = ('# wikidict-namespace-registry-v1\n# wiki\tglwiktionary\n# dump-date\t20261001\n'
               '# content-language\tgl\n-2\tMedia\tMedia\tcase-sensitive\t0\t0\t0\t\tcompile_only\tvirtual_namespace\n'
               '6\tFicheiro\tFile\tcase-sensitive\t0\t0\t0\t\tcompile_only\tstandard_build_input\tImage\n').encode()
        self.namespace.write_bytes(raw)
        self.titles = ['Ficheiro:gl-test-%03d.ogg' % i for i in range(51)]
        self.seed.write_text('\n'.join(self.titles) + '\n')
        (self.source / v2.NAMESPACE).write_bytes(raw)
        (self.source / 'file-metadata.input-0000.titles').write_bytes(self.seed.read_bytes())
        (self.source / 'file-metadata.candidates.json').write_bytes(enc({'titles': self.titles}))
        request_name = 'file-metadata.request-000001.json'
        response_name = 'file-metadata.response-000001-01.raw.json'
        receipt_name = 'file-metadata.response-000001-01.receipt.json'
        first = self.titles[:50]
        (self.source / request_name).write_bytes(enc({'url': v2.query_url('glwiktionary', first), 'query': v2.query_for('glwiktionary', first), 'titles': first}))
        response = self.response(first)
        (self.source / response_name).write_bytes(response)
        (self.source / receipt_name).write_bytes(enc({'accepted': True, 'status': 200, 'request': request_name,
            'response': response_name, 'response_bytes': len(response), 'response_sha256': v2.digest(response),
            'started_utc': '2026-11-03T01:00:00+00:00', 'ended_utc': '2026-11-03T01:00:01+00:00'}))
        failure = {'error': 'Capture wall deadline reached', 'generator_sha256': ANCESTOR,
                   'dependency_sha256': v2.producer()['dependency_sha256']}
        (self.source / 'file-metadata.failure.json').write_bytes(enc(failure))
        pins = [descriptor(self.seed), descriptor(self.namespace), {'path': str(v1.REPO / 'tools/prepare_file_metadata_v2.py'), 'bytes': 21075, 'sha256': ANCESTOR}]
        pins.extend({'path': str(v1.REPO / role), 'sha256': sha} for role, sha in failure['dependency_sha256'].items())
        argv = [sys.executable, '-B', pins[2]['path'], 'capture', '--wiki', 'glwiktionary', '--date', '20261001',
                '--namespace-registry', str(self.namespace), '--titles', str(self.seed), '--output', str(self.source),
                '--batch-size', '50', '--delay', '1', '--wall-seconds', '900']
        start = {'argv': argv, 'pins': pins, 'expected_batches': 2, 'expected_rows': 51}
        result = {'exit_code': 1, 'pins_unchanged': True}
        self.proof = {'schema': 'wikidict.file-metadata-checkpoint.v1', 'source_root': str(self.source), 'planned_batches': 2,
                      'planned_rows': 51, 'artifacts': {p.name: descriptor(p) for p in self.source.iterdir()}}
        for name, value in [('start', start), ('result', result), ('failure', failure)]:
            raw = enc(value)
            self.proof[name + '_raw'] = raw.decode()
            self.proof[name] = {'bytes': len(raw), 'sha256': v2.digest(raw)}
        self.proof_path = self.root / 'checkpoint.json'
        self.write_proof()
        self.args = SimpleNamespace(wiki='glwiktionary', date='20261001', batch_size=50, delay=1,
            wall_seconds=3600, output=self.output, namespace_registry=self.namespace, titles=[self.seed], log=[], resume_proof=self.proof_path)
        self.calls = []
        # Disposable fixture outputs use real exclusive write/close but omit fsync;
        # production durable put remains unchanged and is not qualified by these tests.
        def fixture_put(path, raw):
            path.parent.mkdir(parents=True, exist_ok=True)
            with path.open('xb') as stream:
                stream.write(raw)
        self.writer = patch.object(v2, 'put', fixture_put)
        self.docwriter = patch.object(v2, 'document', lambda path, value: fixture_put(path, v2.encoded(value)))
        self.writer.start(); self.docwriter.start()

    def tearDown(self):
        self.docwriter.stop(); self.writer.stop(); self.tmp.cleanup()

    def write_proof(self):
        self.proof_path.write_bytes(enc(self.proof))

    def response(self, titles):
        return enc({'query': {'general': {'wikiid': 'glwiktionary'}, 'pages': [{'ns': 6, 'title': t, 'missing': True, 'imagerepository': ''} for t in titles]}})

    def transport(self, url, timeout):
        from urllib.parse import urlparse, parse_qs
        titles = parse_qs(urlparse(url).query)['titles'][0].split('|')
        self.calls.append(titles)
        return 200, {}, self.response(titles)

    def run_capture(self):
        return v2.capture(self.args, transport=self.transport, sleep=lambda seconds: None)

    def test_success_fetches_only_missing_and_retains_timestamps(self):
        m = self.run_capture()
        self.assertEqual(self.calls, [self.titles[50:]])
        self.assertEqual((m['rows'], m['positive_rows'], m['negative_rows']), (51, 0, 51))
        self.assertEqual(m['started_utc'], '2026-11-03T01:00:00+00:00')
        self.assertNotEqual(m['generator_sha256'], ANCESTOR)
        for name in self.proof['artifacts']:
            if name.startswith(('file-metadata.request-', 'file-metadata.response-')):
                self.assertEqual((self.output / name).read_bytes(), (self.source / name).read_bytes())
        self.assertEqual(v2.verify(self.output), m)

    def test_seed_changed_rejected_before_network(self):
        self.seed.write_text('Ficheiro:other.ogg\n')
        with self.assertRaises(ValueError): self.run_capture()
        self.assertFalse(self.calls)

    def test_namespace_changed_rejected_before_network(self):
        self.namespace.write_text(self.namespace.read_text().replace('case-sensitive', 'first-letter'))
        with self.assertRaises(ValueError): self.run_capture()
        self.assertFalse(self.calls)

    def test_response_tamper_rejected(self):
        path = self.source / 'file-metadata.response-000001-01.raw.json'; path.write_bytes(path.read_bytes() + b' ')
        with self.assertRaises(ValueError): self.run_capture()
        self.assertFalse(self.calls)

    def test_request_semantics_rejected_even_with_resealed_inventory(self):
        path = self.source / 'file-metadata.request-000001.json'; r = json.loads(path.read_text()); r['query']['iiprop'] = 'size'; path.write_bytes(enc(r))
        self.proof['artifacts'][path.name] = descriptor(path); self.write_proof()
        with self.assertRaises(ValueError): self.run_capture()
        self.assertFalse(self.calls)

    def test_actual_access_rejection_is_not_resumable(self):
        failure = json.loads(self.proof['failure_raw']); failure['error'] = 'API HTTP status 403'
        self.proof['failure_raw'] = enc(failure).decode(); self.proof['failure'] = {'bytes': len(enc(failure)), 'sha256': v2.digest(enc(failure))}; self.write_proof()
        with self.assertRaises(ValueError): self.run_capture()
        self.assertFalse(self.calls)

    def test_options_changed_rejected(self):
        self.args.delay = 0
        with self.assertRaises(ValueError): self.run_capture()
        self.assertFalse(self.calls)

    def test_unknown_extra_checkpoint_file_rejected(self):
        (self.source / 'unrecorded').write_text('x')
        with self.assertRaises(ValueError): self.run_capture()
        self.assertFalse(self.calls)

    def test_old_producer_changed_rejected(self):
        failure = json.loads(self.proof['failure_raw']); failure['generator_sha256'] = '0' * 64
        raw = enc(failure); self.proof['failure_raw'] = raw.decode(); self.proof['failure'] = {'bytes':len(raw),'sha256':v2.digest(raw)}; self.write_proof()
        with self.assertRaises(ValueError): self.run_capture()
        self.assertFalse(self.calls)

    def test_already_complete_checkpoint_rejected(self):
        (self.source / v2.COMPLETE).write_text('{}')
        with self.assertRaises(ValueError): self.run_capture()
        self.assertFalse(self.calls)

    def test_trailing_checkpoint_json_rejected(self):
        self.proof_path.write_text(self.proof_path.read_text() + '{}')
        with self.assertRaises(ValueError): self.run_capture()
        self.assertFalse(self.calls)

    def test_atomic_final_does_not_overwrite(self):
        path = self.root / 'final.json'; path.write_bytes(b'old')
        with self.assertRaises(FileExistsError): v2.publish_final(path, b'new')
        self.assertEqual(path.read_bytes(), b'old')

    def test_missing_transport_result_leaves_no_final_marker(self):
        def failed(url, timeout): raise ValueError('Synthetic interrupted missing batch')
        with self.assertRaises(ValueError): v2.capture(self.args, transport=failed, sleep=lambda n: None)
        for name in (v2.EVIDENCE, v2.MANIFEST, v2.COMPLETE):
            self.assertFalse((self.output / name).exists())

    def test_changed_batch_size_rejected(self):
        self.args.batch_size = 25
        with self.assertRaises(ValueError): self.run_capture()
        self.assertFalse(self.calls)

    def test_authenticated_other_ancestor_and_finite_wall_accepted(self):
        start = json.loads(self.proof['start_raw']); failure = json.loads(self.proof['failure_raw'])
        start['pins'][2]['sha256'] = 'a' * 64; failure['generator_sha256'] = 'a' * 64
        start['argv'][19] = '1200'
        for name, value in [('start', start), ('failure', failure)]:
            raw = enc(value); self.proof[name + '_raw'] = raw.decode()
            self.proof[name] = {'bytes': len(raw), 'sha256': v2.digest(raw)}
        path = self.source / 'file-metadata.failure.json'; path.write_bytes(enc(failure))
        self.proof['artifacts'][path.name] = descriptor(path); self.write_proof()
        m = self.run_capture()
        self.assertEqual(self.calls, [self.titles[50:]])
        self.assertEqual(v2.verify(self.output), m)

    def test_completed_resume_replay_does_not_require_current_producer_revision(self):
        manifest = self.run_capture()
        with patch.object(v2, 'producer', side_effect=AssertionError('Completed observations must replay without a source-version gate')):
            self.assertEqual(v2.verify(self.output), manifest)

    def test_ancestor_dependency_pin_disagreement_rejected(self):
        start = json.loads(self.proof['start_raw']); start['pins'][3]['sha256'] = 'e' * 64
        raw = enc(start); self.proof['start_raw'] = raw.decode()
        self.proof['start'] = {'bytes': len(raw), 'sha256': v2.digest(raw)}; self.write_proof()
        with self.assertRaisesRegex(ValueError, 'dependency lineage'):
            self.run_capture()
        self.assertFalse(self.calls)


class RequestPacingTests(unittest.TestCase):
    setUp = CaptureReplayTest.setUp
    transport = CaptureReplayTest.transport

    def run_timed(self, durations, statuses=None, headers=None, oversleep=0):
        self.now, self.starts, self.sleeps = 0.0, [], []
        statuses = statuses or [200] * len(durations)
        headers = headers or [{}] * len(durations)

        def sleep(seconds):
            self.sleeps.append(seconds)
            self.now += seconds + oversleep

        def transport(url, timeout):
            index = len(self.starts)
            self.starts.append(self.now)
            self.now += durations[index]
            if statuses[index] != 200:
                return statuses[index], headers[index], b'{}'
            return self.transport(url, timeout)

        with mock.patch.object(v2.time, 'monotonic', side_effect=lambda: self.now):
            return v2.capture(self.args, transport=transport, sleep=sleep)

    def start_mode(self):
        self.args.pacing, self.args.delay = 'start-to-start', 1

    def test_slow_serial_requests_have_no_extra_idle(self):
        self.start_mode()
        manifest = self.run_timed([2, 2])
        self.assertEqual(self.starts, [0, 2])
        self.assertEqual(self.sleeps, [])
        self.assertEqual(v2.verify(self.args.output), manifest)
        self.assertEqual((manifest['positive_rows'], manifest['negative_rows']), (1, 1))

    def test_fast_serial_requests_sleep_only_remaining_interval(self):
        self.start_mode()
        self.run_timed([0.25, 0.25])
        self.assertEqual(self.starts, [0, 1])
        self.assertEqual(self.sleeps, [0.75])

    def test_default_preserves_post_response_delay_for_slow_requests(self):
        self.args.delay = 1
        self.run_timed([2, 2])
        self.assertEqual(self.starts, [0, 3])
        self.assertEqual(self.sleeps, [1])

    def test_retry_after_is_after_response_and_not_replaced_by_pacing(self):
        self.start_mode()
        self.run_timed([0.25, 0.25, 0.25], [429, 200, 200], [{'Retry-After': '3'}, {}, {}])
        self.assertEqual(self.starts, [0, 3.25, 4.25])
        self.assertEqual(self.sleeps, [3, 0.75])
        receipt = json.loads((self.args.output / 'file-metadata.response-000001-01.receipt.json').read_text())
        self.assertFalse(receipt['accepted'])
        self.assertEqual(receipt['status'], 429)
        self.assertEqual(receipt['headers']['retry-after'], '3')

    def test_retry_deadline_refuses_before_sleep_or_second_request(self):
        self.start_mode()
        self.args.wall_seconds = 2
        with self.assertRaisesRegex(ValueError, 'Retry exceeds bounded'):
            self.run_timed([0.25], [429], [{'Retry-After': '3'}])
        self.assertEqual(self.starts, [0])
        self.assertEqual(self.sleeps, [])
        self.assertFalse((self.args.output / v2.COMPLETE).exists())

    def test_start_interval_deadline_refuses_next_request(self):
        self.start_mode()
        self.args.wall_seconds = 1
        with self.assertRaisesRegex(ValueError, 'Capture wall deadline'):
            self.run_timed([0.25])
        self.assertEqual(self.starts, [0])
        self.assertEqual(self.sleeps, [])

    def test_sleep_overshoot_cannot_send_past_deadline(self):
        self.start_mode()
        self.args.wall_seconds = 2
        with self.assertRaisesRegex(ValueError, 'Capture wall deadline'):
            self.run_timed([0.25], oversleep=3)
        self.assertEqual(self.starts, [0])
        self.assertEqual(self.sleeps, [0.75])

    def test_access_refusal_remains_one_attempt(self):
        self.start_mode()
        with self.assertRaisesRegex(ValueError, 'API HTTP status 403'):
            self.run_timed([0.25], [403])
        self.assertEqual(self.starts, [0])
        self.assertEqual(self.sleeps, [])

    def test_start_mode_rejects_subsecond_interval_before_output(self):
        self.start_mode()
        self.args.delay = 0.5
        with self.assertRaisesRegex(ValueError, 'Invalid date or bounded'):
            self.run_timed([])
        self.assertEqual(self.starts, [])
        self.assertFalse(self.args.output.exists())


class PacingCheckpointTests(unittest.TestCase):
    setUp = ResumeTests.setUp
    tearDown = ResumeTests.tearDown
    response = ResumeTests.response
    write_proof = ResumeTests.write_proof
    transport = ResumeTests.transport
    run_capture = ResumeTests.run_capture

    def change_original_pacing(self, value):
        start = json.loads(self.proof['start_raw'])
        start['argv'] += ['--pacing', value]
        raw = enc(start)
        self.proof['start_raw'] = raw.decode()
        self.proof['start'] = {'bytes': len(raw), 'sha256': v2.digest(raw)}
        self.write_proof()

    def test_new_pacing_checkpoint_replays_without_changing_old_observations(self):
        self.change_original_pacing('start-to-start')
        self.args.pacing = 'start-to-start'
        now = [0.0]
        with mock.patch.object(v2.time, 'monotonic', side_effect=lambda: now[0]):
            manifest = v2.capture(self.args, transport=self.transport,
                                  sleep=lambda seconds: now.__setitem__(0, now[0] + seconds))
        self.assertEqual(len(self.calls), 1)
        self.assertEqual(now[0], 1)
        self.assertEqual(v2.verify(self.args.output), manifest)

    def test_legacy_checkpoint_cannot_silently_change_pacing(self):
        self.args.pacing = 'start-to-start'
        with self.assertRaisesRegex(ValueError, 'Checkpoint pacing mode differs'):
            self.run_capture()
        self.assertFalse(self.calls)

    def test_new_checkpoint_cannot_silently_resume_with_legacy_pacing(self):
        self.change_original_pacing('start-to-start')
        with self.assertRaisesRegex(ValueError, 'Checkpoint pacing mode differs'):
            self.run_capture()
        self.assertFalse(self.calls)


class InterruptedResumeTests(unittest.TestCase):
    def tearDown(self):
        self.journal_sources.stop()
        ResumeTests.tearDown(self)
    response = ResumeTests.response
    write_proof = ResumeTests.write_proof
    transport = ResumeTests.transport
    run_capture = ResumeTests.run_capture

    def bind(self, name, value):
        raw = enc(value)
        self.proof[name + '_raw'] = raw.decode()
        self.proof[name] = {'path': str(self.root / (name + '.json')), 'bytes': len(raw), 'sha256': v2.digest(raw)}

    def setUp(self):
        ResumeTests.setUp(self)
        self.proof = {'schema': v2.INTERRUPTION_SCHEMA, 'source_root': str(self.source),
                      'planned_batches': 2, 'planned_rows': 51,
                      'filesystem_scope': 'retained-filesystem-process-interruption'}
        (self.source / 'file-metadata.failure.json').unlink()
        # Synthetic reviewed preimages isolate the contract controls. The retained
        # original pair is separately replayed in the real interrupted-prefix check.
        original, writer = 'synthetic request-before-transport', 'synthetic durable writer'
        self.journal_sources = patch.dict(v2.INTERRUPTION_JOURNAL_SOURCES,
            {'collector': v2.digest(original.encode()), 'writer': v2.digest(writer.encode())}, clear=True)
        self.journal_sources.start()
        self.proof['journal_source_raw'] = {'collector': original, 'writer': writer}
        collector = {'path': str(v1.REPO / 'tools/prepare_file_metadata_v2.py'), 'bytes': len(original.encode()), 'sha256': v2.digest(original.encode())}
        dependencies = v2.producer()['dependency_sha256']
        # Keep the live dependency check real; only the test's reviewed writer
        # preimage anchor is synthetic, so bind its digest as the fixture dependency.
        dependencies['tools/prepare_file_metadata.py'] = v2.digest(writer.encode())
        self.live_producer = patch.object(v2, 'producer', return_value={
            'generator_sha256': 'c' * 64, 'dependency_sha256': dependencies})
        self.live_producer.start()
        self.addCleanup(self.live_producer.stop)
        sources = [collector] + [{'path': str(v1.REPO / role), 'sha256': sha} for role, sha in dependencies.items()]
        seed, namespace = descriptor(self.seed), descriptor(self.namespace)
        argv = ['-B', collector['path'], 'capture', '--wiki', 'glwiktionary', '--date', '20261001',
                '--namespace-registry', str(self.namespace), '--titles', str(self.seed), '--output', str(self.source),
                '--batch-size', '50', '--delay', '1', '--wall-seconds', '900']
        self.bind('selection', {'parts': [{'number': 10, 'titles': seed, 'output': str(self.source), 'rows': 51,
                                          'batches': 2, 'capture_argv': argv}], 'source': sources,
            'capture_producer': {'generator_sha256': collector['sha256'], 'dependency_sha256': dependencies},
            'namespace': namespace, 'wiki': 'glwiktionary', 'date': '20261001', 'batch_size': 50, 'delay': 1, 'capture_wall_seconds': 900})
        owner = {'pid': 11, 'birth': 111, 'group': 11, 'session': 11}
        epoch = v2.datetime.fromisoformat('2026-11-03T00:59:59+00:00').timestamp()
        self.bind('serial_start', {'owner': owner, 'selection': self.proof['selection'], 'source': sources + [namespace], 'started_unix': epoch - 100})
        self.bind('phase_start', {'parent': owner, 'argv': argv, 'started_unix': epoch})
        self.proof['phase_start']['path'] = str(self.root / 'start.json')
        self.bind('delivery', {'returncode': -9, 'owner_reaped': True, 'finished_unix': epoch + 3})
        self.bind('watchdog', {'runtime_started': True, 'admission_refused': False, 'child_pid': 12,
                             'child_start_time_ticks': 112, 'guardian_pid': 13, 'guardian_start_time_ticks': 113})
        self.bind('guardian', {'status': 'owned_session_gone', 'signalled': {}, 'reason': 'supervisor_liveness_pipe_closed',
                              'supervisor_pid': 11, 'supervisor_start': 111, 'root_pid': 12, 'root_start': 112, 'guardian_pid': 13})
        self.bind('closure', {'status': 'INTERRUPTED-PHYSICALLY-SOURCE-CLOSED', 'physical_closure': True,
            'source_pins_unchanged': True, 'completed_capture_manifests_unchanged': True, 'owner_reaped': True,
            'owner_returncode': -9, 'ps_absence': True, 'process_observations': {'/proc': [], '/mnt/ogroot/proc': []},
            'allocation_bytes': 0, 'cause': 'SIGKILL source unknown', 'serial_start': self.proof['serial_start'],
            'delivery_result': self.proof['delivery'], 'owner': owner, 'interrupted_part': 10,
            'phases': [{'number': 10, 'phase': 'capture', 'watchdog': self.proof['watchdog'], 'guardian': self.proof['guardian']}],
            'identities': {'11': 111, '12': 112, '13': 113}, 'closed_unix': epoch + 4})
        self.inventory()

    def inventory(self):
        self.proof['artifacts'] = {p.name: descriptor(p) for p in self.source.iterdir()}
        self.write_proof()

    def change(self, name, key, value):
        document = json.loads(self.proof[name + '_raw']); document[key] = value
        oldpath = self.proof[name]['path']; self.bind(name, document); self.proof[name]['path'] = oldpath
        # Rebind genuine enclosing descriptors so tests reach semantic guards.
        if name in ('watchdog', 'guardian'):
            closure = json.loads(self.proof['closure_raw']); closure['phases'][0][name] = self.proof[name]
            self.bind('closure', closure)
        self.write_proof()

    def reject(self):
        with self.assertRaises((ValueError, KeyError)):
            self.run_capture()
        self.assertFalse(self.calls)

    def test_unknown_cause_reuses_prefix_and_preserves_every_original_byte(self):
        old = {p.name: p.read_bytes() for p in self.source.iterdir()}
        manifest = self.run_capture()
        self.assertEqual(self.calls, [self.titles[50:]])
        self.assertEqual(old, {p.name: p.read_bytes() for p in self.source.iterdir()})
        self.assertEqual(v2.verify(self.output), manifest)
        resume = json.loads((self.output / v2.RESUME).read_text())
        self.assertEqual(resume['original_pacing'], 'after-response')
        self.assertEqual(json.loads(resume['checkpoint']['closure_raw'])['cause'], 'SIGKILL source unknown')
        self.assertNotIn('failure_raw', resume['checkpoint'])

    def test_new_start_pacing_waits_fresh_interval_then_fetches_only_missing(self):
        self.args.pacing = 'start-to-start'
        now, starts = [0.0], []
        def transport(url, timeout):
            starts.append(now[0]); return self.transport(url, timeout)
        with patch.object(v2.time, 'monotonic', side_effect=lambda: now[0]):
            manifest = v2.capture(self.args, transport=transport, sleep=lambda n: now.__setitem__(0, now[0] + n))
        self.assertEqual(starts, [1.0]); self.assertEqual(self.calls, [self.titles[50:]])
        self.assertEqual(v2.verify(self.output), manifest)
        resume = json.loads((self.output / v2.RESUME).read_text())
        self.assertEqual((resume['original_pacing'], resume['pacing']), ('after-response', 'start-to-start'))

    def test_completed_replay_does_not_require_current_source(self):
        manifest = self.run_capture()
        with patch.object(v2, 'producer', side_effect=AssertionError('historical observation')):
            self.assertEqual(v2.verify(self.output), manifest)

    def test_exact_phase_argv_required(self):
        phase = json.loads(self.proof['phase_start_raw']); phase['argv'][8] = '/other/namespace'
        self.change('phase_start', 'argv', phase['argv']); self.reject()

    def test_original_source_behavior_preimage_required(self):
        self.proof['journal_source_raw']['collector'] += '\n'
        self.write_proof(); self.reject()

    def test_closed_process_and_source_required(self):
        self.change('closure', 'source_pins_unchanged', False); self.reject()

    def test_live_process_observation_refused(self):
        self.change('closure', 'process_observations', {'/proc': [12], '/mnt/ogroot/proc': []}); self.reject()

    def test_guardian_birth_mismatch_refused(self):
        self.change('guardian', 'root_start', 999); self.reject()

    def test_resealed_orphan_request_refused_before_network(self):
        (self.source / 'file-metadata.request-000002.json').write_bytes(enc({'url': 'pending'}))
        self.inventory(); self.reject()

    def test_resealed_uncommitted_raw_refused_before_network(self):
        (self.source / 'file-metadata.response-000002-01.raw.json').write_bytes(b'{}')
        self.inventory(); self.reject()

    def test_partial_receipt_refused_before_network(self):
        (self.source / 'file-metadata.response-000002-01.receipt.json').write_bytes(b'{')
        self.inventory(); self.reject()

    def test_rejected_observation_is_not_bypassed(self):
        name = 'file-metadata.response-000001-01.receipt.json'
        receipt = json.loads((self.source / name).read_text()); receipt.update(accepted=False, status=429)
        (self.source / name).write_bytes(enc(receipt)); self.inventory(); self.reject()

    def test_transport_unknown_attempt_is_ambiguous(self):
        (self.source / 'file-metadata.response-000002-01.receipt.json').write_bytes(enc({'accepted': False, 'status': None}))
        self.inventory(); self.reject()

    def test_duplicate_accepted_attempt_refused(self):
        (self.source / 'file-metadata.response-000001-02.receipt.json').write_bytes((self.source / 'file-metadata.response-000001-01.receipt.json').read_bytes())
        self.inventory(); self.reject()

    def test_noncontiguous_accepted_prefix_refused(self):
        old = self.source / 'file-metadata.response-000001-01.receipt.json'
        old.rename(self.source / 'file-metadata.response-000002-01.receipt.json')
        self.inventory(); self.reject()

    def test_accepted_response_after_owner_exit_refused(self):
        name = 'file-metadata.response-000001-01.receipt.json'
        receipt = json.loads((self.source / name).read_text()); receipt['ended_utc'] = '2026-11-03T01:10:00+00:00'
        (self.source / name).write_bytes(enc(receipt)); self.inventory(); self.reject()

    def test_timezone_free_request_time_refused(self):
        name = 'file-metadata.response-000001-01.receipt.json'
        receipt = json.loads((self.source / name).read_text()); receipt['started_utc'] = '2026-11-03T01:00:00'
        (self.source / name).write_bytes(enc(receipt)); self.inventory(); self.reject()

    test_seed_changed_rejected_before_network = ResumeTests.test_seed_changed_rejected_before_network
    test_namespace_changed_rejected_before_network = ResumeTests.test_namespace_changed_rejected_before_network
    test_response_tamper_rejected = ResumeTests.test_response_tamper_rejected
    test_request_semantics_rejected_even_with_resealed_inventory = ResumeTests.test_request_semantics_rejected_even_with_resealed_inventory
    test_unknown_extra_checkpoint_file_rejected = ResumeTests.test_unknown_extra_checkpoint_file_rejected
    test_already_complete_checkpoint_rejected = ResumeTests.test_already_complete_checkpoint_rejected
    test_trailing_checkpoint_json_rejected = ResumeTests.test_trailing_checkpoint_json_rejected

    def check_completed_resume(self, manifest, resume):
        proof_raw = enc(resume['checkpoint'])
        resume['checkpoint_raw'] = proof_raw.decode(); resume['checkpoint_sha256'] = v2.digest(proof_raw)
        raw = enc(resume); (self.output / v2.RESUME).write_bytes(raw)
        manifest['checkpoint_resume'] = {'path': v2.RESUME, 'size': len(raw), 'sha256': v2.digest(raw)}
        index = json.loads((self.output / v2.EVIDENCE).read_text())
        v2.verify_resume(self.output, manifest, index)

    def test_completed_replay_rejects_resealed_inconsistent_original_plan(self):
        manifest = self.run_capture(); resume = json.loads((self.output / v2.RESUME).read_text())
        proof = resume['checkpoint']; proof['planned_batches'] = 3
        def bind(name, value):
            raw = enc(value); proof[name + '_raw'] = raw.decode()
            proof[name] = dict(proof[name], bytes=len(raw), sha256=v2.digest(raw))
        selection = json.loads(proof['selection_raw']); selection['parts'][0]['batches'] = 3; bind('selection', selection)
        serial = json.loads(proof['serial_start_raw']); serial['selection'] = proof['selection']; bind('serial_start', serial)
        closure = json.loads(proof['closure_raw']); closure['serial_start'] = proof['serial_start']; bind('closure', closure)
        with self.assertRaisesRegex(ValueError, 'replay batch plan differs'):
            self.check_completed_resume(manifest, resume)

    def test_completed_replay_rejects_resealed_nondeterministic_prefix(self):
        manifest = self.run_capture(); resume = json.loads((self.output / v2.RESUME).read_text())
        name = resume['reused_batches'][0]['request']; path = self.output / name
        request = json.loads(path.read_text()); titles = list(reversed(request['titles']))
        path.write_bytes(enc({'url': v2.query_url('glwiktionary', titles), 'query': v2.query_for('glwiktionary', titles), 'titles': titles}))
        row = dict(resume['copied_artifacts'][name], bytes=path.stat().st_size, sha256=v2.digest(path.read_bytes()))
        resume['copied_artifacts'][name] = row; resume['checkpoint']['artifacts'][name] = row
        with self.assertRaisesRegex(ValueError, 'replay request prefix differs'):
            self.check_completed_resume(manifest, resume)


class FigureMetadataLightTransportTests(unittest.TestCase):

    def test_batches_use_exact_encoded_size_at_profile_url_boundary(self):
        titles = ['File:Space + percent% / slash.ogg', 'File:നാമം.ogg']
        for axes, light in ((False, False), (True, False), (True, True)):
            options = dict(figure_axes=axes, figure_metadata_light=light)
            length = len(v2.query_url(WIKI, titles, **options))
            with self.subTest(options=options), mock.patch.object(v2, 'MAX_URL', length):
                self.assertEqual(list(v2.title_batches(WIKI, iter(titles), 50, **options)), [titles])
            with self.subTest(options=options), mock.patch.object(v2, 'MAX_URL', length - 1):
                self.assertEqual(list(v2.title_batches(WIKI, iter(titles), 50, **options)), [[t] for t in titles])
            with self.subTest(options=options), mock.patch.object(v2, 'MAX_URL', length):
                batches = v2.title_batches(WIKI, [titles[0], titles[1] * 20], 50, **options)
                self.assertEqual(next(batches), [titles[0]])
                with self.assertRaisesRegex(ValueError, 'Single file title'):
                    next(batches)

    def test_default_query_url_and_batch_outputs_are_exact(self):
        from urllib.parse import urlencode
        titles = ['File:Example.ogg', 'File:Other.bin']
        for axes in (False, True):
            expected = {'action': 'query', 'format': 'json', 'formatversion': '2', 'meta': 'siteinfo', 'siprop': 'general', 'prop': 'imageinfo', 'iiprop': 'size|sha1|timestamp|canonicaltitle|mediatype', 'iilimit': '1', 'redirects': '1', 'maxlag': '5', 'titles': '|'.join(titles)}
            if axes:
                expected.update(iiprop=expected['iiprop'] + '|mime|metadata', siprop='general|extensions', curtimestamp='1')
            self.assertEqual(v2.query_for(WIKI, titles, figure_axes=axes), expected)
            self.assertEqual(v2.query_url(WIKI, titles, figure_axes=axes), v1.wiktionary_api(WIKI) + '?' + urlencode(expected))
            self.assertEqual(list(v2.title_batches(WIKI, titles, 1, figure_axes=axes)), [[titles[0]], [titles[1]]])

    def test_light_omits_only_metadata_and_requires_figure_axes(self):
        titles = ['File:Example.ogg']
        full = v2.query_for(WIKI, titles, figure_axes=True)
        light = v2.query_for(WIKI, titles, figure_axes=True, figure_metadata_light=True)
        expected = dict(full, iiprop=full['iiprop'].replace('|metadata', ''))
        self.assertEqual(light, expected)
        self.assertEqual(light['siprop'], 'general|extensions')
        self.assertEqual(light['curtimestamp'], '1')
        self.assertEqual(set(light['iiprop'].split('|')), {'size', 'sha1', 'timestamp', 'canonicaltitle', 'mediatype', 'mime'})
        for value in (True, 1, 'yes', None):
            with self.subTest(value=value):
                with self.assertRaises(ValueError):
                    v2.query_for(WIKI, titles, figure_metadata_light=value)
                with self.assertRaises(ValueError):
                    list(v2.title_batches(WIKI, [], 50, figure_metadata_light=value))

    def test_request_archives_exact_profile_and_replay_rejects_other_mode(self):
        import time
        registry = v2.evidence.Registry(registry_bytes(), WIKI, '20261001')
        for light in (False, True):
            with self.subTest(light=light), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                seen = []

                def transport(url, timeout):
                    seen.append(url)
                    return (200, {}, v2.encoded(response(present('File:Example.ogg'), general={'wikiid': WIKI})))
                _, batch = v2.request_batch(root, 1, ['File:Example.ogg'], registry, transport, lambda _: None, time.monotonic() + 30, 0, figure_axes=True, figure_metadata_light=light)
                request = json.loads((root / batch['request']).read_text())
                self.assertEqual(request['query'], v2.query_for(WIKI, request['titles'], figure_axes=True, figure_metadata_light=light))
                self.assertEqual(request['url'], seen[0])
                artifacts = v2.payload(root)
                titles, raw = v2.verified_batch(root, batch, WIKI, artifacts, figure_axes=True, figure_metadata_light=light)
                self.assertEqual(titles, ['File:Example.ogg'])
                self.assertIn(b'imageinfo', raw)
                with self.assertRaisesRegex(ValueError, 'query semantics changed'):
                    v2.verified_batch(root, batch, WIKI, artifacts, figure_axes=True, figure_metadata_light=not light)

    def test_invalid_light_profile_refuses_before_transport(self):
        import time
        registry = v2.evidence.Registry(registry_bytes(), WIKI, '20261001')
        with tempfile.TemporaryDirectory() as tmp:
            calls = []
            with self.assertRaises(ValueError):
                v2.request_batch(Path(tmp), 1, ['File:A'], registry, lambda *a: calls.append(a), lambda _: None, time.monotonic() + 30, 0, figure_metadata_light=True)
            self.assertEqual(calls, [])
            self.assertEqual(list(Path(tmp).iterdir()), [])
