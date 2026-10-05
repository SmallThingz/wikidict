#!/usr/bin/env python3
"""Capture current, explicit file metadata for a dated offline build.

Capture always uses a new directory. Unknown results never become negative rows,
and incomplete captures never publish the TSV/manifest pair. verify replays the
saved API evidence without networking. This covers only the recorded candidate
set; a later offline expansion must establish that no required query is absent.
"""
import argparse
import ctypes
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

sys.dont_write_bytecode = True
from category_tree_snapshot import rows as sql_rows
from download_wiktionaries import AGENT, wiktionary_api

MAX_RESPONSE = 2 * 1024 * 1024
MAX_MANIFEST = 64 * 1024
MAX_METADATA = 64 * 1024 * 1024
MAX_INPUT = 256 * 1024 * 1024
MAX_LINE = 1024 * 1024
MAX_TITLES = 250_000
MAX_SQL_ROWS = 1_000_000
MAX_URL = 7 * 1024
SCHEMA = 'wikidict.file-metadata-capture.v1'
EVIDENCE_FIELDS = ('namespace_registry', 'input_sources', 'dumpstatus', 'russian_variants', 'batches', 'artifacts')
REPO = Path(__file__).resolve().parent.parent
SPACES = set(' _\t\r\n') | {chr(x) for x in (0xa0, 0x1680, 0x180e, 0x2028, 0x2029, 0x202f, 0x205f, 0x3000)} | {chr(x) for x in range(0x2000, 0x200b)}
BIDI = {chr(x) for x in (0x200e, 0x200f)} | {chr(x) for x in range(0x202a, 0x202f)}
WMF_UNCHANGED = {0xdf, 0x19b, 0x264, 0x1c8a, 0xa7cd, 0xa7cf, 0xa7d3, 0xa7d5, 0xa7db} | set(range(0x10d70, 0x10d86)) | set(range(0x16ebb, 0x16ed4))


def utc():
    return datetime.now(timezone.utc).isoformat()


def digest(raw):
    return hashlib.sha256(raw).hexdigest()


def encoded(value):
    return (json.dumps(value, ensure_ascii=False, sort_keys=True, indent=2, allow_nan=False) + '\n').encode()


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError('Duplicate JSON key: ' + key)
        result[key] = value
    return result


def decode(raw):
    return json.loads(raw, object_pairs_hook=unique_object)


def stamp(path):
    value = path.lstat()
    if not stat.S_ISREG(value.st_mode):
        raise ValueError('Expected a regular, non-symlink file: ' + str(path))
    return (value.st_dev, value.st_ino, value.st_size, value.st_mtime_ns, value.st_ctime_ns)


def small(path, limit=MAX_METADATA):
    before = stamp(path)
    with path.open('rb') as stream:
        raw = stream.read(limit + 1)
    if len(raw) > limit or stamp(path) != before:
        raise ValueError('Oversized or changing input: ' + str(path))
    return raw


def fingerprint(path):
    before = stamp(path)
    sha1, sha256, size = hashlib.sha1(), hashlib.sha256(), 0
    with path.open('rb') as stream:
        while block := stream.read(1024 * 1024):
            sha1.update(block); sha256.update(block); size += len(block)
    if stamp(path) != before:
        raise ValueError('Input changed while hashing: ' + str(path))
    return {'size': size, 'sha1': sha1.hexdigest(), 'sha256': sha256.hexdigest()}


def dependencies():
    return {name: digest(small(REPO / name)) for name in (
        'tools/category_tree_snapshot.py', 'tools/download_wiktionaries.py',
        'src/shared/namespace_registry.zig', 'src/shared/title_case.zig')}


def put(path, raw):
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open('xb') as stream:
        stream.write(raw); stream.flush(); os.fsync(stream.fileno())


def document(path, value):
    put(path, encoded(value))


class Registry:
    """Use the native Unicode libraries; accept exact or ASCII-case aliases."""
    def __init__(self, raw, wiki, date):
        self.wiki, self.date = wiki, date
        lines = raw.decode('utf-8').splitlines()
        if lines[:3] != ['# wikidict-namespace-registry-v1', '# wiki\t' + wiki, '# dump-date\t' + date]:
            raise ValueError('Namespace registry edition/date mismatch')
        def library(*names):
            for name in names:
                try:
                    return ctypes.CDLL(name)
                except OSError:
                    pass
            raise ValueError('Required native Unicode library unavailable')
        self.nfc_lib = library('libutf8proc.so.3', 'libutf8proc.so')
        self.case_lib = library('libunistring.so.5', 'libunistring.so')
        self.libc = ctypes.CDLL(None)
        self.libc.free.argtypes = [ctypes.c_void_p]
        self.nfc_lib.utf8proc_decompose.argtypes = [ctypes.c_char_p, ctypes.c_ssize_t, ctypes.c_void_p, ctypes.c_ssize_t, ctypes.c_int]
        self.nfc_lib.utf8proc_decompose.restype = ctypes.c_ssize_t
        self.nfc_lib.utf8proc_reencode.argtypes = [ctypes.c_void_p, ctypes.c_ssize_t, ctypes.c_int]
        self.nfc_lib.utf8proc_reencode.restype = ctypes.c_ssize_t
        self.case_lib.u8_totitle.argtypes = [ctypes.c_char_p, ctypes.c_size_t, ctypes.c_char_p, ctypes.c_void_p, ctypes.c_void_p, ctypes.POINTER(ctypes.c_size_t)]
        self.case_lib.u8_totitle.restype = ctypes.c_void_p
        self.specs, self.aliases = {}, {}
        for line in lines:
            if not line or line.startswith('#'):
                continue
            fields = line.split('\t')
            if len(fields) < 10:
                raise ValueError('Malformed namespace registry')
            ns = int(fields[0])
            if ns not in (-2, 6):
                continue
            if ns in self.specs or fields[3] not in ('first-letter', 'case-sensitive'):
                raise ValueError('Invalid file/media namespace')
            self.specs[ns] = {'name': fields[1], 'capitalized': fields[3] == 'first-letter'}
            for alias in (fields[1], fields[2], *fields[10:]):
                if not alias:
                    continue
                key = self.alias_key(self.spacing(alias))
                if key in self.aliases and self.aliases[key] != ns:
                    raise ValueError('Conflicting file/media namespace alias')
                self.aliases[key] = ns
        if set(self.specs) != {-2, 6}:
            raise ValueError('File and Media namespace definitions are required')

    @staticmethod
    def alias_key(text):
        # Native aliases use Unicode16 lowercase. Avoid approximating that map.
        return text.lower() if text.isascii() else text

    def spacing(self, text):
        raw = text.encode('utf-8')
        if len(raw) > 4096 or '\0' in text:
            raise ValueError('Invalid or oversized file title')
        count = self.nfc_lib.utf8proc_decompose(raw, len(raw), None, 0, 10)
        if count < 0 or count > 16384:
            raise ValueError('Cannot normalize file title')
        storage = (ctypes.c_int32 * (count + 1))()
        if self.nfc_lib.utf8proc_decompose(raw, len(raw), storage, count, 10) != count:
            raise ValueError('Unicode normalization failed')
        length = self.nfc_lib.utf8proc_reencode(storage, count, 10)
        if length < 0 or length >= ctypes.sizeof(storage):
            raise ValueError('Unicode normalization failed')
        normalized = ctypes.string_at(storage, length).decode('utf-8')
        result, pending = [], False
        for char in normalized:
            if char in BIDI:
                continue
            if char in SPACES:
                pending = bool(result)
            else:
                if pending:
                    result.append(' ')
                result.append(char); pending = False
        return ''.join(result)

    def first(self, text):
        cp = ord(text[0])
        if cp in WMF_UNCHANGED:
            return text
        if cp < 128:
            return text[0].upper() + text[1:]
        raw = text[0].encode('utf-8')
        buffer = ctypes.create_string_buffer(64)
        length = ctypes.c_size_t(64)
        result = self.case_lib.u8_totitle(raw, len(raw), None, None, buffer, ctypes.byref(length))
        if not result:
            raise ValueError('Unicode title casing failed')
        try:
            if length.value > 64:
                raise ValueError('Unexpected Unicode title casing size')
            return ctypes.string_at(result, length.value).decode('utf-8') + text[1:]
        finally:
            if result != ctypes.addressof(buffer):
                self.libc.free(result)

    def file_title(self, raw):
        if not isinstance(raw, str):
            raise ValueError('File title must be text')
        title = self.spacing(raw)
        if title.startswith(':'):
            title = title[1:].strip(' ')
        prefix, separator, body = title.partition(':')
        ns = self.aliases.get(self.alias_key(self.spacing(prefix)))
        body = body.strip(' ')
        if not separator or ns not in (-2, 6) or not body or any(c in body for c in '|\0'):
            raise ValueError('Unsupported or invalid File/Media title: ' + raw[:160])
        if self.specs[ns]['capitalized']:
            body = self.first(body)
        if ns == -2:
            body = self.spacing(body)
            if self.specs[6]['capitalized']:
                body = self.first(body)
        return self.specs[6]['name'] + ':' + body


def add_candidate(titles, raw, registry, russian):
    title = registry.file_title(raw)
    if registry.file_title(title) != title:
        raise ValueError('File title changes when the native TSV loader normalizes its key')
    titles.add(title)
    if russian:
        body = title.split(':', 1)[1]
        match = re.fullmatch(r'Ru[- ](.+)\.(?:ogg|oga)', body)
        if match:
            for prefix, suffix in (('Ru-', '.ogg'), ('Ru-', '.oga'), ('Ru_', '.ogg')):
                add_candidate(titles, registry.specs[6]['name'] + ':' + prefix + match[1] + suffix, registry, False)
    if len(titles) > MAX_TITLES:
        raise ValueError('Candidate set exceeds bounded preparation capacity')


def seed_file(path, kind, titles, registry, russian):
    with path.open('rb') as source:
        while raw := source.readline(MAX_LINE + 1):
            if len(raw) > MAX_LINE:
                raise ValueError('Oversized seed line')
            line = raw.decode('utf-8').rstrip('\r\n')
            if kind == 'log':
                match = re.search(r'file metadata (?:snapshot unavailable|missing): title=(.*)$', line)
                if not match:
                    continue
                line = match[1]
            elif not line or line.startswith('#'):
                continue
            add_candidate(titles, line, registry, russian)


def seed_sql(path, status, titles, registry, russian):
    table = next((name for name in ('image', 'imagelinks') if path.name == f'{registry.wiki}-{registry.date}-{name}.sql.gz'), None)
    if table is None:
        raise ValueError('Expected matching dated image or imagelinks SQL')
    job = status.get('jobs', {}).get(table + 'table', {})
    expected = job.get('files', {}).get(path.name, {})
    identity = fingerprint(path)
    if (job.get('status') != 'done' or identity['size'] != expected.get('size')
            or identity['sha1'] != expected.get('sha1')
            or expected.get('url') != f'/{registry.wiki}/{registry.date}/{path.name}'):
        raise ValueError('SQL differs from pinned dumpstatus size/SHA1/URL')
    for number, (name,) in enumerate(sql_rows(path, ('img_name' if table == 'image' else 'il_to',)), 1):
        if number > MAX_SQL_ROWS:
            raise ValueError('SQL candidate row count exceeds bounded preparation capacity')
        if not isinstance(name, bytes):
            raise ValueError('Invalid SQL filename')
        add_candidate(titles, registry.specs[6]['name'] + ':' + name.decode('utf-8'), registry, russian)
    return identity


def require_edition(data, wiki):
    query = data.get('query') if isinstance(data, dict) else None
    general = query.get('general') if isinstance(query, dict) else None
    if not isinstance(general, dict) or general.get('wikiid') != wiki:
        raise ValueError('Missing matching API wiki identity')


def classify_response(data, titles, registry):
    if not isinstance(data, dict) or any(name in data for name in ('error', 'errors', 'warnings')):
        raise ValueError('API error or warning; file state is unknown')
    query = data.get('query')
    if not isinstance(query, dict) or query.get('interwiki') or query.get('converted'):
        raise ValueError('Missing or unsupported API query result')
    if 'general' in query:
        require_edition(data, registry.wiki)
    mappings = {}
    for field in ('normalized', 'redirects'):
        rows = query.get(field, [])
        if not isinstance(rows, list):
            raise ValueError('Invalid API title mapping')
        for row in rows:
            if (not isinstance(row, dict) or not isinstance(row.get('from'), str)
                    or not isinstance(row.get('to'), str) or row.get('tofragment')):
                raise ValueError('Invalid or fragment API title mapping')
            if row['from'] in mappings and mappings[row['from']] != row['to']:
                raise ValueError('Conflicting API title mapping')
            mappings[row['from']] = row['to']
    pages = query.get('pages')
    if not isinstance(pages, list) or len(pages) > len(titles):
        raise ValueError('Invalid API page inventory')
    by_title = {}
    for page in pages:
        if (not isinstance(page, dict) or type(page.get('ns')) is not int or page['ns'] != 6
                or not isinstance(page.get('title'), str)
                or any(key in page for key in ('invalid', 'interwiki', 'filehidden', 'suppressed', 'filemissing'))):
            raise ValueError('Invalid or inaccessible file result')
        if page['title'] in by_title:
            raise ValueError('Duplicate API page title')
        by_title[page['title']] = page
    result, used = {}, set()
    for requested in titles:
        current, visited = requested, set()
        while current in mappings and mappings[current] != current:
            if current in visited or len(visited) >= 50:
                raise ValueError('Cyclic or excessive API title mapping')
            visited.add(current); current = mappings[current]
        page = by_title.get(current)
        if page is None:
            raise ValueError('Requested title omitted from API response: ' + requested)
        used.add(current)
        repository, info = page.get('imagerepository'), page.get('imageinfo')
        if repository == '' and info is None and not page.get('redirect'):
            value = {'exists': False, 'width': 0, 'height': 0, 'repository': ''}
        elif repository in ('local', 'shared') and isinstance(info, list) and len(info) == 1:
            item = info[0]
            if (not isinstance(item, dict) or any(key in item for key in ('filehidden', 'suppressed', 'filemissing'))
                    or any(type(item.get(key)) is not int or not 0 <= item[key] < 2**32 for key in ('width', 'height'))
                    or type(item.get('size')) is not int or item['size'] < 0
                    or not re.fullmatch('[0-9a-f]{40}', str(item.get('sha1', '')))
                    or not isinstance(item.get('canonicaltitle'), str)
                    or not isinstance(item.get('timestamp'), str) or not item['timestamp'].endswith('Z')):
                raise ValueError('Incomplete or hidden current file metadata')
            datetime.fromisoformat(item['timestamp'].replace('Z', '+00:00'))
            registry.file_title(item['canonicaltitle'])
            value = {'exists': True, 'width': item['width'], 'height': item['height'],
                     'repository': repository, 'file_sha1': item['sha1'], 'file_timestamp': item['timestamp'],
                     'canonicaltitle': item['canonicaltitle']}
        else:
            raise ValueError('File repository state is unknown or incomplete')
        key = registry.file_title(requested)
        if key in result and {k: v for k, v in result[key].items() if k not in ('response_title', 'requested_title')} != value:
            raise ValueError('Conflicting equivalent file queries')
        value.update(response_title=current, requested_title=requested)
        result[key] = value
    if used != set(by_title):
        raise ValueError('Unrequested API result')
    # iilimit=1 selects current metadata. Older-revision continuation is not read;
    # every requested title must already have one explicit, usable current result.
    continuation = data.get('continue', {})
    if not isinstance(continuation, dict) or set(continuation) - {'continue', 'iicontinue', 'iistart'}:
        raise ValueError('Unexpected API continuation')
    return result


def render(records):
    lines = ['# wikidict-file-metadata-v1']
    for title in sorted(records, key=lambda x: x.encode('utf-8')):
        item = records[title]
        lines.append('\t'.join((title, '1' if item['exists'] else '0', str(item['width']), str(item['height']))))
    return ('\n'.join(lines) + '\n').encode('utf-8')


def query_for(wiki, titles):
    return {'action': 'query', 'format': 'json', 'formatversion': '2',
            'meta': 'siteinfo', 'siprop': 'general', 'prop': 'imageinfo',
            'iiprop': 'size|sha1|timestamp|canonicaltitle', 'iilimit': '1',
            'redirects': '1', 'maxlag': '5', 'titles': '|'.join(titles)}


def query_url(wiki, titles):
    return wiktionary_api(wiki) + '?' + urllib.parse.urlencode(query_for(wiki, titles))


def title_batches(wiki, titles, limit):
    batch = []
    for title in titles:
        if batch and (len(batch) == limit or len(query_url(wiki, [*batch, title])) > MAX_URL):
            yield batch
            batch = []
        batch.append(title)
        if len(query_url(wiki, batch)) > MAX_URL:
            raise ValueError('Single file title exceeds the bounded API request size')
    if batch:
        yield batch


def get_response(url, timeout):
    request = urllib.request.Request(url, headers={'User-Agent': AGENT, 'Accept': 'application/json'})
    try:
        response = urllib.request.urlopen(request, timeout=timeout)
    except urllib.error.HTTPError as error:
        response = error
    with response:
        final = urllib.parse.urlsplit(response.url)
        original = urllib.parse.urlsplit(url)
        if (final.scheme, final.netloc, final.path) != (original.scheme, original.netloc, original.path):
            raise ValueError('Unexpected API redirect endpoint')
        return response.status, dict(response.headers), response.read(MAX_RESPONSE + 1)


def request_batch(root, number, titles, registry, transport, sleep, deadline, delay):
    query = query_for(registry.wiki, titles)
    url = query_url(registry.wiki, titles)
    if not 1 <= len(titles) <= 50 or len(url) > MAX_URL:
        raise ValueError('API request exceeds bounded title/URL size')
    request_name = f'requests/{number:06d}.json'
    document(root / request_name, {'url': url, 'query': query, 'titles': titles})
    for attempt in range(1, 5):
        if time.monotonic() >= deadline:
            raise ValueError('Capture wall deadline reached')
        name = f'responses/{number:06d}-{attempt:02d}'
        receipt = {'request': request_name, 'started_utc': utc(), 'status': None}
        raw, headers, code, retry = None, {}, None, False
        try:
            status, headers, raw = transport(url, min(30, deadline - time.monotonic()))
            receipt.update(status=status, response=name + '.raw.json',
                           response_sha256=digest(raw), response_bytes=len(raw),
                           headers={k.lower(): v for k, v in headers.items()
                                    if k.lower() in ('date', 'content-type', 'retry-after', 'etag')})
            put(root / (name + '.raw.json'), raw)
            if len(raw) > MAX_RESPONSE:
                raise ValueError('Oversized API response')
            if status != 200:
                retry = status in (429, 500, 502, 503, 504)
                raise ValueError('API HTTP status ' + str(status))
            data = decode(raw)
            if isinstance(data, dict) and isinstance(data.get('error'), dict):
                code = data['error'].get('code')
                retry = code in ('maxlag', 'ratelimited', 'readonly')
            require_edition(data, registry.wiki)
            records = classify_response(data, titles, registry)
            receipt.update(accepted=True, ended_utc=utc())
            document(root / (name + '.receipt.json'), receipt)
            return records, {'request': request_name, 'accepted_receipt': name + '.receipt.json'}
        except (OSError, ValueError) as error:
            if isinstance(error, OSError):
                retry = True
            receipt.update(accepted=False, error=str(error), api_error_code=code, ended_utc=utc())
            document(root / (name + '.receipt.json'), receipt)
            if not retry or attempt == 4:
                raise
            retry_after = next((v for k, v in headers.items() if k.lower() == 'retry-after'), '')
            if retry_after and not str(retry_after).isdigit():
                raise ValueError('Uninterpretable Retry-After; preserved evidence for a later capture') from error
            wait = max(delay, 2**(attempt - 1), int(retry_after or 0))
            if wait > 60 or time.monotonic() + wait >= deadline:
                raise ValueError('Retry exceeds bounded capture wait/deadline') from error
            sleep(wait)


def snapshot_input(source, root, relative):
    before = stamp(source)
    if before[2] > MAX_INPUT:
        raise ValueError('Seed input exceeds bounded preparation capacity')
    destination = root / relative
    destination.parent.mkdir(parents=True, exist_ok=True)
    with source.open('rb') as src, destination.open('xb') as dst:
        while block := src.read(1024 * 1024):
            dst.write(block)
        dst.flush(); os.fsync(dst.fileno())
    if stamp(source) != before:
        raise ValueError('Seed source changed during capture')
    return {'path': relative, 'source_path': str(source), **fingerprint(destination)}


def artifacts(root):
    result = {}
    for path in sorted(root.rglob('*')):
        if path.is_symlink():
            raise ValueError('Symlink in capture evidence')
        if path.is_dir():
            continue
        name = path.relative_to(root).as_posix()
        if name in ('file-metadata.manifest.json', 'file-metadata.complete.json', 'capture-evidence.json'):
            continue
        found = fingerprint(path)
        result[name] = {'size': found['size'], 'sha256': found['sha256']}
    return result


def seed_candidates(root, sources, namespace, wiki, date, russian, dumpstatus):
    registry = Registry(small(root / namespace), wiki, date)
    titles = set()
    status = decode(small(root / dumpstatus)) if dumpstatus else None
    for source in sources:
        path = root / source['path']
        if source['kind'] not in ('sql', 'log', 'titles'):
            raise ValueError('Unknown seed source kind')
        if source['kind'] == 'sql':
            if status is None:
                raise ValueError('SQL candidate inputs require pinned dumpstatus')
            # Copies retain the original dated filename under their own folder.
            seed_sql(path, status, titles, registry, russian)
        else:
            seed_file(path, source['kind'], titles, registry, russian)
    if not titles:
        raise ValueError('No explicit file metadata candidates')
    return registry, sorted(titles, key=lambda x: x.encode('utf-8'))


def capture(args, transport=None, sleep=time.sleep):
    if not re.fullmatch(r'\d{8}', args.date) or not 1 <= args.batch_size <= 50 or not 0 <= args.delay <= 60 or not 1 <= args.wall_seconds <= 86400:
        raise ValueError('Invalid snapshot date or bounded capture settings')
    wiktionary_api(args.wiki)
    datetime.strptime(args.date, '%Y%m%d')
    root = args.output
    root.mkdir(parents=True, exist_ok=False)
    producer = digest(small(Path(__file__)))
    dependency_hashes = dependencies()
    source_stamps = {}
    deadline = time.monotonic() + args.wall_seconds
    try:
        namespace = 'inputs/namespace-registry.tsv'
        original_paths = [args.namespace_registry, *args.log, *args.titles, *args.sql]
        if args.dumpstatus:
            original_paths.append(args.dumpstatus)
        source_stamps = {path: stamp(path) for path in original_paths}
        namespace_record = snapshot_input(args.namespace_registry, root, namespace)
        dumpstatus = None
        if args.dumpstatus:
            dumpstatus = 'inputs/dumpstatus.json'
            snapshot_input(args.dumpstatus, root, dumpstatus)
        sources = []
        for kind in ('log', 'titles', 'sql'):
            for path in getattr(args, kind):
                relative = f'inputs/{len(sources):04d}/{path.name}'
                sources.append(dict(snapshot_input(path, root, relative), kind=kind))
        registry, titles = seed_candidates(root, sources, namespace, args.wiki, args.date, args.russian_variants, dumpstatus)
        document(root / 'candidates.json', {'titles': titles, 'russian_variants': args.russian_variants})
        records, batches = {}, []
        for batch_titles in title_batches(args.wiki, titles, args.batch_size):
            if batches:
                if time.monotonic() + args.delay >= deadline:
                    raise ValueError('Capture wall deadline reached')
                sleep(args.delay)
            found, batch = request_batch(root, len(batches) + 1, batch_titles,
                                        registry, transport or get_response, sleep, deadline, args.delay)
            records.update(found); batches.append(batch)
            print(json.dumps({'wiki': args.wiki, 'captured': len(records), 'candidates': len(titles)}), flush=True)
        if set(records) != set(titles):
            raise ValueError('Incomplete candidate capture')
        if (digest(small(Path(__file__))) != producer or dependencies() != dependency_hashes
                or any(stamp(path) != observed for path, observed in source_stamps.items())):
            raise ValueError('Collector or seed source changed during capture')
        tsv = render(records)
        manifest = {'schema': SCHEMA, 'wiki': args.wiki, 'date': args.date,
                    'dump_date': None, 'temporal_scope': 'current-api-observation',
                    'retrieved_utc': utc(), 'source_url': wiktionary_api(args.wiki),
                    'generator_sha256': producer, 'namespace_registry': namespace_record,
                    'dependency_sha256': dependency_hashes,
                    'input_sources': sources, 'dumpstatus': dumpstatus,
                    'russian_variants': args.russian_variants, 'batches': batches,
                    'rows': len(records), 'positive_rows': sum(row['exists'] for row in records.values()),
                    'negative_rows': sum(not row['exists'] for row in records.values()),
                    'unknown_rows': 0, 'candidate_queries_complete': True, 'corpus_query_closure_proven': False,
                    'alias_policy': 'Exact NFC/spacing-normalized pinned aliases and ASCII-only alias case variants; unsupported aliases fail.',
                    'normalization': 'Native libutf8proc NFC and libunistring first-codepoint titlecase with WMF overrides; Media then File namespace casing.',
                    'output_bytes': len(tsv), 'output_sha256': digest(tsv)}
        put(root / 'file-metadata.tsv', tsv)
        manifest['artifacts'] = artifacts(root)
        evidence = {key: manifest.pop(key) for key in EVIDENCE_FIELDS}
        evidence_raw = encoded(evidence)
        put(root / 'capture-evidence.json', evidence_raw)
        manifest['evidence'] = {'path': 'capture-evidence.json', 'size': len(evidence_raw), 'sha256': digest(evidence_raw)}
        if len(encoded(manifest)) > MAX_MANIFEST:
            raise ValueError('Auxiliary manifest exceeds the builder size limit')
        document(root / 'file-metadata.manifest.json', manifest)
        verify(root, require_complete=False)
        document(root / 'file-metadata.complete.json', {'schema': SCHEMA,
                 'manifest_sha256': digest(small(root / 'file-metadata.manifest.json'))})
        return manifest
    except BaseException as error:
        # This directory is exclusively owned by this attempt. Preserve failed
        # finalization evidence without leaving a consumable TSV/manifest pair.
        for name in ('file-metadata.complete.json', 'file-metadata.manifest.json', 'file-metadata.tsv'):
            path = root / name
            if path.exists():
                path.rename(root / (name + '.unverified'))
        if not (root / 'failure.json').exists():
            document(root / 'failure.json', {'ended_utc': utc(), 'error': str(error), 'generator_sha256': producer})
        raise


def verify(root, require_complete=True):
    if root.is_symlink() or not root.is_dir():
        raise ValueError('Unsafe capture directory')
    raw = small(root / 'file-metadata.manifest.json', MAX_MANIFEST)
    manifest = decode(raw)
    marker = decode(small(root / 'file-metadata.complete.json')) if require_complete else {'schema': SCHEMA, 'manifest_sha256': digest(raw)}
    if not isinstance(marker, dict) or not isinstance(manifest, dict) or marker.get('schema') != SCHEMA or marker.get('manifest_sha256') != digest(raw) or manifest.get('schema') != SCHEMA:
        raise ValueError('Capture completion/manifest identity mismatch')
    if manifest.get('generator_sha256') != digest(small(Path(__file__))):
        raise ValueError('Capture requires its original collector for replay')
    if manifest.get('dependency_sha256') != dependencies():
        raise ValueError('Capture preparation/normalization dependencies changed')
    if manifest.get('dump_date') is not None or manifest.get('temporal_scope') != 'current-api-observation':
        raise ValueError('Invalid API capture temporal scope')
    reference = manifest.get('evidence')
    if not isinstance(reference, dict) or reference.get('path') != 'capture-evidence.json':
        raise ValueError('Invalid capture evidence reference')
    evidence_raw = small(root / reference['path'])
    if len(evidence_raw) != reference.get('size') or digest(evidence_raw) != reference.get('sha256'):
        raise ValueError('Capture evidence index hash mismatch')
    evidence = decode(evidence_raw)
    if not isinstance(evidence, dict) or set(evidence) != set(EVIDENCE_FIELDS) or set(evidence).intersection(manifest):
        raise ValueError('Invalid capture evidence index')
    compact_manifest = manifest
    manifest = {**manifest, **evidence}
    if artifacts(root) != manifest.get('artifacts'):
        raise ValueError('Capture evidence inventory/hash mismatch')
    for source in [manifest['namespace_registry'], *manifest['input_sources']]:
        path = Path(source['path'])
        if path.is_absolute() or '..' in path.parts or not path.parts or source['path'] not in manifest['artifacts']:
            raise ValueError('Unsafe or unrecorded capture source path')
        if any(source.get(key) != value for key, value in fingerprint(root / path).items()):
            raise ValueError('Preserved seed identity differs from manifest')
    if manifest['dumpstatus'] is not None and manifest['dumpstatus'] not in manifest['artifacts']:
        raise ValueError('Unrecorded dumpstatus source')
    registry, titles = seed_candidates(root, manifest['input_sources'], manifest['namespace_registry']['path'],
            manifest['wiki'], manifest['date'], manifest['russian_variants'], manifest['dumpstatus'])
    candidates = decode(small(root / 'candidates.json'))
    if candidates != {'titles': titles, 'russian_variants': manifest['russian_variants']}:
        raise ValueError('Candidate set differs from preserved seeds')
    records, covered = {}, set()
    for batch in manifest['batches']:
        for field in ('request', 'accepted_receipt'):
            if batch[field] not in manifest['artifacts']:
                raise ValueError('Unrecorded API evidence')
        request = decode(small(root / batch['request']))
        requested = request['titles']
        if not isinstance(requested, list) or not 1 <= len(requested) <= 50 or len(set(requested)) != len(requested) or covered.intersection(requested):
            raise ValueError('Duplicate or invalid captured request titles')
        query = query_for(manifest['wiki'], requested)
        if request['query'] != query or request['url'] != query_url(manifest['wiki'], requested) or len(request['url']) > MAX_URL:
            raise ValueError('Captured request parameters differ from required semantics')
        receipt = decode(small(root / batch['accepted_receipt']))
        if receipt.get('accepted') is not True or receipt.get('status') != 200 or receipt.get('request') != batch['request'] or receipt.get('response') not in manifest['artifacts']:
            raise ValueError('Invalid accepted API receipt')
        response = small(root / receipt['response'], MAX_RESPONSE)
        if len(response) != receipt.get('response_bytes') or digest(response) != receipt.get('response_sha256'):
            raise ValueError('API response hash differs from receipt')
        data = decode(response)
        require_edition(data, registry.wiki)
        records.update(classify_response(data, requested, registry)); covered.update(requested)
    tsv = small(root / 'file-metadata.tsv')
    if (covered != set(titles) or set(records) != set(titles) or render(records) != tsv
            or manifest.get('rows') != len(records) or manifest.get('positive_rows') != sum(x['exists'] for x in records.values())
            or manifest.get('negative_rows') != sum(not x['exists'] for x in records.values())
            or manifest.get('unknown_rows') != 0 or manifest.get('candidate_queries_complete') is not True
            or manifest.get('corpus_query_closure_proven') is not False
            or manifest.get('output_bytes') != len(tsv) or manifest.get('output_sha256') != digest(tsv)):
        raise ValueError('Rendered snapshot differs from complete API evidence')
    return compact_manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    check = commands.add_parser('verify', help='Replay immutable capture evidence without networking')
    check.add_argument('output', type=Path)
    collect = commands.add_parser('capture', help='Capture a new, explicit current API observation')
    collect.add_argument('--wiki', required=True)
    collect.add_argument('--date', required=True, help='Associated dump date; API metadata is current at retrieval')
    collect.add_argument('--namespace-registry', required=True, type=Path)
    collect.add_argument('--output', required=True, type=Path, help='New isolated directory; existing paths are never replaced')
    collect.add_argument('--log', action='append', type=Path, default=[])
    collect.add_argument('--titles', action='append', type=Path, default=[], help='UTF-8 full File/Media titles, one per line')
    collect.add_argument('--sql', action='append', type=Path, default=[], help='Local dated image/imagelinks SQL candidate input')
    collect.add_argument('--dumpstatus', type=Path, help='Pinned dumpstatus for size/SHA1/URL verification of SQL seeds')
    collect.add_argument('--russian-variants', action='store_true', help='Seed all three preserved Russian audio probe branches')
    collect.add_argument('--batch-size', type=int, default=50)
    collect.add_argument('--delay', type=float, default=1.0, help='Seconds between sequential requests; minimum 1')
    collect.add_argument('--wall-seconds', type=int, default=1800)
    args = parser.parse_args()
    if args.command == 'capture' and args.delay < 1:
        parser.error('Network captures require at least one second between requests')
    result = capture(args) if args.command == 'capture' else verify(args.output)
    print(json.dumps({key: result[key] for key in ('wiki', 'date', 'rows', 'positive_rows', 'negative_rows', 'output_sha256', 'temporal_scope')}, sort_keys=True))


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError) as error:
        raise SystemExit(str(error)) from error
