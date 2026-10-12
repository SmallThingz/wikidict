import hashlib
from pathlib import Path
import tempfile
import unittest
import xml.etree.ElementTree as ET

import generate_plural_rules as generator

DATA = Path(generator.__file__).resolve().parent / "data/mediawiki-plurals"
MODULE = Path(generator.__file__).resolve().parents[1] / "src/lua/runtime/plural_rules.zig"


class PluralGeneratorTests(unittest.TestCase):
    def test_checked_in_module_is_reproducible(self):
        self.assertEqual(MODULE.read_text(), generator.generate(DATA))

    def test_mediawiki_whole_family_override_preserves_positional_order(self):
        base = ET.fromstring((DATA / "plurals.xml").read_bytes())
        base_mt = next(row for row in base.findall(".//pluralRules") if "mt" in row.attrib["locales"].split())
        self.assertNotIn("two", [rule.attrib["count"] for rule in base_mt])
        rules = generator.load_rules(DATA)
        self.assertEqual([form for form, _ in rules["mt"]], ["one", "two", "few", "many"])
        self.assertEqual(rules["mt"][1][1], "n = 2")
        self.assertEqual(rules["ja"], ())
        self.assertIn("pt_PT", rules)
        self.assertNotIn("pt-PT", rules)

    def test_modified_pinned_input_is_refused(self):
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            for name in generator.PINS:
                (directory / name).write_bytes((DATA / name).read_bytes())
            (directory / "plurals.xml").write_bytes((directory / "plurals.xml").read_bytes() + b"\n")
            with self.assertRaisesRegex(ValueError, "Pinned plural source changed"):
                generator.load_rules(directory)

    def test_unrecognized_rule_syntax_fails_closed(self):
        for expression in ("n within 0..1", "n % 0 = 1", "n = 3..1", "n = 1; external()"):
            with self.subTest(expression=expression), self.assertRaises(ValueError):
                generator.condition(expression)


if __name__ == "__main__":
    unittest.main()
