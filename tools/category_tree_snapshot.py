#!/usr/bin/env python3
"""Build CategoryTree query results from one pinned Wikimedia SQL dump set.

Only build-time data is produced. SQLite is scratch storage, never a reader
dependency. Input files must come from the same dated dump as the page XML.
"""

import argparse
import gzip
import os
import re
import sqlite3
import time
import xml.etree.ElementTree as ET
from pathlib import Path


ROW = re.compile(rb"\(((?:'(?:[^'\\]|\\.)*'|[^'()])*)\)")
FIELD = re.compile(rb"'(?:[^'\\]|\\.)*'|[^,]+")
ESCAPE = re.compile(rb"\\(.)", re.DOTALL)
ESCAPES = {b"0": b"\0", b"n": b"\n", b"r": b"\r", b"t": b"\t", b"Z": b"\x1a"}


def unquote(value):
    if value == b"NULL":
        return None
    if not value.startswith(b"'"):
        return int(value)
    return ESCAPE.sub(lambda m: ESCAPES.get(m[1], m[1]), value[1:-1])


def rows(path, wanted):
    """Read mysqldump quoted strings without interpreting binary sort keys."""
    columns = []
    indexes = None
    in_schema = False
    in_insert = False
    with gzip.open(path, "rb") as source:
        for line in source:
            if line.startswith(b"CREATE TABLE "):
                in_schema = True
            elif in_schema and line.startswith(b"  `"):
                columns.append(line.split(b"`", 2)[1].decode("ascii"))
            elif in_schema and line.startswith(b")"):
                in_schema = False
                indexes = [columns.index(name) for name in wanted]
            if line.startswith(b"INSERT INTO "):
                in_insert = True
                line = line.split(b" VALUES", 1)[1]
            elif not in_insert:
                continue
            if indexes is None:
                raise ValueError(f"Missing schema in {path}")
            cursor = 0
            for match in ROW.finditer(line):
                if line[cursor:match.start()].strip(b" \t\r\n,"):
                    raise ValueError(f"Unsupported SQL syntax in {path}")
                cursor = match.end()
                fields = FIELD.findall(match[1])
                if len(fields) != len(columns):
                    raise ValueError(f"Invalid SQL row in {path}")
                yield tuple(unquote(fields[index]) for index in indexes)
            if line[cursor:].strip(b" \t\r\n,;"):
                raise ValueError(f"Unsupported SQL syntax in {path}")
            if line.rstrip().endswith(b";"):
                in_insert = False


def namespaces(xml):
    for _, element in ET.iterparse(xml, events=("end",)):
        if element.tag.rsplit("}", 1)[-1] == "namespaces":
            return {int(child.attrib["key"]): (child.text or "").encode() for child in element}
    raise ValueError("XML has no namespace table")


def import_rows(db, sql, values, label):
    print(f"Importing {label}", flush=True)
    batch = []
    count = 0
    started = time.monotonic()
    for value in values:
        batch.append(value)
        if len(batch) == 10000:
            db.executemany(sql, batch)
            count += len(batch)
            batch.clear()
            if count % 1000000 == 0:
                db.commit()
                print(f"{label}: {count:,} rows, {time.monotonic() - started:.1f}s", flush=True)
    db.executemany(sql, batch)
    db.commit()
    print(f"{label}: complete, {count + len(batch):,} rows", flush=True)


def build(args):
    ns = namespaces(args.xml)
    staging = args.output.with_name(args.output.name + ".incomplete")
    if args.database.exists() or args.output.exists() or staging.exists():
        raise ValueError("Use new scratch database and output paths")
    os.environ["SQLITE_TMPDIR"] = str(args.database.parent.resolve())
    db = sqlite3.connect(args.database)
    db.execute("PRAGMA journal_mode=OFF")
    db.execute("PRAGMA synchronous=OFF")
    db.execute("PRAGMA cache_size=-65536")
    db.execute("PRAGMA temp_store=FILE")
    db.executescript("""
        CREATE TABLE pages(id INTEGER PRIMARY KEY, ns INTEGER, title BLOB);
        CREATE TABLE targets(id INTEGER PRIMARY KEY, title BLOB);
        CREATE TABLE links(target INTEGER, kind INTEGER, sortkey BLOB, from_id INTEGER);
    """)

    def pages():
        for page_id, namespace, title in rows(args.page, ("page_id", "page_namespace", "page_title")):
            prefix = ns[namespace]
            yield page_id, namespace, (prefix + b":" if prefix else b"") + title.replace(b"_", b" ")

    import_rows(db, "INSERT INTO pages VALUES (?,?,?)", pages(), "pages")
    import_rows(db, "INSERT INTO targets VALUES (?,?)",
                ((page_id, title) for page_id, namespace, title in rows(
                    args.linktarget, ("lt_id", "lt_namespace", "lt_title")) if namespace == 14), "categories")
    db.execute("CREATE UNIQUE INDEX target_title ON targets(title)")
    import_rows(db, "INSERT INTO links VALUES (?,?,?,?)",
                ((target, 0 if kind == b"page" else 1, key, page_id)
                 for page_id, key, kind, target in rows(
                     args.categorylinks, ("cl_from", "cl_sortkey", "cl_type", "cl_target_id"))
                 if kind in (b"page", b"subcat")), "memberships")
    print("Indexing category members in MediaWiki order", flush=True)
    db.execute("CREATE INDEX member_order ON links(target,kind,sortkey,from_id)")
    db.commit()

    def write_category(out, category, main, pages):
        # SQL LIMIT precedes CategoryTree's display regrouping of subcategories.
        for scope, members in ((b"main", main), (b"pages", pages)):
            fields = [category, scope, *members]
            if any(b"\t" in field or b"\n" in field or b"\r" in field for field in fields):
                raise ValueError("Invalid title in category snapshot")
            out.write(b"\t".join(fields) + b"\n")

    with staging.open("xb") as out:
        out.write(b"# CategoryTree v2: category_db_key\tscope(main|pages)\tmember_titles...\n")
        previous = None
        main = []
        page_members = []
        # The join uses the covering member_order index, with bounded SQLite RAM.
        for category, namespace, title in db.execute("""
            SELECT t.title,p.ns,p.title FROM links l INDEXED BY member_order
            JOIN targets t ON t.id=l.target JOIN pages p ON p.id=l.from_id
            ORDER BY l.target,l.kind,l.sortkey,l.from_id
        """):
            if category != previous:
                if previous is not None:
                    write_category(out, previous, main, page_members)
                previous = category
                main = []
                page_members = []
            if len(page_members) < 200:
                page_members.append(title)
            if namespace == 0 and len(main) < 200:
                main.append(title)
        if previous is not None:
            write_category(out, previous, main, page_members)
        # Explicit empty results are distinct from missing snapshot coverage.
        for (category,) in db.execute("""
            SELECT t.title FROM targets t WHERE NOT EXISTS
            (SELECT 1 FROM links l JOIN pages p ON p.id=l.from_id WHERE l.target=t.id)
        """):
            write_category(out, category, [], [])
        for (title,) in db.execute("""
            SELECT p.title FROM pages p WHERE p.ns=14 AND NOT EXISTS
            (SELECT 1 FROM targets t WHERE t.title=CAST(replace(substr(p.title,10),' ','_') AS BLOB))
        """):
            write_category(out, title[len(b"Category:"):].replace(b" ", b"_"), [], [])
    db.close()
    staging.rename(args.output)
    print(f"Snapshot complete: {args.output}", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("xml", "page", "linktarget", "categorylinks", "database", "output"):
        parser.add_argument("--" + name, type=Path, required=True)
    build(parser.parse_args())


if __name__ == "__main__":
    main()
