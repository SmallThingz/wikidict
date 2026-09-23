#!/usr/bin/env python3
"""Download the latest complete XML/SQL snapshots of every Wiktionary edition.

Uses Python for discovery and aria2 for transfers. Dated URLs, resume, checksums, atomic
publication and at most three connections keep reruns safe and predictable.
"""
import argparse
import concurrent.futures
import hashlib
import json
import os
import shutil
import subprocess
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

def validate_item(item):
    if not re.fullmatch(r"[a-z0-9_]+wiktionary", item["wiki"]) or not re.fullmatch(r"[0-9]{8}", item["date"]):
        raise ValueError("Invalid snapshot identity")
    if not re.fullmatch(r"[A-Za-z0-9_.-]+", item["name"]) or item["name"] in (".", ".."):
        raise ValueError("Invalid filename")
    if item["url"] != f"{BASE}/{item['wiki']}/{item['date']}/{item['name']}":
        raise ValueError("Unexpected dump URL")
    if not re.fullmatch(r"[a-f0-9]{40}", item["sha1"]) or not isinstance(item["size"], int) or item["size"] <= 0:
        raise ValueError("Invalid checksum or size")

def aria2_queue(files, root):
    lines = []
    for item in files:
        validate_item(item)
        directory = (root / item["wiki"] / item["date"]).resolve()
        for field in (str(directory), item["name"], item["url"]):
            if any(c in field for c in "\r\n\t"):
                raise ValueError("Unsafe download queue field")
        lines.extend([item["url"], f"  dir={directory}", f"  out={item['name']}.part",
                      f"  checksum=sha-1={item['sha1']}"])
    return "\n".join(lines) + "\n"

def download_all(files, root, connections):
    for item in files:
        validate_item(item)
    executable = shutil.which("aria2c")
    if not executable:
        raise SystemExit("Install aria2 first: sudo pacman -S aria2 (Arch), sudo apt install aria2 (Debian/Ubuntu), or brew install aria2 (macOS). Then rerun the same command.")
    pending = []
    for item in files:
        target = root / item["wiki"] / item["date"] / item["name"]
        if target.exists() and target.stat().st_size == item["size"] and digest(target) == item["sha1"]:
            print("verified", target, flush=True)
        else:
            pending.append(item)
    if not pending:
        return
    queue = root / "downloads.aria2.txt"
    queue.write_text(aria2_queue(pending, root))
    command = [executable, "--no-conf", "--continue=true", "--check-integrity=true",
               "--auto-file-renaming=false", "--allow-overwrite=true", "--file-allocation=none",
               "--split=1", "--max-connection-per-server=1", f"--max-concurrent-downloads={connections}",
               "--max-tries=10", "--retry-wait=5", "--connect-timeout=30", "--timeout=60",
               "--auto-save-interval=5", "--summary-interval=1", "--show-console-readout=true",
               "--download-result=full", "--console-log-level=warn", f"--user-agent={AGENT}",
               f"--save-session={root / 'downloads.session'}", "--save-session-interval=5",
               f"--input-file={queue}"]
    print("Downloading with aria2. Ctrl-C stops safely; rerun with --resume to continue.", flush=True)
    try:
        result = subprocess.run(command)
    except KeyboardInterrupt:
        raise SystemExit("Stopped. Partial files and aria2 resume state are retained; rerun with --resume.")
    failures = []
    for item in pending:
        target = root / item["wiki"] / item["date"] / item["name"]
        partial = target.with_name(target.name + ".part")
        control = Path(str(partial) + ".aria2")
        if partial.exists() and not control.exists() and partial.stat().st_size == item["size"] and digest(partial) == item["sha1"]:
            os.replace(partial, target)
        else:
            failures.append(item["name"])
    if result.returncode or failures:
        raise SystemExit(f"{len(failures)} downloads incomplete. Resume with the same --output and --resume.")

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=Path("data/dumps"))
    parser.add_argument("--wikis", nargs="+", help="Edition IDs, e.g. enwiktionary simplewiktionary; default: all")
    parser.add_argument("--connections", type=int, choices=range(1, 4), default=2)
    parser.add_argument("--xml-only", action="store_true", help="Omit companion SQL snapshots")
    parser.add_argument("--plan", action="store_true", help="Resolve and save manifest without downloading dump files")
    parser.add_argument("--resume", action="store_true", help="Use the saved manifest, preserving snapshot dates across restarts")
    args = parser.parse_args()
    if args.resume:
        manifest = json.loads((args.output / "manifest.json").read_text())
        if args.plan:
            print(f"{len(manifest['files'])} files in saved manifest")
        else:
            download_all(manifest["files"], args.output, args.connections)
        return
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
        download_all(files, args.output, args.connections)
    for error in failures:
        print("FAILED:", error)
    if failures:
        raise SystemExit(1)

if __name__ == "__main__":
    main()
