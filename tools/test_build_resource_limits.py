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

    def host_pressure_callback(self, reason, *, admission=False):
        disk_check = limits._check_watchdog_disk_floor

        def checked(report):
            disk_check(report)
            if ('child_pid' not in report) != admission:
                return
            report['host_pressure_guard'] = {
                'last_check': 'admission' if admission else 'runtime',
                'last_sample': {'mem_available_bytes': 1, 'psi_full_avg10': 99.0},
                'stopped': True, 'stop_reason': reason,
            }
            raise limits.ContainmentUnavailable('Host pressure safety stop: ' + reason)

        return checked

    def test_runtime_ram_and_psi_pressure_are_telemetry(self):
        for reason in ('host_ram_stop_reserve', 'host_memory_pressure'):
            with self.subTest(reason=reason):
                report = {'child_pid': 123, 'disk_space': []}
                callback = self.host_pressure_callback(reason)
                with patch.object(limits, '_check_watchdog_disk_floor', callback):
                    limits._check_watchdog_runtime(report)
                state = report['host_pressure_guard']
                self.assertEqual(state['runtime_pressure_reason'], reason)
                self.assertFalse(state['stopped'])
                self.assertFalse(state['runtime_termination_enabled'])
                self.assertNotIn('stop_reason', state)
                self.assertEqual(state['last_sample']['mem_available_bytes'], 1)

    def test_host_pressure_admission_still_refuses_before_launch(self):
        for reason in ('host_ram_admission_reserve', 'host_pressure_admission'):
            with self.subTest(reason=reason), tempfile.TemporaryDirectory() as tmp:
                callback = self.host_pressure_callback(reason, admission=True)
                with patch.object(limits, '_check_watchdog_disk_floor', callback), \
                     patch.object(limits.subprocess, 'Popen') as launch:
                    with self.assertRaisesRegex(limits.ContainmentUnavailable, 'monitor_error'):
                        limits.supervise_watchdog(
                            argv=['-c', 'raise SystemExit(99)'],
                            report_path=Path(tmp) / 'watchdog.json', wall_seconds=10,
                            memory_limit_bytes=64 * 1024**2, max_tasks=4)
                launch.assert_not_called()
                report = json.loads((Path(tmp) / 'watchdog.json').read_text())
                self.assertEqual(report['error'], 'Host pressure safety stop: ' + reason)
                self.assertNotIn('child_pid', report)
                self.assertTrue(report['host_pressure_guard']['stopped'])

    def test_runtime_pressure_policy_preserves_other_failures(self):
        errors = [limits._DiskFloorReached('Host pressure safety stop: host_ram_stop_reserve'),
                  limits.ContainmentUnavailable('Cannot measure free disk space'),
                  limits.ContainmentUnavailable('Host pressure observation failed: denied'),
                  OSError('disk I/O'), RuntimeError('unknown callback failure')]
        for error in errors:
            with self.subTest(error=repr(error)):
                # A stale previous pressure observation must not hide a new failure.
                report = {'child_pid': 123, 'host_pressure_guard': {
                    'last_check': 'runtime', 'stopped': True,
                    'stop_reason': 'host_ram_stop_reserve'}}
                with patch.object(limits, '_check_watchdog_disk_floor', side_effect=error):
                    with self.assertRaises(type(error)) as caught:
                        limits._check_watchdog_runtime(report)
                self.assertIs(caught.exception, error)
        for child in (None, 123):
            report = {'host_pressure_guard': {'last_check': 'admission', 'stopped': True,
                                             'stop_reason': 'host_ram_stop_reserve'}}
            if child is not None:
                report['child_pid'] = child
            error = limits.ContainmentUnavailable('Host pressure safety stop: host_ram_stop_reserve')
            with patch.object(limits, '_check_watchdog_disk_floor', side_effect=error):
                with self.assertRaises(limits.ContainmentUnavailable):
                    limits._check_watchdog_runtime(report)

    def test_runtime_pressure_does_not_stop_a_started_child(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'watchdog.json'
            callback = self.host_pressure_callback('host_memory_pressure')
            with patch.object(limits, '_check_watchdog_disk_floor', callback):
                status = limits.supervise_watchdog(
                    argv=['-c', 'import time, build_resource_limits as l; assert l.inside_watchdog(); time.sleep(0.3)'],
                    report_path=path, wall_seconds=10,
                    memory_limit_bytes=64 * 1024**2, max_tasks=4)
            report = json.loads(path.read_text())
            self.assertEqual(status, 0)
            self.assertEqual(report['termination_reason'], 'child_exit')
            self.assertFalse(report['host_pressure_guard']['stopped'])
            self.assertEqual(report['guardian_exit_status'], 0)

    def test_runtime_pressure_does_not_weaken_own_memory_cap(self):
        original_sample = limits._owned_sample

        def over_budget(*args, **kwargs):
            sample = original_sample(*args, **kwargs)
            return {**sample, 'pss_bytes': 65 * 1024**2}

        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'watchdog.json'
            callback = self.host_pressure_callback('host_ram_stop_reserve')
            with patch.object(limits, '_check_watchdog_disk_floor', callback), \
                 patch.object(limits, '_owned_sample', side_effect=over_budget):
                with self.assertRaisesRegex(limits.ContainmentUnavailable, 'sampled_pss_limit'):
                    limits.supervise_watchdog(
                        argv=['-c', 'import time; time.sleep(5)'],
                        report_path=path, wall_seconds=10,
                        memory_limit_bytes=64 * 1024**2, max_tasks=4)
            report = json.loads(path.read_text())
            self.assertEqual(report['termination_reason'], 'sampled_pss_limit')
            self.assertEqual(report['memory_limit_bytes'], 64 * 1024**2)
            self.assertFalse(report['host_pressure_guard']['stopped'])
            self.assertFalse(Path('/proc', str(report['child_pid'])).exists())

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
        for requested,inherited,expected in [(None,0,15),(None,15,19),(None,19,19),(0,0,0),(15,0,15),(15,15,15),(19,15,19)]:
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
        expected=min(19,inherited+15)
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


if __name__ == '__main__':
    unittest.main()
