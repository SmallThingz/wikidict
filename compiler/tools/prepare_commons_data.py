#!/usr/bin/env python3
"""Capture positive Commons tabular pages with immutable raw revision evidence.

This is a current API observation associated with a dated dictionary input,
not a historical reconstruction. Only explicitly requested titles are covered.
"""
import argparse
from datetime import datetime
import json
from pathlib import Path
import re
import sys
import time
import urllib.parse

sys.dont_write_bytecode = True
import prepare_file_metadata as evidence

SCHEMA = 'wikidict.commons-data-capture.v1'
API = 'https://commons.wikimedia.org/w/api.php'
MAX_MANIFEST = 64 * 1024
MAX_RESPONSE = 2 * 1024 * 1024
MAX_TITLES = 16
COMPLETE = 'commons-data.complete.json'


def producer():
    return {'generator_sha256': evidence.digest(evidence.small(Path(__file__))),
            'dependency_sha256': {name: evidence.digest(evidence.small(evidence.REPO / name))
                for name in ('tools/prepare_file_metadata.py', 'tools/download_wiktionaries.py',
                             'tools/category_tree_snapshot.py')}}


def namespace_identity(raw, wiki, date):
    lines = raw.decode('utf-8').splitlines()
    if (len(lines) < 4 or lines[:3] != ['# wikidict-namespace-registry-v1',
            '# wiki\t' + wiki, '# dump-date\t' + date]
            or not lines[3].startswith('# content-language\t')):
        raise ValueError('Namespace identity mismatch')
    language = lines[3].split('\t', 1)[1]
    if not re.fullmatch(r'[A-Za-z0-9-]{2,64}', language):
        raise ValueError('Invalid namespace content language')
    return language


def checked_title(title):
    if (not isinstance(title, str) or not 1 <= len(title.encode('utf-8')) <= 512
            or not title.endswith('.tab') or title.startswith('Data:')
            or any(c in title for c in '|\t\r\n\0#[]{}')
            or title != title.strip() or '_' in title):
        raise ValueError('Expected explicit canonical Commons .tab name without Data: prefix')
    return title


def query_for(title):
    return {'action': 'query', 'format': 'json', 'formatversion': '2',
            'meta': 'siteinfo', 'siprop': 'general', 'prop': 'revisions',
            'rvprop': 'ids|timestamp|content|contentmodel', 'rvslots': 'main',
            'titles': 'Data:' + checked_title(title), 'maxlag': '5'}


def query_url(title):
    return API + '?' + urllib.parse.urlencode(query_for(title))


def classify(data, title):
    if not isinstance(data, dict) or any(k in data for k in ('error', 'errors', 'warnings', 'continue')):
        raise ValueError('Unsuccessful or incomplete Commons API observation')
    query = data.get('query')
    if not isinstance(query, dict) or query.get('general', {}).get('wikiid') != 'commonswiki':
        raise ValueError('Commons repository identity mismatch')
    if any(query.get(k) for k in ('normalized', 'redirects', 'converted')):
        raise ValueError('Unexpected Commons title normalization or redirect')
    pages = query.get('pages')
    if not isinstance(pages, list) or len(pages) != 1:
        raise ValueError('Expected one exact Commons page')
    page = pages[0]
    if (not isinstance(page, dict) or page.get('title') != 'Data:' + title
            or not isinstance(page.get('pageid'), int) or isinstance(page['pageid'], bool)
            or page['pageid'] <= 0 or any(k in page for k in ('missing', 'invalid', 'redirect'))):
        raise ValueError('Requested Commons page is missing, invalid, or different')
    revisions = page.get('revisions')
    if not isinstance(revisions, list) or len(revisions) != 1:
        raise ValueError('Expected one visible Commons revision')
    revision = revisions[0]
    if (not isinstance(revision, dict) or not isinstance(revision.get('revid'), int)
            or isinstance(revision['revid'], bool) or revision['revid'] <= 0
            or any(k in revision for k in ('texthidden', 'suppressed'))
            or not isinstance(revision.get('timestamp'), str)):
        raise ValueError('Invalid or suppressed Commons revision')
    datetime.strptime(revision['timestamp'], '%Y-%m-%dT%H:%M:%SZ')
    slot = revision.get('slots', {}).get('main')
    if (not isinstance(slot, dict) or slot.get('contentmodel') != 'Tabular.JsonConfig'
            or not isinstance(slot.get('content'), str)
            or any(k in slot for k in ('texthidden', 'contenthidden', 'suppressed'))):
        raise ValueError('Expected visible Tabular.JsonConfig main slot')
    source = slot['content']
    if not source or '\0' in source or len(source.encode('utf-8')) > MAX_RESPONSE:
        raise ValueError('Invalid or oversized Commons source')
    value = evidence.decode(source)
    if not isinstance(value, dict) or not isinstance(value.get('schema'), dict):
        raise ValueError('Invalid tabular JSON root/schema')
    fields = value['schema'].get('fields')
    rows = value.get('data')
    if (not isinstance(fields, list) or not fields or len(fields) > 128
            or any(not isinstance(f, dict) or not isinstance(f.get('name'), str)
                   or not isinstance(f.get('type'), str) for f in fields)
            or len({f['name'] for f in fields}) != len(fields)
            or not isinstance(rows, list) or len(rows) > 100000
            or any(not isinstance(row, list) or len(row) != len(fields) for row in rows)):
        raise ValueError('Invalid tabular fields or rows')
    compact = json.dumps(value, ensure_ascii=False, separators=(',', ':'), allow_nan=False)
    return {'title': title, 'page_id': page['pageid'], 'revision_id': revision['revid'],
            'revision_timestamp': revision['timestamp'], 'content_model': slot['contentmodel'],
            'source_sha256': evidence.digest(source.encode()), 'compact_source': compact,
            'license': value.get('license'), 'fields': fields, 'rows': len(rows)}


def render(records, wiki, date, language):
    lines = ['# wikidict-commons-data-v1', '# wiki\t' + wiki, '# dump-date\t' + date,
             '# content-language\t' + language, '# repository\thttps://commons.wikimedia.org']
    for title in sorted(records):
        record = records[title]
        lines.append(title + '\t' + record['content_model'] + '\t' + record['compact_source'])
    return ('\n'.join(lines) + '\n').encode()


def observe(root, number, title, transport, sleep, deadline, delay):
    stem = f'commons-request-{number:06d}'
    request_name = stem + '.request.json'
    request = {'title': title, 'query': query_for(title), 'url': query_url(title)}
    evidence.document(root / request_name, request)
    for attempt in range(1, 5):
        prefix = f'{stem}-{attempt:02d}'
        receipt_name = prefix + '.receipt.json'
        receipt = {'request': request_name, 'started_utc': evidence.utc(), 'status': None}
        retry, headers = False, {}
        try:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise ValueError('Capture deadline reached')
            status, headers, raw = transport(request['url'], min(30, remaining))
            raw_name = prefix + '.raw.json'
            evidence.put(root / raw_name, raw)
            receipt.update(status=status, response=raw_name, response_bytes=len(raw),
                response_sha256=evidence.digest(raw), headers={k.lower(): v for k, v in headers.items()
                    if k.lower() in ('date', 'content-type', 'retry-after', 'etag')})
            if len(raw) > MAX_RESPONSE:
                raise ValueError('Commons response exceeds byte limit')
            if status != 200:
                retry = status in (429, 500, 502, 503, 504)
                raise ValueError('Commons HTTP status ' + str(status))
            data = evidence.decode(raw)
            if isinstance(data, dict) and isinstance(data.get('error'), dict):
                retry = data['error'].get('code') in ('maxlag', 'ratelimited', 'readonly')
            record = classify(data, title)
            receipt.update(accepted=True, ended_utc=evidence.utc())
            evidence.document(root / receipt_name, receipt)
            return record, {'request': request_name, 'accepted_receipt': receipt_name}
        except (OSError, ValueError) as error:
            if isinstance(error, OSError):
                retry = True
            receipt.update(accepted=False, ended_utc=evidence.utc(), error=str(error))
            evidence.document(root / receipt_name, receipt)
            if not retry or attempt == 4:
                raise
            wait_header = next((v for k, v in headers.items() if k.lower() == 'retry-after'), '')
            if wait_header and not str(wait_header).isdigit():
                raise ValueError('Unsupported Retry-After') from error
            wait = max(delay, 2 ** (attempt - 1), int(wait_header or 0))
            if wait > 60 or time.monotonic() + wait >= deadline:
                raise ValueError('Retry exceeds capture deadline') from error
            sleep(wait)


def payload_inventory(root):
    return {p.name: evidence.digest(evidence.small(p)) for p in sorted(root.iterdir())
            if p.name not in ('commons-data.manifest.json', COMPLETE)}


def capture(args, transport=None, sleep=time.sleep):
    datetime.strptime(args.date, '%Y%m%d')
    if not re.fullmatch(r'[a-z0-9_-]+wiktionary', args.wiki):
        raise ValueError('Invalid target wiki')
    if not 0 <= args.delay <= 60 or not 1 <= args.wall_seconds <= 3600:
        raise ValueError('Invalid capture time bounds')
    titles = sorted(set(checked_title(x) for x in args.title))
    if not 1 <= len(titles) <= MAX_TITLES:
        raise ValueError('Invalid bounded Commons title inventory')
    namespace = evidence.small(args.namespace_registry)
    stamp = evidence.stamp(args.namespace_registry)
    language = namespace_identity(namespace, args.wiki, args.date)
    identity = producer()
    root = args.output
    root.mkdir(parents=True, exist_ok=False)
    started = evidence.utc()
    deadline = time.monotonic() + args.wall_seconds
    try:
        configuration = {'wiki': args.wiki, 'date': args.date, 'content_language': language,
                         'titles': titles, 'namespace_registry_sha256': evidence.digest(namespace)}
        evidence.put(root / 'commons-namespace-registry.tsv', namespace)
        evidence.document(root / 'commons-requested.json', configuration)
        records, requests = {}, []
        for i, title in enumerate(titles, 1):
            if i > 1:
                if time.monotonic() + args.delay >= deadline:
                    raise ValueError('Capture deadline reached')
                sleep(args.delay)
            records[title], request = observe(root, i, title, transport or evidence.get_response,
                                              sleep, deadline, args.delay)
            requests.append(request)
        if producer() != identity or evidence.stamp(args.namespace_registry) != stamp:
            raise ValueError('Collector or namespace changed during capture')
        raw = render(records, args.wiki, args.date, language)
        evidence.put(root / 'commons-data.tsv', raw)
        manifest = {'schema': SCHEMA, **configuration, **identity,
                    'source_url': API, 'dump_date': None, 'temporal_scope': 'current-api-observation',
                    'started_utc': started, 'retrieved_utc': evidence.utc(), 'requests': requests,
                    'rows': len(records), 'records': [records[k] for k in sorted(records)],
                    'candidate_queries_complete': True, 'corpus_query_closure_proven': False,
                    'output_bytes': len(raw), 'output_sha256': evidence.digest(raw),
                    'artifacts': payload_inventory(root)}
        # Source bytes already occur in raw API evidence and the TSV.
        for record in manifest['records']:
            record.pop('compact_source')
        encoded = evidence.encoded(manifest)
        if len(encoded) > MAX_MANIFEST:
            raise ValueError('Commons manifest exceeds consumer limit')
        evidence.put(root / 'commons-data.manifest.json', encoded)
        verify(root, require_complete=False)
        evidence.document(root / COMPLETE, {'schema': SCHEMA, 'manifest_sha256': evidence.digest(encoded)})
        return manifest
    except BaseException as error:
        for name in (COMPLETE, 'commons-data.tsv', 'commons-data.manifest.json'):
            p = root / name
            if p.exists():
                p.rename(root / (name + '.unverified'))
        evidence.document(root / 'commons-failure.json', {'ended_utc': evidence.utc(), 'error': str(error), **identity})
        raise


def verify(root, require_complete=True):
    root = Path(root)
    if root.is_symlink() or not root.is_dir():
        raise ValueError('Unsafe Commons capture root')
    raw_manifest = evidence.small(root / 'commons-data.manifest.json', MAX_MANIFEST)
    manifest = evidence.decode(raw_manifest)
    if not isinstance(manifest, dict) or manifest.get('schema') != SCHEMA:
        raise ValueError('Unsupported Commons manifest')
    if require_complete and evidence.decode(evidence.small(root / COMPLETE)) != {
            'schema': SCHEMA, 'manifest_sha256': evidence.digest(raw_manifest)}:
        raise ValueError('Commons completion mismatch')
    if any(manifest.get(k) != v for k, v in producer().items()):
        raise ValueError('Commons collector dependencies changed')
    if (manifest.get('source_url') != API or manifest.get('dump_date') is not None
            or manifest.get('temporal_scope') != 'current-api-observation'
            or manifest.get('candidate_queries_complete') is not True
            or manifest.get('corpus_query_closure_proven') is not False):
        raise ValueError('Unsupported Commons provenance scope')
    inventory = manifest.get('artifacts')
    if not isinstance(inventory, dict) or inventory != payload_inventory(root):
        raise ValueError('Commons payload inventory mismatch')
    for name, sha in inventory.items():
        if Path(name).name != name or not re.fullmatch('[0-9a-f]{64}', sha):
            raise ValueError('Unsafe Commons artifact inventory')
    configuration = evidence.decode(evidence.small(root / 'commons-requested.json'))
    if any(manifest.get(k) != v for k, v in configuration.items()):
        raise ValueError('Commons request configuration mismatch')
    wiki, date = configuration['wiki'], configuration['date']
    namespace = evidence.small(root / 'commons-namespace-registry.tsv')
    language = namespace_identity(namespace, wiki, date)
    if (configuration['content_language'] != language
            or configuration['namespace_registry_sha256'] != evidence.digest(namespace)):
        raise ValueError('Commons namespace proof mismatch')
    titles = configuration['titles']
    if (not isinstance(titles, list) or not 1 <= len(titles) <= MAX_TITLES
            or titles != sorted(set(checked_title(x) for x in titles))
            or not isinstance(manifest.get('requests'), list) or len(manifest['requests']) != len(titles)):
        raise ValueError('Commons request inventory mismatch')
    records = {}
    for i, (title, request_ref) in enumerate(zip(titles, manifest['requests']), 1):
        name = f'commons-request-{i:06d}.request.json'
        if request_ref.get('request') != name:
            raise ValueError('Commons request sequence mismatch')
        request = evidence.decode(evidence.small(root / name))
        if request != {'title': title, 'query': query_for(title), 'url': query_url(title)}:
            raise ValueError('Commons query mismatch')
        accepted = request_ref.get('accepted_receipt')
        if not isinstance(accepted, str) or not re.fullmatch(f'commons-request-{i:06d}-0[1-4]\\.receipt\\.json', accepted):
            raise ValueError('Invalid Commons accepted receipt')
        receipt = evidence.decode(evidence.small(root / accepted))
        response = accepted.replace('.receipt.json', '.raw.json')
        raw = evidence.small(root / response, MAX_RESPONSE)
        if (receipt.get('request') != name or receipt.get('accepted') is not True
                or receipt.get('status') != 200 or receipt.get('response') != response
                or receipt.get('response_sha256') != evidence.digest(raw)
                or receipt.get('response_bytes') != len(raw)):
            raise ValueError('Commons response receipt mismatch')
        records[title] = classify(evidence.decode(raw), title)
    expected = render(records, wiki, date, language)
    if (evidence.small(root / 'commons-data.tsv') != expected
            or manifest.get('output_sha256') != evidence.digest(expected)
            or manifest.get('output_bytes') != len(expected) or manifest.get('rows') != len(records)):
        raise ValueError('Commons TSV replay mismatch')
    proofs = [{k: v for k, v in records[t].items() if k != 'compact_source'} for t in sorted(records)]
    if manifest.get('records') != proofs:
        raise ValueError('Commons revision proof mismatch')
    return manifest


def validate_snapshot(path, wiki=None, date=None):
    path = Path(path)
    if path.name != 'commons-data.tsv':
        raise ValueError('Unexpected Commons snapshot name')
    manifest = verify(path.parent)
    if ((wiki is not None and wiki != manifest['wiki'])
            or (date is not None and date != manifest['date'])):
        raise ValueError('Commons edition/date mismatch')
    return manifest


def capture_artifacts(path, manifest):
    root = Path(path).parent
    return {**manifest['artifacts'], **{name: evidence.digest(evidence.small(root / name))
            for name in ('commons-data.manifest.json', COMPLETE)}}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    cap = commands.add_parser('capture')
    cap.add_argument('--wiki', required=True)
    cap.add_argument('--date', required=True)
    cap.add_argument('--namespace-registry', type=Path, required=True)
    cap.add_argument('--title', action='append', required=True)
    cap.add_argument('--output', type=Path, required=True)
    cap.add_argument('--delay', type=float, default=0.5)
    cap.add_argument('--wall-seconds', type=float, default=300)
    check = commands.add_parser('verify')
    check.add_argument('root', type=Path)
    args = parser.parse_args()
    print(json.dumps(capture(args) if args.command == 'capture' else verify(args.root), ensure_ascii=False))


if __name__ == '__main__':
    main()
