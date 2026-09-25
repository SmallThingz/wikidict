#!/usr/bin/env python3
"""Stream a dated MediaWiki category SQL dump into category-stats.tsv.

The source must match a verified download manifest for the same wiki/date as
the page dump. No absent category rows are synthesized; the runtime treats an
absent row as zero only when this complete category snapshot is installed.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path

from category_tree_snapshot import rows


LIMIT = 2**32 - 1
WANTED = ("cat_title", "cat_pages", "cat_subcats", "cat_files")


def fingerprint(path):
    sha1 = hashlib.sha1()
    sha256 = hashlib.sha256()
    size = 0
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            sha1.update(block)
            sha256.update(block)
            size += len(block)
    return size, sha1.hexdigest(), sha256.hexdigest()


def verified_source(source, download_manifest, wiki, date):
    name = f"{wiki}-{date}-category.sql.gz"
    if source.name != name:
        raise ValueError(f"Expected {name}, got {source.name}")
    with download_manifest.open("r", encoding="utf-8") as stream:
        manifest = json.load(stream)
    matches = [item for item in manifest["files"]
               if item.get("name") == name and item.get("wiki") == wiki
               and item.get("date") == date]
    if len(matches) != 1:
        raise ValueError("Missing or ambiguous category SQL in download manifest")
    record = matches[0]
    size, sha1, sha256 = fingerprint(source)
    if size != record["size"] or sha1 != record["sha1"]:
        raise ValueError("Category SQL does not match verified download manifest")
    return record, size, sha1, sha256


def build(args):
    source = args.category_sql
    output = args.output
    manifest_path = args.output_manifest
    if output.exists() or manifest_path.exists():
        raise ValueError("Use new output and manifest paths")
    source_record, source_size, source_sha1, source_sha256 = verified_source(
        source, args.download_manifest, args.wiki, args.date)
    staging = output.with_name(output.name + ".incomplete")
    manifest_staging = manifest_path.with_name(manifest_path.name + ".incomplete")
    if staging.exists() or manifest_staging.exists():
        raise ValueError("Incomplete output already exists")

    digest = hashlib.sha256()
    output_size = 0
    count = 0
    try:
        with staging.open("xb") as dest:
            for title, all_count, subcats, files in rows(source, WANTED):
                if (not isinstance(title, bytes) or not title or
                        any(byte in title for byte in (b"\t", b"\r", b"\n"))):
                    raise ValueError("Invalid category title")
                if (not all(isinstance(value, int) and 0 <= value <= LIMIT
                            for value in (all_count, subcats, files)) or
                        subcats + files > all_count):
                    raise ValueError("Invalid category counts")
                line = (title + b"\t" + str(all_count).encode() + b"\t" +
                        str(subcats).encode() + b"\t" + str(files).encode() + b"\n")
                dest.write(line)
                digest.update(line)
                output_size += len(line)
                count += 1
            dest.flush()
            os.fsync(dest.fileno())
        if count == 0:
            raise ValueError("Empty category SQL dump")
        provenance = {
            "wiki": args.wiki,
            "date": args.date,
            "source": source.name,
            "source_url": source_record["url"],
            "source_bytes": source_size,
            "source_sha1": source_sha1,
            "source_sha256": source_sha256,
            "output": output.name,
            "output_bytes": output_size,
            "output_sha256": digest.hexdigest(),
            "rows": count,
            "columns": ["cat_title", "cat_pages", "cat_subcats", "cat_files"],
            "mapping": "category_db_key,all,subcats,files; pages=all-subcats-files",
        }
        with manifest_staging.open("x", encoding="utf-8") as dest:
            json.dump(provenance, dest, indent=2, sort_keys=True)
            dest.write("\n")
            dest.flush()
            os.fsync(dest.fileno())
        staging.rename(output)
        manifest_staging.rename(manifest_path)
    finally:
        staging.unlink(missing_ok=True)
        manifest_staging.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--category-sql", type=Path, required=True)
    parser.add_argument("--download-manifest", type=Path, required=True)
    parser.add_argument("--wiki", required=True)
    parser.add_argument("--date", required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--output-manifest", type=Path, required=True)
    build(parser.parse_args())


if __name__ == "__main__":
    main()
