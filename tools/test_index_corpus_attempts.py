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
            run = root / 'external' / 'source-scratch' / 'whole02-runtime'
            closed = run / 'direct-runtime01'
            closed.mkdir(parents=True)

            def record(path, value):
                raw = value if isinstance(value, bytes) else json.dumps(value).encode()
                path.write_bytes(raw)
                return dict(path=str(path), bytes=len(raw), sha256=hashlib.sha256(raw).hexdigest())

            builder = record(root / 'builder.py', b'previously guarded source')
            selector = record(root / 'selector.py', b'catalog selector')
            catalog = dict(modules={'build_wiktionaries': builder}, selector=selector)
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

            def freeze(extra=(), watchdog_code=0, *, exit_code=0, detached=False, selected_catalog=False,
                       input_selection=False, guard_selector=True, selected_manifest=None, cleanup=True):
                command = dict(argv=argv + list(extra), cwd=str(workspace), env={},
                    source_refs=[builder], current_python_catalog=catalog_ref, qualification_root=str(run))
                if selected_catalog:
                    selection = record(root / 'selection.json', dict(python_tooling=command.pop('current_python_catalog')))
                    command.update(selection=selection, source_refs=[builder, selection, catalog_ref])
                if input_selection:
                    command.pop('current_python_catalog')
                    selection = record(root / 'inputs.json', dict(manifest=selected_manifest or manifest))
                    command.update(input_step='ordinary_whole', input_selection=selection,
                                   source_refs=[builder, selection, manifest])
                    if guard_selector:
                        command['source_refs'].append(selector)
                command_ref = record(root / 'command.json', command)
                start = dict(input_authority=command_ref, source_refs=command['source_refs'])
                if selected_catalog:
                    refs = command['source_refs']
                    encoded = json.dumps(refs, sort_keys=True, separators=(',', ':')).encode()
                    start.update(source_refs=refs[:2], source_refs_ref=command_ref, source_ref_count=len(refs),
                                 source_refs_sha256=hashlib.sha256(encoded).hexdigest())
                result = dict(argv=command['argv'], cwd=str(workspace), environment={},
                              returncode=exit_code, elapsed_seconds=3, stdout=stdout, stderr=stderr)
                closure = dict(source_after=True, source_lease_released=True, allocation_released=True,
                    local_proc_absent=True, ps_absent=True, host_namespace_identity_absent=True,
                    terminal=exit_code, reaped=True, closed_unix=1,
                    start=record(closed / 'start.json', start),
                    owner_result=record(closed / 'owner-result.json', dict(returncode=exit_code, source_after=True)),
                    watchdog=record(closed / 'watchdog.json', dict(child_exit_status=watchdog_code,
                        cleanup_complete=cleanup, guardian_exit_status=0, termination_reason='child_exit')),
                    result=record(run / 'result01.json', result))
                if detached:
                    closure.update(terminal=None, reaped=False, original_rd_terminal_known=False,
                        original_rd_reaped=False, original_rd_terminal=None, rd_receipt_gap='terminal unavailable', errors=[])
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

            from index_corpus_attempts import read_execution
            base = workspace / 'receipts'
            freeze(input_selection=True)
            self.assertEqual(read_execution(base, path, guardian=True)['production_seconds'], '2.500')
            freeze(input_selection=True, guard_selector=False)
            with self.assertRaisesRegex(ValueError, 'Unguarded Python catalog member'):
                read_execution(base, path, guardian=True)
            freeze(input_selection=True, selected_manifest=record(root / 'unselected.json', b'{}'))
            with self.assertRaisesRegex(ValueError, 'Selected input manifest differs'):
                read_execution(base, path, guardian=True)
            freeze(selected_catalog=True)
            self.assertEqual(read_execution(base, path, guardian=True)['closure_join'], 'reaped')
            closure = json.loads(path.read_bytes())
            start = json.loads((closed / 'start.json').read_bytes())
            closure['start'] = record(closed / 'start.json', dict(start, source_ref_count=2))
            record(path, closure)
            with self.assertRaisesRegex(ValueError, 'Guardian source list differs'):
                read_execution(base, path, guardian=True)
            freeze(selected_catalog=True)
            (root / 'selection.json').write_text('{}')
            with self.assertRaises(ValueError):
                read_execution(base, path, guardian=True)
            freeze(detached=True)
            with self.assertRaisesRegex(ValueError, 'Incomplete guardian closure'):
                read_execution(base, path, guardian=True)
            stdout = record(run / 'tests.stdout', b'')
            freeze(detached=True, exit_code=1, watchdog_code=1, selected_catalog=True)
            row = read_execution(base, path, guardian=True)
            self.assertEqual(row['command_exit'], 1)
            self.assertEqual(row['closure_join'], 'original-terminal-unknown')
            self.assertEqual(row['production_status'], 'no-terminal-production-clock')
            for watchdog_code, cleanup in [(0, True), (1, False)]:
                freeze(detached=True, exit_code=1, watchdog_code=watchdog_code, cleanup=cleanup)
                with self.assertRaisesRegex(ValueError, 'Incomplete guardian closure'):
                    read_execution(base, path, guardian=True)

    def test_numbered_retries_and_unstarted_production_are_counted_once(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            base = root / 'receipts' / 'example'

            def record(path, data):
                path.write_bytes(data)
                return dict(path=str(path), bytes=len(data), sha256=hashlib.sha256(data).hexdigest())

            def run_receipt(number, elapsed=None, partial=False, events=()):
                run = base / f'runtime{number:02}'
                closed = run / 'direct-runtime01'
                closed.mkdir(parents=True)
                log = b''.join(b'BUILD_PHASE ' + json.dumps(event).encode() + b'\n' for event in events)
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

            preflight = dict(edition='enwiktionary', date='20261001', phase='selected_snapshot_resolution', scope='pre_edition')
            failed = [{**preflight, 'event': 'start'}, {**preflight, 'event': 'end', 'status': 'failure'}]
            started = dict(edition='enwiktionary', date='20261001', phase='edition_build', event='start')
            for n, events in enumerate((failed, failed + [started], failed[1:],
                                        [{**event, 'date': '20260101'} for event in failed]), start=4):
                run_receipt(n, events=events)
            for n in range(4, 8):
                command.extend(['--add-closure', str(base / f'runtime{n:02}/direct-runtime01/independent-closure01.json')])
            subprocess.run(command, cwd=root, capture_output=True, check=True)
            with index.open() as stream:
                extra = list(csv.DictReader(stream, delimiter='\t'))[2:]
            self.assertEqual([r['production_status'] for r in extra],
                             ['failed-before-production'] + ['no-terminal-production-clock'] * 3)
            self.assertTrue(all(r['production_seconds'] == '' and r['command_seconds'] == '10.000' for r in extra))
            # Refresh only the classification of the authenticated legacy row.
            current = index.read_bytes()
            index.write_bytes(current.replace(b'failed-before-production', b'no-terminal-production-clock'))
            subprocess.run(command, cwd=root, capture_output=True, check=True)
            self.assertEqual(index.read_bytes(), current)

    def test_retry_rate_distinguishes_a_proven_preflight_failure_from_an_unknown_clock(self):
        from index_corpus_attempts import refresh_retry_times

        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'times.tsv'
            original = dict(edition='etwiktionary', selected_status='built', known_seconds_through_351='4.000',
                            unknown_durations_through_351='0', recovered_additional_success_seconds='0.000',
                            selected_input_xml_pages='15', later_measured_successes='0', later_measured_failures='0',
                            later_unclocked_invocations='0', later_measured_production_seconds='0.000',
                            total_known_attempt_seconds='4.000', selected_pages_per_recorded_attempt_second='3.750')
            with path.open('w', newline='') as stream:
                writer = csv.DictWriter(stream, fieldnames=original, delimiter='\t')
                writer.writeheader()
                writer.writerow(original)

            def attempt(status, seconds=''):
                return dict(edition='etwiktionary', production_status=status, production_seconds=seconds)
            records = [attempt('success', '0.600'), attempt('failure', '0.400'), attempt('failed-before-production')]
            fresh, = refresh_retry_times(path, records)
            self.assertEqual(fresh['selected_pages_per_recorded_attempt_second'], '3.000')
            self.assertEqual(fresh['later_unclocked_invocations'], '1')
            self.assertEqual(fresh['later_measured_failures'], '1')
            self.assertEqual(fresh['total_known_attempt_seconds'], '5.000')
            uncertain, = refresh_retry_times(path, [*records, attempt('no-terminal-production-clock')])
            self.assertEqual(uncertain['selected_pages_per_recorded_attempt_second'], '')
            self.assertEqual(uncertain['total_known_attempt_seconds'], '5.000')
            self.assertIsNone(refresh_retry_times(path, []))

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
