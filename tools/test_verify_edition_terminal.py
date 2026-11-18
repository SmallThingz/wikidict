import hashlib
import json
from pathlib import Path
import tempfile
import unittest
from types import SimpleNamespace
from unittest.mock import patch

from verify_edition_terminal import copy_publication, main, reading_text
from verify_reader_ux import CheckFailure


class EditionTerminalTests(unittest.TestCase):
    def test_failed_native_review_closes_reader_and_preserves_publication(self):
        with tempfile.TemporaryDirectory() as tmp:
            parent = Path(tmp)
            source = parent / 'source'
            source.mkdir()
            data = b'heading\nOwner\n'
            (source / 'languages.tsv').write_bytes(data)
            (source / 'complete.json').write_text(json.dumps({'status': 'built', 'publication_files': {
                'languages.tsv': {'size': len(data), 'sha256': hashlib.sha256(data).hexdigest()}}}))
            before = {p.name: (p.read_bytes(), p.stat().st_ino, p.stat().st_mtime_ns) for p in source.iterdir()}
            binary = parent / 'reader'
            binary.write_bytes(b'not executed')
            events = []

            class FailedReader:
                def __init__(self, binary, root, width, rows, output, timeout, budget_end, projection, **kwargs):
                    self.screen = SimpleNamespace(close=lambda: events.append('projection closed'))
                    self.checks, self.snapshots = ['original check'], []
                    self.private_root = root
                    (root / 'languages.tsv').write_bytes(b'private state changed')
                    self.width, self.rows, self.timeout = width, rows, timeout

                def close(self):
                    events.append('reader closed')

            def fail(reader, language, entry, witness):
                self.assertEqual((reader.width, reader.rows, reader.timeout), (90, 30, 5))
                self.assertNotEqual(reader.private_root, source)
                raise CheckFailure('body witness missing')

            with patch('verify_edition_terminal.screen_projection', return_value=(None, FailedReader)), \
                    patch('verify_edition_terminal.exercise', side_effect=fail):
                result = main(['--binary', str(binary), '--root', str(source), '--language', 'Owner',
                               '--entry', 'Title', '--witness', 'body', '--report', str(parent / 'reports'),
                               '--screen-projection', 'libvterm'])
            self.assertEqual(result, 1)
            self.assertEqual(events, ['reader closed', 'projection closed'])
            report = json.loads(next((parent / 'reports').glob('*/result.json')).read_text())
            self.assertFalse(report['passed'])
            self.assertEqual(report['error'], 'body witness missing')
            self.assertEqual(report['checks'], ['original check'])
            self.assertEqual(before, {p.name: (p.read_bytes(), p.stat().st_ino, p.stat().st_mtime_ns) for p in source.iterdir()})

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
