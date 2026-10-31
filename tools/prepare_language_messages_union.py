#!/usr/bin/env python3
"""Add one independently observed message to an immutable language capture.

Replay original v1/v2 evidence unchanged; request only the selected message.
Fallback bytes and existing rows remain exact. Both observations retain their
own provenance; paired TSVs keep the existing wire format.
"""
import argparse
from contextlib import contextmanager
import io
import json
from pathlib import Path
import tarfile
import tempfile
import time
import prepare_language_messages as legacy
import prepare_language_messages_v2 as v2

evidence = legacy.evidence
SCHEMA = 'wikidict.language-messages-union.v1'
KINDS, PREFIX, COMPLETE = legacy.KINDS, legacy.PREFIX, legacy.COMPLETE
MAX_MANIFEST = legacy.MAX_MANIFEST
MAX_ARCHIVE = 8 * 1024 * 1024
MAX_CHILD_FILE = 2 * 1024 * 1024
MAX_CHILD_FILES = 512
ARCHIVE = PREFIX + 'base-capture.tar'
NAMESPACE = PREFIX + 'namespace-registry.tsv'


def require(condition, message):
    if not condition:
        raise ValueError(message)


def producer():
    return {'generator_sha256': evidence.digest(evidence.small(Path(__file__))),
            'base_producers': [legacy.producer(), v2.producer()]}


def document(path, value):
    raw = evidence.encoded(value)
    require(len(raw) <= MAX_MANIFEST, 'Union manifest exceeds byte limit')
    evidence.put(path, raw)


def base_helper(root):
    manifest = evidence.decode(evidence.small(root / 'interface-messages.manifest.json', MAX_MANIFEST))
    schema = manifest.get('schema') if isinstance(manifest, dict) else None
    require(schema in (legacy.SCHEMA, v2.SCHEMA), 'Expected original v1/v2 base capture')
    return legacy if schema == legacy.SCHEMA else v2


def archive_base(root, output, helper, records):
    inventory = helper.capture_artifacts(root / 'interface-messages.tsv', records['interface-messages'])
    require(len(inventory) <= MAX_CHILD_FILES, 'Too many base capture artifacts')
    total = 0
    with tarfile.open(output, 'x', format=tarfile.USTAR_FORMAT) as archive:
        for name, expected in sorted(inventory.items()):
            require(Path(name).name == name and name not in ('.', '..'), 'Invalid base artifact name')
            raw = evidence.small(root / name, MAX_CHILD_FILE)
            require(evidence.digest(raw) == expected, 'Base artifact changed before archive')
            total += len(raw) + 1024
            require(total <= MAX_ARCHIVE - 10240, 'Base archive exceeds byte limit')
            info = tarfile.TarInfo(name)
            info.size, info.mode, info.mtime = len(raw), 0o600, 0
            archive.addfile(info, io.BytesIO(raw))
    require(output.stat().st_size <= MAX_ARCHIVE, 'Base archive exceeds byte limit')
    return inventory


@contextmanager
def replay_base(root):
    archive_raw = evidence.small(root / ARCHIVE, MAX_ARCHIVE)
    scratch = evidence.REPO / '.tmp'
    scratch.mkdir(exist_ok=True)
    require(scratch.is_dir() and not scratch.is_symlink(), 'Unsafe replay scratch parent')
    with tempfile.TemporaryDirectory(prefix='language-message-replay-', dir=scratch) as tmp:
        target = Path(tmp)
        names, total = set(), 0
        with tarfile.open(fileobj=io.BytesIO(archive_raw), mode='r:') as archive:
            for member in archive:
                name = member.name
                require(member.isfile() and Path(name).name == name and name not in ('.', '..')
                        and name not in names and len(names) < MAX_CHILD_FILES,
                        'Invalid or duplicate base archive member')
                require(0 <= member.size <= MAX_CHILD_FILE, 'Base artifact exceeds byte limit')
                total += member.size
                require(total <= MAX_ARCHIVE, 'Base payload exceeds byte limit')
                stream = archive.extractfile(member)
                require(stream is not None, 'Missing base archive data')
                with stream:
                    raw = stream.read(MAX_CHILD_FILE + 1)
                require(len(raw) == member.size, 'Truncated base archive member')
                # Disposable replay scratch, authenticated below and removed by
                # TemporaryDirectory. Match the existing union extractor: only
                # published capture artifacts require evidence.put durability.
                with (target / name).open('xb') as output:
                    output.write(raw)
                names.add(name)
        helper = base_helper(target)
        records = helper.verify(target)
        inventory = helper.capture_artifacts(target / 'interface-messages.tsv', records['interface-messages'])
        require(names == set(inventory), 'Base archive inventory differs from replay')
        yield target, records, inventory


def selection(record):
    value = record.get('selection')
    require(isinstance(value, dict) and set(value) == {'language', 'key'}, 'Invalid singleton selection')
    language, key = value['language'], value['key']
    require(legacy.language_code(language) and legacy.normalize_key(key) == key,
            'Singleton key must be normalized and language explicit')
    return language, key


def merged_messages(raw, observed, language, key, base):
    header = ('\n'.join(legacy.header('interface-messages', base['wiki'], base['date'],
                                     base['content_language'])) + '\n').encode()
    require(raw.startswith(header), 'Base TSV identity differs')
    indexed = {}
    for row in raw[len(header):].splitlines(keepends=True):
        fields = row.rstrip(b'\n').split(b'\t')
        require(row.endswith(b'\n') and len(fields) >= 3, 'Invalid base message row')
        identity = (fields[0].decode(), fields[1].decode())
        require(identity not in indexed, 'Duplicate base message identity')
        indexed[identity] = row
    require((language, key) not in indexed, 'Singleton conflicts with existing base row')
    require(set(observed) == {key}, 'Singleton response key set differs')
    extra = legacy.render_messages({(language, key): observed[key]}, base['wiki'], base['date'],
                                   base['content_language'])[len(header):]
    indexed[(language, key)] = extra
    return header + b''.join(indexed[k] for k in sorted(indexed)), len(indexed)


def observation(root, record, base):
    language, key = selection(record)
    require(language in base['fallback_languages'], 'Selected language absent from retained fallback inventory')
    requested = evidence.decode(evidence.small(root / (PREFIX + 'requested.json'), MAX_MANIFEST))
    expected = {'kind': 'messages', 'language': language, 'keys': [key]}
    require(requested == expected, 'Singleton requested key set differs')
    batch = record.get('singleton')
    require(isinstance(batch, dict) and set(batch) == {'request', 'accepted_receipt'}, 'Missing singleton evidence')
    require(batch['request'] == PREFIX + '0001.request.json'
            and batch['accepted_receipt'] in [PREFIX + f'0001-{i:02d}.receipt.json' for i in range(1, 5)],
            'Singleton receipt identity differs')
    request = evidence.decode(evidence.small(root / batch['request'], MAX_MANIFEST))
    query = legacy.query_for(base['wiki'], language, [key])
    require(request == {**expected, 'query': query, 'url': legacy.query_url(base['wiki'], query)},
            'Singleton query differs from required plain-message semantics')
    receipt = evidence.decode(evidence.small(root / batch['accepted_receipt'], MAX_MANIFEST))
    name = batch['accepted_receipt'].removesuffix('.receipt.json') + '.raw.json'
    require(receipt.get('accepted') is True and receipt.get('status') == 200
            and receipt.get('request') == batch['request'] and receipt.get('response') == name,
            'Invalid accepted singleton receipt')
    raw = evidence.small(root / name, legacy.MAX_RESPONSE)
    require(receipt.get('response_bytes') == len(raw) and receipt.get('response_sha256') == evidence.digest(raw),
            'Singleton response differs from receipt')
    require(isinstance(receipt.get('started_utc'), str) and isinstance(receipt.get('ended_utc'), str),
            'Missing singleton observation timestamps')
    return legacy.parse_messages(evidence.decode(raw), language, [key], base['wiki'], base['content_language']), receipt


def owned_payload(root):
    """Inspect only this capture's names; other auxiliary snapshots share staging."""
    expected = {ARCHIVE, NAMESPACE, PREFIX + 'requested.json', PREFIX + '0001.request.json',
                *(kind + '.tsv' for kind in KINDS)}
    expected.update(PREFIX + f'0001-{attempt:02d}.' + suffix
                    for attempt in range(1, 5) for suffix in ('raw.json', 'receipt.json'))
    markers = {COMPLETE, *(kind + '.manifest.json' for kind in KINDS)}
    result = {}
    for path in root.iterdir():
        name = path.name
        if name in markers or not (name.startswith(PREFIX) or name in (kind + '.tsv' for kind in KINDS)):
            continue
        require(name in expected, 'Unexpected union-owned artifact')
        limit = MAX_ARCHIVE if name == ARCHIVE else MAX_CHILD_FILE
        raw = evidence.small(path, limit)
        result[name] = {'size': len(raw), 'sha256': evidence.digest(raw)}
    return dict(sorted(result.items()))


def verify(root, require_complete=True):
    root = Path(root)
    require(not root.is_symlink() and root.is_dir(), 'Unsafe union directory')
    records, hashes = {}, {}
    for kind in KINDS:
        raw = evidence.small(root / (kind + '.manifest.json'), MAX_MANIFEST)
        record = evidence.decode(raw)
        require(isinstance(record, dict) and record.get('schema') == SCHEMA and record.get('kind') == kind
                and record.get('header_version') == 1, 'Union schema differs')
        records[kind], hashes[kind + '.manifest.json'] = record, evidence.digest(raw)
    if require_complete:
        require(evidence.decode(evidence.small(root / COMPLETE, MAX_MANIFEST)) ==
                {'schema': SCHEMA, 'manifests': hashes}, 'Union completion differs')
    record = records['interface-messages']
    per_output = {'kind', 'rows', 'output_bytes', 'output_sha256'}
    require({k: v for k, v in record.items() if k not in per_output} ==
            {k: v for k, v in records['language-fallbacks'].items() if k not in per_output}, 'Paired union manifests differ')
    require(record.get('producer') == producer(), 'Union producer differs')
    require(record.get('temporal_scope') == 'current-api-observation' and record.get('dump_date') is None
            and record.get('candidate_queries_complete') is True and record.get('corpus_query_closure_proven') is False
            and record.get('fallback_mode') == 'strict' and record.get('message_mode') == 'plain-with-database',
            'Union scope differs')
    inventory = owned_payload(root)
    require(inventory == record.get('artifacts'), 'Union artifact inventory differs')
    with replay_base(root) as (base_root, base_records, base_inventory):
        base = base_records['interface-messages']
        require(record.get('base_profile') == {k: base[k] for k in ('schema', 'generator_sha256', 'keys')}, 'Base profile differs')
        for key in ('wiki', 'date', 'content_language', 'namespace_registry_sha256'):
            require(record.get(key) == base[key], 'Union/base identity differs')
        namespace = evidence.small(base_root / NAMESPACE, MAX_MANIFEST)
        require(evidence.small(root / NAMESPACE, MAX_MANIFEST) == namespace, 'Union namespace differs from base')
        observed, receipt = observation(root, record, base)
        language, key = selection(record)
        merged, rows = merged_messages(evidence.small(base_root / 'interface-messages.tsv', MAX_CHILD_FILE),
                                       observed, language, key, base)
        expected_sources = [
            {'role': 'base-capture', 'schema': base['schema'], 'archive': ARCHIVE,
             'manifests': {k + '.manifest.json': base_inventory[k + '.manifest.json'] for k in KINDS},
             'retrieved_utc': base['retrieved_utc']},
            {'role': 'singleton-message', 'request': record['singleton']['request'],
             'accepted_receipt': record['singleton']['accepted_receipt'], 'retrieved_utc': receipt['ended_utc']}]
        require(record.get('sources') == expected_sources, 'Multiple-source provenance differs')
        outputs = {'interface-messages': (merged, rows),
                   'language-fallbacks': (evidence.small(base_root / 'language-fallbacks.tsv', MAX_CHILD_FILE),
                                          base_records['language-fallbacks']['rows'])}
        for kind, (raw, count) in outputs.items():
            current = records[kind]
            require(evidence.small(root / (kind + '.tsv'), MAX_CHILD_FILE) == raw
                    and current.get('rows') == count and current.get('output_bytes') == len(raw)
                    and current.get('output_sha256') == evidence.digest(raw), 'Union TSV differs from source evidence')
    require(owned_payload(root) == inventory, 'Union changed during verification')
    return records


def capture(args, transport=None, sleep=time.sleep):
    require(1 <= args.wall_seconds <= 900 and 0 <= args.delay <= 60, 'Invalid bounded capture settings')
    selected = {'selection': {'language': args.language, 'key': args.message}}
    language, key = selection(selected)
    helper = base_helper(args.base)
    base_records = helper.verify(args.base)
    base = base_records['interface-messages']
    # Reject duplicate/conflicting selections before any output or network work.
    merged_messages(evidence.small(args.base / 'interface-messages.tsv', MAX_CHILD_FILE),
                    {key: None}, language, key, base)
    require(language in base['fallback_languages'], 'Selected language absent from retained fallback inventory')
    identity = producer()
    root = args.output
    root.mkdir(parents=True, exist_ok=False)
    try:
        base_inventory = archive_base(args.base, root / ARCHIVE, helper, base_records)
        evidence.put(root / NAMESPACE, evidence.small(args.base / NAMESPACE, MAX_MANIFEST))
        specification = {'kind': 'messages', 'language': language, 'keys': [key]}
        evidence.document(root / (PREFIX + 'requested.json'), specification)
        observed, batch = legacy.request_observation(root, 1, base['wiki'], base['content_language'], specification,
            transport or evidence.get_response, sleep, args.delay, time.monotonic() + args.wall_seconds)
        receipt = evidence.decode(evidence.small(root / batch['accepted_receipt'], MAX_MANIFEST))
        merged, count = merged_messages(evidence.small(args.base / 'interface-messages.tsv', MAX_CHILD_FILE),
                                       observed, language, key, base)
        outputs = {'interface-messages': (merged, count),
                   'language-fallbacks': (evidence.small(args.base / 'language-fallbacks.tsv', MAX_CHILD_FILE),
                                          base_records['language-fallbacks']['rows'])}
        for kind, (raw, _) in outputs.items():
            evidence.put(root / (kind + '.tsv'), raw)
        require(helper.capture_artifacts(args.base / 'interface-messages.tsv', base) == base_inventory
                and producer() == identity, 'Base capture or collector changed')
        common = {'schema': SCHEMA, 'header_version': 1, 'producer': identity, **selected,
            **{k: base[k] for k in ('wiki', 'date', 'content_language', 'namespace_registry_sha256')},
            'dump_date': None, 'temporal_scope': 'current-api-observation', 'singleton': batch,
            'candidate_queries_complete': True, 'corpus_query_closure_proven': False,
            'fallback_mode': 'strict', 'message_mode': 'plain-with-database',
            'artifacts': owned_payload(root),
            'base_profile': {k: base[k] for k in ('schema', 'generator_sha256', 'keys')},
            'sources': [{'role': 'base-capture', 'schema': base['schema'], 'archive': ARCHIVE,
                'manifests': {k + '.manifest.json': base_inventory[k + '.manifest.json'] for k in KINDS},
                'retrieved_utc': base['retrieved_utc']},
                {'role': 'singleton-message', **batch, 'retrieved_utc': receipt['ended_utc']}]}
        for kind, (raw, rows) in outputs.items():
            document(root / (kind + '.manifest.json'), {**common, 'kind': kind, 'rows': rows,
                'output_bytes': len(raw), 'output_sha256': evidence.digest(raw)})
        verify(root, require_complete=False)
        document(root / COMPLETE, {'schema': SCHEMA, 'manifests': {k + '.manifest.json':
            evidence.digest(evidence.small(root / (k + '.manifest.json'), MAX_MANIFEST)) for k in KINDS}})
        return verify(root)
    except BaseException as error:
        for name in (COMPLETE, *(k + suffix for k in KINDS for suffix in ('.tsv', '.manifest.json'))):
            path = root / name
            if path.exists():
                path.rename(root / (name + '.unverified'))
        evidence.document(root / (PREFIX + 'failure.json'), {'error': str(error), 'ended_utc': evidence.utc()})
        raise


def validate_snapshot(path, wiki=None, date=None):
    path = Path(path)
    kind = path.name.removesuffix('.tsv')
    require(kind in KINDS and path.name == kind + '.tsv', 'Unexpected union snapshot name')
    record = verify(path.parent)[kind]
    require((wiki is None or record['wiki'] == wiki) and (date is None or record['date'] == date),
            'Union edition/date differs')
    return record


def capture_artifacts(path, manifest=None):
    record = validate_snapshot(path)
    require(manifest is None or manifest == record, 'Union manifest changed before pinning')
    result = {name: value['sha256'] for name, value in record['artifacts'].items()}
    for name in (COMPLETE, *(k + '.manifest.json' for k in KINDS)):
        result[name] = evidence.digest(evidence.small(Path(path).parent / name, MAX_MANIFEST))
    return result


def require_preferred_loop(record):
    profile = record.get('base_profile', {})
    keys = profile.get('keys')
    require(profile.get('schema') == v2.SCHEMA
            and profile.get('generator_sha256') == v2.producer()['generator_sha256']
            and isinstance(keys, list) and 1 <= len(keys) <= 67
            and 'parser-template-loop-warning' in keys,
            'Preferred loop union requires current v2 base and loop-warning key')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    collect = commands.add_parser('capture')
    collect.add_argument('--base', required=True, type=Path)
    collect.add_argument('--language', required=True)
    collect.add_argument('--message', required=True)
    collect.add_argument('--output', required=True, type=Path)
    collect.add_argument('--delay', type=float, default=1.0)
    collect.add_argument('--wall-seconds', type=int, default=900)
    check = commands.add_parser('verify')
    check.add_argument('output', type=Path)
    args = parser.parse_args()
    if args.command == 'capture' and args.delay < 1:
        parser.error('Network captures require at least one second between requests')
    result = capture(args) if args.command == 'capture' else verify(args.output)
    print(json.dumps({k: {name: v[name] for name in ('wiki', 'date', 'rows', 'output_sha256', 'temporal_scope')}
                      for k, v in result.items()}, sort_keys=True))


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError) as error:
        raise SystemExit(str(error)) from error
