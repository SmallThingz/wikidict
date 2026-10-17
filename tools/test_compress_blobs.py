#!/usr/bin/env python3
"""Large-XZ concurrency and failure regression tests."""
import importlib.util
import lzma
from pathlib import Path
import subprocess
import tempfile
import threading
import time
import unittest
from unittest import mock

MODULE = Path(__file__).with_name('compress_blobs.py')
spec = importlib.util.spec_from_file_location('compress_blobs_under_test', MODULE)
compress_blobs = importlib.util.module_from_spec(spec)
spec.loader.exec_module(compress_blobs)


class LargeXzWaveTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.paths = [self.root / f'{index}.wikblb' for index in range(3)]
        self.sources = {}
        for index, path in enumerate(self.paths):
            data = b'WIKBLB08' + bytes([index + 1]) + bytes([65 + index]) * 131072
            path.write_bytes(data)
            self.sources[path] = data
        self.worker_count = mock.patch.object(compress_blobs, 'max_workers', return_value=4)
        self.worker_count.start()
        self.addCleanup(self.worker_count.stop)

    def fake_xz(self, *, corrupt=None, fail=None):
        guard = threading.Lock()
        state = {'active': 0, 'peak': 0, 'calls': []}
        first_pair = threading.Barrier(2)

        def invoke(argv, *, stdin, stdout, check):
            self.assertTrue(check)
            self.assertEqual(argv[:3], ['xz', '-0', '--threads=2'])
            self.assertIn('--memlimit-compress=2147483648', argv)
            self.assertIn('--no-adjust', argv)
            self.assertIn('--stdout', argv)
            path = Path(stdin.name)
            with guard:
                state['active'] += 1
                state['peak'] = max(state['peak'], state['active'])
                state['calls'].append(path)
                call_number = len(state['calls'])
            try:
                if call_number <= 2:
                    first_pair.wait(timeout=2)
                time.sleep(0.02)
                if path == fail:
                    raise subprocess.CalledProcessError(1, argv)
                stdout.write(b'corrupt xz' if path == corrupt else lzma.compress(stdin.read(), preset=0))
            finally:
                with guard:
                    state['active'] -= 1
        return invoke, state

    def invoke(self):
        compress_blobs.compress_many(self.paths, 64 * 1024, workers=4, small_limit=1)

    def assert_clean_parts(self):
        self.assertEqual(list(self.root.glob('*.part')), [])

    def test_dynamic_two_encoder_success_and_serial_round_trip(self):
        fake, state = self.fake_xz()
        with mock.patch.object(compress_blobs.subprocess, 'run', side_effect=fake):
            self.invoke()
        self.assertEqual(len(state['calls']), 3)
        self.assertEqual(state['peak'], 2)
        for path, original in self.sources.items():
            self.assertFalse(path.exists())
            self.assertEqual(lzma.decompress(Path(str(path) + '.xz').read_bytes()), original)
        self.assert_clean_parts()

    def test_corrupt_output_keeps_all_raw_and_removes_parts(self):
        fake, _ = self.fake_xz(corrupt=self.paths[1])
        with mock.patch.object(compress_blobs.subprocess, 'run', side_effect=fake):
            with self.assertRaises((lzma.LZMAError, EOFError)):
                self.invoke()
        for path, original in self.sources.items():
            self.assertEqual(path.read_bytes(), original)
            self.assertFalse(Path(str(path) + '.xz').exists())
        self.assert_clean_parts()

    def test_encoder_failure_joins_and_keeps_all_raw(self):
        fake, state = self.fake_xz(fail=self.paths[1])
        with mock.patch.object(compress_blobs.subprocess, 'run', side_effect=fake):
            with self.assertRaises(subprocess.CalledProcessError):
                self.invoke()
        self.assertEqual(state['active'], 0)
        for path, original in self.sources.items():
            self.assertEqual(path.read_bytes(), original)
            self.assertFalse(Path(str(path) + '.xz').exists())
        self.assert_clean_parts()


class SmallXzBatchCleanupTests(unittest.TestCase):
    """Ordinary cleanup errors must retain every already-verified recovery copy."""

    setUp = LargeXzWaveTests.setUp
    assert_clean_parts = LargeXzWaveTests.assert_clean_parts

    def fake_batch_xz(self, *, corrupt=None):
        def invoke(argv, *, check):
            self.assertTrue(check)
            self.assertEqual(argv[:3], ['xz', '-0', '--threads=1'])
            self.assertIn('--keep', argv)
            self.assertEqual([Path(value) for value in argv[5:]], self.paths)
            for path in self.paths:
                target = Path(str(path) + '.xz')
                with target.open('xb') as out:
                    out.write(b'corrupt xz' if path == corrupt else
                              lzma.compress(path.read_bytes(), preset=0))
        return invoke

    def test_later_raw_unlink_failure_retains_all_verified_recovery_copies(self):
        real_unlink = Path.unlink
        failed = False

        def unlink(path, *args, **kwargs):
            nonlocal failed
            if path == self.paths[1] and not failed:
                failed = True
                raise PermissionError('injected later raw cleanup failure')
            return real_unlink(path, *args, **kwargs)

        with mock.patch.object(compress_blobs.subprocess, 'run',
                               side_effect=self.fake_batch_xz()), \
             mock.patch.object(compress_blobs, 'verify_round_trip',
                               wraps=compress_blobs.verify_round_trip) as verified, \
             mock.patch.object(Path, 'unlink', autospec=True, side_effect=unlink):
            with self.assertRaisesRegex(PermissionError, 'later raw cleanup failure'):
                compress_blobs.compress_many(self.paths, 64 * 1024, workers=1)
        self.assertTrue(failed)
        self.assertEqual(verified.call_count, len(self.paths))
        self.assertFalse(self.paths[0].exists())
        for path in self.paths[1:]:
            self.assertEqual(path.read_bytes(), self.sources[path])
        for path, original in self.sources.items():
            self.assertEqual(lzma.decompress(Path(str(path) + '.xz').read_bytes()), original)
        self.assert_clean_parts()

    def test_verification_failure_still_removes_new_outputs_and_keeps_all_raw(self):
        with mock.patch.object(compress_blobs.subprocess, 'run',
                               side_effect=self.fake_batch_xz(corrupt=self.paths[1])):
            with self.assertRaises((lzma.LZMAError, EOFError)):
                compress_blobs.compress_many(self.paths, 64 * 1024, workers=1)
        for path, original in self.sources.items():
            self.assertEqual(path.read_bytes(), original)
            self.assertFalse(Path(str(path) + '.xz').exists())
        self.assert_clean_parts()


if __name__ == '__main__':
    unittest.main()
