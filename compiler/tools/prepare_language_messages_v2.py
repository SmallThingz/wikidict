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
import urllib.request
import urllib.error

sys.dont_write_bytecode = True
import prepare_file_metadata as evidence
import download_wiktionaries as downloader
import prepare_language_messages as legacy

SCHEMA = 'wikidict.language-messages-capture.v2'
COMPLETE_SCHEMA = 'wikidict.language-messages-complete.v1'
COMPLETE_PROFILE = 'allmessages-local-plain-v1'
COMPLETE_RESPONSE_BYTES = 16 * 1024 * 1024
COMPLETE_TOTAL_BYTES = 128 * 1024 * 1024
COMPLETE_MAX_ROWS = 250000
COMPLETE_TSV_BYTES = 64 * 1024 * 1024
COMPLETE_SOURCE_PINS = {
    'ApiQueryAllMessages.php': ('includes/Api/ApiQueryAllMessages.php', '7fb1edf6d66f32ff0f76fac1facfd6fab7293b0f8fc2d768e6a3842e034e04fc'),
    'MessageCache.php': ('includes/Language/MessageCache.php', 'cc1c90078dea41d74be946dbbd32a91c655a312f61a6e5a2355efac32e7281a8'),
}
PREFIX = 'language-messages.'
KINDS = ('interface-messages', 'language-fallbacks')
COMPLETE = PREFIX + 'complete.json'
MAX_MANIFEST = 64 * 1024
MAX_RESPONSE = 2 * 1024 * 1024
MAX_URL = 7 * 1024
MAX_REQUESTS = 128
# Full Arabic/Commons profile66 plus the ordinary parser loop warning.
MAX_MESSAGE_KEYS = 67
REQUIRED_MESSAGE_KEYS = frozenset({'parser-template-loop-warning'})
# Exact previous66-key collector remains replayable with its original scope.
PRE_LOOP_WARNING_GENERATOR_SHA256 = 'c05acb502ac9646d41ddb3285a066e76e678b6d0fefc94550d054dc07e5535b8'
# This exact previous collector retains its original64-key scope. Dependencies,
# ordered request replay and every retained evidence byte remain mandatory.
PRE_LICENSE_GENERATOR_SHA256 = 'ee9c7745aa4bcea3bb44060fd49d086ae49ad1aa47fb2cd82527fbe6f47ebd08'
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


def complete_query(language, continuation):
    return {'action': 'query', 'format': 'json', 'formatversion': '2',
            'meta': 'siteinfo|allmessages', 'siprop': 'general', 'amlang': language,
            'ammessages': '*', 'amincludelocal': '1', 'amcustomised': 'all',
            'amprop': 'default', 'maxlag': '5', **continuation}


def complete_response(url, timeout):
    # Keep the legacy shared transport byte-identical: other retained profiles
    # bind its source identity. Only this explicit profile needs a larger page.
    request = urllib.request.Request(url, headers={'User-Agent': evidence.AGENT, 'Accept': 'application/json'})
    try:
        response = urllib.request.urlopen(request, timeout=timeout)
    except urllib.error.HTTPError as error:
        response = error
    with response:
        final, original = urllib.parse.urlsplit(response.url), urllib.parse.urlsplit(url)
        if (final.scheme, final.netloc, final.path) != (original.scheme, original.netloc, original.path):
            raise ValueError('Unexpected API redirect endpoint')
        return response.status, dict(response.headers), response.read(COMPLETE_RESPONSE_BYTES + 1)


def complete_source_contract(root, prefix=''):
    receipts = evidence.decode(evidence.small(Path(root) / (prefix + 'source-receipts01.json')))
    core = receipts.get('core') if isinstance(receipts, dict) else None
    # The reviewed semantics are pinned by both PHP files below. An unchanged
    # implementation may occur at another core revision; retain that revision
    # in source URLs and require it on every API response, without restamping it.
    if not isinstance(core, str) or re.fullmatch(r'[a-f0-9]{40}', core) is None:
        raise ValueError('Invalid complete-message API source revision')
    records = receipts.get('sources')
    if not isinstance(records, list) or len(records) != len(COMPLETE_SOURCE_PINS):
        raise ValueError('Incomplete complete-message primary source inventory')
    seen = set()
    for record in records:
        name = record.get('file') if isinstance(record, dict) else None
        if name not in COMPLETE_SOURCE_PINS or name in seen:
            raise ValueError('Unexpected complete-message primary source')
        seen.add(name)
        source_path, digest = COMPLETE_SOURCE_PINS[name]
        raw = evidence.small(Path(root) / (prefix + name), 512 * 1024)
        if (record.get('source_path') != source_path or record.get('status') != 200
                or record.get('url') != f'https://raw.githubusercontent.com/wikimedia/mediawiki/{core}/{source_path}'
                or record.get('bytes') != len(raw) or record.get('sha256') != digest
                or evidence.digest(raw) != digest):
            raise ValueError('Complete-message primary source identity differs')
    return core


def checked_core(data, wiki, content_language, core):
    query = checked_query(data, wiki, content_language)
    if query['general'].get('git-hash') != core:
        raise ValueError('API source revision changed or differs from reviewed source')
    return query


def complete_order_key(name):
    # PHP 8 NUM_STRING grammar (php.net/manual/en/language.types.numeric-strings.php).
    # Reject numeric comparison rather than approximating its integer/float
    # coercion; leading-numeric nonnumeric names still compare bytewise.
    if re.fullmatch(r'[ \t\r\n\v\f]*[+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?[ \t\r\n\v\f]*', name):
        raise ValueError('Unsupported numeric-string API message ordering')
    return name.encode('utf-8')


def parse_complete_page(data, wiki, content_language, core, continuation):
    query = checked_core(data, wiki, content_language, core)
    rows = query.get('allmessages')
    if not isinstance(rows, list) or len(rows) > COMPLETE_MAX_ROWS:
        raise ValueError('Missing or excessive complete-message rows')
    next_token = data.get('continue', {})
    if (not isinstance(next_token, dict) or next_token and
            (set(next_token) != {'continue', 'amfrom'} or
             any(not isinstance(v, str) or not 1 <= len(v.encode()) <= 4096 or '\0' in v for v in next_token.values()))):
        raise ValueError('Invalid allmessages continuation')
    if not next_token and data.get('batchcomplete') is not True:
        raise ValueError('Complete-message terminal response is not complete')
    if continuation and (not rows or not isinstance(rows[0], dict) or rows[0].get('name') != continuation['amfrom']):
        raise ValueError('Allmessages continuation skipped the first unreturned key')
    if next_token and not rows:
        raise ValueError('Allmessages continuation made no progress')
    decoded = []
    names = set()
    previous = None
    for row in rows:
        if not isinstance(row, dict) or set(row) - {'name', 'normalizedname', 'content', 'missing', 'default', 'defaultmissing'}:
            raise ValueError('Unsupported complete-message response fields')
        name, normalized = row.get('name'), row.get('normalizedname')
        if any(not isinstance(v, str) or not 1 <= len(v.encode()) <= 4096 or '\0' in v for v in (name, normalized)) or name in names:
            raise ValueError('Invalid or duplicate enumerated message identity')
        names.add(name)
        ordered = complete_order_key(name)
        if previous is not None and ordered <= previous:
            raise ValueError('API message names are not strictly ordered')
        previous = ordered
        if 'default' in row and (not isinstance(row['default'], str) or '\0' in row['default']):
            raise ValueError('Invalid default message evidence')
        if 'defaultmissing' in row and (row['defaultmissing'] is not True or 'default' in row):
            raise ValueError('Ambiguous default message evidence')
        if 'missing' in row:
            if row['missing'] is not True or any(k in row for k in ('content', 'default', 'defaultmissing')):
                raise ValueError('Ambiguous missing message evidence')
            value = None
        else:
            value = row.get('content')
            if not isinstance(value, str) or '\0' in value:
                raise ValueError('Missing or invalid plain message content')
        try:
            key = normalize_key(name)
        except ValueError:
            key = None
        if key is not None and normalized != key:
            raise ValueError('Conflicting supported message normalization')
        decoded.append((name, normalized, key, value))
    if next_token and complete_order_key(next_token['amfrom']) <= previous:
        raise ValueError('Continuation does not follow the last emitted key')
    return decoded, next_token


def fallback_query(continuation):
    return {'action': 'query', 'format': 'json', 'formatversion': '2',
            'meta': 'siteinfo|languageinfo', 'siprop': 'general', 'licode': '*',
            'liprop': 'code|fallbacks', 'maxlag': '5', **continuation}


def query_url(wiki, query):
    return evidence.wiktionary_api(wiki) + '?' + urllib.parse.urlencode(query)


def producer():
    return {'generator_sha256': evidence.digest(evidence.small(Path(__file__))),
            'dependency_sha256': {name: evidence.digest(evidence.small(Path(module.__file__))) for name, module in (
                ('tools/prepare_file_metadata.py', evidence), ('tools/download_wiktionaries.py', downloader),
                ('tools/prepare_language_messages.py', legacy))}}



def validate_provenance(record):
    # Historical producer identities describe the retained observation. Acceptance
    # requires today's complete request/response replay, never an old collector.
    roles = {'tools/prepare_file_metadata.py', 'tools/download_wiktionaries.py',
             'tools/prepare_language_messages.py'}
    dependencies = record.get('dependency_sha256') if isinstance(record, dict) else None
    if (not isinstance(record, dict) or not isinstance(dependencies, dict)
            or set(dependencies) != roles
            or any(not isinstance(value, str) or not re.fullmatch('[0-9a-f]{64}', value)
                   for value in [record.get('generator_sha256'), *dependencies.values()])):
        raise ValueError('Invalid language/message producer provenance')


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


def request_observation(root, number, wiki, content_language, specification, transport, sleep, delay, deadline,
                        *, complete_core=None):
    if number > MAX_REQUESTS:
        raise ValueError('Capture request bound exceeded')
    request_name = f'{PREFIX}{number:04d}.request.json'
    query = (fallback_query(specification['continuation']) if specification['kind'] == 'fallbacks'
             else complete_query(specification['language'], specification['continuation']) if specification['kind'] == 'allmessages'
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
            if complete_core and sum(p.stat().st_size for p in root.glob(PREFIX + '*.raw.json')) + len(raw) > COMPLETE_TOTAL_BYTES:
                receipt.update(status=status, response_not_retained='complete capture raw byte bound exceeded')
                raise ValueError('Complete capture raw byte bound exceeded')
            receipt.update(status=status, response=name + '.raw.json',
                           response_bytes=len(raw), response_sha256=evidence.digest(raw),
                           headers={k.lower(): v for k, v in headers.items()
                                    if k.lower() in ('date', 'content-type', 'retry-after', 'etag')})
            evidence.put(root / receipt['response'], raw)
            if len(raw) > (COMPLETE_RESPONSE_BYTES if complete_core else MAX_RESPONSE):
                raise ValueError('Oversized API response')
            if status != 200:
                retry = status in (429, 500, 502, 503, 504)
                raise ValueError('API HTTP status ' + str(status))
            data = evidence.decode(raw)
            if isinstance(data, dict) and isinstance(data.get('error'), dict):
                retry = data['error'].get('code') in ('maxlag', 'ratelimited', 'readonly')
            if complete_core:
                checked_core(data, wiki, content_language, complete_core)
            result = (parse_fallbacks(data, wiki, content_language) if specification['kind'] == 'fallbacks'
                      else parse_complete_page(data, wiki, content_language, complete_core, specification['continuation']) if specification['kind'] == 'allmessages'
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


def complete_configuration(value):
    fields = {'wiki', 'date', 'content_language', 'languages', 'extra_keys',
              'namespace_registry_sha256', 'fallback_scope', 'profile', 'api_core',
              'projection_scope', 'local_key_caveat', 'ordering_scope'}
    if (not isinstance(value, dict) or set(value) != fields
            or value['profile'] != COMPLETE_PROFILE
            or value['projection_scope'] != 'ascii-key-projection-no-absence-inference'
            or value['local_key_caveat'] != 'language-suffixed-only-pages-without-base-may-be-unenumerated'
            or value['ordering_scope'] != 'utf8-byte-order-numeric-strings-refused'
            or value['fallback_scope'] != 'all-supported-api-languages'
            or not isinstance(value['api_core'], str) or not re.fullmatch('[0-9a-f]{40}', value['api_core'])
            or not isinstance(value['namespace_registry_sha256'], str)
            or not re.fullmatch('[0-9a-f]{64}', value['namespace_registry_sha256'])):
        raise ValueError('Invalid complete-message profile configuration')
    evidence.wiktionary_api(value['wiki'])
    if not isinstance(value['date'], str) or not re.fullmatch('[0-9]{8}', value['date']):
        raise ValueError('Invalid complete-message associated dump date')
    datetime.strptime(value['date'], '%Y%m%d')
    languages, keys = value['languages'], value['extra_keys']
    if (not language_code(value['content_language']) or not isinstance(languages, list)
            or not 1 <= len(languages) <= 50 or any(not language_code(x) for x in languages)
            or languages != sorted(set(languages)) or not isinstance(keys, list)
            or not 1 <= len(keys) <= MAX_MESSAGE_KEYS or keys != sorted(set(keys))
            or len({normalize_key(k) for k in keys}) != len(keys)
            or not REQUIRED_MESSAGE_KEYS <= set(keys)):
        raise ValueError('Invalid complete-message language or supplemental key selection')
    return value


def reconstruct_complete(config, observe):
    """One request plan for collection and replay; no unobserved negatives."""
    complete_configuration(config)
    fallbacks, messages, coverage = {}, {}, {}
    continuation, tokens = {}, set()
    while True:
        rows, continuation = observe({'kind': 'fallbacks', 'continuation': continuation})
        if set(rows) & set(fallbacks) or len(fallbacks) + len(rows) > MAX_FALLBACK_ROWS:
            raise ValueError('Duplicate or excessive fallback rows')
        fallbacks.update(rows)
        if not continuation:
            break
        token = tuple(sorted(continuation.items()))
        if token in tokens:
            raise ValueError('Repeated fallback continuation')
        tokens.add(token)
    if not {config['content_language'], *config['languages']} <= set(fallbacks):
        raise ValueError('Selected language absent from complete fallback inventory')
    total_rows = 0
    for language in config['languages']:
        continuation, tokens, names, last_name = {}, set(), set(), None
        projected, unsupported = {}, []
        counters = dict(api_rows=0, explicit_missing=0, empty_values=0, nonempty_values=0,
                        projected_api_rows=0, normalization_alias_rows=0, supplemental_rows=0)
        while True:
            rows, following = observe({'kind': 'allmessages', 'language': language, 'continuation': continuation})
            for name, normalized, key, value in rows:
                if last_name is not None and complete_order_key(name) <= complete_order_key(last_name):
                    raise ValueError('API message pages are not strictly ordered')
                last_name = name
                if name in names:
                    raise ValueError('Repeated API message key across continuation pages')
                names.add(name); total_rows += 1; counters['api_rows'] += 1
                if total_rows > COMPLETE_MAX_ROWS:
                    raise ValueError('Complete-message row bound exceeded')
                counters['explicit_missing' if value is None else 'empty_values' if value == '' else 'nonempty_values'] += 1
                if key is None:
                    unsupported.append(dict(name=name, normalizedname=normalized, reason='outside-ascii-key-projection'))
                    continue
                if key in projected:
                    if projected[key] != value:
                        raise ValueError('Conflicting normalized message aliases')
                    counters['normalization_alias_rows'] += 1
                else:
                    projected[key] = value
            if not following:
                break
            token = tuple(sorted(following.items()))
            if token in tokens or following['amfrom'] in names:
                raise ValueError('Repeated or regressing allmessages continuation')
            tokens.add(token); continuation = following
        counters['projected_api_rows'] = len(projected)
        missing = [key for key in config['extra_keys'] if normalize_key(key) not in projected]
        for chunk in message_chunks(missing):
            rows = observe({'kind': 'messages', 'language': language, 'keys': chunk})
            if set(rows) & set(projected):
                raise ValueError('Supplemental message conflicts with enumeration')
            projected.update(rows); counters['supplemental_rows'] += len(rows)
        messages.update({(language, key): value for key, value in projected.items()})
        coverage[language] = {**counters, 'raw_key_set_sha256': evidence.digest(evidence.encoded(sorted(names))),
                              'unsupported_rows': unsupported, 'api_enumeration_complete': True,
                              'projection_complete_for_api_inventory': not unsupported,
                              'required_keys_observed': sorted(REQUIRED_MESSAGE_KEYS)}
        if len(messages) > COMPLETE_MAX_ROWS:
            raise ValueError('Complete-message projected row bound exceeded')
    outputs = {'interface-messages': render_messages(messages, config['wiki'], config['date'], config['content_language']),
               'language-fallbacks': render_fallbacks(fallbacks, config['wiki'], config['date'], config['content_language'])}
    if any(len(raw) > COMPLETE_TSV_BYTES for raw in outputs.values()):
        raise ValueError('Complete-message TSV byte bound exceeded')
    return outputs, coverage, fallbacks, messages


def capture_complete(args, transport=None, sleep=time.sleep):
    if not 0 <= args.delay <= 60 or not 1 <= args.wall_seconds <= 86400:
        raise ValueError('Invalid bounded complete-message capture settings')
    original = evidence.stamp(args.namespace_registry)
    namespace = evidence.small(args.namespace_registry)
    language = namespace_identity(namespace, args.wiki, args.date)
    api_core = complete_source_contract(args.api_sources)
    config = complete_configuration(dict(wiki=args.wiki, date=args.date, content_language=language,
        languages=sorted(set(args.languages or ['en', language])), extra_keys=sorted(set(args.messages or []) | REQUIRED_MESSAGE_KEYS),
        namespace_registry_sha256=evidence.digest(namespace), fallback_scope='all-supported-api-languages',
        profile=COMPLETE_PROFILE, api_core=api_core, projection_scope='ascii-key-projection-no-absence-inference',
        local_key_caveat='language-suffixed-only-pages-without-base-may-be-unenumerated',
        ordering_scope='utf8-byte-order-numeric-strings-refused'))
    identity = producer(); root = args.output
    root.mkdir(parents=True, exist_ok=False)
    started, deadline = evidence.utc(), time.monotonic() + args.wall_seconds
    try:
        evidence.put(root / (PREFIX + 'namespace-registry.tsv'), namespace)
        for name in (*COMPLETE_SOURCE_PINS, 'source-receipts01.json'):
            evidence.put(root / (PREFIX + 'source-' + name), evidence.small(Path(args.api_sources) / name, 512 * 1024))
        evidence.document(root / (PREFIX + 'requested.json'), config)
        requests = []
        if transport is None:
            transport = complete_response
        def observe(specification):
            if requests:
                if time.monotonic() + args.delay >= deadline:
                    raise ValueError('Capture wall deadline reached')
                sleep(args.delay)
            result, request = request_observation(root, len(requests) + 1, args.wiki, language,
                specification, transport, sleep, args.delay, deadline, complete_core=api_core)
            requests.append(request)
            return result
        outputs, coverage, fallbacks, messages = reconstruct_complete(config, observe)
        if producer() != identity or evidence.stamp(args.namespace_registry) != original:
            raise ValueError('Collector or selected namespace changed during capture')
        for kind, raw in outputs.items(): evidence.put(root / (kind + '.tsv'), raw)
        coverage_raw = evidence.encoded(coverage)
        if len(coverage_raw) > COMPLETE_RESPONSE_BYTES:
            raise ValueError('Complete-message coverage evidence byte bound exceeded')
        evidence.put(root / (PREFIX + 'coverage.json'), coverage_raw)
        inventory = owned_payload(root)
        common = dict(schema=COMPLETE_SCHEMA, header_version=1, **config, **identity,
            source_url=evidence.wiktionary_api(args.wiki), dump_date=None, temporal_scope='current-api-sequential-observations',
            started_utc=started, retrieved_utc=evidence.utc(), requests=requests, artifacts=inventory,
            api_enumeration_complete=True, candidate_queries_complete=True, corpus_query_closure_proven=False,
            fallback_mode='strict', message_mode='plain-with-database', fallback_languages=sorted(fallbacks),
            coverage_sha256=evidence.digest(coverage_raw))
        hashes = {}
        for kind, raw in outputs.items():
            record = dict(common, kind=kind, rows=len(fallbacks) if kind == 'language-fallbacks' else len(messages),
                          output_bytes=len(raw), output_sha256=evidence.digest(raw))
            encoded = evidence.encoded(record)
            if len(encoded) > MAX_MANIFEST: raise ValueError('Complete-message paired manifest byte bound exceeded')
            name = kind + '.manifest.json'; evidence.put(root / name, encoded); hashes[name] = evidence.digest(encoded)
        verify_complete(root, require_complete=False)
        evidence.document(root / COMPLETE, dict(schema=COMPLETE_SCHEMA, manifests=hashes))
        return verify_complete(root)
    except BaseException as error:
        for name in (COMPLETE, *(kind + suffix for kind in KINDS for suffix in ('.tsv', '.manifest.json'))):
            path = root / name
            if path.exists(): path.rename(root / (name + '.unverified'))
        evidence.document(root / (PREFIX + 'failure.json'), dict(error=str(error), ended_utc=evidence.utc(), **identity))
        raise


def verify_complete(root, require_complete=True):
    root = Path(root)
    if root.is_symlink() or not root.is_dir(): raise ValueError('Unsafe complete-message capture directory')
    records, hashes = {}, {}
    for kind in KINDS:
        name = kind + '.manifest.json'; raw = evidence.small(root / name, MAX_MANIFEST)
        record = evidence.decode(raw)
        if not isinstance(record, dict) or record.get('schema') != COMPLETE_SCHEMA or record.get('kind') != kind or record.get('header_version') != 1:
            raise ValueError('Complete-message paired schema mismatch')
        records[kind], hashes[name] = record, evidence.digest(raw)
    record = records['interface-messages']; other = records['language-fallbacks']
    per_output = {'kind', 'rows', 'output_bytes', 'output_sha256'}
    if {k: v for k, v in record.items() if k not in per_output} != {k: v for k, v in other.items() if k not in per_output}:
        raise ValueError('Complete-message paired manifests differ')
    validate_provenance(record)
    if require_complete and evidence.decode(evidence.small(root / COMPLETE, MAX_MANIFEST)) != dict(schema=COMPLETE_SCHEMA, manifests=hashes):
        raise ValueError('Complete-message completion marker mismatch')
    if (record.get('temporal_scope') != 'current-api-sequential-observations' or record.get('dump_date') is not None
            or record.get('api_enumeration_complete') is not True or record.get('candidate_queries_complete') is not True
            or record.get('corpus_query_closure_proven') is not False or record.get('fallback_mode') != 'strict'
            or record.get('message_mode') != 'plain-with-database'):
        raise ValueError('Invalid complete-message coverage or temporal scope')
    config = complete_configuration(evidence.decode(evidence.small(root / (PREFIX + 'requested.json'), MAX_MANIFEST)))
    if any(record.get(k) != v for k, v in config.items()) or record.get('source_url') != evidence.wiktionary_api(config['wiki']):
        raise ValueError('Complete-message requested configuration differs')
    namespace = evidence.small(root / (PREFIX + 'namespace-registry.tsv'))
    if (namespace_identity(namespace, config['wiki'], config['date']) != config['content_language']
            or evidence.digest(namespace) != config['namespace_registry_sha256']
            or complete_source_contract(root, PREFIX + 'source-') != config['api_core']):
        raise ValueError('Complete-message namespace/source identity differs')
    inventory = owned_payload(root)
    if inventory != record.get('artifacts'):
        raise ValueError('Complete-message artifact inventory differs')
    if sum(v['size'] for k, v in inventory.items() if k.endswith('.raw.json')) > COMPLETE_TOTAL_BYTES:
        raise ValueError('Complete-message raw evidence byte bound exceeded')
    requests = record.get('requests')
    if not isinstance(requests, list) or not 1 <= len(requests) <= MAX_REQUESTS:
        raise ValueError('Invalid complete-message request inventory')
    position = 0
    def observe(specification):
        nonlocal position
        if position >= len(requests): raise ValueError('Unfinished complete-message request chain')
        batch = requests[position]; position += 1
        request_name = f'{PREFIX}{position:04d}.request.json'
        if not isinstance(batch, dict) or set(batch) != {'request', 'accepted_receipt'} or batch['request'] != request_name:
            raise ValueError('Complete-message request order differs')
        accepted = batch['accepted_receipt']
        if accepted not in [f'{PREFIX}{position:04d}-{i:02d}.receipt.json' for i in range(1, 5)]:
            raise ValueError('Invalid accepted complete-message receipt name')
        query = (fallback_query(specification['continuation']) if specification['kind'] == 'fallbacks'
                 else complete_query(specification['language'], specification['continuation']) if specification['kind'] == 'allmessages'
                 else query_for(config['wiki'], specification['language'], specification['keys']))
        request = evidence.decode(evidence.small(root / request_name, MAX_MANIFEST))
        if request != dict(specification, query=query, url=query_url(config['wiki'], query)):
            raise ValueError('Complete-message request or continuation differs')
        receipt = evidence.decode(evidence.small(root / accepted, MAX_MANIFEST))
        response_name = accepted.removesuffix('.receipt.json') + '.raw.json'
        if (receipt.get('accepted') is not True or receipt.get('status') != 200
                or receipt.get('request') != request_name or receipt.get('response') != response_name
                or not isinstance(receipt.get('started_utc'), str) or not isinstance(receipt.get('ended_utc'), str)):
            raise ValueError('Unaccepted complete-message response')
        raw = evidence.small(root / response_name, COMPLETE_RESPONSE_BYTES)
        if receipt.get('response_bytes') != len(raw) or receipt.get('response_sha256') != evidence.digest(raw):
            raise ValueError('Complete-message raw response differs from receipt')
        data = evidence.decode(raw); checked_core(data, config['wiki'], config['content_language'], config['api_core'])
        if specification['kind'] == 'fallbacks': return parse_fallbacks(data, config['wiki'], config['content_language'])
        if specification['kind'] == 'allmessages': return parse_complete_page(data, config['wiki'], config['content_language'], config['api_core'], specification['continuation'])
        return parse_messages(data, specification['language'], specification['keys'], config['wiki'], config['content_language'])
    outputs, coverage, fallbacks, messages = reconstruct_complete(config, observe)
    if position != len(requests): raise ValueError('Unconsumed complete-message request records')
    coverage_raw = evidence.small(root / (PREFIX + 'coverage.json'), COMPLETE_RESPONSE_BYTES)
    if coverage_raw != evidence.encoded(coverage) or record.get('coverage_sha256') != evidence.digest(coverage_raw):
        raise ValueError('Complete-message projection coverage differs from raw evidence')
    if record.get('fallback_languages') != sorted(fallbacks): raise ValueError('Complete-message fallback languages differ')
    for kind, raw in outputs.items():
        current = records[kind]
        if (evidence.small(root / (kind + '.tsv'), COMPLETE_TSV_BYTES) != raw
                or current.get('rows') != (len(fallbacks) if kind == 'language-fallbacks' else len(messages))
                or current.get('output_bytes') != len(raw) or current.get('output_sha256') != evidence.digest(raw)):
            raise ValueError('Complete-message TSV differs from reconstructed API evidence')
    return records


def capture(args, transport=None, sleep=time.sleep):
    if getattr(args, 'complete_messages', False):
        return capture_complete(args, transport, sleep)
    evidence.wiktionary_api(args.wiki)
    if (not re.fullmatch(r'\d{8}', args.date) or not 0 <= args.delay <= 60
            or not 1 <= args.wall_seconds <= 86400):
        raise ValueError('Invalid date or bounded capture settings')
    datetime.strptime(args.date, '%Y%m%d')
    original = evidence.stamp(args.namespace_registry)
    namespace = evidence.small(args.namespace_registry)
    content_language = namespace_identity(namespace, args.wiki, args.date)
    languages = sorted(set(args.languages or [content_language]))
    keys = sorted(set(args.messages) | REQUIRED_MESSAGE_KEYS)
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
    initial = evidence.decode(evidence.small(root / 'interface-messages.manifest.json', MAX_MANIFEST))
    if isinstance(initial, dict) and initial.get('schema') == COMPLETE_SCHEMA:
        return verify_complete(root, require_complete)
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
    prior_limit = {PRE_LICENSE_GENERATOR_SHA256: 64,
                   PRE_LOOP_WARNING_GENERATOR_SHA256: 66}.get(manifest.get('generator_sha256'))
    prior_scope = (prior_limit is not None and isinstance(manifest.get('keys'), list)
                   and 1 <= len(manifest['keys']) <= prior_limit)
    validate_provenance(manifest)
    if prior_limit is not None and not prior_scope:
        raise ValueError('Invalid prior collector message scope')
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
    if not prior_scope and not REQUIRED_MESSAGE_KEYS <= set(keys):
        raise ValueError('Required parser message missing from capture selection')
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


def require_preferred_loop(record):
    # Call only after paired replay. Enumeration does not imply page-context
    # coverage, but the required key has an actual API row in every language.
    if record.get('schema') == COMPLETE_SCHEMA:
        if (record.get('profile') != COMPLETE_PROFILE
                or not REQUIRED_MESSAGE_KEYS <= set(record.get('extra_keys', []))):
            raise ValueError('Preferred loop messages require observed loop-warning key')
        return
    keys = record.get('keys')
    if (record.get('schema') != SCHEMA or not isinstance(keys, list)
            or not 1 <= len(keys) <= MAX_MESSAGE_KEYS or not REQUIRED_MESSAGE_KEYS <= set(keys)):
        raise ValueError('Preferred loop messages require the loop-warning key')


# These are implicit native Phonos requests, not edition-specific template keys.
# Plan them for new ordinary CLI captures; historical replay and explicit
# diagnostic-library selections keep their recorded scope and verifier rules.
NATIVE_CAPTURE_MESSAGE_KEYS = frozenset({
    'phonos-aria-error', 'phonos-player-aria-description',
})


def planned_capture_messages(messages):
    selected = set(messages)
    normalized = {normalize_key(key) for key in selected}
    selected.update(key for key in NATIVE_CAPTURE_MESSAGE_KEYS if normalize_key(key) not in normalized)
    # A missing #invoke module renders this localized Scribunto message. Older
    # full profiles keep their explicit keys and can use the additive collector.
    missing_module = 'scribunto-common-nosuchmodule'
    if missing_module not in normalized and len(selected | REQUIRED_MESSAGE_KEYS) < MAX_MESSAGE_KEYS:
        selected.add(missing_module)
    return sorted(selected)


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
    collect.add_argument('--messages', nargs='+', default=[])
    collect.add_argument('--complete-messages', action='store_true',
                         help='Enumerate all API/local base keys; explicit extras supplement omissions')
    collect.add_argument('--api-sources', type=Path,
                         help='Reviewed immutable API source files and source-receipts01.json')
    collect.add_argument('--delay', type=float, default=1.0)
    collect.add_argument('--wall-seconds', type=int, default=600)
    args = parser.parse_args()
    if args.command == 'capture' and args.delay < 1:
        parser.error('Network captures require at least one second between requests')
    if args.command == 'capture':
        if args.complete_messages and args.api_sources is None:
            parser.error('--complete-messages requires --api-sources')
        if not args.complete_messages and (not args.messages or args.api_sources is not None):
            parser.error('Explicit v2 capture requires --messages and no --api-sources')
    if args.command == 'capture':
        args.messages = planned_capture_messages(args.messages)
    manifests = capture(args) if args.command == 'capture' else verify(args.output)
    print(json.dumps({kind: {k: record[k] for k in ('wiki', 'date', 'content_language', 'rows',
        'output_sha256', 'temporal_scope')} for kind, record in manifests.items()}, sort_keys=True))


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError) as error:
        raise SystemExit(str(error)) from error
