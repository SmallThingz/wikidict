import argparse
import copy
import json
from pathlib import Path
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
        with patch.object(figure, 'verify', wraps=figure.verify) as replay:
            discovered = builder.discover_auxiliary_generation(self.root, 'figure-inputs',
                tuple(figure.ROLES), self.wiki, self.date)
            self.assertEqual(discovered, {name: snapshots[name] for name in figure.ROLES})
            self.assertEqual(replay.call_count, 1)
        with patch.object(figure, 'verify', wraps=figure.verify) as replay:
            started = time.monotonic()
            hashes = builder.verified_auxiliary_hashes(snapshots, self.wiki, self.date)
            elapsed = time.monotonic() - started
            self.assertEqual(replay.call_count, 1)
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


if __name__ == '__main__':
    unittest.main()
