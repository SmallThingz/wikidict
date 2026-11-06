import hashlib
import json
from pathlib import Path
import tempfile
import unittest

# The bounded test worker binds the exact in-memory patched ordinary builder.
# No source file is replaced and no producer entry point is executed.
builder = None
capture_root = None


class StylesheetPipelineTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        if builder is None:
            import build_wiktionaries
            self.builder = build_wiktionaries
        else:
            self.builder = builder
        if capture_root is None:
            from test_prepare_stylesheet_imports import StylesheetImportsTests
            fixture = StylesheetImportsTests()
            fixture.setUp()
            self.addCleanup(fixture.doCleanups)
            selected, _ = fixture.capture()
        else:
            selected = Path(capture_root)
        self.snapshot = selected / 'stylesheet-imports.json'

    def test_normal_auxiliary_route_uses_json_flag_and_full_capture(self):
        self.assertIn('stylesheet-imports', self.builder.AUXILIARY_SNAPSHOT_NAMES)
        self.assertEqual('stylesheet-imports.json', self.builder.auxiliary_snapshot_filename('stylesheet-imports'))
        self.assertEqual(['--stylesheet-imports-snapshot', str(self.snapshot)],
                         self.builder.auxiliary_snapshot_args({'stylesheet-imports': self.snapshot}))
        record, artifacts = self.builder.validated_auxiliary_capture('stylesheet-imports', self.snapshot, 'ptwiktionary', '20261001')
        self.assertEqual('ptwiktionary', record['wiki'])
        self.assertEqual(json.loads(self.snapshot.read_text())['namespace_sha256'], record['namespace_registry_sha256'])
        self.assertIn('stylesheet-imports.complete.json', artifacts)
        self.assertIn('request-02.response', artifacts)
        self.assertEqual(hashlib.sha256(self.snapshot.read_bytes()).hexdigest(), record['output_sha256'])

    def test_normal_pinning_preserves_complete_generation_in_own_folder(self):
        digest = hashlib.sha256(self.snapshot.read_bytes()).hexdigest()
        pinned = self.builder.pinned_auxiliary_snapshots({'stylesheet-imports': self.snapshot},
                    {'stylesheet-imports': digest}, self.root)
        actual = pinned['stylesheet-imports']
        self.assertEqual(self.root / 'stylesheet-imports' / 'stylesheet-imports.json', actual)
        original = self.builder.validated_auxiliary_capture('stylesheet-imports', self.snapshot)
        copied = self.builder.validated_auxiliary_capture('stylesheet-imports', actual)
        self.assertEqual(original, copied)
        (actual.parent / 'request-02.response').write_bytes(b'tampered')
        with self.assertRaises(ValueError):
            self.builder.validated_auxiliary_capture('stylesheet-imports', actual)

    def test_selected_namespace_and_edition_mismatch_are_rejected(self):
        with self.assertRaises(ValueError):
            self.builder.validated_auxiliary_capture('stylesheet-imports', self.snapshot, 'eswiktionary', '20261001')
        bound = self.builder.validated_auxiliary_capture('stylesheet-imports', self.snapshot)
        (self.root / 'namespace-registry.tsv').write_bytes(b'wrong selected namespaces')
        with self.assertRaises(ValueError):
            self.builder._validate_captured_snapshot_context('stylesheet-imports', self.snapshot,
                       {}, [], self.root, bound)

    def test_standalone_validation_replays_current_capture_before_context(self):
        selected = {'wiki': 'ptwiktionary', 'date': '20261001'}
        self.builder.validate_captured_snapshot('stylesheet-imports', self.snapshot, selected, [])
        with self.assertRaises(ValueError):
            self.builder.validate_captured_snapshot('stylesheet-imports', self.snapshot,
                        {'wiki': 'eswiktionary', 'date': '20261001'}, [])
        (self.root / 'namespace-registry.tsv').write_bytes(b'wrong standalone namespaces')
        with self.assertRaises(ValueError):
            self.builder.validate_captured_snapshot('stylesheet-imports', self.snapshot,
                        selected, [], self.root)
