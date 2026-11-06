#!/usr/bin/env python3
"""Capture and replay the one reviewed PT Common.css cross-wiki import.

This immutable build-input generation is not historical API state. It never
fetches dependencies discovered in CSS, retries a failed response, or edits the
selected corpus inputs. Unsupported dependency grammar remains unresolved.
"""
import argparse
from datetime import datetime, timezone
import hashlib
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


def checked_producer(value):
    # Historical recorded producer roles remain immutable. Current verification
    # replays every request/source/projection instead of executing old code or
    # restamping an earned capture as produced by this hardened verifier.
    if (not isinstance(value, dict) or set(value) != {'generator_sha256', 'dependency_sha256'}
            or not hash_string(value.get('generator_sha256'))
            or not isinstance(value.get('dependency_sha256'), dict)
            or set(value['dependency_sha256']) != {'prepare_file_metadata.py'}
            or not hash_string(value['dependency_sha256']['prepare_file_metadata.py'])):
        raise ValueError('Malformed recorded stylesheet producer roles')


def producer():
    return {'generator_sha256': digest(read(__file__)),
            'dependency_sha256': {'prepare_file_metadata.py': digest(read(evidence.__file__))}}


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


def requirement(css):
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
    resolved = urllib.parse.urljoin('https://pt.wiktionary.org/w/index.php?title=MediaWiki:Common.css&action=raw&ctype=text/css', authored)
    if resolved != LEAF_URL:
        raise ValueError('Unselected stylesheet origin or page')
    return {'start': start, 'end': at + 1, 'authored_url': authored, 'resolved_url': resolved}


def authority(raw, css):
    value = evidence.decode(raw)
    if 'table_styles' in value:
        value = value['table_styles']['authority']
    if (not isinstance(value, dict) or value.get('wiki') != 'ptwiktionary'
            or not isinstance(value.get('dump_date'), str) or re.fullmatch(r'\d{8}', value['dump_date']) is None or value.get('title') != 'MediaWiki:Common.css'
            or value.get('content_model') != 'css' or value.get('decoded_source_bytes') != len(css)
            or value.get('decoded_source_sha256') != digest(css)
            or type(value.get('page_id')) is not int or value['page_id'] <= 0
            or type(value.get('revision_id')) is not int or value['revision_id'] <= 0
            or not hash_string(value.get('namespace_sha256'))):
        raise ValueError('Root stylesheet authority mismatch')
    css.decode('utf-8')
    return value


def api_query():
    return {'action': 'query', 'format': 'json', 'formatversion': '2',
            'meta': 'siteinfo', 'siprop': 'general', 'prop': 'revisions',
            'titles': TITLE, 'rvslots': 'main',
            'rvprop': 'ids|timestamp|sha1|contentmodel|content'}


def parse_api(raw):
    value = evidence.decode(raw)
    if any(key in value for key in ('error', 'errors', 'warnings', 'continue')):
        raise ValueError('Incomplete stylesheet API observation')
    query = value.get('query', {})
    general = query.get('general', {})
    if general.get('wikiid') != 'mediawikiwiki':
        raise ValueError('Stylesheet origin identity mismatch')
    pages = query.get('pages')
    if not isinstance(pages, list) or len(pages) != 1:
        raise ValueError('Incomplete exact stylesheet page')
    page = pages[0]
    if page.get('title') != TITLE or type(page.get('ns')) is not int or page.get('ns') != 8 or page.get('missing') or page.get('redirect') or type(page.get('pageid')) is not int or page['pageid'] <= 0:
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
    return {'wiki': 'mediawikiwiki', 'title': TITLE, 'page_id': page['pageid'],
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


def capture(root, root_css, root_authority, transport=None, wall_seconds=25):
    root = Path(root)
    root.mkdir(parents=True, exist_ok=False)
    css = read(root_css, MAX_BYTES)
    raw_authority = read(root_authority)
    auth = authority(raw_authority, css)
    selected = requirement(css)
    identity = producer()
    deadline = time.monotonic() + wall_seconds
    evidence.put(root / 'root-common.css', css)
    evidence.document(root / 'root-authority.json', auth)
    evidence.document(root / 'requested.json', {'schema': SCHEMA, 'root_css_sha256': digest(css), 'import': selected, 'max_requests': 2, 'no_retries': True})
    try:
        query = api_query()
        api_url = API + '?' + urllib.parse.urlencode(query)
        api_raw, api_receipt = request(root, 1, api_url, 'application/json', transport or get_response, deadline)
        revision, imported = parse_api(api_raw)
        pinned = LEAF_URL + '&oldid=' + str(revision['revision_id'])
        raw, raw_receipt = request(root, 2, pinned, 'text/css', transport or get_response, deadline)
        if raw != imported:
            raise ValueError('Pinned raw stylesheet differs from API source bytes')
        evidence.put(root / 'resource.css', raw)
        snapshot = {'schema': SCHEMA, 'wiki': auth['wiki'], 'dump_date': auth['dump_date'],
                    'namespace_sha256': auth['namespace_sha256'], 'root_css_sha256': digest(css),
                    'root_page_id': auth['page_id'], 'root_revision_id': auth['revision_id'],
                    'import': selected,
                    'resource': {'url': LEAF_URL, 'base_url': pinned, 'revision': revision,
                                 'css_bytes': len(raw), 'css_sha256': digest(raw), 'css': raw.decode('utf-8')}}
        evidence.document(root / SNAPSHOT, snapshot)
        names = ['root-common.css', 'root-authority.json', 'requested.json', 'resource.css', SNAPSHOT]
        names += [f'request-{n:02d}{suffix}' for n in (1, 2) for suffix in ('.json', '.receipt.json', '.response')]
        manifest = {'schema': SCHEMA, 'producer': identity, 'retrieved_utc': evidence.utc(),
                    'temporal_scope': TEMPORAL_SCOPE,
                    'artifacts': {name: digest(read(root / name)) for name in names}}
        evidence.document(root / MANIFEST, manifest)
        verify(root, require_complete=False)
        if identity != producer():
            raise ValueError('Changed collector/dependency source')
        evidence.document(root / COMPLETE, {'schema': SCHEMA, 'manifest_sha256': digest(read(root / MANIFEST))})
        return verify(root)
    except BaseException as error:
        evidence.document(root / 'failure.json', {'schema': SCHEMA, 'error': str(error), 'ended_utc': evidence.utc(), 'producer': identity, 'retry': False})
        raise


def verify(root, require_complete=True):
    root = checked_root(root)
    manifest = evidence.decode(read(root / MANIFEST))
    if manifest.get('schema') != SCHEMA or manifest.get('temporal_scope') != TEMPORAL_SCOPE:
        raise ValueError('Changed stylesheet temporal scope/schema')
    checked_producer(manifest.get('producer'))
    retrieved = observed_utc(manifest.get('retrieved_utc'))
    expected = {'root-common.css', 'root-authority.json', 'requested.json', 'resource.css', SNAPSHOT}
    expected |= {f'request-{n:02d}{suffix}' for n in (1, 2) for suffix in ('.json', '.receipt.json', '.response')}
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
    selected = requirement(css)
    if evidence.decode(read(root / 'requested.json')) != {'schema': SCHEMA, 'root_css_sha256': digest(css), 'import': selected, 'max_requests': 2, 'no_retries': True}:
        raise ValueError('Changed stylesheet requirement')
    revision, imported = parse_api(read(root / 'request-01.response', MAX_BYTES))
    pinned = LEAF_URL + '&oldid=' + str(revision['revision_id'])
    urls = [API + '?' + urllib.parse.urlencode(api_query()), pinned]
    previous_end = None
    for n, (url, accept) in enumerate(zip(urls, ['application/json', 'text/css']), 1):
        specification = evidence.decode(read(root / f'request-{n:02d}.json'))
        receipt = evidence.decode(read(root / f'request-{n:02d}.receipt.json'))
        raw = read(root / f'request-{n:02d}.response', MAX_BYTES)
        started = observed_utc(receipt.get('started_utc'))
        ended = observed_utc(receipt.get('ended_utc'))
        if ended < started or ended > retrieved or (previous_end is not None and started < previous_end):
            raise ValueError('Reordered stylesheet observation receipts')
        previous_end = ended
        mime = next((str(v).split(';', 1)[0].strip().lower() for k, v in receipt.get('headers', {}).items() if k.lower() == 'content-type'), '')
        if (specification != {'url': url, 'accept': accept, 'method': 'GET', 'retry': False}
                or receipt.get('request') != f'request-{n:02d}.json' or receipt.get('accepted') is not True
                or receipt.get('status') != 200 or receipt.get('final_url') != url or mime != accept
                or receipt.get('response') != f'request-{n:02d}.response'
                or receipt.get('response_bytes') != len(raw) or receipt.get('response_sha256') != digest(raw)):
            raise ValueError('Unreplayable stylesheet HTTP evidence')
    if observed_utc(revision['revision_timestamp']) > retrieved:
        raise ValueError('Future revision cannot explain recorded current response')
    if read(root / 'resource.css', MAX_BYTES) != imported or read(root / 'request-02.response', MAX_BYTES) != imported:
        raise ValueError('Changed pinned raw stylesheet')
    expected_snapshot = {'schema': SCHEMA, 'wiki': auth['wiki'], 'dump_date': auth['dump_date'],
                         'namespace_sha256': auth['namespace_sha256'], 'root_css_sha256': digest(css),
                         'root_page_id': auth['page_id'], 'root_revision_id': auth['revision_id'],
                         'import': selected,
                         'resource': {'url': LEAF_URL, 'base_url': pinned, 'revision': revision,
                                      'css_bytes': len(imported), 'css_sha256': digest(imported), 'css': imported.decode('utf-8')}}
    if evidence.decode(read(root / SNAPSHOT)) != expected_snapshot:
        raise ValueError('Changed stylesheet snapshot projection')
    return expected_snapshot


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--verify', type=Path)
    parser.add_argument('--output', type=Path)
    parser.add_argument('--root-css', type=Path)
    parser.add_argument('--root-authority', type=Path)
    args = parser.parse_args()
    if args.verify:
        verify(args.verify)
    else:
        if not all((args.output, args.root_css, args.root_authority)):
            parser.error('capture requires output/root-css/root-authority')
        capture(args.output, args.root_css, args.root_authority)


def snapshot_summary(path, value):
    raw = read(path)
    return {'schema': SCHEMA, 'wiki': value['wiki'], 'date': value['dump_date'],
            'namespace_registry_sha256': value['namespace_sha256'],
            'output_sha256': digest(raw), 'output_bytes': len(raw)}


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


if __name__ == '__main__':
    main()
