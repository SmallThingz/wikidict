import hashlib
import json
from pathlib import Path
import tempfile
import unittest
from types import SimpleNamespace

from verify_edition_terminal import copy_publication, reading_text
from verify_reader_ux import CheckFailure


class EditionTerminalTests(unittest.TestCase):
    def test_only_verified_publication_members_enter_the_writable_copy(self):
        with tempfile.TemporaryDirectory() as tmp:
            parent = Path(tmp)
            source = parent / 'source'
            source.mkdir()
            (source / '.dict-state').mkdir()
            (source / '.dict-state/history.json').write_text('original')
            data = b'heading\nRuna Simi\n'
            catalog = source / 'languages.tsv'
            catalog.write_bytes(data)
            manifest = {'status': 'built', 'publication_files': {
                'languages.tsv': {'size': len(data), 'sha256': hashlib.sha256(data).hexdigest()}}}
            (source / 'complete.json').write_text(json.dumps(manifest))
            dest = parent / 'workspace'
            copy_publication(source, dest)
            self.assertFalse((dest / '.dict-state').exists())
            (dest / 'languages.tsv').write_bytes(b'changed')
            self.assertEqual(catalog.read_bytes(), data)
            self.assertEqual((source / '.dict-state/history.json').read_text(), 'original')
            catalog.write_bytes(b'x' * len(data))
            with self.assertRaisesRegex(CheckFailure, 'member differs'):
                copy_publication(source, parent / 'bad')

    def test_body_witness_excludes_match_sidebar_and_reading_title(self):
        lines = [''] * 11
        lines[6:9] = ['other title │ chosen / owner', 'sidebar │', 'wrong │ actual definition']
        reader = SimpleNamespace(width=90, screen=SimpleNamespace(display=lines))
        self.assertEqual(reading_text(reader, 8), 'actual definition')
        reader.width = 45
        lines[8] = 'part one │ part two'
        self.assertEqual(reading_text(reader, 8), 'part one │ part two')
