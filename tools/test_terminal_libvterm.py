import ctypes.util
import gzip
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from terminal_libvterm import Screen, Stream
from verify_edition_terminal import NativeCellReaderPty, screen_projection
from verify_reader_ux import ReaderPty


class ProjectionSelectionTests(unittest.TestCase):
    @unittest.skipUnless(importlib.util.find_spec('pyte'), 'optional pyte is not installed')
    def test_default_projection_uses_existing_reader_and_pyte(self):
        import pyte
        self.assertEqual(screen_projection('pyte'), (pyte, ReaderPty))

    def test_missing_native_library_does_not_fall_back(self):
        with patch('terminal_libvterm.ctypes.util.find_library', return_value=None):
            with self.assertRaisesRegex(RuntimeError, 'requires libvterm.so.0'):
                Screen(20, 3)

    def test_unknown_native_abi_is_refused_before_loading(self):
        with patch('terminal_libvterm.ctypes.util.find_library', return_value='libvterm.so.1'):
            with self.assertRaisesRegex(RuntimeError, 'Unsupported libvterm ABI'):
                Screen(20, 3)


@unittest.skipUnless(ctypes.util.find_library('vterm'), 'optional native libvterm is not installed')
class NativeCellTests(unittest.TestCase):
    def setUp(self):
        self.screen = Screen(20, 3)
        self.addCleanup(self.screen.close)
        self.stream = Stream(self.screen)

    def test_class_zero_marks_spaces_and_wide_continuation_keep_native_columns(self):
        self.stream.feed('A  \u0789\u07a6\u0790\u07b0 Z\x1b[2;3H\U00020000Q')
        rows = self.screen.cell_rows()
        self.assertEqual([c['text'] for c in rows[0][:7]], ['A', ' ', ' ', '\u0789\u07a6', '\u0790\u07b0', ' ', 'Z'])
        self.assertEqual(rows[1][2]['text'], '\U00020000')
        self.assertEqual(rows[1][2]['width'], 2)
        self.assertTrue(rows[1][3]['continuation'])
        self.assertEqual(rows[1][3]['text'], '')
        self.assertEqual(rows[1][4]['text'], 'Q')
        self.assertEqual(self.screen.display[0], 'A  \u0789\u07a6\u0790\u07b0 Z' + ' ' * 13)

    def test_native_cursor_erase_alternate_screen_and_resize(self):
        self.stream.feed('original\x1b[?1049h\x1b[2J\x1b[2;5Hnew\x1b[?25l')
        self.assertEqual(vars(self.screen.cursor), dict(x=7, y=1, hidden=True))
        self.assertEqual(self.screen.display[1][4:7], 'new')
        self.stream.feed('\x1b[2;6H\x1b[K\x1b[?25h')
        self.assertEqual(self.screen.display[1], '    n' + ' ' * 15)
        self.assertFalse(self.screen.cursor.hidden)
        self.stream.feed('\x1b[?1049l')
        self.assertTrue(self.screen.display[0].startswith('original'))
        self.screen.resize(lines=4, columns=12)
        self.assertEqual(len(self.screen.cell_rows()), 4)
        self.assertTrue(all(len(row) == 12 for row in self.screen.cell_rows()))
        self.stream.feed('\x1b[4;12HX')
        self.assertEqual(self.screen.cell_rows()[3][11]['text'], 'X')

    def test_emphasis_is_captured_from_individual_cells_after_selective_resets(self):
        self.stream.feed('A\x1b[1;3;4mB\x1b[23mC\x1b[22;24mD')
        attrs = [{key: cell.get(key) for key in ('bold', 'italic', 'underline')}
                 for cell in self.screen.cell_rows()[0][:4]]
        self.assertEqual(attrs, [dict(bold=None, italic=None, underline=None),
                                 dict(bold=True, italic=True, underline=1),
                                 dict(bold=True, italic=None, underline=1),
                                 dict(bold=None, italic=None, underline=None)])

    def test_capture_records_actual_cells_and_text(self):
        self.stream.feed('  \u0789\u07a6\u0790\u07b0')
        with tempfile.TemporaryDirectory() as temp:
            reader = object.__new__(NativeCellReaderPty)
            reader.screen, reader.width, reader.rows = self.screen, 20, 3
            reader.output, reader.snapshots = Path(temp), []
            reader.snapshot('unicode')
            path = reader.output / reader.snapshots[0]['cells_file']
            self.assertEqual(path.suffixes, ['.cells', '.json', '.gz'])
            captured = json.loads(gzip.decompress(path.read_bytes()))
            self.assertEqual(captured['cells'], self.screen.cell_rows())
            self.assertEqual(captured['columns'], 20)
            self.assertEqual((reader.output / '00-unicode.txt').read_text(), '  \u0789\u07a6\u0790\u07b0\n\n\n')
