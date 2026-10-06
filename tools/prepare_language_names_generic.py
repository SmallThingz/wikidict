#!/usr/bin/env python3
"""Capture generic explicit display-language profiles with pinned CLDR evidence.

The legacy ar/en collector and its v1 captures remain unchanged. This v2 capture
profile retains complete current API observations and immutable source evidence;
native language-names.tsv stays v1. Autonyms and mwfile are outside this profile.
"""
import argparse
from functools import lru_cache
import hashlib
from datetime import datetime
import json
from pathlib import Path
import re
import sys
import time
import urllib.parse

sys.dont_write_bytecode = True
import prepare_file_metadata as evidence

SCHEMA = 'wikidict.language-names-capture.v2'
MAX_SOURCE = 4 * 1024 * 1024
MAX_PROFILES = 21
PREFIX = 'language-names.'
KIND = 'language-names'
COMPLETE = PREFIX + 'complete.json'
CORE = '0d3b507d19ae860ed8a1d22c73fa4bc5abf8dfcc'
# The eleven relevant core PHP sources are byte-identical at these exact
# revisions. Each capture selects one revision and binds every API response to it.
CORE_TREE_SHA256 = {
    CORE: 'df249a63ff3115609f85cdd74fee3051265f7a2b41a6a2eb7005f8e107f6d0c4',
    '79b81ba96674efc8a803fc956bc501d347d440d2': '95c6558642eb825b827726ca6f0886bc6534e9f823f00bf17245af69cc1b46d9',
}
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
    'LanguageNameUtils.php': '5f55c8ed75da5dfee8f708a3c620b5f17dbe33396e99882175cb92f4828ba8f8',
    'LanguageFallback.php': 'ce6508ec338120c6d86f25681ec8f0a1f43ded08ac967507ba4c100aa497d4ed',
    'LocalisationCache.php': 'dab9de5e3b2506a4e10ada26c8dca9b8a379bb066f52f37e493e485ce31e3416',
    'cldr-Hooks.php': '4fdbd86bfa8ecb8ca319ec7166c13cb4878cc742b96083fd3ffc678114b78cf9',
    'cldr-catalog.json': '699f1ae957db93c25f5947c22b65cb5733b3f47da38ced51a35302024d5700f5',
}


def core_revision(value):
    if not isinstance(value, str) or value not in CORE_TREE_SHA256:
        raise ValueError('Unreviewed core source revision')
    return value


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
        raw = evidence.small(root / (prefix + name), MAX_SOURCE)
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
    tables = source_catalog(sources['cldr-catalog.json'])
    return sources, aliases, tables


@lru_cache(maxsize=1)
def source_catalog(raw):
    # The caller re-hashes the complete source bytes before this parse cache.
    value = evidence.decode(raw)
    if (value.get('schema') != 'wikidict.cldr-language-names-source.v1'
            or value.get('commit') != 'bd57961ea538f51f992d911705bdd2b8ff666fe9'
            or not isinstance(value.get('tables'), dict) or 'en' not in value['tables']):
        raise ValueError('Invalid pinned CLDR catalog')
    tables = {}
    for locale, rows in value['tables'].items():
        # CLDR loadLanguage rejects non-built-in locale codes before reading
        # their files. Keep their raw catalog evidence without using the rows.
        if not code(locale):
            continue
        if locale == 'qqq' or not isinstance(rows, dict):
            raise ValueError('Invalid CLDR locale')
        if any(not code(k) or not text(v) or v == '-' for k, v in rows.items()):
            raise ValueError('Invalid CLDR language-name row')
        tables[locale] = rows
    return tables


DIRECTION_PROFILE = 'core-unsupported-en-v1'
EXTRA_DIRECTION_CODES = frozenset(('rmq', 'rmq-x-ca', 'rmq-x-es', 'roa-oca'))
DIRECTION_SOURCE_PINS = {
    'core-tree.json': 'df249a63ff3115609f85cdd74fee3051265f7a2b41a6a2eb7005f8e107f6d0c4',
    'wmf-config-tree.json': 'f82c56aaf86e39f2ccbd70749f834634d084f0179694bff584bea44c88d5e46a',
    'wmf-config-catalog.json': '8f632ab532524ffc83b2e22ed5b1f8647cbaa2b30f83b2211d50d83833b85955',
    'LanguageFactory.php': '26f2e1af27aee67c3e0bc898e5e1dcb9de413515530ddc313ee0d5bde4bc0bd0',
    'Language.php': '8ad4709d4e5dfa37f5dbf8b46c7108e62e2a1559ccce2ff4bda6a3281a1528cf',
    'MessagesEn.php': '72096aaf66242dd6a6ba5817c3ef8bcb0e536aabb55c153c7c6be5fdaba80fa8',
    'MainConfigSchema.php': '3431088101d64e88c2da66453929f942b72b6e7fc540ecb289a21015cd97848a',
    'mw.language.lua': 'f3623631bc6d5a33b936292ef40f8ad9028dded3466d4ecce701262a97ddbb83',
}


def extra_direction_codes(values):
    # Capture normalizes CLI arguments first; offline verification requires this
    # exact representation so omissions, duplicates and changed requests fail.
    if (not isinstance(values, list) or any(not isinstance(x, str) for x in values)
            or values != sorted(set(values)) or not set(values) <= EXTRA_DIRECTION_CODES):
        raise ValueError('Unreviewed or noncanonical extra direction codes')
    return values


def public_direction_config(sources):
    # Source-profile provenance, not an assertion of an API-observed deployed
    # configuration revision. Preserve the complete public configuration proof.
    commit = 'cb5a4a08978a7c8a180837d8236afe616c619bf8'
    tree = evidence.decode(sources['wmf-config-tree.json'])
    catalog = evidence.decode(sources['wmf-config-catalog.json'])
    if (not isinstance(tree, dict) or tree.get('sha') != commit
            or tree.get('truncated') is not False or not isinstance(tree.get('tree'), list)
            or not isinstance(catalog, dict)
            or catalog.get('schema') != 'wikidict.wmf-config-php-source.v1'
            or catalog.get('commit') != commit or not isinstance(catalog.get('records'), list)):
        raise ValueError('Incomplete public configuration source proof')
    expected = {}
    for entry in tree['tree']:
        if not isinstance(entry, dict) or not isinstance(entry.get('path'), str):
            raise ValueError('Invalid configuration source tree')
        path = entry['path']
        if entry.get('type') == 'blob' and path.endswith('.php') and not path.startswith(('tests/', 'docroot/')):
            if path in expected:
                raise ValueError('Duplicate configuration source path')
            expected[path] = entry['sha']
    found = set()
    for row in catalog['records']:
        if (not isinstance(row, dict) or row.get('path') not in expected
                or row['path'] in found or not isinstance(row.get('source'), str)):
            raise ValueError('Invalid or duplicate configuration source record')
        raw = row['source'].encode('utf-8')
        blob = hashlib.sha1(b'blob ' + str(len(raw)).encode() + b'\0' + raw).hexdigest()
        if (len(raw) != row.get('bytes') or evidence.digest(raw) != row.get('sha256')
                or blob != row.get('blob_sha1') or blob != expected[row['path']]):
            raise ValueError('Configuration source identity differs')
        if 'DummyLanguageCodes' in row['source'] or 'ExtraLanguageCodes' in row['source']:
            raise ValueError('Public configuration may override direction language mapping')
        found.add(row['path'])
    if found != set(expected):
        raise ValueError('Incomplete public configuration PHP inventory')


def extra_direction_contract(root, values, aliases, prefix='', core=CORE):
    core = core_revision(core)
    values = extra_direction_codes(values)
    if not values:
        return {}, {}
    if root is None:
        raise ValueError('Extra directions require pinned primary source evidence')
    sources = {}
    pins = DIRECTION_SOURCE_PINS
    if core != CORE:
        pins = {**pins, 'core-tree.json': CORE_TREE_SHA256[core]}
    for name, digest in pins.items():
        raw = evidence.small(root / (prefix + name), MAX_SOURCE)
        if evidence.digest(raw) != digest:
            raise ValueError('Unreviewed direction primary source: ' + name)
        sources[name] = raw
    public_direction_config(sources)
    tree = evidence.decode(sources['core-tree.json'])
    if (not isinstance(tree, dict) or tree.get('sha') != core
            or tree.get('truncated') is not False or not isinstance(tree.get('tree'), list)):
        raise ValueError('Incomplete pinned core tree for extra directions')
    paths = set()
    for entry in tree['tree']:
        if not isinstance(entry, dict) or not isinstance(entry.get('path'), str):
            raise ValueError('Invalid pinned core tree entry')
        paths.add(entry['path'])
    for language in values:
        suffix = language[0].upper() + language[1:].replace('-', '_')
        candidates = (
            'includes/Languages/Language' + suffix + '.php',
            'languages/messages/Messages' + suffix + '.php',
            'languages/i18n/' + language + '.json',
        )
        if language in aliases or any(path in paths for path in candidates):
            raise ValueError('Extra direction language has unaudited core support: ' + language)
    # The pinned public configuration has no language-code mapping override.
    # This is explicitly source-derived, not a measured deployed config hash.
    # The exact pinned PHP/Lua chain proves absent core localization shallow-
    # falls to English, whose rtl is false. No inference from API omission,
    # subtags, scripts, or an arbitrary unknown-language default is used.
    return sources, {language: 'ltr' for language in values}


def merge_extra_directions(directions, derived):
    if derived and directions.get('en') != 'ltr':
        raise ValueError('API English direction conflicts with pinned fallback proof')
    if set(directions) & set(derived):
        raise ValueError('Source-derived direction overlaps an API or alias direction')
    return {**directions, **derived}

def direction_config(config):
    optional = {'extra_direction_codes', 'direction_profile'} & set(config)
    if not optional:
        return []
    if (optional != {'extra_direction_codes', 'direction_profile'}
            or config['direction_profile'] != DIRECTION_PROFILE
            or not config['extra_direction_codes']):
        raise ValueError('Incomplete or unreviewed direction profile')
    return extra_direction_codes(config['extra_direction_codes'])


def direction_provenance(derived):
    return 'current-api-plus-pinned-core' if derived else 'current-api'


def request_query(display, include_dir, continuation):
    return {'action': 'query', 'format': 'json', 'formatversion': '2',
            'meta': 'siteinfo|languageinfo', 'siprop': 'general|languages',
            'siinlanguagecode': display, 'uselang': display, 'licode': '*',
            'liprop': 'code|name|dir|fallbacks' if include_dir else 'code|name', 'maxlag': '5', **continuation}


def parse_response(data, wiki, content_language, include_dir, core=CORE):
    core = core_revision(core)
    if not isinstance(data, dict) or any(key in data for key in ('error', 'errors', 'warnings')):
        raise ValueError('Unsuccessful or warning-bearing API response')
    query = data.get('query')
    general = query.get('general') if isinstance(query, dict) else None
    if (not isinstance(general, dict) or general.get('wikiid') != wiki
            or general.get('lang') != content_language or general.get('git-hash') != core):
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
            fallbacks = row.get('fallbacks')
            if (not isinstance(fallbacks, list) or len(fallbacks) > 32
                    or any(not code(v) for v in fallbacks) or len(set(fallbacks)) != len(fallbacks)
                    or language in fallbacks or language == 'en' and fallbacks):
                raise ValueError('Invalid authoritative STRICT fallback chain')
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


def finish_profile(single, mw, aliases, tables, display, fallbacks):
    normalized = aliases.get(display, display)
    if normalized not in fallbacks:
        raise ValueError('Display-language fallback coverage missing: ' + normalized)
    # LanguageFallback + LocalisationCache append implicit English for MESSAGES;
    # languageinfo exposes the original STRICT list. Order is significant.
    chain = list(fallbacks[normalized])
    if normalized != 'en' and (not chain or chain[-1] != 'en'):
        chain.append('en')
    raw = {}
    for locale in reversed([normalized, *chain]):
        # Absence is proved by the complete pinned source catalog. CLDR's
        # loadLanguage explicitly returns [] for a locale with no source file.
        raw.update(tables.get(locale, {}))
    expected_keys = set(tables['en']) | set(mw)
    if set(single) != expected_keys or not set(raw) <= expected_keys:
        raise ValueError('Complete API enumeration differs from source key universe')
    # API siteinfo gives raw MW keys/values, including configured extra names
    # and the special native-name overwrite for the display language itself.
    raw.update(mw)
    for language, observed in single.items():
        if raw.get(aliases.get(language, language), '') != observed:
            raise ValueError('API name differs from source/fallback derivation: ' + language)
    lookup = dict(single)
    for alias, target in aliases.items():
        lookup[alias] = raw.get(target, '')
    return {'all': raw, 'mw': dict(mw), 'single': lookup}


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
            result = parse_response(data, config['wiki'], config['content_language'], 'dir' in query['liprop'].split('|'), config['core'])
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


def reconstruct(config, batches, aliases, tables):
    profiles, directions, index, inventory = {}, {}, 0, None
    fallbacks = {}
    for display_index, display in enumerate(config['languages']):
        single, mw, continuation, seen = {}, None, {}, set()
        while True:
            if index >= len(batches):
                raise ValueError('Incomplete display-language profile')
            query, data = batches[index]
            expected = request_query(display, display_index == 0, continuation)
            if query != expected:
                raise ValueError('Reordered or unrequested capture query')
            rows, part_mw, part_dir, continuation = parse_response(data, config['wiki'], config['content_language'], display_index == 0, config['core'])
            if set(rows) & set(single) or len(single) + len(rows) > MAX_ROWS:
                raise ValueError('Duplicate or excessive continued name rows')
            if mw is not None and mw != part_mw:
                raise ValueError('MW language names changed during continuation')
            mw = part_mw
            single.update(rows)
            directions.update(part_dir)
            if display_index == 0:
                fallbacks.update({k: tuple(v['fallbacks']) for k, v in data['query']['languageinfo'].items()})
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
        profiles[display] = finish_profile(single, mw, aliases, tables, display, fallbacks)
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
    core = core_revision(getattr(args, 'core', CORE))
    namespace = evidence.small(args.namespace_registry)
    content_language = namespace_identity(namespace, args.wiki, args.date)
    languages = sorted(set(args.languages or [content_language, 'en']))
    if not 1 <= len(languages) <= MAX_PROFILES or any(not code(v) for v in languages):
        raise ValueError('Invalid or excessive explicit display-language profiles')
    sources, aliases, tables = primary_contract(args.primary_sources)
    extra = sorted(set(getattr(args, 'extra_direction_codes', [])))
    direction_sources, derived = extra_direction_contract(
        getattr(args, 'direction_primary_sources', None), extra, aliases, core=core)
    root = args.output
    root.mkdir(parents=True, exist_ok=False)
    identity = producer()
    try:
        evidence.put(root / (PREFIX + 'namespace-registry.tsv'), namespace)
        for name, raw in sources.items():
            evidence.put(root / (PREFIX + 'source-' + name), raw)
        for name, raw in direction_sources.items():
            evidence.put(root / (PREFIX + 'direction-source-' + name), raw)
        config = {'wiki': args.wiki, 'date': args.date, 'content_language': content_language,
                  'languages': languages, 'namespace_registry_sha256': evidence.digest(namespace),
                  'scope': 'explicit-display-mw-all-single-and-enumerated-directions', 'core': core}
        if extra:
            config.update(extra_direction_codes=extra, direction_profile=DIRECTION_PROFILE)
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
        profiles, directions = reconstruct(config, batches, aliases, tables)
        directions = merge_extra_directions(directions, derived)
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
                    'source_derived_directions': derived,
                    'direction_provenance': direction_provenance(derived),
                    'direction_source_profile_scope': 'immutable-public-source-profile-not-deployment-observation' if derived else None,
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
    core = core_revision(config.get('core'))
    extra = direction_config(config)
    if extra:
        expected_keys |= {'extra_direction_codes', 'direction_profile'}
    if (set(config) != expected_keys
            or config['scope'] != 'explicit-display-mw-all-single-and-enumerated-directions'
            or not isinstance(config['languages'], list) or not config['languages']
            or config['languages'] != sorted(set(config['languages']))
            or len(config['languages']) > MAX_PROFILES
            or any(not code(v) for v in config['languages'])
            or any(manifest.get(k) != v for k, v in config.items())):
        raise ValueError('Unreviewed requested profile inventory')
    namespace = evidence.small(root / (PREFIX + 'namespace-registry.tsv'))
    if (namespace_identity(namespace, config['wiki'], config['date']) != config['content_language']
            or evidence.digest(namespace) != config['namespace_registry_sha256']):
        raise ValueError('Pinned namespace differs from capture')
    inventory = payload(root)
    if inventory != manifest['artifacts']:
        raise ValueError('Capture evidence inventory differs')
    _, aliases, tables = primary_contract(root, PREFIX + 'source-')
    _, derived = extra_direction_contract(root, extra, aliases, PREFIX + 'direction-source-', core)
    if (manifest.get('source_derived_directions') != derived
            or manifest.get('direction_provenance') != direction_provenance(derived)
            or manifest.get('direction_source_profile_scope') != ('immutable-public-source-profile-not-deployment-observation' if derived else None)):
        raise ValueError('Direction provenance or source-derived rows differ')
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
    profiles, directions = reconstruct(config, batches, aliases, tables)
    directions = merge_extra_directions(directions, derived)
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
    collect.add_argument('--core', choices=sorted(CORE_TREE_SHA256), default=CORE,
                         help='Exact reviewed API core revision for this complete capture')
    collect.add_argument('--extra-direction-codes', nargs='+', default=[])
    collect.add_argument('--direction-primary-sources', type=Path)
    collect.add_argument('--delay', type=float, default=1)
    collect.add_argument('--wall-seconds', type=int, default=600)
    args = parser.parse_args()
    if args.command == 'capture' and args.delay < 1:
        parser.error('Network captures require at least one second between requests')
    manifest = capture(args) if args.command == 'capture' else verify(args.output)
    print(json.dumps({key: manifest[key] for key in ('wiki', 'date', 'profiles', 'direction_rows', 'output_sha256')}))


if __name__ == '__main__':
    main()
