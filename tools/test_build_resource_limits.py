import contextlib
import io
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch

import build_resource_limits as limits
import build_wiktionaries as builder


class ResourceLimitsTest(unittest.TestCase):
    def test_watchdog_cpu_set_reserves_four_logical_cpus_and_prefers_cores(self):
        topology = {**{cpu: (0, cpu // 2) for cpu in range(8)},
                    **{cpu: (0, cpu + 12) for cpu in range(8, 12)}}
        original = Path.read_text

        def read_topology(path, *args, **kwargs):
            parts = path.parts
            if len(parts) >= 2 and parts[-2] == 'topology':
                cpu = int(parts[-3][3:])
                return str(topology[cpu][0 if parts[-1] == 'physical_package_id' else 1])
            return original(path, *args, **kwargs)

        with patch.object(Path, 'read_text', read_topology):
            self.assertEqual(limits._watchdog_cpu_set(8, set(range(12))),
                             [0, 2, 4, 6, 8, 9, 10, 11])
            self.assertEqual(limits._watchdog_cpu_set(4, set(range(12))), [0, 2, 4, 6])
            self.assertEqual(limits._watchdog_cpu_set(8, set(range(8))), [0, 2, 4, 6])
            self.assertEqual(limits._watchdog_cpu_set(4, set(range(8))), [0, 2, 4, 6])
        with self.assertRaises(limits.ContainmentUnavailable):
            limits._watchdog_cpu_set(9, set(range(12)))

    def test_watchdog_cpu_set_falls_back_on_missing_topology(self):
        with patch.object(Path, 'read_text', side_effect=FileNotFoundError):
            self.assertEqual(limits._watchdog_cpu_set(4, {0, 1, 2, 3}), [0, 1, 2, 3])
            self.assertEqual(limits._watchdog_cpu_set(8, set(range(12))), list(range(8)))

    def test_cli_ignores_host_free_ram_but_requires_containment(self):
        with tempfile.TemporaryDirectory() as tmp:
            with patch.object(builder, 'PROJECT', Path(tmp)), \
                 patch.object(sys, 'argv', ['build_wiktionaries.py']), \
                 patch.object(limits, 'inside_envelope', return_value=False), \
                 patch.object(Path, 'read_text', side_effect=AssertionError('host free RAM was read')) as memory, \
                 patch.object(builder, 'safe_worker_budget', side_effect=AssertionError('budget was read')) as budget, \
                 patch.object(limits, 'supervise',
                              side_effect=limits.ContainmentUnavailable('A delegated cgroup is required')) as launch, \
                 patch.object(builder, 'main') as main:
                with self.assertRaisesRegex(SystemExit, 'delegated cgroup'):
                    builder.cli()
            main.assert_not_called()
            memory.assert_not_called()
            budget.assert_not_called()
            launch.assert_called_once_with()

    def parent(self, root, *, controllers='cpu memory pids', memory_max='max',
               memory_current='0', cpu_max='max 100000', pids_max='max', pids_current='10'):
        for name, value in {
            'cgroup.subtree_control': controllers,
            'memory.max': memory_max,
            'memory.current': memory_current,
            'cpu.max': cpu_max,
            'pids.max': pids_max,
            'pids.current': pids_current,
            'cgroup.procs': '1',
        }.items():
            (root / name).write_text(value)

    def test_limits_bound_the_whole_process_tree(self):
        with tempfile.TemporaryDirectory() as tmp:
            parent = Path(tmp)
            self.parent(parent, memory_max=str(8 * 1024**3),
                        memory_current=str(2 * 1024**3), cpu_max='200000 100000',
                        pids_max='300', pids_current='200')
            result = limits._limits(parent, 12)
            self.assertEqual(result['memory.max'], str(8 * 1024**3))
            self.assertEqual(result['memory.swap.max'], '0')
            self.assertEqual(result['cpu.max'], '150000 100000')
            self.assertEqual(result['pids.max'], '84')
            self.assertEqual(result['memory.oom.group'], '1')

    def test_missing_delegation_fails_before_child_launch(self):
        with tempfile.TemporaryDirectory() as tmp:
            parent = Path(tmp)
            self.parent(parent, controllers='')
            with patch.object(limits, '_self_cgroup', return_value=parent), \
                 patch.object(limits.subprocess, 'Popen') as launch:
                with self.assertRaisesRegex(limits.ContainmentUnavailable, 'delegated cgroup'):
                    limits.supervise(root=parent, affinity_cpus=12)
            launch.assert_not_called()
            self.assertEqual(list(parent.glob('wikidict-build-*')), [])

    def test_inherited_hard_memory_and_pid_caps_are_fail_closed(self):
        with tempfile.TemporaryDirectory() as tmp:
            parent = Path(tmp)
            self.parent(parent, memory_max=str(1 * 1024**3),
                        memory_current=str(3 * 1024**3))
            with self.assertRaisesRegex(limits.ContainmentUnavailable, 'inherited memory cap'):
                limits._limits(parent, 12)
            self.parent(parent, pids_max='20')
            with self.assertRaisesRegex(limits.ContainmentUnavailable, 'process slots'):
                limits._limits(parent, 12)

    def test_child_enters_bounded_group_before_exec(self):
        with tempfile.TemporaryDirectory() as tmp:
            parent = Path(tmp)
            self.parent(parent)
            observed = {}

            class FakeChild:
                def wait(self):
                    return 7

            original_mkdir = Path.mkdir

            def fake_mkdir(path, *args, **kwargs):
                original_mkdir(path, *args, **kwargs)
                if path.name.startswith('wikidict-build-'):
                    (path / 'cgroup.procs').write_text('')
                    (path / 'cgroup.kill').write_text('')

            def fake_popen(command, *, env, preexec_fn):
                group = Path(env[limits.CHILD_CGROUP])
                observed['command'] = command
                observed['memory'] = (group / 'memory.max').read_text()
                observed['swap'] = (group / 'memory.swap.max').read_text()
                observed['cpu'] = (group / 'cpu.max').read_text()
                observed['pids'] = (group / 'pids.max').read_text()
                preexec_fn()
                observed['joined_pid'] = (group / 'cgroup.procs').read_text()
                return FakeChild()

            with patch.object(limits, '_self_cgroup', return_value=parent), \
                 patch.object(Path, 'mkdir', fake_mkdir), \
                 patch.object(limits.subprocess, 'Popen', side_effect=fake_popen), \
                 patch.object(limits, '_cleanup') as cleanup:
                self.assertEqual(limits.supervise(root=parent,
                                                 argv=['tools/build_wiktionaries.py'],
                                                 affinity_cpus=12), 7)
            self.assertEqual(observed['command'][1:], ['tools/build_wiktionaries.py'])
            self.assertEqual(observed['joined_pid'], str(os.getpid()))
            self.assertEqual(observed['memory'], str(8 * 1024**3))
            self.assertEqual(observed['swap'], '0')
            self.assertEqual(observed['cpu'], '900000 100000')
            self.assertEqual(observed['pids'], '256')
            cleanup.assert_called_once()

    def test_child_rejects_unbounded_or_wrong_group(self):
        with tempfile.TemporaryDirectory() as tmp:
            group = Path(tmp) / 'wikidict-build-safe'
            group.mkdir()
            for name, value in {'memory.max': '1073741824', 'memory.swap.max': '0',
                                'pids.max': '64', 'cpu.max': '50000 100000'}.items():
                (group / name).write_text(value)
            with patch.dict(os.environ, {limits.CHILD_CGROUP: str(group)}), \
                 patch.object(limits, '_self_cgroup', return_value=group):
                self.assertTrue(limits.inside_envelope())
                (group / 'pids.max').write_text('max')
                with self.assertRaisesRegex(limits.ContainmentUnavailable, 'pids.max'):
                    limits.inside_envelope()
                (group / 'pids.max').write_text('64')
                (group / 'memory.max').write_text(str(8 * 1024**3 + 1))
                with self.assertRaisesRegex(limits.ContainmentUnavailable, 'memory cap exceeds'):
                    limits.inside_envelope()
                (group / 'memory.max').write_text('1073741824')
                with patch.dict(os.environ, {limits.CHILD_CGROUP: str(Path(tmp))}):
                    with self.assertRaisesRegex(limits.ContainmentUnavailable, 'did not enter'):
                        limits.inside_envelope()

    def test_cli_refuses_without_delegation_before_reading_manifest(self):
        with tempfile.TemporaryDirectory() as tmp:
            parent = Path(tmp)
            self.parent(parent, controllers='')
            with patch.object(builder, 'PROJECT', parent), \
                 patch.object(limits, '_delegated_parent',
                              side_effect=limits.ContainmentUnavailable('A writable delegated cgroup is required')), \
                 patch.object(sys, 'argv', ['build_wiktionaries.py', '--downloads',
                                            str(parent / 'missing-downloads')]), \
                 patch.object(limits.subprocess, 'Popen') as launch:
                with self.assertRaisesRegex(SystemExit, 'delegated cgroup'):
                    builder.cli()
            launch.assert_not_called()

    def test_project_resource_lock_refuses_second_corpus_invocation(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / '.tmp' / 'build-resources.lock'
            with builder.acquire_build_resource_lock(path):
                with self.assertRaisesRegex(limits.ContainmentUnavailable, 'resource lock'):
                    builder.acquire_build_resource_lock(path)
            with builder.acquire_build_resource_lock(path):
                self.assertTrue(path.is_file())

    def test_delegation_search_stays_within_mounted_hierarchy(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / 'mounted'
            outside = Path(tmp) / 'outside'
            root.mkdir()
            outside.mkdir()
            with self.assertRaisesRegex(limits.ContainmentUnavailable, 'outside the mounted hierarchy'):
                limits._delegated_parent(outside, root)

    def test_help_does_not_require_cgroup_or_manifest(self):
        output = io.StringIO()
        with patch.object(sys, 'argv', ['build_wiktionaries.py', '--help']), \
             patch.object(builder, 'safe_worker_budget', return_value=0), \
             patch.object(limits, 'inside_envelope') as inside, \
             patch.object(limits, 'supervise') as launch, \
             contextlib.redirect_stdout(output):
            with self.assertRaises(SystemExit) as stopped:
                builder.cli()
        self.assertEqual(stopped.exception.code, 0)
        self.assertIn('--downloads', output.getvalue())
        inside.assert_not_called()
        launch.assert_not_called()

    def test_worker_budget_does_not_read_host_free_ram(self):
        with patch.dict(os.environ, {}, clear=True), \
             patch.object(Path, 'read_text', side_effect=AssertionError('host free RAM was read')) as memory, \
             patch.object(builder, 'load_average', return_value=0), \
             patch.object(builder.os, 'cpu_count', return_value=12):
            self.assertEqual(builder.safe_worker_budget(), 5)
            memory.assert_not_called()

    def test_sibling_envelope_respects_supervisor_leaf_caps(self):
        with tempfile.TemporaryDirectory() as tmp:
            parent = Path(tmp)
            leaf = parent / 'supervisor-leaf'
            leaf.mkdir()
            self.parent(parent, memory_max='max', cpu_max='max 100000')
            self.parent(leaf, controllers='', memory_max=str(7 * 1024**3),
                        memory_current=str(1 * 1024**3), cpu_max='100000 100000',
                        pids_max='100', pids_current='20')
            result = limits._limits(parent, 12, parent, leaf)
            self.assertEqual(result['memory.max'], str(7 * 1024**3))
            self.assertEqual(result['cpu.max'], '75000 100000')
            self.assertEqual(result['pids.max'], '64')
            self.parent(parent, memory_max=str(4 * 1024**3))
            result = limits._limits(parent, 12, parent, leaf)
            self.assertEqual(result['memory.max'], str(4 * 1024**3))

    def test_cleanup_kills_only_populated_private_group_and_waits_for_empty(self):
        with tempfile.TemporaryDirectory() as tmp:
            group = Path(tmp) / 'wikidict-build-owned'
            group.mkdir()
            (group / 'cgroup.events').write_text('populated 1\n')
            (group / 'cgroup.kill').write_text('')
            def emptied(_seconds):
                (group / 'cgroup.events').write_text('populated 0\n')
            with patch.object(limits.time, 'sleep', side_effect=emptied) as pause, \
                 patch.object(Path, 'rmdir') as remove:
                limits._cleanup(group)
            self.assertEqual((group / 'cgroup.kill').read_text(), '1')
            pause.assert_called_once()
            remove.assert_called_once_with()

    def test_watchdog_rejects_partial_proof_and_unsafe_caps_before_launch(self):
        with patch.dict(os.environ, {limits.WATCHDOG_TOKEN: 'token'}, clear=False):
            with self.assertRaisesRegex(limits.ContainmentUnavailable, 'Incomplete'):
                limits.inside_watchdog()
        with patch.object(limits.subprocess, 'Popen') as launch:
            with self.assertRaisesRegex(limits.ContainmentUnavailable, 'resource limit'):
                limits.supervise_watchdog(memory_limit_bytes=limits.MAX_BUILD_MEMORY + 1)
            with self.assertRaisesRegex(limits.ContainmentUnavailable, 'resource limit'):
                limits.supervise_watchdog(max_tasks=limits.MAX_BUILD_PIDS + 1)
        launch.assert_not_called()

    def test_watchdog_samples_only_owned_pss_and_tasks(self):
        supervisor = os.getpid()
        table = {
            100: {'state':'S','ppid':1,'pgrp':100,'session':100,'threads':1,'start':10,'rss':4096},
            101: {'state':'S','ppid':100,'pgrp':101,'session':101,'threads':3,'start':11,'rss':8192},
            102: {'state':'S','ppid':supervisor,'pgrp':102,'session':102,'threads':2,'start':12,'rss':4096},
            998: {'state':'S','ppid':supervisor,'pgrp':998,'session':998,'threads':9,'start':9,'rss':16384},
            999: {'state':'S','ppid':1,'pgrp':999,'session':999,'threads':9,'start':12,'rss':16384},
        }
        def proc_text(path):
            if path.name == 'smaps_rollup':
                return 'Pss: 100 kB\n'
            if path.name == 'status':
                return 'Threads: ' + {'100':'1','101':'3','102':'2'}[path.parent.name] + '\n'
            raise AssertionError(path)
        known = {}
        with patch.object(limits, '_process_table', return_value=table), \
             patch.object(Path, 'read_text', autospec=True, side_effect=proc_text):
            sample = limits._owned_sample(100, 10, known, supervisor, {(998, 9)})
        self.assertEqual(set(known), {100, 101, 102})
        self.assertEqual(sample['pss_bytes'], 300 * 1024)
        self.assertEqual(sample['rss_bytes'], 16384)
        self.assertEqual(sample['tasks'], 6)

    def test_watchdog_treats_exiting_zombie_as_gone(self):
        running = {100: {'state':'S','ppid':1,'pgrp':100,'session':100,
                         'threads':1,'start':10,'rss':4096}}
        zombie = {100: dict(running[100], state='Z')}
        with patch.object(limits, '_process_table', side_effect=[running, zombie]), \
             patch.object(Path, 'read_text', side_effect=FileNotFoundError):
            sample = limits._owned_sample(100, 10, {}, os.getpid())
        self.assertEqual(sample['live'], {})

    def test_watchdog_handles_mm_teardown_and_charges_live_rss(self):
        running = {100: {'state':'S','ppid':1,'pgrp':100,'session':100,
                         'threads':1,'start':10,'vsize':8192,'rss':4096}}
        no_mm = {100: dict(running[100], vsize=0, rss=0)}
        with patch.object(limits, '_process_table', side_effect=[running, no_mm]), \
             patch.object(limits, '_thread_accounting', return_value=None), \
             patch.object(Path, 'read_text', side_effect=FileNotFoundError):
            self.assertEqual(limits._owned_sample(100, 10, {}, os.getpid())['live'], {})
        with patch.object(limits, '_process_table', side_effect=[running, running]), \
             patch.object(limits, '_thread_accounting', return_value=None), \
             patch.object(Path, 'read_text', side_effect=FileNotFoundError):
            sample = limits._owned_sample(100, 10, {}, os.getpid())
        self.assertEqual(sample['pss_bytes'], 4096)
        self.assertEqual(sample['tasks'], 1)

    def test_watchdog_counts_surviving_threads_and_rejects_permission_errors(self):
        leader = {100: {'state':'Z','ppid':1,'pgrp':100,'session':100,
                        'threads':3,'start':10,'vsize':0,'rss':0}}
        with patch.object(limits, '_process_table', return_value=leader), \
             patch.object(limits, '_thread_accounting', return_value=(5, 3)), \
             patch.object(Path, 'read_text', side_effect=FileNotFoundError):
            sample = limits._owned_sample(100, 10, {}, os.getpid())
        self.assertEqual(sample['pss_bytes'], 5 * 1024)
        self.assertEqual(sample['tasks'], 3)
        with patch.object(limits, '_process_table', return_value=leader), \
             patch.object(Path, 'read_text', side_effect=PermissionError):
            with self.assertRaisesRegex(limits.ContainmentUnavailable, 'Cannot measure owned process'):
                limits._owned_sample(100, 10, {}, os.getpid())

    def test_watchdog_accounts_vanishing_thread_group_without_losing_limits(self):
        running = {100: {'state':'S','ppid':1,'pgrp':100,'session':100,
                         'threads':3,'start':10,'vsize':8192,'rss':8192}}
        no_mm = {100: dict(running[100], vsize=0, rss=0)}
        with patch.object(limits, '_process_table', side_effect=[running, no_mm]), \
             patch.object(limits, '_thread_accounting', return_value=None), \
             patch.object(limits, '_live_mm_siblings', return_value=False), \
             patch.object(Path, 'read_text', side_effect=FileNotFoundError):
            sample = limits._owned_sample(100, 10, {}, os.getpid())
        self.assertEqual(sample['pss_bytes'], 8192)
        self.assertEqual(sample['tasks'], 3)
        self.assertIn(100, sample['live'])

        with patch.object(limits, '_process_table', side_effect=[running, no_mm]), \
             patch.object(limits, '_thread_accounting', return_value=None), \
             patch.object(limits, '_live_mm_siblings', return_value=True), \
             patch.object(Path, 'read_text', side_effect=FileNotFoundError):
            with self.assertRaisesRegex(limits.ContainmentUnavailable, 'Cannot measure live threads'):
                limits._owned_sample(100, 10, {}, os.getpid())

    def test_watchdog_unreadable_task_directory_requires_exit_identity(self):
        running = {100: {'state':'S','ppid':1,'pgrp':100,'session':100,
                         'threads':3,'start':10,'vsize':8192,'rss':8192}}
        no_mm = {100: dict(running[100], vsize=0, rss=0)}
        with patch.object(limits, '_process_table', side_effect=[running, no_mm, no_mm]), \
             patch.object(limits, '_thread_accounting', return_value=None), \
             patch.object(limits, '_live_mm_siblings', return_value=None), \
             patch.object(Path, 'read_text', side_effect=FileNotFoundError):
            with self.assertRaisesRegex(limits.ContainmentUnavailable, 'Cannot measure live threads'):
                limits._owned_sample(100, 10, {}, os.getpid())
        with patch.object(limits, '_process_table', side_effect=[running, no_mm, {}]), \
             patch.object(limits, '_thread_accounting', return_value=None), \
             patch.object(limits, '_live_mm_siblings', return_value=None), \
             patch.object(Path, 'read_text', side_effect=FileNotFoundError):
            self.assertEqual(limits._owned_sample(100, 10, {}, os.getpid())['live'], {})
        with patch.object(os, 'scandir', side_effect=PermissionError('denied')):
            with self.assertRaisesRegex(limits.ContainmentUnavailable, 'Cannot inspect live threads'):
                limits._live_mm_siblings(100)

    def test_runtime_ram_and_psi_pressure_are_telemetry(self):
        observer = self.explicit_host_observer()
        observer.sample()  # Consume the adequate admission observation.
        report = {'child_pid': 123}
        with patch.object(limits, '_check_watchdog_disk_floor') as disk:
            limits._check_watchdog_observation(report, observer)
        disk.assert_called_once_with(report)
        state = report['host_pressure_guard']
        self.assertFalse(state['stopped'])
        self.assertFalse(state['policy']['runtime_termination_enabled'])
        self.assertNotIn('stop_reason', state)
        self.assertEqual(state['last_sample']['mem_available_bytes'], 1)
        self.assertEqual(state['last_sample']['psi_full_avg10'], 99.0)

    def test_host_pressure_admission_still_refuses_before_launch(self):
        observer = self.explicit_host_observer()
        observer.sample()
        with tempfile.TemporaryDirectory() as tmp:
            with patch.object(limits.subprocess, 'Popen') as launch:
                with self.assertRaisesRegex(limits.ContainmentUnavailable, 'admission refused: host_ram_admission_reserve; runtime_started=false'):
                    limits.supervise_watchdog(
                        argv=['-c', 'raise SystemExit(99)'],
                        report_path=Path(tmp) / 'watchdog.json', wall_seconds=10,
                        memory_limit_bytes=64 * 1024**2, max_tasks=4,
                        host_observation=observer)
            launch.assert_not_called()
            report = json.loads((Path(tmp) / 'watchdog.json').read_text())
            self.assertEqual(report['error'], 'Host pressure safety stop: host_ram_admission_reserve')
            self.assertNotIn('child_pid', report)
            self.assertNotIn('guardian_pid', report)
            self.assertFalse(report['runtime_started'])
            self.assertEqual(report['termination_reason'], 'monitor_error')
            self.assertTrue(report['admission_refused'])
            self.assertEqual(report['admission_reason'], 'host_ram_admission_reserve')
            self.assertFalse(report['cleanup_complete'])
            self.assertEqual(report['cleanup_scope'], 'no_child_or_guardian_launched')
            self.assertEqual((report['peak_pss_bytes'], report['peak_rss_bytes'], report['peak_tasks']), (0, 0, 0))
            self.assertTrue(report['host_pressure_guard']['stopped'])

    def test_prelaunch_observation_refusal_is_distinct_from_setup_error(self):
        for observation_error in (True, False):
            with self.subTest(observation_error=observation_error), tempfile.TemporaryDirectory() as tmp:
                observer = (self.explicit_host_observer() if observation_error
                            else Mock(side_effect=limits.ContainmentUnavailable('setup failed')))
                if observation_error:
                    observer.sampler = Mock(side_effect=OSError('sample unavailable'))
                with patch.object(limits.subprocess, 'Popen') as launch:
                    with self.assertRaises(limits.ContainmentUnavailable):
                        limits.supervise_watchdog(
                            argv=['-c', 'raise SystemExit(99)'],
                            report_path=Path(tmp) / 'watchdog.json', wall_seconds=10,
                            memory_limit_bytes=64 * 1024**2, max_tasks=4,
                            host_observation=observer)
                launch.assert_not_called()
                report = json.loads((Path(tmp) / 'watchdog.json').read_text())
                self.assertFalse(report['runtime_started'])
                self.assertEqual(report['admission_refused'], observation_error)
                self.assertEqual(report['termination_reason'], 'monitor_error')
                self.assertEqual(report.get('admission_reason'), 'host_pressure_observation_failed' if observation_error else None)
                self.assertFalse(report['cleanup_complete'])
                self.assertEqual(report['cleanup_scope'], 'no_child_or_guardian_launched')

    def test_runtime_pressure_policy_preserves_other_failures(self):
        errors = [limits._DiskFloorReached('reserve exhausted'),
                  limits.ContainmentUnavailable('Cannot measure free disk space'),
                  OSError('disk I/O'), RuntimeError('unknown disk failure')]
        for error in errors:
            with self.subTest(error=repr(error)):
                observer = Mock()
                report = {'child_pid': 123}
                with patch.object(limits, '_check_watchdog_disk_floor', side_effect=error):
                    with self.assertRaises(type(error)) as caught:
                        limits._check_watchdog_observation(report, observer)
                self.assertIs(caught.exception, error)
                observer.assert_not_called()

    def explicit_host_observer(self):
        # Adequate admission RAM, then exhausted host RAM throughout execution.
        observations = 0
        def sample():
            nonlocal observations
            observations += 1
            return dict(mem_total_bytes=16 * 1024**3,
                        mem_available_bytes=6 * 1024**3 if observations == 1 else 1,
                        swap_total_bytes=0, swap_free_bytes=0,
                        psi_some_avg10=99.0, psi_full_avg10=99.0,
                        observed_unix=observations)
        return limits.HostMemoryObservation(dict(
            job_memory_ceiling_bytes=64 * 1024**2,
            admission_mem_available_bytes=5 * 1024**3,
            admission_pressure_advisory=True, runtime_termination_enabled=False,
            swap_allowed=True, swap_counted_as_ram_headroom=False,
            poll_seconds=0.2, kernel_hard_cap=False), sample)

    def test_runtime_pressure_does_not_stop_a_started_child(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'watchdog.json'
            status = limits.supervise_watchdog(
                argv=['-c', 'import time, build_resource_limits as l; assert l.inside_watchdog(); time.sleep(0.3)'],
                report_path=path, wall_seconds=10,
                memory_limit_bytes=64 * 1024**2, max_tasks=4,
                host_observation=self.explicit_host_observer())
            report = json.loads(path.read_text())
            self.assertEqual(status, 0)
            self.assertEqual(report['termination_reason'], 'child_exit')
            self.assertFalse(report['host_pressure_guard']['stopped'])
            self.assertEqual(report['guardian_exit_status'], 0)
            self.assertTrue(report['cleanup_complete'])
            self.assertEqual(report['host_pressure_guard']['last_sample']['mem_available_bytes'], 1)
            self.assertEqual(report['memory_limit_bytes'], 64 * 1024**2)
            remaining = limits._process_table().get(report['child_pid'])
            self.assertTrue(remaining is None or remaining['start'] != report['child_start_time_ticks'])

    def test_runtime_pressure_does_not_weaken_own_memory_cap(self):
        original_sample = limits._owned_sample

        def over_budget(*args, **kwargs):
            sample = original_sample(*args, **kwargs)
            return {**sample, 'pss_bytes': 65 * 1024**2}

        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'watchdog.json'
            with patch.object(limits, '_owned_sample', side_effect=over_budget), \
                 patch.object(limits, '_signal_owned', wraps=limits._signal_owned) as cleanup_signals:
                with self.assertRaisesRegex(limits.ContainmentUnavailable, 'sampled_pss_limit'):
                    limits.supervise_watchdog(
                        argv=['-c', 'import time; time.sleep(5)'],
                        report_path=path, wall_seconds=10,
                        memory_limit_bytes=64 * 1024**2, max_tasks=4,
                        host_observation=self.explicit_host_observer())
            report = json.loads(path.read_text())
            self.assertEqual(report['termination_reason'], 'sampled_pss_limit')
            self.assertEqual(report['memory_limit_bytes'], 64 * 1024**2)
            self.assertFalse(report['host_pressure_guard']['stopped'])
            self.assertEqual(report['host_pressure_guard']['last_sample']['mem_available_bytes'], 1)
            self.assertTrue(any(call.args[0].get(report['child_pid']) == report['child_start_time_ticks']
                                for call in cleanup_signals.call_args_list))
            remaining = limits._process_table().get(report['child_pid'])
            self.assertTrue(remaining is None or remaining['start'] != report['child_start_time_ticks'])

    def test_guardian_child_birth_recovery_requires_exact_invocation(self):
        record = dict(root_pid=200, root_start=12, supervisor_pid=100,
                      supervisor_start=10, guardian_pid=101, status='observing')
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'guardian.json'
            path.write_text(json.dumps(record))
            self.assertEqual(limits._guardian_child_start(path, 200, 100, 10, 101), 12)
            for delta in ({'root_pid': 201}, {'supervisor_pid': 99},
                          {'supervisor_start': 9}, {'guardian_pid': 102},
                          {'root_start': True}, {'root_start': 9},
                          {'status': 'no_child_started'}):
                with self.subTest(delta=delta):
                    path.write_text(json.dumps({**record, **delta}))
                    with self.assertRaises(limits.ContainmentUnavailable):
                        limits._guardian_child_start(path, 200, 100, 10, 101)
            path.unlink()
            with self.assertRaises(limits.ContainmentUnavailable):
                limits._guardian_child_start(path, 200, 100, 10, 101)

    def test_missing_first_child_snapshot_uses_guardian_birth_for_cleanup(self):
        real_popen, real_table = limits.subprocess.Popen, limits._process_table
        children = []
        hidden = False

        def launch(*args, **kwargs):
            child = real_popen(*args, **kwargs)
            if kwargs.get('preexec_fn') is not None:
                children.append(child)
                child.kill = Mock(side_effect=AssertionError('Unverified PID kill'))
            return child

        def table():
            nonlocal hidden
            result = real_table()
            if children and not hidden:
                result.pop(children[0].pid, None)
                hidden = True
            return result

        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'watchdog.json'
            with patch.object(limits.subprocess, 'Popen', side_effect=launch), \
                 patch.object(limits, '_process_table', side_effect=table):
                with self.assertRaisesRegex(limits.ContainmentUnavailable, 'monitor_error'):
                    limits.supervise_watchdog(
                        argv=['-c', 'import time; time.sleep(5)'],
                        report_path=path, wall_seconds=10,
                        memory_limit_bytes=64 * 1024**2, max_tasks=4)
            report = json.loads(path.read_text())
            guardian = json.loads(path.with_name('watchdog-guardian.json').read_text())
            self.assertEqual(report['error'], 'Cannot identify watchdog child')
            self.assertEqual(report['termination_reason'], 'monitor_error')
            self.assertTrue(report['runtime_started'])
            self.assertFalse(report['admission_refused'])
            self.assertNotIn('admission_reason', report)
            self.assertEqual(report['cleanup_scope'], 'watchdog_owned_processes')
            self.assertTrue(hidden)
            self.assertEqual(report['child_identity_source'], 'guardian_handshake')
            self.assertEqual(report['child_start_time_ticks'], guardian['root_start'])
            self.assertFalse(Path('/proc', str(report['child_pid'])).exists())
            children[0].kill.assert_not_called()

    def test_watchdog_wall_limit_reaps_own_child(self):
        with tempfile.TemporaryDirectory() as tmp:
            report_path = Path(tmp) / 'watchdog.json'
            native_pid_path = Path(tmp) / 'native.pid'
            child_code = (
                'import build_resource_limits as l, os, subprocess, time; '
                'assert l.inside_watchdog(); '
                'native=subprocess.Popen(["/bin/sleep", "5"]); '
                f'pid_path={str(native_pid_path)!r}; '
                'pid_file=open(pid_path + ".tmp", "w"); '
                'pid_file.write(str(native.pid)); pid_file.close(); '
                'os.replace(pid_path + ".tmp", pid_path); '
                'time.sleep(5)'
            )
            # Allow interpreter startup and recording the native descendant under load.
            # Both five-second sleepers must still be stopped by the wall limit.
            with self.assertRaisesRegex(limits.ContainmentUnavailable, 'wall_limit'):
                limits.supervise_watchdog(
                    argv=['-c', child_code],
                    report_path=report_path, wall_seconds=2,
                    memory_limit_bytes=64 * 1024**2, max_tasks=4)
            report = json.loads(report_path.read_text())
            self.assertEqual(report['termination_reason'], 'wall_limit')
            self.assertLessEqual(report['peak_pss_bytes'], 64 * 1024**2)
            self.assertLessEqual(report['peak_tasks'], 4)
            self.assertFalse(Path('/proc', str(report['child_pid'])).exists())
            # Startup may exhaust the wall bound before a native child is created.
            if native_pid_path.exists():
                self.assertFalse(Path('/proc', native_pid_path.read_text()).exists())


    @contextlib.contextmanager
    def guardian_normal_done_fixture(self, shutdown_statement):
        """Run the real guardian, changing only its final normal-disarm delay."""
        with tempfile.TemporaryDirectory() as tmp:
            fixture = Path(tmp) / 'build_watchdog_guardian.py'
            source = Path(limits.__file__).with_name('build_watchdog_guardian.py').read_text()
            original = (
                "        record['tracked_processes'] = len(known)\n"
                "        report(args.report, record)\n"
                "        return\n"
                "    record['status'] = 'cleanup'"
            )
            replacement = (
                "        record['tracked_processes'] = len(known)\n"
                "        " + shutdown_statement + "\n"
                "        report(args.report, record)\n"
                "        return\n"
                "    record['status'] = 'cleanup'"
            )
            self.assertEqual(source.count(original), 1)
            fixture.write_text(source.replace(original, replacement))
            real_popen = limits.subprocess.Popen
            guardians = []
            guardian_starts = {}

            def launch(argv, *args, **kwargs):
                if (isinstance(argv, list) and len(argv) > 2 and
                        Path(argv[2]).name == 'build_watchdog_guardian.py'):
                    argv = [*argv[:2], str(fixture), *argv[3:]]
                    env = dict(os.environ)
                    env['PYTHONPATH'] = str(Path(limits.__file__).resolve().parent) + os.pathsep + env.get('PYTHONPATH', '')
                    kwargs['env'] = env
                    child = real_popen(argv, *args, **kwargs)
                    guardians.append(child)
                    identity = limits._process_table()[child.pid]
                    self.assertEqual(identity['pgrp'], child.pid)
                    self.assertEqual(identity['session'], child.pid)
                    guardian_starts[child.pid] = identity['start']
                    return child
                return real_popen(argv, *args, **kwargs)

            try:
                with patch.object(limits.subprocess, 'Popen', side_effect=launch):
                    yield Path(tmp) / 'watchdog.json', guardians
            finally:
                # A negative test owns and reaps its deliberately hung fixture.
                # Do not leave a test guardian attached to the unittest runner.
                for guardian in guardians:
                    try:
                        guardian.wait(timeout=2)
                    except limits.subprocess.TimeoutExpired:
                        limits._signal_owned({guardian.pid: guardian_starts[guardian.pid]},
                                             limits.signal.SIGKILL)
                        guardian.wait(timeout=5)

    def test_watchdog_normal_guardian_exit_after_five_seconds_is_reaped(self):
        with self.guardian_normal_done_fixture('time.sleep(6.0)') as (report_path, guardians):
            status = limits.supervise_watchdog(
                argv=['-c', 'import build_resource_limits as l; assert l.inside_watchdog()'],
                report_path=report_path, wall_seconds=60,
                memory_limit_bytes=64 * 1024**2, max_tasks=4)
            report = json.loads(report_path.read_text())
            self.assertEqual(status, 0)
            self.assertEqual(report['termination_reason'], 'child_exit')
            self.assertEqual(report['guardian_exit_status'], 0)
            self.assertEqual(len(guardians), 1)
            self.assertEqual(guardians[0].returncode, 0)
            self.assertFalse(Path('/proc', str(report['guardian_pid'])).exists())
            guardian_report = json.loads(report_path.with_name('watchdog-guardian.json').read_text())
            self.assertEqual(guardian_report['status'], 'disarmed')
            self.assertEqual(guardian_report['reason'], 'normal_done')

    def test_watchdog_nonterminating_guardian_still_fails_cleanup(self):
        with self.guardian_normal_done_fixture('time.sleep(60.0)') as (report_path, guardians):
            with patch.object(limits, 'WATCHDOG_GUARDIAN_CLEANUP_SECONDS', 0.25, create=True):
                with self.assertRaisesRegex(limits.ContainmentUnavailable, 'cleanup_error'):
                    limits.supervise_watchdog(
                        argv=['-c', 'import build_resource_limits as l; assert l.inside_watchdog()'],
                        report_path=report_path, wall_seconds=60,
                        memory_limit_bytes=64 * 1024**2, max_tasks=4)
            report = json.loads(report_path.read_text())
            self.assertEqual(report['termination_reason'], 'cleanup_error')
            self.assertEqual(report['error'], 'Independent guardian did not finish cleanup')
            self.assertFalse(report['cleanup_complete'])
            self.assertNotIn('guardian_exit_status', report)
            self.assertEqual(report['child_exit_status'], 0)
            self.assertFalse(Path('/proc', str(report['child_pid'])).exists())
            self.assertEqual(len(guardians), 1)
            self.assertIsNone(guardians[0].poll())

    def test_watchdog_normal_exit_with_native_child(self):
        with tempfile.TemporaryDirectory() as tmp:
            report_path = Path(tmp) / 'watchdog.json'
            status = limits.supervise_watchdog(
                argv=['-c', 'import build_resource_limits as l, subprocess; assert l.inside_watchdog(); subprocess.run(["/bin/true"], check=True)'],
                report_path=report_path, wall_seconds=60,
                memory_limit_bytes=64 * 1024**2, max_tasks=4)
            report = json.loads(report_path.read_text())
            self.assertEqual(status, 0)
            self.assertEqual(report['termination_reason'], 'child_exit')
            self.assertEqual(report['child_exit_status'], 0)
            self.assertFalse(Path('/proc', str(report['child_pid'])).exists())

    def test_watchdog_controller_exit_reaps_orphan_native_child(self):
        with tempfile.TemporaryDirectory() as tmp:
            report_path = Path(tmp) / 'watchdog.json'
            native_pid_path = Path(tmp) / 'native.pid'
            child_code = (
                'import build_resource_limits as l, subprocess; '
                'assert l.inside_watchdog(); '
                'native=subprocess.Popen(["/bin/sleep", "60"]); '
                f'with_file=open({str(native_pid_path)!r}, "w"); '
                'with_file.write(str(native.pid)); with_file.close()'
            )
            with self.assertRaisesRegex(
                    limits.ContainmentUnavailable, 'controller_exited_with_descendants'):
                limits.supervise_watchdog(
                    argv=['-c', child_code], report_path=report_path, wall_seconds=60,
                    memory_limit_bytes=64 * 1024**2, max_tasks=4)
            report = json.loads(report_path.read_text())
            self.assertEqual(report['termination_reason'], 'controller_exited_with_descendants')
            self.assertTrue(report['cleanup_complete'])
            self.assertEqual(report['child_exit_status'], 0)
            # This marker is mandatory: the child wrote it before its normal exit.
            native_pid = int(native_pid_path.read_text())
            self.assertFalse(Path('/proc', str(report['child_pid'])).exists())
            self.assertFalse(Path('/proc', str(native_pid)).exists())

    def test_watchdog_rapid_native_child_exit_churn(self):
        with tempfile.TemporaryDirectory() as tmp:
            report_path = Path(tmp) / 'watchdog.json'
            status = limits.supervise_watchdog(
                argv=['-c', 'import build_resource_limits as l, subprocess; assert l.inside_watchdog(); [subprocess.run(["/bin/true"], check=True) for _ in range(100)]'],
                report_path=report_path, wall_seconds=60,
                memory_limit_bytes=64 * 1024**2, max_tasks=4)
            report = json.loads(report_path.read_text())
            self.assertEqual(status, 0)
            self.assertEqual(report['termination_reason'], 'child_exit')
            self.assertLessEqual(report['peak_tasks'], 4)


    def test_finite_virtual_limit_is_separate_from_sampled_physical_budget(self):
        with tempfile.TemporaryDirectory() as tmp:
            report_path=Path(tmp)/'watchdog.json'
            status=limits.supervise_watchdog(argv=['-c','import build_resource_limits as l, resource; assert l.inside_watchdog(); assert resource.getrlimit(resource.RLIMIT_AS)[0] == 128*1024**2'],report_path=report_path,wall_seconds=10,memory_limit_bytes=64*1024**2,address_space_limit_bytes=128*1024**2,max_tasks=4)
            self.assertEqual(status,0)
            report=json.loads(report_path.read_text())
            self.assertEqual(report['memory_limit_bytes'],64*1024**2)
            self.assertEqual(report['address_space_limit_bytes'],128*1024**2)
            self.assertLessEqual(report['peak_pss_bytes'],64*1024**2)
    def test_virtual_override_remains_bounded_and_does_not_weaken_memory_limit(self):
        for value in [0,1,True,limits.MAX_BUILD_MEMORY+1,float('inf')]:
            with self.subTest(value=value),self.assertRaises(limits.ContainmentUnavailable):
                limits.supervise_watchdog(argv=['-c','raise SystemExit(99)'],memory_limit_bytes=64*1024**2,address_space_limit_bytes=value)
        with patch.object(limits.resource,'getrlimit',return_value=(limits.MAX_BUILD_MEMORY,limits.MAX_BUILD_MEMORY)),patch.object(limits.subprocess,'Popen') as popen:
            with self.assertRaisesRegex(limits.ContainmentUnavailable,'unlimited inherited hard limit'):
                limits.supervise_watchdog(address_space_limit_bytes='unlimited')
            popen.assert_not_called()


    def test_watchdog_child_nice_preserves_default_and_absolute_targets(self):
        for requested,inherited,expected in [(None,0,0),(None,7,7),(None,15,15),(None,19,19),(None,-5,-5),(0,0,0),(0,-5,0),(15,0,15),(15,15,15),(19,15,19)]:
            with self.subTest(requested=requested,inherited=inherited):
                self.assertEqual(expected,limits._watchdog_child_nice(requested,inherited))
        with self.assertRaises(limits.ContainmentUnavailable):
            limits._watchdog_child_nice(0,15)

    def test_watchdog_child_nice_rejects_invalid_requests_before_launch(self):
        for value in [-1,20,True,False,0.0,15.0,'0']:
            with self.subTest(value=value),patch.object(limits.subprocess,'Popen') as launch:
                with self.assertRaises(limits.ContainmentUnavailable):
                    limits.supervise_watchdog(argv=['-c','raise SystemExit(99)'],child_nice=value)
                launch.assert_not_called()
        with patch.object(limits.os,'getpriority',return_value=15),patch.object(limits.subprocess,'Popen') as launch:
            with self.assertRaises(limits.ContainmentUnavailable):
                limits.supervise_watchdog(argv=['-c','raise SystemExit(99)'],child_nice=0)
            launch.assert_not_called()

    def test_watchdog_reports_actual_default_child_priority_without_weakening_limits(self):
        inherited=os.getpriority(os.PRIO_PROCESS,0)
        expected=inherited
        with tempfile.TemporaryDirectory() as tmp:
            report_path=Path(tmp)/'watchdog.json'
            code='import os,resource,build_resource_limits as l; assert l.inside_watchdog(); assert os.getpriority(os.PRIO_PROCESS,0)=='+str(expected)+'; assert resource.getrlimit(resource.RLIMIT_AS)[0]==128*1024**2'
            status=limits.supervise_watchdog(argv=['-c',code],report_path=report_path,wall_seconds=60,memory_limit_bytes=64*1024**2,address_space_limit_bytes=128*1024**2,max_tasks=4)
            self.assertEqual(status,0)
            report=json.loads(report_path.read_text())
            self.assertIsNone(report['requested_child_nice'])
            self.assertEqual(expected,report['child_nice'])
            self.assertEqual(64*1024**2,report['memory_limit_bytes'])
            self.assertLessEqual(report['peak_pss_bytes'],64*1024**2)

    def test_watchdog_absolute_child_priority_retains_inherited_priority(self):
        inherited=os.getpriority(os.PRIO_PROCESS,0)
        with tempfile.TemporaryDirectory() as tmp:
            report_path=Path(tmp)/'watchdog.json'
            code='import os,build_resource_limits as l; assert l.inside_watchdog(); assert os.getpriority(os.PRIO_PROCESS,0)=='+str(inherited)
            status=limits.supervise_watchdog(argv=['-c',code],child_nice=inherited,report_path=report_path,wall_seconds=60,memory_limit_bytes=64*1024**2,address_space_limit_bytes=128*1024**2,max_tasks=4)
            self.assertEqual(status,0)
            report=json.loads(report_path.read_text())
            self.assertEqual(inherited,report['requested_child_nice'])
            self.assertEqual(inherited,report['child_nice'])


# Append before the existing unittest.main block in tools/test_build_resource_limits.py.
class ExplicitAdmissionTest(unittest.TestCase):
    def test_backed_swap_opt_in_reaches_original_threshold(self):
        policy = self.policy()
        policy['swap_counted_as_ram_headroom'] = True
        value = self.sample(2 * 1024**3)
        value['backed_swap_free_bytes'] = 3 * 1024**3
        obs = limits.HostMemoryObservation(policy)
        self.assertIsNone(obs.admission_reason(value))
        value['backed_swap_free_bytes'] -= 1
        self.assertEqual(obs.admission_reason(value), 'host_ram_admission_reserve')
        del value['backed_swap_free_bytes']
        self.assertEqual(obs.admission_reason(value), 'host_ram_admission_reserve')

    def test_backed_swap_validation_and_default_ram_only(self):
        value = self.sample(1)
        value['backed_swap_free_bytes'] = value['swap_free_bytes']
        self.assertEqual(self.observer().admission_reason(value), 'host_ram_admission_reserve')
        for bad in (True, -1, 1.5, value['swap_free_bytes'] + 1):
            value['backed_swap_free_bytes'] = bad
            with self.assertRaises(ValueError):
                limits.HostMemoryObservation.validate_sample(value)

    def test_only_verified_physical_swap_partitions_count(self):
        from types import SimpleNamespace
        import stat
        rows = 'Filename Type Size Used Priority\n/dev/disk partition 100 20 -2\n/dev/zram0 partition 200 0 -3\n/swapfile file 300 0 -4\n/dev/unknown partition 400 0 -5\n'
        def device(path):
            if str(path) == '/dev/unknown':
                raise PermissionError()
            return SimpleNamespace(st_mode=stat.S_IFBLK, st_rdev=os.makedev(8, 1 if str(path) == '/dev/disk' else 2))
        def backing(path, strict=False):
            return Path('/sys/devices/pci/block/disk' if str(path).endswith('8:1') else '/sys/devices/virtual/block/zram0')
        with patch.object(Path, 'read_text', return_value=rows), patch.object(Path, 'stat', device), patch.object(Path, 'resolve', backing), patch.object(Path, 'is_dir', return_value=True):
            self.assertEqual(limits._backed_swap_free_bytes(), 80 * 1024)

    def test_hidden_device_node_requires_matching_physical_sysfs_indexes(self):
        rows = 'Filename Type Size Used Priority\n/dev/nvme0n1p10 partition 100 20 -1\n'
        def read(path):
            return rows if str(path) == '/proc/swaps' else '259:8\n'
        def resolve(path, strict=False):
            return Path('/sys/devices/pci/block/nvme0n1/nvme0n1p10')
        with patch.object(Path, 'read_text', read), patch.object(Path, 'stat', side_effect=FileNotFoundError), patch.object(Path, 'resolve', resolve), patch.object(Path, 'is_dir', return_value=True):
            self.assertEqual(limits._backed_swap_free_bytes(), 80 * 1024)
            with patch.object(Path, 'resolve', side_effect=[Path('/sys/devices/pci/block/disk'), Path('/sys/devices/virtual/block/zram0')]):
                self.assertEqual(limits._backed_swap_free_bytes(), 0)

    @staticmethod
    def policy():
        return dict(admission_mem_available_bytes=5 * 1024**3,
                    admission_pressure_advisory=True, runtime_termination_enabled=False,
                    swap_counted_as_ram_headroom=False, poll_seconds=0.2)

    @staticmethod
    def sample(available=6 * 1024**3):
        return dict(mem_total_bytes=16 * 1024**3, mem_available_bytes=available,
                    swap_total_bytes=8 * 1024**3, swap_free_bytes=8 * 1024**3,
                    psi_some_avg10=99.0, psi_full_avg10=99.0, observed_unix=1.0)

    def observer(self, *samples):
        return limits.HostMemoryObservation(self.policy(), Mock(side_effect=samples))

    def test_swap_and_psi_do_not_supply_ram_or_veto_sufficient_ram(self):
        obs = self.observer(self.sample(), self.sample(1))
        self.assertIsNone(obs.admission_reason(obs.sample()))
        self.assertEqual(obs.admission_reason(obs.sample()), 'host_ram_admission_reserve')

    def test_admission_observation_failure_refuses_but_runtime_failure_is_recorded(self):
        obs = self.observer(OSError('unreadable'), OSError('unreadable'))
        report = {}
        with self.assertRaises(limits.ContainmentUnavailable):
            obs(report)
        self.assertEqual(report['host_pressure_guard']['stop_reason'], 'host_pressure_observation_failed')
        running = {'child_pid': 123}
        obs(running)
        self.assertEqual(running['host_pressure_guard']['observation_error'], 'unreadable')
        self.assertFalse(running['host_pressure_guard']['stopped'])

    def test_runtime_low_ram_does_not_stop_and_retains_extrema(self):
        obs = self.observer(self.sample(2), self.sample(1))
        report = {'child_pid': 123}
        obs(report)
        obs(report)
        state = report['host_pressure_guard']
        self.assertEqual(state['minimum_mem_available_bytes'], 1)
        self.assertEqual(state['maximum_full_psi_avg10'], 99.0)
        self.assertFalse(state['stopped'])
        self.assertNotIn('stop_reason', state)

    def test_disk_failure_precedes_observer_at_both_check_sites(self):
        obs = Mock()
        with patch.object(limits, '_check_watchdog_disk_floor', side_effect=limits.ContainmentUnavailable('disk')):
            with self.assertRaisesRegex(limits.ContainmentUnavailable, 'disk'):
                limits._check_watchdog_observation({}, obs)
        obs.assert_not_called()
        events = []
        with patch.object(limits, '_check_watchdog_disk_floor', side_effect=lambda report: events.append('disk/runtime')):
            limits._check_watchdog_observation({'child_pid': 123}, lambda report: events.append('host'))
        self.assertEqual(events, ['disk/runtime', 'host'])

    def test_malformed_sample_and_runtime_stop_policy_are_rejected(self):
        bad = self.sample()
        bad['mem_available_bytes'] = True
        with self.assertRaises(ValueError):
            self.observer(bad).sample()
        policy = self.policy()
        policy['runtime_termination_enabled'] = True
        with self.assertRaises(ValueError):
            limits.HostMemoryObservation(policy)

    def admission(self, observer, *, guard=None, record=None, once=True, deadline=100):
        return limits.wait_for_build_admission(
            deadline_unix=deadline,
            locks=[dict(path='/owned/lock' + str(i), dev=1, ino=i) for i in range(4)],
            host_observation=observer, final_guard=guard or Mock(),
            record_refusal=record or Mock(), once=once)

    def test_low_ram_does_not_open_locks_or_hash_and_records_original_reason(self):
        guard, record = Mock(), Mock()
        with patch.object(limits.time, 'time', return_value=1), patch.object(limits.os, 'open') as opened:
            with self.assertRaises(limits.AdmissionRefused) as caught:
                self.admission(self.observer(self.sample(1)), guard=guard, record=record)
        opened.assert_not_called()
        guard.assert_not_called()
        self.assertEqual(caught.exception.reason, 'host_ram_admission_reserve')
        self.assertEqual(record.call_args.args[0], 'host_ram_admission_reserve')

    def lock_mocks(self, stack, events, blocking=False, changed=False):
        from types import SimpleNamespace
        stack.enter_context(patch.object(limits.os, 'open', side_effect=lambda path, flags: events.append(('open', path)) or (10 + int(path[-1]))))
        def flock(fd, flags):
            events.append(('lock', fd))
            if blocking and fd == 11:
                raise BlockingIOError()
        stack.enter_context(patch.object(limits.fcntl, 'flock', side_effect=flock))
        stack.enter_context(patch.object(limits.os, 'fstat', side_effect=lambda fd: SimpleNamespace(st_dev=2 if changed else 1, st_ino=fd - 10)))
        return stack.enter_context(patch.object(limits.os, 'close', side_effect=lambda fd: events.append(('close', fd))))

    def test_four_locks_precede_guard_fresh_sample_and_held_fds_transfer(self):
        events = []
        def sample():
            events.append('sample')
            return self.sample()
        with contextlib.ExitStack() as stack:
            stack.enter_context(patch.object(limits.time, 'time', return_value=1))
            closed = self.lock_mocks(stack, events)
            fds, sample_value = self.admission(limits.HostMemoryObservation(self.policy(), sample), guard=lambda: events.append('guard'))
        self.assertEqual(fds, [10, 11, 12, 13])
        self.assertEqual(events[-2:], ['guard', 'sample'])
        self.assertEqual(sum(isinstance(e, tuple) and e[0] == 'lock' for e in events), 4)
        closed.assert_not_called()
        self.assertEqual(sample_value, self.sample())

    def test_contended_lock_closes_partial_set_without_guard(self):
        events, guard = [], Mock()
        with contextlib.ExitStack() as stack:
            stack.enter_context(patch.object(limits.time, 'time', return_value=1))
            closed = self.lock_mocks(stack, events, blocking=True)
            with self.assertRaises(limits.AdmissionRefused) as caught:
                self.admission(self.observer(self.sample()), guard=guard)
        guard.assert_not_called()
        self.assertEqual(caught.exception.reason, 'shared_resource_owner')
        self.assertEqual([call.args[0] for call in closed.call_args_list], [10, 11])

    def test_guard_blocking_io_propagates_without_refusal_or_sleep(self):
        events, record = [], Mock(side_effect=AssertionError('unexpected refusal'))
        error = BlockingIOError('source guard read failed')
        observer = self.observer(self.sample())
        with contextlib.ExitStack() as stack:
            stack.enter_context(patch.object(limits.time, 'time', return_value=1))
            slept = stack.enter_context(patch.object(limits.time, 'sleep', side_effect=AssertionError('unexpected retry')))
            closed = self.lock_mocks(stack, events)
            with self.assertRaises(BlockingIOError) as caught:
                self.admission(observer, guard=Mock(side_effect=error), record=record, once=False)
        self.assertIs(caught.exception, error)
        self.assertEqual([call.args[0] for call in closed.call_args_list], [10, 11, 12, 13])
        observer.sampler.assert_called_once()
        record.assert_not_called()
        slept.assert_not_called()

    def test_guard_error_and_lock_identity_mismatch_close_without_retry(self):
        for changed in (False, True):
            events, record = [], Mock()
            with contextlib.ExitStack() as stack:
                stack.enter_context(patch.object(limits.time, 'time', return_value=1))
                closed = self.lock_mocks(stack, events, changed=changed)
                with self.assertRaises((RuntimeError, limits.ContainmentUnavailable)):
                    self.admission(self.observer(self.sample()), guard=Mock(side_effect=RuntimeError('source changed')), record=record)
            record.assert_not_called()
            self.assertEqual(closed.call_count, 1 if changed else 4)

    def test_postguard_ram_refusal_closes_all_and_deadline_poll_is_clamped(self):
        events, record = [], Mock()
        with contextlib.ExitStack() as stack:
            stack.enter_context(patch.object(limits.time, 'time', side_effect=[1, 95, 100]))
            slept = stack.enter_context(patch.object(limits.time, 'sleep'))
            closed = self.lock_mocks(stack, events)
            with self.assertRaises(limits.AdmissionRefused) as caught:
                self.admission(self.observer(self.sample(), self.sample(1)), record=record, once=False)
        self.assertEqual(caught.exception.reason, 'deadline-before-admission')
        self.assertEqual(closed.call_count, 4)
        slept.assert_called_once_with(5)
        self.assertEqual(record.call_count, 1)


# Append before existing unittest.main in tools/test_build_resource_limits.py.
class WatchdogOpenFilesTest(unittest.TestCase):
    def test_open_files_rejects_invalid_requests_before_launch(self):
        for value in (True, False, 0, -1, 1.5, float('inf'), '8192', None, sys.maxsize + 1):
            with self.subTest(value=value), patch.object(limits.subprocess, 'Popen') as launch:
                with self.assertRaisesRegex(limits.ContainmentUnavailable, 'finite positive integer'):
                    limits.supervise_watchdog(max_open_files=value)
                launch.assert_not_called()

    def test_open_files_preserves_inherited_hard_limit(self):
        self.assertEqual(limits.watchdog_open_files_limit(8192, 1024), 1024)
        self.assertEqual(limits.watchdog_open_files_limit(512, 1024), 512)
        self.assertEqual(limits.watchdog_open_files_limit(8192, limits.resource.RLIM_INFINITY), 8192)
        with self.assertRaises(limits.ContainmentUnavailable):
            limits.watchdog_open_files_limit(8192, 0)

    def run_child_open_files(self, request=None):
        requested = 512 if request is None else request
        inherited = limits.resource.getrlimit(limits.resource.RLIMIT_NOFILE)[1]
        expected = requested if inherited == limits.resource.RLIM_INFINITY else min(requested, inherited)
        if request == 8192:
            self.assertEqual(expected, 8192, 'Android lifecycle prerequisite: inherited NOFILE hard limit must permit8192')
        # Prove the explicit Android setting can actually exceed the old512 cap
        # when inherited hard limits permit, without changing the parent's limit.
        count = 600 if expected >= 632 else 0
        with tempfile.TemporaryDirectory() as tmp:
            report_path = Path(tmp) / 'watchdog.json'
            observed_path = Path(tmp) / 'child.json'
            code = (
                'import os,sys,json,resource,build_resource_limits as limits; '
                'assert limits.inside_watchdog(); '
                'expected=int(sys.argv[1]); count=int(sys.argv[2]); '
                'soft,hard=resource.getrlimit(resource.RLIMIT_NOFILE); '
                'assert (soft,hard)==(expected,expected),(soft,hard,expected); '
                'fds=[os.open("/dev/null",os.O_RDONLY) for _ in range(count)]; '
                'observed=dict(soft=soft,hard=hard,opened=len(fds)); '
                '[os.close(fd) for fd in fds]; '
                'open(sys.argv[3],"x").write(json.dumps(observed))'
            )
            kwargs = {} if request is None else dict(max_open_files=request)
            status = limits.supervise_watchdog(
                argv=['-c', code, str(expected), str(count), str(observed_path)],
                report_path=report_path, memory_limit_bytes=64 * 1024**2,
                max_tasks=4, wall_seconds=10, **kwargs)
            report = json.loads(report_path.read_text())
            self.assertEqual(status, 0)
            self.assertEqual(json.loads(observed_path.read_text()), dict(soft=expected, hard=expected, opened=count))
            self.assertEqual(report['requested_max_open_files'], requested)
            self.assertEqual(report['max_open_files'], expected)
            self.assertEqual(report['memory_limit_bytes'], 64 * 1024**2)
            self.assertEqual(report['max_tasks'], 4)
            self.assertEqual(report['wall_seconds'], 10)
            self.assertEqual(report['termination_reason'], 'child_exit')
            self.assertEqual(report['guardian_exit_status'], 0)
            remaining = limits._process_table().get(report['child_pid'])
            self.assertTrue(remaining is None or remaining['start'] != report['child_start_time_ticks'])

    def test_watchdog_real_child_default_open_files_512(self):
        self.run_child_open_files()

    def test_watchdog_real_child_android_open_files_8192(self):
        self.run_child_open_files(8192)


class WatchdogPeakObservationTest(unittest.TestCase):
    @staticmethod
    def update(report, sample, *, elapsed, supervisor=None, guardian=None):
        # Execute the actual supervisor's accounting/update block without a job.
        import ast
        import inspect
        from types import SimpleNamespace
        function = ast.parse(inspect.getsource(limits.supervise_watchdog)).body[0]
        blocks = [node.body for node in ast.walk(function) if isinstance(node, ast.While)
                  and any(isinstance(row, ast.Assign) and isinstance(row.targets[0], ast.Name)
                          and row.targets[0].id == 'overhead_pss' for row in node.body)]
        assert len(blocks) == 1
        block = blocks[0]
        begin = next(i for i, row in enumerate(block) if isinstance(row, ast.Assign)
                     and isinstance(row.targets[0], ast.Name) and row.targets[0].id == 'overhead_pss')
        end = next(i for i, row in enumerate(block) if isinstance(row, ast.Assign)
                   and ast.unparse(row.targets[0]) == "report['elapsed_seconds']")
        code = compile(ast.Module(body=block[begin:end + 1], type_ignores=[]), '<actual-peak-update>', 'exec')
        usage = dict(pss_bytes=1024, rss_bytes=2048, tasks=1)
        namespace = dict(sample=sample, supervisor_usage=supervisor or usage,
                         guardian_usage=guardian or usage, supervisor_start=9,
                         guardian=SimpleNamespace(pid=91), guardian_info={'start': 8},
                         report=report, started=10.0, time=limits.time, os=limits.os)
        with patch.object(limits.time, 'monotonic', return_value=10.0 + elapsed), \
             patch.object(limits.os, 'getpid', return_value=90):
            exec(code, namespace)

    @staticmethod
    def report():
        return dict(peak_pss_bytes=0, peak_rss_bytes=0, peak_tasks=0)

    def test_peak_captures_owned_contributions_without_extra_process_reads(self):
        table = {
            100: dict(state='S', ppid=1, session=100, threads=1, start=10, rss=4096),
            101: dict(state='S', ppid=100, session=101, threads=2, start=11, rss=8192),
            800: dict(state='S', ppid=90, session=800, threads=5, start=8, rss=99999),
            900: dict(state='S', ppid=1, session=900, threads=5, start=20, rss=99999),
        }
        reads = []
        def read(path):
            reads.append(str(path))
            pid = int(path.parent.name)
            self.assertIn(pid, (100, 101))
            if path.name == 'smaps_rollup':
                return 'Pss: ' + ('3' if pid == 100 else '5') + ' kB\n'
            self.assertEqual(path.name, 'status')
            return 'Threads: ' + str(table[pid]['threads']) + '\n'
        known = {900: 19}  # Reused foreign PID must not appear in this sample.
        with patch.object(limits, '_process_table', return_value=table) as process_table, \
             patch.object(Path, 'read_text', autospec=True, side_effect=read):
            sample = limits._owned_sample(100, 10, known, 90, {(800, 8)})
        process_table.assert_called_once_with()
        self.assertEqual(len(reads), 4)
        report = self.report()
        with patch.object(limits, '_process_table', side_effect=AssertionError('extra process scan')), \
             patch.object(Path, 'read_text', side_effect=AssertionError('extra process read')), \
             patch.object(limits.time, 'time', return_value=1234.5):
            self.update(report, sample, elapsed=7.0,
                        guardian=dict(pss_bytes=2048, rss_bytes=4096, tasks=1))
        peak = report['peak_pss_observation']
        self.assertEqual((peak['sample_finished_unix'], peak['elapsed_seconds']), (1234.5, 7.0))
        self.assertTrue(peak['sequential_sample'])
        self.assertEqual((peak['pss_bytes'], peak['rss_bytes'], peak['tasks']), (11264, 18432, 5))
        self.assertEqual([(r['pid'], r['start_time_ticks'], r['pss_bytes'], r['tasks'])
                          for r in peak['processes']],
                         [(100, 10, 3072, 1), (101, 11, 5120, 2), (90, 9, 1024, 1), (91, 8, 2048, 1)])
        self.assertEqual(sum(r['pss_bytes'] for r in peak['processes']), report['peak_pss_bytes'])
        self.assertTrue(all(r['accounting'] == 'smaps_rollup' for r in peak['processes']))
        self.assertEqual([r['role'] for r in peak['processes']], ['child_tree', 'child_tree', 'supervisor', 'guardian'])
        self.assertNotIn('pss_bytes', table[100])
        snapshot = json.dumps(peak, sort_keys=True)
        sample['live'][100]['pss_bytes'] = 0
        self.assertEqual(json.dumps(peak, sort_keys=True), snapshot)
        self.assertTrue(all('argv' not in row and 'command' not in row for row in peak['processes']))

    def test_equal_lower_and_new_peak_keep_the_correct_sample(self):
        def sample(pss, rss, tasks):
            return dict(pss_bytes=pss, rss_bytes=rss, tasks=tasks,
                        live={100: dict(start=10, ppid=1, rss=rss, pss_bytes=pss,
                                        measured_tasks=tasks, accounting='smaps_rollup')})
        report = self.report()
        with patch.object(limits.time, 'time', side_effect=[100.0, 200.0]) as clock, \
             patch.object(limits, '_process_table', side_effect=AssertionError('extra scan')), \
             patch.object(Path, 'read_text', side_effect=AssertionError('extra read')):
            self.update(report, sample(100, 200, 1), elapsed=1)
            first = report['peak_pss_observation']
            self.update(report, sample(100, 500, 5), elapsed=2)
            self.assertIs(report['peak_pss_observation'], first)
            self.update(report, sample(90, 600, 6), elapsed=3)
            self.assertIs(report['peak_pss_observation'], first)
            self.assertEqual(first['rss_bytes'], 4296)
            self.assertEqual((report['peak_rss_bytes'], report['peak_tasks']), (4696, 8))
            self.assertEqual(report['elapsed_seconds'], 3)
            self.update(report, sample(101, 100, 1), elapsed=4)
        self.assertEqual(clock.call_count, 2)
        self.assertEqual(report['peak_pss_observation']['sample_finished_unix'], 200.0)
        self.assertEqual(report['peak_pss_observation']['elapsed_seconds'], 4)
        self.assertEqual(report['peak_pss_bytes'], 2149)
        self.assertEqual((report['peak_rss_bytes'], report['peak_tasks']), (4696, 8))

    def test_peak_identifies_thread_and_rss_fallback_charges(self):
        running = {100: dict(state='S', ppid=1, session=100, threads=3,
                             start=10, vsize=8192, rss=8192)}
        cases = [('thread_smaps_rollup', (5, 3), running, 5120),
                 ('rss_fallback', None, running, 8192),
                 ('released_mm_rss_fallback', None,
                  {100: dict(running[100], vsize=0, rss=0)}, 8192)]
        for expected, alternate, fresh, charged in cases:
            with self.subTest(accounting=expected), \
                 patch.object(limits, '_process_table', side_effect=[running, fresh]), \
                 patch.object(Path, 'read_text', side_effect=FileNotFoundError), \
                 patch.object(limits, '_thread_accounting', return_value=alternate), \
                 patch.object(limits, '_live_mm_siblings', return_value=False):
                sample = limits._owned_sample(100, 10, {}, 90)
            self.assertEqual(sample['pss_bytes'], charged)
            report = self.report()
            with patch.object(limits.time, 'time', return_value=123):
                self.update(report, sample, elapsed=2)
            row = report['peak_pss_observation']['processes'][0]
            self.assertEqual((row['pid'], row['start_time_ticks'], row['pss_bytes'], row['accounting']),
                             (100, 10, charged, expected))
            self.assertEqual(row['tasks'], 3)


if __name__ == '__main__':
    unittest.main()
