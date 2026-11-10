"""Ordinary optional-role validation and pinning; no network or native work."""
import hashlib
import tempfile
import unittest
from pathlib import Path

import build_wiktionaries as builder
import prepare_figure_page_observations as observations

FIXTURES = Path(__file__).resolve().parent / 'testdata' / 'figure-page-observations'
ROLE = 'figure-page-observations'
TEMP_ROOT = Path.cwd() / '.tmp'


class NormalObservationRole(unittest.TestCase):
    def setUp(self):
        TEMP_ROOT.mkdir(exist_ok=True)

    def package(self, root, edition):
        fixture = FIXTURES / edition
        output = root / ('source-' + edition)
        record = observations.pack(fixture / observations.SNAPSHOT,
                                   fixture / 'namespace-registry.tsv',
                                   fixture / 'figure-siteinfo.raw.json', output)
        return output / observations.SNAPSHOT, record

    def test_standalone_selected_capture_requires_fresh_verified_namespace(self):
        with tempfile.TemporaryDirectory(dir=TEMP_ROOT) as temporary:
            root = Path(temporary)
            for edition in ('it', 'hsb'):
                with self.subTest(edition=edition):
                    source, record = self.package(root, edition)
                    selected = root / ('selected-' + edition)
                    selected.mkdir()
                    namespace = selected / 'namespace-registry.tsv'
                    namespace.write_bytes((FIXTURES / edition / 'namespace-registry.tsv').read_bytes())
                    capture = dict(wiki=record['wiki'], date=record['date'])
                    builder.validate_captured_snapshot(ROLE, source, capture, [], selected)
                    namespace.write_bytes(namespace.read_bytes() + b'\n# different selected source\n')
                    with self.assertRaisesRegex(ValueError, 'different selected namespace registry'):
                        builder.validate_captured_snapshot(ROLE, source, capture, [], selected)
                    with self.assertRaisesRegex(ValueError, 'fresh capture verification'):
                        builder._validate_captured_snapshot_context(ROLE, source, capture, [], selected, None)

    def test_normal_pinning_copies_complete_package_into_its_own_capture_folder(self):
        with tempfile.TemporaryDirectory(dir=TEMP_ROOT) as temporary:
            root = Path(temporary)
            for edition in ('it', 'hsb'):
                with self.subTest(edition=edition):
                    source, record = self.package(root, edition)
                    inventory = observations.capture_artifacts(source, record)
                    destination = root / ('pinned-' + edition)
                    pinned = builder.pinned_auxiliary_snapshots(
                        {ROLE: source}, {ROLE: hashlib.sha256(source.read_bytes()).hexdigest()},
                        destination, {ROLE: inventory[observations.MANIFEST]},
                        {ROLE: builder.auxiliary_artifact_digest(inventory)})
                    expected = destination / ROLE / observations.SNAPSHOT
                    self.assertEqual(pinned, {ROLE: expected})
                    self.assertEqual(observations.validate_snapshot(expected), record)
                    self.assertEqual(observations.capture_artifacts(expected, record), inventory)
                    self.assertEqual({p.name for p in expected.parent.iterdir()}, set(inventory))
                    for name in inventory:
                        self.assertEqual((source.parent / name).read_bytes(), (expected.parent / name).read_bytes())
                    self.assertEqual(builder.pipeline_snapshot_args('registry.tsv', pinned),
                                     ['--figure-page-observations-snapshot', str(expected),
                                      '--language-registry-snapshot', 'registry.tsv'])
                    self.assertNotIn(ROLE, builder.FIGURE_SNAPSHOT_FILES)
                    (expected.parent / observations.COMPLETE).unlink()
                    with self.assertRaises((ValueError, OSError)):
                        observations.validate_snapshot(expected)


if __name__ == '__main__':
    unittest.main()
