"""Derive Android input roles without treating generated APKs as qualified builds.

The caller authenticates every JSON descriptor through ``authenticate`` and
hashes the returned APK descriptors under its existing source/output lock.
This module does no filesystem, process, build, signing, or device operations.
Public inspection still uses ``archive``; an accepted generated input is only
an incremental-build checkpoint, never a public or installed baseline.
"""

import copy
import re
from pathlib import PurePosixPath


_ROLES = {"debug", "instrumentation"}


def _require(condition, message):
    if not condition:
        raise ValueError(message)


def _descriptor(value):
    _require(isinstance(value, dict) and set(value) == {"path", "bytes", "sha256"},
             "Expected an exact file descriptor")
    path = value["path"]
    _require(isinstance(path, str) and path.startswith("/")
             and str(PurePosixPath(path)) == path and ".." not in path.split("/"),
             "Expected a canonical absolute path")
    _require(type(value["bytes"]) is int and value["bytes"] >= 0,
             "Invalid descriptor size")
    _require(isinstance(value["sha256"], str)
             and re.fullmatch(r"[0-9a-f]{64}", value["sha256"]) is not None,
             "Invalid descriptor digest")
    return value


def _outputs(rows):
    result = {}
    for row in rows:
        _descriptor(row)
        _require(row["path"] not in result, "Duplicate output path")
        result[row["path"]] = row
    return result


def derive_container_roles(configuration, authenticate, *, checkpoint_source=None):
    """Return named roles for existing generator/worker container inputs.

    ``configuration`` uses the existing apk_paths, generated_container_inputs,
    normal_outputs and qualified_package fields. Optional checkpoint fields
    are generated_input_checkpoint/latest_failed_package/latest_failed_physical.
    ``checkpoint_source`` must be the independently selected source descriptor
    of that failed build (which may precede a test-only correction). It must
    not be inferred from the checkpoint itself. Authentication exceptions and
    malformed records are fatal; no fallback adopts an unknown output.
    """
    cfg = configuration
    _require(set(cfg["apk_paths"]) == _ROLES
             and set(cfg["generated_container_inputs"]) == _ROLES,
             "Expected exactly debug and instrumentation roles")
    _require(len(set(cfg["apk_paths"].values())) == 2, "APK role paths collide")
    qualified = authenticate(_descriptor(cfg["qualified_package"]))
    _require(qualified["status"] == "PASSED-CLOSED"
             and qualified["public_identity_pass"] is True,
             "Archive authority is not publicly qualified")
    _require(set(qualified["retained_artifacts"]) == _ROLES,
             "Qualified archive roles differ")
    current = _outputs(cfg["normal_outputs"])
    checkpoint = None
    if cfg.get("generated_input_checkpoint") is not None:
        _descriptor(checkpoint_source)
        checkpoint = authenticate(_descriptor(cfg["generated_input_checkpoint"]))
        failed = authenticate(_descriptor(cfg["latest_failed_package"]))
        physical = authenticate(_descriptor(cfg["latest_failed_physical"]))
        failed_cfg = authenticate(_descriptor(failed["configuration"]))
        _require(checkpoint["status"] == "UNQUALIFIED_GENERATED_MAIN_CHECKPOINT"
                 and checkpoint["public_qualified"] is False,
                 "Unsupported checkpoint role")
        _require(checkpoint["failed_package"] == cfg["latest_failed_package"]
                 and checkpoint["physical_closure"] == cfg["latest_failed_physical"]
                 and checkpoint["configuration"] == failed["configuration"],
                 "Checkpoint provenance differs")
        _require(failed["status"] == "FAILED-CLOSED"
                 and failed["runtime_physical_closure"] == cfg["latest_failed_physical"]
                 and failed["canonical_source"] == failed_cfg["source"] == checkpoint_source,
                 "Checkpoint failed-build source differs")
        _require(physical["status"] == "FAILED-PHYSICALLY-CLOSED"
                 and all(physical[key] is True for key in (
                     "identities_absent_dual_proc_ps", "child_guardian_scopes_empty",
                     "locks_free_same_inode")), "Checkpoint build is not physically closed")
        before = _outputs(failed_cfg["normal_outputs"])
        after = _outputs(checkpoint["normal_outputs"])
        _require(len(before) == 4 and before.keys() == after.keys()
                 and after == current and failed_cfg["apk_paths"] == cfg["apk_paths"],
                 "Checkpoint output paths or current descriptors differ")
        changed = [[before[path], after[path]] for path in before if before[path] != after[path]]
        _require(len(changed) == 1 and changed[0][0]["path"] == cfg["apk_paths"]["debug"]
                 and checkpoint["changed"] == changed,
                 "Checkpoint must change only the named main APK")
    else:
        _require(checkpoint_source is None, "Source supplied without a checkpoint")

    result = {}
    for role in sorted(_ROLES):
        row = cfg["generated_container_inputs"][role]
        original, archive = _descriptor(row["original"]), _descriptor(row["archive"])
        retained = qualified["retained_artifacts"][role]
        _require(original["path"] == cfg["apk_paths"][role]
                 and current.get(original["path"]) == original,
                 "Current input does not match its named output")
        _require(archive == _descriptor(retained["preserved"])
                 and retained["original"]["path"] == original["path"],
                 "Archive is not the selected qualified role")
        _require((retained["original"]["bytes"], retained["original"]["sha256"])
                 == (archive["bytes"], archive["sha256"]),
                 "Qualified original and archive disagree")
        same = (original["bytes"], original["sha256"]) == (archive["bytes"], archive["sha256"])
        _require(same or (checkpoint is not None and role == "debug"),
                 "Unknown generated container")
        result[role] = dict(
            input_role="qualified-identical" if same else "generated-checkpoint",
            original=copy.deepcopy(original), archive=copy.deepcopy(archive))
    return result
