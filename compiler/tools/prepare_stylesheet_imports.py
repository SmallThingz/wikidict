#!/usr/bin/env python3
"""Capture and replay the reviewed PT and JV Common.css cross-wiki imports.

This immutable build-input generation is not historical API state. It never
fetches dependencies discovered in CSS, retries a failed response, or edits the
selected corpus inputs. Unsupported dependency grammar remains unresolved.
"""
import argparse
from datetime import datetime, timezone
import gzip
import hashlib
import errno
import os
import shutil
import json
from pathlib import Path
import re
import sys
import stat
import time
import urllib.error
import urllib.parse
import urllib.request

sys.dont_write_bytecode = True
import prepare_file_metadata as evidence

SCHEMA = 'wikidict.stylesheet-imports.v1'
MANIFEST = 'stylesheet-imports.manifest.json'
SNAPSHOT = 'stylesheet-imports.json'
COMPLETE = 'stylesheet-imports.complete.json'
LEAF_URL = 'https://www.mediawiki.org/w/index.php?title=MediaWiki:Gadget-enwp-boxes.css&action=raw&ctype=text/css'
API = 'https://www.mediawiki.org/w/api.php'
TITLE = 'MediaWiki:Gadget-enwp-boxes.css'
MAX_BYTES = 1024 * 1024
MAX_JSON = 2 * 1024 * 1024
TEMPORAL_SCOPE = 'Current external revision/source observation associated with exact retained PT root; not historical 20261001 remote state'


def import_context(wiki='ptwiktionary'):
    # Two explicit reviewed roots/leaves, never a CSS-discovered host allowlist.
    if wiki == 'ptwiktionary':
        return {'root_title': 'MediaWiki:Common.css',
                'root_url': 'https://pt.wiktionary.org/w/index.php?title=MediaWiki:Common.css&action=raw&ctype=text/css',
                'leaf_url': LEAF_URL, 'api': API, 'title': TITLE, 'resource_wiki': 'mediawikiwiki',
                'temporal_scope': TEMPORAL_SCOPE}
    if wiki == 'jvwiktionary':
        return {'root_title': 'MédhiaWiki:Common.css',
                'root_url': 'https://jv.wiktionary.org/w/index.php?title=MediaWiki:Common.css&action=raw&ctype=text/css',
                'leaf_url': 'https://jv.wikipedia.org/w/index.php?title=MediaWiki:Common.css&action=raw&ctype=text/css',
                'api': 'https://jv.wikipedia.org/w/api.php', 'title': 'MediaWiki:Common.css', 'resource_wiki': 'jvwiki',
                'temporal_scope': 'Current external revision/source observation associated with exact retained JV root; not historical 20261001 remote state'}
    raise ValueError('Unselected stylesheet root edition')


def digest(raw):
    return hashlib.sha256(raw).hexdigest()


def hash_string(value):
    return isinstance(value, str) and re.fullmatch(r'[0-9a-f]{64}', value) is not None


def read(path, limit=MAX_JSON):
    return evidence.small(Path(path), limit)


def checked_root(path):
    path = Path(path)
    if not stat.S_ISDIR(path.lstat().st_mode):
        raise ValueError('Expected a non-symlink stylesheet generation directory')
    return path


def observed_utc(value):
    if not isinstance(value, str) or re.fullmatch(r'\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d{1,6})?(?:Z|\+00:00)', value) is None:
        raise ValueError('Invalid current-observation UTC timestamp')
    result = datetime.fromisoformat(value.replace('Z', '+00:00'))
    if result.utcoffset() != timezone.utc.utcoffset(result):
        raise ValueError('Non-UTC observation')
    return result


def checked_producer(value, page_inventory=False):
    # Historical recorded producer roles remain immutable. Current verification
    # replays every request/source/projection instead of executing old code or
    # restamping an earned capture as produced by this hardened verifier.
    if (not isinstance(value, dict) or set(value) != {'generator_sha256', 'dependency_sha256'}
            or not hash_string(value.get('generator_sha256'))
            or not isinstance(value.get('dependency_sha256'), dict)
            or set(value['dependency_sha256']) != ({'prepare_file_metadata.py', 'category_tree_snapshot.py'} if page_inventory else {'prepare_file_metadata.py'})
            or not all(hash_string(item) for item in value['dependency_sha256'].values())):
        raise ValueError('Malformed recorded stylesheet producer roles')


def producer(page_inventory=False):
    dependencies = {'prepare_file_metadata.py': digest(read(evidence.__file__))}
    if page_inventory:
        import category_tree_snapshot
        dependencies['category_tree_snapshot.py'] = digest(read(category_tree_snapshot.__file__))
    return {'generator_sha256': digest(read(__file__)), 'dependency_sha256': dependencies}


def space_comments(raw, at):
    while at < len(raw):
        if raw[at] in b' \t\r\n\f':
            at += 1
        elif raw[at:at + 2] == b'/*':
            end = raw.find(b'*/', at + 2)
            if end < 0:
                raise ValueError('Unclosed CSS comment')
            at = end + 2
        else:
            break
    return at


def requirement(css, wiki='ptwiktionary'):
    context = import_context(wiki)
    # This finite collector admits one complete unconditional quoted first
    # import. It does not regex-match imports inside comments, strings or rules.
    at = space_comments(css, 0)
    start = at
    if css[at:at + 7].lower() != b'@import' or at + 7 >= len(css) or css[at + 7] not in b' \t\r\n\f':
        raise ValueError('Missing supported first stylesheet import')
    at = space_comments(css, at + 7)
    if at >= len(css) or css[at] not in b'\"\'':
        raise ValueError('Only proved quoted import syntax admitted')
    quote = css[at]
    at += 1
    begin = at
    while at < len(css) and css[at] != quote:
        if css[at] < 32 or css[at] in b'\\':
            raise ValueError('Escaped/control import URL is unsupported')
        at += 1
    if at >= len(css):
        raise ValueError('Incomplete import URL')
    authored = css[begin:at].decode('utf-8')
    at = space_comments(css, at + 1)
    if at >= len(css) or css[at] != ord(';'):
        raise ValueError('Conditional or malformed import remains unresolved')
    resolved = urllib.parse.urljoin(context['root_url'], authored)
    if resolved != context['leaf_url']:
        raise ValueError('Unselected stylesheet origin or page')
    return {'start': start, 'end': at + 1, 'authored_url': authored, 'resolved_url': resolved}


def authority(raw, css):
    value = evidence.decode(raw)
    if 'table_styles' in value:
        value = value['table_styles']['authority']
    if not isinstance(value, dict):
        raise ValueError('Root stylesheet authority mismatch')
    context = import_context(value.get('wiki'))
    if (not isinstance(value.get('dump_date'), str) or re.fullmatch(r'\d{8}', value['dump_date']) is None or value.get('title') != context['root_title']
            or value.get('content_model') != 'css' or value.get('decoded_source_bytes') != len(css)
            or value.get('decoded_source_sha256') != digest(css)
            or type(value.get('page_id')) is not int or value['page_id'] <= 0
            or type(value.get('revision_id')) is not int or value['revision_id'] <= 0
            or not hash_string(value.get('namespace_sha256'))):
        raise ValueError('Root stylesheet authority mismatch')
    css.decode('utf-8')
    return value


def api_query(context=None):
    context = context or import_context()
    return {'action': 'query', 'format': 'json', 'formatversion': '2',
            'meta': 'siteinfo', 'siprop': 'general|namespaces' if context['resource_wiki'] == 'jvwiki' else 'general', 'prop': 'revisions',
            'titles': context['title'], 'rvslots': 'main',
            'rvprop': 'ids|timestamp|sha1|contentmodel|content'}


def parse_api(raw, context=None):
    context = context or import_context()
    value = evidence.decode(raw)
    if any(key in value for key in ('error', 'errors', 'warnings', 'continue')):
        raise ValueError('Incomplete stylesheet API observation')
    query = value.get('query', {})
    general = query.get('general', {})
    if general.get('wikiid') != context['resource_wiki']:
        raise ValueError('Stylesheet origin identity mismatch')
    expected_title = context['title']
    if context['resource_wiki'] == 'jvwiki':
        # The authored canonical namespace may normalize to the remote local
        # name. Require its returned NS8 identity and exact query normalization.
        namespace = query.get('namespaces', {}).get('8')
        if not isinstance(namespace, dict) or type(namespace.get('id')) is not int or namespace['id'] != 8:
            raise ValueError('Missing imported stylesheet namespace authority')
        name = namespace.get('name')
        if (not isinstance(name, str) or not name or ':' in name or any(ord(c) < 32 for c in name)
                or namespace.get('canonical', name) != 'MediaWiki'):
            raise ValueError('Imported stylesheet namespace identity mismatch')
        expected_title = name + ':Common.css'
        normalized = query.get('normalized', [])
        if normalized:
            if (not isinstance(normalized, list) or len(normalized) != 1 or not isinstance(normalized[0], dict)
                    or normalized[0].get('from') != context['title'] or normalized[0].get('to') != expected_title
                    or ('fromencoded' in normalized[0] and type(normalized[0]['fromencoded']) is not bool)):
                raise ValueError('Unproved imported stylesheet title normalization')
        elif expected_title != context['title']:
            raise ValueError('Unproved imported stylesheet title normalization')
    pages = query.get('pages')
    if not isinstance(pages, list) or len(pages) != 1:
        raise ValueError('Incomplete exact stylesheet page')
    page = pages[0]
    if page.get('title') != expected_title or type(page.get('ns')) is not int or page.get('ns') != 8 or page.get('missing') or page.get('redirect') or type(page.get('pageid')) is not int or page['pageid'] <= 0:
        raise ValueError('Missing, redirected or mismatched stylesheet page')
    revisions = page.get('revisions')
    if not isinstance(revisions, list) or len(revisions) != 1:
        raise ValueError('Missing pinned stylesheet revision')
    rev = revisions[0]
    slot = rev.get('slots', {}).get('main', {})
    text = slot.get('content')
    model = slot.get('contentmodel')
    if (model != 'css' or not isinstance(text, str) or '\0' in text
            or type(rev.get('revid')) is not int or rev['revid'] <= 0
            or not isinstance(rev.get('timestamp'), str) or re.fullmatch(r'\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ', rev['timestamp']) is None):
        raise ValueError('Unsupported stylesheet revision/content model')
    css = text.encode('utf-8')
    if len(css) > MAX_BYTES:
        raise ValueError('Stylesheet source exceeds bound')
    sha1 = hashlib.sha1(css).hexdigest()
    if rev.get('sha1') != sha1:
        raise ValueError('API revision/source SHA1 mismatch')
    return {'wiki': context['resource_wiki'], 'title': expected_title, 'page_id': page['pageid'],
            'revision_id': rev['revid'], 'revision_timestamp': rev['timestamp'],
            'content_model': model, 'source_sha1': sha1}, css


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def get_response(url, timeout, accept):
    request = urllib.request.Request(url, headers={'User-Agent': evidence.AGENT, 'Accept': accept})
    try:
        response = urllib.request.build_opener(NoRedirect).open(request, timeout=timeout)
    except urllib.error.HTTPError as error:
        response = error
    with response:
        return response.status, dict(response.headers), response.read(MAX_BYTES + 1), response.url


def request(root, number, url, accept, transport, deadline):
    name = f'request-{number:02d}'
    specification = {'url': url, 'accept': accept, 'method': 'GET', 'retry': False}
    evidence.document(root / (name + '.json'), specification)
    receipt = {'request': name + '.json', 'started_utc': evidence.utc(), 'accepted': False}
    try:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise ValueError('Stylesheet capture deadline')
        status, headers, raw, final = transport(url, min(10.0, remaining), accept)
        receipt.update(status=status, headers=headers, final_url=final,
                       response=name + '.response', response_bytes=len(raw), response_sha256=digest(raw))
        evidence.put(root / receipt['response'], raw)
        if len(raw) > MAX_BYTES or final != url or status != 200:
            raise ValueError('Stylesheet HTTP failure/redirect; no retry or reroute')
        mime = next((str(v).split(';', 1)[0].strip().lower() for k, v in headers.items() if k.lower() == 'content-type'), '')
        if mime != accept:
            raise ValueError('Unexpected stylesheet response MIME')
        receipt.update(accepted=True, ended_utc=evidence.utc())
        evidence.document(root / (name + '.receipt.json'), receipt)
        return raw, receipt
    except BaseException as error:
        receipt.update(error=str(error), ended_utc=evidence.utc())
        evidence.document(root / (name + '.receipt.json'), receipt)
        raise


def replay_request(spec_raw, receipt_raw, raw, number, url, accept):
    specification = evidence.decode(spec_raw)
    receipt = evidence.decode(receipt_raw)
    started = observed_utc(receipt.get('started_utc'))
    ended = observed_utc(receipt.get('ended_utc'))
    mime = next((str(v).split(';', 1)[0].strip().lower() for k, v in receipt.get('headers', {}).items() if k.lower() == 'content-type'), '')
    if (ended < started or specification != {'url': url, 'accept': accept, 'method': 'GET', 'retry': False}
            or receipt.get('request') != f'request-{number:02d}.json' or receipt.get('accepted') is not True
            or receipt.get('status') != 200 or receipt.get('final_url') != url or mime != accept
            or receipt.get('response') != f'request-{number:02d}.response'
            or receipt.get('response_bytes') != len(raw) or receipt.get('response_sha256') != digest(raw)):
        raise ValueError('Unreplayable stylesheet HTTP evidence')
    return started, ended


def continuation_failure(raw):
    value = evidence.decode(raw)
    if (not isinstance(value, dict) or value.get('schema') != SCHEMA or value.get('retry') is not False
            or not isinstance(value.get('error'), str) or not value['error']):
        raise ValueError('Invalid retained first-response disposition')
    checked_producer(value.get('producer'))
    return observed_utc(value.get('ended_utc'))


def finish_capture(root, css, auth, selected, context, revision, raw, identity, continuation=False):
    pinned = context['leaf_url'] + '&oldid=' + str(revision['revision_id'])
    evidence.put(root / 'resource.css', raw)
    snapshot = {'schema': SCHEMA, 'wiki': auth['wiki'], 'dump_date': auth['dump_date'],
                'namespace_sha256': auth['namespace_sha256'], 'root_css_sha256': digest(css),
                'root_page_id': auth['page_id'], 'root_revision_id': auth['revision_id'],
                'import': selected,
                'resource': {'url': context['leaf_url'], 'base_url': pinned, 'revision': revision,
                             'css_bytes': len(raw), 'css_sha256': digest(raw), 'css': raw.decode('utf-8')}}
    evidence.document(root / SNAPSHOT, snapshot)
    names = ['root-common.css', 'root-authority.json', 'requested.json', 'resource.css', SNAPSHOT]
    names += [f'request-{n:02d}{suffix}' for n in (1, 2) for suffix in ('.json', '.receipt.json', '.response')]
    manifest = {'schema': SCHEMA, 'producer': identity, 'retrieved_utc': evidence.utc(),
                'temporal_scope': context['temporal_scope']}
    if continuation:
        names.append('continued-from.failure.json')
        # This producer assembles a new generation. The first request, receipt,
        # response and their UTC times remain byte-exact from the old producer.
        manifest['continuation'] = {'schema': 'wikidict.stylesheet-retained-first.v1',
                                    'parent_failure_sha256': digest(read(root / 'continued-from.failure.json'))}
    manifest['artifacts'] = {name: digest(read(root / name)) for name in names}
    evidence.document(root / MANIFEST, manifest)
    verify(root, require_complete=False)
    if identity != producer():
        raise ValueError('Changed collector/dependency source')
    evidence.document(root / COMPLETE, {'schema': SCHEMA, 'manifest_sha256': digest(read(root / MANIFEST))})
    return verify(root)


def resume_capture(root, previous, root_css, root_authority, transport=None, wall_seconds=25):
    """Finish only raw request two after a retained accepted first observation.

    Never reissue the API request, resume access failures, or overwrite the old
    generation. Any evidence of request two forbids this single-request continuation.
    """
    previous = checked_root(previous)
    destination = Path(root).resolve()
    if destination == previous.resolve() or previous.resolve() in destination.parents:
        raise ValueError('Continuation output overlaps retained generation')
    expected = {'root-common.css', 'root-authority.json', 'requested.json', 'failure.json',
                'request-01.json', 'request-01.receipt.json', 'request-01.response'}
    if {p.name for p in previous.iterdir()} != expected:
        raise ValueError('Retained first response is not an unissued-second-request generation')
    retained = {name: read(previous / name, MAX_BYTES if name.endswith('.response') or name == 'root-common.css' else MAX_JSON)
                for name in expected}
    css = read(root_css, MAX_BYTES)
    auth = authority(read(root_authority), css)
    context = import_context(auth['wiki'])
    selected = requirement(css, auth['wiki'])
    if (retained['root-common.css'] != css or authority(retained['root-authority.json'], css) != auth
            or evidence.decode(retained['requested.json']) != {'schema': SCHEMA, 'root_css_sha256': digest(css), 'import': selected, 'max_requests': 2, 'no_retries': True}):
        raise ValueError('Retained first-response root context mismatch')
    api_url = context['api'] + '?' + urllib.parse.urlencode(api_query(context))
    _, ended = replay_request(retained['request-01.json'], retained['request-01.receipt.json'],
                              retained['request-01.response'], 1, api_url, 'application/json')
    if continuation_failure(retained['failure.json']) < ended:
        raise ValueError('Retained first-response disposition predates its response')
    revision, imported = parse_api(retained['request-01.response'], context)
    identity = producer()
    root = Path(root)
    root.mkdir(parents=True, exist_ok=False)
    for name, raw in retained.items():
        evidence.put(root / ('continued-from.failure.json' if name == 'failure.json' else name), raw)
    deadline = time.monotonic() + wall_seconds
    try:
        pinned = context['leaf_url'] + '&oldid=' + str(revision['revision_id'])
        raw, _ = request(root, 2, pinned, 'text/css', transport or get_response, deadline)
        if raw != imported:
            raise ValueError('Pinned raw stylesheet differs from API source bytes')
        return finish_capture(root, css, auth, selected, context, revision, raw, identity, continuation=True)
    except BaseException as error:
        evidence.document(root / 'failure.json', {'schema': SCHEMA, 'error': str(error), 'ended_utc': evidence.utc(), 'producer': identity, 'retry': False})
        raise


def capture(root, root_css, root_authority, transport=None, wall_seconds=25):
    root = Path(root)
    root.mkdir(parents=True, exist_ok=False)
    css = read(root_css, MAX_BYTES)
    raw_authority = read(root_authority)
    auth = authority(raw_authority, css)
    context = import_context(auth['wiki'])
    selected = requirement(css, auth['wiki'])
    identity = producer()
    deadline = time.monotonic() + wall_seconds
    evidence.put(root / 'root-common.css', css)
    evidence.document(root / 'root-authority.json', auth)
    evidence.document(root / 'requested.json', {'schema': SCHEMA, 'root_css_sha256': digest(css), 'import': selected, 'max_requests': 2, 'no_retries': True})
    try:
        query = api_query(context)
        api_url = context['api'] + '?' + urllib.parse.urlencode(query)
        api_raw, api_receipt = request(root, 1, api_url, 'application/json', transport or get_response, deadline)
        revision, imported = parse_api(api_raw, context)
        pinned = context['leaf_url'] + '&oldid=' + str(revision['revision_id'])
        raw, raw_receipt = request(root, 2, pinned, 'text/css', transport or get_response, deadline)
        if raw != imported:
            raise ValueError('Pinned raw stylesheet differs from API source bytes')
        return finish_capture(root, css, auth, selected, context, revision, raw, identity)
    except BaseException as error:
        evidence.document(root / 'failure.json', {'schema': SCHEMA, 'error': str(error), 'ended_utc': evidence.utc(), 'producer': identity, 'retry': False})
        raise


# Explicit offline source derivation, separate from the PT HTTP observation.
# These fixed pins encode the reviewed selected-property closure. They are not
# caller assertions of arbitrary range completeness or a claim of skin parity.
CORE_SCHEMA = 'wikidict.core-default-styles.v1'
CORE_REVISION = '79b81ba96674efc8a803fc956bc501d347d440d2'
CORE_POLICY = 'mediawiki-79b81-elements-literal-alignment-v1'
CORE_RAW_SHA = 'c750bb9f3cfdf543d287ce2a45f87150b8ca35e1fe0944e0636c11a7bcc583bb'
CORE_NORMALIZED_SHA = '62c5d7bdbe3a9df80b178f5346075ac2e1265fbec423859166be439f509ada86'
CORE_NAMESPACE_SHA = 'c27eaadbf67364c9eef4848466df97c439fcf36e780f7e47d795a359222e7641'
CORE_RANGE = {'source_index': 0, 'start': 4824, 'end': 4927,
              'sha256': '1bfe9721e23c539bf6a8c1312f447178cc0c90799f2888578af30313331497ea'}
CORE_SOURCES = (
    ('mediawiki-79b81-elements.less', 'resources/src/mediawiki.skinning/elements.less', 5025, '91b3adb124ea39ea8d3c0f4b4ccabe0b4b407c92a5d4eca495e9f022ed44bb94'),
    ('mediawiki.mixins.less', 'resources/src/mediawiki.less/mediawiki.mixins.less', 7459, '3dc08902d9913935a32d341648ad08e856a723efea8f6706733fbd2daacea19a'),
    ('mediawiki.skin.variables.less', 'resources/src/mediawiki.less/mediawiki.skin.variables.less', 206, 'a7e87080020f19b64470e7a61b9aa8267dcc0f74ca6a7fa714ea1bbb4a0ea32f'),
    ('mediawiki.skin.defaults.less', 'resources/src/mediawiki.less/mediawiki.skin.defaults.less', 19027, '412516b776272f977dd5c54456a4782599b3668ed9bdd2d15ececd0ba119b8a6'),
)
CORE_TEMPORAL_SCOPE = 'Offline reviewed core source derivation from version observed 2026-10-06; not historical dump-date deployment or skin equivalence'


def core_snapshot(css, root_authority, siteinfo_raw, siteinfo_normalized, namespace, sources):
    auth = evidence.decode(root_authority)
    if 'table_styles' in auth:
        auth = auth['table_styles']['authority']
    if (not isinstance(auth, dict) or auth.get('wiki') != 'euwiktionary'
            or auth.get('dump_date') != '20261001' or auth.get('title') != 'MediaWiki:Common.css'
            or auth.get('content_model') != 'css' or auth.get('decoded_source_bytes') != len(css)
            or auth.get('decoded_source_sha256') != digest(css)
            or auth.get('namespace_sha256') != CORE_NAMESPACE_SHA
            or type(auth.get('page_id')) is not int or auth['page_id'] <= 0
            or type(auth.get('revision_id')) is not int or auth['revision_id'] <= 0
            or len(css) > MAX_BYTES):
        raise ValueError('Core default root authority mismatch')
    css.decode('utf-8')
    if (digest(siteinfo_raw) != CORE_RAW_SHA or digest(siteinfo_normalized) != CORE_NORMALIZED_SHA
            or digest(namespace) != CORE_NAMESPACE_SHA):
        raise ValueError('Core default siteinfo or namespace mismatch')
    general = evidence.decode(siteinfo_raw)['query']['general']
    normalized = evidence.decode(siteinfo_normalized)
    if (general.get('generator') != 'MediaWiki 1.47.0-wmf.22'
            or general.get('git-hash') != CORE_REVISION or general.get('wikiid') != auth['wiki']
            or normalized.get('namespace_registry_sha256') != CORE_NAMESPACE_SHA
            or normalized.get('raw_response_sha256') != CORE_RAW_SHA
            or normalized.get('wiki') != auth['wiki'] or normalized.get('date') != auth['dump_date']):
        raise ValueError('Core default version/edition join mismatch')
    if set(sources) != {item[0] for item in CORE_SOURCES}:
        raise ValueError('Incomplete reviewed core source closure')
    full = []
    for name, source_path, size, wanted in CORE_SOURCES:
        raw = sources[name]
        if len(raw) != size or digest(raw) != wanted:
            raise ValueError('Changed reviewed core source closure')
        full.append({'path': source_path, 'bytes': size, 'sha256': wanted, 'text': raw.decode('utf-8')})
    projected = sources[CORE_SOURCES[0][0]][CORE_RANGE['start']:CORE_RANGE['end']]
    if digest(projected) != CORE_RANGE['sha256']:
        raise ValueError('Changed reviewed core projection')
    return {'schema': CORE_SCHEMA, 'wiki': auth['wiki'], 'dump_date': auth['dump_date'],
            'namespace_sha256': auth['namespace_sha256'], 'root_css_sha256': digest(css),
            'root_page_id': auth['page_id'], 'root_revision_id': auth['revision_id'],
            'core_revision': CORE_REVISION, 'coverage_policy': CORE_POLICY,
            'siteinfo_raw': siteinfo_raw.decode('utf-8'), 'siteinfo_normalized': siteinfo_normalized.decode('utf-8'),
            'sources': full, 'projection': dict(CORE_RANGE)}


def verify_core_defaults(root, manifest, require_complete=True):
    expected_names = {'root-common.css', 'root-authority.json', 'siteinfo.raw.json',
                      'siteinfo.normalized.json', 'namespace-registry.tsv', SNAPSHOT}
    expected_names |= {item[0] for item in CORE_SOURCES}
    if (manifest.get('schema') != CORE_SCHEMA or manifest.get('kind') != 'offline-reviewed-source-derivation'
            or manifest.get('temporal_scope') != CORE_TEMPORAL_SCOPE
            or manifest.get('coverage_policy') != CORE_POLICY
            or set(manifest.get('artifacts', {})) != expected_names):
        raise ValueError('Changed core default derivation manifest')
    checked_producer(manifest.get('producer'))
    for name, wanted in manifest['artifacts'].items():
        if not hash_string(wanted) or digest(read(root / name)) != wanted:
            raise ValueError('Changed core default derivation evidence')
    if require_complete:
        complete = evidence.decode(read(root / COMPLETE))
        if complete != {'schema': CORE_SCHEMA, 'manifest_sha256': digest(read(root / MANIFEST))}:
            raise ValueError('Invalid core default derivation completion')
    expected = core_snapshot(read(root / 'root-common.css', MAX_BYTES), read(root / 'root-authority.json'),
                             read(root / 'siteinfo.raw.json'), read(root / 'siteinfo.normalized.json'),
                             read(root / 'namespace-registry.tsv'),
                             {item[0]: read(root / item[0], MAX_BYTES) for item in CORE_SOURCES})
    if evidence.decode(read(root / SNAPSHOT)) != expected:
        raise ValueError('Changed core default snapshot projection')
    return expected


def derive_core_defaults(output, root_css, root_authority, siteinfo_raw, siteinfo_normalized, namespace, source_dir):
    # No network. Refuse an existing destination and preserve every input byte.
    artifacts = {'root-common.css': read(root_css, MAX_BYTES), 'root-authority.json': read(root_authority),
                 'siteinfo.raw.json': read(siteinfo_raw), 'siteinfo.normalized.json': read(siteinfo_normalized),
                 'namespace-registry.tsv': read(namespace)}
    artifacts.update({item[0]: read(Path(source_dir) / item[0], MAX_BYTES) for item in CORE_SOURCES})
    value = core_snapshot(artifacts['root-common.css'], artifacts['root-authority.json'],
                          artifacts['siteinfo.raw.json'], artifacts['siteinfo.normalized.json'],
                          artifacts['namespace-registry.tsv'], {item[0]: artifacts[item[0]] for item in CORE_SOURCES})
    root = Path(output)
    root.mkdir(parents=True, exist_ok=False)
    for name, raw in artifacts.items():
        evidence.put(root / name, raw)
    evidence.document(root / SNAPSHOT, value)
    artifacts[SNAPSHOT] = read(root / SNAPSHOT)
    evidence.document(root / MANIFEST, {'schema': CORE_SCHEMA, 'kind': 'offline-reviewed-source-derivation',
                      'temporal_scope': CORE_TEMPORAL_SCOPE, 'coverage_policy': CORE_POLICY,
                      'producer': producer(), 'artifacts': {name: digest(raw) for name, raw in artifacts.items()}})
    verify(root, require_complete=False)
    evidence.document(root / COMPLETE, {'schema': CORE_SCHEMA, 'manifest_sha256': digest(read(root / MANIFEST))})
    return verify(root)


def verify(root, require_complete=True):
    root = checked_root(root)
    manifest = evidence.decode(read(root / MANIFEST))
    if manifest.get('schema') in (CUSTOM_SCHEMA, ABSENT_SCHEMA):
        return verify_custom_properties(root, manifest, require_complete)
    if manifest.get('schema') == CORE_SCHEMA:
        return verify_core_defaults(root, manifest, require_complete)
    if manifest.get('schema') != SCHEMA:
        raise ValueError('Changed stylesheet schema')
    checked_producer(manifest.get('producer'))
    retrieved = observed_utc(manifest.get('retrieved_utc'))
    expected = {'root-common.css', 'root-authority.json', 'requested.json', 'resource.css', SNAPSHOT}
    expected |= {f'request-{n:02d}{suffix}' for n in (1, 2) for suffix in ('.json', '.receipt.json', '.response')}
    continuation = manifest.get('continuation')
    if continuation is not None:
        if (not isinstance(continuation, dict) or set(continuation) != {'schema', 'parent_failure_sha256'}
                or continuation.get('schema') != 'wikidict.stylesheet-retained-first.v1'
                or not hash_string(continuation.get('parent_failure_sha256'))):
            raise ValueError('Invalid stylesheet continuation provenance')
        expected.add('continued-from.failure.json')
    if set(manifest.get('artifacts', {})) != expected:
        raise ValueError('Unexpected stylesheet evidence inventory')
    for name, wanted in manifest['artifacts'].items():
        if digest(read(root / name)) != wanted:
            raise ValueError('Changed stylesheet evidence')
    if require_complete:
        complete = evidence.decode(read(root / COMPLETE))
        if complete != {'schema': SCHEMA, 'manifest_sha256': digest(read(root / MANIFEST))}:
            raise ValueError('Invalid stylesheet completion')
    css = read(root / 'root-common.css', MAX_BYTES)
    auth = authority(read(root / 'root-authority.json'), css)
    context = import_context(auth['wiki'])
    selected = requirement(css, auth['wiki'])
    if manifest.get('temporal_scope') != context['temporal_scope']:
        raise ValueError('Changed stylesheet temporal scope/schema')
    if evidence.decode(read(root / 'requested.json')) != {'schema': SCHEMA, 'root_css_sha256': digest(css), 'import': selected, 'max_requests': 2, 'no_retries': True}:
        raise ValueError('Changed stylesheet requirement')
    revision, imported = parse_api(read(root / 'request-01.response', MAX_BYTES), context)
    pinned = context['leaf_url'] + '&oldid=' + str(revision['revision_id'])
    urls = [context['api'] + '?' + urllib.parse.urlencode(api_query(context)), pinned]
    previous_end = None
    bounds = []
    for n, (url, accept) in enumerate(zip(urls, ['application/json', 'text/css']), 1):
        raw = read(root / f'request-{n:02d}.response', MAX_BYTES)
        started, ended = replay_request(read(root / f'request-{n:02d}.json'),
                                        read(root / f'request-{n:02d}.receipt.json'), raw, n, url, accept)
        if ended > retrieved or (previous_end is not None and started < previous_end):
            raise ValueError('Reordered stylesheet observation receipts')
        previous_end = ended
        bounds.append((started, ended))
    if continuation is not None:
        failure_raw = read(root / 'continued-from.failure.json')
        if digest(failure_raw) != continuation['parent_failure_sha256']:
            raise ValueError('Changed stylesheet continuation provenance')
        ended = continuation_failure(failure_raw)
        if not bounds[0][1] <= ended <= bounds[1][0]:
            raise ValueError('Reordered stylesheet continuation observations')
    if observed_utc(revision['revision_timestamp']) > retrieved:
        raise ValueError('Future revision cannot explain recorded current response')
    if read(root / 'resource.css', MAX_BYTES) != imported or read(root / 'request-02.response', MAX_BYTES) != imported:
        raise ValueError('Changed pinned raw stylesheet')
    expected_snapshot = {'schema': SCHEMA, 'wiki': auth['wiki'], 'dump_date': auth['dump_date'],
                         'namespace_sha256': auth['namespace_sha256'], 'root_css_sha256': digest(css),
                         'root_page_id': auth['page_id'], 'root_revision_id': auth['revision_id'],
                         'import': selected,
                         'resource': {'url': context['leaf_url'], 'base_url': pinned, 'revision': revision,
                                      'css_bytes': len(imported), 'css_sha256': digest(imported), 'css': imported.decode('utf-8')}}
    if evidence.decode(read(root / SNAPSHOT)) != expected_snapshot:
        raise ValueError('Changed stylesheet snapshot projection')
    return expected_snapshot


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--verify', type=Path)
    parser.add_argument('--resume-first-response', type=Path)
    parser.add_argument('--output', type=Path)
    parser.add_argument('--root-css', type=Path)
    parser.add_argument('--root-authority', type=Path)
    parser.add_argument('--absent-root-page-table', type=Path)
    parser.add_argument('--dumpstatus', type=Path)
    parser.add_argument('--core-defaults', action='store_true')
    parser.add_argument('--custom-properties-capture', type=Path)
    parser.add_argument('--siteinfo-raw', type=Path)
    parser.add_argument('--siteinfo-normalized', type=Path)
    parser.add_argument('--namespace-registry', type=Path)
    parser.add_argument('--core-source-dir', type=Path)
    args = parser.parse_args()
    if args.verify:
        verify(args.verify)
    elif args.resume_first_response:
        if not all((args.output, args.root_css, args.root_authority)):
            parser.error('continuation requires output, root css and authority')
        resume_capture(args.output, args.resume_first_response, args.root_css, args.root_authority)
    elif args.absent_root_page_table:
        if not all((args.output, args.custom_properties_capture, args.namespace_registry, args.dumpstatus)) or args.root_css or args.root_authority:
            parser.error('absent root requires page table, namespace registry, dumpstatus and observed page')
        derive_custom_properties(args.output, None, None, args.custom_properties_capture,
                                 (args.absent_root_page_table, args.namespace_registry, args.dumpstatus))
    elif args.custom_properties_capture:
        if not all((args.output, args.root_css, args.root_authority)):
            parser.error('custom properties require root css, authority and retained capture')
        derive_custom_properties(args.output, args.root_css, args.root_authority, args.custom_properties_capture)
    elif args.core_defaults:
        if not all((args.output, args.root_css, args.root_authority, args.siteinfo_raw,
                    args.siteinfo_normalized, args.namespace_registry, args.core_source_dir)):
            parser.error('core defaults require exact root, metadata, namespace and source inputs')
        derive_core_defaults(args.output, args.root_css, args.root_authority, args.siteinfo_raw,
                             args.siteinfo_normalized, args.namespace_registry, args.core_source_dir)
    else:
        if not all((args.output, args.root_css, args.root_authority)):
            parser.error('capture requires output/root-css/root-authority')
        capture(args.output, args.root_css, args.root_authority)


def snapshot_summary(path, value):
    raw = read(path)
    record = {'schema': value['schema'], 'wiki': value['wiki'], 'date': value['dump_date'],
              'namespace_registry_sha256': value['namespace_sha256'],
              'output_sha256': digest(raw), 'output_bytes': len(raw)}
    if value['schema'] == ABSENT_SCHEMA:
        status = read(Path(path).with_name('pagetable-dumpstatus.raw.json'))
        if digest(status) != value['root_absence']['dumpstatus_sha256']:
            raise ValueError('Changed page table dumpstatus during snapshot projection')
        files = evidence.decode(status)['jobs']['pagetable']['files']
        name = f"{value['wiki']}-{value['dump_date']}-page.sql.gz"
        item = files[name]
        record['source_dump_files'] = [{'wiki': value['wiki'], 'date': value['dump_date'], 'name': name,
                                        'url': 'https://dumps.wikimedia.org' + item['url'],
                                        'size': item['size'], 'sha1': item['sha1']}]
    return record


def validate_snapshot(path, wiki=None, date=None):
    path = Path(path)
    if path.name != SNAPSHOT:
        raise ValueError('Unexpected stylesheet snapshot filename')
    value = verify(path.parent)
    if (wiki is not None and value['wiki'] != wiki) or (date is not None and value['dump_date'] != date):
        raise ValueError('Stylesheet snapshot edition/date mismatch')
    return snapshot_summary(path, value)


def capture_artifacts(path, record=None):
    path = Path(path)
    if path.name != SNAPSHOT:
        raise ValueError('Unexpected stylesheet snapshot filename')
    value = verify(path.parent)
    if record is not None and record != snapshot_summary(path, value):
        raise ValueError('Changed stylesheet capture context')
    manifest = evidence.decode(read(path.with_name(MANIFEST)))
    return {**manifest['artifacts'], MANIFEST: digest(read(path.with_name(MANIFEST))),
            COMPLETE: digest(read(path.with_name(COMPLETE)))}


ABSENT_SCOPE = 'current anonymous server-emitted screen styles before client scripts applied to retained source; not historical dump deployment'
ABSENT_SCHEMA = 'wikidict.stylesheet-imports.custom-properties-absent-root.v1'
CUSTOM_SCHEMA = 'wikidict.custom-property-styles.v1'
CUSTOM_TEMPORAL_SCOPE = 'current anonymous screen stylesheet observation applied to retained source; not historical dump deployment'


def custom_page_context(raw, page_url):
    # Read the actual advertised sources and ancestor spelling; this does not
    # execute scripts, adopt browser preferences or claim historical API state.
    from html.parser import HTMLParser
    text = raw.decode('utf-8')
    line_starts = [0]
    for match in re.finditer('\n', text):
        line_starts.append(match.end())

    class ContextParser(HTMLParser):
        def __init__(self):
            super().__init__(convert_charrefs=False)
            self.stack = []
            self.ancestors = None
            self.links = []
            self.inline = []
            self.sequence = []
            self.style = None
            self.generator = None
            self.failed = False

        def handle_starttag(self, tag, attrs):
            values = dict(attrs)
            if len(values) != len(attrs):
                self.failed = True
            if tag == 'base' and 'href' in values:
                self.failed = True
            if tag == 'meta' and values.get('name') == 'generator':
                self.generator = values.get('content')
            rel = (values.get('rel') or '').lower().split()
            if tag == 'link' and 'stylesheet' in rel:
                href = values.get('href')
                if (not href or rel != ['stylesheet']
                        or 'disabled' in values or values.get('title') not in (None, '')
                        or values.get('type') not in (None, '', 'text/css')
                        or values.get('media') not in (None, '', 'screen', 'all')):
                    self.failed = True
                self.sequence.append(('link', len(self.links)))
                self.links.append(urllib.parse.urljoin(page_url, href or ''))
            if tag == 'style':
                if ('disabled' in values or 'scoped' in values or values.get('title') not in (None, '')
                        or values.get('media') not in (None, '', 'screen', 'all')
                        or values.get('type') not in (None, '', 'text/css')):
                    self.failed = True
                self.style = []
            if tag in {'area', 'base', 'br', 'col', 'embed', 'hr', 'img', 'input', 'link', 'meta', 'param', 'source', 'track', 'wbr'}:
                return
            line, column = self.getpos()
            character_start = line_starts[line - 1] + column
            start = len(text[:character_start].encode('utf-8'))
            item = {'tag': tag, 'classes': values.get('class') or '', 'id': values.get('id') or '',
                    'inline_css': values.get('style') or '',
                    '_encoded_attributes': '&' in self.get_starttag_text(),
                    'root': tag == 'html', 'start': start,
                    'end': start + len(self.get_starttag_text().encode('utf-8'))}
            self.stack.append(item)
            if self.ancestors is None and 'mw-parser-output' in item['classes'].split():
                self.ancestors = [dict(entry) for entry in self.stack]
                if any(entry.pop('_encoded_attributes') for entry in self.ancestors):
                    self.failed = True

        def handle_startendtag(self, tag, attrs):
            self.handle_starttag(tag, attrs)
            self.handle_endtag(tag)

        def handle_endtag(self, tag):
            if tag == 'style' and self.style is not None:
                self.sequence.append(('inline', len(self.inline)))
                self.inline.append(''.join(self.style))
                self.style = None
            for i in range(len(self.stack) - 1, -1, -1):
                if self.stack[i]['tag'] == tag:
                    del self.stack[i:]
                    break

        def handle_data(self, data):
            if self.style is not None:
                self.style.append(data)

        def handle_entityref(self, name):
            if self.style is not None:
                self.style.append('&' + name + ';')

        def handle_charref(self, name):
            if self.style is not None:
                self.style.append('&#' + name + ';')

    parsed = ContextParser()
    parsed.feed(text)
    parsed.close()
    ancestors = parsed.ancestors
    if (parsed.failed or not parsed.generator or not ancestors or len(ancestors) < 2 or len(ancestors) > 32
            or ancestors[0]['tag'] != 'html' or ancestors[1]['tag'] != 'body'
            or any(item['root'] for item in ancestors[1:]) or not parsed.links or len(parsed.links) > 16):
        raise ValueError('Unsupported stylesheet page/context structure')
    query = urllib.parse.parse_qs(urllib.parse.urlsplit(page_url).query, strict_parsing=True)
    skin = query.get('useskin')
    if (not skin or len(skin) != 1 or not re.fullmatch(r'[a-z0-9-]+', skin[0])
            or len(query.get('title', [])) != 1 or not query['title'][0]):
        raise ValueError('An explicit selected skin is required')
    classes = ancestors[0]['classes'].split()
    themes = [value for value in classes if value.startswith('skin-theme-clientpref-')]
    if themes not in (['skin-theme-clientpref-day'], ['skin-theme-clientpref-night']):
        raise ValueError('Explicit day/night context required; OS preference is unknown')
    # A selected day/night skin class does not reveal the user's OS media
    # preference. Conditional prefers-color-scheme rules remain unknown unless
    # their own selector excludes them (as html...-os does for this day root).
    return parsed, skin[0], None


def custom_snapshot(artifacts):
    css = artifacts['root-common.css']
    auth = evidence.decode(artifacts['root-authority.json'])
    if 'table_styles' in auth:
        auth = auth['table_styles']['authority']
    if (auth.get('title') != 'MediaWiki:Common.css' or auth.get('content_model') != 'css'
            or auth.get('decoded_source_sha256') != digest(css) or auth.get('decoded_source_bytes') != len(css)
            or not hash_string(auth.get('namespace_sha256')) or not re.fullmatch(r'[a-z0-9_-]+wiktionary', auth.get('wiki', ''))
            or not re.fullmatch(r'\d{8}', auth.get('dump_date', ''))
            or type(auth.get('page_id')) is not int or auth['page_id'] <= 0
            or type(auth.get('revision_id')) is not int or auth['revision_id'] <= 0):
        raise ValueError('Custom-property root authority mismatch')
    root_fields = {'root_css_sha256': digest(css), 'root_page_id': auth['page_id'], 'root_revision_id': auth['revision_id']}
    return screen_snapshot(artifacts, auth, root_fields, len(css), {'root-common.css', 'root-authority.json'}, CUSTOM_SCHEMA)


def screen_snapshot(artifacts, auth, root_fields, root_css_bytes, expected, schema):
    specification = evidence.decode(artifacts['request-02.json'])
    page_url = specification['url']
    parsed_url = urllib.parse.urlsplit(page_url)
    if (parsed_url.scheme != 'https' or parsed_url.hostname != auth['wiki'][:-10] + '.wiktionary.org'
            or parsed_url.port is not None or parsed_url.username is not None or parsed_url.fragment):
        raise ValueError('Page observation edition mismatch')
    page = artifacts['request-02.response']
    parsed, skin, dark = custom_page_context(page, page_url)
    if schema == ABSENT_SCHEMA and 'client-nojs' not in parsed.ancestors[0]['classes'].split():
        raise ValueError('Observed root must identify the server-emitted pre-script view')
    sources = []
    requested = [(2, page_url, 'text/html')]
    for n, url in enumerate(parsed.links, 3):
        endpoint = urllib.parse.urlsplit(url)
        params = urllib.parse.parse_qs(endpoint.query, strict_parsing=True)
        if (endpoint.scheme != 'https' or endpoint.netloc != parsed_url.netloc or endpoint.path != '/w/load.php'
                or endpoint.fragment or params.get('only') != ['styles'] or params.get('skin') != [skin]):
            raise ValueError('Unadvertised stylesheet origin or selected skin')
        requested.append((n, url, 'text/css'))
    for n, url, mime in requested:
        names = [f'request-{n:02d}{suffix}' for suffix in ('.json', '.receipt.json', '.response')]
        expected.update(names)
        spec = evidence.decode(artifacts[names[0]])
        receipt = evidence.decode(artifacts[names[1]])
        body = artifacts[names[2]]
        observed_utc(receipt['started_utc'])
        observed_utc(receipt['ended_utc'])
        if (spec.get('url') != url or spec.get('accept') != mime or spec.get('method') != 'GET' or spec.get('retry') is not False
                or receipt.get('accepted') is not True
                or receipt.get('status') != 200 or receipt.get('final_url') != url
                or receipt.get('response_bytes') != len(body) or receipt.get('response_sha256') != digest(body)
                or receipt.get('headers', {}).get('content-type', '').split(';')[0].strip().lower() != mime
                or len(body) > MAX_BYTES):
            raise ValueError('Changed bounded stylesheet request/response')
        body.decode('utf-8')
        if mime == 'text/css':
            sources.append({'url': url, 'css': body.decode('utf-8'), 'bytes': len(body), 'sha256': digest(body)})
    if set(artifacts) != expected:
        raise ValueError('Extra or missing custom-property observation artifact')
    inline_sources = []
    for n, text in enumerate(parsed.inline):
        body = text.encode('utf-8')
        inline_sources.append({'url': page_url + '#inline-style-' + str(n), 'css': text, 'bytes': len(body), 'sha256': digest(body)})
    sources = [(sources if kind == 'link' else inline_sources)[i] for kind, i in parsed.sequence]
    if schema == ABSENT_SCHEMA:
        for source in sources:
            # Unresolved imports can contribute new custom properties. Reject
            # escaped at-rule names too rather than guessing their meaning.
            if re.search(r'@(?:import\b|[\w-]*\\)', source['css'], re.I):
                raise ValueError('Unobserved stylesheet import')
    if sum(source['bytes'] for source in sources) + root_css_bytes > MAX_BYTES:
        raise ValueError('Stylesheet closure exceeds bound')
    return {'schema': schema, 'wiki': auth['wiki'], 'dump_date': auth['dump_date'],
            'namespace_sha256': auth['namespace_sha256'], **root_fields,
            'temporal_scope': ABSENT_SCOPE if schema == ABSENT_SCHEMA else CUSTOM_TEMPORAL_SCOPE,
            'observed_utc': evidence.decode(artifacts['request-02.receipt.json'])['ended_utc'],
            'page_url': page_url, 'page_title': urllib.parse.parse_qs(parsed_url.query)['title'][0],
            'page_html': page.decode('utf-8'), 'page_sha256': digest(page),
            'generator': parsed.generator, 'skin': skin, 'dark': dark, 'ancestors': parsed.ancestors, 'sources': sources}


def absent_root_snapshot(artifacts, page_table):
    import category_tree_snapshot
    from html.parser import HTMLParser

    registry = artifacts['namespace-registry.tsv']
    lines = registry.decode().splitlines()
    if (len(lines) < 4 or lines[0] != '# wikidict-namespace-registry-v1' or
            not re.fullmatch(r'# wiki\t[a-z0-9_-]+wiktionary', lines[1]) or
            not re.fullmatch(r'# dump-date\t[0-9]{8}', lines[2]) or
            [line.split('\t')[2] for line in lines if line.startswith('8\t')] != ['MediaWiki']):
        raise ValueError('Invalid MediaWiki namespace or edition identity')
    wiki = lines[1].split('\t')[1]
    date = lines[2].split('\t')[1]
    filename = f'{wiki}-{date}-page.sql.gz'
    status = evidence.decode(artifacts['pagetable-dumpstatus.raw.json'])['jobs']['pagetable']
    if status['status'] != 'done' or set(status['files']) != {filename}:
        raise ValueError('Expected complete official page table')
    official = status['files'][filename]
    before = evidence.stamp(page_table)
    pin = evidence.fingerprint(page_table)
    if (official['url'] != f'/{wiki}/{date}/{filename}' or official['sha1'] != pin['sha1'] or
            official['size'] != pin['size']):
        raise ValueError('Dated page table identity mismatch')

    class PageConfig(HTMLParser):
        in_head = False
        in_script = False
        configurations = None

        def handle_starttag(self, tag, attrs):
            if tag == 'head':
                self.in_head = True
            if tag == 'script' and self.in_head and not attrs:
                self.in_script = True

        def handle_endtag(self, tag):
            if tag == 'head':
                self.in_head = False
            if tag == 'script':
                self.in_script = False

        def handle_data(self, data):
            if self.in_script:
                for match in re.finditer(r'(?<![\w$])RLCONF\s*=\s*(?=\{)', data):
                    value, _ = json.JSONDecoder().raw_decode(data[match.end():])
                    self.configurations.append(value)

    parser = PageConfig()
    parser.configurations = []
    parser.feed(artifacts['request-02.response'].decode())
    parser.close()
    if len(parser.configurations) != 1:
        raise ValueError('Missing or ambiguous observed page identity')
    config = parser.configurations[0]
    page_id, revision_id = config['wgArticleId'], config['wgRevisionId']
    url = evidence.decode(artifacts['request-02.json'])['url']
    query = urllib.parse.parse_qs(urllib.parse.urlsplit(url).query, strict_parsing=True)
    if (urllib.parse.urlsplit(url).path != '/w/index.php' or set(query) != {'useskin', 'oldid', 'title'} or
            type(page_id) != int or type(revision_id) != int or min(page_id, revision_id) < 1 or
            query.get('oldid') != [str(revision_id)] or query.get('title') != [config['wgPageName'].replace('_', ' ')] or
            config['wgNamespaceNumber'] != 0 or config['wgAction'] != 'view' or config['wgIsRedirect'] is not False):
        raise ValueError('Unbound revision, title or view')
    article = (page_id, 0, config['wgPageName'].replace(' ', '_').encode(), revision_id)
    # The official size/hash binds all bytes. Require the mysqldump completion
    # marker as well, so a syntactically complete INSERT prefix cannot pass.
    with gzip.open(page_table, 'rb') as sql:
        last_line = b''
        saw_database = False
        saw_schema = False
        while line := sql.readline(16 * 1024 * 1024 + 1):
            if len(line) > 16 * 1024 * 1024:
                raise ValueError('Oversized page table line')
            if line.startswith(b'-- Host:'):
                saw_database = line.rstrip().endswith(b' Database: ' + wiki.encode())
            if line.startswith(b'CREATE TABLE '):
                if saw_schema or line.rstrip() != b'CREATE TABLE `page` (':
                    raise ValueError('Unexpected page table schema')
                saw_schema = True
            if line.startswith(b'INSERT INTO ') and not line.startswith(b'INSERT INTO `page` VALUES'):
                raise ValueError('Unexpected page table INSERT')
            if line.strip():
                last_line = line.strip()
        if not saw_database or not saw_schema or not re.fullmatch(rb'-- Dump completed on [0-9-]+ [0-9:]+', last_line):
            raise ValueError('Incomplete or mismatched page table dump')
    matches = 0
    for row in category_tree_snapshot.rows(page_table, ['page_id', 'page_namespace', 'page_title', 'page_latest']):
        if row[1:3] == (8, b'Common.css'):
            raise ValueError('MediaWiki:Common.css exists in the dump')
        if row[0] == page_id or row[1:3] == article[1:3]:
            if row != article:
                raise ValueError('Dated article identity mismatch')
            matches += 1
    if matches != 1 or evidence.stamp(page_table) != before:
        raise ValueError('Missing article or changing page table')
    absence = {'namespace': 8, 'dbkey': 'Common.css', 'page_table_sha256': pin['sha256'],
               'page_table_bytes': pin['size'], 'dumpstatus_sha256': digest(artifacts['pagetable-dumpstatus.raw.json']),
               'namespace_registry_sha256': digest(registry)}
    return screen_snapshot(artifacts, {'wiki': wiki, 'dump_date': date, 'namespace_sha256': digest(registry)},
                           {'root_absence': absence, 'article_page_id': page_id, 'article_revision_id': revision_id},
                           0, {'namespace-registry.tsv', 'pagetable-dumpstatus.raw.json'}, ABSENT_SCHEMA)


def derive_custom_properties(output, root_css, root_authority, capture_root, absence_inputs=None):
    # Replay only already retained ordinary collector responses. No networking,
    # retries, current preferences, or modifications of the original capture.
    capture_root = checked_root(capture_root)
    page_url = evidence.decode(read(capture_root / 'request-02.json'))['url']
    parsed, _, _ = custom_page_context(read(capture_root / 'request-02.response', MAX_BYTES), page_url)
    if absence_inputs is None:
        artifacts = {'root-common.css': read(root_css, MAX_BYTES), 'root-authority.json': read(root_authority)}
    else:
        page_table, namespace, dumpstatus = absence_inputs
        artifacts = {'namespace-registry.tsv': read(namespace), 'pagetable-dumpstatus.raw.json': read(dumpstatus)}
    for n in range(2, len(parsed.links) + 3):
        for suffix in ('.json', '.receipt.json', '.response'):
            name = f'request-{n:02d}{suffix}'
            artifacts[name] = read(capture_root / name, MAX_BYTES)
    value = custom_snapshot(artifacts) if absence_inputs is None else absent_root_snapshot(artifacts, page_table)
    root = Path(output)
    root.mkdir(parents=True, exist_ok=False)
    for name, raw in artifacts.items():
        evidence.put(root / name, raw)
    evidence.document(root / SNAPSHOT, value)
    artifacts[SNAPSHOT] = read(root / SNAPSHOT)
    hashes = {name: digest(raw) for name, raw in artifacts.items()}
    if absence_inputs is not None:
        try:
            os.link(page_table, root / 'page.sql.gz', follow_symlinks=False)
        except OSError as error:
            if error.errno != errno.EXDEV:
                raise
            shutil.copyfile(page_table, root / 'page.sql.gz')
        hashes['page.sql.gz'] = value['root_absence']['page_table_sha256']
    evidence.document(root / MANIFEST, {'schema': value['schema'], 'temporal_scope': value['temporal_scope'],
                      'producer': producer(absence_inputs is not None), 'artifacts': hashes})
    verify(root, require_complete=False)
    evidence.document(root / COMPLETE, {'schema': value['schema'], 'manifest_sha256': digest(read(root / MANIFEST))})
    return verify(root)


def verify_custom_properties(root, manifest, require_complete=True):
    scope = ABSENT_SCOPE if manifest['schema'] == ABSENT_SCHEMA else CUSTOM_TEMPORAL_SCOPE
    if manifest.get('temporal_scope') != scope:
        raise ValueError('Changed custom-property temporal scope')
    checked_producer(manifest.get('producer'), manifest['schema'] == ABSENT_SCHEMA)
    artifacts = {}
    for name, wanted in manifest.get('artifacts', {}).items():
        if Path(name).name != name or not hash_string(wanted):
            raise ValueError('Invalid custom-property artifact')
        if name == 'page.sql.gz' and manifest['schema'] == ABSENT_SCHEMA:
            continue
        artifacts[name] = read(root / name)
        if digest(artifacts[name]) != wanted:
            raise ValueError('Changed custom-property evidence')
    actual = evidence.decode(artifacts.pop(SNAPSHOT))
    if manifest['schema'] == ABSENT_SCHEMA:
        expected = absent_root_snapshot(artifacts, root / 'page.sql.gz')
        if manifest['artifacts'].get('page.sql.gz') != expected['root_absence']['page_table_sha256']:
            raise ValueError('Page table digest missing or changed')
    else:
        expected = custom_snapshot(artifacts)
    if actual != expected:
        raise ValueError('Changed custom-property snapshot derivation')
    if require_complete and evidence.decode(read(root / COMPLETE)) != {'schema': manifest['schema'], 'manifest_sha256': digest(read(root / MANIFEST))}:
        raise ValueError('Incomplete custom-property generation')
    return expected


if __name__ == '__main__':
    main()
