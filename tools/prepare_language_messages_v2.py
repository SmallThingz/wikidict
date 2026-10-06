#!/usr/bin/env python3
"""Capture explicit current MediaWiki language fallbacks and plain messages.

The immutable generation contains both TSVs and all raw request evidence.
STRICT language fallbacks are captured verbatim; the native Scribunto API adds
the documented terminal English fallback for its default MESSAGES mode.
These are current API observations associated with a dump, not historical data.
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

SCHEMA = 'wikidict.language-messages-capture.v2'
PREFIX = 'language-messages.'
KINDS = ('interface-messages', 'language-fallbacks')
COMPLETE = PREFIX + 'complete.json'
MAX_MANIFEST = 64 * 1024
MAX_RESPONSE = 2 * 1024 * 1024
MAX_URL = 7 * 1024
MAX_REQUESTS = 128
# Full date-format names use50 keys; the largest existing inventory (AR) has14.
MAX_MESSAGE_KEYS = 64
# Ordinary MediaWiki clients accept at most50 ammessages values. Keep each
# request at32 values and replay every exact chunk.
MAX_MESSAGE_KEYS_PER_REQUEST = 32
_VALIDATED_REPLAY_KEYS = set()
_MAX_VALIDATED_REPLAY_KEYS = 256

MAX_FALLBACK_ROWS = 20000
REPO = Path(__file__).resolve().parent.parent


def language_code(value):
    return isinstance(value, str) and re.fullmatch(r'[a-zA-Z0-9-]{2,64}', value) is not None


def normalize_key(key):
    # MessageCache::normalizeKey uses content-language lcfirst for Unicode.
    # Capture only the ASCII key domain we can reproduce exactly.
    if (not isinstance(key, str) or not 1 <= len(key) <= 255 or not key.isascii()
            or any(ord(c) < 32 or ord(c) == 127 or c == '|' for c in key)):
        raise ValueError('Unsupported interface message key')
    key = key.replace(' ', '_')
    return key[0].lower() + key[1:]


def namespace_identity(raw, wiki, date):
    lines = raw.decode('utf-8').splitlines()
    if (len(lines) < 4 or lines[:3] != ['# wikidict-namespace-registry-v1',
            '# wiki\t' + wiki, '# dump-date\t' + date]
            or not lines[3].startswith('# content-language\t')):
        raise ValueError('Namespace registry edition/date/header mismatch')
    language = lines[3].split('\t', 1)[1]
    if not language_code(language):
        raise ValueError('Invalid pinned content language')
    return language


def checked_query(data, wiki, content_language):
    if (not isinstance(data, dict) or any(k in data for k in ('error', 'errors', 'warnings'))):
        raise ValueError('Incomplete or unsuccessful API observation')
    query = data.get('query')
    general = query.get('general') if isinstance(query, dict) else None
    if (not isinstance(general, dict) or general.get('wikiid') != wiki
            or general.get('lang') != content_language):
        raise ValueError('API edition/content-language mismatch')
    return query


def parse_fallbacks(data, wiki, content_language):
    info = checked_query(data, wiki, content_language).get('languageinfo')
    if not isinstance(info, dict) or not 1 <= len(info) <= MAX_FALLBACK_ROWS:
        raise ValueError('Missing or excessive language metadata')
    fallbacks = {}
    for language, row in info.items():
        if not language_code(language) or not isinstance(row, dict) or row.get('code') != language:
            raise ValueError('API language code mismatch')
        chain = row.get('fallbacks')
        if not isinstance(chain, list) or len(chain) > 64 or any(not language_code(x) for x in chain):
            raise ValueError('Missing or invalid explicit STRICT fallback list')
        if language == 'en' and chain:
            raise ValueError('English must have an empty STRICT fallback list')
        fallbacks[language] = chain
    continuation = data.get('continue', {})
    if (not isinstance(continuation, dict) or continuation and (set(continuation) != {'continue', 'licontinue'}
            or any(not isinstance(v, str) or not 1 <= len(v) <= 128 for v in continuation.values()))):
        raise ValueError('Unsupported languageinfo continuation')
    return fallbacks, continuation


def parse_messages(data, language, keys, wiki, content_language):
    query = checked_query(data, wiki, content_language)
    if 'continue' in data:
        raise ValueError('Incomplete requested message inventory')
    rows = query.get('allmessages')
    if not isinstance(rows, list) or len(rows) != len(keys):
        raise ValueError('Incomplete requested message inventory')
    messages = {}
    expected = {normalize_key(key) for key in keys}
    for row in rows:
        if not isinstance(row, dict) or row.get('name') not in keys:
            raise ValueError('Unrequested interface message')
        key = normalize_key(row['name'])
        if row.get('normalizedname') != key or key in messages:
            raise ValueError('Conflicting or unsupported message key normalization')
        if 'default' in row and not isinstance(row['default'], str):
            raise ValueError('Invalid default message evidence')
        if 'defaultmissing' in row and (row['defaultmissing'] is not True or 'default' in row):
            raise ValueError('Invalid missing default message evidence')
        if 'missing' in row:
            if row['missing'] is not True or 'content' in row:
                raise ValueError('Ambiguous missing message observation')
            value = None
        else:
            value = row.get('content')
            if not isinstance(value, str) or '\0' in value:
                raise ValueError('Missing or invalid plain message content')
        messages[key] = value
    if set(messages) != expected:
        raise ValueError('Requested message coverage differs from API evidence')
    return messages


def header(kind, wiki, date, content_language):
    return [f'# wikidict-{kind}-v1', '# wiki\t' + wiki, '# dump-date\t' + date,
            '# content-language\t' + content_language]


def escaped(value):
    return value.replace('\\', '\\\\').replace('\t', '\\t').replace('\n', '\\n').replace('\r', '\\r')


def render_fallbacks(fallbacks, wiki, date, content_language):
    lines = header('language-fallbacks', wiki, date, content_language) + ['# mode\tstrict']
    for language, chain in sorted(fallbacks.items()):
        lines.append(language + '\t' + '\t'.join(chain))
    return ('\n'.join(lines) + '\n').encode('utf-8')


def render_messages(messages, wiki, date, content_language):
    lines = header('interface-messages', wiki, date, content_language)
    for (language, key), source in sorted(messages.items()):
        lines.append(language + '\t' + key + '\t' + ('M' if source is None else 'V\t' + escaped(source)))
    return ('\n'.join(lines) + '\n').encode('utf-8')


def message_chunks(keys):
    return [keys[start:start + MAX_MESSAGE_KEYS_PER_REQUEST]
            for start in range(0, len(keys), MAX_MESSAGE_KEYS_PER_REQUEST)]


def query_for(wiki, language, keys):
    return {'action': 'query', 'format': 'json', 'formatversion': '2',
            'meta': 'siteinfo|allmessages', 'siprop': 'general', 'amlang': language,
            'ammessages': '|'.join(keys), 'amprop': 'default', 'maxlag': '5'}


def fallback_query(continuation):
    return {'action': 'query', 'format': 'json', 'formatversion': '2',
            'meta': 'siteinfo|languageinfo', 'siprop': 'general', 'licode': '*',
            'liprop': 'code|fallbacks', 'maxlag': '5', **continuation}


def query_url(wiki, query):
    return evidence.wiktionary_api(wiki) + '?' + urllib.parse.urlencode(query)


def producer():
    return {'generator_sha256': evidence.digest(evidence.small(Path(__file__))),
            'dependency_sha256': {name: evidence.digest(evidence.small(REPO / name)) for name in (
                'tools/prepare_file_metadata.py', 'tools/download_wiktionaries.py',
                'tools/prepare_language_messages.py')}}


def owned_payload(root):
    found = {}
    for path in root.iterdir():
        if path.name in (COMPLETE, *(kind + '.manifest.json' for kind in KINDS)):
            continue
        if not (path.name.startswith(PREFIX) or path.name in (kind + '.tsv' for kind in KINDS)):
            continue
        identity = evidence.fingerprint(path)
        found[path.name] = {'size': identity['size'], 'sha256': identity['sha256']}
    return dict(sorted(found.items()))


def request_observation(root, number, wiki, content_language, specification, transport, sleep, delay, deadline):
    if number > MAX_REQUESTS:
        raise ValueError('Capture request bound exceeded')
    request_name = f'{PREFIX}{number:04d}.request.json'
    query = (fallback_query(specification['continuation']) if specification['kind'] == 'fallbacks'
             else query_for(wiki, specification['language'], specification['keys']))
    url = query_url(wiki, query)
    if len(url) > MAX_URL:
        raise ValueError('Message request exceeds bounded URL size')
    evidence.document(root / request_name, {'url': url, 'query': query, **specification})
    for attempt in range(1, 5):
        if time.monotonic() >= deadline:
            raise ValueError('Capture wall deadline reached')
        name = f'{PREFIX}{number:04d}-{attempt:02d}'
        receipt = {'request': request_name, 'started_utc': evidence.utc(), 'status': None}
        headers, retry = {}, False
        try:
            status, headers, raw = transport(url, min(30, deadline - time.monotonic()))
            receipt.update(status=status, response=name + '.raw.json',
                           response_bytes=len(raw), response_sha256=evidence.digest(raw),
                           headers={k.lower(): v for k, v in headers.items()
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
            result = (parse_fallbacks(data, wiki, content_language) if specification['kind'] == 'fallbacks'
                      else parse_messages(data, specification['language'], specification['keys'], wiki, content_language))
            receipt.update(accepted=True, ended_utc=evidence.utc())
            evidence.document(root / (name + '.receipt.json'), receipt)
            return result, {'request': request_name, 'accepted_receipt': name + '.receipt.json'}
        except (OSError, ValueError) as error:
            retry = retry or isinstance(error, OSError)
            receipt.update(accepted=False, error=str(error), ended_utc=evidence.utc())
            evidence.document(root / (name + '.receipt.json'), receipt)
            if not retry or attempt == 4:
                raise
            retry_after = next((v for k, v in headers.items() if k.lower() == 'retry-after'), '')
            if retry_after and not str(retry_after).isdigit():
                raise ValueError('Unsupported Retry-After; retain capture for later review') from error
            wait = max(delay, 2**(attempt - 1), int(retry_after or 0))
            if wait > 60 or time.monotonic() + wait >= deadline:
                raise ValueError('Retry exceeds bounded capture wait/deadline') from error
            sleep(wait)


def capture(args, transport=None, sleep=time.sleep):
    evidence.wiktionary_api(args.wiki)
    if (not re.fullmatch(r'\d{8}', args.date) or not 0 <= args.delay <= 60
            or not 1 <= args.wall_seconds <= 86400):
        raise ValueError('Invalid date or bounded capture settings')
    datetime.strptime(args.date, '%Y%m%d')
    original = evidence.stamp(args.namespace_registry)
    namespace = evidence.small(args.namespace_registry)
    content_language = namespace_identity(namespace, args.wiki, args.date)
    languages = sorted(set(args.languages or [content_language]))
    keys = sorted(set(args.messages))
    if (not 1 <= len(languages) <= 50 or any(not language_code(x) for x in languages)
            or not 1 <= len(keys) <= MAX_MESSAGE_KEYS or len({normalize_key(k) for k in keys}) != len(keys)):
        raise ValueError('Invalid, duplicate-normalized, or excessive requested language/message inventory')
    identity = producer()
    root = args.output
    root.mkdir(parents=True, exist_ok=False)
    started, deadline = evidence.utc(), time.monotonic() + args.wall_seconds
    try:
        evidence.put(root / (PREFIX + 'namespace-registry.tsv'), namespace)
        configuration = {'wiki': args.wiki, 'date': args.date, 'content_language': content_language,
                         'languages': languages, 'keys': keys, 'namespace_registry_sha256': evidence.digest(namespace),
                         'fallback_scope': 'all-supported-api-languages'}
        evidence.document(root / (PREFIX + 'requested.json'), configuration)
        fallbacks, messages, requests = {}, {}, []
        def observe(specification):
            if requests:
                if time.monotonic() + args.delay >= deadline:
                    raise ValueError('Capture wall deadline reached')
                sleep(args.delay)
            result, request = request_observation(root, len(requests) + 1, args.wiki, content_language,
                specification, transport or evidence.get_response, sleep, args.delay, deadline)
            requests.append(request)
            return result
        continuation, seen = {}, set()
        while True:
            rows, continuation = observe({'kind': 'fallbacks', 'continuation': continuation})
            if set(rows) & set(fallbacks) or len(fallbacks) + len(rows) > MAX_FALLBACK_ROWS:
                raise ValueError('Duplicate or excessive captured language rows')
            fallbacks.update(rows)
            if not continuation:
                break
            token = tuple(sorted(continuation.items()))
            if token in seen:
                raise ValueError('Repeated languageinfo continuation')
            seen.add(token)
        if not set([content_language, *languages]) <= set(fallbacks):
            raise ValueError('Selected language missing from complete API fallback inventory')
        for language in languages:
            for chunk in message_chunks(keys):
                localized = observe({'kind': 'messages', 'language': language, 'keys': chunk})
                messages.update({(language, key): value for key, value in localized.items()})
        if producer() != identity or evidence.stamp(args.namespace_registry) != original:
            raise ValueError('Collector or pinned namespace changed during capture')
        outputs = {'language-fallbacks': render_fallbacks(fallbacks, args.wiki, args.date, content_language),
                   'interface-messages': render_messages(messages, args.wiki, args.date, content_language)}
        for kind, raw in outputs.items():
            evidence.put(root / (kind + '.tsv'), raw)
        inventory = owned_payload(root)
        manifests = {}
        for kind, raw in outputs.items():
            manifest = {'schema': SCHEMA, 'kind': kind, 'header_version': 1, **configuration, **identity,
                        'source_url': evidence.wiktionary_api(args.wiki), 'dump_date': None,
                        'temporal_scope': 'current-api-observation', 'started_utc': started,
                        'retrieved_utc': evidence.utc(), 'requests': requests, 'artifacts': inventory,
                        'candidate_queries_complete': True, 'corpus_query_closure_proven': False,
                        'fallback_mode': 'strict', 'message_mode': 'plain-with-database',
                        'fallback_languages': sorted(fallbacks),
                        'rows': len(fallbacks) if kind == 'language-fallbacks' else len(messages),
                        'output_bytes': len(raw), 'output_sha256': evidence.digest(raw)}
            raw_manifest = evidence.encoded(manifest)
            if len(raw_manifest) > MAX_MANIFEST:
                raise ValueError('Auxiliary manifest exceeds the builder size limit')
            evidence.put(root / (kind + '.manifest.json'), raw_manifest)
            manifests[kind] = manifest
        verify(root, require_complete=False)
        evidence.document(root / COMPLETE, {'schema': SCHEMA, 'manifests': {
            kind + '.manifest.json': evidence.digest(evidence.small(root / (kind + '.manifest.json')))
            for kind in KINDS}})
        return manifests
    except BaseException as error:
        for name in (COMPLETE, *(kind + suffix for kind in KINDS for suffix in ('.tsv', '.manifest.json'))):
            path = root / name
            if path.exists():
                path.rename(root / (name + '.unverified'))
        evidence.document(root / (PREFIX + 'failure.json'), {'ended_utc': evidence.utc(), 'error': str(error), **identity})
        raise


def verify(root, require_complete=True):
    root = Path(root)
    if root.is_symlink() or not root.is_dir():
        raise ValueError('Unsafe language/message capture directory')
    manifests, hashes = {}, {}
    for kind in KINDS:
        path = root / (kind + '.manifest.json')
        raw = evidence.small(path, MAX_MANIFEST)
        manifest = evidence.decode(raw)
        if (not isinstance(manifest, dict) or manifest.get('schema') != SCHEMA
                or manifest.get('kind') != kind or manifest.get('header_version') != 1):
            raise ValueError('Unsupported language/message capture manifest')
        manifests[kind], hashes[path.name] = manifest, evidence.digest(raw)
    if require_complete:
        marker = evidence.decode(evidence.small(root / COMPLETE, MAX_MANIFEST))
        if marker != {'schema': SCHEMA, 'manifests': hashes}:
            raise ValueError('Capture completion marker mismatch')
    manifest = manifests['language-fallbacks']
    other = manifests['interface-messages']
    per_output = {'kind', 'rows', 'output_bytes', 'output_sha256', 'retrieved_utc'}
    if {k: v for k, v in manifest.items() if k not in per_output} != {k: v for k, v in other.items() if k not in per_output}:
        raise ValueError('Paired language/message manifests differ')
    identity = producer()
    if (manifest.get('dependency_sha256') != identity['dependency_sha256']
            or manifest.get('generator_sha256') != identity['generator_sha256']):
        raise ValueError('Capture requires its original collector and dependencies')
    if (manifest.get('temporal_scope') != 'current-api-observation' or manifest.get('dump_date') is not None
            or manifest.get('fallback_mode') != 'strict' or manifest.get('message_mode') != 'plain-with-database'
            or manifest.get('candidate_queries_complete') is not True or manifest.get('corpus_query_closure_proven') is not False):
        raise ValueError('Unsupported observation scope or query semantics')
    inventory = owned_payload(root)
    if inventory != manifest.get('artifacts'):
        raise ValueError('Capture artifact inventory/hash mismatch')
    # owned_payload has just read and hashed every raw/proof/TSV artifact.
    # Keep per-call completion, identity, dependencies and integrity checks;
    # exact previously successful bytes can omit deterministic API replay.
    replay_key = (tuple(sorted(hashes.items())), identity['generator_sha256'],
                  tuple(sorted(identity['dependency_sha256'].items())), require_complete,
                  MAX_MANIFEST, MAX_RESPONSE, MAX_URL, MAX_REQUESTS,
                  MAX_MESSAGE_KEYS, MAX_MESSAGE_KEYS_PER_REQUEST, MAX_FALLBACK_ROWS)
    if replay_key in _VALIDATED_REPLAY_KEYS:
        return manifests
    config = evidence.decode(evidence.small(root / (PREFIX + 'requested.json'), MAX_MANIFEST))
    if (not isinstance(config, dict) or set(config) != {'wiki', 'date', 'content_language', 'languages',
            'keys', 'namespace_registry_sha256', 'fallback_scope'}
            or config.get('fallback_scope') != 'all-supported-api-languages'
            or any(manifest.get(k) != v for k, v in config.items())):
        raise ValueError('Requested inventory differs from capture configuration')
    wiki, date = manifest['wiki'], manifest['date']
    content_language = namespace_identity(evidence.small(root / (PREFIX + 'namespace-registry.tsv')), wiki, date)
    if (content_language != manifest['content_language']
            or evidence.digest(evidence.small(root / (PREFIX + 'namespace-registry.tsv'))) != manifest['namespace_registry_sha256']):
        raise ValueError('Pinned namespace identity differs from capture')
    languages, keys = manifest['languages'], manifest['keys']
    if (not isinstance(languages, list) or not 1 <= len(languages) <= 50
            or len(set(languages)) != len(languages) or any(not language_code(x) for x in languages)
            or not isinstance(keys, list) or not 1 <= len(keys) <= MAX_MESSAGE_KEYS
            or len({normalize_key(k) for k in keys}) != len(keys)):
        raise ValueError('Invalid captured language/message selection')
    fallbacks, messages, observed_languages, seen = {}, {}, set(), set()
    expected_messages = [(language, chunk) for language in languages for chunk in message_chunks(keys)]
    message_position = 0
    continuation, fallback_complete = {}, False
    if not isinstance(manifest.get('requests'), list) or not 1 <= len(manifest['requests']) <= MAX_REQUESTS:
        raise ValueError('Invalid capture request inventory')
    for batch in manifest['requests']:
        if any(batch.get(k) not in inventory for k in ('request', 'accepted_receipt')):
            raise ValueError('Unrecorded request evidence')
        request = evidence.decode(evidence.small(root / batch['request'], MAX_MANIFEST))
        if request.get('kind') == 'fallbacks':
            if fallback_complete or request.get('continuation') != continuation:
                raise ValueError('Incomplete or reordered fallback continuation evidence')
            query = fallback_query(continuation)
        elif request.get('kind') == 'messages':
            if not fallback_complete or message_position >= len(expected_messages):
                raise ValueError('Incomplete or excess requested message chunk')
            language, chunk = expected_messages[message_position]
            if request.get('language') != language or request.get('keys') != chunk:
                raise ValueError('Incomplete, reordered, or duplicate requested message chunk')
            query = query_for(wiki, language, chunk)
        else:
            raise ValueError('Unsupported capture request kind')
        if (request.get('query') != query or request.get('url') != query_url(wiki, query)
                or len(request['url']) > MAX_URL):
            raise ValueError('Capture request differs from required API semantics')
        receipt = evidence.decode(evidence.small(root / batch['accepted_receipt'], MAX_MANIFEST))
        if (receipt.get('accepted') is not True or receipt.get('status') != 200
                or receipt.get('request') != batch['request'] or receipt.get('response') not in inventory):
            raise ValueError('Invalid accepted API receipt')
        raw = evidence.small(root / receipt['response'], MAX_RESPONSE)
        if receipt.get('response_bytes') != len(raw) or receipt.get('response_sha256') != evidence.digest(raw):
            raise ValueError('Raw API response differs from receipt')
        if request['kind'] == 'fallbacks':
            rows, continuation = parse_fallbacks(evidence.decode(raw), wiki, content_language)
            if set(rows) & set(fallbacks) or len(fallbacks) + len(rows) > MAX_FALLBACK_ROWS:
                raise ValueError('Duplicate or excessive captured language rows')
            fallbacks.update(rows)
            if continuation:
                token = tuple(sorted(continuation.items()))
                if token in seen:
                    raise ValueError('Repeated languageinfo continuation')
                seen.add(token)
            else:
                fallback_complete = True
        else:
            localized = parse_messages(evidence.decode(raw), language, chunk, wiki, content_language)
            observed_languages.add(language)
            messages.update({(language, key): source for key, source in localized.items()})
            message_position += 1
    if (not fallback_complete or message_position != len(expected_messages)
            or observed_languages != set(languages)
            or sorted(fallbacks) != manifest.get('fallback_languages')
            or not set([content_language, *languages]) <= set(fallbacks)):
        raise ValueError('Requested language coverage is incomplete')
    outputs = {'language-fallbacks': render_fallbacks(fallbacks, wiki, date, content_language),
               'interface-messages': render_messages(messages, wiki, date, content_language)}
    for kind, expected in outputs.items():
        record = manifests[kind]
        if (evidence.small(root / (kind + '.tsv')) != expected or record.get('output_bytes') != len(expected)
                or record.get('output_sha256') != evidence.digest(expected)
                or record.get('rows') != (len(fallbacks) if kind == 'language-fallbacks' else len(messages))):
            raise ValueError('Rendered TSV differs from complete API evidence')
    if len(_VALIDATED_REPLAY_KEYS) >= _MAX_VALIDATED_REPLAY_KEYS:
        _VALIDATED_REPLAY_KEYS.clear()
    _VALIDATED_REPLAY_KEYS.add(replay_key)
    return manifests


def validate_snapshot(path, wiki=None, date=None):
    path = Path(path)
    kind = path.name.removesuffix('.tsv')
    if path.name != kind + '.tsv' or kind not in KINDS:
        raise ValueError('Unexpected language/message snapshot name')
    manifest = verify(path.parent)[kind]
    if ((wiki is not None and manifest['wiki'] != wiki) or (date is not None and manifest['date'] != date)):
        raise ValueError('Language/message snapshot edition/date mismatch')
    return manifest


def capture_artifacts(path, manifest=None):
    path = Path(path)
    validated = validate_snapshot(path)
    if manifest is not None and manifest != validated:
        raise ValueError('Manifest changed before capture pinning')
    result = {name: row['sha256'] for name, row in validated['artifacts'].items()}
    for name in (COMPLETE, *(kind + '.manifest.json' for kind in KINDS)):
        result[name] = evidence.digest(evidence.small(path.parent / name, MAX_MANIFEST))
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    check = commands.add_parser('verify')
    check.add_argument('output', type=Path)
    collect = commands.add_parser('capture')
    collect.add_argument('--wiki', required=True)
    collect.add_argument('--date', required=True, help='Associated dump date; captured metadata is current')
    collect.add_argument('--namespace-registry', required=True, type=Path)
    collect.add_argument('--output', required=True, type=Path, help='New immutable capture directory')
    collect.add_argument('--languages', nargs='+', default=[])
    collect.add_argument('--messages', nargs='+', required=True)
    collect.add_argument('--delay', type=float, default=1.0)
    collect.add_argument('--wall-seconds', type=int, default=600)
    args = parser.parse_args()
    if args.command == 'capture' and args.delay < 1:
        parser.error('Network captures require at least one second between requests')
    manifests = capture(args) if args.command == 'capture' else verify(args.output)
    print(json.dumps({kind: {k: record[k] for k in ('wiki', 'date', 'content_language', 'rows',
        'output_sha256', 'temporal_scope')} for kind, record in manifests.items()}, sort_keys=True))


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError) as error:
        raise SystemExit(str(error)) from error
