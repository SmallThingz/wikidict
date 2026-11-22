#!/usr/bin/env python3
"""Capture, derive, and verify edition-scoped magic words without changing old captures.

The dump date associates this input with a corpus snapshot. The API response is
an observation at its recorded retrieval time, not historical dump metadata.
"""
import argparse
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import re
import time
import unicodedata
import urllib.error
import urllib.parse
import urllib.request


SUPPORTED = frozenset('''pagename pagenamee fullpagename fullpagenamee namespace
namespacee namespacenumber basepagename basepagenamee rootpagename rootpagenamee
subpagename subpagenamee subjectspace subjectspacee talkspace talkspacee
subjectpagename subjectpagenamee talkpagename talkpagenamee'''.split())
PARSER_FUNCTIONS = frozenset('''special tag formatdate time len sub titleparts iferror
invoke categorytree if ifeq ifexist switch expr ifexpr displaytitle defaultsort ns
uc lc ucfirst lcfirst formatnum plural anchorencode fullurl fullurle localurl
canonicalurl urlencode padleft padright'''.split())
TITLE_PROFILE = 'title-v1'
PARSER_PROFILE = 'title-and-parser-functions-v1'
DERIVED_DIRECTORY = 'magic-words-parser-v1'
MAX_RAW_BYTES = 4 * 1024 * 1024
MAX_TSV_BYTES = 1024 * 1024
AGENT = 'Wikidict/1.0 (https://github.com/SmallThingz/wikidict)'
ARTIFACTS = frozenset(('magic-words.raw.json', 'magic-words.tsv',
    'magic-words.request.json', 'namespace-siteinfo.raw.json',
    'namespace-capture.complete.json'))
SOURCE_MANIFEST = 'magic-words.source.manifest.json'
SOURCE_TSV = 'magic-words.source.tsv'
DERIVED_ARTIFACTS = ARTIFACTS | {SOURCE_MANIFEST, SOURCE_TSV}


def digest(data):
    return hashlib.sha256(data).hexdigest()


PRODUCER_SHA256 = digest(Path(__file__).read_bytes())


def document(value):
    return (json.dumps(value, ensure_ascii=False, sort_keys=True, indent=2) + '\n').encode('utf-8')


def parse_json(raw):
    def unique(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError('Duplicate JSON key: ' + key)
            result[key] = value
        return result
    return json.loads(raw, object_pairs_hook=unique)


def identity(wiki, date):
    if not isinstance(wiki, str) or not re.fullmatch(r'[a-z0-9_]+wiktionary', wiki):
        raise ValueError('Invalid Wiktionary edition')
    if not isinstance(date, str) or not re.fullmatch(r'\d{8}', date):
        raise ValueError('Invalid dump date')
    dt.datetime.strptime(date, '%Y%m%d')


def language(value):
    if not isinstance(value, str) or not re.fullmatch(r'[a-z][a-z0-9-]*', value):
        raise ValueError('Invalid content language')
    return value


def source_url(wiki):
    identity(wiki, '20000101')
    prefix = wiki[:-len('wiktionary')].replace('_', '-')
    params = dict(action='query', meta='siteinfo', siprop='general|magicwords',
                  format='json', formatversion='2', maxlag='5')
    return 'https://' + prefix + '.wiktionary.org/w/api.php?' + urllib.parse.urlencode(params)


def render_snapshot(data, wiki, date, content_language, profile=TITLE_PROFILE):
    identity(wiki, date)
    language(content_language)
    if profile not in (TITLE_PROFILE, PARSER_PROFILE):
        raise ValueError('Unknown magic-word projection profile')
    supported = SUPPORTED | PARSER_FUNCTIONS if profile == PARSER_PROFILE else SUPPORTED
    if not isinstance(data, dict) or any(data.get(k) for k in ('error', 'errors', 'warnings', 'continue')):
        raise ValueError('Incomplete or unsuccessful siteinfo response')
    query = data.get('query')
    if not isinstance(query, dict) or not isinstance(query.get('general'), dict):
        raise ValueError('Missing siteinfo general identity')
    general = query['general']
    if general.get('wikiid') != wiki or general.get('lang') != content_language:
        raise ValueError('Siteinfo edition/content-language mismatch')
    words = query.get('magicwords')
    if not isinstance(words, list) or not words or len(words) > 10000:
        raise ValueError('Missing or invalid magic-word inventory')
    rows, seen_ids = set(), set()
    for word in words:
        if not isinstance(word, dict) or not isinstance(word.get('name'), str):
            raise ValueError('Invalid magic-word record')
        name = word['name']
        if name not in supported:
            continue
        if name in seen_ids:
            raise ValueError('Duplicate canonical magic word: ' + name)
        seen_ids.add(name)
        sensitive = word.get('case-sensitive', False)
        if type(sensitive) is not bool:
            raise ValueError('Invalid magic-word case flag')
        aliases = word.get('aliases')
        if not isinstance(aliases, list) or not aliases or len(aliases) > 1000:
            raise ValueError('Missing or invalid magic-word aliases')
        for alias in aliases:
            if (not isinstance(alias, str) or not alias or len(alias.encode('utf-8')) > 1024
                    or any(unicodedata.category(c) == 'Cc' for c in alias)):
                raise ValueError('Unsafe magic-word alias')
            # MediaWiki permits aliases shared by canonical words. Preserve all
            # rows; the native resolver applies variable/function registration
            # precedence, which cannot be inferred from TSV sorting.
            rows.add((name, int(sensitive), alias))
    if not SUPPORTED.issubset(seen_ids):
        raise ValueError('Incomplete supported title magic words: ' + ','.join(sorted(SUPPORTED - seen_ids)))
    header = ('# wikidict-magic-words-' + ('v2' if profile == PARSER_PROFILE else 'v1')
              + '\n# wiki\t' + wiki + '\n# dump-date\t' + date
              + '\n# content-language\t' + content_language + '\n')
    body = ''.join(name + '\t' + str(flag) + '\t' + alias + '\n' for name, flag, alias in sorted(rows))
    output = (header + body).encode('utf-8')
    if len(output) > MAX_TSV_BYTES:
        raise ValueError('Title magic-word table exceeds the native registry limit')
    return output, len(rows)


def canonical_word_count(output):
    return len({line.split(b'\t', 1)[0] for line in output.splitlines()
                if line and not line.startswith(b'#')})


def capture_profile(manifest):
    if not isinstance(manifest, dict) or type(manifest.get('version')) is not int:
        raise ValueError('Invalid magic-word capture version')
    version = manifest['version']
    profile = manifest.get('profile', TITLE_PROFILE if version == 1 else None)
    if version == 1 and profile == TITLE_PROFILE:
        return profile, ARTIFACTS
    if version == 2 and profile == PARSER_PROFILE:
        return profile, DERIVED_ARTIFACTS
    raise ValueError('Invalid magic-word capture version/profile')


def read_regular(path, limit=MAX_RAW_BYTES):
    path = Path(path)
    if path.is_symlink() or not path.is_file() or path.stat().st_size > limit:
        raise ValueError('Missing, unsafe, or oversized capture artifact: ' + str(path))
    with path.open('rb') as stream:
        raw = stream.read(limit + 1)
    if len(raw) > limit:
        raise ValueError('Oversized capture artifact: ' + str(path))
    return raw


def namespace_input(raw, complete_raw, wiki, date):
    identity(wiki, date)
    complete = parse_json(complete_raw)
    if not isinstance(complete, dict) or complete.get('wiki') != wiki or complete.get('date') != date:
        raise ValueError('Namespace capture identity mismatch')
    if (not isinstance(complete.get('artifacts'), dict)
            or complete['artifacts'].get('namespace-siteinfo.raw.json') != digest(raw)):
        raise ValueError('Changed pinned namespace capture')
    data = parse_json(raw)
    if (not isinstance(data, dict) or not isinstance(data.get('query'), dict)
            or not isinstance(data['query'].get('general'), dict)):
        raise ValueError('Missing namespace siteinfo identity')
    general = data['query']['general']
    if general.get('wikiid') != wiki:
        raise ValueError('Namespace siteinfo edition mismatch')
    return language(general.get('lang'))


def timestamp(value):
    if not isinstance(value, str):
        raise ValueError('Missing retrieval timestamp')
    parsed = dt.datetime.fromisoformat(value)
    if parsed.utcoffset() != dt.timedelta(0):
        raise ValueError('Retrieval timestamp must use UTC')
    return parsed


def validate_snapshot(path, wiki=None, date=None):
    """Replay a complete capture offline; return its validated manifest."""
    path = Path(path)
    root = path.parent if path.name == 'magic-words.tsv' else path
    if root.is_symlink() or not root.is_dir():
        raise ValueError('Unsafe magic-word capture directory')
    manifest = parse_json(read_regular(root / 'magic-words.manifest.json'))
    _, artifacts = capture_profile(manifest)
    blobs = {name: read_regular(root / name) for name in artifacts}
    return validate_capture(manifest, blobs, wiki, date)


def validate_capture(manifest, blobs, wiki=None, date=None):
    """Validate either projection, including an embedded original v1 capture."""
    profile, artifacts = capture_profile(manifest)
    if (wiki is not None and manifest.get('wiki') != wiki
            or date is not None and manifest.get('date') != date):
        raise ValueError('Magic-word capture differs from requested edition/date')
    wiki, date = manifest.get('wiki'), manifest.get('date')
    identity(wiki, date)
    if (manifest.get('wiki') != wiki or manifest.get('date') != date
            or manifest.get('temporal_scope') != 'current-at-retrieval'):
        raise ValueError('Magic-word capture identity or temporal scope mismatch')
    if not isinstance(manifest.get('artifacts'), dict) or set(manifest['artifacts']) != artifacts:
        raise ValueError('Incomplete magic-word capture provenance')
    if set(blobs) != artifacts:
        raise ValueError('Incomplete magic-word capture artifacts')
    if any(digest(raw) != manifest['artifacts'][name] for name, raw in blobs.items()):
        raise ValueError('Changed magic-word capture artifact')
    content_language = namespace_input(blobs['namespace-siteinfo.raw.json'],
        blobs['namespace-capture.complete.json'], wiki, date)
    if manifest.get('content_language') != content_language:
        raise ValueError('Magic-word capture language differs from pinned namespace')
    if profile == PARSER_PROFILE:
        source_manifest = parse_json(blobs[SOURCE_MANIFEST])
        if capture_profile(source_manifest)[0] != TITLE_PROFILE or source_manifest['version'] != 1:
            raise ValueError('Derived magic words require an original v1 source capture')
        source_blobs = {name: blobs[name] for name in ARTIFACTS}
        source_blobs['magic-words.tsv'] = blobs[SOURCE_TSV]
        validate_capture(source_manifest, source_blobs, wiki, date)
        expected_source = dict(profile=TITLE_PROFILE,
            manifest_sha256=digest(blobs[SOURCE_MANIFEST]), output_sha256=digest(blobs[SOURCE_TSV]))
        if manifest.get('source_capture') != expected_source:
            raise ValueError('Derived magic-word source identity mismatch')
        if timestamp(manifest.get('derived_utc')) < timestamp(manifest.get('retrieved_utc')):
            raise ValueError('Derivation predates the source retrieval')
    output, rows = render_snapshot(parse_json(blobs['magic-words.raw.json']), wiki, date, content_language, profile)
    if output != blobs['magic-words.tsv']:
        raise ValueError('Magic-word output does not replay from its raw response')
    if (manifest.get('raw_sha256') != digest(blobs['magic-words.raw.json'])
            or manifest.get('output_sha256') != digest(output)
            or manifest.get('output_bytes') != len(output) or manifest.get('rows') != rows
            or type(manifest.get('canonical_words')) is not int
            or manifest['canonical_words'] != canonical_word_count(output)):
        raise ValueError('Magic-word output identity mismatch')
    request = parse_json(blobs['magic-words.request.json'])
    if not isinstance(request, dict):
        raise ValueError('Invalid magic-word request receipt')
    if request.get('source_url') != source_url(wiki) or manifest.get('source_url') != source_url(wiki):
        raise ValueError('Unexpected magic-word query')
    resolved = urllib.parse.urlsplit(request.get('response_url', ''))
    if (resolved.scheme != 'https' or not resolved.hostname or not resolved.hostname.endswith('.wiktionary.org')
            or resolved.path != '/w/api.php' or resolved.username or resolved.password or resolved.port):
        raise ValueError('Unexpected magic-word response origin')
    if (request.get('status') != 200 or request.get('raw_sha256') != manifest['raw_sha256']
            or request.get('raw_bytes') != len(blobs['magic-words.raw.json'])
            or request.get('retrieved_utc') != manifest.get('retrieved_utc')
            or timestamp(request.get('started_utc')) > timestamp(request.get('retrieved_utc'))):
        raise ValueError('Invalid magic-word response receipt')
    if not re.fullmatch(r'[0-9a-f]{64}', manifest.get('generator_sha256', '')):
        raise ValueError('Missing capture generator identity')
    return manifest


def selected_snapshot_root(capture_root):
    """Prefer the expanded projection; an incomplete new capture must not fall back."""
    root = Path(capture_root)
    derived = root / DERIVED_DIRECTORY
    if derived.exists() or derived.is_symlink():
        manifest = validate_snapshot(derived)
        if manifest['version'] != 2 or manifest.get('profile') != PARSER_PROFILE:
            raise ValueError('Expanded capture directory requires the parser profile')
        return derived
    return root / 'magic-words'


def write_capture(output, artifacts, manifest):
    output.mkdir(parents=True, exist_ok=False)
    # The manifest is published last; partial directories are never reusable.
    for name, body in [*artifacts.items(), ('magic-words.manifest.json', document(manifest))]:
        with (output / name).open('xb') as stream:
            stream.write(body)
            stream.flush()
            os.fsync(stream.fileno())
        (output / name).chmod(0o444)


def derive_snapshot(source, output, wiki=None, date=None):
    """Derive an immutable parser profile from saved raw bytes, without networking."""
    source = Path(source)
    source = source.parent if source.name == 'magic-words.tsv' else source
    output = Path(output)
    original = validate_snapshot(source, wiki, date)
    if original['version'] != 1:
        raise ValueError('Derivation requires an original v1 source capture')
    wiki, date = original['wiki'], original['date']
    blobs = {name: read_regular(source / name) for name in ARTIFACTS}
    source_manifest_raw = read_regular(source / 'magic-words.manifest.json')
    if parse_json(source_manifest_raw) != original:
        raise ValueError('Source capture changed during derivation')
    validate_capture(original, blobs, wiki, date)
    source_identity = dict(profile=TITLE_PROFILE, manifest_sha256=digest(source_manifest_raw),
                           output_sha256=digest(blobs['magic-words.tsv']))
    if output.exists() or output.is_symlink():
        existing = validate_snapshot(output, wiki, date)
        if existing.get('profile') != PARSER_PROFILE or existing.get('source_capture') != source_identity:
            raise ValueError('Existing derivation uses a different source capture')
        return existing, False
    tsv, rows = render_snapshot(parse_json(blobs['magic-words.raw.json']), wiki, date,
                                original['content_language'], PARSER_PROFILE)
    artifacts = {**blobs, SOURCE_MANIFEST: source_manifest_raw,
                 SOURCE_TSV: blobs['magic-words.tsv'], 'magic-words.tsv': tsv}
    manifest = dict(version=2, profile=PARSER_PROFILE, wiki=wiki, date=date,
        content_language=original['content_language'], temporal_scope=original['temporal_scope'],
        retrieved_utc=original['retrieved_utc'], source_url=original['source_url'],
        raw_sha256=original['raw_sha256'], output_sha256=digest(tsv), output_bytes=len(tsv),
        rows=rows, canonical_words=canonical_word_count(tsv), generator_sha256=PRODUCER_SHA256,
        derived_utc=dt.datetime.now(dt.timezone.utc).isoformat(), source_capture=source_identity,
        artifacts={name: digest(body) for name, body in artifacts.items()})
    validate_capture(manifest, artifacts, wiki, date)
    if digest(Path(__file__).read_bytes()) != PRODUCER_SHA256:
        raise ValueError('Derivation generator changed during execution')
    if (read_regular(source / 'magic-words.manifest.json') != source_manifest_raw
            or any(read_regular(source / name) != raw for name, raw in blobs.items())):
        raise ValueError('Source capture changed during derivation')
    write_capture(output, artifacts, manifest)
    return validate_snapshot(output, wiki, date), True


def fetch_response(url):
    """Bounded, sequential API request with finite transient-error retries."""
    for attempt in range(4):
        started = dt.datetime.now(dt.timezone.utc).isoformat()
        try:
            req = urllib.request.Request(url, headers={'User-Agent': AGENT, 'Accept': 'application/json'})
            with urllib.request.urlopen(req, timeout=30) as response:
                raw = response.read(MAX_RAW_BYTES + 1)
                if len(raw) > MAX_RAW_BYTES:
                    raise ValueError('Oversized siteinfo response')
                receipt = dict(source_url=url, response_url=response.geturl(), status=response.status,
                    started_utc=started, retrieved_utc=dt.datetime.now(dt.timezone.utc).isoformat(),
                    raw_sha256=digest(raw), raw_bytes=len(raw))
            data = parse_json(raw)
            if isinstance(data, dict) and isinstance(data.get('error'), dict) and data['error'].get('code') == 'maxlag':
                raise TimeoutError('MediaWiki maxlag')
            return raw, receipt
        except (OSError, urllib.error.URLError) as error:
            if isinstance(error, urllib.error.HTTPError) and error.code not in (429, 500, 502, 503, 504):
                raise
            if attempt == 3:
                raise
            print(json.dumps({'phase': 'api_retry', 'attempt': attempt + 1, 'error': str(error)}), flush=True)
            time.sleep(min(2 ** (attempt + 1), 15))
    raise AssertionError('Unreachable request loop')


def capture_snapshot(capture_root, wiki, date, output=None, fetcher=None):
    """Publish a new immutable capture, or verify an existing identical one."""
    identity(wiki, date)
    capture_root = Path(capture_root)
    output = Path(output) if output is not None else capture_root / 'magic-words'
    pinned_raw = read_regular(capture_root / 'namespace-siteinfo.raw.json')
    pinned_complete = read_regular(capture_root / 'capture.complete.json')
    content_language = namespace_input(pinned_raw, pinned_complete, wiki, date)
    if output.exists() or output.is_symlink():
        old = validate_snapshot(output, wiki, date)
        if (old['artifacts']['namespace-siteinfo.raw.json'] != digest(pinned_raw)
                or old['artifacts']['namespace-capture.complete.json'] != digest(pinned_complete)):
            raise ValueError('Existing magic-word capture uses different namespace input')
        return old, False
    if digest(Path(__file__).read_bytes()) != PRODUCER_SHA256:
        raise ValueError('Capture generator changed during execution')
    raw, request = (fetcher or fetch_response)(source_url(wiki))
    if len(raw) > MAX_RAW_BYTES:
        raise ValueError('Oversized siteinfo response')
    tsv, rows = render_snapshot(parse_json(raw), wiki, date, content_language)
    artifacts = {'magic-words.raw.json': raw, 'magic-words.tsv': tsv,
        'magic-words.request.json': document(request), 'namespace-siteinfo.raw.json': pinned_raw,
        'namespace-capture.complete.json': pinned_complete}
    manifest = dict(version=1, wiki=wiki, date=date, content_language=content_language,
        temporal_scope='current-at-retrieval', retrieved_utc=request['retrieved_utc'],
        source_url=source_url(wiki), raw_sha256=digest(raw), output_sha256=digest(tsv),
        output_bytes=len(tsv), rows=rows, canonical_words=len(SUPPORTED),
        generator_sha256=PRODUCER_SHA256,
        artifacts={name: digest(body) for name, body in artifacts.items()})
    if (digest(Path(__file__).read_bytes()) != PRODUCER_SHA256
            or read_regular(capture_root / 'namespace-siteinfo.raw.json') != pinned_raw
            or read_regular(capture_root / 'capture.complete.json') != pinned_complete):
        raise ValueError('Capture producer or pinned namespace input changed')
    write_capture(output, artifacts, manifest)
    return validate_snapshot(output, wiki, date), True


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    selection = parser.add_mutually_exclusive_group(required=True)
    selection.add_argument('--capture-root', type=Path)
    selection.add_argument('--manifest', type=Path)
    parser.add_argument('--wiki')
    parser.add_argument('--date')
    parser.add_argument('--output', type=Path)
    parser.add_argument('--project', type=Path, default=Path('.'))
    parser.add_argument('--wikis', nargs='+')
    parser.add_argument('--verify', action='store_true')
    parser.add_argument('--derive-existing', action='store_true',
        help='Derive the expanded parser profile offline from each existing title capture')
    args = parser.parse_args()
    selected = []
    if args.capture_root:
        if not args.wiki or not args.date or args.wikis:
            parser.error('--capture-root requires --wiki and --date, without --wikis')
        selected.append((args.wiki, args.date, args.capture_root, args.output))
    else:
        if args.wiki or args.date or args.output:
            parser.error('--manifest uses --wikis and its declared capture roots')
        manifest = parse_json(read_regular(args.manifest, 32 * 1024 * 1024))
        roots = manifest.get('auxiliary_capture_roots')
        if not isinstance(roots, dict) or not roots:
            raise ValueError('Missing auxiliary capture roots')
        requested = set(args.wikis) if args.wikis else set(roots)
        if requested - set(roots):
            raise ValueError('Unknown requested editions')
        for wiki in sorted(requested):
            path = Path(roots[wiki])
            if path.is_absolute() or '..' in path.parts:
                raise ValueError('Unsafe auxiliary capture root')
            root = args.project / path
            record = parse_json(read_regular(root / 'capture.complete.json'))
            selected.append((wiki, record.get('date'), root, None))
    failures = []
    for wiki, date, root, output in selected:
        started = time.monotonic()
        try:
            if args.verify:
                result = validate_snapshot(output or root / (DERIVED_DIRECTORY if args.derive_existing else 'magic-words'), wiki, date)
                if args.derive_existing and (result['version'] != 2 or result.get('profile') != PARSER_PROFILE):
                    raise ValueError('Expanded capture verification requires the parser profile')
                created = False
            elif args.derive_existing:
                result, created = derive_snapshot(root / 'magic-words', output or root / DERIVED_DIRECTORY, wiki, date)
            else:
                result, created = capture_snapshot(root, wiki, date, output)
            print(json.dumps(dict(wiki=wiki, date=date, status='verified', created=created,
                rows=result['rows'], seconds=round(time.monotonic() - started, 3)), sort_keys=True), flush=True)
        except (OSError, ValueError, KeyError, TypeError) as error:
            failures.append(wiki)
            print(json.dumps(dict(wiki=wiki, date=date, status='failed', error=str(error))), flush=True)
    print(json.dumps(dict(requested=len(selected), verified=len(selected) - len(failures), failures=failures)), flush=True)
    return int(bool(failures))


if __name__ == '__main__':
    raise SystemExit(main())
