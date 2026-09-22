#!/usr/bin/env python3
"""Download the latest complete XML/SQL snapshots of every Wiktionary edition.

Uses only the Python standard library. Dated URLs, resume, checksums, atomic
publication and at most three connections keep reruns safe and predictable.
"""
import argparse
import concurrent.futures
import hashlib
import json
import os
from pathlib import Path
import re
import time
import urllib.error
import urllib.parse
import urllib.request

BASE = "https://dumps.wikimedia.org"
AGENT = "Wikidict/1.0 (https://github.com/SmallThingz/wikidict)"
JOBS = ("metacurrentdump", "categorytable", "categorylinkstable", "pagepropstable", "redirecttable", "sitestatstable", "linktargettable")

def request(url, offset=0):
    headers = {"User-Agent": AGENT}
    if offset:
        headers["Range"] = f"bytes={offset}-"
    return urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=120)

def fetch(url):
    for attempt in range(4):
        try:
            with request(url) as response:
                return response.read(16 * 1024 * 1024).decode("utf-8")
        except (OSError, urllib.error.URLError):
            if attempt == 3:
                raise
            time.sleep(2 ** attempt)

def editions():
    return sorted(set(re.findall(r'href=["\'](?:https://dumps.wikimedia.org/)?/?([a-z0-9_]+wiktionary)/', fetch(BASE + "/backup-index.html"))))

def snapshot(wiki, jobs):
    if not re.fullmatch(r"[a-z0-9_]+wiktionary", wiki):
        raise ValueError(f"Invalid edition: {wiki}")
    dates = sorted(set(re.findall(r'href=["\'](\d{8})/', fetch(f"{BASE}/{wiki}/"))), reverse=True)
    for date in dates:
        status = json.loads(fetch(f"{BASE}/{wiki}/{date}/dumpstatus.json"))["jobs"]
        if not all(status.get(job, {}).get("status") == "done" for job in jobs):
            continue
        files = []
        for job in jobs:
            for name, info in sorted(status[job]["files"].items()):
                if Path(name).name != name or not name.startswith(f"{wiki}-{date}-"):
                    raise ValueError("Invalid dump filename")
                url = urllib.parse.urljoin(BASE, info["url"])
                if not url.startswith(f"{BASE}/{wiki}/{date}/"):
                    raise ValueError("Unexpected dump URL")
                if not re.fullmatch(r"[a-f0-9]{40}", info.get("sha1", "")) or info["size"] <= 0:
                    raise ValueError("Missing checksum or size")
                files.append(dict(wiki=wiki, date=date, name=name, url=url, size=info["size"], sha1=info["sha1"]))
        return files
    raise ValueError(f"No complete snapshot for {wiki}")

def digest(path):
    with path.open("rb") as source:
        return hashlib.file_digest(source, "sha1").hexdigest()

def download(item, root):
    target = root / item["wiki"] / item["date"] / item["name"]
    target.parent.mkdir(parents=True, exist_ok=True)
    if target.exists() and target.stat().st_size == item["size"] and digest(target) == item["sha1"]:
        return "verified " + str(target)
    partial = target.with_name(target.name + ".part")
    for attempt in range(4):
        try:
            offset = partial.stat().st_size if partial.exists() else 0
            if offset >= item["size"]:
                if offset == item["size"] and digest(partial) == item["sha1"]:
                    os.replace(partial, target)
                    return "downloaded " + str(target)
                partial.unlink()
                offset = 0
            with request(item["url"], offset) as response:
                if offset and response.status != 206:
                    offset = 0
                if response.status == 206:
                    expected = f"bytes {offset}-"
                    if not response.headers.get("Content-Range", "").startswith(expected):
                        raise ValueError("Incorrect resume range")
                with partial.open("ab" if offset else "wb") as out:
                    total = offset
                    while chunk := response.read(1024 * 1024):
                        total += len(chunk)
                        if total > item["size"]:
                            raise ValueError("Download exceeds published size")
                        out.write(chunk)
                    out.flush()
                    os.fsync(out.fileno())
            if partial.stat().st_size != item["size"]:
                raise OSError("Incomplete download; retrying")
            if digest(partial) != item["sha1"]:
                partial.unlink()
                raise OSError("Checksum mismatch; retrying")
            os.replace(partial, target)
            return "downloaded " + str(target)
        except (OSError, urllib.error.URLError):
            if attempt == 3:
                raise
            time.sleep(2 ** attempt)

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=Path("data/dumps"))
    parser.add_argument("--wikis", nargs="+", help="Edition IDs, e.g. enwiktionary simplewiktionary; default: all")
    parser.add_argument("--connections", type=int, choices=range(1, 4), default=2)
    parser.add_argument("--xml-only", action="store_true", help="Omit companion SQL snapshots")
    parser.add_argument("--plan", action="store_true", help="Resolve and save manifest without downloading dump files")
    args = parser.parse_args()
    files, failures = [], []
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.connections) as pool:
        jobs = {pool.submit(snapshot, wiki, JOBS[:1] if args.xml_only else JOBS): wiki for wiki in (args.wikis or editions())}
        for future in concurrent.futures.as_completed(jobs):
            try:
                files.extend(future.result())
            except Exception as error:
                failures.append(f"{jobs[future]}: {error}")
        files.sort(key=lambda x: (x["wiki"], x["name"]))
        args.output.mkdir(parents=True, exist_ok=True)
        manifest = args.output / "manifest.json"
        tmp = manifest.with_suffix(".part")
        tmp.write_text(json.dumps(dict(files=files, failures=failures), indent=2) + "\n")
        os.replace(tmp, manifest)
        print(f"{len(files)} files, {sum(x['size'] for x in files):,} bytes; manifest: {manifest}", flush=True)
        if not args.plan:
            jobs = {pool.submit(download, item, args.output): item for item in files}
            for future in concurrent.futures.as_completed(jobs):
                try:
                    print(future.result(), flush=True)
                except Exception as error:
                    failures.append(f"{jobs[future]['name']}: {error}")
    for error in failures:
        print("FAILED:", error)
    if failures:
        raise SystemExit(1)

if __name__ == "__main__":
    main()
