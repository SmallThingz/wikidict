import importlib.util
import tempfile
import unittest
from unittest import mock
from pathlib import Path

spec = importlib.util.spec_from_file_location(
    "extraction_cache", Path(__file__).with_name("extraction_cache.py"))
cache = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cache)


class ExtractionCacheTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.source = self.base / "source"
        self.source.mkdir()
        (self.source / "modules").mkdir()
        (self.source / "modules" / "123.lua").write_text("return 1")
        for name in cache.FILES:
            (self.source / name).write_bytes(name.encode())
        self.root = self.base / "cache"
        self.expected = {"version": 1, "dump_sha256": "a" * 64,
                         "index_sha256": "d" * 64,
                         "tool": {"extractor_sha256": "b" * 64, "libraries": []}}

    def test_round_trip_and_corruption(self):
        self.assertEqual(0, cache.publish(self.root, self.expected, self.source))
        output = self.base / "output"
        output.mkdir()
        self.assertEqual(0, cache.probe(self.root, self.expected, output))
        self.assertEqual(b"return 1", (output / "modules" / "123.lua").read_bytes())
        self.assertEqual((self.source / "page-index.tsv").read_bytes(),
                         (output / "page-index.tsv").read_bytes())
        (output / "page-index.tsv").write_bytes(b"corrupt")
        other = self.base / "other"
        other.mkdir()
        self.assertEqual(cache.MISS, cache.probe(self.root, self.expected, other))
        self.assertFalse((other / "modules").exists())

    def test_extractor_identity_change_is_miss(self):
        cache.publish(self.root, self.expected, self.source)
        changed = dict(self.expected, tool={"extractor_sha256": "c" * 64,
                                            "libraries": []})
        output = self.base / "other"
        output.mkdir()
        self.assertEqual(cache.MISS, cache.probe(self.root, changed, output))
        changed_index = dict(self.expected, index_sha256="e" * 64)
        self.assertEqual(cache.MISS, cache.probe(self.root, changed_index, output))

    def test_extractor_argv_is_part_of_identity(self):
        with mock.patch.object(cache, "tool_identity", return_value=self.expected["tool"]):
            original = cache.identity(Path("extractor"), "a" * 64, "d" * 64)
            with mock.patch.object(cache, "EXTRACTOR_ARGS", ("--other-mode",)):
                changed = cache.identity(Path("extractor"), "a" * 64, "d" * 64)
        self.assertEqual(["--page-index"], original["extractor_args"])
        self.assertNotEqual(original, changed)

    def test_valid_generation_prunes_older_extraction_cache(self):
        cache.publish(self.root, self.expected, self.source)
        older = self.root / ("f" * 64)
        older.mkdir()
        (older / ".complete.json").write_text("old")
        self.assertEqual(0, cache.publish(self.root, self.expected, self.source))
        self.assertFalse(older.exists())

    def test_missing_required_asset_rejected(self):
        (self.source / "page-title-index.bin").unlink()
        with self.assertRaises(ValueError):
            cache.publish(self.root, self.expected, self.source)

    def test_oversized_and_wrong_shape_extraction_markers_are_misses(self):
        cache.publish(self.root, self.expected, self.source)
        key = cache.hashlib.sha256(cache.json.dumps(self.expected, sort_keys=True).encode()).hexdigest()
        marker = self.root / key / ".complete.json"
        output = self.base / "output"
        output.mkdir()
        with mock.patch.object(cache, "MAX_MARKER_BYTES", 64):
            marker.write_bytes(b" " * 65)
            self.assertEqual(cache.MISS, cache.probe(self.root, self.expected, output))
        marker.write_text("[]")
        self.assertEqual(cache.MISS, cache.probe(self.root, self.expected, output))
        self.assertFalse((output / "modules").exists())


class ObjectCacheTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.root = self.base / "cache"
        self.project = self.base / "project"
        for name in cache.ABI_FILES:
            path = self.project / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(name)
        self.flags = ["-fno-lto", "-Wno-override-module", "-O1"]
        self.tool = {"tool": {"extractor_sha256": "c" * 64, "libraries": []},
                     "target": "x86_64-linux-gnu", "version": "clang fixture"}
        self.patched = mock.patch.object(cache, "clang_identity", return_value=self.tool)
        self.patched.start()
        self.addCleanup(self.patched.stop)

    def llvm(self, name):
        root = self.base / name
        root.mkdir()
        (root / "batch-plan.tsv").write_text(
            "# dict-llvm-batch-plan-v1\n"
            "-O2\tmodule_batch_o2_000000.bc\t1\t0\t0\t10\n"
            "-O0\tmodule_batch_o0_000000.bc\t1\t1\t1\t5\n")
        (root / "module_batch_o2_000000.bc").write_bytes(b"batch-high")
        (root / "module_batch_o0_000000.bc").write_bytes(b"batch-low")
        (root / "program.bc").write_bytes(b"program bitcode")
        (root / "program.meta").write_bytes(b"program metadata")
        return root

    def test_round_trip_and_corrupt_object(self):
        first = self.llvm("first")
        self.assertEqual(cache.MISS, cache.probe_objects(
            self.root, "clang", self.project, first, self.flags))
        for name in ("module_batch_000000.o", "module_batch_000001.o", "program.o"):
            (first / name).write_bytes(name.encode())
        self.assertEqual(0, cache.publish_objects(self.root, first))
        second = self.llvm("second")
        self.assertEqual(0, cache.probe_objects(
            self.root, "clang", self.project, second, self.flags))
        self.assertEqual(b"module_batch_000001.o",
                         (second / "module_batch_000001.o").read_bytes())
        (second / "module_batch_000001.o").write_bytes(b"bad")
        third = self.llvm("third")
        self.assertEqual(cache.MISS, cache.probe_objects(
            self.root, "clang", self.project, third, self.flags))
        self.assertFalse((third / "program.o").exists())

    def test_bitcode_metadata_and_flags_invalidate_but_abi_only_change_hits(self):
        first = self.llvm("first")
        cache.probe_objects(self.root, "clang", self.project, first, self.flags)
        for name in ("module_batch_000000.o", "module_batch_000001.o", "program.o"):
            (first / name).write_bytes(name.encode())
        cache.publish_objects(self.root, first)
        for label, filename, content in (
            ("bitcode", "module_batch_o2_000000.bc", b"new bitcode"),
            ("metadata", "program.meta", b"new metadata"),
        ):
            changed = self.llvm(label)
            (changed / filename).write_bytes(content)
            self.assertEqual(cache.MISS, cache.probe_objects(
                self.root, "clang", self.project, changed, self.flags))
        abi = self.project / cache.ABI_FILES[0]
        abi.write_text("changed ABI")
        changed = self.llvm("abi")
        self.assertEqual(0, cache.probe_objects(
            self.root, "clang", self.project, changed, self.flags))
        self.assertNotIn("abi", cache.object_identity(
            changed, "clang", self.project, self.flags))
        self.assertEqual(b"program.o", (changed / "program.o").read_bytes())
        abi.write_text(cache.ABI_FILES[0])
        changed = self.llvm("flags")
        self.assertEqual(cache.MISS, cache.probe_objects(
            self.root, "clang", self.project, changed, ["-O3"]))
        changed_tool = dict(self.tool, version="changed clang")
        with mock.patch.object(cache, "clang_identity", return_value=changed_tool):
            changed = self.llvm("tool")
            self.assertEqual(cache.MISS, cache.probe_objects(
                self.root, "clang", self.project, changed, self.flags))

    def test_incomplete_generation_never_hits(self):
        first = self.llvm("first")
        identity = cache.object_identity(first, "clang", self.project, self.flags)
        partial = cache.object_cache_path(self.root, identity)
        partial.mkdir(parents=True)
        (partial / "module_batch_000000.o").write_bytes(b"partial")
        self.assertEqual(cache.MISS, cache.probe_objects(
            self.root, "clang", self.project, first, self.flags))

    def test_oversized_and_wrong_shape_object_markers_are_misses(self):
        first = self.llvm("first")
        cache.probe_objects(self.root, "clang", self.project, first, self.flags)
        for name in ("module_batch_000000.o", "module_batch_000001.o", "program.o"):
            (first / name).write_bytes(name.encode())
        cache.publish_objects(self.root, first)
        expected = cache.object_identity(first, "clang", self.project, self.flags)
        marker = cache.object_cache_path(self.root, expected) / ".complete.json"
        second = self.llvm("second")
        with mock.patch.object(cache, "MAX_MARKER_BYTES", 64):
            marker.write_bytes(b" " * 65)
            self.assertEqual(cache.MISS, cache.probe_objects(
                self.root, "clang", self.project, second, self.flags))
        marker.write_text("[]")
        self.assertEqual(cache.MISS, cache.probe_objects(
            self.root, "clang", self.project, second, self.flags))
        self.assertFalse((second / "program.o").exists())

    def test_oversized_private_object_identity_is_rejected(self):
        first = self.llvm("first")
        cache.probe_objects(self.root, "clang", self.project, first, self.flags)
        for name in ("module_batch_000000.o", "module_batch_000001.o", "program.o"):
            (first / name).write_bytes(name.encode())
        with mock.patch.object(cache, "MAX_MARKER_BYTES", 64):
            (first / ".object-identity.json").write_bytes(b" " * 65)
            with self.assertRaisesRegex(ValueError, "Oversized"):
                cache.publish_objects(self.root, first)

    def test_valid_generation_prunes_older_object_cache(self):
        first = self.llvm("first")
        cache.probe_objects(self.root, "clang", self.project, first, self.flags)
        for name in ("module_batch_000000.o", "module_batch_000001.o", "program.o"):
            (first / name).write_bytes(name.encode())
        cache.publish_objects(self.root, first)
        older = self.root / "objects" / ("f" * 64)
        older.mkdir()
        (older / ".complete.json").write_text("old")
        self.assertEqual(0, cache.publish_objects(self.root, first))
        self.assertFalse(older.exists())

    def test_verified_legacy_generation_survives_abi_only_change(self):
        first = self.llvm("first")
        current = cache.object_identity(first, "clang", self.project, self.flags)
        legacy = dict(current, version=cache.LEGACY_OBJECT_VERSION,
                      abi=cache.abi_provenance(self.project))
        old_root = cache.object_cache_path(self.root, legacy)
        old_root.mkdir(parents=True)
        names = cache.object_names(legacy)
        for name in names:
            (old_root / name).write_bytes(name.encode())
        (old_root / ".complete.json").write_text(cache.json.dumps({
            "identity": legacy,
            "assets": cache.record_named_assets(old_root, names),
        }))
        (self.project / cache.ABI_FILES[0]).write_text("new runtime implementation")
        second = self.llvm("second")
        self.assertEqual(0, cache.probe_objects(
            self.root, "clang", self.project, second, self.flags))
        self.assertEqual(b"program.o", (second / "program.o").read_bytes())
        self.assertFalse(cache.object_cache_path(self.root, current).exists())
        self.assertTrue(old_root.is_dir())

        # A legacy marker with a mismatched non-ABI field is not compatible.
        changed = self.llvm("changed")
        (changed / "program.meta").write_bytes(b"different metadata")
        self.assertEqual(cache.MISS, cache.probe_objects(
            self.root, "clang", self.project, changed, self.flags))

        # The legacy key cannot redeem an object whose content changed.
        (old_root / "program.o").write_bytes(b"corrupt")
        third = self.llvm("third")
        self.assertEqual(cache.MISS, cache.probe_objects(
            self.root, "clang", self.project, third, self.flags))
        self.assertFalse((third / "program.o").exists())


if __name__ == "__main__":
    unittest.main()
