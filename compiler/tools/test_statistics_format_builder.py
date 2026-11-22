import json
import unittest

import build_wiktionaries as builder
import prepare_site_statistics_format as formatting
import test_prepare_site_info as site_fixtures


class StatisticsFormattingBuilderTests(unittest.TestCase):
    setUp = site_fixtures.SiteInfoCaptureTests.setUp
    args = site_fixtures.SiteInfoCaptureTests.args
    collect = site_fixtures.SiteInfoCaptureTests.collect

    def pair(self):
        site_root, _ = self.collect('site-info')
        site = site_root / 'namespace-siteinfo.raw.json'
        cfg = formatting.profile.configuration(json.loads(site.read_bytes()), builder.sha256_file(site))
        def transport(url, timeout):
            self.assertGreater(timeout, 0)
            if 'action=query' in url:
                data = {'query': {'general': {'wikiid': cfg['wiki'], 'lang': cfg['content_language'], 'generator': 'fixture'}}}
            else:
                lines = [formatting.profile.BEGIN]
                for key in formatting.profile.KEYS:
                    raw = cfg['raw'][key]
                    lines.extend((key + '=' + raw, key + '-RAW=' + raw))
                data = {'expandtemplates': {'wikitext': '\n'.join(lines + [formatting.profile.END])}}
            return 200, {}, json.dumps(data).encode()
        output = self.root / 'site-statistics-format-v1'
        formatting.capture(site, output, delay=0, sleep=lambda _: None, transport=transport)
        return {'site-info': site, 'site-statistics-format': output / formatting.OUTPUT,
                'namespace-registry': self.original / 'namespace-registry.tsv'}

    def test_actual_capture_pair_hashes_and_pins_all_evidence_in_isolated_folders(self):
        snapshots = self.pair()
        before = {key: path.read_bytes() for key, path in snapshots.items()}
        hashes = builder.verified_auxiliary_hashes(snapshots, 'testwiktionary', '20261001')
        manifests, artifacts = builder.auxiliary_capture_identities(snapshots, 'testwiktionary', '20261001')
        destination = self.root / 'pinned'
        pinned = builder.pinned_auxiliary_snapshots(snapshots, hashes, destination, manifests, artifacts)
        self.assertEqual(pinned['site-statistics-format'].parent, destination / 'site-statistics-format')
        self.assertEqual(pinned['site-info'].parent, destination / 'site-info')
        record = formatting.validate_snapshot(pinned['site-statistics-format'], 'testwiktionary', '20261001')
        self.assertEqual(record['configuration']['site_info_sha256'], hashes['site-info'])
        self.assertEqual(builder.verified_auxiliary_hashes(pinned, 'testwiktionary', '20261001'), hashes)
        for key, path in snapshots.items(): self.assertEqual(path.read_bytes(), before[key])
        self.assertEqual(set(formatting.capture_artifacts(pinned['site-statistics-format'])),
                         {p.name for p in pinned['site-statistics-format'].parent.iterdir()})

    def test_valid_but_different_selected_site_info_cannot_reuse_old_formatting(self):
        snapshots = self.pair()
        changed = json.loads(json.dumps(self.data))
        changed['query']['statistics']['articles'] += 1
        other, _ = self.collect('different-site-info', data=changed)
        snapshots['site-info'] = other / 'namespace-siteinfo.raw.json'
        with self.assertRaisesRegex(ValueError, 'different selected site-info'):
            builder.verified_auxiliary_hashes(snapshots, 'testwiktionary', '20261001')

    def test_formatting_requires_selected_site_and_matching_namespace_authority(self):
        snapshots = self.pair()
        with self.assertRaisesRegex(ValueError, 'selected site-info'):
            builder.verified_auxiliary_hashes({'site-statistics-format': snapshots['site-statistics-format']}, 'testwiktionary', '20261001')
        other = self.root / 'other-namespace.tsv'
        other.write_bytes(snapshots['namespace-registry'].read_bytes() + b'\n')
        snapshots['namespace-registry'] = other
        with self.assertRaisesRegex(ValueError, 'different namespace registry'):
            builder.verified_auxiliary_hashes(snapshots, 'testwiktionary', '20261001')

    def test_normal_optional_generation_and_native_option_use_exact_json_asset(self):
        snapshots = self.pair()
        self.assertEqual(builder.discover_auxiliary_generation(self.root, 'site-statistics-format-v1',
            ('site-statistics-format',), 'testwiktionary', '20261001'),
            {'site-statistics-format': snapshots['site-statistics-format']})
        self.assertEqual(builder.auxiliary_snapshot_args({'site-statistics-format': snapshots['site-statistics-format']}),
            ['--site-statistics-format-snapshot', str(snapshots['site-statistics-format'])])
        self.assertIs(builder.auxiliary_capture_helper('site-statistics-format', snapshots['site-statistics-format']), formatting)
        self.assertEqual(builder.auxiliary_snapshot_filename('site-statistics-format'), 'site-statistics-format.json')
        self.assertEqual(builder.discover_auxiliary_generation(self.root, 'absent',
            ('site-statistics-format',), 'testwiktionary', '20261001'), {})

    def test_present_incomplete_generation_refuses_instead_of_silent_omission(self):
        (self.root / 'site-statistics-format-v1').mkdir()
        with self.assertRaises((OSError, ValueError)):
            builder.discover_auxiliary_generation(self.root, 'site-statistics-format-v1',
                ('site-statistics-format',), 'testwiktionary', '20261001')


if __name__ == '__main__':
    unittest.main()
