#!/usr/bin/env python3
"""Prepare partial current-page item lookups from pinned SQL and explicit API observations.

Local page_props positives have precedence. An absent SQL row does not mean
unlinked: the upstream API also checks repository sitelinks. Only a replayed,
exact-title repository negative can produce a '-' record; all other missing
rows remain missing metadata in the native provider.
"""
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import urllib.parse

from category_tree_snapshot import rows

NAME = 'wikibase-page-links'
SCHEMA = 'wikidict-wikibase-page-links-v1'
HEADER = b'# wikidict-wikibase-page-links-v1\tpartial\n'
MAX_ROWS = 4_000_000
MAX_OUTPUT_BYTES = 256 * 1024 * 1024
MAX_PROOF_BYTES = 4 * 1024 * 1024
MAX_REQUESTS = 1024
SOURCE_FIELDS = ('wiki', 'date', 'name', 'url', 'size', 'sha1')
ENTITY = re.compile(r'Q[1-9][0-9]*')
PRODUCER_SHA256 = hashlib.sha256(Path(__file__).read_bytes()).hexdigest()


def digest(raw):
    return hashlib.sha256(raw).hexdigest()


def document(value):
    return (json.dumps(value, ensure_ascii=False, sort_keys=True, indent=2, allow_nan=False) + '\n').encode()


def parse(raw):
    def unique(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError('Duplicate page-link JSON key')
            result[key] = value
        return result
    return json.loads(raw, object_pairs_hook=unique,
                      parse_constant=lambda value: (_ for _ in ()).throw(ValueError('Nonfinite JSON')))


def regular(path, limit=MAX_PROOF_BYTES):
    path = Path(path)
    if path.is_symlink() or not path.is_file() or path.stat().st_size > limit:
        raise ValueError('Missing, unsafe or oversized page-link artifact: ' + str(path))
    with path.open('rb') as stream:
        raw = stream.read(limit + 1)
    if len(raw) > limit:
        raise ValueError('Page-link artifact exceeded byte limit')
    return raw


def page_id(value):
    if type(value) is not int or not 0 < value <= (1 << 64) - 1:
        raise ValueError('Invalid page-link page ID')
    return value


def entity_id(value):
    if not isinstance(value, str) or not ENTITY.fullmatch(value) or len(value) > 11 or int(value[1:]) > 2147483647:
        raise ValueError('Invalid page-link entity ID')
    return value


def wire(records):
    if len(records) > MAX_ROWS:
        raise ValueError('Too many page-link rows')
    out = bytearray(HEADER)
    for key in sorted(records):
        page_id(key)
        value = records[key]
        out.extend((str(key) + '\t' + ('-' if value is None else entity_id(value)) + '\n').encode())
        if len(out) > MAX_OUTPUT_BYTES:
            raise ValueError('Page-link output exceeds byte limit')
    out.extend(('# end\t' + str(len(records)) + '\n').encode())
    return bytes(out)


def read_wire(raw):
    if len(raw) > MAX_OUTPUT_BYTES or not raw.startswith(HEADER) or not raw.endswith(b'\n'):
        raise ValueError('Invalid page-link framing')
    lines = raw[len(HEADER):].splitlines()
    if not lines or not re.fullmatch(rb'# end\t(?:0|[1-9][0-9]*)', lines[-1]):
        raise ValueError('Missing page-link completion footer')
    result = {}
    previous = 0
    for line in lines[:-1]:
        fields = line.split(b'\t')
        if len(fields) != 2 or not re.fullmatch(rb'[1-9][0-9]*', fields[0]):
            raise ValueError('Invalid page-link row')
        key = page_id(int(fields[0]))
        if key <= previous:
            raise ValueError('Unsorted or duplicate page-link row')
        result[key] = None if fields[1] == b'-' else entity_id(fields[1].decode('ascii'))
        previous = key
        if len(result) > MAX_ROWS:
            raise ValueError('Too many page-link rows')
    if int(lines[-1].split(b'\t')[1]) != len(result) or wire(result) != raw:
        raise ValueError('Page-link row count or canonical framing mismatch')
    return result


def expected_params(wiki, title):
    return dict(action='wbgetentities', format='json', formatversion='2',
                sites=wiki, titles=title, props='info', maxlag='5')


def replay_request(request, response, receipt, wiki, date, namespace_sha):
    title = request.get('title')
    if (not isinstance(title, str) or not title or any(c in title for c in '\r\n\t|')
            or request.get('wiki') != wiki or request.get('date') != date
            or request.get('method') != 'GET' or request.get('params') != expected_params(wiki, title)):
        raise ValueError('Invalid page-link request identity')
    key = page_id(request.get('page_id'))
    params = expected_params(wiki, title)
    url = 'https://www.wikidata.org/w/api.php?' + urllib.parse.urlencode(params)
    if (request.get('url') != url or receipt.get('url') != url or receipt.get('final_url') != url
            or receipt.get('status') != 200 or receipt.get('outcome') != 'passed'
            or receipt.get('source_guard') is not True
            or request.get('inputs', {}).get('namespace', {}).get('sha256') != namespace_sha):
        raise ValueError('Unverified page-link API observation')
    for field in ('started_utc', 'ended_utc'):
        parsed = dt.datetime.fromisoformat(receipt[field].replace('Z', '+00:00'))
        if parsed.tzinfo is None:
            raise ValueError('Unzoned page-link observation time')
    if (not isinstance(response, dict) or response.get('success') != 1 or 'error' in response
            or not isinstance(response.get('entities'), dict) or len(response['entities']) != 1):
        raise ValueError('Incomplete or unsuccessful page-link API response')
    result_key, result = next(iter(response['entities'].items()))
    if not isinstance(result, dict):
        raise ValueError('Invalid page-link API entity')
    if 'missing' in result:
        if result_key != '-1' or result.get('site') != wiki or result.get('title') != title or result['missing'] not in ('', True):
            raise ValueError('Negative page-link result lacks exact site/title coverage')
        value = None
    else:
        value = entity_id(result_key)
        if result.get('id') != value:
            raise ValueError('Page-link entity identity mismatch')
    if receipt.get('result_entity_id') != value:
        raise ValueError('Page-link receipt disagrees with raw response')
    return key, title, value


def validate_snapshot(path, wiki=None, date=None):
    path = Path(path)
    root = path.parent
    manifest = parse(regular(root / (NAME + '.manifest.json')))
    if (manifest.get('schema') != SCHEMA or manifest.get('profile') != 'repository-sitelink-supplement-v1'
            or manifest.get('generator_sha256') != PRODUCER_SHA256
            or manifest.get('observation_kind') != 'current-repository-sitelink'
            or manifest.get('historical_dump_sitelink_claim') is not False
            or (wiki is not None and manifest.get('wiki') != wiki)
            or (date is not None and manifest.get('date') != date)):
        raise ValueError('Wrong page-link supplement provenance')
    wiki, date = manifest['wiki'], manifest['date']
    if not re.fullmatch(r'[a-z0-9_]+wiktionary', wiki) or not re.fullmatch(r'[0-9]{8}', date):
        raise ValueError('Invalid page-link edition/date')
    count = manifest.get('request_count')
    if type(count) is not int or not 1 <= count <= MAX_REQUESTS:
        raise ValueError('Invalid page-link request count')
    required = {NAME + '.tsv', NAME + '.namespace-registry.tsv'}
    for i in range(1, count + 1):
        required.update(NAME + f'.{i:04d}.' + tail for tail in ('request.json', 'raw.json', 'receipt.json'))
    artifacts = manifest.get('artifacts')
    if not isinstance(artifacts, dict) or set(artifacts) != required:
        raise ValueError('Incomplete page-link capture inventory')
    blobs = {}
    for name, expected in artifacts.items():
        if Path(name).name != name or not re.fullmatch(r'[0-9a-f]{64}', expected):
            raise ValueError('Unsafe page-link artifact identity')
        blobs[name] = regular(root / name, MAX_OUTPUT_BYTES if name.endswith('.tsv') else MAX_PROOF_BYTES)
        if digest(blobs[name]) != expected:
            raise ValueError('Page-link capture artifact changed: ' + name)
    namespace = blobs[NAME + '.namespace-registry.tsv']
    prefix = ('# wikidict-namespace-registry-v1\n# wiki\t' + wiki + '\n# dump-date\t' + date + '\n').encode()
    if not namespace.startswith(prefix) or digest(namespace) != manifest.get('namespace_registry_sha256'):
        raise ValueError('Page-link namespace binding mismatch')
    targets, records = {}, {}
    for i in range(1, count + 1):
        prefix = NAME + f'.{i:04d}.'
        req = parse(blobs[prefix + 'request.json'])
        receipt = parse(blobs[prefix + 'receipt.json'])
        raw = blobs[prefix + 'raw.json']
        if receipt.get('response', {}).get('sha256') != digest(raw) or receipt.get('response', {}).get('bytes') != len(raw):
            raise ValueError('Page-link HTTP receipt changed')
        key, title, value = replay_request(req, parse(raw), receipt, wiki, date, digest(namespace))
        if key in records or title in targets.values():
            raise ValueError('Duplicate page-link observation')
        records[key], targets[key] = value, title
    raw = wire(records)
    if (blobs[NAME + '.tsv'] != raw or manifest.get('output_sha256') != digest(raw)
            or manifest.get('output_bytes') != len(raw) or manifest.get('row_count') != len(records)):
        raise ValueError('Page-link supplement differs from offline replay')
    sources = manifest.get('source_dump_files')
    if not isinstance(sources, list) or len(sources) != 2:
        raise ValueError('Missing page-link SQL provenance')
    expected_names = {wiki + '-' + date + '-' + table + '.sql.gz' for table in ('page', 'page_props')}
    if {r.get('name') for r in sources} != expected_names:
        raise ValueError('Wrong page-link SQL input set')
    for source in sources:
        if (set(source) != set(SOURCE_FIELDS) or source['wiki'] != wiki or source['date'] != date
                or type(source['size']) is not int or source['size'] <= 0
                or not re.fullmatch('[0-9a-f]{40}', source.get('sha1', ''))):
            raise ValueError('Invalid page-link source identity')
    return manifest


def capture_artifacts(path, manifest=None):
    verified = validate_snapshot(path)
    if manifest is not None and verified != manifest:
        raise ValueError('Page-link capture changed during verification')
    result = dict(verified['artifacts'])
    result[NAME + '.manifest.json'] = digest(regular(Path(path).with_name(NAME + '.manifest.json')))
    return result


def supplement_targets(path, wiki, date):
    manifest = validate_snapshot(path, wiki, date)
    targets = {}
    for i in range(1, manifest['request_count'] + 1):
        request = parse(regular(Path(path).with_name(NAME + f'.{i:04d}.request.json')))
        targets[request['page_id']] = request['title']
    return manifest, targets, read_wire(regular(path, MAX_OUTPUT_BYTES))


def namespace_names(path, wiki, date):
    raw = regular(path)
    prefix = ('# wikidict-namespace-registry-v1\n# wiki\t' + wiki + '\n# dump-date\t' + date + '\n').encode()
    if not raw.startswith(prefix):
        raise ValueError('Wrong derived page-link namespace registry')
    result = {}
    for line in raw.decode('utf-8').splitlines():
        if line.startswith('#'):
            continue
        fields = line.split('\t')
        key = int(fields[0])
        if len(fields) < 10 or key in result:
            raise ValueError('Invalid derived page-link namespace row')
        result[key] = fields[1]
    return result, digest(raw)


def prepare_from_dumps(items, downloads, namespace, workspace, supplement=None):
    """One derived native input, reused only for identical verified source bytes.

    XML-only custom builds may omit this optional provider. The production
    all-edition manifest includes page_props, and missing runtime coverage still
    raises a typed error rather than returning nil.
    """
    if not items:
        raise ValueError('No page-link dump inputs')
    wiki, date = items[0]['wiki'], items[0]['date']
    selected = [i for i in items if i['name'] == wiki + '-' + date + '-page_props.sql.gz']
    if not selected and supplement is None:
        return None
    if len(selected) != 1:
        raise ValueError('Expected one pinned page_props input')
    prop_item = selected[0]
    source = Path(downloads) / wiki / date / prop_item['name']
    names, namespace_sha = namespace_names(namespace, wiki, date)
    manifest, targets, extra = (None, {}, {})
    if supplement is not None:
        manifest, targets, extra = supplement_targets(supplement, wiki, date)
        if manifest['namespace_registry_sha256'] != namespace_sha:
            raise ValueError('Page-link supplement uses another namespace registry')
        for recorded in manifest['source_dump_files']:
            matches = [i for i in items if i['name'] == recorded['name']]
            if len(matches) != 1 or {k: matches[0].get(k) for k in SOURCE_FIELDS} != recorded:
                raise ValueError('Page-link supplement uses another selected SQL input')
    identity = dict(schema=SCHEMA, source={k:prop_item[k] for k in SOURCE_FIELDS},
                    generator_sha256=PRODUCER_SHA256,
                    parser_sha256=digest(Path(__import__('category_tree_snapshot').__file__).read_bytes()),
                    namespace_registry_sha256=namespace_sha,
                    supplement_artifacts=capture_artifacts(supplement, manifest) if supplement is not None else None)
    # The caller verifies all selected downloads first. Recheck these exact
    # compressed SQL identities here so this helper is safe standalone too.
    checked = [prop_item]
    if targets:
        checked.append(next(i for i in items if i['name'] == wiki + '-' + date + '-page.sql.gz'))
    before = {}
    for item in checked:
        path = Path(downloads) / wiki / date / item['name']
        st = path.lstat()
        initial = (st.st_dev, st.st_ino, st.st_size, st.st_mtime_ns, st.st_ctime_ns)
        if not stat.S_ISREG(st.st_mode) or st.st_size != item['size']:
            raise ValueError('Missing or unsafe page-link SQL input')
        sha1, sha256 = hashlib.sha1(), hashlib.sha256()
        descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
        with os.fdopen(descriptor, 'rb') as stream:
            opened = os.fstat(stream.fileno())
            if (opened.st_dev, opened.st_ino, opened.st_size, opened.st_mtime_ns, opened.st_ctime_ns) != initial:
                raise ValueError('Page-link SQL input changed before hashing')
            while chunk := stream.read(1024 * 1024):
                sha1.update(chunk); sha256.update(chunk)
        st = path.lstat()
        if (st.st_dev, st.st_ino, st.st_size, st.st_mtime_ns, st.st_ctime_ns) != initial:
            raise ValueError('Page-link SQL input changed while hashing')
        actual = sha1.hexdigest()
        if manifest is not None and item['name'].endswith('-page_props.sql.gz'):
            for i in range(1, manifest['request_count'] + 1):
                request = parse(regular(Path(supplement).with_name(NAME + f'.{i:04d}.request.json')))
                if request.get('inputs', {}).get('page_props', {}).get('sha256') != sha256.hexdigest():
                    raise ValueError('Repository observation uses another pinned page_props source')
        if actual != item['sha1']:
            raise ValueError('Unverified page-link SQL input')
        before[str(path)] = initial
    def require_sql_unchanged():
        for filename, expected in before.items():
            st = Path(filename).stat()
            if (st.st_dev, st.st_ino, st.st_size, st.st_mtime_ns, st.st_ctime_ns) != expected:
                raise ValueError('Page-link SQL input changed during parsing')
    root = Path(workspace) / 'derived-page-links'
    if root.is_symlink():
        raise ValueError('Unsafe derived page-link directory')
    root.mkdir(exist_ok=True)
    output, proof = root / (NAME + '.tsv'), root / 'complete.json'
    if output.is_file() and proof.is_file() and not output.is_symlink() and not proof.is_symlink():
        try:
            cached = parse(regular(proof))
            raw = regular(output, MAX_OUTPUT_BYTES)
            if cached['input_identity'] == identity and cached['output_sha256'] == digest(raw):
                read_wire(raw)
                require_sql_unchanged()
                return output
        except (ValueError, KeyError, OSError):
            pass
    records, source_rows = {}, 0
    for key, prop, value in rows(source, ('pp_page', 'pp_propname', 'pp_value')):
        source_rows += 1
        if prop != b'wikibase_item':
            continue
        key = page_id(key)
        if key in records or not isinstance(value, bytes):
            raise ValueError('Duplicate or invalid SQL wikibase_item')
        records[key] = entity_id(value.decode('ascii'))
        if len(records) > MAX_ROWS:
            raise ValueError('Too many SQL wikibase_item rows')
    sql_positives = len(records)
    if targets:
        found = set()
        page_path = Path(downloads) / wiki / date / (wiki + '-' + date + '-page.sql.gz')
        for key, ns, title in rows(page_path, ('page_id', 'page_namespace', 'page_title')):
            if key not in targets:
                continue
            if key in found or ns not in names or not isinstance(title, bytes):
                raise ValueError('Invalid supplemental page identity')
            full = (names[ns] + ':' if ns else '') + title.decode('utf-8').replace('_', ' ')
            if full != targets[key]:
                raise ValueError('Repository title differs from pinned page ID/title')
            found.add(key)
        if found != set(targets):
            raise ValueError('Supplement page ID absent from pinned page table')
    ignored = sorted(set(extra) & set(records))
    for key, value in extra.items():
        # This matches the upstream local lookup before repository fallback.
        records.setdefault(key, value)
    raw = wire(records)
    require_sql_unchanged()
    record = dict(input_identity=identity, source_rows=source_rows, sql_positive_rows=sql_positives,
                  repository_rows=len(extra), repository_rows_shadowed_by_sql=ignored,
                  explicit_negative_rows=sum(v is None for v in records.values()),
                  row_count=len(records), output_sha256=digest(raw), output_bytes=len(raw))
    for path, payload in ((output, raw), (proof, document(record))):
        if path.is_symlink():
            raise ValueError('Unsafe derived page-link artifact')
        temporary = path.with_name(path.name + '.part-' + str(os.getpid()))
        with temporary.open('xb') as stream:
            stream.write(payload); stream.flush(); os.fsync(stream.fileno())
        os.replace(temporary, path)
    return output


def create_supplement(observations, source_items, namespace, output):
    """Finalize saved HTTP observations without refetching or changing raw bytes."""
    observations = [Path(p) for p in observations]
    if not 1 <= len(observations) <= MAX_REQUESTS:
        raise ValueError('Invalid observation count')
    request = parse(regular(observations[0] / 'request.json'))
    wiki, date = request['wiki'], request['date']
    names, namespace_sha = namespace_names(namespace, wiki, date)
    del names
    records, artifacts = {}, {}
    output = Path(output)
    output.mkdir(exist_ok=False)
    def put(name, raw):
        with (output / name).open('xb') as stream:
            stream.write(raw)
        artifacts[name] = digest(raw)
    put(NAME + '.namespace-registry.tsv', regular(namespace))
    for i, observation in enumerate(observations, 1):
        req = regular(observation / 'request.json')
        raw = regular(observation / 'response.raw.json')
        receipt = regular(observation / 'http-receipt.json')
        key, title, value = replay_request(parse(req), parse(raw), parse(receipt), wiki, date, namespace_sha)
        if key in records:
            raise ValueError('Duplicate observed page')
        records[key] = value
        for tail, data in (('request.json', req), ('raw.json', raw), ('receipt.json', receipt)):
            put(NAME + f'.{i:04d}.' + tail, data)
    raw = wire(records)
    put(NAME + '.tsv', raw)
    sources = [{k:item[k] for k in SOURCE_FIELDS} for item in source_items
               if item['name'] in {wiki + '-' + date + '-' + table + '.sql.gz' for table in ('page', 'page_props')}]
    manifest = dict(schema=SCHEMA, profile='repository-sitelink-supplement-v1',
                    wiki=wiki, date=date, generator_sha256=PRODUCER_SHA256,
                    observation_kind='current-repository-sitelink', historical_dump_sitelink_claim=False,
                    namespace_registry_sha256=namespace_sha, source_dump_files=sources,
                    request_count=len(observations), row_count=len(records),
                    output_sha256=digest(raw), output_bytes=len(raw), artifacts=artifacts)
    (output / (NAME + '.manifest.json')).write_bytes(document(manifest))
    validate_snapshot(output / (NAME + '.tsv'), wiki, date)
    return output / (NAME + '.tsv')
