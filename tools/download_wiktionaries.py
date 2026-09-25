#!/usr/bin/env python3
"""Download the latest complete XML/SQL snapshots of every Wiktionary edition.

Uses Python for discovery and aria2 for transfers. Dated URLs, resume, checksums, atomic
publication and at most three connections keep reruns safe and predictable.
"""
import argparse
import concurrent.futures
import datetime
import hashlib
import functools
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path
import re
import time
import unicodedata
import urllib.error
import urllib.parse
import urllib.request

BASE = "https://dumps.wikimedia.org"
AGENT = "Wikidict/1.0 (https://github.com/SmallThingz/wikidict)"
JOBS = ("metacurrentdump", "categorytable", "categorylinkstable", "pagepropstable", "redirecttable", "sitestatstable", "linktargettable")
ISO_639_3_PATHS = (
    Path("/usr/share/iso-codes/json/iso_639-3.json"),
    Path("/usr/local/share/iso-codes/json/iso_639-3.json"),
)

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

def wiktionary_api(wiki):
    if not re.fullmatch(r"[a-z0-9_]+wiktionary", wiki):
        raise ValueError(f"Invalid edition: {wiki}")
    prefix = wiki[:-len("wiktionary")].replace("_", "-")
    return f"https://{prefix}.wiktionary.org/w/api.php"

def siteinfo(wiki, props, language=None):
    query = {
        "action": "query",
        "meta": "siteinfo",
        "siprop": props,
        "format": "json",
        "formatversion": "2",
    }
    if language is not None:
        query["siinlanguagecode"] = language
    data = json.loads(fetch(wiktionary_api(wiki) + "?" + urllib.parse.urlencode(query)))
    result = data.get("query")
    if not isinstance(result, dict):
        raise ValueError(f"Invalid siteinfo response for {wiki}")
    return result


def interwiki_map_snapshot(wiki, output):
    """Capture the current MediaWiki interwiki map with its retrieval provenance.

    This API response is current at retrieval time, not part of a dated dump.
    """
    query = {"action": "query", "meta": "siteinfo", "siprop": "interwikimap",
             "format": "json", "formatversion": "2"}
    url = wiktionary_api(wiki) + "?" + urllib.parse.urlencode(query)
    root = output / wiki
    if root.exists() or root.is_symlink():
        raise ValueError(f"Interwiki snapshot already exists: {root}")
    temporary = output / ("." + wiki + ".interwiki-map.part")
    if temporary.exists() or temporary.is_symlink():
        raise ValueError(f"Incomplete interwiki snapshot already exists: {temporary}")
    request = urllib.request.Request(url, headers={"User-Agent": AGENT})
    with urllib.request.urlopen(request, timeout=30) as response:
        raw = response.read(2 * 1024 * 1024 + 1)
    retrieved = datetime.datetime.now(datetime.timezone.utc).isoformat()
    if len(raw) > 2 * 1024 * 1024:
        raise ValueError("Interwiki API response exceeds 2 MiB")
    data = json.loads(raw)
    rows = data.get("query", {}).get("interwikimap") if isinstance(data, dict) else None
    if not isinstance(rows, list) or not rows or len(rows) > 10_000:
        raise ValueError("Missing or invalid interwiki map")

    def field(value):
        return value.replace("\\", "\\\\").replace("\t", "\\t").replace("\n", "\\n").replace("\r", "\\r")

    lines = []
    prefixes = set()
    for row in rows:
        if not isinstance(row, dict):
            raise ValueError("Invalid interwiki row")
        prefix, target = row.get("prefix"), row.get("url")
        if not isinstance(prefix, str) or not prefix or not isinstance(target, str) or not target:
            raise ValueError("Invalid interwiki prefix or URL")
        if prefix.casefold() in prefixes:
            raise ValueError(f"Duplicate interwiki prefix: {prefix}")
        prefixes.add(prefix.casefold())
        for flag in ("local", "localinterwiki", "protorel", "trans"):
            if flag in row and type(row[flag]) is not bool:
                raise ValueError(f"Invalid interwiki flag: {flag}")
        # siteinfo exposes localinterwiki for prefixes targeting this wiki.
        # Its current response does not expose transcludability; absent flags
        # remain false rather than inventing external transclusion behavior.
        lines.append("\t".join((field(prefix),
                                 "1" if row.get("local", False) else "0",
                                 "1" if row.get("localinterwiki", False) else "0",
                                 "1" if row.get("protorel", False) else "0",
                                 "1" if row.get("trans", False) else "0",
                                 field(target))))
    tsv = ("\n".join(lines) + "\n").encode("utf-8")
    provenance = {"wiki": wiki, "kind": "current-siteinfo-interwikimap",
                  "retrieved_utc": retrieved, "source_url": url, "rows": len(rows),
                  "raw_bytes": len(raw), "raw_sha256": hashlib.sha256(raw).hexdigest(),
                  "tsv_bytes": len(tsv), "tsv_sha256": hashlib.sha256(tsv).hexdigest(),
                  "dump_date": None,
                  "transcludability_note": "Missing API trans flags are represented as false"}
    output.mkdir(parents=True, exist_ok=True)
    temporary.mkdir(exist_ok=False)
    try:
        (temporary / "interwiki-map.raw.json").write_bytes(raw)
        (temporary / "interwiki-map.tsv").write_bytes(tsv)
        (temporary / "interwiki-map.provenance.json").write_text(
            json.dumps(provenance, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        os.rename(temporary, root)
    except BaseException:
        shutil.rmtree(temporary)
        raise
    return root / "interwiki-map.tsv", provenance

@functools.lru_cache(maxsize=4)
def _load_iso_639_3(path):
    data = json.loads(Path(path).read_text(encoding="utf-8"))
    rows = data.get("639-3")
    if not isinstance(rows, list) or not rows:
        raise ValueError(f"Invalid ISO 639-3 data: {path}")
    return tuple(rows)

def iso_639_3(path=None):
    if path is None:
        configured = os.environ.get("ISO_639_3_JSON")
        candidates = ([Path(configured)] if configured else []) + list(ISO_639_3_PATHS)
        path = next((candidate for candidate in candidates if candidate.is_file()), None)
    if path is None:
        raise ValueError("ISO 639-3 data not found; install the iso-codes package or set ISO_639_3_JSON")
    return _load_iso_639_3(str(Path(path).resolve()))

def _capitalized_alias(name):
    return name[:1].upper() + name[1:] if name else name

def _linktrail_class_atom(source, index):
    if index >= len(source):
        raise ValueError("Invalid linktrail character class")
    if source[index] != "\\":
        value = ord(source[index])
        if 0xD800 <= value <= 0xDFFF:
            raise ValueError("Invalid linktrail Unicode scalar")
        return value, index + 1
    if source.startswith("\\x{", index):
        close = source.find("}", index + 3)
        if close < 0:
            raise ValueError("Invalid linktrail hex escape")
        raw = source[index + 3:close]
        if not re.fullmatch(r"[0-9A-Fa-f]{1,6}", raw):
            raise ValueError("Invalid linktrail hex escape")
        value = int(raw, 16)
        if value > 0x10FFFF or 0xD800 <= value <= 0xDFFF:
            raise ValueError("Invalid linktrail Unicode scalar")
        return value, close + 1
    if source.startswith("\\x", index):
        raw = source[index + 2:index + 4]
        if len(raw) != 2 or not re.fullmatch(r"[0-9A-Fa-f]{2}", raw):
            raise ValueError("Invalid linktrail byte escape")
        return int(raw, 16), index + 4
    if index + 1 < len(source) and source[index + 1] in "\\-[]/'":
        return ord(source[index + 1]), index + 2
    raise ValueError(f"Unsupported linktrail escape: {source[index:index+8]}")

def _merge_linktrail_ranges(ranges):
    ranges.sort()
    merged = []
    for first, last in ranges:
        if merged and first <= merged[-1][1] + 1:
            merged[-1] = (merged[-1][0], max(merged[-1][1], last))
        else:
            merged.append((first, last))
    return merged

def _parse_linktrail_class(source):
    if source.startswith("^"):
        raise ValueError("Unsupported negated linktrail character class")
    ranges = []
    index = 0
    while index < len(source):
        first, index = _linktrail_class_atom(source, index)
        last = first
        if index < len(source) and source[index] == "-" and index + 1 < len(source):
            last, index = _linktrail_class_atom(source, index + 1)
            if last < first:
                raise ValueError("Invalid descending linktrail range")
        if first <= 0xDFFF and last >= 0xD800:
            raise ValueError("Linktrail range crosses Unicode surrogates")
        ranges.append((first, last))
    return ranges

def _format_linktrail_ranges(ranges):
    merged = _merge_linktrail_ranges(ranges)
    return ",".join(
        f"{first:04X}" if first == last else f"{first:04X}-{last:04X}"
        for first, last in merged
    )

@functools.lru_cache(maxsize=1)
def _unicode_letter_ranges():
    ranges = []
    start = None
    previous = None
    for value in range(0x110000):
        if 0xD800 <= value <= 0xDFFF:
            is_letter = False
        else:
            is_letter = unicodedata.category(chr(value)).startswith("L")
        if is_letter:
            if start is None:
                start = value
            previous = value
        elif start is not None:
            ranges.append((start, previous))
            start = previous = None
    if start is not None:
        ranges.append((start, previous))
    return tuple(ranges)

def _split_linktrail_alternatives(source):
    parts = []
    start = 0
    depth = 0
    in_class = False
    escaped = False
    for index, ch in enumerate(source):
        if escaped:
            escaped = False
            continue
        if ch == "\\":
            escaped = True
            continue
        if in_class:
            if ch == "]":
                in_class = False
            continue
        if ch == "[":
            in_class = True
        elif ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
            if depth < 0:
                raise ValueError("Invalid MediaWiki linktrail alternation")
        elif ch == "|" and depth == 0:
            parts.append(source[start:index])
            start = index + 1
    if escaped or in_class or depth != 0:
        raise ValueError("Invalid MediaWiki linktrail alternation")
    parts.append(source[start:])
    return parts

def _parse_linktrail_literal(source):
    values = []
    index = 0
    while index < len(source):
        if source[index] in "[]()|+*?{}.^$":
            raise ValueError(f"Unsupported MediaWiki linktrail token: {source}")
        value, index = _linktrail_class_atom(source, index)
        values.append(value)
    if not values:
        raise ValueError("Empty MediaWiki linktrail token")
    return tuple(values)

def canonical_linktrail_metadata(pattern):
    if not isinstance(pattern, str):
        raise ValueError("Missing MediaWiki linktrail")
    flags = pattern.rsplit("/", 1)[-1]
    if any(flag not in "sDu" for flag in flags) or len(set(flags)) != len(flags):
        raise ValueError(f"Unsupported MediaWiki linktrail flags: {pattern}")
    if re.fullmatch(r"/\^\(\)\(\.\*\)\$/[A-Za-z]*", pattern):
        return "", "", ""

    simple = re.fullmatch(r"/\^\(\[([^]]*)\]\+\)\(\.\*\)\$/[A-Za-z]*", pattern)
    if simple:
        return _format_linktrail_ranges(_parse_linktrail_class(simple.group(1))), "", ""

    if re.fullmatch(r"/\^\(\\p\{L\}\+\)\(\.\*\)\$/[A-Za-z]*", pattern):
        return _format_linktrail_ranges(list(_unicode_letter_ranges())), "", ""

    complex_match = re.fullmatch(r"/\^\(\(\?:([\s\S]+)\)\+\)\(\.\*\)\$/[A-Za-z]*", pattern)
    if not complex_match:
        raise ValueError(f"Unsupported MediaWiki linktrail: {pattern}")
    ranges = []
    sequences = []
    guarded = []
    for alternative in _split_linktrail_alternatives(complex_match.group(1)):
        if alternative.startswith("[") and alternative.endswith("]"):
            ranges.extend(_parse_linktrail_class(alternative[1:-1]))
        elif alternative in ("'(?!')", "\\'(?!\\')"):
            guarded.append(ord("'"))
        else:
            literal = _parse_linktrail_literal(alternative)
            if len(literal) == 1:
                ranges.append((literal[0], literal[0]))
            else:
                sequences.append(literal)

    sequence_text = ",".join("+".join(f"{cp:04X}" for cp in sequence) for sequence in sequences)
    guarded_text = ",".join(f"{cp:04X}" for cp in sorted(set(guarded)))
    return _format_linktrail_ranges(ranges), sequence_text, guarded_text

def canonical_linktrail_ranges(pattern):
    return canonical_linktrail_metadata(pattern)[0]

def language_registry_snapshot(wiki, iso_path=None):
    base = siteinfo(wiki, "general|languages")
    general = base.get("general")
    site_languages = base.get("languages")
    if not isinstance(general, dict) or not isinstance(site_languages, list):
        raise ValueError(f"Missing site language metadata for {wiki}")
    content_language = general.get("lang")
    if not isinstance(content_language, str) or not re.fullmatch(r"[A-Za-z0-9-]+", content_language):
        raise ValueError(f"Invalid content language for {wiki}")
    linktrail_ranges, linktrail_sequences, linktrail_not_double = canonical_linktrail_metadata(general.get("linktrail"))

    localized = siteinfo(wiki, "languages", content_language).get("languages")
    if not isinstance(localized, list):
        raise ValueError(f"Missing localized language names for {wiki}")
    localized_by_code = {}
    for row in localized:
        if not isinstance(row, dict) or not isinstance(row.get("code"), str) or not isinstance(row.get("name"), str):
            raise ValueError(f"Invalid localized language row for {wiki}")
        if row["code"] in localized_by_code:
            raise ValueError(f"Duplicate localized language code for {wiki}: {row['code']}")
        localized_by_code[row["code"]] = row["name"]

    iso_by_code = {}
    for row in iso_639_3(iso_path):
        if not isinstance(row, dict):
            raise ValueError("Invalid ISO 639-3 row")
        alpha3 = row.get("alpha_3")
        name = row.get("name")
        if not isinstance(alpha3, str) or not re.fullmatch(r"[a-z]{3}", alpha3) or not isinstance(name, str) or not name:
            raise ValueError("Invalid ISO 639-3 row")
        canonical = row.get("alpha_2") or alpha3
        if not isinstance(canonical, str) or not re.fullmatch(r"[a-z]{2,3}", canonical):
            raise ValueError("Invalid ISO 639-3 code")
        if canonical in iso_by_code:
            raise ValueError(f"Duplicate ISO 639-3 canonical code: {canonical}")
        aliases = []
        for alias in (name, _capitalized_alias(name), canonical, alpha3, row.get("bibliographic"), row.get("common_name")):
            if isinstance(alias, str) and alias and alias not in aliases:
                aliases.append(alias)
        iso_by_code[canonical] = aliases

    site_entries = []
    site_codes = set()
    for row in site_languages:
        if not isinstance(row, dict):
            raise ValueError(f"Invalid site language row for {wiki}")
        code, default_name, bcp47 = row.get("code"), row.get("name"), row.get("bcp47")
        if not isinstance(code, str) or not re.fullmatch(r"[A-Za-z0-9-]+", code):
            raise ValueError(f"Invalid site language code for {wiki}")
        if not isinstance(default_name, str) or not default_name:
            raise ValueError(f"Invalid site language name for {wiki}")
        if bcp47 is not None and (not isinstance(bcp47, str) or not re.fullmatch(r"[A-Za-z0-9-]+", bcp47)):
            raise ValueError(f"Invalid site BCP47 code for {wiki}")
        if code in site_codes:
            raise ValueError(f"Duplicate site language code for {wiki}: {code}")
        site_codes.add(code)

        preferred = localized_by_code.get(code, default_name)
        aliases = [preferred, _capitalized_alias(preferred)]
        for alias in (
            _capitalized_alias(default_name), default_name,
            code, bcp47,
        ):
            if isinstance(alias, str) and alias and alias not in aliases:
                aliases.append(alias)

        # Add ISO aliases when the site code itself is canonical ISO 639, or when
        # its BCP47 code names the same base language. Script/region variants keep
        # their own canonical label while still retaining the raw site code.
        iso_key = code.lower() if code.lower() in iso_by_code else None
        if iso_key is None and isinstance(bcp47, str) and re.fullmatch(r"[A-Za-z]{2,3}", bcp47):
            candidate = bcp47.lower()
            if candidate in iso_by_code:
                iso_key = candidate
        if iso_key is not None:
            for alias in iso_by_code[iso_key]:
                if alias not in aliases:
                    aliases.append(alias)
        site_entries.append([code, aliases])

    if set(localized_by_code) != site_codes:
        raise ValueError(f"Inconsistent localized language registry for {wiki}")

    # ISO rows already represented by an exact MediaWiki code are folded into
    # those rows. Remaining ISO languages provide explicit-code resolution for
    # Wiktionary markers such as aiw even if MediaWiki itself has no UI locale.
    iso_entries = [
        [code, aliases.copy()]
        for code, aliases in sorted(iso_by_code.items())
        if code not in site_codes
    ]

    entries = site_entries + iso_entries
    label_counts = {}
    for _, aliases in entries:
        label = aliases[0]
        label_counts[label] = label_counts.get(label, 0) + 1

    used_labels = set()
    for code, aliases in entries:
        label = aliases[0]
        if label_counts[label] != 1 or label in used_labels:
            label = f"{label} ({code})"
        suffix = 2
        base_label = label
        while label in used_labels:
            label = f"{base_label} {suffix}"
            suffix += 1
        used_labels.add(label)
        aliases[:] = [label, *[alias for alias in aliases if alias != label]]

    rows = [
        "# wikidict-language-registry-v2",
        f"# content-language\t{content_language}",
        f"# link-trail-ranges\t{linktrail_ranges}",
    ]
    if linktrail_sequences:
        rows.append(f"# link-trail-sequences\t{linktrail_sequences}")
    if linktrail_not_double:
        rows.append(f"# link-trail-not-double\t{linktrail_not_double}")
    rows.append("# mediawiki")
    rows.extend("\t".join([code, *aliases]) for code, aliases in sorted(site_entries))
    rows.append("# iso-639-3")
    rows.extend("\t".join([code, *aliases]) for code, aliases in iso_entries)
    return content_language, "\n".join(rows) + "\n"

def sha256_digest(path):
    with path.open("rb") as source:
        return hashlib.file_digest(source, "sha256").hexdigest()

def write_language_registry(root, wiki, date, text, content_language):
    folder = root / wiki / date
    folder.mkdir(parents=True, exist_ok=True)
    path = folder / "language-registry.tsv"
    temp = path.with_suffix(".part")
    temp.write_text(text, encoding="utf-8")
    os.replace(temp, path)
    return dict(
        wiki=wiki,
        date=date,
        name=path.name,
        content_language=content_language,
        size=path.stat().st_size,
        sha256=sha256_digest(path),
    )

def validate_registry_item(item):
    if not re.fullmatch(r"[a-z0-9_]+wiktionary", item.get("wiki", "")) or not re.fullmatch(r"[0-9]{8}", item.get("date", "")):
        raise ValueError("Invalid language registry identity")
    if item.get("name") != "language-registry.tsv":
        raise ValueError("Invalid language registry filename")
    if not re.fullmatch(r"[A-Za-z0-9-]+", item.get("content_language", "")):
        raise ValueError("Invalid content language")
    if not re.fullmatch(r"[a-f0-9]{64}", item.get("sha256", "")) or not isinstance(item.get("size"), int) or item["size"] <= 0:
        raise ValueError("Invalid language registry checksum or size")

def validate_registry_file(root, item):
    validate_registry_item(item)
    path = root / item["wiki"] / item["date"] / item["name"]
    if not path.is_file() or path.stat().st_size != item["size"] or sha256_digest(path) != item["sha256"]:
        raise ValueError(f"Missing or unverified language registry: {path}")
    return path

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

def transfer_progress(files, root, previous=None):
    """Measure on-disk bytes, including verified files and resumed partials."""
    previous = previous or {}
    transferred = 0
    active = None
    largest_growth = 0
    current = {}
    for item in files:
        target = root / item["wiki"] / item["date"] / item["name"]
        partial = target.with_name(target.name + ".part")
        size = target.stat().st_size if target.exists() else partial.stat().st_size if partial.exists() else 0
        size = min(size, item["size"])
        current[item["url"]] = size
        transferred += size
        growth = size - previous.get(item["url"], size)
        if growth > largest_growth:
            largest_growth = growth
            active = target
    return transferred, active, current

def progress_line(done, total, destination, speed=0):
    width = 30
    fraction = min(done / total, 1) if total else 1
    filled = int(fraction * width)
    bar = "#" * filled + "-" * (width - filled)
    location = str(destination) if destination else "waiting for transfer"
    return f"[{bar}] {fraction * 100:5.1f}% {done:,}/{total:,} bytes {speed / 1048576:.1f} MiB/s  {location}"

def discovery_line(done, total, wiki, destination):
    width = 30
    filled = int(done * width / total) if total else width
    return f"[{'#' * filled}{'-' * (width - filled)}] {done}/{total} editions  {wiki}  -> {destination.resolve()}"

def run_aria2(command, files, root):
    total = sum(item["size"] for item in files)
    print(f"Destination: {root.resolve()} ({len(files)} files, {total:,} bytes)", flush=True)
    process = subprocess.Popen(command, stdout=subprocess.DEVNULL)
    previous = None
    last_time = time.monotonic()
    last_done = None
    printed = False
    shown_location = None
    try:
        while True:
            done, active, previous = transfer_progress(files, root, previous)
            now = time.monotonic()
            speed = max(0, done - last_done) / max(now - last_time, 0.001) if last_done is not None else 0
            if sys.stdout.isatty():
                if active is not None and active != shown_location:
                    if printed: print(flush=True)
                    print(f"Location: {active.resolve()}", flush=True)
                    shown_location = active
                label = active.name[:32] if active else "waiting for transfer"
                line = progress_line(done, total, label, speed)
                print("\r\033[2K" + line, end="", flush=True)
            else:
                line = progress_line(done, total, active or root, speed)
                print(line, flush=True)
            printed = True
            last_done, last_time = done, now
            if process.poll() is not None:
                break
            time.sleep(0.5 if sys.stdout.isatty() else 5)
    except KeyboardInterrupt:
        process.send_signal(2)
        process.wait()
        if printed and sys.stdout.isatty(): print(flush=True)
        raise
    if printed and sys.stdout.isatty(): print(flush=True)
    return process.wait()

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
        result = run_aria2(command, pending, root)
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
    if result or failures:
        raise SystemExit(f"{len(failures)} downloads incomplete. Resume with the same --output and --resume.")

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", "--out", type=Path, default=Path("data/dumps"), metavar="DIR")
    parser.add_argument("--wikis", nargs="+", help="Edition IDs, e.g. enwiktionary simplewiktionary; default: all")
    parser.add_argument("--connections", type=int, choices=range(1, 4), default=2)
    parser.add_argument("--xml-only", action="store_true", help="Omit companion SQL snapshots")
    parser.add_argument("--plan", action="store_true", help="Resolve and save manifest without downloading dump files")
    parser.add_argument("--resume", action="store_true", help="Use the saved manifest, preserving snapshot dates across restarts")
    parser.add_argument("--interwiki-map-only", action="store_true",
                        help="Capture the current siteinfo interwiki map for exactly one --wikis edition")
    args = parser.parse_args()
    args.output = args.output.expanduser().resolve()
    args.output.mkdir(parents=True, exist_ok=True)

    if args.interwiki_map_only:
        if args.resume or args.plan or args.xml_only or not args.wikis or len(args.wikis) != 1:
            parser.error("--interwiki-map-only requires exactly one --wikis edition and no other mode")
        path, provenance = interwiki_map_snapshot(args.wikis[0], args.output)
        print(f"Current interwiki map: {path} rows={provenance['rows']} sha256={provenance['tsv_sha256']}", flush=True)
        return

    if args.resume:
        manifest = json.loads((args.output / "manifest.json").read_text())
        for item in manifest.get("language_registries", []):
            validate_registry_file(args.output, item)
        if args.plan:
            print(f"{len(manifest['files'])} files in saved manifest")
        else:
            download_all(manifest["files"], args.output, args.connections)
        return

    requested = args.wikis or editions()
    files, registries, failures = [], [], []

    def discover(wiki):
        selected = snapshot(wiki, JOBS[:1] if args.xml_only else JOBS)
        if not selected:
            raise ValueError(f"No dump files for {wiki}")
        dates = {item["date"] for item in selected}
        if len(dates) != 1:
            raise ValueError(f"Mixed snapshot dates for {wiki}")
        content_language, registry_text = language_registry_snapshot(wiki)
        return selected, content_language, registry_text

    with concurrent.futures.ThreadPoolExecutor(max_workers=args.connections) as pool:
        jobs = {pool.submit(discover, wiki): wiki for wiki in requested}
        for completed, future in enumerate(concurrent.futures.as_completed(jobs), 1):
            wiki = jobs[future]
            try:
                selected, content_language, registry_text = future.result()
                files.extend(selected)
                registries.append(write_language_registry(
                    args.output, wiki, selected[0]["date"], registry_text, content_language,
                ))
            except Exception as error:
                failures.append(f"{wiki}: {error}")
            line = discovery_line(completed, len(jobs), wiki, args.output)
            if sys.stdout.isatty():
                print("\r\033[2K" + line, end="", flush=True)
            else:
                print(line, flush=True)
        if jobs and sys.stdout.isatty():
            print(flush=True)

    files.sort(key=lambda x: (x["wiki"], x["name"]))
    registries.sort(key=lambda x: x["wiki"])
    manifest = args.output / "manifest.json"
    temp = manifest.with_suffix(".part")
    temp.write_text(json.dumps(dict(files=files, language_registries=registries, failures=failures), indent=2) + "\n")
    os.replace(temp, manifest)
    print(f"{len(files)} files, {sum(x['size'] for x in files):,} bytes; manifest: {manifest}", flush=True)

    if not args.plan:
        download_all(files, args.output, args.connections)
    for error in failures:
        print("FAILED:", error)
    if failures:
        raise SystemExit(1)

if __name__ == "__main__":
    main()
