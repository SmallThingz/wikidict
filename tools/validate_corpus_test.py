import argparse
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

sys.dont_write_bytecode = True
from validate_corpus import validate


class CorpusPublicationTest(unittest.TestCase):
    def test_publication_requires_complete_encoding_and_verification(self):
        Path(".tmp").mkdir(exist_ok=True)
        for scenario in ("pass", "encode_failure", "short_corpus", "verify_failure"):
            with self.subTest(scenario=scenario), tempfile.TemporaryDirectory(dir=".tmp") as directory:
                root = Path(directory)
                (root / "page-index.tsv").write_text("# index\npage one\npage two\n")
                args = argparse.Namespace(builder=Path("builder"), verifier=Path("verifier"), dump=root / "dump",
                                          expander_root=root, output=root / "published", report=root / "report", workers=2)

                def run(argv, **kwargs):
                    if argv[0] == "builder":
                        self.assertTrue((root / ".published.building" / ".incomplete").exists())
                        if scenario == "encode_failure":
                            raise subprocess.CalledProcessError(1, argv)
                        kwargs["stdout"].write(f"pages={1 if scenario == 'short_corpus' else 2} main_pages=2\n")
                    else:
                        self.assertEqual(argv[0], "verifier")
                        self.assertFalse(args.output.exists())
                        if scenario == "verify_failure":
                            raise subprocess.CalledProcessError(1, argv)

                with patch("validate_corpus.subprocess.run", side_effect=run):
                    if scenario == "pass":
                        validate(args)
                    else:
                        with self.assertRaises((subprocess.CalledProcessError, ValueError)):
                            validate(args)
                status = json.loads((args.report / "status.json").read_text())
                self.assertEqual(status["state"], "passed" if scenario == "pass" else "failed")
                self.assertEqual(args.output.exists(), scenario == "pass")
                if scenario != "pass":
                    self.assertTrue((root / ".published.building" / ".incomplete").exists())


if __name__ == "__main__":
    unittest.main()
