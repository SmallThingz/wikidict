#!/usr/bin/env python3
"""Add a bounded independently observed message family to a language capture.

Replay original v1/v2 or complete evidence unchanged; request only selected keys.
Fallback bytes and existing rows remain exact. Both observations retain their
own provenance; paired TSVs keep the existing wire format.
"""
import argparse
from contextlib import contextmanager
import errno
import io
import json
import os
from pathlib import Path
import re
import shutil
import sys
import tarfile
import tempfile
import time
import prepare_language_messages as legacy
import prepare_language_messages_v2 as v2

evidence = legacy.evidence
SCHEMA = 'wikidict.language-messages-union.v1'
BATCH_SCHEMA = 'wikidict.language-messages-union.v2'
MAX_BATCH_KEYS = 50
KINDS, PREFIX, COMPLETE = legacy.KINDS, legacy.PREFIX, legacy.COMPLETE
MAX_MANIFEST = legacy.MAX_MANIFEST
MAX_ARCHIVE = 8 * 1024 * 1024
MAX_CHILD_FILE = 2 * 1024 * 1024
MAX_CHILD_FILES = 512
ARCHIVE = PREFIX + 'base-capture.tar'
NAMESPACE = PREFIX + 'namespace-registry.tsv'
PRIOR_PREFIX = PREFIX + 'prior-singleton.'


def require(condition, message):
    if not condition:
        raise ValueError(message)


def replay_scratch():
    project = evidence.REPO
    # Only the installed compiler dependency root shares repository scratch.
    if (project.name == 'compiler' and project == Path(evidence.__file__).resolve().parent.parent
            and (project.parent / 'renderer/src').is_dir()):
        project = project.parent
    return project / '.tmp'


def producer():
    return {'generator_sha256': evidence.digest(evidence.small(Path(__file__))),
            'base_producers': [legacy.producer(), v2.producer()]}


def validate_provenance(value):
    # Current replay authenticates the data; recorded hashes never select old code.
    require(isinstance(value, dict) and set(value) == {'generator_sha256', 'base_producers'},
            'Invalid union producer provenance')
    require(isinstance(value['generator_sha256'], str)
            and re.fullmatch('[0-9a-f]{64}', value['generator_sha256']), 'Invalid union producer digest')
    bases = value['base_producers']
    require(isinstance(bases, list) and len(bases) == 2, 'Invalid union base producer provenance')
    for index, base in enumerate(bases):
        roles = {'tools/prepare_file_metadata.py', 'tools/download_wiktionaries.py'}
        if index == 1: roles.add('tools/prepare_language_messages.py')
        require(isinstance(base, dict) and set(base) == {'generator_sha256', 'dependency_sha256'}
                and isinstance(base['dependency_sha256'], dict) and set(base['dependency_sha256']) == roles,
                'Invalid union base dependency roles')
        require(all(isinstance(v, str) and re.fullmatch('[0-9a-f]{64}', v)
                    for v in [base['generator_sha256'], *base['dependency_sha256'].values()]),
                'Invalid union base producer digest')


def document(path, value):
    raw = evidence.encoded(value)
    require(len(raw) <= MAX_MANIFEST, 'Union manifest exceeds byte limit')
    evidence.put(path, raw)


def base_helper(root):
    manifest = evidence.decode(evidence.small(root / 'interface-messages.manifest.json', MAX_MANIFEST))
    schema = manifest.get('schema') if isinstance(manifest, dict) else None
    # Retained v1 singleton inputs are the only additional base shape needed.
    # A batch result is not recursively archived or silently flattened again.
    if schema == SCHEMA:
        return sys.modules[__name__]
    require(schema in (legacy.SCHEMA, v2.SCHEMA, v2.COMPLETE_SCHEMA),
            'Expected original v1/v2 or complete base capture')
    return legacy if schema == legacy.SCHEMA else v2


def base_profile(base):
    fields = ('schema', 'generator_sha256', 'keys')
    if base['schema'] == v2.COMPLETE_SCHEMA:
        fields = ('schema', 'generator_sha256', 'extra_keys', 'profile', 'api_core', 'coverage_sha256')
    return {key: base[key] for key in fields}


def base_bounds(profile):
    require(isinstance(profile, dict), 'Invalid base profile')
    schema = profile.get('schema')
    require(schema in (legacy.SCHEMA, v2.SCHEMA, v2.COMPLETE_SCHEMA), 'Unknown base profile schema')
    if schema == v2.COMPLETE_SCHEMA:
        # Current complete replay independently enforces its payload/TSV limits.
        # The archive allowance includes bounded tar headers and padding.
        return v2.COMPLETE_TOTAL_BYTES + (MAX_CHILD_FILES + 10) * 1024, v2.COMPLETE_TSV_BYTES
    return MAX_ARCHIVE, MAX_CHILD_FILE


def archive_base(root, output, helper, records):
    archive_limit, child_limit = base_bounds(base_profile(records['interface-messages']))
    inventory = helper.capture_artifacts(root / 'interface-messages.tsv', records['interface-messages'])
    require(len(inventory) <= MAX_CHILD_FILES, 'Too many base capture artifacts')
    total = 0
    with tarfile.open(output, 'x', format=tarfile.USTAR_FORMAT) as archive:
        for name, expected in sorted(inventory.items()):
            require(Path(name).name == name and name not in ('.', '..'), 'Invalid base artifact name')
            raw = evidence.small(root / name, child_limit)
            require(evidence.digest(raw) == expected, 'Base artifact changed before archive')
            total += len(raw) + 1024
            require(total <= archive_limit - 10240, 'Base archive exceeds byte limit')
            info = tarfile.TarInfo(name)
            info.size, info.mode, info.mtime = len(raw), 0o600, 0
            archive.addfile(info, io.BytesIO(raw))
    require(output.stat().st_size <= archive_limit, 'Base archive exceeds byte limit')
    return inventory


@contextmanager
def replay_base(root, profile):
    archive_limit, child_limit = base_bounds(profile)
    scratch = replay_scratch()
    scratch.mkdir(exist_ok=True)
    require(scratch.is_dir() and not scratch.is_symlink(), 'Unsafe replay scratch parent')
    with tempfile.TemporaryDirectory(prefix='language-message-replay-', dir=scratch) as tmp:
        target = Path(tmp)
        names, total = set(), 0
        # Release the authenticated archive buffer before verifying or yielding the extracted base.
        with io.BytesIO(evidence.small(root / ARCHIVE, archive_limit)) as archive_bytes, \
                tarfile.open(fileobj=archive_bytes, mode='r:') as archive:
            for member in archive:
                name = member.name
                require(member.isfile() and Path(name).name == name and name not in ('.', '..')
                        and name not in names and len(names) < MAX_CHILD_FILES,
                        'Invalid or duplicate base archive member')
                require(0 <= member.size <= child_limit, 'Base artifact exceeds byte limit')
                total += member.size
                require(total <= archive_limit, 'Base payload exceeds byte limit')
                stream = archive.extractfile(member)
                require(stream is not None, 'Missing base archive data')
                destination = target / name
                with stream, destination.open('xb') as output:
                    shutil.copyfileobj(stream, output, 256 * 1024)
                require(destination.stat().st_size == member.size, 'Truncated base archive member')
                names.add(name)
        helper = base_helper(target)
        require(helper is not sys.modules[__name__], 'Base archive must contain original capture evidence')
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


def selected_keys(record):
    if record.get('schema', SCHEMA) == SCHEMA:
        language, key = selection(record)
        return language, [key]
    require(record.get('schema') == BATCH_SCHEMA, 'Unknown message union schema')
    value = record.get('selection')
    require(isinstance(value, dict) and set(value) == {'language', 'keys'}, 'Invalid batch selection')
    language, keys = value['language'], value['keys']
    require(legacy.language_code(language) and isinstance(keys, list)
            and 1 <= len(keys) <= MAX_BATCH_KEYS and all(isinstance(key, str) for key in keys)
            and keys == sorted(set(keys)) and all(legacy.normalize_key(key) == key for key in keys),
            'Batch keys must be normalized, sorted, unique and bounded')
    return language, keys


def prior_names():
    return {COMPLETE, *(kind + '.manifest.json' for kind in KINDS),
            PREFIX + 'requested.json', PREFIX + '0001.request.json',
            *(PREFIX + f'0001-{attempt:02d}.' + suffix
              for attempt in range(1, 5) for suffix in ('raw.json', 'receipt.json'))}


def prior_source(root, record):
    return {'role': 'prior-singleton-message', 'evidence_prefix': PRIOR_PREFIX,
            'manifests': {kind + '.manifest.json': evidence.digest(evidence.small(
                root / (PRIOR_PREFIX + kind + '.manifest.json'), MAX_MANIFEST)) for kind in KINDS},
            'source': record['sources'][1]}


@contextmanager
def replay_prior(root, profile, base_root, base_records):
    """Replay the actual old singleton with one shared original base archive.

    Prior request/response/receipt/manifest bytes keep their original names and
    content in disposable replay scratch. Its old TSV is reconstructed from
    evidence, then the unchanged v1 verifier checks the complete old contract.
    """
    scratch = replay_scratch()
    with tempfile.TemporaryDirectory(prefix='language-message-prior-', dir=scratch) as tmp:
        target = Path(tmp)
        for name in prior_names():
            path = root / (PRIOR_PREFIX + name)
            if path.exists():
                (target / name).write_bytes(evidence.small(path, legacy.MAX_RESPONSE
                    if name.endswith('.raw.json') else MAX_MANIFEST))
        for name in (ARCHIVE, NAMESPACE):
            try:
                os.link(root / name, target / name)
            except OSError as error:
                if error.errno != errno.EXDEV:
                    raise
                # Replay scratch can be on another filesystem. The persistent
                # capture still stores one original archive; v1 replay checks
                # this bounded disposable copy against its original inventory.
                limit = base_bounds(profile)[0] if name == ARCHIVE else MAX_MANIFEST
                with (target / name).open('xb') as output:
                    output.write(evidence.small(root / name, limit))
        prior = evidence.decode(evidence.small(target / 'interface-messages.manifest.json', MAX_MANIFEST))
        require(isinstance(prior, dict) and prior.get('schema') == SCHEMA
                and prior.get('base_profile') == profile, 'Prior singleton base differs')
        base = base_records['interface-messages']
        observed, _ = observation(target, prior, base)
        language, key = selection(prior)
        child_limit = base_bounds(profile)[1]
        merged, _ = merged_messages(evidence.small(base_root / 'interface-messages.tsv', child_limit),
                                    observed, language, key, base)
        (target / 'interface-messages.tsv').write_bytes(merged)
        (target / 'language-fallbacks.tsv').write_bytes(
            evidence.small(base_root / 'language-fallbacks.tsv', child_limit))
        records = verify(target)
        yield merged, records['interface-messages']


def merged_messages(raw, observed, language, key, base):
    keys = [key] if isinstance(key, str) else key
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
    require(all((language, item) not in indexed for item in keys), 'Selection conflicts with existing base row')
    require(set(observed) == set(keys), 'Message response key set differs')
    for item in keys:
        extra = legacy.render_messages({(language, item): observed[item]}, base['wiki'], base['date'],
                                       base['content_language'])[len(header):]
        indexed[(language, item)] = extra
    return header + b''.join(indexed[k] for k in sorted(indexed)), len(indexed)


def observation(root, record, base):
    language, keys = selected_keys(record)
    require(language in base['fallback_languages'], 'Selected language absent from retained fallback inventory')
    requested = evidence.decode(evidence.small(root / (PREFIX + 'requested.json'), MAX_MANIFEST))
    expected = {'kind': 'messages', 'language': language, 'keys': keys}
    require(requested == expected, 'Singleton requested key set differs')
    batch = record.get('singleton' if record['schema'] == SCHEMA else 'batch')
    require(isinstance(batch, dict) and set(batch) == {'request', 'accepted_receipt'}, 'Missing singleton evidence')
    require(batch['request'] == PREFIX + '0001.request.json'
            and batch['accepted_receipt'] in [PREFIX + f'0001-{i:02d}.receipt.json' for i in range(1, 5)],
            'Singleton receipt identity differs')
    request = evidence.decode(evidence.small(root / batch['request'], MAX_MANIFEST))
    query = legacy.query_for(base['wiki'], language, keys)
    require(len(legacy.query_url(base['wiki'], query)) <= legacy.MAX_URL, 'Message batch URL exceeds bound')
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
    return legacy.parse_messages(evidence.decode(raw), language, keys, base['wiki'], base['content_language']), receipt


def owned_payload(root, profile, prior=False):
    """Inspect only this capture's names; other auxiliary snapshots share staging."""
    archive_limit, child_limit = base_bounds(profile)
    expected = {ARCHIVE, NAMESPACE, PREFIX + 'requested.json', PREFIX + '0001.request.json',
                *(kind + '.tsv' for kind in KINDS)}
    expected.update(PREFIX + f'0001-{attempt:02d}.' + suffix
                    for attempt in range(1, 5) for suffix in ('raw.json', 'receipt.json'))
    if prior:
        expected.update(PRIOR_PREFIX + name for name in prior_names())
    markers = {COMPLETE, *(kind + '.manifest.json' for kind in KINDS)}
    result = {}
    for path in root.iterdir():
        name = path.name
        if name in markers or not (name.startswith(PREFIX) or name in (kind + '.tsv' for kind in KINDS)):
            continue
        require(name in expected, 'Unexpected union-owned artifact')
        limit = archive_limit if name == ARCHIVE else child_limit
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
        require(isinstance(record, dict) and record.get('schema') in (SCHEMA, BATCH_SCHEMA) and record.get('kind') == kind
                and record.get('header_version') == 1, 'Union schema differs')
        records[kind], hashes[kind + '.manifest.json'] = record, evidence.digest(raw)
    if require_complete:
        require(evidence.decode(evidence.small(root / COMPLETE, MAX_MANIFEST)) ==
                {'schema': records['interface-messages']['schema'], 'manifests': hashes}, 'Union completion differs')
    record = records['interface-messages']
    per_output = {'kind', 'rows', 'output_bytes', 'output_sha256'}
    require({k: v for k, v in record.items() if k not in per_output} ==
            {k: v for k, v in records['language-fallbacks'].items() if k not in per_output}, 'Paired union manifests differ')
    validate_provenance(record.get('producer'))
    require(record.get('temporal_scope') == 'current-api-observation' and record.get('dump_date') is None
            and record.get('candidate_queries_complete') is True and record.get('corpus_query_closure_proven') is False
            and record.get('fallback_mode') == 'strict' and record.get('message_mode') == 'plain-with-database',
            'Union scope differs')
    profile = record.get('base_profile')
    _, child_limit = base_bounds(profile)
    prior = record.get('prior_singleton', False)
    require(type(prior) is bool and ('prior_singleton' in record) == (record['schema'] == BATCH_SCHEMA),
            'Invalid prior singleton state')
    inventory = owned_payload(root, profile, prior)
    require(inventory == record.get('artifacts'), 'Union artifact inventory differs')
    with replay_base(root, profile) as (base_root, base_records, base_inventory):
        base = base_records['interface-messages']
        require(profile == base_profile(base), 'Base profile differs')
        for key in ('wiki', 'date', 'content_language', 'namespace_registry_sha256'):
            require(record.get(key) == base[key], 'Union/base identity differs')
        namespace = evidence.small(base_root / NAMESPACE, MAX_MANIFEST)
        require(evidence.small(root / NAMESPACE, MAX_MANIFEST) == namespace, 'Union namespace differs from base')
        observed, receipt = observation(root, record, base)
        language, keys = selected_keys(record)
        original = evidence.small(base_root / 'interface-messages.tsv', child_limit)
        prior_sources = []
        if prior:
            with replay_prior(root, profile, base_root, base_records) as (original, old):
                prior_sources.append(prior_source(root, old))
        merged, rows = merged_messages(original, observed, language, keys, base)
        batch = record['singleton' if record['schema'] == SCHEMA else 'batch']
        expected_sources = [
            {'role': 'base-capture', 'schema': base['schema'], 'archive': ARCHIVE,
             'manifests': {k + '.manifest.json': base_inventory[k + '.manifest.json'] for k in KINDS},
             'retrieved_utc': base['retrieved_utc']},
            *prior_sources,
            {'role': 'singleton-message' if record['schema'] == SCHEMA else 'message-batch',
             **batch, 'retrieved_utc': receipt['ended_utc']}]
        require(record.get('sources') == expected_sources, 'Multiple-source provenance differs')
        outputs = {'interface-messages': (merged, rows),
                   'language-fallbacks': (evidence.small(base_root / 'language-fallbacks.tsv', child_limit),
                                          base_records['language-fallbacks']['rows'])}
        for kind, (raw, count) in outputs.items():
            current = records[kind]
            require(evidence.small(root / (kind + '.tsv'), child_limit) == raw
                    and current.get('rows') == count and current.get('output_bytes') == len(raw)
                    and current.get('output_sha256') == evidence.digest(raw), 'Union TSV differs from source evidence')
    require(owned_payload(root, profile, prior) == inventory, 'Union changed during verification')
    return records


def capture(args, transport=None, sleep=time.sleep):
    require(1 <= args.wall_seconds <= 900 and 0 <= args.delay <= 60, 'Invalid bounded capture settings')
    helper = base_helper(args.base)
    base_records = helper.verify(args.base)
    base = base_records['interface-messages']
    prior = base['schema'] == SCHEMA
    messages = getattr(args, 'messages', None)
    schema = BATCH_SCHEMA if messages is not None or prior else SCHEMA
    selected = {'schema': schema, 'selection': ({'language': args.language, 'key': args.message}
        if schema == SCHEMA else {'language': args.language, 'keys': messages if messages is not None else [args.message]})}
    language, keys = selected_keys(selected)
    profile = base['base_profile'] if prior else base_profile(base)
    _, child_limit = base_bounds(profile)
    # Reject duplicate/conflicting selections before any output or network work.
    merged_messages(evidence.small(args.base / 'interface-messages.tsv', child_limit),
                    dict.fromkeys(keys), language, keys, base)
    fallback_raw = evidence.small(args.base / 'language-fallbacks.tsv', child_limit)
    require(any(row.split(b'\t', 1)[0] == language.encode() for row in fallback_raw.splitlines()
                if row and not row.startswith(b'#')), 'Selected language absent from retained fallback inventory')
    require(len(legacy.query_url(base['wiki'], legacy.query_for(base['wiki'], language, keys))) <= legacy.MAX_URL,
            'Message batch URL exceeds bound')
    identity = producer()
    root = args.output
    root.mkdir(parents=True, exist_ok=False)
    try:
        if prior:
            base_inventory = helper.capture_artifacts(args.base / 'interface-messages.tsv', base)
            evidence.put(root / ARCHIVE, evidence.small(args.base / ARCHIVE, base_bounds(profile)[0]))
            for name in prior_names():
                if name in base_inventory:
                    evidence.put(root / (PRIOR_PREFIX + name), evidence.small(args.base / name,
                        legacy.MAX_RESPONSE if name.endswith('.raw.json') else MAX_MANIFEST))
        else:
            base_inventory = archive_base(args.base, root / ARCHIVE, helper, base_records)
        evidence.put(root / NAMESPACE, evidence.small(args.base / NAMESPACE, MAX_MANIFEST))
        specification = {'kind': 'messages', 'language': language, 'keys': keys}
        evidence.document(root / (PREFIX + 'requested.json'), specification)
        observed, batch = legacy.request_observation(root, 1, base['wiki'], base['content_language'], specification,
            transport or evidence.get_response, sleep, args.delay, time.monotonic() + args.wall_seconds)
        receipt = evidence.decode(evidence.small(root / batch['accepted_receipt'], MAX_MANIFEST))
        merged, count = merged_messages(evidence.small(args.base / 'interface-messages.tsv', child_limit),
                                       observed, language, keys, base)
        outputs = {'interface-messages': (merged, count),
                   'language-fallbacks': (evidence.small(args.base / 'language-fallbacks.tsv', child_limit),
                                          base_records['language-fallbacks']['rows'])}
        for kind, (raw, _) in outputs.items():
            evidence.put(root / (kind + '.tsv'), raw)
        require(helper.capture_artifacts(args.base / 'interface-messages.tsv', base) == base_inventory
                and producer() == identity, 'Base capture or collector changed')
        sources = ([base['sources'][0], prior_source(root, base)] if prior else
            [{'role': 'base-capture', 'schema': base['schema'], 'archive': ARCHIVE,
              'manifests': {k + '.manifest.json': base_inventory[k + '.manifest.json'] for k in KINDS},
              'retrieved_utc': base['retrieved_utc']}])
        sources.append({'role': 'singleton-message' if schema == SCHEMA else 'message-batch',
                        **batch, 'retrieved_utc': receipt['ended_utc']})
        common = {'header_version': 1, 'producer': identity, **selected,
            **{k: base[k] for k in ('wiki', 'date', 'content_language', 'namespace_registry_sha256')},
            'dump_date': None, 'temporal_scope': 'current-api-observation',
            ('singleton' if schema == SCHEMA else 'batch'): batch,
            'candidate_queries_complete': True, 'corpus_query_closure_proven': False,
            'fallback_mode': 'strict', 'message_mode': 'plain-with-database',
            'artifacts': owned_payload(root, profile, prior),
            'base_profile': profile,
            'sources': sources}
        if schema == BATCH_SCHEMA:
            common['prior_singleton'] = prior
        for kind, (raw, rows) in outputs.items():
            document(root / (kind + '.manifest.json'), {**common, 'kind': kind, 'rows': rows,
                'output_bytes': len(raw), 'output_sha256': evidence.digest(raw)})
        verify(root, require_complete=False)
        document(root / COMPLETE, {'schema': schema, 'manifests': {k + '.manifest.json':
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
            and isinstance(keys, list) and 1 <= len(keys) <= 67
            and 'parser-template-loop-warning' in keys,
            'Preferred loop union requires replayed v2 base and loop-warning key')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    collect = commands.add_parser('capture')
    collect.add_argument('--base', required=True, type=Path)
    collect.add_argument('--language', required=True)
    choice = collect.add_mutually_exclusive_group(required=True)
    choice.add_argument('--message')
    choice.add_argument('--messages', nargs='+', help='Sorted unique literal keys; one bounded authoritative request')
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
