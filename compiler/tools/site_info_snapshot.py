"""Bind the existing current-at-retrieval siteinfo JSON to its namespace capture.

This module is read-only: it performs no API requests and creates no projection.
"""
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import xml.etree.ElementTree as ET
import namespace_registry_snapshot

SNAPSHOT_NAME = 'namespace-siteinfo.raw.json'
MANIFEST_NAME = 'namespace-registry.manifest.json'
MAX_BYTES = 2 * 1024**2
_FILES = (SNAPSHOT_NAME, MANIFEST_NAME, 'namespace-registry.tsv',
          'dump-siteinfo.xml', 'capture.complete.json')


def validate_server(value):
    """Admit bounded ASCII DNS authorities without rewriting the captured value."""
    if not isinstance(value, str) or not value or len(value) > 1024 or not value.isascii():
        raise ValueError('Invalid captured site server')
    if value.startswith('//'):
        authority = value[2:]
    elif value.startswith('https://'):
        authority = value[8:]
    elif value.startswith('http://'):
        authority = value[7:]
    else:
        raise ValueError('Invalid captured site server scheme')
    if not authority or any(ord(c) <= 32 or ord(c) == 127 or c in '/?#@\\' for c in authority):
        raise ValueError('Invalid captured site server authority')
    if ':' in authority:
        host, port = authority.rsplit(':', 1)
        if not re.fullmatch('[0-9]{1,5}', port) or not 1 <= int(port) <= 65535:
            raise ValueError('Invalid captured site server port')
    else:
        host = authority
    hostname = host[:-1] if host.endswith('.') else host
    if not hostname or len(hostname) > 253:
        raise ValueError('Invalid captured site server hostname')
    if any(not re.fullmatch('[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?', label)
           for label in hostname.split('.')):
        raise ValueError('Invalid captured site server DNS label')
    return value


def _object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError('Duplicate siteinfo evidence JSON field: ' + key)
        result[key] = value
    return result


def _json(data):
    return json.loads(data, object_pairs_hook=_object)


def _read(path):
    if path.is_symlink():
        raise ValueError('Unsafe siteinfo evidence path: ' + str(path))
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, 'rb') as source:
        before = os.fstat(source.fileno())
        if not stat.S_ISREG(before.st_mode) or before.st_size > MAX_BYTES:
            raise ValueError('Unsupported or oversized siteinfo evidence: ' + str(path))
        data = source.read(MAX_BYTES + 1)
        after = os.fstat(source.fileno())
    identity = lambda info: (info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns)
    if len(data) != before.st_size or identity(before) != identity(after) or identity(after) != identity(path.lstat()):
        raise ValueError('Siteinfo evidence changed while reading: ' + str(path))
    return data


def _digest(data):
    return hashlib.sha256(data).hexdigest()


def validate_snapshot(path, wiki=None, date=None):
    path = Path(path)
    if path.name != SNAPSHOT_NAME or path.parent.is_symlink():
        raise ValueError('Unexpected siteinfo snapshot path')
    blobs = {name: _read(path.with_name(name)) for name in _FILES}
    manifest = _json(blobs[MANIFEST_NAME])
    capture = _json(blobs['capture.complete.json'])
    raw = _json(blobs[SNAPSHOT_NAME])
    if not isinstance(manifest, dict) or not isinstance(capture, dict) or not isinstance(raw, dict):
        raise ValueError('Invalid siteinfo capture evidence')
    captured_wiki, captured_date = capture.get('wiki'), capture.get('date')
    if (not isinstance(captured_wiki, str) or not captured_wiki or
            not isinstance(captured_date, str) or not re.fullmatch('[0-9]{8}', captured_date) or
            manifest.get('wiki') != captured_wiki or manifest.get('date') != captured_date or
            (wiki is not None and wiki != captured_wiki) or
            (date is not None and date != captured_date)):
        raise ValueError('Siteinfo edition/date mismatch')
    if capture.get('namespace_mismatches') != []:
        raise ValueError('Unresolved siteinfo namespace mismatch')
    artifacts = capture.get('artifacts')
    if not isinstance(artifacts, dict):
        raise ValueError('Missing siteinfo capture inventory')
    for filename, field in ((SNAPSHOT_NAME, 'raw_siteinfo_sha256'),
                            ('dump-siteinfo.xml', 'dump_siteinfo_sha256')):
        actual = _digest(blobs[filename])
        if artifacts.get(filename) != actual or manifest.get(field) != actual:
            raise ValueError('Siteinfo raw evidence hash mismatch: ' + filename)
    namespace_sha = _digest(blobs['namespace-registry.tsv'])
    if manifest.get('output_sha256') != namespace_sha:
        raise ValueError('Siteinfo paired namespace registry hash mismatch')
    source = capture.get('source_xml')
    if (not isinstance(source, dict) or source.get('wiki') != captured_wiki or
            source.get('date') != captured_date or manifest.get('source_dump_files') != [source]):
        raise ValueError('Siteinfo dated source identity mismatch')
    for projected, captured in (('retrieved_utc', 'retrieved_utc'),
                                ('source_url', 'siteinfo_source_url'),
                                ('supplementary_api_scope', 'siteinfo_temporal_scope')):
        value = manifest.get(projected)
        if not isinstance(value, str) or not value or value != capture.get(captured):
            raise ValueError('Siteinfo observation provenance mismatch: ' + projected)
    query = raw.get('query')
    general = query.get('general') if isinstance(query, dict) else None
    if not isinstance(general, dict) or general.get('wikiid') != captured_wiki:
        raise ValueError('Siteinfo raw edition mismatch')
    server = validate_server(general.get('server'))
    xml = ET.fromstring(blobs['dump-siteinfo.xml'])
    site = xml.find('{*}siteinfo')
    if site is None or site.findtext('{*}dbname') != captured_wiki:
        raise ValueError('Siteinfo dated XML edition mismatch')
    inventory = [{'id': int(row.attrib['key']), 'name': row.text or '', 'case': row.attrib['case']}
                 for row in site.findall('{*}namespaces/{*}namespace')]
    if sorted(inventory, key=lambda row: row['id']) != sorted(capture.get('dump_namespace_inventory', []), key=lambda row: row['id']):
        raise ValueError('Siteinfo inventory differs from dated XML')
    projected, roles = namespace_registry_snapshot.render(captured_wiki, captured_date, query, inventory)
    if projected != blobs['namespace-registry.tsv'] or roles != manifest.get('roles'):
        raise ValueError('Siteinfo namespace projection differs from paired registry')
    # Normalize only the returned validation record; original manifest bytes stay
    # unchanged and remain independently bound in the artifact inventory.
    return dict(manifest, output_sha256=_digest(blobs[SNAPSHOT_NAME]),
                namespace_registry_sha256=namespace_sha, server=server,
                artifacts={name: _digest(data) for name, data in blobs.items()})


def capture_artifacts(path, record=None):
    record = validate_snapshot(path) if record is None else record
    return dict(record['artifacts'])
