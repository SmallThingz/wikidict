#!/usr/bin/env python3
"""Add genuine null-display autonyms while retaining and replaying old captures."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import tempfile
import time
import urllib.parse

import prepare_file_metadata as evidence
import prepare_language_names as legacy

SCHEMA = 'wikidict.language-names-autonym-capture.v1'
OBSERVATION_SCHEMA = 'wikidict.language-autonym-observation.v1'
DIRECTORY = 'language-names-autonyms-v1'
KIND = 'language-names'
PREFIX = 'language-autonyms.'
COMPLETE = 'language-names.complete.json'
MAX_MANIFEST = 256 * 1024
MAX_RESPONSE = 2 * 1024 * 1024
MAX_ROWS = 20000
MAX_PREVIOUS_BYTES = 64 * 1024 * 1024
CORE = '18344669b5e5bd97a08905f87d4317edc7411396'
LEGACY_GENERATOR_SHA256 = 'ee28f69fab94d1e24e4ba17914ea024a77054206477da93aaf7e5534d4c65419'
SOURCE_PATHS = {
    'ApiQueryLanguageinfo.php': 'includes/Api/ApiQueryLanguageinfo.php',
    'ApiQuerySiteinfo.php': 'includes/Api/ApiQuerySiteinfo.php',
    'LanguageNameUtils.php': 'includes/Language/LanguageNameUtils.php',
    'LanguageCode.php': 'includes/Language/LanguageCode.php',
    'Names.php': 'includes/Languages/Data/Names.php',
}
SOURCE_PINS = {
    'ApiQueryLanguageinfo.php': '3f37142b0d676c68b1cac50fd510ac039ff52de186388b92083428e445fe3e96',
    'ApiQuerySiteinfo.php': 'a318da6f2cae4275a15595a93aa324bcbeb433381b29bd356fc577f72d5c2ced',
    'LanguageNameUtils.php': '5f55c8ed75da5dfee8f708a3c620b5f17dbe33396e99882175cb92f4828ba8f8',
    'LanguageCode.php': '17962f89468aa25369f126cc7a4edd8c074cb73497c8d4de77e8cbb04858d60d',
    'Names.php': '0b0c62791924c139d7d476530c2ad9a58d053c0f34e1195595b0c2e43776b11f',
}
DEPENDENCIES = {
    'prepare_language_names.py': 'e65eeb33bd1986bd4ffd09a35748206207471134fd6ea8c0ebb878810fdb0fed',
    'prepare_language_names_generic.py': 'e76d9a80f6c5ab32df2ddd596f3b383f2dc604f75eb469fc65ca5006f3a19f03',
    'prepare_language_names_translate.py': '45935d70e31651e8c3c51c0fa6eddb7cd2cf86e21193cc0f1f55ad1f16510281',
    'prepare_file_metadata.py': 'd2a09c741c3fb12ee1a59ea5ce6eeb9611105ffa782d90ca25d3a7b37acf23ab',
    'download_wiktionaries.py': '061472228c81890c4eecc670ea643c8793cb5928cde7854fa4896f5c3c3b29d2',
}


def producer():
    for name, expected in DEPENDENCIES.items():
        if evidence.digest(evidence.small(Path(evidence.__file__).with_name(name))) != expected:
            raise ValueError('Autonym dependency changed: ' + name)
    return dict(generator_sha256=evidence.digest(evidence.small(Path(__file__))),
                dependency_sha256=DEPENDENCIES)


def regular(path, maximum=4 * 1024 * 1024):
    path = Path(path)
    before = path.lstat()
    if path.is_symlink() or not path.is_file() or before.st_size > maximum:
        raise ValueError('Unsafe or excessive autonym artifact')
    with path.open('rb') as stream:
        raw = stream.read(before.st_size + 1)
    after = path.lstat()
    fields = lambda value: (value.st_dev, value.st_ino, value.st_size, value.st_mtime_ns, value.st_ctime_ns)
    if fields(before) != fields(after) or len(raw) != before.st_size:
        raise ValueError('Autonym artifact changed during read')
    return raw


def safe_name(value):
    if not isinstance(value, str) or Path(value).name != value or value in ('.', '..') or len(value) > 240 or '\0' in value:
        raise ValueError('Unsafe artifact name')
    return value


def inventory(root):
    result = {}
    for path in Path(root).iterdir():
        if path.name in (COMPLETE, KIND + '.manifest.json'):
            continue
        if not path.name.startswith(('language-names.', PREFIX, 'previous.')):
            raise ValueError('Unexpected capture artifact: ' + path.name)
        raw = regular(path)
        result[path.name] = dict(size=len(raw), sha256=evidence.digest(raw))
    return dict(sorted(result.items()))


def query(continuation):
    return dict(action='query', format='json', formatversion='2',
                meta='siteinfo|languageinfo', siprop='general|languages',
                uselang='en', licode='*', liprop='code|autonym', maxlag='5', **continuation)


def parse_response(data, wiki, content, core=CORE):
    if not isinstance(data, dict) or any(key in data for key in ('error', 'errors', 'warnings')):
        raise ValueError('Unsuccessful autonym response')
    q = data.get('query')
    general = q.get('general') if isinstance(q, dict) else None
    if not isinstance(core, str) or not re.fullmatch('[0-9a-f]{40}', core) or not isinstance(general, dict) or (
            general.get('wikiid'), general.get('lang'), general.get('git-hash')) != (wiki, content, core):
        raise ValueError('Exact API wiki/content/core identity changed')
    rows, mw_rows = q.get('languageinfo'), q.get('languages')
    if not isinstance(rows, dict) or not 1 <= len(rows) <= MAX_ROWS or not isinstance(mw_rows, list) or not 1 <= len(mw_rows) <= MAX_ROWS:
        raise ValueError('Incomplete autonym universe')
    names, mw = {}, {}
    for code, row in rows.items():
        if not legacy.code(code) or not isinstance(row, dict) or row.get('code') != code:
            raise ValueError('Invalid autonym code')
        name = row.get('autonym')
        if not isinstance(name, str) or len(name.encode()) > 4096 or '\0' in name:
            raise ValueError('Invalid genuine autonym')
        names[code] = name
    for row in mw_rows:
        if not isinstance(row, dict) or not legacy.code(row.get('code')) or row['code'] in mw or not legacy.text(row.get('name')):
            raise ValueError('Invalid MW code inventory')
        mw[row['code']] = row['name']  # Values are never used as autonyms.
    continuation = data.get('continue', {})
    if not isinstance(continuation, dict) or continuation and (
            set(continuation) != {'continue', 'licontinue'} or
            any(not isinstance(v, str) or not 1 <= len(v) <= 128 for v in continuation.values())):
        raise ValueError('Invalid continuation')
    return names, mw, {}, continuation


def source_aliases(root):
    sources = {}
    for name, expected in SOURCE_PINS.items():
        raw = regular(Path(root) / (PREFIX + 'source-' + name))
        if evidence.digest(raw) != expected:
            raise ValueError('Unreviewed autonym source: ' + name)
        sources[name] = raw
    source = sources['LanguageCode.php'].decode()
    def mapping(name):
        block = source.split('private const ' + name + ' = [', 1)[1].split('\n\t];', 1)[0]
        return dict(re.findall(r"'([^']+)'\s*=>\s*'([^']+)'", block))
    deprecated = mapping('DEPRECATED_LANGUAGE_CODE_MAPPING')
    aliases = {external.lower(): internal for internal, external in mapping('NON_STANDARD_LANGUAGE_CODE_MAPPING').items()}
    aliases.update(deprecated)
    block = sources['Names.php'].decode().split('public const NAMES = [', 1)[1].split('\n\t];', 1)[0]
    builtin_codes = re.findall(r"^\s*'([^']+)'\s*=>", block, re.MULTILINE)
    if not builtin_codes or len(builtin_codes) != len(set(builtin_codes)) or any(not legacy.code(code) for code in builtin_codes):
        raise ValueError('Invalid pinned built-in language code inventory')
    # LanguageNameUtils may omit the testing language; configured extras are allowed.
    required_builtin_codes = set(builtin_codes) - {'en-x-piglatin'}
    return {key: deprecated.get(value, value) for key, value in aliases.items()}, required_builtin_codes


def finish(names, mw, aliases, required_builtin_codes):
    if not required_builtin_codes <= set(mw):
        raise ValueError('Incomplete built-in MW inventory')
    if not set(mw) <= set(names):
        raise ValueError('Incomplete MW inventory')
    for code, name in names.items():
        target = aliases.get(code, code)
        if name and target not in mw:
            raise ValueError('Positive autonym outside normalized MW inventory')
        if target in names and names[target] != name:
            raise ValueError('Observed alias differs from normalized target')
    single = dict(names)
    for alias, target in aliases.items():
        if target in mw and target not in names:
            raise ValueError('Missing alias target')
        single[alias] = names.get(target, '')
    return single


def render_profile(single):
    return ('C\t-\tsingle\t' + str(len(single)) + '\n' +
            ''.join('N\t-\tsingle\t' + code + '\t' + legacy.escaped(name) + '\n'
                    for code, name in sorted(single.items()))).encode()



def accepted_producer(record):
    current = producer()
    return (record.get('dependency_sha256') == current['dependency_sha256'] and
            (record.get('generator_sha256') == current['generator_sha256'] or
             record.get('generator_sha256') == LEGACY_GENERATOR_SHA256 and record.get('core', record.get('config', {}).get('core')) == CORE))


def validate_source_contract(root, core):
    """Authenticate the fixed five-file API contract at its observed revision."""
    root = Path(root)
    if not isinstance(core, str) or not re.fullmatch('[0-9a-f]{40}', core):
        raise ValueError('Invalid observed core revision')
    aliases = source_aliases(root)
    comparison_path = root / (PREFIX + 'source-comparison.json')
    if not comparison_path.exists():
        if core != CORE:
            raise ValueError('Observed core requires exact source comparison')
        return aliases
    comparison = evidence.decode(regular(comparison_path, MAX_MANIFEST))
    if (comparison.get('schema') != 'wikidict.observed-core-source-comparison.v1' or
            comparison.get('outcome') != 'completed-source-comparison' or
            comparison.get('core') != core or comparison.get('all_five_byte_identical') is not True or
            comparison.get('source_requests') != len(SOURCE_PINS) or comparison.get('api_requests') != 0 or
            not isinstance(comparison.get('previous_core'), str) or
            not re.fullmatch('[0-9a-f]{40}', comparison['previous_core'])):
        raise ValueError('Source comparison identity differs')
    rows = comparison.get('files')
    if not isinstance(rows, list) or len(rows) != len(SOURCE_PINS):
        raise ValueError('Incomplete compared source set')
    seen = set()
    for row in rows:
        if not isinstance(row, dict):
            raise ValueError('Invalid compared source row')
        name = row.get('url', '').rsplit('/', 1)[-1]
        if name in seen or name not in SOURCE_PINS:
            raise ValueError('Duplicate or unreviewed compared source')
        raw = regular(root / (PREFIX + 'source-' + name))
        expected_url = 'https://raw.githubusercontent.com/wikimedia/mediawiki/' + core + '/' + SOURCE_PATHS[name]
        if (row.get('url') != expected_url or row.get('status') != 200 or row.get('core') != core or
                row.get('bytes') != len(raw) or row.get('sha256') != SOURCE_PINS[name] or
                row.get('previous_sha256') != SOURCE_PINS[name] or row.get('byte_identical_to_previous') is not True):
            raise ValueError('Changed compared source')
        seen.add(name)
    if seen != set(SOURCE_PINS):
        raise ValueError('Incomplete compared source set')
    return aliases


def accepted_receipt(root, record, receipt, core=CORE):
    if receipt.get('accepted') is True:
        if set(record) != {'request', 'accepted_receipt'}:
            raise ValueError('Unexpected normal observation record')
        return
    if set(record) != {'request', 'accepted_receipt', 'offline_revalidation'} or receipt.get('accepted') is not False or receipt.get('error') != 'Exact API wiki/content/core identity changed':
        raise ValueError('Unaccepted autonym response')
    root = Path(root)
    proof = evidence.decode(regular(root / safe_name(record['offline_revalidation']), MAX_MANIFEST))
    receipt_raw = regular(root / safe_name(record['accepted_receipt']), MAX_MANIFEST)
    comparison_raw = regular(root / (PREFIX + 'source-comparison.json'), MAX_MANIFEST)
    comparison = evidence.decode(comparison_raw)
    if proof.get('schema') == 'wikidict.autonym-old-core-revalidation.v1':
        expected = dict(schema='wikidict.autonym-old-core-revalidation.v1',
                        original_receipt_sha256=evidence.digest(receipt_raw),
                        source_comparison_sha256=evidence.digest(comparison_raw),
                        previous_core='0d3b507d19ae860ed8a1d22c73fa4bc5abf8dfcc', core=CORE,
                        original_receipt_accepted=False)
        if core != CORE:
            raise ValueError('Legacy revalidation core differs')
    else:
        requested_raw = regular(root / (PREFIX + 'original-requested.json'), MAX_MANIFEST)
        requested = evidence.decode(requested_raw)
        expected = dict(schema='wikidict.autonym-core-revalidation.v2',
                        original_receipt_sha256=evidence.digest(receipt_raw),
                        original_requested_sha256=evidence.digest(requested_raw),
                        source_comparison_sha256=evidence.digest(comparison_raw),
                        previous_core=requested.get('core'), core=core, original_receipt_accepted=False)
    if proof != expected or comparison.get('previous_core') != proof['previous_core']:
        raise ValueError('Invalid retained-core revalidation')
    validate_source_contract(root, core)


def adopt_observation(wiki, date, saved, sources, comparison, output):
    """Keep the failed request/receipt/body unchanged and revalidate offline."""
    saved, sources, output = map(Path, (saved, sources, output))
    output.mkdir(parents=True, exist_ok=False)
    prefixes = [prefix for prefix in ('language-names.', PREFIX) if (saved / (prefix + 'namespace-registry.tsv')).exists()]
    if len(prefixes) != 1:
        raise ValueError('Ambiguous retained observation layout')
    prefix = prefixes[0]
    namespace = regular(saved / (prefix + 'namespace-registry.tsv'))
    content = legacy.namespace_identity(namespace, wiki, date)
    requested_raw = regular(saved / (prefix + 'requested.json'), MAX_MANIFEST)
    requested = evidence.decode(requested_raw)
    comparison_raw = regular(comparison, MAX_MANIFEST)
    compared = evidence.decode(comparison_raw)
    core = compared.get('core')
    config = dict(wiki=wiki, date=date, content_language=content, core=core,
                  namespace_registry_sha256=evidence.digest(namespace))
    if any(requested.get(k) != v for k, v in config.items() if k != 'core') or requested.get('core') != compared.get('previous_core'):
        raise ValueError('Original requested identity differs')
    evidence.document(output / (PREFIX + 'requested.json'), config)
    evidence.put(output / (PREFIX + 'original-requested.json'), requested_raw)
    evidence.put(output / (PREFIX + 'namespace-registry.tsv'), namespace)
    for name, expected in SOURCE_PINS.items():
        raw = regular(sources / name)
        if evidence.digest(raw) != expected:
            raise ValueError('Unreviewed adoption source')
        evidence.put(output / (PREFIX + 'source-' + name), raw)
    evidence.put(output / (PREFIX + 'source-comparison.json'), comparison_raw)
    validate_source_contract(output, core)
    request_name = prefix + '0001.request.json'
    receipt_name = prefix + '0001-01.receipt.json'
    receipt_raw = regular(saved / receipt_name, MAX_MANIFEST)
    receipt = evidence.decode(receipt_raw)
    if receipt.get('request') != request_name or receipt.get('response') != prefix + '0001-01.raw.json':
        raise ValueError('Unexpected retained observation layout')
    for name in (request_name, receipt_name, receipt['response']):
        evidence.put(output / name, regular(saved / name))
    revalidation_name = PREFIX + 'offline-revalidation.json'
    evidence.document(output / revalidation_name, dict(schema='wikidict.autonym-core-revalidation.v2',
        original_receipt_sha256=evidence.digest(receipt_raw), original_requested_sha256=evidence.digest(requested_raw),
        source_comparison_sha256=evidence.digest(comparison_raw),
        previous_core=requested['core'], core=core, original_receipt_accepted=False))
    observation = dict(schema=OBSERVATION_SCHEMA, config=config, requests=[
        dict(request=request_name, accepted_receipt=receipt_name, offline_revalidation=revalidation_name)],
        retrieved_utc=receipt['ended_utc'], offline_derived_utc=evidence.utc(), **producer())
    names, single = replay_observation(output, observation)
    observation.update(observed_codes=len(names), observed_positive=sum(bool(v) for v in names.values()),
        observed_empty=sum(not v for v in names.values()), singular_codes=len(single),
        singular_positive=sum(bool(v) for v in single.values()), singular_empty=sum(not v for v in single.values()))
    evidence.document(output / (PREFIX + 'observation.json'), observation)
    return observation


def replay_observation(root, observation):
    config = observation['config']
    if set(config) != {'wiki', 'date', 'content_language', 'core', 'namespace_registry_sha256'}:
        raise ValueError('Invalid autonym configuration')
    aliases = validate_source_contract(root, config['core'])
    namespace = regular(Path(root) / (PREFIX + 'namespace-registry.tsv'))
    if legacy.namespace_identity(namespace, config['wiki'], config['date']) != config['content_language'] or evidence.digest(namespace) != config['namespace_registry_sha256']:
        raise ValueError('Autonym namespace identity differs')
    records = observation.get('requests')
    if not isinstance(records, list) or not 1 <= len(records) <= 128:
        raise ValueError('Invalid autonym request inventory')
    names, mw, continuation, seen = {}, None, {}, set()
    for record in records:
        request = evidence.decode(regular(Path(root) / safe_name(record['request']), MAX_MANIFEST))
        receipt = evidence.decode(regular(Path(root) / safe_name(record['accepted_receipt']), MAX_MANIFEST))
        if request['query'] != query(continuation) or request['url'] != evidence.wiktionary_api(config['wiki']) + '?' + urllib.parse.urlencode(sorted(request['query'].items())):
            raise ValueError('Unrequested autonym query')
        raw = regular(Path(root) / safe_name(receipt['response']), MAX_RESPONSE)
        accepted_receipt(root, record, receipt, config['core'])
        if receipt.get('status') != 200 or receipt.get('request') != record['request'] or receipt.get('response_bytes') != len(raw) or receipt.get('response_sha256') != evidence.digest(raw):
            raise ValueError('Unaccepted or changed autonym HTTP evidence')
        part, current, _, continuation = parse_response(evidence.decode(raw), config['wiki'], config['content_language'], config['core'])
        if set(part) & set(names) or len(names) + len(part) > MAX_ROWS or mw is not None and current != mw:
            raise ValueError('Duplicate/changed autonym universe')
        names.update(part); mw = current
        if continuation:
            token = tuple(sorted(continuation.items()))
            if token in seen:
                raise ValueError('Repeated continuation')
            seen.add(token)
        elif record is not records[-1]:
            raise ValueError('Excess autonym responses')
    if continuation:
        raise ValueError('Incomplete continuation')
    return names, finish(names, mw, *aliases)


def capture_observation(wiki, date, namespace_path, sources, output, wall_seconds=90, transport=None, sleep=time.sleep):
    if not 1 <= wall_seconds <= 120:
        raise ValueError('Invalid capture deadline')
    evidence.wiktionary_api(wiki)
    namespace = regular(namespace_path)
    content = legacy.namespace_identity(namespace, wiki, date)
    output = Path(output); output.mkdir(parents=True, exist_ok=False)
    comparison_path = Path(sources) / 'comparison.json'
    comparison_raw = regular(comparison_path, MAX_MANIFEST) if comparison_path.exists() else None
    core = evidence.decode(comparison_raw).get('core') if comparison_raw is not None else CORE
    config = dict(wiki=wiki, date=date, content_language=content, core=core,
                  namespace_registry_sha256=evidence.digest(namespace))
    evidence.document(output / (PREFIX + 'requested.json'), config)
    evidence.put(output / (PREFIX + 'namespace-registry.tsv'), namespace)
    for name, expected in SOURCE_PINS.items():
        raw = regular(Path(sources) / name)
        if evidence.digest(raw) != expected:
            raise ValueError('Unreviewed capture source')
        evidence.put(output / (PREFIX + 'source-' + name), raw)
    if comparison_raw is not None:
        evidence.put(output / (PREFIX + 'source-comparison.json'), comparison_raw)
    validate_source_contract(output, core)
    # Isolated existing transport/retry implementation; no shared-module mutation.
    path = Path(legacy.__file__)
    spec = importlib.util.spec_from_file_location('_autonym_transport', path)
    runner = importlib.util.module_from_spec(spec); spec.loader.exec_module(runner)
    runner.PREFIX = PREFIX
    runner.parse_response = lambda data, wiki, content, include_dir: parse_response(data, wiki, content, core)
    deadline = time.monotonic() + wall_seconds
    records, continuation, seen = [], {}, set()
    try:
        while True:
            parsed, record = runner.observe(output, len(records) + 1, query(continuation),
                                            transport or evidence.get_response, sleep, 1, deadline)
            records.append(record); continuation = parsed[3]
            if not continuation:
                break
            token = tuple(sorted(continuation.items()))
            if token in seen:
                raise ValueError('Repeated continuation')
            seen.add(token)
        observation = dict(schema=OBSERVATION_SCHEMA, config=config, requests=records,
                           retrieved_utc=evidence.utc(), **producer())
        names, single = replay_observation(output, observation)
        observation.update(observed_codes=len(names), observed_positive=sum(bool(v) for v in names.values()),
                           observed_empty=sum(not v for v in names.values()), singular_codes=len(single),
                           singular_positive=sum(bool(v) for v in single.values()),
                           singular_empty=sum(not v for v in single.values()))
        evidence.document(output / (PREFIX + 'observation.json'), observation)
        return observation
    except BaseException as error:
        evidence.document(output / (PREFIX + 'failure.json'), dict(error=str(error), ended_utc=evidence.utc()))
        raise


def previous_helper(schema):
    if schema == 'wikidict.language-names-capture.v1':
        return legacy
    if schema == 'wikidict.language-names-capture.v2':
        import prepare_language_names_generic
        return prepare_language_names_generic
    if schema == 'wikidict.language-names-translate-capture.v1':
        import prepare_language_names_translate
        return prepare_language_names_translate
    raise ValueError('Unreviewed previous language-name schema')


def replay_previous(root, manifest):
    """Recreate only this bounded, embedded old family for its unchanged validator."""
    previous = manifest['previous']
    if not isinstance(previous, dict) or not 1 <= len(previous) <= 512:
        raise ValueError('Invalid previous artifact inventory')
    total = 0
    with tempfile.TemporaryDirectory(prefix='wikidict-autonyms-previous-') as temp:
        temp = Path(temp)
        for name, identity in previous.items():
            if Path(name).name != name or name in ('.', '..'):
                raise ValueError('Unsafe previous artifact name')
            raw = regular(Path(root) / ('previous.' + name))
            total += len(raw)
            if total > MAX_PREVIOUS_BYTES or identity != dict(size=len(raw), sha256=evidence.digest(raw)):
                raise ValueError('Previous evidence changed or excessive')
            (temp / name).write_bytes(raw)
        old_raw = regular(temp / (KIND + '.manifest.json'), MAX_MANIFEST)
        old = evidence.decode(old_raw)
        validated = previous_helper(old.get('schema')).validate_snapshot(temp / (KIND + '.tsv'), manifest['wiki'], manifest['date'])
        if old != validated:
            raise ValueError('Previous capture changed')
        return regular(temp / (KIND + '.tsv')), old


def augment(previous, observation_root, output):
    previous, observation_root, output = map(Path, (previous, observation_root, output))
    old_manifest = evidence.decode(regular(previous / (KIND + '.manifest.json'), MAX_MANIFEST))
    old = previous_helper(old_manifest.get('schema')).validate_snapshot(previous / (KIND + '.tsv'))
    observation = evidence.decode(regular(observation_root / (PREFIX + 'observation.json'), MAX_MANIFEST))
    if observation.get('schema') != OBSERVATION_SCHEMA or not accepted_producer(observation):
        raise ValueError('Unreviewed observation producer')
    names, single = replay_observation(observation_root, observation)
    config = observation['config']
    if any(old.get(k) != config[k] for k in ('wiki', 'date', 'content_language')):
        raise ValueError('Previous and autonym identities differ')
    output.mkdir(parents=True, exist_ok=False)
    previous_files = set(old['artifacts']) | {KIND + '.manifest.json', COMPLETE}
    previous_inventory = {}
    for name in sorted(previous_files):
        raw = regular(previous / name)
        previous_inventory[name] = dict(size=len(raw), sha256=evidence.digest(raw))
        evidence.put(output / ('previous.' + name), raw)
    for path in observation_root.iterdir():
        if not path.name.startswith((PREFIX, 'language-names.')):
            raise ValueError('Unexpected observation file')
        evidence.put(output / path.name, regular(path))
    old_tsv = regular(previous / (KIND + '.tsv'))
    if not old_tsv.endswith(b'\n') or b'\nC\t-\tsingle\t' in old_tsv:
        raise ValueError('Old capture already has a null profile')
    candidate = old_tsv + render_profile(single)
    evidence.put(output / (KIND + '.tsv'), candidate)
    manifest = dict(schema=SCHEMA, kind=KIND, header_version=1, **config, **producer(),
                    previous=previous_inventory, observation=PREFIX + 'observation.json',
                    old_output_sha256=evidence.digest(old_tsv), output_bytes=len(candidate),
                    output_sha256=evidence.digest(candidate), singular_codes=len(single),
                    singular_positive=sum(bool(v) for v in single.values()),
                    singular_empty=sum(not v for v in single.values()),
                    native_resolution_proven=False, corpus_query_closure_proven=False,
                    temporal_scope='current-api-observation', artifacts=inventory(output))
    evidence.document(output / (KIND + '.manifest.json'), manifest)
    validate_snapshot(output / (KIND + '.tsv'), require_complete=False)
    evidence.document(output / COMPLETE, dict(schema=SCHEMA, manifest_sha256=evidence.digest(regular(output / (KIND + '.manifest.json')))))
    return validate_snapshot(output / (KIND + '.tsv'))


def validate_snapshot(path, wiki=None, date=None, require_complete=True):
    path = Path(path); root = path.parent
    if path.name != KIND + '.tsv' or root.is_symlink() or not root.is_dir():
        raise ValueError('Unsafe autonym capture')
    raw = regular(root / (KIND + '.manifest.json'), MAX_MANIFEST)
    manifest = evidence.decode(raw)
    if (manifest.get('schema') != SCHEMA or manifest.get('kind') != KIND or manifest.get('header_version') != 1 or manifest.get('native_resolution_proven') is not False or manifest.get('corpus_query_closure_proven') is not False or manifest.get('temporal_scope') != 'current-api-observation' or manifest.get('observation') != PREFIX + 'observation.json' or not accepted_producer(manifest)):
        raise ValueError('Unreviewed autonym capture')
    if (wiki is not None and manifest['wiki'] != wiki or date is not None and manifest['date'] != date):
        raise ValueError('Autonym edition/date mismatch')
    if require_complete and evidence.decode(regular(root / COMPLETE, MAX_MANIFEST)) != dict(schema=SCHEMA, manifest_sha256=evidence.digest(raw)):
        raise ValueError('Autonym completion mismatch')
    if manifest.get('artifacts') != inventory(root):
        raise ValueError('Autonym artifact inventory differs')
    old_tsv, old = replay_previous(root, manifest)
    observation = evidence.decode(regular(root / manifest['observation'], MAX_MANIFEST))
    if observation.get('schema') != OBSERVATION_SCHEMA or not accepted_producer(observation):
        raise ValueError('Unreviewed observation')
    config = observation['config']
    if any(manifest.get(k) != v for k, v in config.items()) or any(old.get(k) != config[k] for k in ('wiki', 'date', 'content_language')):
        raise ValueError('Autonym identities differ')
    names, single = replay_observation(root, observation)
    counts = dict(observed_codes=len(names), observed_positive=sum(bool(v) for v in names.values()), observed_empty=sum(not v for v in names.values()), singular_codes=len(single), singular_positive=sum(bool(v) for v in single.values()), singular_empty=sum(not v for v in single.values()))
    if any(observation.get(k) != v for k, v in counts.items()):
        raise ValueError('Observation counts differ')
    expected = old_tsv + render_profile(single)
    if b'\nC\t-\tsingle\t' in old_tsv or regular(path) != expected or manifest.get('old_output_sha256') != evidence.digest(old_tsv) or manifest.get('output_bytes') != len(expected) or manifest.get('output_sha256') != evidence.digest(expected) or manifest.get('singular_codes') != len(single) or manifest.get('singular_positive') != sum(bool(v) for v in single.values()) or manifest.get('singular_empty') != sum(not v for v in single.values()):
        raise ValueError('Autonym projection differs from exact replay')
    return manifest


def capture_artifacts(path, manifest=None):
    validated = validate_snapshot(path)
    if manifest is not None and manifest != validated:
        raise ValueError('Autonym capture changed')
    result = {name: row['sha256'] for name, row in validated['artifacts'].items()}
    for name in (COMPLETE, KIND + '.manifest.json'):
        result[name] = evidence.digest(regular(Path(path).parent / name, MAX_MANIFEST))
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    capture = commands.add_parser('capture')
    for key in ('wiki', 'date'):
        capture.add_argument('--' + key, required=True)
    for key in ('namespace-registry', 'sources', 'output'):
        capture.add_argument('--' + key, type=Path, required=True)
    capture.add_argument('--wall-seconds', type=int, default=90)
    derive = commands.add_parser('augment')
    for key in ('previous', 'observation', 'output'):
        derive.add_argument('--' + key, type=Path, required=True)
    verify = commands.add_parser('verify'); verify.add_argument('path', type=Path)
    args = parser.parse_args()
    if args.command == 'capture':
        value = capture_observation(args.wiki, args.date, args.namespace_registry, args.sources, args.output, args.wall_seconds)
    elif args.command == 'augment':
        value = augment(args.previous, args.observation, args.output)
    else:
        value = validate_snapshot(args.path)
    print(json.dumps(value, ensure_ascii=False))


if __name__ == '__main__':
    main()
