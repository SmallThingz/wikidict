"""Pure controller controls; no builder, provider, or native process is invoked."""
import copy
from contextlib import contextmanager
import json
import os
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock

import corpus_controller as controller

AN14_REVIEWED_ALIASES = [['it', 'Italián'], ['scn', 'Secilián'], ['scn', 'secilián'], ['pl', 'Polonés'], ['be', 'Belarruso'], ['eu', 'Vasco'], ['fi', 'Finlandés'], ['fi', 'Suomen kieli'], ['nci', 'Náhuatl clásico'], ['nci', 'Nahuatlahtolli'], ['mul', 'Internacional'], ['mul', 'internacional'], ['ms', 'Bahasa Melayu بهاس ملايو'], ['fr', 'Franzés']]

FRESH = 'pipeline_run_may_reuse_verified_inputs_or_shards'


def attempt(identity, sequence, edition='enwiktionary', seconds=2.0,
            accepted=True, mode=FRESH, pages=10):
    return dict(attempt_id=identity, sequence=sequence, edition=edition,
                elapsed_seconds=seconds, execution_mode=mode,
                outcome='accepted' if accepted else 'failed',
                accepted=dict(input_pages=pages) if accepted else None)


def all_editions():
    return list(controller.PILOT) + ['enwiktionary'] + [f'toy{i:03d}wiktionary' for i in range(189)]


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, sort_keys=True) + '\n')


class LaunchHandoffTests(unittest.TestCase):
    @contextmanager
    def launch_workspace(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            for name in ('.tmp', 'data/build-resources', 'data/runtime'):
                (root / name).mkdir(parents=True, exist_ok=True)
            locks = []
            for path in (root / 'data/build-resources/corpus-controller.lock',
                         root / '.tmp/build-resources.lock'):
                path.touch()
                st = path.stat()
                locks.append(dict(path=str(path), device=st.st_dev, inode=st.st_ino))
            with mock.patch.object(controller, 'ROOT', root):
                yield root, locks

    def test_binder_locks_feed_actual_admission_and_owner_creates_missing_runtime(self):
        import build_resource_limits as limits
        with self.launch_workspace() as (root, locks):
            runtime = str(root / 'data/runtime/new-launch')
            original = copy.deepcopy(locks)
            prepared = controller.normalize_launch_handoff({}, locks=locks, runtime=runtime)
            self.assertFalse(Path(runtime).exists())
            self.assertEqual(locks, original)
            with self.assertRaises(FileNotFoundError):
                (Path(runtime) / 'start.json').open('x')
            created = controller.normalize_launch_handoff({}, locks=prepared['locks'],
                runtime=runtime, create_runtime=True)
            self.assertEqual(prepared, created)
            with (Path(runtime) / 'start.json').open('x') as stream:
                stream.write('{}\n')
            host = mock.Mock()
            host.admission_reason.return_value = None
            host.sample.return_value = {}
            fds, _ = limits.wait_for_build_admission(deadline_unix=controller.time.time() + 2,
                locks=created['locks'], host_observation=host, final_guard=lambda: None,
                record_refusal=lambda *_: self.fail('Unexpected admission refusal'), once=True)
            for fd in fds:
                os.close(fd)
            with self.assertRaisesRegex(ValueError, 'already exists'):
                controller.normalize_launch_handoff({}, locks=locks, runtime=runtime,
                    create_runtime=True)
            self.assertEqual((Path(runtime) / 'start.json').read_text(), '{}\n')

    def test_lock_schema_and_identity_refusals_precede_runtime_creation(self):
        with self.launch_workspace() as (root, locks):
            runtime = str(root / 'data/runtime/new-launch')
            bad_rows = []
            for change in ({'inode': locks[0]['inode'] + 1}, {'inode': True},
                           {'path': str(root / 'other.lock')}, {'extra': 1}):
                bad = copy.deepcopy(locks)
                bad[0].update(change)
                bad_rows.append(bad)
            bad_rows.extend([locks[:1], [locks[0], dict(path=locks[1]['path'],
                dev=locks[1]['device'], ino=locks[1]['inode'])]])
            for bad in bad_rows:
                with self.subTest(locks=bad), self.assertRaises(ValueError):
                    controller.normalize_launch_handoff({}, locks=bad, runtime=runtime,
                        create_runtime=True)
                self.assertFalse(Path(runtime).exists())
            path = Path(locks[0]['path'])
            path.rename(path.with_suffix('.old'))
            path.touch()
            with self.assertRaisesRegex(ValueError, 'identity changed'):
                controller.normalize_launch_handoff({}, locks=locks, runtime=runtime,
                    create_runtime=True)
            self.assertFalse(Path(runtime).exists())

    def test_runtime_refuses_noncanonical_missing_parent_and_symlink_paths(self):
        with self.launch_workspace() as (root, locks):
            (root / 'data/link').symlink_to(root / 'data/runtime', target_is_directory=True)
            bad_paths = ['data/runtime/new', str(root / 'data') + '/runtime/../new',
                         str(root / 'src/new'), str(root / 'data/link/new'),
                         str(root / 'data/missing-parent/new'), str(root / 'data')]
            for runtime in bad_paths:
                with self.subTest(runtime=runtime), self.assertRaises((ValueError, FileNotFoundError)):
                    controller.normalize_launch_handoff({}, locks=locks, runtime=runtime,
                        create_runtime=True)
            self.assertEqual(list((root / 'data/runtime').iterdir()), [])


class ControllerPureTests(unittest.TestCase):
    def test_pilot_then_english_then_remaining_order_and_duplicate_refusal(self):
        editions = all_editions()
        actual = controller.edition_order(list(reversed(editions)))
        self.assertEqual(list(controller.PILOT) + ['enwiktionary'], actual[:9])
        self.assertEqual(sorted(editions[9:]), actual[9:])
        self.assertEqual(['arwiktionary', 'enwiktionary', 'zzwiktionary'],
                         controller.edition_order(['zzwiktionary', 'enwiktionary', 'arwiktionary']))
        with self.assertRaisesRegex(ValueError, 'Duplicate editions'):
            controller.edition_order(['enwiktionary', 'enwiktionary'])

    def test_only_watchdog_memory_termination_lowers_workers(self):
        memory = {'termination_reason': 'sampled_pss_limit'}
        self.assertEqual(2, controller.next_workers(4, memory))
        self.assertEqual(1, controller.next_workers(2, memory))
        self.assertIsNone(controller.next_workers(1, memory))
        self.assertIsNone(controller.next_workers(3, memory))
        for reason in ['child_exit', 'wall_timeout', 'running', None]:
            for text in ['', 'error: OutOfMemory', 'title=MemoryError: an ordinary entry',
                         'OutOfMemory mentioned in a non-memory parser failure']:
                with self.subTest(reason=reason, text=text):
                    self.assertIsNone(controller.next_workers(4, {'termination_reason': reason}, text))

    def test_phase_end_matches_exact_edition_date_phase_and_event(self):
        wanted = dict(edition='enwiktionary', date='20261001', phase='edition_build', event='end',
                      status='success', execution_mode=FRESH)
        wrong = [dict(wanted, edition='arwiktionary'), dict(wanted, date='20260901'),
                 dict(wanted, phase='expander_build'), dict(wanted, event='start')]
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'build.log'
            path.write_text('ordinary noise\nBUILD_PHASE {broken\n' +
                            ''.join('BUILD_PHASE ' + json.dumps(x) + '\n' for x in wrong))
            self.assertIsNone(controller.phase_end(path, 'enwiktionary', '20261001'))
            with path.open('a') as stream:
                stream.write('BUILD_PHASE ' + json.dumps(wanted) + '\n')
            self.assertEqual(wanted, controller.phase_end(path, 'enwiktionary', '20261001'))
            with path.open('a') as stream:
                stream.write('BUILD_PHASE ' + json.dumps(wanted) + '\n')
            with self.assertRaisesRegex(ValueError, 'More than one edition completion'):
                controller.phase_end(path, 'enwiktionary', '20261001')

    def test_summary_charges_each_attempt_once_and_rejects_conflicting_identity(self):
        failed = attempt('a1', 1, seconds=10, accepted=False)
        passed = attempt('a2', 2, seconds=20, pages=100)
        result = controller.summarize([passed, failed, copy.deepcopy(passed)], ['enwiktionary'])
        row = result['editions'][0]
        self.assertEqual(2, row['attempt_count'])
        self.assertEqual(30, row['observed_build_seconds'])
        self.assertEqual(100, result['accepted_cohort_input_pages'])
        self.assertFalse(result['historical_timings_reconstructed'])
        self.assertIsNone(result['lost_historical_seconds'])
        with self.assertRaisesRegex(ValueError, 'Conflicting attempt identity'):
            controller.summarize([passed, dict(passed, elapsed_seconds=21)], ['enwiktionary'])

    def test_latest_failure_hides_previous_acceptance_without_erasing_time(self):
        passed = attempt('a1', 1, seconds=20, pages=100)
        failed = attempt('a2', 2, seconds=3, accepted=False, mode='existing_output')
        result = controller.summarize([failed, passed], ['enwiktionary'])
        row = result['editions'][0]
        self.assertIsNone(row['accepted'])
        self.assertEqual(20, row['observed_build_seconds'])
        self.assertEqual(3, row['verification_seconds'])
        self.assertEqual(0, result['accepted_cohort_input_pages'])
        self.assertIsNone(result['final_observed_pages_per_second'])

    def test_verification_time_is_separate_and_does_not_invent_original_build_time(self):
        verify = attempt('verify', 2, seconds=3, mode='existing_output', pages=100)
        alone = controller.summarize([verify], ['enwiktionary'])
        row = alone['editions'][0]
        self.assertEqual(0, row['observed_build_seconds'])
        self.assertEqual(3, row['verification_seconds'])
        self.assertTrue(row['original_build_time_unknown'])
        self.assertEqual(['enwiktionary'], alone['unknown_timing_editions'])
        built = attempt('build', 1, seconds=20, pages=100)
        combined = controller.summarize([verify, built, copy.deepcopy(verify)], ['enwiktionary'])
        row = combined['editions'][0]
        self.assertEqual(20, row['observed_build_seconds'])
        self.assertEqual(3, row['verification_seconds'])
        self.assertFalse(row['original_build_time_unknown'])
        self.assertEqual(2, row['attempt_count'])

    def test_final_rate_requires_all_198_current_acceptances_and_excludes_original_seven(self):
        editions = all_editions()
        rows = [attempt(str(i), i, edition=e, seconds=999 if e in controller.EXCLUDED else 2)
                for i, e in enumerate(editions)]
        result = controller.summarize(rows, editions)
        self.assertTrue(result['final_cohort_complete'])
        self.assertEqual(191, result['accepted_cohort_editions'])
        self.assertEqual(1910, result['accepted_cohort_input_pages'])
        self.assertEqual(382, result['observed_cohort_seconds'])
        self.assertEqual(5, result['final_observed_pages_per_second'])
        excluded = [r for r in result['editions'] if r['timing_excluded']]
        self.assertEqual(set(controller.EXCLUDED), {r['edition'] for r in excluded})
        self.assertTrue(all(r['observed_build_seconds'] is None and r['verification_seconds'] is None for r in excluded))
        # Even a timing-excluded original edition still needs a fresh acceptance.
        incomplete = controller.summarize(rows[1:], editions)
        self.assertEqual(191, incomplete['accepted_cohort_editions'])
        self.assertFalse(incomplete['final_cohort_complete'])
        self.assertIsNone(incomplete['final_observed_pages_per_second'])

    def test_mixed_known_unknown_retries_preserve_known_subtotal_across_editions(self):
        editions=all_editions()
        rows=[attempt('initial-'+edition,i+1,edition=edition,seconds=2,pages=10) for i,edition in enumerate(editions)]
        rows.extend([attempt('en-interrupted',199,seconds=None,accepted=False),
                     attempt('en-retry',200,seconds=7,pages=10),
                     attempt('ar-failed',201,edition='arwiktionary',seconds=3,accepted=False),
                     attempt('ar-retry',202,edition='arwiktionary',seconds=5,pages=10),
                     attempt('en-verify',203,seconds=11,pages=10,mode='existing_output'),
                     attempt('aa-unknown-excluded',204,edition='aawiktionary',seconds=None,accepted=False),
                     attempt('aa-retry-excluded',205,edition='aawiktionary',seconds=999,pages=10)])
        for row in rows:row['controller_elapsed_seconds']=1000000
        result=controller.summarize(rows,editions)
        by_edition={row['edition']:row for row in result['editions']}
        self.assertEqual(by_edition['enwiktionary']['known_production_seconds'],9)
        self.assertIsNone(by_edition['enwiktionary']['observed_build_seconds'])
        self.assertEqual(by_edition['enwiktionary']['verification_seconds'],11)
        self.assertEqual(by_edition['arwiktionary']['known_production_seconds'],10)
        self.assertEqual(by_edition['arwiktionary']['observed_build_seconds'],10)
        self.assertIsNone(by_edition['aawiktionary']['known_production_seconds'])
        self.assertEqual(result['known_cohort_build_seconds'],397)
        self.assertEqual(result['known_cohort_seconds'],397)
        self.assertIsNone(result['observed_cohort_build_seconds'])
        self.assertIsNone(result['observed_cohort_seconds'])
        self.assertEqual(result['unknown_timing_editions'],['enwiktionary'])
        self.assertTrue(result['final_cohort_complete'])
        self.assertEqual(result['accepted_cohort_input_pages'],1910)
        self.assertIsNone(result['final_observed_pages_per_second'])

    def test_unknown_build_interval_blocks_rate_without_discarding_acceptance(self):
        editions = all_editions()
        rows = [attempt(str(i), i, edition=e) for i, e in enumerate(editions)]
        rows[8]['elapsed_seconds'] = None  # English, in the measured cohort.
        result = controller.summarize(rows, editions)
        self.assertTrue(result['final_cohort_complete'])
        self.assertEqual(['enwiktionary'], result['unknown_timing_editions'])
        self.assertIsNone(result['final_observed_pages_per_second'])
        self.assertIsNotNone(next(r for r in result['editions'] if r['edition'] == 'enwiktionary')['accepted'])

    def test_invalid_build_intervals_and_unconfigured_editions_are_refused(self):
        for seconds in [-1, float('nan'), float('inf'), True, '2']:
            with self.subTest(seconds=seconds), self.assertRaisesRegex(ValueError, 'Invalid interval'):
                controller.summarize([attempt('a', 1, seconds=seconds)], ['enwiktionary'])
        with self.assertRaisesRegex(ValueError, 'Attempt outside configured corpus'):
            controller.summarize([attempt('a', 1)], ['arwiktionary'])


    def test_retained_tl_mon_phase_times_exclude_controller_wall_and_keep_unknown(self):
        def retained(identity, sequence, edition, wall, seconds, accepted):
            row = attempt(identity, sequence, edition, seconds=wall, accepted=accepted)
            row['timing_authority'] = 'actual controller monotonic interval around joined tracked CLI'
            row['edition_build'] = (dict(edition=edition, date='20261001', phase='edition_build',
                event='end', status='success' if accepted else 'failure', seconds=seconds)
                if seconds is not None else None)
            return row
        tl = retained('tl', 1, 'tlwiktionary', 242.23714185500285, 238.341, True)
        mon_disk = retained('mon-disk', 2, 'mnwwiktionary', 628.3383523279917, None, False)
        mon_writer = retained('mon-writer', 3, 'mnwwiktionary', 1373.5042524439923, 1354.011, False)
        rows = [tl, mon_disk, mon_writer, copy.deepcopy(mon_writer)]
        before = copy.deepcopy(rows)
        summary = controller.summarize(rows, ['tlwiktionary', 'mnwwiktionary'])
        by_edition = {row['edition']: row for row in summary['editions']}
        self.assertEqual(by_edition['tlwiktionary']['known_production_seconds'], 238.341)
        self.assertEqual(by_edition['mnwwiktionary']['known_production_seconds'], 1354.011)
        self.assertEqual(by_edition['mnwwiktionary']['attempt_count'], 2)
        self.assertIsNone(by_edition['mnwwiktionary']['observed_build_seconds'])
        self.assertEqual(summary['unknown_timing_editions'], ['mnwwiktionary'])
        self.assertAlmostEqual(summary['known_cohort_build_seconds'], 1592.352)
        self.assertIsNone(summary['observed_cohort_seconds'])
        self.assertIsNone(summary['final_observed_pages_per_second'])
        self.assertEqual(rows, before)

    def test_legacy_controller_only_interval_is_unknown_without_phase(self):
        row = attempt('legacy-controller', 1, seconds=300)
        row['timing_authority'] = 'actual controller monotonic interval around joined tracked CLI'
        summary = controller.summarize([row], ['enwiktionary'])
        self.assertEqual(summary['known_cohort_build_seconds'], 0)
        self.assertEqual(summary['unknown_timing_editions'], ['enwiktionary'])
        self.assertIsNone(summary['observed_cohort_seconds'])
        self.assertIsNotNone(summary['editions'][0]['accepted'])

    def test_retained_existing_output_phase_counts_only_verification(self):
        row = attempt('legacy-verify', 1, seconds=8, mode='existing_output')
        row['timing_authority'] = 'actual controller monotonic interval around joined tracked CLI'
        row['edition_build'] = dict(edition='enwiktionary', phase='edition_build', event='end',
                                   execution_mode='existing_output', seconds=3.25)
        summary = controller.summarize([row], ['enwiktionary'])
        self.assertEqual(summary['known_cohort_build_seconds'], 0)
        self.assertEqual(summary['editions'][0]['verification_seconds'], 3.25)
        self.assertTrue(summary['editions'][0]['original_build_time_unknown'])

    def test_noncampaign_execute_records_phase_and_separate_controller_time(self):
        cases = [('tlwiktionary', 238.341, True, True, FRESH),
                 ('mnwwiktionary', 1354.011, True, False, FRESH),
                 ('mnwwiktionary', None, True, False, FRESH),
                 ('mnwwiktionary', None, False, False, FRESH),
                 ('tlwiktionary', 3.25, True, True, 'existing_output')]
        for edition, seconds, started, success, mode in cases:
            with self.subTest(edition=edition, seconds=seconds, started=started, mode=mode), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp); cfg = ControllerMemoryPolicyTests().cfg(root)
                self.assertNotIn('campaign', cfg)
                folder = root / 'attempt'; code = 0 if success else 1
                process = mock.Mock(pid=900123); process.poll.return_value=code; process.wait.return_value=code
                start = dict(edition=edition, date='20261001', phase='edition_build', event='start')
                end = dict(start, event='end', status='success' if success else 'failure', seconds=seconds, execution_mode=mode)
                def spawn(*args, **kwargs):
                    write_json(Path(kwargs['cwd'])/'.tmp/build-watchdog-report.json', dict(termination_reason='child_exit',
                        child_exit_status=code, guardian_exit_status=0, memory_limit_bytes=controller.MEMORY))
                    if started:
                        kwargs['stdout'].write(('BUILD_PHASE '+json.dumps(start)+'\n').encode())
                    if seconds is not None:
                        kwargs['stdout'].write(('BUILD_PHASE '+json.dumps(end)+'\n').encode())
                    kwargs['stdout'].flush()
                    return process
                with mock.patch.object(controller, 'ROOT', root), \
                     mock.patch.object(controller.subprocess, 'Popen', side_effect=spawn), \
                     mock.patch.object(controller, 'process_identity', return_value=dict(pid=900123, start_time_ticks=1)), \
                     mock.patch.object(controller, 'watchdog_closed', return_value=True), \
                     mock.patch.object(controller, 'source_guard'), \
                     mock.patch.object(controller, 'accept', return_value=dict(input_pages=10)):
                    row, _ = controller.execute(cfg, edition, 4, folder, 1, 'context', [])
                self.assertEqual(controller.read_json(folder/'result.json'), row)
                self.assertEqual(row['elapsed_seconds'], seconds if started else 0.0)
                self.assertGreaterEqual(row['controller_elapsed_seconds'], 0)
                self.assertEqual(row['production_started'], started and mode != 'existing_output')
                self.assertEqual(row['production_elapsed_seconds'], seconds if started and mode != 'existing_output' else None)
                self.assertEqual(row['verification_elapsed_seconds'], seconds if mode == 'existing_output' else None)
                self.assertEqual(row['accepted'] is not None, success)


class ControllerHistoryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.state = Path(self.temp.name) / 'state'
        self.folder = self.state / 'attempts' / '000001-toy'
        self.context = {'source': 'tiny-current-source', 'inputs': 'tiny-current-inputs'}
        self.owner = dict(pid=900001, start_time_ticks=101)
        self.launch = dict(pid=900002, start_time_ticks=102)
        self.child = dict(pid=900003, start_time_ticks=103)
        self.guardian = dict(pid=900004, start_time_ticks=104)
        self.start = dict(attempt_id='000001-toy', sequence=1, edition='enwiktionary',
                          context=self.context, controller=self.owner)
        write_json(self.folder / 'start.json', self.start)
        write_json(self.folder / 'launch.json', {'identity': self.launch})
        self.watchdog = dict(termination_reason='child_exit', child_pid=self.child['pid'],
                            child_start_time_ticks=self.child['start_time_ticks'],
                            guardian_pid=self.guardian['pid'], guardian_start_time_ticks=self.guardian['start_time_ticks'],
                            elapsed_seconds=8.5, child_exit_status=0, guardian_exit_status=0, error=None)

    def write_watchdog(self):
        write_json(self.folder / '.tmp' / 'build-watchdog-report.json', self.watchdog)

    def test_completed_history_reuses_authenticated_snapshot_without_rewriting_receipts(self):
        snapshot = self.folder / 'complete.snapshot.json'
        write_json(snapshot, {'input_pages': 10, 'publication': 'tiny'})
        row = attempt(self.start['attempt_id'], 1)
        row['accepted']['complete_snapshot'] = controller.descriptor(snapshot)
        terminal = self.folder / 'result.json'
        write_json(terminal, row)
        original = terminal.read_bytes()
        with mock.patch.object(controller, 'process_identity', side_effect=AssertionError('No live process query for completed history')):
            first = controller.history(self.state, self.context)
            second = controller.history(self.state, self.context)
        self.assertEqual([row], first)
        self.assertEqual(first, second)
        self.assertEqual(original, terminal.read_bytes())
        self.assertEqual(1, controller.summarize(first + second, ['enwiktionary'])['editions'][0]['attempt_count'])
        snapshot.write_text('{"input_pages": 11}\n')
        with self.assertRaisesRegex(ValueError, 'Receipt bytes changed'):
            controller.history(self.state, self.context)

    def test_interrupted_history_records_unknown_parent_time_once_without_acceptance(self):
        self.write_watchdog()
        with mock.patch.object(controller, 'process_identity', return_value=None):
            first = controller.history(self.state, self.context)
            terminal = (self.folder / 'result.json').read_bytes()
            second = controller.history(self.state, self.context)
        self.assertEqual(first, second)
        self.assertEqual(terminal, (self.folder / 'result.json').read_bytes())
        row = first[0]
        self.assertEqual('interrupted', row['outcome'])
        self.assertIsNone(row['elapsed_seconds'])
        self.assertIsNone(row['exit_code'])
        self.assertIsNone(row['accepted'])
        self.assertEqual(8.5, row['watchdog_elapsed_seconds'])
        self.assertTrue(row['recovered'])
        summary = controller.summarize(first + second, ['enwiktionary'])
        self.assertEqual(1, summary['editions'][0]['attempt_count'])
        self.assertEqual(['enwiktionary'], summary['unknown_timing_editions'])

    def test_unfinished_history_refuses_live_owners_and_missing_or_running_watchdog(self):
        self.write_watchdog()
        for active in [self.owner, self.launch, self.child, self.guardian]:
            with self.subTest(active=active), mock.patch.object(controller, 'process_identity',
                    side_effect=lambda pid, active=active: active if pid == active['pid'] else None):
                with self.assertRaises(ValueError):
                    controller.history(self.state, self.context)
                self.assertFalse((self.folder / 'result.json').exists())
        with mock.patch.object(controller, 'process_identity', return_value=None):
            self.watchdog['termination_reason'] = 'running'
            self.write_watchdog()
            with self.assertRaisesRegex(ValueError, 'Watchdog terminal missing'):
                controller.history(self.state, self.context)
            (self.folder / '.tmp' / 'build-watchdog-report.json').unlink()
            with self.assertRaisesRegex(ValueError, 'Unresolved attempt'):
                controller.history(self.state, self.context)
        self.assertFalse((self.folder / 'result.json').exists())

    def test_history_rejects_another_source_or_input_context(self):
        with self.assertRaisesRegex(ValueError, 'another source/input configuration'):
            controller.history(self.state, dict(self.context, source='different-current-source'))
        self.assertFalse((self.folder / 'result.json').exists())

    def test_retired_source78_migration_is_rejected_as_unsupported(self):
        cfg = dict(production_manifest_transition=dict(scope='source78-pilot-retry-time-only'))
        with self.assertRaisesRegex(ValueError, 'Explicit English-only history transition required'):
            controller.load_history_transition(cfg)


class ControllerLockTests(unittest.TestCase):
    def test_lock_persists_after_release_and_replaced_inode_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'locks' / 'controller.lock'
            with controller.Lock(path, True) as held:
                original = path.stat().st_ino
                held.check()
            self.assertTrue(path.is_file())
            self.assertEqual(original, path.stat().st_ino)
            with controller.Lock(path, True) as held:
                replacement = path.with_name('replacement.lock')
                replacement.write_bytes(b'')
                self.assertNotEqual(path.stat().st_ino, replacement.stat().st_ino)
                os.replace(replacement, path)
                with self.assertRaisesRegex(ValueError, 'removed or replaced'):
                    held.check()
            self.assertTrue(path.is_file())



class ControllerAdmissionTests(unittest.TestCase):
    def terminal(self):
        return dict(termination_reason='child_exit', child_pid=910001,
                    child_start_time_ticks=201, guardian_pid=910002,
                    guardian_start_time_ticks=202, child_exit_status=0,
                    guardian_exit_status=0, error=None)

    def test_watchdog_closure_requires_real_terminal_statuses_and_no_cleanup_error(self):
        with mock.patch.object(controller, 'process_identity', return_value=None):
            self.assertTrue(controller.watchdog_closed(self.terminal()))
            self.assertTrue(controller.watchdog_closed(dict(self.terminal(), child_exit_status=1)))
            for reason in [None, 'starting', 'running', 'monitor_error', 'cleanup_error', 'guardian_lost']:
                with self.subTest(reason=reason):
                    self.assertFalse(controller.watchdog_closed(dict(self.terminal(), termination_reason=reason)))
            for change in [dict(error='observer failed'), dict(guardian_exit_status=1),
                           dict(guardian_exit_status=None), dict(child_exit_status=None),
                           dict(child_exit_status='0'), dict(child_exit_status=True),
                           dict(child_pid='910001'), dict(guardian_start_time_ticks=None)]:
                with self.subTest(change=change):
                    self.assertFalse(controller.watchdog_closed(dict(self.terminal(), **change)))

    def test_explicit_cleanup_proof_preserves_operational_failure_and_all_identity_guards(self):
        terminal=dict(self.terminal(),cleanup_complete=True,termination_reason='disk_free_floor',
                      child_exit_status=-15,error='Disk free-space safety stop: fixture')
        with mock.patch.object(controller,'process_identity',return_value=None):
            self.assertTrue(controller.watchdog_closed(terminal))
            self.assertEqual(terminal['termination_reason'],'disk_free_floor')
            self.assertEqual(terminal['error'],'Disk free-space safety stop: fixture')
            self.assertIsNone(controller.next_resources(4,controller.MEMORY,terminal))
            for change in (dict(cleanup_complete=False),dict(cleanup_complete=1),
                           dict(child_exit_status=None),dict(guardian_exit_status=1),
                           dict(termination_reason='cleanup_error'),dict(termination_reason='guardian_lost')):
                with self.subTest(change=change):
                    self.assertFalse(controller.watchdog_closed(dict(terminal,**change)))
        for role in ('child','guardian'):
            live=dict(pid=terminal[role+'_pid'],start_time_ticks=terminal[role+'_start_time_ticks'])
            with self.subTest(role=role),mock.patch.object(controller,'process_identity',
                    side_effect=lambda pid,live=live:live if pid==live['pid'] else None):
                self.assertFalse(controller.watchdog_closed(terminal))

    def test_watchdog_closure_uses_pid_and_start_identity_without_pid_reuse_false_positive(self):
        terminal = self.terminal()
        for role in ['child', 'guardian']:
            live = dict(pid=terminal[role + '_pid'], start_time_ticks=terminal[role + '_start_time_ticks'])
            with self.subTest(role=role), mock.patch.object(controller, 'process_identity',
                    side_effect=lambda pid, live=live: live if pid == live['pid'] else None):
                self.assertFalse(controller.watchdog_closed(terminal))
        with mock.patch.object(controller, 'process_identity',
                side_effect=lambda pid: dict(pid=pid, start_time_ticks=999)):
            self.assertTrue(controller.watchdog_closed(terminal))

    def publication(self, directory, members=None):
        top = Path(directory)
        root = top / 'publication'
        payload = root / 'language.wikblb'
        root.mkdir()
        payload.write_bytes(b'tiny')
        complete = dict(input_pages=1, publication_files=members or {'language.wikblb': {'size': 4}})
        live = root / 'complete.json'
        snapshot = top / 'receipts' / 'complete.snapshot.json'
        write_json(live, complete)
        write_json(snapshot, complete)
        accepted = dict(root=str(root), input_pages=1,
                        complete=controller.descriptor(live),
                        complete_snapshot=controller.descriptor(snapshot))
        return accepted, payload, live, snapshot

    def test_publication_presence_authenticates_distinct_same_byte_receipts_without_payload_hashing(self):
        with tempfile.TemporaryDirectory() as directory:
            accepted, payload, live, snapshot = self.publication(directory)
            self.assertNotEqual(live, snapshot)
            self.assertEqual(live.read_bytes(), snapshot.read_bytes())
            original_digest = controller.digest
            def metadata_only(path):
                self.assertIn(Path(path), {live, snapshot}, 'Presence guard must not hash dictionary payloads')
                return original_digest(path)
            with mock.patch.object(controller, 'digest', side_effect=metadata_only):
                self.assertTrue(controller.publication_present(accepted))
                # This is deliberately only a presence/size guard. Actual byte
                # verification remains the tracked builder/release obligation.
                payload.write_bytes(b'else')
                self.assertTrue(controller.publication_present(accepted))

    def test_publication_presence_rejects_changed_mismatched_or_mislocated_completion(self):
        for change in ['live_changed', 'snapshot_changed', 'mismatched_authenticated_snapshot', 'wrong_live_location']:
            with self.subTest(change=change), tempfile.TemporaryDirectory() as directory:
                accepted, _, live, snapshot = self.publication(directory)
                if change == 'live_changed':
                    live.write_text(live.read_text() + ' ')
                elif change == 'snapshot_changed':
                    snapshot.write_text(snapshot.read_text() + ' ')
                elif change == 'mismatched_authenticated_snapshot':
                    body = json.loads(snapshot.read_text())
                    body['input_pages'] = 2
                    write_json(snapshot, body)
                    accepted['complete_snapshot'] = controller.descriptor(snapshot)
                else:
                    other = Path(directory) / 'other-complete.json'
                    other.write_bytes(live.read_bytes())
                    accepted['complete'] = controller.descriptor(other)
                self.assertFalse(controller.publication_present(accepted))

    def test_publication_presence_rejects_missing_resized_symlink_and_escaped_members(self):
        for change in ['missing', 'resized', 'member_symlink', 'root_symlink', 'parent_escape', 'absolute_member']:
            with self.subTest(change=change), tempfile.TemporaryDirectory() as directory:
                members = None
                if change == 'parent_escape':
                    members = {'../outside.wikblb': {'size': 4}}
                elif change == 'absolute_member':
                    members = {str(Path(directory) / 'outside.wikblb'): {'size': 4}}
                accepted, payload, _, _ = self.publication(directory, members)
                if change == 'missing':
                    payload.unlink()
                elif change == 'resized':
                    payload.write_bytes(b'wrong size')
                elif change == 'member_symlink':
                    target = Path(directory) / 'target.wikblb'
                    target.write_bytes(payload.read_bytes())
                    payload.unlink()
                    payload.symlink_to(target)
                elif change == 'root_symlink':
                    alias = Path(directory) / 'alias'
                    alias.symlink_to(Path(accepted['root']), target_is_directory=True)
                    accepted['root'] = str(alias)
                self.assertFalse(controller.publication_present(accepted))



class ControllerPreparationTests(unittest.TestCase):
    def config(self, root):
        root.mkdir(parents=True, exist_ok=True)
        cfg = dict(date='20261001', now_unix=1791731560, expansion_timeout_ms=60000)
        for name in ['source', 'manifest', 'compiler']:
            path = root / (name + '.json')
            write_json(path, {'toy_context': name})
            cfg[name] = controller.descriptor(path)
        return cfg

    def preparation(self, root, cfg, identity, outcome='passed', seconds=2,
                    edition='enwiktionary', result_changes=None, closure_changes=None):
        root.mkdir(parents=True, exist_ok=True)
        result = dict(schema='wikidict.corpus-production-preparation-result.v1',
                      preparation_id=identity, edition=edition, outcome=outcome,
                      accounting_scope='production-preparation', elapsed_seconds=seconds,
                      **{key: cfg[key] for key in ['source', 'manifest', 'compiler', 'date', 'now_unix', 'expansion_timeout_ms']})
        result.update(result_changes or {})
        result_path = root / 'result.json'
        write_json(result_path, result)
        result_ref = controller.descriptor(result_path)
        closed = dict(schema='wikidict.corpus-production-preparation-closure.v1',
                      result=result_ref, outcome=outcome + '-closed', cleanup_proven=True,
                      source_guard=True, remaining_owned_processes=[])
        closed.update(closure_changes or {})
        closure_path = root / 'closure.json'
        write_json(closure_path, closed)
        receipt_path = root / 'accounting.json'
        write_json(receipt_path, dict(schema='wikidict.corpus-production-preparation.v1',
                                     result=result_ref, closure=controller.descriptor(closure_path)))
        return controller.descriptor(receipt_path)

    def location_context(self, root, *, result_changes=None, closure_changes=None):
        old = self.config(root / 'context')
        relocated = root / 'selected-identical-manifest.json'
        relocated.write_bytes(Path(old['manifest']['path']).read_bytes())
        current = dict(old, manifest=controller.descriptor(relocated))
        receipt = self.preparation(root / 'prep', old, 'location-only', outcome='failed',
            seconds=7, edition='arwiktionary', result_changes=result_changes, closure_changes=closure_changes)
        value = controller.read_ref(receipt)
        value['manifest_transition'] = dict(from_manifest=old['manifest'], to_manifest=current['manifest'],
            from_manifest_snapshot=old['manifest'], scope='retained-production-time-only',
            runtime_reuse_credit=False, reason='Same authenticated manifest bytes at the selected ordinary path.',
            identical_manifest_content=True)
        path = root / 'location-accounting.json'; write_json(path, value)
        current['production_preparations'] = [controller.descriptor(path)]
        return old, current, value, path

    def test_identical_manifest_location_preserves_failed_arabic_interval_once(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory); old,cfg,value,path=self.location_context(root)
            original=Path(value['result']['path']).read_bytes()
            cfg['production_preparations'] *= 2
            rows=controller.load_preparations(cfg)
            self.assertEqual(len(rows),1); self.assertEqual(rows[0]['edition'],'arwiktionary')
            self.assertEqual(rows[0]['outcome'],'failed'); self.assertEqual(rows[0]['elapsed_seconds'],7)
            self.assertEqual(rows[0]['original_manifest'],old['manifest'])
            self.assertEqual(rows[0]['manifest_transition'],value['manifest_transition'])
            self.assertFalse(rows[0]['manifest_transition']['runtime_reuse_credit'])
            self.assertEqual(rows,controller.load_preparations(cfg))
            self.assertEqual(Path(value['result']['path']).read_bytes(),original)

    def test_identical_manifest_location_requires_explicit_authenticated_time_only_proof(self):
        for change in ('missing-flag','runtime-credit','wrong-from','stale-snapshot','different-bytes','registry-credit'):
            with self.subTest(change=change), tempfile.TemporaryDirectory() as directory:
                root=Path(directory); old,cfg,value,path=self.location_context(root)
                transition=value['manifest_transition']
                if change=='missing-flag':transition.pop('identical_manifest_content')
                if change=='runtime-credit':transition['runtime_reuse_credit']=True
                if change=='wrong-from':transition['from_manifest']={}
                if change=='stale-snapshot':transition['from_manifest_snapshot']['sha256']='f'*64
                if change=='different-bytes':
                    write_json(Path(cfg['manifest']['path']),{'changed_payload':True})
                    cfg['manifest']=controller.descriptor(cfg['manifest']['path']);transition['to_manifest']=cfg['manifest']
                if change=='registry-credit':transition['unrelated_arabic_registry']={}
                write_json(path,value);cfg['production_preparations']=[controller.descriptor(path)]
                with self.assertRaises(ValueError):controller.load_preparations(cfg)

    def test_identical_manifest_location_does_not_relax_context_or_independent_closure(self):
        for changed in ('clock','unclosed','source'):
            with self.subTest(changed=changed), tempfile.TemporaryDirectory() as directory:
                changes={'now_unix':1} if changed=='clock' else ({'source':{}} if changed=='source' else None)
                old,cfg,value,path=self.location_context(Path(directory),result_changes=changes,
                    closure_changes={'cleanup_proven':False} if changed=='unclosed' else None)
                with self.assertRaises(ValueError):controller.load_preparations(cfg)

    def test_all_production_outcomes_count_once_across_duplicate_load_and_resume(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            cfg = self.config(root / 'context')
            self.assertEqual([], controller.load_preparations(cfg))
            refs = [self.preparation(root / status, cfg, status, status, seconds)
                    for status, seconds in [('passed', 2), ('failed', 3), ('superseded', 5)]]
            cfg['production_preparations'] = refs + [copy.deepcopy(refs[0])]
            before = [Path(ref['path']).read_bytes() for ref in refs]
            first = controller.load_preparations(cfg)
            second = controller.load_preparations(cfg)
            self.assertEqual(first, second)
            self.assertEqual(3, len(first))
            self.assertEqual({'passed', 'failed', 'superseded'}, {row['outcome'] for row in first})
            self.assertEqual(before, [Path(ref['path']).read_bytes() for ref in refs])
            summary = controller.summarize([attempt('build', 1, seconds=20)], ['enwiktionary'], first + second)
            row = summary['editions'][0]
            self.assertEqual(20, row['observed_build_seconds'])
            self.assertEqual(10, row['observed_preparation_seconds'])
            self.assertEqual(30, row['observed_total_seconds'])
            self.assertEqual(3, len(row['production_preparations']))
            self.assertEqual(30, summary['observed_cohort_seconds'])

    def test_preparation_identity_conflicts_and_attempt_overlap_are_refused(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            cfg = self.config(root / 'context')
            first = self.preparation(root / 'first', cfg, 'same-id', seconds=2)
            other = self.preparation(root / 'other', cfg, 'same-id', seconds=3)
            cfg['production_preparations'] = [first, other]
            with self.assertRaisesRegex(ValueError, 'Conflicting preparation identity'):
                controller.load_preparations(cfg)
            cfg['production_preparations'] = [first]
            prep = controller.load_preparations(cfg)[0]
            with self.assertRaisesRegex(ValueError, 'Conflicting preparation identity'):
                controller.summarize([], ['enwiktionary'], [prep, dict(prep, elapsed_seconds=3)])
            with self.assertRaisesRegex(ValueError, 'also an attempt'):
                controller.summarize([attempt('same-id', 1)], ['enwiktionary'], [prep])

    def test_diagnostic_scope_and_wrong_current_context_are_refused(self):
        changes = [{'accounting_scope': scope} for scope in ['diagnostic', 'canary', 'trial']]
        changes += [{key: 'different-current-value'} for key in
                    ['source', 'manifest', 'compiler', 'date', 'now_unix', 'expansion_timeout_ms']]
        for change in changes:
            with self.subTest(change=change), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                cfg = self.config(root / 'context')
                cfg['production_preparations'] = [self.preparation(root / 'prep', cfg, 'p', result_changes=change)]
                with self.assertRaises(ValueError):
                    controller.load_preparations(cfg)

    def test_unclosed_or_invalid_measured_preparations_are_refused(self):
        cases = [(dict(elapsed_seconds=value), None) for value in [None, -1, float('nan'), float('inf'), True]]
        cases += [(None, change) for change in [dict(cleanup_proven=False), dict(source_guard=False),
                  dict(remaining_owned_processes=[{'pid': 999999}]), dict(outcome='failed-closed'),
                  dict(result={'path': '/not-the-recorded-result', 'bytes': 0, 'sha256': '0' * 64})]]
        for result_change, closure_change in cases:
            with self.subTest(result=result_change, closure=closure_change), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                cfg = self.config(root / 'context')
                cfg['production_preparations'] = [self.preparation(root / 'prep', cfg, 'p',
                    result_changes=result_change, closure_changes=closure_change)]
                with self.assertRaises(ValueError):
                    controller.load_preparations(cfg)

    def transition_receipt(self, root, ref, old_source, new_source, reason='renderer correction'):
        receipt = controller.read_ref(ref)
        receipt['source_transition'] = dict(from_source=old_source, to_source=new_source, reason=reason)
        path = root / 'transition-accounting.json'
        write_json(path, receipt)
        return controller.descriptor(path)

    def test_source_transition_preserves_actual_outcomes_and_counts_each_interval_once(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            old = self.config(root / 'old-context')
            current = dict(old, source=self.config(root / 'new-context')['source'])
            selected = []
            originals = []
            for status, seconds in [('passed', 2), ('failed', 3)]:
                receipt = self.preparation(root / status, old, status, status, seconds)
                authority = controller.read_ref(receipt)
                originals.extend((Path(authority[key]['path']), Path(authority[key]['path']).read_bytes()) for key in ('result', 'closure'))
                selected.append(self.transition_receipt(root / status, receipt, old['source'], current['source']))
            selected.append(self.preparation(root / 'fresh', current, 'fresh', seconds=5))
            current['production_preparations'] = selected + [selected[0]]
            rows = controller.load_preparations(current)
            summary = controller.summarize([attempt('build', 1, seconds=20)], ['enwiktionary'], rows + rows)
            self.assertEqual(10, summary['observed_cohort_preparation_seconds'])
            self.assertEqual(30, summary['observed_cohort_seconds'])
            self.assertEqual(['passed', 'failed', 'passed'], [row['outcome'] for row in rows])
            self.assertEqual(old['source'], rows[0]['original_source'])
            self.assertEqual(current['source'], rows[0]['source_transition']['to_source'])
            self.assertIsNone(rows[2]['source_transition'])
            for path, before in originals:
                self.assertEqual(before, path.read_bytes())

    def test_unacknowledged_or_wrong_source_transitions_are_refused(self):
        for change in [None, {'from_source': 'wrong'}, {'to_source': 'wrong'}, {'reason': ''}, {'reason': '   '}]:
            with self.subTest(change=change), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                old = self.config(root / 'old')
                current = dict(old, source=self.config(root / 'new')['source'])
                receipt = self.preparation(root / 'prep', old, 'p')
                if change is not None:
                    receipt = self.transition_receipt(root / 'prep', receipt, old['source'], current['source'])
                    value = controller.read_ref(receipt); value['source_transition'].update(change)
                    write_json(Path(receipt['path']), value); receipt = controller.descriptor(receipt['path'])
                current['production_preparations'] = [receipt]
                with self.assertRaisesRegex(ValueError, 'explicit source transition'):
                    controller.load_preparations(current)

    def test_source_transition_cannot_change_other_context_or_bypass_closure(self):
        changes = [{key: 'different'} for key in ['manifest', 'compiler', 'date', 'now_unix', 'expansion_timeout_ms']]
        for change in changes:
            with self.subTest(change=change), tempfile.TemporaryDirectory() as directory:
                root = Path(directory); old = self.config(root / 'old')
                current = dict(old, source=self.config(root / 'new')['source']); current.update(change)
                receipt = self.preparation(root / 'prep', old, 'p')
                current['production_preparations'] = [self.transition_receipt(root / 'prep', receipt, old['source'], current['source'])]
                with self.assertRaises(ValueError):controller.load_preparations(current)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); old = self.config(root / 'old')
            current = dict(old, source=self.config(root / 'new')['source'])
            receipt = self.preparation(root / 'prep', old, 'p', closure_changes={'source_guard': False})
            current['production_preparations'] = [self.transition_receipt(root / 'prep', receipt, old['source'], current['source'])]
            with self.assertRaisesRegex(ValueError, 'independently closed'):controller.load_preparations(current)

    def test_preparation_denominator_excludes_original_seven_and_cannot_mask_unknown_time(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            cfg = self.config(root / 'context')
            cfg['production_preparations'] = [
                self.preparation(root / 'passed', cfg, 'p1', 'passed', 2),
                self.preparation(root / 'failed', cfg, 'p2', 'failed', 3),
                self.preparation(root / 'superseded', cfg, 'p3', 'superseded', 5),
                self.preparation(root / 'excluded', cfg, 'p4', 'passed', 999, controller.PILOT[0])]
            preparations = controller.load_preparations(cfg)
            editions = all_editions()
            rows = [attempt(str(i), i, edition=edition) for i, edition in enumerate(editions)]
            summary = controller.summarize(rows, editions, preparations + copy.deepcopy(preparations))
            self.assertTrue(summary['final_cohort_complete'])
            self.assertEqual(382, summary['observed_cohort_build_seconds'])
            self.assertEqual(10, summary['observed_cohort_preparation_seconds'])
            self.assertEqual(392, summary['observed_cohort_seconds'])
            self.assertAlmostEqual(1910 / 392, summary['final_observed_pages_per_second'])
            excluded = next(row for row in summary['editions'] if row['edition'] == controller.PILOT[0])
            self.assertIsNone(excluded['observed_preparation_seconds'])
            self.assertIsNone(excluded['observed_total_seconds'])
            self.assertEqual(1, len(excluded['production_preparations']))
            rows[8]['elapsed_seconds'] = None
            unknown = controller.summarize(rows, editions, preparations)
            self.assertEqual(10, unknown['observed_cohort_preparation_seconds'])
            self.assertIsNone(unknown['final_observed_pages_per_second'])
            self.assertEqual(['enwiktionary'], unknown['unknown_timing_editions'])


    def manifest_contexts(self, root):
        old = self.config(root / 'context')
        original = dict(requested_editions=['enwiktionary', 'arwiktionary'],
                        files=[dict(edition='enwiktionary', date='20261001', sha256='a' * 64)],
                        auxiliary_capture_roots={'enwiktionary': '/captures/old', 'arwiktionary': '/captures/ar'})
        path = Path(old['manifest']['path'])
        write_json(path, original)
        old['manifest'] = controller.descriptor(path)
        snapshot = root / 'manifest.original.json'
        snapshot.write_bytes(path.read_bytes())
        updated = copy.deepcopy(original)
        updated['auxiliary_capture_roots']['enwiktionary'] = '/captures/new'
        # The immutable saved copy authenticates history even after the selected path changes.
        write_json(path, updated)
        current = dict(old, manifest=controller.descriptor(path))
        return old, current, controller.descriptor(snapshot)

    def manifest_receipt(self, root, ref, old, current, snapshot, change=None):
        receipt = controller.read_ref(ref)
        receipt['manifest_transition'] = dict(from_manifest=old['manifest'], to_manifest=current['manifest'],
            from_manifest_snapshot=snapshot, scope='retained-production-time-only', runtime_reuse_credit=False,
            reason='Select the isolated auxiliary file metadata union; keep actual prior work, not runtime authority')
        receipt['manifest_transition'].update(change or {})
        path = root / 'manifest-transition-accounting.json'
        write_json(path, receipt)
        return controller.descriptor(path)

    def test_manifest_transition_preserves_original_timing_once_with_separate_source_transition(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            old, current, snapshot = self.manifest_contexts(root)
            current['source'] = self.config(root / 'new-source')['source']
            selected, originals = [], []
            for status, seconds in [('passed', 2), ('failed', 3)]:
                receipt = self.preparation(root / status, old, status, status, seconds)
                authority = controller.read_ref(receipt)
                originals.extend((Path(authority[key]['path']), Path(authority[key]['path']).read_bytes())
                                 for key in ('result', 'closure'))
                receipt = self.transition_receipt(root / status, receipt, old['source'], current['source'])
                selected.append(self.manifest_receipt(root / status, receipt, old, current, snapshot))
            selected.append(self.preparation(root / 'fresh', current, 'fresh', seconds=5))
            current['production_preparations'] = selected + [selected[0]]
            first = controller.load_preparations(current)
            self.assertEqual(first, controller.load_preparations(current))
            summary = controller.summarize([attempt('build', 1, seconds=20)], ['enwiktionary'], first + first)
            self.assertEqual(10, summary['observed_cohort_preparation_seconds'])
            self.assertEqual(30, summary['observed_cohort_seconds'])
            self.assertEqual(['passed', 'failed', 'passed'], [row['outcome'] for row in first])
            self.assertEqual(old['manifest'], first[0]['original_manifest'])
            self.assertEqual(current['manifest'], first[0]['manifest_transition']['to_manifest'])
            self.assertEqual(old['source'], first[0]['original_source'])
            self.assertEqual(current['source'], first[0]['source_transition']['to_source'])
            self.assertIsNone(first[2]['manifest_transition'])
            self.assertIsNone(first[2]['source_transition'])
            for path, before in originals:
                self.assertEqual(before, path.read_bytes())

    def test_manifest_transition_requires_exact_time_only_authority(self):
        changes = [None, {'from_manifest': {}}, {'to_manifest': {}}, {'reason': ' '},
                   {'scope': 'runtime-reuse'}, {'runtime_reuse_credit': True},
                   {'from_manifest_snapshot': {}}, {'from_manifest_snapshot': {'bytes': 1, 'sha256': '0' * 64}}]
        for change in changes:
            with self.subTest(change=change), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                old, current, snapshot = self.manifest_contexts(root)
                receipt = self.preparation(root / 'prep', old, 'p')
                if change is not None:
                    receipt = self.manifest_receipt(root / 'prep', receipt, old, current, snapshot, change)
                current['production_preparations'] = [receipt]
                with self.assertRaises(ValueError):
                    controller.load_preparations(current)

    def test_manifest_transition_refuses_payload_other_editions_and_unrelated_metadata_changes(self):
        changes = ['dump-bytes', 'editions', 'other-root', 'extra-field', 'missing-root', 'empty-root', 'unchanged-root']
        for change in changes:
            with self.subTest(change=change), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                old, current, snapshot = self.manifest_contexts(root)
                path = Path(current['manifest']['path'])
                value = controller.read_ref(current['manifest'])
                if change == 'dump-bytes': value['files'][0]['sha256'] = 'b' * 64
                if change == 'editions': value['requested_editions'].append('dewiktionary')
                if change == 'other-root': value['auxiliary_capture_roots']['arwiktionary'] = '/different'
                if change == 'extra-field': value['unrelated'] = True
                if change == 'missing-root': del value['auxiliary_capture_roots']['enwiktionary']
                if change == 'empty-root': value['auxiliary_capture_roots']['enwiktionary'] = ''
                if change == 'unchanged-root': value['auxiliary_capture_roots']['enwiktionary'] = '/captures/old'
                write_json(path, value)
                current['manifest'] = controller.descriptor(path)
                receipt = self.preparation(root / 'prep', old, 'p')
                current['production_preparations'] = [self.manifest_receipt(root / 'prep', receipt, old, current, snapshot)]
                with self.assertRaises(ValueError):
                    controller.load_preparations(current)

    def test_manifest_transition_authenticates_saved_and_current_manifest_bytes(self):
        for which in ['snapshot', 'current']:
            with self.subTest(which=which), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                old, current, snapshot = self.manifest_contexts(root)
                receipt = self.preparation(root / 'prep', old, 'p')
                current['production_preparations'] = [self.manifest_receipt(root / 'prep', receipt, old, current, snapshot)]
                path = Path((snapshot if which == 'snapshot' else current['manifest'])['path'])
                path.write_bytes(path.read_bytes() + b' ')
                with self.assertRaisesRegex(ValueError, 'Receipt bytes changed'):
                    controller.load_preparations(current)

    def test_manifest_transition_does_not_relax_source_context_or_independent_closure(self):
        changes = [{key: 'different'} for key in ['source', 'compiler', 'date', 'now_unix', 'expansion_timeout_ms']]
        for change in changes:
            with self.subTest(change=change), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                old, current, snapshot = self.manifest_contexts(root)
                current.update(change)
                receipt = self.preparation(root / 'prep', old, 'p')
                current['production_preparations'] = [self.manifest_receipt(root / 'prep', receipt, old, current, snapshot)]
                with self.assertRaises(ValueError):
                    controller.load_preparations(current)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            old, current, snapshot = self.manifest_contexts(root)
            receipt = self.preparation(root / 'prep', old, 'p', closure_changes={'source_guard': False})
            current['production_preparations'] = [self.manifest_receipt(root / 'prep', receipt, old, current, snapshot)]
            with self.assertRaisesRegex(ValueError, 'independently closed'):
                controller.load_preparations(current)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            old, current, snapshot = self.manifest_contexts(root)
            receipt = self.preparation(root / 'prep', current, 'p')
            current['production_preparations'] = [self.manifest_receipt(root / 'prep', receipt, current, current, snapshot)]
            with self.assertRaisesRegex(ValueError, 'does not change manifest'):
                controller.load_preparations(current)


    def arabic_registry_contexts(self, root):
        old = self.config(root / 'context')
        original_registry = root / 'language-registry.original.tsv'
        original_registry.write_bytes(b'# wikidict-language-registry-v2\n# content-language\tar\nmul\tMultiple languages\tmul\n')
        derived_registry = root / 'language-registry.derived.tsv'
        derived_registry.write_bytes(original_registry.read_bytes() + '# local-alias\tmul\tمتفق عليه دوليا\n'.encode())
        refs = dict(original_registry=controller.descriptor(original_registry),
                    derived_registry=controller.descriptor(derived_registry))
        value = dict(requested_editions=['enwiktionary', 'arwiktionary'],
                     files=[dict(wiki='arwiktionary', date='20261001', sha1='a' * 40)],
                     auxiliary_capture_roots={'enwiktionary': '/captures/en', 'arwiktionary': '/captures/ar'},
                     language_registries=[dict(wiki='enwiktionary', date='20261001', name='language-registry.tsv', content_language='en', size=5, sha256='f' * 64),
                         dict(wiki='arwiktionary', date='20261001', name='language-registry.tsv', content_language='ar',
                              size=refs['original_registry']['bytes'], sha256=refs['original_registry']['sha256'])])
        path = Path(old['manifest']['path']); write_json(path, value)
        old['manifest'] = controller.descriptor(path)
        snapshot = root / 'manifest.original.json'; snapshot.write_bytes(path.read_bytes())
        value['language_registries'][1].update(size=refs['derived_registry']['bytes'], sha256=refs['derived_registry']['sha256'])
        write_json(path, value)
        return old, dict(old, manifest=controller.descriptor(path)), controller.descriptor(snapshot), refs

    def test_unrelated_arabic_registry_retains_sixteen_intervals_once(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); old, current, snapshot, refs = self.arabic_registry_contexts(root)
            current['source'] = self.config(root / 'new-source')['source']
            value = controller.read_ref(current['manifest'])
            value['auxiliary_capture_roots']['enwiktionary'] = '/captures/new'
            write_json(Path(current['manifest']['path']), value)
            current['manifest'] = controller.descriptor(current['manifest']['path'])
            selected, immutable = [], []
            for i in range(16):
                receipt = self.preparation(root / str(i), old, 'p' + str(i),
                    outcome=('passed', 'failed', 'superseded')[i % 3], seconds=i + 1)
                authority = controller.read_ref(receipt)
                immutable.extend((Path(authority[key]['path']), Path(authority[key]['path']).read_bytes()) for key in ('result', 'closure'))
                receipt = self.transition_receipt(root / str(i), receipt, old['source'], current['source'])
                selected.append(self.manifest_receipt(root / str(i), receipt, old, current, snapshot,
                    dict(unrelated_arabic_registry=refs)))
            current['production_preparations'] = selected + selected
            rows = controller.load_preparations(current)
            self.assertEqual(16, len(rows))
            summary = controller.summarize([attempt('a', 1, pages=17, seconds=20)], ['enwiktionary'], rows + rows)
            self.assertEqual(136, summary['observed_cohort_preparation_seconds'])
            self.assertEqual(156, summary['observed_cohort_seconds'])
            self.assertTrue(all(row['manifest_transition']['runtime_reuse_credit'] is False for row in rows))
            for path, content in immutable:self.assertEqual(content, path.read_bytes())

    def test_unrelated_arabic_registry_rejects_nonalias_and_other_input_changes(self):
        for change in ('extra-directive', 'wrong-code', 'symbol-alias', 'rewrite-old', 'other-registry', 'dump', 'capture-root', 'editions', 'extra-field'):
            with self.subTest(change=change), tempfile.TemporaryDirectory() as directory:
                root=Path(directory);old,current,snapshot,refs=self.arabic_registry_contexts(root)
                value=controller.read_ref(current['manifest'])
                if change in ('extra-directive','wrong-code','symbol-alias','rewrite-old'):
                    path=Path(refs['derived_registry']['path']); data=path.read_bytes()
                    if change=='extra-directive':data+=b'# local-alias\tmul\textra\n'
                    if change=='wrong-code':data=data.replace(b'# local-alias\tmul\t',b'# local-alias\tzxx\t')
                    if change=='symbol-alias':data=data.replace('متفق عليه دوليا'.encode(),'رموز'.encode())
                    if change=='rewrite-old':data=data.replace(b'Multiple languages',b'Something else')
                    path.write_bytes(data);refs['derived_registry']=controller.descriptor(path)
                    value['language_registries'][1].update(size=refs['derived_registry']['bytes'],sha256=refs['derived_registry']['sha256'])
                if change=='other-registry':value['language_registries'][0]['sha256']='b'*64
                if change=='dump':value['files'][0]['sha1']='b'*40
                if change=='capture-root':value['auxiliary_capture_roots']['arwiktionary']='/other'
                if change=='editions':value['requested_editions'].append('dewiktionary')
                if change=='extra-field':value['unrelated']=True
                write_json(Path(current['manifest']['path']),value);current['manifest']=controller.descriptor(current['manifest']['path'])
                receipt=self.preparation(root/'prep',old,'p')
                current['production_preparations']=[self.manifest_receipt(root/'prep',receipt,old,current,snapshot,dict(unrelated_arabic_registry=refs))]
                with self.assertRaises(ValueError):controller.load_preparations(current)

    def test_unrelated_arabic_registry_rejects_same_edition_runtime_credit_and_stale_bytes(self):
        for change in ('same-edition','runtime-credit','stale-registry','unclosed','missing-proof'):
            with self.subTest(change=change), tempfile.TemporaryDirectory() as directory:
                root=Path(directory);old,current,snapshot,refs=self.arabic_registry_contexts(root)
                receipt=self.preparation(root/'prep',old,'p',edition='arwiktionary' if change=='same-edition' else 'enwiktionary',
                    closure_changes={'cleanup_proven':False} if change=='unclosed' else None)
                extra=dict(unrelated_arabic_registry=refs)
                if change=='runtime-credit':extra['runtime_reuse_credit']=True
                if change=='missing-proof':extra['unrelated_arabic_registry']={}
                current['production_preparations']=[self.manifest_receipt(root/'prep',receipt,old,current,snapshot,extra)]
                if change=='stale-registry':Path(refs['derived_registry']['path']).write_bytes(b'changed')
                with self.assertRaises(ValueError):controller.load_preparations(current)


    def registry_appends_context(self, root):
        old = self.config(root / 'context')
        original = dict(requested_editions=['enwiktionary', 'arwiktionary', 'afwiktionary', 'amwiktionary'],
            files=[dict(wiki='arwiktionary', date='20261001', sha1='a' * 40)],
            auxiliary_capture_roots={wiki: '/captures/' + wiki for wiki in
                ('enwiktionary', 'arwiktionary', 'afwiktionary', 'amwiktionary')},
            language_registries=[])
        changes = []
        for wiki, language, code, label in (
                ('arwiktionary', 'ar', 'mul', 'متفق عليه دوليا'),
                ('afwiktionary', 'af', 'zh', 'Sjinees'),
                ('amwiktionary', 'am', 'am', 'አማርኛ የዕለት ቋንቋ')):
            before = root / (wiki + '.original.tsv')
            before.write_text('# wikidict-language-registry-v2\n# content-language\t' + language +
                '\n' + code + '\tExisting name\n' + ('ngh\tN/u\n' if language == 'am' else ''))
            after = root / (wiki + '.derived.tsv')
            after.write_bytes(before.read_bytes() + ('# local-alias\t' + code + '\t' + label + '\n').encode())
            change = dict(edition=wiki, original_registry=controller.descriptor(before),
                derived_registry=controller.descriptor(after), aliases=[[code, label]])
            if language == 'am':
                change['local_headings'] = [['ngh', 'Nǁng']]
                after.write_bytes(after.read_bytes() + '# local-heading\tngh\tNǁng\n'.encode())
                change['derived_registry'] = controller.descriptor(after)
            changes.append(change)
            original['language_registries'].append(dict(wiki=wiki, date='20261001',
                name='language-registry.tsv', content_language=language,
                size=change['original_registry']['bytes'], sha256=change['original_registry']['sha256']))
        path = Path(old['manifest']['path']); write_json(path, original)
        old['manifest'] = controller.descriptor(path)
        snapshot = root / 'manifest.snapshot.json'; snapshot.write_bytes(path.read_bytes())
        updated = copy.deepcopy(original)
        for row, change in zip(updated['language_registries'], changes):
            row.update(size=change['derived_registry']['bytes'], sha256=change['derived_registry']['sha256'])
        selected = root / 'manifest.selected.json'; write_json(selected, updated)
        return old, dict(old, manifest=controller.descriptor(selected)), controller.descriptor(snapshot), changes

    def test_registry_appends_preserve_eighteen_intervals_and_deduplicate_without_reuse(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); old, current, snapshot, changes = self.registry_appends_context(root)
            refs = []; immutable = []
            for i in range(18):
                receipt = self.preparation(root / str(i), old, 'append-' + str(i),
                    outcome=['passed', 'failed', 'superseded'][i % 3], seconds=i + 1.25)
                value = controller.read_ref(receipt)
                immutable.extend((Path(value[key]['path']), Path(value[key]['path']).read_bytes())
                                 for key in ('result', 'closure'))
                refs.append(self.manifest_receipt(root / str(i), receipt, old, current, snapshot,
                    dict(unrelated_registry_appends=changes)))
            current['production_preparations'] = refs + refs
            rows = controller.load_preparations(current)
            self.assertEqual(18, len(rows))
            self.assertAlmostEqual(175.5, sum(row['elapsed_seconds'] for row in rows))
            self.assertTrue(all(row['manifest_transition']['runtime_reuse_credit'] is False for row in rows))
            for path, raw in immutable: self.assertEqual(raw, path.read_bytes())

    def test_registry_appends_keep_explicit_source_and_own_capture_root_carries(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); old, current, snapshot, changes = self.registry_appends_context(root)
            value = controller.read_ref(current['manifest'])
            value['auxiliary_capture_roots']['enwiktionary'] = '/captures/new-en'
            write_json(Path(current['manifest']['path']), value)
            current['manifest'] = controller.descriptor(current['manifest']['path'])
            source = root / 'new-source.json'; write_json(source, dict(new_source=True))
            current['source'] = controller.descriptor(source)
            receipt = self.preparation(root / 'prep', old, 'source', seconds=7)
            receipt = self.transition_receipt(root / 'prep', receipt, old['source'], current['source'])
            current['production_preparations'] = [self.manifest_receipt(root / 'prep', receipt, old,
                current, snapshot, dict(unrelated_registry_appends=changes))]
            self.assertEqual(7, controller.load_preparations(current)[0]['elapsed_seconds'])

    def test_registry_appends_refuse_other_manifest_fields(self):
        for kind in ('dump', 'other-root', 'row-name', 'reordered-rows', 'editions', 'extra'):
            with self.subTest(kind=kind), tempfile.TemporaryDirectory() as directory:
                root = Path(directory); old, current, snapshot, changes = self.registry_appends_context(root)
                value = controller.read_ref(current['manifest'])
                if kind == 'dump': value['files'][0]['sha1'] = 'b' * 40
                if kind == 'other-root': value['auxiliary_capture_roots']['arwiktionary'] = '/other'
                if kind == 'row-name': value['language_registries'][0]['name'] = 'other.tsv'
                if kind == 'reordered-rows': value['language_registries'].reverse()
                if kind == 'editions': value['requested_editions'].append('dewiktionary')
                if kind == 'extra': value['extra'] = True
                write_json(Path(current['manifest']['path']), value)
                current['manifest'] = controller.descriptor(current['manifest']['path'])
                with self.assertRaises(ValueError):
                    controller.validate_preparation_manifest_transition(current, old['manifest'],
                        'enwiktionary', old['date'], dict(from_manifest=old['manifest'],
                        to_manifest=current['manifest'], from_manifest_snapshot=snapshot,
                        scope='retained-production-time-only', runtime_reuse_credit=False,
                        reason='explicit', unrelated_registry_appends=changes))

    def test_registry_appends_refuse_bad_proof_and_registry_bytes(self):
        for kind in ('empty', 'duplicate-edition', 'duplicate-label', 'unknown-code', 'stale',
                     'rewrite', 'extra-alias', 'mixed-proof', 'runtime-credit'):
            with self.subTest(kind=kind), tempfile.TemporaryDirectory() as directory:
                root = Path(directory); old, current, snapshot, changes = self.registry_appends_context(root)
                proof = dict(from_manifest=old['manifest'], to_manifest=current['manifest'],
                    from_manifest_snapshot=snapshot, scope='retained-production-time-only',
                    runtime_reuse_credit=False, reason='explicit', unrelated_registry_appends=changes)
                if kind == 'empty': proof['unrelated_registry_appends'] = []
                if kind == 'duplicate-edition': changes[1] = copy.deepcopy(changes[0])
                if kind == 'duplicate-label': changes[0]['aliases'] *= 2
                if kind == 'unknown-code': changes[0]['aliases'][0][0] = 'unknown'
                if kind == 'mixed-proof': proof['unrelated_arabic_registry'] = {}
                if kind == 'runtime-credit': proof['runtime_reuse_credit'] = True
                if kind in ('stale', 'rewrite', 'extra-alias'):
                    path = Path(changes[0]['derived_registry']['path'])
                    data = path.read_bytes()
                    if kind == 'stale': path.write_bytes(b'changed')
                    else:
                        data = (data.replace(b'Existing name', b'Rewritten') if kind == 'rewrite'
                                else data + b'# local-alias\tmul\tUndeclared\n')
                        path.write_bytes(data); changes[0]['derived_registry'] = controller.descriptor(path)
                        value = controller.read_ref(current['manifest'])
                        value['language_registries'][0].update(size=changes[0]['derived_registry']['bytes'],
                            sha256=changes[0]['derived_registry']['sha256'])
                        write_json(Path(current['manifest']['path']), value)
                        current['manifest'] = controller.descriptor(current['manifest']['path'])
                        proof['to_manifest'] = current['manifest']
                with self.assertRaises(ValueError):
                    controller.validate_preparation_manifest_transition(current, old['manifest'],
                        'enwiktionary', old['date'], proof)

    def test_registry_appends_never_relax_preparation_edition_context_or_closure(self):
        for kind in ('same-edition', 'clock', 'source', 'unclosed'):
            with self.subTest(kind=kind), tempfile.TemporaryDirectory() as directory:
                root = Path(directory); old, current, snapshot, changes = self.registry_appends_context(root)
                receipt = self.preparation(root / 'prep', old, 'bad',
                    edition='arwiktionary' if kind == 'same-edition' else 'enwiktionary',
                    closure_changes={'cleanup_proven': False} if kind == 'unclosed' else None)
                current['production_preparations'] = [self.manifest_receipt(root / 'prep', receipt,
                    old, current, snapshot, dict(unrelated_registry_appends=changes))]
                if kind == 'clock': current['now_unix'] += 1
                if kind == 'source':
                    source = root / 'other-source.json'; write_json(source, dict(other=True))
                    current['source'] = controller.descriptor(source)
                with self.assertRaises(ValueError): controller.load_preparations(current)

    def test_registry_appends_refuse_identical_content_and_same_manifest_proofs(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); old, current, snapshot, changes = self.registry_appends_context(root)
            identical = root / 'same-content.json'
            identical.write_bytes(Path(old['manifest']['path']).read_bytes())
            current['manifest'] = controller.descriptor(identical)
            proof = dict(from_manifest=old['manifest'], to_manifest=current['manifest'],
                from_manifest_snapshot=snapshot, scope='retained-production-time-only',
                runtime_reuse_credit=False, reason='explicit',
                identical_manifest_content=True, unrelated_registry_appends=changes)
            with self.assertRaises(ValueError):
                controller.validate_preparation_manifest_transition(current, old['manifest'],
                    'enwiktionary', old['date'], proof)
            with self.assertRaises(ValueError):
                controller.validate_preparation_manifest_transition(old, old['manifest'],
                    'enwiktionary', old['date'], proof)



    def test_registry_appends_local_heading_proof_does_not_grant_runtime_or_accept_unknown_codes(self):
        for kind in ('valid', 'unknown-code', 'duplicate-label', 'missing-declaration', 'malformed-pair'):
            with self.subTest(kind=kind), tempfile.TemporaryDirectory() as directory:
                root = Path(directory); old, current, snapshot, changes = self.registry_appends_context(root)
                if kind == 'unknown-code': changes[2]['local_headings'][0][0] = 'unknown'
                if kind == 'duplicate-label': changes[2]['local_headings'][0][1] = changes[2]['aliases'][0][1]
                if kind == 'missing-declaration': changes[2].pop('local_headings')
                if kind == 'malformed-pair': changes[2]['local_headings'] = [['ngh']]
                proof = dict(from_manifest=old['manifest'], to_manifest=current['manifest'],
                    from_manifest_snapshot=snapshot, scope='retained-production-time-only',
                    runtime_reuse_credit=False, reason='explicit', unrelated_registry_appends=changes)
                if kind == 'valid':
                    self.assertIs(proof, controller.validate_preparation_manifest_transition(
                        current, old['manifest'], 'enwiktionary', old['date'], proof))
                    self.assertIs(proof['runtime_reuse_credit'], False)
                else:
                    with self.assertRaises(ValueError):
                        controller.validate_preparation_manifest_transition(current, old['manifest'],
                            'enwiktionary', old['date'], proof)




    def four_registry_appends_context(self, root, an_aliases=None):
        old, current, snapshot, changes = self.registry_appends_context(root)
        before, after = controller.read_ref(snapshot), controller.read_ref(current['manifest'])
        original = root / 'an.original.tsv'
        aliases = [['it', 'Italián']] if an_aliases is None else copy.deepcopy(an_aliases)
        codes = sorted({code for code, _ in aliases})
        original.write_text('# wikidict-language-registry-v2\n# content-language\tan\n' +
            ('it\tItalian\n' if an_aliases is None else ''.join(code + '\tExisting ' + code + '\n' for code in codes)))
        derived = root / 'an.derived.tsv'
        derived.write_bytes(original.read_bytes() + ''.join('# local-alias\t' + code + '\t' + label + '\n'
            for code, label in aliases).encode())
        change = dict(edition='anwiktionary', original_registry=controller.descriptor(original),
            derived_registry=controller.descriptor(derived), aliases=aliases)
        row = dict(wiki='anwiktionary', date='20261001', name='language-registry.tsv',
            content_language='an', size=change['original_registry']['bytes'],
            sha256=change['original_registry']['sha256'])
        for value in (before, after):
            value['requested_editions'].append('anwiktionary')
            value['auxiliary_capture_roots']['anwiktionary'] = '/captures/anwiktionary'
        before['language_registries'].append(row)
        after['language_registries'].append(dict(row, size=change['derived_registry']['bytes'],
            sha256=change['derived_registry']['sha256']))
        write_json(Path(old['manifest']['path']), before)
        write_json(Path(snapshot['path']), before)
        write_json(Path(current['manifest']['path']), after)
        old['manifest'] = controller.descriptor(old['manifest']['path'])
        current['manifest'] = controller.descriptor(current['manifest']['path'])
        return old, current, controller.descriptor(snapshot['path']), changes + [change]

    def test_four_registry_lineages_preserve_nineteen_mixed_intervals_once(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            old, current, snapshot, changes = self.four_registry_appends_context(root)
            refs, immutable = [], []
            for i in range(19):
                receipt = self.preparation(root / str(i), old, 'four-' + str(i),
                    outcome=['passed', 'failed', 'superseded'][i % 3], seconds=i + 1.25)
                authority = controller.read_ref(receipt)
                immutable.extend((Path(authority[key]['path']), Path(authority[key]['path']).read_bytes())
                    for key in ('result', 'closure'))
                refs.append(self.manifest_receipt(root / str(i), receipt, old, current, snapshot,
                    dict(unrelated_registry_appends=changes)))
            current['production_preparations'] = refs + refs
            rows = controller.load_preparations(current)
            self.assertEqual(19, len(rows))
            self.assertEqual(194.75, sum(row['elapsed_seconds'] for row in rows))
            self.assertEqual({'passed', 'failed', 'superseded'}, {row['outcome'] for row in rows})
            self.assertTrue(all(row['manifest_transition']['runtime_reuse_credit'] is False for row in rows))
            for path, content in immutable: self.assertEqual(content, path.read_bytes())

    def test_four_registry_scope_refuses_unreviewed_fourth_fifth_and_duplicate(self):
        for kind in ('unreviewed-fourth', 'fifth', 'duplicate', 'malformed', 'nonstring-edition'):
            with self.subTest(kind=kind), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                old, current, snapshot, changes = self.four_registry_appends_context(root)
                if kind == 'unreviewed-fourth': changes[-1]['edition'] = 'dewiktionary'
                if kind == 'fifth': changes.append(copy.deepcopy(changes[-1]))
                if kind == 'duplicate': changes[-1] = copy.deepcopy(changes[0])
                if kind == 'malformed': changes[-1] = None
                if kind == 'nonstring-edition': changes[-1]['edition'] = []
                with self.assertRaises(ValueError):
                    controller._validate_unrelated_registry_appends(controller.read_ref(snapshot),
                        controller.read_ref(current['manifest']), 'enwiktionary', '20261001', changes)

    def test_four_registry_proof_keeps_an_bytes_other_inputs_and_cleanup_strict(self):
        for kind in ('stale-an', 'rewrite-an', 'other-input', 'same-edition', 'runtime-credit', 'unclosed'):
            with self.subTest(kind=kind), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                old, current, snapshot, changes = self.four_registry_appends_context(root)
                if kind in ('stale-an', 'rewrite-an'):
                    path = Path(changes[-1]['derived_registry']['path'])
                    path.write_bytes(path.read_bytes().replace(b'Italian', b'Rewritten'))
                    if kind == 'rewrite-an':
                        changes[-1]['derived_registry'] = controller.descriptor(path)
                        value = controller.read_ref(current['manifest'])
                        value['language_registries'][-1].update(
                            size=changes[-1]['derived_registry']['bytes'],
                            sha256=changes[-1]['derived_registry']['sha256'])
                        write_json(Path(current['manifest']['path']), value)
                        current['manifest'] = controller.descriptor(current['manifest']['path'])
                if kind == 'other-input':
                    value = controller.read_ref(current['manifest'])
                    value['files'][0]['sha1'] = 'b' * 40
                    write_json(Path(current['manifest']['path']), value)
                    current['manifest'] = controller.descriptor(current['manifest']['path'])
                receipt = self.preparation(root / 'prep', old, 'refused',
                    edition='anwiktionary' if kind == 'same-edition' else 'enwiktionary',
                    closure_changes={'cleanup_proven': False} if kind == 'unclosed' else None)
                extra = dict(unrelated_registry_appends=changes)
                if kind == 'runtime-credit': extra['runtime_reuse_credit'] = True
                current['production_preparations'] = [self.manifest_receipt(root / 'prep',
                    receipt, old, current, snapshot, extra)]
                with self.assertRaises(ValueError): controller.load_preparations(current)


    def test_an14_case_distinct_same_owner_retains_nineteen_preparation_intervals(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            old, current, snapshot, changes = self.four_registry_appends_context(root, AN14_REVIEWED_ALIASES)
            self.assertEqual(426, changes[-1]['derived_registry']['bytes'] - changes[-1]['original_registry']['bytes'])
            refs, originals = [], {}
            durations = [38590.353032794985 / 18] * 18 + [1354.0153575069999]
            for i, seconds in enumerate(durations):
                receipt = self.preparation(root / str(i), old, 'case-distinct-' + str(i),
                    outcome=['passed', 'failed', 'superseded'][i % 3], seconds=seconds)
                value = controller.read_ref(receipt)
                for key in ('result', 'closure'):
                    path = Path(value[key]['path']); originals[str(path)] = path.read_bytes()
                refs.append(self.manifest_receipt(root / str(i), receipt, old, current, snapshot,
                    dict(unrelated_registry_appends=changes)))
            current['production_preparations'] = refs + refs
            rows = controller.load_preparations(current)
            self.assertEqual(19, len(rows))
            self.assertAlmostEqual(39944.368390301985, sum(row['elapsed_seconds'] for row in rows))
            self.assertTrue(all(row['manifest_transition']['runtime_reuse_credit'] is False for row in rows))
            self.assertEqual(originals, {path: Path(path).read_bytes() for path in originals})

    def test_case_distinct_aliases_refuse_exact_duplicates_and_cross_owner_folds(self):
        for extra in (['it', 'Italián'], ['fr', 'ITALIÁN']):
            with self.subTest(extra=extra), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                old, current, snapshot, changes = self.four_registry_appends_context(root, AN14_REVIEWED_ALIASES + [extra])
                receipt = self.preparation(root / 'prep', old, 'bad-case-distinct')
                current['production_preparations'] = [self.manifest_receipt(root / 'prep', receipt,
                    old, current, snapshot, dict(unrelated_registry_appends=changes))]
                with self.assertRaises(ValueError): controller.load_preparations(current)

class ControllerMemoryPolicyTests(unittest.TestCase):
    def cfg(self, root):
        return dict(armed=True, source={'head': 'a'*40, 'fingerprint': 'b'*64},
                    compiler={'path': str(root/'zig'), 'bytes': 1, 'sha256': 'c'*64},
                    manifest={'path': str(root/'downloads/manifest.json'), 'bytes': 1, 'sha256': 'd'*64},
                    downloads=str(root/'downloads'), output=str(root/'output'),
                    raw_shard_root=str(root/'raw'), state_directory=str(root/'state'),
                    date='20261001', now_unix=1, expansion_timeout_ms=10,
                    build_timeout_seconds=123, qualification={}, diagnostic_disposition={})

    def test_fixed_8g_budget_reduces_workers_without_same_resource_replay(self):
        state = (4, 8*1024**3)
        observed = [state]
        for expected in [(2, 8*1024**3), (1, 8*1024**3)]:
            state = controller.next_resources(*state, {
                'termination_reason': 'sampled_pss_limit', 'memory_limit_bytes': state[1]})
            self.assertEqual(expected, state)
            observed.append(state)
        self.assertEqual([(4, 8*1024**3), (2, 8*1024**3), (1, 8*1024**3)], observed)
        self.assertIsNone(controller.next_resources(*state, {
            'termination_reason': 'sampled_pss_limit', 'memory_limit_bytes': state[1]}))

    def test_noncap_or_unmatched_actual_limit_never_authorizes_worker_retry(self):
        for reason in ['child_exit', 'wall_timeout', 'running', None, 'OutOfMemory',
                       'host_ram_stop_reserve', 'host_memory_pressure']:
            with self.subTest(reason=reason):
                self.assertIsNone(controller.next_resources(4, 8*1024**3, {
                    'termination_reason': reason, 'memory_limit_bytes': 8*1024**3,
                    'error': 'OutOfMemory: ordinary failed entry'}))
        for actual in [None, True, '8589934592', 2*1024**3, 4*1024**3]:
            with self.subTest(actual=actual):
                self.assertIsNone(controller.next_resources(4, 8*1024**3, {
                    'termination_reason': 'sampled_pss_limit', 'memory_limit_bytes': actual}))
        self.assertIsNone(controller.next_resources(4, 4*1024**3, {
            'termination_reason': 'sampled_pss_limit', 'memory_limit_bytes': 4*1024**3}))
        self.assertIsNone(controller.next_resources(3, 8*1024**3, {
            'termination_reason': 'sampled_pss_limit', 'memory_limit_bytes': 8*1024**3}))

    def test_command_requests_fixed_8g_without_other_guard_changes(self):
        cfg = self.cfg(Path('/unused-memory-control'))
        for memory, mib in [(None, '8192'), (8*1024**3, '8192')]:
            argv = (controller.command(cfg, 'arwiktionary', 4) if memory is None else
                    controller.command(cfg, 'arwiktionary', 4, memory))
            self.assertEqual(mib, argv[argv.index('--watchdog-memory-limit-mib')+1])
            self.assertEqual('unlimited', argv[argv.index('--watchdog-address-space')+1])
            self.assertEqual('affinity', argv[argv.index('--cpu-admission')+1])
            self.assertEqual('watchdog', argv[argv.index('--resource-mode')+1])
            self.assertEqual(1, argv.count('--compress-shards'))
            self.assertNotIn('--compress-output', argv)  # This belongs to native merge, not the builder CLI.
            for flag in ['--threads', '--expansion-workers']:
                self.assertEqual('4', argv[argv.index(flag)+1])
            self.assertEqual('1', argv[argv.index('--jobs')+1])
            self.assertEqual('arwiktionary', argv[argv.index('--wikis')+1])
            self.assertNotIn('--clobber', argv)
        for invalid in [True, '8589934592', 4*1024**3, 16*1024**3]:
            with self.subTest(invalid=invalid), self.assertRaises(ValueError):
                controller.command(cfg, 'arwiktionary', 4, invalid)

    def test_execute_start_receipt_matches_selected_memory_and_actual_argv(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); cfg = self.cfg(root)
            for memory in [8*1024**3]:
                folder = root/str(memory)
                process = mock.Mock(pid=900123)
                process.poll.return_value = 1
                process.wait.return_value = 1
                def spawn(*args, **kwargs):
                    write_json(Path(kwargs['cwd'])/'.tmp/build-watchdog-report.json', {
                        'termination_reason': 'child_exit', 'memory_limit_bytes': memory})
                    return process
                with mock.patch.object(controller,'ROOT',root), \
                     mock.patch.object(controller.subprocess, 'Popen', side_effect=spawn), \
                     mock.patch.object(controller, 'process_identity', return_value={'pid':900123,'start_time_ticks':1}), \
                     mock.patch.object(controller, 'watchdog_closed', return_value=True), \
                     mock.patch.object(controller, 'source_guard'), \
                     mock.patch.object(controller, 'phase_end', return_value=None):
                    row, _ = controller.execute(cfg, 'arwiktionary', 4, folder, 1, 'context', [], memory)
                start = json.loads((folder/'start.json').read_text())
                self.assertEqual(memory, start['memory_limit_bytes'])
                self.assertEqual(str(memory//1024**2),
                                 start['argv'][start['argv'].index('--watchdog-memory-limit-mib')+1])
                self.assertEqual(1, row['exit_code'])
                self.assertIsNone(row['accepted'])

    def test_main_keeps_8g_and_resets_workers_for_next_edition(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); cfg = self.cfg(root); seen = []
            def execute(cfg, edition, workers, folder, sequence, context, locks,
                        memory_limit_bytes=controller.MEMORY):
                seen.append((edition, workers, memory_limit_bytes))
                cap = len(seen) == 1
                return ({'edition': edition, 'sequence': sequence,
                         'controller_interrupted': False, 'cleanup_proven': True, 'source_guard': True, 'control_proven': True,
                         'accepted': None if cap else {'tiny': True}},
                        {'termination_reason': 'sampled_pss_limit' if cap else 'child_exit',
                         'memory_limit_bytes': memory_limit_bytes})
            manifest = {'requested_editions': all_editions(), 'files': [{'date':'20261001'}]}
            summary = {'editions': [{'edition': e, 'accepted': {'tiny':True}}
                                    for e in ['arwiktionary', 'enwiktionary']]}
            with mock.patch.object(controller, 'read_json', return_value=cfg), \
                 mock.patch.object(controller, 'read_ref', return_value=manifest), \
                 mock.patch.object(controller, 'descriptor', return_value=cfg['compiler']), \
                 mock.patch.object(controller, 'validate_pipeline_paths'), \
                 mock.patch.object(controller, 'source_guard'), \
                 mock.patch.object(controller, 'gate', return_value={}), \
                 mock.patch.object(controller, 'production_context', return_value='context'), \
                 mock.patch.object(controller, 'history', return_value=[]), \
                 mock.patch.object(controller, 'load_preparations', return_value=[]), \
                 mock.patch.object(controller, 'summarize', return_value=summary), \
                 mock.patch.object(controller, 'selected_phase_editions', return_value=['arwiktionary','enwiktionary']), \
                 mock.patch.object(controller, 'Lock'), \
                 mock.patch.object(controller.resource, 'getrlimit',
                     return_value=(controller.resource.RLIM_INFINITY, controller.resource.RLIM_INFINITY)), \
                 mock.patch.object(controller.os, 'sched_getaffinity', return_value={0,2,4,6}), \
                 mock.patch.object(controller, 'execute', side_effect=execute), \
                 mock.patch('builtins.print'):
                self.assertEqual(0, controller.main(['--config', str(root/'config.json')]))
            self.assertEqual([('arwiktionary',4,8*1024**3),
                              ('arwiktionary',2,8*1024**3),
                              ('enwiktionary',4,8*1024**3)], seen)


    def test_nominal_success_with_wrong_actual_cap_cannot_accept_publication(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);cfg=self.cfg(root);folder=root/'attempt'
            process=mock.Mock(pid=900123);process.poll.return_value=0;process.wait.return_value=0
            def spawn(*args,**kwargs):
                write_json(Path(kwargs['cwd'])/'.tmp/build-watchdog-report.json', {
                    'termination_reason':'child_exit','memory_limit_bytes':4*1024**3})
                return process
            with mock.patch.object(controller,'ROOT',root), \
                 mock.patch.object(controller.subprocess,'Popen',side_effect=spawn), \
                 mock.patch.object(controller,'process_identity',return_value={'pid':900123,'start_time_ticks':1}), \
                 mock.patch.object(controller,'watchdog_closed',return_value=True), \
                 mock.patch.object(controller,'source_guard'), \
                 mock.patch.object(controller,'phase_end',return_value={'status':'success'}), \
                 mock.patch.object(controller,'accept') as accept:
                row,_=controller.execute(cfg,'arwiktionary',4,folder,1,'context',[],8*1024**3)
            self.assertEqual(0,row['exit_code'])
            self.assertIsNone(row['accepted'])
            self.assertIn('watchdog memory budget differs',row['error'])
            self.assertTrue(row['source_guard']); self.assertFalse(row['control_proven'])
            accept.assert_not_called()




def content_review_fixture(top, editions, *, fallback_reasons=(), unclassified=False, empty=False):
    """Synthetic authenticated metadata; no native publication is represented as tested."""
    source = dict(head='test-head', fingerprint='test-source')
    rows = []; reviews = []
    for index, edition in enumerate(editions):
        root = top / 'dictionaries' / edition / '20261001'; root.mkdir(parents=True)
        special = index == 0
        reasons = list(fallback_reasons) if special else []
        is_empty = empty and special; is_unclassified = unclassified and special
        headings = [] if is_empty else ['Unclassified' if is_unclassified else 'Test language']
        (root/'languages.tsv').write_text('heading\n' + ''.join(x+'\n' for x in headings))
        write_json(root/'page-coverage.json', dict(version=1,start_page=0,requested_limit=None,pages_seen=81,index_byte_offset=0,expected_input_pages=81,page_index_rows=81,page_index_identity=dict(device_major=1,device_minor=0,inode=1,size=81,mtime_ns=1)))
        counters=dict(input_rows=81,compile_only_rows=81 if is_empty else 0,source_unavailable_rows=0,dispatched_rows=0 if is_empty else 81,expanded_pages=0 if is_empty else 81-int(bool(reasons)),fallback_pages=int(bool(reasons)),duplicate_rows=0)
        write_json(root/'namespace-coverage.json',dict(version=1,namespaces=[dict(id=10,name='Template',kind=None,**counters)] if is_empty else [dict(id=0,name='',kind='language',**counters)]))
        (root/'fallback-pages.jsonl').write_text(''.join(json.dumps(dict(namespace=0,title='entry',reasons=reasons))+'\n' for _ in range(bool(reasons))))
        if not is_empty: (root/'test.wikblb.xz').write_bytes(b'synthetic payload; structurally qualified elsewhere')
        files = {p.name:dict(size=p.stat().st_size,sha256=controller.digest(p)) for p in root.iterdir()}
        inputs = dict(source=source['fingerprint'], files=[[edition,'20261001','dump.xml',81,'test-sha1']])
        complete = dict(edition=edition,date='20261001',build_inputs=inputs,input_pages=81,
                        status='empty' if is_empty else 'built',blobs=0 if is_empty else 1,
                        fallback_pages=int(bool(reasons)),namespace_coverage_totals=counters,publication_files=files)
        write_json(root/'complete.json',complete)
        snapshot=top/'receipts'/edition/'complete.json'; snapshot.parent.mkdir(parents=True)
        snapshot.write_bytes((root/'complete.json').read_bytes())
        reports={name:controller.descriptor(root/name) for name in controller.REVIEW_REPORT_NAMES}
        accepted=dict(root=str(root),source=source,build_inputs=inputs,input_pages=81,
                      complete=controller.descriptor(root/'complete.json'),complete_snapshot=controller.descriptor(snapshot),reports=reports)
        rows.append(dict(edition=edition,accepted=accepted))
        evidence=top/'evidence'/edition; evidence.mkdir(parents=True)
        (evidence/'source.txt').write_text('Selected source explicitly contains no qualifying dictionary content.' if is_empty else 'Selected authored source context.')
        write_json(evidence/'output.json',dict(edition=edition,complete=accepted['complete'],reports=reports))
        explanation='Selected source and native output checked; no qualifying dictionary content.' if is_empty else 'Selected source intent and native output checked.'
        reviews.append(dict(edition=edition,complete=accepted['complete'],reports=reports,
            fallback_pages=int(bool(reasons)),fallback_reasons={reason:1 for reason in reasons},
            language_inventory=controller.descriptor(root/'languages.tsv'),unclassified_present=is_unclassified,
            publication_status=complete['status'],input_pages=81,namespace_coverage_totals=complete['namespace_coverage_totals'],content_review=dict(edition=edition,
                complete_sha256=accepted['complete']['sha256'],build_inputs=inputs,input_pages=81,
                source_intent_verified=True,native_output_checked=True,no_unresolved_language_declarations=True,
                no_build_render_errors=True,explanation=explanation,
                source_evidence=[controller.descriptor(evidence/'source.txt')],output_evidence=[controller.descriptor(evidence/'output.json')]),
            dispositions=dict(fallbacks=dict(status='source-verified' if reasons else 'none',
                explanation='Verified authored warning context and native output.',source_verified_reasons={reason:'Exact authored limitation checked.' for reason in reasons}),
                unclassified=dict(status='source-verified' if is_unclassified else 'none',explanation='Verified authored non-language content, no unresolved language declaration.'),
                empty=dict(status='source-verified' if is_empty else 'not-empty',explanation=explanation))))
    scope='pilot' if set(editions)==set(controller.PILOT) else 'final'
    review=dict(schema='wikidict.corpus-pilot-content-review.v1' if scope=='pilot' else 'wikidict.corpus-final-semantic-review.v1',
        outcome='passed',source_head=source['head'],source_fingerprint=source['fingerprint'],
        accepted_completions={row['edition']:row['accepted']['complete']['sha256'] for row in rows},editions=reviews,
        pending_build_failures=[],unresolved_build_failures=[],pending_render_failures=[],unresolved_render_failures=[])
    return source,rows,review


class ContentReviewTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.top=Path(self.temp.name).resolve()

    def fixture(self, **kwargs):
        return content_review_fixture(self.top, controller.PILOT, **kwargs)

    def check(self, data, scope='pilot'):
        source,rows,review=data
        return controller.validate_content_review(review,source,rows,[row['edition'] for row in rows],scope=scope)

    def test_exact_clean_pilot_passes(self):
        data=self.fixture(); self.assertIs(data[2],self.check(data))

    def test_same_validator_accepts_exact_final198(self):
        data=content_review_fixture(self.top,all_editions()); self.check(data,'final')
        data[2]['editions'].pop()
        with self.assertRaises(ValueError):self.check(data,'final')

    def test_old_generic_hash_map_is_insufficient(self):
        data=self.fixture(); del data[2]['editions']
        with self.assertRaises(ValueError):self.check(data)

    def test_duplicate_edition_review_refused(self):
        data=self.fixture(); data[2]['editions'][1]=copy.deepcopy(data[2]['editions'][0])
        with self.assertRaises(ValueError):self.check(data)

    def test_source_verified_warning_requires_every_reason(self):
        data=self.fixture(fallback_reasons=['unclosed_formatting']); self.check(data)
        data[2]['editions'][0]['dispositions']['fallbacks']['source_verified_reasons']={}
        with self.assertRaises(ValueError):self.check(data)

    def test_zero_claim_cannot_hide_actual_fallback(self):
        data=self.fixture(fallback_reasons=['unclosed_formatting']); data[2]['editions'][0]['fallback_pages']=0
        with self.assertRaises(ValueError):self.check(data)

    def test_expansion_and_unresolved_language_errors_never_waived(self):
        for index,reason in enumerate(('expansion_error','expansion_error:expand:NotImplemented','missing_language_heading','unresolved_language_heading','rendered_lua_error','rendered_extension_error','render_limit','template_presentation','missing_template')):
            with self.subTest(reason=reason):
                data=content_review_fixture(self.top/str(index),controller.PILOT,fallback_reasons=[reason])
                with self.assertRaisesRegex(ValueError,'remains unresolved'):self.check(data)

    def test_streams_late_error_without_materializing_report(self):
        path=self.top/'fallback.jsonl'
        rows=[dict(namespace=0,title=str(n),reasons=['unclosed_formatting']) for n in range(1000)]
        rows.append(dict(namespace=0,title='late',reasons=['expansion_error:expand:NotImplemented']))
        path.write_text(''.join(json.dumps(row)+'\n' for row in rows))
        with mock.patch.object(Path,'read_bytes',side_effect=AssertionError('Do not materialize fallback report')):
            with self.assertRaisesRegex(ValueError,'late'):
                controller._review_fallbacks(path,len(rows))

    def test_stream_count_and_oversized_row_refused(self):
        path=self.top/'fallback.jsonl'; path.write_text(json.dumps(dict(namespace=0,title='x',reasons=['warning']))+'\n')
        with self.assertRaises(ValueError):controller._review_fallbacks(path,0)
        path.write_bytes(b'x'*(controller.REVIEW_METADATA_LIMIT+1))
        with self.assertRaisesRegex(ValueError,'exceeds'):controller._review_fallbacks(path,1)

    def test_unclassified_presence_not_a_guessed_record_count(self):
        data=self.fixture(unclassified=True); self.check(data)
        data[2]['editions'][0]['unclassified_present']=False
        with self.assertRaises(ValueError):self.check(data)

    def test_empty_edition_with81_input_rows_needs_source_and_output(self):
        data=self.fixture(empty=True); self.check(data)
        data[2]['editions'][0]['content_review']['source_evidence']=[]
        with self.assertRaises(ValueError):self.check(data)

    def test_empty_edition_cannot_be_inferred_from_missing_inventory(self):
        data=self.fixture(empty=True); Path(data[2]['editions'][0]['language_inventory']['path']).unlink()
        with self.assertRaises((ValueError,OSError)):self.check(data)

    def test_each_pending_or_unresolved_array_blocks_review(self):
        data=self.fixture()
        for key in ('pending_build_failures','unresolved_build_failures','pending_render_failures','unresolved_render_failures'):
            with self.subTest(key=key):
                value=copy.deepcopy(data); value[2][key]=['unresolved']
                with self.assertRaises(ValueError):self.check(value)

    def test_missing_zero_disposition_is_not_implicitly_clear(self):
        data=self.fixture(); del data[2]['editions'][0]['dispositions']['unclassified']
        with self.assertRaises(ValueError):self.check(data)

    def test_arbitrary_waiver_status_refused(self):
        data=self.fixture(fallback_reasons=['unclosed_formatting']); data[2]['editions'][0]['dispositions']['fallbacks']['status']='waived'
        with self.assertRaises(ValueError):self.check(data)

    def test_report_mutation_and_cross_edition_substitution_refused(self):
        data=self.fixture(); report=data[2]['editions'][0]['reports']['page-coverage.json']; Path(report['path']).write_text('{}')
        with self.assertRaises(ValueError):self.check(data)

    def test_completion_map_and_current_source_bound(self):
        data=self.fixture()
        for field in ('accepted_completions','source_fingerprint'):
            value=copy.deepcopy(data); value[2][field]={} if field=='accepted_completions' else 'stale'
            with self.assertRaises(ValueError):self.check(value)

    def test_review_intent_and_output_evidence_are_mandatory(self):
        data=self.fixture()
        for field in ('source_intent_verified','native_output_checked','no_unresolved_language_declarations','no_build_render_errors'):
            value=copy.deepcopy(data); value[2]['editions'][0]['content_review'][field]=False
            with self.assertRaises(ValueError):self.check(value)

    def test_evidence_and_build_input_binding_refused_if_changed(self):
        data=self.fixture(); value=copy.deepcopy(data); value[2]['editions'][0]['content_review']['build_inputs']={}
        with self.assertRaises(ValueError):self.check(value)
        Path(data[2]['editions'][0]['content_review']['output_evidence'][0]['path']).write_text('changed')
        with self.assertRaises(ValueError):self.check(data)

    def test_explicit_failure_and_wrong_schema_refused(self):
        data=self.fixture(); data[2]['passed']=False
        with self.assertRaises(ValueError):self.check(data)
        del data[2]['passed']; data[2]['schema']='generic-pass'
        with self.assertRaises(ValueError):self.check(data)


    def test_empty_review_must_state_observed_namespace_counts(self):
        data=self.fixture(empty=True); data[2]['editions'][0]['namespace_coverage_totals']={}
        with self.assertRaises(ValueError):self.check(data)

    def test_empty_output_cannot_omit_native_evidence(self):
        data=self.fixture(empty=True); data[2]['editions'][0]['content_review']['output_evidence']=[]
        with self.assertRaises(ValueError):self.check(data)



    def test_completion_cannot_conceal_page_coverage_mismatch(self):
        data=self.fixture(empty=True); self.rewrite_report(data,'page-coverage.json',dict(version=1,start_page=0,requested_limit=None,pages_seen=80,index_byte_offset=0,expected_input_pages=81,page_index_identity=dict(device_major=1,device_minor=0,inode=1,size=81,mtime_ns=1)))
        with self.assertRaises(ValueError):self.check(data)

    def test_completion_cannot_conceal_namespace_conservation_mismatch(self):
        data=self.fixture(empty=True); path=Path(data[1][0]['accepted']['root'])/'namespace-coverage.json'
        value=json.loads(path.read_bytes()); value['namespaces'][0]['compile_only_rows']=80
        self.rewrite_report(data,'namespace-coverage.json',value)
        with self.assertRaises(ValueError):self.check(data)

    def rewrite_report(self,data,name,value):
        accepted=data[1][0]['accepted']; review=data[2]['editions'][0];root=Path(accepted['root'])
        write_json(root/name,value); reference=controller.descriptor(root/name)
        accepted['reports'][name]=reference;review['reports']=copy.deepcopy(accepted['reports'])
        complete=json.loads((root/'complete.json').read_bytes());complete['publication_files'][name]=dict(size=reference['bytes'],sha256=reference['sha256'])
        write_json(root/'complete.json',complete);Path(accepted['complete_snapshot']['path']).write_bytes((root/'complete.json').read_bytes())
        accepted['complete']=controller.descriptor(root/'complete.json');accepted['complete_snapshot']=controller.descriptor(accepted['complete_snapshot']['path'])
        review['complete']=accepted['complete'];review['content_review']['complete_sha256']=accepted['complete']['sha256'];data[2]['accepted_completions'][data[1][0]['edition']]=accepted['complete']['sha256']



    def test_valid_coverage_total_must_match_completion(self):
        data=self.fixture(empty=True); root=Path(data[1][0]['accepted']['root'])
        coverage=json.loads((root/'page-coverage.json').read_bytes());coverage.update(pages_seen=80,expected_input_pages=80,page_index_rows=80)
        self.rewrite_report(data,'page-coverage.json',coverage)
        with self.assertRaisesRegex(ValueError,'namespace|coverage|Namespace'):self.check(data)

    def test_accepted_input_numerator_must_match_actual_coverage(self):
        data=self.fixture();data[1][0]['accepted']['input_pages']=80
        with self.assertRaises(ValueError):self.check(data)


    def site_metadata_fixture(self, suffix='metadata'):
        data=content_review_fixture(self.top/suffix,controller.PILOT,empty=True)
        accepted=data[1][0]['accepted'];review=data[2]['editions'][0];root=Path(accepted['root'])
        site=dict(schema='wikidict.site-info.v2',wiki=data[1][0]['edition'],date=root.name,
                  namespace_registry_sha256='a'*64,query=dict(general=dict(wikiid=data[1][0]['edition'],mainpage='Main Page')))
        path=self.top/(suffix+'-site.json');write_json(path,site)
        review['site_info_snapshot']=controller.descriptor(path)
        accepted['build_inputs']['auxiliary_snapshot_sha256']={'site-info':review['site_info_snapshot']['sha256']}
        counts=dict(input_rows=81,compile_only_rows=79,source_unavailable_rows=0,site_metadata_rows=2,
                    dispatched_rows=0,expanded_pages=0,fallback_pages=0,duplicate_rows=0)
        row=dict(id=0,name='',kind='language',**dict(counts,input_rows=2,compile_only_rows=0))
        compile_only=dict(id=10,name='Template',kind=None,**dict(counts,input_rows=79,site_metadata_rows=0))
        report=dict(version=1,registry_sha256='a'*64,site_info_sha256=review['site_info_snapshot']['sha256'],namespaces=[row,compile_only])
        complete=json.loads((root/'complete.json').read_bytes())
        complete['build_inputs']=accepted['build_inputs'];complete['namespace_coverage_totals']=counts
        write_json(root/'complete.json',complete);review['namespace_coverage_totals']=counts
        self.rewrite_report(data,'namespace-coverage.json',report)
        return data

    def test_site_metadata_review_forwards_original_captured_authority(self):
        self.check(self.site_metadata_fixture())

    def test_site_metadata_review_missing_authority_stays_strict(self):
        data=self.site_metadata_fixture();del data[2]['editions'][0]['site_info_snapshot']
        with self.assertRaisesRegex(ValueError,'requires pinned site info'):self.check(data)

    def test_site_metadata_review_changed_or_wrong_edition_authority_refused(self):
        for suffix in ('changed','wrong-edition','wrong-date'):
            with self.subTest(suffix=suffix):
                data=self.site_metadata_fixture(suffix);review=data[2]['editions'][0]
                path=Path(review['site_info_snapshot']['path']);site=json.loads(path.read_bytes())
                site['wiki']='otherwiktionary'
                if suffix=='wrong-date':site['wiki']=data[1][0]['edition'];site['date']='20260901'
                write_json(path,site)
                if suffix!='changed':
                    review['site_info_snapshot']=controller.descriptor(path)
                    accepted=data[1][0]['accepted'];root=Path(accepted['root'])
                    accepted['build_inputs']['auxiliary_snapshot_sha256']['site-info']=review['site_info_snapshot']['sha256']
                    complete=json.loads((root/'complete.json').read_bytes());complete['build_inputs']=accepted['build_inputs']
                    write_json(root/'complete.json',complete)
                    self.rewrite_report(data,'namespace-coverage.json',json.loads((root/'namespace-coverage.json').read_bytes()))
                with self.assertRaises(ValueError):self.check(data)

    def test_site_metadata_report_authority_cannot_replace_accepted_input(self):
        data=self.site_metadata_fixture();accepted=data[1][0]['accepted'];review=data[2]['editions'][0]
        path=Path(review['site_info_snapshot']['path']);site=json.loads(path.read_bytes())
        site['query']['general']['mainpage']='Different Main Page';write_json(path,site)
        review['site_info_snapshot']=controller.descriptor(path)
        report=json.loads((Path(accepted['root'])/'namespace-coverage.json').read_bytes())
        report['site_info_sha256']=review['site_info_snapshot']['sha256']
        self.rewrite_report(data,'namespace-coverage.json',report)
        with self.assertRaisesRegex(ValueError,'differs from accepted build inputs'):self.check(data)


class UnsectionedNoticeFixture:
    """Synthetic review evidence only; never a tested native publication."""
    def __init__(self, top):
        self.top=top;self.serial=0
        self.source,self.rows,self.review=content_review_fixture(top,controller.PILOT,fallback_reasons=['missing_language_heading'])
        self.accepted=self.rows[0]['accepted'];self.er=self.review['editions'][0]
        self.producer_changes={};self.item_changes={};self.authority_changes={};self.output_changes={};self.body_changes={}
        self.raw="<div style='font-weight:bold'>This wiki is closed; see [https://example.test/closure closure].</div>\n----\n''Number of Articles: 0''"
        self.entry=dict(title='entry',language='Test language',language_code='test',sections=[dict(level=2,title='',blocks=[
            dict(kind='paragraph',spans=[dict(kind='text',text='This wiki is closed; see ',bold=True),
                dict(kind='external_link',text='closure',target='https://example.test/closure',bold=True),dict(kind='text',text='.',bold=True)]),
            dict(kind='rule',spans=[]),dict(kind='paragraph',spans=[dict(kind='text',text='Number of Articles: 0',italic=True,bold=False)])])])
    def save(self,name,value):
        self.serial+=1;p=self.top/('notice-%d-%s'%(self.serial,name))
        p.write_bytes(value if isinstance(value,bytes)else json.dumps(value,ensure_ascii=False,sort_keys=True).encode())
        return controller.descriptor(p)
    def seal(self):
        complete=controller.read_ref(self.accepted['complete']);raw=self.save('source',self.raw.encode())
        producer=dict(namespace=0,title='entry',page_id=51,revision_id=73,build_inputs=complete['build_inputs'],raw_source=raw,source_input=complete['build_inputs']['files'][0])
        producer.update(self.producer_changes);producer=self.save('producer',producer)
        classifier=self.save('classifier',b'// synthetic classifier authority, not executed\n')
        snapshot=self.save('snapshot',dict(self.source,files={'src/encoder/blob_builder.zig':classifier}))
        authority=dict(schema='wikidict.nonlexical-notice-source-review.v1',raw_source=raw,producer_row=producer,
            whole_source_reviewed=True,nonlexical_notice=True,no_authored_language_declaration=True,no_authored_lexical_sections=True,
            producer_default_owner_observed=True,explanation='Whole source is a closure notice; no lexical declaration is present.',
            source_snapshot=snapshot,classifier_source=classifier,evidence=[snapshot,classifier],expected_entries_by_owner={'Test language':[copy.deepcopy(self.entry)]})
        authority.update(self.authority_changes);authority=self.save('authority',authority)
        inventory=self.save('inventory',dict(schema='dict.languages.v1',query='entry',accounting=[dict(heading='Test language',records=17)]))
        invcmd=self.save('inventory-command',dict(argv=['/synthetic/reader','languages','entry','--root',self.accepted['root']],exit_code=0,error=None,remaining_owned_processes=[],stdout=inventory))
        body=dict(schema='dict.results.v1',query='entry',language='Test language',operation='lookup',offset=0,record_count=21,total_matches=1,has_more=False,entries=[copy.deepcopy(self.entry)])
        body.update(self.body_changes);lookup=self.save('lookup',body)
        cmd=self.save('lookup-command',dict(argv=['/synthetic/reader','lookup','entry','--root',self.accepted['root'],'--language','Test language'],exit_code=0,error=None,remaining_owned_processes=[],stdout=lookup))
        output=dict(schema='wikidict.manual-page-review.v1',verdict='pass-with-documented-source-limitation',complete=self.accepted['complete'],raw_source=raw,producer_row=producer,
            all_positive_owners_accounted=True,whole_page_payload_conserved=True,known_owners_preserved=True,notice_text_actions_styles_and_rules_conserved=True,
            language_inventory=inventory,inventory_command=invcmd,owner_exports=[dict(owner='Test language',lookup=lookup,command=cmd)],fallback=dict(namespace=0,title='entry',reasons=['missing_language_heading']))
        output.update(self.output_changes);output=self.save('output-review',output)
        item=dict(schema='wikidict.source-authored-unsectioned-notice.v1',edition=complete['edition'],date=complete['date'],complete=self.accepted['complete'],build_inputs=complete['build_inputs'],
            namespace=0,title='entry',page_id=51,revision_id=73,raw_source=raw,producer_row=producer,source_review=authority,source_evidence=[raw,producer,authority],
            output_review=output,output_evidence=[output,inventory,invcmd,lookup,cmd])
        item.update(self.item_changes);self.item=self.save('limitation',item)
        self.er['source_authored_unsectioned_notices']=[self.item]
        self.er['content_review'].update(source_unsectioned_notices_present=True,source_unsectioned_notice_count=1,no_product_missing_language_errors=True)
        return self
    def check(self):return controller.validate_content_review(self.review,self.source,self.rows,controller.PILOT,scope='pilot')


class UnsectionedNoticeTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.addCleanup(self.tmp.cleanup);self.top=Path(self.tmp.name).resolve();self.serial=0
    def fixture(self):
        self.serial+=1;p=self.top/str(self.serial);p.mkdir();return UnsectionedNoticeFixture(p)
    def test_exact_notice_preserves_diagnostic_and_independent_language_claims(self):
        f=self.fixture().seal();before=copy.deepcopy(f.review);raw=Path(f.accepted['reports']['fallback-pages.jsonl']['path']).read_bytes()
        self.assertIs(f.check(),f.review);self.assertEqual(before,f.review);self.assertEqual(raw,Path(f.accepted['reports']['fallback-pages.jsonl']['path']).read_bytes())
        self.assertTrue(f.er['content_review']['no_unresolved_language_declarations'])
        del f.er['source_authored_unsectioned_notices']
        with self.assertRaisesRegex(ValueError,'remains unresolved'):f.check()
        source,rows,review=content_review_fixture(self.top/'clean',controller.PILOT)
        content=review['editions'][0]['content_review']
        content.update(source_unsectioned_notices_present=False,source_unsectioned_notice_count=0,no_product_missing_language_errors=True)
        controller.validate_content_review(review,source,rows,controller.PILOT,scope='pilot')
        for key,value in (('source_unsectioned_notices_present',True),('source_unsectioned_notice_count',1)):
            old=content[key];content[key]=value
            with self.subTest(key=key),self.assertRaises(ValueError):controller.validate_content_review(review,source,rows,controller.PILOT,scope='pilot')
            content[key]=old
    def test_other_completion_revision_input_or_source_cannot_borrow_notice_proof(self):
        for change in (dict(revision_id=74),dict(page_id=52),dict(title='other'),dict(source_input=['other'])):
            f=self.fixture();f.producer_changes=change;f.seal()
            with self.subTest(change=change),self.assertRaises(ValueError):f.check()
        f=self.fixture();f.item_changes={'complete':dict(path='/historical/complete',bytes=1,sha256='0'*64)};f.seal()
        with self.assertRaises(ValueError):f.check()
        f=self.fixture();f.authority_changes={'source_snapshot':dict(path='/historical/source',bytes=1,sha256='0'*64)};f.seal()
        with self.assertRaises(ValueError):f.check()
    def test_lexical_or_unreviewed_source_and_false_clear_claims_refused(self):
        for key in ('whole_source_reviewed','nonlexical_notice','no_authored_language_declaration','no_authored_lexical_sections','producer_default_owner_observed'):
            f=self.fixture();f.authority_changes={key:False};f.seal()
            with self.subTest(key=key),self.assertRaises(ValueError):f.check()
        for key,value in (('source_unsectioned_notices_present',False),('source_unsectioned_notice_count',0),('no_product_missing_language_errors',False)):
            f=self.fixture().seal();f.er['content_review'][key]=value
            with self.subTest(key=key),self.assertRaises(ValueError):f.check()
    def test_lost_text_action_style_rule_or_owner_cannot_pass_whole_body_review(self):
        for part in ('text','action','bold','italic','rule','owner','pagination'):
            f=self.fixture();entry=copy.deepcopy(f.entry);blocks=entry['sections'][0]['blocks']
            if part=='text':blocks[0]['spans'][0]['text']='truncated'
            elif part=='action':blocks[0]['spans'][1]['target']='https://example.test/wrong'
            elif part=='bold':blocks[0]['spans'][1]['bold']=False
            elif part=='italic':blocks[2]['spans'][0]['italic']=False
            elif part=='rule':blocks.pop(1)
            elif part=='owner':entry['language']='Other'
            f.body_changes={'entries':[entry]}
            if part=='pagination':f.body_changes['has_more']=True
            f.seal()
            with self.subTest(part=part),self.assertRaises(ValueError):f.check()
        f=self.fixture();f.output_changes={'owner_exports':[]};f.seal()
        with self.assertRaises(ValueError):f.check()
    def test_exact_single_row_no_overlap_duplicates_unused_or_extra_error(self):
        f=self.fixture().seal();f.er['source_authored_unsectioned_notices']*=2
        with self.assertRaises(ValueError):f.check()
        p=self.top/'fallback';row=dict(namespace=0,title='entry',reasons=['missing_language_heading']);notices={(0,'entry'):row}
        for rows in ([],[row,row],[dict(row,title='other')],[dict(row,reasons=['missing_language_heading','expansion_error'])]):
            p.write_text(''.join(json.dumps(r)+'\n'for r in rows))
            with self.subTest(rows=rows),self.assertRaises(ValueError):controller._review_fallbacks(p,len(rows),unsectioned_notices=notices)
        p.write_text(json.dumps(row)+'\n')
        with self.assertRaises(ValueError):controller._review_fallbacks(p,1,source_limitations=notices,unsectioned_notices=notices)


class SourceLimitationFixture:
    def __init__(self,top,*,label='رموز',inline=False):
        self.top=top;self.serial=0;self.label=label
        self.data=content_review_fixture(top,controller.PILOT,fallback_reasons=['unresolved_language_heading'],unclassified=True)
        self.source,self.rows,self.review=self.data;self.row=self.rows[0];self.accepted=self.row['accepted'];self.edition=self.row['edition']
        self.root=Path(self.accepted['root']);self.er=self.review['editions'][0]
        declaration='{{اللغة|'+label+'}}';self.raw=(('prefix '+declaration+' suffix') if inline else ('== '+declaration+' =='))+'\n# retained symbol sense\n== {{اللغة|إنجليزية}} ==\n# retained known sense\n'
        self.declaration=dict(start=self.raw.encode().index(declaration.encode()),text=declaration)
        self.declaration['end']=self.declaration['start']+len(declaration.encode())
        self.registry='# wikidict-language-registry-v2\n# content-language\tar\nen\tEnglish\ten\nzxx\tNo linguistic content\tzxx\n'
        self.producer_changes={};self.item_changes={};self.output_changes={};self.convention_changes={}
        self.lookup_changes={};self.command_changes={};self.inventory_changes={};self.inventory_command_changes={}
        self.owner_records={'Unclassified':293,'English':701};self.alias_records=89
    def rawref(self,name,data):
        self.serial+=1;p=self.top/('evidence-%d-%s'%(self.serial,name));p.write_bytes(data);return controller.descriptor(p)
    def save(self,name,value):return self.rawref(name,json.dumps(value,ensure_ascii=False,sort_keys=True).encode())
    def seal(self):
        raw=self.rawref('source.wikitext',self.raw.encode());registry=self.rawref('registry.tsv',self.registry.encode())
        complete=controller.read_ref(self.accepted['complete']);inputs=copy.deepcopy(complete['build_inputs']);inputs['auxiliary_snapshot_sha256']={'language-registry':registry['sha256']}
        complete['build_inputs']=inputs
        # Preserve ordinary authenticated completion/snapshot joins after adding the selected registry.
        for d in (self.accepted['complete'],self.accepted['complete_snapshot']):write_json(Path(d['path']),complete)
        self.accepted['complete']=controller.descriptor(Path(self.accepted['complete']['path']));self.accepted['complete_snapshot']=controller.descriptor(Path(self.accepted['complete_snapshot']['path']));self.accepted['build_inputs']=inputs
        self.er['complete']=self.accepted['complete'];self.er['content_review']['complete_sha256']=self.accepted['complete']['sha256'];self.er['content_review']['build_inputs']=inputs
        self.review['accepted_completions'][self.edition]=self.accepted['complete']['sha256']
        resolver=self.rawref('resolver.zig',b'// synthetic captured resolver source; never executed\n')
        snapshot=self.save('snapshot.json',dict(self.source,files={'tools/language_registry.zig':resolver}))
        docs=self.rawref('docs.txt','Synthetic review fixture: declaration convention is explicitly documented.'.encode())
        convention=dict(label=self.label,canonical_language=None,source_authored_unsupported_declaration=True,known_language_alias_omission=False,
            actual_producer_classification_observed=True,normal_registry_source_reviewed=True,no_new_resolver_query=True,
            source_snapshot=snapshot,resolver_source=resolver,evidence=[snapshot,resolver,docs])
        convention.update(self.convention_changes);convention=self.save('convention.json',convention)
        producer=dict(namespace=0,title='entry',page_id=51,revision_id=73,build_inputs=inputs,raw_source=raw,source_input=inputs['files'][0]);producer.update(self.producer_changes)
        producer=self.save('producer.json',producer)
        accounting=[dict(heading='Unclassified',records=self.owner_records['Unclassified'],code='',classification='unverified'),dict(heading='English',records=self.owner_records['English'],code='en',classification='language')]
        inventory=dict(schema='dict.languages.v1',scope='entry',query='entry',accounting=accounting,languages=['Unclassified','English'],heading_count=2,language_count=1,translingual_count=0,unverified_count=1)
        inventory.update(self.inventory_changes);inventory=self.save('inventory.json',inventory)
        invcmd=dict(argv=['/synthetic/reader','languages','entry','--root',self.accepted['root']],exit_code=0,error=None,remaining_owned_processes=[],stdout=inventory);invcmd.update(self.inventory_command_changes)
        invcmd=self.save('inventory-command.json',invcmd);exports=[];out_evidence=[inventory,invcmd]
        for owner in ('Unclassified','English'):
            body=dict(schema='dict.results.v1',operation='lookup',kind='language',query='entry',language=owner,offset=0,record_count=self.owner_records[owner]+self.alias_records,total_matches=1,has_more=False,
                entries=[dict(title='entry',language=owner,language_code='' if owner=='Unclassified' else 'en',sections=[dict(level=2,title=self.label if owner=='Unclassified' else 'English',blocks=[dict(kind='definition',spans=[dict(kind='text',text='retained symbol sense' if owner=='Unclassified' else 'retained known sense')])])])])
            body.update(self.lookup_changes.get(owner,{}));lookup=self.save('lookup.json',body)
            command=dict(argv=['/synthetic/reader','lookup','entry','--root',self.accepted['root'],'--language',owner,'--format','json','--limit','1000'],exit_code=0,error=None,remaining_owned_processes=[],stdout=lookup)
            command.update(self.command_changes.get(owner,{}));command=self.save('command.json',command)
            exports.append(dict(owner=owner,lookup=lookup,command=command));out_evidence.extend([lookup,command])
        output=dict(schema='wikidict.manual-page-review.v1',verdict='pass-with-documented-source-defect',complete=self.accepted['complete'],raw_source=raw,producer_row=producer,label=self.label,
            all_positive_owners_accounted=True,whole_page_payload_conserved=True,known_owners_preserved=True,language_inventory=inventory,inventory_command=invcmd,
            owner_exports=exports,fallback=dict(namespace=0,title='entry',reasons=['unresolved_language_heading']))
        output.update(self.output_changes);output=self.save('output-review.json',output);out_evidence.append(output)
        item=dict(schema='wikidict.source-authored-unresolved-declaration.v1',edition=self.edition,date=complete['date'],complete=self.accepted['complete'],build_inputs=inputs,
            namespace=0,title='entry',page_id=51,revision_id=73,label=self.label,raw_source=raw,producer_row=producer,registry=registry,declaration_convention=convention,declaration=self.declaration,
            source_evidence=[raw,producer,registry,convention],output_review=output,output_evidence=out_evidence)
        item.update(self.item_changes);self.item=self.save('limitation.json',item);self.er['source_authored_unresolved_declarations']=[self.item]
        self.er['content_review'].update(no_unresolved_language_declarations=False,source_unresolved_declarations_present=True,product_unresolved_language_errors=False,source_limitation_count=1)
        self.er['dispositions']['unclassified']['explanation']='Exact unsupported source label and both owner payloads retained; source declaration remains unresolved.'
        return self
    def check(self):return controller.validate_content_review(self.review,self.source,self.rows,controller.PILOT,scope='pilot')
class SourceLimitationTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.addCleanup(self.tmp.cleanup);self.top=Path(self.tmp.name).resolve();self.count=0
    def fixture(self,**kw):
        self.count+=1;p=self.top/str(self.count);p.mkdir();return SourceLimitationFixture(p,**kw)
    def test_clean_default_and_unproved_unresolved_remain_strict(self):
        source,rows,value=content_review_fixture(self.top/'legacy',controller.PILOT)
        controller.validate_content_review(value,source,rows,controller.PILOT,scope='pilot')
        f=self.fixture().seal();del f.er['source_authored_unresolved_declarations']
        with self.assertRaises(ValueError):f.check()
    def test_exact_evidence_passes_without_clearing_source_declaration_or_fallback(self):
        f=self.fixture().seal();before=(Path(f.accepted['reports']['fallback-pages.jsonl']['path']).read_bytes(),copy.deepcopy(f.review))
        self.assertIs(f.check(),f.review);self.assertEqual(before,(Path(f.accepted['reports']['fallback-pages.jsonl']['path']).read_bytes(),f.review))
        self.assertFalse(f.er['content_review']['no_unresolved_language_declarations'])
    def test_multi_record_stores_with_or_without_alias_overlay_keep_one_exact_title(self):
        for alias_records in (0,89):
            f=self.fixture();f.alias_records=alias_records;f.seal()
            self.assertIs(f.check(),f.review)
            output=controller.read_ref(controller.read_ref(f.item)['output_review'])
            for exported in output['owner_exports']:
                body=controller.read_ref(exported['lookup'])
                self.assertEqual(body['record_count'],f.owner_records[exported['owner']]+alias_records)
                self.assertEqual((body['total_matches'],len(body['entries']),body['offset'],body['has_more']),(1,1,0,False))
    def test_whole_store_counts_cannot_substitute_for_exact_match_or_undercount_owner(self):
        for changes in (dict(record_count=292),dict(record_count=True),dict(record_count='382'),
                        dict(total_matches=382),dict(total_matches=True),dict(total_matches=0),dict(entries=[])):
            f=self.fixture();f.lookup_changes={'Unclassified':changes};f.seal()
            with self.subTest(changes=changes),self.assertRaises(ValueError):f.check()
    def test_other_page_revision_input_or_completion_cannot_borrow_proof(self):
        for changes in (dict(revision_id=74),dict(page_id=52),dict(source_input=['other']),dict(title='elsewhere')):
            f=self.fixture();f.producer_changes=changes;f.seal()
            with self.subTest(changes=changes),self.assertRaises(ValueError):f.check()
        f=self.fixture();f.item_changes={'complete':dict(path='/diagnostic/complete.json',bytes=1,sha256='0'*64)};f.seal()
        with self.assertRaises(ValueError):f.check()
    def test_exact_byte_span_and_actual_heading_required(self):
        f=self.fixture(inline=True).seal()
        with self.assertRaises(ValueError):f.check()
        f=self.fixture();f.declaration['start']+=1;f.seal()
        with self.assertRaises(ValueError):f.check()
    def test_known_alias_or_unreviewed_normal_resolver_cannot_be_source_exception(self):
        f=self.fixture(label='English').seal()
        with self.assertRaises(ValueError):f.check()
        for key in ('normal_registry_source_reviewed','actual_producer_classification_observed','no_new_resolver_query'):
            f=self.fixture();f.convention_changes={key:False};f.seal()
            with self.subTest(key=key),self.assertRaises(ValueError):f.check()
    def test_false_clear_or_product_error_claims_rejected(self):
        for key,val in [('no_unresolved_language_declarations',True),('source_unresolved_declarations_present',False),('product_unresolved_language_errors',True),('source_limitation_count',0)]:
            f=self.fixture().seal();f.er['content_review'][key]=val
            with self.subTest(key=key),self.assertRaises(ValueError):f.check()
    def test_known_owner_omission_cross_owner_or_lost_label_rejected(self):
        for changes in (dict(known_owners_preserved=False),dict(whole_page_payload_conserved=False),dict(owner_exports=[])):
            f=self.fixture();f.output_changes=changes;f.seal()
            with self.subTest(changes=changes),self.assertRaises(ValueError):f.check()
        f=self.fixture();f.lookup_changes={'Unclassified':dict(entries=[dict(title='entry',language='Unclassified',sections=[dict(title='other')])])};f.seal()
        with self.assertRaises(ValueError):f.check()
    def test_inventory_and_lookup_must_read_actual_accepted_root(self):
        for inventory in (True,False):
            f=self.fixture();bad=dict(argv=['/synthetic/reader','languages' if inventory else 'lookup','entry','--root','/diagnostic/root','--language','English'])
            if inventory:f.inventory_command_changes=bad
            else:f.command_changes={'English':bad}
            f.seal()
            with self.subTest(inventory=inventory),self.assertRaises(ValueError):f.check()
    def test_full_export_pagination_counts_and_owner_identity_are_checked(self):
        for changes in (dict(offset=1),dict(has_more=True),dict(total_matches=2),dict(record_count=0),dict(language='Unclassified')):
            f=self.fixture();f.lookup_changes={'English':changes};f.seal()
            with self.subTest(changes=changes),self.assertRaises(ValueError):f.check()
    def test_only_exact_single_fallback_rows_are_matched(self):
        row=dict(namespace=0,title='entry',reasons=['unresolved_language_heading']);p=self.top/'fallback.jsonl';limits={(0,'entry'):row}
        for rows in ([dict(row,title='other')],[dict(row,reasons=['unresolved_language_heading','expansion_error'])],[row,row],[]):
            p.write_text(''.join(json.dumps(r)+'\n' for r in rows))
            with self.subTest(rows=rows),self.assertRaises(ValueError):controller._review_fallbacks(p,len(rows),source_limitations=limits)
    def test_duplicate_exception_and_changed_evidence_rejected(self):
        f=self.fixture().seal();f.er['source_authored_unresolved_declarations']*=2
        with self.assertRaises(ValueError):f.check()
        f=self.fixture().seal();Path(f.item['path']).write_text('{}')
        with self.assertRaises(ValueError):f.check()
    def test_diagnostic_cohort_cannot_be_final198_or_hide_other_failures(self):
        f=self.fixture().seal()
        with self.assertRaises(ValueError):controller.validate_content_review(f.review,f.source,f.rows,[r['edition'] for r in f.rows],scope='final')
        f.review['unresolved_render_failures']=['actual error']
        with self.assertRaises(ValueError):f.check()


class LuaReviewFixture:
    rawref = SourceLimitationFixture.rawref
    save = SourceLimitationFixture.save

    def __init__(self, top):
        self.top = top
        self.serial = 0
        self.source, self.rows, self.review = content_review_fixture(
            top, controller.PILOT, fallback_reasons=['rendered_lua_error'], unclassified=True)
        self.accepted = self.rows[0]['accepted']
        self.edition = self.rows[0]['edition']
        self.er = self.review['editions'][0]
        self.owner_records = {'Unclassified': 293, 'English': 701}
        self.alias_records = 89
        self.inventory_root = None
        self.lookup_roots = {}
        self.lookup_changes = {}
        self.command_changes = {}
        self.inventory_changes = {}
        self.inventory_command_changes = {}
        self.item_changes = {}
        self.producer_changes = {}
        self.dependency_changes = {}
        self.trace_changes = {}
        self.output_changes = {}
        self.binding_changes = {}
        self.result_changes = {}
        self.execution_changes = {}
        self.transport_changes = {}
        self.closure_changes = {}
        self.qualification_changes = {}
        self.extra_body_error = False
        self.drop_command = False
        self.drop_snapshot = False
        self.message = 'Lua error in Module:Fixture at line 7: bad argument'

    def seal(self):
        complete = controller.read_ref(self.accepted['complete'])
        inputs = complete['build_inputs']
        raw = self.rawref('source.wikitext', b'==English==\n{{fixture-call|bad}}\n# retained lexical sense\n')
        snapshot = self.save('source-snapshot.json', dict(self.source, files={}))
        producer = dict(namespace=0, title='entry', page_id=51, revision_id=73,
            build_inputs=inputs, raw_source=raw, source_input=inputs['files'][0])
        producer.update(self.producer_changes)
        producer_ref = self.save('producer.json', producer)
        dependency_raw = self.rawref('dependency.lua', b'return {run=function(value) error("bad argument") end}\n')
        dependency = dict(namespace=828, title='Module:Fixture', page_id=151, revision_id=173,
            source_input=inputs['files'][0], raw_source=dependency_raw)
        dependency.update(self.dependency_changes)
        dependency_ref = self.save('dependency.json', dependency)
        reader = self.rawref('reader', b'Synthetic Reader identity only; never executed')
        self.reader = reader
        qualification = dict(schema='wikidict.durable-fresh-qualification-result.v1',passed=True, source_guard=True, installed_reader=reader)
        qualification.update(self.qualification_changes)
        qualification_ref = self.save('qualification-result.json', qualification)
        stderr = self.rawref('stderr', b'')
        owners = ['Unclassified', 'English']
        inventory = dict(schema='dict.languages.v1', scope='entry', query='entry',
            accounting=[dict(heading=x, records=self.owner_records[x], code='' if x=='Unclassified' else 'en',
                classification='unverified' if x=='Unclassified' else 'language') for x in owners],
            languages=owners, heading_count=2, language_count=1, translingual_count=0, unverified_count=1)
        inventory.update(self.inventory_changes)
        inventory_ref = self.save('inventory.json', inventory)
        identities = []
        def command(argv, stdout, changes):
            identity = dict(pid=1001+len(identities), start_time_ticks=5001+len(identities),
                process_group=1000, session=1000)
            identities.append(identity)
            # Literal normal-batch command schema: no fictional error/remaining-process fields.
            value = dict(argv=argv, exit_code=0, identity=identity, reaped=True, stderr=stderr, stdout=stdout)
            value.update(changes)
            return self.save('command.json', value)
        inventory_command = command([reader['path'],'languages','entry','--root',self.inventory_root or self.accepted['root'],
            '--format','json'], inventory_ref, self.inventory_command_changes)
        exports = []
        expected_errors = []
        self.commands = [inventory_command]
        for owner in owners:
            spans = [dict(kind='text', text='retained lexical sense', classes='')]
            for index in range(2 if owner=='Unclassified' else 1):
                spans.append(dict(kind='text', text=self.message, classes='error scribunto-error'))
                expected_errors.append(dict(owner=owner,
                    path=['entries',0,'sections',0,'blocks',0,'spans',index+1], message=self.message))
            if self.extra_body_error and owner=='English':
                spans.append(dict(kind='text', text='Lua error in Module:Extra at line 9: extra failure', classes='scribunto-error'))
            body = dict(schema='dict.results.v1', operation='lookup', kind='language', query='entry', language=owner,
                offset=0, record_count=self.owner_records[owner]+self.alias_records, total_matches=1, has_more=False,
                entries=[dict(title='entry',language=owner,language_code='' if owner=='Unclassified' else 'en',
                    sections=[dict(title=owner,level=2,blocks=[dict(kind='definition',spans=spans)])])])
            body.update(self.lookup_changes.get(owner, {}))
            lookup = self.save('lookup.json', body)
            cmd = command([reader['path'],'lookup','entry','--root',self.lookup_roots.get(owner,self.accepted['root']),'--format','json',
                '--language',owner], lookup, self.command_changes.get(owner, {}))
            self.commands.append(cmd)
            exports.append(dict(owner=owner,lookup=lookup,command=cmd))
        inputs_selected = [reader, qualification_ref, self.accepted['complete'], self.accepted['complete_snapshot']]
        if self.drop_snapshot: inputs_selected.pop()
        binding = dict(schema='wikidict.saved-publication-reader-triage-binding.v1', reader=reader,
            inputs=inputs_selected, requests=[dict(edition=self.edition,key='fixture-0',root=self.accepted['root'],title='entry')],
            production_seconds=0)
        binding.update(self.binding_changes)
        binding_ref = self.save('binding.json', binding)
        row = dict(edition=self.edition,title='entry',inventory=inventory_ref,inventory_command=inventory_command,
            owners=[dict(owner=x['owner'],command=x['command'],export=x['lookup']) for x in exports])
        result = dict(schema='wikidict.saved-publication-reader-triage.v1', passed=True,error=None,reader=reader,rows=[row],
            production_seconds=0,semantic_acceptance_claimed=False)
        result.update(self.result_changes)
        result_ref = self.save('query-result.json', result)
        execution = dict(exit_code=0,worker_result=result_ref,binding=binding_ref,production_seconds=0)
        execution.update(self.execution_changes)
        execution_ref = self.save('execution.json', execution)
        transport = dict(exit_code=0,reaped=True,error=None)
        transport.update(self.transport_changes)
        transport_ref = self.save('transport.json', transport)
        closed_commands = list(self.commands)
        if self.drop_command: closed_commands.pop()
        closure = dict(schema='wikidict.bounded-reader-queries-independent-closure.v1', outcome='passed-closed',
            passed=True,cleanup_proven=True,all_recorded_identities_absent=True,
            all_owned_groups_and_sessions_empty=True,remaining_owned_processes=[],
            result=result_ref,execution=execution_ref,transport=transport_ref,binding=binding_ref,reader=reader,
            commands=closed_commands,recorded_identities=identities,title_requests=1,command_count=3,
            semantic_acceptance=False,unit_tests_executed=False,producer_executed=False,product_cli_executed=True,
            qualification_scope='Synthetic saved-query metadata fixture; no CLI executed',production_seconds=0)
        closure.update(self.closure_changes)
        closure_ref = self.save('query-closure.json', closure)
        output = dict(schema='wikidict.manual-page-review.v1',verdict='pass-with-documented-source-defect',
            complete=self.accepted['complete'],raw_source=raw,producer_row=producer_ref,
            independent_limitations=[],all_positive_owners_accounted=True,full_payload_reviewed=True,
            all_non_error_content_conserved=True,known_owners_preserved=True,all_actions_reviewed=True,
            query_closure=closure_ref,reader_qualification=qualification_ref,
            language_inventory=inventory_ref,inventory_command=inventory_command,owner_exports=exports,
            lua_error_spans=expected_errors,fallback=dict(namespace=0,title='entry',reasons=['rendered_lua_error']))
        output.update(self.output_changes)
        self.output = output
        output_ref = self.save('manual-output-review.json', output)
        output_evidence = [inventory_ref,inventory_command,qualification_ref,closure_ref,output_ref]
        for x in exports: output_evidence.extend([x['lookup'],x['command']])
        trace_evidence = [raw,producer_ref,snapshot,dependency_raw,dependency_ref]
        trace = dict(schema='wikidict.manual-lua-source-trace.v1',edition=self.edition,date=complete['date'],
            namespace=0,title='entry',page_id=51,revision_id=73,raw_source=raw,producer_row=producer_ref,
            source_snapshot=snapshot,complete=self.accepted['complete'],build_inputs=inputs,
            captured_source_defect=True,product_runtime_defect=False,explanation='Synthetic authored argument mismatch.',
            evidence=trace_evidence,captured_dependencies=[dependency_ref],lua_error_spans=expected_errors,
            causes=[dict(span=error,kind='authored-argument-mismatch',explanation='Literal captured caller passes unsupported argument.',
                evidence=[raw,dependency_ref,dependency_raw]) for error in expected_errors])
        trace.update(self.trace_changes)
        trace_ref = self.save('source-trace.json', trace)
        item = dict(schema='wikidict.source-authored-lua-defect.v1',edition=self.edition,date=complete['date'],
            namespace=0,title='entry',page_id=51,revision_id=73,raw_source=raw,producer_row=producer_ref,
            source_snapshot=snapshot,source_trace=trace_ref,complete=self.accepted['complete'],build_inputs=inputs,
            source_evidence=[raw,producer_ref,snapshot,trace_ref],output_review=output_ref,output_evidence=output_evidence)
        item.update(self.item_changes)
        self.item = self.save('lua-defect.json', item)
        self.er['source_authored_lua_defects'] = [self.item]
        self.er['content_review'].update(no_build_render_errors=False,no_product_build_render_errors=True,
            source_authored_lua_defects_present=True,source_lua_defect_count=1,source_lua_error_message_count=3)
        return self

    def check(self):
        return controller.validate_content_review(self.review,self.source,self.rows,controller.PILOT,scope='pilot')


class SourceLuaDefectTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.top = Path(self.tmp.name).resolve()
        self.serial = 0

    def fixture(self):
        self.serial += 1
        root = self.top / str(self.serial)
        root.mkdir()
        return LuaReviewFixture(root)

    def test_default_remains_strict_and_complete_clean_legacy_review_is_unchanged(self):
        source,rows,value = content_review_fixture(self.top/'clean',controller.PILOT)
        self.assertIs(controller.validate_content_review(value,source,rows,controller.PILOT,scope='pilot'),value)
        f=self.fixture().seal();del f.er['source_authored_lua_defects']
        with self.assertRaises(ValueError):f.check()

    def test_full_multiowner_alias_store_review_preserves_three_repeated_semantic_errors(self):
        f=self.fixture().seal();before=copy.deepcopy(f.review)
        self.assertIs(f.check(),f.review)
        self.assertEqual(before,f.review)
        self.assertFalse(f.er['content_review']['no_build_render_errors'])
        self.assertEqual(f.er['content_review']['source_lua_error_message_count'],3)
        for cmd in f.commands:
            value=controller.read_ref(cmd)
            self.assertNotIn('remaining_owned_processes',value)
            self.assertNotIn('error',value)
        self.assertEqual(len(f.output['owner_exports']),2)

    def test_extra_or_missing_error_spans_cannot_be_waived_by_existing_source_trace(self):
        f=self.fixture();f.extra_body_error=True;f.seal()
        with self.assertRaisesRegex(ValueError,'extra/missing'):f.check()
        f=self.fixture();f.output_changes={'lua_error_spans':[]};f.seal()
        with self.assertRaises(ValueError):f.check()
        f=self.fixture();f.trace_changes={'lua_error_spans':[]};f.seal()
        with self.assertRaises(ValueError):f.check()

    def test_independent_missing_templates_or_unresolved_owners_and_action_loss_stay_failures(self):
        for changes in (dict(independent_limitations=['missing_template']),dict(independent_limitations=['unresolved_language_heading']),
                        dict(all_actions_reviewed=False),dict(all_non_error_content_conserved=False),
                        dict(full_payload_reviewed=False),dict(known_owners_preserved=False)):
            f=self.fixture();f.output_changes=changes;f.seal()
            with self.subTest(changes=changes),self.assertRaises(ValueError):f.check()

    def test_source_page_revision_input_or_producer_identity_cannot_borrow_the_review(self):
        for changes in (dict(page_id=52),dict(revision_id=74),dict(title='elsewhere'),dict(source_input=['wrong-input'])):
            f=self.fixture();f.producer_changes=changes;f.seal()
            with self.subTest(changes=changes),self.assertRaises(ValueError):f.check()
        f=self.fixture();f.item_changes={'complete':{'path':'/not-selected/complete','bytes':1,'sha256':'0'*64}};f.seal()
        with self.assertRaises(ValueError):f.check()

    def test_captured_dependency_and_source_cause_must_be_complete_and_non_product(self):
        for changes in (dict(page_id=0),dict(revision_id=0),dict(source_input=['wrong-input']),dict(raw_source={})):
            f=self.fixture();f.dependency_changes=changes;f.seal()
            with self.subTest(changes=changes),self.assertRaises(ValueError):f.check()
        for changes in (dict(captured_dependencies=[]),dict(product_runtime_defect=True),dict(captured_source_defect=False),
                        dict(explanation=''),dict(causes=[])):
            f=self.fixture();f.trace_changes=changes;f.seal()
            with self.subTest(changes=changes),self.assertRaises(ValueError):f.check()

    def test_normal_reader_batch_is_required_and_aggregate_cleanup_is_not_invented_per_command(self):
        f=self.fixture();f.output_changes={'query_closure':None};f.seal()
        with self.assertRaises(ValueError):f.check()
        for key in ('passed','cleanup_proven','all_recorded_identities_absent','all_owned_groups_and_sessions_empty'):
            f=self.fixture();f.closure_changes={key:False};f.seal()
            with self.subTest(key=key),self.assertRaises(ValueError):f.check()
        f=self.fixture();f.drop_command=True;f.seal()
        with self.assertRaisesRegex(ValueError,'omitted from closure'):f.check()

    def test_command_identity_membership_reaping_root_and_reader_must_match_actual_closed_batch(self):
        for changes in (dict(identity=dict(pid=999,start_time_ticks=999,process_group=999,session=999)),dict(reaped=False),
                        dict(exit_code=1),dict(argv=['/other/reader','lookup','entry','--root','/wrong','--language','English'])):
            f=self.fixture();f.command_changes={'English':changes};f.seal()
            with self.subTest(changes=changes),self.assertRaises(ValueError):f.check()
        f=self.fixture();f.inventory_command_changes={'argv':['/other/reader','languages','entry','--root','/wrong']};f.seal()
        with self.assertRaises(ValueError):f.check()
        # Correct Reader/PID/closure and export membership still cannot authorize another root.
        for inventory in (True,False):
            f=self.fixture()
            if inventory:f.inventory_root='/diagnostic/root'
            else:f.lookup_roots={'English':'/diagnostic/root'}
            f.seal()
            with self.subTest(inventory=inventory),self.assertRaises(ValueError):f.check()

    def test_completion_snapshot_request_and_saved_result_must_join_the_same_publication(self):
        f=self.fixture();f.drop_snapshot=True;f.seal()
        with self.assertRaisesRegex(ValueError,'snapshot differs'):f.check()
        f=self.fixture();f.binding_changes={'requests':[dict(edition='other',title='entry',root='/wrong')]};f.seal()
        with self.assertRaises(ValueError):f.check()
        f=self.fixture();f.result_changes={'rows':[]};f.seal()
        with self.assertRaises(ValueError):f.check()

    def test_reader_qualification_result_and_execution_transport_joins_remain_required(self):
        for changes in (dict(passed=False),dict(source_guard=False),dict(installed_reader={}),dict(schema='wikidict.qualification-independent-closure.v1')):
            f=self.fixture();f.qualification_changes=changes;f.seal()
            with self.subTest(changes=changes),self.assertRaises(ValueError):f.check()
        for role in ('binding','result'):
            f=self.fixture();setattr(f,role+'_changes',dict(reader={}));f.seal()
            with self.subTest(role=role),self.assertRaises(ValueError):f.check()
        for role,changes in (('execution',dict(exit_code=1)),('execution',dict(worker_result={})),
                             ('transport',dict(exit_code=1)),('transport',dict(reaped=False)),('transport',dict(error='failed'))):
            f=self.fixture();setattr(f,role+'_changes',changes);f.seal()
            with self.subTest(role=role,changes=changes),self.assertRaises(ValueError):f.check()

    def test_exact_title_matches_are_independent_of_whole_store_and_owner_counts(self):
        for changes in (dict(record_count=292),dict(record_count=True),dict(total_matches=382),dict(total_matches=True),
                        dict(offset=1),dict(has_more=True),dict(entries=[]),dict(language='Unclassified'),dict(query='other')):
            f=self.fixture();f.lookup_changes={'English':changes};f.seal()
            with self.subTest(changes=changes),self.assertRaises(ValueError):f.check()

    def test_missing_owner_export_or_forged_full_review_claim_does_not_cover_owner_loss(self):
        for changes in (dict(owner_exports=[]),dict(all_positive_owners_accounted=False)):
            f=self.fixture();f.output_changes=changes;f.seal()
            with self.subTest(changes=changes),self.assertRaises(ValueError):f.check()

    def test_true_error_counts_and_claims_cannot_be_relabelled_zero_or_product_clean(self):
        for key,value in (('no_build_render_errors',True),('no_product_build_render_errors',False),
                          ('source_authored_lua_defects_present',False),('source_lua_defect_count',0),
                          ('source_lua_error_message_count',1)):
            f=self.fixture().seal();f.er['content_review'][key]=value
            with self.subTest(key=key),self.assertRaises(ValueError):f.check()

    def test_mixed_unused_duplicate_or_unmatched_fallbacks_and_final_scope_remain_strict(self):
        path=self.top/'fallback.jsonl';row=dict(namespace=0,title='entry',reasons=['rendered_lua_error'])
        limits={(0,'entry'):row}
        for rows in ([dict(row,reasons=['rendered_lua_error','missing_template'])],[dict(row,title='other')],[row,row],[]):
            path.write_text(''.join(json.dumps(x)+'\n' for x in rows))
            with self.subTest(rows=rows),self.assertRaises(ValueError):
                controller._review_fallbacks(path,len(rows),source_lua_defects=limits)
        f=self.fixture().seal()
        with self.assertRaises(ValueError):
            controller.validate_content_review(f.review,f.source,f.rows,[x['edition'] for x in f.rows],scope='final')
        f.review['unresolved_render_failures']=['independent actual failure']
        with self.assertRaises(ValueError):f.check()

    def test_changed_authenticated_source_evidence_is_not_reused(self):
        f=self.fixture().seal();Path(f.item['path']).write_text('{}')
        with self.assertRaises(ValueError):f.check()




class ControllerAllReadyTests(unittest.TestCase):
    def editions(self):
        return list(controller.PILOT)+['enwiktionary']+[f'toy{i:03d}wiktionary'for i in range(189)]

    def manifest(self):
        editions=self.editions();files=[]
        for i,wiki in enumerate(editions):
            name=wiki+'-20261001-pages-meta-current.xml.bz2'
            files.append(dict(wiki=wiki,date='20261001',name=name,size=1 if wiki=='arwiktionary'else i+10,
                sha1='a'*40,url='https://dumps.wikimedia.org/'+wiki+'/20261001/'+name))
        return dict(requested_editions=editions,files=files)

    def test_all_phase_orders_all_198_by_xml_size_without_changing_legacy_phases(self):
        manifest=self.manifest();editions=manifest['requested_editions'];before=copy.deepcopy(manifest)
        selected=controller.selected_phase_editions(editions,'all',manifest=manifest)
        self.assertEqual(selected[0],'arwiktionary');self.assertEqual(len(selected),198);self.assertEqual(set(selected),set(editions))
        self.assertEqual(manifest,before)
        self.assertEqual(controller.selected_phase_editions(editions,'pilot'),list(controller.PILOT))
        self.assertEqual(controller.selected_phase_editions(editions,'remaining')[0],'enwiktionary')
        self.assertNotIn('enwiktionary',controller.selected_phase_editions(editions,'all',True,manifest))
        with self.assertRaises(ValueError):controller.selected_phase_editions(editions,'all')

    def run_main(self,root,cleanup=True,unsafe=None,plan=None,history_rows=None,max_editions=None,execute_override=None,manifest_override=None,phase="all",cfg_overrides=None,observe_execute_kwargs=None):
        manifest=self.manifest() if manifest_override is None else manifest_override;cfg=dict(armed=True,source={'head':'a'*40,'fingerprint':'b'*64},
            compiler={'path':str(root/'zig'),'bytes':1,'sha256':'c'*64},
            manifest={'path':str(root/'downloads/manifest.json'),'bytes':1,'sha256':'d'*64},
            downloads=str(root/'downloads'),output=str(root/'output'),raw_shard_root=str(root/'raw'),state_directory=str(root/'state'),
            date='20261001',now_unix=1,expansion_timeout_ms=10,build_timeout_seconds=123,qualification={},diagnostic_disposition={})
        cfg.update(cfg_overrides or {})
        seen=[];written=[];gates=[]
        def execute(cfg,edition,workers,folder,sequence,context,locks,memory_limit_bytes,**kwargs):
            if observe_execute_kwargs is not None: observe_execute_kwargs(kwargs)
            seen.append(edition)
            if execute_override is not None:
                return execute_override(edition, workers, memory_limit_bytes, sequence)
            return (dict(attempt_id='attempt-'+str(sequence),edition=edition,sequence=sequence,
                controller_interrupted=False,cleanup_proven=cleanup,source_guard=unsafe!='source',control_proven=unsafe!='control',elapsed_seconds=0.125,
                execution_mode='pipeline_run_may_reuse_verified_inputs_or_shards',outcome='failed'if edition=='arwiktionary'else'passed',
                accepted=None if edition=='arwiktionary'else dict(input_pages=10)),
                dict(termination_reason='monitor_error' if unsafe=='monitor' else ('sampled_pss_limit' if unsafe=='cap' else 'child_exit'),
                     child_exit_status=-9 if unsafe=='signal' else 1,memory_limit_bytes=memory_limit_bytes))
        with mock.patch.object(controller,'read_json',return_value=cfg), \
             mock.patch.object(controller,'read_ref',return_value=manifest), \
             mock.patch.object(controller,'descriptor',return_value=cfg['compiler']), \
             mock.patch.object(controller,'validate_pipeline_paths'), \
             mock.patch.object(controller,'source_guard') as source_guard, \
             mock.patch.object(controller,'gate',side_effect=lambda value,*args:gates.append(value)or{}), \
             mock.patch.object(controller,'production_context',return_value='current-context'), \
             mock.patch.object(controller,'history',return_value=history_rows or []), \
             mock.patch.object(controller,'campaign_selection',return_value=plan), \
             mock.patch.object(controller,'load_preparations',return_value=[]) as preparations, \
             mock.patch.object(controller,'Lock'), \
             mock.patch.object(controller.resource,'getrlimit',return_value=(controller.resource.RLIM_INFINITY,controller.resource.RLIM_INFINITY)), \
             mock.patch.object(controller.os,'sched_getaffinity',return_value={0,2,4,6}), \
             mock.patch.object(controller,'execute',side_effect=execute), \
             mock.patch.object(controller,'write_json',side_effect=lambda path,value,**kw:written.append(value)), \
             mock.patch('builtins.print'):
            if not cleanup or unsafe:
                with self.assertRaisesRegex(ValueError,'unproven|control validation|Non-ordinary'):controller.main(['--config',str(root/'cfg.json'),'--phase',phase] + ([] if max_editions is None else ['--max-editions',str(max_editions)]))
                return seen
            code=controller.main(['--config',str(root/'cfg.json'),'--phase',phase] + ([] if max_editions is None else ['--max-editions',str(max_editions)]))
        self.assertEqual(len(gates),2) # qualification+diagnostic, never bypassed; no pilot prerequisite
        self.assertGreaterEqual(source_guard.call_count,len(seen)+1);preparations.assert_called_once()
        return code,seen,written[-1]

    def test_real_main_continues_after_closed_pilot_failure_once_without_semantic_credit(self):
        with tempfile.TemporaryDirectory() as tmp:code,seen,summary=self.run_main(Path(tmp))
        self.assertEqual(code,1);self.assertEqual(seen[0],'arwiktionary')
        self.assertEqual(len(seen),198);self.assertEqual(len(set(seen)),198)
        self.assertTrue(all(row['attempt_count']==1 for row in summary['editions']))
        self.assertIsNone(next(row for row in summary['editions']if row['edition']=='arwiktionary')['accepted'])
        self.assertFalse(summary['final_cohort_complete']);self.assertFalse(summary['residual_review_complete'])
        self.assertEqual(summary['observed_cohort_build_seconds'],191*0.125)

    def test_real_main_still_halts_before_next_edition_when_cleanup_unknown(self):
        with tempfile.TemporaryDirectory() as tmp:seen=self.run_main(Path(tmp),False)
        self.assertEqual(seen,['arwiktionary'])


class ControllerProducerScopeTests(unittest.TestCase):
    def fixture(self, root):
        for name, data in {'build.zig': b'build', 'src/main.zig': b'core', 'tools/reviewed_language_aliases.json': b'{"records":[]}'}.items():
            path = root/name; path.parent.mkdir(parents=True, exist_ok=True); path.write_bytes(data); path.chmod(0o644)
        names = ['build.zig', 'src/main.zig', 'tools/reviewed_language_aliases.json']
        inventory = dict(head='qualified', domain='tracked non-app producer inputs',
            files={name: controller.descriptor(root/name) for name in names}, modes={name: 0o644 for name in names})
        write_json(root/'inventory.json', inventory); write_json(root/'manifest.json', {})
        return dict(source=dict(head='qualified', fingerprint='fingerprint', inventory=controller.descriptor(root/'inventory.json')),
                    manifest=controller.descriptor(root/'manifest.json')), names

    def guard(self, root, cfg, names, *, head='qualified', untracked=()):
        def git(argv, **kwargs):
            if argv == ['git', 'rev-parse', 'HEAD']: return head
            if argv == ['git', 'ls-files', '-z']: return ('\0'.join(names + ['apps/desktop/current.cpp'])+'\0').encode()
            if argv == ['git', 'ls-files', '--others', '--exclude-standard', '-z']: return '\0'.join(untracked).encode()
            self.fail('Producer-scoped guard must not impose whole-repository status: '+repr(argv))
        with mock.patch.object(controller, 'ROOT', root), \
             mock.patch.object(controller.subprocess, 'check_output', side_effect=git), \
             mock.patch.dict('sys.modules', {'build_wiktionaries': mock.Mock(source_fingerprint=mock.Mock(return_value='fingerprint'))}):
            return controller.source_guard(cfg)

    def test_dirty_app_and_unrelated_app_commit_preserve_exact_producer(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);cfg,names=self.fixture(root)
            app=root/'apps/desktop/current.cpp';app.parent.mkdir(parents=True);app.write_bytes(b'independent dirty app')
            self.assertEqual(self.guard(root,cfg,names)['current_head'], 'qualified')
            result=self.guard(root,cfg,names,head='app-only-commit')
            self.assertEqual(result['qualified_head'], 'qualified');self.assertEqual(result['current_head'], 'app-only-commit')
            self.assertFalse(result['apps_acceptance']);self.assertEqual(cfg['source']['head'],'qualified')

    def test_dirty_core_and_embedded_alias_bytes_are_rejected_even_with_same_fingerprint(self):
        for name in ('src/main.zig', 'tools/reviewed_language_aliases.json'):
            with self.subTest(name=name), tempfile.TemporaryDirectory() as tmp:
                root=Path(tmp);cfg,names=self.fixture(root);(root/name).write_bytes(b'changed')
                with self.assertRaisesRegex(ValueError,'Producer input bytes changed'):self.guard(root,cfg,names)

    def test_changed_mode_missing_inventory_entry_and_symlink_are_rejected(self):
        for change in ('mode','added','removed','symlink'):
            with self.subTest(change=change), tempfile.TemporaryDirectory() as tmp:
                root=Path(tmp);cfg,names=self.fixture(root)
                if change=='mode':(root/'src/main.zig').chmod(0o755)
                elif change=='added':names.append('tools/new.py')
                elif change=='removed':names.remove('src/main.zig')
                else:
                    path=root/'src/main.zig';path.unlink();path.symlink_to(root/'build.zig')
                with self.assertRaises(ValueError):self.guard(root,cfg,names)

    def test_untracked_embedded_input_rejected_and_untracked_app_allowed(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);cfg,names=self.fixture(root)
            (root/'tools/new-embedded.json').write_text('{"new":true}')
            with self.assertRaisesRegex(ValueError,'Untracked producer input'):
                self.guard(root,cfg,names,untracked=['tools/new-embedded.json'])
            self.assertFalse(self.guard(root,cfg,names,untracked=['apps/desktop/new.json'])['apps_acceptance'])

    def test_execute_retains_current_head_without_restamping_qualification(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);cfg=ControllerMemoryPolicyTests().cfg(root);folder=root/'attempt'
            observation=dict(qualified_head='qualified',current_head='app-only-commit',producer_inventory={'sha256':'pinned'},apps_acceptance=False)
            process=mock.Mock(pid=900123);process.poll.return_value=1;process.wait.return_value=1
            def spawn(*args,**kwargs):
                write_json(Path(kwargs['cwd'])/'.tmp/build-watchdog-report.json',dict(termination_reason='child_exit',
                    child_exit_status=1,guardian_exit_status=0,memory_limit_bytes=controller.MEMORY))
                return process
            with mock.patch.object(controller,'ROOT',root), \
                 mock.patch.object(controller.subprocess,'Popen',side_effect=spawn), \
                 mock.patch.object(controller,'process_identity',return_value=dict(pid=900123,start_time_ticks=1)), \
                 mock.patch.object(controller,'watchdog_closed',return_value=True), \
                 mock.patch.object(controller,'source_guard',return_value=observation):
                row,_=controller.execute(cfg,'arwiktionary',4,folder,1,'context',[])
            self.assertEqual(row['source_observation'],observation)
            self.assertEqual(controller.read_json(folder/'result.json')['source_observation'],observation)

    def test_manifest_change_and_wrong_qualified_inventory_are_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);cfg,names=self.fixture(root);(root/'manifest.json').write_text('{"changed":true}')
            with self.assertRaisesRegex(ValueError,'Input manifest changed'):self.guard(root,cfg,names)
            cfg['source']['head']='different'
            with self.assertRaisesRegex(ValueError,'another qualification'):self.guard(root,cfg,names)


class ControllerCampaignSelectionTests(unittest.TestCase):
    def fixture(self, root):
        def store(name, value):
            path = root / name; write_json(path, value); return controller.descriptor(path)
        editions = [f'toy{i:03d}wiktionary' for i in range(198)]
        files = []
        for index, wiki in enumerate(editions):
            name = wiki + '-20261001-pages-meta-current.xml.bz2'
            files.append(dict(wiki=wiki, date='20261001', name=name, size=100 + index,
                sha1='a' * 40, url='https://dumps.wikimedia.org/' + wiki + '/20261001/' + name))
        inventory = dict(edition_count=198, missing=[], rows=[dict(wiki=row['wiki'], compressed_xml_bytes=row['size'],
            members=[{key: value for key, value in row.items() if key != 'wiki'}]) for row in files])
        inv = store('inventory.json', inventory)
        baseline = store('baseline.json', dict(history=dict(inventory=inv, attempted_editions=editions[:2], attempted_count=2)))
        manifest = dict(requested_editions=editions[:5], files=files[:5], language_registries=[])
        manifest_ref = store('downloads/manifest.json', manifest)
        rows = []
        for index, outcome in [(0, 'passed-closed'), (1, 'failed-closed')]:
            wiki = editions[index]; source = 'a' * 64
            driver = dict(edition=wiki, date='20261001', attempt_number=1,
                attempt_directory=str(root / ('attempt-' + wiki)), source_fingerprint=source, manifest=manifest_ref)
            dr = store(wiki + '/driver.json', driver)
            owner = store(wiki + '/owner.json', dict(driver_configuration=dr))
            complete = None
            if outcome == 'passed-closed':
                complete = store(wiki + '/publication/complete.json', dict(edition=wiki, date='20261001', input_pages=3,
                    build_inputs=dict(files=[[wiki, '20261001', files[index]['name'], files[index]['size'], files[index]['sha1']]], source=source),
                    publication_files={}))
            result = store(wiki + '/result.json', dict(accepted=outcome == 'passed-closed', complete=complete,
                input_pages=3 if complete else None, elapsed_seconds=2.5))
            closure = store(wiki + '/closure.json', dict(cleanup_proven=True, source_guard=True, production_started=True,
                production_elapsed_seconds=2.5, outcome=outcome, configuration=owner, result=result))
            rows.append(dict(driver, closure_ref=closure, result=result, complete=complete, outcome=outcome,
                input_pages=3 if complete else None, elapsed_seconds=2.5))
        ledger = dict(attempts=rows, aggregate=dict(closed_production_attempts=2))
        lr = store('ledger.json', ledger)
        report = dict(sources=dict(campaign_ledger=lr), report_refresh_inputs=dict(inventory=inv, baseline=baseline),
            deduplication=dict(identity_inventory=dict(campaign_logical_attempts=[{key: row[key] for key in
                ('edition', 'attempt_number', 'attempt_directory')} for row in rows])),
            inventory_disposition=dict(not_started_in_recorded_ledgers=196, mechanical_publications=1),
            progress=dict(initial_mechanical_editions=0))
        rr = store('report.json', report)
        cfg = dict(date='20261001', source=dict(fingerprint='b' * 64), campaign=dict(report=rr, ledger=lr))
        return cfg, manifest, ledger, report, store

    def test_authenticated_completed_skip_unstarted_order_and_exact_failed_retry(self):
        with tempfile.TemporaryDirectory() as tmp:
            cfg, manifest, ledger, report, store = self.fixture(Path(tmp))
            plan = controller.campaign_selection(cfg, manifest)
            self.assertEqual(plan['ready'], ['toy002wiktionary', 'toy003wiktionary', 'toy004wiktionary'])
            self.assertEqual([row['status'] for row in plan['dispositions']], ['skipped-published', 'held-prior-failure'])
            self.assertFalse(plan['historical_timing_imported']); self.assertFalse(plan['semantic_acceptance'])
            cfg['campaign']['retry_failed'] = {'toy001wiktionary': ledger['attempts'][1]['closure_ref']}
            self.assertEqual(controller.campaign_selection(cfg, manifest)['ready'][0], 'toy001wiktionary')
            cfg['source']['fingerprint'] = 'a' * 64
            with self.assertRaisesRegex(ValueError, 'Identical failed'): controller.campaign_selection(cfg, manifest)

    def test_stale_ledger_attempt_join_and_changed_xml_are_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            cfg, manifest, ledger, report, store = self.fixture(Path(tmp))
            stale = copy.deepcopy(cfg); stale['campaign']['ledger'] = store('other-ledger.json', dict(ledger, extra=True))
            with self.assertRaisesRegex(ValueError, 'Stale'): controller.campaign_selection(stale, manifest)
            bad = copy.deepcopy(report); bad['deduplication']['identity_inventory']['campaign_logical_attempts'][0]['attempt_number'] = 2
            wrong = copy.deepcopy(cfg); wrong['campaign']['report'] = store('wrong-report.json', bad)
            with self.assertRaisesRegex(ValueError, 'attempt identity'): controller.campaign_selection(wrong, manifest)
            bad_manifest = copy.deepcopy(manifest); bad_manifest['files'][2]['sha1'] = 'b' * 40
            with self.assertRaisesRegex(ValueError, 'Selected XML'): controller.campaign_selection(cfg, bad_manifest)

    def test_completed_path_result_and_source_identity_cannot_be_borrowed(self):
        for mutation in ('result', 'source', 'missing'):
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory() as tmp:
                cfg, manifest, ledger, report, store = self.fixture(Path(tmp)); row = ledger['attempts'][0]
                if mutation == 'missing':
                    Path(row['complete']['path']).unlink()
                elif mutation == 'source':
                    row['source_fingerprint'] = 'c' * 64
                else:
                    row['result'] = ledger['attempts'][1]['result']
                if mutation != 'missing':
                    cfg['campaign']['ledger'] = store('changed-ledger.json', ledger)
                    report['sources']['campaign_ledger'] = cfg['campaign']['ledger']
                    cfg['campaign']['report'] = store('changed-report.json', report)
                with self.assertRaises((ValueError, FileNotFoundError)): controller.campaign_selection(cfg, manifest)

    def test_explicit_hold_does_not_invent_acceptance_or_duration(self):
        with tempfile.TemporaryDirectory() as tmp:
            cfg, manifest, ledger, report, store = self.fixture(Path(tmp))
            cfg['campaign']['held'] = {'toy002wiktionary': 'Missing supported metadata role'}
            plan = controller.campaign_selection(cfg, manifest)
            self.assertNotIn('toy002wiktionary', plan['ready'])
            held = next(row for row in plan['dispositions'] if row['edition'] == 'toy002wiktionary')
            self.assertEqual(held['status'], 'held'); self.assertNotIn('elapsed_seconds', held)
            cfg['campaign']['held']['toy002wiktionary'] = ''
            with self.assertRaisesRegex(ValueError, 'explicit reasons'): controller.campaign_selection(cfg, manifest)

    def test_existing_cli_options_are_pinned_and_cache_identity_checked(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); snap = root / 'file-metadata.tsv'; snap.write_text('retained fixture')
            cache = root / 'cache'; cache.mkdir(); st = cache.stat()
            record = dict(path=str(cache), device=st.st_dev, inode=st.st_ino, uid=st.st_uid, mode=st.st_mode & 0o777)
            cfg = dict(llvm_workers=2, edition_options={'toy': dict(extraction_cache_root=record,
                auxiliary_snapshots={'file-metadata': controller.descriptor(snap)})})
            argv = controller.edition_cli_options(cfg, 'toy')
            self.assertEqual(argv, ['--llvm-workers', '2', '--file-metadata-snapshot', str(snap), '--extraction-cache-root', str(cache)])
            record['inode'] += 1
            with self.assertRaisesRegex(ValueError, 'cache identity'): controller.edition_cli_options(cfg, 'toy')
            record['inode'] -= 1; snap.write_text('changed')
            with self.assertRaisesRegex(ValueError, 'snapshot identity'): controller.edition_cli_options(cfg, 'toy')
            self.assertEqual(controller.edition_cli_options({}, 'toy'), [])

    def test_started_without_terminal_keeps_unknown_production_time_evidence(self):
        with tempfile.TemporaryDirectory() as tmp:
            log = Path(tmp) / 'build.log'
            log.write_text('BUILD_PHASE ' + json.dumps(dict(edition='toy', date='20261001', phase='edition_build', event='start')) + '\n')
            evidence = controller.phase_evidence(log, 'toy', '20261001')
            self.assertTrue(evidence['production_started']); self.assertIsNone(evidence['end'])
            log.write_text('preflight refused\n')
            self.assertEqual(controller.phase_evidence(log, 'toy', '20261001'), dict(production_started=False, end=None))

    def test_campaign_restart_refuses_missing_recovered_or_unproved_lifecycle(self):
        for failure in ('missing', 'recovered', 'cleanup_proven', 'source_guard', 'control_proven'):
            with self.subTest(failure=failure), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp); folder = root / 'attempts/000001'; folder.mkdir(parents=True)
                write_json(folder / 'start.json', dict(context='same-context'))
                if failure != 'missing':
                    row = dict(outcome='failed', cleanup_proven=True, source_guard=True, control_proven=True)
                    if failure == 'recovered': row['recovered'] = True
                    else: row[failure] = False
                    write_json(folder / 'result.json', row)
                with mock.patch.object(controller, 'load_history_transition', return_value=None):
                    with self.assertRaisesRegex(ValueError, 'Unresolved campaign'):
                        controller.history(root, 'same-context', dict(campaign={}))

    def test_campaign_restart_rechecks_real_watchdog_descriptor_and_live_owner(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); folder = root / 'attempts/000001'; folder.mkdir(parents=True)
            write_json(folder / 'start.json', dict(context='same-context'))
            wd = folder / 'watchdog.json'; write_json(wd, dict(termination_reason='child_exit', memory_limit_bytes=controller.MEMORY))
            row = dict(outcome='failed', cleanup_proven=True, source_guard=True, control_proven=True,
                       memory_limit_bytes=controller.MEMORY, watchdog=controller.descriptor(wd))
            write_json(folder / 'result.json', row)
            with mock.patch.object(controller, 'load_history_transition', return_value=None), \
                 mock.patch.object(controller, 'validate_history_context'), \
                 mock.patch.object(controller, 'watchdog_closed', return_value=False):
                with self.assertRaisesRegex(ValueError, 'not safe to continue'):
                    controller.history(root, 'same-context', dict(campaign={}))
            wd.write_text('{}')
            with mock.patch.object(controller, 'load_history_transition', return_value=None):
                with self.assertRaisesRegex(ValueError, 'Receipt bytes changed'):
                    controller.history(root, 'same-context', dict(campaign={}))

    def test_signal_exit_cannot_become_safe_after_campaign_restart(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); folder = root / 'attempts/000001'; folder.mkdir(parents=True)
            write_json(folder / 'start.json', dict(context='same-context'))
            wd = folder / 'watchdog.json'
            for status in (1, -9):
                write_json(wd, dict(termination_reason='child_exit', child_exit_status=status, memory_limit_bytes=controller.MEMORY))
                row = dict(outcome='failed', exit_code=status, cleanup_proven=True, source_guard=True, control_proven=True,
                           memory_limit_bytes=controller.MEMORY, watchdog=controller.descriptor(wd))
                write_json(folder / 'result.json', row)
                with mock.patch.object(controller, 'load_history_transition', return_value=None), \
                     mock.patch.object(controller, 'validate_history_context'), \
                     mock.patch.object(controller, 'watchdog_closed', return_value=True):
                    if status < 0:
                        with self.assertRaisesRegex(ValueError, 'not safe to continue'):
                            controller.history(root, 'same-context', dict(campaign={}))
                    else:
                        self.assertEqual(controller.history(root, 'same-context', dict(campaign={})), [row])

    def test_all_held_queue_has_failure_status_and_never_launches(self):
        for status, expected in [('held', 1), ('not-ready', 1), ('skipped-published', 0)]:
            with self.subTest(status=status), tempfile.TemporaryDirectory() as tmp:
                plan = dict(ready=[], dispositions=[dict(edition='arwiktionary', status=status)])
                code, seen, summary = ControllerAllReadyTests().run_main(Path(tmp), plan=plan)
                self.assertEqual(code, expected); self.assertEqual(seen, [])
                self.assertFalse(summary['final_cohort_complete'])

    def test_main_halts_source_control_signal_monitor_and_exhausted_cap_failures(self):
        for unsafe in ('source', 'control', 'signal', 'monitor', 'cap'):
            with self.subTest(unsafe=unsafe), tempfile.TemporaryDirectory() as tmp:
                seen = ControllerAllReadyTests().run_main(Path(tmp), unsafe=unsafe)
                self.assertTrue(seen)
                self.assertEqual(set(seen), {'arwiktionary'})

    def test_campaign_execute_separates_existing_output_success_and_failed_verification(self):
        for status in ('success', 'error'):
            with self.subTest(status=status), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp); cfg = ControllerMemoryPolicyTests().cfg(root); cfg['campaign'] = {}
                folder = root / 'attempt'; code = 0 if status == 'success' else 1
                process = mock.Mock(pid=900123); process.poll.return_value=code; process.wait.return_value=code
                start = dict(edition='arwiktionary', date='20261001', phase='edition_build', event='start')
                end = dict(start, event='end', status=status, seconds=3.25, execution_mode='existing_output')
                def spawn(*args, **kwargs):
                    write_json(Path(kwargs['cwd'])/'.tmp/build-watchdog-report.json', dict(termination_reason='child_exit',
                        child_exit_status=code, guardian_exit_status=0, memory_limit_bytes=controller.MEMORY))
                    kwargs['stdout'].write(('BUILD_PHASE '+json.dumps(start)+'\nBUILD_PHASE '+json.dumps(end)+'\n').encode())
                    kwargs['stdout'].flush()
                    return process
                with mock.patch.object(controller, 'ROOT', root), \
                     mock.patch.object(controller.subprocess, 'Popen', side_effect=spawn), \
                     mock.patch.object(controller, 'process_identity', return_value=dict(pid=900123, start_time_ticks=1)), \
                     mock.patch.object(controller, 'watchdog_closed', return_value=True), \
                     mock.patch.object(controller, 'source_guard'), \
                     mock.patch.object(controller, 'accept', return_value=dict(input_pages=10)):
                    row, _ = controller.execute(cfg, 'arwiktionary', 4, folder, 1, 'context', [])
                self.assertTrue(row['verification_only']); self.assertFalse(row['production_started'])
                self.assertIsNone(row['production_elapsed_seconds']); self.assertEqual(row['verification_elapsed_seconds'], 3.25)
                self.assertEqual(row['edition_build'], end); self.assertGreaterEqual(row['controller_elapsed_seconds'], 0)
                summary = controller.summarize([row], ['arwiktionary'])
                self.assertEqual(summary['editions'][0]['observed_build_seconds'], 0)
                self.assertEqual(summary['editions'][0]['verification_seconds'], 3.25)
                self.assertEqual(row['accepted'] is None, status == 'error')

    def test_campaign_execute_start_only_is_unknown_and_true_no_start_is_not_production(self):
        for started in (True, False):
            with self.subTest(started=started), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp); cfg = ControllerMemoryPolicyTests().cfg(root); cfg['campaign'] = {}; folder = root/'attempt'
                process = mock.Mock(pid=900123); process.poll.return_value=1; process.wait.return_value=1
                def spawn(*args, **kwargs):
                    write_json(Path(kwargs['cwd'])/'.tmp/build-watchdog-report.json', dict(termination_reason='child_exit',
                        child_exit_status=1, guardian_exit_status=0, memory_limit_bytes=controller.MEMORY))
                    if started:
                        kwargs['stdout'].write(('BUILD_PHASE '+json.dumps(dict(edition='arwiktionary', date='20261001', phase='edition_build', event='start'))+'\n').encode())
                        kwargs['stdout'].flush()
                    return process
                with mock.patch.object(controller, 'ROOT', root), \
                     mock.patch.object(controller.subprocess, 'Popen', side_effect=spawn), \
                     mock.patch.object(controller, 'process_identity', return_value=dict(pid=900123, start_time_ticks=1)), \
                     mock.patch.object(controller, 'watchdog_closed', return_value=True), \
                     mock.patch.object(controller, 'source_guard'):
                    row, _ = controller.execute(cfg, 'arwiktionary', 4, folder, 1, 'context', [])
                self.assertEqual(row['production_started'], started)
                self.assertEqual(row['elapsed_seconds'], None if started else 0.0)
                self.assertIsNone(row['production_elapsed_seconds'])
                self.assertEqual(row['not_ready_reason'] is None, started)
                self.assertFalse(row['verification_only'])

    def test_campaign_execute_records_malformed_terminal_and_finishes_source_cleanup_checks(self):
        for source_fails in (False, True):
            with self.subTest(source_fails=source_fails), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp); cfg = ControllerMemoryPolicyTests().cfg(root); cfg['campaign'] = {}; folder = root/'attempt'
                process = mock.Mock(pid=900123); process.poll.return_value=1; process.wait.return_value=1
                start = dict(edition='arwiktionary', date='20261001', phase='edition_build', event='start')
                def spawn(*args, **kwargs):
                    write_json(Path(kwargs['cwd'])/'.tmp/build-watchdog-report.json', dict(termination_reason='child_exit',
                        child_exit_status=1, guardian_exit_status=0, memory_limit_bytes=controller.MEMORY))
                    kwargs['stdout'].write(('BUILD_PHASE '+json.dumps(start)+'\nBUILD_PHASE {"event":"end",').encode())
                    kwargs['stdout'].flush()
                    return process
                lock = mock.Mock()
                with mock.patch.object(controller, 'ROOT', root), \
                     mock.patch.object(controller.subprocess, 'Popen', side_effect=spawn), \
                     mock.patch.object(controller, 'process_identity', return_value=dict(pid=900123, start_time_ticks=1)), \
                     mock.patch.object(controller, 'watchdog_closed', return_value=True) as cleanup, \
                     mock.patch.object(controller, 'source_guard', side_effect=ValueError('source changed') if source_fails else None) as source, \
                     mock.patch.object(controller, 'accept') as accept:
                    row, _ = controller.execute(cfg, 'arwiktionary', 4, folder, 1, 'context', [lock])
                self.assertEqual(controller.read_json(folder/'result.json'), row)
                process.wait.assert_called_once(); source.assert_called_once_with(cfg)
                cleanup.assert_called_once(); lock.check.assert_called(); accept.assert_not_called()
                self.assertTrue(row['cleanup_proven']); self.assertEqual(row['source_guard'], not source_fails)
                self.assertFalse(row['control_proven']); self.assertEqual(row['outcome'], 'failed')
                self.assertIsNone(row['production_started']); self.assertIsNone(row['verification_only'])
                self.assertIsNone(row['elapsed_seconds']); self.assertIsNone(row['production_elapsed_seconds'])
                self.assertIsNone(row['verification_elapsed_seconds']); self.assertIsNone(row['edition_build'])
                self.assertGreaterEqual(row['controller_elapsed_seconds'], 0)
                self.assertIn('Invalid phase evidence', row['error']); self.assertTrue(row['phase_evidence_error'])
                self.assertEqual('source changed' in row['error'], source_fails)
                self.assertEqual(controller.descriptor(folder/'build.log'), row['build_log'])
                summary = controller.summarize([row], ['arwiktionary'])
                self.assertIsNone(summary['editions'][0]['observed_build_seconds'])

    def test_failed_local_verification_cannot_be_hidden_by_older_campaign_publication(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); plan = dict(ready=[], dispositions=[dict(edition='arwiktionary', status='skipped-published')])
            failed = attempt('verify-failed', 1, 'arwiktionary', seconds=3, accepted=False, mode='existing_output')
            with self.assertRaisesRegex(ValueError, 'Failed publication verification'):
                ControllerAllReadyTests().run_main(root, plan=copy.deepcopy(plan), history_rows=[failed])
            failed_production = attempt('production-failed', 2, 'arwiktionary', seconds=5, accepted=False)
            with self.assertRaisesRegex(ValueError, 'Failed publication verification'):
                ControllerAllReadyTests().run_main(root, plan=copy.deepcopy(plan), history_rows=[failed, failed_production])
            passed = attempt('verify-passed', 2, 'arwiktionary', seconds=4, accepted=True, mode='existing_output')
            code, seen, summary = ControllerAllReadyTests().run_main(root, plan=copy.deepcopy(plan), history_rows=[failed, passed])
            self.assertEqual(code, 0); self.assertEqual(seen, [])
            row = next(row for row in summary['editions'] if row['edition'] == 'arwiktionary')
            self.assertEqual(row['observed_build_seconds'], 0); self.assertEqual(row['verification_seconds'], 7)

    def test_strict_phase_timeline_rejects_malformed_duplicate_and_reordered_records(self):
        start = dict(edition='toy', date='20261001', phase='edition_build', event='start')
        end = dict(start, event='end', seconds=1)
        cases = [['broken'], [end], [start, start, end], [start, end, start], [start, dict(end, seconds=-1)], [start, dict(end, seconds=float('nan'))]]
        with tempfile.TemporaryDirectory() as tmp:
            log = Path(tmp)/'build.log'
            for rows in cases:
                log.write_text(''.join('BUILD_PHASE '+(row if isinstance(row, str) else json.dumps(row))+'\n' for row in rows))
                with self.subTest(rows=rows), self.assertRaises(ValueError):
                    controller.phase_evidence(log, 'toy', '20261001', strict=True)

    def test_all44_unstarted_are_selected_from_complete_inventory_without_payload_reads(self):
        with tempfile.TemporaryDirectory() as tmp:
            cfg, manifest, ledger, report, store = self.fixture(Path(tmp))
            inventory = controller.read_ref(report['report_refresh_inputs']['inventory'])
            editions = [row['wiki'] for row in inventory['rows']]
            baseline = dict(history=dict(inventory=report['report_refresh_inputs']['inventory'],
                                         attempted_editions=editions[:154], attempted_count=154))
            report['report_refresh_inputs']['baseline'] = store('baseline-154.json', baseline)
            report['inventory_disposition']['not_started_in_recorded_ledgers'] = 44
            cfg['campaign']['report'] = store('report-154.json', report)
            selected = editions[154:]
            manifest = dict(requested_editions=list(reversed(selected)), files=[dict(row['members'][0], wiki=row['wiki'])
                for row in inventory['rows'] if row['wiki'] in selected])
            plan = controller.campaign_selection(cfg, manifest)
            self.assertEqual(plan['ready'], selected)
            self.assertEqual(plan['unstarted_count'], 44)
            self.assertEqual(plan['dispositions'], [])
            self.assertFalse(plan['semantic_acceptance'])




class ControllerBatchBoundaryTests(unittest.TestCase):
    def test_positive_limit_yields_after_closed_failed_edition_and_preserves_pending(self):
        with tempfile.TemporaryDirectory() as tmp:
            code,seen,summary=ControllerAllReadyTests().run_main(Path(tmp),
                plan=dict(ready=['arwiktionary','enwiktionary'],dispositions=[]),max_editions=1)
        self.assertEqual(code,1);self.assertEqual(seen,['arwiktionary'])
        self.assertEqual(summary['execution'],dict(outcome='batch-complete',max_editions=1,
            completed_editions=['arwiktionary'],pending_editions=['enwiktionary'],all_selected_editions_processed=False))
        self.assertFalse(summary['final_cohort_complete'])

    def test_default_unbounded_and_limit_larger_than_selection_finish_selection(self):
        for limit in (None,9):
            with self.subTest(limit=limit),tempfile.TemporaryDirectory() as tmp:
                code,seen,summary=ControllerAllReadyTests().run_main(Path(tmp),
                    plan=dict(ready=['arwiktionary','enwiktionary'],dispositions=[]),max_editions=limit)
                self.assertEqual(seen,['arwiktionary','enwiktionary'])
                self.assertEqual(summary['execution']['outcome'],'selection-complete')
                self.assertEqual(summary['execution']['pending_editions'],[])

    def test_memory_worker_backoff_finishes_inside_one_edition_before_yield(self):
        calls=[]
        def execute(edition,workers,memory,sequence):
            calls.append((edition,workers,memory));passed=workers==2
            row=attempt('attempt-'+str(sequence),sequence,edition,accepted=passed)
            row.update(controller_interrupted=False,cleanup_proven=True,source_guard=True,control_proven=True)
            return row,dict(termination_reason='child_exit' if passed else 'sampled_pss_limit',
                            child_exit_status=0 if passed else -15,memory_limit_bytes=memory)
        with tempfile.TemporaryDirectory() as tmp:
            code,seen,summary=ControllerAllReadyTests().run_main(Path(tmp),
                plan=dict(ready=['arwiktionary','enwiktionary'],dispositions=[]),max_editions=1,execute_override=execute)
        self.assertEqual(calls,[('arwiktionary',4,controller.MEMORY),('arwiktionary',2,controller.MEMORY)])
        self.assertEqual(code,0);self.assertEqual(summary['execution']['completed_editions'],['arwiktionary'])
        self.assertEqual(summary['execution']['pending_editions'],['enwiktionary'])
        self.assertEqual(next(x for x in summary['editions'] if x['edition']=='arwiktionary')['attempt_count'],2)
        self.assertFalse(summary['final_cohort_complete'])

    def test_skipped_old_failure_does_not_consume_limit_and_no_pending_phantom(self):
        old=attempt('old',1,'arwiktionary',accepted=False)
        with tempfile.TemporaryDirectory() as tmp:
            code,seen,summary=ControllerAllReadyTests().run_main(Path(tmp),
                plan=dict(ready=['arwiktionary','enwiktionary'],dispositions=[]),max_editions=1,history_rows=[old])
        self.assertEqual(seen,['enwiktionary']);self.assertEqual(summary['execution']['completed_editions'],['enwiktionary'])
        self.assertEqual(summary['execution']['outcome'],'selection-complete')

    def test_unsafe_cleanup_cannot_become_clean_batch_yield(self):
        with tempfile.TemporaryDirectory() as tmp:
            seen=ControllerAllReadyTests().run_main(Path(tmp),cleanup=False,
                plan=dict(ready=['arwiktionary','enwiktionary'],dispositions=[]),max_editions=1)
        self.assertEqual(seen,['arwiktionary'])

    def test_nonpositive_limit_rejected_before_configuration_or_launch(self):
        for limit in (0,-1):
            with self.subTest(limit=limit),mock.patch.object(controller,'read_json',side_effect=AssertionError('must not read config')):
                with self.assertRaisesRegex(ValueError,'must be positive'):
                    controller.main(['--config','unused','--max-editions',str(limit)])




class ControllerExplicitSubsetTests(unittest.TestCase):
    def manifest(self):
        editions=['kaawiktionary','mrwiktionary','slwiktionary']+[f'toy{i:03d}wiktionary' for i in range(45)]
        return dict(requested_editions=list(reversed(editions)),files=[dict(wiki=wiki,date='20261001',
            name=wiki+'-20261001-pages-meta-current.xml.bz2',size=i+1,sha1='a'*40,
            url='https://dumps.wikimedia.org/'+wiki+'/20261001/'+wiki+'-20261001-pages-meta-current.xml.bz2')
            for i,wiki in enumerate(editions)])

    def test_explicit_48_runs_smallest_three_without_legacy_campaign_history(self):
        with tempfile.TemporaryDirectory() as tmp:
            code,seen,summary=ControllerAllReadyTests().run_main(Path(tmp),manifest_override=self.manifest(),max_editions=3)
        self.assertEqual(code,0);self.assertEqual(seen,['kaawiktionary','mrwiktionary','slwiktionary'])
        self.assertEqual(summary['execution']['outcome'],'batch-complete')
        self.assertEqual(len(summary['execution']['pending_editions']),45)
        self.assertNotIn('campaign_selection',summary)
        self.assertFalse(summary['residual_review_complete'])

    def test_empty_duplicate_or_mismatched_selection_refuses_before_execution(self):
        variants=[]
        value=self.manifest();value['requested_editions']=[];variants.append(value)
        value=self.manifest();value['requested_editions'].append(value['requested_editions'][0]);variants.append(value)
        value=self.manifest();value['requested_editions'].pop();variants.append(value)
        value=self.manifest();value['files'].pop();variants.append(value)
        for manifest in variants:
            with self.subTest(manifest=manifest['requested_editions'][:3]),tempfile.TemporaryDirectory() as tmp:
                with self.assertRaisesRegex(ValueError,'Explicit all-phase selection'):
                    ControllerAllReadyTests().run_main(Path(tmp),manifest_override=manifest,max_editions=3)

    def test_partial_manifest_does_not_change_pilot_or_remaining_contract(self):
        for phase in ('pilot','remaining'):
            with self.subTest(phase=phase),tempfile.TemporaryDirectory() as tmp:
                with self.assertRaisesRegex(ValueError,'Exactly the selected 198'):
                    ControllerAllReadyTests().run_main(Path(tmp),manifest_override=self.manifest(),phase=phase)

    def test_subset_batch_still_stops_on_unproven_cleanup_or_source(self):
        for options in ({'cleanup':False},{'unsafe':'source'}):
            with self.subTest(options=options),tempfile.TemporaryDirectory() as tmp:
                seen=ControllerAllReadyTests().run_main(Path(tmp),manifest_override=self.manifest(),max_editions=3,**options)
                self.assertEqual(seen,['kaawiktionary'])




class OptionalControllerSourceTimingTests(unittest.TestCase):
    def exercise(self, root, enabled, *, tamper=False, broken_emit=False, fingerprint_error=None):
        import sys
        import types
        import extraction_cache as timings
        fixture = ControllerProducerScopeTests('test_dirty_app_and_unrelated_app_commit_preserve_exact_producer')
        cfg, names = fixture.fixture(root)
        if tamper: (root/'src/main.zig').write_bytes(b'changed')
        records = []
        def emit(edition, date, name, event, **fields):
            if broken_emit: raise OSError('diagnostic unavailable')
            records.append(dict(edition=edition, phase=name, event=event, **fields))
        fingerprint = mock.Mock(side_effect=fingerprint_error) if fingerprint_error else mock.Mock(return_value='fingerprint')
        builder = types.SimpleNamespace(source_fingerprint=fingerprint, phase_event=emit)
        def git(argv, **kwargs):
            if argv==['git', 'rev-parse', 'HEAD']: return 'qualified'
            if argv==['git', 'ls-files', '-z']: return ('\0'.join(names)+'\0').encode()
            if argv==['git', 'ls-files', '--others', '--exclude-standard', '-z']: return b''
            self.fail('Unexpected git query: '+repr(argv))
        result, caught = None, None
        with mock.patch.dict(controller.os.environ, {timings.PHASE_TIMING_ENV: '1' if enabled else '0'}), \
             mock.patch.dict(sys.modules, {'build_wiktionaries': builder}), \
             mock.patch.object(controller, 'ROOT', root), \
             mock.patch.object(controller.subprocess, 'check_output', side_effect=git), \
             mock.patch.object(controller, 'digest', wraps=controller.digest) as hashes:
            try: result = controller.source_guard(cfg)
            except Exception as error: caught = error
        return result, caught, records, hashes.call_count, fingerprint.call_count

    def test_opt_in_does_not_add_hashes_or_change_source_observation(self):
        with tempfile.TemporaryDirectory() as a, tempfile.TemporaryDirectory() as b:
            off=self.exercise(Path(a), False); on=self.exercise(Path(b), True)
            # Receipt paths differ between fixtures; observation identities do not.
            self.assertEqual(off[0]['qualified_head'], on[0]['qualified_head'])
            self.assertEqual(off[0]['current_head'], on[0]['current_head'])
            self.assertIsNone(off[1]); self.assertIsNone(on[1]); self.assertEqual(off[2], [])
            self.assertEqual(off[3:], on[3:]); self.assertEqual(on[4], 1)
            phases={row['phase']:row for row in on[2]}
            self.assertEqual(set(phases), {'source_guard_baseline', 'source_guard_inventory', 'source_guard_fingerprint', 'source_guard_manifest'})
            self.assertEqual(phases['source_guard_inventory']['files'], 3)
            self.assertEqual(phases['source_guard_manifest']['files'], 1)
            self.assertTrue(all(row['edition']=='__controller__' and row['scope']=='controller-source-guard' for row in on[2]))

    def test_disabled_uses_no_clock_and_tampering_still_fails(self):
        import extraction_cache as timings
        with tempfile.TemporaryDirectory() as folder, mock.patch.object(timings.time, 'monotonic', side_effect=AssertionError('disabled clock')):
            self.assertIsNone(self.exercise(Path(folder), False)[1])
        for enabled in (False, True):
            with tempfile.TemporaryDirectory() as folder:
                result=self.exercise(Path(folder), enabled, tamper=True)
                self.assertIsInstance(result[1], ValueError); self.assertIn('Producer input bytes changed', str(result[1]))
                if enabled:self.assertEqual(result[2][-1]['status'], 'failure')

    def test_failed_logger_preserves_success_and_original_fingerprint_exception(self):
        failure=ValueError('original source fingerprint failure')
        with tempfile.TemporaryDirectory() as folder:
            self.assertIsNone(self.exercise(Path(folder), True, broken_emit=True)[1])
        with tempfile.TemporaryDirectory() as folder:
            result=self.exercise(Path(folder), True, broken_emit=True, fingerprint_error=failure)
            self.assertIs(result[1], failure)


class RetainedProducerRootTests(unittest.TestCase):
    @staticmethod
    def directory(path):
        st = path.stat()
        return dict(path=str(path), device=st.st_dev, inode=st.st_ino,
                    uid=st.st_uid, mode=st.st_mode & 0o7777)

    @contextmanager
    def retained(self):
        import sys
        from build_wiktionaries import AUXILIARY_SNAPSHOT_NAMES
        with tempfile.TemporaryDirectory() as temporary:
            workspace = Path(temporary) / 'workspace'
            source = workspace / '.tmp/producer'
            for name in ('src', 'tools', '.tmp', '.zig-cache'):
                (source / name).mkdir(parents=True, exist_ok=True)
            for name in ('downloads', 'state', 'output', 'raw'):
                (workspace / 'data' / name).mkdir(parents=True)
            names = ('build.zig', 'src/producer.zig', 'tools/corpus_controller.py',
                     'tools/build_wiktionaries.py', 'tools/build_artifact_root.py',
                     'tools/reviewed_language_aliases.json')
            for name in names:
                (source / name).write_text('# qualified fixture bytes: ' + name + '\n')
            manifest = workspace / 'data/downloads/manifest.json'
            write_json(manifest, {'requested_editions': ['enwiktionary']})
            compiler = workspace / 'compiler'
            compiler.write_bytes(b'bound compiler fixture')
            inventory = workspace / 'data/state/source-inventory.json'
            write_json(inventory, dict(head='a' * 40,
                files={name: controller.descriptor(source / name) for name in names},
                modes={name: (source / name).stat().st_mode & 0o7777 for name in names}))
            cfg = dict(source=dict(head='a' * 40, fingerprint='f' * 64,
                                  root=self.directory(source), inventory=controller.descriptor(inventory)),
                       workspace_root=self.directory(workspace), compiler=controller.descriptor(compiler),
                       manifest=controller.descriptor(manifest), date='20261001', now_unix=1791731560,
                       expansion_timeout_ms=60000, build_timeout_seconds=7200,
                       downloads=str(manifest.parent), state_directory=str(inventory.parent),
                       output=str(workspace / 'data/output'), raw_shard_root=str(workspace / 'data/raw'))
            builder = SimpleNamespace(__file__=str(source / 'tools/build_wiktionaries.py'),
                                      PROJECT=source, source_fingerprint=lambda: 'f' * 64,
                                      AUXILIARY_SNAPSHOT_NAMES=AUXILIARY_SNAPSHOT_NAMES)
            origins = {'__main__': str(source / 'tools/corpus_controller.py'),
                       'build_wiktionaries': builder.__file__,
                       'build_artifact_root': str(source / 'tools/build_artifact_root.py')}
            with mock.patch.object(controller, 'ROOT', source), \
                 mock.patch.object(controller, '__file__', str(source / 'tools/corpus_controller.py')), \
                 mock.patch.dict(sys.modules, {'build_wiktionaries': builder}), \
                 mock.patch.object(controller, 'loaded_module_origins', side_effect=lambda: dict(origins)), \
                 mock.patch.dict(os.environ, {'WIKIDICT_PHASE_TIMING': '0'}):
                yield cfg, source, workspace, builder, origins

    def test_retained_guard_ignores_later_canonical_changes_without_reading_git(self):
        with self.retained() as (cfg, source, workspace, _, _), \
             mock.patch.object(controller.subprocess, 'check_output', side_effect=AssertionError('No live Git membership')):
            first = controller.source_guard(cfg)
            (workspace / 'src').mkdir()
            (workspace / 'src/new-compiler-input.zig').write_text('later main work')
            (workspace / '.git').mkdir()
            (workspace / '.git/index').write_bytes(b'changed canonical index')
            (source / '.tmp/runtime.log').write_text('ordinary generated output')
            (source / '.zig-cache/cache-item').write_bytes(b'ordinary compiler output')
            self.assertEqual(first, controller.source_guard(cfg))
            self.assertIsNone(first['current_head'])
            self.assertFalse(first['canonical_worktree_consumed'])
            self.assertEqual(first['source_root'], cfg['source']['root'])

    def test_retained_guard_rejects_changed_missing_extra_aliased_and_redirected_source(self):
        changes = ('content', 'mode', 'missing', 'extra-python', 'extra-data', 'symlink', 'directory-symlink', 'hardlink')
        for change in changes:
            with self.subTest(change=change), self.retained() as (cfg, source, workspace, _, _):
                path = source / 'src/producer.zig'
                if change == 'content': path.write_text('changed source')
                elif change == 'mode': path.chmod(0o600 if path.stat().st_mode & 0o7777 != 0o600 else 0o644)
                elif change == 'missing': path.unlink()
                elif change == 'extra-python': (source / 'tools/extra.py').write_text('new consumed helper')
                elif change == 'extra-data': (source / 'tools/extra.json').write_text('{}')
                elif change == 'directory-symlink': (source / 'linked').symlink_to(workspace, target_is_directory=True)
                else:
                    external = workspace / 'external.zig'; external.write_bytes(path.read_bytes()); path.unlink()
                    if change == 'symlink': path.symlink_to(external)
                    else: os.link(external, path)
                with self.assertRaises(ValueError): controller.source_guard(cfg)

    def test_retained_guard_rejects_wrong_root_inventory_and_mixed_helper_imports(self):
        for change in ('source-inode', 'workspace-inode', 'source-path', 'inventory-path',
                       'builder-project', 'builder-origin', 'late-helper'):
            with self.subTest(change=change), self.retained() as (cfg, source, workspace, builder, origins):
                if change == 'source-inode': cfg['source']['root']['inode'] += 1
                elif change == 'workspace-inode': cfg['workspace_root']['inode'] += 1
                elif change == 'source-path':
                    other = workspace / '.tmp/other'; other.mkdir()
                    cfg['source']['root'] = self.directory(other)
                elif change == 'inventory-path':
                    p = Path(cfg['source']['inventory']['path']); value = json.loads(p.read_text())
                    value['files']['src/producer.zig']['path'] = str(workspace / 'src/producer.zig')
                    write_json(p, value); cfg['source']['inventory'] = controller.descriptor(p)
                elif change == 'builder-project': builder.PROJECT = workspace
                elif change == 'builder-origin': builder.__file__ = str(workspace / 'tools/build_wiktionaries.py')
                else: origins['late_helper'] = str(workspace / 'tools/late_helper.py')
                with self.assertRaises(ValueError): controller.source_guard(cfg)

    def test_retained_guard_rejects_real_standard_legacy_and_external_bytecode(self):
        import importlib.util
        import py_compile
        import sys
        for kind in ('standard', 'legacy', 'external'):
            with self.subTest(kind=kind), self.retained() as (cfg, source, workspace, _, _):
                helper = source / 'tools/build_wiktionaries.py'
                if kind == 'legacy':
                    py_compile.compile(str(helper), cfile=str(helper.with_suffix('.pyc')), doraise=True)
                elif kind == 'standard':
                    py_compile.compile(str(helper), doraise=True)
                else:
                    with mock.patch.object(sys, 'pycache_prefix', str(workspace / 'external-cache')):
                        cached = Path(importlib.util.cache_from_source(str(helper)))
                        py_compile.compile(str(helper), doraise=True)
                        self.assertTrue(cached.is_file())
                        self.assertFalse(cached.is_relative_to(source))
                        with self.assertRaisesRegex(ValueError, 'unbound Python bytecode'):
                            controller.source_guard(cfg)
                    continue
                with self.assertRaisesRegex(ValueError, 'Python bytecode'):
                    controller.source_guard(cfg)

    def test_retained_guard_preserves_data_and_toolchain_boundaries(self):
        for change in ('downloads', 'state_directory', 'output', 'raw_shard_root', 'compiler', 'fingerprint'):
            with self.subTest(change=change), self.retained() as (cfg, source, workspace, builder, _):
                if change == 'compiler': Path(cfg['compiler']['path']).write_bytes(b'changed compiler')
                elif change == 'fingerprint': builder.source_fingerprint = lambda: '0' * 64
                else: cfg[change] = str(source / 'data/escaped-role')
                with self.assertRaises(ValueError): controller.source_guard(cfg)

    def test_retained_command_uses_bound_source_and_existing_workspace_artifacts(self):
        with self.retained() as (cfg, source, workspace, _, _):
            argv = controller.command(cfg, 'enwiktionary', 4)
            self.assertEqual(argv[:3], [controller.sys.executable, '-B', str(source / 'tools/build_wiktionaries.py')])
            for flag, key in (('--downloads', 'downloads'), ('--output', 'output'), ('--raw-shard-root', 'raw_shard_root')):
                self.assertEqual(argv[argv.index(flag) + 1], cfg[key])
                self.assertTrue(Path(cfg[key]).is_relative_to(workspace / 'data'))
            self.assertEqual(argv[argv.index('--zig') + 1], cfg['compiler']['path'])
            self.assertEqual(argv[argv.index('--resource-mode') + 1], 'watchdog')
            self.assertEqual(argv[argv.index('--watchdog-memory-limit-mib') + 1], '8192')
            self.assertEqual(json.loads(argv[argv.index('--workspace-root-spec') + 1]), cfg['workspace_root'])
            changed = copy.deepcopy(cfg); changed['workspace_root']['inode'] += 1
            self.assertNotEqual(controller.production_context(cfg), controller.production_context(changed))

    def test_retained_lock_paths_preserve_original_workspace_inode_checks(self):
        with self.retained() as (cfg, source, workspace, _, _):
            own, shared = controller.resource_lock_paths(cfg)
            self.assertEqual(own, workspace / 'data/build-resources/corpus-controller.lock')
            self.assertEqual(shared, workspace / '.tmp/build-resources.lock')
            self.assertFalse(shared.is_relative_to(source))
            with controller.Lock(shared, False) as lock:
                inode = shared.stat().st_ino
                lock.check()
                # The ordinary builder, not the controller, owns this flock.
                holder = os.open(shared, os.O_RDWR)
                try:
                    controller.fcntl.flock(holder, controller.fcntl.LOCK_EX | controller.fcntl.LOCK_NB)
                    lock.check()
                    shared.rename(shared.with_name('original.lock'))
                    shared.write_bytes(b'')
                    with self.assertRaises(ValueError): lock.check()
                finally: os.close(holder)
                self.assertEqual(shared.with_name('original.lock').stat().st_ino, inode)

    def test_default_roots_and_lock_paths_remain_unchanged(self):
        cfg = {'source': {}}
        self.assertEqual(controller.source_roots(cfg), (controller.ROOT, controller.ROOT))
        self.assertEqual(controller.resource_lock_paths(cfg),
                         (controller.ROOT / 'data/build-resources/corpus-controller.lock',
                          controller.ROOT / '.tmp/build-resources.lock'))
        with self.assertRaises(ValueError): controller.source_roots(dict(cfg, workspace_root={}))


class IndependentExecutionRootTests(unittest.TestCase):
    @staticmethod
    def identity(path):
        st = path.stat()
        return dict(path=str(path), device=st.st_dev, inode=st.st_ino,
                    uid=st.st_uid, mode=st.st_mode & 0o7777)

    def configure(self, cfg, workspace, name):
        root = workspace / 'data/corpus-executions' / name
        root.mkdir(parents=True, mode=0o700)
        for role in ('state', 'output', 'raw', 'cache'):
            (root / role).mkdir(mode=0o700)
        manifest = root / 'manifest.json'
        write_json(manifest, dict(requested_editions=['enwiktionary'],
            files=[dict(wiki='enwiktionary', date='20261001')]))
        manifest.chmod(0o400)
        spec = {name: self.identity(root if name == 'root' else root / name)
                for name in ('root', 'state', 'output', 'raw', 'cache')}
        cfg.update(execution_root=spec, artifact_root=spec['root'],
            state_directory=str(root/'state'), output=str(root/'output'), raw_shard_root=str(root/'raw'),
            manifest=controller.descriptor(manifest),
            edition_options={'enwiktionary': {'extraction_cache_root': spec['cache']}})
        return root

    @contextmanager
    def fixture(self):
        with RetainedProducerRootTests().retained() as (cfg, source, workspace, builder, origins):
            root = self.configure(cfg, workspace, 'first')
            yield cfg, source, workspace, root

    def test_existing_command_and_source_guard_bind_private_roles_without_replacing_download_manifest(self):
        with self.fixture() as (cfg, source, workspace, root):
            original = Path(cfg['downloads'])/'manifest.json'
            before = (original.stat().st_ino, original.read_bytes())
            observation = controller.source_guard(cfg)
            self.assertFalse(observation['canonical_worktree_consumed'])
            argv = controller.command(cfg, 'enwiktionary', 4)
            self.assertEqual(argv[:3], [controller.sys.executable, '-B', str(source/'tools/build_wiktionaries.py')])
            for flag, expected in (('--input-manifest', str(root/'manifest.json')),
                                   ('--input-manifest-sha256', cfg['manifest']['sha256']),
                                   ('--downloads', cfg['downloads']),
                                   ('--extraction-cache-root', str(root/'cache'))):
                self.assertEqual(argv[argv.index(flag)+1], expected)
            self.assertEqual(json.loads(argv[argv.index('--execution-root-spec')+1]), cfg['execution_root'])
            self.assertEqual(before, (original.stat().st_ino, original.read_bytes()))
            with self.assertRaisesRegex(ValueError, 'edition differs'):
                controller.command(cfg, 'frwiktionary', 4)
            changed = copy.deepcopy(cfg); changed.pop('execution_root')
            self.assertNotEqual(controller.production_context(cfg), controller.production_context(changed))

    def test_real_scope_locks_conflict_for_same_owner_and_coexist_with_global_and_disjoint_scope(self):
        with self.fixture() as (cfg, source, workspace, root):
            own, build = controller.resource_lock_paths(cfg)
            other = copy.deepcopy(cfg); other_root = self.configure(other, workspace, 'second')
            other_own, other_build = controller.resource_lock_paths(other)
            self.assertEqual((own, build), (root/'controller.lock', root/'build-resources.lock'))
            with controller.Lock(workspace/'data/build-resources/corpus-controller.lock', True), \
                 controller.Lock(workspace/'.tmp/build-resources.lock', True), \
                 controller.Lock(own, True) as held, controller.Lock(other_own, True):
                with self.assertRaises(BlockingIOError):
                    with controller.Lock(own, True): pass
                held.check()
                self.assertNotEqual(own.stat().st_ino, other_own.stat().st_ino)
                self.assertEqual(other_build, other_root/'build-resources.lock')
            inode = own.stat().st_ino
            with controller.Lock(own, True) as held: held.check()
            self.assertEqual(own.stat().st_ino, inode)

    def test_conflicting_shared_nested_and_changed_destinations_refuse_before_lock_creation(self):
        for mutation in ('shared-output', 'raw-output', 'external-cache', 'state-outside',
                         'nested-root', 'root-inode', 'cache-inode', 'manifest-path',
                         'writable-manifest', 'manifest-bytes', 'multiple-editions', 'default-bypass'):
            with self.subTest(mutation=mutation), self.fixture() as (cfg, source, workspace, root):
                if mutation == 'shared-output': cfg['output'] = str(workspace/'data/output')
                elif mutation == 'raw-output': cfg['raw_shard_root'] = cfg['output']
                elif mutation == 'external-cache':
                    external = workspace/'data/extraction'; external.mkdir(mode=0o700)
                    cfg['edition_options']['enwiktionary']['extraction_cache_root'] = self.identity(external)
                elif mutation == 'state-outside': cfg['state_directory'] = str(workspace/'data/state')
                elif mutation == 'nested-root':
                    cfg['execution_root']['root']['path'] = str(root/'state')
                    cfg['execution_root']['root'].update(self.identity(root/'state'))
                    cfg['artifact_root'] = cfg['execution_root']['root']
                elif mutation == 'root-inode': cfg['execution_root']['root']['inode'] += 1
                elif mutation == 'cache-inode': cfg['execution_root']['cache']['inode'] += 1
                elif mutation == 'manifest-path': cfg['manifest'] = controller.descriptor(Path(cfg['downloads'])/'manifest.json')
                elif mutation == 'writable-manifest': (root/'manifest.json').chmod(0o600)
                elif mutation == 'manifest-bytes':
                    (root/'manifest.json').chmod(0o600); (root/'manifest.json').write_text('{}'); (root/'manifest.json').chmod(0o400)
                elif mutation == 'multiple-editions':
                    (root/'manifest.json').chmod(0o600)
                    write_json(root/'manifest.json', dict(requested_editions=['enwiktionary', 'frwiktionary'], files=[dict(wiki='enwiktionary')]))
                    (root/'manifest.json').chmod(0o400); cfg['manifest'] = controller.descriptor(root/'manifest.json')
                elif mutation == 'default-bypass': cfg.pop('execution_root')
                with self.assertRaises(ValueError): controller.resource_lock_paths(cfg)
                self.assertFalse((root/'controller.lock').exists())
                self.assertEqual(list((root/'state').iterdir()), [])
                self.assertEqual(list((root/'output').iterdir()), [])

    def test_real_symlinks_hardlinked_manifest_and_mount_or_inode_aliases_are_not_owned_scopes(self):
        import build_artifact_root as artifacts
        for mutation in ('role-symlink', 'root-symlink', 'hardlinked-manifest',
                         'mount-alias', 'mount-parent', 'mount-source', 'mount-downloads', 'inode-alias'):
            with self.subTest(mutation=mutation), self.fixture() as (cfg, source, workspace, root):
                if mutation == 'role-symlink':
                    (root/'cache').rmdir(); (root/'cache').symlink_to(root/'output', target_is_directory=True)
                elif mutation == 'root-symlink':
                    alias=root.with_name('alias'); alias.symlink_to(root, target_is_directory=True)
                    cfg['execution_root']['root']['path']=str(alias)
                elif mutation == 'hardlinked-manifest': os.link(root/'manifest.json',root/'alias.json')
                if mutation.startswith('mount-'):
                    mount = {'mount-alias': root/'cache/alias', 'mount-parent': root.parent,
                             'mount-source': source, 'mount-downloads': Path(cfg['downloads'])}[mutation]
                    with mock.patch.object(artifacts,'execution_mount_points',return_value=[mount]), self.assertRaisesRegex(ValueError,'mount alias'):
                        controller.resource_lock_paths(cfg)
                elif mutation == 'inode-alias':
                    original=Path.lstat
                    aliased=original(root/'output')
                    cfg['execution_root']['cache']['inode']=aliased.st_ino
                    def observed(path, *args, **kwargs):
                        return aliased if path==root/'cache' else original(path,*args,**kwargs)
                    with mock.patch.object(Path,'lstat',observed), self.assertRaisesRegex(ValueError,'alias the same inode'):
                        controller.resource_lock_paths(cfg)
                else:
                    with self.assertRaises(ValueError): controller.resource_lock_paths(cfg)
                self.assertFalse((root/'controller.lock').exists())
        with self.fixture() as (cfg, source, workspace, root):
            with mock.patch.object(artifacts,'execution_mount_points',return_value=[workspace]):
                self.assertEqual(controller.resource_lock_paths(cfg)[0],root/'controller.lock')

    def test_controller_guard_rejects_role_replacement_and_retained_source_mutation(self):
        for mutation in ('state-replaced','source-changed'):
            with self.subTest(mutation=mutation), self.fixture() as (cfg,source,workspace,root):
                controller.source_guard(cfg)
                if mutation=='state-replaced':
                    (root/'state').rename(root/'old-state'); (root/'state').mkdir(mode=0o700)
                else:(source/'src/producer.zig').write_text('changed source')
                with self.assertRaises(ValueError):controller.source_guard(cfg)

    def test_default_destination_bind_aliases_refuse_but_unrelated_mounted_outputs_keep_global_locks(self):
        import build_artifact_root as artifacts
        record = r'29 1 8:1 /private\040volume /output\040alias rw - ext4 /dev/example rw' + '\n'
        with mock.patch.object(Path, 'read_text', return_value=record):
            self.assertEqual(artifacts.execution_mounts(),
                [(Path('/output alias'), (8, 1), '/private volume')])
        # Actual namespace record from the failed qualification: unrelated
        # cgroup ancestry is not an artifact path, but must not authorize writes.
        kernel = '30 1 0:29 /../../../../../.. /mnt/ogroot/sys/fs/cgroup rw - cgroup2 cgroup rw\n'
        with mock.patch.object(Path, 'read_text', return_value=kernel):
            raw = artifacts.execution_mounts()
        self.assertEqual(raw[0][2], '/../../../../../..')
        with RetainedProducerRootTests().retained() as (cfg, source, workspace, _, _):
            records = [(Path('/'), (8, 1), '/'), *raw]
            with mock.patch.object(artifacts, 'execution_mounts', return_value=records):
                self.assertEqual(controller.resource_lock_paths(cfg)[0],
                                 workspace/'data/build-resources/corpus-controller.lock')
            for point in (Path(cfg['output']), Path(cfg['output'])/'nested'):
                with self.subTest(ambiguous_root=point):
                    records = [(Path('/'), (8, 1), '/'), (point, (0, 29), raw[0][2])]
                    with mock.patch.object(artifacts, 'execution_mounts', return_value=records), \
                         self.assertRaisesRegex(ValueError, 'absolute and canonical'):
                        controller.resource_lock_paths(cfg)
        for kind in ('role', 'ancestor', 'nested', 'unrelated', 'other-device'):
            with self.subTest(kind=kind), RetainedProducerRootTests().retained() as (cfg, source, workspace, _, _):
                reserved = workspace/'data/corpus-executions'
                output = Path(cfg['output'])
                point = output/'nested' if kind == 'nested' else output
                physical = reserved/'first/output'
                if kind == 'ancestor': physical = reserved.parent
                elif kind == 'unrelated': physical = Path('/unrelated-mounted-output')
                device = (8, 2) if kind == 'other-device' else (8, 1)
                mounts = [(Path('/'), (8, 1), Path('/')), (point, device, physical)]
                with mock.patch.object(artifacts, 'execution_mounts', return_value=mounts):
                    if kind in ('unrelated', 'other-device'):
                        self.assertEqual(controller.resource_lock_paths(cfg),
                            (workspace/'data/build-resources/corpus-controller.lock',
                             workspace/'.tmp/build-resources.lock'))
                    else:
                        with self.assertRaisesRegex(ValueError, 'aliases the execution namespace'):
                            controller.resource_lock_paths(cfg)
                self.assertFalse((workspace/'data/build-resources').exists())

    def test_execution_guard_rejects_actual_private_helper_origins_outside_retained_source(self):
        import build_artifact_root as artifacts
        origins_to_refuse = {'corpus_controller': controller.__file__,
                            'build_artifact_root': artifacts.__file__}
        for name, origin in origins_to_refuse.items():
            with self.subTest(helper=name), RetainedProducerRootTests().retained() as (cfg, source, workspace, _, origins):
                self.configure(cfg, workspace, 'private-import')
                controller.source_guard(cfg)
                origins[name] = origin
                with self.assertRaisesRegex(ValueError, 'outside the bound producer inventory'):
                    controller.source_guard(cfg)

    def test_canonical_scope_keeps_git_inventory_guards_and_refuses_source_domain_aliases(self):
        import build_artifact_root as artifacts
        for mutation in ('none', 'source-bytes', 'extra-source', 'directory-alias',
                         'file-alias', 'source-mount', 'controller-origin'):
            with self.subTest(mutation=mutation), RetainedProducerRootTests().retained() as (cfg, old_source, workspace, builder, _):
                inventory_path=Path(cfg['source']['inventory']['path'])
                inventory=json.loads(inventory_path.read_text())
                names=list(inventory['files'])
                for name in names:
                    path=workspace/name;path.parent.mkdir(parents=True,exist_ok=True)
                    path.write_bytes((old_source/name).read_bytes())
                inventory['files']={name:controller.descriptor(workspace/name) for name in names}
                inventory['modes']={name:(workspace/name).stat().st_mode & 0o7777 for name in names}
                write_json(inventory_path,inventory);cfg['source']['inventory']=controller.descriptor(inventory_path)
                cfg['source'].pop('root');cfg.pop('workspace_root')
                builder.PROJECT=workspace;builder.__file__=str(workspace/'tools/build_wiktionaries.py')
                root=self.configure(cfg,workspace,'canonical')
                tracked=list(names)
                def git(command, **kwargs):
                    self.assertEqual(kwargs['cwd'],workspace)
                    args=command[1:]
                    if args==['rev-parse','HEAD']:return cfg['source']['head']+'\n'
                    if args==['ls-files','-z']:return ('\0'.join(tracked)+'\0').encode()
                    if args==['ls-files','--others','--exclude-standard','-z']:return b''
                    self.fail('Unexpected canonical guard command: '+repr(command))
                with mock.patch.object(controller,'ROOT',workspace), \
                     mock.patch.object(controller,'__file__',str(workspace/'tools/corpus_controller.py')), \
                     mock.patch.object(controller.subprocess,'check_output',side_effect=git):
                    observed=controller.source_guard(cfg)
                    self.assertEqual(observed,dict(qualified_head=cfg['source']['head'],
                        current_head=cfg['source']['head'],producer_inventory=cfg['source']['inventory'],
                        apps_acceptance=False))
                    argv=controller.command(cfg,'enwiktionary',4)
                    self.assertEqual(argv[:3],[controller.sys.executable,'-B',str(workspace/'tools/build_wiktionaries.py')])
                    self.assertNotIn('--workspace-root-spec',argv)
                    self.assertIn('--execution-root-spec',argv)
                    if mutation=='none':
                        self.assertEqual(controller.resource_lock_paths(cfg)[0],root/'controller.lock')
                        continue
                    if mutation=='source-bytes':(workspace/'src/producer.zig').write_text('changed canonical source')
                    elif mutation=='extra-source':
                        (workspace/'src/new.py').write_text('new canonical source');tracked.append('src/new.py')
                    elif mutation=='directory-alias':
                        (workspace/'src').rename(workspace/'old-src');(workspace/'src').symlink_to(root/'output',target_is_directory=True)
                    elif mutation=='file-alias':
                        (workspace/'build.zig').unlink();(workspace/'build.zig').symlink_to(root/'manifest.json')
                    elif mutation=='source-mount':
                        with mock.patch.object(artifacts,'execution_mount_points',return_value=[workspace/'src']), \
                             self.assertRaisesRegex(ValueError,'mount alias'):
                            controller.source_guard(cfg)
                        continue
                    elif mutation=='controller-origin':
                        with mock.patch.object(controller,'__file__',str(old_source/'tools/corpus_controller.py')), \
                             self.assertRaisesRegex(ValueError,'bound producer source'):
                            controller.source_guard(cfg)
                        continue
                    with self.assertRaises(ValueError):controller.source_guard(cfg)


if __name__ == '__main__':
    unittest.main()


class BorrowedStagedInputOptionTests(unittest.TestCase):
    def fixture(self, root):
        path=root/'input';path.mkdir();(path/'.complete.json').write_text('{"version":"fixture"}\n')
        st=path.stat()
        record=dict(path=str(path),device=st.st_dev,inode=st.st_ino,uid=st.st_uid,mode=st.st_mode & 0o777,
                    completion=controller.descriptor(path/'.complete.json'))
        return path,record,dict(edition_options={'toy':dict(staged_input_root=record)})

    def test_exact_owned_root_and_completion_forward_existing_cli(self):
        with tempfile.TemporaryDirectory() as tmp:
            path,record,cfg=self.fixture(Path(tmp));before=tuple(getattr((path/'.complete.json').stat(),k) for k in ('st_dev','st_ino','st_size','st_mtime_ns','st_ctime_ns'))
            self.assertEqual(controller.edition_cli_options(cfg,'toy'),['--staged-input-root',str(path)])
            self.assertEqual(tuple(getattr((path/'.complete.json').stat(),k) for k in ('st_dev','st_ino','st_size','st_mtime_ns','st_ctime_ns')),before)
            self.assertEqual(controller.edition_cli_options({},'toy'),[])
            cfg.update(build_timeout_seconds=60,now_unix=123,expansion_timeout_ms=1000,downloads=str(path.parent/'downloads'),output=str(path.parent/'output'),raw_shard_root=str(path.parent/'raw'),compiler=dict(path='/fixture/zig'))
            with mock.patch.object(controller,'source_roots',return_value=(path.parent,path.parent)):
                argv=controller.command(cfg,'toy',1)
            self.assertEqual(argv.count('--staged-input-root'),1)
            self.assertEqual(argv[argv.index('--staged-input-root')+1],str(path))
            self.assertEqual(argv[argv.index('--watchdog-memory-limit-mib')+1],'8192')

    def test_replaced_completion_wrong_root_and_symlink_refuse(self):
        for mode in ('marker','inode','uid','completion-path','alias','extra'):
            with self.subTest(mode=mode),tempfile.TemporaryDirectory() as tmp:
                root=Path(tmp);path,record,cfg=self.fixture(root)
                if mode=='marker':(path/'.complete.json').write_text('changed')
                if mode=='inode':record['inode']+=1
                if mode=='uid':record['uid']+=1
                if mode=='completion-path':record['completion']=controller.descriptor(path/'.complete.json')|{'path':str(root/'elsewhere')}
                if mode=='alias':
                    alias=root/'alias';alias.symlink_to(path,target_is_directory=True);record['path']=str(alias)
                if mode=='extra':record['unverified_payloads']=True
                with self.assertRaises((ValueError,OSError)):controller.edition_cli_options(cfg,'toy')


class SupersededGeneratedLifecycleTests(unittest.TestCase):
    @contextmanager
    def fixture(self, root):
        from contextlib import ExitStack
        artifacts = root / 'data/artifacts'; artifacts.mkdir(parents=True, mode=0o700)
        info = artifacts.stat()
        owner = dict(path=str(artifacts), device=info.st_dev, inode=info.st_ino,
                     uid=info.st_uid, mode=0o700)
        edition, date = 'toy', '20261001'
        cfg = dict(date=date, output=str(artifacts/'new'), raw_shard_root=str(artifacts/'new-raw'),
                   state_directory=str(root/'data/new-state'), downloads=str(root/'data/downloads'),
                   artifact_root=owner, edition_options={})
        old = dict(cfg, output=str(artifacts/'old'), raw_shard_root=str(artifacts/'old-raw'),
                   state_directory=str(root/'data/old-state'))
        def doc(path, value):
            write_json(path, value)
            return controller.descriptor(path)
        old_ref = doc(root/'old-config.json', old)
        prior_path = Path(old['state_directory'])/'attempts/000001/result.json'
        prior = dict(edition=edition, outcome='failed', accepted=None, cleanup_proven=True,
                     source_guard=True, control_proven=True)
        prior_ref = doc(prior_path, prior)
        closed = dict(configuration=old_ref, attempts=[prior_ref], physical_closure=True,
                      source_guard_after=True, cleanup_complete=True, ps_owned_absent=True,
                      attempt_evidence={str(prior_path): dict(result=prior_ref, physical_closure=True,
                                                             source_guard_after=True)})
        closed_ref = doc(root/'old-closure.json', closed)
        parent = Path(old['output'])/edition; parent.mkdir(parents=True)
        lock_path = parent/(date+'.lock'); lock_path.touch()
        paths = [parent/(date+'.shards')/'expander/.bundle-expander',
                 parent/(date+'.shards')/'native-blob-tools',
                 parent/(date+'.building')/'.bundle-expander']
        for path in paths:
            path.mkdir(parents=True); (path/'generated.bin').write_bytes(b'generated native fixture')
        keep = [parent/date/'languages/blob.wikblb.xz', parent/(date+'.shards')/'input/pages.xml.zst',
                parent/(date+'.shards.failures')/'failed/raw.wikitext',
                parent/(date+'.building')/'.presentation-first-failure/capture.json',
                Path(old['raw_shard_root'])/edition/(date+'.raw-shards')/'00000000/.presentation-first-failure/raw.wikitext',
                Path(cfg['downloads'])/'official.xml.bz2', Path(cfg['output'])/edition/(date+'.shards')/'resume-state']
        for path in keep:
            path.parent.mkdir(parents=True, exist_ok=True); path.write_bytes(('keep '+path.name).encode())
        roles = dict(schema='wikidict.runtime-generated-artifact-role-dispositions.v1', keep_current_outputs={},
                     records=[dict(configuration=old_ref, closed_results=[prior_ref], edition=edition,
                                   date=date, output_root=old['output'],
                                   runtime_disposition='NO_RUNTIME_EXECUTION_OR_QUEUED_REUSE_OF_GENERATED_WORKER_LLVM_OBJECT_TOOL_LEAVES',
                                   derived_generated_parent_candidates=list(map(str, paths)))])
        roles_ref = doc(root/'roles.json', roles)
        record = dict(configuration=old_ref, result=prior_ref, closure=closed_ref, runtime_roles=roles_ref)
        cfg['superseded_generated'] = {edition: [record]}
        publication = Path(cfg['output'])/edition/date; publication.mkdir(parents=True)
        (publication/'blob.wikblb.xz').write_bytes(b'accepted dictionary')
        complete = doc(publication/'complete.json', dict(publication_files={'blob.wikblb.xz': dict(size=19)}))
        snapshot = root/'current-complete.json'; snapshot.write_bytes((publication/'complete.json').read_bytes())
        accepted = dict(root=str(publication), complete=complete, complete_snapshot=controller.descriptor(snapshot))
        row = dict(outcome='passed', accepted=accepted, exit_code=0, controller_interrupted=False,
                   cleanup_proven=True, source_guard=True, control_proven=True)
        folder = Path(cfg['state_directory'])/'attempts/new'; folder.mkdir(parents=True)
        views = (root/'proc-local', root/'proc-parent')
        for view in views: view.mkdir()
        with mock.patch.object(controller, 'ROOT', root), \
             mock.patch.object(controller, 'GENERATION_PROC_VIEWS', tuple(map(str, views))), ExitStack() as stack:
            locks = [stack.enter_context(controller.Lock(path, own))
                     for path, own in zip(controller.resource_lock_paths(cfg), (True, False))]
            yield dict(cfg=cfg, old=old, row=row, record=record, roles=roles, closed=closed,
                       folder=folder, locks=locks, edition=edition, paths=paths, keep=keep,
                       lock_path=lock_path, doc=doc, root=root, views=views)

    def retire(self, f):
        return controller.cleanup_superseded_generated(f['cfg'], f['edition'], f['folder'], f['row'], f['locks'])

    def snapshot(self, root):
        return {str(path.relative_to(root)): path.read_bytes() for path in root.rglob('*') if path.is_file()}

    def test_replacement_retires_only_three_owned_generated_roles_and_keeps_diagnostics(self):
        with tempfile.TemporaryDirectory() as tmp, self.fixture(Path(tmp)) as f:
            before = {path: path.read_bytes() for path in f['keep']}
            original = copy.deepcopy(f['row'])
            generated = [path/'generated.bin' for path in f['paths']]
            logical = sum(path.stat().st_size for path in generated)
            allocated = sum(path.stat().st_blocks * 512 for path in generated)
            result = self.retire(f)
            self.assertEqual(result['status'], 'superseded-generated-retired')
            self.assertEqual(result['generations'][0]['removed'], list(map(str, f['paths'])))
            self.assertEqual(result['generations'][0]['removed_file_count'], 3)
            self.assertEqual(result['generations'][0]['removed_logical_file_bytes'], logical)
            self.assertEqual(result['generations'][0]['removed_allocated_file_bytes'], allocated)
            self.assertIn('not filesystem free-space delta', result['generations'][0]['accounting'])
            self.assertTrue(all(not path.exists() for path in f['paths']))
            self.assertEqual(before, {path: path.read_bytes() for path in f['keep']})
            self.assertEqual(f['row'], original)
            self.assertTrue(controller.publication_present(f['row']['accepted']))
            self.assertTrue(f['lock_path'].is_file())
            self.assertEqual(self.retire(f)['generations'][0]['removed'], [])

    def test_default_resume_and_failed_or_unproven_replacement_preserve_every_byte(self):
        for defect in ('absent', 'failed', 'unjoined', 'source', 'control', 'interrupted', 'missing-publication'):
            with self.subTest(defect=defect), tempfile.TemporaryDirectory() as tmp, self.fixture(Path(tmp)) as f:
                if defect == 'absent': del f['cfg']['superseded_generated']
                elif defect == 'failed': f['row'].update(outcome='failed', accepted=None, exit_code=1)
                elif defect == 'missing-publication': Path(f['row']['accepted']['complete']['path']).unlink()
                elif defect == 'interrupted': f['row']['controller_interrupted'] = True
                else: f['row'][dict(unjoined='cleanup_proven', source='source_guard', control='control_proven')[defect]] = False
                before = self.snapshot(f['root'])
                if defect == 'missing-publication':
                    with self.assertRaisesRegex(ValueError, 'publication is unavailable'): self.retire(f)
                else:
                    self.assertIn(self.retire(f)['status'], ('not-selected', 'retained-no-valid-replacement'))
                self.assertEqual(self.snapshot(f['root']), before)

    def test_selected_consumer_borrowed_input_and_live_edition_lock_prevent_retirement(self):
        import fcntl
        for mode in ('selected', 'borrowed', 'edition-lock'):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as tmp, self.fixture(Path(tmp)) as f:
                fd = None
                if mode == 'selected':
                    f['roles']['keep_current_outputs'][f['old']['output']] = {'role': 'selected audit'}
                    f['record']['runtime_roles'] = f['doc'](f['root']/'roles.json', f['roles'])
                elif mode == 'borrowed':
                    f['cfg']['edition_options'] = {'other': {'staged_input_root': {'path': str(f['paths'][0])}}}
                else:
                    fd = os.open(f['lock_path'], os.O_RDWR); fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                try:
                    before = self.snapshot(f['root'])
                    with self.assertRaises((ValueError, BlockingIOError)): self.retire(f)
                    self.assertEqual(self.snapshot(f['root']), before)
                finally:
                    if fd is not None: os.close(fd)

    def test_live_open_file_and_hardlink_alias_are_detected_without_signals(self):
        for alias in (False, True):
            with self.subTest(alias=alias), tempfile.TemporaryDirectory() as tmp, self.fixture(Path(tmp)) as f:
                # Real current-process FDs and birth, exposed through the parent view only.
                own = f['views'][1]/str(os.getpid()); own.symlink_to(Path('/proc')/str(os.getpid()))
                path = f['paths'][0]/'generated.bin'
                other = f['root']/'borrowed-native'
                if alias: os.link(path, other); path = other
                with path.open('rb'), mock.patch.object(controller.os, 'kill', side_effect=AssertionError('no signals')) as kill:
                    before = self.snapshot(f['root'])
                    with self.assertRaisesRegex(ValueError, 'external hardlinks' if alias else 'live consumer'):
                        self.retire(f)
                    self.assertEqual(self.snapshot(f['root']), before)
                kill.assert_not_called()
                if alias: other.unlink()
                self.assertEqual(self.retire(f)['status'], 'superseded-generated-retired')

    def test_missing_closure_wrong_role_and_current_generation_alias_are_refused(self):
        for mode in ('closure', 'wrong-edition', 'role', 'current', 'duplicate'):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as tmp, self.fixture(Path(tmp)) as f:
                if mode == 'closure':
                    f['closed']['physical_closure'] = False
                    f['record']['closure'] = f['doc'](f['root']/'old-closure.json', f['closed'])
                elif mode == 'wrong-edition':
                    f['roles']['records'][0]['edition'] = 'other'
                    f['record']['runtime_roles'] = f['doc'](f['root']/'roles.json', f['roles'])
                elif mode == 'role':
                    f['roles']['records'][0]['derived_generated_parent_candidates'][0] = str(f['root'])
                    f['record']['runtime_roles'] = f['doc'](f['root']/'roles.json', f['roles'])
                elif mode == 'current': f['cfg']['raw_shard_root'] = str(f['paths'][0])
                else: f['cfg']['superseded_generated'][f['edition']].append(copy.deepcopy(f['record']))
                before = self.snapshot(f['root'])
                with self.assertRaises(ValueError): self.retire(f)
                self.assertEqual(self.snapshot(f['root']), before)

    def test_symlink_or_unique_diagnostic_inside_generated_role_defers_before_deletion(self):
        for mode in ('root-symlink', 'child-symlink', 'capture', 'fifo'):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as tmp, self.fixture(Path(tmp)) as f:
                path = f['paths'][0]
                if mode == 'root-symlink':
                    saved = path.with_name('saved'); path.rename(saved); path.symlink_to(saved, target_is_directory=True)
                elif mode == 'child-symlink': (path/'alias').symlink_to(f['keep'][0])
                elif mode == 'fifo': os.mkfifo(path/'unexpected-pipe')
                else: (path/'capture.json').write_bytes(b'unique evidence, do not discard')
                before = self.snapshot(f['root'])
                with self.assertRaises(ValueError): self.retire(f)
                self.assertEqual(self.snapshot(f['root']), before)
                self.assertTrue(f['paths'][1].is_dir())

    def test_existing_execute_records_cleanup_error_after_original_result_without_changing_time(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); cfg = ControllerMemoryPolicyTests().cfg(root)
            cfg['superseded_generated'] = {'arwiktionary': [{}]}; folder = root/'attempt'
            process = mock.Mock(pid=900123); process.poll.return_value=0; process.wait.return_value=0
            start = dict(edition='arwiktionary', date='20261001', phase='edition_build', event='start')
            end = dict(start, event='end', status='success', seconds=3.25, execution_mode=FRESH)
            original = []
            def spawn(*args, **kwargs):
                write_json(Path(kwargs['cwd'])/'.tmp/build-watchdog-report.json', dict(termination_reason='child_exit',
                    child_exit_status=0, guardian_exit_status=0, memory_limit_bytes=controller.MEMORY))
                kwargs['stdout'].write(('BUILD_PHASE '+json.dumps(start)+'\nBUILD_PHASE '+json.dumps(end)+'\n').encode())
                kwargs['stdout'].flush(); return process
            def cleanup(*args):
                original.append((folder/'result.json').read_bytes())
                self.assertEqual(controller.read_json(folder/'result.json'), args[3])
                raise OSError('retirement unavailable')
            with mock.patch.object(controller, 'ROOT', root), \
                 mock.patch.object(controller.subprocess, 'Popen', side_effect=spawn), \
                 mock.patch.object(controller, 'process_identity', return_value=dict(pid=900123, start_time_ticks=1)), \
                 mock.patch.object(controller, 'watchdog_closed', return_value=True), \
                 mock.patch.object(controller, 'source_guard'), \
                 mock.patch.object(controller, 'accept', return_value=dict(input_pages=10)), \
                 mock.patch.object(controller, 'cleanup_superseded_generated', side_effect=cleanup) as retired:
                row, _ = controller.execute(cfg, 'arwiktionary', 4, folder, 1, 'context', [])
            retired.assert_called_once()
            self.assertEqual((folder/'result.json').read_bytes(), original[0])
            self.assertEqual(row['outcome'], 'passed'); self.assertEqual(row['production_elapsed_seconds'], 3.25)
            self.assertIsNone(row['error'])
            evidence = controller.read_json(folder/'superseded-generated-cleanup.json')
            self.assertEqual(evidence['status'], 'cleanup-deferred')
            self.assertIn('retirement unavailable', evidence['error'])

    def test_predecessor_selection_is_bound_into_existing_production_context(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); cfg = ControllerMemoryPolicyTests().cfg(root)
            before = controller.production_context(cfg)
            cfg['superseded_generated'] = {'arwiktionary': [{'configuration': 'selected predecessor'}]}
            self.assertNotEqual(controller.production_context(cfg), before)

    def test_closed_protected_hardlink_keeps_content_and_identity_pins(self):
        with tempfile.TemporaryDirectory() as tmp, self.fixture(Path(tmp)) as f:
            protected = f['keep'][5]
            alias = f['paths'][0]/'closed-input-alias'; os.link(protected, alias)
            before = protected.stat()
            payload = protected.read_bytes()
            with self.assertRaisesRegex(ValueError, 'external hardlinks'): self.retire(f)
            after = protected.stat()
            self.assertEqual((before.st_dev, before.st_ino, before.st_nlink, before.st_ctime_ns),
                             (after.st_dev, after.st_ino, after.st_nlink, after.st_ctime_ns))
            self.assertEqual(protected.read_bytes(), payload)
            self.assertTrue(all(path.is_dir() for path in f['paths']))

    def test_both_proc_views_use_local_births_and_refuse_unknown_visibility(self):
        for mode in ('parent-only', 'duplicate-view', 'changed-birth', 'missing-view', 'permission'):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp); views = (root/'local', root/'parent')
                for view in views: view.mkdir()
                target = root/'generated'; target.write_bytes(b'owned payload')
                info = target.stat(); identity = {(info.st_dev, info.st_ino)}
                process = views[1]/'731'; process.mkdir(); (process/'fd').mkdir()
                (process/'fd/4').symlink_to(target); (process/'maps').write_text('')
                (process/'stat').write_text('731 (fixture) ' + ' '.join(['S'] + ['0']*18 + ['9001']))
                selected = (str(views[1]), str(views[1])) if mode == 'duplicate-view' else tuple(map(str, views))
                if mode == 'missing-view': selected = (str(views[0]), str(root/'absent'))
                with mock.patch.object(controller, 'GENERATION_PROC_VIEWS', selected):
                    if mode == 'changed-birth':
                        with mock.patch.object(controller, '_generation_process_identity',
                            side_effect=[dict(pid=731, start_time_ticks=9001), dict(pid=731, start_time_ticks=9002)]):
                            with self.assertRaisesRegex(ValueError, 'birth changed'):
                                controller._generated_consumers(identity)
                    elif mode == 'permission':
                        with mock.patch.object(controller, '_generation_process_identity', side_effect=PermissionError('unknown owner')):
                            with self.assertRaises(PermissionError): controller._generated_consumers(identity)
                    elif mode == 'missing-view':
                        with self.assertRaisesRegex(ValueError, 'visibility is unavailable'):
                            controller._generated_consumers(identity)
                    else:
                        found = controller._generated_consumers(identity)
                        self.assertEqual(len(found), 1)
                        self.assertEqual(found[0]['identity'], dict(pid=731, start_time_ticks=9001))
                        self.assertEqual(found[0]['proc_view'], str(views[1]))
                        self.assertEqual(found[0]['uses'], [str(process/'fd/4')])

    def test_source_domains_aliases_and_authorization_files_are_preserved(self):
        from contextlib import ExitStack
        import build_artifact_root
        for mode in ('frozen-source', 'canonical-source-alias', 'role-receipt', 'old-downloads', 'old-borrowed-input'):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as tmp, self.fixture(Path(tmp)) as f, ExitStack() as stack:
                if mode == 'frozen-source':
                    stack.enter_context(mock.patch.object(controller, 'source_roots', return_value=(f['paths'][0], f['root'])))
                elif mode == 'canonical-source-alias':
                    original = build_artifact_root.execution_mount_regions
                    def regions(path, mounts):
                        return original(f['paths'][0] if path == f['root']/'src' else path, mounts)
                    stack.enter_context(mock.patch.object(build_artifact_root, 'execution_mount_regions', side_effect=regions))
                elif mode == 'role-receipt':
                    f['record']['runtime_roles'] = f['doc'](f['paths'][0]/'released-roles.json', f['roles'])
                else:
                    old_ref = f['record']['configuration']
                    if mode == 'old-downloads': f['old']['downloads'] = str(f['paths'][0])
                    else: f['old']['edition_options'] = {'other': {'staged_input_root': {'path': str(f['paths'][0])}}}
                    new_ref = f['doc'](Path(old_ref['path']), f['old'])
                    f['record']['configuration'] = new_ref
                    f['closed']['configuration'] = new_ref
                    f['record']['closure'] = f['doc'](Path(f['record']['closure']['path']), f['closed'])
                    f['roles']['records'][0]['configuration'] = new_ref
                    f['record']['runtime_roles'] = f['doc'](Path(f['record']['runtime_roles']['path']), f['roles'])
                before = self.snapshot(f['root'])
                with self.assertRaisesRegex(ValueError, 'overlaps current|physically aliases current'): self.retire(f)
                self.assertEqual(self.snapshot(f['root']), before)
                self.assertTrue(all(path.is_dir() for path in f['paths']))

    def test_descendant_drift_after_consumer_scan_preserves_all_selected_trees(self):
        for mode in ('added-capture', 'replacement', 'protected-hardlink'):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as tmp, self.fixture(Path(tmp)) as f:
                def observed(_):
                    if mode == 'added-capture': (f['paths'][2]/'capture.json').write_bytes(b'new unique failure')
                    elif mode == 'protected-hardlink': os.link(f['keep'][5], f['paths'][2]/'new-input')
                    else:
                        path = f['paths'][2]/'generated.bin'; replacement = path.with_name('new')
                        replacement.write_bytes(path.read_bytes()); replacement.replace(path)
                    return []
                with mock.patch.object(controller, '_generated_consumers', side_effect=observed):
                    with self.assertRaisesRegex(ValueError, 'Unique diagnostic|external hardlinks|descendants changed'):
                        self.retire(f)
                self.assertTrue(all((path/'generated.bin').is_file() for path in f['paths']))

    def test_inventory_bounds_visits_even_when_entries_repeat(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); (root/'same').write_bytes(b'one inode')
            with mock.patch.object(controller, 'GENERATED_RETIREMENT_MAX_ENTRIES', 3), \
                 mock.patch.object(controller.os, 'walk', return_value=[(str(root), [], ['same']*4)]):
                with self.assertRaisesRegex(ValueError, 'exceeds bounded cleanup'):
                    controller._generated_inventory([root])

    def test_removal_error_reports_only_completed_inode_bytes_without_changing_result(self):
        import build_artifact_root
        with tempfile.TemporaryDirectory() as tmp, self.fixture(Path(tmp)) as f:
            original = build_artifact_root.OwnedArtifactRoot.remove_tree
            info = (f['paths'][0]/'generated.bin').stat()
            row = copy.deepcopy(f['row'])
            def remove(owner, path):
                if path == f['paths'][1]: raise OSError('injected removal error')
                return original(owner, path)
            with mock.patch.object(build_artifact_root.OwnedArtifactRoot, 'remove_tree', remove):
                result = self.retire(f)
            self.assertEqual(result['status'], 'cleanup-deferred')
            self.assertIn('injected removal error', result['error'])
            actual = result['generations'][0]
            self.assertEqual(actual['removed'], [str(f['paths'][0])])
            self.assertEqual(actual['removed_file_count'], 1)
            self.assertEqual(actual['removed_logical_file_bytes'], info.st_size)
            self.assertEqual(actual['removed_allocated_file_bytes'], info.st_blocks*512)
            self.assertTrue(actual['partial_removal_unknown'])
            self.assertEqual(actual['incomplete_removal'], str(f['paths'][1]))
            self.assertTrue(f['paths'][1].is_dir() and f['paths'][2].is_dir())
            self.assertEqual(f['row'], row)


class DerivedGenerationLifecycleTests(unittest.TestCase):
    @contextmanager
    def fixture(self, root, count=2):
        import hashlib
        import native_qualification
        with SupersededGeneratedLifecycleTests().fixture(root) as f:
            def directory(path):
                s=path.stat()
                return dict(path=str(path),device=s.st_dev,inode=s.st_ino,uid=s.st_uid,mode=s.st_mode&0o7777)
            identity=dict(version=4,extractor_args=['--page-index'],dump_sha256='a'*64,index_sha256='b'*64,
                namespace_registry_sha256='c'*64,transclusion_redirects_sha256=None,page_redirects_sha256=None,
                unicode_case={'libraries':[]},tool={'extractor_sha256':'d'*64,'libraries':[]})
            keep_identity=copy.deepcopy(identity);keep_identity['tool']['extractor_sha256']='e'*64
            key=lambda v:hashlib.sha256(json.dumps(v,sort_keys=True).encode()).hexdigest()
            parent=Path(f['old']['output'])/f['edition']/(f['cfg']['date']+'.shards')
            aliases=[parent/'input/extraction-cache'/key(identity),f['paths'][0]]
            for index in range(2,count):
                aliases.append(root/'data'/('alias'+str(index))/(f['cfg']['date']+'.shards')/'input/extraction-cache'/key(identity))
            keeper=root/'data/keeper/input/extraction-cache'/key(keep_identity)
            names=['modules/1.lua','modules/nested/2.lua','page-index.tsv']
            rows=[]
            for name in names:
                data=('derived '+name).encode();rows.append([name,len(data),hashlib.sha256(data).hexdigest()])
                path=aliases[0]/name;path.parent.mkdir(parents=True,exist_ok=True);path.write_bytes(data)
                for alias in aliases[1:]:
                    target=alias/name;target.parent.mkdir(parents=True,exist_ok=True);os.link(path,target)
                target=keeper/name;target.parent.mkdir(parents=True,exist_ok=True);target.write_bytes(data)
            for path in aliases:
                (path/'extraction-source.json').write_text('old source provenance')
                (path/'lua-usage.tsv').write_text('retain usage evidence')
            (keeper/'extraction-source.json').write_text('new keeper provenance')
            def marker(where,value):
                raw=(where/'extraction-source.json').read_bytes()
                return f['doc'](where/'.complete.json',dict(identity=value,assets=sorted(rows+[
                    ['extraction-source.json',len(raw),hashlib.sha256(raw).hexdigest()]])))
            old=marker(aliases[0],identity);keep=marker(keeper,keep_identity)
            authority=f['doc'](root/'source-authority.json',{'source':'selected immutable input'})
            source=root/'data/current-source';source.mkdir();source_file=source/'input.xml';source_file.write_bytes(b'official input retained')
            lock=f['locks'][0];s=os.fstat(lock.fd)
            core=dict(selection_protocol='controller-lock-v1',lock=dict(path=str(lock.path),dev=s.st_dev,ino=s.st_ino),
                authorities=[authority],paths=[dict(path=str(source_file),identity=list(controller._derived_identity(source_file)))],unresolved=[])
            checkpoint=f['doc'](root/'selection.json',dict(committed_source_selection=core))
            f['roles']['derived_source_pins']=dict(core,selection_checkpoint=checkpoint)
            record=dict(manifest=old,keeper=keep,aliases=list(map(directory,aliases)),asset_groups=['modules','shared-indexes'])
            f['record']['derived_assets']=[record]
            f['roles']['records'][0]['released_derived_assets']=[record]
            f['record']['runtime_roles']=f['doc'](root/'roles.json',f['roles'])
            f['cfg']['build_timeout_seconds']=30
            f.update(aliases=aliases,keeper=keeper,names=names,derived=record,core=core,checkpoint=root/'selection.json')
            with mock.patch.object(native_qualification,'_retention_locks_clear',return_value=True), \
                 mock.patch.object(controller.subprocess,'run',return_value=SimpleNamespace(returncode=1,stdout='',stderr='')):
                yield f

    def retire(self, f, callback=True):
        return controller.cleanup_superseded_generated(f['cfg'],f['edition'],f['folder'],f['row'],f['locks'],
            reconcile_derived_sources=controller._reconcile_derived_sources if callback else None)

    def assert_kept(self, f):
        self.assertTrue(all((root/name).is_file() for root in f['aliases'] for name in f['names']))
        self.assertTrue(all((f['keeper']/name).is_file() for name in f['names']))

    def test_manifest_aliases_remove_last_link_once_and_preserve_sources_and_unique_siblings(self):
        for count in (2,4):
            with self.subTest(count=count),tempfile.TemporaryDirectory() as tmp,self.fixture(Path(tmp),count) as f:
                unique=f['aliases'][1]/'capture.json';unique.write_text('unique diagnostic')
                before={p:p.read_bytes() for p in [unique,*f['keep'],Path(f['derived']['manifest']['path']),
                    *[root/'extraction-source.json' for root in f['aliases']],*[root/'lua-usage.tsv' for root in f['aliases']]]}
                allocated=sum((f['aliases'][0]/name).stat().st_blocks*512 for name in f['names'])
                original=copy.deepcopy(f['row']);walk=os.walk
                def bounded_walk(path,*args,**kwargs):
                    self.assertFalse(any(Path(path).is_relative_to(root) for root in f['aliases']))
                    return walk(path,*args,**kwargs)
                with mock.patch.object(controller.os,'walk',side_effect=bounded_walk):out=self.retire(f)
                result=out['generations'][0]['derived_assets']
                self.assertEqual(out['status'],'superseded-generated-retired')
                self.assertEqual((result['removed_names'],result['freed_inodes']),(3*count,3))
                self.assertEqual(result['freed_allocated_inode_bytes'],allocated)
                self.assertIsNone(result['exclusive_gain_bytes'])
                self.assertEqual(f['row'],original)
                self.assertTrue(all(not (root/name).exists() for root in f['aliases'] for name in f['names']))
                self.assertEqual(before,{p:p.read_bytes() for p in before})

    def test_current_physical_source_and_active_consumer_each_defer_derived_assets(self):
        for mode in ('current-root','current-inode','active','active-parent'):
            with self.subTest(mode=mode),tempfile.TemporaryDirectory() as tmp,self.fixture(Path(tmp)) as f:
                if mode.startswith('current'):
                    path=f['aliases'][0] if mode=='current-root' else f['aliases'][0]/f['names'][0]
                    f['core']['paths'].append(dict(path=str(path),identity=list(controller._derived_identity(path))))
                    checkpoint=f['doc'](f['checkpoint'],dict(committed_source_selection=f['core']))
                    f['roles']['derived_source_pins']=dict(f['core'],selection_checkpoint=checkpoint)
                    f['record']['runtime_roles']=f['doc'](f['root']/'roles.json',f['roles'])
                inode=controller._derived_identity(f['aliases'][0] if mode=='active-parent' else f['aliases'][0]/f['names'][0])[:2]
                real=controller._generated_consumers
                with mock.patch.object(controller,'_generated_consumers',side_effect=lambda ids:
                    ['active'] if mode.startswith('active') and inode in ids else real(ids)):
                    out=self.retire(f)
                self.assertEqual(out['status'],'cleanup-deferred');self.assert_kept(f)

    def test_unique_assets_unknown_aliases_and_changed_keeper_are_not_removed(self):
        for mode in ('unique','unknown-marker','unknown-alias','keeper-during-probe'):
            with self.subTest(mode=mode),tempfile.TemporaryDirectory() as tmp,self.fixture(Path(tmp)) as f:
                if mode in ('unique','unknown-marker'):
                    old=controller.read_ref(f['derived']['manifest'])
                    if mode=='unique':old['assets'].append(['modules/unique.lua',1,'a'*64])
                    else:old['asset_ownership']='unsupported-v9'
                    old['assets'].sort();f['derived']['manifest']=f['doc'](Path(f['derived']['manifest']['path']),old)
                    f['record']['runtime_roles']=f['doc'](f['root']/'roles.json',f['roles'])
                elif mode=='unknown-alias':os.link(f['aliases'][0]/f['names'][0],f['root']/'unreleased-source.lua')
                else:
                    def probe(*args,**kwargs):
                        (f['keeper']/f['names'][0]).write_bytes(b'changed keeper')
                        return SimpleNamespace(returncode=1,stdout='',stderr='')
                    controller.subprocess.run.side_effect=probe
                out=self.retire(f)
                self.assertEqual(out['status'],'cleanup-deferred');self.assert_kept(f)

    def test_new_committed_queue_after_original_selection_and_unknown_authority_defer(self):
        for mode in ('new-queue','unknown','source-drift','legacy','no-callback'):
            with self.subTest(mode=mode),tempfile.TemporaryDirectory() as tmp,self.fixture(Path(tmp)) as f:
                if mode=='new-queue':
                    # Publisher already holds the exact coordinator lock here.
                    changed=copy.deepcopy(f['core']);path=f['aliases'][0]/f['names'][0]
                    changed['paths'].append(dict(path=str(path),identity=list(controller._derived_identity(path))))
                    f['doc'](f['checkpoint'],dict(committed_source_selection=changed))
                elif mode=='unknown':
                    f['roles']['derived_source_pins']['unresolved']=['queued source unresolved']
                    f['record']['runtime_roles']=f['doc'](f['root']/'roles.json',f['roles'])
                elif mode=='source-drift':Path(f['core']['paths'][0]['path']).write_bytes(b'changed source')
                elif mode=='legacy':
                    del f['roles']['derived_source_pins']
                    f['record']['runtime_roles']=f['doc'](f['root']/'roles.json',f['roles'])
                out=self.retire(f,callback=mode!='no-callback')
                self.assertEqual(out['status'],'cleanup-deferred');self.assert_kept(f)
                # Deferring the new branch does not disable old nlink1 cleanup.
                self.assertTrue(all(not path.exists() for path in f['paths'][1:]))

    def test_concurrent_committed_queue_writer_cannot_cross_held_controller_lock(self):
        import sys
        with tempfile.TemporaryDirectory() as tmp,self.fixture(Path(tmp)) as f:
            checkpoint=f['checkpoint'].read_bytes();observed=[]
            code="""import fcntl,os,sys
fd=os.open(sys.argv[1],os.O_RDWR)
try:fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB)
except BlockingIOError:sys.exit(23)
open(sys.argv[2],'w').write('unexpected committed source')
sys.exit(0)
"""
            def probe(*args,**kwargs):
                child=controller.subprocess.Popen([sys.executable,'-I','-c',code,str(f['locks'][0].path),str(f['checkpoint'])],
                    stdout=controller.subprocess.PIPE,stderr=controller.subprocess.PIPE)
                stdout,stderr=child.communicate(timeout=5);observed.append(child.returncode)
                self.assertEqual((child.returncode,stdout,stderr),(23,b'',b''))
                return SimpleNamespace(returncode=1,stdout='',stderr='')
            controller.subprocess.run.side_effect=probe
            result=self.retire(f)
            self.assertEqual(result['status'],'superseded-generated-retired');self.assertTrue(observed)
            self.assertEqual(f['checkpoint'].read_bytes(),checkpoint)

    def test_normal_cli_selects_reconciler_only_for_declared_derived_predecessor(self):
        for enabled in (False,True):
            with self.subTest(enabled=enabled),tempfile.TemporaryDirectory() as tmp:
                root=Path(tmp);seen=[]
                overrides={'superseded_generated':{'arwiktionary':[{'derived_assets':[{'declared':'selection'}]}]}} if enabled else {}
                def observe(kwargs):seen.append(kwargs)
                with mock.patch.object(controller,'ROOT',root):
                    ControllerAllReadyTests().run_main(root,max_editions=1,cfg_overrides=overrides,observe_execute_kwargs=observe)
                self.assertEqual(len(seen),1)
                self.assertEqual(seen[0],{'reconcile_derived_sources':controller._reconcile_derived_sources} if enabled else {})

    def test_actual_execute_forwards_custody_after_durable_result_without_changing_qualification(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);cfg=ControllerMemoryPolicyTests().cfg(root);cfg['superseded_generated']={'arwiktionary':[{}]}
            folder=root/'attempt';process=mock.Mock(pid=900123);process.poll.return_value=0;process.wait.return_value=0
            start=dict(edition='arwiktionary',date='20261001',phase='edition_build',event='start')
            end=dict(start,event='end',status='success',seconds=3.25,execution_mode=FRESH);original=[]
            def spawn(*args,**kwargs):
                write_json(Path(kwargs['cwd'])/'.tmp/build-watchdog-report.json',dict(termination_reason='child_exit',
                    child_exit_status=0,guardian_exit_status=0,memory_limit_bytes=controller.MEMORY))
                kwargs['stdout'].write(('BUILD_PHASE '+json.dumps(start)+'\nBUILD_PHASE '+json.dumps(end)+'\n').encode())
                kwargs['stdout'].flush();return process
            def cleanup(*args,**kwargs):
                original.append((folder/'result.json').read_bytes())
                self.assertIs(kwargs['reconcile_derived_sources'],controller._reconcile_derived_sources)
                self.assertEqual(controller.read_json(folder/'result.json'),args[3]);raise ValueError('queue source changed')
            with mock.patch.object(controller,'ROOT',root),mock.patch.object(controller.subprocess,'Popen',side_effect=spawn), \
                 mock.patch.object(controller,'process_identity',return_value=dict(pid=900123,start_time_ticks=1)), \
                 mock.patch.object(controller,'watchdog_closed',return_value=True),mock.patch.object(controller,'source_guard'), \
                 mock.patch.object(controller,'accept',return_value=dict(input_pages=10)), \
                 mock.patch.object(controller,'cleanup_superseded_generated',side_effect=cleanup):
                row,_=controller.execute(cfg,'arwiktionary',4,folder,1,'context',[],reconcile_derived_sources=controller._reconcile_derived_sources)
            self.assertEqual((folder/'result.json').read_bytes(),original[0]);self.assertEqual(row['outcome'],'passed')
            self.assertEqual(row['production_elapsed_seconds'],3.25);self.assertIsNone(row['error'])
            self.assertEqual(controller.read_json(folder/'superseded-generated-cleanup.json')['status'],'cleanup-deferred')

    def test_actual_binder_commit_and_backend_share_checkpoint_tuple_units_and_lock(self):
        with tempfile.TemporaryDirectory() as tmp,self.fixture(Path(tmp)) as f:
            lock=f['locks'][0];info=os.fstat(lock.fd)
            replacement=f['doc'](f['root']/'next-selection.json',dict(epoch=2,committed_source_selection=f['core']))
            update=dict(protocol='controller-lock-v1',before=controller.descriptor(f['checkpoint']),replacement=replacement,
                after=dict(replacement,path=str(f['checkpoint'])))
            joined=controller.commit_source_selection_checkpoint(update,lock.fd,
                lock=dict(path=str(lock.path),device=info.st_dev,inode=info.st_ino),
                authenticate=lambda reference,metadata=False:controller.read_ref(reference))
            self.assertEqual(joined['selection_checkpoint'],update['after'])
            f['roles']['derived_source_pins']['selection_checkpoint']=joined['selection_checkpoint']
            f['record']['runtime_roles']=f['doc'](f['root']/'roles.json',f['roles'])
            self.assertEqual(self.retire(f)['status'],'superseded-generated-retired')

    def test_open_use_locks_timeout_symlink_and_mount_refuse_without_derived_unlink(self):
        import build_artifact_root,native_qualification
        for mode in ('locked','open','timeout','symlink','mount'):
            with self.subTest(mode=mode),tempfile.TemporaryDirectory() as tmp,self.fixture(Path(tmp)) as f:
                if mode=='locked':native_qualification._retention_locks_clear.return_value=False
                elif mode=='open':controller.subprocess.run.return_value=SimpleNamespace(returncode=0,stdout='owned open use',stderr='')
                elif mode=='timeout':controller.subprocess.run.side_effect=controller.subprocess.TimeoutExpired('fuser',1)
                elif mode=='symlink':
                    path=f['aliases'][0]/f['names'][0];path.unlink();path.symlink_to(f['keeper']/f['names'][0])
                points=build_artifact_root.execution_mounts()
                if mode=='mount':points.append((f['aliases'][0]/'modules',(1,2),'/foreign'))
                with mock.patch.object(build_artifact_root,'execution_mounts',return_value=points):out=self.retire(f)
                self.assertEqual(out['status'],'cleanup-deferred');self.assert_kept(f)
                self.assertEqual(out['generations'][0]['derived_assets']['removed_names'],0)

    def test_unlisted_provenance_pin_is_preserved_without_blanket_freezing_derived_siblings(self):
        with tempfile.TemporaryDirectory() as tmp,self.fixture(Path(tmp)) as f:
            path=f['aliases'][0]/'lua-usage.tsv';before=path.read_bytes()
            f['core']['paths'].append(dict(path=str(path),identity=list(controller._derived_identity(path))))
            checkpoint=f['doc'](f['checkpoint'],dict(committed_source_selection=f['core']))
            f['roles']['derived_source_pins']=dict(f['core'],selection_checkpoint=checkpoint)
            f['record']['runtime_roles']=f['doc'](f['root']/'roles.json',f['roles'])
            result=self.retire(f)
            self.assertEqual(result['status'],'superseded-generated-retired')
            self.assertEqual(path.read_bytes(),before)
            self.assertEqual(result['generations'][0]['derived_assets']['freed_inodes'],3)

    def test_parent_replacement_after_initial_authentication_defers_before_first_unlink(self):
        with tempfile.TemporaryDirectory() as tmp,self.fixture(Path(tmp)) as f:
            original=f['aliases'][0]/'modules';moved=original.with_name('preserved-modules')
            before={p.relative_to(original):p.read_bytes() for p in original.rglob('*') if p.is_file()}
            def probe(*args,**kwargs):
                original.rename(moved);original.mkdir()
                return SimpleNamespace(returncode=1,stdout='',stderr='')
            controller.subprocess.run.side_effect=probe
            result=self.retire(f)
            self.assertEqual(result['status'],'cleanup-deferred')
            self.assertEqual(result['generations'][0]['derived_assets']['removed_names'],0)
            self.assertEqual(before,{p.relative_to(moved):p.read_bytes() for p in moved.rglob('*') if p.is_file()})
            self.assertTrue(all((f['aliases'][1]/name).is_file() for name in f['names']))

    def test_retained_source_uses_actual_workspace_data_not_source_copy_data(self):
        with tempfile.TemporaryDirectory() as tmp,self.fixture(Path(tmp)) as f:
            retained=f['root']/'.tmp/retained-source';retained.mkdir(parents=True)
            with mock.patch.object(controller,'ROOT',retained), \
                 mock.patch.object(controller,'source_roots',return_value=(retained,f['root'])):
                result=self.retire(f)
            self.assertEqual(result['status'],'superseded-generated-retired')
            self.assertEqual(result['generations'][0]['derived_assets']['freed_inodes'],3)


    def test_released_old_staged_parent_allows_only_manifest_proven_duplicate_children(self):
        import build_wiktionaries
        for mode in ('released','current','queued','unknown-schema','changed-raw'):
            with self.subTest(mode=mode),tempfile.TemporaryDirectory() as tmp,self.fixture(Path(tmp)) as f:
                stage=f['aliases'][0].parents[1]
                self.assertEqual(stage.name,'input')
                dump=stage/'pages.xml.zst';dump.write_bytes(b'original staged dump retained')
                index=stage/'pages-index.txt.bz2';index.write_bytes(b'original staged index retained')
                marker=f['doc'](stage/'.complete.json',dict(version=build_wiktionaries.DUMP_STAGING_VERSION if mode!='unknown-schema' else 'unknown',
                    dump_codec='zstd',dump_stream_kind='multistream-zstd',dump_size=dump.stat().st_size,index_size=index.stat().st_size))
                info=stage.stat();record=dict(path=str(stage),device=info.st_dev,inode=info.st_ino,uid=info.st_uid,
                    mode=info.st_mode&0o7777,completion=marker)
                f['old']['edition_options']={f['edition']:dict(staged_input_root=record)}
                old_ref=f['doc'](f['root']/'old-config.json',f['old']);f['record']['configuration']=old_ref
                f['closed']['configuration']=old_ref;f['record']['closure']=f['doc'](f['root']/'old-closure.json',f['closed'])
                f['roles']['records'][0]['configuration']=old_ref
                if mode=='current':f['cfg']['edition_options']={f['edition']:dict(staged_input_root=record)}
                if mode=='queued':
                    f['core']['paths'].append(dict(path=str(stage),identity=list(controller._derived_identity(stage))))
                    checkpoint=f['doc'](f['checkpoint'],dict(committed_source_selection=f['core']))
                    f['roles']['derived_source_pins']=dict(f['core'],selection_checkpoint=checkpoint)
                f['record']['runtime_roles']=f['doc'](f['root']/'roles.json',f['roles'])
                before={p:p.read_bytes() for p in [dump,index,stage/'.complete.json']}
                if mode=='changed-raw':
                    def probe(*args,**kwargs):
                        dump.write_bytes(b'changed source')
                        return SimpleNamespace(returncode=1,stdout='',stderr='')
                    controller.subprocess.run.side_effect=probe
                outcome=self.retire(f)
                if mode=='released':
                    self.assertEqual(outcome['status'],'superseded-generated-retired')
                    self.assertEqual(outcome['generations'][0]['derived_assets']['freed_inodes'],3)
                    self.assertTrue(all(not (root/name).exists() for root in f['aliases'] for name in f['names']))
                else:
                    self.assertEqual(outcome['status'],'cleanup-deferred');self.assert_kept(f)
                    self.assertEqual(outcome['generations'][0]['derived_assets']['removed_names'],0)
                self.assertEqual({p:data for p,data in before.items() if not(mode=='changed-raw' and p==dump)},
                                 {p:p.read_bytes() for p in before if not(mode=='changed-raw' and p==dump)})




class ProviderCopyLifecycleTests(unittest.TestCase):
    @contextmanager
    def fixture(self, root, kind='file-metadata'):
        import hashlib,shutil,native_qualification
        with SupersededGeneratedLifecycleTests().fixture(root) as f:
            workspace=Path(f['old']['output'])/f['edition']/(f['cfg']['date']+'.shards')
            canonical=root/'data/canonical'/kind;canonical.mkdir(parents=True)
            def payload(name,data):
                path=canonical/name;path.write_bytes(data);return hashlib.sha256(data).hexdigest()
            def metadata(name,value):return f['doc'](canonical/name,value)
            if kind=='file-metadata':
                snapshot=b'File\twidth\n';sha=payload('file-metadata.tsv',snapshot)
                names=['file-metadata.capture-0000.tar','file-metadata.capture-0001.tar']
                artifacts={name:dict(size=len(name.encode()),sha256=payload(name,name.encode()))for name in names}
                artifacts['file-metadata.tsv']=dict(size=len(snapshot),sha256=sha)
                evidence=metadata('file-metadata.evidence.json',dict(artifacts=artifacts,captures=[dict(path=name)for name in names]))
                primary=metadata('file-metadata.manifest.json',dict(schema='wikidict.file-metadata-union.v1',wiki=f['edition'],
                    date=f['cfg']['date'],output_bytes=len(snapshot),output_sha256=sha,
                    evidence=dict(path='file-metadata.evidence.json',size=evidence['bytes'],sha256=evidence['sha256'])))
                metadata('file-metadata.complete.json',dict(schema='wikidict.file-metadata-union.v1',manifest_sha256=primary['sha256']))
                roles={'file-metadata':controller.descriptor(canonical/'file-metadata.tsv')};group='file-metadata-captures'
            else:
                names=['wikibase-request-000001.raw.json','wikibase-request-000002.raw.json'];artifacts={}
                requests=[]
                for index,name in enumerate(names):
                    artifacts[name]=payload(name,json.dumps({'response':index}).encode());req=name.replace('.raw.json','.request.json')
                    request=metadata(req,dict(ids=[str(index)]));artifacts[req]=request['sha256'];requests.append(dict(response=name,request=req))
                complete=metadata('wikibase-namespace-capture.complete.json',{'retained':'namespace source'})
                artifacts[Path(complete['path']).name]=complete['sha256']
                roles={};primary=None
                for role in ('wikibase-entities','wikibase-entity-terms'):
                    data=(role+' retained snapshot').encode();artifacts[role+'.tsv']=payload(role+'.tsv',data)
                    roles[role]=controller.descriptor(canonical/(role+'.tsv'))
                for role in roles:
                    item=metadata(role+'.manifest.json',dict(schema='wikidict-wikibase-capture-v1',version=1,name=role,
                        wiki=f['edition'],date=f['cfg']['date'],output_bytes=roles[role]['bytes'],output_sha256=roles[role]['sha256'],
                        requests=requests,artifacts=artifacts))
                    if role=='wikibase-entities':primary=item
                group='wikibase-responses'
            for path in canonical.iterdir():shutil.copyfile(path,workspace/path.name)
            f['old']['edition_options']={f['edition']:dict(auxiliary_snapshots=roles)}
            old_ref=f['doc'](root/'old-config.json',f['old']);f['record']['configuration']=old_ref
            f['closed']['configuration']=old_ref;f['record']['closure']=f['doc'](root/'old-closure.json',f['closed'])
            f['roles']['records'][0]['configuration']=old_ref
            info=workspace.stat();record=dict(manifest=controller.descriptor(workspace/Path(primary['path']).name),keeper=primary,
                aliases=[dict(path=str(workspace),device=info.st_dev,inode=info.st_ino,uid=info.st_uid,mode=info.st_mode&0o7777)],
                asset_groups=[group],payload_names=names)
            f['record']['provider_copies']=[record];f['roles']['records'][0]['released_provider_copies']=[record]
            authority=f['doc'](root/'provider-authority.json',dict(original_provider_roles=roles))
            current=root/'data/current-source';current.write_bytes(b'current source')
            lock=f['locks'][0];info=os.fstat(lock.fd)
            core=dict(selection_protocol='controller-lock-v1',lock=dict(path=str(lock.path),dev=info.st_dev,ino=info.st_ino),
                authorities=[authority],paths=[dict(path=str(current),identity=list(controller._derived_identity(current)))],unresolved=[])
            checkpoint=f['doc'](root/'selection.json',dict(committed_source_selection=core))
            f['roles']['derived_source_pins']=dict(core,selection_checkpoint=checkpoint)
            f['record']['runtime_roles']=f['doc'](root/'roles.json',f['roles']);f['cfg']['build_timeout_seconds']=30
            receipt=f['paths'][0]/'extraction-source.json';receipt.write_bytes(b'exact original SourceReceipt')
            failure=workspace/'failure.json';failure.write_bytes(b'exact original failure')
            f.update(workspace=workspace,canonical=canonical,payloads=names,provider=record,core=core,receipt=receipt,failure=failure)
            with mock.patch.object(native_qualification,'_retention_locks_clear',return_value=True), \
                 mock.patch.object(controller.subprocess,'run',return_value=SimpleNamespace(returncode=1,stdout='',stderr='')):
                yield f

    def retire(self, f):
        return controller.cleanup_superseded_generated(f['cfg'],f['edition'],f['folder'],f['row'],f['locks'],
            reconcile_derived_sources=controller._reconcile_derived_sources)

    def test_closed_equal_provider_copies_retire_without_treewalk_or_receipt_changes(self):
        for kind in ('file-metadata','wikibase'):
            with self.subTest(kind=kind),tempfile.TemporaryDirectory() as tmp,self.fixture(Path(tmp),kind) as f:
                metadata={p:p.read_bytes()for p in f['workspace'].iterdir()if p.is_file()and p.name not in f['payloads']}
                metadata.update({f['receipt']:f['receipt'].read_bytes(),f['failure']:f['failure'].read_bytes()})
                keeper={p:controller._derived_identity(p)for p in f['canonical'].iterdir()}
                allocated=sum((f['workspace']/name).stat().st_blocks*512 for name in f['payloads'])
                before=copy.deepcopy(f['row'])
                with mock.patch.object(controller.os,'walk',side_effect=AssertionError('no provider treewalk')):result=self.retire(f)
                retired=result['generations'][0]['provider_copies']
                self.assertEqual(result['status'],'superseded-generated-retired');self.assertEqual(retired['status'],'provider-copies-retired')
                self.assertEqual((retired['removed_names'],retired['freed_inodes']),(2,2))
                self.assertEqual(retired['freed_allocated_inode_bytes'],allocated);self.assertIsNone(retired['exclusive_gain_bytes'])
                self.assertEqual(metadata,{p:p.read_bytes()for p in metadata});self.assertEqual(f['row'],before)
                self.assertEqual(keeper,{p:controller._derived_identity(p)for p in keeper})
                self.assertTrue(all(path.exists()for path in f['paths']))
                marker=controller.read_json(f['workspace']/controller.RETIRED_PROVIDER_MARKERS[0])
                self.assertEqual(marker['schema'],'wikidict.retired-provider-payloads.v1')
                self.assertTrue(all(not(f['workspace']/name).exists()for name in f['payloads']))

    def test_current_queued_raw_and_native_failure_replay_pins_have_exact_scope(self):
        for mode in ('current-root','queued-raw','native-replay','unknown'):
            with self.subTest(mode=mode),tempfile.TemporaryDirectory() as tmp,self.fixture(Path(tmp)) as f:
                if mode!='unknown':
                    paths=[f['workspace']]if mode=='current-root'else([f['workspace']/f['payloads'][0]]if mode=='queued-raw'else
                        [f['receipt'],f['failure'],f['workspace']/'file-metadata.tsv'])
                    f['core']['paths'] += [dict(path=str(p),identity=list(controller._derived_identity(p)))for p in paths]
                else:f['core']['unresolved']=['unknown queued reader']
                checkpoint=f['doc'](f['root']/'selection.json',dict(committed_source_selection=f['core']))
                f['roles']['derived_source_pins']=dict(f['core'],selection_checkpoint=checkpoint)
                f['record']['runtime_roles']=f['doc'](f['root']/'roles.json',f['roles'])
                result=self.retire(f)
                self.assertEqual(result['status'],'superseded-generated-retired'if mode=='native-replay'else'cleanup-deferred')
                self.assertTrue(f['receipt'].is_file()and f['failure'].is_file())
                if mode!='native-replay':
                    self.assertTrue(all((f['workspace']/name).is_file()for name in f['payloads']))
                    self.assertFalse((f['workspace']/controller.RETIRED_PROVIDER_MARKERS[0]).exists())

    def test_unique_changed_keeper_shared_copy_and_unlisted_payload_are_refused(self):
        for mode in ('unique','keeper-drift','hardlink','unlisted','metadata','metadata-during-reconcile'):
            with self.subTest(mode=mode),tempfile.TemporaryDirectory() as tmp,self.fixture(Path(tmp)) as f:
                if mode=='unique':(f['workspace']/f['payloads'][0]).write_bytes(b'unique changed capture')
                elif mode=='hardlink':os.link(f['workspace']/f['payloads'][0],f['root']/'other-held-copy')
                elif mode=='unlisted':f['provider']['payload_names'].append('failure.json');f['provider']['payload_names'].sort()
                elif mode=='metadata':(f['workspace']/'file-metadata.evidence.json').write_text('changed evidence')
                elif mode=='metadata-during-reconcile':
                    real=controller._reconcile_derived_sources
                    def reconcile(*args,**kwargs):
                        value=real(*args,**kwargs)
                        (f['workspace']/'file-metadata.evidence.json').write_text('changed during reconciliation')
                        return value
                    original_retire=self.retire
                    self.retire=lambda item: controller.cleanup_superseded_generated(item['cfg'],item['edition'],item['folder'],item['row'],item['locks'],reconcile_derived_sources=reconcile)
                    self.addCleanup(setattr,self,'retire',original_retire)
                else:
                    def probe(*args,**kwargs):
                        (f['canonical']/f['payloads'][0]).write_bytes(b'changed canonical keeper')
                        return SimpleNamespace(returncode=1,stdout='',stderr='')
                    controller.subprocess.run.side_effect=probe
                f['record']['runtime_roles']=f['doc'](f['root']/'roles.json',f['roles'])
                result=self.retire(f)
                if mode=='metadata-during-reconcile':self.retire=original_retire
                self.assertEqual(result['status'],'cleanup-deferred')
                self.assertTrue(all((f['workspace']/name).exists()for name in f['payloads']if name!='failure.json'))
                self.assertFalse((f['workspace']/controller.RETIRED_PROVIDER_MARKERS[0]).exists())

    def test_already_absent_copies_have_zero_credit_and_no_keeper_payload_reread(self):
        for all_absent in (False,True):
            with self.subTest(all_absent=all_absent),tempfile.TemporaryDirectory() as tmp,self.fixture(Path(tmp)) as f:
                absent=f['payloads']if all_absent else f['payloads'][:1]
                for name in absent:(f['workspace']/name).unlink()
                real=controller.digest;reads=[]
                def digest(path):reads.append(Path(path));return real(path)
                with mock.patch.object(controller,'digest',side_effect=digest):result=self.retire(f)
                retired=result['generations'][0]['provider_copies']
                self.assertEqual(retired['removed_names'],2-len(absent));self.assertEqual(retired['freed_inodes'],2-len(absent))
                self.assertEqual(retired['already_absent_names'],len(absent))
                self.assertTrue(all(f['canonical']/name not in reads for name in absent))
                if all_absent:self.assertFalse((f['workspace']/controller.RETIRED_PROVIDER_MARKERS[0]).exists())

    def test_retired_workspace_cannot_repin_but_compiled_publication_verification_remains(self):
        with tempfile.TemporaryDirectory() as tmp,self.fixture(Path(tmp)) as f:
            self.assertEqual(self.retire(f)['status'],'superseded-generated-retired')
            with self.assertRaisesRegex(ValueError,'Retired provider-copy workspace'):
                controller.edition_cli_options(f['old'],f['edition'])
            target=Path(f['old']['output'])/f['edition']/f['cfg']['date'];(target/'complete.json').write_text('{}')
            # Only argument construction; the ordinary builder still performs
            # every original publication/input check and cannot rebuild in place.
            self.assertIn('--file-metadata-snapshot',controller.edition_cli_options(f['old'],f['edition']))

    def test_existing_pin_copies_complete_capture_without_mutating_canonical_link_identity(self):
        import build_wiktionaries as builder,prepare_wikibase_entities as entities
        from test_build_wiktionaries import write_wikibase_capture_fixture
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);snapshots=write_wikibase_capture_fixture(root/'canonical');first=next(iter(snapshots.values()))
            with mock.patch.object(entities,'fetch_response',side_effect=AssertionError('no network')):
                hashes=builder.verified_auxiliary_hashes(snapshots,'arwiktionary','20261001')
                manifests,artifacts=builder.auxiliary_capture_identities(snapshots)
                inventory=entities.capture_artifacts(first)
                before={first.with_name(name):controller._derived_identity(first.with_name(name))for name in inventory}
                destination=root/'private-pinned'
                pinned=builder.pinned_auxiliary_snapshots(snapshots,hashes,destination,manifests,artifacts)
                self.assertEqual(set(p.name for p in destination.iterdir()),set(inventory))
                self.assertEqual(builder.verified_auxiliary_hashes(pinned,'arwiktionary','20261001'),hashes)
                self.assertEqual(before,{p:controller._derived_identity(p)for p in before})
                self.assertTrue(all((destination/name).stat().st_ino != first.with_name(name).stat().st_ino
                    and (destination/name).stat().st_nlink == 1 for name in inventory))

    def test_base_union_exact_retirement_and_malformed_base_refusal(self):
        for mode in ('valid','boolean-base','wrong-base','wrong-name','oversized-child'):
            with self.subTest(mode=mode),tempfile.TemporaryDirectory() as tmp,self.fixture(Path(tmp)) as f:
                evidence=controller.read_json(f['canonical']/'file-metadata.evidence.json')
                evidence['base_capture']=False if mode=='boolean-base' else (1 if mode=='wrong-base' else 0)
                evidence['captures']=[dict(path=name,manifest_sha256='a'*64,rows=24731 if i==0 else 1) for i,name in enumerate(f['payloads'])]
                if mode=='wrong-name':evidence['captures'][0]['path']='file-metadata.capture-0.tar'
                if mode=='oversized-child':evidence['captures'][1]['rows']=10001
                for root in (f['workspace'],f['canonical']):
                    er=f['doc'](root/'file-metadata.evidence.json',evidence)
                    primary=controller.read_json(root/'file-metadata.manifest.json')
                    primary.update(schema='wikidict.file-metadata-union.v2',header_version=2,evidence=dict(path='file-metadata.evidence.json',size=er['bytes'],sha256=er['sha256']))
                    pr=f['doc'](root/'file-metadata.manifest.json',primary)
                    f['doc'](root/'file-metadata.complete.json',dict(schema=primary['schema'],manifest_sha256=pr['sha256']))
                f['provider']['manifest']=controller.descriptor(f['workspace']/'file-metadata.manifest.json')
                f['provider']['keeper']=controller.descriptor(f['canonical']/'file-metadata.manifest.json')
                f['record']['runtime_roles']=f['doc'](f['root']/'roles.json',f['roles'])
                result=self.retire(f)
                self.assertEqual(result['status'],'superseded-generated-retired' if mode=='valid' else 'cleanup-deferred')
                self.assertTrue((f['workspace']/'file-metadata.manifest.json').exists())
                self.assertEqual(all((f['workspace']/n).exists() for n in f['payloads']),mode!='valid')


class RegistryRowNormalizationTests(unittest.TestCase):
    def row(self,wiki='viwiktionary',language='vi'):
        return dict(content_language=language,date='20261001',name='language-registry.tsv',sha256='df8550b607be9a7a6b3ef964defa941fc0f56040a323f534f2b8a7053258ea9f',size=166976,wiki=wiki)
    def select(self,value):
        return controller.normalize_registry_rows(value,edition='viwiktionary',date='20261001')
    def test_singleton_and_list_preserve_original_metadata(self):
        row=self.row(); original=copy.deepcopy(row)
        self.assertEqual(self.select(row),[row]);self.assertEqual(row,original)
        rows=[self.row('srwiktionary','sr'),row];before=copy.deepcopy(rows)
        result=self.select(rows);self.assertEqual(result,[row]);self.assertEqual(rows,before)
        result[0]['size']=1;self.assertEqual(row,original)
    def test_malformed_fields_types_and_context_refuse(self):
        mutations=[dict(size=True),dict(size=0),dict(sha256='bad'),dict(name='../language-registry.tsv'),dict(date='20260901'),dict(content_language=''),dict(wiki='otherwiktionary')]
        for delta in mutations:
            with self.subTest(delta=delta),self.assertRaises(ValueError):self.select(dict(self.row(),**delta))
        for value in (None,(),[],['row'],dict(self.row(),extra=1)):
            with self.subTest(value=value),self.assertRaises(ValueError):self.select(value)
    def test_duplicates_and_unselected_malformed_rows_refuse(self):
        for rows in ([self.row(),self.row()],[self.row(),dict(self.row('srwiktionary','sr'),size=True)]):
            with self.subTest(rows=rows),self.assertRaises(ValueError):self.select(rows)


class ContentReviewHeadOnlyTests(unittest.TestCase):
    def test_identical_bytes_different_heads_preserve_original_provenance(self):
        with tempfile.TemporaryDirectory() as tmp:
            source,rows,review=content_review_fixture(Path(tmp),controller.PILOT)
            original=copy.deepcopy(rows); current=dict(source,head='new-unrelated-head')
            review['source_head']=current['head']
            self.assertIs(controller.validate_content_review(review,current,rows,controller.PILOT,scope='pilot'),review)
            self.assertEqual(rows,original)
    def test_final198_same_fingerprint_can_keep_distinct_original_heads(self):
        with tempfile.TemporaryDirectory() as tmp:
            source,rows,review=content_review_fixture(Path(tmp),all_editions())
            for i,row in enumerate(rows):row['accepted']['source']=dict(source,head='original-'+str(i))
            current=dict(source,head='review-head');review['source_head']=current['head']
            controller.validate_content_review(review,current,rows,all_editions(),scope='final')
    def test_changed_fingerprint_inputs_completion_and_review_head_refuse(self):
        for mode in ('fingerprint','extra-source-field','empty-head','nonstring-head','inputs','complete','review-head','native-output'):
            with self.subTest(mode=mode),tempfile.TemporaryDirectory() as tmp:
                source,rows,review=content_review_fixture(Path(tmp),controller.PILOT)
                current=dict(source,head='new-head');review['source_head']=current['head']
                if mode=='fingerprint':
                    current['fingerprint']='changed-producer';review['source_fingerprint']=current['fingerprint']
                elif mode=='extra-source-field':rows[0]['accepted']['source']=dict(source,unexpected='unbound')
                elif mode=='empty-head':rows[0]['accepted']['source']=dict(source,head='')
                elif mode=='nonstring-head':rows[0]['accepted']['source']=dict(source,head=123)
                elif mode=='inputs':rows[0]['accepted']['build_inputs']={}
                elif mode=='complete':rows[0]['accepted']['complete']=dict(rows[0]['accepted']['complete'],sha256='0'*64)
                elif mode=='review-head':review['source_head']='unbound-review'
                else:review['editions'][0]['content_review']['native_output_checked']=False
                with self.assertRaises(ValueError):controller.validate_content_review(review,current,rows,controller.PILOT,scope='pilot')
