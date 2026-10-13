#!/usr/bin/env python3
"""Strict streaming union of independently replayable v2 file-metadata captures.

Network collection remains in prepare_file_metadata_v2 with its original limits.
This helper archives unchanged captures and never promotes an inventory to corpus
query closure. Only one child capture is extracted and replayed at a time.
"""
import argparse
from contextlib import ExitStack
import hashlib
import heapq
from pathlib import Path
import re
import shutil
import tarfile
import tempfile

import prepare_file_metadata_v2 as v2

SCHEMA = 'wikidict.file-metadata-union.v1'
MANIFEST, COMPLETE, EVIDENCE = v2.MANIFEST, v2.COMPLETE, v2.EVIDENCE
NAMESPACE = v2.NAMESPACE
INVENTORY = 'file-metadata.inventory.txt'
TSV = 'file-metadata.tsv'
MAX_MANIFEST = v2.MAX_MANIFEST
MAX_INDEX = 1024 * 1024
# Complete dated EN inventory plus all prior observations: 1,203,769 + 3,533.
MAX_ROWS = 1_207_302
MAX_TSV = 256 * 1024 * 1024
MAX_INVENTORY = 64 * 1024 * 1024
MAX_CAPTURES = 128
MAX_CHILD_ROWS = 10_000
MAX_ARCHIVE = 128 * 1024 * 1024
MAX_ARCHIVE_FILES = 4096
MAX_ARCHIVE_PAYLOAD = 128 * 1024 * 1024
MAX_ROW_BYTES = 16384
small = v2.small


def require(condition, message):
    if not condition:
        raise ValueError(message)


def producer():
    return {'generator_sha256': v2.digest(small(Path(__file__))),
            'capture_producer': v2.producer()}


def file_record(path, limit):
    before = v2.evidence.stamp(path)
    require(before[2] <= limit, 'Union artifact exceeds byte limit')
    digest = hashlib.sha256()
    total = 0
    with path.open('rb') as source:
        for raw in iter(lambda: source.read(1024 * 1024), b''):
            total += len(raw)
            require(total <= limit, 'Union artifact exceeds byte limit')
            digest.update(raw)
    require(v2.evidence.stamp(path) == before, 'Union artifact changed while reading')
    return {'size': total, 'sha256': digest.hexdigest()}


def artifact_limit(name):
    if name == TSV:
        return MAX_TSV
    if name == INVENTORY:
        return MAX_INVENTORY
    if name == NAMESPACE:
        return MAX_MANIFEST
    if re.fullmatch(r'file-metadata\.capture-\d{4}\.tar', name):
        return MAX_ARCHIVE
    raise ValueError('Unexpected union artifact name')


def payload(root):
    return {p.name: file_record(p, artifact_limit(p.name))
            for p in sorted(root.iterdir())
            if p.name.startswith(v2.PREFIX) and p.name not in (MANIFEST, COMPLETE, EVIDENCE)}


def document(path, value, limit):
    raw = v2.encoded(value)
    require(len(raw) <= limit, 'Union document exceeds byte limit')
    with path.open('xb') as out:
        out.write(raw)


def inventory_rows(path):
    previous = None
    count = 0
    total = 0
    with path.open('rb') as source:
        while raw := source.readline(4098):
            total += len(raw)
            require(total <= MAX_INVENTORY and raw.endswith(b'\n') and len(raw) <= 4097,
                    'Oversized or unterminated union inventory row')
            title = raw[:-1]
            title.decode('utf-8')
            require(title and not any(c in title for c in (b'\0', b'\t', b'\r')),
                    'Unsafe union inventory title')
            require(previous is None or previous < title, 'Union inventory is not unique and sorted')
            count += 1
            require(count <= MAX_ROWS, 'Union inventory exceeds row limit')
            previous = title
            yield title


def tsv_rows(path):
    with path.open('rb') as source:
        require(source.readline(256) == (v2.HEADER + '\n').encode(), 'Union child TSV header differs')
        previous = None
        while raw := source.readline(MAX_ROW_BYTES + 1):
            require(raw.endswith(b'\n') and len(raw) <= MAX_ROW_BYTES, 'Oversized child TSV row')
            fields = raw[:-1].split(b'\t')
            require(len(fields) == 6 and fields[1] in (b'0', b'1'), 'Invalid child TSV row')
            require(previous is None or previous < fields[0], 'Child TSV is not unique and sorted')
            previous = fields[0]
            yield fields[0], raw, fields[1] == b'1'


def merge_rows(snapshots, inventory, output=None, existing=None):
    require((output is None) != (existing is None), 'Select writing or exact comparison')
    expected = iter(inventory_rows(inventory))
    count = positive = 0
    total = len(v2.HEADER.encode()) + 1
    digest = hashlib.sha256((v2.HEADER + '\n').encode())
    previous = None
    with ExitStack() as stack:
        target = stack.enter_context(output.open('xb') if output else existing.open('rb'))
        header = (v2.HEADER + '\n').encode()
        if output:
            target.write(header)
        else:
            require(target.readline(256) == header, 'Union TSV header differs')
        for title, raw, present in heapq.merge(*(tsv_rows(p) for p in snapshots)):
            require(previous is None or previous < title, 'Duplicate title across captures')
            require(next(expected, None) == title, 'Union differs from complete selected inventory')
            count += 1
            positive += present
            total += len(raw)
            require(count <= MAX_ROWS and total <= MAX_TSV, 'Union TSV capacity exceeded')
            digest.update(raw)
            if output:
                target.write(raw)
            else:
                require(target.readline(MAX_ROW_BYTES + 1) == raw, 'Union TSV differs from replayed captures')
            previous = title
        require(count > 0 and next(expected, None) is None, 'Uncovered union inventory title')
        if existing:
            require(target.read(1) == b'', 'Unexpected trailing union TSV bytes')
    return {'rows': count, 'positive_rows': positive, 'negative_rows': count - positive,
            'output_bytes': total, 'output_sha256': digest.hexdigest()}


def child_identity(root, wiki, date, namespace_sha):
    record = v2.decode(small(root / MANIFEST, v2.MAX_MANIFEST))
    require(type(record.get('rows')) is int and 0 < record['rows'] <= MAX_CHILD_ROWS,
            'Child capture row capacity exceeded')
    require(record.get('wiki') == wiki and record.get('date') == date
            and record.get('namespace_registry_sha256') == namespace_sha,
            'Child capture edition/date/namespace mismatch')
    verified = v2.verify(root)
    require(verified == record, 'Child manifest changed during replay')
    return record


def archive_capture(root, destination, record):
    inventory = v2.capture_artifacts(root / TSV, record)
    require(len(inventory) <= MAX_ARCHIVE_FILES, 'Too many child archive files')
    total = 0
    with tarfile.open(destination, 'x', format=tarfile.USTAR_FORMAT) as archive:
        for name, expected_sha in sorted(inventory.items()):
            v2.safe_name(name)
            path = root / name
            found = file_record(path, v2.MAX_METADATA)
            require(found['sha256'] == expected_sha, 'Child changed before archive')
            total += found['size']
            require(total <= MAX_ARCHIVE_PAYLOAD, 'Child archive payload exceeds capacity')
            info = tarfile.TarInfo(name)
            info.size, info.mode, info.mtime = found['size'], 0o600, 0
            with path.open('rb') as source:
                archive.addfile(info, source)
            require(file_record(path, v2.MAX_METADATA) == found, 'Child changed during archive')
    return file_record(destination, MAX_ARCHIVE)


def extract_capture(archive_path, root):
    names = set()
    total = 0
    with tarfile.open(archive_path, 'r|') as archive:
        for member in archive:
            name = v2.safe_name(member.name)
            require(member.isfile() and name not in names and len(names) < MAX_ARCHIVE_FILES,
                    'Unsafe or duplicate child archive member')
            require(0 <= member.size <= v2.MAX_METADATA, 'Oversized child archive member')
            total += member.size
            require(total <= MAX_ARCHIVE_PAYLOAD, 'Child archive payload exceeds capacity')
            names.add(name)
            source = archive.extractfile(member)
            require(source is not None, 'Missing child archive data')
            with source, (root / name).open('xb') as output:
                shutil.copyfileobj(source, output, 1024 * 1024)
            require((root / name).stat().st_size == member.size, 'Truncated child archive member')


def read_manifest(root, require_complete=True):
    require(not root.is_symlink() and root.is_dir(), 'Unsafe union root')
    raw = small(root / MANIFEST, MAX_MANIFEST)
    manifest = v2.decode(raw)
    require(isinstance(manifest, dict) and manifest.get('schema') == SCHEMA
            and manifest.get('header_version') == 2, 'Union schema mismatch')
    require(all(manifest.get(k) == value for k, value in producer().items()), 'Union producer changed')
    require(manifest.get('dump_date') is None
            and manifest.get('temporal_scope') == 'current-api-observation'
            and manifest.get('source_url') == v2.wiktionary_api(manifest['wiki'])
            and manifest.get('candidate_queries_complete') is True
            and manifest.get('corpus_query_closure_proven') is False
            and manifest.get('unknown_rows') == 0, 'Invalid union scope')
    if require_complete:
        require(v2.decode(small(root / COMPLETE, MAX_MANIFEST)) ==
                {'schema': SCHEMA, 'manifest_sha256': v2.digest(raw)}, 'Union completion mismatch')
    return manifest


def evidence_index(root, manifest):
    raw = small(root / EVIDENCE, MAX_INDEX)
    require(manifest.get('evidence') == {'path': EVIDENCE, 'size': len(raw), 'sha256': v2.digest(raw)},
            'Union evidence identity changed')
    index = v2.decode(raw)
    require(isinstance(index, dict) and set(index) == {'captures', 'artifacts'}, 'Invalid union index')
    captures = index['captures']
    require(isinstance(captures, list) and 1 <= len(captures) <= MAX_CAPTURES, 'Union capture capacity exceeded')
    expected = {TSV, INVENTORY, NAMESPACE}
    for number, row in enumerate(captures):
        name = 'file-metadata.capture-%04d.tar' % number
        require(isinstance(row, dict) and set(row) == {'path', 'manifest_sha256', 'rows'}
                and row['path'] == name and type(row['rows']) is int and 0 < row['rows'] <= MAX_CHILD_ROWS
                and isinstance(row['manifest_sha256'], str)
                and re.fullmatch('[0-9a-f]{64}', row['manifest_sha256']), 'Invalid union child reference')
        expected.add(name)
    require(isinstance(index['artifacts'], dict) and set(index['artifacts']) == expected
            and payload(root) == index['artifacts'], 'Union artifact inventory changed')
    require(index['artifacts'][NAMESPACE]['sha256'] == manifest.get('namespace_registry_sha256'),
            'Union namespace changed')
    return index


def verify(root, require_complete=True):
    root = Path(root)
    manifest = read_manifest(root, require_complete)
    index = evidence_index(root, manifest)
    with tempfile.TemporaryDirectory(prefix='wikidict-file-union-') as directory:
        temporary = Path(directory)
        snapshots = []
        for number, row in enumerate(index['captures']):
            with tempfile.TemporaryDirectory(dir=temporary) as child:
                child = Path(child)
                archive = root / row['path']
                extract_capture(archive, child)
                require(v2.digest(small(child / MANIFEST, MAX_MANIFEST)) == row['manifest_sha256'],
                        'Archived child manifest differs')
                record = child_identity(child, manifest['wiki'], manifest['date'],
                                        manifest['namespace_registry_sha256'])
                require(record['rows'] == row['rows'], 'Archived child row count differs')
                snapshot = temporary / ('part-%04d.tsv' % number)
                shutil.copyfile(child / TSV, snapshot)
                snapshots.append(snapshot)
                require(file_record(archive, MAX_ARCHIVE) == index['artifacts'][row['path']],
                        'Archive changed during replay')
        totals = merge_rows(snapshots, root / INVENTORY, existing=root / TSV)
    require(all(manifest.get(k) == value for k, value in totals.items()), 'Union totals differ')
    require(read_manifest(root, require_complete) == manifest
            and payload(root) == index['artifacts'], 'Union changed during replay')
    return manifest


def compose(captures, inventory, output, wiki, date):
    require(1 <= len(captures) <= MAX_CAPTURES, 'Union capture capacity exceeded')
    require(len({Path(p).resolve() for p in captures}) == len(captures), 'Duplicate capture root')
    require(sum(1 for _ in inventory_rows(inventory)) > 0, 'Empty union inventory')
    output.mkdir(parents=True, exist_ok=False)
    shutil.copyfile(inventory, output / INVENTORY)
    identity = producer()
    namespace_raw = small(Path(captures[0]) / NAMESPACE, MAX_MANIFEST)
    namespace_sha = v2.digest(namespace_raw)
    (output / NAMESPACE).write_bytes(namespace_raw)
    rows, snapshots, dates = [], [], []
    try:
        for number, root in enumerate(map(Path, captures)):
            record = child_identity(root, wiki, date, namespace_sha)
            archive = output / ('file-metadata.capture-%04d.tar' % number)
            archive_capture(root, archive, record)
            rows.append({'path': archive.name, 'manifest_sha256': v2.digest(small(root / MANIFEST, MAX_MANIFEST)),
                         'rows': record['rows']})
            snapshots.append(root / TSV)
            dates.append((record['started_utc'], record['retrieved_utc']))
        totals = merge_rows(snapshots, output / INVENTORY, output=output / TSV)
        index = {'captures': rows, 'artifacts': payload(output)}
        document(output / EVIDENCE, index, MAX_INDEX)
        evidence_raw = small(output / EVIDENCE, MAX_INDEX)
        manifest = {'schema': SCHEMA, 'header_version': 2, 'wiki': wiki, 'date': date,
                    'dump_date': None, 'temporal_scope': 'current-api-observation',
                    'source_url': v2.wiktionary_api(wiki), **identity,
                    'started_utc': min(x[0] for x in dates), 'retrieved_utc': max(x[1] for x in dates),
                    'namespace_registry_sha256': namespace_sha,
                    'evidence': {'path': EVIDENCE, 'size': len(evidence_raw), 'sha256': v2.digest(evidence_raw)},
                    **totals, 'unknown_rows': 0, 'candidate_queries_complete': True,
                    'corpus_query_closure_proven': False}
        require(producer() == identity, 'Union producer changed during composition')
        document(output / MANIFEST, manifest, MAX_MANIFEST)
        verify(output, require_complete=False)
        document(output / COMPLETE, {'schema': SCHEMA, 'manifest_sha256': v2.digest(small(output / MANIFEST))}, MAX_MANIFEST)
        return manifest
    except BaseException:
        # An incomplete output remains unselected, without a completion marker.
        raise


def validate_snapshot(path, edition=None, date=None):
    path = Path(path)
    require(path.name == TSV and not path.is_symlink(), 'Invalid union snapshot path')
    manifest = verify(path.parent)
    require((edition is None or manifest['wiki'] == edition) and
            (date is None or manifest['date'] == date), 'Union edition/date mismatch')
    return manifest


def capture_artifacts(path, manifest):
    root = Path(path).parent
    require(read_manifest(root) == manifest, 'Union manifest changed')
    index = evidence_index(root, manifest)
    result = {name: row['sha256'] for name, row in index['artifacts'].items()}
    for name, limit in ((MANIFEST, MAX_MANIFEST), (COMPLETE, MAX_MANIFEST), (EVIDENCE, MAX_INDEX)):
        result[name] = file_record(root / name, limit)['sha256']
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    check = commands.add_parser('verify')
    check.add_argument('root', type=Path)
    make = commands.add_parser('compose')
    make.add_argument('--capture', action='append', type=Path, required=True)
    make.add_argument('--inventory', type=Path, required=True)
    make.add_argument('--output', type=Path, required=True)
    make.add_argument('--wiki', required=True)
    make.add_argument('--date', required=True)
    args = parser.parse_args()
    result = (verify(args.root) if args.command == 'verify' else
              compose(args.capture, args.inventory, args.output, args.wiki, args.date))
    print(v2.encoded(result).decode(), end='')


if __name__ == '__main__':
    main()
