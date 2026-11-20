import csv
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).with_name('index_corpus_attempts.py').resolve()


class AttemptIndexTests(unittest.TestCase):
    def test_numbered_retries_and_unstarted_production_are_counted_once(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            base = root / 'receipts' / 'example'

            def record(path, data):
                path.write_bytes(data)
                return dict(path=str(path), bytes=len(data), sha256=hashlib.sha256(data).hexdigest())

            def run_receipt(number, elapsed=None, partial=False):
                run = base / f'runtime{number:02}'
                closed = run / 'direct-runtime01'
                closed.mkdir(parents=True)
                log = b''
                if elapsed is not None:
                    phase = dict(edition='enwiktionary', date='20261001', phase='edition_build')
                    for event in [dict(event='start'), dict(event='end', seconds=elapsed, status='failure')]:
                        log += b'BUILD_PHASE ' + json.dumps({**phase, **event}).encode() + b'\n'
                result = dict(stdout=record(run / 'tests.stdout', log), returncode=1,
                              elapsed_seconds=10, argv=['build', '--wikis', 'enwiktionary'])
                closure = dict(whole_edition_selected=not partial, command_returncode=1, reaped=True,
                               ordinary_producer_passed=False, edition_output='enwiktionary/20261001',
                               closed_unix=number, result=record(run / 'result01.json', json.dumps(result).encode()))
                (closed / 'independent-closure01.json').write_text(json.dumps(closure))

            index = root / 'times.tsv'
            command = [sys.executable, '-B', str(SCRIPT), '--receipts', 'receipts', '--output', index]
            run_receipt(1)
            subprocess.run(command, cwd=root, capture_output=True, check=True)
            run_receipt(2, 7.5)
            run_receipt(3, 3.0, partial=True)
            subprocess.run([*command, '--add', 'example'], cwd=root, capture_output=True, check=True)
            with index.open() as stream:
                rows = list(csv.DictReader(stream, delimiter='\t'))
            self.assertEqual([(r['attempt'], r['production_seconds']) for r in rows],
                             [('example', ''), ('example/runtime02', '7.500')])
            before = index.stat()
            subprocess.run(command, cwd=root, capture_output=True, check=True)
            self.assertEqual(before.st_mtime_ns, index.stat().st_mtime_ns)
            with (base / 'runtime02/tests.stdout').open('ab') as stream:
                stream.write(b'another line\n')
            damaged = subprocess.run(command, cwd=root, capture_output=True)
            self.assertNotEqual(damaged.returncode, 0)
            self.assertIn(b'Build log differs', damaged.stderr)
            self.assertEqual(before.st_ino, index.stat().st_ino)
