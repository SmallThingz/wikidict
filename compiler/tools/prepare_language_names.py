#!/usr/bin/env python3
"""Capture complete, explicitly scoped language names and directions.

Proposal: install as tools/prepare_language_names.py after review. Current source
proof covers ar and en on MediaWiki 1.47.0-wmf.22. Other display languages and
autonyms require additional evidence; no profile is silently substituted.
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

SCHEMA = 'wikidict.language-names-capture.v1'
PREFIX = 'language-names.'
KIND = 'language-names'
COMPLETE = PREFIX + 'complete.json'
CORE = '0d3b507d19ae860ed8a1d22c73fa4bc5abf8dfcc'
MAX_RESPONSE = 2 * 1024 * 1024
MAX_MANIFEST = 64 * 1024
MAX_ROWS = 20000
MAX_REQUESTS = 128
SCOPES = ('all', 'mw', 'single')
# Source bytes were independently audited; the collector verifies and copies
# them into each generation so the derivation remains reviewable offline.
SOURCE_PINS = {
    'ApiQueryLanguageinfo.php': '3f37142b0d676c68b1cac50fd510ac039ff52de186388b92083428e445fe3e96',
    'ApiQuerySiteinfo.php': 'a318da6f2cae4275a15595a93aa324bcbeb433381b29bd356fc577f72d5c2ced',
    'LanguageLibrary.php': '017462f0c5ae7a1ffefdd44839845dbeea1e11a4a637fc7db8b9ec99dbd3baeb',
    'LanguageCode.php': '17962f89468aa25369f126cc7a4edd8c074cb73497c8d4de77e8cbb04858d60d',
    'Names.php': '0b0c62791924c139d7d476530c2ad9a58d053c0f34e1195595b0c2e43776b11f',
    'cldr-LanguageNames.php': '206f8f7f2ad4d3f541e995ecb66538f35cb5d2301a9ffe6e6328649432af41e7',
    'cldr-ar.json': 'a49e70ee9b7a7f8dd9048656d9e958b2f220a538c26d7f85f0b19f33b7948ef9',
    'cldr-en.json': 'a1f10dd7a54c5d222d21c75e2427cc26b81b49d79b05480221de1c95b150f138',
}


def code(value):
    return isinstance(value, str) and re.fullmatch(r'[a-z0-9-]{2,128}', value) is not None


def text(value):
    return isinstance(value, str) and 0 < len(value.encode('utf-8')) <= 4096 and '\0' not in value


def escaped(value):
    return value.replace('\\', '\\\\').replace('\t', '\\t').replace('\n', '\\n').replace('\r', '\\r')


def namespace_identity(raw, wiki, date):
    lines = raw.decode('utf-8').splitlines()
    if (len(lines) < 4 or lines[:3] != ['# wikidict-namespace-registry-v1',
            '# wiki\t' + wiki, '# dump-date\t' + date]
            or not lines[3].startswith('# content-language\t')):
        raise ValueError('Namespace registry identity mismatch')
    language = lines[3].split('\t', 1)[1]
    if not code(language):
        raise ValueError('Invalid content language')
    return language


def primary_contract(root, prefix=''):
    sources = {}
    for name, digest in SOURCE_PINS.items():
        raw = evidence.small(root / (prefix + name), MAX_RESPONSE)
        if evidence.digest(raw) != digest:
            raise ValueError('Unreviewed primary source: ' + name)
        sources[name] = raw
    source = sources['LanguageCode.php'].decode()
    def mapping(name):
        block = source.split('private const ' + name + ' = [', 1)[1].split('\n\t];', 1)[0]
        return dict(re.findall(r"'([^']+)'\s*=>\s*'([^']+)'", block))
    deprecated = mapping('DEPRECATED_LANGUAGE_CODE_MAPPING')
    aliases = {external.lower(): internal for internal, external in
               mapping('NON_STANDARD_LANGUAGE_CODE_MAPPING').items()}
    aliases.update(deprecated)
    aliases = {key: deprecated.get(value, value) for key, value in aliases.items()}
    native = set(re.findall(r"^\s*'([^']+)'\s*=>", sources['Names.php'].decode(), re.M))
    def cldr(language):
        return {key[19:]: value for key, value in evidence.decode(sources['cldr-' + language + '.json']).items()
                if key.startswith('cldr-language-name-') and value and value != '-'}
    english, arabic = cldr('en'), cldr('ar')
    if not set(arabic) <= set(english):
        raise ValueError('Arabic ALL exceeds API enumeration')
    for names in (english, {**english, **arabic}):
        for original, normalized in aliases.items():
            if original in names and original not in native and names[original] != names.get(normalized):
                raise ValueError('Languageinfo alias cannot reconstruct raw ALL table')
    return sources, aliases


def request_query(display, include_dir, continuation):
    return {'action': 'query', 'format': 'json', 'formatversion': '2',
            'meta': 'siteinfo|languageinfo', 'siprop': 'general|languages',
            'siinlanguagecode': display, 'uselang': display, 'licode': '*',
            'liprop': 'code|name|dir|fallbacks' if include_dir else 'code|name', 'maxlag': '5', **continuation}


def parse_response(data, wiki, content_language, include_dir):
    if not isinstance(data, dict) or any(key in data for key in ('error', 'errors', 'warnings')):
        raise ValueError('Unsuccessful or warning-bearing API response')
    query = data.get('query')
    general = query.get('general') if isinstance(query, dict) else None
    if (not isinstance(general, dict) or general.get('wikiid') != wiki
            or general.get('lang') != content_language or general.get('git-hash') != CORE):
        raise ValueError('API edition/language/source contract mismatch')
    info, languages = query.get('languageinfo'), query.get('languages')
    if not isinstance(info, dict) or not 1 <= len(info) <= MAX_ROWS:
        raise ValueError('Missing or excessive languageinfo inventory')
    if not isinstance(languages, list) or not 1 <= len(languages) <= MAX_ROWS:
        raise ValueError('Missing or excessive MW language inventory')
    names, directions, mw = {}, {}, {}
    for language, row in info.items():
        if (not code(language) or not isinstance(row, dict) or row.get('code') != language
                or not text(row.get('name'))):
            raise ValueError('Invalid languageinfo row')
        names[language] = row['name']
        if include_dir:
            if row.get('dir') not in ('ltr', 'rtl'):
                raise ValueError('Missing or invalid authoritative direction')
            if language in ('ar', 'en') and row.get('fallbacks') != []:
                raise ValueError('Audited ar/en STRICT fallback contract changed')
            directions[language] = row['dir']
    for row in languages:
        if (not isinstance(row, dict) or not code(row.get('code')) or not text(row.get('name'))
                or row['code'] in mw):
            raise ValueError('Invalid or duplicate raw MW language row')
        mw[row['code']] = row['name']
    continuation = data.get('continue', {})
    if (not isinstance(continuation, dict) or continuation and
            (set(continuation) != {'continue', 'licontinue'} or
             any(not isinstance(v, str) or not 1 <= len(v) <= 128 for v in continuation.values()))):
        raise ValueError('Unsupported or incomplete API continuation')
    return names, mw, directions, continuation


def finish_profile(single, mw, aliases):
    if not set(mw) <= set(single):
        raise ValueError('MW inventory missing from complete API languageinfo')
    # API getLanguageName normalizes aliases. getLanguageNames preserves raw
    # keys. For the audited ar/en contracts, MW overwrite repairs every alias
    # whose raw-table value differs; CLDR-only aliases were checked above.
    all_names = {**single, **mw}
    lookup = dict(single)
    for alias, target in aliases.items():
        lookup[alias] = single.get(target, '')
    return {'all': all_names, 'mw': dict(mw), 'single': lookup}


def render(profiles, directions, wiki, date, content_language):
    lines = ['# wikidict-language-names-v1', '# wiki\t' + wiki, '# dump-date\t' + date,
             '# content-language\t' + content_language]
    for display, scopes in sorted(profiles.items()):
        for scope in SCOPES:
            rows = scopes[scope]
            lines.append(f'C\t{display}\t{scope}\t{len(rows)}')
            lines.extend(f'N\t{display}\t{scope}\t{language}\t{escaped(name)}'
                         for language, name in sorted(rows.items()))
    lines.append(f'C\t-\tdir\t{len(directions)}')
    lines.extend(f'D\t{language}\t{direction}' for language, direction in sorted(directions.items()))
    return ('\n'.join(lines) + '\n').encode('utf-8')


def producer():
    return {'generator_sha256': evidence.digest(evidence.small(Path(__file__))),
            'dependency_sha256': {name: evidence.digest(evidence.small(Path(evidence.__file__).with_name(name)))
                                  for name in ('prepare_file_metadata.py', 'download_wiktionaries.py')}}


def payload(root):
    result = {}
    for path in root.iterdir():
        if path.name in (COMPLETE, KIND + '.manifest.json'):
            continue
        if path.name.startswith(PREFIX) or path.name == KIND + '.tsv':
            identity = evidence.fingerprint(path)
            result[path.name] = {'size': identity['size'], 'sha256': identity['sha256']}
    return dict(sorted(result.items()))


def observe(root, number, query, transport, sleep, delay, deadline):
    if number > MAX_REQUESTS:
        raise ValueError('Capture request bound exceeded')
    config = evidence.decode(evidence.small(root / (PREFIX + 'requested.json')))
    request_name = f'{PREFIX}{number:04d}.request.json'
    url = evidence.wiktionary_api(config['wiki']) + '?' + urllib.parse.urlencode(sorted(query.items()))
    evidence.document(root / request_name, {'query': query, 'url': url})
    for attempt in range(1, 5):
        if time.monotonic() >= deadline:
            raise ValueError('Capture deadline reached')
        name = f'{PREFIX}{number:04d}-{attempt:02d}'
        receipt = {'request': request_name, 'started_utc': evidence.utc()}
        retry, headers = False, {}
        try:
            status, headers, raw = transport(url, min(30, deadline - time.monotonic()))
            receipt.update(status=status, response=name + '.raw.json', response_bytes=len(raw),
                           response_sha256=evidence.digest(raw), headers={k.lower(): v for k, v in headers.items()
                           if k.lower() in ('date', 'content-type', 'retry-after', 'etag')})
            evidence.put(root / receipt['response'], raw)
            if len(raw) > MAX_RESPONSE:
                raise ValueError('Oversized API response')
            if status != 200:
                retry = status in (429, 500, 502, 503, 504)
                raise ValueError('API HTTP status ' + str(status))
            data = evidence.decode(raw)
            if isinstance(data, dict) and isinstance(data.get('error'), dict):
                retry = data['error'].get('code') in ('maxlag', 'ratelimited', 'readonly')
            result = parse_response(data, config['wiki'], config['content_language'], 'dir' in query['liprop'].split('|'))
            receipt.update(accepted=True, ended_utc=evidence.utc())
            evidence.document(root / (name + '.receipt.json'), receipt)
            return result, {'request': request_name, 'accepted_receipt': name + '.receipt.json'}
        except (OSError, ValueError) as error:
            receipt.update(accepted=False, error=str(error), ended_utc=evidence.utc())
            evidence.document(root / (name + '.receipt.json'), receipt)
            if not (retry or isinstance(error, OSError)) or attempt == 4:
                raise
            retry_after = next((str(v) for k, v in headers.items() if k.lower() == 'retry-after'), '')
            if retry_after and not retry_after.isdigit():
                raise ValueError('Unsupported Retry-After') from error
            wait = max(delay, 2**(attempt - 1), int(retry_after or 0))
            if wait > 60 or time.monotonic() + wait >= deadline:
                raise ValueError('Retry exceeds bounded deadline') from error
            sleep(wait)


def reconstruct(config, batches, aliases):
    profiles, directions, index, inventory = {}, {}, 0, None
    for display_index, display in enumerate(config['languages']):
        single, mw, continuation, seen = {}, None, {}, set()
        while True:
            if index >= len(batches):
                raise ValueError('Incomplete display-language profile')
            query, data = batches[index]
            expected = request_query(display, display_index == 0, continuation)
            if query != expected:
                raise ValueError('Reordered or unrequested capture query')
            rows, part_mw, part_dir, continuation = parse_response(data, config['wiki'], config['content_language'], display_index == 0)
            if set(rows) & set(single) or len(single) + len(rows) > MAX_ROWS:
                raise ValueError('Duplicate or excessive continued name rows')
            if mw is not None and mw != part_mw:
                raise ValueError('MW language names changed during continuation')
            mw = part_mw
            single.update(rows)
            directions.update(part_dir)
            index += 1
            if not continuation:
                break
            token = tuple(sorted(continuation.items()))
            if token in seen:
                raise ValueError('Repeated continuation token')
            seen.add(token)
        if inventory is not None and inventory != set(single):
            raise ValueError('API language universe changed between display profiles')
        inventory = set(single)
        profiles[display] = finish_profile(single, mw, aliases)
    if index != len(batches) or not directions or config['content_language'] not in directions:
        raise ValueError('Excess requests or incomplete direction inventory')
    for alias, target in aliases.items():
        if target in directions:
            directions[alias] = directions[target]
    return profiles, directions


def capture(args, transport=None, sleep=time.sleep):
    evidence.wiktionary_api(args.wiki)
    datetime.strptime(args.date, '%Y%m%d')
    if not re.fullmatch(r'\d{8}', args.date) or not 0 <= args.delay <= 60 or not 1 <= args.wall_seconds <= 86400:
        raise ValueError('Invalid date or capture bounds')
    namespace = evidence.small(args.namespace_registry)
    content_language = namespace_identity(namespace, args.wiki, args.date)
    languages = sorted(set(args.languages or [content_language, 'en']))
    if not languages or not set(languages) <= {'ar', 'en'}:
        raise ValueError('Display-language source contract is unproved; supported profiles: ar en')
    sources, aliases = primary_contract(args.primary_sources)
    root = args.output
    root.mkdir(parents=True, exist_ok=False)
    identity = producer()
    try:
        evidence.put(root / (PREFIX + 'namespace-registry.tsv'), namespace)
        for name, raw in sources.items():
            evidence.put(root / (PREFIX + 'source-' + name), raw)
        config = {'wiki': args.wiki, 'date': args.date, 'content_language': content_language,
                  'languages': languages, 'namespace_registry_sha256': evidence.digest(namespace),
                  'scope': 'explicit-display-mw-all-single-and-enumerated-directions', 'core': CORE}
        evidence.document(root / (PREFIX + 'requested.json'), config)
        started, deadline = evidence.utc(), time.monotonic() + args.wall_seconds
        batches, requests = [], []
        for index, display in enumerate(languages):
            continuation, seen = {}, set()
            while True:
                if requests:
                    if time.monotonic() + args.delay >= deadline:
                        raise ValueError('Capture deadline reached')
                    sleep(args.delay)
                query = request_query(display, index == 0, continuation)
                result, record = observe(root, len(requests) + 1, query, transport or evidence.get_response,
                                         sleep, args.delay, deadline)
                receipt = evidence.decode(evidence.small(root / record['accepted_receipt']))
                batches.append((query, evidence.decode(evidence.small(root / receipt['response'], MAX_RESPONSE))))
                requests.append(record)
                continuation = result[3]
                if not continuation:
                    break
                token = tuple(sorted(continuation.items()))
                if token in seen:
                    raise ValueError('Repeated continuation token')
                seen.add(token)
        profiles, directions = reconstruct(config, batches, aliases)
        raw = render(profiles, directions, args.wiki, args.date, content_language)
        if producer() != identity or evidence.small(args.namespace_registry) != namespace:
            raise ValueError('Producer or namespace changed during capture')
        evidence.put(root / (KIND + '.tsv'), raw)
        manifest = {'schema': SCHEMA, 'kind': KIND, 'header_version': 1, **config, **identity,
                    'source_url': evidence.wiktionary_api(args.wiki), 'dump_date': None,
                    'temporal_scope': 'current-api-observation', 'started_utc': started,
                    'retrieved_utc': evidence.utc(), 'requests': requests, 'artifacts': payload(root),
                    'candidate_queries_complete': True, 'corpus_query_closure_proven': False,
                    'profiles': {language: {scope: len(rows) for scope, rows in scopes.items()}
                                 for language, scopes in profiles.items()},
                    'direction_rows': len(directions),
                    'rows': sum(len(rows) for scopes in profiles.values() for rows in scopes.values()) + len(directions),
                    'output_bytes': len(raw), 'output_sha256': evidence.digest(raw)}
        if len(evidence.encoded(manifest)) > MAX_MANIFEST:
            raise ValueError('Manifest exceeds builder limit')
        evidence.document(root / (KIND + '.manifest.json'), manifest)
        verify(root, require_complete=False)
        evidence.document(root / COMPLETE, {'schema': SCHEMA,
            'manifest_sha256': evidence.digest(evidence.small(root / (KIND + '.manifest.json'), MAX_MANIFEST))})
        return manifest
    except BaseException as error:
        for name in (COMPLETE, KIND + '.tsv', KIND + '.manifest.json'):
            path = root / name
            if path.exists():
                path.rename(root / (name + '.unverified'))
        evidence.document(root / (PREFIX + 'failure.json'), {'ended_utc': evidence.utc(), 'error': str(error)})
        raise


def verify(root, require_complete=True):
    root = Path(root)
    if root.is_symlink() or not root.is_dir():
        raise ValueError('Unsafe capture directory')
    manifest_raw = evidence.small(root / (KIND + '.manifest.json'), MAX_MANIFEST)
    manifest = evidence.decode(manifest_raw)
    if (manifest.get('schema') != SCHEMA or manifest.get('kind') != KIND or manifest.get('header_version') != 1
            or manifest.get('temporal_scope') != 'current-api-observation' or manifest.get('dump_date') is not None
            or manifest.get('candidate_queries_complete') is not True or manifest.get('corpus_query_closure_proven') is not False
            or manifest.get('source_url') != evidence.wiktionary_api(manifest.get('wiki', ''))
            or any(manifest.get(k) != v for k, v in producer().items())):
        raise ValueError('Unreviewed capture manifest/producer/scope')
    if require_complete and evidence.decode(evidence.small(root / COMPLETE, MAX_MANIFEST)) != {
            'schema': SCHEMA, 'manifest_sha256': evidence.digest(manifest_raw)}:
        raise ValueError('Capture completion marker mismatch')
    config = evidence.decode(evidence.small(root / (PREFIX + 'requested.json'), MAX_MANIFEST))
    expected_keys = {'wiki', 'date', 'content_language', 'languages', 'namespace_registry_sha256', 'scope', 'core'}
    if (set(config) != expected_keys or config['core'] != CORE
            or config['scope'] != 'explicit-display-mw-all-single-and-enumerated-directions'
            or not isinstance(config['languages'], list) or not config['languages']
            or config['languages'] != sorted(set(config['languages']))
            or not set(config['languages']) <= {'ar', 'en'}
            or any(manifest.get(k) != v for k, v in config.items())):
        raise ValueError('Unreviewed requested profile inventory')
    namespace = evidence.small(root / (PREFIX + 'namespace-registry.tsv'))
    if (namespace_identity(namespace, config['wiki'], config['date']) != config['content_language']
            or evidence.digest(namespace) != config['namespace_registry_sha256']):
        raise ValueError('Pinned namespace differs from capture')
    inventory = payload(root)
    if inventory != manifest['artifacts']:
        raise ValueError('Capture evidence inventory differs')
    _, aliases = primary_contract(root, PREFIX + 'source-')
    records = manifest.get('requests')
    if not isinstance(records, list) or not 1 <= len(records) <= MAX_REQUESTS:
        raise ValueError('Invalid request inventory')
    batches = []
    for record in records:
        if any(record.get(key) not in inventory for key in ('request', 'accepted_receipt')):
            raise ValueError('Missing request evidence')
        request = evidence.decode(evidence.small(root / record['request'], MAX_MANIFEST))
        receipt = evidence.decode(evidence.small(root / record['accepted_receipt'], MAX_MANIFEST))
        expected_url = evidence.wiktionary_api(config['wiki']) + '?' + urllib.parse.urlencode(sorted(request['query'].items()))
        if (request.get('url') != expected_url or receipt.get('accepted') is not True
                or receipt.get('status') != 200 or receipt.get('request') != record['request']
                or receipt.get('response') not in inventory):
            raise ValueError('Unaccepted or mismatched request evidence')
        raw = evidence.small(root / receipt['response'], MAX_RESPONSE)
        if receipt.get('response_bytes') != len(raw) or receipt.get('response_sha256') != evidence.digest(raw):
            raise ValueError('API response receipt differs')
        batches.append((request['query'], evidence.decode(raw)))
    profiles, directions = reconstruct(config, batches, aliases)
    expected = render(profiles, directions, config['wiki'], config['date'], config['content_language'])
    counts = {language: {scope: len(rows) for scope, rows in scopes.items()} for language, scopes in profiles.items()}
    row_count = sum(len(rows) for scopes in profiles.values() for rows in scopes.values()) + len(directions)
    if (evidence.small(root / (KIND + '.tsv')) != expected or manifest.get('profiles') != counts
            or manifest.get('rows') != row_count
            or manifest.get('direction_rows') != len(directions) or manifest.get('output_bytes') != len(expected)
            or manifest.get('output_sha256') != evidence.digest(expected)):
        raise ValueError('Rendered rows differ from complete capture evidence')
    return manifest


def validate_snapshot(path, wiki=None, date=None):
    path = Path(path)
    if path.name != KIND + '.tsv':
        raise ValueError('Unexpected snapshot filename')
    manifest = verify(path.parent)
    if (wiki is not None and manifest['wiki'] != wiki) or (date is not None and manifest['date'] != date):
        raise ValueError('Capture edition/date mismatch')
    return manifest


def capture_artifacts(path, manifest=None):
    path = Path(path)
    validated = validate_snapshot(path)
    if manifest is not None and manifest != validated:
        raise ValueError('Capture changed during pinning')
    result = {name: row['sha256'] for name, row in validated['artifacts'].items()}
    for name in (COMPLETE, KIND + '.manifest.json'):
        result[name] = evidence.digest(evidence.small(path.parent / name, MAX_MANIFEST))
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    check = sub.add_parser('verify')
    check.add_argument('output', type=Path)
    collect = sub.add_parser('capture')
    for name in ('wiki', 'date'):
        collect.add_argument('--' + name, required=True)
    for name in ('namespace-registry', 'primary-sources', 'output'):
        collect.add_argument('--' + name, required=True, type=Path)
    collect.add_argument('--languages', nargs='+', default=[])
    collect.add_argument('--delay', type=float, default=1)
    collect.add_argument('--wall-seconds', type=int, default=600)
    args = parser.parse_args()
    if args.command == 'capture' and args.delay < 1:
        parser.error('Network captures require at least one second between requests')
    manifest = capture(args) if args.command == 'capture' else verify(args.output)
    print(json.dumps({key: manifest[key] for key in ('wiki', 'date', 'profiles', 'direction_rows', 'output_sha256')}))


if __name__ == '__main__':
    main()
