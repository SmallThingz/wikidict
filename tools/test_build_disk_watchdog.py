import contextlib
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import build_resource_limits as limits
import build_wiktionaries as builder


class DiskWatchdogTest(unittest.TestCase):
    def temp(self):
        root = Path(os.environ.get('WIKIDICT_DISK_TEST_ROOT', '.tmp/disk-watchdog-tests'))
        root.mkdir(parents=True, exist_ok=True)
        return tempfile.TemporaryDirectory(dir=root)

    def report(self, path, floor=8192):
        return {'disk_floor_bytes': floor, 'disk_space': limits._watchdog_disk_roots((path,))}

    def test_missing_output_uses_existing_ancestor_without_creating_it(self):
        with self.temp() as tmp:
            missing = Path(tmp) / 'missing' / 'output'
            records = limits._watchdog_disk_roots((missing, Path(tmp)))
            self.assertEqual(records, [{'path': str(Path(tmp).resolve()), 'device': Path(tmp).stat().st_dev}])
            self.assertFalse(missing.parent.exists())
            regular = Path(tmp) / 'file'
            regular.write_bytes(b'')
            with self.assertRaisesRegex(limits.ContainmentUnavailable, 'not a directory'):
                limits._watchdog_disk_roots((regular,))
        with self.assertRaisesRegex(limits.ContainmentUnavailable, 'At least one'):
            limits._watchdog_disk_roots(())

    def test_reserve_boundary_uses_unprivileged_available_blocks_and_records_low_water(self):
        with self.temp() as tmp:
            report = self.report(tmp)
            # f_bfree deliberately cannot fund the reserve: only f_bavail can.
            with patch.object(limits.os, 'statvfs', return_value=SimpleNamespace(f_bavail=2, f_bfree=900, f_frsize=4096)):
                limits._check_watchdog_disk_floor(report)
            self.assertEqual(report['disk_space'][0]['available_bytes'], 8192)
            with patch.object(limits.os, 'statvfs', return_value=SimpleNamespace(f_bavail=1, f_bfree=900, f_frsize=4096)):
                with self.assertRaisesRegex(limits._DiskFloorReached, '4096 bytes available, 8192 bytes required'):
                    limits._check_watchdog_disk_floor(report)
            with patch.object(limits.os, 'statvfs', return_value=SimpleNamespace(f_bavail=8, f_bfree=900, f_frsize=4096)):
                limits._check_watchdog_disk_floor(report)
            self.assertEqual(report['disk_space'][0]['available_bytes'], 32768)
            self.assertEqual(report['disk_space'][0]['minimum_available_bytes'], 4096)

    def test_second_filesystem_cannot_borrow_first_filesystem_free_space(self):
        with self.temp() as tmp:
            first, second = Path(tmp) / 'first', Path(tmp) / 'second'
            first.mkdir()
            second.mkdir()
            original = Path.stat
            def filesystem_stat(path, *args, **kwargs):
                info = original(path, *args, **kwargs)
                return SimpleNamespace(st_mode=info.st_mode, st_dev=1 if path == first else 2)
            with patch.object(Path, 'stat', filesystem_stat):
                records = limits._watchdog_disk_roots((first, second))
                self.assertEqual(len(records), 2)
                def free(path):
                    return SimpleNamespace(f_bavail=100 if path == first else 0, f_frsize=4096)
                report = {'disk_floor_bytes': 8192, 'disk_space': records}
                with patch.object(limits.os, 'statvfs', side_effect=free):
                    with self.assertRaisesRegex(limits._DiskFloorReached, 'second'):
                        limits._check_watchdog_disk_floor(report)

    def test_filesystem_replacement_or_measurement_error_fails_closed(self):
        with self.temp() as tmp:
            report = self.report(tmp)
            with patch.object(limits.os, 'statvfs', side_effect=PermissionError('fixture')):
                with self.assertRaisesRegex(limits.ContainmentUnavailable, 'Cannot measure free disk'):
                    limits._check_watchdog_disk_floor(report)
            report['disk_space'][0]['device'] += 1
            with patch.object(limits.os, 'statvfs') as measure:
                with self.assertRaisesRegex(limits.ContainmentUnavailable, 'filesystem changed'):
                    limits._check_watchdog_disk_floor(report)
                measure.assert_not_called()

    def test_invalid_reserve_fails_before_any_child_launch(self):
        with patch.object(limits.subprocess, 'Popen') as launch:
            for value in (0, -1, True, 1.5, float('inf')):
                with self.subTest(value=value), self.assertRaisesRegex(limits.ContainmentUnavailable, 'disk reserve'):
                    limits.supervise_watchdog(disk_floor_bytes=value)
            launch.assert_not_called()

    def test_floor_already_spent_refuses_before_guardian_or_build_launch(self):
        with self.temp() as tmp:
            report_path = Path(tmp) / 'watchdog.json'
            with patch.object(limits.os, 'statvfs', return_value=SimpleNamespace(f_bavail=0, f_frsize=4096)), \
                 patch.object(limits.subprocess, 'Popen') as launch:
                with self.assertRaisesRegex(limits.ContainmentUnavailable, 'disk_free_floor'):
                    limits.supervise_watchdog(argv=['-B', '-c', 'raise SystemExit(99)'],
                        report_path=report_path, disk_paths=(tmp,), disk_floor_bytes=8192)
            launch.assert_not_called()
            report = json.loads(report_path.read_text())
            self.assertEqual(report['termination_reason'], 'disk_free_floor')
            self.assertEqual(report['disk_space'][0]['minimum_available_bytes'], 0)
            self.assertIsNone(report['child_exit_status'])

    def test_cli_covers_project_scratch_and_explicit_output_filesystem(self):
        with self.temp() as tmp:
            project = Path(tmp) / 'project'
            output = Path(tmp) / 'separate-output'
            project.mkdir()
            for option in ('--output', '--out'):
                with self.subTest(option=option), \
                     patch.object(builder, 'PROJECT', project), \
                     patch.object(sys, 'argv', ['build_wiktionaries.py', '--resource-mode=watchdog', option, str(output)]), \
                     patch.object(limits, 'inside_watchdog', return_value=False), \
                     patch.object(limits, 'supervise_watchdog', return_value=0) as launch:
                    with self.assertRaises(SystemExit) as stopped:
                        builder.cli()
                    self.assertEqual(stopped.exception.code, 0)
                    launch.assert_called_once_with(wall_seconds=7200, disk_paths=(project / '.tmp', output))

    def test_floor_crossing_reaps_owned_python_child_and_leaves_existing_child_alive(self):
        # Only Python fixtures are launched; no compiler, native build, or corpus input.
        with self.temp() as tmp:
            tmp = Path(tmp)
            report_path, ready = tmp / 'watchdog.json', tmp / 'ready'
            unrelated = subprocess.Popen([sys.executable, '-B', '-c', 'import time; time.sleep(10)'],
                                         start_new_session=True)
            child_code = (
                'import time; from pathlib import Path; '
                f'Path({str(ready)!r}).write_text("ready"); time.sleep(10)'
            )
            def free(_path):
                return SimpleNamespace(f_bavail=1 if ready.exists() else 16, f_frsize=4096)
            try:
                with patch.object(limits.os, 'statvfs', side_effect=free):
                    with self.assertRaisesRegex(limits.ContainmentUnavailable, 'disk_free_floor'):
                        limits.supervise_watchdog(argv=['-B', '-c', child_code], report_path=report_path,
                            wall_seconds=5, memory_limit_bytes=128 * 1024**2, max_tasks=8,
                            max_cpus=1, disk_paths=(tmp,), disk_floor_bytes=8192)
                report = json.loads(report_path.read_text())
                self.assertEqual(report['termination_reason'], 'disk_free_floor')
                self.assertLess(report['child_exit_status'], 0)
                self.assertEqual(report['guardian_exit_status'], 0)
                self.assertFalse(Path('/proc', str(report['child_pid'])).exists())
                self.assertFalse(Path('/proc', str(report['guardian_pid'])).exists())
                self.assertIsNone(unrelated.poll())
                self.assertEqual(report['disk_space'][0]['minimum_available_bytes'], 4096)
            finally:
                unrelated.terminate()
                unrelated.wait(timeout=2)


if __name__ == '__main__':
    unittest.main()
