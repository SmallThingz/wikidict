import argparse
import contextlib
import gzip
import io
import tempfile
import sys
import unittest
from pathlib import Path

sys.dont_write_bytecode = True
from category_tree_snapshot import build, rows


def sql_dump(path, table, columns, records):
    def literal(value):
        if isinstance(value, int):
            return str(value).encode()
        return b"'" + value.replace(b"\\", b"\\\\").replace(b"'", b"\\'").replace(b"\n", b"\\n").replace(b"\0", b"\\0") + b"'"

    with gzip.open(path, "wb") as out:
        out.write(b"CREATE TABLE `" + table.encode() + b"` (\n")
        for column in columns:
            out.write(b"  `" + column.encode() + b"` blob,\n")
        out.write(b");\nINSERT INTO `" + table.encode() + b"` VALUES\n")
        for index, record in enumerate(records):
            out.write(b"(" + b",".join(map(literal, record)) + b")" + (b";\n" if index == len(records) - 1 else b",\n"))


class CategorySnapshotTest(unittest.TestCase):
    def test_binary_order_namespace_filter_and_limit(self):
        Path(".tmp").mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(dir=".tmp") as directory:
            root = Path(directory)
            args = argparse.Namespace(**{name: root / name for name in (
                "xml", "page", "linktarget", "categorylinks", "database", "output")})
            args.xml.write_text('<mediawiki><siteinfo><namespaces><namespace key="0" />'
                                '<namespace key="1">Talk</namespace><namespace key="14">Category</namespace>'
                                '</namespaces></siteinfo></mediawiki>')
            pages = [(1, 14, b"Parent"), (2, 14, b"Empty"), (3, 14, b"Unlinked"),
                     (4, 14, b"Child"), (5, 1, b"Talk_member")]
            pages += [(100 + i, 0, f"word_{i:03}".encode()) for i in range(205)]
            sql_dump(args.page, "page", ("page_id", "page_namespace", "page_title"), pages)
            sql_dump(args.linktarget, "linktarget", ("lt_id", "lt_namespace", "lt_title"),
                     [(10, 14, b"Parent"), (11, 14, b"Empty"), (12, 0, b"ignored")])
            # Talk sorts first, but must not consume a main-namespace limit slot.
            members = [(5, b"\0'\\()\n", b"page", 10), (4, b"AAA", b"subcat", 10)]
            members += [(100 + i, f"key{i:03}".encode(), b"page", 10) for i in reversed(range(205))]
            sql_dump(args.categorylinks, "categorylinks", ("cl_from", "cl_sortkey", "cl_type", "cl_target_id"), members)
            self.assertEqual(next(rows(args.categorylinks, ("cl_sortkey",)))[0], b"\0'\\()\n")
            with contextlib.redirect_stdout(io.StringIO()):
                build(args)
            result = {}
            for line in args.output.read_text().splitlines():
                if line.startswith("#"):
                    continue
                category, scope, *titles = line.split("\t")
                result[category, scope] = titles
            self.assertEqual(result["Parent", "main"], [f"word {i:03}" for i in range(200)])
            self.assertEqual(result["Parent", "pages"], ["Talk:Talk member"] + [f"word {i:03}" for i in range(199)])
            self.assertEqual(result["Empty", "main"], [])
            self.assertEqual(result["Unlinked", "pages"], [])
            self.assertNotIn(("ignored", "main"), result)


if __name__ == "__main__":
    unittest.main()
