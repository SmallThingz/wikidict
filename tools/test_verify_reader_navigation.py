#!/usr/bin/env python3
"""Host-only isolation and process-custody controls; no Reader binary is run."""
import contextlib
import hashlib
import io
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

import verify_reader_navigation as navigation
from verify_reader_ux import CheckFailure


class NavigationIsolationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name)
        self.source = self.base / "fixture"
        self.source.mkdir()
        (self.source / ".reader-fixture").write_text("owned test fixture\n")
        (self.source / "languages.tsv").write_text("English\ten\n")
        (self.source / "languages").mkdir()
        (self.source / "languages" / "english.wikblb").write_bytes(b"fixture bytes")
        for directory in (".dict-state", ".dict-cache", ".dict-media"):
            (self.source / directory).mkdir()
            (self.source / directory / "keep.json").write_text('{"original":true}\n')
        self.report = self.base / "report"
        self.binary = Path(sys.executable).resolve()
        self.before = self.snapshot()

    def snapshot(self):
        return {str(p.relative_to(self.source)): (
            p.stat().st_ino, p.stat().st_mtime_ns, p.stat().st_mode,
            hashlib.sha256(p.read_bytes()).hexdigest())
            for p in self.source.rglob("*") if p.is_file()}

    def assert_source_unchanged(self):
        self.assertEqual(self.before, self.snapshot())

    def test_each_width_uses_an_independent_copy_and_private_state(self):
        roots = []

        def exercise(binary, root, report, cols, rows):
            self.assertEqual(binary, self.binary)
            self.assertNotEqual(root, self.source)
            self.assertTrue(root.is_relative_to(report))
            roots.append(root)
            for directory in (".dict-state", ".dict-cache", ".dict-media"):
                self.assertFalse((root / directory).exists())
            env = navigation.reader_environment(root)
            for key in ("HOME", "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_CACHE_HOME",
                        "XDG_STATE_HOME", "XDG_RUNTIME_DIR"):
                target = Path(env[key])
                self.assertEqual(target.parent, root.parent)
                self.assertEqual(target.stat().st_mode & 0o777, 0o700)
            self.assertEqual(env["DICT_ROOT"], str(root))
            (root / "languages" / "english.wikblb").write_bytes(b"private mutation")
            (root / ".dict-state").mkdir()
            (root / ".dict-state" / "reader.json").write_text(
                json.dumps(dict(saved=["elephant"], history_limit=200)))

        with mock.patch.object(navigation, "run_owned", side_effect=exercise) as run:
            with contextlib.redirect_stdout(io.StringIO()) as output:
                self.assertEqual(navigation.main([
                    "--binary", str(self.binary), "--root", str(self.source),
                    "--report", str(self.report)]), 0)
        self.assertEqual([(c.args[3], c.args[4]) for c in run.call_args_list],
                         [(40, 24), (80, 30), (120, 40)])
        self.assertEqual(len(set(roots)), 3)
        self.assertTrue(all(not root.parent.exists() for root in roots))
        self.assertIn("TERMINAL_NAVIGATION_PASS widths=40,80,120 persistence=true", output.getvalue())
        self.assert_source_unchanged()

    def test_assertion_failure_removes_only_disposable_copy(self):
        with mock.patch.object(navigation, "run_owned", side_effect=AssertionError("screen mismatch")):
            with self.assertRaisesRegex(AssertionError, "screen mismatch"):
                navigation.run(self.binary, self.source, self.report, 40, 24)
        self.assertEqual(list(self.report.iterdir()), [])
        self.assert_source_unchanged()

    def test_unreaped_child_retains_private_copy(self):
        with mock.patch.object(navigation, "run_owned", side_effect=navigation.ReaderCleanupError("identity refused")):
            with self.assertRaisesRegex(navigation.ReaderCleanupError, "retained at"):
                navigation.run(self.binary, self.source, self.report, 40, 24)
        self.assertEqual(len(list(self.report.glob("navigation-40-*/root/.reader-fixture"))), 1)
        self.assert_source_unchanged()

    def test_persistence_assertions_are_still_required(self):
        def exercise(binary, root, report, cols, rows):
            (root / ".dict-state").mkdir()
            (root / ".dict-state" / "reader.json").write_text(
                json.dumps(dict(saved=["elephant"], history_limit=100)))
        with mock.patch.object(navigation, "run_owned", side_effect=exercise):
            with self.assertRaises(AssertionError):
                navigation.run(self.binary, self.source, self.report, 40, 24)
        self.assertEqual(list(self.report.iterdir()), [])
        self.assert_source_unchanged()

    def test_report_inside_original_is_refused(self):
        with mock.patch.object(navigation, "run_owned") as run:
            with self.assertRaisesRegex(CheckFailure, "outside the original"):
                navigation.run(self.binary, self.source, self.source / "reports", 40, 24)
        run.assert_not_called()
        self.assertFalse((self.source / "reports").exists())
        self.assert_source_unchanged()

    def test_unmarked_fixture_is_refused(self):
        (self.source / ".reader-fixture").unlink()
        with mock.patch.object(navigation, "run_owned") as run:
            with self.assertRaisesRegex(CheckFailure, "unmarked"):
                navigation.run(self.binary, self.source, self.report, 40, 24)
        run.assert_not_called()
        self.assertFalse(self.report.exists())

    def test_symlink_fixture_is_refused_without_touching_target(self):
        outside = self.base / "outside"
        outside.write_text("keep")
        (self.source / "symlink").symlink_to(outside)
        with mock.patch.object(navigation, "run_owned") as run:
            with self.assertRaisesRegex(CheckFailure, "symlink"):
                navigation.run(self.binary, self.source, self.report, 40, 24)
        run.assert_not_called()
        self.assertEqual(outside.read_text(), "keep")
        self.assertEqual(list(self.report.iterdir()), [])


class NavigationCustodyTests(unittest.TestCase):
    def process(self):
        child = mock.Mock()
        child.poll.return_value = None
        return child

    def test_exited_child_needs_no_signal(self):
        child = self.process()
        child.poll.return_value = 1
        navigation.stop_reader(child, None)
        child.wait.assert_not_called()
        child.kill.assert_not_called()

    def test_cleanup_uses_owned_identity_then_bounded_wait(self):
        child, owned = self.process(), mock.Mock()
        child.wait.side_effect = [subprocess.TimeoutExpired("reader", 1), 0]
        navigation.stop_reader(child, owned)
        self.assertEqual(owned.send.call_args_list,
                         [mock.call(signal.SIGTERM), mock.call(signal.SIGKILL)])
        self.assertEqual(child.wait.call_args_list, [mock.call(timeout=1), mock.call(timeout=1)])
        child.kill.assert_not_called()
        child.terminate.assert_not_called()

    def test_identity_refusal_never_falls_back_to_raw_pid(self):
        child, owned = self.process(), mock.Mock()
        owned.send.return_value = False
        child.wait.side_effect = subprocess.TimeoutExpired("reader", 1)
        with self.assertRaisesRegex(navigation.ReaderCleanupError, "unreaped"):
            navigation.stop_reader(child, owned)
        child.kill.assert_not_called()
        child.terminate.assert_not_called()

    def test_uncaptured_owner_is_never_signalled(self):
        child = self.process()
        with self.assertRaisesRegex(navigation.ReaderCleanupError, "no signal"):
            navigation.stop_reader(child, None)
        child.wait.assert_not_called()
        child.kill.assert_not_called()

    def test_launch_failure_closes_both_pty_descriptors(self):
        pyte = mock.Mock()
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "root"
            root.mkdir()
            with mock.patch.dict(sys.modules, pyte=pyte), \
                    mock.patch.object(navigation.pty, "openpty", return_value=(100, 101)), \
                    mock.patch.object(navigation.termios, "tcsetwinsize"), \
                    mock.patch.object(navigation.os, "close") as close, \
                    mock.patch.object(navigation.subprocess, "Popen", side_effect=OSError("launch failed")), \
                    mock.patch.object(navigation, "OwnedReaderProcess") as owned:
                with self.assertRaisesRegex(OSError, "launch failed"):
                    navigation.run_owned(Path("reader"), root, Path(temporary), 40, 24)
            owned.assert_not_called()
            self.assertEqual(close.call_args_list, [mock.call(100), mock.call(101)])

    def test_ownership_capture_failure_preserves_live_child(self):
        pyte, child = mock.Mock(), self.process()
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "root"
            root.mkdir()
            with mock.patch.dict(sys.modules, pyte=pyte), \
                    mock.patch.object(navigation.pty, "openpty", return_value=(100, 101)), \
                    mock.patch.object(navigation.termios, "tcsetwinsize"), \
                    mock.patch.object(navigation.os, "close") as close, \
                    mock.patch.object(navigation.subprocess, "Popen", return_value=child) as launch, \
                    mock.patch.object(navigation, "OwnedReaderProcess", side_effect=CheckFailure("wrong birth")):
                with self.assertRaises(navigation.ReaderCleanupError):
                    navigation.run_owned(Path("reader"), root, Path(temporary), 40, 24)
            self.assertEqual(launch.call_args.kwargs["cwd"], root)
            self.assertTrue(launch.call_args.kwargs["start_new_session"])
            self.assertEqual(launch.call_args.args[0], ["reader", "tui", "elephant", "--root", str(root), "--color", "always"])
            self.assertEqual(close.call_args_list, [mock.call(100), mock.call(101)])
            child.kill.assert_not_called()
            child.terminate.assert_not_called()


if __name__ == "__main__":
    unittest.main()
