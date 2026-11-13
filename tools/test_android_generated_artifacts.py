"""Pure role controls: no APK reads, build commands, or device operations."""

import copy
import unittest

from android_generated_artifacts import derive_container_roles


def descriptor(path, digit="a", size=10):
    return dict(path=path, bytes=size, sha256=digit * 64)


class ContainerRoleTests(unittest.TestCase):
    def setUp(self):
        self.main = descriptor("/build/debug.apk")
        self.test = descriptor("/build/test.apk", "b")
        self.metadata = [descriptor("/build/debug.json", "c"), descriptor("/build/test.json", "d")]
        self.source = descriptor("/proof/source.json", "e")
        self.refs = {name: descriptor("/proof/" + name + ".json", digit)
                     for name, digit in zip(("qualified", "failed", "physical", "config", "checkpoint"), "12345")}
        self.qualified = dict(status="PASSED-CLOSED", public_identity_pass=True,
                              retained_artifacts={})
        inputs = {}
        for role, original in (("debug", self.main), ("instrumentation", self.test)):
            archive = dict(original, path="/archive/" + role + ".apk")
            self.qualified["retained_artifacts"][role] = dict(original=original, preserved=archive)
            inputs[role] = dict(original=original, archive=archive)
        self.cfg = dict(apk_paths=dict(debug=self.main["path"], instrumentation=self.test["path"]),
                        generated_container_inputs=inputs,
                        normal_outputs=[self.main, self.test] + self.metadata,
                        qualified_package=self.refs["qualified"])
        self.failed_cfg = dict(source=self.source, normal_outputs=copy.deepcopy(self.cfg["normal_outputs"]),
                               apk_paths=dict(self.cfg["apk_paths"]))
        self.failed = dict(status="FAILED-CLOSED", canonical_source=self.source,
                           configuration=self.refs["config"], runtime_physical_closure=self.refs["physical"])
        self.physical = dict(status="FAILED-PHYSICALLY-CLOSED", identities_absent_dual_proc_ps=True,
                             child_guardian_scopes_empty=True, locks_free_same_inode=True)
        self.records = dict(qualified=self.qualified, failed=self.failed, physical=self.physical,
                            config=self.failed_cfg)

    def authenticate(self, ref):
        for name, expected in self.refs.items():
            if ref == expected:
                return self.records[name]
        raise ValueError("Unknown authenticated descriptor")

    def checkpoint(self):
        generated = dict(self.main, sha256="f" * 64, bytes=12)
        self.cfg["normal_outputs"] = [generated, self.test] + self.metadata
        self.cfg["generated_container_inputs"]["debug"]["original"] = generated
        self.cfg.update(generated_input_checkpoint=self.refs["checkpoint"],
                        latest_failed_package=self.refs["failed"],
                        latest_failed_physical=self.refs["physical"])
        self.records["checkpoint"] = dict(
            status="UNQUALIFIED_GENERATED_MAIN_CHECKPOINT", public_qualified=False,
            failed_package=self.refs["failed"], physical_closure=self.refs["physical"],
            configuration=self.refs["config"], normal_outputs=copy.deepcopy(self.cfg["normal_outputs"]),
            changed=[[self.main, generated]])

    def derive(self):
        return derive_container_roles(self.cfg, self.authenticate,
                                      checkpoint_source=self.source if "checkpoint" in self.records else None)

    def test_qualified_inputs_and_independent_return(self):
        before = copy.deepcopy(self.cfg)
        result = self.derive()
        self.assertEqual({r["input_role"] for r in result.values()}, {"qualified-identical"})
        result["debug"]["original"]["path"] = "/changed"
        self.assertEqual(self.cfg, before)

    def test_distinct_generated_main_keeps_qualified_archive(self):
        self.checkpoint()
        result = self.derive()
        self.assertEqual(result["debug"]["input_role"], "generated-checkpoint")
        self.assertEqual(result["debug"]["archive"], self.qualified["retained_artifacts"]["debug"]["preserved"])
        self.assertEqual(result["instrumentation"]["input_role"], "qualified-identical")

    def test_unknown_changed_output_is_refused(self):
        self.cfg["normal_outputs"][0] = dict(self.main, sha256="f" * 64)
        self.cfg["generated_container_inputs"]["debug"]["original"] = self.cfg["normal_outputs"][0]
        with self.assertRaisesRegex(ValueError, "Unknown generated"):
            self.derive()

    def test_unknown_or_missing_role_is_refused(self):
        for role in ("release", "instrumentation"):
            with self.subTest(role=role):
                bad = copy.deepcopy(self.cfg)
                if role == "release":
                    bad["generated_container_inputs"][role] = bad["generated_container_inputs"]["debug"]
                else:
                    del bad["generated_container_inputs"][role]
                with self.assertRaises(ValueError):
                    derive_container_roles(bad, self.authenticate)

    def test_wrong_role_path_is_refused(self):
        self.cfg["apk_paths"]["debug"] = "/other/debug.apk"
        with self.assertRaises(ValueError):
            self.derive()

    def test_wrong_archive_even_with_same_bytes_is_refused(self):
        self.cfg["generated_container_inputs"]["debug"]["archive"] = dict(self.main, path="/unknown.apk")
        with self.assertRaisesRegex(ValueError, "Archive"):
            self.derive()

    def test_unqualified_archive_is_refused(self):
        self.qualified["public_identity_pass"] = False
        with self.assertRaises(ValueError):
            self.derive()

    def test_checkpoint_needs_independently_selected_source(self):
        self.checkpoint()
        for source in (None, descriptor("/proof/other-source.json")):
            with self.subTest(source=source), self.assertRaises(ValueError):
                derive_container_roles(self.cfg, self.authenticate, checkpoint_source=source)

    def test_wrong_source_in_failed_configuration_is_refused(self):
        self.checkpoint()
        self.failed_cfg["source"] = descriptor("/proof/wrong-source.json")
        with self.assertRaisesRegex(ValueError, "source"):
            self.derive()

    def test_checkpoint_provenance_mismatch_is_refused(self):
        self.checkpoint()
        for key in ("configuration", "failed_package", "physical_closure"):
            original = self.records["checkpoint"][key]
            self.records["checkpoint"][key] = descriptor("/proof/unknown.json")
            with self.subTest(key=key), self.assertRaisesRegex(ValueError, "provenance"):
                self.derive()
            self.records["checkpoint"][key] = original

    def test_open_failed_build_is_refused(self):
        self.checkpoint()
        for key in ("identities_absent_dual_proc_ps", "child_guardian_scopes_empty", "locks_free_same_inode"):
            self.physical[key] = False
            with self.subTest(key=key), self.assertRaisesRegex(ValueError, "physically closed"):
                self.derive()
            self.physical[key] = True

    def test_second_changed_output_is_refused(self):
        self.checkpoint()
        changed = dict(self.test, sha256="f" * 64)
        self.cfg["normal_outputs"][1] = changed
        self.records["checkpoint"]["normal_outputs"][1] = changed
        self.records["checkpoint"]["changed"].append([self.test, changed])
        self.cfg["generated_container_inputs"]["instrumentation"]["original"] = changed
        with self.assertRaisesRegex(ValueError, "only the named main"):
            self.derive()

    def test_duplicate_or_changed_checkpoint_output_is_refused(self):
        self.checkpoint()
        self.records["checkpoint"]["normal_outputs"].append(self.main)
        with self.assertRaisesRegex(ValueError, "Duplicate"):
            self.derive()

    def test_malformed_descriptor_is_refused(self):
        for bad in (dict(self.main, bytes=True), dict(self.main, path="/build/../debug.apk"),
                    dict(self.main, sha256="unknown")):
            with self.subTest(bad=bad):
                cfg = copy.deepcopy(self.cfg)
                cfg["normal_outputs"][0] = bad
                with self.assertRaises(ValueError):
                    derive_container_roles(cfg, self.authenticate)


if __name__ == "__main__":
    unittest.main()
