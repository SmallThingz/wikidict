#!/usr/bin/env python3
"""Package and verify retained supplied-page Figure observations, offline only."""
import argparse
import hashlib
from html.parser import HTMLParser
import json
from pathlib import Path
import re
import stat
import urllib.parse

ROLE = 'figure-page-observations'
SNAPSHOT = ROLE + '.json'
MANIFEST = ROLE + '.manifest.json'
COMPLETE = ROLE + '.complete.json'
NAMESPACE = ROLE + '.namespace-registry.tsv'
DEFAULTS = ROLE + '.figure-siteinfo.raw.json'
MAX_INPUT = 16 * 1024 * 1024
MAX_MANIFEST = 1024 * 1024
MAX_RESPONSE = 2 * 1024 * 1024
MISSING_LINK_PROFILE = 'vector_new_link_v1'
MISSING_LINK_SITES = {'enwiktionary': 'en', 'viwiktionary': 'vi'}
MISSING_LINK_SHA256 = 'ecbc7435843a302ddba3652426b60f876a56950eeebdd1b9df0332aefeabd5fb'


def validate_missing_link_styles(value, defaults, wiki):
    # Independently observed EN and VI public module responses, not core guesses.
    language = MISSING_LINK_SITES.get(wiki)
    expected_url = f'https://{language}.wiktionary.org/w/load.php?lang={language}&modules=skins.vector.styles&only=styles&skin=vector-2022'
    # It supplies this module's semantics; indexed page CSS is still resolved
    # or refused by the compiler, and no absent gadget override is inferred.
    if (not isinstance(value, dict) or set(value) != {'profile', 'response', 'receipt', 'defaults'} or
            value['profile'] != MISSING_LINK_PROFILE or language is None or
            any(not isinstance(value[key], str) or len(value[key].encode()) > MAX_RESPONSE
                for key in ('response', 'receipt', 'defaults')) or
            value['defaults'].encode() != defaults):
        raise ValueError('Invalid missing-link stylesheet context')
    response = value['response'].encode()
    if len(response) != 90597 or digest(response) != MISSING_LINK_SHA256:
        raise ValueError('Unreviewed missing-link stylesheet bytes')
    receipt = decode(value['receipt'])
    if (set(receipt) != {'core', 'sources'} or receipt['core'] is not None or
            not isinstance(receipt['sources'], list) or len(receipt['sources']) != 1):
        raise ValueError('Invalid missing-link stylesheet receipt')
    source = receipt['sources'][0]
    descriptor(response, source)
    if (source.get('status') != 200 or source.get('url') != expected_url or
            source.get('final_url') != expected_url or
            source.get('source_path') != f'served:skins.vector.styles:{language}:vector-2022' or
            source.get('headers', {}).get('content-type', '').split(';')[0].strip() != 'text/css'):
        raise ValueError('Wrong missing-link stylesheet request or response')
    selected = decode(defaults)
    options = selected.get('query', {}).get('defaultoptions', {})
    if (selected.get('wiki') != wiki or options.get('skin') != 'vector-2022' or
            options.get('language') != language or options.get('vector-theme') != 'day'):
        raise ValueError('Wrong missing-link stylesheet default context')


def digest(raw):
    return hashlib.sha256(raw).hexdigest()


def encoded(value):
    return (json.dumps(value, ensure_ascii=False, sort_keys=True, indent=2) + '\n').encode()


def regular(path, limit):
    path = Path(path)
    if path.is_symlink() or not stat.S_ISREG(path.stat().st_mode):
        raise ValueError('Observation artifact is not a regular selection')
    before = path.stat()
    if before.st_size > limit:
        raise ValueError('Oversized observation artifact')
    raw = path.read_bytes()
    after = path.stat()
    fields = lambda s: (s.st_dev, s.st_ino, s.st_size, s.st_mtime_ns, s.st_ctime_ns)
    if fields(before) != fields(after) or len(raw) != before.st_size:
        raise ValueError('Observation artifact changed while reading')
    return raw


def decode(raw):
    def unique(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError('Duplicate observation JSON key')
            result[key] = value
        return result
    return json.loads(raw, object_pairs_hook=unique)


def descriptor(raw, record):
    if record.get('bytes') != len(raw) or record.get('sha256') != digest(raw):
        raise ValueError('Observation descriptor mismatch')


OUTER_CONTEXT_PROFILE = 'mediawiki-vector-2022-1.48.0-wmf.3'


def validate_outer_context(value, page, wiki, parsed):
    # This transports authenticated observations, not a computed class list or
    # permission to substitute the GET parser body for the supplied API body.
    if (not isinstance(value, dict) or set(value) != {'profile', 'receipt', 'response'} or
            value.get('profile') != OUTER_CONTEXT_PROFILE or
            any(not isinstance(value.get(key), str) or not 0 < len(value[key].encode()) <= MAX_RESPONSE
                for key in ('receipt', 'response'))):
        raise ValueError('Invalid observed outer context')
    response = value['response'].encode()
    receipt = decode(value['receipt'])
    if (not isinstance(receipt, dict) or set(receipt) != {'core', 'sources'} or receipt['core'] is not None or
            not isinstance(receipt['sources'], list) or len(receipt['sources']) != 1 or
            not isinstance(receipt['sources'][0], dict)):
        raise ValueError('Invalid outer-context receipt')
    source = receipt['sources'][0]
    descriptor(response, source)
    url = source.get('url')
    if not isinstance(url, str) or source.get('final_url') != url or source.get('status') != 200:
        raise ValueError('Wrong outer-context transport identity')
    selected = urllib.parse.urlsplit(url)
    origin = wiki[:-len('wiktionary')].replace('_', '-') + '.wiktionary.org'
    pairs = urllib.parse.parse_qsl(selected.query, keep_blank_values=True, strict_parsing=True,
                                  encoding='utf-8', errors='strict')
    expected = {'title': page['title'], 'oldid': str(page['revision_id']), 'useskin': 'vector-2022'}
    headers = source.get('headers')
    if (selected.scheme != 'https' or selected.netloc != origin or selected.path != '/w/index.php' or
            selected.fragment or len(pairs) != len(expected) or dict(pairs) != expected or
            re.search(r'%(?![0-9a-fA-F]{2})', selected.query) or
            source.get('source_path') != f"served:full-page:{page['title']}:oldid{page['revision_id']}:vector-2022" or
            not isinstance(headers, dict) or not isinstance(headers.get('content-type'), str) or
            headers['content-type'].split(';')[0].strip().lower() != 'text/html'):
        raise ValueError('Wrong selected outer-context page or skin')

    class Facts(HTMLParser):
        def __init__(self):
            super().__init__(convert_charrefs=True)
            self.tags = {'html': [], 'body': [], 'generator': [], 'root': []}

        def handle_starttag(self, tag, attrs):
            values = dict(attrs)
            key = (tag if tag in ('html', 'body') else
                   'generator' if tag == 'meta' and values.get('name') == 'generator' else
                   'root' if 'mw-parser-output' in (values.get('class') or '').split() else None)
            if key is not None:
                if len(values) != len(attrs) or any(value is None for value in values.values()):
                    raise ValueError('Ambiguous outer-context HTML attributes')
                self.tags[key].append((tag, values))

        def handle_startendtag(self, tag, attrs):
            self.handle_starttag(tag, attrs)

    def facts(text):
        if not isinstance(text, str) or not 0 < len(text.encode()) <= MAX_RESPONSE:
            raise ValueError('Missing outer-context HTML facts')
        result = Facts()
        result.feed(text)
        result.close()
        return result.tags

    full, head, body = facts(value['response']), facts(parsed.get('headhtml')), facts(parsed['text'])
    if (any(len(full[key]) != 1 for key in ('html', 'body', 'generator', 'root')) or
            any(len(head[key]) != 1 for key in ('html', 'body', 'generator')) or
            head['root'] or len(body['root']) != 1 or any(body[key] for key in ('html', 'body', 'generator'))):
        raise ValueError('Ambiguous outer-context HTML roots')
    if (full['generator'][0][1].get('content') != 'MediaWiki 1.48.0-wmf.3' or
            head['generator'][0][1].get('content') != 'MediaWiki 1.48.0-wmf.3' or
            full['body'] != head['body'] or
            'skin-vector-2022' not in full['body'][0][1].get('class', '').split()):
        raise ValueError('Changed outer-context generator or body')
    for key, counterpart in (('html', head), ('root', body)):
        actual_tag, actual = full[key][0]
        expected_tag, expected_attrs = counterpart[key][0]
        if (actual_tag != expected_tag or actual.get('lang') != expected_attrs.get('lang') or
                actual.get('dir') not in ('ltr', 'rtl') or actual.get('dir') != expected_attrs.get('dir') or
                not actual.get('lang') or (key == 'root' and actual.get('class') != expected_attrs.get('class'))):
            raise ValueError('Changed outer-context language, direction or parser root')
    # Native Book additionally proves the exact prefix, six middle wrappers and
    # allowed HTML class difference before deriving any ancestor absence fact.


def validate_document(raw, namespace, defaults):
    if not 0 < len(raw) <= MAX_INPUT:
        raise ValueError('Invalid observation document size')
    doc = decode(raw)
    paint_contract = doc.get('schema') == 'wikidict.figure-page-observations.v3'
    class_contract = doc.get('schema') == 'wikidict.figure-page-observations.v4'
    expected_fields = {'schema', 'wiki', 'date', 'namespace_sha256', 'defaults_sha256', 'pages'}
    if paint_contract or (class_contract and 'missing_link_styles' in doc):
        expected_fields.add('missing_link_styles')
    if (set(doc) != expected_fields or
            doc.get('schema') not in ('wikidict.figure-page-observations.v1', 'wikidict.figure-page-observations.v2', 'wikidict.figure-page-observations.v3', 'wikidict.figure-page-observations.v4') or
            not re.fullmatch('[a-z0-9_]+wiktionary', doc.get('wiki', '')) or
            not re.fullmatch('[0-9]{8}', doc.get('date', '')) or
            doc.get('namespace_sha256') != digest(namespace) or
            doc.get('defaults_sha256') != digest(defaults) or
            not isinstance(doc.get('pages'), list) or not 1 <= len(doc['pages']) <= 256):
        raise ValueError('Invalid observation document identity')
    if paint_contract or (class_contract and doc.get('missing_link_styles') is not None):
        validate_missing_link_styles(doc['missing_link_styles'], defaults, doc['wiki'])
    seen_ids, seen_titles = set(), set()
    for page in doc['pages']:
        page_fields = {'namespace_id', 'page_id', 'revision_id', 'title', 'raw_sha256', 'request', 'form_body', 'receipt', 'response', 'occurrences'}
        if class_contract and 'text_class_scope' in page:
            page_fields.add('text_class_scope')
        if 'outer_context' in page:
            page_fields.add('outer_context')
        text_scope = page.get('text_class_scope', False)
        if (set(page) != page_fields or type(text_scope) is not bool or
                type(page.get('namespace_id')) is not int or type(page.get('page_id')) is not int or
                type(page.get('revision_id')) is not int or page['page_id'] <= 0 or page['revision_id'] <= 0 or
                not isinstance(page.get('title'), str) or not page['title'] or
                not re.fullmatch('[0-9a-f]{64}', page.get('raw_sha256', ''))):
            raise ValueError('Invalid observed page identity')
        title = page['namespace_id'], page['title']
        if page['page_id'] in seen_ids or title in seen_titles:
            raise ValueError('Duplicate observed page')
        seen_ids.add(page['page_id']); seen_titles.add(title)
        request, receipt, response = (decode(page[name]) for name in ('request', 'receipt', 'response'))
        form = page['form_body'].encode('ascii')
        if not 1 <= len(form) <= 131072 or re.search(rb'%(?![0-9a-fA-F]{2})', form):
            raise ValueError('Invalid observation form body')
        if any(len(page[name].encode()) > MAX_RESPONSE for name in ('request', 'receipt', 'response')):
            raise ValueError('Oversized embedded observation')
        descriptor(form, request['form'])
        descriptor(page['request'].encode(), receipt['request'])
        descriptor(page['response'].encode(), receipt['response'])
        endpoint = 'https://' + doc['wiki'][:-len('wiktionary')].replace('_', '-') + '.wiktionary.org/w/api.php'
        if (request.get('schema') != 'wikidict.supplied-expanded-page-request.v1' or
                request.get('method') != 'POST' or request.get('url') != endpoint or
                request.get('content_type') != 'application/x-www-form-urlencoded; charset=utf-8' or
                request.get('page_id') != page['page_id'] or request.get('requested_revision_id') != page['revision_id'] or
                request.get('request_count') != 1 or request.get('controlled_single_token') is not False or
                request.get('full_supplied_expanded_page') is not True or request.get('historical_transclusions') is not False or
                request.get('parse_core_binding_proven') is not False or receipt.get('accepted') is not True or
                receipt.get('request_count') != 1 or receipt.get('status') != 200):
            raise ValueError('Unsupported supplied-page observation contract')
        expected = dict(action='parse', format='json', formatversion='2', title=page['title'],
                        revid=str(page['revision_id']), contentmodel='wikitext',
                        prop='text|wikitext|revid|displaytitle', parser='legacy', usearticle='1', maxlag='5')
        if text_scope:
            # Carry the explicit request only; Zig derives the bounded class
            # inventory from complete authenticated HTML after normal selection.
            expected.update(prop='text|wikitext|revid|displaytitle|headhtml|modules|jsconfigvars', useskin='vector-2022')
        if request.get('parameters_except_text') != expected:
            raise ValueError('Changed supplied-page parse parameters')
        pairs = urllib.parse.parse_qsl(form.decode('ascii'), keep_blank_values=True,
                                      strict_parsing=True, encoding='utf-8', errors='strict')
        params = dict(pairs)
        if len(pairs) != len(expected) + 1 or len(params) != len(expected) + 1 or {k: v for k, v in params.items() if k != 'text'} != expected:
            raise ValueError('Changed or duplicate form parameters')
        source = params['text'].encode()
        descriptor(source, request['text_source'])
        if 'error' in response or 'warnings' in response:
            raise ValueError('Parse error or warning retained; no fact may be selected')
        parsed = response.get('parse', {})
        if (parsed.get('title') != page['title'] or parsed.get('pageid') != page['page_id'] or
                parsed.get('wikitext') != params['text'] or not isinstance(parsed.get('text'), str) or
                not parsed['text'] or len(parsed['text'].encode()) > MAX_RESPONSE or
                parsed.get('revid') not in (None, page['revision_id'])):
            raise ValueError('Incomplete supplied-page echo/HTML/page identity')
        if page.get('outer_context') is not None:
            if not class_contract or text_scope is not True:
                raise ValueError('Outer context requires v4 text class scope')
            validate_outer_context(page['outer_context'], page, doc['wiki'], parsed)
        occurrences = page.get('occurrences')
        if not isinstance(occurrences, list) or not 1 <= len(occurrences) <= 64:
            raise ValueError('Invalid selected occurrence count')
        files, intervals = set(), []
        for item in occurrences:
            missing = item.get('missing_content') is True
            image_fields = {'start', 'end', 'canonical_file', 'file_sha1', 'file_timestamp', 'original_width', 'original_height', 'width', 'anchor_attributes'}
            missing_fields = {'start', 'end', 'canonical_file', 'missing_content'}
            if (type(item.get('start')) is not int or type(item.get('end')) is not int or
                    not 0 <= item['start'] < item['end'] <= len(source) or
                    not isinstance(item.get('canonical_file'), str) or not item['canonical_file']):
                raise ValueError('Invalid selected occurrence range or file')
            if missing:
                # This packages retained occurrence evidence only. The native
                # Book must separately validate Registry missing=true and HTML.
                if doc['schema'] not in ('wikidict.figure-page-observations.v2', 'wikidict.figure-page-observations.v3', 'wikidict.figure-page-observations.v4') or set(item) != missing_fields:
                    raise ValueError('Invalid missing occurrence contract')
            elif (set(item) not in (image_fields, image_fields | {'height'}) or
                    type(item.get('height', False)) is not bool or
                    (item.get('height', False) and (item.get('width') or item.get('anchor_attributes'))) or
                    type(item.get('width')) is not bool or type(item.get('anchor_attributes')) is not bool or
                    not (item['width'] or item['anchor_attributes'] or item.get('height', False)) or
                    not re.fullmatch('[0-9a-f]{40}', item.get('file_sha1', '')) or
                    not isinstance(item.get('file_timestamp'), str) or not item['file_timestamp'] or
                    type(item.get('original_width')) is not int or type(item.get('original_height')) is not int or
                    not 1 <= item['original_width'] <= 4294967295 or not 1 <= item['original_height'] <= 4294967295):
                raise ValueError('Invalid selected image occurrence identity')
            interval = item['start'], item['end']
            if item['canonical_file'] in files or any(a < interval[1] and interval[0] < b for a, b in intervals):
                raise ValueError('Duplicate or overlapping selected occurrence')
            files.add(item['canonical_file']); intervals.append(interval)
    return doc


def producer():
    return {'generator_sha256': digest(Path(__file__).read_bytes())}


def validate_snapshot(path, edition=None, date=None):
    path = Path(path)
    if path.name != SNAPSHOT or path.parent.is_symlink():
        raise ValueError('Invalid observation snapshot path')
    record = decode(regular(path.with_name(MANIFEST), MAX_MANIFEST))
    if (record.get('schema') != 'wikidict.figure-page-observation-capture.v1' or
            record.get('generator_sha256') != producer()['generator_sha256'] or
            (edition is not None and record.get('wiki') != edition) or
            (date is not None and record.get('date') != date)):
        raise ValueError('Observation capture identity mismatch')
    capture_artifacts(path, record)
    return record


def capture_artifacts(path, record):
    root = Path(path).parent
    if set(record.get('artifacts', {})) != {SNAPSHOT, NAMESPACE, DEFAULTS}:
        raise ValueError('Incomplete observation capture inventory')
    raw = {}
    for name, declared in record['artifacts'].items():
        raw[name] = regular(root / name, MAX_INPUT if name == SNAPSHOT else MAX_RESPONSE)
        descriptor(raw[name], declared)
    doc = validate_document(raw[SNAPSHOT], raw[NAMESPACE], raw[DEFAULTS])
    if (doc['wiki'], doc['date'], doc['namespace_sha256']) != (record.get('wiki'), record.get('date'), record.get('namespace_registry_sha256')):
        raise ValueError('Observation capture namespace or edition mismatch')
    if record.get('output_sha256') != digest(raw[SNAPSHOT]):
        raise ValueError('Observation output digest mismatch')
    manifest = regular(root / MANIFEST, MAX_MANIFEST)
    if decode(manifest) != record:
        raise ValueError('Observation manifest changed')
    complete = decode(regular(root / COMPLETE, MAX_MANIFEST))
    if complete != {'schema': 'wikidict.figure-page-observation-capture.v1', 'manifest_sha256': digest(manifest)}:
        raise ValueError('Observation COMPLETE mismatch')
    return {**{name: digest(value) for name, value in raw.items()}, MANIFEST: digest(manifest), COMPLETE: digest(regular(root / COMPLETE, MAX_MANIFEST))}


def pack(snapshot, namespace, defaults, output):
    source = regular(snapshot, MAX_INPUT); namespace = regular(namespace, MAX_RESPONSE); defaults = regular(defaults, MAX_RESPONSE)
    doc = validate_document(source, namespace, defaults)
    output = Path(output); output.mkdir(exist_ok=False, parents=True)
    artifacts = {SNAPSHOT: source, NAMESPACE: namespace, DEFAULTS: defaults}
    for name, value in artifacts.items():
        (output / name).write_bytes(value)
    record = dict(schema='wikidict.figure-page-observation-capture.v1', wiki=doc['wiki'], date=doc['date'],
                  namespace_registry_sha256=doc['namespace_sha256'], output_sha256=digest(source), **producer(),
                  artifacts={name: {'bytes': len(value), 'sha256': digest(value)} for name, value in artifacts.items()},
                  source_contract='Exact supplied full expansion/current parse; requested revision context; no parse-core or historical-transclusion inference')
    manifest = encoded(record); (output / MANIFEST).write_bytes(manifest)
    (output / COMPLETE).write_bytes(encoded(dict(schema=record['schema'], manifest_sha256=digest(manifest))))
    validate_snapshot(output / SNAPSHOT, doc['wiki'], doc['date'])
    return record


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    create = sub.add_parser('pack'); create.add_argument('--snapshot', required=True); create.add_argument('--namespace-registry', required=True); create.add_argument('--figure-siteinfo', required=True); create.add_argument('--output', required=True)
    verify = sub.add_parser('verify'); verify.add_argument('output')
    args = parser.parse_args()
    if args.command == 'pack':
        pack(args.snapshot, args.namespace_registry, args.figure_siteinfo, args.output)
    else:
        validate_snapshot(Path(args.output) / SNAPSHOT)


if __name__ == '__main__':
    main()
