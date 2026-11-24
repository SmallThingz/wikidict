import argparse
import copy
import gzip
import json
from pathlib import Path
import tempfile
import time
import unittest
from unittest.mock import patch

import build_wiktionaries as builder
import prepare_figure_metadata as figure
import prepare_site_info as site
from test_prepare_file_metadata import registry_bytes, present_page
import test_prepare_site_info as site_tests


class FigureInputTests(unittest.TestCase):
    def setUp(self):
        site_tests.SiteInfoCaptureTests.setUp(self)
        self.wiki, self.date = 'arwiktionary', '20261001'
        self.namespace = self.root / 'namespace-registry.tsv'
        self.namespace.write_bytes(registry_bytes())
        self.core = next(iter(figure.FIGURE_SOURCE_PROFILES))
        self.data['query']['general'].update(wikiid=self.wiki, lang='ar',
            server='https://ar.wiktionary.org', **{'git-hash': self.core},
            rtl=True, thumblimits=[120, 250, 400])
        self.data['query']['defaultoptions'] = {'thumbsize': 1}
        args = argparse.Namespace(wiki=self.wiki, date=self.date,
            namespace_registry=self.namespace, primary_sources=self.primary,
            output=self.root/'defaults', delay=0, wall_seconds=30, figure_defaults=True)
        site.capture(args, transport=lambda *_: (200, {}, figure.encoded(self.data)), sleep=lambda _: None)
        self.projection = self.root / 'projection'
        self.projection.mkdir()
        page = present_page('ملف:Example.svg')
        page['imageinfo'][0].update(width=800, height=600, mime='image/svg+xml', mediatype='DRAWING')
        general = copy.deepcopy(self.data['query']['general'])
        profile = figure.FIGURE_SOURCE_PROFILES[self.core]
        self.api = {'batchcomplete': True, 'curtimestamp': '2026-10-05T23:00:00Z',
                    'query': {'general': general, 'pages': [page]}}
        self.site_api = {'curtimestamp': '2026-10-05T23:00:00Z', 'query': {
            'general': general, 'extensions': [{'name': name, 'type': 'media', 'vcs-version': revision}
                for name, revision in profile['media_extensions'].items()]}}
        self.requests = [{'canonical_file': 'ملف:Example.svg', 'format': 'thumbnail',
                          'width_px': 250, 'height_px': None}]
        self.request_path = self.root / 'requests.json'
        self.request_path.write_bytes(figure.encoded(self.requests))
        self.write_projection()

    def write_projection(self):
        raw, site_raw = figure.encoded(self.api), figure.encoded(self.site_api)
        profile = dict(figure.FIGURE_SOURCE_PROFILES[self.core], site_raw_sha256=figure.digest(site_raw))
        value = figure.figure_sizing_document(raw, self.namespace.read_bytes(), self.wiki,
            self.date, self.requests, profile, site_raw)
        value['generator_sha256'] = figure.LEGACY_GENERATOR
        output = figure.encoded(value)
        for filename, data in (('figure-sizing.json', output), ('figure-sizing.raw.json', raw),
                               ('figure-sizing.site.json', site_raw)):
            (self.projection / filename).write_bytes(data)
        authority = {'schema': figure.FIGURE_SIZING_SCHEMA + '.projection',
            'output': {'path': 'figure-sizing.json', 'bytes': len(output), 'sha256': figure.digest(output)},
            'raw': {'path': 'figure-sizing.raw.json', 'bytes': len(raw), 'sha256': figure.digest(raw)},
            'site': {'path': 'figure-sizing.site.json', 'bytes': len(site_raw), 'sha256': figure.digest(site_raw)},
            'inputs': {'api_response_sha256': figure.digest(raw),
                'namespace_registry_sha256': figure.digest(self.namespace.read_bytes()),
                'requests_sha256': figure.digest(self.request_path.read_bytes()),
                'sources': {name: {'bytes': 1, 'sha256': profile[role]}
                            for role, name in figure.FIGURE_SOURCE_FILES.items()}},
            'temporal_scope': 'fresh-current-api-observation-not-historical-equivalence'}
        (self.projection / figure.PROJECTION).write_bytes(figure.encoded(authority))

    def stage(self, name='assembled'):
        args = argparse.Namespace(wiki=self.wiki, date=self.date, defaults=self.root/'defaults',
            projection=self.projection, requests=self.request_path, output=self.root/name)
        with patch.object(site, 'capture', side_effect=AssertionError('offline staging performed acquisition')):
            figure.stage(args)
        return args.output

    def snapshots(self, root):
        return {**{name: root/filename for name, filename in figure.ROLES.items()},
                'namespace-registry': self.namespace}

    def test_offline_replay_pins_all_four_roles_and_exact_source_evidence_once(self):
        root = self.stage('figure-inputs')
        record = figure.verify(root)
        self.assertEqual(record['coverage']['whole_edition'], False)
        self.assertEqual((record['coverage']['files'], record['coverage']['occurrences']), (1, 1))
        snapshots = self.snapshots(root)
        with patch.object(builder, '_FIGURE_TUPLE_REPLAYS', {}):
            with patch.object(figure, 'verify', wraps=figure.verify) as replay:
                discovered = builder.discover_auxiliary_generation(self.root, 'figure-inputs',
                    tuple(figure.ROLES), self.wiki, self.date)
                self.assertEqual(discovered, {name: snapshots[name] for name in figure.ROLES})
                self.assertEqual(replay.call_count, 1)
            with patch.object(figure, 'verify', wraps=figure.verify) as replay:
                started = time.monotonic()
                hashes = builder.verified_auxiliary_hashes(snapshots, self.wiki, self.date)
                elapsed = time.monotonic() - started
                self.assertEqual(replay.call_count, 0)  # Same invocation reuses the guarded complete tuple.
                print(json.dumps({'figure_tuple_replays': replay.call_count,
                                  'fixture_validation_wall_seconds': elapsed,
                                  'figure_fixture_bytes': sum(row['bytes'] for row in record['artifacts'].values())}))
            pinned = builder.pinned_auxiliary_snapshots(snapshots, hashes, self.root/'pinned')
            self.assertEqual({pinned[name].parent for name in figure.ROLES}, {self.root/'pinned'/'figure-inputs'})
            self.assertEqual(figure.verify(pinned['figure-sizing'].parent), record)
            for role, filename in figure.ROLES.items():
                self.assertEqual(pinned[role].read_bytes(), (root/filename).read_bytes())
                self.assertIn('--'+role+'-snapshot', builder.auxiliary_snapshot_args(pinned))

    def test_incomplete_roles_and_missing_production_inputs_fail_before_native_work(self):
        root = self.stage()
        for role in figure.ROLES:
            snapshots = self.snapshots(root)
            del snapshots[role]
            with self.subTest(role=role), self.assertRaisesRegex(ValueError, 'Incomplete Figure'):
                builder.verified_auxiliary_hashes(snapshots, self.wiki, self.date)
        with self.assertRaisesRegex(ValueError, 'before native preparation'):
            builder.require_figure_inputs({}, required=True)
        builder.require_figure_inputs({}, required=False)

    def test_mixed_valid_captures_cannot_form_a_tuple(self):
        first = self.stage('first')
        self.requests[0]['width_px'] = 300
        self.request_path.write_bytes(figure.encoded(self.requests))
        self.write_projection()
        second = self.stage('second')
        snapshots = self.snapshots(first)
        snapshots['figure-sizing'] = second/'figure-sizing.json'
        with self.assertRaisesRegex(ValueError, 'different source captures'):
            builder.verified_auxiliary_hashes(snapshots, self.wiki, self.date)

    def test_rehashed_projection_axes_still_fail_exact_source_replay(self):
        path = self.projection/'figure-sizing.json'
        value = figure.decode(path.read_bytes())
        value['records'][0]['original_width'] += 1
        path.write_bytes(figure.encoded(value))
        authority = figure.decode((self.projection/figure.PROJECTION).read_bytes())
        authority['output'].update(bytes=path.stat().st_size, sha256=figure.digest(path.read_bytes()))
        (self.projection/figure.PROJECTION).write_bytes(figure.encoded(authority))
        with self.assertRaisesRegex(ValueError, 'exact source replay'):
            self.stage()
        self.assertFalse((self.root/'assembled'/figure.COMPLETE).exists())

    def test_old_defaults_profile_and_namespace_mismatch_remain_errors(self):
        with patch.object(site, 'validate_snapshot', return_value={'profile': site.PROFILE}):
            with self.assertRaisesRegex(ValueError, 'default-options'):
                self.stage()
        root = self.stage()
        snapshots = self.snapshots(root)
        alternate = self.root/'other-ns.tsv'
        alternate.write_bytes(self.namespace.read_bytes()+b'# changed\n')
        snapshots['namespace-registry'] = alternate
        with self.assertRaisesRegex(ValueError, 'different namespace'):
            builder.verified_auxiliary_hashes(snapshots, self.wiki, self.date)

    def test_tuple_replay_rejects_foreign_core_unknown_handlers_upscale_and_height(self):
        raw, site_raw = figure.encoded(self.api), figure.encoded(self.site_api)
        profile = dict(figure.FIGURE_SOURCE_PROFILES[self.core], site_raw_sha256=figure.digest(site_raw))
        for request in ({**self.requests[0], 'width_px': 801},
                        {**self.requests[0], 'height_px': 10},
                        {**self.requests[0], 'format': 'framed'}):
            with self.subTest(request=request), self.assertRaises(ValueError):
                figure.figure_sizing_document(raw, self.namespace.read_bytes(), self.wiki,
                    self.date, [request], profile, site_raw)
        for field, value in (('mime', 'image/unknown'), ('mediatype', 'AUDIO')):
            changed = copy.deepcopy(self.api)
            changed['query']['pages'][0]['imageinfo'][0][field] = value
            with self.subTest(field=field), self.assertRaises(ValueError):
                figure.figure_sizing_document(figure.encoded(changed), self.namespace.read_bytes(),
                    self.wiki, self.date, self.requests, profile, site_raw)
        changed = copy.deepcopy(self.api)
        changed['query']['general']['git-hash'] = 'f' * 40
        with self.assertRaisesRegex(ValueError, 'Unreviewed'):
            figure.figure_sizing_document(figure.encoded(changed), self.namespace.read_bytes(),
                self.wiki, self.date, self.requests, profile, site_raw)

    def test_staging_never_changes_retained_captures_or_accepts_malformed_authority(self):
        args = argparse.Namespace(wiki=self.wiki, date=self.date, defaults=self.root/'defaults',
            projection=self.projection, requests=self.request_path, output=self.root/'assembled')
        for source in (args.defaults, args.projection):
            before = {path.name: path.read_bytes() for path in source.iterdir()}
            args.output = source/'nested'
            with self.subTest(source=source), self.assertRaisesRegex(ValueError, 'retained input'):
                figure.stage(args)
            self.assertEqual(before, {path.name: path.read_bytes() for path in source.iterdir()})
        alias = self.root/'projection-link'
        alias.symlink_to(self.projection, target_is_directory=True)
        args.projection, args.output = alias, self.root/'assembled'
        with self.assertRaisesRegex(ValueError, 'Unsafe Figure projection'):
            figure.stage(args)
        args.projection = self.projection
        for index, value in enumerate(([], {'inputs': None}, {'inputs': []}, {'inputs': 'bad'})):
            args.output = self.root/('malformed-' + str(index))
            (self.projection/figure.PROJECTION).write_bytes(figure.encoded(value))
            with self.subTest(value=value), self.assertRaisesRegex(ValueError, 'Invalid Figure projection authority'):
                figure.stage(args)
            self.assertFalse((args.output/figure.COMPLETE).exists())


ML_FIGURE_TITLE_FIXTURES = Path(__file__).parent / 'testdata/ml-figure-title-seeds01'
D191_CORE = 'd1919ec5e4ebd7b0dea1ff6ea1cb4347a9349ca2'
D191_F03 = 'f03f1fdaa2d112807b6ce63170eb50e86de615bd'


class ExplicitFigureTitleInputs(unittest.TestCase):
 def setUp(self):
  import tempfile
  self.tmp=tempfile.TemporaryDirectory();self.addCleanup(self.tmp.cleanup);self.root=Path(self.tmp.name)
 def row(self,kind,raw,number=0):
  source=self.root/('source-'+str(number));source.write_bytes(raw)
  return dict(figure.evidence.snapshot_input(source,self.root,f'figure-file-query-{number:04d}.{kind}'),kind=kind)
 def names(self,rows):return figure.provider_query_titles(self.root,rows,(ML_FIGURE_TITLE_FIXTURES/'namespace-registry.tsv').read_bytes(),'mlwiktionary','20261001')
 def test_explicit_original_titles_match_all_sixteen_recorded_api_names(self):
  # Independent expected names come from the actually accepted official v2
  # observation, not from a second call to the normalizer being tested.
  expected={line.split('\t',1)[0] for line in (ML_FIGURE_TITLE_FIXTURES/'observed.tsv').read_text().splitlines()[1:]}
  row=self.row('titles',(ML_FIGURE_TITLE_FIXTURES/'titles.txt').read_bytes());self.assertEqual(16,len(expected));self.assertEqual(expected,self.names([row]))
 def test_legacy_warning_source_and_explicit_titles_union_without_owner_claim(self):
  # Synthetic unit warning only; never used as a capture input or presented
  # as a real native failure. The existing warning grammar stays unchanged.
  warning=b'file metadata snapshot unavailable: title=File:Example.ogg\nignored text\n'
  log=self.row('log',warning);titles=self.row('titles',b'File:Example.ogg\nMedia:Second.wav\n',1)
  self.assertEqual({'പ്രമാണം:Example.ogg'},self.names([log]))
  self.assertEqual({'പ്രമാണം:Example.ogg','പ്രമാണം:Second.wav'},self.names([log,titles]))
 def test_invalid_kind_extension_and_non_file_namespace_refuse(self):
  row=self.row('titles',b'File:Example.ogg\n')
  for change in ({'kind':'unknown'},{'kind':'log'},{'path':'../figure-file-query-0000.titles'}):
   with self.subTest(change=change),self.assertRaises(ValueError):self.names([{**row,**change}])
  other=self.row('titles',b'Category:Example\n',1)
  with self.assertRaises(ValueError):self.names([other])
 def test_seed_mutation_and_duplicate_evidence_refuse(self):
  row=self.row('titles',b'File:Example.ogg\n')
  with self.assertRaises(ValueError):self.names([row,row])
  (self.root/row['path']).write_bytes(b'File:Other.ogg\n')
  with self.assertRaises(ValueError):self.names([row])


class D191ProfileTests(unittest.TestCase):
    def test_exact_registration_retains_reviewed_v4_model(self):
        registration = dict(figure.FIGURE_MEDIA_VARIANTS[D191_F03])
        actual = figure.figure_profile(D191_CORE, figure.FIGURE_PROFILE_V4, registration)
        expected = dict(figure.FIGURE_WMF4_PROFILE, media_extensions=registration)
        self.assertEqual(actual, expected)
        # Retain the reviewed geometry model anchors, distinct from raw epoch bodies.
        self.assertEqual(actual['svg_handler_sha256'], 'f3e8b5c497c8ed3871e89edb23ca19c8279caf93a6697f2b9431a562204637a9')
        self.assertEqual(actual['bitmap_handler_sha256'], 'd479a959113ddeb55d07ba5607d4a06c52010cba60b616544fcc0800aaab2ce4')
        registration.clear()
        self.assertTrue(actual['media_extensions'])

    def test_legacy_and_foreign_registration_refused(self):
        registration = dict(figure.FIGURE_MEDIA_VARIANTS[D191_F03])
        for kind in (figure.FIGURE_PROFILE_V3, figure.FIGURE_PROFILE_V5):
            with self.subTest(kind=kind), self.assertRaises(ValueError):
                figure.figure_profile(D191_CORE, kind, registration)
        for changed in ({}, dict(registration, Unknown='0' * 40),
                        dict(registration, TimedMediaHandler='0' * 40)):
            with self.subTest(changed=changed), self.assertRaises(ValueError):
                figure.figure_profile(D191_CORE, figure.FIGURE_PROFILE_V4, changed)


class CurrentSvgIdentityTests(unittest.TestCase):
    def setUp(self):
        root = Path(__file__).parent / 'testdata/vi-imageinfo-87f'
        self.namespace = (root/'namespace-registry.tsv').read_bytes()
        self.raw = figure.zstd.decompress((root/'raw.jsonl.zst').read_bytes())
        self.expected = figure.zstd.decompress((root/'projection.jsonl.zst').read_bytes())
        self.selected = figure.zstd.decompress((root/'selected-defaults.json.zst').read_bytes())
        self.observed = gzip.decompress((root/'defaultoptions.raw.json.gz').read_bytes())
        header, *frames = self.raw.splitlines(True)
        self.batches = [figure.raw_record_decode(line, figure.raw_record_encoding(figure.decode(header))) for line in frames]
        self.site = self.batches[0]['response'].encode()

    def replay(self, batches, **options):
        settings = dict(has_batches=True, record_limit=44, profile_kind=figure.FIGURE_PROFILE_V4,
                        allow_compatible_epochs=True, current_file_supplements=True)
        return figure.file_records(batches, self.namespace, 'viwiktionary', '20261001', self.site, **(settings|options))

    def test_vietnamese_svg_axes_absence_and_width_match_ordinary_stream(self):
        figure.verify_file_defaults(self.selected,self.observed)
        doc = self.replay(self.batches)
        header, *records = map(figure.decode,self.expected.splitlines())
        self.assertEqual(header['source_profile'],doc['source_profile'])
        self.assertEqual(doc['records'],records)
        self.assertEqual((doc['base_batches'],doc['observed_batches'],len(records)),(2,1,44))
        by_name = {row['requested_file']:row for row in records}
        self.assertEqual(by_name['Tập tin:Vi-hanoi-m-uy ky pê đi a.ogg']['state'],'missing')
        self.assertEqual(by_name['Tập tin:Wikipedia-logo-v2.svg']['observed_svg_width_px'],250)
        for options in (dict(current_file_supplements=False),dict(profile_kind=figure.FIGURE_PROFILE_V5)):
            with self.assertRaises(ValueError): self.replay(self.batches, **options)
        for old,new in ((self.selected+b' ',self.observed),(self.selected,self.observed+b' ')):
            with self.assertRaises(ValueError): figure.verify_file_defaults(old,new)

    def test_vietnamese_ordinary_identity_requires_literal_absence_or_positive_svg(self):
        for property_name,value in [('missing',1),('missing','yes'),('missing',False),('missing',None),
                ('mime','image/tiff'),('height',0),('mediatype','BITMAP'),('canonicaltitle','Tập tin:Other.svg'),
                ('wikiid','frwiktionary'),('rtl',True),('git-hash','0'*40)]:
            batches=copy.deepcopy(self.batches)
            data=json.loads(batches[1]['response'])
            pages=data['query']['pages']
            if property_name=='missing':
                target=next(p for p in pages if p['imagerepository']=='')
            elif property_name in ('wikiid','rtl','git-hash'):
                target=data['query']['general']
            else:
                target=next(p for p in pages if p.get('imageinfo'))['imageinfo'][0]
            target[property_name]=value
            batches[1]['response']=figure.encoded(data).decode()
            with self.subTest(property_name=property_name,value=value),self.assertRaises(ValueError):
                self.replay(batches)


class EnglishMaterializedWidthTests(unittest.TestCase):
    def test_historical_webp_profile_and_current_pngs_survive_moved_parents(self):
        import test_prepare_figure_files as files_tests
        fixtures = Path(__file__).parent/'testdata'
        shared = fixtures/'current-file-observations'
        docs = figure.decode(figure.zstd.decompress((shared/'en-v5-materialized-proofs.json.zst').read_bytes()))
        cases = figure.decode(figure.zstd.decompress((shared/'historical-file-facts.json.zst').read_bytes()))
        namespace = next(case['namespace'] for case in cases if case['wiki']=='enwiktionary').encode()
        width = figure.raw_record_decode((shared/'observations.jsonl').read_bytes().splitlines(True)[-1], figure.RAW_RECORD_ENCODING)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            defaults = root/'defaults'
            defaults.mkdir()
            prefix = site.PREFIX+'source-'
            for name, source in site.primary_sources(fixtures/'kw-figure-defaults-bfe249', prefix).items():
                (defaults/(prefix+name)).write_bytes(source)
            (defaults/(site.PREFIX+'namespace-registry.tsv')).write_bytes(namespace)
            for name, source in docs['defaults'].items():
                (defaults/name).write_bytes(source.encode())
            refs, names = [], []
            for index, members in enumerate([*docs['bases'], docs['current']]):
                folder = root/str(index)
                folder.mkdir()
                (folder/figure.metadata.NAMESPACE).write_bytes(namespace)
                for name, data in members.items():
                    (folder/name).write_bytes(data.encode())
                ref = folder/'retained-observation.json'
                record = figure.decode(ref.read_bytes())
                if 'observed_svg_width_px' in record:
                    receipt = figure.decode((folder/record['batch']['accepted_receipt']).read_bytes())
                    (folder/receipt['response']).write_bytes(width['response'].encode())
                else:
                    names.extend(figure.decode((folder/record['batch']['request']).read_bytes())['titles'])
                refs.append(ref)
            self.assertEqual((len(names), len(set(names)), len(refs)), (850, 850, 18))
            sql_escape = str.maketrans({'\\': '\\\\', "'": "\\'"})
            escaped = [name.split(':', 1)[1].replace(' ', '_').translate(sql_escape) for name in names]
            args = argparse.Namespace(root=root, wiki='enwiktionary', date='20261001', defaults=defaults,
                output=root/'base', reuse=[], reuse_batch=refs[:-1], figure_profile=figure.FIGURE_PROFILE_V4,
                batch_size=50, delay=1, wall_seconds=300, max_inflight=1, metadata_mode='full')
            args.sql, args.dumpstatus = files_tests.FigureFileTests.inventory(args, links=escaped)
            def offline(*_):
                self.fail('All authentic request and response bytes are available offline')
            figure.capture_files(args, transport=offline)
            # Match the retained English parent storage: one gzip member per raw
            # record, with sequential compression for its other five large roles.
            for name in (figure.ROLES['figure-sizing-raw'], figure.ROLES['figure-sizing'], figure.MANIFEST,
                         figure.PROVIDER, figure.FILE_REQUESTS, figure.INVENTORY):
                path = args.output/name
                stored = path.with_name(name+'.gz')
                with path.open('rb') as source, stored.open('xb') as output:
                    if name == figure.ROLES['figure-sizing-raw']:
                        for line in source:
                            output.write(gzip.compress(line, compresslevel=1, mtime=0))
                    else:
                        output.write(gzip.compress(source.read(), compresslevel=1, mtime=0))
                path.unlink()
            args.reuse = [args.output]
            args.output = root/'appended'
            args.gzip_output = True
            args.figure_profile = figure.FIGURE_PROFILE_V5
            args.reuse_batch = [refs[-1]]
            figure.capture_files(args, transport=offline)
            materialized = root/'materialized'
            figure.materialize_complete_capture(args.output/figure.MANIFEST, materialized)
            (root/'base').rename(root/'retired-base')
            (root/'appended').rename(root/'retired-appended')
            self.assertEqual(figure.verify(materialized)['coverage']['files'], 850)
            for name in (figure.ROLES['figure-sizing-raw'], figure.ROLES['figure-sizing'], figure.PROVIDER):
                self.assertFalse((materialized/name).exists())
                self.assertTrue((materialized/(name+'.gz')).is_file())
            _, verified = figure._figure_capture_manifest(materialized)
            raw_name = figure.ROLES['figure-sizing-raw']
            descriptors = {}
            for role, name in {**figure.ROLES, 'file-metadata':figure.PROVIDER}.items():
                source = materialized/name
                compressed = not source.exists()
                if compressed:
                    source = source.with_name(name+'.gz')
                descriptors[role] = dict(verified['artifacts'][name], path=str(source.relative_to(root)))
                if compressed:
                    descriptors[role]['codec'] = 'gzip'
            materialized.rename(root/'relocated')
            descriptors = {k: dict(v, path=v['path'].replace('materialized/', 'relocated/', 1))
                           for k,v in descriptors.items()}
            materialized = root/'relocated'
            member = materialized / (raw_name + '.gz')
            storage = {}
            paths, capture = builder.materialize_snapshot_selection(root, root/'view', descriptors, None,
                                                                       figure_raw_storage=storage)
            self.assertIsNone(capture)
            selected = paths['figure-sizing-raw']
            self.assertTrue(selected.samefile(member))
            self.assertEqual(storage['stamp'], builder._figure_replay_identity(selected))
            with figure.bind_inventory_downloads(root):
                resolved = builder.verified_figure_tuple(figure, paths, 'enwiktionary', '20261001')
            self.assertEqual(resolved['figure-sizing-raw'][0]['coverage']['files'], 850)
            self.assertEqual(resolved['figure-sizing-raw'][0]['_raw_storage'],
                             {'size':member.stat().st_size, 'sha256':figure.digest(member.read_bytes())})
            self.assertEqual(resolved['figure-sizing-raw'][0]['output_sha256'],
                             verified['artifacts'][raw_name]['sha256'])
            packed_names = ('figure-sizing', 'file-metadata')
            packed = resolved['figure-sizing-raw'][0]['_packed_storage']
            hashes = {}
            for role, (declaration, _) in resolved.items():
                hashes[role] = declaration['output_sha256']
            for role in packed_names:
                self.assertTrue(paths[role].samefile(materialized/(paths[role].name+'.gz')))
                self.assertEqual(packed[paths[role].name], {
                    'size': paths[role].stat().st_size, 'sha256': figure.digest(paths[role].read_bytes())})
                self.assertEqual(hashes[role], verified['artifacts'][paths[role].name]['sha256'])
            (root/'pin').mkdir()
            with figure.bind_inventory_downloads(root):
                pinned = builder.pinned_auxiliary_snapshots(paths, hashes, root/'pin')
            for role in ('figure-sizing-raw', *packed_names):
                self.assertEqual(pinned[role].read_bytes(), paths[role].read_bytes())
            for role in packed_names:
                path = paths[role]
                original_member = path.read_bytes()
                damaged = bytearray(original_member)
                damaged[-8] ^= 1
                path.write_bytes(damaged)
                builder._FIGURE_TUPLE_REPLAYS.clear()
                with figure.bind_inventory_downloads(root):
                    with self.assertRaises((ValueError, OSError)):
                        builder.verified_figure_tuple(figure, paths, 'enwiktionary', '20261001')
                path.write_bytes(original_member)
            forged = dict(descriptors, **{'file-metadata': dict(descriptors['file-metadata'], sha256='0'*64)})
            with self.assertRaisesRegex(ValueError, 'Conflicting snapshot providers'):
                builder.materialize_snapshot_selection(root, root/'forged', forged, None, figure_raw_storage={})
            original = member.read_bytes()
            with figure.bind_inventory_downloads(root):
                builder.verified_figure_tuple(figure, paths, 'enwiktionary', '20261001')
            corrupted = bytearray(original)
            corrupted[-8] ^= 1
            member.write_bytes(corrupted)
            with self.assertRaises((ValueError, OSError)):
                with figure.bind_inventory_downloads(root):
                    builder.verified_figure_tuple(figure, paths, 'enwiktionary', '20261001')
            builder._FIGURE_TUPLE_REPLAYS.clear()
            with self.assertRaises((EOFError, ValueError, OSError)):
                with figure.bind_inventory_downloads(root):
                    builder.verified_figure_tuple(figure, paths, 'enwiktionary', '20261001')
            member.write_bytes(gzip.decompress(original))
            with self.assertRaisesRegex(ValueError, 'not gzip'):
                builder.materialize_snapshot_selection(root, root/'plain', descriptors, None, figure_raw_storage={})
            member.write_bytes(original)
            plan = figure.inventory_document(materialized/figure.PLAN)
            self.assertEqual((plan['figure_profile'], plan['replay_contract'], plan['base_batches'], plan['observed_batches']),
                             (figure.FIGURE_PROFILE_V5, figure.REPLAY_CONTRACT, 17, 1))
            with self.assertRaises(ValueError):
                figure.figure_profile(site.FIGURE_WMF5_CORE, figure.FIGURE_PROFILE_V5, wiki='enwiktionary')
            current_path = refs[-1]
            current_path.write_bytes(current_path.read_bytes()+b' ')
            with self.assertRaises(ValueError):
                figure.verify(materialized)


class CurrentOrdinaryWidthTests(unittest.TestCase):
    def test_current_thai_and_italian_pngs_match_their_distinct_ordinary_files(self):
        path = Path(__file__).parent/'testdata/current-file-observations/th-it-ordinary-source.json.zst'
        cases = figure.decode(figure.zstd.decompress(path.read_bytes()))
        self.assertEqual([case['wiki'] for case in cases], ['thwiktionary', 'itwiktionary'])
        for case, expected in zip(cases, ((59, [50, 100, 200, 250, 400]), (52, [600])), strict=True):
            batches = case['batches']
            wiki = case['wiki']
            site_raw = batches[0]['response'].encode()
            def replay(source, **overrides):
                options = dict(has_batches=True, record_limit=64, profile_kind=figure.FIGURE_PROFILE_V4,
                               allow_compatible_epochs=True, current_file_supplements=True)
                return figure.file_records(source, case['namespace'].encode(), wiki, '20261001', site_raw,
                                           **(options | overrides))
            with self.subTest(wiki=wiki):
                figure.verify_file_defaults(case['selected_defaults'].encode(), case['observed_defaults'].encode())
                doc = replay(batches)
                self.assertEqual(doc['records'], case['records'])
                self.assertEqual(doc['source_profile'], case['source_profile'])
                widths = sorted({r['observed_svg_width_px'] for r in doc['records'] if 'observed_svg_width_px' in r})
                self.assertEqual((len(doc['records']), widths), expected)
                with self.assertRaises(ValueError):
                    replay([batches[0], *batches[2:]])
                with self.assertRaises(ValueError):
                    replay(batches, current_file_supplements=False)
                with self.assertRaises(ValueError):
                    replay(batches, profile_kind=figure.FIGURE_PROFILE_V5)
                for extra in ({'jpeg_metadata_only':True}, {'observed_svg_occurrences':[]}):
                    with self.assertRaises(ValueError):
                        replay(batches[:2]+[dict(batches[1], **extra)])
                changed = copy.deepcopy(batches[2])
                response = figure.decode(changed['response'].encode())
                response['query']['pages'][0]['imageinfo'][0]['thumbmime'] = 'image/webp'
                changed['response'] = figure.encoded(response).decode()
                with self.assertRaises(ValueError):
                    replay(batches[:2]+[changed])


class CurrentOrdinaryImageInfoTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        source = Path(__file__).parent/'testdata/current-file-observations/ordinary-source.json.zst'
        cls.cases = figure.decode(figure.zstd.decompress(source.read_bytes()))

    def replay(self, case, batches, **overrides):
        batch = case['imageinfo']
        options = dict(has_batches=True, record_limit=50, profile_kind=figure.FIGURE_PROFILE_V4,
                       allow_compatible_epochs=True, current_file_supplements=True)
        return figure.file_records(batches, case['namespace'].encode(), case['wiki'], '20261001',
                                   batch['response'].encode(), **(options | overrides))

    def test_authentic_ordinary_facts_require_their_own_defaults(self):
        self.assertEqual([c['wiki'] for c in self.cases], ['dewiktionary', 'ruwiktionary'])
        for case, other in zip(self.cases, reversed(self.cases), strict=True):
            defaults = case['selected_defaults'].encode()
            observed = case['observed_defaults'].encode()
            wiki = case['wiki']
            with self.subTest(wiki=wiki):
                figure.verify_file_defaults(defaults, observed)
                self.assertTrue(figure.bound_file_core(site.FIGURE_WMF5_CORE, figure.FIGURE_CURRENT_CORE, observed, wiki=wiki))
                doc = self.replay(case, [case['imageinfo']])
                self.assertEqual(doc['source_profile'], case['source_profile'])
                self.assertEqual(doc['records'], case['records'])
                self.assertEqual(doc['source_profile']['selected_defaults_sha256'], figure.digest(defaults))
                self.assertEqual(doc['source_profile']['observed_defaults_response_sha256'], figure.digest(observed))
                self.assertFalse(figure.bound_file_core(site.FIGURE_WMF5_CORE, figure.FIGURE_CURRENT_CORE, observed, wiki=other['wiki']))
                self.assertFalse(figure.bound_file_core(site.FIGURE_WMF5_CORE, figure.FIGURE_CURRENT_CORE, None, wiki=wiki))
                with self.assertRaises(ValueError):
                    figure.verify_file_defaults(defaults, other['observed_defaults'].encode())
                with self.assertRaises(ValueError):
                    figure.verify_file_defaults(other['selected_defaults'].encode(), observed)
                for key, value in [('thumbsize', 0), ('skin', 'monobook')]:
                    changed = figure.decode(observed)
                    changed['query']['defaultoptions'][key] = value
                    with self.assertRaises(ValueError):
                        figure.verify_file_defaults(defaults, figure.encoded(changed))

    def test_verified_ordinary_capture_and_materialization_survive_moved_parent(self):
        self.check_ordinary_materialization({})

    def test_rollout_ordinary_capture_and_materialization_survive_moved_parent(self):
        path = Path(__file__).parent/'testdata/current-file-observations/ordinary-rollout-57f.json.zst'
        rows = figure.decode(figure.zstd.decompress(path.read_bytes()))
        self.check_ordinary_materialization({row['wiki']:row['rollout_batch'] for row in rows})

    def test_rollout_depends_on_the_wmf5_document_and_ordinary_imageinfo(self):
        fixtures = Path(__file__).parent/'testdata/current-file-observations'
        def cases(name):
            return figure.decode(figure.zstd.decompress((fixtures/name).read_bytes()))
        anchors = {case['wiki']:(case['imageinfo'], case['namespace']) for case in self.cases}
        thai = cases('th-it-ordinary-source.json.zst')[0]
        anchors[thai['wiki']] = thai['batches'][0], thai['namespace']
        for observed in cases('ordinary-rollout-57f.json.zst'):
            wiki = observed['wiki']
            first, namespace = anchors[wiki]
            batch = observed['rollout_batch']
            def replay(batches, *, registration=first['response'], date='20261001', **options):
                defaults = dict(has_batches=True, record_limit=100, profile_kind=figure.FIGURE_PROFILE_V4,
                                allow_compatible_epochs=True, current_file_supplements=True)
                return figure.file_records(batches, namespace.encode(), wiki, date,
                                           registration.encode(), **(defaults | options))
            with self.subTest(wiki=wiki):
                value = replay([first, batch])
                self.assertEqual(value['core_revision'], site.FIGURE_WMF5_CORE)
                self.assertEqual([r for r in value['records'] if r['batch'] == 1], observed['records'])
                with self.assertRaises(ValueError): replay([batch], registration=batch['response'])
                with self.assertRaises(ValueError): replay([first, batch], current_file_supplements=False)
                with self.assertRaises(ValueError): replay([first, batch], profile_kind=figure.FIGURE_PROFILE_V5)
                with self.assertRaises(ValueError): replay([first, batch], date='20261002')
                for role in ({'observed_svg_width_px':250}, {'jpeg_metadata_only':True}, {'observed_svg_occurrences':[]}):
                    with self.assertRaises(ValueError): replay([first, dict(batch, **role)])
                for changed in ('core', 'generator', 'registry', 'wiki', 'rtl', 'case', 'widths'):
                    raw = figure.decode(batch['response'].encode())
                    general = raw['query']['general']
                    if changed == 'registry':
                        next(e for e in raw['query']['extensions'] if e['name']=='PagedTiffHandler')['vcs-version'] = 'a'*40
                    else:
                        key, replacement = {'core':('git-hash','a'*40), 'generator':('generator','MediaWiki 1.48.0-wmf.6'),
                          'wiki':('wikiid','itwiktionary'), 'rtl':('rtl',True), 'case':('case','first-letter'),
                          'widths':('thumblimits',{'0':180,'1':220,'2':400})}[changed]
                        general[key] = replacement
                    with self.subTest(change=changed), self.assertRaises(ValueError):
                        replay([first, dict(batch, response=figure.encoded(raw).decode())])

    def test_rollout_lean_tiff_requires_the_same_response_core_and_file(self):
        fixtures = Path(__file__).parent / 'testdata/current-file-observations'
        source = figure.decode(figure.zstd.decompress((fixtures/'ordinary-rollout-57f.json.zst').read_bytes()))[0]
        first = self.cases[0]
        self.assertEqual((source['wiki'], first['wiki']), ('dewiktionary', 'dewiktionary'))
        response = figure.decode(source['rollout_batch']['response'].encode())
        title = 'Datei:Regression.tif'
        # Synthetic TIFF payload over the retained registration. The actual
        # rollover batch contains audio and supplies no TIFF observation.
        response['query']['pages'] = [{'ns': 6, 'title': title, 'missing': True, 'known': True,
            'imagerepository': 'shared', 'imageinfo': [{'canonicaltitle': title, 'timestamp': '2021-03-20T23:39:21Z',
            'sha1': '1'*40, 'size': 4096, 'width': 800, 'height': 600, 'mime': 'image/tiff',
            'mediatype': 'BITMAP', 'pagecount': 1}]}]
        companion = copy.deepcopy(response)
        companion['query']['pages'][0]['imageinfo'][0]['metadata'] = [
            {'name': 'TIFF_METADATA_VERSION', 'value': '1.4'},
            *({'name': name, 'value': 1} for name in ('page_count', 'first_page', 'last_page')),
            {'name': 'page_data', 'value': [{'name': 1, 'value': [
                {'name': 'page', 'value': 1}, {'name': 'width', 'value': 800}, {'name': 'height', 'value': 600}]}]}]
        def replay(other):
            batch = {'requests': [title], 'response': figure.encoded(response).decode(),
                     'tiff_metadata_response': figure.encoded(other).decode()}
            return self.replay(first, [first['imageinfo'], batch])
        records = replay(companion)['records']
        self.assertEqual(next(row['state'] for row in records if row['requested_file'] == title), 'eligible')
        for field in ('core', 'registry', 'file'):
            changed = copy.deepcopy(companion)
            if field == 'core':
                changed['query']['general']['git-hash'] = site.FIGURE_WMF5_CORE
            elif field == 'registry':
                next(e for e in changed['query']['extensions'] if e['name'] == 'PagedTiffHandler')['vcs-version'] = '1'*40
            else:
                changed['query']['pages'][0]['imageinfo'][0]['sha1'] = '2'*40
            with self.subTest(field=field), self.assertRaises(ValueError):
                replay(changed)

    def check_ordinary_materialization(self, rollout_batches):
        import test_prepare_figure_files as files_tests
        fixtures = Path(__file__).parent/'testdata'
        proofs = figure.decode(figure.zstd.decompress((fixtures/'current-file-observations/ordinary-proofs.json.zst').read_bytes()))
        prefix = site.PREFIX+'source-'
        sources = site.primary_sources(fixtures/'kw-figure-defaults-bfe249', prefix)
        for case in self.cases:
            wiki = case['wiki']
            with self.subTest(wiki=wiki), tempfile.TemporaryDirectory() as directory:
                root = Path(directory).resolve()
                selected, observed, image = (root/name for name in ('selected', 'observed', 'image'))
                for package in (selected, observed, image):
                    package.mkdir()
                    for name, data in proofs[wiki][package.name].items():
                        (package/name).write_bytes(data.encode())
                for package in (selected, observed):
                    (package/(site.PREFIX+'namespace-registry.tsv')).write_bytes(case['namespace'].encode())
                    for name, data in sources.items():
                        (package/(prefix+name)).write_bytes(data)
                (selected/site.SNAPSHOT).write_bytes(case['selected_defaults'].encode())
                (observed/'site-info.01.raw.json').write_bytes(case['observed_defaults'].encode())
                (image/figure.metadata.NAMESPACE).write_bytes(case['namespace'].encode())
                (image/'file-metadata.response-000001-01.raw.json').write_bytes(case['imageinfo']['response'].encode())
                failure = figure.digest((observed/'site-info.failure.json').read_bytes())
                site.revalidate(observed, failure)
                with self.assertRaises(ValueError):
                    site.validate_snapshot(observed/site.SNAPSHOT, wiki, '20261101', file_defaults=True)
                seed = argparse.Namespace(root=root, wiki=wiki, date='20261001')
                rollout = rollout_batches.get(wiki)
                requested = case['imageinfo']['requests'] + (rollout['requests'] if rollout else [])
                names = [name.split(':', 1)[1].replace(' ', '_') for name in requested]
                paths, status = files_tests.FigureFileTests.inventory(seed, links=names)
                source, appended, materialized = (root/name for name in ('source', 'appended', 'materialized'))
                args = argparse.Namespace(wiki=wiki, date='20261001', defaults=selected, file_defaults=observed,
                    sql=paths, dumpstatus=status, batch_size=50, delay=1, wall_seconds=30, max_inflight=1,
                    metadata_mode='lean-tiff-v1' if rollout or wiki=='ruwiktionary' else 'full', figure_profile=figure.FIGURE_PROFILE_V4,
                    output=source, reuse=[], reuse_batch=[image/'retained-observation.json'])
                def offline(*_):
                    self.fail('The verified source requires no further request')
                calls = []
                def captured(url, timeout):
                    self.assertFalse(calls)
                    self.assertEqual(url, figure.metadata.query_url(wiki, rollout['requests'], figure_axes=True,
                        figure_metadata_light=args.metadata_mode == 'lean-tiff-v1'))
                    calls.append(url)
                    return 200, {}, rollout['response'].encode()
                self.assertEqual(figure.capture_files(args, transport=captured if rollout else offline)['coverage']['files'], len(requested))
                self.assertEqual(len(calls), int(rollout is not None))
                args.output, args.reuse, args.reuse_batch = appended, [source], []
                figure.capture_files(args, transport=offline)
                figure.materialize_complete_capture(appended/figure.MANIFEST, materialized)
                source.rename(root/'retired-source')
                appended.rename(root/'retired-appended')
                self.assertEqual(figure.verify(materialized)['coverage']['files'], len(requested))
                descriptor = figure.decode((image/'retained-observation.json').read_bytes())
                receipt = image/descriptor['batch']['accepted_receipt']
                original = receipt.read_bytes()
                receipt.write_bytes(original + b' ')
                with self.assertRaises(ValueError):
                    figure.verify(materialized)
                receipt.write_bytes(original)
                witness = materialized/figure.FILE_DEFAULTS
                self.assertEqual(witness.read_bytes(), case['observed_defaults'].encode())
                witness.unlink()
                with self.assertRaises((OSError, ValueError)):
                    figure.verify(materialized)

    def test_ordinary_does_not_grant_supplements_or_other_profiles(self):
        for case in self.cases:
            batch = case['imageinfo']
            for role in ({'observed_svg_width_px':250}, {'jpeg_metadata_only':True}, {'observed_svg_occurrences':[]}):
                with self.subTest(wiki=case['wiki'], role=role), self.assertRaises(ValueError):
                    self.replay(case, [batch, dict(batch, **role)])
            with self.subTest(wiki=case['wiki']), self.assertRaises(ValueError):
                self.replay(case, [batch], profile_kind=figure.FIGURE_PROFILE_V5)
            for change in ('registration', 'case', 'rtl', 'core'):
                changed = copy.deepcopy(case)
                data = figure.decode(batch['response'].encode())
                if change == 'registration':
                    next(e for e in data['query']['extensions'] if e['type'] == 'media')['vcs-version'] = '0'*40
                elif change == 'core':
                    data['query']['general']['git-hash'] = '0'*40
                else:
                    data['query']['general'][change] = True if change == 'rtl' else 'first-letter'
                changed['imageinfo']['response'] = figure.encoded(data).decode()
                with self.subTest(wiki=case['wiki'], change=change), self.assertRaises(ValueError):
                    self.replay(changed, [changed['imageinfo']])


class CurrentFileObservationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        source = Path(__file__).parent/'testdata/current-file-observations'
        cases = figure.decode(figure.zstd.decompress((source/'historical-file-facts.json.zst').read_bytes()))
        remaining = iter((source/'observations.jsonl').read_bytes().splitlines(True))
        cls.cases = [(case, [figure.raw_record_decode(next(remaining), figure.RAW_RECORD_ENCODING)
                            for _ in range(case['fresh_count'])]) for case in cases]
        assert next(remaining, None) is None

    def replay(self, case, current, **overrides):
        base = case['base']
        options = dict(has_batches=True, record_limit=2000, profile_kind=case['source_profile']['kind'],
                       allow_compatible_epochs=True, current_file_supplements=True)
        return figure.file_records([*base, *current], case['namespace'].encode(), case['wiki'], '20261001',
                                   base[0]['response'].encode(), **(options | overrides))

    def test_current_ogg_states_and_explicit_svg_widths(self):
        counts = {}
        for case, batches in self.cases:
            wiki = case['wiki']
            with self.subTest(wiki=wiki):
                doc = self.replay(case, batches)
                self.assertEqual(doc['records'], case['records'])
                self.assertEqual(doc['core_revision'], figure.FIGURE_CURRENT_CORE)
                rows = {row['requested_file']:row for row in doc['records']}
                expected = []
                for batch in batches:
                    for name in batch['requests']:
                        row = rows[name]
                        if 'observed_svg_width_px' in batch:
                            self.assertEqual(row['observed_svg_width_px'], batch['observed_svg_width_px'])
                            expected.append('width')
                        elif wiki == 'huwiktionary':
                            self.assertEqual((row['state'], row['file_sha1']), ('missing', ''))
                            expected.append('missing')
                        else:
                            self.assertEqual((row['state'], row['mime'], row['mediatype']),
                                             ('unsupported', 'application/ogg', 'AUDIO'))
                            expected.append('audio')
                counts[wiki] = (expected.count('width'), expected.count('missing'), expected.count('audio'))
        self.assertEqual(counts, {'huwiktionary': (0, 1, 0), 'elwiktionary': (18, 0, 3),
                                 'thwiktionary': (8, 0, 0), 'itwiktionary': (2, 0, 0), 'enwiktionary': (18, 0, 0)})

    def test_audio_states_refuse_redirects_and_namespace_aliases(self):
        for case, batches in self.cases[:2]:
            batch = batches[0]
            for change in ('redirect', 'normalized'):
                data = figure.decode(batch['response'].encode())
                if change == 'redirect':
                    data['query']['pages'][0]['redirect'] = True
                else:
                    title = batch['requests'][0]
                    data['query']['normalized'] = [{'from':title, 'to':title}]
                with self.subTest(wiki=case['wiki'], change=change), self.assertRaises(ValueError):
                    self.replay(case, [dict(batch, response=figure.encoded(data).decode())])
            if case['wiki'] == 'elwiktionary':
                data = figure.decode(batch['response'].encode())
                file = data['query']['pages'][0]['imageinfo'][0]
                file['canonicaltitle'] = 'File:' + file['canonicaltitle'].split(':', 1)[1]
                with self.assertRaises(ValueError):
                    self.replay(case, [dict(batch, response=figure.encoded(data).decode())])

    def test_edition_profile_registration_and_file_role_are_required(self):
        for case, batches in self.cases:
            wiki = case['wiki']
            wrong_profile = figure.FIGURE_PROFILE_V4 if wiki == 'enwiktionary' else figure.FIGURE_PROFILE_V5
            for change in ('source', 'registration', 'role', 'typed-file-fact', 'response-context'):
                changed = copy.deepcopy(batches[0])
                data = figure.decode(changed['response'].encode())
                page = data['query']['pages'][0]
                if change == 'source':
                    data['query']['general']['git-hash'] = '0'*40
                elif change == 'registration':
                    next(e for e in data['query']['extensions'] if e['type'] == 'media')['vcs-version'] = '0'*40
                elif change == 'role':
                    changed.pop('observed_svg_width_px', None)
                    changed['jpeg_metadata_only'] = True
                elif change == 'response-context':
                    data['query']['general']['rtl'] = True
                elif wiki == 'huwiktionary':
                    page['known'] = True
                elif wiki == 'elwiktionary':
                    page['imageinfo'][0]['mime'] = 'video/ogg'
                else:
                    page['imageinfo'][0]['thumbmime'] = 'image/webp'
                changed['response'] = figure.encoded(data).decode()
                with self.subTest(wiki=wiki, change=change), self.assertRaises(ValueError):
                    self.replay(case, [changed])
            for opts in ({'current_file_supplements':False}, {'profile_kind':wrong_profile}):
                with self.subTest(wiki=wiki, options=opts), self.assertRaises(ValueError):
                    self.replay(case, batches, **opts)


class FrenchCurrentSupplementTests(unittest.TestCase):
    def setUp(self):
        fixtures = Path(__file__).parent/'testdata'
        self.sources = fixtures/'fr-imageinfo-87f'
        self.namespace = (fixtures/'figure-page-observations/fr-cauannos-alias/namespace-registry.tsv').read_bytes()
        wire = (self.sources/'selected-batches.jsonl').read_bytes()
        self.batches = [figure.raw_record_decode(row, figure.RAW_RECORD_ENCODING) for row in wire.splitlines(True)]
        self.site = self.batches[0]['response'].encode()
        self.wiki = 'frwiktionary'
        self.date = '20261001'

    def replay(self, base, supplements, **overrides):
        options = dict(has_batches=True, record_limit=250, profile_kind=figure.FIGURE_PROFILE_V4,
                       allow_compatible_epochs=True, current_file_supplements=True)
        return figure.file_records([*base, *supplements], self.namespace, self.wiki, self.date,
                                   self.site, **(options | overrides))

    def test_two_scoped_roles_and_original_jpeg_alias(self):
        doc = self.replay(self.batches[:5], self.batches[5:])
        records = {row['requested_file']:row for row in doc['records']}
        self.assertEqual((len(records), doc['core_revision'], doc['observed_batches']), (250, figure.FIGURE_CURRENT_CORE, 2))
        self.assertEqual(records['Fichier:75 percent.svg']['observed_svg_width_px'], 120)
        self.assertEqual(records['Fichier:table a couture nommee orphee.jpg']['canonical_file'], 'Fichier:Table a couture nommee orphee.jpg')
        self.assertEqual(sum('observed_svg_width_px' in row for row in records.values()), 1)
        with self.assertRaisesRegex(ValueError, 'mix site/source versions'):
            self.replay(self.batches[:5], self.batches[5:], current_file_supplements=False)
        with self.assertRaises(ValueError):
            self.replay(self.batches[:5], self.batches[5:], profile_kind=figure.FIGURE_PROFILE_V5)

    def test_retargeted_alias_and_unregistered_source(self):
        width = copy.deepcopy(self.batches[5])
        data = figure.decode(width['response'].encode())
        old_title = 'Fichier:table a couture nommee orphee.jpg'
        width['requests'] = [old_title]
        data['query']['redirects'] = [{'from':old_title, 'to':data['query']['pages'][0]['title']}]
        width['response'] = figure.encoded(data).decode()
        with self.assertRaisesRegex(ValueError, 'retargets its original file request'):
            self.replay(self.batches[:5], [width])
        for change in ('registration', 'source', 'pinned-context', 'png'):
            width = copy.deepcopy(self.batches[5]); data = figure.decode(width['response'].encode())
            if change == 'registration':
                next(e for e in data['query']['extensions'] if e['name'] == 'PagedTiffHandler')['vcs-version'] = '0'*40
            elif change == 'source':
                data['query']['general']['git-hash'] = '0'*40
            elif change == 'pinned-context':
                data['query']['general']['rtl'] = True
            else:
                del data['query']['pages'][0]['imageinfo'][0]['thumbmime']
            width['response'] = figure.encoded(data).decode()
            with self.subTest(change=change), self.assertRaises(ValueError):
                self.replay(self.batches[:5], [width])

    def test_width_aliases_duplicates_and_original_error_order(self):
        width = self.batches[5]
        canonical = width['requests'][0]
        alias = 'Fichier:Test alias.svg'
        original = next(b for b in self.batches[:5] if canonical in b['requests'])

        def redirect(batch, title):
            source = figure.decode(batch['response'].encode())
            query = source['query']
            query['pages'] = [page for page in query['pages'] if page['title'] == canonical]
            query['redirects'] = [{'from': title, 'to': canonical}]
            return dict(batch, requests=[title], response=figure.encoded(source).decode())

        base = [*self.batches[:5], redirect(original, alias)]
        alias_width = redirect(width, alias)
        result = self.replay(base, [alias_width], record_limit=251)
        matches = {row['requested_file']: (row['observed_svg_width_px'], row['observed_batch'])
                   for row in result['records'] if 'observed_svg_width_px' in row}
        self.assertEqual(matches, {canonical: (120, 6), alias: (120, 6)})
        with self.assertRaisesRegex(ValueError, 'duplicate observed SVG width'):
            self.replay(base, [alias_width, width], record_limit=251)
        with self.assertRaisesRegex(ValueError, 'supplements must follow ordinary'):
            self.replay(base, [alias_width, original], record_limit=251)
        crossed = redirect(width, 'Fichier:table a couture nommee orphee.jpg')
        with self.assertRaisesRegex(ValueError, 'retargets its original file request'):
            self.replay(base, [crossed, original], record_limit=251)

    def test_jpeg_requires_omission_positive_metadata_and_matching_file(self):
        base = copy.deepcopy(self.batches[:5])
        target = 'Fichier:Mouchoir.JPG'
        previous = next(b for b in base if target in b['requests'])
        source = figure.decode(previous['response'].encode()); page = next(p for p in source['query']['pages'] if p['title'] == target)
        page['imageinfo'][0]['metadata'] = [{'name':'Orientation', 'value':8}]
        previous['response'] = figure.encoded(source).decode()
        with self.assertRaisesRegex(ValueError, 'does not complete exact omitted'):
            self.replay(base, self.batches[6:])
        for field, value in (('sha1', '0'*40), ('size', 5), ('metadata', [{'name':'Orientation','value':6}])):
            supplement = copy.deepcopy(self.batches[6]); data = figure.decode(supplement['response'].encode())
            data['query']['pages'][0]['imageinfo'][0][field] = value
            supplement['response'] = figure.encoded(data).decode()
            with self.subTest(field=field), self.assertRaises(ValueError):
                self.replay(self.batches[:5], [supplement])

    def test_explicit_request_reuse_authenticates_both_retained_http_proofs(self):
        proofs = figure.decode(gzip.decompress((self.sources/'selected-proofs.json.gz').read_bytes()))
        with tempfile.TemporaryDirectory() as directory:
            paths = []
            for i, (documents, batch) in enumerate(zip(proofs, self.batches[5:], strict=True)):
                root = Path(directory)/str(i); root.mkdir()
                (root/figure.metadata.NAMESPACE).write_bytes(self.namespace)
                for name, text in documents.items():
                    (root/name).write_bytes(text.encode())
                path = root/'retained-observation.json'; record = figure.decode(path.read_bytes())
                receipt = figure.decode((root/record['batch']['accepted_receipt']).read_bytes())
                (root/receipt['response']).write_bytes(batch['response'].encode()); paths.append(path.resolve())
            self.assertEqual(len(figure.select_reuse_batches(paths, self.wiki, self.date, self.namespace)), 2)
            with self.assertRaisesRegex(ValueError, 'namespace/date'):
                figure.select_reuse_batches(paths, self.wiki, '20261101', self.namespace)
            record = figure.decode(paths[0].read_bytes()); record['figure_profile'] = figure.FIGURE_PROFILE_V3
            paths[0].write_bytes(figure.encoded(record))
            with self.assertRaises(ValueError):
                figure.select_reuse_batches(paths, self.wiki, self.date, self.namespace)


class SrImageInfoBindingTests(unittest.TestCase):
    def setUp(self):
        fixtures = Path(__file__).parent / 'testdata'
        self.selected = (fixtures/'figure-page-observations/sr-fuhe-served-set/figure-siteinfo.raw.json').read_bytes()
        sources = fixtures/'sr-imageinfo-87f'
        self.observed = gzip.decompress((sources/'defaultoptions.raw.json.gz').read_bytes())
        self.image = json.loads((sources/'imageinfo-first.raw.json').read_bytes())
        self.media = figure._figure_media_extensions(self.image)
        self.old = json.loads(self.selected)['query']['general']['git-hash']
        self.core = site.FIGURE_WMF5_CORE

    def test_bound_geometry_keeps_both_specific_observations(self):
        figure.verify_file_defaults(self.selected, self.observed)
        current = json.loads(self.observed)
        self.assertEqual(site.figure_thumbnail_width(current['query']), 250)
        site.response(current, 'srwiktionary', 'sr', site.FIGURE_PROFILE, raw_sha=figure.digest(self.observed))
        approved = figure.figure_profile(self.core, figure.FIGURE_PROFILE_V4, self.media)
        self.assertEqual(approved['observed_defaults_response_sha256'], figure.digest(self.observed))
        self.assertEqual(approved['selected_defaults_sha256'], figure.digest(self.selected))
        figure._figure_site_registration(self.image, self.image['query']['general'], 'srwiktionary', approved)
        self.assertTrue(figure.bound_file_core(self.core, self.old, self.observed))
        self.assertFalse(figure.bound_file_core(self.core, self.old, None))
        self.assertFalse(figure.bound_file_core(self.old, self.core, self.observed))
        self.assertFalse(figure.figure_source_compatible(self.core, self.old))
        self.assertNotIn(self.core, figure.FIGURE_RESPONSE_EPOCHS)
        self.assertNotIn(self.core, site.CORE_PROFILES)
        with self.assertRaises(ValueError):
            site.response(current, 'srwiktionary', 'sr', site.PROFILE, raw_sha=figure.digest(self.observed))
        with patch.object(site, 'verify', return_value={'core': self.core, 'wiki': 'srwiktionary', 'date': '20261001'}):
            with self.assertRaisesRegex(ValueError, 'scoped to the ImageInfo'):
                site.validate_snapshot(Path(site.SNAPSHOT))

    def test_current_height_receipts_bind_the_exact_imageinfo_and_http_date(self):
        fixtures = Path(__file__).parent/'testdata'
        namespace = (fixtures/'figure-page-observations/sr-fuhe-served-set/namespace-registry.tsv').read_bytes()
        batch = figure.stream_decode((fixtures/'sr-svg226/current-height-batch.json').read_bytes())
        base = {key: batch[key] for key in ('requests', 'response')}
        def replay(supplement):
            return figure.file_records((base, supplement), namespace, 'srwiktionary', '20261001',
                base['response'].encode(), has_batches=True, record_limit=4,
                profile_kind=figure.FIGURE_PROFILE_V4, allow_compatible_epochs=True)
        observed = [height for row in replay(batch)['records'] for height in row['observed_svg_heights']]
        self.assertEqual({(v['title'], v['observed_width_px'], v['observed_height_px']) for v in observed},
            {('Нови Сад',224,250), ('Ниш',194,250), ('Приштина',156,200), ('Београд',168,200)})
        self.assertTrue(all(v['parse_core_binding_proven'] is False for v in observed))
        other_batch = figure.stream_decode((fixtures/'sr-svg226/current-height-batch-651.json').read_bytes())
        other_base = {key: other_batch[key] for key in ('requests', 'response')}
        projected = figure.file_records((other_base, other_batch), namespace, 'srwiktionary', '20261001',
            other_base['response'].encode(), has_batches=True, record_limit=4,
            profile_kind=figure.FIGURE_PROFILE_V4, allow_compatible_epochs=True)
        other_heights = [v for row in projected['records'] for v in row['observed_svg_heights']]
        self.assertEqual({(v['title'], v['observed_width_px'], v['observed_height_px']) for v in other_heights},
            {('Краљево',192,230), ('Зрењанин',194,300), ('рударство',171,150),
             ('rudarstvo',171,150), ('Зајечар',178,200)})
        self.assertTrue(all(v['parse_core_binding_proven'] is False for v in other_heights))
        for change in ('unbound', 'wrong-image', 'old-response', 'changed-header', 'fraction'):
            altered = copy.deepcopy(batch)
            triple = altered['observed_svg_occurrences'][0]
            receipt = json.loads(triple['receipt'])
            if change == 'unbound':
                del receipt['imageinfo_response_sha256']
            elif change == 'wrong-image':
                receipt['imageinfo_response_sha256'] = '0'*64
            elif change == 'old-response':
                receipt['observed_utc'] = '2026-11-09T19:14:37Z'
                receipt['headers']['date'] = 'Mon, 09 Nov 2026 19:14:37 GMT'
            elif change == 'changed-header':
                receipt['headers']['date'] = 'Mon, 09 Nov 2026 19:14:37 GMT'
            else:
                receipt['observed_utc'] = receipt['observed_utc'].replace('Z', '.0Z')
            triple['receipt'] = figure.encoded(receipt).decode()
            with self.subTest(change=change), self.assertRaisesRegex(ValueError, 'ImageInfo source or HTTP date'):
                replay(altered)
        with self.assertRaisesRegex(ValueError, 'Unproved or duplicate observed SVG width'):
            replay(dict(base, observed_svg_width_px=250))
        with self.assertRaisesRegex(ValueError, 'Unreviewed ImageInfo supplement'):
            replay(dict(base, jpeg_metadata_only=True))

    def test_current_svg_width_requires_exact_rasterized_png_from_registered_response(self):
        fixtures = Path(__file__).parent/'testdata'
        namespace = (fixtures/'figure-page-observations/sr-fuhe-served-set/namespace-registry.tsv').read_bytes()
        body = (fixtures/'sr-imageinfo-87f/sun-width75.raw.json').read_text()
        names = ['Датотека:Sun symbol.svg']
        base = {'requests':names, 'response':body}
        def replay(raw, width):
            supplement = {'requests':names, 'response':raw, 'observed_svg_width_px':width}
            return figure.file_records((base, supplement), namespace, 'srwiktionary', '20261001',
                body.encode(), has_batches=True, record_limit=1,
                profile_kind=figure.FIGURE_PROFILE_V4, allow_compatible_epochs=True)['records'][0]
        row = replay(body, 75)
        self.assertEqual((row['canonical_file'], row['observed_svg_width_px'], row['observed_batch']), (names[0],75,1))
        with self.assertRaises(ValueError):
            replay(body, 74)
        for key, value in (('thumbmime', None), ('thumbmime', 'image/jpeg'), ('thumbheight', 1),
                           ('thumburl', 'original'), ('sha1', '0'*40)):
            altered = json.loads(body)
            info = altered['query']['pages'][0]['imageinfo'][0]
            if value is None:
                del info[key]
            else:
                info[key] = info['url'] if value == 'original' else value
            with self.subTest(key=key, value=value), self.assertRaises(ValueError):
                replay(figure.encoded(altered).decode(), 75)

    def test_changed_defaults_profile_and_media_are_rejected(self):
        for group, key, value in (('defaultoptions', 'thumbsize', 0), ('defaultoptions', 'skin', 'vector'),
                                  ('defaultoptions', 'vector-theme', 'night'), ('general', 'rtl', True)):
            current = json.loads(self.observed)
            current['query'][group][key] = value
            altered = figure.encoded(current)
            with self.subTest(key=key), self.assertRaises(ValueError):
                figure.verify_file_defaults(self.selected, altered)
            # Even a changed raw digest cannot make the two contexts equal.
            with patch.object(site, 'FIGURE_WMF5_SR_RAW', figure.digest(altered)), self.assertRaises(ValueError):
                figure.verify_file_defaults(self.selected, altered)
        for kind, media in ((figure.FIGURE_PROFILE_V3, self.media), (figure.FIGURE_PROFILE_V5, self.media),
                            (figure.FIGURE_PROFILE_V4, dict(self.media, TimedMediaHandler='0'*40))):
            with self.subTest(kind=kind, media=media), self.assertRaises(ValueError):
                figure.figure_profile(self.core, kind, media)
        approved = figure.figure_profile(self.core, figure.FIGURE_PROFILE_V4, self.media)
        for key, value in (('rtl', True), ('thumblimits', {'0': 250}), ('lang', 'en')):
            changed = copy.deepcopy(self.image)
            general = changed['query']['general']
            general[key] = value
            with self.subTest(key=key), self.assertRaises(ValueError):
                figure._figure_site_registration(changed, general, 'srwiktionary', approved)


if __name__ == '__main__':
    unittest.main()
