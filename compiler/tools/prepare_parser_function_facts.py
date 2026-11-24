#!/usr/bin/env python3
"""Project retained, authenticated API facts for build-time filepath and PAGESIZE."""
import argparse
from datetime import datetime
from email.utils import format_datetime, parsedate_to_datetime
import hashlib
import json
import math
from pathlib import Path
import re
import urllib.parse

import prepare_file_metadata as evidence

SCHEMA = 'wikidict.parser-function-facts.v1'
CAPTURE_SCHEMA = 'wikidict.parser-function-facts-capture.v1'
OUTPUT = 'parser-function-facts.json'
MANIFEST = 'parser-function-facts.manifest.json'
COMPLETE = 'parser-function-facts.complete.json'
DIRECTORY = 'parser-function-facts'
NAMESPACE = 'parser-function-facts.namespace-registry.tsv'
SITE = 'parser-function-facts.site-info.json'
MAX_RESPONSE = 2 * 1024 * 1024
MAX_MANIFEST = 8 * 1024 * 1024
MAX_RECORDS = 65536
MAX_OBSERVATIONS = 1024
CORE = 'f45897451256aa3799aecc5d7ee320ade22beaec'
HU_OBSERVED_CORE = '87f311882d8c84ec21e288d0bde8aa289df8dc56'
HU_CONFIGURATION = dict(wiki='huwiktionary', date='20261001', content_language='hu',
    namespace_sha256='68c76ee3cf6c32dcbccccd6afa6be303d4066e78b08eb9fd96fc06bb82c2d3cf',
    site_info_sha256='60661fb85446842ab46e689307488a4ea9c9b9246810da5eb59dbe8415c78ce8')
LEGACY_PRODUCER = 'ef49e2fef666eafcaa45526d8250e58ce06267f89b3cbf6e42feaed4751ca263'
HU_INTEGERS = (0, 9, 999, 1000, 9999, 10000, 23220, 1000000, 2147483648, 9007199254740991)
HU_BEGIN = 'WIKIDICT_FORMATNUM_HU_V1_BEGIN'
HU_END = 'WIKIDICT_FORMATNUM_HU_V1_END'
HU_FORMAT_PROFILE = 'mw-87f-hu-latn-integer-v1'
COMMON = dict(action='query', format='json', formatversion='2', curtimestamp='1',
              meta='siteinfo', siprop='general|extensions', maxlag='5')
FILE_QUERY = dict(COMMON, prop='imageinfo', iiprop='url|sha1|timestamp|canonicaltitle|mime|size',
                  iilimit='1', redirects='1')
PAGE_QUERY = dict(COMMON, prop='revisions', rvprop='ids|size|timestamp')
VALUE_QUERY = dict(action='expandtemplates', format='json', formatversion='2',
                   curtimestamp='1', maxlag='5', prop='wikitext')
BEGIN = 'WIKIDICT_FILEPATH_V1_BEGIN'
END = 'WIKIDICT_FILEPATH_V1_END'


def digest(raw):
    return hashlib.sha256(raw).hexdigest()


def encoded(value):
    return (json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(',', ':'), allow_nan=False) + '\n').encode()


def decode(raw):
    def floating(value):
        number = float(value)
        if not math.isfinite(number):
            raise ValueError('Nonfinite parser-function fact')
        return number
    def constant(value):
        raise ValueError('Nonfinite parser-function fact: ' + value)
    return json.loads(raw, object_pairs_hook=evidence.unique_object,
                      parse_float=floating, parse_constant=constant)


def text(value, limit=4096, empty=False):
    if (not isinstance(value, str) or (not empty and not value)
            or len(value.encode('utf-8')) > limit
            or any(ord(c) < 32 or ord(c) == 127 for c in value)):
        raise ValueError('Invalid parser-function text')
    return value


def integer(value, positive=False):
    if type(value) is not int or not (1 if positive else 0) <= value < 2**63:
        raise ValueError('Invalid parser-function integer')
    return value


def configuration(namespace_raw, site_raw, wiki, date):
    if not isinstance(wiki, str) or not re.fullmatch(r'[a-z][a-z0-9_-]*wiktionary', wiki):
        raise ValueError('Invalid parser-function wiki')
    if not isinstance(date, str) or not re.fullmatch(r'\d{8}', date):
        raise ValueError('Invalid parser-function date')
    evidence.Registry(namespace_raw, wiki, date)
    site = decode(site_raw)
    general = site.get('query', {}).get('general', {}) if isinstance(site, dict) else {}
    if general.get('wikiid') != wiki:
        raise ValueError('Site-info belongs to a different edition')
    language = text(general.get('lang'), 128)
    languages = [line.split('\t', 1)[1] for line in namespace_raw.decode('utf-8').splitlines()
                 if line.startswith('# content-language\t')]
    if languages != [language]:
        raise ValueError('Site-info content language differs from namespace registry')
    return dict(wiki=wiki, date=date, content_language=language,
                namespace_sha256=digest(namespace_raw), site_info_sha256=digest(site_raw))


def observed(request_raw, receipt_raw, response_raw, response_name, cfg):
    request, receipt, data = decode(request_raw), decode(receipt_raw), decode(response_raw)
    if (not isinstance(request, dict) or request.get('schema') != 'wikidict.existing-metadata-transport-request.v1'
            or request.get('wiki') != cfg['wiki'] or request.get('date') != cfg['date']):
        raise ValueError('Retained parser-function request identity differs')
    query = request.get('query')
    if not isinstance(query, dict) or any(not isinstance(k, str) or not isinstance(v, str) for k, v in query.items()):
        raise ValueError('Invalid parser-function query')
    builtin = query.get('action') == 'expandtemplates'
    kind = 'filepath-values' if builtin else query.get('prop')
    authority = request.get('core_authority')
    if builtin and not isinstance(authority, dict):
        raise ValueError('Missing separate builtin source authority')
    core = authority.get('revision') if builtin else request.get('expected_core')
    if core != CORE and not (core == HU_OBSERVED_CORE and cfg == HU_CONFIGURATION):
        raise ValueError('Unreviewed parser-function source or selected site')
    variable = 'titles' if kind == 'imageinfo' else 'revids'
    expected = FILE_QUERY if kind == 'imageinfo' else PAGE_QUERY if kind == 'revisions' else None
    if builtin:
        if (set(query) != set(VALUE_QUERY) | {'title', 'text'}
                or any(query[k] != v for k, v in VALUE_QUERY.items())
                or authority.get('kind') != 'separate-observation-and-primary-source'
                or authority.get('revision') != core
                or authority.get('same_response_core_observed') is not False):
            raise ValueError('Unsupported builtin-only function observation')
        text(query['title'])
        frame = request.get('framing', {})
        if not isinstance(frame, dict):
            raise ValueError('Missing builtin request framing')
        if core == HU_OBSERVED_CORE and frame.get('begin') == HU_BEGIN:
            kind = 'number-format'
            if (frame != dict(begin=HU_BEGIN, end=HU_END, ordered_integers=list(HU_INTEGERS),
                    field_separator='\t', separator='\n', trailing_newline=False) or
                    query['text'] != '\n'.join([HU_BEGIN, *(f'{n}\t{{{{FORMATNUM:{n}}}}}' for n in HU_INTEGERS), HU_END])):
                raise ValueError('Hungarian integer formatting request differs')
        elif (frame.get('begin') != BEGIN or frame.get('end') != END
                or frame.get('separator') != '\n' or frame.get('field_separator') != '\t'
                or frame.get('ordered_files') != filepath_names(query) or frame.get('trailing_newline') is not False
                or type(frame.get('exact_lines')) is not int or frame['exact_lines'] != len(frame['ordered_files']) + 2):
            raise ValueError('Builtin request framing differs')
    elif (expected is None or set(query) != set(expected) | {variable}
          or any(query[k] != v for k, v in expected.items())):
        raise ValueError('Unsupported parser-function query profile')
    if (request.get('url') != evidence.wiktionary_api(cfg['wiki']) + '?' + urllib.parse.urlencode(query)
            or len(request['url'].encode()) > 7168):
        raise ValueError('Retained parser-function URL differs')
    if (not isinstance(receipt, dict) or receipt.get('accepted') is not True
            or type(receipt.get('status')) is not int or receipt['status'] != 200
            or receipt.get('url') != request['url']
            or type(receipt.get('request_count')) is not int or receipt['request_count'] != 1
            or (receipt.get('core_revision') is not None if builtin else receipt.get('core_revision') != core)
            or receipt.get('response') != response_name
            or type(receipt.get('response_bytes')) is not int
            or receipt['response_bytes'] != len(response_raw)
            or receipt.get('response_sha256') != digest(response_raw)
            or not 0 < len(response_raw) <= MAX_RESPONSE):
        raise ValueError('Retained parser-function response receipt differs')
    if not isinstance(data, dict) or any(k in data for k in ('error', 'errors', 'warnings', 'continue')):
        raise ValueError('Parser-function response is incomplete or refused')
    if core == HU_OBSERVED_CORE:
        headers = receipt.get('headers')
        if not isinstance(headers, dict) or not isinstance(headers.get('date'), str):
            raise ValueError('Missing current HTTP date')
        http_date = headers['date']
        try:
            stamp = parsedate_to_datetime(http_date)
            served = datetime.strptime(data['curtimestamp'], '%Y-%m-%dT%H:%M:%SZ').replace(tzinfo=stamp.tzinfo)
            observed_at = datetime.fromisoformat(receipt['observed_utc'])
            if (format_datetime(stamp, usegmt=True) != http_date or
                    observed_at.utcoffset() != stamp.utcoffset() or
                    abs((served - stamp).total_seconds()) > 5 or abs((observed_at - stamp).total_seconds()) > 60 or
                    receipt.get('request_sha256') != digest(request_raw)):
                raise ValueError('Current parser-function receipt differs from the original HTTP date or request')
        except (KeyError, TypeError, OverflowError) as error:
            raise ValueError('Missing current parser-function transport facts') from error
    if builtin:
        if (set(data) - {'expandtemplates', 'curtimestamp'} or not isinstance(data.get('expandtemplates'), dict)
                or set(data['expandtemplates']) != {'wikitext'}
                or receipt.get('core_authority') != request['core_authority']
                or receipt.get('same_response_core_observed') is not False):
            raise ValueError('Unexpected builtin function response')
        return kind, query, data
    if not isinstance(data.get('query'), dict) or (core == HU_OBSERVED_CORE and data.get('batchcomplete') is not True):
        raise ValueError('Missing API query facts')
    general = data['query'].get('general', {})
    if (not isinstance(general, dict) or general.get('wikiid') != cfg['wiki']
            or general.get('lang') != cfg['content_language'] or general.get('git-hash') != core
            or (core == HU_OBSERVED_CORE and general.get('generator') != 'MediaWiki 1.48.0-wmf.5')
            or not isinstance(data['query'].get('extensions'), list)):
        raise ValueError('Parser-function response source identity differs')
    if any(data['query'].get(k) for k in ('interwiki', 'converted', 'badrevids')):
        raise ValueError('Unsupported parser-function response target')
    return kind, query, data


def filepath_names(query):
    lines = query['text'].split('\n')
    if not 3 <= len(lines) <= 52 or lines[0] != BEGIN or lines[-1] != END:
        raise ValueError('Builtin filepath request frame differs')
    names = []
    for index, line in enumerate(lines[1:-1]):
        prefix = str(index) + '\t{{filepath:'
        if not line.startswith(prefix) or not line.endswith('}}'):
            raise ValueError('Only ordered builtin filepath calls are supported')
        name = line[len(prefix):-2]
        text(name)
        if any(c in name for c in '{}[]|'):
            raise ValueError('Only literal no-option filepath calls are supported')
        names.append(name)
    return names


def function_rows(query, data, registry):
    names = filepath_names(query)
    output = data['expandtemplates']['wikitext']
    if not isinstance(output, str):
        raise ValueError('Missing observed function values')
    values = output.split('\n')
    if len(values) != len(names) + 2 or values[0] != BEGIN or values[-1] != END:
        raise ValueError('Function observation frame differs')
    rows = []
    for index, (filename, value) in enumerate(zip(names, values[1:-1])):
        prefix = str(index) + '\t'
        if not value.startswith(prefix):
            raise ValueError('Function observation key differs')
        # CoreParserFunctions passes a literal filename to makeTitleSafe(NS_FILE).
        # An apparent namespace prefix inside that filename remains literal.
        key = registry.file_title(registry.specs[6]['name'] + ':' + filename)
        url = value[len(prefix):]
        text(url, 8192, empty=True)
        if url:
            parsed = urllib.parse.urlsplit(url)
            if (parsed.scheme not in ('', 'http', 'https') or not parsed.netloc
                    or parsed.username is not None or parsed.password is not None
                    or parsed.fragment or '\\' in url or any(c in url for c in '{}[]')):
                raise ValueError('Invalid observed filepath URL')
        rows.append((key, url))
    return rows


def file_rows(query, data, registry):
    titles = query['titles'].split('|')
    if not 1 <= len(titles) <= 50 or len(set(titles)) != len(titles):
        raise ValueError('Invalid requested file inventory')
    keys = [registry.file_title(name) for name in titles]
    if len(set(keys)) != len(keys):
        raise ValueError('Equivalent requested file duplicates')
    facts = evidence.classify_response(data, titles, registry)
    by_title = {p['title']: p for p in data['query']['pages']}
    result = []
    for key in keys:
        fact = facts[key]
        page = by_title[fact['response_title']]
        if not fact['exists']:
            if page.get('missing') is not True or page.get('imagerepository') != '' or 'imageinfo' in page:
                raise ValueError('File absence is not explicit')
            result.append(dict(title=key, size_argument='', canonical_title='', exists=False, url='', sha1=''))
            continue
        item = page['imageinfo'][0]
        canonical = registry.file_title(fact['canonicaltitle'])
        if canonical != registry.file_title(page['title']):
            raise ValueError('File canonical identity differs')
        url = text(item.get('url'), 8192)
        parsed = urllib.parse.urlsplit(url)
        if (parsed.scheme not in ('http', 'https') or not parsed.netloc or parsed.username is not None
                or parsed.password is not None or parsed.fragment or '\\' in url):
            raise ValueError('Invalid authoritative full file URL')
        # This URL is identity evidence only. imageinfo adds provenance and can
        # change the scheme; the function value is joined independently below.
        result.append(dict(title=key, size_argument='', canonical_title=canonical,
                           exists=True, url=url, sha1=fact['file_sha1']))
    return result


def page_rows(query, data):
    ids = query['revids'].split('|')
    if (not 1 <= len(ids) <= 50 or len(set(ids)) != len(ids)
            or any(re.fullmatch(r'[1-9][0-9]*', value) is None for value in ids)):
        raise ValueError('Invalid requested revision inventory')
    desired = {integer(int(value), positive=True) for value in ids}
    pages = data['query'].get('pages')
    if (not isinstance(pages, list) or not pages or len(pages) > len(desired)
            or data['query'].get('normalized') or data['query'].get('redirects')):
        raise ValueError('Invalid revision page inventory')
    seen, result = set(), []
    for page in pages:
        if (not isinstance(page, dict) or any(k in page for k in ('missing', 'invalid', 'interwiki', 'suppressed'))
                or type(page.get('ns')) is not int or not -(2**31) <= page['ns'] < 2**31):
            raise ValueError('Revision page is absent or inaccessible')
        title = text(page.get('title'))
        page_id = integer(page.get('pageid'), positive=True)
        revisions = page.get('revisions')
        if not isinstance(revisions, list) or not revisions:
            raise ValueError('Revision size was not observed')
        for revision in revisions:
            if (not isinstance(revision, dict)
                    or any(k in revision for k in ('texthidden', 'sha1hidden', 'suppressed', 'sizehidden'))):
                raise ValueError('Hidden revision size')
            revid = integer(revision.get('revid'), positive=True)
            if revid not in desired or revid in seen:
                raise ValueError('Unrequested or duplicate revision')
            seen.add(revid)
            size = integer(revision.get('size'))
            timestamp = text(revision.get('timestamp'), 128)
            if not re.fullmatch(r'\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ', timestamp):
                raise ValueError('Invalid revision timestamp')
            datetime.fromisoformat(timestamp.replace('Z', '+00:00'))
            result.append(dict(title=title, namespace=page['ns'], page_id=page_id, revision_id=revid, size=size))
    if seen != desired:
        raise ValueError('Requested revision was omitted')
    return result


def project(namespace_raw, site_raw, observations, wiki, date):
    cfg = configuration(namespace_raw, site_raw, wiki, date)
    registry = evidence.Registry(namespace_raw, wiki, date)
    files, pages, function_values = {}, {}, {}
    canonical_files = {}
    epochs, current_times = set(), []
    format_title = None
    if not 1 <= len(observations) <= MAX_OBSERVATIONS:
        raise ValueError('Invalid parser-function observation inventory')
    for request_raw, receipt_raw, response_raw, response_name in observations:
        kind, query, data = observed(request_raw, receipt_raw, response_raw, response_name, cfg)
        request = decode(request_raw)
        epoch = request.get('expected_core') if kind in ('imageinfo', 'revisions') else request['core_authority']['revision']
        epochs.add(epoch)
        if epoch == HU_OBSERVED_CORE:
            current_times.append(datetime.fromisoformat(data['curtimestamp']))
        if kind == 'imageinfo':
            for row in file_rows(query, data, registry):
                key = (row['title'], row['size_argument'])
                if key in files:
                    raise ValueError('Duplicate filepath fact')
                files[key] = row
                if row['exists']:
                    identity = (row['url'], row['sha1'])
                    previous = canonical_files.setdefault((row['canonical_title'], row['size_argument']), identity)
                    if previous != identity:
                        raise ValueError('Conflicting canonical file URL identity')
        elif kind == 'revisions':
            for row in page_rows(query, data):
                if row['title'] in pages:
                    raise ValueError('Duplicate or ambiguous page-size fact')
                pages[row['title']] = row
        elif kind == 'number-format':
            expected = '\n'.join([HU_BEGIN, *(f'{n}\t' + format(n, ',').replace(',', '\u00a0') for n in HU_INTEGERS), HU_END])
            if format_title is not None or data['expandtemplates']['wikitext'] != expected:
                raise ValueError('Formatting results differ from the source-bound HU integer profile')
            format_title = query['title']
        else:
            for key, value in function_rows(query, data, registry):
                if key in function_values:
                    raise ValueError('Duplicate filepath value observation')
                function_values[key] = value
        if len(files) + len(pages) > MAX_RECORDS:
            raise ValueError('Parser-function fact inventory exceeds its typed reader bound')
    for row in files.values():
        expected = canonical_files.get((row['title'], row['size_argument']))
        if expected is not None and (not row['exists'] or (row['url'], row['sha1']) != expected):
            raise ValueError('Requested file conflicts with canonical identity')
    if not set(function_values) <= {row['title'] for row in files.values()}:
        raise ValueError('Function value has no observed file identity')
    for row in files.values():
        observed_url = function_values.get(row['title'])
        if row['exists']:
            if not observed_url:
                raise ValueError('Positive filepath requires its observed builtin value')
            api, builtin_url = urllib.parse.urlsplit(row['url']), urllib.parse.urlsplit(observed_url)
            if (api.netloc, api.path) != (builtin_url.netloc, builtin_url.path):
                raise ValueError('Function URL does not identify the observed file')
            row['url'] = observed_url
        elif observed_url not in (None, ''):
            raise ValueError('Function result conflicts with explicit file absence')
    result = dict(schema=SCHEMA, **cfg, files=sorted(files.values(), key=lambda x:(x['title'].encode(), x['size_argument'])),
                  pages=sorted(pages.values(), key=lambda x:x['title'].encode()), formats=[])
    if len(epochs) != 1 or (current_times and (max(current_times) - min(current_times)).total_seconds() > 900):
        raise ValueError('Parser-function observations cross source epochs or acquisition windows')
    if format_title is not None:
        if not pages or format_title not in pages or not any(row['exists'] for row in files.values()):
            raise ValueError('Hungarian format witness lacks its separately observed page and file sources')
        result.update(number_format_profile=HU_FORMAT_PROFILE, number_format_witness_title=format_title)
    if len(encoded(result)) > MAX_MANIFEST:
        raise ValueError('Parser-function facts exceed native byte bound')
    return result


def producer_paths():
    return {'parser-function-facts.producer.py': Path(__file__),
            'parser-function-facts.evidence.py': Path(evidence.__file__)}


def safe_name(value):
    if not isinstance(value, str) or Path(value).name != value or value in ('', '.', '..') or '\\' in value:
        raise ValueError('Unsafe parser-function artifact name')
    return value


def artifacts(root):
    result = {}
    for path in root.iterdir():
        if path.name in (MANIFEST, COMPLETE):
            continue
        safe_name(path.name)
        raw = evidence.small(path, MAX_MANIFEST)
        if len(result) >= 3 * MAX_OBSERVATIONS + 5:
            raise ValueError('Excessive parser-function artifact inventory')
        result[path.name] = dict(bytes=len(raw), sha256=digest(raw))
    return result


def verify(root, complete=True):
    root = Path(root)
    if root.is_symlink() or not root.is_dir():
        raise ValueError('Unsafe parser-function capture root')
    manifest_raw = evidence.small(root / MANIFEST, MAX_MANIFEST)
    manifest = decode(manifest_raw)
    if (not isinstance(manifest, dict) or manifest.get('schema') != CAPTURE_SCHEMA
            or manifest.get('function_observation_core_binding_proven') is not False
            or manifest.get('cross_request_atomicity') is not False
            or manifest.get('full_edition_coverage') is not False
            or type(manifest.get('network_requests')) is not int or manifest['network_requests'] != 0
            or manifest.get('artifacts') != artifacts(root)):
        raise ValueError('Parser-function artifact inventory differs')
    historical_producer = False
    for name, path in producer_paths().items():
        recorded = evidence.small(root / name)
        if recorded != evidence.small(path):
            if name != 'parser-function-facts.producer.py' or digest(recorded) != LEGACY_PRODUCER:
                raise ValueError('Parser-function projection producer changed')
            historical_producer = True
    records = manifest.get('observations')
    if not isinstance(records, list) or not 1 <= len(records) <= MAX_OBSERVATIONS:
        raise ValueError('Invalid parser-function capture plan')
    observations, expected = [], {NAMESPACE, SITE, OUTPUT, *producer_paths()}
    for index, row in enumerate(records, 1):
        names = {kind:f'observation-{index:04d}.{kind}.json' for kind in ('request', 'receipt', 'response')}
        if not isinstance(row, dict) or set(row) != {*names, 'response_name'} or any(row[k] != v for k, v in names.items()):
            raise ValueError('Parser-function observation locator differs')
        safe_name(row['response_name'])
        expected.update(names.values())
        observations.append(tuple(evidence.small(root / names[k], MAX_RESPONSE) for k in ('request', 'receipt', 'response')) + (row['response_name'],))
    if expected != set(manifest['artifacts']):
        raise ValueError('Unexpected parser-function evidence artifacts')
    if historical_producer:
        for request_raw, _, _, _ in observations:
            request = decode(request_raw)
            if not isinstance(request, dict) or not isinstance(request.get('query'), dict):
                raise ValueError('Invalid historical parser-function request')
            epoch = request.get('expected_core')
            if request['query'].get('action') == 'expandtemplates':
                authority = request.get('core_authority')
                epoch = authority.get('revision') if isinstance(authority, dict) else None
            if epoch != CORE:
                raise ValueError('Historical parser-function producer did not support this epoch')
    value = project(evidence.small(root / NAMESPACE), evidence.small(root / SITE), observations, manifest.get('wiki'), manifest.get('date'))
    raw = encoded(value)
    if (evidence.small(root / OUTPUT, MAX_MANIFEST) != raw or manifest.get('output') != OUTPUT
            or manifest.get('output_bytes') != len(raw) or manifest.get('output_sha256') != digest(raw)
            or manifest.get('namespace_registry_sha256') != value['namespace_sha256']
            or manifest.get('site_info_sha256') != value['site_info_sha256']
            or manifest.get('content_language') != value['content_language']):
        raise ValueError('Parser-function projection does not replay')
    if complete and decode(evidence.small(root / COMPLETE)) != dict(schema=CAPTURE_SCHEMA, manifest_sha256=digest(manifest_raw)):
        raise ValueError('Parser-function completion differs')
    return manifest


def derive(namespace_path, site_path, observations, root, wiki, date):
    """Import original request/receipt/response triples without any network path."""
    root = Path(root)
    paths = [Path(namespace_path), Path(site_path), *(Path(p) for triple in observations for p in triple)]
    observation_paths = [Path(p) for triple in observations for p in triple]
    if root.exists() or root.is_symlink() or any(root.resolve().is_relative_to(p.parent.resolve()) for p in observation_paths):
        raise ValueError('Projection must use a new directory outside retained evidence')
    before = {path:evidence.stamp(path) for path in paths}
    raw = [evidence.small(path, MAX_RESPONSE) for path in paths]
    triples = [(raw[2+i*3], raw[3+i*3], raw[4+i*3], Path(triple[2]).name) for i, triple in enumerate(observations)]
    value = project(raw[0], raw[1], triples, wiki, date)
    root.mkdir(parents=True, exist_ok=False)
    evidence.put(root / NAMESPACE, raw[0]); evidence.put(root / SITE, raw[1])
    for name, path in producer_paths().items():
        evidence.put(root / name, evidence.small(path))
    locators = []
    for index, triple in enumerate(triples, 1):
        names = {kind:f'observation-{index:04d}.{kind}.json' for kind in ('request', 'receipt', 'response')}
        for kind, data in zip(('request', 'receipt', 'response'), triple[:3]):
            evidence.put(root / names[kind], data)
        locators.append(dict(names, response_name=triple[3]))
    output_raw = encoded(value)
    evidence.put(root / OUTPUT, output_raw)
    if any(evidence.stamp(path) != stamp for path, stamp in before.items()):
        raise ValueError('Retained parser-function evidence changed')
    manifest = dict(schema=CAPTURE_SCHEMA, wiki=wiki, date=date, content_language=value['content_language'],
                    namespace_registry_sha256=value['namespace_sha256'], site_info_sha256=value['site_info_sha256'],
                    output=OUTPUT, output_bytes=len(output_raw), output_sha256=digest(output_raw),
                    observations=locators, artifacts=artifacts(root), temporal_scope='current-file-urls-and-requested-revision-sizes',
                    function_observation_core_binding_proven=False, cross_request_atomicity=False,
                    full_edition_coverage=False, network_requests=0)
    evidence.put(root / MANIFEST, encoded(manifest))
    verify(root, complete=False)
    evidence.put(root / COMPLETE, encoded(dict(schema=CAPTURE_SCHEMA, manifest_sha256=digest(encoded(manifest)))))
    return manifest


def validate_snapshot(path, wiki=None, date=None):
    path = Path(path)
    if path.name != OUTPUT:
        raise ValueError('Unexpected parser-function snapshot filename')
    manifest = verify(path.parent)
    if (wiki is not None and manifest['wiki'] != wiki) or (date is not None and manifest['date'] != date):
        raise ValueError('Parser-function snapshot edition/date differs')
    return manifest


def capture_artifacts(path, manifest=None):
    path = Path(path)
    actual = validate_snapshot(path)
    if manifest is not None and actual != manifest:
        raise ValueError('Parser-function manifest changed')
    result = {name:row['sha256'] for name, row in actual['artifacts'].items()}
    for name in (MANIFEST, COMPLETE):
        result[name] = digest(evidence.small(path.parent / name, MAX_MANIFEST))
    return result


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--wiki'); p.add_argument('--date'); p.add_argument('--namespace-registry', type=Path)
    p.add_argument('--site-info', type=Path); p.add_argument('--output', type=Path, required=True)
    for name in ('request', 'receipt', 'response'):
        p.add_argument('--' + name, type=Path, action='append', default=[])
    p.add_argument('--verify', action='store_true'); args = p.parse_args(argv)
    if args.verify:
        verify(args.output)
    elif (args.wiki and args.date and args.namespace_registry and args.site_info
          and len(args.request) == len(args.receipt) == len(args.response) > 0):
        derive(args.namespace_registry, args.site_info, list(zip(args.request, args.receipt, args.response)), args.output, args.wiki, args.date)
    else:
        p.error('Provide edition, namespace/site and matching request/receipt/response triples')


if __name__ == '__main__':
    main()
