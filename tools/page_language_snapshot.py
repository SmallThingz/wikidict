"""Validate and stage indexed page-language inputs; no acquisition or CLI.

This layer binds complete files, ranges and selected namespace identity. The
native provider validates API/source-profile semantics and parses each prefix.
Current observations never assert the historical dump's language policy.
"""
from datetime import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import stat
from urllib.parse import quote

SNAPSHOT = 'page-language.json'
RAW = 'page-language.raw.json'
HTML = 'page-language.html'
MANIFEST = 'page-language.manifest.json'
MAX_INDEX = 8 * 1024 * 1024
MAX_MANIFEST = 64 * 1024
MAX_STORE = 64 * 1024 * 1024
MAX_RESPONSE = 64 * 1024
MAX_PREFIX = 512 * 1024
MAX_RECORDS = 8192
MAX_RESPONSES = 1024


def _fail(message):
    raise ValueError('Page language: ' + message)


def _hash(raw):
    return hashlib.sha256(raw).hexdigest()


def _hash_string(value, length=64):
    return isinstance(value, str) and re.fullmatch('[0-9a-f]{' + str(length) + '}', value) is not None


def _integer(value, minimum=0):
    return type(value) is int and value >= minimum


def _keys(value, expected):
    return isinstance(value, dict) and set(value) == set(expected)


def _regular(path, limit):
    """Reject links/FIFOs before reading and detect replacement during the read."""
    path = Path(path)
    before = path.lstat()
    if not stat.S_ISREG(before.st_mode) or before.st_size > limit:
        _fail('expected bounded regular file: ' + path.name)
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        opened = os.fstat(fd)
        def identity(s):
            return (s.st_dev, s.st_ino, s.st_mode, s.st_uid, s.st_gid,
                    s.st_size, s.st_mtime_ns, s.st_ctime_ns)
        if identity(before) != identity(opened):
            _fail('file changed before read: ' + path.name)
        with os.fdopen(fd, 'rb', closefd=False) as stream:
            raw = stream.read(limit + 1)
        if len(raw) != before.st_size or identity(before) != identity(os.fstat(fd)) or identity(before) != identity(path.lstat()):
            _fail('file changed during read: ' + path.name)
        return raw
    finally:
        os.close(fd)


def _json(raw):
    def pairs(items):
        result = {}
        for key, value in items:
            if key in result:
                _fail('duplicate JSON key')
            result[key] = value
        return result
    try:
        return json.loads(raw.decode('utf-8'), object_pairs_hook=pairs,
                          parse_constant=lambda value: _fail('nonfinite JSON number'))
    except (UnicodeDecodeError, json.JSONDecodeError, RecursionError) as error:
        raise ValueError('Page language: invalid bounded JSON') from error


def _utc(value):
    if not isinstance(value, str) or re.fullmatch(r'\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ', value) is None:
        _fail('invalid observation timestamp')
    try:
        datetime.strptime(value, '%Y-%m-%dT%H:%M:%SZ')
    except ValueError as error:
        raise ValueError('Page language: invalid observation timestamp') from error


def _ranges(index, raw, html):
    responses, records = index.get('responses'), index.get('records')
    if not isinstance(responses, list) or not 1 <= len(responses) <= MAX_RESPONSES:
        _fail('invalid response inventory')
    if not isinstance(records, list) or not 1 <= len(records) <= MAX_RECORDS:
        _fail('invalid record inventory')
    offset = 0
    expected_rows = set()
    for number, item in enumerate(responses):
        if (not _keys(item, ('offset', 'bytes', 'sha256', 'observed_utc')) or
                not _integer(item['offset']) or item['offset'] != offset or
                not _integer(item['bytes'], 1) or item['bytes'] > MAX_RESPONSE or
                not _hash_string(item['sha256'])):
            _fail('invalid contiguous response range')
        end = offset + item['bytes']
        if end > len(raw) or _hash(raw[offset:end]) != item['sha256']:
            _fail('response range differs from store')
        _utc(item['observed_utc'])
        response = _json(raw[offset:end])
        pages = response.get('query', {}).get('pages') if isinstance(response, dict) and isinstance(response.get('query'), dict) else None
        if not isinstance(pages, list) or not 1 <= len(pages) <= MAX_RECORDS or len(expected_rows) + len(pages) > MAX_RECORDS:
            _fail('invalid response page inventory')
        expected_rows.update((number, row) for row in range(len(pages)))
        offset = end
    if offset != len(raw):
        _fail('unclaimed response bytes')
    previous_page = 0
    used_rows = set()
    prefix_offset = 0
    prefix_count = 0
    for item in records:
        if not _keys(item, ('page', 'response_index', 'response_page_index', 'prefix')):
            _fail('invalid record shape')
        page = item['page']
        if (not isinstance(page, dict) or set(page) not in (
                {'id', 'revision', 'namespace', 'title', 'model', 'raw_sha256'},
                {'id', 'revision', 'namespace', 'title', 'model', 'raw_sha256', 'expanded_sha256'}) or
                not _integer(page['id'], 1) or page['id'] <= previous_page or
                not _integer(page['revision'], 1) or type(page['namespace']) is not int or
                not isinstance(page['title'], str) or not page['title'] or
                not isinstance(page['model'], str) or not page['model'] or
                not _hash_string(page['raw_sha256']) or
                (page.get('expanded_sha256') is not None and not _hash_string(page['expanded_sha256']))):
            _fail('invalid or nonascending exact page identity')
        previous_page = page['id']
        if not _integer(item['response_index']) or not _integer(item['response_page_index']):
            _fail('invalid response row index')
        selected = (item['response_index'], item['response_page_index'])
        if selected not in expected_rows or selected in used_rows:
            _fail('unregistered or multiply used response row')
        used_rows.add(selected)
        prefix = item['prefix']
        if prefix is not None:
            if (not isinstance(prefix, dict) or not _integer(prefix.get('offset')) or prefix['offset'] != prefix_offset or
                    not _integer(prefix.get('slice_bytes'), 1) or prefix['slice_bytes'] > MAX_PREFIX or
                    not _hash_string(prefix.get('sha256'))):
                _fail('invalid contiguous prefix range')
            end = prefix_offset + prefix['slice_bytes']
            if html is None or end > len(html) or _hash(html[prefix_offset:end]) != prefix['sha256']:
                _fail('prefix range differs from store')
            _utc(prefix.get('observed_utc'))
            prefix_offset = end
            prefix_count += 1
    if used_rows != expected_rows:
        _fail('unclaimed response page rows')
    if (html is None) != (prefix_count == 0) or (html is not None and prefix_offset != len(html)):
        _fail('unclaimed or missing prefix store')



def _direct_records(index):
    """Bind complete direct responses; native code still validates HTML semantics.

    Only the maintained current-canonical complete-response transport is packaged
    here. Saved-prefix recovery and historical acquisitions need their own exact
    transport support; they are not converted to successful API observations.
    """
    rows = index.get('direct_get_contexts', [])
    if not isinstance(rows, list) or len(rows) > 256:
        _fail('invalid direct response inventory')
    used_ids = {row['page']['id'] for row in index['records']}
    used_titles = {row['page']['title'] for row in index['records']}
    previous = 0
    for row in rows:
        if (not _keys(row, ('profile', 'page', 'mode', 'response_kind', 'response', 'prefix', 'receipt', 'styles')) or
                row['profile'] != 'source-parent-direct-get-v1' or row['mode'] != 'current-canonical' or
                row['response_kind'] != 'complete-response'):
            _fail('unsupported direct response transport')
        page = row['page']
        if (not _keys(page, ('id', 'revision', 'namespace', 'title', 'model', 'raw_sha256', 'expanded_sha256')) or
                not _integer(page['id'], 1) or page['id'] <= previous or page['id'] in used_ids or
                not _integer(page['revision'], 1) or type(page['namespace']) is not int or page['namespace'] != 0 or
                page['model'] != 'wikitext' or not isinstance(page['title'], str) or not page['title'] or
                any(c in page['title'] for c in '\x00\r\n\t') or page['title'] in used_titles or
                not _hash_string(page['raw_sha256']) or not _hash_string(page['expanded_sha256'])):
            _fail('invalid exact direct page identity')
        previous = page['id']
        used_ids.add(page['id'])
        used_titles.add(page['title'])
        if not all(isinstance(row[key], str) for key in ('response', 'prefix', 'receipt')):
            _fail('invalid direct response strings')
        response, prefix = row['response'].encode(), row['prefix'].encode()
        if (not 0 < len(response) <= 2 * 1024 * 1024 or not 0 < len(prefix) <= MAX_PREFIX or
                b'\x00' in response or not response.startswith(prefix) or
                not 0 < len(row['receipt'].encode()) <= MAX_INDEX):
            _fail('invalid complete direct response or prefix')
        # This first normal package supports the earned no-external-CSS route.
        # A nonempty stylesheet receipt must not be dropped or loaned authority.
        if row['styles'] != {'responses': [], 'receipt': ''}:
            _fail('unsupported direct stylesheet package')
        receipt = _json(row['receipt'].encode())
        if (not _keys(receipt, ('core', 'historical_equality_proven', 'sources', 'unrequested')) or
                receipt['core'] is not None or receipt['historical_equality_proven'] is not False or
                receipt['unrequested'] != [] or not isinstance(receipt['sources'], list) or len(receipt['sources']) != 1):
            _fail('invalid complete direct receipt')
        saved = receipt['sources'][0]
        fields = ('accept_encoding', 'accepted', 'bytes', 'content_encoding', 'encoded', 'file', 'final_url',
                  'headers', 'request_count', 'response_complete', 'retrieved_utc', 'sha256', 'source_path',
                  'status', 'unknown_response_outcome', 'url', 'user_agent')
        url = 'https://' + index['wiki'][:-len('wiktionary')].replace('_', '-') + '.wiktionary.org/wiki/' + quote(page['title'].replace(' ', '_'), safe='-._~/:')
        if (not _keys(saved, fields) or saved['accepted'] is not True or saved['response_complete'] is not True or
                saved['unknown_response_outcome'] is not False or type(saved['status']) is not int or saved['status'] != 200 or
                type(saved['request_count']) is not int or saved['request_count'] != 1 or
                type(saved['bytes']) is not int or saved['bytes'] != len(response) or saved['sha256'] != _hash(response) or
                saved['url'] != url or saved['final_url'] != url or saved['accept_encoding'] != 'gzip' or
                saved['content_encoding'] != 'gzip' or saved['user_agent'] != 'Wikidict/1.0 (https://github.com/SmallThingz/wikidict)' or
                not isinstance(saved['headers'], dict) or saved['headers'].get('content-encoding') != 'gzip' or
                saved['headers'].get('content-type') != 'text/html; charset=UTF-8' or
                not isinstance(saved['file'], str) or not saved['file'] or
                not isinstance(saved['source_path'], str) or not saved['source_path']):
            _fail('direct response differs from original receipt')
        stamp = saved['retrieved_utc']
        if not isinstance(stamp, str) or re.fullmatch(r'\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d{1,9})?(?:Z|\+00:00)', stamp) is None:
            _fail('invalid direct timestamp')
        _utc(stamp[:19] + 'Z')
        encoded = saved['encoded']
        if (not _keys(encoded, ('bytes', 'path', 'sha256')) or not _integer(encoded['bytes'], 1) or
                encoded['bytes'] > MAX_STORE or not _hash_string(encoded['sha256']) or
                not isinstance(encoded['path'], str) or not 0 < len(encoded['path']) <= 4096 or
                any(c in encoded['path'] for c in '\x00\r\n')):
            _fail('invalid retained encoded response descriptor')
    return len(rows)


def _validated_payload(payload, wiki, namespace_sha256):
    index = _json(payload[SNAPSHOT])
    keys = {'schema', 'wiki', 'core_revision', 'namespace_registry_sha256', 'historical_page_language_proven', 'source_profile', 'responses', 'records'}
    if (not isinstance(index, dict) or set(index) not in (keys, keys | {'direct_get_contexts'}) or
            index['schema'] != 'wikidict.page-language-index.v1' or index['wiki'] != wiki or
            index['namespace_registry_sha256'] != namespace_sha256 or index['historical_page_language_proven'] is not False or
            not isinstance(index['records'], list)):
        _fail('index differs from manifest identity')
    if index['records']:
        if not _hash_string(index['core_revision'], 40) or not isinstance(index['source_profile'], dict) or not index['source_profile']:
            _fail('invalid API source identity')
        _ranges(index, payload[RAW], payload.get(HTML))
    elif (index['responses'] != [] or payload[RAW] != b'' or HTML in payload or
          index['core_revision'] is not None or index['source_profile'] is not None):
        _fail('direct-only packet has API payload or authority')
    count = len(index['records']) + _direct_records(index)
    if not 0 < count <= MAX_RECORDS:
        _fail('empty or oversized record inventory')
    return index, count


def pack_snapshot(path, namespace, destination, *, wiki, date):
    """Package existing exact bytes offline, without acquisition or re-rendering."""
    path, namespace, destination = Path(path), Path(namespace), Path(destination)
    if (path.name != SNAPSHOT or not re.fullmatch(r'[a-z0-9_]+wiktionary', wiki) or
            not re.fullmatch(r'\d{8}', date)):
        _fail('invalid package identity')
    ns = _regular(namespace, MAX_STORE)
    payload = {SNAPSHOT: _regular(path, MAX_INDEX), RAW: _regular(path.with_name(RAW), MAX_STORE)}
    if os.path.lexists(path.with_name(HTML)):
        payload[HTML] = _regular(path.with_name(HTML), MAX_STORE)
    _, count = _validated_payload(payload, wiki, _hash(ns))
    artifacts = {name: {'bytes': len(raw), 'sha256': _hash(raw)} for name, raw in payload.items()}
    manifest = dict(schema='wikidict.page-language-capture.v1', wiki=wiki, date=date,
                    namespace_registry_sha256=_hash(ns), output_sha256=_hash(payload[SNAPSHOT]),
                    output_bytes=len(payload[SNAPSHOT]), record_count=count, artifacts=artifacts)
    destination.mkdir(mode=0o700, parents=True, exist_ok=False)
    for name, raw in payload.items():
        with (destination / name).open('xb') as output:
            output.write(raw)
    with (destination / MANIFEST).open('xb') as output:
        output.write((json.dumps(manifest, sort_keys=True, indent=2) + '\n').encode())
    for name, raw in payload.items():
        if _regular(path.with_name(name), MAX_INDEX if name == SNAPSHOT else MAX_STORE) != raw:
            _fail('source changed during packaging')
    if _regular(namespace, MAX_STORE) != ns or (HTML not in payload and os.path.lexists(path.with_name(HTML))):
        _fail('namespace or prefix presence changed during packaging')
    validated_capture(destination / SNAPSHOT, wiki, date)
    return destination / SNAPSHOT

def validated_capture(path, wiki=None, date=None):
    path = Path(path)
    if path.name != SNAPSHOT or not stat.S_ISDIR(path.parent.lstat().st_mode):
        _fail('invalid generation path')
    manifest_raw = _regular(path.with_name(MANIFEST), MAX_MANIFEST)
    manifest = _json(manifest_raw)
    if (not _keys(manifest, ('schema', 'wiki', 'date', 'namespace_registry_sha256', 'output_sha256', 'output_bytes', 'record_count', 'artifacts')) or
            manifest['schema'] != 'wikidict.page-language-capture.v1' or
            not isinstance(manifest['wiki'], str) or not re.fullmatch(r'[a-z0-9_]+wiktionary', manifest['wiki']) or
            not isinstance(manifest['date'], str) or not re.fullmatch(r'\d{8}', manifest['date']) or
            (wiki is not None and manifest['wiki'] != wiki) or (date is not None and manifest['date'] != date) or
            not _hash_string(manifest['namespace_registry_sha256']) or not _hash_string(manifest['output_sha256']) or
            not _integer(manifest['output_bytes'], 1) or manifest['output_bytes'] > MAX_INDEX or
            not _integer(manifest['record_count'], 1) or manifest['record_count'] > MAX_RECORDS):
        _fail('invalid manifest identity')
    artifacts = manifest['artifacts']
    if not isinstance(artifacts, dict) or set(artifacts) not in ({SNAPSHOT, RAW}, {SNAPSHOT, RAW, HTML}):
        _fail('invalid exact payload inventory')
    if HTML not in artifacts and (path.with_name(HTML).exists() or path.with_name(HTML).is_symlink()):
        _fail('unregistered prefix store')
    payload = {}
    for name, item in artifacts.items():
        limit = MAX_INDEX if name == SNAPSHOT else MAX_STORE
        if (not _keys(item, ('bytes', 'sha256')) or not _integer(item['bytes'], 0 if name == RAW else 1) or
                item['bytes'] > limit or not _hash_string(item['sha256'])):
            _fail('invalid payload descriptor')
        content = _regular(path.with_name(name), limit)
        if len(content) != item['bytes'] or _hash(content) != item['sha256']:
            _fail('changed payload: ' + name)
        payload[name] = content
    if artifacts[SNAPSHOT] != {'bytes': manifest['output_bytes'], 'sha256': manifest['output_sha256']}:
        _fail('output descriptor differs')
    _, count = _validated_payload(payload, manifest['wiki'], manifest['namespace_registry_sha256'])
    if manifest['record_count'] != count:
        _fail('record count differs')
    if _regular(path.with_name(MANIFEST), MAX_MANIFEST) != manifest_raw:
        _fail('manifest changed during validation')
    inventory = {name: item['sha256'] for name, item in artifacts.items()}
    inventory[MANIFEST] = _hash(manifest_raw)
    return manifest, inventory


def validate_snapshot(path, wiki=None, date=None):
    return validated_capture(path, wiki, date)[0]


def capture_artifacts(path, record=None):
    current, inventory = validated_capture(path)
    if record is not None and current != record:
        _fail('manifest changed before artifact binding')
    return inventory
