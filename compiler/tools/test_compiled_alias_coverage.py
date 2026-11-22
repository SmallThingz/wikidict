import json
from pathlib import Path
import tempfile
import unittest

import build_wiktionaries as builder


class CompiledAliasCoverageTests(unittest.TestCase):
    def check(self, rows):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / 'namespace-coverage.json').write_text(json.dumps({'version': 1, 'namespaces': rows}))
            return builder.validate_namespace_coverage(root, sum(row['input_rows'] for row in rows))

    @staticmethod
    def main_row():
        return dict(id=0, name='', kind='language', input_rows=3, compile_only_rows=0,
                    source_unavailable_rows=0, dispatched_rows=3, expanded_pages=2,
                    fallback_pages=1, duplicate_rows=0)

    def test_legacy_completion_totals_remain_byte_shape_compatible(self):
        row = self.main_row()
        self.assertEqual(self.check([row]), {key: row[key] for key in (
            'input_rows', 'compile_only_rows', 'source_unavailable_rows', 'dispatched_rows',
            'expanded_pages', 'fallback_pages', 'duplicate_rows')})

    def test_aliases_include_honest_tail_fallbacks_without_extra_dispatched_pages(self):
        row = self.main_row()
        row['alias_pages'] = 3
        totals = self.check([row])
        self.assertEqual(totals['alias_pages'], 3)
        self.assertEqual(totals['dispatched_rows'], 3)
        self.assertEqual(totals['fallback_pages'], 1)
        row['alias_pages'] = 4
        with self.assertRaisesRegex(ValueError, 'alias coverage subset'):
            self.check([row])

    def test_mixed_schemas_and_compile_only_aliases_are_rejected(self):
        row = self.main_row()
        other = dict(id=10, name='Template', kind=None, input_rows=1, compile_only_rows=1,
                     source_unavailable_rows=0, dispatched_rows=0, expanded_pages=0,
                     fallback_pages=0, duplicate_rows=0)
        row['alias_pages'] = 0
        with self.assertRaisesRegex(ValueError, 'Mixed alias'):
            self.check([row, other])
        other['alias_pages'] = 1
        with self.assertRaisesRegex(ValueError, 'alias coverage subset'):
            self.check([row, other])
        other['alias_pages'] = 0
        self.assertEqual(self.check([row, other])['alias_pages'], 0)


if __name__ == '__main__':
    unittest.main()
