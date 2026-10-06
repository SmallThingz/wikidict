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
        (self.source / "compiler-inputs.ready").write_bytes(b"complete\n")
        (self.source / "dump-streams.tsv").write_bytes(b"0\t0\t100\n")
        (self.source / "page-index.tsv").write_bytes(b"0\t0\t10\tTemplate:fixture\n")
        self.root = self.base / "cache"
        self.expected = {"version": 1, "dump_sha256": "a" * 64,
                         "index_sha256": "d" * 64,
                         "tool": {"extractor_sha256": "b" * 64, "libraries": []}}

    def snapshot_output(self, output, backing, *, copied=False):
        output.mkdir(exist_ok=True)
        (output / "namespace-registry.tsv").write_bytes(b"namespace fixture")
        destination = output / "page-redirects.tsv"
        if copied:
            destination.write_bytes(backing.read_bytes())
        else:
            destination.symlink_to(backing)
        return destination

    def snapshot_main(self, action, output):
        with mock.patch.object(cache, "tool_identity", return_value=self.expected["tool"]), \
             mock.patch.object(cache, "unicode_case_identity", return_value={}):
            return cache.main(["extraction_cache.py", action, str(self.root),
                               "extractor", "a" * 64, "d" * 64, str(output)])

    def test_snapshot_main_cold_publish_warm_link_and_copy(self):
        backing = self.base / "redirects.tsv"
        backing.write_bytes(b"exact redirect snapshot")
        installed = self.snapshot_output(self.source, backing)
        self.assertEqual(cache.MISS, self.snapshot_main("probe", self.source))
        self.assertEqual(0, self.snapshot_main("publish", self.source))
        generation, = [p for p in self.root.iterdir() if not p.name.startswith(".")]
        marker = cache.read_marker(generation / ".complete.json")
        self.assertEqual(cache.sha256(backing), marker["identity"]["page_redirects_sha256"])
        self.assertNotIn("page-redirects.tsv", cache.FILES)
        self.assertFalse((generation / "page-redirects.tsv").exists())
        for name in cache.walk_assets(generation):
            self.assertFalse((generation / name).is_symlink(), name)
        self.assertTrue(installed.is_symlink())
        for copied in (False, True):
            with self.subTest(copied=copied):
                output = self.base / ("copy" if copied else "linked")
                sidecar = self.snapshot_output(output, backing, copied=copied)
                self.assertEqual(0, self.snapshot_main("probe", output))
                self.assertEqual(not copied, sidecar.is_symlink())
                self.assertEqual(backing.read_bytes(), sidecar.read_bytes())
                self.assertEqual(b"return 1", (output / "modules/123.lua").read_bytes())

    def test_snapshot_backing_mutation_invalidates_main_probe(self):
        backing = self.base / "redirects.tsv"
        backing.write_bytes(b"snapshot before")
        self.snapshot_output(self.source, backing)
        self.assertEqual(0, self.snapshot_main("publish", self.source))
        backing.write_bytes(b"snapshot after")
        output = self.base / "changed"
        self.snapshot_output(output, backing)
        self.assertEqual(cache.MISS, self.snapshot_main("probe", output))
        self.assertFalse((output / "modules").exists())
        self.assertTrue(all(not (output / name).exists() for name in cache.FILES))

    def test_snapshot_dangling_and_directory_links_are_not_absent(self):
        for kind in ("dangling", "directory"):
            with self.subTest(kind=kind):
                backing = self.base / (kind + "-target")
                if kind == "directory":
                    backing.mkdir()
                output = self.base / kind
                self.snapshot_output(output, backing)
                with self.assertRaises((FileNotFoundError, ValueError)):
                    self.snapshot_main("probe", output)
                self.assertFalse(self.root.exists())

    def test_snapshot_input_resolution_does_not_allow_symlink_cache_assets(self):
        backing = self.base / "redirects.tsv"
        backing.write_bytes(b"snapshot")
        self.snapshot_output(self.source, backing)
        self.assertEqual(0, self.snapshot_main("publish", self.source))
        generation, = [p for p in self.root.iterdir() if not p.name.startswith(".")]
        external = self.base / "external-page-index.tsv"
        external.write_bytes((generation / "page-index.tsv").read_bytes())
        (generation / "page-index.tsv").unlink()
        (generation / "page-index.tsv").symlink_to(external)
        output = self.base / "corrupt-cache"
        self.snapshot_output(output, backing)
        self.assertEqual(cache.MISS, self.snapshot_main("probe", output))
        self.assertFalse((output / "modules").exists())
        (self.source / "page-index.tsv").unlink()
        (self.source / "page-index.tsv").symlink_to(external)
        with self.assertRaisesRegex(ValueError, "Expected regular extraction asset"):
            self.snapshot_main("publish", self.source)

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

    def test_incomplete_extraction_never_publishes(self):
        (self.source / "compiler-inputs.ready").write_bytes(b"incomplete\n")
        with self.assertRaises(ValueError):cache.publish(self.root,self.expected,self.source)
        (self.source / "compiler-inputs.ready").write_bytes(b"complete\n")
        (self.source / "dump-streams.tsv").write_bytes(b"1\t100\t100\n")
        with self.assertRaises(ValueError):cache.publish(self.root,self.expected,self.source)

    def test_namespace_registry_is_part_of_identity(self):
        with mock.patch.object(cache, "tool_identity", return_value={}):
            original=cache.identity(Path("extractor"), "a"*64, "d"*64, "e"*64)
            changed=cache.identity(Path("extractor"), "a"*64, "d"*64, "f"*64)
        self.assertNotEqual(original,changed)
        self.assertEqual(2,len(original["unicode_case"]["libraries"]))

    def test_extractor_argv_is_part_of_identity(self):
        with mock.patch.object(cache, "tool_identity", return_value=self.expected["tool"]):
            original = cache.identity(Path("extractor"), "a" * 64, "d" * 64, "e" * 64)
            with mock.patch.object(cache, "EXTRACTOR_ARGS", ("--other-mode",)):
                changed = cache.identity(Path("extractor"), "a" * 64, "d" * 64, "e" * 64)
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
        for name in cache.LIVE_LEAF_SOURCE_PATHS:
            path = self.project / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(name)
        self.flags = ["-march=native", "-fno-lto", "-Wno-override-module", "-O1"]
        self.tool = {"tool": {"extractor_sha256": "c" * 64, "libraries": []},
                     "target": "x86_64-linux-gnu", "version": "clang fixture"}
        self.patched = mock.patch.object(cache, "clang_identity", return_value=self.tool)
        self.patched.start()
        self.addCleanup(self.patched.stop)
        self.zig_tool = {"tool_sha256": "e" * 64, "version": "zig fixture",
                         "target": "x86_64-linux-gnu", "flags": list(cache.LEAF_CONTRACT_FLAGS)}
        self.patched_zig = mock.patch.object(cache, "live_zig_observation", return_value=self.zig_tool)
        self.patched_zig.start()
        self.addCleanup(self.patched_zig.stop)

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
        (root / "value_leaf.bc").write_bytes(b"verified build-only helper bitcode")
        return root

    names = ("module_batch_000000.o", "module_batch_000001.o", "program.o")

    def probe(self, output, flags=None):
        return cache.probe_objects(self.root, "clang", self.project, output,
                                   self.flags if flags is None else flags)

    def publish(self, output, flags=None):
        return cache.publish_objects(self.root, output, "clang",
                                     self.flags if flags is None else flags)

    def complete_missing(self, output):
        for name in self.names:
            path = output / name
            if not path.exists():
                path.write_bytes(name.encode())

    def seed(self):
        first = self.llvm("first")
        self.assertEqual(cache.MISS, self.probe(first))
        self.assertEqual("000\n", (first / ".object-hits").read_text())
        self.complete_missing(first)
        self.assertEqual(0, self.publish(first))
        snapshot = cache.read_marker(first / ".object-identity.json")
        self.entries = dict(cache.object_entries(snapshot["identity"]))
        return first

    def entry(self, name):
        return cache.object_cache_path(self.root, self.entries[name])

    def assert_hits(self, output, bits, flags=None):
        expected = 0 if bits == "111" else cache.MISS
        self.assertEqual(expected, self.probe(output, flags))
        self.assertEqual(bits + "\n", (output / ".object-hits").read_text())
        for name, hit in zip(self.names, bits):
            self.assertEqual(hit == "1", (output / name).is_file(), name)

    def test_round_trip_corruption_is_local_and_can_be_repaired(self):
        self.seed()
        second = self.llvm("second")
        self.assert_hits(second, "111")
        self.assertEqual(b"module_batch_000001.o",
                         (second / "module_batch_000001.o").read_bytes())
        # The installed output is a hardlink: corruption must invalidate only
        # its own content entry, not otherwise unchanged batches/program.
        (second / "module_batch_000001.o").write_bytes(b"bad")
        third = self.llvm("third")
        self.assert_hits(third, "101")
        self.complete_missing(third)
        self.assertEqual(0, self.publish(third))
        self.assert_hits(self.llvm("fourth"), "111")

    def test_one_batch_changed_restores_other_batch_and_program(self):
        self.seed()
        changed = self.llvm("changed")
        (changed / "module_batch_o2_000000.bc").write_bytes(b"different function IDs/body")
        self.assert_hits(changed, "011")
        cached = self.entry("module_batch_000001.o") / "object.o"
        self.assertEqual(cached.stat().st_ino,
                         (changed / "module_batch_000001.o").stat().st_ino)

    def test_metadata_only_change_does_not_invalidate_native_objects(self):
        self.seed()
        changed = self.llvm("changed")
        (changed / "program.meta").write_bytes(b"fresh runtime metadata")
        plan = changed / "batch-plan.tsv"
        plan.write_text(plan.read_text() + "# fresh non-native plan annotation\n")
        self.assert_hits(changed, "111")
        self.assertEqual(0, self.publish(changed))
        self.assertEqual(b"fresh runtime metadata", (changed / "program.meta").read_bytes())

    def test_program_bitcode_change_invalidates_only_program(self):
        self.seed()
        changed = self.llvm("changed")
        (changed / "program.bc").write_bytes(b"new roots")
        self.assert_hits(changed, "110")

    def test_batch_mode_and_program_mode_are_independent_inputs(self):
        self.seed()
        changed = self.llvm("batch-mode")
        plan = changed / "batch-plan.tsv"
        plan.write_text(plan.read_text().replace("-O2\t", "-O1\t"))
        self.assert_hits(changed, "011")
        self.assert_hits(self.llvm("program-mode"), "110", self.flags[:-1] + ["-O2"])

    def test_reordered_batches_reuse_content_in_fresh_link_order(self):
        self.seed()
        changed = self.llvm("changed")
        plan = changed / "batch-plan.tsv"
        header, high, low = plan.read_text().splitlines()
        plan.write_text("\n".join((header, low, high)) + "\n")
        self.assert_hits(changed, "111")
        self.assertEqual(b"module_batch_000001.o", (changed / self.names[0]).read_bytes())
        self.assertEqual(b"module_batch_000000.o", (changed / self.names[1]).read_bytes())
        self.assertEqual(0, self.publish(changed))

    def test_abi_source_only_change_is_provenance_and_still_hits(self):
        self.seed()
        published = cache.read_marker(self.entry(self.names[0]) / ".complete.json")
        self.assertEqual("live-source-observation", published["provenance"]["abi_scope"])
        (self.project / cache.ABI_FILES[0]).write_text("changed runtime ABI source")
        changed = self.llvm("changed")
        self.assert_hits(changed, "111")
        snapshot = cache.read_marker(changed / ".object-identity.json")
        self.assertEqual(cache.abi_provenance(self.project), snapshot["provenance"]["abi"])
        self.assertEqual("live-source-observation", snapshot["provenance"]["abi_scope"])
        for _, identity in cache.object_entries(snapshot["identity"]):
            self.assertNotIn("abi", identity)

    def test_leaf_inputs_invalidate_only_optimized_batches(self):
        self.seed()
        changed = self.llvm("leaf-bitcode")
        (changed / "value_leaf.bc").write_bytes(b"different leaf definitions")
        self.assert_hits(changed, "011")
        source = self.project / cache.LIVE_LEAF_SOURCE_PATHS[1]
        source.write_text("changed helper source")
        self.assert_hits(self.llvm("leaf-source"), "011")
        source.write_text(cache.LIVE_LEAF_SOURCE_PATHS[1])
        for label, value in (("version", "new Zig"), ("target", "aarch64-linux-gnu"),
                             ("flags", ["-O2"]), ("tool_sha256", "f" * 64)):
            with self.subTest(label=label), mock.patch.object(
                    cache, "live_zig_observation", return_value=dict(self.zig_tool, **{label: value})):
                self.assert_hits(self.llvm("leaf-" + label), "011")

    def test_live_observations_do_not_claim_to_have_produced_cached_leaf(self):
        output = self.llvm("paired-build-artifact")
        before = cache.value_leaf_identity(output, self.project, "zig")
        source = self.project / cache.LIVE_LEAF_SOURCE_PATHS[1]
        source.write_text("new live source after cached pipeline was built")
        with mock.patch.object(cache, "live_zig_observation",
                               return_value=dict(self.zig_tool, version="new live Zig")):
            after = cache.value_leaf_identity(output, self.project, "zig")
        self.assertEqual(before["bitcode"], after["bitcode"])
        self.assertEqual(set(after), {"bitcode", "live_source_observations", "live_zig_observation"})
        self.assertNotEqual(before["live_source_observations"], after["live_source_observations"])
        self.assertNotEqual(before["live_zig_observation"], after["live_zig_observation"])
        self.assertEqual(cache.sha256(source),
                         dict(after["live_source_observations"])[cache.LIVE_LEAF_SOURCE_PATHS[1]])

    def test_legacy_leaf_labels_cannot_redeem_optimized_objects(self):
        output = self.llvm("legacy")
        snapshot = cache.object_identity(output, "clang", self.project, self.flags)
        leaf = snapshot["value_leaf"]
        snapshot["value_leaf"] = {
            "bitcode": leaf["bitcode"],
            "producer_sources": leaf["live_source_observations"],
            "zig": leaf["live_zig_observation"],
        }
        for name, identity in cache.object_entries(snapshot):
            entry = cache.object_cache_path(self.root, identity)
            entry.mkdir(parents=True)
            asset = entry / "object.o"
            asset.write_bytes(name.encode())
            (entry / ".complete.json").write_text(cache.json.dumps({
                "identity": identity, "object": cache.record_object(asset),
                "provenance": {"abi": cache.abi_provenance(self.project)},
            }))
        # O0/program consume no leaf; their exact existing content keys survive.
        self.assert_hits(self.llvm("current"), "011")

    def test_compiler_target_features_and_common_flags_invalidate_every_object(self):
        self.seed()
        for label, value in (("version", "new Clang"), ("target", "aarch64-linux-gnu"),
                             ("tool", {"extractor_sha256": "f" * 64, "libraries": []}),
                             ("resolved_native", {"cpu": "alderlake", "features": ["+avx2"]})):
            with self.subTest(label=label), mock.patch.object(
                    cache, "clang_identity", return_value=dict(self.tool, **{label: value})):
                self.assert_hits(self.llvm("clang-" + label), "000")
        self.assert_hits(self.llvm("flags"), "000", ["-march=x86-64", *self.flags[1:]])

    def test_publish_rechecks_compiler_native_features_and_flags(self):
        first = self.llvm("first")
        self.probe(first)
        self.complete_missing(first)
        changed_tool = dict(self.tool, resolved_native={"cpu": "alderlake", "features": ["+avx2"]})
        with mock.patch.object(cache, "clang_identity", return_value=changed_tool):
            with self.assertRaisesRegex(ValueError, "native target"):
                self.publish(first)
        with self.assertRaisesRegex(ValueError, "compile flags"):
            self.publish(first, self.flags[:-1] + ["-O2"])
        self.assertFalse((self.root / "objects").exists())

    def test_publish_rechecks_plan_metadata_and_leaf(self):
        for name in ("batch-plan.tsv", "program.meta", "value_leaf.bc"):
            with self.subTest(name=name):
                output = self.llvm(name)
                self.probe(output)
                self.complete_missing(output)
                (output / name).write_bytes(b"changed while compiling")
                with self.assertRaisesRegex(ValueError, "changed during compilation"):
                    self.publish(output)
        self.assertFalse((self.root / "objects").exists())

    def test_compiled_bitcode_may_be_deleted_before_publication(self):
        first = self.llvm("first")
        self.probe(first)
        self.complete_missing(first)
        for name in ("module_batch_o2_000000.bc", "module_batch_o0_000000.bc", "program.bc"):
            (first / name).unlink()
        self.assertEqual(0, self.publish(first))
        self.assert_hits(self.llvm("second"), "111")

    def test_changed_restored_hardlink_cannot_be_recertified(self):
        self.seed()
        changed = self.llvm("changed")
        self.assert_hits(changed, "111")
        (changed / "program.o").write_bytes(b"changed after probe")
        with self.assertRaisesRegex(ValueError, "Restored native object changed"):
            self.publish(changed)
        self.assert_hits(self.llvm("third"), "110")

    def test_preexisting_output_rejected_before_any_restore(self):
        self.seed()
        changed = self.llvm("changed")
        (changed / "program.o").write_bytes(b"unverified object")
        with self.assertRaisesRegex(ValueError, "Refusing to replace"):
            self.probe(changed)
        self.assertFalse((changed / self.names[0]).exists())
        self.assertFalse((changed / ".object-hits").exists())

    def test_nonregular_oversized_empty_or_extra_cache_assets_are_local_misses(self):
        self.seed()
        target = self.entry(self.names[0])
        original = (target / "object.o").read_bytes()
        for label in ("symlink", "oversize", "empty", "extra"):
            with self.subTest(label=label), mock.patch.object(cache, "MAX_OBJECT_BYTES", 64):
                asset = target / "object.o"
                asset.unlink()
                if label == "symlink":
                    outside = self.base / "outside"
                    outside.write_bytes(original)
                    asset.symlink_to(outside)
                elif label == "oversize":
                    with asset.open("wb") as stream:
                        stream.truncate(65)
                else:
                    asset.write_bytes(b"" if label == "empty" else original)
                if label == "extra":
                    (target / "extra").write_text("not allowed")
                self.assert_hits(self.llvm(label), "011")
            (target / "extra").unlink(missing_ok=True)
        (target / "object.o").unlink()
        (target / "object.o").write_bytes(original)

    def test_invalid_and_oversized_cache_markers_are_local_misses(self):
        first = self.seed()
        marker = self.entry(self.names[0]) / ".complete.json"
        for label, raw in (("list", "[]"), ("identity", '{}'), ("invalid", "{")):
            marker.write_text(raw)
            self.assert_hits(self.llvm(label), "011")
        bound = max(4096, (first / ".object-identity.json").stat().st_size * 2)
        marker.write_bytes(b" " * (bound + 1))
        with mock.patch.object(cache, "MAX_MARKER_BYTES", bound):
            self.assert_hits(self.llvm("oversized"), "011")

    def test_incomplete_or_symlink_cache_entry_never_hits(self):
        first = self.llvm("first")
        snapshot = cache.object_identity(first, "clang", self.project, self.flags)
        entries = list(cache.object_entries(snapshot))
        target = cache.object_cache_path(self.root, entries[0][1])
        target.mkdir(parents=True)
        (target / "object.o").write_bytes(b"incomplete")
        self.assert_hits(first, "000")
        cache.shutil.rmtree(target)
        outside = self.base / "outside"
        outside.mkdir()
        target.symlink_to(outside, target_is_directory=True)
        self.assert_hits(self.llvm("second"), "000")

    def test_private_snapshot_bounds_shape_and_version_are_rejected(self):
        first = self.llvm("first")
        self.probe(first)
        self.complete_missing(first)
        marker = first / ".object-identity.json"
        original = cache.read_marker(marker)
        for label, value in (("list", []), ("shape", {"identity": []}),
                             ("old", dict(original, identity=dict(original["identity"], version=3))),
                             ("program", dict(original, identity=dict(original["identity"], program_bc=None))),
                             ("restored", dict(original, restored=[["../bad", 1, "a" * 64]]))):
            with self.subTest(label=label):
                marker.write_text(cache.json.dumps(value))
                with self.assertRaises(ValueError):
                    self.publish(first)
        with mock.patch.object(cache, "MAX_MARKER_BYTES", 64):
            marker.write_bytes(b" " * 65)
            with self.assertRaisesRegex(ValueError, "Oversized"):
                self.publish(first)

    def test_success_retains_shared_keys_and_prunes_old_and_legacy_keys(self):
        self.seed()
        old = {self.entry(name) for name in self.names}
        legacy = self.root / "objects" / ("f" * 64)
        legacy.mkdir()
        (legacy / ".complete.json").write_text("old generation")
        changed = self.llvm("changed")
        (changed / "module_batch_o2_000000.bc").write_bytes(b"new batch")
        self.assert_hits(changed, "011")
        # An incomplete producer cannot delete the previous successful set.
        with self.assertRaises(ValueError):
            self.publish(changed)
        self.assertTrue(all(path.exists() for path in old))
        self.complete_missing(changed)
        self.assertEqual(0, self.publish(changed))
        self.assertFalse(legacy.exists())
        self.assertFalse(self.entry(self.names[0]).exists())
        self.assertTrue(self.entry(self.names[1]).exists())
        self.assertTrue(self.entry(self.names[2]).exists())
        self.assertEqual(3, len(list((self.root / "objects").iterdir())))

    def test_failed_atomic_publish_preserves_previous_keys(self):
        self.seed()
        previous = {path.name for path in (self.root / "objects").iterdir()}
        changed = self.llvm("changed")
        (changed / "module_batch_o2_000000.bc").write_bytes(b"new batch")
        self.assert_hits(changed, "011")
        self.complete_missing(changed)
        rename = Path.rename
        def fail_publish(path, destination):
            if path.name.startswith(".part-"):
                raise OSError("injected atomic publication failure")
            return rename(path, destination)
        with mock.patch.object(Path, "rename", fail_publish):
            with self.assertRaisesRegex(OSError, "injected"):
                self.publish(changed)
        self.assertEqual(previous, {path.name for path in (self.root / "objects").iterdir()})

    def test_old_object_version_cannot_redeem_current_objects(self):
        first = self.llvm("first")
        snapshot = cache.object_identity(first, "clang", self.project, self.flags)
        for _, current in cache.object_entries(snapshot):
            old = dict(current, version=3)
            root = cache.object_cache_path(self.root, old)
            root.mkdir(parents=True)
            (root / "object.o").write_bytes(b"old object")
            (root / ".complete.json").write_text(cache.json.dumps({
                "identity": old, "object": cache.record_object(root / "object.o"),
                "provenance": {"abi": cache.abi_provenance(self.project)},
            }))
        self.assert_hits(first, "000")


if __name__ == "__main__":
    unittest.main()
