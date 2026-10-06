#!/usr/bin/env python3
"""Capture current MediaWiki date-numbering observations for an offline build.

The fourteen-field #time probe shares Language::sprintfDate with Scribunto.
Profiles are specific to this wiki and requested language. They do not assert
historical dump-time configuration or corpus-wide requested-language closure.
The repeated composite is a consistency check, not an independent execution.
"""
import argparse
from datetime import datetime
import json
import math
from pathlib import Path
import re
import sys
import time
import urllib.parse

sys.dont_write_bytecode = True
import prepare_file_metadata as evidence
import prepare_language_messages as language_evidence

SCHEMA = 'wikidict.date-numbering-capture.v1'
PROOF_SCHEMA = 'wikidict.date-numbering-source-contract.v1'
PREFIX = 'date-numbering.'
KIND = 'date-numbering'
SNAPSHOT = KIND + '.tsv'
MANIFEST = KIND + '.manifest.json'
COMPLETE = PREFIX + 'complete.json'
MAX_PROFILES = 64
MAX_SNAPSHOT = 128 * 1024
MAX_MANIFEST = 64 * 1024
MAX_RESPONSE = 2 * 1024 * 1024
MAX_URL = 7 * 1024
MAX_REQUESTS = 128
MAX_SOURCE = 512 * 1024
MAX_ARTIFACTS = 1200
REPO = Path(__file__).resolve().parent.parent
REASONS = ('invalid-glyphs', 'composite-mismatch', 'raw-control-mismatch',
           'negative-mismatch', 'duplicate-mismatch')
BEGIN = 'BEGIN-WIKIDICT-DATE-NUMBERING-V1'
END = 'END-WIKIDICT-DATE-NUMBERING-V1'
FIELDS = tuple('D' + str(i) for i in range(10)) + ('COMPOSITE', 'RAW', 'NEGATIVE', 'REPEAT')

# Unicode 16 White_Space | Cc | Cf, shared exactly with the native reader.
# DerivedGeneralCategory SHA256: 7676ab755a41ef82108460238569e60ad65c191ddafe61b36c6765ec1353f293
# PropList SHA256: 53d614508e2a0b2305a8aa21cd60d993de9326cdf65993660dfcce4503548583
EXCLUDED_SCALARS = (
    (0, 32), (127, 160), (173, 173), (1536, 1541), (1564, 1564),
    (1757, 1757), (1807, 1807), (2192, 2193), (2274, 2274),
    (5760, 5760), (6158, 6158), (8192, 8207), (8232, 8239),
    (8287, 8292), (8294, 8303), (12288, 12288), (65279, 65279),
    (65529, 65531), (69821, 69821), (69837, 69837), (78896, 78911),
    (113824, 113827), (119155, 119162), (917505, 917505), (917536, 917631),
)
_CORE = 'https://raw.githubusercontent.com/wikimedia/mediawiki/534a011895bffbb001eef512fc313b8ad4bc939c/'
SOURCE_CONTRACT = {
    'language': (_CORE + 'includes/Language/Language.php',
                 '8ad4709d4e5dfa37f5dbf8b46c7108e62e2a1559ccce2ff4bda6a3281a1528cf'),
    'api-expandtemplates': (_CORE + 'includes/Api/ApiExpandTemplates.php',
                           'f34753d61c87b4854e45a1104fa3e84cbe2c7383cb20d8b2bdd9c0ed7fd78438'),
    'parser': (_CORE + 'includes/Parser/Parser.php',
               '02962e675880b9034a4cd2b0d05a2f5c7bdbb8817ba0774a6663474812f86a99'),
    'parser-functions': (
        'https://raw.githubusercontent.com/wikimedia/mediawiki-extensions-ParserFunctions/'
        '9cb4035d0a54de71beb1b8fa8a12ecc8461fac2b/includes/ParserFunctions.php',
        'aa71d3ca97ebe825115ca3919e22377fc9565e433a158f73b55bf3a6a5bfb3d2'),
    'scribunto': (
        'https://raw.githubusercontent.com/wikimedia/mediawiki-extensions-Scribunto/'
        'b109cb6e5866c13871e308859ef78249b1bd3ea2/includes/Engines/LuaCommon/LanguageLibrary.php',
        '017462f0c5ae7a1ffefdd44839845dbeea1e11a4a637fc7db8b9ec99dbd3baeb'),
}


def language_code(value):
    return isinstance(value, str) and re.fullmatch(r'[a-z0-9-]{2,64}', value) is not None


def timezone_name(value):
    return (isinstance(value, str) and 1 <= len(value) <= 128
            and all(33 <= ord(c) <= 126 and c != '\\' for c in value))


def glyph(value):
    if not isinstance(value, str):
        return False
    try:
        if not 1 <= len(value.encode('utf-8')) <= 32:
            return False
    except UnicodeEncodeError:
        return False
    return all(not (ord(c) < 128 and not '0' <= c <= '9')
               and not any(lo <= ord(c) <= hi for lo, hi in EXCLUDED_SCALARS)
               for c in value)


def oracle_text(language):
    if not language_code(language):
        raise ValueError('Invalid requested language')
    cases = [('U', '@' + str(i)) for i in range(10)]
    cases += [('U', '@1234567890'), ('xnU', '@1234567890'),
              ('U', '@-1'), ('U', '@1234567890')]
    return '\n'.join([BEGIN, *(key + '={{#time:' + fmt + '|' + date + '|' + language + '}}'
                             for key, (fmt, date) in zip(FIELDS, cases)), END])


def clean_api(data):
    if (not isinstance(data, dict)
            or any(k in data for k in ('error', 'errors', 'warnings', 'continue'))):
        raise ValueError('Incomplete or unsuccessful API observation')
    return data


def parse_oracle(data):
    expanded = clean_api(data).get('expandtemplates')
    text = expanded.get('wikitext') if isinstance(expanded, dict) else None
    if not isinstance(text, str) or '\r' in text:
        raise ValueError('Missing or malformed date oracle')
    lines = text.split('\n')
    if len(lines) != 16 or lines[0] != BEGIN or lines[-1] != END:
        raise ValueError('Date oracle framing mismatch')
    values = []
    for key, line in zip(FIELDS, lines[1:-1]):
        if not line.startswith(key + '='):
            raise ValueError('Date oracle field order/framing mismatch')
        values.append(line[len(key) + 1:])
    digits, composite, raw, negative, repeat = values[:10], *values[10:]
    if not all(glyph(x) for x in digits) or len(set(digits)) != 10:
        return ('U', 'invalid-glyphs')
    if composite != ''.join(digits[1:] + digits[:1]):
        return ('U', 'composite-mismatch')
    if raw != '1234567890':
        return ('U', 'raw-control-mismatch')
    # Language::sprintfDate only translates /^[\d.]+$/, so negative U is raw.
    if negative != '-1':
        return ('U', 'negative-mismatch')
    if repeat != composite:
        return ('U', 'duplicate-mismatch')
    return ('D', digits)


def parse_siteinfo(data, wiki, content_language, languages=None):
    query = clean_api(data).get('query')
    general = query.get('general') if isinstance(query, dict) else None
    if (not isinstance(general, dict) or general.get('wikiid') != wiki
            or general.get('lang') != content_language or not timezone_name(general.get('timezone'))
            or not isinstance(general.get('generator'), str)
            or not 1 <= len(general['generator']) <= 256
            or any(ord(c) < 32 or ord(c) == 127 for c in general['generator'])):
        raise ValueError('API wiki/language/timezone/generator identity mismatch')
    identity = {key: general[key] for key in ('wikiid', 'lang', 'timezone', 'generator')}
    for key in ('git-hash', 'git-branch'):
        if key in general:
            value = general[key]
            if (not isinstance(value, str) or not 1 <= len(value) <= 256
                    or any(ord(c) < 32 or ord(c) == 127 for c in value)):
                raise ValueError('Malformed server source identity')
            identity[key] = value
    if languages is not None:
        info = query.get('languageinfo')
        if (not isinstance(info, dict) or set(info) != set(languages)
                or any(not isinstance(row, dict) or row.get('code') != code
                       for code, row in info.items())):
            raise ValueError('Requested language is not an explicit known API language')
    return identity


def query_for(specification):
    if specification['kind'] == 'oracle':
        return {'action': 'expandtemplates', 'format': 'json', 'formatversion': '2',
                'prop': 'wikitext', 'title': 'API', 'text': oracle_text(specification['language']),
                'uselang': 'en', 'maxlag': '5'}
    query = {'action': 'query', 'format': 'json', 'formatversion': '2',
             'meta': 'siteinfo', 'siprop': 'general', 'maxlag': '5'}
    if specification['kind'] == 'languages':
        query.update(meta='siteinfo|languageinfo', licode='|'.join(specification['languages']),
                     liprop='code')
    elif specification['kind'] != 'final-siteinfo':
        raise ValueError('Unknown date capture request kind')
    return query


def specifications(languages):
    return ([{'kind': 'languages', 'languages': languages[i:i + 16]}
             for i in range(0, len(languages), 16)]
            + [{'kind': 'oracle', 'language': language} for language in languages]
            + [{'kind': 'final-siteinfo'}])


def query_url(wiki, query):
    return evidence.wiktionary_api(wiki) + '?' + urllib.parse.urlencode(query)


def render(profiles, wiki, date, content_language, timezone):
    if not timezone_name(timezone) or not 1 <= len(profiles) <= MAX_PROFILES:
        raise ValueError('Invalid date-numbering profile inventory')
    lines = ['# wikidict-date-numbering-v1', '# wiki\t' + wiki, '# dump-date\t' + date,
             '# content-language\t' + content_language, '# timezone\t' + timezone,
             '# profiles\t' + str(len(profiles))]
    for language, (kind, value) in sorted(profiles.items()):
        if not language_code(language):
            raise ValueError('Invalid date profile language')
        if kind == 'D' and isinstance(value, list) and len(value) == 10:
            if not all(glyph(x) for x in value) or len(set(value)) != 10:
                raise ValueError('Invalid supported date-numbering profile')
            lines.append('\t'.join(('D', language, *value)))
        elif kind == 'U' and value in REASONS:
            lines.append('\t'.join(('U', language, value)))
        else:
            raise ValueError('Invalid date-numbering profile kind/reason')
    raw = ('\n'.join(lines) + '\n').encode('utf-8')
    if len(raw) > MAX_SNAPSHOT:
        raise ValueError('Date-numbering snapshot exceeds native size limit')
    return raw


def producer():
    return {'generator_sha256': evidence.digest(evidence.small(Path(__file__))),
            'dependency_sha256': {name: evidence.digest(evidence.small(REPO / name)) for name in (
                'tools/prepare_file_metadata.py', 'tools/prepare_language_messages.py',
                'tools/download_wiktionaries.py', 'tools/category_tree_snapshot.py')}}


def source_rows(raw):
    proof = evidence.decode(raw)
    if (not isinstance(proof, dict) or set(proof) != {'schema', 'sources'}
            or proof.get('schema') != PROOF_SCHEMA or not isinstance(proof.get('sources'), list)
            or len(proof['sources']) != len(SOURCE_CONTRACT)):
        raise ValueError('Invalid primary source reference contract')
    rows = {}
    for row in proof['sources']:
        if not isinstance(row, dict) or set(row) != {'role', 'path', 'url', 'sha256'}:
            raise ValueError('Invalid primary source descriptor')
        role = row['role']
        if (not isinstance(role, str) or role not in SOURCE_CONTRACT or role in rows
                or not isinstance(row['path'], str)
                or re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]{0,127}', row['path']) is None
                or (row['url'], row['sha256']) != SOURCE_CONTRACT[role]):
            raise ValueError('Unreviewed or conflicting primary source contract')
        rows[role] = row
    if set(rows) != set(SOURCE_CONTRACT):
        raise ValueError('Incomplete primary source contract')
    return rows


def portable_proof(rows):
    return {'schema': PROOF_SCHEMA, 'scope': 'reviewed-reference-semantics-not-server-commit',
            'sources': [{'role': role, 'path': PREFIX + 'source.' + role + '.php',
                         'url': row['url'], 'sha256': row['sha256']}
                        for role, row in sorted(rows.items())]}


def copy_proof(path, root):
    raw = evidence.small(path, MAX_MANIFEST)
    rows = source_rows(raw)
    evidence.put(root / (PREFIX + 'core-proof.requested.json'), raw)
    for role, row in rows.items():
        data = evidence.small(path.parent / row['path'], MAX_SOURCE)
        if evidence.digest(data) != row['sha256']:
            raise ValueError('Primary source bytes differ from reviewed contract')
        evidence.put(root / (PREFIX + 'source.' + role + '.php'), data)
    evidence.document(root / (PREFIX + 'core-proof.json'), portable_proof(rows))


def verify_proof(root):
    rows = source_rows(evidence.small(root / (PREFIX + 'core-proof.requested.json'), MAX_MANIFEST))
    if evidence.decode(evidence.small(root / (PREFIX + 'core-proof.json'), MAX_MANIFEST)) != portable_proof(rows):
        raise ValueError('Portable primary source contract changed')
    for role, row in rows.items():
        if evidence.digest(evidence.small(root / (PREFIX + 'source.' + role + '.php'), MAX_SOURCE)) != row['sha256']:
            raise ValueError('Archived primary source bytes changed')


def owned_payload(root):
    result = {}
    for path in root.iterdir():
        if path.name in (MANIFEST, COMPLETE):
            continue
        if path.name.startswith(PREFIX) or path.name == SNAPSHOT:
            if len(result) >= MAX_ARTIFACTS:
                raise ValueError('Excessive date-numbering evidence artifacts')
            item = evidence.fingerprint(path)
            result[path.name] = {key: item[key] for key in ('size', 'sha256')}
    return dict(sorted(result.items()))


def observe(root, number, wiki, specification, parser, transport, sleep, delay, deadline):
    if not 1 <= number <= MAX_REQUESTS:
        raise ValueError('Capture request bound exceeded')
    request_name = f'{PREFIX}{number:04d}.request.json'
    query = query_for(specification)
    url = query_url(wiki, query)
    if len(url.encode()) > MAX_URL:
        raise ValueError('Date oracle exceeds bounded URL size')
    evidence.document(root / request_name, {'url': url, 'query': query, **specification})
    for attempt in range(1, 5):
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise ValueError('Capture wall deadline reached')
        stem = f'{PREFIX}{number:04d}-{attempt:02d}'
        receipt = {'request': request_name, 'started_utc': evidence.utc(), 'status': None}
        headers, retry = {}, False
        try:
            status, headers, raw = transport(url, min(30, remaining))
            if len(raw) > MAX_RESPONSE + 1:
                raise ValueError('Transport exceeded bounded response read')
            receipt.update(status=status, response=stem + '.raw.json', response_bytes=len(raw),
                           response_sha256=evidence.digest(raw),
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
            result = parser(data)
            if time.monotonic() >= deadline:
                raise ValueError('Capture wall deadline reached')
            receipt.update(accepted=True, ended_utc=evidence.utc())
            evidence.document(root / (stem + '.receipt.json'), receipt)
            return result, {'request': request_name, 'accepted_receipt': stem + '.receipt.json'}
        except (OSError, ValueError) as error:
            retry = retry or isinstance(error, OSError)
            receipt.update(accepted=False, error=str(error), ended_utc=evidence.utc())
            evidence.document(root / (stem + '.receipt.json'), receipt)
            if not retry or attempt == 4:
                raise
            retry_after = next((v for k, v in headers.items() if k.lower() == 'retry-after'), '')
            if retry_after and not str(retry_after).isdigit():
                raise ValueError('Unsupported Retry-After; preserve evidence for review') from error
            wait = max(delay, 2 ** (attempt - 1), int(retry_after or 0))
            if wait > 60 or time.monotonic() + wait >= deadline:
                raise ValueError('Retry exceeds bounded capture wait/deadline') from error
            sleep(wait)


def valid_configuration(config):
    if (not isinstance(config, dict) or set(config) != {'wiki', 'date', 'content_language', 'languages',
                                                     'namespace_registry_sha256'}
            or not isinstance(config['date'], str) or not re.fullmatch(r'[0-9]{8}', config['date'])
            or not language_code(config['content_language'])
            or not isinstance(config['languages'], list)
            or not 1 <= len(config['languages']) <= MAX_PROFILES
            or any(not language_code(x) for x in config['languages'])
            or config['languages'] != sorted(set(config['languages']))):
        raise ValueError('Invalid date-numbering capture configuration')
    evidence.wiktionary_api(config['wiki'])
    datetime.strptime(config['date'], '%Y%m%d')


def capture(args, transport=None, sleep=time.sleep):
    original = evidence.stamp(args.namespace_registry)
    namespace = evidence.small(args.namespace_registry)
    content_language = language_evidence.namespace_identity(namespace, args.wiki, args.date)
    languages = list(args.languages or [content_language])
    if len(set(languages)) != len(languages):
        raise ValueError('Duplicate requested date-numbering language')
    config = {'wiki': args.wiki, 'date': args.date, 'content_language': content_language,
              'languages': sorted(languages), 'namespace_registry_sha256': evidence.digest(namespace)}
    valid_configuration(config)
    if (not isinstance(args.delay, (int, float)) or not math.isfinite(args.delay) or not 0 <= args.delay <= 60
            or type(args.wall_seconds) is not int or not 1 <= args.wall_seconds <= 3600):
        raise ValueError('Invalid bounded capture settings')
    identity = producer()
    root = args.output
    root.mkdir(parents=True, exist_ok=False)
    started, deadline = evidence.utc(), time.monotonic() + args.wall_seconds
    try:
        evidence.put(root / (PREFIX + 'namespace-registry.tsv'), namespace)
        copy_proof(args.core_proof, root)
        evidence.document(root / (PREFIX + 'requested.json'), config)
        profiles, requests, site = {}, [], None
        for spec in specifications(config['languages']):
            if requests:
                if time.monotonic() + args.delay >= deadline:
                    raise ValueError('Capture wall deadline reached')
                sleep(args.delay)
            if spec['kind'] == 'oracle':
                parser = parse_oracle
            else:
                parser = lambda data, spec=spec: parse_siteinfo(
                    data, args.wiki, content_language, spec.get('languages'))
            result, request = observe(root, len(requests) + 1, args.wiki, spec, parser,
                transport or evidence.get_response, sleep, args.delay, deadline)
            requests.append(request)
            if spec['kind'] == 'oracle':
                profiles[spec['language']] = result
            elif site is None:
                site = result
            elif site != result:
                raise ValueError('Wiki timezone/generator identity changed during capture')
        if (producer() != identity or evidence.stamp(args.namespace_registry) != original
                or time.monotonic() >= deadline):
            raise ValueError('Collector, pinned namespace or capture deadline changed')
        raw = render(profiles, args.wiki, args.date, content_language, site['timezone'])
        evidence.put(root / SNAPSHOT, raw)
        manifest = {'schema': SCHEMA, 'kind': KIND, 'header_version': 1, **config, **identity,
                    'source_url': evidence.wiktionary_api(args.wiki), 'dump_date': None,
                    'temporal_scope': 'current-api-observation', 'started_utc': started,
                    'retrieved_utc': evidence.utc(), 'requests': requests, 'siteinfo_identity': site,
                    'reference_scope': 'reviewed-reference-semantics-not-server-commit',
                    'observation_scope': 'per-request-configuration-no-cross-request-config-atomicity',
                    'candidate_queries_complete': True, 'corpus_query_closure_proven': False,
                    'rows': len(profiles), 'supported_rows': sum(kind == 'D' for kind, _ in profiles.values()),
                    'unknown_rows': sum(kind == 'U' for kind, _ in profiles.values()),
                    'output_bytes': len(raw), 'output_sha256': evidence.digest(raw),
                    'artifacts': owned_payload(root)}
        encoded = evidence.encoded(manifest)
        if len(encoded) > MAX_MANIFEST:
            raise ValueError('Date-numbering manifest exceeds builder size limit')
        evidence.put(root / MANIFEST, encoded)
        verify(root, require_complete=False)
        evidence.document(root / COMPLETE, {'schema': SCHEMA, 'manifest_sha256': evidence.digest(encoded)})
        return manifest
    except BaseException as error:
        for name in (COMPLETE, SNAPSHOT, MANIFEST):
            path = root / name
            if path.exists():
                path.rename(root / (name + '.unverified'))
        evidence.document(root / (PREFIX + 'failure.json'), {'ended_utc': evidence.utc(), 'error': str(error), **identity})
        raise


def verify(root, require_complete=True):
    root = Path(root)
    if root.is_symlink() or not root.is_dir():
        raise ValueError('Unsafe date-numbering capture directory')
    raw_manifest = evidence.small(root / MANIFEST, MAX_MANIFEST)
    manifest = evidence.decode(raw_manifest)
    if (not isinstance(manifest, dict) or manifest.get('schema') != SCHEMA
            or manifest.get('kind') != KIND or manifest.get('header_version') != 1):
        raise ValueError('Unsupported date-numbering capture manifest')
    if require_complete and evidence.decode(evidence.small(root / COMPLETE, MAX_MANIFEST)) != {
            'schema': SCHEMA, 'manifest_sha256': evidence.digest(raw_manifest)}:
        raise ValueError('Date-numbering completion marker mismatch')
    identity = producer()
    if any(manifest.get(k) != v for k, v in identity.items()):
        raise ValueError('Capture requires its original collector and dependencies')
    if (manifest.get('temporal_scope') != 'current-api-observation' or manifest.get('dump_date') is not None
            or manifest.get('reference_scope') != 'reviewed-reference-semantics-not-server-commit'
            or manifest.get('observation_scope') != 'per-request-configuration-no-cross-request-config-atomicity'
            or manifest.get('candidate_queries_complete') is not True
            or manifest.get('corpus_query_closure_proven') is not False):
        raise ValueError('Unsupported date-numbering observation scope')
    inventory = owned_payload(root)
    if inventory != manifest.get('artifacts'):
        raise ValueError('Date-numbering artifact inventory/hash mismatch')
    verify_proof(root)
    config = evidence.decode(evidence.small(root / (PREFIX + 'requested.json'), MAX_MANIFEST))
    valid_configuration(config)
    if any(manifest.get(k) != v for k, v in config.items()):
        raise ValueError('Requested date profiles differ from manifest')
    wiki, date, content_language = config['wiki'], config['date'], config['content_language']
    namespace = evidence.small(root / (PREFIX + 'namespace-registry.tsv'))
    if (language_evidence.namespace_identity(namespace, wiki, date) != content_language
            or evidence.digest(namespace) != config['namespace_registry_sha256']
            or manifest.get('source_url') != evidence.wiktionary_api(wiki)):
        raise ValueError('Pinned namespace/API identity differs from capture')
    expected_specs = specifications(config['languages'])
    batches = manifest.get('requests')
    if not isinstance(batches, list) or len(batches) != len(expected_specs) or len(batches) > MAX_REQUESTS:
        raise ValueError('Invalid date-numbering request inventory')
    profiles, site = {}, None
    for number, (spec, batch) in enumerate(zip(expected_specs, batches), 1):
        request_name = f'{PREFIX}{number:04d}.request.json'
        if (not isinstance(batch, dict) or set(batch) != {'request', 'accepted_receipt'}
                or batch['request'] != request_name or request_name not in inventory
                or not isinstance(batch['accepted_receipt'], str)
                or re.fullmatch(re.escape(f'{PREFIX}{number:04d}-') + r'0[1-4]\.receipt\.json',
                                batch['accepted_receipt']) is None
                or batch['accepted_receipt'] not in inventory):
            raise ValueError('Unrecorded, reordered or excessive request evidence')
        query = query_for(spec)
        url = query_url(wiki, query)
        request = evidence.decode(evidence.small(root / request_name, MAX_MANIFEST))
        if request != {'url': url, 'query': query, **spec} or len(url.encode()) > MAX_URL:
            raise ValueError('Capture request differs from date oracle semantics')
        receipt = evidence.decode(evidence.small(root / batch['accepted_receipt'], MAX_MANIFEST))
        expected_response = batch['accepted_receipt'].removesuffix('.receipt.json') + '.raw.json'
        if (not isinstance(receipt, dict) or receipt.get('accepted') is not True or receipt.get('status') != 200
                or receipt.get('request') != request_name or receipt.get('response') != expected_response
                or expected_response not in inventory):
            raise ValueError('Invalid accepted date oracle receipt')
        raw = evidence.small(root / expected_response, MAX_RESPONSE)
        if receipt.get('response_bytes') != len(raw) or receipt.get('response_sha256') != evidence.digest(raw):
            raise ValueError('Raw date response differs from receipt')
        data = evidence.decode(raw)
        if spec['kind'] == 'oracle':
            profiles[spec['language']] = parse_oracle(data)
        else:
            result = parse_siteinfo(data, wiki, content_language, spec.get('languages'))
            if site is None:
                site = result
            elif site != result:
                raise ValueError('Wiki timezone/generator identity drift in retained evidence')
    expected = render(profiles, wiki, date, content_language, site['timezone'])
    if (manifest.get('siteinfo_identity') != site or manifest.get('rows') != len(profiles)
            or manifest.get('supported_rows') != sum(kind == 'D' for kind, _ in profiles.values())
            or manifest.get('unknown_rows') != sum(kind == 'U' for kind, _ in profiles.values())
            or manifest.get('output_bytes') != len(expected) or manifest.get('output_sha256') != evidence.digest(expected)
            or evidence.small(root / SNAPSHOT, MAX_SNAPSHOT) != expected):
        raise ValueError('Date-numbering TSV differs from complete API evidence')
    return manifest


def validate_snapshot(path, wiki=None, date=None):
    path = Path(path)
    if path.name != SNAPSHOT:
        raise ValueError('Unexpected date-numbering snapshot name')
    manifest = verify(path.parent)
    if ((wiki is not None and manifest['wiki'] != wiki) or (date is not None and manifest['date'] != date)):
        raise ValueError('Date-numbering snapshot edition/date mismatch')
    return manifest


def capture_artifacts(path, manifest=None):
    path = Path(path)
    validated = validate_snapshot(path)
    if manifest is not None and manifest != validated:
        raise ValueError('Date-numbering manifest changed before pinning')
    result = {name: row['sha256'] for name, row in validated['artifacts'].items()}
    for name in (MANIFEST, COMPLETE):
        result[name] = evidence.digest(evidence.small(path.parent / name, MAX_MANIFEST))
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    check = commands.add_parser('verify')
    check.add_argument('output', type=Path)
    collect = commands.add_parser('capture')
    collect.add_argument('--wiki', required=True)
    collect.add_argument('--date', required=True, help='Associated dump date, not observation time')
    collect.add_argument('--namespace-registry', required=True, type=Path)
    collect.add_argument('--core-proof', required=True, type=Path)
    collect.add_argument('--output', required=True, type=Path)
    collect.add_argument('--languages', nargs='+', default=[])
    collect.add_argument('--delay', type=float, default=1)
    collect.add_argument('--wall-seconds', type=int, default=600)
    args = parser.parse_args()
    if args.command == 'capture' and args.delay < 1:
        parser.error('Network captures require at least one second between requests')
    manifest = capture(args) if args.command == 'capture' else verify(args.output)
    print(json.dumps({key: manifest[key] for key in ('wiki', 'date', 'content_language', 'rows',
                                                   'output_sha256', 'temporal_scope')}, sort_keys=True))


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError) as error:
        raise SystemExit(str(error)) from error
