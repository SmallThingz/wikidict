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
