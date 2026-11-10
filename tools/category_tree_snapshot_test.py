import argparse
import contextlib
import gzip
import io
import itertools
import re
import tempfile
import sys
import unittest
from pathlib import Path
from unittest.mock import patch

sys.dont_write_bytecode = True
from category_tree_snapshot import build, rows
import category_tree_snapshot as snapshot


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


    def test_localized_multibyte_category_prefix_uses_original_database_key(self):
        for prefix in ("Catégorie", "分类", "Категория"):
            with self.subTest(prefix=prefix),tempfile.TemporaryDirectory(dir=".tmp") as directory:
                root=Path(directory)
                args=argparse.Namespace(**{name:root/name for name in ("xml","page","linktarget","categorylinks","database","output")})
                args.xml.write_text('<mediawiki><siteinfo><namespaces><namespace key="0" />'+
                                    '<namespace key="14">'+prefix+'</namespace></namespaces></siteinfo></mediawiki>')
                sql_dump(args.page,"page",("page_id","page_namespace","page_title"),
                         [(1,14,b"Parent"),(2,14,"Élément_vide".encode()),(3,0,b"word")])
                sql_dump(args.linktarget,"linktarget",("lt_id","lt_namespace","lt_title"),[(10,14,b"Parent")])
                sql_dump(args.categorylinks,"categorylinks",("cl_from","cl_sortkey","cl_type","cl_target_id"),[(3,b"word",b"page",10)])
                with contextlib.redirect_stdout(io.StringIO()):build(args)
                lines=[line.split('\t') for line in args.output.read_text().splitlines() if not line.startswith('#')]
                self.assertEqual(len(lines),4)
                self.assertIn(['Parent','main','word'],lines)
                self.assertIn(['Élément_vide','main'],lines)
                self.assertIn(['Élément_vide','pages'],lines)


    def test_quoted_run_patterns_preserve_row_and_field_match_boundaries(self):
        prior_row = re.compile(rb"\(((?:'(?:[^'\\]|\\.)*'|[^'()])*)\)")
        prior_field = re.compile(rb"'(?:[^'\\]|\\.)*'|[^,]+")
        samples = [b"(1,6,'a\\\'b,()\\\\tail')", b"(1,6,'')", b"(1,NULL,'a\\0b\\n\\Z\\q')",
            b"(1,6,'a' 'b')", b"(1,6,'missing", b"(1,6,'tail\\')", b"(1,6,'tail\\\n')",
            b"(1,6,'"+b"long_unescaped_title_"*4096+b"')",
            b"(1,6,'"+b"\\\'\\\\"*4096+b"')", b"(1,6,'"+b"x"*65536]
        samples.extend(b"("+bytes(value)+b")" for size in range(6)
            for value in itertools.product(b"a'\\,()\n0", repeat=size))
        for value in samples:
            expected = [(m.span(), m.span(1), m[1]) for m in prior_row.finditer(value)]
            self.assertEqual([(m.span(), m.span(1), m[1]) for m in snapshot.ROW.finditer(value)], expected)
            self.assertEqual(snapshot.FIELD.findall(value), prior_field.findall(value))

    def test_quoted_run_parser_preserves_values_prefix_and_late_error_semantics(self):
        prior_row = re.compile(rb"\(((?:'(?:[^'\\]|\\.)*'|[^'()])*)\)")
        prior_field = re.compile(rb"'(?:[^'\\]|\\.)*'|[^,]+")
        header = b"CREATE TABLE `linktarget` (\n  `lt_id` bigint,\n  `lt_namespace` int,\n  `lt_title` blob,\n);\n"
        good = b"INSERT INTO `linktarget` VALUES (1,6,'comma,paren()quote\\\'slash\\\\'),(2,0,'\\0\\n\\r\\t\\Z\\q'),(3,6,NULL);\n"
        variants = [header+good, header+good+b"INSERT INTO `linktarget` VALUES (4,6,'unterminated);\n",
            header+good+b"INSERT INTO `linktarget` VALUES (4,6);\n",
            header+good+b"INSERT INTO `linktarget` VALUES (4,6,'ok') trailing;\n",
            header+good+b"INSERT INTO `linktarget` VALUES (bad,6,'ok');\n",
            header+good+b"INSERT INTO `linktarget` VALUES (4,6,'ok'),\n",
            good, header[:-3]]
        def result(path, previous):
            values = []
            try:
                with contextlib.ExitStack() as stack:
                    if previous:
                        stack.enter_context(patch.object(snapshot, 'ROW', prior_row))
                        stack.enter_context(patch.object(snapshot, 'FIELD', prior_field))
                    values.extend(rows(path, ('lt_id', 'lt_namespace', 'lt_title')))
            except Exception as error:
                return values, type(error), str(error)
            return values, None, None
        Path('.tmp').mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(dir='.tmp') as directory:
            path = Path(directory)/'linktarget.sql.gz'
            for index, value in enumerate(variants):
                path.write_bytes(gzip.compress(value, mtime=0))
                before = path.read_bytes()
                old = result(path, True); current = result(path, False)
                with self.subTest(index=index):
                    self.assertEqual(current, old)
                    self.assertEqual(path.read_bytes(), before)
                    if index == 0:
                        self.assertIsNone(current[1])
                        self.assertEqual(current[0], [(1,6,b"comma,paren()quote'slash\\"), (2,0,b"\0\n\r\t\x1aq"), (3,6,None)])
                    else:
                        self.assertIsNotNone(current[1])
                        if index < 6: self.assertEqual(current[0][:3], [(1,6,b"comma,paren()quote'slash\\"), (2,0,b"\0\n\r\t\x1aq"), (3,6,None)])


if __name__ == "__main__":
    unittest.main()
