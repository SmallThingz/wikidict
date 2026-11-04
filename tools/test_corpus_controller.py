"""Pure controller controls; no builder, provider, or native process is invoked."""
import copy
import json
import os
from pathlib import Path
import tempfile
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

class ControllerMemoryPolicyTests(unittest.TestCase):
    def cfg(self, root):
        return dict(armed=True, source={'head': 'a'*40, 'fingerprint': 'b'*64},
                    compiler={'path': str(root/'zig'), 'bytes': 1, 'sha256': 'c'*64},
                    manifest={'path': str(root/'downloads/manifest.json'), 'bytes': 1, 'sha256': 'd'*64},
                    downloads=str(root/'downloads'), output=str(root/'output'),
                    raw_shard_root=str(root/'raw'), state_directory=str(root/'state'),
                    date='20261001', now_unix=1, expansion_timeout_ms=10,
                    build_timeout_seconds=123, qualification={}, diagnostic_disposition={})

    def test_real_cap_transition_preserves_workers_before_8g_backoff(self):
        state = (4, 4*1024**3)
        observed = [state]
        for expected in [(4, 8*1024**3), (2, 8*1024**3), (1, 8*1024**3)]:
            state = controller.next_resources(*state, {
                'termination_reason': 'sampled_pss_limit', 'memory_limit_bytes': state[1]})
            self.assertEqual(expected, state)
            observed.append(state)
        self.assertEqual([(4, 4*1024**3), (4, 8*1024**3),
                          (2, 8*1024**3), (1, 8*1024**3)], observed)
        self.assertIsNone(controller.next_resources(*state, {
            'termination_reason': 'sampled_pss_limit', 'memory_limit_bytes': state[1]}))

    def test_noncap_or_unmatched_actual_limit_never_authorizes_8g(self):
        for reason in ['child_exit', 'wall_timeout', 'running', None, 'OutOfMemory']:
            with self.subTest(reason=reason):
                self.assertIsNone(controller.next_resources(4, 4*1024**3, {
                    'termination_reason': reason, 'memory_limit_bytes': 4*1024**3,
                    'error': 'OutOfMemory: ordinary failed entry'}))
        for actual in [None, True, '4294967296', 2*1024**3, 8*1024**3]:
            with self.subTest(actual=actual):
                self.assertIsNone(controller.next_resources(4, 4*1024**3, {
                    'termination_reason': 'sampled_pss_limit', 'memory_limit_bytes': actual}))

    def test_command_requests_actual_4g_default_and_explicit_8g_without_guard_changes(self):
        cfg = self.cfg(Path('/unused-memory-control'))
        for memory, mib in [(None, '4096'), (8*1024**3, '8192')]:
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

    def test_execute_start_receipt_matches_selected_memory_and_actual_argv(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); cfg = self.cfg(root)
            for memory in [4*1024**3, 8*1024**3]:
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

    def test_main_resets_initial_4g_for_next_edition_after_8g_retry(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); cfg = self.cfg(root); seen = []
            def execute(cfg, edition, workers, folder, sequence, context, locks,
                        memory_limit_bytes=controller.MEMORY_INITIAL):
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
            self.assertEqual([('arwiktionary',4,4*1024**3),
                              ('arwiktionary',4,8*1024**3),
                              ('enwiktionary',4,4*1024**3)], seen)


    def test_nominal_success_with_wrong_actual_cap_cannot_accept_publication(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);cfg=self.cfg(root);folder=root/'attempt'
            process=mock.Mock(pid=900123);process.poll.return_value=0;process.wait.return_value=0
            def spawn(*args,**kwargs):
                write_json(Path(kwargs['cwd'])/'.tmp/build-watchdog-report.json', {
                    'termination_reason':'child_exit','memory_limit_bytes':8*1024**3})
                return process
            with mock.patch.object(controller,'ROOT',root), \
                 mock.patch.object(controller.subprocess,'Popen',side_effect=spawn), \
                 mock.patch.object(controller,'process_identity',return_value={'pid':900123,'start_time_ticks':1}), \
                 mock.patch.object(controller,'watchdog_closed',return_value=True), \
                 mock.patch.object(controller,'source_guard'), \
                 mock.patch.object(controller,'phase_end',return_value={'status':'success'}), \
                 mock.patch.object(controller,'accept') as accept:
                row,_=controller.execute(cfg,'arwiktionary',4,folder,1,'context',[],4*1024**3)
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


class Source78PilotTimeHistoryTests(unittest.TestCase):
    """Closed source78 pilot costs survive; every target publication is rebuilt."""
    def fixture(self, root, an_aliases=None):
        source = dict(controller.SOURCE78_PILOT)
        target = dict(head='9' * 40, fingerprint='a' * 64)
        manifest_path = root / 'dumps/manifest.json'
        registry = root / 'an.original.tsv'
        aliases = [['it', 'Italián']] if an_aliases is None else copy.deepcopy(an_aliases)
        codes = sorted({code for code, _ in aliases})
        registry.write_text('# wikidict-language-registry-v2\n# content-language\tan\n' +
            ('it\tItalian\n' if an_aliases is None else ''.join(code + '\tExisting ' + code + '\n' for code in codes)))
        derived = root / 'an.derived.tsv'
        derived.write_bytes(registry.read_bytes() + ''.join('# local-alias\t' + code + '\t' + label + '\n'
            for code, label in aliases).encode())
        change = dict(edition='anwiktionary', original_registry=controller.descriptor(registry),
                      derived_registry=controller.descriptor(derived), aliases=aliases)
        before = dict(requested_editions=all_editions(),
            files=[dict(wiki='arwiktionary', date='20261001', name='synthetic.xml.bz2', size=1, sha1='0' * 40)],
            auxiliary_capture_roots={e: str(root / 'capture' / e) for e in all_editions()},
            language_registries=[dict(wiki='anwiktionary', date='20261001',
                name='language-registry.tsv', content_language='an',
                size=registry.stat().st_size, sha256=change['original_registry']['sha256'])])
        write_json(manifest_path, before)
        original_manifest = controller.descriptor(manifest_path)
        write_json(root / 'manifest.original.json', before)
        old = dict(armed=True, source=source, compiler=dict(path='/fixture/zig', bytes=1, sha256='b' * 64),
            manifest=original_manifest, downloads=str(root / 'dumps'), output=str(root / 'output'),
            raw_shard_root=str(root / 'raw'), date='20261001', now_unix=1791731560,
            expansion_timeout_ms=60000, state_directory=str(root / 'state'),
            build_timeout_seconds=604800, production_manifest_transition=None, diagnostic_disposition=None)
        write_json(root / 'oldcfg.json', old)
        after = copy.deepcopy(before)
        after['language_registries'][0].update(size=derived.stat().st_size, sha256=change['derived_registry']['sha256'])
        write_json(manifest_path, after)
        snapshot = dict(target, files={})
        write_json(root / 'source-snapshot79.json', snapshot)
        snapshot_ref = controller.descriptor(root / 'source-snapshot79.json')
        q = dict(schema='wikidict.durable-fresh-qualification-result.v1', passed=True, source_guard=True,
            error=None, source_head=target['head'], source_fingerprint=target['fingerprint'],
            source_snapshot=snapshot_ref, phases=dict(native=dict(exit_code=0), python=dict(exit_code=0)))
        write_json(root / 'qualified.json', q)
        qref = controller.descriptor(root / 'qualified.json')
        closed = dict(schema='wikidict.durable-fresh-qualification-independent-closure.v1',
            outcome='passed-closed', result=qref, qualification_passed=True, cleanup_proven=True,
            source_guard=True, source_head=target['head'], source_fingerprint=target['fingerprint'],
            source_snapshot=snapshot_ref)
        write_json(root / 'qualified-close.json', closed)
        entries, originals = [], {}
        for sequence, (edition, passed, cap) in enumerate([
                ('arwiktionary', True, False), ('arwiktionary', False, True),
                ('aawiktionary', True, False), ('anwiktionary', False, False)], 1):
            folder = root / 'state/attempts' / ('%06d-%s' % (sequence, edition))
            start = dict(attempt_id=folder.name, sequence=sequence, edition=edition, date='20261001',
                         context=controller.production_context(old), controller=dict(pid=900001, start_time_ticks=1))
            wd = dict(termination_reason='sampled_pss_limit' if cap else 'child_exit',
                child_exit_status=-15 if cap else (0 if passed else 1), guardian_exit_status=0,
                memory_limit_bytes=controller.MEMORY_INITIAL, error=None)
            write_json(folder / 'start.json', start)
            write_json(folder / 'watchdog.json', wd)
            accepted = None
            if passed:
                inputs = dict(source=source['fingerprint'])
                complete = dict(edition=edition, date='20261001', now_unix=old['now_unix'],
                                build_inputs=inputs, input_pages=111)
                write_json(folder / 'complete.json', complete)
                complete_ref = controller.descriptor(folder / 'complete.json')
                accepted = dict(source=source, complete=complete_ref, complete_snapshot=complete_ref,
                                build_inputs=inputs, input_pages=111)
            row = dict(attempt_id=folder.name, sequence=sequence, edition=edition,
                outcome='passed' if passed else 'failed', accepted=accepted,
                elapsed_seconds=float(sequence * 10), execution_mode=FRESH,
                memory_limit_bytes=controller.MEMORY_INITIAL, watchdog=controller.descriptor(folder / 'watchdog.json'),
                cleanup_proven=True, controller_interrupted=False, exit_code=0 if passed else 1)
            write_json(folder / 'result.json', row)
            result_ref = controller.descriptor(folder / 'result.json')
            entries.append(dict(result=result_ref, start=controller.descriptor(folder / 'start.json'),
                watchdog=row['watchdog'], original_result=row, original_watchdog=wd))
            for name in ('start.json', 'result.json', 'complete.json'):
                if (folder / name).exists(): originals[str(folder / name)] = (folder / name).read_bytes()
        launch = dict(configuration=controller.descriptor(root / 'oldcfg.json'))
        write_json(root / 'launch.json', launch)
        terminal = dict(schema='wikidict.production-controller-terminal.v1', controller_joined=True,
            controller_exit_status=1, source=source, launch=controller.descriptor(root / 'launch.json'),
            cleanup=dict(cleanup_proven=True, attempts=[dict(result=e['result']) for e in entries]))
        write_json(root / 'terminal.json', terminal)
        pilot = dict(schema='wikidict.production-controller-independent-owned-cleanup.v1',
            configuration=controller.descriptor(root / 'oldcfg.json'), source=source,
            source_guard=True, cleanup_proven=True, all_recorded_identities_absent=True,
            all_owned_groups_and_sessions_empty=True, remaining_owned_processes=[],
            semantic_acceptance=False, all198_complete=False, terminal=controller.descriptor(root / 'terminal.json'),
            launch=terminal['launch'], original_terminal=terminal, attempts=entries)
        write_json(root / 'pilot-close.json', pilot)
        transition = dict(scope='source78-pilot-retry-time-only', reason='Measured old work only',
            runtime_reuse_credit=False, from_configuration=controller.descriptor(root / 'oldcfg.json'),
            from_manifest_snapshot=controller.descriptor(root / 'manifest.original.json'),
            to_manifest=controller.descriptor(manifest_path), to_source_snapshot=snapshot_ref,
            qualification_result=qref, qualification_closure=controller.descriptor(root / 'qualified-close.json'),
            pilot_closure=controller.descriptor(root / 'pilot-close.json'), an_registry_append=change)
        cfg = dict(old, source=target, manifest=transition['to_manifest'],
                   qualification=transition['qualification_closure'], production_manifest_transition=transition)
        return cfg, originals

    def rows(self, cfg):
        with mock.patch.object(controller, 'process_identity', side_effect=AssertionError('Closed history never queries live processes')):
            return controller.history(Path(cfg['state_directory']), controller.production_context(cfg), cfg)

    def interrupted_fixture(self, root, an_aliases=None, interrupted_seconds=None):
        cfg, _ = self.fixture(root, an_aliases)
        tr = cfg['production_manifest_transition']; pilot = controller.read_ref(tr['pilot_closure'])
        entry = pilot['attempts'][1]; folder = Path(entry['result']['path']).parent
        row = controller.read_ref(entry['result']); wd = controller.read_ref(entry['watchdog'])
        row.update(cleanup_proven=False, error=None)
        if interrupted_seconds is not None: row['elapsed_seconds'] = interrupted_seconds
        wd.update(termination_reason='interrupted', error='Build supervisor interrupted by signal 15',
                  child_pid=900003, child_start_time_ticks=3, guardian_pid=900004)
        write_json(folder/'watchdog.json', wd); row['watchdog']=controller.descriptor(folder/'watchdog.json')
        write_json(folder/'result.json', row)
        launched=dict(identity=dict(pid=900002,start_time_ticks=2),private_session=900002)
        write_json(folder/'launch.json',launched)
        entry.update(result=controller.descriptor(folder/'result.json'),watchdog=row['watchdog'],
                     original_result=row,original_watchdog=wd,launch=controller.descriptor(folder/'launch.json'))
        guardian=dict(status='disarmed',reason='normal_done',supervisor_pid=900002,supervisor_start=2,
                      root_pid=900003,root_start=3,guardian_pid=900004)
        write_json(folder/'guardian.json',guardian);entry['guardian']=controller.descriptor(folder/'guardian.json')
        intent=dict(schema='wikidict.owned-diagnosed-build-interruption-intent.v1',configuration=tr['from_configuration'],
                    signal=15,boot_id='synthetic-boot',attempt_start=entry['start'],attempt_launch=entry['launch'],
                    target=dict(pid=900002,start_time_ticks=2,process_group=900002,session=900002))
        write_json(root/'intent.json',intent);pilot['authorized_interruption_intent']=controller.descriptor(root/'intent.json')
        signal=dict(schema='wikidict.owned-diagnosed-build-interruption-signal.v1',intent=pilot['authorized_interruption_intent'],
                    helper_invocations=1,helper_returned=True,error=None,cleanup_proven=False,
                    controller_and_observer_signalled=False,other_owner_signalled=False)
        write_json(root/'signal.json',signal);pilot['authorized_interruption_signal']=controller.descriptor(root/'signal.json')
        terminal=controller.read_ref(pilot['terminal']);terminal['cleanup']['cleanup_proven']=False
        terminal['cleanup']['attempts']=[dict(result=e['result']) for e in pilot['attempts']]
        write_json(root/'terminal.json',terminal)
        pilot.update(terminal=controller.descriptor(root/'terminal.json'),original_terminal=terminal,
                     outcome='failed-closed',passed_mechanical=False,ordinary_watchdog_closed=False,
                     both_locks_free_same_inode=True,original_observer_cleanup_proven=False,host_boot_id='synthetic-boot')
        write_json(root/'pilot-close.json',pilot);tr['pilot_closure']=controller.descriptor(root/'pilot-close.json')
        return cfg, dict(closure=tr['pilot_closure'],attempt_id=row['attempt_id'])

    def test_exact_independent_interruption_counts_failed_time_without_restamping_or_pages(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);cfg,pin=self.interrupted_fixture(root)
            originals={str(p):p.read_bytes() for p in root.rglob('*.json')}
            # Synthetic pin is explicit: this test cannot authorize the real maintenance closure.
            with mock.patch.object(controller,'SOURCE78_INTERRUPTED_PILOT',pin):
                rows=self.rows(cfg)
                self.assertEqual(len(rows),4)
                self.assertEqual(sum(r['elapsed_seconds'] for r in rows if r['edition']=='arwiktionary'),30)
                self.assertTrue(all(r['accepted'] is None for r in rows))
                failed=next(r for r in rows if r['attempt_id']==pin['attempt_id'])
                self.assertIs(failed['cleanup_proven'],False)
            self.assertEqual(originals,{str(p):p.read_bytes() for p in root.rglob('*.json')})
            with self.assertRaises(ValueError):self.rows(cfg) # Same data without exact trusted pin refuses.

    def test_interruption_exception_refuses_other_error_owner_identity_or_false_independent_cleanup(self):
        for mode in ('error','owner','identity','guardian','independent','other-row'):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as directory:
                root=Path(directory);cfg,pin=self.interrupted_fixture(root)
                tr=cfg['production_manifest_transition'];pilot=controller.read_ref(tr['pilot_closure']);entry=pilot['attempts'][1]
                if mode=='independent':pilot['cleanup_proven']=False
                elif mode=='identity':
                    value=controller.read_ref(pilot['authorized_interruption_intent']);value['target']['start_time_ticks']=99
                    write_json(root/'intent.json',value);pilot['authorized_interruption_intent']=controller.descriptor(root/'intent.json')
                elif mode=='guardian':
                    value=controller.read_ref(entry['guardian']);value['status']='armed'
                    write_json(Path(entry['guardian']['path']),value);entry['guardian']=controller.descriptor(entry['guardian']['path'])
                elif mode=='other-row':
                    other=pilot['attempts'][3];value=controller.read_ref(other['result']);value['cleanup_proven']=False
                    write_json(Path(other['result']['path']),value);other.update(result=controller.descriptor(other['result']['path']),original_result=value)
                else:
                    value=controller.read_ref(entry['result']);wd=controller.read_ref(entry['watchdog'])
                    if mode=='owner':value['edition']='anwiktionary'
                    else:wd['error']='different watchdog failure'
                    write_json(Path(entry['watchdog']['path']),wd);value['watchdog']=controller.descriptor(entry['watchdog']['path'])
                    write_json(Path(entry['result']['path']),value)
                    entry.update(result=controller.descriptor(entry['result']['path']),watchdog=value['watchdog'],original_result=value,original_watchdog=wd)
                terminal=controller.read_ref(pilot['terminal']);terminal['cleanup']['attempts']=[dict(result=e['result']) for e in pilot['attempts']]
                write_json(root/'terminal.json',terminal);pilot.update(terminal=controller.descriptor(root/'terminal.json'),original_terminal=terminal)
                write_json(root/'pilot-close.json',pilot);tr['pilot_closure']=controller.descriptor(root/'pilot-close.json');pin['closure']=tr['pilot_closure']
                with mock.patch.object(controller,'SOURCE78_INTERRUPTED_PILOT',pin), self.assertRaises(ValueError):self.rows(cfg)

    def test_closed_mixed_old_intervals_count_once_without_old_acceptance_or_pages(self):
        with tempfile.TemporaryDirectory() as directory:
            cfg, original = self.fixture(Path(directory))
            rows = self.rows(cfg)
            self.assertEqual(4, len(rows))
            self.assertTrue(all(r['accepted'] is None and r['history_time_only'] for r in rows))
            self.assertEqual(2, sum(r['historical_accepted'] is not None for r in rows))
            summary = controller.summarize(rows + copy.deepcopy(rows), all_editions())
            ar = next(r for r in summary['editions'] if r['edition'] == 'arwiktionary')
            self.assertEqual(30, ar['observed_build_seconds'])
            self.assertIsNone(ar['accepted'])
            self.assertEqual(0, summary['accepted_cohort_input_pages'])
            self.assertEqual(set(controller.PILOT[:7]), {r['edition'] for r in summary['editions'] if r['timing_excluded']})
            current = attempt('new-ar', 5, edition='arwiktionary', seconds=5, pages=222)
            joined = controller.summarize(rows + [current], all_editions())
            self.assertEqual(222, joined['accepted_cohort_input_pages'])
            self.assertEqual(35, next(r for r in joined['editions'] if r['edition'] == 'arwiktionary')['observed_build_seconds'])
            self.assertFalse(joined['final_cohort_complete'])
            self.assertEqual(rows, self.rows(cfg))
            for path, raw in original.items(): self.assertEqual(raw, Path(path).read_bytes())

    def test_real_main_does_not_skip_old_passed_or_failed_without_retry_flag(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory);cfg, _ = self.fixture(root);rows = self.rows(cfg);seen = []
            real_descriptor = controller.descriptor
            def selected_descriptor(path):
                return cfg['compiler'] if Path(path) == Path(cfg['compiler']['path']) else real_descriptor(path)
            write_json(root / 'cfg.json', cfg)
            def execute(current, edition, workers, folder, sequence, context, locks, memory):
                seen.append((edition, sequence))
                row = attempt('current-' + edition, sequence, edition=edition, seconds=2, pages=20)
                row.update(controller_interrupted=False, cleanup_proven=True, source_guard=True, control_proven=True)
                return row, {}
            with mock.patch.object(controller, 'history', return_value=rows), \
                 mock.patch.object(controller, 'source_guard'), \
                 mock.patch.object(controller, 'gate', return_value={}), \
                 mock.patch.object(controller, 'load_preparations', return_value=[]), \
                 mock.patch.object(controller, 'descriptor', side_effect=selected_descriptor), \
                 mock.patch.object(controller, 'validate_pipeline_paths'), \
                 mock.patch.object(controller, 'selected_phase_editions', return_value=['arwiktionary', 'aawiktionary']), \
                 mock.patch.object(controller, 'Lock'), \
                 mock.patch.object(controller, 'execute', side_effect=execute), \
                 mock.patch.object(controller.resource, 'getrlimit', return_value=(-1, -1)), \
                 mock.patch.object(controller.os, 'sched_getaffinity', return_value={1,3,5,7}), \
                 mock.patch('builtins.print'):
                self.assertEqual(0, controller.main(['--config', str(root / 'cfg.json')]))
            self.assertEqual([('arwiktionary', 5), ('aawiktionary', 6)], seen)
            summary = json.loads((root / 'state/summary.json').read_text())
            self.assertEqual(20, summary['accepted_cohort_input_pages'])

    def test_stale_unclean_malformed_source_or_manifest_proofs_refuse(self):
        for mode in ('source', 'target-source', 'unclosed', 'terminal', 'inventory',
                     'other-edition', 'roots', 'registry-rewrite', 'runtime-credit', 'extra-field'):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as directory:
                root=Path(directory);cfg,_=self.fixture(root);tr=cfg['production_manifest_transition']
                if mode=='runtime-credit':tr['runtime_reuse_credit']=True
                elif mode=='extra-field':tr['surprise']=True
                elif mode=='source':
                    old=controller.read_ref(tr['from_configuration']);old['source']['head']='0'*40
                    write_json(root/'oldcfg.json',old);tr['from_configuration']=controller.descriptor(root/'oldcfg.json')
                elif mode=='target-source':cfg['source']=dict(head='0'*40,fingerprint='0'*64)
                elif mode in ('unclosed','terminal','inventory','other-edition'):
                    close=controller.read_ref(tr['pilot_closure'])
                    if mode=='unclosed':close['cleanup_proven']=False
                    if mode=='terminal':close['original_terminal']['controller_joined']=False
                    if mode=='inventory':close['attempts'].pop()
                    if mode=='other-edition':close['attempts'][0]['original_result']['edition']='enwiktionary'
                    write_json(root/'pilot-close.json',close);tr['pilot_closure']=controller.descriptor(root/'pilot-close.json')
                elif mode=='roots':
                    value=controller.read_ref(cfg['manifest']);value['auxiliary_capture_roots']['arwiktionary']+='-changed'
                    write_json(root/'dumps/manifest.json',value);cfg['manifest']=tr['to_manifest']=controller.descriptor(root/'dumps/manifest.json')
                elif mode=='registry-rewrite':
                    p=Path(tr['an_registry_append']['derived_registry']['path']);p.write_bytes(p.read_bytes()+b'bad')
                with self.assertRaises(ValueError):self.rows(cfg)

    def test_old_missing_stale_or_uncatalogued_attempt_cannot_be_recovered(self):
        for mode in ('missing-result','stale-result','missing-folder','extra-old-row'):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as directory:
                root=Path(directory);cfg,_=self.fixture(root)
                folders=sorted((root/'state/attempts').iterdir());first=folders[0]
                if mode=='missing-result':(first/'result.json').unlink()
                if mode=='stale-result':
                    row=json.loads((first/'result.json').read_text());row['elapsed_seconds']+=1
                    write_json(first/'result.json',row)
                if mode=='missing-folder':first.rename(root/'retired-attempt')
                if mode=='extra-old-row':
                    extra=root/'state/attempts/999999-unproven'
                    start=json.loads((first/'start.json').read_text());start.update(attempt_id=extra.name,sequence=999999)
                    write_json(extra/'start.json',start);write_json(extra/'result.json',dict(attempt_id=extra.name,sequence=999999,edition='arwiktionary',accepted=None))
                with self.assertRaises((ValueError,FileNotFoundError)):self.rows(cfg)
                if mode=='missing-result':self.assertFalse((first/'result.json').exists())


    def test_an14_case_distinct_same_owner_keeps_exact_interrupted_time_without_output_credit(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            cfg, pin = self.interrupted_fixture(root, AN14_REVIEWED_ALIASES, 4090.5811582690003)
            originals = {str(p): p.read_bytes() for p in root.rglob('*.json')}
            with mock.patch.object(controller, 'SOURCE78_INTERRUPTED_PILOT', pin):
                rows = self.rows(cfg)
                failed = next(row for row in rows if row['attempt_id'] == pin['attempt_id'])
                self.assertEqual(4090.5811582690003, failed['elapsed_seconds'])
                self.assertIs(failed['cleanup_proven'], False)
                self.assertTrue(all(row['history_time_only'] and row['accepted'] is None for row in rows))
                summary = controller.summarize(rows + copy.deepcopy(rows), all_editions())
                ar = next(row for row in summary['editions'] if row['edition'] == 'arwiktionary')
                self.assertAlmostEqual(4100.581158269, ar['observed_build_seconds'])
                self.assertEqual(0, summary['accepted_cohort_input_pages'])
                self.assertEqual(set(controller.PILOT[:7]), {row['edition'] for row in summary['editions'] if row['timing_excluded']})
            self.assertEqual(originals, {str(p): p.read_bytes() for p in root.rglob('*.json')})

    def test_case_distinct_aliases_still_refuse_exact_duplicates_and_cross_owner_folds(self):
        for extra in (['it', 'Italián'], ['fr', 'ITALIÁN']):
            for route in ('preparations', 'pilot-history'):
                with self.subTest(extra=extra, route=route), tempfile.TemporaryDirectory() as directory:
                    root = Path(directory); aliases = AN14_REVIEWED_ALIASES + [extra]
                    if route == 'pilot-history':
                        cfg, _ = self.fixture(root, aliases)
                        with self.assertRaises(ValueError): self.rows(cfg)
                    else:
                        helper = ControllerPreparationTests()
                        old, current, snapshot, changes = helper.four_registry_appends_context(root, aliases)
                        receipt = helper.preparation(root / 'prep', old, 'bad-case-distinct')
                        current['production_preparations'] = [helper.manifest_receipt(root / 'prep', receipt,
                            old, current, snapshot, dict(unrelated_registry_appends=changes))]
                        with self.assertRaises(ValueError): controller.load_preparations(current)


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

    def run_main(self,root,cleanup=True,unsafe=None,plan=None,history_rows=None):
        manifest=self.manifest();cfg=dict(armed=True,source={'head':'a'*40,'fingerprint':'b'*64},
            compiler={'path':str(root/'zig'),'bytes':1,'sha256':'c'*64},
            manifest={'path':str(root/'downloads/manifest.json'),'bytes':1,'sha256':'d'*64},
            downloads=str(root/'downloads'),output=str(root/'output'),raw_shard_root=str(root/'raw'),state_directory=str(root/'state'),
            date='20261001',now_unix=1,expansion_timeout_ms=10,build_timeout_seconds=123,qualification={},diagnostic_disposition={})
        seen=[];written=[];gates=[]
        def execute(cfg,edition,workers,folder,sequence,context,locks,memory_limit_bytes):
            seen.append(edition)
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
                with self.assertRaisesRegex(ValueError,'unproven|control validation|Non-ordinary'):controller.main(['--config',str(root/'cfg.json'),'--phase','all'])
                return seen
            code=controller.main(['--config',str(root/'cfg.json'),'--phase','all'])
        self.assertEqual(len(gates),2) # qualification+diagnostic, never bypassed; no pilot prerequisite
        self.assertGreaterEqual(source_guard.call_count,199 if plan is None else 1);preparations.assert_called_once()
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
                    child_exit_status=1,guardian_exit_status=0,memory_limit_bytes=controller.MEMORY_INITIAL))
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
            wd = folder / 'watchdog.json'; write_json(wd, dict(termination_reason='child_exit', memory_limit_bytes=controller.MEMORY_INITIAL))
            row = dict(outcome='failed', cleanup_proven=True, source_guard=True, control_proven=True,
                       memory_limit_bytes=controller.MEMORY_INITIAL, watchdog=controller.descriptor(wd))
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
                write_json(wd, dict(termination_reason='child_exit', child_exit_status=status, memory_limit_bytes=controller.MEMORY_INITIAL))
                row = dict(outcome='failed', exit_code=status, cleanup_proven=True, source_guard=True, control_proven=True,
                           memory_limit_bytes=controller.MEMORY_INITIAL, watchdog=controller.descriptor(wd))
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
                        child_exit_status=code, guardian_exit_status=0, memory_limit_bytes=controller.MEMORY_INITIAL))
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
                        child_exit_status=1, guardian_exit_status=0, memory_limit_bytes=controller.MEMORY_INITIAL))
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
                        child_exit_status=1, guardian_exit_status=0, memory_limit_bytes=controller.MEMORY_INITIAL))
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


if __name__ == '__main__':
    unittest.main()
