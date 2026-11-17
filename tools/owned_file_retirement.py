"""Retire an exact owned file selection without enumerating its siblings.

The caller must hold the selected owners' exclusive custody locks throughout
preparation, deletion and closure, and establish nonuse and recovery authority.
This module does not grant a release, acquire resource leases, or run a scan.
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


class ExactFileRetirement:
    """One-use selected-file transaction under externally held custody locks.

    Rows use the existing {path, bytes, sha256, stamp} representation. Protected
    rows are opened and hashed too; keep this list to the actual recovery or
    artifact keepers. Source/nonuse/other proof verification stays in the caller.
    No method mutates an unselected name or a directory. ``removed`` records
    successful unlink calls even if subsequent fsync or verification fails.
    """

    def __init__(self, root, selected, protected=()):
        self.root = os.fspath(root)
        self.root_parts = _components(self.root)
        self.selected = [dict(row, stamp=list(row["stamp"])) for row in selected]
        self.protected = [dict(row, stamp=list(row["stamp"])) for row in protected]
        _require(bool(self.selected), "empty selection")
        rows = self.selected + self.protected
        _require(len({row["path"] for row in rows}) == len(rows), "duplicate path")
        self.removed = []
        self.parent_bindings = []
        self._root_fd = None
        self._parents = {}
        self._files = []
        self._prepared = False
        self._started = False
        self._used = False

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
                 "selected": selected}
        self._files.append(bound)
        value = os.fstat(fd)
        _require(stat.S_ISREG(value.st_mode) and value.st_uid == os.getuid(),
                 "candidate or keeper is not an owned regular file")
        _require(not selected or value.st_nlink == 1, "selected file has aliases")
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
            for row in self.protected:
                self._open_file(row, False)
            for row in self.selected:
                self._open_file(row, True)
            selected_ids = {tuple(row["stamp"][:2]) for row in self.selected}
            keeper_ids = {tuple(row["stamp"][:2]) for row in self.protected}
            _require(len(selected_ids) == len(self.selected) and
                     not selected_ids.intersection(keeper_ids), "selected inode is protected")
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
        wanted = bound["row"]["stamp"]
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

    def unlink(self, verify_proofs):
        """Verify caller proofs and every remaining selected/keeper before each unlink."""
        _require(self._prepared and not self._used, "transaction not prepared or already used")
        self._used = True
        removed_paths = set()
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
            os.unlink(bound["name"], dir_fd=bound["parent"]["fd"])
            self.removed.append(bound["row"])
            removed_paths.add(bound["row"]["path"])
            os.fsync(bound["parent"]["fd"])
            self._check_absent(bound["row"])
        verify_proofs()
        self._check_parents()
        for row in self.removed:
            self._check_absent(row)
        for bound in self._files:
            if not bound["selected"]:
                self._check_file(bound)
        return list(self.removed)

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
