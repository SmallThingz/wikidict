"""Negative custody tests; all mutations are inside fresh temporary fixtures."""

import hashlib
import os
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from owned_file_retirement import (ExactFileRetirement, RetirementError,
                                   file_identity, file_stamp, verify_retired_files,
                                   verify_source_proof)


class RetirementTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(dir=Path.cwd() / ".tmp")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.parent = self.root / "owned"
        self.parent.mkdir()
        self.first = self.parent / "first.json"
        self.second = self.parent / "second.json"
        self.keeper = self.root / "keeper.gz"
        self.first.write_bytes(b"first original")
        self.second.write_bytes(b"second original")
        self.keeper.write_bytes(b"retained recovery")

    def row(self, path):
        body = path.read_bytes()
        return {"path": str(path), "bytes": len(body),
                "sha256": hashlib.sha256(body).hexdigest(),
                "stamp": file_stamp(path.lstat())}

    def transaction(self):
        return ExactFileRetirement(self.root, [self.row(self.first), self.row(self.second)],
                                   [self.row(self.keeper)])

    def assert_originals(self):
        self.assertEqual(self.first.read_bytes(), b"first original")
        self.assertEqual(self.second.read_bytes(), b"second original")
        self.assertEqual(self.keeper.read_bytes(), b"retained recovery")

    def test_exact_names_only_and_no_sibling_enumeration(self):
        siblings = []
        for n in range(128):
            p = self.parent / ("unselected-%03d" % n)
            p.write_bytes(str(n).encode())
            siblings.append((p, self.row(p)))
        actual_unlink = os.unlink
        calls = []

        def checked_unlink(name, *, dir_fd):
            calls.append((name, os.fstat(dir_fd).st_ino))
            self.assertIn(name, (self.first.name, self.second.name))
            self.assertEqual(os.fstat(dir_fd).st_ino, self.parent.stat().st_ino)
            actual_unlink(name, dir_fd=dir_fd)

        with mock.patch("os.listdir", side_effect=AssertionError("no listing")), \
             mock.patch("os.scandir", side_effect=AssertionError("no scan")), \
             mock.patch("os.unlink", side_effect=checked_unlink):
            with self.transaction() as operation:
                removed = operation.unlink(lambda: None)
                self.assertEqual(len(removed), 2)
        self.assertEqual([name for name, _ in calls], [self.first.name, self.second.name])
        for p, original in siblings:
            self.assertEqual(self.row(p), original)
        self.assertEqual(self.keeper.read_bytes(), b"retained recovery")

    def test_bad_second_hash_removes_nothing(self):
        rows = [self.row(self.first), self.row(self.second)]
        rows[1]["sha256"] = "0" * 64
        with self.assertRaises(RetirementError):
            with ExactFileRetirement(self.root, rows, [self.row(self.keeper)]):
                self.fail("must reject before unlink")
        self.assert_originals()

    def test_failed_preparation_cannot_be_silently_reused(self):
        rows = [self.row(self.first), self.row(self.second)]
        rows[1]["sha256"] = "0" * 64
        operation = ExactFileRetirement(self.root, rows)
        with self.assertRaises(RetirementError):
            operation.prepare()
        with self.assertRaises(RetirementError):
            operation.prepare()
        self.assert_originals()

    def test_traversal_and_outside_paths_are_rejected(self):
        row = self.row(self.first)
        for path in [str(self.parent / ".." / "owned" / "first.json"),
                     str(self.root) + "//owned/first.json", "/etc/passwd"]:
            with self.subTest(path=path), self.assertRaises(RetirementError):
                with ExactFileRetirement(self.root, [dict(row, path=path)]):
                    self.fail("unsafe path")
        self.assert_originals()

    def test_symlink_parent_is_rejected(self):
        alias = self.root / "alias"
        alias.symlink_to(self.parent, target_is_directory=True)
        row = dict(self.row(self.first), path=str(alias / self.first.name))
        with self.assertRaises(OSError):
            with ExactFileRetirement(self.root, [row]):
                self.fail("symlink parent")
        self.assert_originals()

    def test_selected_symlink_is_rejected(self):
        row = self.row(self.first)
        self.first.unlink()
        self.first.symlink_to(self.keeper)
        with self.assertRaises(OSError):
            with ExactFileRetirement(self.root, [row]):
                self.fail("symlink file")
        self.assertTrue(self.first.is_symlink())
        self.assertEqual(self.keeper.read_bytes(), b"retained recovery")

    def test_directory_and_fifo_are_rejected_without_blocking(self):
        for name, create in [("directory", lambda p: p.mkdir()),
                             ("fifo", lambda p: os.mkfifo(p))]:
            p = self.parent / name
            create(p)
            stamp = file_stamp(p.lstat())
            row = {"path": str(p), "stamp": stamp, "bytes": stamp[4], "sha256": "0" * 64}
            with self.subTest(name=name), self.assertRaises(RetirementError):
                with ExactFileRetirement(self.root, [row]):
                    self.fail("not regular")
            self.assertTrue(p.exists())

    def test_hardlinked_selected_file_is_rejected(self):
        os.link(self.first, self.parent / "alias")
        with self.assertRaises(RetirementError):
            with self.transaction():
                self.fail("selected alias")
        self.assert_originals()

    def test_duplicate_selection_is_rejected(self):
        row = self.row(self.first)
        with self.assertRaises(RetirementError):
            ExactFileRetirement(self.root, [row, row])
        self.assert_originals()

    def test_selected_keeper_overlap_is_rejected(self):
        row = self.row(self.first)
        with self.assertRaises(RetirementError):
            ExactFileRetirement(self.root, [row], [row])
        self.assert_originals()

    def test_name_replacement_after_prepare_is_preserved(self):
        with self.transaction() as operation:
            self.first.rename(self.parent / "original-moved")
            self.first.write_bytes(b"replacement")
            with self.assertRaises(RetirementError):
                operation.unlink(lambda: None)
            self.assertEqual(operation.removed, [])
        self.assertEqual(self.first.read_bytes(), b"replacement")
        self.assertEqual(self.second.read_bytes(), b"second original")

    def test_parent_replacement_after_prepare_is_preserved(self):
        with self.transaction() as operation:
            moved = self.root / "moved"
            self.parent.rename(moved)
            self.parent.mkdir()
            self.first.write_bytes(b"replacement")
            with self.assertRaises(RetirementError):
                operation.unlink(lambda: None)
            self.assertEqual(operation.removed, [])
        self.assertEqual((moved / self.first.name).read_bytes(), b"first original")
        self.assertEqual(self.first.read_bytes(), b"replacement")

    def test_keeper_change_aborts_before_unlink(self):
        with self.transaction() as operation:
            self.keeper.write_bytes(b"changed")
            with self.assertRaises(RetirementError):
                operation.unlink(lambda: None)
            self.assertEqual(operation.removed, [])
        self.assertTrue(self.first.exists() and self.second.exists())

    def test_proof_failure_aborts_before_unlink(self):
        def fail():
            raise RuntimeError("source or recovery proof changed")
        with self.transaction() as operation:
            with self.assertRaises(RuntimeError):
                operation.unlink(fail)
            self.assertEqual(operation.removed, [])
        self.assert_originals()

    def test_second_file_changes_after_first_unlink_stops_exactly(self):
        calls = 0
        def guard():
            nonlocal calls
            calls += 1
            if calls == 2:
                self.second.write_bytes(b"changed")
        with self.transaction() as operation:
            with self.assertRaises(RetirementError):
                operation.unlink(guard)
            self.assertEqual([r["path"] for r in operation.removed], [str(self.first)])
        self.assertFalse(self.first.exists())
        self.assertEqual(self.second.read_bytes(), b"changed")

    def test_recreated_selected_name_is_preserved_and_not_retried(self):
        real_unlink = os.unlink
        def recreate(name, *, dir_fd):
            real_unlink(name, dir_fd=dir_fd)
            self.first.write_bytes(b"new owner")
        with self.transaction() as operation:
            with mock.patch("os.unlink", side_effect=recreate), self.assertRaises(RetirementError):
                operation.unlink(lambda: None)
            self.assertEqual(len(operation.removed), 1)
            with self.assertRaises(RetirementError):
                operation.unlink(lambda: None)
        self.assertEqual(self.first.read_bytes(), b"new owner")
        self.assertEqual(self.second.read_bytes(), b"second original")

    def test_later_recreation_stops_before_the_next_unlink(self):
        calls = 0
        def guard():
            nonlocal calls
            calls += 1
            if calls == 2:
                self.first.write_bytes(b"new owner")
        with self.transaction() as operation:
            with self.assertRaises(RetirementError):
                operation.unlink(guard)
            self.assertEqual(len(operation.removed), 1)
        self.assertEqual(self.first.read_bytes(), b"new owner")
        self.assertEqual(self.second.read_bytes(), b"second original")

    def test_final_fsync_failure_keeps_all_successful_unlinks_in_receipt(self):
        with self.transaction() as operation:
            with mock.patch("os.fsync", side_effect=OSError("disk error")), \
                 self.assertRaises(RetirementError):
                operation.unlink(lambda: None)
            self.assertEqual([r["path"] for r in operation.removed],
                             [str(self.first), str(self.second)])
            self.assertEqual(len(operation.durability_failures), 1)
            self.assertEqual(operation.synced_parents, [])
        self.assertFalse(self.first.exists() or self.second.exists())

    def test_one_flush_per_dirty_parent_and_actual_allocation(self):
        expected = {str(p): p.stat().st_blocks * 512 for p in (self.first, self.second)}
        actual_fsync = os.fsync
        flushed = []

        def flush(fd):
            flushed.append(os.fstat(fd).st_ino)
            actual_fsync(fd)

        with self.transaction() as operation, mock.patch("os.fsync", side_effect=flush):
            removed = operation.unlink(lambda: None)
            self.assertEqual(operation.synced_parents, [str(self.parent)])
            self.assertEqual(operation.durability_failures, [])
        self.assertEqual(flushed, [self.parent.stat().st_ino])
        self.assertEqual({r["path"]: r["allocated_bytes_before_unlink"] for r in removed}, expected)

    def test_partial_proof_failure_flushes_the_successful_unlink(self):
        actual_fsync = os.fsync
        calls = 0
        flushed = []

        def guard():
            nonlocal calls
            calls += 1
            if calls == 2:
                raise RuntimeError("later proof failed")

        def flush(fd):
            flushed.append(os.fstat(fd).st_ino)
            actual_fsync(fd)

        with self.transaction() as operation, mock.patch("os.fsync", side_effect=flush):
            with self.assertRaisesRegex(RuntimeError, "later proof failed"):
                operation.unlink(guard)
            self.assertEqual(len(operation.removed), 1)
            self.assertEqual(operation.synced_parents, [str(self.parent)])
        self.assertEqual(flushed, [self.parent.stat().st_ino])
        self.assertFalse(self.first.exists())
        self.assertTrue(self.second.exists())

    def test_flush_failure_preserves_prior_error_and_attempts_other_parents(self):
        other = self.root / "other"
        other.mkdir()
        third = other / "third.json"
        third.write_bytes(b"third")
        calls = 0
        attempted = []
        actual_fsync = os.fsync

        def guard():
            nonlocal calls
            calls += 1
            if calls == 3:
                raise ValueError("final proof failed")

        def flush(fd):
            inode = os.fstat(fd).st_ino
            attempted.append(inode)
            if inode == self.parent.stat().st_ino:
                raise OSError("first parent failed")
            actual_fsync(fd)

        with ExactFileRetirement(self.root, [self.row(self.first), self.row(third)]) as operation:
            with mock.patch("os.fsync", side_effect=flush), self.assertRaises(RetirementError) as error:
                operation.unlink(guard)
            self.assertIsInstance(error.exception.__cause__, ValueError)
            self.assertEqual(len(operation.removed), 2)
            self.assertEqual(operation.synced_parents, [str(other)])
            self.assertEqual(operation.durability_failures[0]["path"], str(self.parent))
        self.assertEqual(attempted, [self.parent.stat().st_ino, other.stat().st_ino])

    def test_proof_failure_before_any_unlink_does_not_flush(self):
        def fail():
            raise RuntimeError("initial proof failed")
        with self.transaction() as operation, mock.patch("os.fsync") as flush:
            with self.assertRaises(RuntimeError):
                operation.unlink(fail)
            flush.assert_not_called()
            self.assertEqual(operation.removed, [])
        self.assert_originals()

    def test_source_proof_allocation_only_change_is_observational(self):
        row = self.row(self.first)
        actual = row["stamp"][8]
        row["stamp"][8] += 4096
        historical = list(row["stamp"])
        result = verify_source_proof(row)
        self.assertEqual(result["identity"], file_identity(self.first.stat()))
        self.assertEqual(result["observed_allocated_bytes"], actual)
        self.assertEqual(result["sha256"], row["sha256"])
        self.assertEqual(row["stamp"], historical)
        self.assert_originals()

    def test_source_proof_rejects_each_immutable_identity_field(self):
        for index in range(8):
            row = self.row(self.first)
            row["stamp"][index] += 1
            with self.subTest(index=index), self.assertRaises(RetirementError):
                verify_source_proof(row)
        self.assert_originals()

    def test_source_proof_rejects_actual_replacement_metadata_and_content_changes(self):
        def replace(p):
            p.rename(p.with_suffix(".original"))
            p.write_bytes(b"unchanged bytes")

        changes = [replace, lambda p: p.chmod(0o400),
                   lambda p: os.link(p, p.with_suffix(".alias")),
                   lambda p: os.utime(p, ns=(p.stat().st_atime_ns, p.stat().st_mtime_ns + 1)),
                   lambda p: p.write_bytes(b"different bytes")]
        for index, change in enumerate(changes):
            p = self.parent / ("proof-%d" % index)
            p.write_bytes(b"unchanged bytes")
            row = self.row(p)
            change(p)
            with self.subTest(index=index), self.assertRaises(RetirementError):
                verify_source_proof(row)
            self.assertTrue(p.exists())

    def test_source_proof_hash_rejects_changed_bytes_even_with_current_stat(self):
        row = self.row(self.first)
        self.first.write_bytes(b"other original")
        row["stamp"] = file_stamp(self.first.stat())
        row["bytes"] = self.first.stat().st_size
        with self.assertRaisesRegex(RetirementError, "source proof hash changed"):
            verify_source_proof(row)
        self.assertEqual(self.first.read_bytes(), b"other original")

    def test_source_proof_rejects_path_replacement_during_hash(self):
        row = self.row(self.first)
        real_read = os.read
        replaced = False

        def read(fd, size):
            nonlocal replaced
            data = real_read(fd, size)
            if not replaced:
                replaced = True
                self.first.rename(self.parent / "moved-proof")
                self.first.write_bytes(b"first original")
            return data

        with mock.patch("os.read", side_effect=read), self.assertRaises(RetirementError):
            verify_source_proof(row)
        self.assertEqual(self.first.read_bytes(), b"first original")

    def test_selected_and_keeper_block_checks_remain_strict(self):
        for change_keeper in (False, True):
            selected, keeper = self.row(self.first), self.row(self.keeper)
            (keeper if change_keeper else selected)["stamp"][8] += 4096
            with self.subTest(keeper=change_keeper), self.assertRaises(RetirementError):
                with ExactFileRetirement(self.root, [selected], [keeper]):
                    self.fail("selected and keeper stamps must remain exact")
        self.assert_originals()

    def finish(self):
        with self.transaction() as operation:
            selected = operation.unlink(lambda: None)
            return selected, operation.protected, operation.parent_bindings

    def test_independent_closure_needs_no_sibling_inventory(self):
        selected, protected, parents = self.finish()
        unrelated = self.parent / "new-unselected-owner"
        unrelated.write_bytes(b"owned by someone else")
        with mock.patch("os.listdir", side_effect=AssertionError("no listing")), \
             mock.patch("os.scandir", side_effect=AssertionError("no scan")):
            result = verify_retired_files(self.root, selected, protected, parents, lambda: None)
        self.assertEqual(result["selected_absent"], 2)
        self.assertEqual(unrelated.read_bytes(), b"owned by someone else")

    def test_closure_rejects_recreated_name_without_removing_it(self):
        selected, protected, parents = self.finish()
        self.first.write_bytes(b"new file")
        with self.assertRaises(RetirementError):
            verify_retired_files(self.root, selected, protected, parents, lambda: None)
        self.assertEqual(self.first.read_bytes(), b"new file")

    def test_closure_rejects_replaced_parent(self):
        selected, protected, parents = self.finish()
        self.parent.rename(self.root / "old-parent")
        self.parent.mkdir()
        with self.assertRaises(RetirementError):
            verify_retired_files(self.root, selected, protected, parents, lambda: None)

    def test_closure_rejects_changed_keeper(self):
        selected, protected, parents = self.finish()
        self.keeper.write_bytes(b"changed keeper")
        with self.assertRaises(RetirementError):
            verify_retired_files(self.root, selected, protected, parents, lambda: None)
        self.assertEqual(self.keeper.read_bytes(), b"changed keeper")

    def test_closure_rechecks_names_after_final_proof_check(self):
        selected, protected, parents = self.finish()
        calls = 0
        def guard():
            nonlocal calls
            calls += 1
            if calls == 2:
                self.first.write_bytes(b"new owner")
        with self.assertRaises(RetirementError):
            verify_retired_files(self.root, selected, protected, parents, guard)
        self.assertEqual(self.first.read_bytes(), b"new owner")


if __name__ == "__main__":
    unittest.main()
