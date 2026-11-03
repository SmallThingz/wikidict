#!/usr/bin/env python3
"""Capture explicit file metadata v2 with MediaWiki type and canonical title.

The v1 collector and existing captures remain unchanged. This collector accepts
finite title/log seeds, saves flat immutable API evidence, and fully replays it
before publication. API observations are current, not historical dump facts.
"""
import argparse
from datetime import datetime
from pathlib import Path
import os
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


def validate_provenance(record):
    # Recorded producer identity is provenance, not a substitute for API replay.
    # Old observations remain usable only when today's verifier rederives the data.
    roles = {'src/shared/namespace_registry.zig', 'src/shared/title_case.zig',
             'tools/category_tree_snapshot.py', 'tools/download_wiktionaries.py',
             'tools/prepare_file_metadata.py'}
    dependencies = record.get('dependency_sha256') if isinstance(record, dict) else None
    if (not isinstance(record, dict) or not isinstance(dependencies, dict)
            or set(dependencies) != roles
            or any(not isinstance(value, str) or not re.fullmatch('[0-9a-f]{64}', value)
                   for value in [record.get('generator_sha256'), *dependencies.values()])):
        raise ValueError('Invalid file metadata producer provenance')


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


# Resume authenticated completed requests without repeating their HTTP observations.
RESUME = PREFIX + 'resume.json'


def checkpoint_read(path, descriptor, limit=MAX_METADATA):
    before = evidence.stamp(path)
    if before[2] > limit:
        raise ValueError('Checkpoint artifact exceeds bound')
    with path.open('rb') as stream:
        raw = stream.read(before[2] + 1)
    if (evidence.stamp(path) != before or len(raw) != before[2]
            or descriptor.get('bytes') != len(raw)
            or descriptor.get('sha256') != digest(raw)):
        raise ValueError('Checkpoint artifact changed')
    return raw


def checkpoint_contract(record, namespace_sha, seed_sha, wiki, date, batch_size=None, delay=None):
    if not isinstance(record, dict) or record.get('schema') != 'wikidict.file-metadata-checkpoint.v1':
        raise ValueError('Invalid checkpoint schema')
    start, result, failure = (decode(record[name]) for name in ('start_raw', 'result_raw', 'failure_raw'))
    if (result.get('exit_code') == 0 or result.get('pins_unchanged') is not True
            or failure.get('error') not in ('Original capture wall deadline reached',
                'Capture wall deadline reached', 'Retry exceeds bounded capture wait/deadline')):
        raise ValueError('Checkpoint is not a closed unchanged wall-stop capture')
    ancestor = start['pins'][2]['sha256']
    validate_provenance(failure)
    if (not isinstance(ancestor, str) or not re.fullmatch('[0-9a-f]{64}', ancestor)
            or failure.get('generator_sha256') != ancestor):
        raise ValueError('Checkpoint producer differs')
    for role, sha in failure['dependency_sha256'].items():
        suffix = Path(role).parts
        pins = [row for row in start['pins'][3:]
                if isinstance(row, dict) and isinstance(row.get('path'), str)
                and Path(row['path']).parts[-len(suffix):] == suffix]
        if len(pins) != 1 or pins[0].get('sha256') != sha:
            raise ValueError('Checkpoint dependency lineage differs')
    argv = start.get('argv')
    if not isinstance(argv, list) or len(argv) != 20 or argv[1:4] != ['-B', start['pins'][2]['path'], 'capture']:
        raise ValueError('Checkpoint original argv shape differs')
    old_batch, old_delay, old_wall = int(argv[15]), float(argv[17]), float(argv[19])
    if (not 1 <= old_batch <= 50 or not 0 <= old_delay <= 60 or not 1 <= old_wall <= 86400
            or (batch_size is not None and old_batch != batch_size)
            or (delay is not None and old_delay != delay)):
        raise ValueError('Checkpoint bounded batch/rate settings differ')
    expected = ['--wiki', wiki, '--date', date, '--namespace-registry', start['pins'][1]['path'],
                '--titles', start['pins'][0]['path'], '--output', record['source_root'],
                '--batch-size', argv[15], '--delay', argv[17], '--wall-seconds', argv[19]]
    # Python,-B,helper,capture followed by the exact original option inventory.
    if argv[4:] != expected:
        raise ValueError('Checkpoint seed/options differ')
    if start['pins'][0]['sha256'] != seed_sha or start['pins'][1]['sha256'] != namespace_sha:
        raise ValueError('Checkpoint selected inputs differ')
    if (start.get('expected_batches') != record.get('planned_batches')
            or start.get('expected_rows') != record.get('planned_rows')):
        raise ValueError('Checkpoint expected inventory differs')
    for name in ('start', 'result', 'failure'):
        raw = record[name + '_raw'].encode()
        if record[name]['bytes'] != len(raw) or record[name]['sha256'] != digest(raw):
            raise ValueError('Checkpoint original receipt hash differs')
    return start


def replay_checkpoint(root, proof_path, registry, inputs, titles, batch_size, delay):
    proof_raw = evidence.small(proof_path, 8 * 1024 * 1024)
    proof = decode(proof_raw)
    if len(inputs) != 1 or inputs[0]['kind'] != 'titles':
        raise ValueError('Resume requires one exact title seed')
    start = checkpoint_contract(proof, digest(small(root / NAMESPACE)), inputs[0]['sha256'], registry.wiki, registry.date, batch_size, delay)
    # Live continuation retains its source contract. Completed-data verification
    # below instead replays the observations without requiring this source revision.
    if decode(proof['failure_raw'])['dependency_sha256'] != producer()['dependency_sha256']:
        raise ValueError('Checkpoint live continuation dependencies differ')
    source = Path(proof['source_root'])
    if source.is_symlink() or not source.is_dir() or (source / COMPLETE).exists():
        raise ValueError('Unsafe or already completed checkpoint')
    inventory = proof.get('artifacts')
    if not isinstance(inventory, dict) or not 1 <= len(inventory) <= MAX_REQUESTS * 10:
        raise ValueError('Invalid checkpoint inventory')
    actual_names = {p.name for p in source.iterdir()}
    if actual_names != set(inventory):
        raise ValueError('Checkpoint file inventory changed')
    for name, descriptor in inventory.items():
        checkpoint_read(source / safe_name(name), descriptor)
    if checkpoint_read(source / (PREFIX + 'failure.json'), inventory[PREFIX + 'failure.json']) != proof['failure_raw'].encode():
        raise ValueError('Checkpoint failure differs from preserved source artifact')
    for old_name, new_name in ((NAMESPACE, NAMESPACE), ('file-metadata.input-0000.titles', inputs[0]['path']),
                               ('file-metadata.candidates.json', 'file-metadata.candidates.json')):
        if checkpoint_read(source / old_name, inventory[old_name]) != small(root / new_name):
            raise ValueError('Checkpoint namespace/seed/candidates differ')
    planned = list(title_batches(registry.wiki, titles, batch_size))
    if (len(planned), len(titles)) != (proof['planned_batches'], proof['planned_rows']):
        raise ValueError('Checkpoint batch plan differs')
    accepted = {}
    for name in sorted(inventory):
        if not re.fullmatch(r'file-metadata.response-\d{6}-\d{2}\.receipt\.json', name):
            continue
        receipt = decode(checkpoint_read(source / name, inventory[name]))
        if receipt.get('accepted') is not True:
            # Only a terminal deadline can be resumed; any actual API rejection is held.
            if receipt.get('status') is not None or receipt.get('api_error_code') is not None:
                raise ValueError('Rejected API observation requires separate scope review')
            continue
        number = int(name.split('-')[2])
        if number in accepted:
            raise ValueError('Duplicate accepted checkpoint batch')
        accepted[number] = (name, receipt)
    if not accepted or sorted(accepted) != list(range(1, len(accepted) + 1)) or len(accepted) >= len(planned):
        raise ValueError('Checkpoint accepted prefix is empty/noncontiguous/already complete')
    records, batches, copied = {}, [], {}
    for number, (receipt_name, receipt) in sorted(accepted.items()):
        request_name = f'file-metadata.request-{number:06d}.json'
        request_raw = checkpoint_read(source / request_name, inventory[request_name])
        request = decode(request_raw)
        requested = planned[number - 1]
        if request != {'url': query_url(registry.wiki, requested), 'query': query_for(registry.wiki, requested), 'titles': requested}:
            raise ValueError('Checkpoint request semantics differ')
        response_name = safe_name(receipt.get('response'))
        response = checkpoint_read(source / response_name, inventory[response_name], MAX_RESPONSE)
        if (receipt.get('status') != 200 or receipt.get('request') != request_name
                or receipt.get('response_bytes') != len(response) or receipt.get('response_sha256') != digest(response)
                or not isinstance(receipt.get('started_utc'), str) or not isinstance(receipt.get('ended_utc'), str)):
            raise ValueError('Invalid accepted checkpoint receipt')
        require_edition(decode(response), registry.wiki)
        records.update(classify_response(decode(response), requested, registry))
        for name in (request_name, receipt_name, response_name):
            raw = checkpoint_read(source / name, inventory[name])
            put(root / name, raw)
            copied[name] = inventory[name]
        batches.append({'request': request_name, 'accepted_receipt': receipt_name})
    resume = {'checkpoint': proof, 'checkpoint_raw': proof_raw.decode(), 'checkpoint_sha256': digest(proof_raw),
              'copied_artifacts': copied, 'reused_batches': batches,
              'ancestor_generator_sha256': start['pins'][2]['sha256'],
              'batch_size': batch_size, 'delay': delay,
              'successor_generator_sha256': producer()['generator_sha256'],
              'observation_scope': 'Sequential current observations retained across a closed wall-stop; not one atomic API observation.'}
    document(root / RESUME, resume)
    return records, batches


def verify_resume(root, manifest, index):
    reference = manifest.get('checkpoint_resume')
    if reference is None:
        if RESUME in index['artifacts']:
            raise ValueError('Unbound checkpoint provenance')
        return
    raw = small(root / RESUME, 8 * 1024 * 1024)
    if reference != {'path': RESUME, 'size': len(raw), 'sha256': digest(raw)}:
        raise ValueError('Checkpoint provenance changed')
    resume = decode(raw)
    if (digest(resume['checkpoint_raw'].encode()) != resume['checkpoint_sha256']
            or decode(resume['checkpoint_raw']) != resume['checkpoint']):
        raise ValueError('Checkpoint source document changed')
    start = checkpoint_contract(resume['checkpoint'], manifest['namespace_registry_sha256'],
                        index['inputs'][0]['sha256'], manifest['wiki'], manifest['date'], resume['batch_size'], resume['delay'])
    reused = resume['reused_batches']
    if (not reused or index['batches'][:len(reused)] != reused
            or resume['ancestor_generator_sha256'] != start['pins'][2]['sha256']
            or resume['successor_generator_sha256'] != manifest['generator_sha256']):
        raise ValueError('Checkpoint batch/source lineage differs')
    expected = set()
    for row in reused:
        receipt = decode(small(root / row['accepted_receipt']))
        expected.update((row['request'], row['accepted_receipt'], receipt['response']))
    if set(resume['copied_artifacts']) != expected:
        raise ValueError('Checkpoint copied artifact inventory differs')
    for name, descriptor in resume['copied_artifacts'].items():
        if descriptor != resume['checkpoint']['artifacts'].get(name):
            raise ValueError('Checkpoint copied descriptor differs')
        checkpoint_read(root / safe_name(name), descriptor)


def publish_final(path, raw):
    temporary = path.with_name('.' + path.name + '.pending')
    put(temporary, raw)
    # Atomic, exclusive publication on the same filesystem; never overwrite.
    os.link(temporary, path)
    temporary.unlink()
    fd = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


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
        if getattr(args, "resume_proof", None) is not None:
            records, batches = replay_checkpoint(root, args.resume_proof, registry, inputs, titles, args.batch_size, args.delay)
        reused_count = len(batches)
        for number, batch in enumerate(title_batches(args.wiki, titles, args.batch_size), 1):
            if number <= reused_count:
                continue
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
        publish_final(root / EVIDENCE, index_raw)
        manifest = {'schema': SCHEMA, 'header_version': 2, 'wiki': args.wiki, 'date': args.date,
                    'dump_date': None, 'temporal_scope': 'current-api-observation',
                    'source_url': wiktionary_api(args.wiki), 'started_utc': started, 'retrieved_utc': utc(),
                    **identity, 'namespace_registry_sha256': namespace_record['sha256'],
                    'evidence': {'path': EVIDENCE, 'size': len(index_raw), 'sha256': digest(index_raw)},
                    'rows': len(records), 'positive_rows': sum(x['exists'] for x in records.values()),
                    'negative_rows': sum(not x['exists'] for x in records.values()), 'unknown_rows': 0,
                    'candidate_queries_complete': True, 'corpus_query_closure_proven': False,
                    'output_bytes': len(tsv), 'output_sha256': digest(tsv)}
        if (root / RESUME).exists():
            resume_raw = small(root / RESUME, 8 * 1024 * 1024)
            manifest["checkpoint_resume"] = {"path": RESUME, "size": len(resume_raw), "sha256": digest(resume_raw)}
            manifest["successor_started_utc"] = started
            manifest["started_utc"] = min(decode(small(root / b["accepted_receipt"]))["started_utc"] for b in batches)
        if len(encoded(manifest)) > MAX_MANIFEST:
            raise ValueError('File metadata manifest exceeds bound')
        publish_final(root / MANIFEST, encoded(manifest))
        verify(root, require_complete=False)
        publish_final(root / COMPLETE, encoded({'schema': SCHEMA, 'manifest_sha256': digest(small(root / MANIFEST))}))
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
    validate_provenance(manifest)
    if (manifest.get('dump_date') is not None or manifest.get('temporal_scope') != 'current-api-observation'
            or manifest.get('source_url') != wiktionary_api(manifest['wiki'])):
        raise ValueError('Invalid file metadata capture scope')
    if not isinstance(manifest.get('date'), str) or not re.fullmatch(r'\d{8}', manifest['date']):
        raise ValueError('Invalid file metadata date')
    datetime.strptime(manifest['date'], '%Y%m%d')
    index = evidence_index(root, manifest)
    verify_resume(root, manifest, index)
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
    collect.add_argument('--resume-proof', type=Path)
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
