"""Retire an exact owned file selection without enumerating its siblings.

The caller must hold the selected owners' exclusive custody locks throughout
preparation, deletion and closure, and establish nonuse and recovery authority.
This module does not grant a release, acquire resource leases, or run a scan.
Zig indexed cache entries are excluded: deleting an output alone can leave a
valid compiler success index pointing at a missing file. Use toolchain-aware
index invalidation and normal rebuilding instead of this file-only API.
Historical receipt files and carrier invocations must remain immutable.

POSIX has no unlink-if-inode operation. The final identity check and unlink
therefore rely on that exclusive custody; this is not protection against an
uncooperative writer racing inside the selected namespace.
"""

import hashlib
import os
import stat
from pathlib import Path


class RetirementError(RuntimeError):
    pass


def file_stamp(value):
    """The existing retirement manifest's nine-field stat representation."""
    return [value.st_dev, value.st_ino, value.st_mode, value.st_uid,
            value.st_size, value.st_mtime_ns, value.st_ctime_ns,
            value.st_nlink, value.st_blocks * 512]


def file_identity(value):
    """Immutable proof identity; allocated blocks are a separate observation."""
    return file_stamp(value)[:8]


def _directory_identity(value):
    return [value.st_dev, value.st_ino, value.st_mode, value.st_uid]


def _require(condition, message):
    if not condition:
        raise RetirementError(message)


def _components(path):
    raw = os.fspath(path)
    _require(isinstance(raw, str) and raw.startswith("/"), "absolute path required")
    parts = raw.split("/")[1:]
    _require(all(p and p not in (".", "..") and "\0" not in p for p in parts),
             "empty or traversing path component")
    return parts


def _reject_zig_indexed_entry(path):
    # Generated outputs and success manifests share this toolchain-defined
    # namespace. Reject it even when the owned root starts inside the entry.
    # No sibling enumeration or guess from the output extension is needed.
    parts = _components(path)
    for kind, name in zip(parts, parts[1:]):
        digest = name.removesuffix(".txt")
        if (kind in ("o", "h") and len(digest) == 32
                and all(c in "0123456789abcdefABCDEF" for c in digest)):
            raise RetirementError("indexed Zig cache entry requires index-coherent retirement")


def _open_directory(parts, base_fd=None):
    """Walk only declared components; reject symlinks at every level."""
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC
    fd = os.open("/", flags) if base_fd is None else os.dup(base_fd)
    try:
        for part in parts:
            next_fd = os.open(part, flags, dir_fd=fd)
            os.close(fd)
            fd = next_fd
        return fd
    except BaseException:
        os.close(fd)
        raise


def verify_source_proof(row):
    """Hash a named source/helper proof without treating block settling as a write.

    Use this at authentication boundaries. Between boundaries, the caller can
    compare ``file_identity`` under its custody locks. This does not relax the
    nine-field checks on selected files or protected recovery/artifact keepers.
    The historical row is never rewritten.
    """
    wanted = row["stamp"]
    _require(len(wanted) == 9 and row["bytes"] == wanted[4],
             "invalid source proof identity")
    parts = _components(row["path"])
    parent_fd = _open_directory(parts[:-1])
    fd = None
    try:
        parent_identity = _directory_identity(os.fstat(parent_fd))
        fd = os.open(parts[-1], os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC | os.O_NONBLOCK,
                     dir_fd=parent_fd)

        def check():
            value = os.fstat(fd)
            _require(stat.S_ISREG(value.st_mode) and value.st_uid == os.getuid(),
                     "source proof is not an owned regular file")
            _require(file_identity(value) == wanted[:8], "source proof identity changed")
            named = os.stat(parts[-1], dir_fd=parent_fd, follow_symlinks=False)
            _require(file_identity(named) == wanted[:8], "source proof pathname changed")
            fresh = _open_directory(parts[:-1])
            try:
                _require(_directory_identity(os.fstat(fresh)) == parent_identity,
                         "source proof parent changed")
            finally:
                os.close(fresh)
            return value

        check()
        digest = hashlib.sha256()
        for block in iter(lambda: os.read(fd, 1024 * 1024), b""):
            digest.update(block)
        value = check()
        _require(digest.hexdigest() == row["sha256"], "source proof hash changed")
        return {"path": row["path"], "identity": file_identity(value),
                "sha256": digest.hexdigest(), "observed_allocated_bytes": value.st_blocks * 512}
    finally:
        if fd is not None:
            os.close(fd)
        os.close(parent_fd)


class ExactFileRetirement:
    """One-use selected-file transaction under externally held custody locks.

    Rows use the existing {path, bytes, sha256, stamp} representation. Protected
    rows are opened and hashed too; keep this list to the actual recovery or
    artifact keepers. Source/nonuse/other proof verification stays in the caller.
    No method mutates an unselected name or a directory. ``removed`` records
    successful unlink calls even if subsequent fsync or verification fails.

    ``complete_alias_groups=True`` accepts hardlinks only when every link to
    each selected inode is named in this transaction. Never split such a group
    across batches. Sum ``retired_inode_allocated_bytes``, not the per-name
    allocation observations, to account for these groups without double counting.
    """

    def __init__(self, root, selected, protected=(), *, complete_alias_groups=False):
        self.root = os.fspath(root)
        self.root_parts = _components(self.root)
        self.selected = [dict(row, stamp=list(row["stamp"])) for row in selected]
        self.protected = [dict(row, stamp=list(row["stamp"])) for row in protected]
        _require(bool(self.selected), "empty selection")
        for row in self.selected:
            _reject_zig_indexed_entry(row["path"])
        rows = self.selected + self.protected
        _require(len({row["path"] for row in rows}) == len(rows), "duplicate path")
        _require(isinstance(complete_alias_groups, bool), "explicit alias policy required")
        self.complete_alias_groups = complete_alias_groups
        self.removed = []
        self.durability_failures = []
        self.synced_parents = []
        self.parent_bindings = []
        self._root_fd = None
        self._parents = {}
        self._files = []
        self._prepared = False
        self._started = False
        self._used = False
        self._alias_transition_failed = False

    def _parent(self, path):
        parts = _components(path)
        _require(parts[:len(self.root_parts)] == self.root_parts and
                 len(parts) > len(self.root_parts), "file outside owned root")
        relative = parts[len(self.root_parts):]
        parent_parts, name = relative[:-1], relative[-1]
        key = tuple(parent_parts)
        if key not in self._parents:
            fd = _open_directory(parent_parts, self._root_fd)
            value = os.fstat(fd)
            if value.st_uid != os.getuid():
                os.close(fd)
                raise RetirementError("parent is not owned")
            parent = {"fd": fd, "parts": parent_parts,
                      "path": str(Path(self.root).joinpath(*parent_parts)),
                      "identity": _directory_identity(value)}
            self._parents[key] = parent
            self.parent_bindings.append({k: parent[k] for k in ("path", "identity")})
        return self._parents[key], name

    def _open_file(self, row, selected):
        _require(len(row["stamp"]) == 9 and row["bytes"] == row["stamp"][4],
                 "invalid recorded identity")
        _require(isinstance(row["sha256"], str) and len(row["sha256"]) == 64 and
                 all(c in "0123456789abcdef" for c in row["sha256"]),
                 "invalid SHA-256")
        parent, name = self._parent(row["path"])
        fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC | os.O_NONBLOCK,
                     dir_fd=parent["fd"])
        bound = {"row": row, "parent": parent, "name": name, "fd": fd,
                 "selected": selected, "expected_stamp": list(row["stamp"])}
        self._files.append(bound)
        value = os.fstat(fd)
        _require(stat.S_ISREG(value.st_mode) and value.st_uid == os.getuid(),
                 "candidate or keeper is not an owned regular file")
        _require(not selected or self.complete_alias_groups or value.st_nlink == 1,
                 "selected file has aliases")
        self._check_file(bound)
        digest = hashlib.sha256()
        for block in iter(lambda: os.read(fd, 1024 * 1024), b""):
            digest.update(block)
        _require(digest.hexdigest() == row["sha256"], "file hash changed")
        self._check_file(bound)

    def _open_root(self):
        self._root_fd = _open_directory(self.root_parts)
        root_stat = os.fstat(self._root_fd)
        _require(root_stat.st_uid == os.getuid(), "root is not owned")
        self._root_identity = _directory_identity(root_stat)

    def prepare(self):
        _require(not self._started, "transaction already used")
        self._started = True
        try:
            self._open_root()
            groups = {}
            for row in self.selected:
                _require(len(row["stamp"]) == 9, "invalid recorded identity")
                groups.setdefault(tuple(row["stamp"][:2]), []).append(row)
            if self.complete_alias_groups:
                for rows in groups.values():
                    first = rows[0]
                    _require(first["stamp"][7] == len(rows), "incomplete alias group")
                    _require(all(row["stamp"] == first["stamp"] and
                                 row["bytes"] == first["bytes"] and
                                 row["sha256"] == first["sha256"] for row in rows),
                             "alias group identities disagree")
            for row in self.protected:
                self._open_file(row, False)
            for row in self.selected:
                self._open_file(row, True)
            selected_ids = {tuple(row["stamp"][:2]) for row in self.selected}
            keeper_ids = {tuple(row["stamp"][:2]) for row in self.protected}
            _require(self.complete_alias_groups or len(selected_ids) == len(self.selected),
                     "selected inode has aliases")
            _require(not selected_ids.intersection(keeper_ids), "selected inode is protected")
            self._check_parents()
            self._prepared = True
            return self
        except BaseException:
            self.close()
            raise

    def _check_parents(self):
        root_fd = _open_directory(self.root_parts)
        try:
            _require(_directory_identity(os.fstat(root_fd)) == self._root_identity,
                     "root binding changed")
        finally:
            os.close(root_fd)
        for parent in self._parents.values():
            _require(_directory_identity(os.fstat(parent["fd"])) == parent["identity"],
                     "owned parent identity changed")
            fd = _open_directory(parent["parts"], self._root_fd)
            try:
                _require(_directory_identity(os.fstat(fd)) == parent["identity"],
                         "parent pathname was replaced")
            finally:
                os.close(fd)

    def _check_file(self, bound):
        wanted = bound["expected_stamp"]
        _require(file_stamp(os.fstat(bound["fd"])) == wanted, "open file identity changed")
        value = os.stat(bound["name"], dir_fd=bound["parent"]["fd"], follow_symlinks=False)
        _require(file_stamp(value) == wanted, "selected or protected pathname changed")

    def _check_absent(self, row):
        parent, name = self._parent(row["path"])
        try:
            os.stat(name, dir_fd=parent["fd"], follow_symlinks=False)
        except FileNotFoundError:
            return
        raise RetirementError("selected name reappeared; replacement was preserved")

    def _advance_alias_group(self, bound, before, removed):
        """Accept only the nlink/ctime transition caused by our successful unlink."""
        self._alias_transition_failed = True
        after = file_stamp(os.fstat(bound["fd"]))
        _require(after[:6] == before[:6] and after[8] == before[8] and
                 after[7] == before[7] - 1 and after[6] >= before[6],
                 "unexpected post-unlink inode change")
        removed["post_unlink_stamp"] = after
        removed["retired_inode_allocated_bytes"] = before[8] if after[7] == 0 else 0
        for other in self._files:
            if other["selected"] and other["row"]["stamp"][:2] == before[:2]:
                other["expected_stamp"] = list(after)
        self._alias_transition_failed = False

    def remaining_selection(self):
        """Return authenticated remaining rows after a durable partial operation.

        Call before close, while custody is still held. A new transaction must
        reauthenticate these rows and all nonuse/recovery proofs; this method
        neither retries an unlink nor rewrites the original selection receipt.
        A post-unlink identity failure or recreated name prevents this export.
        """
        _require(self._prepared and self._used and not self.durability_failures and
                 not self._alias_transition_failed,
                 "remaining selection is not safely exportable")
        self._check_parents()
        removed_paths = {row["path"] for row in self.removed}
        for row in self.removed:
            self._check_absent(row)
        remaining = []
        for bound in self._files:
            if bound["row"]["path"] not in removed_paths:
                self._check_file(bound)
                if bound["selected"]:
                    remaining.append(dict(bound["row"], stamp=list(bound["expected_stamp"])))
        return remaining

    def unlink(self, verify_proofs):
        """Verify caller proofs and every remaining selected/keeper before each unlink."""
        _require(self._prepared and not self._used, "transaction not prepared or already used")
        self._used = True
        removed_paths = set()
        dirty_parents = {}
        failure = None
        try:
            for bound in self._files:
                if not bound["selected"]:
                    continue
                verify_proofs()
                self._check_parents()
                for row in self.removed:
                    self._check_absent(row)
                for other in self._files:
                    if other["row"]["path"] not in removed_paths:
                        self._check_file(other)
                observed = file_stamp(os.fstat(bound["fd"]))
                _require(observed == bound["expected_stamp"], "pre-unlink identity changed")
                os.unlink(bound["name"], dir_fd=bound["parent"]["fd"])
                removed = dict(bound["row"], pre_unlink_stamp=observed,
                               allocated_bytes_before_unlink=observed[8],
                               retired_inode_allocated_bytes=0 if self.complete_alias_groups else observed[8])
                self.removed.append(removed)
                removed_paths.add(bound["row"]["path"])
                dirty_parents[bound["parent"]["path"]] = bound["parent"]
                if self.complete_alias_groups:
                    self._advance_alias_group(bound, observed, removed)
                self._check_absent(bound["row"])
            verify_proofs()
            self._check_parents()
            for row in self.removed:
                self._check_absent(row)
            for bound in self._files:
                if not bound["selected"]:
                    self._check_file(bound)
            return list(self.removed)
        except BaseException as error:
            failure = error
            raise
        finally:
            # Persist every successful unlink, including a partial transaction.
            # Attempt all dirty parents even if an earlier flush fails.
            for parent in dirty_parents.values():
                try:
                    os.fsync(parent["fd"])
                    self.synced_parents.append(parent["path"])
                except BaseException as error:
                    self.durability_failures.append({"path": parent["path"],
                                                     "error": repr(error)})
            if self.durability_failures:
                raise RetirementError("directory durability failed: " +
                                      repr(self.durability_failures)) from failure

    def close(self):
        for bound in self._files:
            os.close(bound["fd"])
        self._files.clear()
        for parent in self._parents.values():
            os.close(parent["fd"])
        self._parents.clear()
        if self._root_fd is not None:
            os.close(self._root_fd)
            self._root_fd = None
        self._prepared = False

    def __enter__(self):
        return self.prepare()

    def __exit__(self, *unused):
        self.close()


def verify_retired_files(root, selected, protected, parent_bindings, verify_proofs):
    """Independent closure under reacquired custody, without sibling snapshots.

    The caller separately establishes original process/child absence and retains
    the authenticated deletion receipt. Parent identities come from that receipt.
    """
    operation = ExactFileRetirement(root, selected, protected)
    try:
        operation._open_root()
        verify_proofs()
        for row in operation.selected:
            operation._check_absent(row)
        for row in operation.protected:
            operation._open_file(row, False)
        expected = {row["path"]: row["identity"] for row in parent_bindings}
        _require(len(expected) == len(parent_bindings), "duplicate recorded parent")
        actual = {row["path"]: row["identity"] for row in operation.parent_bindings}
        _require(actual == expected, "recorded parent binding changed")
        operation._check_parents()
        verify_proofs()
        operation._check_parents()
        for row in operation.selected:
            operation._check_absent(row)
        for bound in operation._files:
            operation._check_file(bound)
        return {"selected_absent": len(operation.selected),
                "protected_verified": len(operation.protected),
                "parent_bindings": operation.parent_bindings}
    finally:
        operation.close()
