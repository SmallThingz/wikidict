import argparse
import copy
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import prepare_site_info as s
import build_wiktionaries as builder
import test_site_info_snapshot as legacy_tests


class SiteInfoCaptureTests(unittest.TestCase):
    def setUp(self):
        work = Path(os.environ.get('WIKIDICT_SITE_INFO_TEST_ROOT', '.tmp/site-info-v2-tests'))
        work.mkdir(parents=True, exist_ok=True)
        self.tmp = tempfile.TemporaryDirectory(prefix='case-', dir=work)
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()
        self.original = legacy_tests.SiteInfoSnapshotTests.fixture(self)
        self.primary = self.root / 'primary'
        self.primary.mkdir()
        # Hermetic byte fixtures exercise pin validation without network/source downloads.
        pins = {}
        for name in s.SOURCE_PINS:
            raw = ('reviewed fixture ' + name).encode()
            (self.primary / name).write_bytes(raw)
            pins[name] = s.evidence.digest(raw)
        self.pin_patch = patch.object(s, 'SOURCE_PINS', pins)
        self.pin_patch.start()
        self.addCleanup(self.pin_patch.stop)
        self.data = {'batchcomplete': True, 'query': {
            'general': {'wikiid': 'testwiktionary', 'lang': 'en', 'server': '//actual.example',
                        'script': '/w/index.php', 'articlepath': '/wiki/$1', 'git-hash': s.CORE,
                        'time': '2026-10-05T23:00:00Z'},
            'statistics': {'pages': 13332, 'articles': 8530, 'images': 0, 'edits': 60889,
                           'users': 1596, 'activeusers': 14, 'admins': 2, 'jobs': 0}}}

    def args(self, name='new'):
        return argparse.Namespace(wiki='testwiktionary', date='20261001',
            namespace_registry=self.original/'namespace-registry.tsv', primary_sources=self.primary,
            output=self.root/name, delay=0, wall_seconds=30)

    def collect(self, name='new', data=None, transport=None):
        raw = s.evidence.encoded(self.data if data is None else data)
        def get(url, timeout):
            self.assertIn('siprop=general%7Cstatistics', url)
            self.assertGreater(timeout, 0)
            self.assertLessEqual(timeout, 30)
            return 200, {'Content-Type': 'application/json'}, raw
        args = self.args(name)
        result = s.capture(args, transport=transport or get, sleep=lambda _: None)
        return args.output, result

    def rebind(self, root):
        manifest = s.evidence.decode((root/s.MANIFEST).read_bytes())
        manifest['artifacts'] = s.payload(root)
        (root/s.MANIFEST).write_bytes(s.evidence.encoded(manifest))
        (root/s.COMPLETE).write_bytes(s.evidence.encoded({'schema': s.SCHEMA,
            'manifest_sha256': s.evidence.digest((root/s.MANIFEST).read_bytes())}))

    def test_complete_one_response_and_legacy_evidence_immutable(self):
        before = {p.name: p.read_bytes() for p in self.original.iterdir()}
        root, manifest = self.collect()
        self.assertEqual(s.validate_snapshot(root/s.SNAPSHOT, 'testwiktionary', '20261001'), manifest)
        projection = s.evidence.decode((root/s.SNAPSHOT).read_bytes())
        self.assertEqual(projection['query'], self.data['query'])
        self.assertEqual(projection['schema'], s.HEADER)
        self.assertEqual(projection['query']['statistics']['images'], 0)
        self.assertEqual(manifest['dump_date'], None)
        self.assertEqual(manifest['date'], '20261001')
        self.assertEqual(manifest['temporal_scope'], 'current-api-observation')
        self.assertEqual(before, {p.name: p.read_bytes() for p in self.original.iterdir()})
        self.assertEqual(set(s.capture_artifacts(root/s.SNAPSHOT)), {p.name for p in root.iterdir()})
        with self.assertRaises(FileExistsError): self.collect()

    def test_all_seven_required_zero_allowed_and_invalid_numbers_rejected(self):
        for key in s.FIELDS.values():
            good = copy.deepcopy(self.data); good['query']['statistics'][key] = 0
            s.response(good, 'testwiktionary', 'en')
            for bad in (None, True, -1, 1.5, '1', 2**53):
                data = copy.deepcopy(good); data['query']['statistics'][key] = bad
                with self.subTest(key=key, bad=bad), self.assertRaises(ValueError):
                    s.response(data, 'testwiktionary', 'en')
            del good['query']['statistics'][key]
            with self.assertRaises(ValueError): s.response(good, 'testwiktionary', 'en')

    def test_identity_source_errors_and_continuation_fail_closed(self):
        for key, value in (('wikiid', 'otherwiktionary'), ('lang', 'fr'), ('git-hash', '0'*40),
                           ('server', 'https://bad/path'), ('time', '2026-10-05')):
            data = copy.deepcopy(self.data); data['query']['general'][key] = value
            with self.subTest(key=key), self.assertRaises(ValueError):
                s.response(data, 'testwiktionary', 'en')
        for key in ('error', 'errors', 'warnings', 'continue'):
            with self.subTest(key=key), self.assertRaises(ValueError):
                s.response({**self.data, key: {}}, 'testwiktionary', 'en')
        with self.assertRaises(ValueError): s.evidence.decode(b'{"query":{},"query":{}}')

    def test_retry_evidence_preserved_and_replayed(self):
        replies = iter([(503, {'Retry-After': '1'}, b'temporary failure'),
                        (200, {}, s.evidence.encoded(self.data))])
        root, manifest = self.collect(transport=lambda *_: next(replies))
        self.assertEqual(manifest['accepted_receipt'], 'site-info.02.receipt.json')
        self.assertEqual((root/'site-info.01.raw.json').read_bytes(), b'temporary failure')
        self.assertEqual(s.verify(root), manifest)
        (root/'site-info.01.receipt.json').unlink()
        with self.assertRaises((ValueError, OSError)): s.verify(root)

    def test_failed_unknown_response_cannot_publish(self):
        bad = copy.deepcopy(self.data); del bad['query']['statistics']['admins']
        with self.assertRaises(ValueError): self.collect(data=bad)
        root = self.args().output
        self.assertTrue((root/'site-info.01.raw.json').is_file())
        self.assertTrue((root/'site-info.failure.json').is_file())
        self.assertFalse((root/s.COMPLETE).exists())
        self.assertFalse((root/s.SNAPSHOT).exists())

    def test_rebound_hashes_cannot_bless_changed_raw_projection_or_primary(self):
        root, _ = self.collect()
        rawpath = root/'site-info.01.raw.json'
        data = copy.deepcopy(self.data); data['query']['statistics']['admins'] = 42
        rawpath.write_bytes(s.evidence.encoded(data))
        receipt = s.evidence.decode((root/'site-info.01.receipt.json').read_bytes())
        receipt.update(response_bytes=rawpath.stat().st_size, response_sha256=s.evidence.digest(rawpath.read_bytes()))
        (root/'site-info.01.receipt.json').write_bytes(s.evidence.encoded(receipt))
        self.rebind(root)
        with self.assertRaisesRegex(ValueError, 'projection'): s.verify(root)
        other, _ = self.collect('other')
        (other/'site-info.source-SiteLibrary.php').write_bytes(b'unreviewed source')
        self.rebind(other)
        with self.assertRaisesRegex(ValueError, 'primary source'): s.verify(other)

    def test_symlinks_foreign_namespace_and_unsupported_schema_rejected(self):
        root, _ = self.collect()
        with self.assertRaises(ValueError): s.validate_snapshot(root/s.SNAPSHOT, 'otherwiktionary', '20261001')
        raw = root/'site-info.01.raw.json'; saved = self.root/'saved'; raw.rename(saved); raw.symlink_to(saved)
        with self.assertRaises(ValueError): s.verify(root)
        other, _ = self.collect('other')
        manifest = s.evidence.decode((other/s.MANIFEST).read_bytes()); manifest['schema'] = 'unsupported'
        (other/s.MANIFEST).write_bytes(s.evidence.encoded(manifest))
        with self.assertRaises(ValueError): builder.verified_auxiliary_hashes({'site-info': other/s.SNAPSHOT})

    def test_builder_prefers_versioned_capture_and_pins_complete_evidence_separately(self):
        root, manifest = self.collect('capture/site-info')
        discovered = builder.discover_auxiliary_generation(self.original, 'site-info', ('site-info',), 'testwiktionary', '20261001')
        self.assertEqual(discovered, {'site-info': root/s.SNAPSHOT})
        snapshots = {**discovered, 'namespace-registry': self.original/'namespace-registry.tsv'}
        hashes = builder.verified_auxiliary_hashes(snapshots, 'testwiktionary', '20261001')
        identities, inventories = builder.auxiliary_capture_identities(snapshots)
        self.assertEqual(identities['site-info'], s.evidence.digest((root/s.MANIFEST).read_bytes()))
        capture = json.loads((self.original/'capture.complete.json').read_bytes())
        builder.validate_captured_snapshot('site-info', root/s.SNAPSHOT, capture, [capture['source_xml']], self.original)
        destination = self.root/'pinned'
        pinned = builder.pinned_auxiliary_snapshots(snapshots, hashes, destination, identities, inventories)
        self.assertEqual(pinned['site-info'], destination/'site-info'/s.SNAPSHOT)
        self.assertEqual(builder.verified_auxiliary_hashes(pinned), hashes)
        self.assertEqual(builder.auxiliary_capture_identities(pinned), (identities, inventories))
        self.assertEqual(s.validate_snapshot(pinned['site-info']), manifest)
        self.assertEqual((destination/'namespace-registry.tsv').read_bytes(), (self.original/'namespace-registry.tsv').read_bytes())
        (root/s.COMPLETE).unlink()
        with self.assertRaises((OSError, ValueError)):
            builder.discover_auxiliary_generation(self.original, 'site-info', ('site-info',), 'testwiktionary', '20261001')

    def test_versioned_snapshot_cannot_fall_back_without_manifest(self):
        root, _ = self.collect()
        (root/s.MANIFEST).unlink()
        with self.assertRaisesRegex(ValueError, 'requires its capture manifest'):
            builder.verified_auxiliary_hashes({'site-info': root/s.SNAPSHOT})


    def test_each_reviewed_core_is_preserved_from_its_accepted_api_response(self):
        for number, core in enumerate(s.CORE_PROFILES):
            with self.subTest(core=core):
                data=copy.deepcopy(self.data);data['query']['general']['git-hash']=core
                root,manifest=self.collect('core-'+str(number),data=data)
                self.assertEqual(manifest['core'],core)
                self.assertEqual(s.verify(root)['core'],core)
                projection=s.evidence.decode((root/s.SNAPSHOT).read_bytes())
                self.assertEqual(projection['query']['general']['git-hash'],core)
                self.assertEqual(projection['query']['statistics'],data['query']['statistics'])

    def test_unknown_or_untyped_core_preserves_failed_evidence_without_publication(self):
        for number,core in enumerate(('f'*40,None,[],{})):
            with self.subTest(core=core):
                data=copy.deepcopy(self.data);data['query']['general']['git-hash']=core
                name='unknown-'+str(number)
                with self.assertRaisesRegex(ValueError,'source mismatch'):self.collect(name,data=data)
                root=self.args(name).output
                raw=s.evidence.decode((root/'site-info.01.raw.json').read_bytes())
                self.assertEqual(raw['query']['general']['git-hash'],core)
                receipt=s.evidence.decode((root/'site-info.01.receipt.json').read_bytes())
                self.assertIs(receipt['accepted'],False)
                self.assertTrue((root/'site-info.failure.json').is_file())
                self.assertFalse((root/s.COMPLETE).exists())
                self.assertFalse((root/s.SNAPSHOT).exists())

    def test_supported_manifest_core_substitution_cannot_relabel_observed_revision(self):
        for number,core in enumerate(s.CORE_PROFILES):
            with self.subTest(core=core):
                data=copy.deepcopy(self.data);data['query']['general']['git-hash']=core
                root,manifest=self.collect('mismatch-'+str(number),data=data)
                manifest['core']=next(value for value in s.CORE_PROFILES if value!=core)
                (root/s.MANIFEST).write_bytes(s.evidence.encoded(manifest));self.rebind(root)
                with self.assertRaisesRegex(ValueError,'core differs from API observation'):s.verify(root)

    def test_new_core_does_not_relax_primary_source_pins(self):
        data=copy.deepcopy(self.data);data['query']['general']['git-hash']=s.CORE_PROFILES[1]
        root,_=self.collect(data=data)
        (root/'site-info.source-ApiQuerySiteinfo.php').write_bytes(b'unreviewed counter contract')
        self.rebind(root)
        with self.assertRaisesRegex(ValueError,'primary source'):s.verify(root)


if __name__ == '__main__':
    unittest.main()
