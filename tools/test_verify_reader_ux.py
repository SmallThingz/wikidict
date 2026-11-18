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


class EntryFocusTests(unittest.TestCase):
    def test_read_projects_only_frames_with_a_complete_end_marker(self):
        reader = m.ReaderPty.__new__(m.ReaderPty)
        reader.master, reader.raw, reader.frames, reader.projected = 31, bytearray(), 0, 0
        reader.stream = unittest.mock.Mock()
        reader.decoder = m.codecs.getincrementaldecoder('utf-8')('strict')
        data = [b'first' + m.FRAME_END + 'dé'.encode()[:-1], 'é'.encode()[1:] + m.FRAME_END[:-1],
                m.FRAME_END[-1:] + b'third' + m.FRAME_END]
        with patch.object(m.select, 'select', return_value=([31], [], [])), patch.object(m.os, 'read', side_effect=data):
            reader.read()
            reader.stream.feed.assert_called_once_with('first' + m.FRAME_END.decode())
            reader.read()
            self.assertEqual((reader.frames, reader.stream.feed.call_count), (1, 1))
            reader.read()
            reader.stream.feed.assert_called_with('dé' + m.FRAME_END.decode() + 'third' + m.FRAME_END.decode())
        self.assertEqual(reader.frames, 3)
        self.assertEqual(reader.raw, b''.join(data))

    @staticmethod
    def reader(width, footer):
        # A completed terminal screen only: no PTY, subprocess, or signals.
        from types import SimpleNamespace
        reader = m.ReaderPty.__new__(m.ReaderPty)
        reader.width, reader.rows = width, 32
        display = [" " * width for _ in range(reader.rows)]
        display[5] = "  MATCHES  2  |  READING   s to save"
        display[6] = "  cat        |  cat / English"
        display[12] = "             |  1. A small animal."
        display[-2] = ("  " + footer).ljust(width)
        reader.screen = SimpleNamespace(display=display)
        return reader

    def test_complete_reading_footer_tracks_display_width(self):
        compact = "Esc back ↑↓ e fold d details ? help"
        wide = "Esc results  / search  ↑↓ scroll  PgUp/PgDn page  [ ] section  e fold  d all  s save  ? help"
        # 96 is the selected TUI's 92-cell wide hint plus its four-cell margin.
        for width, footer in ((40, compact), (80, compact), (95, compact),
                              (96, wide), (120, wide)):
            with self.subTest(width=width):
                self.assertTrue(self.reader(width, footer).entry_focused())
        self.assertFalse(self.reader(80, wide).entry_focused())
        self.assertFalse(self.reader(120, compact).entry_focused())

    def test_reading_preview_with_body_is_not_entry_focus(self):
        # Search and Matches both have a real READING preview at wide widths.
        # A body/title/READING heading is deliberately present in every screen.
        footers = (
            "type to search  ↑↓ results  Enter read  Tab switch  Ctrl-U clear  Ctrl-C quit",
            "/ search  ↑↓ select  Enter read  PgUp/PgDn page  ? help  q quit",
            "Enter read  Del remove  / search  ? help",
            "Tab game  Esc search  Ctrl-C quit",
        )
        for footer in footers:
            with self.subTest(footer=footer):
                reader = self.reader(120, footer)
                self.assertIn("READING", reader.text())
                self.assertIn("A small animal.", reader.text())
                self.assertFalse(reader.entry_focused())

    def test_partial_misplaced_or_extended_hint_does_not_prove_focus(self):
        compact = "Esc back ↑↓ e fold d details ? help"
        for footer in ("Esc back", compact[:-1], compact + " unexpected"):
            with self.subTest(footer=footer):
                self.assertFalse(self.reader(80, footer).entry_focused())
        self.assertFalse(self.reader(120, "Esc results  / search").entry_focused())
        reader = self.reader(80, "type  ↑↓ select  Enter read  ^C quit")
        reader.screen.display[10] = compact
        self.assertFalse(reader.entry_focused())


if __name__ == "__main__":
    unittest.main()
