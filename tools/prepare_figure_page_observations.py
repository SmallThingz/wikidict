#!/usr/bin/env python3
"""Package and verify retained supplied-page Figure observations, offline only."""
import argparse
import hashlib
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


def validate_document(raw, namespace, defaults):
    if not 0 < len(raw) <= MAX_INPUT:
        raise ValueError('Invalid observation document size')
    doc = decode(raw)
    if (set(doc) != {'schema', 'wiki', 'date', 'namespace_sha256', 'defaults_sha256', 'pages'} or
            doc.get('schema') != 'wikidict.figure-page-observations.v1' or
            not re.fullmatch('[a-z0-9_]+wiktionary', doc.get('wiki', '')) or
            not re.fullmatch('[0-9]{8}', doc.get('date', '')) or
            doc.get('namespace_sha256') != digest(namespace) or
            doc.get('defaults_sha256') != digest(defaults) or
            not isinstance(doc.get('pages'), list) or not 1 <= len(doc['pages']) <= 256):
        raise ValueError('Invalid observation document identity')
    seen_ids, seen_titles = set(), set()
    for page in doc['pages']:
        if (set(page) != {'namespace_id', 'page_id', 'revision_id', 'title', 'raw_sha256', 'request', 'form_body', 'receipt', 'response', 'occurrences'} or
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
        if not 1 <= len(form) <= 65536 or re.search(rb'%(?![0-9a-fA-F]{2})', form):
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
        if request.get('parameters_except_text') != expected:
            raise ValueError('Changed supplied-page parse parameters')
        pairs = urllib.parse.parse_qsl(form.decode('ascii'), keep_blank_values=True,
                                      strict_parsing=True, encoding='utf-8', errors='strict')
        params = dict(pairs)
        if len(pairs) != 11 or len(params) != 11 or {k: v for k, v in params.items() if k != 'text'} != expected:
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
        occurrences = page.get('occurrences')
        if not isinstance(occurrences, list) or not 1 <= len(occurrences) <= 64:
            raise ValueError('Invalid selected occurrence count')
        files, intervals = set(), []
        for item in occurrences:
            if (set(item) != {'start', 'end', 'canonical_file', 'file_sha1', 'file_timestamp', 'original_width', 'original_height', 'width', 'anchor_attributes'} or
                    type(item.get('start')) is not int or type(item.get('end')) is not int or
                    not 0 <= item['start'] < item['end'] <= len(source) or
                    type(item.get('width')) is not bool or type(item.get('anchor_attributes')) is not bool or
                    not (item['width'] or item['anchor_attributes']) or
                    not isinstance(item.get('canonical_file'), str) or not item['canonical_file'] or
                    not re.fullmatch('[0-9a-f]{40}', item.get('file_sha1', '')) or
                    not isinstance(item.get('file_timestamp'), str) or not item['file_timestamp'] or
                    type(item.get('original_width')) is not int or type(item.get('original_height')) is not int or
                    not 1 <= item['original_width'] <= 4294967295 or not 1 <= item['original_height'] <= 4294967295):
                raise ValueError('Invalid selected occurrence identity')
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
