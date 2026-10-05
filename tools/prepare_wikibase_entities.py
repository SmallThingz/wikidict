#!/usr/bin/env python3
"""Capture bounded, immutable Wikibase entities and edition-default term results.

A dump date selects the consumer corpus; entity data is a current API observation.
Raw responses are retained verbatim. Verification and reuse never access the API.
"""
import argparse
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import re
import time
import urllib.error
import urllib.parse
import urllib.request

from prepare_magic_words import identity, language, namespace_input, timestamp

NAMES = ('wikibase-entities', 'wikibase-entity-terms')
PROFILES = dict(zip(NAMES, ('complete-entities-v1', 'resolved-default-terms-v1')))
REPOSITORY = 'https://www.wikidata.org'
ENDPOINT = REPOSITORY + '/w/api.php'
DIRECTORY = 'wikibase-entities'
MAX_ENTITIES = 32768
MAX_RESPONSE_BYTES = 32 * 1024 * 1024
MAX_ENTITY_BYTES = 4 * 1024 * 1024
MAX_TOTAL_RAW_BYTES = 512 * 1024 * 1024
MAX_OUTPUT_BYTES = 512 * 1024 * 1024
MAX_PROOF_BYTES = 32 * 1024 * 1024
MAX_SECONDS = 3600
BATCH_SIZE = 50
AGENT = 'Wikidict/1.0 (https://github.com/SmallThingz/wikidict)'
CLOSURE_PROPERTIES = ('P5920', 'P9295')
BASE_ARTIFACTS = frozenset(('wikibase-seeds.json', 'wikibase-dependencies.json',
    'wikibase-namespace-siteinfo.raw.json', 'wikibase-namespace-capture.complete.json',
    'wikibase-entities.tsv', 'wikibase-entity-terms.tsv'))
META_FIELDS = frozenset(('pageid', 'ns', 'title', 'lastrevid', 'modified', 'redirects'))
ENTITY_ID = re.compile(r'(?:[QPL][1-9][0-9]*|L[1-9][0-9]*-[FS][1-9][0-9]*)')


def digest(raw):
    return hashlib.sha256(raw).hexdigest()


PRODUCER_SHA256 = digest(Path(__file__).read_bytes())


def document(value):
    return (json.dumps(value, ensure_ascii=False, sort_keys=True, indent=2, allow_nan=False) + '\n').encode()


def compact(value):
    # Entity member order is retained; getLemmas traverses the lemma map.
    return json.dumps(value, ensure_ascii=False, separators=(',', ':'), allow_nan=False)


def parse_json(raw):
    def unique(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError('Duplicate JSON key: ' + key)
            result[key] = value
        return result
    def invalid(value):
        raise ValueError('Non-finite JSON number: ' + value)
    try:
        return json.loads(raw, object_pairs_hook=unique, parse_constant=invalid)
    except (UnicodeError, RecursionError, json.JSONDecodeError) as exc:
        raise ValueError('Invalid capture JSON') from exc


def regular(path, limit=MAX_RESPONSE_BYTES):
    path = Path(path)
    if path.is_symlink() or not path.is_file() or path.stat().st_size > limit:
        raise ValueError('Missing, unsafe or oversized capture artifact: ' + str(path))
    with path.open('rb') as stream:
        raw = stream.read(limit + 1)
    if len(raw) > limit:
        raise ValueError('Oversized capture artifact')
    return raw


def valid_id(value):
    if not isinstance(value, str) or not ENTITY_ID.fullmatch(value):
        raise ValueError('Invalid Wikibase entity ID')
    return value


def seed_ids(proof, wiki, date):
    if not isinstance(proof, dict):
        raise ValueError('Invalid entity seed proof')
    if proof.get('schema') == 'wikidict-arabic-wikibase-direct-seed-audit-v1':
        source = proof.get('dump', {})
        if source.get('wiki') != wiki or source.get('date') != date or proof.get('dump_sha1_verified') is not True:
            raise ValueError('Seed proof differs from pinned dump identity')
        rows = proof.get('all_namespace_proofs')
        if not isinstance(rows, list):
            raise ValueError('Missing literal source proofs')
        selected = [row for row in rows if isinstance(row, dict) and row.get('namespace_id') == 0]
        for row in selected:
            if (not re.fullmatch(r'[0-9a-f]{64}', row.get('source_sha256', ''))
                    or not row.get('page_id') or not row.get('revision_id')
                    or row.get('entity_id') != row.get('argument')
                    or row['entity_id'] not in row.get('invocation', '')):
                raise ValueError('Incomplete literal source proof')
        ids = sorted({valid_id(row.get('entity_id')) for row in selected})
        if (proof.get('mainspace_entity_ids') != ids or proof.get('mainspace_entity_count') != len(ids)
                or proof.get('mainspace_invocation_count') != len(selected)):
            raise ValueError('Entity seed inventory differs from literal proofs')
    elif proof.get('schema') == 'wikidict-wikibase-seeds-v1':
        if proof.get('wiki') != wiki or proof.get('date') != date or not isinstance(proof.get('reason'), str) or not proof['reason'].strip():
            raise ValueError('Explicit seed identity or reason missing')
        ids = proof.get('ids')
        if not isinstance(ids, list) or ids != sorted(set(valid_id(value) for value in ids)):
            raise ValueError('Seed IDs must be unique and sorted')
    else:
        raise ValueError('Unknown entity seed proof schema')
    if not ids or len(ids) > MAX_ENTITIES:
        raise ValueError('Entity seed count exceeds bound')
    return ids


def validate_seed_source(proof, complete, wiki, date):
    ids = seed_ids(proof, wiki, date)
    if proof.get('schema') == 'wikidict-arabic-wikibase-direct-seed-audit-v1':
        fields = ('wiki', 'date', 'name', 'url', 'size', 'sha1')
        source = complete.get('source_xml')
        if not isinstance(source, dict) or any(source.get(key) != proof['dump'].get(key) for key in fields):
            raise ValueError('Literal seed source differs from namespace capture dump')
    return ids


def query_url(ids, mode, content_language):
    if not ids or len(ids) > BATCH_SIZE or len(set(ids)) != len(ids):
        raise ValueError('Invalid entity request batch')
    for entity_id in ids:
        valid_id(entity_id)
    params = dict(action='wbgetentities', format='json', formatversion='2',
                  ids='|'.join(ids), redirects='yes', maxlag='5')
    if mode == 'full':
        params['props'] = 'info|sitelinks|aliases|labels|descriptions|claims|datatype'
    elif mode == 'terms':
        params.update(props='info|labels|descriptions', languages=language(content_language), languagefallback='1')
    else:
        raise ValueError('Unknown entity request mode')
    return ENDPOINT + '?' + urllib.parse.urlencode(params)


def map_field(entity, key):
    value = entity.get(key, {})
    if value == []:
        return {}
    if not isinstance(value, dict):
        raise ValueError('Invalid entity map: ' + key)
    return value


def response_records(raw, ids, mode):
    if len(raw) > MAX_RESPONSE_BYTES:
        raise ValueError('Oversized entity response')
    data = parse_json(raw)
    if (not isinstance(data, dict) or data.get('success') != 1
            or any(key in data for key in ('error', 'errors', 'warnings', 'continue'))
            or not isinstance(data.get('entities'), dict) or set(data['entities']) != set(ids)):
        raise ValueError('Incomplete or unsuccessful Wikibase response')
    records = {}
    for requested, entity in data['entities'].items():
        if not isinstance(entity, dict):
            raise ValueError('Invalid entity record')
        if 'missing' in entity:
            if (entity.get('id') != requested or entity['missing'] not in ('', True)
                    or any(key in entity for key in ('claims', 'lemmas', 'labels', 'redirects'))):
                raise ValueError('Invalid explicit missing entity')
            records[requested] = None
            continue
        canonical = valid_id(entity.get('id'))
        redirect = entity.get('redirects')
        if canonical != requested:
            if redirect != {'from': requested, 'to': canonical}:
                raise ValueError('Entity redirect lacks exact source/target proof')
        elif redirect is not None:
            raise ValueError('Unexpected entity redirect annotation')
        if type(entity.get('lastrevid')) is not int or entity['lastrevid'] <= 0 or not isinstance(entity.get('modified'), str):
            raise ValueError('Missing entity revision provenance')
        try:
            dt.datetime.strptime(entity['modified'], '%Y-%m-%dT%H:%M:%SZ')
        except ValueError as exc:
            raise ValueError('Invalid entity revision time') from exc
        if mode == 'full':
            expected = ('form' if '-F' in canonical else 'sense' if '-S' in canonical else
                        {'Q': 'item', 'P': 'property', 'L': 'lexeme'}[canonical[0]])
            if entity.get('type') != expected:
                raise ValueError('Entity type does not match ID')
            for field in ('claims', 'labels', 'descriptions', 'aliases', 'sitelinks'):
                map_field(entity, field)
            if expected == 'lexeme':
                map_field(entity, 'lemmas')
                if not isinstance(entity.get('forms', []), list) or not isinstance(entity.get('senses', []), list):
                    raise ValueError('Invalid lexeme forms or senses')
        for field in ('labels', 'descriptions'):
            for key, term in map_field(entity, field).items():
                if (not isinstance(key, str) or not isinstance(term, dict)
                        or not isinstance(term.get('value'), str) or not isinstance(term.get('language'), str)
                        or not term['language']
                        or mode == 'full' and term['language'] != key
                        or 'source-language' in term and (not isinstance(term['source-language'], str) or not term['source-language'])):
                    raise ValueError('Invalid entity term')
        if len(compact(entity).encode()) > MAX_ENTITY_BYTES:
            raise ValueError('Entity record exceeds size bound')
        records[requested] = entity
    return records


def verify_request(receipt, raw, ids, mode, content_language):
    url = query_url(ids, mode, content_language)
    if not isinstance(receipt, dict) or receipt.get('source_url') != url or receipt.get('response_url') != url:
        raise ValueError('Unexpected Wikibase request or response URL')
    if (receipt.get('status') != 200 or receipt.get('raw_sha256') != digest(raw)
            or receipt.get('raw_bytes') != len(raw)
            or timestamp(receipt.get('started_utc')) > timestamp(receipt.get('retrieved_utc'))):
        raise ValueError('Invalid entity request receipt')


def dependency_rows(records, seeds):
    rows = []
    for seed in seeds:
        entity = records.get(seed)
        if entity is None:
            continue
        claims = map_field(entity, 'claims')
        for prop in CLOSURE_PROPERTIES:
            statements = claims.get(prop, [])
            if not isinstance(statements, list):
                raise ValueError('Invalid source statement list')
            for index, statement in enumerate(statements):
                if not isinstance(statement, dict) or not isinstance(statement.get('mainsnak'), dict):
                    raise ValueError('Invalid source statement')
                snak = statement['mainsnak']
                if snak.get('snaktype') in ('novalue', 'somevalue'):
                    continue
                value = snak.get('datavalue', {})
                if snak.get('snaktype') != 'value' or not isinstance(value, dict):
                    raise ValueError('Invalid source snak')
                if value.get('type') != 'wikibase-entityid':
                    # The pinned module may format another datatype; it does not imply an ID.
                    continue
                target = value.get('value')
                if not isinstance(target, dict):
                    raise ValueError('Invalid entity-valued claim')
                entity_id = valid_id(target.get('id'))
                rows.append(dict(seed=seed, property=prop, statement=index,
                    pointer='/claims/' + prop + '/' + str(index) + '/mainsnak/datavalue/value/id',
                    target=entity_id, rank=statement.get('rank')))
    return rows


def derived_entity(entity):
    result = {key: value for key, value in entity.items()
              if key not in META_FIELDS and value != [] and value != {}}
    result['schemaVersion'] = 2
    return result


def resolved_terms(full, response, content_language):
    result = {}
    for singular, plural in (('label', 'labels'), ('description', 'descriptions')):
        original = map_field(full, plural)
        term = map_field(response, plural).get(content_language) if response is not None else None
        if response is None and original:
            raise ValueError('Missing default-term response for nonempty terms')
        if term is None:
            result[singular] = None
            continue
        if term.get('for-language', content_language) != content_language:
            raise ValueError('Resolved term targets the wrong content language')
        result[singular] = {key: term[key] for key in ('value', 'language', 'source-language') if key in term}
        if not result[singular].get('language'):
            raise ValueError('Resolved term has no actual language')
    return result


def render_outputs(records, terms, wiki, date, content_language):
    outputs = {}
    for name in NAMES:
        header = ('# wikidict-' + name + '-v1\n# wiki=' + wiki + '\n# date=' + date
                  + '\n# content-language=' + content_language + '\n# repository=' + REPOSITORY
                  + '\n# profile=' + PROFILES[name] + '\n')
        rows = []
        for requested, entity in sorted(records.items()):
            if entity is None:
                rows.append(requested + '\tM\t\t\n')
            else:
                value = derived_entity(entity) if name == NAMES[0] else terms[requested]
                rows.append(requested + '\tE\t' + entity['id'] + '\t' + compact(value) + '\n')
        raw = (header + ''.join(rows)).encode()
        if len(raw) > MAX_OUTPUT_BYTES:
            raise ValueError('Entity snapshot exceeds output bound')
        outputs[name + '.tsv'] = raw
    return outputs


def replay(blobs, requests, seeds, content_language):
    records, term_records = {}, {}
    total_raw = 0
    canonical_records = {}
    expected_names = set(BASE_ARTIFACTS)
    for index, request in enumerate(requests, 1):
        prefix = 'wikibase-request-' + format(index, '06d')
        if (not isinstance(request, dict) or set(request) != {'mode', 'ids', 'request', 'response'}
                or request['request'] != prefix + '.request.json' or request['response'] != prefix + '.raw.json'):
            raise ValueError('Invalid entity request inventory')
        expected_names.update((request['request'], request['response']))
        raw = blobs[request['response']]
        total_raw += len(raw)
        if total_raw > MAX_TOTAL_RAW_BYTES:
            raise ValueError('Capture exceeds total response bound')
        verify_request(parse_json(blobs[request['request']]), raw, request['ids'], request['mode'], content_language)
        values = response_records(raw, request['ids'], request['mode'])
        target = records if request['mode'] == 'full' else term_records
        if set(target) & set(values):
            raise ValueError('Duplicate captured entity request')
        target.update(values)
        if len(records) > MAX_ENTITIES:
            raise ValueError('Entity count exceeds bound')
        if request['mode'] == 'full':
            for entity in values.values():
                if entity is None:
                    continue
                value = {key: item for key, item in entity.items() if key != 'redirects'}
                prior = canonical_records.setdefault(entity['id'], value)
                if prior != value:
                    raise ValueError('Conflicting revisions for one canonical entity')
    if set(blobs) != expected_names:
        raise ValueError('Incomplete or unexpected entity artifact inventory')
    if not set(seeds).issubset(records):
        raise ValueError('Seed entity request missing')
    dependencies = dependency_rows(records, seeds)
    closure = set(seeds) | {row['target'] for row in dependencies}
    if set(records) != closure:
        raise ValueError('Entity set differs from bounded seed/property closure')
    if parse_json(blobs['wikibase-dependencies.json']) != dependencies:
        raise ValueError('Dependency proof differs from captured claims')
    terms = {}
    expected_term_ids = set()
    for requested, entity in records.items():
        if entity is None:
            continue
        needs_terms = bool(map_field(entity, 'labels') or map_field(entity, 'descriptions'))
        response = term_records.get(requested)
        if needs_terms:
            expected_term_ids.add(requested)
            if (response is None or response.get('id') != entity['id']
                    or response.get('lastrevid') != entity['lastrevid']
                    or response.get('modified') != entity['modified']):
                raise ValueError('Resolved terms and full entity revision differ')
        terms[requested] = resolved_terms(entity, response, content_language)
    if set(term_records) != expected_term_ids:
        raise ValueError('Resolved-term request set differs from entity terms')
    return records, terms, dependencies


def manifest_common(record):
    return {key: value for key, value in record.items()
            if key not in ('name', 'profile', 'output_sha256', 'output_bytes')}


def validate_snapshot(path, wiki=None, date=None):
    path = Path(path)
    selected = path.stem if path.name in (name + '.tsv' for name in NAMES) else NAMES[0]
    root = path.parent if path.name.endswith('.tsv') else path
    if root.is_symlink() or not root.is_dir():
        raise ValueError('Unsafe entity capture root')
    manifests = {name: parse_json(regular(root / (name + '.manifest.json'), MAX_PROOF_BYTES)) for name in NAMES}
    manifest = manifests[selected]
    if not isinstance(manifest, dict):
        raise ValueError('Invalid entity manifest')
    actual_wiki, actual_date = manifest.get('wiki'), manifest.get('date')
    identity(actual_wiki, actual_date)
    if (wiki is not None and actual_wiki != wiki or date is not None and actual_date != date):
        raise ValueError('Entity capture edition/date mismatch')
    if (type(manifest.get('version')) is not int or manifest.get('version') != 1 or manifest.get('schema') != 'wikidict-wikibase-capture-v1'
            or manifest.get('temporal_scope') != 'current-at-retrieval' or manifest.get('repository') != REPOSITORY):
        raise ValueError('Invalid entity capture version or scope')
    artifacts = manifest.get('artifacts')
    if not isinstance(artifacts, dict) or not BASE_ARTIFACTS.issubset(artifacts):
        raise ValueError('Missing entity capture artifacts')
    blobs = {}
    for name, expected in artifacts.items():
        if not isinstance(name, str) or Path(name).name != name or not name.startswith('wikibase-'):
            raise ValueError('Unsafe entity artifact name')
        limit = MAX_OUTPUT_BYTES if name.endswith('.tsv') else MAX_PROOF_BYTES if name in BASE_ARTIFACTS else MAX_RESPONSE_BYTES
        raw = regular(root / name, limit)
        if not isinstance(expected, str) or digest(raw) != expected:
            raise ValueError('Changed entity capture artifact: ' + name)
        blobs[name] = raw
    content_language = namespace_input(blobs['wikibase-namespace-siteinfo.raw.json'],
        blobs['wikibase-namespace-capture.complete.json'], actual_wiki, actual_date)
    if manifest.get('content_language') != content_language:
        raise ValueError('Entity capture content language differs')
    seeds = validate_seed_source(parse_json(blobs['wikibase-seeds.json']),
        parse_json(blobs['wikibase-namespace-capture.complete.json']), actual_wiki, actual_date)
    requests = manifest.get('requests')
    if not isinstance(requests, list) or not requests or len(requests) > 2 * MAX_ENTITIES:
        raise ValueError('Invalid entity request count')
    records, terms, dependencies = replay(blobs, requests, seeds, content_language)
    outputs = render_outputs(records, terms, actual_wiki, actual_date, content_language)
    receipts = [parse_json(blobs[row['request']]) for row in requests]
    if (manifest.get('seed_count') != len(seeds) or manifest.get('entity_count') != len(records)
            or manifest.get('missing_count') != sum(value is None for value in records.values())
            or manifest.get('dependency_count') != len(dependencies)
            or manifest.get('started_utc') != min(row['started_utc'] for row in receipts)
            or manifest.get('retrieved_utc') != max(row['retrieved_utc'] for row in receipts)
            or not re.fullmatch(r'[0-9a-f]{64}', manifest.get('generator_sha256', ''))):
        raise ValueError('Entity manifest accounting differs from evidence')
    timestamp(manifest.get('created_utc'))
    for name, other in manifests.items():
        raw = outputs[name + '.tsv']
        if (not isinstance(other, dict) or manifest_common(other) != manifest_common(manifest)
                or other.get('name') != name or other.get('profile') != PROFILES[name]
                or other.get('output_sha256') != digest(raw) or other.get('output_bytes') != len(raw)
                or blobs[name + '.tsv'] != raw):
            raise ValueError('Entity projection differs from exact offline replay')
    return manifest


def capture_artifacts(path, manifest=None):
    path = Path(path)
    root = path.parent if path.name.endswith('.tsv') else path
    verified = validate_snapshot(path)
    if manifest is not None and verified != manifest:
        raise ValueError('Entity capture changed during validation')
    result = dict(verified['artifacts'])
    for name in NAMES:
        filename = name + '.manifest.json'
        result[filename] = digest(regular(root / filename, MAX_PROOF_BYTES))
    return result


def fetch_response(url):
    for attempt in range(4):
        started = dt.datetime.now(dt.timezone.utc).isoformat()
        try:
            req = urllib.request.Request(url, headers={'User-Agent': AGENT, 'Accept': 'application/json'})
            with urllib.request.urlopen(req, timeout=30) as response:
                raw = response.read(MAX_RESPONSE_BYTES + 1)
                if len(raw) > MAX_RESPONSE_BYTES:
                    raise ValueError('Entity response exceeds byte limit')
                receipt = dict(source_url=url, response_url=response.geturl(), status=response.status,
                    started_utc=started, retrieved_utc=dt.datetime.now(dt.timezone.utc).isoformat(),
                    raw_sha256=digest(raw), raw_bytes=len(raw))
            value = parse_json(raw)
            if isinstance(value, dict) and isinstance(value.get('error'), dict) and value['error'].get('code') == 'maxlag':
                raise TimeoutError('MediaWiki maxlag')
            return raw, receipt
        except (OSError, urllib.error.URLError) as error:
            if isinstance(error, urllib.error.HTTPError) and error.code not in (429, 500, 502, 503, 504):
                raise
            if attempt == 3:
                raise
            print(json.dumps(dict(phase='wikibase_retry', attempt=attempt + 1, error=str(error))), flush=True)
            time.sleep(min(2 ** (attempt + 1), 15))
    raise AssertionError('Unreachable request loop')


def capture_snapshot(capture_root, wiki, date, seeds_path, output=None, fetcher=None):
    identity(wiki, date)
    capture_root = Path(capture_root)
    output = Path(output) if output is not None else capture_root / DIRECTORY
    pinned_raw = regular(capture_root / 'namespace-siteinfo.raw.json')
    pinned_complete = regular(capture_root / 'capture.complete.json')
    content_language = namespace_input(pinned_raw, pinned_complete, wiki, date)
    seed_raw = regular(seeds_path, MAX_PROOF_BYTES)
    seeds = validate_seed_source(parse_json(seed_raw), parse_json(pinned_complete), wiki, date)
    if output.exists() or output.is_symlink():
        old = validate_snapshot(output, wiki, date)
        for name, raw in (('wikibase-seeds.json', seed_raw),
                          ('wikibase-namespace-siteinfo.raw.json', pinned_raw),
                          ('wikibase-namespace-capture.complete.json', pinned_complete)):
            if old['artifacts'][name] != digest(raw):
                raise ValueError('Existing entity capture uses different source inputs')
        return old, False
    if digest(Path(__file__).read_bytes()) != PRODUCER_SHA256:
        raise ValueError('Entity capture generator changed')
    blobs = {'wikibase-seeds.json': seed_raw, 'wikibase-namespace-siteinfo.raw.json': pinned_raw,
             'wikibase-namespace-capture.complete.json': pinned_complete}
    output.mkdir(parents=True, exist_ok=False)
    def persist(name, raw):
        path = output / name
        if path.exists():
            if regular(path, MAX_OUTPUT_BYTES) != raw:
                raise ValueError('Partial entity capture changed')
            return
        with path.open('xb') as stream:
            stream.write(raw)
            stream.flush()
            os.fsync(stream.fileno())
        path.chmod(0o444)
    for name, raw in blobs.items():
        persist(name, raw)
    requests, records, term_records = [], {}, {}
    start = time.monotonic()
    raw_bytes = 0
    def collect(ids, mode):
        nonlocal raw_bytes
        target = records if mode == 'full' else term_records
        for offset in range(0, len(ids), BATCH_SIZE):
            if time.monotonic() - start > MAX_SECONDS:
                raise ValueError('Entity capture time bound exceeded')
            batch = ids[offset:offset + BATCH_SIZE]
            raw, receipt = (fetcher or fetch_response)(query_url(batch, mode, content_language))
            prefix = 'wikibase-request-' + format(len(requests) + 1, '06d')
            request_name, response_name = prefix + '.request.json', prefix + '.raw.json'
            persist(request_name, document(receipt))
            persist(response_name, raw)
            if time.monotonic() - start > MAX_SECONDS:
                raise ValueError('Entity capture time bound exceeded')
            raw_bytes += len(raw)
            if raw_bytes > MAX_TOTAL_RAW_BYTES:
                raise ValueError('Entity capture total byte limit exceeded')
            verify_request(receipt, raw, batch, mode, content_language)
            values = response_records(raw, batch, mode)
            if set(target) & set(values):
                raise ValueError('Duplicate entity capture')
            target.update(values)
            blobs[request_name], blobs[response_name] = document(receipt), raw
            requests.append(dict(mode=mode, ids=batch, request=request_name, response=response_name))
            print(json.dumps(dict(phase='wikibase_capture', mode=mode, batch=len(requests),
                                  entities=len(records), terms=len(term_records), raw_bytes=raw_bytes)), flush=True)
    collect(seeds, 'full')
    dependencies = dependency_rows(records, seeds)
    closure = sorted({row['target'] for row in dependencies} - set(records))
    if len(records) + len(closure) > MAX_ENTITIES:
        raise ValueError('Entity property closure exceeds count limit')
    collect(closure, 'full')
    term_ids = sorted(key for key, entity in records.items()
                      if entity is not None and (map_field(entity, 'labels') or map_field(entity, 'descriptions')))
    collect(term_ids, 'terms')
    terms = {}
    for requested, entity in records.items():
        if entity is None:
            continue
        response = term_records.get(requested)
        if response is not None and (response['id'] != entity['id'] or response['lastrevid'] != entity['lastrevid']
                                     or response['modified'] != entity['modified']):
            raise ValueError('Entity changed while capturing resolved terms; retry a fresh generation')
        terms[requested] = resolved_terms(entity, response, content_language)
    blobs['wikibase-dependencies.json'] = document(dependencies)
    blobs.update(render_outputs(records, terms, wiki, date, content_language))
    replay(blobs, requests, seeds, content_language)
    receipts = [parse_json(blobs[row['request']]) for row in requests]
    common = dict(version=1, schema='wikidict-wikibase-capture-v1', wiki=wiki, date=date,
        content_language=content_language, repository=REPOSITORY, temporal_scope='current-at-retrieval',
        created_utc=dt.datetime.now(dt.timezone.utc).isoformat(),
        started_utc=min(row['started_utc'] for row in receipts), retrieved_utc=max(row['retrieved_utc'] for row in receipts),
        seed_count=len(seeds), entity_count=len(records), missing_count=sum(value is None for value in records.values()),
        dependency_count=len(dependencies), generator_sha256=PRODUCER_SHA256, requests=requests,
        artifacts={name: digest(raw) for name, raw in blobs.items()})
    if (digest(Path(__file__).read_bytes()) != PRODUCER_SHA256
            or regular(capture_root / 'namespace-siteinfo.raw.json') != pinned_raw
            or regular(capture_root / 'capture.complete.json') != pinned_complete
            or regular(seeds_path, MAX_PROOF_BYTES) != seed_raw):
        raise ValueError('Capture producer or source input changed')
    manifests = {}
    for name in NAMES:
        raw = blobs[name + '.tsv']
        manifests[name + '.manifest.json'] = document(dict(common, name=name, profile=PROFILES[name],
                                                          output_sha256=digest(raw), output_bytes=len(raw)))
    # Only publish manifests after every payload byte is durable.
    for name, raw in [*blobs.items(), *manifests.items()]:
        persist(name, raw)
    return validate_snapshot(output, wiki, date), True


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--capture-root', type=Path)
    parser.add_argument('--wiki')
    parser.add_argument('--date')
    parser.add_argument('--seeds', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--verify', action='store_true')
    args = parser.parse_args()
    if args.verify:
        manifest = validate_snapshot(args.output, args.wiki, args.date)
        created = False
    else:
        if not all((args.capture_root, args.wiki, args.date, args.seeds)):
            parser.error('Capture requires --capture-root, --wiki, --date and --seeds')
        manifest, created = capture_snapshot(args.capture_root, args.wiki, args.date, args.seeds, args.output)
    print(json.dumps(dict(phase='wikibase_complete', created=created, wiki=manifest['wiki'],
                         entity_count=manifest['entity_count'], seed_count=manifest['seed_count'],
                         missing_count=manifest['missing_count'], output_sha256=manifest['output_sha256'])), flush=True)


if __name__ == '__main__':
    main()
