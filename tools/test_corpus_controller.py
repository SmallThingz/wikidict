"""Pure controller controls; no builder, provider, or native process is invoked."""
import copy
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest import mock

import corpus_controller as controller

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


if __name__ == '__main__':
    unittest.main()
