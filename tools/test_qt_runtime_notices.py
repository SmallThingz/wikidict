#!/usr/bin/env python3
"""Tiny file controls; no Qt build, runtime, stage or network dependency."""
import hashlib
import json
from pathlib import Path
import tempfile
import unittest

import qt_runtime_notices as notices


class NoticeFiles(unittest.TestCase):
    def setUp(self):
        temporary_root = Path(__file__).resolve().parents[1] / ".tmp"
        temporary_root.mkdir(exist_ok=True)
        self.temporary = tempfile.TemporaryDirectory(dir=temporary_root, prefix="qt-notices-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.roots = {name: self.root / name for name in notices.MODULES}
        for name, root in self.roots.items():
            (root / "LICENSES").mkdir(parents=True)
            (root / "LICENSES/Test.txt").write_bytes((name + " license\n").encode())
        self.metadata = self.roots["qtbase"] / "src/component/qt_attribution.json"
        self.metadata.parent.mkdir(parents=True)
        self.metadata.write_bytes(b'[{"LicenseFile":"../NOTICE","CopyrightFiles":["COPYRIGHT"],"Files":"code.cpp","Comment":"literal\tcontrol"}]')
        self.notice = self.metadata.parent.parent / "NOTICE"
        self.notice.write_bytes(b"unmodified license\r\n")
        (self.metadata.parent / "COPYRIGHT").write_bytes(b"unmodified copyright\n")
        (self.metadata.parent / "code.cpp").write_bytes(b"not a notice\n")
        self.selection = self.make_selection()
        self.output = self.root / "output"

    def make_selection(self):
        names = [name + "/LICENSES/Test.txt" for name in notices.MODULES]
        names += ["qtbase/src/component/qt_attribution.json", "qtbase/src/NOTICE", "qtbase/src/component/COPYRIGHT"]
        rows = []
        for name in sorted(names):
            module, relative = name.split("/", 1)
            data = (self.roots[module] / relative).read_bytes()
            rows.append(dict(path=name, bytes=len(data), sha256=hashlib.sha256(data).hexdigest()))
        return dict(schema="wikidict.qt-notice-selection.v1", files=rows,
                    attribution_files=["qtbase/src/component/qt_attribution.json"])

    def test_selected_bytes_schema_and_no_source_tree_copy(self):
        manifest = notices.generate(self.roots, self.selection, self.output)
        value = json.loads(manifest.read_text())
        self.assertEqual(value["schema"], "wikidict.qt-notices.v1")
        self.assertEqual(value["missing_referenced_files"], [])
        self.assertEqual(len(value["files"]), 6)
        for row in value["files"]:
            copied = self.output / "notices" / row["path"]
            self.assertEqual(copied.read_bytes(), Path(row["source"]).read_bytes())
            self.assertEqual(hashlib.sha256(copied.read_bytes()).hexdigest(), row["sha256"])
        self.assertFalse(list(self.output.rglob("code.cpp")))
        self.assertEqual((self.output / "notices/qtbase/src/component/qt_attribution.json").read_bytes(), self.metadata.read_bytes())
        with self.assertRaisesRegex(ValueError, "must be new"):
            notices.generate(self.roots, self.selection, self.output)

    def test_missing_reference_does_not_publish(self):
        self.notice.unlink()
        with self.assertRaisesRegex(ValueError, "missing referenced"):
            notices.generate(self.roots, self.selection, self.output)
        self.assertFalse(self.output.exists())

    def test_reference_escape_does_not_publish(self):
        self.metadata.write_text('{"LicenseFile":"../../../outside"}')
        with self.assertRaisesRegex(ValueError, "escapes module"):
            notices.generate(self.roots, self.selection, self.output)
        self.assertFalse(self.output.exists())

    def test_source_byte_and_selection_drift_do_not_publish(self):
        self.notice.write_bytes(b"changed\n")
        with self.assertRaisesRegex(ValueError, "bytes drifted"):
            notices.generate(self.roots, self.selection, self.output)
        self.assertFalse(self.output.exists())
        self.notice.write_bytes(b"unmodified license\r\n")
        (self.roots["qtsvg"] / "LICENSES/New.txt").write_text("new notice")
        with self.assertRaisesRegex(ValueError, "selection drift"):
            notices.generate(self.roots, self.selection, self.output)
        self.assertFalse(self.output.exists())

    def test_symlinked_notice_is_rejected(self):
        self.notice.unlink()
        self.notice.symlink_to(self.metadata.parent / "COPYRIGHT")
        with self.assertRaisesRegex(ValueError, "symlinked"):
            notices.generate(self.roots, self.selection, self.output)
        self.assertFalse(self.output.exists())


if __name__ == "__main__":
    unittest.main()
