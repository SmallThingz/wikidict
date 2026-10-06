#!/usr/bin/env python3
"""Capture v2 site-info with seven current Scribunto counters from one response.

The existing namespace capture is immutable. This profile creates a separate
generation and preserves the complete API response, including failed retries.
The historical installed filename namespace-siteinfo.raw.json now carries an
explicit v2 envelope; the original HTTP bytes have their own receipt-bound file.
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
import site_info_snapshot as legacy

SCHEMA = 'wikidict.site-info-capture.v2'
HEADER = 'wikidict.site-info.v2'
PROFILE = 'general-and-seven-scribunto-statistics'
SNAPSHOT = 'namespace-siteinfo.raw.json'
MANIFEST = 'site-info.manifest.json'
COMPLETE = 'site-info.complete.json'
PREFIX = 'site-info.'
CORE = '0d3b507d19ae860ed8a1d22c73fa4bc5abf8dfcc'
# Exact deployment revisions whose complete ApiQuerySiteinfo.php is byte-identical
# to SOURCE_PINS below; other revisions require another explicit source review.
CORE_PROFILES = (CORE, '79b81ba96674efc8a803fc956bc501d347d440d2')
SCRIBUNTO = 'b109cb6e5866c13871e308859ef78249b1bd3ea2'
MAX_RESPONSE = 2 * 1024 * 1024
MAX_MANIFEST = 64 * 1024
MAX_INTEGER = 2**53 - 1
FIELDS = {'pages': 'pages', 'articles': 'articles', 'files': 'images',
          'edits': 'edits', 'users': 'users', 'activeUsers': 'activeusers', 'admins': 'admins'}
SOURCE_PINS = {
    'ApiQuerySiteinfo.php': 'a318da6f2cae4275a15595a93aa324bcbeb433381b29bd356fc577f72d5c2ced',
    'SiteLibrary.php': '564db2fbec6c5e9bb46e02eccf1d1b9cde9fac7f5e02efaccf185b2f7c69e60d',
    'mw.site.lua': '97555f7f9c575fd098f78a72ad590ef753b7389c5715d521168635c63dabbab8',
}


def stamp(value):
    if not isinstance(value, str):
        raise ValueError('Missing observation timestamp')
    result = datetime.fromisoformat(value.replace('Z', '+00:00'))
    if result.tzinfo is None:
        raise ValueError('Observation timestamp lacks timezone')
    return result


def namespace_identity(raw, wiki, date):
    evidence.wiktionary_api(wiki)
    if not isinstance(date, str) or not re.fullmatch('[0-9]{8}', date):
        raise ValueError('Invalid dump date')
    datetime.strptime(date, '%Y%m%d')
    lines = raw.decode().splitlines()
    if len(lines) < 4 or lines[:3] != ['# wikidict-namespace-registry-v1',
            '# wiki\t' + wiki, '# dump-date\t' + date] or not lines[3].startswith('# content-language\t'):
        raise ValueError('Namespace edition/date mismatch')
    language = lines[3].split('\t', 1)[1]
    if not re.fullmatch('[a-z0-9-]{2,128}', language):
        raise ValueError('Invalid namespace content language')
    return language


def producer():
    return {'generator_sha256': evidence.digest(evidence.small(Path(__file__))),
            'dependency_sha256': {name: evidence.digest(evidence.small(Path(evidence.__file__).with_name(name)))
                for name in ('prepare_file_metadata.py', 'download_wiktionaries.py',
                             'site_info_snapshot.py', 'namespace_registry_snapshot.py')}}


def primary_sources(root, prefix=''):
    result = {}
    for name, expected in SOURCE_PINS.items():
        raw = evidence.small(Path(root) / (prefix + name), MAX_RESPONSE)
        if evidence.digest(raw) != expected:
            raise ValueError('Unreviewed primary source: ' + name)
        result[name] = raw
    return result


def query():
    return {'action': 'query', 'meta': 'siteinfo', 'siprop': 'general|statistics',
            'format': 'json', 'formatversion': '2', 'maxlag': '5'}


def response(data, wiki, language):
    if not isinstance(data, dict) or any(key in data for key in ('error', 'errors', 'warnings', 'continue')):
        raise ValueError('Unsuccessful or incomplete site-info API response')
    result = data.get('query')
    general = result.get('general') if isinstance(result, dict) else None
    if (not isinstance(general, dict) or general.get('wikiid') != wiki
            or general.get('lang') != language or general.get('git-hash') not in CORE_PROFILES):
        raise ValueError('Site-info edition/language/source mismatch')
    legacy.validate_server(general.get('server'))
    stamp(general.get('time'))
    counters = result.get('statistics')
    if not isinstance(counters, dict) or any(type(counters.get(key)) is not int
            or not 0 <= counters[key] <= MAX_INTEGER for key in FIELDS.values()):
        raise ValueError('Missing or invalid complete site statistics')
    return result


def render(data, config, retrieved, raw_sha):
    result = response(data, config['wiki'], config['content_language'])
    return evidence.encoded({'schema': HEADER, **config, 'temporal_scope': 'current-api-observation',
        'retrieved_utc': retrieved, 'raw_response_sha256': raw_sha, 'query': result})


def payload(root):
    rows = {}
    for path in root.iterdir():
        if path.name in (MANIFEST, COMPLETE):
            continue
        if path.name != SNAPSHOT and not path.name.startswith(PREFIX):
            raise ValueError('Unexpected capture artifact: ' + path.name)
        raw = evidence.small(path, MAX_RESPONSE)
        rows[path.name] = {'size': len(raw), 'sha256': evidence.digest(raw)}
    return dict(sorted(rows.items()))


def capture(args, transport=None, sleep=time.sleep):
    if not 0 <= args.delay <= 60 or not 1 <= args.wall_seconds <= 3600:
        raise ValueError('Invalid capture bounds')
    namespace = evidence.small(args.namespace_registry, MAX_RESPONSE)
    language = namespace_identity(namespace, args.wiki, args.date)
    sources = primary_sources(args.primary_sources)
    config = {'wiki': args.wiki, 'date': args.date, 'content_language': language,
              'namespace_registry_sha256': evidence.digest(namespace), 'profile': PROFILE}
    identity = producer()
    root = Path(args.output)
    root.mkdir(parents=True, exist_ok=False)
    started, deadline = evidence.utc(), time.monotonic() + args.wall_seconds
    try:
        evidence.put(root / (PREFIX + 'namespace-registry.tsv'), namespace)
        for name, raw in sources.items():
            evidence.put(root / (PREFIX + 'source-' + name), raw)
        url = evidence.wiktionary_api(args.wiki) + '?' + urllib.parse.urlencode(sorted(query().items()))
        request = {'url': url, 'query': query(), **config}
        evidence.document(root / (PREFIX + 'request.json'), request)
        accepted = None
        for attempt in range(1, 5):
            if time.monotonic() >= deadline:
                raise ValueError('Capture deadline reached')
            name = PREFIX + f'{attempt:02d}'
            receipt = {'request': PREFIX + 'request.json', 'started_utc': evidence.utc()}
            retry, headers = False, {}
            try:
                status, headers, raw = (transport or evidence.get_response)(url, min(30, deadline - time.monotonic()))
                receipt.update(status=status, response=name + '.raw.json', response_bytes=len(raw),
                    response_sha256=evidence.digest(raw), headers={k.lower(): v for k, v in headers.items()
                    if k.lower() in ('date', 'content-type', 'retry-after', 'etag')})
                evidence.put(root / receipt['response'], raw)
                if len(raw) > MAX_RESPONSE:
                    raise ValueError('Oversized API response')
                if status != 200:
                    retry = status in (429, 500, 502, 503, 504)
                    raise ValueError('HTTP status ' + str(status))
                data = evidence.decode(raw)
                if isinstance(data, dict) and isinstance(data.get('error'), dict):
                    retry = data['error'].get('code') in ('maxlag', 'ratelimited', 'readonly')
                response(data, args.wiki, language)
                receipt.update(accepted=True, ended_utc=evidence.utc())
                evidence.document(root / (name + '.receipt.json'), receipt)
                accepted = name + '.receipt.json'
                break
            except (ValueError, OSError) as error:
                receipt.update(accepted=False, ended_utc=evidence.utc(), error=str(error))
                evidence.document(root / (name + '.receipt.json'), receipt)
                if not (retry or isinstance(error, OSError)) or attempt == 4:
                    raise
                retry_after = next((str(v) for k, v in headers.items() if k.lower() == 'retry-after'), '')
                if retry_after and not retry_after.isdigit():
                    raise ValueError('Unsupported Retry-After') from error
                wait = max(args.delay, 2**(attempt-1), int(retry_after or 0))
                if wait > 60 or time.monotonic() + wait >= deadline:
                    raise ValueError('Retry exceeds bounded deadline') from error
                sleep(wait)
        output = render(data, config, receipt['ended_utc'], evidence.digest(raw))
        if producer() != identity or evidence.small(args.namespace_registry, MAX_RESPONSE) != namespace:
            raise ValueError('Capture producer or namespace changed')
        evidence.put(root / SNAPSHOT, output)
        manifest = {'schema': SCHEMA, **config, **identity, 'core': data['query']['general']['git-hash'], 'scribunto': SCRIBUNTO,
            'temporal_scope': 'current-api-observation', 'dump_date': None,
            'started_utc': started, 'retrieved_utc': receipt['ended_utc'], 'accepted_receipt': accepted,
            'source_url': url, 'output_sha256': evidence.digest(output), 'output_bytes': len(output),
            'artifacts': payload(root)}
        evidence.document(root / MANIFEST, manifest)
        verify(root, require_complete=False)
        evidence.document(root / COMPLETE, {'schema': SCHEMA, 'manifest_sha256': evidence.digest(evidence.small(root / MANIFEST, MAX_MANIFEST))})
        return manifest
    except BaseException as error:
        for name in (SNAPSHOT, MANIFEST, COMPLETE):
            path = root / name
            if path.exists():
                path.rename(root / (name + '.unverified'))
        evidence.document(root / (PREFIX + 'failure.json'), {'ended_utc': evidence.utc(), 'error': str(error)})
        raise


def verify(root, require_complete=True):
    root = Path(root)
    if root.is_symlink() or not root.is_dir():
        raise ValueError('Unsafe capture directory')
    raw_manifest = evidence.small(root / MANIFEST, MAX_MANIFEST)
    manifest = evidence.decode(raw_manifest)
    if (not isinstance(manifest, dict) or manifest.get('schema') != SCHEMA or manifest.get('profile') != PROFILE
            or manifest.get('core') not in CORE_PROFILES or manifest.get('scribunto') != SCRIBUNTO
            or manifest.get('temporal_scope') != 'current-api-observation' or manifest.get('dump_date') is not None
            or any(manifest.get(k) != v for k, v in producer().items())):
        raise ValueError('Unreviewed site-info capture profile or producer')
    if require_complete and evidence.decode(evidence.small(root / COMPLETE, MAX_MANIFEST)) != {
            'schema': SCHEMA, 'manifest_sha256': evidence.digest(raw_manifest)}:
        raise ValueError('Capture completion mismatch')
    if manifest.get('artifacts') != payload(root):
        raise ValueError('Capture evidence inventory mismatch')
    primary_sources(root, PREFIX + 'source-')
    namespace = evidence.small(root / (PREFIX + 'namespace-registry.tsv'), MAX_RESPONSE)
    language = namespace_identity(namespace, manifest['wiki'], manifest['date'])
    config = {k: manifest[k] for k in ('wiki', 'date', 'content_language', 'namespace_registry_sha256', 'profile')}
    if language != config['content_language'] or evidence.digest(namespace) != config['namespace_registry_sha256']:
        raise ValueError('Capture namespace binding mismatch')
    request = evidence.decode(evidence.small(root / (PREFIX + 'request.json'), MAX_MANIFEST))
    url = evidence.wiktionary_api(config['wiki']) + '?' + urllib.parse.urlencode(sorted(query().items()))
    if request != {'url': url, 'query': query(), **config} or manifest.get('source_url') != url:
        raise ValueError('Unrequested site-info query')
    accepted = manifest.get('accepted_receipt')
    if not isinstance(accepted, str) or not re.fullmatch(r'site-info\.0[1-4]\.receipt\.json', accepted):
        raise ValueError('Invalid accepted receipt')
    number = int(accepted.split('.')[1])
    expected_files = {SNAPSHOT, PREFIX+'request.json', PREFIX+'namespace-registry.tsv',
                      *(PREFIX+'source-'+name for name in SOURCE_PINS)}
    previous = stamp(manifest['started_utc'])
    for attempt in range(1, number+1):
        name = PREFIX + f'{attempt:02d}'
        receipt_name = name + '.receipt.json'
        expected_files.add(receipt_name)
        receipt = evidence.decode(evidence.small(root / receipt_name, MAX_MANIFEST))
        start, end = stamp(receipt.get('started_utc')), stamp(receipt.get('ended_utc'))
        if start < previous or end < start or receipt.get('request') != PREFIX+'request.json' or receipt.get('accepted') is not (attempt == number):
            raise ValueError('Invalid receipt order or acceptance')
        previous = end
        if 'response' in receipt:
            if receipt['response'] != name+'.raw.json':
                raise ValueError('Unsafe or mismatched response path')
            expected_files.add(receipt['response'])
            raw = evidence.small(root / receipt['response'], MAX_RESPONSE)
            if receipt.get('response_bytes') != len(raw) or receipt.get('response_sha256') != evidence.digest(raw):
                raise ValueError('Response receipt hash mismatch')
        elif attempt == number:
            raise ValueError('Accepted response absent')
        if attempt == number:
            if receipt.get('status') != 200 or receipt['ended_utc'] != manifest['retrieved_utc']:
                raise ValueError('Accepted HTTP or observation mismatch')
            observed = evidence.decode(raw)
            expected = render(observed, config, receipt['ended_utc'], evidence.digest(raw))
            if manifest['core'] != observed['query']['general']['git-hash']:
                raise ValueError('Site-info manifest core differs from API observation')
    if set(manifest['artifacts']) != expected_files:
        raise ValueError('Unexpected or incomplete retry inventory')
    if (evidence.small(root / SNAPSHOT, MAX_RESPONSE) != expected or manifest.get('output_bytes') != len(expected)
            or manifest.get('output_sha256') != evidence.digest(expected)):
        raise ValueError('Site-info projection differs from complete API response')
    return manifest


def validate_snapshot(path, wiki=None, date=None):
    path = Path(path)
    if path.name != SNAPSHOT:
        raise ValueError('Unexpected site-info snapshot filename')
    manifest = verify(path.parent)
    if (wiki is not None and manifest['wiki'] != wiki) or (date is not None and manifest['date'] != date):
        raise ValueError('Site-info edition/date mismatch')
    return manifest


def capture_artifacts(path, manifest=None):
    validated = validate_snapshot(path)
    if manifest is not None and validated != manifest:
        raise ValueError('Capture changed during pinning')
    return {**{name: row['sha256'] for name, row in validated['artifacts'].items()},
            **{name: evidence.digest(evidence.small(Path(path).with_name(name), MAX_MANIFEST))
               for name in (MANIFEST, COMPLETE)}}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    check = sub.add_parser('verify'); check.add_argument('output', type=Path)
    collect = sub.add_parser('capture')
    for name in ('wiki', 'date'):
        collect.add_argument('--'+name, required=True)
    for name in ('namespace-registry', 'primary-sources', 'output'):
        collect.add_argument('--'+name, type=Path, required=True)
    collect.add_argument('--delay', type=float, default=1)
    collect.add_argument('--wall-seconds', type=int, default=180)
    args = parser.parse_args()
    if args.command == 'capture' and args.delay < 1:
        parser.error('Network retries require at least one second of spacing')
    result = capture(args) if args.command == 'capture' else verify(args.output)
    print(json.dumps({key: result[key] for key in ('wiki','date','output_sha256','retrieved_utc')}))


if __name__ == '__main__':
    main()
