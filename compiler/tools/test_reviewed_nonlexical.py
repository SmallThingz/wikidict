"""Focused contract tests; synthetic fixtures, never corpus inputs."""
import hashlib
import json
from pathlib import Path
import tempfile
import unittest
import reviewed_nonlexical as review


def coverage_row():
    return dict(id=0, kind='language', input_rows=1, compile_only_rows=0,
                source_unavailable_rows=0, site_metadata_rows=0, reviewed_nonlexical_rows=1,
                dispatched_rows=0, expanded_pages=0, fallback_pages=0, duplicate_rows=0)


class ReviewedNonlexicalTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.namespace = self.root / 'namespace.tsv'
        self.namespace.write_text('synthetic namespace fixture\n')
        self.evidence = self.root / 'evidence.txt'
        self.evidence.write_text('synthetic source review evidence\n')
        self.items = [dict(wiki='testwiktionary', date='20261001', name='test.xml.bz2', size=123, sha1='a' * 40)]
        self.record = dict(schema=review.SOURCE_SCHEMA, wiki='testwiktionary', date='20261001',
            input_files=[['testwiktionary', '20261001', 'test.xml.bz2', 123, 'a' * 40]],
            namespace_registry_sha256=review.digest(self.namespace),
            rows=[dict(namespace=0, page_id=7, revision_id=9, title='Home', decoded_source_sha256='b' * 64, reason='nonlexical_site_navigation')],
            review_evidence=[dict(path=str(self.evidence), bytes=self.evidence.stat().st_size, sha256=review.digest(self.evidence))])
        self.source = self.root / 'source-review.json'

    def load(self):
        self.source.write_text(json.dumps(self.record))
        return review.load_review(self.source, self.items, self.namespace)

    def test_exact_original_input_selection_required(self):
        self.record['input_files'][0][3] += 1
        with self.assertRaisesRegex(ValueError, 'input selection'):
            self.load()

    def test_unknown_source_scope_rejected(self):
        self.record['dump_sha256'] = 'c' * 64
        with self.assertRaisesRegex(ValueError, 'scope fields'):
            self.load()

    def test_duplicate_page_and_foreign_namespace_rejected(self):
        self.record['rows'].append(dict(self.record['rows'][0]))
        with self.assertRaisesRegex(ValueError, 'Duplicate'):
            self.load()
        self.record['rows'].pop()
        self.record['rows'][0]['namespace'] = 10
        with self.assertRaisesRegex(ValueError, 'namespace zero'):
            self.load()

    def test_changed_evidence_rejected(self):
        self.evidence.write_text('changed')
        with self.assertRaisesRegex(ValueError, 'evidence changed'):
            self.load()

    def test_execution_strips_reason_and_binds_native_inputs(self):
        selected = self.load()
        dump, index = self.root / 'dump.zst', self.root / 'page-index.tsv'
        dump.write_bytes(b'synthetic dump')
        index.write_bytes(b'synthetic native index')
        execution = review.materialize(selected, dump, index, self.root / review.NAME)
        value = json.loads(execution.read_text())
        self.assertNotIn('reason', value['rows'][0])
        self.assertNotIn('review_evidence', value)
        self.assertEqual(value['dump_sha256'], review.digest(dump))
        self.assertEqual(value['page_index_sha256'], review.digest(index))
        identity = {'reviewed_nonlexical_source_review_sha256': selected['sha256']}
        review.bind_identity(self.root, identity, selected)
        coverage = dict(version=2, reviewed_nonlexical_sha256=review.digest(execution),
                        reviewed_nonlexical_page_ids=[7], namespaces=[coverage_row()])
        path = self.root / 'namespace-coverage.json'
        path.write_text(json.dumps(coverage))
        review.check_coverage(self.root, identity)
        coverage['reviewed_nonlexical_page_ids'] = [8]
        path.write_text(json.dumps(coverage))
        with self.assertRaisesRegex(ValueError, 'coverage identity'):
            review.check_coverage(self.root, identity)

    def test_existing_execution_cannot_adopt_foreign_review(self):
        selected = self.load()
        for name in ('dump', 'index'):
            (self.root / name).write_bytes(name.encode())
        execution = review.materialize(selected, self.root / 'dump', self.root / 'index', self.root / review.NAME)
        value = json.loads(execution.read_text())
        value['rows'][0]['revision_id'] += 1
        execution.write_text(json.dumps(value))
        with self.assertRaisesRegex(ValueError, 'rows differ'):
            review.bind_identity(self.root, {}, selected)

    def test_no_review_requires_unchanged_v1_coverage(self):
        path = self.root / 'namespace-coverage.json'
        path.write_text(json.dumps(dict(version=1, namespaces=[])))
        review.check_coverage(self.root, {})
        path.write_text(json.dumps(dict(version=2, namespaces=[])))
        with self.assertRaisesRegex(ValueError, 'Unexpected'):
            review.check_coverage(self.root, {})

    def test_scanner_requires_actual_builder_identity(self):
        selected = self.load()
        for name in ('dump', 'index'):
            (self.root / name).write_bytes(name.encode())
        execution = review.materialize(selected, self.root / 'dump', self.root / 'index', self.root / review.NAME)
        identity = dict(files=self.record['input_files'], reviewed_nonlexical_source_review_sha256=selected['sha256'])
        review.bind_identity(self.root, identity, selected)
        coverage = dict(version=2, registry_sha256=self.record['namespace_registry_sha256'],
            reviewed_nonlexical_sha256=review.digest(execution), reviewed_nonlexical_page_ids=[7],
            namespaces=[coverage_row()])
        (self.root / 'namespace-coverage.json').write_text(json.dumps(coverage))
        with self.assertRaises(FileNotFoundError):
            review.check_publication(self.root)
        identity_path = self.root / '.build-inputs.json'
        execution_sha = identity.pop('reviewed_nonlexical_sha256')
        identity_path.write_text(json.dumps(identity))
        with self.assertRaisesRegex(ValueError, 'Missing review execution identity'):
            review.check_publication(self.root)
        identity['reviewed_nonlexical_sha256'] = execution_sha
        identity_path.write_text(json.dumps(identity))
        review.check_publication(self.root)
        identity['reviewed_nonlexical_source_review_sha256'] = 'c' * 64
        identity_path.write_text(json.dumps(identity))
        with self.assertRaisesRegex(ValueError, 'identity differs'):
            review.check_publication(self.root)

    def test_v1_rejects_review_artifacts_and_partial_identity(self):
        path = self.root / 'namespace-coverage.json'
        path.write_text(json.dumps(dict(version=1, namespaces=[])))
        review.check_publication(self.root)
        sidecar = self.root / review.NAME
        sidecar.write_text('{}')
        with self.assertRaisesRegex(ValueError, 'Unexpected reviewed publication'):
            review.check_publication(self.root)
        sidecar.unlink()
        identity = self.root / '.build-inputs.json'
        identity.write_text(json.dumps(dict(reviewed_nonlexical_source_review_sha256='a' * 64)))
        with self.assertRaisesRegex(ValueError, 'review execution identity'):
            review.check_publication(self.root)
        identity.write_text(json.dumps(dict(reviewed_nonlexical_sha256='b' * 64)))
        with self.assertRaisesRegex(ValueError, 'review execution identity'):
            review.check_publication(self.root)

    def test_reviewed_counter_conservation_required(self):
        selected = self.load()
        for name in ('dump', 'index'):
            (self.root / name).write_bytes(name.encode())
        execution = review.materialize(selected, self.root / 'dump', self.root / 'index', self.root / review.NAME)
        identity = dict(reviewed_nonlexical_source_review_sha256=selected['sha256'])
        review.bind_identity(self.root, identity, selected)
        row = coverage_row()
        row['input_rows'] = 2
        coverage = dict(version=2, reviewed_nonlexical_sha256=review.digest(execution),
                        reviewed_nonlexical_page_ids=[7], namespaces=[row])
        (self.root / 'namespace-coverage.json').write_text(json.dumps(coverage))
        with self.assertRaisesRegex(ValueError, 'Incomplete reviewed coverage accounting'):
            review.check_coverage(self.root, identity)


if __name__ == '__main__':
    unittest.main()
