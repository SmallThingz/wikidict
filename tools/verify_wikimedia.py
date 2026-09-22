#!/usr/bin/env python3
"""Differentially check a raw XML corpus against the live MediaWiki Action API.

No edits are made to the wiki. Exact dump source/title/revision are submitted.
Live template/module revisions are NOT pinned by expandtemplates.revid: differing
outputs with dependency drift remain unresolved, never automatically excused.
Reports/cache are persistent evidence; .tmp is used only by offline tests.
"""
import argparse
import collections
import datetime as dt
import difflib
import hashlib
import json
import os
from pathlib import Path
import random
import re
import selectors
import struct
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
from html.parser import HTMLParser

DEFAULT_TITLES = ['cat', 'water', 'run', 'école', 'كتاب', '日本', '兇', 'აღმოაჩენს']
# name, source, independent of live templates/modules, intentional error
PROBES = [
    ('arithmetic', '{{#expr:(2+3)*4}}|{{#expr:2^3^2}}|{{#expr:-2^2}}', True, False),
    ('numeric-comparison', '{{#ifeq:01|1|equal|different}}|{{#ifeq:  x |x|equal|different}}', True, False),
    ('if-empty-zero', '{{#if:0|yes|no}}|{{#if: |yes|no}}', True, False),
    ('switch-fallthrough', '{{#switch:b|a|b|c=hit|#default=miss}}|{{#switch:z|a=A|#default=Z}}', True, False),
    ('parameter-default', '{{{missing|fallback}}}|{{{missing|{{#expr:6*7}}}}}', True, False),
    ('comments-nowiki', 'a<!--hidden {{#expr:1+1}}--><nowiki>{{#expr:2+2}}</nowiki>b', True, False),
    ('include-tags', 'a<noinclude>N</noinclude><includeonly>I</includeonly><onlyinclude>O</onlyinclude>z', True, False),
    ('unicode-case', '{{uc:Straße}}|{{lc:İSTANBUL}}|{{ucfirst:école}}', True, False),
    ('url-anchor', '{{urlencode:a b/é|WIKI}}|{{anchorencode:a b#c}}', True, False),
    ('page-context', '{{PAGENAME}}|{{FULLPAGENAME}}|{{NAMESPACE}}|{{REVISIONID}}', True, False),
    ('fixed-date', '{{#time:Y-m-d|2000-02-29}}|{{#time:l|2000-01-01}}', True, False),
    ('nested-functions', '{{#if:{{#expr:2>1}}|{{uc:yes}}|no}}', True, False),
    ('tag-nowiki', '{{#tag:nowiki|{{#expr:1+1}}}}', True, False),
    ('entity-literals', '&amp; &lt; &#123; &nbsp; [[cat|a &amp; b]]', True, False),
    ('table-boundaries', "before\n{| class=\"wikitable\"\n! A !! B\n|-\n| {{#expr:1+1}} || x\n|}\nafter", True, False),
    ('references', 'one<ref name="probe">reference</ref>two<ref name="probe"/><references/>', True, False),
    ('division-error', '{{#expr:1/0}}', True, True),
    ('missing-template', '{{DictCorpusVerifier nonexistent 9f17c83e}}', False, False),
    ('existence', '{{#ifexist:cat|yes|no}}|{{#ifexist:DictCorpusVerifier nonexistent 9f17c83e|yes|no}}', False, False),
    ('english-headword', '{{en-noun}}', False, False),
    ('language-link', '{{l|en|cat}}|{{m|fr|chat}}', False, False),
    ('pronunciation', '{{IPA|en|/kæt/}}', False, False),
]


def utc():
    return dt.datetime.now(dt.timezone.utc).isoformat()


def sha(data):
    return hashlib.sha256(data).hexdigest()


def file_sha(path):
    with path.open('rb') as f:
        return hashlib.file_digest(f, 'sha256').hexdigest()


def unescape(value):
    return re.sub(r'\\([tnr\\])', lambda m: {'t': '\t', 'n': '\n', 'r': '\r', '\\': '\\'}[m[1]], value)


def row(fields, ordinal):
    return dict(offset=int(fields[0]), length=int(fields[1]), title=unescape(fields[2].decode()),
                page_id=int(fields[4]), revision=int(fields[5]), timestamp=fields[6].decode(),
                namespace=int(fields[9]), ordinal=ordinal, decode=fields[11] == b'1')


def select_pages(index, count, seed, titles):
    """Uniform reservoir over nonredirect main-namespace wikitext with source."""
    rng = random.Random(seed)
    selected, targets, revisions = [], {}, {}
    wanted = {title.encode() for title in titles}
    population = ordinal = 0
    with index.open('rb') as f:
        for line in f:
            if line.startswith(b'#'):
                if b'v2' in line:
                    raise ValueError('Compressed page index unsupported; use raw XML and its index')
                continue
            if not line.strip():
                continue
            fields = line.rstrip(b'\n').split(b'\t')
            if len(fields) != 12:
                raise ValueError(f'Invalid index at ordinal {ordinal}')
            if fields[9] in (b'10', b'828'):
                revisions[unescape(fields[2].decode())] = int(fields[5])
            if fields[2] in wanted:
                targets[unescape(fields[2].decode())] = row(fields, ordinal)
            if fields[9] == b'0' and fields[8] == b'wikitext' and not fields[3] and fields[10] == b'1':
                population += 1
                slot = population - 1 if population <= count else rng.randrange(population)
                if slot < count:
                    item = row(fields, ordinal)
                    if slot == len(selected):
                        selected.append(item)
                    else:
                        selected[slot] = item
            ordinal += 1
    return selected, targets, revisions, population


def source_at(dump, page):
    with dump.open('rb') as f:
        f.seek(page['offset'])
        raw = f.read(page['length'])
    if len(raw) != page['length']:
        raise ValueError('Truncated dump source')
    return (ET.fromstring(b'<text>' + raw + b'</text>').text or '') if page['decode'] else raw.decode()


class NativeWorker:
    def __init__(self, executable, root, dump, now, timeout, log):
        self.executable, self.root, self.dump = executable, root, dump
        self.now, self.timeout, self.log, self.child = now, timeout, log, None

    def close(self):
        if self.child is not None:
            self.child.kill()
            self.child.wait()
            self.child.stdin.close()
            self.child.stdout.close()
            self.child = None

    def transfer(self, pipe, value, writing, deadline):
        out, pos = bytearray(), 0
        size = len(value) if writing else value
        with selectors.DefaultSelector() as selector:
            selector.register(pipe, selectors.EVENT_WRITE if writing else selectors.EVENT_READ)
            while pos < size:
                remaining = deadline - time.monotonic()
                if remaining <= 0 or not selector.select(remaining):
                    raise TimeoutError('Native expansion deadline exceeded')
                try:
                    chunk = os.write(pipe.fileno(), value[pos:pos + 65536]) if writing else os.read(pipe.fileno(), min(size - pos, 65536))
                except BlockingIOError:
                    continue
                if not chunk:
                    raise RuntimeError('Native worker closed its protocol pipe')
                pos += chunk if writing else len(chunk)
                if not writing:
                    out.extend(chunk)
        return bytes(out)

    def expand(self, page, source):
        parts = [str(self.root).encode(), str(self.dump).encode(), page['title'].encode(), source.encode()]
        if len(parts[3]) > 16 * 1024 * 1024:
            raise ValueError('Source exceeds worker protocol limit')
        payload = struct.pack('<BqQIIII', 2, self.now, page['ordinal'], *map(len, parts)) + b''.join(parts)
        try:
            if self.child is None:
                self.child = subprocess.Popen([str(self.executable)], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                              stderr=self.log, bufsize=0)
                os.set_blocking(self.child.stdin.fileno(), False)
                os.set_blocking(self.child.stdout.fileno(), False)
            deadline = time.monotonic() + self.timeout
            self.transfer(self.child.stdin, struct.pack('<I', len(payload)) + payload, True, deadline)
            size = struct.unpack('<I', self.transfer(self.child.stdout, 4, False, deadline))[0]
            if not 0 < size <= 32 * 1024 * 1024:
                raise ValueError('Invalid native reply length')
            return decode_reply(self.transfer(self.child.stdout, size, False, deadline))
        except Exception:
            self.close()
            raise


def decode_reply(payload):
    if payload == b'\x02':
        raise ValueError('Worker skipped noncanonical page; sample is not verified')
    if not payload or payload[0] not in (0, 1):
        raise ValueError('Invalid native reply')
    count = 2 if payload[0] == 0 else 3
    header = 1 + 4 * count
    if len(payload) < header:
        raise ValueError('Truncated native reply')
    lengths = struct.unpack_from('<' + 'I' * count, payload, 1)
    if header + sum(lengths) != len(payload):
        raise ValueError('Invalid native reply fields')
    fields, pos = [], header
    for length in lengths:
        fields.append(payload[pos:pos + length].decode())
        pos += length
    if payload[0] == 1:
        raise RuntimeError(': '.join(fields))
    return fields[0], fields[1]


class API:
    def __init__(self, endpoint, cache, interval, timeout, user_agent):
        self.endpoint, self.cache = endpoint, cache
        self.interval, self.timeout, self.user_agent = interval, timeout, user_agent
        self.last = 0.0
        cache.mkdir(parents=True, exist_ok=True)

    def call(self, **params):
        params.update(format='json', formatversion=2, maxlag=5)
        encoded = urllib.parse.urlencode(params).encode()
        key = sha(self.endpoint.encode() + b'\0' + encoded)
        path = self.cache / (key + '.json')
        if path.exists():
            return json.loads(path.read_text())['response']
        for attempt in range(3):
            time.sleep(max(0, self.interval - (time.monotonic() - self.last)))
            self.last = time.monotonic()
            request = urllib.request.Request(self.endpoint, data=encoded, headers={'User-Agent': self.user_agent})
            try:
                with urllib.request.urlopen(request, timeout=self.timeout) as response:
                    body = response.read(32 * 1024 * 1024 + 1)
                    if len(body) > 32 * 1024 * 1024:
                        raise ValueError('API response exceeds limit')
                    data = json.loads(body)
                    server_date = response.headers.get('Date')
                if 'error' in data:
                    if data['error'].get('code') == 'maxlag' and attempt < 2:
                        time.sleep(5 * (attempt + 1))
                        continue
                    raise RuntimeError('MediaWiki API error: ' + json.dumps(data['error']))
                path.write_text(json.dumps(dict(endpoint=self.endpoint, params=params, retrieved_at=utc(),
                                               server_date=server_date, response=data), ensure_ascii=False, indent=2) + '\n')
                return data
            except urllib.error.HTTPError as error:
                if error.code not in (429, 502, 503, 504) or attempt == 2:
                    raise
                delay = error.headers.get('Retry-After', '')
                time.sleep(min(float(delay) if delay.isdigit() else 5 * (attempt + 1), 30))
        raise RuntimeError('API retries exhausted')

    def parse(self, title, source):
        return self.call(action='parse', title=title, text=source, contentmodel='wikitext',
                         prop='text|templates|categories|displaytitle', disablelimitreport=1,
                         disableeditsection=1, uselang='en')['parse']


class HTMLTokens(HTMLParser):
    """Keep structure/attributes/text; discard only nonrendered HTML comments.

    No whitespace, error text, links, classes, or generated IDs are discarded.
    This deliberately prefers false mismatches over masking a presentation bug.
    """
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.tokens = []

    def handle_starttag(self, tag, attrs):
        self.tokens.append(('start', tag, tuple(sorted(attrs))))

    def handle_startendtag(self, tag, attrs):
        self.tokens.append(('void', tag, tuple(sorted(attrs))))

    def handle_endtag(self, tag):
        self.tokens.append(('end', tag))

    def handle_data(self, data):
        if self.tokens and self.tokens[-1][0] == 'text':
            self.tokens[-1] = ('text', self.tokens[-1][1] + data)
        else:
            self.tokens.append(('text', data))


def render_signature(parsed):
    parser = HTMLTokens()
    parser.feed(parsed['text'])
    parser.close()
    categories = sorted(json.dumps(c, sort_keys=True, ensure_ascii=False) for c in parsed.get('categories', []))
    return parser.tokens, categories, parsed.get('displaytitle')


def unresolved_syntax(text):
    visible = re.sub(r'<nowiki\b[^>]*>.*?</nowiki\s*>|<!--.*?-->', '', text, flags=re.S | re.I)
    return '{{' in visible or '}}' in visible or '\x7fUNIQ' in visible


def has_error(text):
    return bool(re.search(r'Lua error|Expression error|class=[\'"][^\'"]*\b(?:error|scribunto-error)\b', text, re.I))


def write_json(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n')


def compare(case, worker, api, directory, render):
    page, source = case['page'], case['source']
    directory.mkdir(exist_ok=True)
    (directory / 'source.wiki').write_text(source)
    result = {k: v for k, v in case.items() if k != 'source'}
    result['source_sha256'] = sha(source.encode())
    result['stage'] = 'local'
    start = time.monotonic()
    try:
        local, display = worker.expand(page, source)
        result.update(local_seconds=time.monotonic() - start, local_display_title=display,
                      local_sha256=sha(local.encode()), local_error_markup=has_error(local))
        (directory / 'local.wiki').write_text(local)
        result['stage'] = 'oracle'
        response = api.call(action='expandtemplates', title=page['title'], revid=page['revision'], text=source,
                            prop='wikitext|properties|volatile', uselang='en')
        write_json(directory / 'oracle.json', response)
        oracle = response['expandtemplates']['wikitext']
        (directory / 'oracle.wiki').write_text(oracle)
        result.update(oracle_sha256=sha(oracle.encode()), oracle_error_markup=has_error(oracle),
                      oracle_volatile=response['expandtemplates'].get('volatile', False))
        if local == oracle:
            result['status'] = 'matching_error' if has_error(local) and not case['expected_error'] else 'exact_match'
            return result
        (directory / 'expansion.diff').write_text(''.join(difflib.unified_diff(
            oracle.splitlines(keepends=True), local.splitlines(keepends=True), fromfile='wikimedia', tofile='local')))
        result['status'] = 'expansion_mismatch'
        result['unresolved_syntax'] = unresolved_syntax(local)
        if render:
            result['stage'] = 'render'
            # Use the full page parser as the presentation oracle. Expanding a
            # fragment first loses parser context (e.g. language-header tracking)
            # and can introduce false category differences. Never grant equality
            # if the server could repair unresolved constructs in local output.
            remote_html = api.parse(page['title'], source)
            local_html = api.parse(page['title'], (('{{DISPLAYTITLE:' + display + '}}\n') if display else '') + local)
            write_json(directory / 'oracle-render.json', remote_html)
            write_json(directory / 'local-render.json', local_html)
            result['render_equal'] = render_signature(remote_html) == render_signature(local_html)
            result['local_render_error'] = has_error(local_html['text'])
            result['oracle_render_error'] = has_error(remote_html['text'])
            if result['render_equal'] and not result['unresolved_syntax']:
                result['status'] = ('matching_error' if result['local_render_error'] and not case['expected_error']
                                    else 'render_equivalent')
        if result['status'] == 'expansion_mismatch' and not case['independent']:
            result['stage'] = 'dependencies'
            dependency_parse = api.call(action='parse', title=page['title'], text=source, contentmodel='wikitext',
                                        prop='templates', uselang='en')['parse']
            write_json(directory / 'dependencies.json', dependency_parse)
            result['dependencies'] = [t['title'] for t in dependency_parse.get('templates', [])]
        result['stage'] = 'complete'
    except Exception as error:
        result.update(status='error', error=f'{type(error).__name__}: {error}')
    return result


def dependency_revisions(api, results, local_revisions):
    names = sorted({title for r in results for title in r.get('dependencies', [])})
    current = {}
    for start in range(0, len(names), 50):
        response = api.call(action='query', titles='|'.join(names[start:start + 50]), prop='revisions', rvprop='ids|timestamp', rvslots='main')
        pages = response['query']['pages']
        batch = {p['title']: (p.get('revisions') or [{}])[0].get('revid') for p in pages}
        for item in response['query'].get('normalized', []):
            batch[item['from']] = batch.get(item['to'])
        current.update(batch)
    for result in results:
        if result['status'] != 'expansion_mismatch':
            continue
        changed, unknown = [], []
        for title in result.get('dependencies', []):
            before, after = local_revisions.get(title), current.get(title)
            if before is None:
                unknown.append(title)
            elif before != after:
                changed.append(dict(title=title, snapshot_revision=before, live_revision=after))
        result['changed_dependencies'] = changed
        result['untracked_dependencies'] = unknown
        result['status'] = ('mismatch_with_dependency_drift' if changed else
                            'mismatch_unpinned_dependencies' if unknown else 'mismatch')
    return current


def run(args):
    if args.dump.suffix != '.xml':
        raise ValueError('Use the raw .xml dump matching this expander')
    args.report.mkdir(parents=True, exist_ok=False)
    titles = list(dict.fromkeys(['cat'] + DEFAULT_TITLES + args.title))
    print('Selecting reproducible corpus sample...', flush=True)
    random_pages, targets, revisions, population = select_pages(args.root / 'page-index.tsv', args.samples, args.seed, titles)
    if 'cat' not in targets:
        raise ValueError('The corpus must contain cat for contextual edge probes')
    cases = []
    for name, source, independent, expected_error in PROBES:
        cases.append(dict(name='probe-' + name, kind='edge-probe', page=targets['cat'], source=source,
                          independent=independent, expected_error=expected_error))
    for page in sorted(random_pages, key=lambda p: p['ordinal']):
        cases.append(dict(name=f"random-{page['ordinal']}", kind='random-page', page=page,
                          source=source_at(args.dump, page), independent=False, expected_error=False))
    for title in DEFAULT_TITLES + args.title:
        if title in targets and not any(c['kind'] == 'targeted-page' and c['page']['title'] == title for c in cases):
            page = targets[title]
            cases.append(dict(name=f"target-{page['ordinal']}", kind='targeted-page', page=page,
                              source=source_at(args.dump, page), independent=False, expected_error=False))
    now = int(time.time())
    provenance = dict(methodology_version=2, started_at=utc(), endpoint=args.endpoint, seed=args.seed, population=population,
                      sampling='uniform reservoir: main namespace, wikitext, nonredirect, has source',
                      samples_requested=args.samples, samples_selected=len(random_pages), cases=len(cases),
                      missing_targets=[t for t in titles if t not in targets], pinned_local_time=now,
                      executable=str(args.worker), executable_sha256=file_sha(args.worker),
                      manifest_sha256=file_sha(args.root / 'manifest.jsonl'), dump=str(args.dump),
                      dump_size=args.dump.stat().st_size, index_sha256=file_sha(args.root / 'page-index.tsv'),
                      limits=['Sample evidence is not proof for the whole corpus.',
                              'Live templates, modules, site configuration, extension versions and external data are not pinned.',
                              'Rendered comparison uses Wikimedia, not the shipped blob reader.',
                              'Current dependency revisions are checked after expansion; edits during the run remain possible.'])
    write_json(args.report / 'manifest.json', {**provenance, 'cases': [{k: v for k, v in c.items() if k != 'source'} for c in cases]})
    api = API(args.endpoint, args.cache or args.report / 'api-cache', args.interval, args.api_timeout, args.user_agent)
    results = []
    with (args.report / 'worker.log').open('wb') as log, (args.report / 'results.jsonl').open('w') as journal:
        worker = NativeWorker(args.worker, args.root, args.dump, now, args.local_timeout, log)
        try:
            for index, case in enumerate(cases):
                result = compare(case, worker, api, args.report / case['name'], not args.no_render)
                results.append(result)
                journal.write(json.dumps(result, ensure_ascii=False) + '\n')
                journal.flush()
                print(f"[{index + 1}/{len(cases)}] {case['name']} {case['page']['title']}: {result['status']}", flush=True)
        finally:
            worker.close()
    dependency_error = None
    try:
        current = dependency_revisions(api, results, revisions)
        write_json(args.report / 'dependency-revisions.json', current)
    except Exception as error:
        dependency_error = f'{type(error).__name__}: {error}'
    counts = collections.Counter(r['status'] for r in results)
    passed = sum(counts[k] for k in ('exact_match', 'render_equivalent'))
    state = 'passed_sample' if passed == len(cases) and not provenance['missing_targets'] and not dependency_error else 'not_verified'
    summary = dict(**provenance, finished_at=utc(), state=state, counts=counts, dependency_error=dependency_error, results=results)
    write_json(args.report / 'report.json', summary)
    rows = ['# Wikimedia differential verification', '', f"Result: **{state}**. Seed: `{args.seed}`. Random sampling population: {population:,}.", '',
            '| Classification | Cases |', '| --- | ---: |']
    rows.extend(f'| {name} | {count} |' for name, count in sorted(counts.items()))
    rows += ['', 'This checks native expansion, not whole-corpus or blob-reader correctness. Dependency drift is unresolved evidence, not a pass.', '',
             '| Case | Title | Result | Evidence |', '| --- | --- | --- | --- |']
    for r in results:
        title = r['page']['title'].replace('|', '&#124;').replace('\n', ' ')
        rows.append(f"| {r['name']} | {title} | {r['status']} | [source]({r['name']}/source.wiki), [local]({r['name']}/local.wiki), [oracle]({r['name']}/oracle.wiki) |")
        write_json(args.report / r['name'] / 'result.json', r)
    (args.report / 'report.md').write_text('\n'.join(rows) + '\n')
    print(json.dumps(dict(state=state, counts=counts, report=str(args.report / 'report.md')), ensure_ascii=False), flush=True)
    return 0 if state == 'passed_sample' else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('dump', 'root', 'worker', 'report'):
        parser.add_argument('--' + name, type=Path, required=True)
    parser.add_argument('--samples', type=int, default=32)
    parser.add_argument('--seed', type=int, default=20260922)
    parser.add_argument('--title', action='append', default=[])
    parser.add_argument('--endpoint', default='https://en.wiktionary.org/w/api.php')
    parser.add_argument('--cache', type=Path)
    parser.add_argument('--interval', type=float, default=1.0)
    parser.add_argument('--api-timeout', type=float, default=45)
    parser.add_argument('--local-timeout', type=float, default=60)
    parser.add_argument('--no-render', action='store_true')
    parser.add_argument('--user-agent', default='DictCorpusVerifier/0.1 (local differential verification; low-rate requests)')
    args = parser.parse_args()
    if args.samples < 0 or args.interval < 0.5 or args.api_timeout <= 0 or args.local_timeout <= 0:
        parser.error('Samples must be nonnegative, interval >= 0.5, and timeouts positive')
    for name in ('dump', 'root', 'worker', 'report', 'cache'):
        if getattr(args, name) is not None:
            setattr(args, name, getattr(args, name).resolve())
    return run(args)


if __name__ == '__main__':
    sys.exit(main())
