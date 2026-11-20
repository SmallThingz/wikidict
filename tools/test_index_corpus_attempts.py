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
    def test_external_guardian_uses_original_identity_and_rejects_partial_or_damaged_authority(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            workspace = root / 'workspace'
            (workspace / 'receipts').mkdir(parents=True)
            run = root / 'external' / 'runtime01'
            closed = run / 'direct-runtime01'
            closed.mkdir(parents=True)

            def record(path, value):
                raw = value if isinstance(value, bytes) else json.dumps(value).encode()
                path.write_bytes(raw)
                return dict(path=str(path), bytes=len(raw), sha256=hashlib.sha256(raw).hexdigest())

            builder = record(root / 'builder.py', b'previously guarded source')
            catalog = dict(modules={'build_wiktionaries': builder})
            catalog_ref = record(root / 'catalog.json', catalog)
            manifest = record(root / 'manifest.json', dict(requested_editions=['blkwiktionary'],
                files=[dict(wiki='blkwiktionary', date='20261001')]))
            argv = ['python', builder['path'], '--python-tooling-json', json.dumps(catalog),
                    '--input-manifest', manifest['path'], '--input-manifest-sha256', manifest['sha256'],
                    '--wikis', 'blkwiktionary', '--output', str(root / 'output')]
            phase = dict(edition='blkwiktionary', date='20261001', phase='edition_build')
            log = b''.join(b'BUILD_PHASE ' + json.dumps({**phase, **event}).encode() + b'\n'
                          for event in [dict(event='start'), dict(event='end', seconds=2.5, status='success')])
            stdout = record(run / 'tests.stdout', log)
            diagnostics = b'build diagnostic\n' * 32768
            stderr = record(run / 'tests.stderr', diagnostics)

            def freeze(extra=(), watchdog_code=0):
                command = dict(argv=argv + list(extra), cwd=str(workspace), env={},
                    source_refs=[builder], current_python_catalog=catalog_ref, qualification_root=str(run))
                command_ref = record(root / 'command.json', command)
                result = dict(argv=command['argv'], cwd=str(workspace), environment={},
                              returncode=0, elapsed_seconds=3, stdout=stdout, stderr=stderr)
                closure = dict(source_after=True, source_lease_released=True, allocation_released=True,
                    local_proc_absent=True, ps_absent=True, host_namespace_identity_absent=True,
                    terminal=0, reaped=True, closed_unix=1,
                    start=record(closed / 'start.json', dict(input_authority=command_ref, source_refs=[builder])),
                    owner_result=record(closed / 'owner-result.json', dict(returncode=0, source_after=True)),
                    watchdog=record(closed / 'watchdog.json', dict(child_exit_status=watchdog_code)),
                    result=record(run / 'result01.json', result))
                path = closed / 'independent-closure01.json'
                record(path, closure)
                return path

            path = freeze()
            index = workspace / 'times.tsv'
            command = [sys.executable, '-B', str(SCRIPT), '--receipts', 'receipts', '--output', index,
                       '--add-guardian-closure', str(path)]
            subprocess.run(command, cwd=workspace, capture_output=True, check=True)
            with index.open() as stream:
                row, = csv.DictReader(stream, delimiter='\t')
            self.assertEqual(row['attempt'], 'absolute:' + str(run))
            self.assertEqual(row['closure_path'], str(path))
            self.assertEqual(row['production_seconds'], '2.500')
            before = index.read_bytes(), index.stat().st_ino
            subprocess.run(command, cwd=workspace, capture_output=True, check=True)
            self.assertEqual((index.read_bytes(), index.stat().st_ino), before)
            for extra, code, message in [(('--presentation-audit-pages', '100'), 0, b'Partial build'),
                                         ((), 1, b'Incomplete guardian closure')]:
                freeze(extra, code)
                refused = subprocess.run(command, cwd=workspace, capture_output=True)
                self.assertNotEqual(refused.returncode, 0)
                self.assertIn(message, refused.stderr)
                self.assertEqual((index.read_bytes(), index.stat().st_ino), before)
            freeze()
            for changed in (diagnostics[:-1], diagnostics[:-1] + b'!'):
                (run / 'tests.stderr').write_bytes(changed)
                refused = subprocess.run(command, cwd=workspace, capture_output=True)
                self.assertNotEqual(refused.returncode, 0)
                self.assertIn(b'tests.stderr', refused.stderr)
                self.assertEqual((index.read_bytes(), index.stat().st_ino), before)
            (run / 'tests.stderr').write_bytes(diagnostics)
            (root / 'command.json').write_bytes(b'changed authority')
            refused = subprocess.run(command, cwd=workspace, capture_output=True)
            self.assertNotEqual(refused.returncode, 0)
            self.assertEqual((index.read_bytes(), index.stat().st_ino), before)

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

    def test_explicit_owner_paths_keep_legacy_keys_and_distinguish_same_names(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'receipts').mkdir()

            def record(owner, number):
                run = root / owner / 'example' / f'runtime{number:02}'
                closed = run / 'direct-runtime01'
                closed.mkdir(parents=True)
                log = run / 'tests.stdout'
                log.write_bytes(b'')
                result = dict(stdout=dict(path=str(log), bytes=0,
                              sha256=hashlib.sha256(b'').hexdigest()), returncode=2,
                              elapsed_seconds=5.454, argv=['build', '--wikis', 'iuwiktionary'])
                result_path = run / 'result01.json'
                raw = json.dumps(result).encode()
                result_path.write_bytes(raw)
                closure = dict(whole_edition_selected=True, command_returncode=2, reaped=True,
                               ordinary_producer_passed=False, edition_output='iuwiktionary/20261001',
                               closed_unix=number, result=dict(path=str(result_path), bytes=len(raw),
                               sha256=hashlib.sha256(raw).hexdigest()))
                path = closed / 'independent-closure01.json'
                path.write_text(json.dumps(closure))
                return path

            legacy = record('receipts', 1)
            first = record('owner-a', 1)
            retry = record('owner-a', 2)
            second = record('owner-b', 1)
            index = root / 'times.tsv'
            command = [sys.executable, '-B', str(SCRIPT), '--receipts', 'receipts', '--output', index]
            subprocess.run([*command, '--add', 'example'], cwd=root, capture_output=True, check=True)
            selected = [item for p in (first, retry, second) for item in ('--add-closure', str(p))]
            subprocess.run([*command, *selected], cwd=root, capture_output=True, check=True)
            with index.open() as stream:
                rows = list(csv.DictReader(stream, delimiter='\t'))
            self.assertEqual({r['attempt'] for r in rows}, {'example',
                'path:owner-a/example/runtime01', 'path:owner-a/example/runtime02',
                'path:owner-b/example/runtime01'})
            self.assertTrue(all(r['production_seconds'] == '' for r in rows))
            before = index.read_bytes(), index.stat().st_ino
            subprocess.run([*command, *selected], cwd=root, capture_output=True, check=True)
            self.assertEqual((index.read_bytes(), index.stat().st_ino), before)
            # Explicit selection must not silently broaden into a legacy scan.
            (legacy.parents[1] / 'tests.stdout').write_bytes(b'changed old stream')
            subprocess.run([*command, '--add-closure', str(second)], cwd=root, capture_output=True, check=True)
            (first.parents[1] / 'tests.stdout').write_bytes(b'changed selected stream')
            refused = subprocess.run([*command, '--add-closure', str(first)], cwd=root, capture_output=True)
            self.assertNotEqual(refused.returncode, 0)
            self.assertIn(b'Build log differs', refused.stderr)
            self.assertEqual((index.read_bytes(), index.stat().st_ino), before)
