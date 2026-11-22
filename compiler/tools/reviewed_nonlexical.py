"""Optional reviewed source dispositions; immutable inputs and data-only publication."""
import hashlib
import json
from pathlib import Path

NAME = 'reviewed-nonlexical.json'
SOURCE_SCHEMA = 'wikidict.reviewed-nonlexical-source.v1'
SCHEMA = 'wikidict.reviewed-nonlexical.v1'


def require(ok, message):
    if not ok:
        raise ValueError(message)


def digest(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def hex_digest(value):
    return isinstance(value, str) and len(value) == 64 and all(c in '0123456789abcdef' for c in value)


def read_bytes(path):
    path = Path(path)
    require(path.is_absolute() and not any(p.is_symlink() for p in (path, *path.parents)), 'Unsafe review path')
    before = path.stat()
    require(before.st_size <= 8 * 1024**2, 'Review exceeds size limit')
    raw = path.read_bytes()
    after = path.stat()
    require(all(getattr(before, k) == getattr(after, k) for k in ('st_dev', 'st_ino', 'st_size', 'st_mtime_ns', 'st_ctime_ns')), 'Review changed during read')
    return raw


def read(path):
    raw = read_bytes(path)
    return raw, json.loads(raw)


def rows(record, reasons):
    require(isinstance(record.get('rows'), list) and record['rows'], 'Missing reviewed rows')
    result = []
    ids = set()
    fields = {'namespace', 'page_id', 'revision_id', 'title', 'decoded_source_sha256'}
    for row in record['rows']:
        require(isinstance(row, dict) and set(row) == fields | ({'reason'} if reasons else set()), 'Invalid reviewed row fields')
        require(type(row['namespace']) is int and row['namespace'] == 0, 'Review requires namespace zero')
        for name in ('page_id', 'revision_id'):
            require(type(row[name]) is int and 0 < row[name] < 2**64, 'Invalid reviewed identity')
        require(row['page_id'] not in ids, 'Duplicate reviewed page')
        ids.add(row['page_id'])
        require(isinstance(row['title'], str) and bool(row['title']) and hex_digest(row['decoded_source_sha256']), 'Invalid reviewed title or source digest')
        if reasons:
            require(row['reason'] in ('nonlexical_site_notice', 'nonlexical_site_navigation'), 'Invalid reviewed reason')
        result.append({key: row[key] for key in sorted(fields)})
    return sorted(result, key=lambda row: row['page_id'])


def load_review(path, items, namespace):
    if path is None:
        return None
    raw, record = read(path)
    require(record.get('schema') == SOURCE_SCHEMA, 'Invalid source review schema')
    require(set(record) == {'schema', 'wiki', 'date', 'input_files', 'namespace_registry_sha256', 'rows', 'review_evidence'}, 'Invalid source review scope fields')
    require(items and (record.get('wiki'), record.get('date')) == (items[0]['wiki'], items[0]['date']), 'Foreign source review')
    expected = sorted([[i['wiki'], i['date'], i['name'], i['size'], i['sha1']] for i in items])
    require(record.get('input_files') == expected, 'Source review input selection differs')
    require(record.get('namespace_registry_sha256') == digest(namespace), 'Source review namespace registry differs')
    selected = rows(record, True)
    evidence = record.get('review_evidence')
    require(isinstance(evidence, list) and evidence, 'Missing source review evidence')
    for descriptor in evidence:
        require(isinstance(descriptor, dict) and set(descriptor) == {'path', 'bytes', 'sha256'}, 'Invalid review evidence descriptor')
        evidence_raw = read_bytes(descriptor['path'])
        require(len(evidence_raw) == descriptor['bytes'] and hashlib.sha256(evidence_raw).hexdigest() == descriptor['sha256'], 'Review evidence changed')
    return dict(path=str(Path(path)), raw=raw, sha256=hashlib.sha256(raw).hexdigest(), record=record, rows=selected)


def pin_review(review, destination):
    require(read(review['path'])[0] == review['raw'], 'Source review changed')
    destination = Path(destination)
    if destination.exists():
        require(read(destination)[0] == review['raw'], 'Pinned source review differs')
    else:
        with destination.open('xb') as stream:
            stream.write(review['raw'])
    return destination


def materialize(review, dump, index, destination):
    record = review['record']
    value = dict(schema=SCHEMA, wiki=record['wiki'], date=record['date'],
                 namespace_registry_sha256=record['namespace_registry_sha256'],
                 dump_sha256=digest(dump), page_index_sha256=digest(index),
                 source_review_sha256=review['sha256'], rows=review['rows'])
    raw = (json.dumps(value, sort_keys=True, separators=(',', ':')) + '\n').encode()
    destination = Path(destination)
    if destination.exists():
        require(read(destination)[0] == raw, 'Execution review differs')
    else:
        with destination.open('xb') as stream:
            stream.write(raw)
    return destination


def bind_identity(root, identity, review):
    path = Path(root) / NAME
    if review is None:
        require(not path.exists() and not path.is_symlink(), 'Unexpected reviewed publication')
        return
    raw, record = read(path)
    expected = review['record']
    require(set(record) == {'schema', 'wiki', 'date', 'namespace_registry_sha256', 'dump_sha256', 'page_index_sha256', 'source_review_sha256', 'rows'}, 'Invalid execution review fields')
    require(record['schema'] == SCHEMA and (record['wiki'], record['date']) == (expected['wiki'], expected['date']), 'Foreign execution review')
    require(record['source_review_sha256'] == review['sha256'] and record['namespace_registry_sha256'] == expected['namespace_registry_sha256'], 'Execution review authority differs')
    require(rows(record, False) == review['rows'], 'Execution review rows differ')
    require(hex_digest(record['dump_sha256']) and hex_digest(record['page_index_sha256']), 'Invalid execution input digests')
    identity['reviewed_nonlexical_sha256'] = hashlib.sha256(raw).hexdigest()


def check_unreviewed(root, coverage, identity):
    require(not identity or (identity.get('reviewed_nonlexical_source_review_sha256') is None and identity.get('reviewed_nonlexical_sha256') is None), 'Missing or conflicting review execution identity')
    require(not (Path(root)/NAME).exists() and not (Path(root)/NAME).is_symlink(), 'Unexpected reviewed publication')
    require(coverage.get('version') == 1 and 'reviewed_nonlexical_sha256' not in coverage and 'reviewed_nonlexical_page_ids' not in coverage and
            all('reviewed_nonlexical_rows' not in row for row in coverage.get('namespaces', [])), 'Unexpected reviewed coverage')


def check_coverage(root, identity):
    _, coverage = read(Path(root) / 'namespace-coverage.json')
    expected = identity.get('reviewed_nonlexical_sha256') if identity else None
    if expected is None:
        check_unreviewed(root, coverage, identity)
        return
    raw, record = read(Path(root) / NAME)
    require(hashlib.sha256(raw).hexdigest() == expected and record['source_review_sha256'] == identity['reviewed_nonlexical_source_review_sha256'], 'Published review identity differs')
    ids = sorted(row['page_id'] for row in rows(record, False))
    reported = coverage.get('reviewed_nonlexical_page_ids')
    require(isinstance(reported, list) and all(type(page) is int for page in reported), 'Invalid reviewed coverage page IDs')
    require(coverage.get('version') == 2 and coverage.get('reviewed_nonlexical_sha256') == expected and coverage.get('reviewed_nonlexical_page_ids') == ids, 'Reviewed coverage identity differs')
    total = 0
    for row in coverage['namespaces']:
        count = row.get('reviewed_nonlexical_rows')
        require(type(count) is int and count >= 0 and (count == 0 or (row['id'] == 0 and row.get('kind') == 'language')), 'Invalid reviewed coverage count')
        for field in ('input_rows', 'compile_only_rows', 'source_unavailable_rows', 'site_metadata_rows', 'dispatched_rows', 'expanded_pages', 'fallback_pages', 'duplicate_rows'):
            require(type(row.get(field)) is int and 0 <= row[field] < 2**64, 'Invalid coverage counter')
        require(row['input_rows'] == row['compile_only_rows'] + row['source_unavailable_rows'] + row['site_metadata_rows'] + count + row['dispatched_rows'] and
                row['dispatched_rows'] == row['expanded_pages'] + row['fallback_pages'] + row['duplicate_rows'], 'Incomplete reviewed coverage accounting')
        total += count
    require(total == len(ids), 'Reviewed coverage is incomplete')


def check_publication(root):
    """Scanner binding to a normal builder's publication or sealed staging identity."""
    root = Path(root).absolute()
    coverage = json.loads((root/'namespace-coverage.json').read_text())
    if coverage.get('version') == 1:
        identity = None
        if (root/'complete.json').exists():
            complete = json.loads((root/'complete.json').read_text())
            identity = complete.get('build_inputs')
        elif (root/'.build-inputs.json').exists():
            identity = json.loads((root/'.build-inputs.json').read_text())
        check_unreviewed(root, coverage, identity)
        return
    raw, manifest = read(root / NAME)
    complete_path = root / 'complete.json'
    if complete_path.exists():
        _, complete = read(complete_path)
        identity = complete['build_inputs']
        selected = complete['publication_files'][NAME]
        require(selected == {'size': len(raw), 'sha256': hashlib.sha256(raw).hexdigest()}, 'Review publication inventory differs')
        require((manifest['wiki'], manifest['date']) == (complete['edition'], complete['date']), 'Review publication edition differs')
    else:
        _, identity = read(root / '.build-inputs.json')
    require(hex_digest(identity.get('reviewed_nonlexical_sha256')), 'Missing review execution identity')
    require(set(manifest) == {'schema', 'wiki', 'date', 'namespace_registry_sha256', 'dump_sha256', 'page_index_sha256', 'source_review_sha256', 'rows'}, 'Invalid execution review fields')
    require(identity.get('files') and all(row[:2] == [manifest['wiki'], manifest['date']] for row in identity['files']), 'Review selected edition differs')
    require(manifest.get('schema') == SCHEMA and manifest.get('namespace_registry_sha256') == coverage.get('registry_sha256'), 'Review publication namespace differs')
    require(hex_digest(manifest.get('dump_sha256')) and hex_digest(manifest.get('page_index_sha256')) and hex_digest(identity.get('reviewed_nonlexical_source_review_sha256')), 'Missing review input authority')
    check_coverage(root, identity)
