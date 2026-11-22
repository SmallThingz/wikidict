import argparse
import gzip
import hashlib
import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.dont_write_bytecode = True
from category_stats_snapshot import build


def fixture(root):
    wiki, date = "enwiktionary", "20260901"
    source = root / f"{wiki}-{date}-category.sql.gz"
    with gzip.open(source, "wb") as out:
        out.write(b"CREATE TABLE `category` (\n")
        for field in ("cat_id", "cat_title", "cat_pages", "cat_subcats", "cat_files"):
            out.write(f"  `{field}` blob,\n".encode())
        out.write(b");\nINSERT INTO `category` VALUES\n")
        out.write(b"(1,'English_words',17,2,1),\n")
        out.write(b"(2,'A\\'s_words',3,0,0);\n")
    raw = source.read_bytes()
    manifest = root / "downloads.json"
    manifest.write_text(json.dumps({"files": [{
        "wiki": wiki, "date": date, "name": source.name,
        "url": f"https://dumps.wikimedia.org/{wiki}/{date}/{source.name}",
        "size": len(raw), "sha1": hashlib.sha1(raw).hexdigest(),
    }]}))
    args = argparse.Namespace(
        category_sql=source, download_manifest=manifest, wiki=wiki, date=date,
        output=root / "category-stats.tsv",
        output_manifest=root / "category-stats.manifest.json",
    )
    return args


class CategoryStatsSnapshotTest(unittest.TestCase):
    def test_exact_counts_provenance_and_no_extra_rows(self):
        with tempfile.TemporaryDirectory() as directory:
            args = fixture(Path(directory))
            build(args)
            output = args.output.read_bytes()
            self.assertEqual(output, b"English_words\t17\t2\t1\nA's_words\t3\t0\t0\n")
            metadata = json.loads(args.output_manifest.read_text())
            self.assertEqual(metadata["rows"], 2)
            self.assertEqual(metadata["output_sha256"], hashlib.sha256(output).hexdigest())
            self.assertEqual(metadata["source_sha1"], hashlib.sha1(args.category_sql.read_bytes()).hexdigest())

    def test_reject_unverified_source_without_publishing(self):
        with tempfile.TemporaryDirectory() as directory:
            args = fixture(Path(directory))
            with args.category_sql.open("ab") as out:
                out.write(b"corruption")
            with self.assertRaisesRegex(ValueError, "does not match"):
                build(args)
            self.assertFalse(args.output.exists())
            self.assertFalse(args.output_manifest.exists())

    def test_reject_impossible_counts(self):
        with tempfile.TemporaryDirectory() as directory:
            args = fixture(Path(directory))
            with gzip.open(args.category_sql, "wb") as out:
                out.write(b"CREATE TABLE `category` (\n")
                for field in ("cat_id", "cat_title", "cat_pages", "cat_subcats", "cat_files"):
                    out.write(f"  `{field}` blob,\n".encode())
                out.write(b");\nINSERT INTO `category` VALUES\n(1,'Bad',1,1,1);\n")
            raw = args.category_sql.read_bytes()
            manifest = json.loads(args.download_manifest.read_text())
            manifest["files"][0]["size"] = len(raw)
            manifest["files"][0]["sha1"] = hashlib.sha1(raw).hexdigest()
            args.download_manifest.write_text(json.dumps(manifest))
            with self.assertRaisesRegex(ValueError, "Invalid category counts"):
                build(args)
            self.assertFalse(args.output.exists())
            self.assertFalse(args.output_manifest.exists())
            self.assertFalse(args.output.with_name(args.output.name + ".incomplete").exists())


if __name__ == "__main__":
    unittest.main()
