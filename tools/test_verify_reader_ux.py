#!/usr/bin/env python3
import contextlib
import importlib.util
from pathlib import Path
import signal
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("reader_ux", Path(__file__).with_name("verify_reader_ux.py"))
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

class OwnedReaderTests(unittest.TestCase):
    def setUp(self):
        self.identity = (900, 11, 42, 42, 1000)
        self.stack = contextlib.ExitStack()
        self.addCleanup(self.stack.close)
        self.stack.enter_context(patch.object(m.os, "getpid", return_value=11))
        self.stack.enter_context(patch.object(m.os, "getuid", return_value=1000))
        self.stack.enter_context(patch.object(m.os, "pidfd_open", return_value=73))
        self.closed = self.stack.enter_context(patch.object(m.os, "close"))
        self.read = self.stack.enter_context(patch.object(m, "reader_identity", return_value=self.identity))
        self.sent = self.stack.enter_context(patch.object(m.signal, "pidfd_send_signal"))
        self.groups = self.stack.enter_context(patch.object(m.os, "killpg"))
    def test_owned_signals_use_held_pidfd(self):
        owner = m.OwnedReaderProcess(42)
        for sig in (signal.SIGWINCH, signal.SIGTERM, signal.SIGKILL):
            self.assertTrue(owner.send(sig))
        self.assertEqual([c.args for c in self.sent.call_args_list], [(73, signal.SIGWINCH), (73, signal.SIGTERM), (73, signal.SIGKILL)])
        owner.close()
        self.closed.assert_called_once_with(73)
        self.groups.assert_not_called()
    def test_pid_reuse_never_signals(self):
        owner = m.OwnedReaderProcess(42)
        self.read.return_value = (901, *self.identity[1:])
        self.assertFalse(owner.send(signal.SIGKILL))
        self.sent.assert_not_called()
    def test_wrong_owner_never_signals(self):
        for index in (1, 2, 3, 4):
            identity = list(self.identity); identity[index] += 1
            self.read.return_value = tuple(identity)
            with self.assertRaises(m.CheckFailure): m.OwnedReaderProcess(42)
        self.assertEqual(self.closed.call_count, 4)
        self.sent.assert_not_called()
    def test_owner_change_never_signals(self):
        owner = m.OwnedReaderProcess(42)
        self.read.return_value = (900, 12, 42, 42, 1000)
        self.assertFalse(owner.send(signal.SIGTERM))
        self.sent.assert_not_called()
    def test_disappeared_process_never_signals(self):
        owner = m.OwnedReaderProcess(42)
        self.read.side_effect = FileNotFoundError
        self.assertFalse(owner.send(signal.SIGTERM))
        self.sent.assert_not_called()
    def test_pidfd_exit_race_returns_false(self):
        owner = m.OwnedReaderProcess(42)
        self.sent.side_effect = ProcessLookupError
        self.assertFalse(owner.send(signal.SIGWINCH))

    def test_missing_pidfd_support_refuses_before_launch(self):
        with patch.object(m.signal, "pidfd_send_signal", None):
            # Missing API, rather than a callable failure after launch.
            del m.signal.pidfd_send_signal
            with patch.object(m.subprocess, "Popen") as launch:
                with self.assertRaisesRegex(m.CheckFailure, "pidfd signaling"):
                    m.ReaderPty(None, None, 80, 24, None, 1, 2, None)
                launch.assert_not_called()
    def test_immediate_exit_is_reaped_and_preserved_without_signal(self):
        from types import SimpleNamespace
        root = unittest.mock.MagicMock()
        output = unittest.mock.MagicMock()
        child = unittest.mock.Mock(pid=42)
        child.poll.return_value = 17
        pyte = SimpleNamespace(Screen=lambda *a: object(), Stream=lambda *a: object())
        with patch.object(m.os, "openpty", return_value=(81, 82)), patch.object(m.fcntl, "ioctl"), patch.object(m.termios, "tcgetattr", return_value=[]), patch.object(m.subprocess, "Popen", return_value=child), patch.object(m, "OwnedReaderProcess", side_effect=ProcessLookupError):
            with self.assertRaisesRegex(m.CheckFailure, "returncode=17") as caught:
                m.ReaderPty(Path("/unused"), root, 80, 24, output, 1, 2, pyte)
        child.poll.assert_called_once_with()
        self.assertIsInstance(caught.exception.__cause__, ProcessLookupError)
        self.closed.assert_has_calls([unittest.mock.call(81), unittest.mock.call(82)])
        self.sent.assert_not_called()
        self.groups.assert_not_called()


if __name__ == "__main__":
    unittest.main()
