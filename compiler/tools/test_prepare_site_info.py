import argparse
import copy
import gzip
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

    def historical(self, root):
        manifest = s.evidence.decode((root/s.MANIFEST).read_bytes())
        manifest['generator_sha256'] = 'a' * 64
        manifest['dependency_sha256'] = {name: 'b' * 64 for name in s.PRODUCER_DEPENDENCIES}
        (root/s.MANIFEST).write_bytes(s.evidence.encoded(manifest))
        self.rebind(root)
        return s.evidence.decode((root/s.MANIFEST).read_bytes())

    def test_historical_producer_is_preserved_and_replayed_without_old_code(self):
        root, _ = self.collect()
        expected = self.historical(root)
        before = {path.name: path.read_bytes() for path in root.iterdir()}
        with patch.object(s, 'producer', side_effect=AssertionError('must not execute historical producer')):
            self.assertEqual(expected, s.validate_snapshot(root/s.SNAPSHOT, 'testwiktionary', '20261001'))
            self.assertEqual(set(before), set(s.capture_artifacts(root/s.SNAPSHOT)))
        self.assertEqual(before, {path.name: path.read_bytes() for path in root.iterdir()})

    def test_malformed_recorded_producer_cannot_bypass_current_replay(self):
        root, _ = self.collect()
        good = self.historical(root)
        bad = []
        for value in (None, True, '', 'a' * 63, 'A' * 64, '../producer.py'):
            bad.append({**good, 'generator_sha256': value})
        for value in (None, [], {}, {'other.py': 'b' * 64},
                      {**good['dependency_sha256'], 'extra.py': 'b' * 64},
                      {**good['dependency_sha256'], 'download_wiktionaries.py': True}):
            bad.append({**good, 'dependency_sha256': value})
        for manifest in bad:
            with self.subTest(provenance=manifest.get('dependency_sha256')):
                (root/s.MANIFEST).write_bytes(s.evidence.encoded(manifest))
                self.rebind(root)
                with self.assertRaisesRegex(ValueError, 'producer provenance'):
                    s.verify(root)

    def test_historical_provenance_still_requires_http_query_and_exact_projection(self):
        root, _ = self.collect()
        self.historical(root)
        saved = {path.name: path.read_bytes() for path in root.iterdir()}
        mutations = [('site-info.request.json', lambda value: value['query'].update(siprop='general')),
                     ('site-info.01.receipt.json', lambda value: value.update(status=503)),
                     (s.SNAPSHOT, lambda value: value['query']['statistics'].update(admins=999))]
        for name, mutate in mutations:
            with self.subTest(artifact=name):
                for key, value in saved.items(): (root/key).write_bytes(value)
                value = s.evidence.decode((root/name).read_bytes()); mutate(value)
                (root/name).write_bytes(s.evidence.encoded(value)); self.rebind(root)
                with self.assertRaises(ValueError): s.verify(root)

    def source_refusal(self, name='refused'):
        unknown = copy.deepcopy(self.data)
        unknown['query']['general']['git-hash'] = '1' * 40
        args = self.args(name)
        with self.assertRaisesRegex(ValueError, 'source mismatch'):
            self.collect(name, data=unknown)
        return args.output, unknown

    def test_current_imageinfo_observations_are_bound_to_edition_date_and_exact_bytes(self):
        fixtures = Path(__file__).parent/'testdata/current-imageinfo-defaults'
        for lang in ('de', 'it', 'mnw', 'ru', 'th', 'vi'):
            wiki = lang+'wiktionary'
            raw = gzip.decompress((fixtures/(wiki+'.json.gz')).read_bytes())
            data = s.evidence.decode(raw)
            sha = s.evidence.digest(raw)
            def read(w=wiki, language=lang, profile=s.FIGURE_PROFILE, date='20261001', digest=sha):
                return s.response(data, w, language, profile, date=date, raw_sha=digest)
            with self.subTest(wiki=wiki):
                self.assertEqual(s.figure_thumbnail_width(read()),250)
                for options in ({'w':'srwiktionary'}, {'language':'sr'}, {'profile':s.PROFILE},
                                {'date':'20261002'},{'digest':'0'*64}):
                    with self.assertRaises(ValueError):read(**options)

    def test_mon_file_defaults_require_the_observed_rollout_and_own_returned_options(self):
        fixture = Path(__file__).parent/'testdata/current-imageinfo-defaults/mnwwiktionary.json.gz'
        raw = gzip.decompress(fixture.read_bytes())
        response = s.evidence.decode(raw)
        self.assertEqual(s.scribunto_reference(s.FIGURE_MON_CORE), s.FIGURE_WMF5_SCRIBUNTO)
        self.assertFalse(s.reviewed_source(s.FIGURE_MON_CORE, s.PROFILE, 'mnwwiktionary'))
        for field, changed in (('git-hash', s.FIGURE_WMF5_CORE), ('rtl', True), ('thumbsize', 0)):
            modified = copy.deepcopy(response)
            group = 'defaultoptions' if field == 'thumbsize' else 'general'
            modified['query'][group][field] = changed
            with self.subTest(field=field), self.assertRaises(ValueError):
                s.response(modified, 'mnwwiktionary', 'mnw', s.FIGURE_PROFILE, date='20261001',
                           raw_sha=s.evidence.digest(s.evidence.encoded(modified)))

    def test_csb_current_defaults_require_exact_original_and_figure_role(self):
        fixture = Path(__file__).parent/'testdata/current-imageinfo-defaults/csbwiktionary.json.gz'
        raw = gzip.decompress(fixture.read_bytes())
        self.assertEqual(s.evidence.digest(raw), '862b5a0e908b6fba2236583698a9606c53f692090c0aff1ccbe47a87e26269b7')
        data = s.evidence.decode(raw)
        def read(value=data, wiki='csbwiktionary', language='csb', profile=s.FIGURE_PROFILE,
                 date='20261001', digest=s.evidence.digest(raw)):
            return s.response(value, wiki, language, profile, date=date, raw_sha=digest)
        observed = read()
        self.assertEqual(observed, data['query'])
        self.assertEqual(s.figure_thumbnail_width(observed), 250)
        self.assertEqual(s.scribunto_reference(s.FIGURE_CSB_CORE), s.FIGURE_WMF5_SCRIBUNTO)
        for options in ({'wiki': 'enwiktionary'}, {'language': 'en'}, {'profile': s.PROFILE},
                        {'date': None}, {'date': '20261002'}, {'digest': None},
                        {'digest': s.evidence.digest(raw+b' ')}):
            with self.subTest(options=options), self.assertRaises(ValueError): read(**options)
        for group, key, value in [('general', 'git-hash', s.SEPTEMBER_EN_CORE),
                                   ('general', 'rtl', True), ('defaultoptions', 'thumbsize', 0)]:
            changed = copy.deepcopy(data)
            changed['query'][group][key] = value
            with self.subTest(key=key), self.assertRaises(ValueError):
                read(value=changed, digest=s.evidence.digest(s.evidence.encoded(changed)))

    def test_revalidation_preserves_original_failed_http_and_observation(self):
        root, data = self.source_refusal()
        saved = {p.name: p.read_bytes() for p in root.iterdir()}
        failure_hash = s.evidence.digest(saved['site-info.failure.json'])
        with patch.object(s, 'CORE_PROFILES', (*s.CORE_PROFILES, '1' * 40)), \
                patch.object(s.evidence, 'get_response', side_effect=AssertionError('no HTTP')):
            manifest = s.revalidate(root, failure_hash)
            self.assertEqual(manifest, s.verify(root))
            self.assertEqual(data['query'], s.evidence.decode((root/s.SNAPSHOT).read_bytes())['query'])
            old_receipt = s.evidence.decode(saved['site-info.01.receipt.json'])
            self.assertFalse(old_receipt['accepted'])
            self.assertEqual(old_receipt['ended_utc'], manifest['retrieved_utc'])
            self.assertEqual('1' * 40, manifest['core'])
            self.assertEqual('retained-source-profile-refusal', manifest['revalidation']['kind'])
            for name, raw in saved.items():
                self.assertEqual(raw, (root/name).read_bytes())
            before = {p.name: p.read_bytes() for p in root.iterdir()}
            with self.assertRaises(ValueError): s.revalidate(root, failure_hash)
            self.assertEqual(before, {p.name: p.read_bytes() for p in root.iterdir()})
        with self.assertRaises(ValueError): s.verify(root)

    def test_revalidation_refuses_unreviewed_source_and_changed_failure_without_writes(self):
        root, _ = self.source_refusal()
        saved = {p.name: p.read_bytes() for p in root.iterdir()}
        failure_hash = s.evidence.digest(saved['site-info.failure.json'])
        with self.assertRaisesRegex(ValueError, 'source mismatch'):
            s.revalidate(root, failure_hash)
        with self.assertRaisesRegex(ValueError, 'identity mismatch'):
            s.revalidate(root, '0' * 64)
        self.assertEqual(saved, {p.name: p.read_bytes() for p in root.iterdir()})

    def test_revalidation_requires_original_http_request_identity_and_refusal(self):
        changes = [
            ('site-info.01.receipt.json', lambda d: d.update(status=403)),
            ('site-info.01.receipt.json', lambda d: d.update(accepted=True)),
            ('site-info.01.receipt.json', lambda d: d.update(error='HTTP status 403')),
            ('site-info.01.receipt.json', lambda d: d.update(response_sha256='0' * 64)),
            ('site-info.01.receipt.json', lambda d: d.update(response='../foreign.json')),
            ('site-info.request.json', lambda d: d['query'].update(siprop='general')),
            ('site-info.request.json', lambda d: d.update(content_language='fr')),
            ('site-info.failure.json', lambda d: d.update(error='HTTP status 403')),
        ]
        for index, (name, change) in enumerate(changes):
            with self.subTest(name=name, index=index):
                root, _ = self.source_refusal('bad-'+str(index))
                data = s.evidence.decode((root/name).read_bytes()); change(data)
                (root/name).write_bytes(s.evidence.encoded(data))
                saved = {p.name: p.read_bytes() for p in root.iterdir()}
                failure_hash = s.evidence.digest(saved['site-info.failure.json'])
                with patch.object(s, 'CORE_PROFILES', (*s.CORE_PROFILES, '1' * 40)):
                    with self.assertRaises(ValueError): s.revalidate(root, failure_hash)
                self.assertEqual(saved, {p.name: p.read_bytes() for p in root.iterdir()})

    def test_revalidated_manifest_cannot_rewrite_original_acceptance_or_omit_refusal(self):
        root, _ = self.source_refusal()
        with patch.object(s, 'CORE_PROFILES', (*s.CORE_PROFILES, '1' * 40)):
            s.revalidate(root, s.evidence.digest((root/'site-info.failure.json').read_bytes()))
            saved = {p.name: p.read_bytes() for p in root.iterdir()}
            for key in ('accepted', 'error', 'status'):
                for name, raw in saved.items(): (root/name).write_bytes(raw)
                receipt = s.evidence.decode(saved['site-info.01.receipt.json'])
                receipt[key] = {'accepted': True, 'error': 'HTTP status 503', 'status': 503}[key]
                (root/'site-info.01.receipt.json').write_bytes(s.evidence.encoded(receipt))
                manifest = s.evidence.decode(saved[s.MANIFEST])
                manifest['revalidation']['receipt_sha256'] = s.evidence.digest((root/'site-info.01.receipt.json').read_bytes())
                (root/s.MANIFEST).write_bytes(s.evidence.encoded(manifest)); self.rebind(root)
                with self.assertRaises(ValueError): s.verify(root)
            for name, raw in saved.items(): (root/name).write_bytes(raw)
            (root/'site-info.failure.json').unlink()
            self.rebind(root)
            with self.assertRaises((OSError, ValueError)): s.verify(root)

    def test_retained_992ad_response_keeps_actual_core_and_same_response_default(self):
        raw = (Path(__file__).parent/'testdata/ik-figure-defaults992ad/site-info.01.raw.json').read_bytes()
        self.assertEqual(s.evidence.digest(raw), 'f132be95ae9e9f9e9eac6d1c6f1a1159ced0be17cdbd14ea52f21a1e451fdece')
        data = s.evidence.decode(raw)
        result = s.response(data, 'ikwiktionary', 'ik', s.FIGURE_PROFILE)
        self.assertEqual(result['general']['git-hash'], '992ad5e3679f848254828e823860ba8b3ad3b39b')
        self.assertEqual(s.figure_thumbnail_width(result), 250)
        for wiki, language in [('aswiktionary', 'ik'), ('ikwiktionary', 'as')]:
            with self.assertRaises(ValueError): s.response(data, wiki, language, s.FIGURE_PROFILE)
        changed = copy.deepcopy(data)
        changed['query']['general']['git-hash'] = '0' * 40
        with self.assertRaises(ValueError): s.response(changed, 'ikwiktionary', 'ik', s.FIGURE_PROFILE)

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


    def test_figure_defaults_use_one_observation_and_preserve_legacy_capture(self):
        old_root, _ = self.collect('old-without-defaults')
        old_bytes = {p.name: p.read_bytes() for p in old_root.iterdir()}
        data = copy.deepcopy(self.data)
        data['query']['general']['thumblimits'] = {'0': 180, '1': 250, '2': 400}
        data['query']['defaultoptions'] = {'thumbsize': 1, 'unrelated': 'retained'}
        args = self.args('figure-defaults'); args.figure_defaults = True
        requests = []
        def get(url, timeout):
            requests.append(url)
            self.assertIn('siprop=general%7Cstatistics%7Cdefaultoptions', url)
            return 200, {}, s.evidence.encoded(data)
        manifest = s.capture(args, transport=get, sleep=lambda _: None)
        self.assertEqual(len(requests), 1)
        self.assertEqual(manifest['profile'], s.FIGURE_PROFILE)
        self.assertEqual(s.verify(args.output), manifest)
        snapshot = s.evidence.decode((args.output/s.SNAPSHOT).read_bytes())
        self.assertEqual(snapshot['query'], data['query'])
        self.assertEqual(s.figure_thumbnail_width(snapshot['query']), 250)
        self.assertEqual(old_bytes, {p.name: p.read_bytes() for p in old_root.iterdir()})


    def test_current_reviewed_core_keeps_observed_figure_defaults_and_source_identity(self):
        for core in ('ead780177c5a02aa63ac6fd3a50977df9719fe63', 'f45897451256aa3799aecc5d7ee320ade22beaec'):
            with self.subTest(core=core):
                data = copy.deepcopy(self.data)
                data['query']['general'].update({'git-hash': core, 'thumblimits': [135, 275, 410]})
                data['query']['defaultoptions'] = {'thumbsize': 2}
                args = self.args('current-figure-defaults-'+core); args.figure_defaults = True
                raw = s.evidence.encoded(data)
                manifest = s.capture(args, transport=lambda *_: (200, {}, raw), sleep=lambda _: None)
                self.assertEqual(manifest['core'], core)
                self.assertEqual(s.verify(args.output), manifest)
                snapshot = s.evidence.decode((args.output/s.SNAPSHOT).read_bytes())
                self.assertEqual(snapshot['query'], data['query'])
                self.assertEqual(s.figure_thumbnail_width(snapshot['query']), 410)
                self.assertEqual((args.output/'site-info.01.raw.json').read_bytes(), raw)
                manifest['core'] = '0470f6c99a6456a366635bf25a517a1f951de6f5'
                (args.output/s.MANIFEST).write_bytes(s.evidence.encoded(manifest)); self.rebind(args.output)
                with self.assertRaisesRegex(ValueError, 'core differs from API observation'):
                    s.verify(args.output)

    def test_figure_default_index_is_remapped_api_index_not_installation_default(self):
        data = copy.deepcopy(self.data)
        data['query']['general']['thumblimits'] = {'2': 410, '0': 135, '1': 275}
        data['query']['defaultoptions'] = {'thumbsize': 2}
        self.assertEqual(s.figure_thumbnail_width(data['query']), 410)
        data['query']['general']['thumblimits'] = [135, 275, 410]
        self.assertEqual(s.figure_thumbnail_width(data['query']), 410)
        for index in (None, False, True, -1, 3, 5, 1.0, '1'):
            data['query']['defaultoptions']['thumbsize'] = index
            with self.subTest(index=index), self.assertRaises(ValueError):
                s.response(data, 'testwiktionary', 'en', s.FIGURE_PROFILE)
        data['query']['defaultoptions']['thumbsize'] = 1
        for limits in ({'1': 180, '4': 250}, {'00': 180}, [], [0], [True], [1.5], [2**32]):
            data['query']['general']['thumblimits'] = limits
            with self.subTest(limits=limits), self.assertRaises(ValueError):
                s.response(data, 'testwiktionary', 'en', s.FIGURE_PROFILE)


    def test_figure_profile_cannot_be_added_by_rebinding_old_query_or_missing_defaults(self):
        root, _ = self.collect('old-query')
        manifest = s.evidence.decode((root/s.MANIFEST).read_bytes())
        manifest['profile'] = s.FIGURE_PROFILE
        (root/s.MANIFEST).write_bytes(s.evidence.encoded(manifest)); self.rebind(root)
        with self.assertRaisesRegex(ValueError, 'Unrequested'): s.verify(root)
        args = self.args('missing-defaults'); args.figure_defaults = True
        with self.assertRaisesRegex(ValueError, 'figure thumbnail default'):
            s.capture(args, transport=lambda *_: (200, {}, s.evidence.encoded(self.data)), sleep=lambda _: None)
        self.assertTrue((args.output/'site-info.01.raw.json').is_file())
        self.assertFalse((args.output/s.COMPLETE).exists())
        self.assertFalse((args.output/s.SNAPSHOT).exists())




class RetainedSeptemberEnglishTests(unittest.TestCase):
    def fixtures(self):
        root = Path(__file__).parent/'testdata/en-september-siteinfo'
        return ((root/'ordinary', s.PROFILE,
                 '83fcd31286d6be77e11d199c5e1615078a1b4c0b2bf3b08b11508c55e103f976'),
                (root/'figure', s.FIGURE_PROFILE,
                 'bdfe398945abd372cdb7d12df74c586c4843f1711786949bc1478889967693d5'))

    def test_retained_observations_require_exact_date_body_profile_and_edition(self):
        for root, profile, expected_sha in self.fixtures():
            with self.subTest(profile=profile):
                raw = (root/'site-info.01.raw.json').read_bytes()
                self.assertEqual(s.evidence.digest(raw), expected_sha)
                data = s.evidence.decode(raw)
                options = dict(date='20260901', raw_sha=expected_sha)
                result = s.response(data, 'enwiktionary', 'en', profile, **options)
                self.assertEqual(result, data['query'])
                self.assertEqual(result['general']['git-hash'], s.SEPTEMBER_EN_CORE)
                self.assertEqual(s.scribunto_reference(s.SEPTEMBER_EN_CORE), s.FIGURE_WMF5_SCRIBUNTO)
                if profile == s.FIGURE_PROFILE:
                    self.assertEqual(s.figure_thumbnail_width(result), 250)
                for changed in (dict(date=None), dict(date='20261001'),
                                dict(raw_sha=s.evidence.digest(raw+b'\n'))):
                    with self.subTest(changed=changed), self.assertRaises(ValueError):
                        s.response(data, 'enwiktionary', 'en', profile, **(options | changed))
                other = s.PROFILE if profile == s.FIGURE_PROFILE else s.FIGURE_PROFILE
                with self.assertRaises(ValueError):
                    s.response(data, 'enwiktionary', 'en', other, **options)
                with self.assertRaises(ValueError):
                    s.response(data, 'dewiktionary', 'de', profile, **options)

    def test_offline_revalidation_preserves_originals_and_current_observation_scope(self):
        work = Path(os.environ.get('WIKIDICT_SITE_INFO_TEST_ROOT', '.tmp/site-info-v2-tests'))
        work.mkdir(parents=True, exist_ok=True)
        for fixture, profile, _ in self.fixtures():
            with self.subTest(profile=profile), tempfile.TemporaryDirectory(prefix='en-september-', dir=work) as temporary:
                root = Path(temporary)
                original = {p.name:p.read_bytes() for p in fixture.iterdir()}
                self.assertEqual(len(original), 8)
                for name, raw in original.items():
                    (root/name).write_bytes(raw)
                with patch.object(s.evidence, 'get_response', side_effect=AssertionError('offline means no HTTP')):
                    manifest = s.revalidate(root, s.evidence.digest(original['site-info.failure.json']))
                    self.assertEqual(s.verify(root), manifest)
                    snapshot = s.validate_snapshot(root/s.SNAPSHOT, 'enwiktionary', '20260901',
                                                   file_defaults=profile == s.FIGURE_PROFILE)
                    self.assertEqual(snapshot, manifest)
                self.assertEqual({name:(root/name).read_bytes() for name in original}, original)
                self.assertIs(s.evidence.decode(original['site-info.01.receipt.json'])['accepted'], False)
                projected = s.evidence.decode((root/s.SNAPSHOT).read_bytes())
                self.assertEqual(projected['query'], s.evidence.decode(original['site-info.01.raw.json'])['query'])
                self.assertEqual(projected['temporal_scope'], 'current-api-observation')
                self.assertEqual(projected['date'], '20260901')
                self.assertNotIn('dump_date', projected)
                self.assertTrue(projected['retrieved_utc'].startswith('2026-11-24T11:01:01.'))
                with self.assertRaises(ValueError):
                    s.validate_snapshot(root/s.SNAPSHOT, 'enwiktionary', '20261001',
                                        file_defaults=profile == s.FIGURE_PROFILE)
                if profile == s.FIGURE_PROFILE:
                    with self.assertRaisesRegex(ValueError, 'scoped to the ImageInfo'):
                        s.validate_snapshot(root/s.SNAPSHOT, 'enwiktionary', '20260901')
                self.assertEqual(set(p.name for p in root.iterdir())-set(original),
                                 {s.SNAPSHOT, s.MANIFEST, s.COMPLETE})


class RetainedKwBfe249Tests(unittest.TestCase):
    def fixture(self):
        return Path(__file__).parent/'testdata/kw-figure-defaults-bfe249'

    def test_actual_kw_response_preserves_core_default_and_refuses_foreign_identity(self):
        raw = (self.fixture()/'site-info.01.raw.json').read_bytes()
        self.assertEqual(s.evidence.digest(raw), '503fe4f9fd0424e0cfe2edad648283876f65f939a6ac62df1a9cf8d88b8a3cfa')
        data = s.evidence.decode(raw)
        result = s.response(data, 'kwwiktionary', 'kw', s.FIGURE_PROFILE)
        self.assertEqual(result['general']['git-hash'], 'bfe24921d500b20f2938fb8fe2a09cf5cac80161')
        self.assertEqual(s.figure_thumbnail_width(result), 250)
        for wiki, language in [('chrwiktionary', 'kw'), ('kwwiktionary', 'chr')]:
            with self.assertRaises(ValueError): s.response(data, wiki, language, s.FIGURE_PROFILE)
        changed = copy.deepcopy(data)
        changed['query']['general']['git-hash'] = '0' * 40
        with self.assertRaises(ValueError): s.response(changed, 'kwwiktionary', 'kw', s.FIGURE_PROFILE)
        changed = copy.deepcopy(data)
        del changed['query']['defaultoptions']
        with self.assertRaises(ValueError): s.response(changed, 'kwwiktionary', 'kw', s.FIGURE_PROFILE)

    def test_actual_kw_offline_revalidation_preserves_all_eight_originals(self):
        work = Path(os.environ.get('WIKIDICT_SITE_INFO_TEST_ROOT', '.tmp/site-info-v2-tests'))
        work.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix='kw-', dir=work) as temporary:
            root = Path(temporary)
            original = {p.name:p.read_bytes() for p in self.fixture().iterdir()}
            self.assertEqual(len(original), 8)
            for name, raw in original.items(): (root/name).write_bytes(raw)
            with patch.object(s.evidence, 'get_response', side_effect=AssertionError('offline means no HTTP')):
                manifest = s.revalidate(root, s.evidence.digest(original['site-info.failure.json']))
                self.assertEqual(s.verify(root), manifest)
            self.assertEqual({name:(root/name).read_bytes() for name in original}, original)
            self.assertIs(s.evidence.decode((root/'site-info.01.receipt.json').read_bytes())['accepted'], False)
            self.assertEqual(manifest['wiki'], 'kwwiktionary')
            self.assertEqual(manifest['core'], 'bfe24921d500b20f2938fb8fe2a09cf5cac80161')
            projected = s.evidence.decode((root/s.SNAPSHOT).read_bytes())
            self.assertEqual(projected['query'], s.evidence.decode(original['site-info.01.raw.json'])['query'])
            self.assertEqual(set(p.name for p in root.iterdir())-set(original), {s.SNAPSHOT,s.MANIFEST,s.COMPLETE})

if __name__ == '__main__':
    unittest.main()
