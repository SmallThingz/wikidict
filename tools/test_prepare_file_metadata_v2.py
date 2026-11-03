import copy
import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
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
