import hashlib
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import namespace_registry_snapshot as n
import site_info_snapshot as s
import build_wiktionaries as b

HERE = Path(__file__).resolve().parent


def digest(data):
    return hashlib.sha256(data).hexdigest()


class SiteInfoSnapshotTests(unittest.TestCase):
    def setUp(self):
        work = Path(os.environ.get('WIKIDICT_SITE_INFO_TEST_ROOT',
            str(HERE.parent / '.tmp' / 'site-info-tests')))
        work.mkdir(parents=True, exist_ok=True)
        self.root = Path(tempfile.mkdtemp(prefix='case-', dir=work))

    def fixture(self, name='capture', lang='en', server='//actual.example'):
        root = self.root / name
        root.mkdir()
        wiki, date = 'testwiktionary', '20261001'
        ns = {str(i): dict(id=i, name=label, canonical=label, case='case-sensitive')
              for i, label in ((0, ''), (10, 'Template'), (14, 'Category'))}
        query = dict(general=dict(wikiid=wiki, lang=lang, server=server),
                     namespaces=ns, namespacealiases=[])
        raw = json.dumps(dict(query=query)).encode()
        xml = ('<mediawiki><siteinfo><dbname>' + wiki + '</dbname><namespaces>' +
               ''.join('<namespace key="' + str(row['id']) + '" case="case-sensitive">' +
                       row['name'] + '</namespace>' for row in ns.values()) +
               '</namespaces></siteinfo></mediawiki>').encode()
        for filename, data in ((s.SNAPSHOT_NAME, raw), ('dump-siteinfo.xml', xml),
                               ('pagetable-dumpstatus.raw.json', b'{}')):
            (root / filename).write_bytes(data)
        source = dict(wiki=wiki, date=date, name=wiki + '-' + date + '-pages-meta-current.xml.bz2',
                      url='https://dumps.wikimedia.org/' + wiki + '/' + date + '/' +
                          wiki + '-' + date + '-pages-meta-current.xml.bz2',
                      size=1, sha1='1' * 40)
        record = dict(wiki=wiki, date=date, retrieved_utc='2026-10-04T18:00:00+00:00',
                      siteinfo_source_url='https://actual.example/w/api.php?action=query&meta=siteinfo',
                      siteinfo_temporal_scope='current at retrieval; not historical API state',
                      source_xml=source, namespace_mismatches=[],
                      dump_namespace_inventory=[dict(id=row['id'], name=row['name'], case=row['case'])
                                                for row in ns.values()],
                      artifacts={filename: digest((root / filename).read_bytes())
                                 for filename in (s.SNAPSHOT_NAME, 'dump-siteinfo.xml',
                                                  'pagetable-dumpstatus.raw.json')})
        (root / 'capture.complete.json').write_text(json.dumps(record))
        n.build(root)
        return root

    def rebind_raw(self, root, transform):
        raw = json.loads((root / s.SNAPSHOT_NAME).read_bytes())
        transform(raw)
        data = json.dumps(raw).encode()
        (root / s.SNAPSHOT_NAME).write_bytes(data)
        capture = json.loads((root / 'capture.complete.json').read_bytes())
        capture['artifacts'][s.SNAPSHOT_NAME] = digest(data)
        (root / 'capture.complete.json').write_text(json.dumps(capture))
        manifest = json.loads((root / s.MANIFEST_NAME).read_bytes())
        manifest['raw_siteinfo_sha256'] = digest(data)
        (root / s.MANIFEST_NAME).write_text(json.dumps(manifest))

    def test_server_syntax_preserves_exact_supported_values(self):
        values = ('//ar.wiktionary.org', 'http://Host.Example:80',
                  'https://xn--r8jz45g.example:65535', '//host.', '//localhost:1')
        for value in values:
            self.assertEqual(s.validate_server(value), value)
        invalid = (None, 1, '', 'ar.wiktionary.org', 'ftp://host', '//', '//-host',
                   '//host-', '//a..b', '//a_b', '//user@host', '//host/', '//host?q',
                   '//host#x', '//host\\x', '//host\n', '//ho st', '//höst',
                   '//host:0', '//host:65536', '//host:', '//host:abc', '//[::1]',
                   '//' + 'a' * 64 + '.org', '//' + '.'.join(['a' * 63] * 5))
        for value in invalid:
            with self.subTest(value=value), self.assertRaises(ValueError):
                s.validate_server(value)

    def test_original_evidence_is_bound_and_never_rewritten(self):
        root = self.fixture(server='//different-from-language.example')
        before = {p.name: p.read_bytes() for p in root.iterdir()}
        record = s.validate_snapshot(root / s.SNAPSHOT_NAME, 'testwiktionary', '20261001')
        self.assertEqual(record['server'], '//different-from-language.example')
        self.assertEqual(record['output_sha256'], digest(before[s.SNAPSHOT_NAME]))
        self.assertEqual(record['namespace_registry_sha256'], digest(before['namespace-registry.tsv']))
        self.assertEqual(s.capture_artifacts(root / s.SNAPSHOT_NAME, record),
                         {name: digest(before[name]) for name in s._FILES})
        self.assertEqual(before, {p.name: p.read_bytes() for p in root.iterdir()})

    def test_each_bound_artifact_tamper_or_absence_rejected(self):
        for name in s._FILES:
            root = self.fixture('tamper-' + name)
            path = root / name
            original = path.read_bytes()
            path.write_bytes(original + b' ')
            if name in (s.SNAPSHOT_NAME, 'namespace-registry.tsv', 'dump-siteinfo.xml'):
                with self.assertRaises(ValueError): s.validate_snapshot(root / s.SNAPSHOT_NAME)
            else:
                # JSON whitespace is valid but changes the pinned artifact identity.
                record = s.validate_snapshot(root / s.SNAPSHOT_NAME)
                self.assertNotEqual(record['artifacts'][name], digest(original))
            path.unlink()
            with self.assertRaises((ValueError, OSError)): s.validate_snapshot(root / s.SNAPSHOT_NAME)

    def test_raw_identity_and_missing_server_fail_even_with_rebound_hashes(self):
        for case in ('server', 'wiki', 'lang'):
            root = self.fixture(case)
            def alter(raw):
                if case == 'server': del raw['query']['general']['server']
                else: raw['query']['general'][case if case == 'lang' else 'wikiid'] = 'wrong'
            self.rebind_raw(root, alter)
            with self.assertRaises(ValueError): s.validate_snapshot(root / s.SNAPSHOT_NAME)

    def test_paired_registry_projection_and_observation_identity_must_match(self):
        for case in ('namespace', 'retrieval', 'source'):
            root = self.fixture(case)
            manifest = json.loads((root / s.MANIFEST_NAME).read_bytes())
            if case == 'namespace':
                path = root / 'namespace-registry.tsv'
                path.write_bytes(path.read_bytes().replace(b'content-language\ten', b'content-language\tfr'))
                manifest['output_sha256'] = digest(path.read_bytes())
            elif case == 'retrieval': manifest['retrieved_utc'] = '2026-10-05T18:00:00+00:00'
            else: manifest['source_dump_files'][0]['sha1'] = '2' * 40
            (root / s.MANIFEST_NAME).write_text(json.dumps(manifest))
            with self.assertRaises(ValueError): s.validate_snapshot(root / s.SNAPSHOT_NAME)

    def test_symlink_oversize_and_duplicate_json_keys_rejected(self):
        root = self.fixture()
        raw = root / s.SNAPSHOT_NAME
        saved = self.root / 'raw.saved'
        raw.rename(saved)
        raw.symlink_to(saved)
        with self.assertRaises(ValueError): s.validate_snapshot(raw)
        raw.unlink()
        raw.write_bytes(saved.read_bytes())
        with patch.object(s, 'MAX_BYTES', 10):
            with self.assertRaises(ValueError): s.validate_snapshot(raw)
        with self.assertRaises(ValueError): s._json(b'{"query":{},"query":{}}')

    def test_pinning_keeps_original_filenames_and_complete_evidence(self):
        root = self.fixture()
        snapshots = {'site-info': root / s.SNAPSHOT_NAME, 'namespace-registry': root / 'namespace-registry.tsv'}
        hashes = b.verified_auxiliary_hashes(snapshots, 'testwiktionary', '20261001')
        manifests, artifacts = b.auxiliary_capture_identities(snapshots)
        before = {p.name: p.read_bytes() for p in root.iterdir()}
        destination = self.root / 'pinned'
        with patch.object(b, 'copy_verified_snapshot', wraps=b.copy_verified_snapshot) as copy:
            pinned = b.pinned_auxiliary_snapshots(snapshots, hashes, destination, manifests, artifacts)
        self.assertEqual(copy.call_count, 5)
        self.assertEqual(pinned['site-info'], destination / s.SNAPSHOT_NAME)
        self.assertEqual({p.name for p in destination.iterdir()}, set(s._FILES))
        self.assertEqual(b.verified_auxiliary_hashes(pinned), hashes)
        self.assertEqual(b.auxiliary_capture_identities(pinned), (manifests, artifacts))
        self.assertEqual(before, {p.name: p.read_bytes() for p in root.iterdir()})
        self.assertIn('--site-info-snapshot', b.auxiliary_snapshot_args(pinned))
        self.assertEqual(manifests['site-info'], digest(before[s.MANIFEST_NAME]))

    def test_current_namespace_pair_mismatch_and_changed_provenance_rejected(self):
        root = self.fixture()
        other = self.fixture('other', lang='fr')
        mixed = {'site-info': root / s.SNAPSHOT_NAME, 'namespace-registry': other / 'namespace-registry.tsv'}
        with self.assertRaisesRegex(ValueError, 'different namespace registry'):
            b.verified_auxiliary_hashes(mixed)
        snapshots = {'site-info': root / s.SNAPSHOT_NAME, 'namespace-registry': root / 'namespace-registry.tsv'}
        hashes = b.verified_auxiliary_hashes(snapshots)
        manifests, artifacts = b.auxiliary_capture_identities(snapshots)
        path = root / 'capture.complete.json'
        path.write_bytes(path.read_bytes() + b' ')
        with self.assertRaisesRegex(ValueError, 'artifacts changed'):
            b.pinned_auxiliary_snapshots(snapshots, hashes, self.root / 'rejected', manifests, artifacts)
        self.assertFalse((self.root / 'rejected').exists())

    def test_discovery_binds_selected_capture_and_cannot_invent_missing_siteinfo(self):
        root = self.fixture()
        capture = json.loads((root / 'capture.complete.json').read_bytes())
        source = capture['source_xml']
        downloads = self.root / 'downloads'
        language_root = downloads / source['wiki'] / source['date']
        language_root.mkdir(parents=True)
        language = language_root / 'language-registry.tsv'
        language.write_bytes(b'# content-language\ten\nen\tEnglish\n')
        manifest = dict(auxiliary_capture_roots={source['wiki']: 'capture'},
                        language_registries=[dict(wiki=source['wiki'], date=source['date'],
                            name=language.name, size=language.stat().st_size, sha256=digest(language.read_bytes()))])
        key = (source['wiki'], source['date'])
        with patch.object(b, 'PROJECT', self.root):
            options = b.resolve_edition_snapshot_options(manifest, {key: [source]}, downloads)[key]
        self.assertEqual(options['auxiliary_snapshots']['site-info'], root / s.SNAPSHOT_NAME)
        b.validate_captured_snapshot('site-info', root / s.SNAPSHOT_NAME, capture, [source], root)
        other = self.fixture('other')
        (other / 'capture.complete.json').write_bytes((other / 'capture.complete.json').read_bytes() + b' ')
        with self.assertRaisesRegex(ValueError, 'different namespace capture'):
            b.validate_captured_snapshot('site-info', other / s.SNAPSHOT_NAME, capture, [source], root)
        (root / s.SNAPSHOT_NAME).unlink()
        with patch.object(b, 'PROJECT', self.root), self.assertRaises((ValueError, OSError)):
            b.resolve_edition_snapshot_options(manifest, {key: [source]}, downloads)

    def test_expander_reuse_hashes_exact_raw_json_filename(self):
        root = self.fixture()
        expander_build = self.root / 'expander'
        expander = expander_build / '.bundle-expander'
        expander.mkdir(parents=True)
        (expander_build / '.incomplete').write_text('expander ready')
        for name in ('dict-bundle-expander', 'page-index.tsv'):
            (expander / name).write_text('fixture')
        (expander / 'namespace-registry.tsv').write_bytes((root / 'namespace-registry.tsv').read_bytes())
        raw = (root / s.SNAPSHOT_NAME).read_bytes()
        (expander / s.SNAPSHOT_NAME).write_bytes(raw)
        self.assertTrue(b.expander_ready(expander_build, {'site-info': digest(raw)}))
        (expander / s.SNAPSHOT_NAME).write_bytes(raw + b' ')
        self.assertFalse(b.expander_ready(expander_build, {'site-info': digest(raw)}))


if __name__ == '__main__':
    unittest.main(verbosity=2)
