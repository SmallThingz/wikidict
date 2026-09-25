import contextlib
import io
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

import build_resource_limits as limits
import build_wiktionaries as builder


class ResourceLimitsTest(unittest.TestCase):
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


if __name__ == '__main__':
    unittest.main()
