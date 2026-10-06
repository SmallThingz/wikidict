#!/usr/bin/env python3
"""Capture explicit file metadata v2 with MediaWiki type and canonical title.

The v1 collector and existing captures remain unchanged. This collector accepts
finite title/log seeds, saves flat immutable API evidence, and fully replays it
before publication. API observations are current, not historical dump facts.
"""
import argparse
from datetime import datetime
from pathlib import Path
import re
import sys
import time
import urllib.parse

sys.dont_write_bytecode = True
import prepare_file_metadata as evidence

SCHEMA = 'wikidict.file-metadata-capture.v2'
HEADER = '# wikidict-file-metadata-v2'
PREFIX = 'file-metadata.'
MANIFEST = PREFIX + 'manifest.json'
COMPLETE = PREFIX + 'complete.json'
EVIDENCE = PREFIX + 'evidence.json'
NAMESPACE = PREFIX + 'namespace-registry.tsv'
MEDIATYPES = frozenset(('UNKNOWN', 'BITMAP', 'DRAWING', 'AUDIO', 'VIDEO',
                       'MULTIMEDIA', 'OFFICE', 'TEXT', 'EXECUTABLE', 'ARCHIVE', '3D'))
MAX_RESPONSE = evidence.MAX_RESPONSE
MAX_MANIFEST = evidence.MAX_MANIFEST
MAX_URL = evidence.MAX_URL
MAX_METADATA = evidence.MAX_METADATA
MAX_TITLES = evidence.MAX_TITLES
MAX_REQUESTS = 10000
REPO = evidence.REPO
utc, digest, encoded = evidence.utc, evidence.digest, evidence.encoded
small, decode, put, document = evidence.small, evidence.decode, evidence.put, evidence.document
require_edition, wiktionary_api = evidence.require_edition, evidence.wiktionary_api


def producer():
    return {'generator_sha256': digest(small(Path(__file__))),
            'dependency_sha256': {**evidence.dependencies(),
                'tools/prepare_file_metadata.py': digest(small(Path(evidence.__file__)))}}


def classify_response(data, titles, registry):
    records = evidence.classify_response(data, titles, registry)
    pages = {page['title']: page for page in data['query']['pages']}
    for row in records.values():
        if not row['exists']:
            row.update(mediatype='-', canonicaltitle='-')
            continue
        item = pages[row['response_title']]['imageinfo'][0]
        mediatype = item.get('mediatype')
        if not isinstance(mediatype, str) or mediatype not in MEDIATYPES:
            raise ValueError('Missing or unsupported authoritative MediaWiki mediatype')
        canonical = registry.file_title(item['canonicaltitle'])
        if registry.file_title(canonical) != canonical or any(c in canonical for c in '\t\r\n\0'):
            raise ValueError('Unstable or unsafe canonical file title')
        row.update(mediatype=mediatype, canonicaltitle=canonical)
    return records


def render(records):
    lines = [HEADER]
    for title in sorted(records, key=lambda x: x.encode('utf-8')):
        row = records[title]
        if row['exists']:
            if row['mediatype'] not in MEDIATYPES or not row['canonicaltitle'] or row['canonicaltitle'] == '-':
                raise ValueError('Incomplete positive v2 metadata')
        elif (row['width'], row['height'], row['mediatype'], row['canonicaltitle']) != (0, 0, '-', '-'):
            raise ValueError('Invalid negative v2 metadata')
        fields = (title, '1' if row['exists'] else '0', str(row['width']), str(row['height']),
                  row['mediatype'], row['canonicaltitle'])
        if any(any(c in value for c in '\t\r\n\0') for value in fields):
            raise ValueError('Unsafe file metadata TSV field')
        lines.append('\t'.join(fields))
    raw = ('\n'.join(lines) + '\n').encode('utf-8')
    if len(raw) > MAX_METADATA:
        raise ValueError('File metadata exceeds bounded snapshot capacity')
    return raw


def query_for(wiki, titles):
    return {**evidence.query_for(wiki, titles),
            'iiprop': 'size|sha1|timestamp|canonicaltitle|mediatype'}


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

def request_batch(root, number, titles, registry, transport, sleep, deadline, delay):
    query = query_for(registry.wiki, titles)
    url = query_url(registry.wiki, titles)
    if not 1 <= len(titles) <= 50 or len(url) > MAX_URL:
        raise ValueError('API request exceeds bounded title/URL size')
    request_name = f'file-metadata.request-{number:06d}.json'
    document(root / request_name, {'url': url, 'query': query, 'titles': titles})
    for attempt in range(1, 5):
        if time.monotonic() >= deadline:
            raise ValueError('Capture wall deadline reached')
        name = f'file-metadata.response-{number:06d}-{attempt:02d}'
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


def payload(root):
    result = {}
    for path in sorted(root.iterdir()):
        if not path.name.startswith(PREFIX) or path.name in (MANIFEST, COMPLETE, EVIDENCE):
            continue
        found = evidence.fingerprint(path)
        result[path.name] = {'size': found['size'], 'sha256': found['sha256']}
    return result


def safe_name(name):
    if not isinstance(name, str) or Path(name).name != name or not name.startswith(PREFIX):
        raise ValueError('Unsafe file metadata artifact name')
    return name


def candidates(root, inputs, registry):
    if not isinstance(inputs, list) or not 1 <= len(inputs) <= 1024:
        raise ValueError('Invalid file metadata seed inventory')
    titles, seen = set(), set()
    for row in inputs:
        if not isinstance(row, dict) or row.get('kind') not in ('titles', 'log'):
            raise ValueError('Unsupported file metadata seed kind')
        name = safe_name(row.get('path'))
        if name in seen:
            raise ValueError('Duplicate file metadata seed input')
        seen.add(name)
        if any(row.get(k) != v for k, v in evidence.fingerprint(root / name).items()):
            raise ValueError('Preserved file metadata seed identity changed')
        evidence.seed_file(root / name, row['kind'], titles, registry, False)
    if not titles:
        raise ValueError('No explicit file metadata candidates')
    return sorted(titles, key=lambda value: value.encode('utf-8'))


def capture(args, transport=None, sleep=time.sleep):
    if (not re.fullmatch(r'\d{8}', args.date) or not 1 <= args.batch_size <= 50
            or not 0 <= args.delay <= 60 or not 1 <= args.wall_seconds <= 86400):
        raise ValueError('Invalid date or bounded capture settings')
    wiktionary_api(args.wiki)
    datetime.strptime(args.date, '%Y%m%d')
    root = args.output
    root.mkdir(parents=True, exist_ok=False)
    identity = producer()
    started, deadline = utc(), time.monotonic() + args.wall_seconds
    try:
        paths = [args.namespace_registry, *args.titles, *args.log]
        if not 1 <= len(paths) - 1 <= 1024:
            raise ValueError('Invalid explicit file metadata seed count')
        stamps = {path: evidence.stamp(path) for path in paths}
        namespace_record = evidence.snapshot_input(args.namespace_registry, root, NAMESPACE)
        registry = evidence.Registry(small(root / NAMESPACE), args.wiki, args.date)
        inputs = []
        for kind in ('titles', 'log'):
            for path in getattr(args, kind):
                name = f'file-metadata.input-{len(inputs):04d}.{kind}'
                inputs.append({**evidence.snapshot_input(path, root, name), 'kind': kind})
        titles = candidates(root, inputs, registry)
        document(root / (PREFIX + 'candidates.json'), {'titles': titles})
        records, batches = {}, []
        for batch in title_batches(args.wiki, titles, args.batch_size):
            if len(batches) >= MAX_REQUESTS:
                raise ValueError('File metadata request bound exceeded')
            if batches:
                if time.monotonic() + args.delay >= deadline:
                    raise ValueError('Capture wall deadline reached')
                sleep(args.delay)
            found, receipt = request_batch(root, len(batches) + 1, batch, registry,
                    transport or evidence.get_response, sleep, deadline, args.delay)
            records.update(found)
            batches.append(receipt)
        if set(records) != set(titles):
            raise ValueError('Incomplete file metadata capture')
        if producer() != identity or any(evidence.stamp(p) != s for p, s in stamps.items()):
            raise ValueError('File metadata collector or seed source changed')
        tsv = render(records)
        put(root / 'file-metadata.tsv', tsv)
        index = {'namespace_registry': namespace_record, 'inputs': inputs,
                 'batches': batches, 'artifacts': payload(root)}
        index_raw = encoded(index)
        if len(index_raw) > MAX_METADATA:
            raise ValueError('File metadata evidence index exceeds bound')
        put(root / EVIDENCE, index_raw)
        manifest = {'schema': SCHEMA, 'header_version': 2, 'wiki': args.wiki, 'date': args.date,
                    'dump_date': None, 'temporal_scope': 'current-api-observation',
                    'source_url': wiktionary_api(args.wiki), 'started_utc': started, 'retrieved_utc': utc(),
                    **identity, 'namespace_registry_sha256': namespace_record['sha256'],
                    'evidence': {'path': EVIDENCE, 'size': len(index_raw), 'sha256': digest(index_raw)},
                    'rows': len(records), 'positive_rows': sum(x['exists'] for x in records.values()),
                    'negative_rows': sum(not x['exists'] for x in records.values()), 'unknown_rows': 0,
                    'candidate_queries_complete': True, 'corpus_query_closure_proven': False,
                    'output_bytes': len(tsv), 'output_sha256': digest(tsv)}
        if len(encoded(manifest)) > MAX_MANIFEST:
            raise ValueError('File metadata manifest exceeds bound')
        document(root / MANIFEST, manifest)
        verify(root, require_complete=False)
        document(root / COMPLETE, {'schema': SCHEMA, 'manifest_sha256': digest(small(root / MANIFEST))})
        return manifest
    except BaseException as error:
        for name in (COMPLETE, MANIFEST, 'file-metadata.tsv'):
            path = root / name
            if path.exists():
                path.rename(root / (name + '.unverified'))
        if not (root / (PREFIX + 'failure.json')).exists():
            document(root / (PREFIX + 'failure.json'), {'ended_utc': utc(), 'error': str(error), **identity})
        raise


def evidence_index(root, manifest):
    reference = manifest.get('evidence')
    if not isinstance(reference, dict) or reference.get('path') != EVIDENCE:
        raise ValueError('Invalid file metadata evidence reference')
    raw = small(root / EVIDENCE)
    if reference.get('size') != len(raw) or reference.get('sha256') != digest(raw):
        raise ValueError('File metadata evidence index changed')
    index = decode(raw)
    if not isinstance(index, dict) or set(index) != {'namespace_registry', 'inputs', 'batches', 'artifacts'}:
        raise ValueError('Invalid file metadata evidence index')
    if not isinstance(index['artifacts'], dict) or payload(root) != index['artifacts']:
        raise ValueError('File metadata artifact inventory changed')
    return index


def verify(root, require_complete=True):
    if root.is_symlink() or not root.is_dir():
        raise ValueError('Unsafe file metadata capture root')
    raw = small(root / MANIFEST, MAX_MANIFEST)
    manifest = decode(raw)
    expected_marker = {'schema': SCHEMA, 'manifest_sha256': digest(raw)}
    marker = decode(small(root / COMPLETE)) if require_complete else expected_marker
    if (not isinstance(manifest, dict) or manifest.get('schema') != SCHEMA
            or manifest.get('header_version') != 2 or marker != expected_marker):
        raise ValueError('File metadata completion/schema mismatch')
    if any(manifest.get(key) != value for key, value in producer().items()):
        raise ValueError('File metadata collector or dependency identity changed')
    if (manifest.get('dump_date') is not None or manifest.get('temporal_scope') != 'current-api-observation'
            or manifest.get('source_url') != wiktionary_api(manifest['wiki'])):
        raise ValueError('Invalid file metadata capture scope')
    if not isinstance(manifest.get('date'), str) or not re.fullmatch(r'\d{8}', manifest['date']):
        raise ValueError('Invalid file metadata date')
    datetime.strptime(manifest['date'], '%Y%m%d')
    index = evidence_index(root, manifest)
    namespace = index['namespace_registry']
    if not isinstance(namespace, dict) or namespace.get('path') != NAMESPACE:
        raise ValueError('Invalid file metadata namespace source')
    if any(namespace.get(k) != v for k, v in evidence.fingerprint(root / NAMESPACE).items()):
        raise ValueError('File metadata namespace source changed')
    namespace_raw = small(root / NAMESPACE)
    if manifest.get('namespace_registry_sha256') != digest(namespace_raw):
        raise ValueError('File metadata namespace identity mismatch')
    registry = evidence.Registry(namespace_raw, manifest['wiki'], manifest['date'])
    titles = candidates(root, index['inputs'], registry)
    title_set = set(titles)
    if decode(small(root / (PREFIX + 'candidates.json'))) != {'titles': titles}:
        raise ValueError('File metadata candidates differ from preserved seeds')
    batches = index['batches']
    if not isinstance(batches, list) or not 1 <= len(batches) <= MAX_REQUESTS:
        raise ValueError('Invalid file metadata request inventory')
    records, covered = {}, set()
    for batch in batches:
        if not isinstance(batch, dict) or set(batch) != {'request', 'accepted_receipt'}:
            raise ValueError('Invalid file metadata batch')
        for name in batch.values():
            if safe_name(name) not in index['artifacts']:
                raise ValueError('Unrecorded file metadata API evidence')
        request = decode(small(root / batch['request']))
        requested = request.get('titles') if isinstance(request, dict) else None
        if (not isinstance(requested, list) or not 1 <= len(requested) <= 50
                or any(not isinstance(t, str) for t in requested)
                or len(set(requested)) != len(requested) or covered.intersection(requested)
                or not set(requested) <= title_set):
            raise ValueError('Invalid or duplicate file metadata query titles')
        if (request.get('query') != query_for(manifest['wiki'], requested)
                or request.get('url') != query_url(manifest['wiki'], requested)
                or len(request['url']) > MAX_URL):
            raise ValueError('File metadata query semantics changed')
        receipt = decode(small(root / batch['accepted_receipt']))
        if (not isinstance(receipt, dict) or receipt.get('accepted') is not True
                or receipt.get('status') != 200 or receipt.get('request') != batch['request']
                or safe_name(receipt.get('response')) not in index['artifacts']):
            raise ValueError('Invalid file metadata accepted receipt')
        response = small(root / receipt['response'], MAX_RESPONSE)
        if receipt.get('response_bytes') != len(response) or receipt.get('response_sha256') != digest(response):
            raise ValueError('File metadata API response changed')
        data = decode(response)
        require_edition(data, registry.wiki)
        records.update(classify_response(data, requested, registry))
        covered.update(requested)
    tsv = small(root / 'file-metadata.tsv')
    if (covered != title_set or set(records) != title_set or render(records) != tsv
            or manifest.get('rows') != len(records)
            or manifest.get('positive_rows') != sum(x['exists'] for x in records.values())
            or manifest.get('negative_rows') != sum(not x['exists'] for x in records.values())
            or manifest.get('unknown_rows') != 0 or manifest.get('candidate_queries_complete') is not True
            or manifest.get('corpus_query_closure_proven') is not False
            or manifest.get('output_bytes') != len(tsv) or manifest.get('output_sha256') != digest(tsv)):
        raise ValueError('File metadata TSV differs from complete API evidence')
    return manifest


def validate_snapshot(path, edition=None, date=None):
    path = Path(path)
    if path.name != 'file-metadata.tsv' or path.is_symlink():
        raise ValueError('Invalid file metadata snapshot path')
    manifest = verify(path.parent)
    if ((edition is not None and manifest['wiki'] != edition)
            or (date is not None and manifest['date'] != date)):
        raise ValueError('File metadata edition/date mismatch')
    return manifest


def capture_artifacts(path, manifest):
    root = Path(path).parent
    index = evidence_index(root, manifest)
    result = {name: row['sha256'] for name, row in index['artifacts'].items()}
    for name in (MANIFEST, COMPLETE, EVIDENCE):
        result[name] = digest(small(root / name))
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    check = commands.add_parser('verify')
    check.add_argument('output', type=Path)
    collect = commands.add_parser('capture')
    collect.add_argument('--wiki', required=True)
    collect.add_argument('--date', required=True)
    collect.add_argument('--namespace-registry', type=Path, required=True)
    collect.add_argument('--output', type=Path, required=True)
    collect.add_argument('--titles', type=Path, action='append', default=[])
    collect.add_argument('--log', type=Path, action='append', default=[])
    collect.add_argument('--batch-size', type=int, default=50)
    collect.add_argument('--delay', type=float, default=1)
    collect.add_argument('--wall-seconds', type=int, default=1800)
    args = parser.parse_args()
    if args.command == 'capture' and args.delay < 1:
        parser.error('Network captures require at least one second between requests')
    result = capture(args) if args.command == 'capture' else verify(args.output)
    print(encoded({key: result[key] for key in ('wiki', 'date', 'rows', 'positive_rows',
                 'negative_rows', 'output_sha256', 'temporal_scope')}).decode(), end='')


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError) as error:
        raise SystemExit(str(error)) from error
