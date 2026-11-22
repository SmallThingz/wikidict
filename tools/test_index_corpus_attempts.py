import csv
from contextlib import chdir
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch


SCRIPT = Path(__file__).with_name('index_corpus_attempts.py').resolve()


class AttemptIndexTests(unittest.TestCase):
    def test_bootstrap_failure_requires_the_original_import_and_selected_module(self):
        from index_corpus_attempts import failed_builder_import
        with tempfile.TemporaryDirectory() as directory:
            script = Path(directory) / 'build_wiktionaries.py'
            body = b'from compress_blobs import compress, SHARD_BATCH_BYTES\n\ndef main():\n    pass\n'
            script.write_bytes(body)
            builder = dict(path=str(script), bytes=len(body), sha256=hashlib.sha256(body).hexdigest())
            helper = str(script.with_name('compress_blobs.py'))
            modules = {'compress_blobs': {'path': helper}}
            error = (f'Traceback (most recent call last):\n  File "{script}", line 1, in <module>\n'
                     f'    from compress_blobs import compress, SHARD_BATCH_BYTES\n'
                     f"ImportError: cannot import name 'SHARD_BATCH_BYTES' from 'compress_blobs' ({helper})\n").encode()
            self.assertTrue(failed_builder_import(error, builder, modules))
            for other in (error.replace(b'line 1', b'line 3'), error.replace(b'in <module>', b'in main'),
                          error.replace(f'({helper})'.encode(), b'(/other.py)'), b''):
                self.assertFalse(failed_builder_import(other, builder, modules))
            script.write_bytes(body + b'# changed\n')
            self.assertFalse(failed_builder_import(error, builder, modules))

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
                       input_selection=False, guard_selector=True, selected_manifest=None, cleanup=True,
                       snapshot=None, guard_snapshot=True, bootstrap_copy=None, snapshot_context=None, extra_refs=(),
                       input_selection_key='input_selection', direct_catalog=False):
                command = dict(argv=argv + list(extra), cwd=str(workspace), env={},
                    source_refs=[builder], current_python_catalog=catalog_ref, qualification_root=str(run))
                if selected_catalog:
                    selection = record(root / 'selection.json', dict(python_tooling=command.pop('current_python_catalog')))
                    command.update(selection=selection, source_refs=[builder, selection, catalog_ref])
                if direct_catalog:
                    command['python_tooling'] = command.pop('current_python_catalog')
                if input_selection:
                    command.pop('current_python_catalog')
                    inputs = dict(snapshots={'language-registry': snapshot}) if snapshot else dict(manifest=selected_manifest or manifest)
                    if snapshot_context:
                        inputs.update(snapshot_context)
                    selection = record(root / 'inputs.json', inputs)
                    command.update(input_step='ordinary_whole', source_refs=[builder, selection, manifest])
                    command[input_selection_key] = selection
                    if snapshot:
                        command['input_step'] = 'whole build using the sealed worker'
                        command['source_refs'][1] = dict(selection, mode=0o644)
                        if guard_snapshot:
                            command['source_refs'].append(snapshot)
                    if guard_selector:
                        command['source_refs'].append(selector)
                    if bootstrap_copy:
                        guarded, selected = bootstrap_copy
                        modules = {**catalog['modules'], Path(selected['path']).stem: selected}
                        command['argv'][command['argv'].index('--python-tooling-json') + 1] = json.dumps({**catalog, 'modules': modules})
                        command['source_refs'].insert(0, guarded)
                command['source_refs'].extend(extra_refs)
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
            direct_refs = [selector, manifest, catalog_ref]
            freeze(direct_catalog=True, extra_refs=direct_refs)
            self.assertEqual(read_execution(base, path, guardian=True)['production_seconds'], '2.500')
            for ref in direct_refs:
                freeze(direct_catalog=True, extra_refs=[r for r in direct_refs if r != ref])
                with self.assertRaises(ValueError):
                    read_execution(base, path, guardian=True)
            freeze(('--site-info-snapshot', str(root / 'other')), direct_catalog=True, extra_refs=direct_refs)
            with self.assertRaisesRegex(ValueError, 'Unguarded snapshot'):
                read_execution(base, path, guardian=True)
            for key in ('input_selection', 'selection'):
                with self.subTest(input_selection_key=key):
                    ordinary = dict(input_selection=True, input_selection_key=key)
                    freeze(**ordinary)
                    self.assertEqual(read_execution(base, path, guardian=True)['production_seconds'], '2.500')
                    freeze(**ordinary, guard_selector=False)
                    with self.assertRaisesRegex(ValueError, 'Unguarded Python catalog member'):
                        read_execution(base, path, guardian=True)
                    freeze(**ordinary, selected_manifest=record(root / 'unselected.json', b'{}'))
                    with self.assertRaisesRegex(ValueError, 'Selected input manifest differs'):
                        read_execution(base, path, guardian=True)
            snapshot = record(root / 'languages.tsv', b'Sesotho\tst\n')
            flags = ('--exact-snapshot-selection', '--language-registry-snapshot', snapshot['path'])
            freeze(flags, input_selection=True, snapshot=snapshot)
            self.assertEqual(read_execution(base, path, guardian=True)['production_seconds'], '2.500')
            context = dict(edition='blkwiktionary', date='20261001', normal_resolution_validated=True)
            freeze(flags, input_selection=True, snapshot=snapshot, snapshot_context=context)
            self.assertEqual(read_execution(base, path, guardian=True)['production_seconds'], '2.500')
            for changed in (dict(edition='enwiktionary'), dict(date='20260901'),
                            dict(normal_resolution_validated=1), dict(unrecognized=True)):
                freeze(flags, input_selection=True, snapshot=snapshot, snapshot_context={**context, **changed})
                with self.assertRaises(ValueError):
                    read_execution(base, path, guardian=True)
            disk = record(root / 'build_disk_limits.py', b'disk helper')
            key = hashlib.sha256(disk['path'].encode()).hexdigest()[:16]
            alias = run.parent / 'guarded-source-aliases01' / f'source-{key}.py'
            alias.parent.mkdir()
            alias.symlink_to(disk['path'])
            freeze(flags, input_selection=True, snapshot=snapshot, snapshot_context=context,
                   bootstrap_copy=(dict(disk, path=str(alias)), disk))
            self.assertEqual(read_execution(base, path, guardian=True)['production_seconds'], '2.500')
            alias.unlink()
            alias.write_bytes(b'disk helper')
            with self.assertRaisesRegex(ValueError, 'Unguarded Python catalog member'):
                read_execution(base, path, guardian=True)
            alias.unlink()
            other = record(root / 'other.py', b'disk helper')
            alias.symlink_to(other['path'])
            with self.assertRaisesRegex(ValueError, 'Unguarded Python catalog member'):
                read_execution(base, path, guardian=True)
            for options, guarded in [(flags, False), (flags[:-1] + ('different.tsv',), True),
                                     (flags + flags[1:], True), (flags[:1], True)]:
                freeze(options, input_selection=True, snapshot=snapshot, guard_snapshot=guarded)
                with self.assertRaisesRegex(ValueError, 'Guarded snapshots differ'):
                    read_execution(base, path, guardian=True)
            interwiki = record(root / 'interwiki.tsv', b'interwiki')
            stage = root / 'worker' / 'input'
            stage.mkdir(parents=True)
            marker = record(stage / '.complete.json', {})
            roles = record(root / 'roles.json', {})
            initial = record(root / 'initial.json', {})
            source_alias = stage.parent / 'expander' / '.bundle-expander' / 'interwiki-map.tsv'
            source_alias.parent.mkdir(parents=True)
            source_alias.symlink_to(interwiki['path'])
            staged = dict(staged_input_root=str(stage), staged_completion=marker, roles=roles,
                          initial_generation=initial, interwiki=interwiki, original_inputs=manifest)
            staged_args = (*flags, '--interwiki-map-snapshot', interwiki['path'], '--staged-input-root', str(stage),
                           '--retained-native-roles-ref', json.dumps(roles))
            staged_auth = dict(input_selection=True, snapshot=snapshot, snapshot_context=staged,
                               extra_refs=(roles, marker, initial, dict(interwiki, path=str(source_alias))))
            freeze(staged_args, **staged_auth)
            self.assertEqual(read_execution(base, path, guardian=True)['production_seconds'], '2.500')
            source_alias.unlink()
            source_alias.write_bytes(Path(interwiki['path']).read_bytes())
            with self.assertRaisesRegex(ValueError, 'Unguarded staged snapshot'):
                read_execution(base, path, guardian=True)
            for changed in (dict(roles=initial), dict(staged_input_root=str(root))):
                freeze(staged_args, **{**staged_auth, 'snapshot_context': {**staged, **changed}})
                with self.assertRaisesRegex(ValueError, 'Different staged worker'):
                    read_execution(base, path, guardian=True)
            plan = dict(manifest=manifest, snapshots={'language-registry': snapshot}, interwiki=interwiki,
                        indexed_pages=4000, shard_pages=200, presentation_audit_pages=50, normal_input_validation_pending=True)
            original = record(root / 'whole-inputs.json', plan)
            deferred = dict(context, normal_resolution_validated=False, input_validation_deferred_to_normal_whole=True,
                            original_input_selection=original, indexed_pages=4000, shard_pages=200,
                            snapshots={**plan['snapshots'], 'interwiki-map': interwiki})
            options = (*flags, '--interwiki-map-snapshot', interwiki['path'], '--shard-pages', '200', '--presentation-audit-pages', '50')
            auth = dict(input_selection=True, snapshot=snapshot, snapshot_context=deferred, extra_refs=[original, interwiki])
            freeze(options, **auth)
            with self.assertRaisesRegex(ValueError, 'lacks an ordered snapshot check'):
                read_execution(base, path, guardian=True)
            preflight = dict(edition='blkwiktionary', date='20261001', phase='selected_snapshot_resolution', scope='pre_edition')
            stdout = record(run / 'tests.stdout', b''.join(b'BUILD_PHASE ' + json.dumps({**preflight, **event}).encode() + b'\n'
                            for event in [dict(event='start'), dict(event='end', status='failure')]))
            freeze(options, **auth, exit_code=2, watchdog_code=2, detached=True)
            row = read_execution(base, path, guardian=True)
            self.assertEqual((row['production_status'], row['production_seconds'], row['closure_join']),
                             ('failed-before-production', '', 'original-terminal-unknown'))
            freeze((*options[:-1], '51'), **auth, exit_code=2, watchdog_code=2)
            with self.assertRaisesRegex(ValueError, 'Deferred whole-edition plan differs'):
                read_execution(base, path, guardian=True)

            def render_events(events):
                return b''.join(b'BUILD_PHASE ' + json.dumps(event).encode() + b'\n' for event in events)

            resolved = [{**preflight, 'event': 'start'}, {**preflight, 'event': 'end', 'status': 'success', 'seconds': 1}]
            started = {**phase, 'event': 'start'}
            published = [{**phase, 'phase': 'publish', 'event': 'start'},
                         {**phase, 'phase': 'publish', 'event': 'end', 'status': 'success'}]
            finished = {**phase, 'event': 'end', 'status': 'success', 'seconds': 2.5,
                        'execution_mode': 'pipeline_run_may_reuse_verified_inputs_or_shards'}
            target = root / 'output/blkwiktionary/20261001/complete.json'
            target.parent.mkdir(parents=True)
            metadata = dict(edition='blkwiktionary', date='20261001', input_pages=4000, status='built')
            record(target, metadata)
            valid = [*resolved, started, *published, finished]
            stdout = record(run / 'tests.stdout', render_events(valid))
            freeze(options, **auth)
            self.assertEqual(read_execution(base, path, guardian=True)['production_seconds'], '2.500')
            record(target, {**metadata, 'input_pages': 50})
            with self.assertRaisesRegex(ValueError, 'output differs'):
                read_execution(base, path, guardian=True)
            record(target, metadata)
            for invalid in ([*resolved, started, finished], [started, *resolved, *published, finished],
                            [*resolved, *resolved, started, *published, finished],
                            [*resolved, *published, started, finished],
                            [*valid[:-1], {**finished, 'execution_mode': 'existing_output'}]):
                stdout = record(run / 'tests.stdout', render_events(invalid))
                freeze(options, **auth)
                with self.assertRaises(ValueError):
                    read_execution(base, path, guardian=True)
            stdout = record(run / 'tests.stdout', render_events([*resolved, started]))
            freeze(options, **auth, exit_code=2, watchdog_code=2)
            self.assertEqual(read_execution(base, path, guardian=True)['production_status'], 'no-terminal-production-clock')
            stdout = record(run / 'tests.stdout', render_events([*resolved, started, {**finished, 'status': 'failure'}]))
            freeze(options, **auth, exit_code=2, watchdog_code=2)
            self.assertEqual(read_execution(base, path, guardian=True)['production_status'], 'failure')
            stdout = record(run / 'tests.stdout', log)
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
            private = root / 'private'
            private.mkdir()
            owner_module = record(root / 'build_resource_limits.py', b'limits')
            private_module = record(private / 'build_resource_limits.py', b'limits')
            copies = owner_module, private_module
            stdout = record(run / 'tests.stdout', render_events(valid))
            freeze(options, **auth, bootstrap_copy=copies)
            self.assertEqual(read_execution(base, path, guardian=True)['production_seconds'], '2.500')
            stdout = record(run / 'tests.stdout', b'')
            freeze(input_selection=True, bootstrap_copy=copies, exit_code=2, watchdog_code=2)
            self.assertEqual(read_execution(base, path, guardian=True)['production_status'], 'no-terminal-production-clock')
            (private / 'build_resource_limits.py').write_bytes(b'edited')
            with self.assertRaisesRegex(ValueError, 'build_resource_limits.py'):
                read_execution(base, path, guardian=True)
            (private / 'build_resource_limits.py').write_bytes(b'limits')
            freeze(input_selection=True, bootstrap_copy=copies)
            with self.assertRaisesRegex(ValueError, 'Unguarded Python catalog member'):
                read_execution(base, path, guardian=True)
            freeze(detached=True, exit_code=1, watchdog_code=1, selected_catalog=True)
            row = read_execution(base, path, guardian=True)
            self.assertEqual(row['command_exit'], 1)
            self.assertEqual(row['closure_join'], 'original-terminal-unknown')
            self.assertEqual(row['production_status'], 'no-terminal-production-clock')
            for program, expected in ((b'builder.py', 'failed-before-production'), (b'other', 'no-terminal-production-clock')):
                stderr = record(run / 'tests.stderr', b'usage: builder.py [-h]\n' + program + b': error: invalid role\n')
                freeze(exit_code=2, watchdog_code=2, selected_catalog=True)
                self.assertEqual(read_execution(base, path, guardian=True)['production_status'], expected)
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
            # The same explicitly named run can also belong to the selected family.
            # Authenticate its real log once and preserve the existing output inode.
            import index_corpus_attempts as indexer
            overlap = [str(SCRIPT), '--receipts', str(root / 'receipts'), '--output', str(index),
                       '--add', 'example', '--add-closure', str(legacy)]
            with chdir(root), patch.object(sys, 'argv', overlap), patch.object(indexer, 'read_execution', wraps=indexer.read_execution) as read:
                indexer.main()
            read.assert_called_once_with(root / 'receipts', legacy)
            self.assertEqual((index.read_bytes(), index.stat().st_ino), before)
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
