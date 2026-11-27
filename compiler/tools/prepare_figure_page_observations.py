#!/usr/bin/env python3
"""Package and verify retained supplied-page Figure observations, offline only."""
import argparse
import base64
import zlib
import hashlib
import html
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
MISSING_LINK_SHA256 = 'ecbc7435843a302ddba3652426b60f876a56950eeebdd1b9df0332aefeabd5fb'


def source_link_end(source, start, top_level_pipes=None):
    """Return a complete source link's byte end; never select the first inner ]].

    This is a packaging boundary check, not File identity/options authority.
    Keep delimiters and protected regions consistent with wikitext_syntax's
    balancedWithOpaqueScan; the native Book still validates the whole occurrence.
    """
    if type(source) is not bytes or type(start) is not int or start < 0 or source[start:start + 2] != b'[[':
        raise ValueError('Invalid source link start')
    opaque = {b'nowiki', b'pre', b'gallery', b'indicator', b'ref', b'references',
              b'templatestyles', b'math', b'ce', b'chem', b'score', b'syntaxhighlight',
              b'source', b'timeline', b'hiero', b'poem', b'categorytree', b'charinsert',
              b'graph', b'mapframe', b'maplink', b'section', b'inputbox', b'imagemap',
              b'dynamicpagelist'}

    def raw_nowiki(at):
        opening = re.match(rb'<nowiki(?=[\s/>])', source[at:], re.I)
        if opening is None:
            return None
        boundary = at + opening.end()
        if source[boundary:boundary + 1] == b'/' and source[boundary:boundary + 2] != b'/>':
            return None
        gt = source.find(b'>', boundary)
        if gt < 0:
            return None
        if source[gt - 1:gt] == b'/':
            return gt + 1
        close = re.compile(rb'</nowiki\s*>', re.I).search(source, gt + 1)
        return close.end() if close else None

    def tag(at):
        match = re.match(rb'<(/?)([A-Za-z][A-Za-z0-9-]*)(?=[\s/>])', source[at:])
        if match is None:
            return None
        closing, name = bool(match[1]), match[2].lower()
        cursor = at + match.end()
        invalid_extension_boundary = not closing and name in opaque and source[cursor:cursor + 1] == b'/' and source[cursor:cursor + 2] != b'/>'
        html_pre = invalid_extension_boundary and name == b'pre'
        if invalid_extension_boundary and not html_pre:
            return None
        while cursor < len(source):
            if source[cursor:cursor + 1] == b'>':
                return cursor + 1, name, closing, source[cursor - 1:cursor] == b'/', html_pre
            if source[cursor:cursor + 1] == b'<':
                protected = raw_nowiki(cursor)
                if protected is not None:
                    cursor = protected
                    continue
                if closing or name not in (b'ref', b'references'):
                    return None
            cursor += 1
        return None

    stack, at = [], start
    while at < len(source):
        if source.startswith(b'<!--', at):
            close = source.find(b'-->', at + 4)
            at = close + 3 if close >= 0 else len(source)
            continue
        if source[at:at + 1] == b'<':
            protected = raw_nowiki(at)
            if protected is not None:
                at = protected
                continue
            found = tag(at)
            if found is not None:
                end, name, closing, short, html_pre = found
                if not closing and name in opaque and name != b'nowiki' and not html_pre:
                    close = re.compile(rb'</' + name + rb'\s*>', re.I).search(source, end)
                    at = end if short or close is None else close.end()
                    continue
                if stack == [b']]']:
                    at = end
                    continue
        if top_level_pipes is not None and stack == [b']]'] and source[at:at + 1] == b'|':
            top_level_pipes.append(at)
        for opening, closing in ((b'{{{', b'}}}'), (b'{{', b'}}'), (b'[[', b']]')):
            if source.startswith(opening, at):
                if len(stack) == 128:
                    raise ValueError('Source link nesting limit')
                stack.append(closing)
                at += len(opening)
                break
        else:
            if stack and source.startswith(stack[-1], at):
                at += len(stack.pop())
                if not stack:
                    return at
            else:
                at += 1
    raise ValueError('Incomplete source link')


MISSING_OBSERVED_SET_PROFILE = 'vector_new_link_observed_set_v1'
MISSING_MODULE_PREFIX = b'@media (prefers-reduced-motion:reduce){*,::before,::after{animation-delay:-0.01ms !important;'


def missing_style_url(url, wiki):
    prefix = wiki[:-len('wiktionary')]
    if re.fullmatch(r'[a-z][a-z0-9]*(?:_[a-z0-9]+)*', prefix) is None:
        raise ValueError('Invalid stylesheet wiki')
    language = prefix.replace('_', '-')
    if (not isinstance(url, str) or re.search(r'%(?![0-9a-fA-F]{2})', url) or
            any(ord(char) < 32 or ord(char) == 127 for char in url) or
            not url.startswith('https://' + language + '.wiktionary.org/w/load.php?')):
        raise ValueError('Invalid stylesheet URL')
    selected = urllib.parse.urlsplit(url)
    pairs = urllib.parse.parse_qsl(selected.query, keep_blank_values=True, strict_parsing=True,
                                  encoding='utf-8', errors='strict')
    params = dict(pairs)
    if (selected.scheme != 'https' or selected.netloc != language + '.wiktionary.org' or
            selected.path != '/w/load.php' or selected.fragment or len(pairs) != 4 or
            set(params) != {'lang', 'modules', 'only', 'skin'} or params['lang'] != language or
            params['only'] != 'styles' or params['skin'] != 'vector-2022' or
            re.fullmatch(r'[A-Za-z0-9._,|\-]{1,4096}', params['modules']) is None or
            '\\' in url or any(part.split('=', 1)[0] not in {'lang', 'modules', 'only', 'skin'}
                               for part in selected.query.split('&'))):
        raise ValueError('Wrong selected stylesheet request')
    return language


def validate_observed_missing_style_set(value, defaults, wiki):
    if (set(value) != {'profile', 'defaults', 'served_set'} or
            not isinstance(value.get('defaults'), str) or value['defaults'].encode() != defaults or
            not isinstance(value.get('served_set'), dict) or
            set(value['served_set']) != {'responses', 'receipt'}):
        raise ValueError('Invalid observed Missing stylesheet set')
    served = value['served_set']
    responses = served['responses']
    if (not isinstance(responses, list) or not 1 <= len(responses) <= 16 or
            any(not isinstance(item, str) or len(item.encode()) > MAX_RESPONSE or '\0' in item for item in responses) or
            not isinstance(served['receipt'], str) or not 0 < len(served['receipt'].encode()) <= MAX_RESPONSE):
        raise ValueError('Invalid observed stylesheet bodies')
    receipt = decode(served['receipt'])
    if (not isinstance(receipt, dict) or set(receipt) != {'core', 'sources'} or receipt['core'] is not None or
            not isinstance(receipt['sources'], list) or len(receipt['sources']) != len(responses)):
        raise ValueError('Invalid observed stylesheet receipt')
    urls = {}
    for response, source in zip(responses, receipt['sources']):
        if not isinstance(source, dict):
            raise ValueError('Invalid stylesheet receipt row')
        raw = response.encode()
        if type(source.get('bytes')) is not int or source['bytes'] < 0:
            raise ValueError('Invalid stylesheet response size')
        descriptor(raw, source)
        url = source.get('url')
        language = missing_style_url(url, wiki)
        headers = source.get('headers')
        if (source.get('status') != 200 or source.get('final_url') != url or url in urls or
                not isinstance(source.get('source_path'), str) or not 0 < len(source['source_path'].encode()) <= 4096 or
                not isinstance(headers, dict) or not isinstance(headers.get('content-type'), str) or
                headers['content-type'].split(';')[0].strip() != 'text/css'):
            raise ValueError('Wrong stylesheet response identity')
        urls[url] = raw
    selected = decode(defaults)
    options = selected.get('query', {}).get('defaultoptions', {})
    if (selected.get('wiki') != wiki or options.get('skin') != 'vector-2022' or
            options.get('language') != language or options.get('vector-theme') != 'day'):
        raise ValueError('Wrong observed stylesheet default context')
    return urls


def page_missing_style_set(doc, page, defaults, inherited):
    if 'missing_served_set' not in page:
        return inherited
    legacy = doc.get('missing_link_styles')
    occurrences = page.get('occurrences')
    if (doc.get('schema') not in ('wikidict.figure-page-observations.v4', 'wikidict.figure-page-observations.v7', 'wikidict.figure-page-observations.v8', 'wikidict.figure-page-observations.v9', 'wikidict.figure-page-observations.v10', 'wikidict.figure-page-observations.v11') or inherited is not None or
            not isinstance(legacy, dict) or legacy.get('profile') != MISSING_LINK_PROFILE or
            page.get('text_class_scope') is not True or page.get('outer_context') is None or
            not isinstance(occurrences, list) or
            not any(isinstance(item, dict) and item.get('missing_content') is True for item in occurrences)):
        raise ValueError('Page stylesheet supplement requires its own admitted outer context and legacy Missing policy')
    validate_missing_link_styles(legacy, defaults, doc['wiki'])
    return validate_observed_missing_style_set({
        'profile': MISSING_OBSERVED_SET_PROFILE,
        'defaults': legacy['defaults'],
        'served_set': page['missing_served_set'],
    }, defaults, doc['wiki'])


def validate_observed_style_head(parsed, sources, wiki):
    head = parsed.get('headhtml')
    if not isinstance(head, str) or not 0 < len(head.encode()) <= MAX_RESPONSE:
        raise ValueError('Missing observed stylesheet head')

    class Head(HTMLParser):
        def __init__(self):
            super().__init__(convert_charrefs=True)
            self.roots, self.bodies, self.urls = [], [], []

        def handle_starttag(self, tag, attrs):
            values = dict(attrs)
            if tag in ('html', 'body', 'link') and (len(values) != len(attrs) or any(v is None for v in values.values())):
                raise ValueError('Ambiguous observed stylesheet head attributes')
            if tag == 'style':
                raise ValueError('Unrepresented head STYLE')
            if tag == 'base' and 'href' in values:
                raise ValueError('Unrepresented stylesheet BASE href')
            if tag == 'html':
                self.roots.append(values)
            elif tag == 'body':
                self.bodies.append(values)
            elif tag == 'link' and 'stylesheet' in values.get('rel', '').lower().split():
                if (set(values) != {'rel', 'href'} or values['rel'].lower().split() != ['stylesheet'] or
                        len(self.urls) == 16):
                    raise ValueError('Unrepresented stylesheet link context')
                href = values['href']
                origin = 'https://' + wiki[:-len('wiktionary')].replace('_', '-') + '.wiktionary.org'
                url = origin + href if href.startswith('/w/') else href
                missing_style_url(url, wiki)
                if url not in sources or url in self.urls:
                    raise ValueError('Missing or duplicate emitted stylesheet')
                self.urls.append(url)

        def handle_startendtag(self, tag, attrs):
            self.handle_starttag(tag, attrs)

    facts = Head()
    facts.feed(head)
    facts.close()
    if len(facts.roots) != 1 or len(facts.bodies) != 1 or not facts.urls:
        raise ValueError('Incomplete observed stylesheet head')
    classes = facts.roots[0].get('class', '').split()
    if ('skin-theme-clientpref-day' not in classes or 'skin-theme-clientpref-night' in classes or
            'skin-theme-clientpref-os' in classes or 'skin-vector-2022' not in facts.bodies[0].get('class', '').split()):
        raise ValueError('Unproved observed stylesheet theme or skin')
    return facts.urls



def validate_missing_style_head(parsed, sources, wiki):
    urls = validate_observed_style_head(parsed, sources, wiki)
    count = 0
    for url in urls:
        raw = sources[url]
        at = 0
        candidates = 0
        while (found := raw.find(MISSING_MODULE_PREFIX, at)) != -1:
            candidates += 1
            if candidates > 64:
                raise ValueError('Too many known-module candidates')
            at = found + len(MISSING_MODULE_PREFIX)
            module = raw[found:found + 90597]
            if len(module) == 90597 and digest(module) == MISSING_LINK_SHA256:
                count += 1
                at = found + 90597
    if count != 1:
        raise ValueError('Missing or repeated reviewed Vector module')
    # Native Book proves complete CSS grammar/module boundaries and all actual
    # inherited/own selector effects. The offline package grants no paint itself.


def source_svg_authored_width(source, start, end):
    # Reuse the exact protected/nested source-link scanner; this is only the
    # literal width boundary. Native selection still checks captured option IDs.
    pipes = []
    if source_link_end(source, start, pipes) != end:
        raise ValueError('Changed SVG source interval')
    width = None
    for left, right in zip(pipes, pipes[1:] + [end - 2]):
        part = source[left + 1:right].strip(b' \t\r\n')
        if re.fullmatch(rb'[0-9]{1,10}px', part, re.I) is not None:
            value = int(part[:-2])
            if width is not None or not 0 < value <= 4294967295:
                raise ValueError('Invalid or duplicate authored SVG width')
            width = value
    return width


def validate_missing_link_styles(value, defaults, wiki):
    # A site's identity is not a paint grant. Its own exact module response,
    # receipt and selected defaults must still satisfy every check below.
    if not isinstance(wiki, str) or not wiki.endswith('wiktionary'):
        raise ValueError('Invalid missing-link stylesheet wiki')
    prefix = wiki[:-len('wiktionary')]
    if re.fullmatch(r'[a-z][a-z0-9]*(?:_[a-z0-9]+)*', prefix) is None:
        raise ValueError('Invalid missing-link stylesheet wiki')
    language = prefix.replace('_', '-')
    if isinstance(value, dict) and value.get('profile') == MISSING_OBSERVED_SET_PROFILE:
        return validate_observed_missing_style_set(value, defaults, wiki)
    expected_url = f'https://{language}.wiktionary.org/w/load.php?lang={language}&modules=skins.vector.styles&only=styles&skin=vector-2022'
    # It supplies this module's semantics; indexed page CSS is still resolved
    # or refused by the compiler, and no absent gadget override is inferred.
    if (not isinstance(value, dict) or set(value) != {'profile', 'response', 'receipt', 'defaults'} or
            value['profile'] != MISSING_LINK_PROFILE or
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


STATIC_POSTER_PROFILE = 'vector_3d_stl_it_v1'
STATIC_POSTER_STYLES = (
    ('20ecb909844c67ed3118d8c4c2b92355b53dee8e8bc0a9f5dbddc42a3ef10d0d',
     'https://it.wiktionary.org/w/load.php?lang=it&modules=ext.3d.styles%7Cext.wikimediamessages.styles%7Cskins.vector.icons%2Cstyles%7Cskins.vector.search.codex.styles&only=styles&skin=vector-2022'),
    ('6a78d97e623212d1460468bf6f5c19268ec86b3e1d47c0511eadd4a061881f9a',
     'https://it.wiktionary.org/w/load.php?lang=it&modules=ext.gadget.IndiceOrizzontale&only=styles&skin=vector-2022'),
    ('da9678cb2aa52dd820774f001fdc1f5a0de05b1c84d196776e3f9d3c95650e38',
     'https://it.wiktionary.org/w/load.php?lang=it&modules=site.styles&only=styles&skin=vector-2022'),
)


def validate_static_poster_styles(value, defaults, wiki):
    # Package the exact closed observation set. Native Book still owns complete
    # source/HTML/cascade applicability and Registry/file/message qualification.
    if (not isinstance(value, dict) or set(value) != {'profile', 'responses', 'receipt', 'defaults'} or
            value.get('profile') != STATIC_POSTER_PROFILE or wiki != 'itwiktionary' or
            not isinstance(value.get('responses'), list) or len(value['responses']) != 3 or
            any(not isinstance(raw, str) or not 0 < len(raw.encode()) <= MAX_RESPONSE
                for raw in [*value['responses'], value.get('receipt'), value.get('defaults')]) or
            value['defaults'].encode() != defaults):
        raise ValueError('Invalid static-poster stylesheet context')
    receipt = decode(value['receipt'])
    if (not isinstance(receipt, dict) or set(receipt) != {'core', 'sources'} or receipt['core'] is not None or
            not isinstance(receipt['sources'], list) or len(receipt['sources']) != 3):
        raise ValueError('Invalid static-poster stylesheet receipt')
    for index, (response, source, (expected_hash, expected_url)) in enumerate(
            zip(value['responses'], receipt['sources'], STATIC_POSTER_STYLES), 1):
        raw = response.encode()
        if not isinstance(source, dict) or digest(raw) != expected_hash:
            raise ValueError('Unreviewed static-poster stylesheet bytes')
        descriptor(raw, source)
        headers = source.get('headers')
        if (type(source.get('status')) is not int or source['status'] != 200 or
                source.get('url') != expected_url or source.get('final_url') != expected_url or
                source.get('source_path') != f'served:it-stl-head-stylesheet-{index}:it:vector-2022' or
                not isinstance(headers, dict) or not isinstance(headers.get('content-type'), str) or
                headers['content-type'].split(';')[0].strip() != 'text/css'):
            raise ValueError('Wrong static-poster stylesheet request or response')
    selected = decode(defaults)
    options = selected.get('query', {}).get('defaultoptions', {})
    if (selected.get('wiki') != wiki or options.get('skin') != 'vector-2022' or
            options.get('language') != 'it' or options.get('vector-theme') != 'day'):
        raise ValueError('Wrong static-poster stylesheet default context')


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
OUTER_CONTEXT_GENERATORS = {
    OUTER_CONTEXT_PROFILE: 'MediaWiki 1.48.0-wmf.3',
    'mediawiki-vector-2022-1.48.0-wmf.4': 'MediaWiki 1.48.0-wmf.4',
}


def validate_current_outer_identity(proof, page, wiki, response, url, profile):
    # Packaging validates the literal capture/source join. Native intake also
    # calls the qualified direct-configuration prefix parser on these same bytes.
    names = {'mode', 'historical', 'api_request', 'api_receipt', 'api_response',
             'received_prefix', 'prefix_receipt'}
    if (not isinstance(proof, dict) or set(proof) != names or
            proof['mode'] != 'canonical-current-v1' or proof['historical'] is not False or
            page['namespace_id'] != 0 or profile != 'mediawiki-vector-2022-1.48.0-wmf.4'):
        raise ValueError('Invalid current outer identity mode')
    for key in names - {'mode', 'historical', 'received_prefix'}:
        if not isinstance(proof[key], str) or not 0 < len(proof[key].encode()) <= 65536:
            raise ValueError('Invalid current identity capture size')
    received = proof['received_prefix']
    if not isinstance(received, str) or not 0 < len(received.encode()) <= 512 * 1024 or not received.encode().startswith(response):
        raise ValueError('Current outer prefix is not the retained response slice')
    host = wiki[:-len('wiktionary')].replace('_', '-')
    expected_url = 'https://' + host + '.wiktionary.org/wiki/' + urllib.parse.quote(page['title'].replace(' ', '_'), safe='-._~/:')
    if url != expected_url:
        raise ValueError('Wrong current canonical URL')
    request = decode(proof['api_request']); receipt = decode(proof['api_receipt']); doc = decode(proof['api_response'])
    def receipt_matches(raw, item, expected):
        if (not isinstance(item, dict) or type(item.get('status')) is not int or item['status'] != 200 or
                type(item.get('request_count')) is not int or item['request_count'] != 1 or item.get('url') != expected or
                item.get('response_bytes') != len(raw) or item.get('response_sha256') != digest(raw) or
                not isinstance(item.get('started_utc'), str) or not item['started_utc']):
            raise ValueError('Current capture receipt differs')
    selected = request.get('pages')
    if not isinstance(selected, list) or not 1 <= len(selected) <= 50:
        raise ValueError('Invalid current identity batch')
    identities = {}; revisions = []
    for entry in selected:
        want = entry['expected_identity']; pid = want['pageid']; rev = want['selected_revision_id']
        if (type(pid) is not int or pid <= 0 or pid in identities or type(rev) is not int or rev <= 0 or rev in revisions or
                type(want['ns']) is not int or want['ns'] != 0 or want['contentmodel'] != 'wikitext'):
            raise ValueError('Invalid current request identity')
        identities[pid] = want; revisions.append(rev)
        if pid == page['page_id'] and (rev != page['revision_id'] or want['title'] != page['title'] or
                entry['raw_source']['sha256'] != page['raw_sha256']):
            raise ValueError('Current request differs from selected source')
    if page['page_id'] not in identities:
        raise ValueError('Current request omits selected page')
    params = {'action': 'query', 'curtimestamp': '1', 'format': 'json', 'formatversion': '2', 'maxlag': '5',
              'meta': 'siteinfo', 'prop': 'info|revisions', 'revids': '|'.join(map(str, revisions)), 'rvprop': 'ids', 'siprop': 'general'}
    api_url = 'https://' + host + '.wiktionary.org/w/api.php?' + urllib.parse.urlencode(params)
    if request['request']['method'] != 'GET' or request['request']['url'] != api_url:
        raise ValueError('Wrong current API request')
    receipt_matches(proof['api_response'].encode(), receipt, api_url)
    core = 'a2f17941896ce97ea79981632f6ec9ffd9a79802'
    if (receipt.get('accepted') is not True or receipt.get('core_revision') != core or doc.get('batchcomplete') is not True or
            any(k in doc for k in ('error', 'errors', 'warnings', 'continue')) or not isinstance(doc.get('curtimestamp'), str) or not doc['curtimestamp']):
        raise ValueError('Unaccepted current API capture')
    query = doc['query']; general = query['general']
    if (any(k in query for k in ('normalized', 'redirects', 'interwiki', 'converted', 'badrevids')) or
            general['wikiid'] != wiki or general['generator'] != 'MediaWiki 1.48.0-wmf.4' or general['git-hash'] != core):
        raise ValueError('Unproved current API source')
    observed = query['pages']; seen = set()
    if not isinstance(observed, list) or len(observed) != len(selected):
        raise ValueError('Current API page census differs')
    for item in observed:
        pid = item['pageid']
        if type(pid) is not int or pid not in identities or pid in seen or any(k in item for k in ('missing', 'invalid', 'suppressed', 'redirect')):
            raise ValueError('Ambiguous current API identity')
        seen.add(pid); want = identities[pid]; revs = item['revisions']
        if (type(item['ns']) is not int or item['ns'] != 0 or item['title'] != want['title'] or item['contentmodel'] != 'wikitext' or
                not isinstance(revs, list) or len(revs) != 1 or type(revs[0]['revid']) is not int or
                revs[0]['revid'] != want['selected_revision_id'] or any(k in revs[0] for k in ('texthidden', 'userhidden', 'suppressed'))):
            raise ValueError('Current API revision differs')
        if pid == page['page_id'] and (type(item['lastrevid']) is not int or item['lastrevid'] != page['revision_id']):
            raise ValueError('Selected revision is no longer current')
    prefix_receipt = decode(proof['prefix_receipt'])
    receipt_matches(received.encode(), prefix_receipt, url)
    if (prefix_receipt.get('final_url') != url or prefix_receipt.get('mode') != 'current-canonical' or
            prefix_receipt.get('redirects') is not False or prefix_receipt.get('headers', {}).get('content-type') != 'text/html; charset=UTF-8'):
        raise ValueError('Wrong current prefix transport identity')


def validate_missing_head_context(page, parsed, wiki, source):
    value = page.get('missing_head_context')
    if (not isinstance(value, dict) or set(value) != {'request', 'form_body', 'receipt', 'response'} or
            any(not isinstance(value[k], str) or not 0 < len(value[k].encode()) <= MAX_RESPONSE for k in value) or
            page.get('text_class_scope') is not True or 'headhtml' in parsed):
        raise ValueError('Invalid separate Missing head context')
    outer = page.get('outer_context')
    current = outer.get('current_identity') if isinstance(outer, dict) else None
    if (not isinstance(current, dict) or current.get('mode') != 'canonical-current-v1' or current.get('historical') is not False or
            any(page.get(k) is not None for k in ('image_map_no_link', 'authored_style_operations', 'figure_style_assets'))):
        raise ValueError('Missing head supplement requires current outer proof without unrelated capabilities')
    operations = page.get('figure_style_operations', [])
    if not isinstance(operations, list) or any(not isinstance(item, dict) for item in operations):
        raise ValueError('Invalid Missing head operation container')
    occurrences = page.get('occurrences')
    if (not isinstance(occurrences, list) or not occurrences or
            any(not isinstance(item, dict) or item.get('missing_content') is not True or item.get('static_poster', False) is not False or
                item.get('svg_language') is not None or item.get('resolved_svg_language') is not None for item in occurrences) or
            any(item.get('media_kind') != 'missing' for item in operations)):
        raise ValueError('Head supplement is Missing-only')
    return validate_separate_head_context(value, page, parsed, wiki, source)


def validate_separate_head_context(value, page, parsed, wiki, source):
    form = value['form_body'].encode('ascii')
    if not 0 < len(form) <= 262144 or re.search(rb'%(?![0-9a-fA-F]{2})', form):
        raise ValueError('Invalid head form')
    request, receipt, response = (decode(value[k]) for k in ('request', 'receipt', 'response'))
    descriptor(form, request['form']); descriptor(value['request'].encode(), receipt['request'])
    descriptor(value['response'].encode(), receipt['response']); descriptor(source, request['text_source'])
    endpoint = 'https://' + wiki[:-len('wiktionary')].replace('_', '-') + '.wiktionary.org/w/api.php'
    if (request.get('schema') != 'wikidict.supplied-expanded-head-request.v1' or request.get('method') != 'POST' or
            request.get('url') != endpoint or request.get('content_type') != 'application/x-www-form-urlencoded; charset=utf-8' or
            request.get('page_id') != page['page_id'] or request.get('requested_revision_id') != page['revision_id'] or
            request.get('request_count') != 1 or receipt.get('request_count') != 1 or receipt.get('status') != 200 or
            receipt.get('accepted') is not True or request.get('controlled_single_token') is not False or
            request.get('full_supplied_expanded_page') is not True or request.get('historical_transclusions') is not False or
            request.get('parse_core_binding_proven') is not False):
        raise ValueError('Unproved head capture request or receipt')
    expected = dict(action='parse', format='json', formatversion='2', title=page['title'], revid=str(page['revision_id']),
                    contentmodel='wikitext', prop='headhtml|wikitext', parser='legacy', usearticle='1', maxlag='5', useskin='vector-2022')
    if request.get('parameters_except_text') != expected:
        raise ValueError('Changed head request parameters')
    pairs = urllib.parse.parse_qsl(form.decode('ascii'), keep_blank_values=True, strict_parsing=True, encoding='utf-8', errors='strict')
    params = dict(pairs)
    if (len(pairs) != 12 or len(params) != 12 or {k: v for k, v in params.items() if k != 'text'} != expected or
            params.get('text', '').encode() != source):
        raise ValueError('Head form differs from original supplied source')
    if not isinstance(response, dict) or any(k in response for k in ('error', 'errors', 'warnings')):
        raise ValueError('Head capture error or warning')
    head = response.get('parse')
    if (not isinstance(head, dict) or 'text' in head or head.get('title') != page['title'] or head.get('pageid') != page['page_id'] or
            head.get('wikitext', '').encode() != source or ('revid' in head and head['revid'] != page['revision_id']) or
            not isinstance(head.get('headhtml'), str) or not 0 < len(head['headhtml'].encode()) <= MAX_RESPONSE or '\0' in head['headhtml']):
        raise ValueError('Head supplement source/page identity differs')
    # Validation-only view; neither the input document nor either response or
    # receipt is rewritten. Every consumer reads the two authenticated sources.
    return dict(parsed, headhtml=head['headhtml'])



def validate_authored_head_context(page, parsed, wiki, source):
    value = page.get('authored_head_context')
    outer = page.get('outer_context')
    current = outer.get('current_identity') if isinstance(outer, dict) else None
    operations = page.get('authored_style_operations')
    if (not isinstance(value, dict) or set(value) != {'request', 'form_body', 'receipt', 'response'} or
            any(not isinstance(value[k], str) or not 0 < len(value[k].encode()) <= MAX_RESPONSE for k in value) or
            'headhtml' in parsed or page.get('text_class_scope') is not True or page.get('occurrences') != [] or
            not isinstance(page.get('page_styles'), dict) or not isinstance(operations, list) or not operations or
            not isinstance(current, dict) or current.get('mode') != 'canonical-current-v1' or current.get('historical') is not False or
            outer.get('selected_body') is not None or
            any(page.get(k) is not None for k in ('missing_head_context', 'figure_style_operations', 'figure_style_assets', 'figure_block_renditions', 'image_map_no_link', 'missing_served_set'))):
        raise ValueError('Authored head requires its own non-Missing source operations and current context')
    return validate_separate_head_context(value, page, parsed, wiki, source)


def current_literal_top_level(source, start, end):
    # This deliberately small raw-source arm accepts a literal whole line,
    # outside templates, links, HTML and wiki-table scopes. It never expands it.
    if (type(start) is not int or type(end) is not int or not 0 <= start < end <= len(source) or
            source_link_end(source, start) != end or
            (start and source[start - 1:start] != b'\n') or
            source[end:end + 1] not in (b'', b'\n', b'\r')):
        raise ValueError('Current literal is not a complete source line')
    stack, at = [], 0
    while at < start:
        if source[at:at + 1] in (b'<', b'>', b'\0') or source.startswith(b'{|', at):
            raise ValueError('Unproved raw literal parent')
        if source.startswith(b'[[', at):
            at = source_link_end(source, at)
            if at > start:
                raise ValueError('Literal is nested in another link')
            continue
        if source.startswith(b'{{{', at):
            stack.append(3); at += 3
        elif source.startswith(b'{{', at):
            stack.append(2); at += 2
        elif source.startswith(b'}}', at):
            if not stack:
                raise ValueError('Unbalanced raw literal source')
            width = stack.pop()
            if source[at:at + width] != b'}' * width:
                raise ValueError('Unbalanced raw literal source')
            at += width
        elif source[at:at + 1] in (b'{', b'}'):
            raise ValueError('Unproved raw literal delimiter')
        else:
            at += 1
        if len(stack) > 128:
            raise ValueError('Raw literal nesting exceeds bounds')
    if at != start or stack:
        raise ValueError('Literal is nested in a template')


def current_literal_frame(fragment, canonical, caption):
    class Frame(HTMLParser):
        def __init__(self):
            super().__init__(convert_charrefs=True)
            self.stack, self.order = [], []
            self.media_text, self.caption_text = [], []

        def handle_starttag(self, tag, attrs):
            path = tuple(self.stack)
            expected = {(): 'figure', ('figure',): ('a', 'figcaption'), ('figure', 'a'): 'span'}
            wanted = expected.get(path, ())
            if tag not in ((wanted,) if isinstance(wanted, str) else wanted):
                raise ValueError('Foreign current literal frame node')
            values = dict(attrs)
            if len(values) != len(attrs) or any(value is None for _, value in attrs):
                raise ValueError('Ambiguous current literal frame attributes')
            self.order.append(tag)
            if tag == 'figure':
                data = decode(values.get('data-mw', '{}'))
                if (set(values) - {'class', 'typeof', 'id', 'data-mw'} or
                        values.get('class') != 'mw-default-size' or values.get('typeof') != 'mw:Error mw:File/Thumb' or
                        not isinstance(data, dict) or set(data) != {'errors'} or
                        not isinstance(data['errors'], list) or len(data['errors']) != 1 or
                        not isinstance(data['errors'][0], dict) or set(data['errors'][0]) != {'key', 'message'} or
                        not isinstance(data['errors'][0]['message'], str) or not data['errors'][0]['message'] or
                        data['errors'][0].get('key') != 'apierror-filedoesnotexist'):
                    raise ValueError('Unproved current literal Missing frame')
            elif tag == 'a':
                if (set(values) - {'href', 'class', 'title', 'id'} or values.get('class') != 'new' or
                        values.get('title') != canonical or not isinstance(values.get('href'), str)):
                    raise ValueError('Current literal link identity differs')
            elif tag == 'span':
                if (set(values) - {'class', 'resource', 'data-width', 'id'} or
                        values.get('class') != 'mw-file-element mw-broken-media' or
                        urllib.parse.unquote(values.get('resource', '')).replace('_', ' ') != './' + canonical or
                        not re.fullmatch('[1-9][0-9]*', values.get('data-width', ''))):
                    raise ValueError('Current literal media identity differs')
            elif set(values) - {'id'}:
                raise ValueError('Foreign current literal caption attributes')
            self.stack.append(tag)

        def handle_endtag(self, tag):
            if not self.stack or self.stack.pop() != tag:
                raise ValueError('Unbalanced current literal frame')

        def handle_startendtag(self, tag, attrs):
            raise ValueError('Self-closing current literal frame')

        def handle_data(self, text):
            if self.stack == ['figure', 'a', 'span']:
                self.media_text.append(text)
            elif self.stack == ['figure', 'figcaption']:
                self.caption_text.append(text)
            elif text:
                raise ValueError('Foreign current literal frame text')

        def handle_comment(self, text):
            raise ValueError('Opaque current literal frame comment')

        def handle_decl(self, text):
            raise ValueError('Foreign current literal declaration')

        def unknown_decl(self, text):
            raise ValueError('Foreign current literal declaration')

        def handle_pi(self, text):
            raise ValueError('Foreign current literal instruction')

    frame = Frame(); frame.feed(fragment); frame.close()
    if (not fragment.startswith('<figure ') or not fragment.endswith('</figure>') or
            frame.stack or frame.order != ['figure', 'a', 'span', 'figcaption'] or
            ''.join(frame.media_text) != canonical or ''.join(frame.caption_text) != caption):
        raise ValueError('Current literal frame/caption differs')


def current_literal_style_view(page):
    # Preserve the complete acquisition receipt in the document. Only this
    # explicit source mode validates its extra acquisition facts before using
    # the unchanged shared stylesheet validator's neutral two-field view.
    served = page.get('page_styles')
    if (page.get('current_get_literal') is None or
            not isinstance(page.get('outer_context'), dict) or
            page['outer_context'].get('selected_body') != 'current_get_literal' or
            not isinstance(served, dict) or set(served) != {'responses', 'receipt'} or
            not isinstance(served['receipt'], str) or not 0 < len(served['receipt'].encode()) <= MAX_RESPONSE):
        raise ValueError('Invalid current literal stylesheet acquisition')
    receipt = decode(served['receipt'])
    if (not isinstance(receipt, dict) or
            set(receipt) != {'core', 'historical_equality_proven', 'sources', 'unrequested'} or
            receipt['core'] is not None or receipt['historical_equality_proven'] is not False or
            receipt['unrequested'] != [] or not isinstance(receipt['sources'], list)):
        raise ValueError('Unproved current literal stylesheet acquisition')
    for source in receipt['sources']:
        if (not isinstance(source, dict) or source.get('accepted') is not True or
                source.get('response_complete') is not True or source.get('unknown_response_outcome') is not False or
                type(source.get('request_count')) is not int or source['request_count'] != 1):
            raise ValueError('Incomplete current literal stylesheet acquisition')
    return {'responses': served['responses'],
            'receipt': encoded({'core': None, 'sources': receipt['sources']}).decode()}


def current_get_literal_view(page, wiki):
    value = page.get('current_get_literal')
    names = {'raw_source', 'expanded_source', 'raw_start', 'raw_end', 'frame_start', 'frame_end', 'encoded_gzip_base64'}
    outer = page.get('outer_context')
    if (not isinstance(value, dict) or set(value) != names or not isinstance(outer, dict) or
            set(outer) != {'profile', 'selected_body', 'response', 'current_identity'} or
            outer.get('selected_body') != 'current_get_literal' or page.get('text_class_scope') is not True or
            page.get('namespace_id') != 0 or not isinstance(page.get('page_styles'), dict) or
            any(key in page for key in ('request', 'form_body', 'receipt', 'response', 'missing_head_context',
                                       'image_map_no_link', 'figure_style_assets', 'authored_style_operations',
                                       'authored_head_context', 'figure_block_renditions',
                                       'missing_served_set', 'source_element_relations'))):
        raise ValueError('Invalid current GET literal source mode')
    for key in ('raw_source', 'expanded_source'):
        if not isinstance(value[key], str) or not 0 < len(value[key].encode()) <= MAX_RESPONSE or '\0' in value[key]:
            raise ValueError('Invalid current literal source bytes')
    raw, source = value['raw_source'].encode(), value['expanded_source'].encode()
    if digest(raw) != page['raw_sha256']:
        raise ValueError('Current literal raw source differs')
    operations, occurrences = page.get('figure_style_operations'), page.get('occurrences')
    if (not isinstance(operations, list) or len(operations) != 1 or not isinstance(operations[0], dict) or
            set(operations[0]) != {'start', 'end', 'media_kind'} or operations[0]['media_kind'] != 'missing' or
            not isinstance(occurrences, list) or len(occurrences) != 1 or not isinstance(occurrences[0], dict) or
            set(occurrences[0]) != {'start', 'end', 'canonical_file', 'missing_content'} or
            occurrences[0]['missing_content'] is not True or
            not isinstance(occurrences[0]['canonical_file'], str) or not occurrences[0]['canonical_file'] or
            any(operations[0][key] != occurrences[0][key] for key in ('start', 'end'))):
        raise ValueError('Current literal requires one matching Missing operation')
    start, end = operations[0]['start'], operations[0]['end']
    current_literal_top_level(raw, value['raw_start'], value['raw_end'])
    if (type(start) is not int or type(end) is not int or not 0 <= start < end <= len(source) or
            source_link_end(source, start) != end):
        raise ValueError('Current literal expanded interval differs')
    token = raw[value['raw_start']:value['raw_end']]
    if source[start:end] != token or raw.count(token) != 1 or source.count(token) != 1:
        raise ValueError('Current literal is not unique in both exact sources')
    # The native Book independently proves the full expanded source grammar,
    # namespace File identity, root parent and captured candidate correspondence.
    pieces = token[2:-2].split(b'|')
    if (len(pieces) != 3 or pieces[1] != b'thumb' or b':' not in pieces[0] or not pieces[2] or
            any(byte in pieces[2] for byte in b'[]{}<>|&\r\n\x00') or pieces[2].strip() != pieces[2]):
        raise ValueError('Current literal requires exact plain thumbnail caption')
    html = outer['response']
    if not isinstance(html, str) or not 0 < len(html.encode()) <= 512 * 1024 or '\0' in html:
        raise ValueError('Invalid current literal full GET bytes')
    encoded_text = value['encoded_gzip_base64']
    if not isinstance(encoded_text, str) or not 0 < len(encoded_text) <= 4 * 256 * 1024 // 3 + 4:
        raise ValueError('Invalid current literal compressed size')
    encoded = base64.b64decode(encoded_text, validate=True)
    if not 18 <= len(encoded) <= 256 * 1024 or encoded[:4] != b'\x1f\x8b\x08\x00':
        raise ValueError('Unsupported current literal gzip member')
    inflater = zlib.decompressobj(16 + zlib.MAX_WBITS)
    try:
        full = inflater.decompress(encoded, 512 * 1024 + 1)
    except zlib.error as error:
        raise ValueError('Invalid current literal gzip member') from error
    if (len(full) > 512 * 1024 or not inflater.eof or inflater.unused_data or inflater.unconsumed_tail or
            full != html.encode()):
        raise ValueError('Current literal gzip does not prove complete GET')
    proof = outer['current_identity']
    if (not isinstance(proof, dict) or not isinstance(proof.get('prefix_receipt'), str) or
            not isinstance(proof.get('received_prefix'), str)):
        raise ValueError('Invalid current literal original receipt')
    receipt = decode(proof['prefix_receipt'])
    if not isinstance(receipt, dict):
        raise ValueError('Invalid current literal original receipt')
    received = proof['received_prefix'].encode()
    if (not full.startswith(received) or len(received) >= len(full) or
            receipt.get('encoded_received_bytes') != len(encoded) or receipt.get('encoded_received_sha256') != digest(encoded) or
            receipt.get('headers', {}).get('content-encoding') != 'gzip' or
            receipt.get('accepted') is not False or receipt.get('compressed_stream_complete') is not False):
        raise ValueError('Current literal original prefix custody differs')
    url = receipt.get('url')
    validate_current_outer_identity(proof, page, wiki, received, url, outer['profile'])
    selected = selected_full_get_view(outer, page, {'wikitext': value['expanded_source']})
    start, end = value['frame_start'], value['frame_end']
    body = html.encode()
    if type(start) is not int or type(end) is not int or not 0 <= start < end <= len(body):
        raise ValueError('Invalid current literal frame interval')
    frame = body[start:end].decode('utf-8')
    current_literal_frame(frame, occurrences[0]['canonical_file'], pieces[2].decode('utf-8'))
    return source, selected


def current_literal_section(attributes):
    # These are captured structural identities, not a style or geometry grant.
    if (set(attributes) not in ({'data-mw-section-id', 'id'},
                                {'data-mw-section-id', 'id', 'aria-labelledby'}) or
            not isinstance(attributes.get('data-mw-section-id'), str)):
        raise ValueError('Invalid current literal section attributes')
    section = attributes['data-mw-section-id']
    if section != '-1' and (re.fullmatch(r'0|[1-9][0-9]{0,19}', section) is None or int(section) > (1 << 64) - 1):
        raise ValueError('Invalid current literal section identity')
    for key in ('id', 'aria-labelledby'):
        if key not in attributes:
            continue
        token = attributes[key]
        if (not isinstance(token, str) or not 0 < len(token.encode()) <= 256 or
                any(ord(char) <= 32 or ord(char) == 127 or char in '<>\"\'&' for char in token)):
            raise ValueError('Invalid current literal section token')


SD_READY_OUTER_PROFILE = 'mediawiki-vector-2022-1.48.0-wmf.6'
SD_READY_HEAD_PROGRAM = '1515b0419cd9415da2a3a86dc261948d619a89960f38dd6287a26fc48627444b'


def selected_sd_ready_outer(wiki, page, outer):
    return (wiki == 'sdwiktionary' and page.get('namespace_id') == 0 and
            page.get('page_id') == 5753 and page.get('revision_id') == 21696 and
            page.get('title') == 'تِرڇائِي' and
            page.get('raw_sha256') == 'b6a53bb81092f66ebb81b361ee84d723726c5a46fb0bfedd6261c061eae4f64e' and
            outer.get('profile') == SD_READY_OUTER_PROFILE and
            outer.get('selected_body') == 'full_get_root' and
            page.get('figure_style_operations') == [{'start': 0, 'end': 111}] and
            'current_identity' not in outer)


def selected_full_get_view(value, page, parsed, *, sd_ready=False):
    """Return a validation-only view; retain the original API/GET payloads."""
    current_literal = value.get('selected_body') == 'current_get_literal'
    if ((not current_literal and (value.get('selected_body') != 'full_get_root' or 'current_identity' in value)) or
            (current_literal and ('current_get_literal' not in page or 'current_identity' not in value)) or
            'missing_head_context' in page or 'authored_head_context' in page or page.get('text_class_scope') is not True or
            not isinstance(page.get('page_styles'), dict) or
            not isinstance(page.get('figure_style_operations'), list) or not page['figure_style_operations']):
        raise ValueError('Full GET selection requires exact oldid source operations and styles')
    html = value['response']
    if '\0' in html:
        raise ValueError('Invalid full GET source')
    offsets = [0]
    for index, character in enumerate(html):
        if character == '\n':
            offsets.append(index + 1)

    class Parts(HTMLParser):
        void = {'area', 'base', 'br', 'col', 'embed', 'hr', 'img', 'input', 'link', 'meta', 'param', 'source', 'track', 'wbr'}

        def __init__(self):
            super().__init__(convert_charrefs=True)
            self.root_start = self.root_end = self.body_end = None
            self.stack = []
            self.prefix_path = []
            self.head_seen = self.head_closed = False
            self.script = None
            self.configs = []
            self.html_classes = None
            self.elements = 0
            self.literal_frame_root = False
            self.current_root_attributes = None
            self.current_html_attributes = None
            self.current_body_attributes = None
            self.current_generators = []

        def position(self):
            line, column = self.getpos()
            return offsets[line - 1] + column

        def handle_starttag(self, tag, attrs):
            values = dict(attrs)
            if len(values) != len(attrs):
                raise ValueError('Duplicate full GET attributes')
            start = self.position()
            if current_literal:
                if tag == 'html': self.current_html_attributes = values
                if tag == 'body': self.current_body_attributes = values
                if 'mw-parser-output' in (values.get('class') or '').split(): self.current_root_attributes = values
                if tag == 'meta' and values.get('name') == 'generator':
                    if self.prefix_path != ['html', 'head'] or set(values) != {'name', 'content'}:
                        raise ValueError('Misplaced current GET generator')
                    self.current_generators.append(values['content'])
            end = start + len(self.get_starttag_text())
            if tag == 'html':
                if self.html_classes is not None or self.prefix_path or self.body_end is not None:
                    raise ValueError('Repeated full GET HTML')
                self.html_classes = values.get('class', '')
            elif tag == 'head':
                if self.head_seen or self.body_end is not None or self.prefix_path != ['html'] or attrs:
                    raise ValueError('Misplaced full GET HEAD')
                self.head_seen = True
            elif tag == 'body':
                if self.body_end is not None or not self.head_closed or self.prefix_path != ['html']:
                    raise ValueError('Ambiguous full GET body')
                self.body_end = end
            elif self.body_end is None and not self.prefix_path:
                raise ValueError('Element outside full GET HTML')
            if tag == 'script' and self.body_end is None:
                self.script = (end, attrs, self.prefix_path == ['html', 'head'])
            if self.body_end is None and tag not in self.void:
                self.prefix_path.append(tag)
                if len(self.prefix_path) > 128:
                    raise ValueError('Full GET prefix exceeds bounds')
            if current_literal and self.stack and tag == 'section':
                if self.stack[0] != 'div' or len(self.stack) > 32 or any(parent != 'section' for parent in self.stack[1:]):
                    raise ValueError('Current literal section is outside the selected root chain')
                current_literal_section(values)
            if current_literal and len(html[:start].encode()) == page['current_get_literal']['frame_start']:
                if (tag != 'figure' or not self.stack or self.stack[0] != 'div' or
                        len(self.stack) > 33 or any(parent != 'section' for parent in self.stack[1:]) or self.literal_frame_root):
                    raise ValueError('Current literal frame is outside its unique selected root chain')
                self.literal_frame_root = True
            if 'mw-parser-output' in (values.get('class') or '').split():
                if self.root_start is not None or tag != 'div' or self.body_end is None:
                    raise ValueError('Ambiguous full GET parser root')
                if current_literal and (set(values) != {'class', 'lang', 'dir', 'data-mw-parsoid-version', 'data-mw-html-version'} or
                        values.get('class') != 'mw-content-ltr mw-parser-output' or
                        values.get('data-mw-parsoid-version') != '0.24.0.0-alpha27' or values.get('data-mw-html-version') != '2.8.0'):
                    raise ValueError('Unsupported current literal parser-root metadata')
                self.root_start = start
                self.stack.append(tag)
            elif self.stack and tag not in self.void:
                self.stack.append(tag)
            if self.body_end is not None and not self.stack and tag in ('style', 'link', 'base'):
                raise ValueError('Unselected full GET stylesheet')
            if self.stack:
                self.elements += 1
                if len(self.stack) > 128 or self.elements > 16384:
                    raise ValueError('Full GET body exceeds bounds')

        def handle_startendtag(self, tag, attrs):
            if tag not in self.void:
                raise ValueError('Self-closing full GET container')
            self.handle_starttag(tag, attrs)

        def handle_endtag(self, tag):
            if tag == 'head' and (self.body_end is not None or self.prefix_path != ['html', 'head']):
                raise ValueError('Misplaced full GET HEAD closure')
            if self.body_end is None:
                if not self.prefix_path or self.prefix_path[-1] != tag:
                    raise ValueError('Unbalanced full GET prefix')
                if tag == 'head':
                    self.head_closed = True
                self.prefix_path.pop()
            if tag == 'script' and self.script is not None:
                begin, attrs, direct_head = self.script
                text = html[begin:self.position()]
                self.script = None
                at = text.find('RLCONF=')
                if at >= 0:
                    if attrs or not direct_head:
                        raise ValueError('Indirect full GET configuration')
                    if at:
                        expected_program = ('e925dc8ae7861a33fd0b23132dbc9eeae57bba470d42e81320a4b43ed0a6a5e1' if current_literal else
                                            '65ec9c98e6764dbb12bc436514f1033a9cb2eb780783cd043398b237e6dc8d6b')
                        if sd_ready:
                            expected_program = SD_READY_HEAD_PROGRAM
                        if digest(text[:at].encode()) != expected_program:
                            raise ValueError('Unproved full GET head program')
                        begin_class = '(function(){var className="'
                        end_class = text.index('";var cookie=')
                        if (not isinstance(self.html_classes, str) or not self.html_classes.startswith('client-nojs ') or
                                text[len(begin_class):end_class] != 'client-js ' + self.html_classes[len('client-nojs '):]):
                            raise ValueError('Full GET root state differs from retained head')
                    payload = text[at + len('RLCONF='):]
                    _, end = json.JSONDecoder().raw_decode(payload)
                    if end >= len(payload) or payload[end] != ';' or 'RLCONF' in payload[end + 1:]:
                        raise ValueError('Ambiguous full GET configuration')
                    self.configs.append(decode(payload[:end]))
            if self.stack:
                if self.stack[-1] != tag:
                    raise ValueError('Unbalanced full GET parser root')
                self.stack.pop()
                if not self.stack:
                    close = re.match(r'</div\s*>', html[self.position():], re.I)
                    if close is None:
                        raise ValueError('Invalid full GET root closure')
                    self.root_end = self.position() + close.end()

    parts = Parts()
    parts.feed(html)
    parts.close()
    if (parts.stack or not parts.head_closed or parts.root_start is None or parts.root_end is None or
            parts.body_end is None or len(parts.configs) != 1 or (current_literal and not parts.literal_frame_root)):
        raise ValueError('Incomplete full GET source')
    config = parts.configs[0]
    if (not isinstance(config, dict) or
            any(type(config.get(key)) is not int or config[key] != expected for key, expected in (
                ('wgArticleId', page['page_id']), ('wgRevisionId', page['revision_id']), ('wgNamespaceNumber', page['namespace_id']))) or
            config.get('wgPageName') != page['title'].replace(' ', '_') or config.get('wgAction') != 'view' or config.get('wgIsArticle') is not True):
        raise ValueError('Full GET configuration differs from selected source')
    if sd_ready and (config.get('wgTitle') != page['title'] or 'wgUserName' not in config or
                     config['wgUserName'] is not None or config.get('wgUserGroups') != ['*']):
        raise ValueError('Selected SD ready-Figure context requires the anonymous oldid view')
    if current_literal and (type(config.get('wgCurRevisionId')) is not int or config['wgCurRevisionId'] != page['revision_id'] or config.get('wgTitle') != page['title']):
        raise ValueError('Full current GET revision identity differs')
    if current_literal:
        language = decode(value['current_identity']['api_response'])['query']['general']['lang']
        if (parts.current_generators != [OUTER_CONTEXT_GENERATORS.get(value['profile'])] or
                not isinstance(language, str) or not language or
                any(not isinstance(attrs, dict) or attrs.get('lang') != language or attrs.get('dir') != 'ltr'
                    for attrs in (parts.current_html_attributes, parts.current_root_attributes)) or
                not isinstance(parts.current_body_attributes, dict) or
                'skin-vector-2022' not in parts.current_body_attributes.get('class', '').split()):
            raise ValueError('Current GET source generator or root differs')
    return dict(parsed, text=html[parts.root_start:parts.root_end], headhtml=html[:parts.body_end])


def validate_outer_context(value, page, wiki, parsed, *, literal_region=False):
    if isinstance(value, dict) and value.get('selected_body') == 'current_get_literal':
        _, selected = current_get_literal_view(page, wiki)
        return selected
    generator = OUTER_CONTEXT_GENERATORS.get(value.get('profile')) if isinstance(value, dict) and isinstance(value.get('profile'), str) else None
    sd_ready = not literal_region and isinstance(value, dict) and selected_sd_ready_outer(wiki, page, value)
    if sd_ready:
        generator = 'MediaWiki 1.48.0-wmf.6'
    if (generator is None and literal_region and isinstance(value, dict) and
            value.get('profile') == 'mediawiki-vector-2022-1.48.0-wmf.5' and
            wiki == 'srwiktionary' and page['namespace_id'] == 0):
        generator = 'MediaWiki 1.48.0-wmf.5'
    # Default transport does not substitute roots. Explicit selection below
    # validates a whole GET view without rewriting either captured payload.
    expected_fields = {'profile', 'receipt', 'response'}
    if isinstance(value, dict) and 'selected_body' in value:
        expected_fields.add('selected_body')
    if isinstance(value, dict) and 'current_identity' in value:
        expected_fields.add('current_identity')
    if (not isinstance(value, dict) or set(value) != expected_fields or
            generator is None or
            any(not isinstance(value.get(key), str) or not 0 < len(value[key].encode()) <= MAX_RESPONSE
                for key in ('receipt', 'response'))):
        raise ValueError('Invalid observed outer context')
    response = value['response'].encode()
    if sd_ready and (digest(response) != '1cfa030fea7af31f853bd8db0e0eacbe281622153a6cff5f1b8a2457e5260364' or
                     digest(page['response'].encode()) != '32c709e458258145c504754bca7b57be427122677a9a1f9e5dc2e4b4f8775be1'):
        raise ValueError('Changed selected SD ready-Figure capture')
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
    if 'current_identity' in value:
        headers = source.get('headers')
        if (not isinstance(source.get('source_path'), str) or not source['source_path'] or len(source['source_path']) > 4096 or
                not isinstance(headers, dict) or not isinstance(headers.get('content-type'), str) or
                headers['content-type'].split(';')[0].strip().lower() != 'text/html'):
            raise ValueError('Invalid current outer-context capture provenance')
        validate_current_outer_identity(value['current_identity'], page, wiki, response, url, value['profile'])
    else:
        selected = urllib.parse.urlsplit(url)
        origin = wiki[:-len('wiktionary')].replace('_', '-') + '.wiktionary.org'
        pairs = urllib.parse.parse_qsl(selected.query, keep_blank_values=True, strict_parsing=True,
                                      encoding='utf-8', errors='strict')
        expected = {'title': page['title'], 'oldid': str(page['revision_id']), 'useskin': 'vector-2022'}
        # source_path is the capture's local provenance label; the URL binds the page.
        headers = source.get('headers')
        if (selected.scheme != 'https' or selected.netloc != origin or selected.path != '/w/index.php' or
                selected.fragment or len(pairs) != len(expected) or dict(pairs) != expected or
                re.search(r'%(?![0-9a-fA-F]{2})', selected.query) or
                not isinstance(source.get('source_path'), str) or not source['source_path'] or len(source['source_path']) > 4096 or
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
    if (full['generator'][0][1].get('content') != generator or
            head['generator'][0][1].get('content') != generator or
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
    if sd_ready and any(tags[key][0][1].get('lang') != 'sd' or tags[key][0][1].get('dir') != 'rtl'
                        for tags, key in ((full, 'html'), (full, 'root'), (head, 'html'), (body, 'root'))):
        raise ValueError('Selected SD ready-Figure context requires its retained RTL root')
    if 'selected_body' in value and not literal_region:
        return selected_full_get_view(value, page, parsed, sd_ready=sd_ready)
    # Native Book additionally proves the exact prefix, six middle wrappers and
    # allowed HTML class difference before deriving any ancestor absence fact.


FIGURE_ASSET_BODIES = (b'<?xml version="1.0" encoding="UTF-8"?>\n<svg xmlns="http://www.w3.org/2000/svg" width="15" height="11" viewBox="0 0 11 15">\n\t<g id="magnify-clip" fill="#fff" stroke="#000">\n\t\t<path id="bigbox" d="M1.509 1.865h10.99v7.919H1.509z"/>\n\t\t<path id="smallbox" d="M-1.499 6.868h5.943v4.904h-5.943z"/>\n\t</g>\n</svg>\n', b'<?xml version="1.0" encoding="UTF-8"?>\n<svg xmlns="http://www.w3.org/2000/svg" width="15" height="11" viewBox="0 0 11 15">\n\t<g id="magnify-clip" fill="#fff" stroke="#000">\n\t\t<path id="bigbox" d="M9.491 1.865h-10.99v7.919h10.99z"/>\n\t\t<path id="smallbox" d="M12.499 6.868H6.556v4.904h5.943z"/>\n\t</g>\n</svg>\n')

def figure_asset_get_head_urls(html, sources, wiki):
    class Head(HTMLParser):
        def __init__(self):
            super().__init__(convert_charrefs=True)
            self.opened = self.closed = False
            self.urls = []

        def handle_starttag(self, tag, attrs):
            if self.closed:
                return
            values = dict(attrs)
            if tag in ('head', 'link', 'base') and (len(values) != len(attrs) or any(v is None for v in values.values())):
                raise ValueError('Ambiguous asset head attributes')
            if tag == 'head':
                if self.opened:
                    raise ValueError('Repeated asset stylesheet head')
                self.opened = True
            elif tag == 'body':
                raise ValueError('Incomplete asset stylesheet head')
            if tag == 'style' or (tag == 'base' and 'href' in values):
                raise ValueError('Unbound asset head style or BASE')
            if tag == 'link' and 'stylesheet' in values.get('rel', '').lower().split():
                if (not self.opened or len(values) != len(attrs) or set(values) != {'rel', 'href'} or
                        values['rel'].lower().split() != ['stylesheet'] or len(self.urls) == 16):
                    raise ValueError('Invalid asset stylesheet link')
                origin = 'https://' + wiki[:-len('wiktionary')].replace('_', '-') + '.wiktionary.org'
                href = values['href']
                url = origin + href if href.startswith('/w/') else href
                missing_style_url(url, wiki)
                if url not in sources or url in self.urls:
                    raise ValueError('Unbound or duplicate asset stylesheet')
                self.urls.append(url)

        def handle_endtag(self, tag):
            if tag == 'head':
                if not self.opened or self.closed:
                    raise ValueError('Invalid asset stylesheet head boundary')
                self.closed = True

        def handle_startendtag(self, tag, attrs):
            self.handle_starttag(tag, attrs)

    facts = Head(); facts.feed(html); facts.close()
    if not facts.opened or not facts.closed or not facts.urls:
        raise ValueError('Missing asset stylesheet head')
    return facts.urls


def validate_figure_style_assets(value, page, parsed, sources, wiki):
    if (not isinstance(value, dict) or set(value) != {'responses', 'receipt'} or
            not isinstance(page.get('figure_style_operations'), list) or
            not isinstance(page.get('page_styles'), dict) or page.get('text_class_scope') is not True or
            not isinstance(page.get('outer_context'), dict) or not isinstance(sources, dict) or
            not isinstance(value['responses'], list) or not 1 <= len(value['responses']) <= 8 or
            any(not isinstance(body, str) or len(body.encode()) > 4096 for body in value['responses']) or
            not isinstance(value['receipt'], str) or not 0 < len(value['receipt'].encode()) <= MAX_RESPONSE):
        raise ValueError('Invalid Figure artwork evidence')
    receipt = decode(value['receipt'])
    if (not isinstance(receipt, dict) or set(receipt) != {'core', 'css', 'source_fixture', 'sources'} or receipt['core'] is not None or
            not isinstance(receipt['css'], dict) or set(receipt['css']) != {'bytes', 'sha256'} or
            type(receipt['css']['bytes']) is not int or receipt['css']['bytes'] <= 0 or
            not isinstance(receipt['sources'], list) or len(receipt['sources']) != len(value['responses'])):
        raise ValueError('Invalid Figure artwork receipt')
    urls = validate_observed_style_head(parsed, sources, wiki)
    urls += figure_asset_get_head_urls(page['outer_context']['response'], sources, wiki)
    if not any(receipt['css'] == {'bytes': len(sources[url]), 'sha256': digest(sources[url])} for url in urls):
        raise ValueError('Figure artwork stylesheet is not emitted by this page')
    source_fixture = receipt['source_fixture']
    if (not isinstance(source_fixture, dict) or set(source_fixture) != {'bytes', 'sha256', 'path'} or
            type(source_fixture['bytes']) is not int or not 0 < source_fixture['bytes'] <= MAX_INPUT or
            not isinstance(source_fixture['path'], str) or not 0 < len(source_fixture['path'].encode()) <= 4096 or
            any(ord(c) < 32 or ord(c) == 127 for c in source_fixture['path']) or
            not isinstance(source_fixture['sha256'], str) or not re.fullmatch('[0-9a-f]{64}', source_fixture['sha256'])):
        raise ValueError('Invalid retained artwork acquisition provenance')
    origin = 'https://' + wiki[:-len('wiktionary')].replace('_', '-') + '.wiktionary.org'
    seen = set()
    for body, row in zip(value['responses'], receipt['sources']):
        if (not isinstance(row, dict) or set(row) != {'bytes', 'file', 'final_url', 'headers', 'retrieved_utc', 'sha256', 'source_path', 'status', 'url'} or
                type(row['bytes']) is not int or row['bytes'] <= 0 or type(row['status']) is not int or row['status'] != 200):
            raise ValueError('Invalid artwork response row')
        raw = body.encode(); descriptor(raw, row)
        path = row['source_path']; url = row['url']
        if (not isinstance(path, str) or not path.startswith('/w/resources/') or len(path.encode()) > 4096 or
                any(c in path for c in '#%\\\r\n\t') or '..' in path or any(ord(c) <= 32 or ord(c) == 127 for c in path) or
                url != origin + path or row['final_url'] != url or url in seen):
            raise ValueError('Invalid artwork request identity')
        seen.add(url)
        headers = row['headers']
        if (not isinstance(headers, dict) or not 1 <= len(headers) <= 64 or
                any(not isinstance(k, str) or not 0 < len(k.encode()) <= 256 or not isinstance(v, str) or len(v.encode()) > 16384 for k, v in headers.items()) or
                headers.get('content-type', '').split(';')[0].strip() != 'image/svg+xml' or
                not isinstance(row['file'], str) or not 0 < len(row['file'].encode()) <= 256 or any(c in row['file'] for c in '/\\\r\n\t') or
                not isinstance(row['retrieved_utc'], str) or not 20 <= len(row['retrieved_utc'].encode()) <= 80):
            raise ValueError('Invalid artwork response metadata')
        if raw not in FIGURE_ASSET_BODIES:
            raise ValueError('Unsupported exact Figure artwork body')


def validate_missing_figure_style_token(block, *, caption_bare_br=False):
    # Only structural packaging. Native proof additionally closes the whole
    # ordinary-emission domain, canonical collisions and every DOM candidate.
    structural = block.replace(b'<br>', b'') if caption_bare_br else block
    if (not block.startswith(b'[[') or not block.endswith(b']]') or
            any(token in structural for token in (b'{', b'}', b'<', b'>', b'\n', b'\r'))):
        raise ValueError('Missing Figure styles require a complete ordinary token')
    depth = 0
    last_pipe = None
    caption_brackets = 0
    caption_ambiguous = False
    at = 0
    while at < len(block):
        if block[at:at + 2] == b'[[':
            if caption_bare_br and last_pipe is not None:
                caption_brackets += 2
            depth += 1
            if depth > 16:
                raise ValueError('Missing Figure style nesting limit')
            at += 2
        elif block[at:at + 2] == b']]':
            if caption_bare_br and last_pipe is not None and depth > 1:
                caption_brackets -= 2
                caption_ambiguous = caption_ambiguous or caption_brackets < 0
            depth -= 1
            at += 2
            if depth < 0 or (depth == 0 and at != len(block)):
                raise ValueError('Missing Figure style token boundary')
        else:
            if caption_bare_br and block[at:at + 4] == b'<br>':
                if depth != 1 or caption_brackets != 0 or caption_ambiguous:
                    raise ValueError('Missing Figure BR must be in the outer caption')
            if (depth == 1 and block[at:at + 1] == b'|' and
                    (not caption_bare_br or caption_brackets == 0)):
                last_pipe = at
                caption_brackets = 0
                caption_ambiguous = False
            elif caption_bare_br and last_pipe is not None:
                if block[at:at + 1] == b'[':
                    caption_brackets += 1
                elif block[at:at + 1] == b']':
                    caption_brackets -= 1
                    caption_ambiguous = caption_ambiguous or caption_brackets < 0
            at += 1
    if depth != 0 or last_pipe is None or not block[last_pipe + 1:-2].strip():
        raise ValueError('Missing Figure styles require a complete caption')
    if caption_bare_br and b'<br>' in block[:last_pipe + 1]:
        raise ValueError('Missing Figure BR cannot occur in target or options')


def validate_authored_style_operations(value, source, page, sources, wiki):
    if (not isinstance(value, list) or not 1 <= len(value) <= 64 or
            page.get('text_class_scope') is not True or not isinstance(page.get('page_styles'), dict) or
            not isinstance(page.get('outer_context'), dict) or sources is None):
        raise ValueError('Authored element operations require independent complete page styles and context')
    previous_start, owners = -1, []
    for operation in value:
        if (not isinstance(operation, dict) or set(operation) != {'start', 'end'} or
                type(operation['start']) is not int or type(operation['end']) is not int or
                not previous_start < operation['start'] < operation['end'] <= len(source)):
            raise ValueError('Invalid authored element operation range')
        start, end = operation['start'], operation['end']
        previous_start = start
        token = source[start:end]
        paired = re.fullmatch(rb'<(div|span|abbr|sup|sub)\b[^<>]*>.*</\1\s*>', token, re.IGNORECASE | re.DOTALL)
        inline = paired is not None and paired[1].lower() in (b'abbr', b'sup', b'sub')
        if (b'\0' in token or (token not in (b'<hr>', b'<hr />') and paired is None) or
                (inline and any(byte in token for byte in (b'\n', b'\r', b'{', b'}', b'__')))):
            raise ValueError('Authored operation must be a complete supported element')
        while owners and start >= owners[-1][0]:
            owners.pop()
        if owners and (not inline or not owners[-1][1] or end > owners[-1][0]):
            raise ValueError('Only complete authored inline owners may nest')
        owners.append((end, inline))
    # This is packaging shape, not a source-to-DOM ordinal or a font grant.
    # Native Book closes each source body and every candidate under both heads;
    # native preflight additionally requires the complete inline census.
    figure_asset_get_head_urls(page['outer_context']['response'], sources, wiki)


def validate_ready_figure_style_token(block):
    # Packaging closes the source interval and a finite markup vocabulary.
    # Native Book still proves File identity, caption emission and correspondence.
    if (source_link_end(block, 0) != len(block) or
            any(token in block for token in (b'{{', b'}}', b'\n', b'\r', b'\0'))):
        raise ValueError('Figure styles require one complete ordinary File operation')
    at, last_pipe = 2, None
    while at < len(block) - 2:
        if block.startswith(b'[[', at):
            at = source_link_end(block, at)
        else:
            if block[at:at + 1] == b'|':
                last_pipe = at
            at += 1
    if last_pipe is None or not block[last_pipe + 1:-2].strip():
        raise ValueError('Figure styles require a complete caption')
    caption = block[last_pipe + 1:-2]
    if b'<' not in block and b'>' not in block and block.count(b'[[') == 1:
        return  # Preserve the existing simple-caption structural contract.
    if (len(caption) > 4096 or any(token in block for token in (b'{', b'}', b'&', b'\t', b'__')) or
            b'<' in block[:last_pipe] or b'>' in block[:last_pipe]):
        raise ValueError('Unsupported mixed Figure caption structure')
    stack, cursor, nodes = [], 0, 0
    tag = re.compile(rb'''<(?:(i|b|span)|br\s*/?|span\s+class=(?:"[A-Za-z0-9_ -]+"|'[A-Za-z0-9_ -]+')|/(i|b|span)\s*)>''')
    while cursor < len(caption):
        byte = caption[cursor:cursor + 1]
        if byte == b'>':
            raise ValueError('Unmatched Figure caption tag delimiter')
        if byte != b'<':
            cursor += 1
            continue
        found = tag.match(caption, cursor)
        if found is None:
            raise ValueError('Unsupported Figure caption tag or attributes')
        token = found[0]
        if found[2]:
            if not stack or stack.pop() != found[2]:
                raise ValueError('Unbalanced Figure caption markup')
        else:
            nodes += 1
            if nodes > 64:
                raise ValueError('Figure caption node limit')
            if not token.startswith(b'<br'):
                stack.append(found[1] or b'span')
                if len(stack) > 8:
                    raise ValueError('Figure caption nesting limit')
        cursor = found.end()
    if stack:
        raise ValueError('Incomplete Figure caption markup')


def validate_figure_style_operations(value, source, page, *, caption_bare_br=False):
    # Structural packaging only. Native Book must prove ordinary emission,
    # all candidate correspondence, closed DOM and both earned shell contexts.
    if (not isinstance(value, list) or not 1 <= len(value) <= 64 or
            page.get('text_class_scope') is not True or
            not isinstance(page.get('page_styles'), dict) or
            not isinstance(page.get('outer_context'), dict)):
        raise ValueError('Figure styles require explicit own page styles and context')
    previous = 0
    missing_kind = None
    for item in value:
        missing = isinstance(item, dict) and set(item) == {'start', 'end', 'media_kind'} and item['media_kind'] == 'missing'
        if (not isinstance(item, dict) or (set(item) != {'start', 'end'} and not missing) or
                type(item['start']) is not int or type(item['end']) is not int or
                not previous <= item['start'] < item['end'] <= len(source)):
            raise ValueError('Invalid Figure style operation range')
        if missing_kind is not None and missing_kind != missing:
            raise ValueError('Mixed Figure style operation families')
        missing_kind = missing
        block = source[item['start']:item['end']]
        try:
            block.decode('utf-8')
        except UnicodeDecodeError as error:
            raise ValueError('Figure style range splits UTF-8') from error
        if missing:
            validate_missing_figure_style_token(block, caption_bare_br=caption_bare_br)
            previous = item['end']
            continue
        if any(isinstance(known, dict) and known.get('missing_content') is True and
               known.get('start') == item['start'] and known.get('end') == item['end']
               for known in page.get('occurrences', [])):
            raise ValueError('Known Missing Figure operation requires its explicit media kind')
        validate_ready_figure_style_token(block)
        previous = item['end']


def validate_image_map_no_link(value, source, html):
    # Packaging checks only. Native Book additionally joins the normal localized
    # message and the complete ordered source-map/rendered-output census.
    if (not isinstance(value, dict) or set(value) != {'start', 'end'} or
            type(value['start']) is not int or type(value['end']) is not int or
            not 0 <= value['start'] < value['end'] <= len(source)):
        raise ValueError('Invalid ImageMap error occurrence range')
    block = source[value['start']:value['end']]
    if (not block.startswith(b'<imagemap>') or not block.endswith(b'</imagemap>') or
            source.count(block) != 1 or block.count(b'<imagemap>') != 1 or
            block.count(b'</imagemap>') != 1):
        raise ValueError('ImageMap error requires one complete original extension')
    body = block[len(b'<imagemap>'):-len(b'</imagemap>')]
    lines = [(index + 1, line.strip(b' \t\r')) for index, line in enumerate(body.split(b'\n'))
             if line.strip(b' \t\r') and not line.strip(b' \t\r').startswith(b'#')]
    if len(lines) < 2 or not re.fullmatch(rb'[^<>\[\]{}|]+\|[0-9]+(?:x[0-9]+)?px\|?', lines[0][1]):
        raise ValueError('ImageMap error header is outside the observed contract')
    if not re.match(rb'default[ \t]', lines[1][1]) or b'[' in lines[1][1]:
        raise ValueError('ImageMap error must retain first no-link command')
    class Errors(HTMLParser):
        def __init__(self):
            super().__init__(convert_charrefs=True)
            self.current = None
            self.values = []
        def handle_starttag(self, tag, attrs):
            if self.current is not None:
                raise ValueError('Nested markup inside observed error')
            if tag == 'p' and 'error' in dict(attrs).get('class', '').split():
                if attrs != [('class', 'error')]:
                    raise ValueError('Changed observed error attributes')
                self.current = []
        def handle_data(self, data):
            if self.current is not None:
                self.current.append(data)
        def handle_endtag(self, tag):
            if self.current is not None:
                if tag != 'p':
                    raise ValueError('Changed observed error closing tag')
                self.values.append(''.join(self.current))
                self.current = None
        def handle_comment(self, data):
            if self.current is not None:
                raise ValueError('Comment inside observed error')
    parser = Errors()
    parser.feed(html)
    parser.close()
    if parser.current is not None or len(parser.values) != 1 or not parser.values[0]:
        raise ValueError('Expected exactly one plain observed extension error')


def figure_block_png_header(body):
    # Match the native input domain; this proves framing/axes, not decoded pixels.
    if not isinstance(body, bytes) or not 57 <= len(body) <= MAX_RESPONSE or body[:8] != b'\x89PNG\r\n\x1a\n':
        raise ValueError('Invalid Figure block PNG envelope')
    at, chunks = 8, 0
    axes = None
    idat = ended_idat = palette = False
    while at < len(body):
        if len(body) - at < 12 or chunks == 4096:
            raise ValueError('Truncated or excessive Figure block PNG chunks')
        length = int.from_bytes(body[at:at + 4], 'big')
        if length > len(body) - at - 12:
            raise ValueError('Truncated Figure block PNG chunk')
        kind = body[at + 4:at + 8]
        data = body[at + 8:at + 8 + length]
        crc = int.from_bytes(body[at + 8 + length:at + 12 + length], 'big')
        if (not re.fullmatch(b'[A-Za-z]{4}', kind) or not 65 <= kind[2] <= 90 or
                zlib.crc32(body[at + 4:at + 8 + length]) != crc):
            raise ValueError('Invalid Figure block PNG chunk type or CRC')
        if kind == b'IHDR':
            if chunks != 0 or length != 13 or axes is not None:
                raise ValueError('Invalid Figure block PNG IHDR')
            width, height = int.from_bytes(data[:4], 'big'), int.from_bytes(data[4:8], 'big')
            if not 0 < width <= 0x7fffffff or not 0 < height <= 0x7fffffff or data[8:] != b'\x08\x06\x00\x00\x00':
                raise ValueError('Figure block PNG requires noninterlaced RGBA8 axes')
            axes = (width, height)
        elif axes is None:
            raise ValueError('Figure block PNG missing first IHDR')
        elif kind == b'IDAT':
            if ended_idat or length == 0:
                raise ValueError('Invalid Figure block PNG IDAT sequence')
            idat = True
        elif kind == b'IEND':
            if not idat or length != 0 or at + 12 != len(body):
                raise ValueError('Invalid Figure block PNG IEND')
            return dict(width=axes[0], height=axes[1], chunks=chunks + 1,
                        bit_depth=8, color_type=6, interlace=0,
                        validation='signature-ihdr-chunk-crc-iend', pixels_decoded=False)
        else:
            if idat:
                ended_idat = True
            if kind == b'PLTE':
                if palette or idat or not 0 < length <= 768 or length % 3:
                    raise ValueError('Invalid Figure block PNG palette')
                palette = True
            elif 65 <= kind[0] <= 90 or kind in (b'acTL', b'fcTL', b'fdAT'):
                raise ValueError('Unsupported critical or animated Figure block PNG chunk')
        at += length + 12
        chunks += 1
    raise ValueError('Figure block PNG missing IEND')


def validate_figure_block_renditions(value):
    def text(item, minimum, maximum):
        return isinstance(item, str) and minimum <= len(item.encode()) <= maximum

    def exact_int(item, expected):
        return type(item) is int and item == expected

    if (not isinstance(value, dict) or set(value) != {'receipt', 'responses_base64'} or
            not text(value['receipt'], 1, MAX_RESPONSE) or
            not isinstance(value['responses_base64'], list) or len(value['responses_base64']) != 2):
        raise ValueError('Invalid Figure block rendition envelope')
    receipt = decode(value['receipt'])
    if (not isinstance(receipt, dict) or set(receipt) != {'core', 'historical_equality_proven', 'unrequested', 'sources'} or
            receipt['core'] is not None or receipt['historical_equality_proven'] is not False or
            receipt['unrequested'] != [] or not isinstance(receipt['sources'], list) or len(receipt['sources']) != 2):
        raise ValueError('Invalid Figure block rendition receipt')
    keys = {'url', 'sha256', 'final_url', 'bytes', 'status', 'request_count', 'content_encoding',
            'accepted', 'response_complete', 'unknown_response_outcome', 'source_path', 'encoded',
            'file', 'retrieved_utc', 'accept_encoding', 'user_agent', 'headers', 'png_header'}
    results = []
    for encoded_body, row in zip(value['responses_base64'], receipt['sources']):
        if (not text(encoded_body, 1, MAX_RESPONSE * 4 // 3 + 4) or
                not isinstance(row, dict) or set(row) != keys):
            raise ValueError('Invalid Figure block rendition source')
        try:
            body = base64.b64decode(encoded_body, validate=True)
        except (ValueError, UnicodeError) as error:
            raise ValueError('Invalid Figure block rendition base64') from error
        if not 0 < len(body) <= MAX_RESPONSE:
            raise ValueError('Invalid Figure block rendition body size')
        url, sha = row['url'], row['sha256']
        if (not text(url, 1, 8192) or not isinstance(sha, str) or not re.fullmatch('[0-9a-f]{64}', sha) or
                not url.startswith('https://') or any(ord(c) <= 32 or ord(c) >= 127 or c in '\\#' for c in url)):
            raise ValueError('Invalid Figure block rendition identity')
        path_at = url.find('/', 8)
        host = url[8:path_at]
        if (path_at <= 8 or path_at + 1 == len(url) or not re.fullmatch('[A-Za-z0-9.-]+', host) or
                '.' not in host or host.startswith('.') or host.endswith('.') or
                row['final_url'] != url or row['source_path'] != url[path_at:] or digest(body) != sha or
                not exact_int(row['bytes'], len(body)) or not exact_int(row['status'], 200) or
                not exact_int(row['request_count'], 1) or row['content_encoding'] != 'identity' or
                row['accepted'] is not True or row['response_complete'] is not True or row['unknown_response_outcome'] is not False):
            raise ValueError('Changed Figure block rendition response identity')
        wire = row['encoded']
        if (not isinstance(wire, dict) or set(wire) != {'path', 'bytes', 'sha256'} or
                not exact_int(wire['bytes'], len(body)) or wire['sha256'] != sha or not text(wire['path'], 1, 4096) or
                not text(row['file'], 1, 256) or any(c in row['file'] for c in '/\\\r\n\t') or
                not text(row['retrieved_utc'], 20, 80) or row['accept_encoding'] not in ('identity', 'gzip') or
                not text(row['user_agent'], 1, 4096) or any(c in row['user_agent'] for c in '\r\n\0')):
            raise ValueError('Invalid Figure block rendition transport evidence')
        headers = row['headers']
        if (not isinstance(headers, dict) or not 1 <= len(headers) <= 64 or
                any(not text(k, 1, 256) or not text(v, 0, 16384) for k, v in headers.items()) or
                headers.get('content-type', '').split(';', 1)[0].strip(' \t') != 'image/png'):
            raise ValueError('Invalid Figure block rendition HTTP headers')
        actual = figure_block_png_header(body)
        header = row['png_header']
        if (not isinstance(header, dict) or set(header) != set(actual) or
                any(not exact_int(header[k], actual[k]) for k in ('width', 'height', 'chunks', 'bit_depth', 'color_type', 'interlace')) or
                header['validation'] != actual['validation'] or header['pixels_decoded'] is not False):
            raise ValueError('Changed Figure block rendition PNG header proof')
        results.append((url, sha, actual['width'], actual['height']))
    if (results[0][0] == results[1][0] or results[0][1] == results[1][1] or
            results[1][2:] != (2 * results[0][2], 2 * results[0][3])):
        raise ValueError('Figure block renditions require distinct exact 1x/2x axes')
    return results


def table_root_transport_receipt(value, responses, mime):
    if not isinstance(value, str) or not 0 < len(value.encode()) <= MAX_RESPONSE:
        raise ValueError('Invalid table root receipt text')
    receipt = decode(value)
    if (not isinstance(receipt, dict) or set(receipt) != {'core', 'sources', 'unrequested', 'historical_equality_proven'} or
            receipt['core'] is not None or receipt['unrequested'] != [] or receipt['historical_equality_proven'] is not False or
            not isinstance(receipt['sources'], list) or len(receipt['sources']) != len(responses)):
        raise ValueError('Invalid table root receipt')
    for source, response in zip(receipt['sources'], responses):
        if (not isinstance(source, dict) or source.get('accepted') is not True or source.get('response_complete') is not True or
                source.get('unknown_response_outcome') is not False or type(source.get('request_count')) is not int or source['request_count'] != 1 or
                type(source.get('status')) is not int or source['status'] != 200 or type(source.get('bytes')) is not int or
                not isinstance(source.get('url'), str) or source.get('final_url') != source['url'] or
                not isinstance(source.get('retrieved_utc'), str) or not source['retrieved_utc'] or not isinstance(source.get('headers'), dict)):
            raise ValueError('Incomplete table root transport')
        descriptor(response.encode(), source)
        types = [v for k, v in source['headers'].items() if k.lower() == 'content-type']
        if len(types) != 1 or not isinstance(types[0], str) or types[0].split(';')[0].strip().lower() != mime:
            raise ValueError('Wrong table root response MIME')
    return receipt


def table_root_opening_attributes(text, name):
    class Opening(HTMLParser):
        def __init__(self):
            super().__init__(convert_charrefs=True)
            self.attributes = None
        def handle_starttag(self, tag, attrs):
            if tag != name or self.attributes is not None or len(dict(attrs)) != len(attrs) or any(v is None for _, v in attrs):
                raise ValueError('Ambiguous table source attributes')
            self.attributes = dict(attrs)
        def handle_startendtag(self, tag, attrs):
            raise ValueError('Self-closing table source')
        def handle_endtag(self, tag):
            raise ValueError('Unexpected table source close')
        def handle_data(self, text):
            if text:
                raise ValueError('Unexpected table source text')
    parser = Opening()
    parser.feed(text)
    parser.close()
    if parser.attributes is None:
        raise ValueError('Missing table source attributes')
    return parser.attributes


def table_root_configuration(text, html_classes):
    # Exact non-selected prelude inventory from page_language_prefix.zig.
    marker = text.find('RLCONF=')
    if marker < 0: raise ValueError('Missing table configuration')
    if marker:
        hashes = {
            '4596a0a448783bdf5cd823d3b017520464502eba17da6e0277049df0c171bf39',
            '296e5797ae51141a36d124508c23b7e0aeb2cb5be620e060fc6eb5aceb39cc89',
            '4883bdb1c585b9440aa445aacdea8bdb5df146ca42bde57bd25862fffb71ed0f',
            'ff0406678d57587b7409bfba7f818a44a9ec8dd418eb27da4b32823b3e19ed0d',
            '50617cc2b928696b5f738520ed06f6814b186a4a6ddcadd9743d34abd74a8d5d',
            '1e6d52df99a5b900fc18cec459f5e77aee670a50858da0923389f6c308ac7c49',
            '1a3d0fcd4371047de9a485248822f83026e5d7361fb2e9ec9b547c0093bf1bb0',
            'f8b4a82d07b0c2847a010739493119441c8ce97437e68ba0dac16f921ee322a8',
            '932b9910c9e926e55516112a7ce9644909c06c20035d794b10947a5eec4e3f94',
            'e925dc8ae7861a33fd0b23132dbc9eeae57bba470d42e81320a4b43ed0a6a5e1'}
        if len(text[:marker].encode()) not in (952,956) or digest(text[:marker].encode()) not in hashes:
            raise ValueError('Unproved table configuration program')
        lead = '(function(){var className="'; finish = text.find('";var cookie=')
        if (not text.startswith(lead) or not isinstance(html_classes,str) or not html_classes.startswith('client-nojs ')
                or text[len(lead):finish] != 'client-js ' + html_classes[len('client-nojs '):]):
            raise ValueError('Table root class/program mismatch')
    start = marker + 7
    if text[start:start+1] != '{': raise ValueError('Non-object table configuration')
    stack = []; quoted = False; escaped = False; end = None
    for index in range(start,len(text)):
        char = text[index]
        if quoted:
            if escaped: escaped = False
            elif char == '\\': escaped = True
            elif char == '"': quoted = False
        elif char == '"': quoted = True
        elif char in '{[':
            stack.append(char)
            if len(stack)>32: raise ValueError('Table configuration exceeds native depth')
        elif char in '}]':
            if not stack or (stack.pop(),char) not in (('{','}'),('[',']')):
                raise ValueError('Unbalanced table configuration')
            if not stack: end=index+1; break
    if end is None or text[end:end+1] != ';' or 'RLCONF' in text[end+1:]:
        raise ValueError('Ambiguous table configuration')
    def unique(pairs):
        value = {}
        for key,item in pairs:
            if key in value: raise ValueError('Duplicate table configuration key')
            value[key] = item
        return value
    def reject_constant(token):
        raise ValueError('Nonstandard table configuration constant')
    value=json.loads(text[start:end],object_pairs_hook=unique,parse_constant=reject_constant)
    if not isinstance(value,dict): raise ValueError('Non-object table configuration')
    return value


def table_root_source_parent(source, start):
    # Conservative native-equivalent prefix custody, not a general HTML parser.
    prefix = source[:start].decode()
    def heading_boundaries():
        boundaries = set(); offset = 0
        # Scan each physical line once. A heading-looking line inside an open
        # construct cannot establish a block boundary for a later parent.
        for physical in prefix.split('\n'):
            raw = physical.encode(); cursor = 0; bold = italic = False
            while cursor < len(raw):
                if raw.startswith(b'[[', cursor):
                    cursor = source_link_end(raw, cursor); continue
                if raw.startswith(b':[', cursor) and cursor == 0:
                    marker = re.match(rb':\[[0-9]{1,9}\]:', raw)
                    if marker: cursor = marker.end(); continue
                if raw[cursor:cursor+1] in (b'[',b']',b'{',b'}',b'\0'): return boundaries
                if raw[cursor] == 39:
                    end = cursor + 1
                    while end < len(raw) and raw[end] == 39: end += 1
                    run = end - cursor
                    if run not in (1,2,3,5): return boundaries
                    if run in (2,5): italic = not italic
                    if run in (3,5): bold = not bold
                    cursor = end; continue
                cursor += 1
            if bold or italic: return boundaries
            offset += len(physical) + 1
            heading = re.fullmatch(r'(={1,6})([^=<>\[\]{}|\'\x00-\x1f]+)\1', physical)
            if heading and heading[2].strip(' '):
                boundaries.add(offset)
        return boundaries

    class SourcePrefix(HTMLParser):
        def __init__(self):
            super().__init__(convert_charrefs=True); self.stack = []; self.nodes = 0; self.offsets = [0]
            self.offsets += [i + 1 for i, ch in enumerate(prefix) if ch == '\n']
        def heading_boundaries(self):
            if not hasattr(self, 'boundaries'): self.boundaries = heading_boundaries()
            return self.boundaries
        def handle_starttag(self, tag, attrs):
            self.nodes += 1
            if tag not in {'span','ul','li','div','h3','sub'} or self.nodes > 16384 or len(self.stack) >= 128:
                raise ValueError('Unsupported table source prefix owner')
            opening = self.get_starttag_text(); line, col = self.getpos()
            at = self.offsets[line - 1] + col
            values = dict(attrs)
            if len(values) != len(attrs) or len(attrs) > 64 or any(value is None for _, value in attrs):
                raise ValueError('Ambiguous table source prefix attributes')
            line_start = self.offsets[line - 1]
            line_end = self.offsets[line] - 1 if line < len(self.offsets) else len(prefix)
            # Earlier heading markup is balanced on its own physical line; it
            # cannot contribute an active ancestor to the selected table.
            heading_div = (tag == 'div' and not self.stack and col == 1 and
                           re.fullmatch(r'=<div id="toc" class="toccolours" *>[^<>]+</div>=(?:__NOTOC__ __NOEDITSECTION__)?', prefix[line_start:line_end]))
            if tag == 'h3':
                if self.stack or col != 2 or not re.fullmatch(r'==<h3>[^<>]+</h3>==', prefix[line_start:line_end], re.I):
                    raise ValueError('Unproved closed HTML heading')
            if tag == 'sub' and (attrs or not re.compile(r'<sub>[^<>\[\]{}]+</sub>',re.I).match(prefix, at, line_end)):
                raise ValueError('Unproved subscript')
            if tag == 'div' and not heading_div:
                match = re.fullmatch(r"<div[ \t]+(align|style)[ \t]*=[ \t]*([\"'])(.*?)\2[ \t]*>", opening)
                if (match is None or (at and (at < 2 or prefix[at - 2:at] != '\n\n') and at not in self.heading_boundaries()) or self.stack):
                    raise ValueError('Unproved table source parent')
                key, value = match[1], match[3]
                if (not value or any(c in value for c in '{}[]<>|\r\n\0') or '__' in value
                        or (key == 'align' and value != 'center')):
                    raise ValueError('Invalid table source parent attribute')
                if key == 'style':
                    for raw in value.split(';'):
                        declaration = raw.strip(' ')
                        if not declaration: continue
                        if ':' not in declaration: raise ValueError('Nonliteral table source style')
                        prop, content = (part.strip(' ') for part in declaration.split(':', 1))
                        if re.fullmatch(r'[A-Za-z-]+', prop) is None or re.fullmatch(r'[A-Za-z0-9 #.,%+\-]+', content) is None:
                            raise ValueError('Nonliteral table source style')
                values = {key: html.unescape(value)}
            self.stack.append((tag, values, at + len(opening)))
        def handle_endtag(self, tag):
            if not self.stack or self.stack[-1][0] != tag:
                raise ValueError('Unbalanced table source prefix')
            self.stack.pop()
        def handle_startendtag(self, tag, attrs):
            raise ValueError('Self-closing table source prefix owner')
    parser = SourcePrefix(); parser.feed(prefix); parser.close()
    if not parser.stack: return None
    if len(parser.stack) != 1 or parser.stack[0][0] != 'div':
        raise ValueError('Foreign active table source owner')
    _, attrs, end = parser.stack[0]
    if prefix[end:].strip(' \t\r\n'):
        raise ValueError('Table source parent is not adjacent')
    return attrs


def validate_table_roots(roots, doc, defaults):
    # Structural packaging only. The native selector additionally proves the
    # complete source/observed parent graph and exact live expanded-source match.
    if (doc['schema'] not in ('wikidict.figure-page-observations.v8', 'wikidict.figure-page-observations.v11') or
            not isinstance(roots, list) or not 1 <= len(roots) <= 256 or len(roots) + len(doc['pages']) > 256):
        raise ValueError('Invalid independent table root capability')
    seen_ids, seen_titles = set(), set()
    fields = {'profile', 'namespace_id', 'page_id', 'revision_id', 'title', 'raw_sha256', 'source', 'source_table', 'observed_table', 'response', 'receipt', 'styles'}
    for root in roots:
        if (not isinstance(root, dict) or set(root) != fields or root['profile'] != 'canonical-current-root-table-v1' or
                type(root['namespace_id']) is not int or root['namespace_id'] != 0 or
                any(type(root[k]) is not int or not 0 < root[k] <= (1 << 64) - 1 for k in ('page_id', 'revision_id')) or
                not isinstance(root['title'], str) or not 0 < len(root['title'].encode()) <= 4096 or '\0' in root['title'] or
                not isinstance(root['raw_sha256'], str) or re.fullmatch('[0-9a-f]{64}', root['raw_sha256']) is None or
                any(not isinstance(root[k], str) or not 0 < len(root[k].encode()) <= MAX_RESPONSE or '\0' in root[k] for k in ('source', 'response'))):
            raise ValueError('Invalid table root identity')
        if root['page_id'] in seen_ids or root['title'] in seen_titles:
            raise ValueError('Duplicate table root identity')
        seen_ids.add(root['page_id']); seen_titles.add(root['title'])
        for field, content in (('source_table', root['source']), ('observed_table', root['response'])):
            interval = root[field]
            if (not isinstance(interval, dict) or set(interval) != {'start', 'end'} or
                    any(type(interval[k]) is not int for k in ('start', 'end')) or
                    not 0 <= interval['start'] < interval['end'] <= len(content.encode())):
                raise ValueError('Invalid table root interval')
            raw = content.encode()
            raw[:interval['start']].decode(); raw[interval['start']:interval['end']].decode()
        source = root['source'].encode(); start, end = root['source_table']['start'], root['source_table']['end']
        if ((start and source[start - 1:start] != b'\n') or source[start:start + 2] != b'{|' or source.find(b'\n', start) != end):
            raise ValueError('Table source interval is not one complete opening line')
        table_attrs = table_root_opening_attributes('<table ' + source[start + 2:end].decode() + '>', 'table')
        source_parent = table_root_source_parent(source, start)
        header_start = end + 1
        header_end = source.find(b'\n', header_start)
        header = source[header_start:header_end]
        if header == b'|-':
            header_start = header_end + 1
            header_end = source.find(b'\n', header_start)
            header = source[header_start:header_end]
        if header_end < 0 or not header.startswith(b'!') or header.startswith(b'!!') or b'|' not in header:
            raise ValueError('Missing literal table signature')
        attributes, label = header[1:].split(b'|', 1); label = label.strip(b' \t\r').decode()
        if not label or any(c in label for c in '<>&[]{}\r\n'):
            raise ValueError('Nonliteral table signature')
        header_attrs = table_root_opening_attributes('<th ' + attributes.decode() + '>', 'th')
        for span in ('colspan', 'rowspan'):
            if span in header_attrs and (re.fullmatch(r'[0-9]+', header_attrs[span]) is None or not 1 <= int(header_attrs[span]) <= 65535):
                raise ValueError('Invalid literal table header span')
        response = root['response']; raw = response.encode()
        receipt = table_root_transport_receipt(root['receipt'], [response], 'text/html')
        origin = 'https://' + doc['wiki'][:-len('wiktionary')].replace('_', '-') + '.wiktionary.org'
        url = origin + '/wiki/' + urllib.parse.quote(root['title'].replace(' ', '_'), safe='/:')
        if receipt['sources'][0]['url'] != url:
            raise ValueError('Table root is not its canonical URL')
        offsets = [0]
        for i, ch in enumerate(response):
            if ch == '\n': offsets.append(i + 1)
        class Context(HTMLParser):
            void = {'area', 'base', 'br', 'col', 'embed', 'hr', 'img', 'input', 'link', 'meta', 'param', 'source', 'track', 'wbr'}
            def __init__(self):
                super().__init__(convert_charrefs=True)
                self.path = []; self.script = None; self.configs = []; self.html_classes = None
                self.body_end = None; self.head_closed = False; self.root_count = 0; self.tables = []
                self.root_stack = []; self.root_closed = False; self.root_nodes = 0
                self.selected = None; self.header = None; self.header_text = ''; self.header_done = False; self.first_row = None; self.table_depth = None; self.tbody = False
            def position(self):
                line, col = self.getpos(); return offsets[line - 1] + col
            def handle_starttag(self, tag, attrs):
                values = dict(attrs)
                if len(values) != len(attrs): raise ValueError('Duplicate table context attributes')
                at = self.position()
                if tag == 'html':
                    if self.html_classes is not None or self.path: raise ValueError('Repeated table HTML')
                    self.html_classes = values.get('class', '')
                if tag == 'head' and (self.path != ['html'] or attrs or self.head_closed): raise ValueError('Invalid table HEAD')
                if tag == 'body':
                    if self.body_end is not None or not self.head_closed or self.path != ['html']: raise ValueError('Invalid table BODY')
                    self.body_end = at + len(self.get_starttag_text())
                if tag == 'script' and self.body_end is None:
                    self.script = (at + len(self.get_starttag_text()), attrs, self.path == ['html', 'head'])
                if self.body_end is None and tag not in self.void:
                    self.path.append(tag)
                    if len(self.path) > 128: raise ValueError('Table head exceeds bounds')
                if 'mw-parser-output' in (values.get('class') or '').split():
                    if tag != 'div' or self.body_end is None or self.root_count: raise ValueError('Invalid table parser root')
                    self.root_count += 1
                    self.root_stack.append((tag, values))
                elif self.root_stack and tag not in self.void:
                    self.root_stack.append((tag, values))
                if self.root_stack:
                    self.root_nodes += 1
                    if len(self.root_stack) > 128 or self.root_nodes > 16384: raise ValueError('Table body exceeds bounds')
                if tag == 'table':
                    if len(self.tables) == 256: raise ValueError('Too many table candidates')
                    location = len(response[:at].encode())
                    self.tables.append((location, values))
                    if location == root['observed_table']['start']:
                        if self.selected is not None or location + len(self.get_starttag_text().encode()) != root['observed_table']['end']: raise ValueError('Invalid observed table interval')
                        if len(self.root_stack) < 2 or self.root_stack[-1][0] != 'table': raise ValueError('Unproved table local parent')
                        # Generated section ancestors remain in the original response
                        # and the native CSS graph; this is only structural intake.
                        parents = self.root_stack[1:-1]
                        if parents and parents[-1][0] == 'div':
                            captured_parent = parents[-1][1]
                            if (source_parent is None or not set(captured_parent) <= set(source_parent) | {'about','typeof','id','data-mw'}
                                    or any(captured_parent.get(k) != v for k, v in source_parent.items())):
                                raise ValueError('Unsupported table local parent')
                            parents = parents[:-1]
                        elif source_parent is not None:
                            raise ValueError('Missing captured table source parent')
                        if len(parents) > 32: raise ValueError('Too many generated table section ancestors')
                        for parent_tag, parent_attrs in parents:
                            section_id = parent_attrs.get('data-mw-section-id') or ''
                            if (parent_tag != 'section' or set(parent_attrs) != {'data-mw-section-id', 'id', 'aria-labelledby'} or section_id == '-1'):
                                raise ValueError('Unproved generated table section ancestor')
                            current_literal_section(parent_attrs)
                        self.selected = values; self.table_depth = len(self.root_stack)
                if self.selected is not None and not self.header_done:
                    depth = len(self.root_stack)
                    if tag == 'table':
                        if depth != self.table_depth: raise ValueError('Nested table before literal signature')
                    elif tag == 'tbody':
                        if self.tbody or self.first_row is not None or depth != self.table_depth + 1:
                            raise ValueError('Unproved table row container')
                        self.tbody = True
                    elif tag == 'tr':
                        if self.first_row is not None or values or depth != self.table_depth + 1 + int(self.tbody):
                            raise ValueError('Unproved first table row')
                        self.first_row = values
                    elif tag == 'th':
                        if self.first_row is None or self.header is not None or depth != self.table_depth + 2 + int(self.tbody):
                            raise ValueError('Missing first-child literal table signature')
                        self.header = values
                    else:
                        raise ValueError('Nonliteral observed table header')
            def handle_startendtag(self, tag, attrs):
                if tag not in self.void: raise ValueError('Self-closing table container')
                self.handle_starttag(tag, attrs)
            def handle_endtag(self, tag):
                at = self.position()
                if tag == 'script' and self.script is not None:
                    begin, attrs, direct = self.script; self.script = None; text = response[begin:at]
                    marker = text.find('RLCONF=')
                    if marker >= 0:
                        if attrs or not direct: raise ValueError('Unproved table configuration script')
                        self.configs.append(table_root_configuration(text,self.html_classes))
                if self.body_end is None:
                    if not self.path or self.path[-1] != tag: raise ValueError('Unbalanced table head')
                    if tag == 'head': self.head_closed = True
                    self.path.pop()
                if tag == 'th' and self.header is not None and not self.header_done: self.header_done = True
                if self.root_stack:
                    if self.root_stack[-1][0] != tag: raise ValueError('Unbalanced table parser body')
                    self.root_stack.pop()
                    if not self.root_stack: self.root_closed = True
            def handle_data(self, text):
                if self.selected is not None and self.header is None and not self.header_done and text.strip(' \t\r\n'):
                    raise ValueError('Nonliteral content before first table header')
                if self.header is not None and not self.header_done: self.header_text += text
        context = Context(); context.feed(response); context.close()
        if (context.body_end is None or context.root_count != 1 or not context.root_closed or context.root_stack or len(context.configs) != 1 or
                sum(attrs == table_attrs for _, attrs in context.tables) != 1 or
                context.selected != table_attrs or not context.header_done or context.header != header_attrs or context.header_text.strip(' \t\r\n') != label):
            raise ValueError('Incomplete or mismatching table context')
        config = context.configs[0]
        if (any(type(config.get(k)) is not int or config[k] != v for k, v in (
                ('wgArticleId', root['page_id']), ('wgRevisionId', root['revision_id']), ('wgCurRevisionId', root['revision_id']), ('wgNamespaceNumber', 0))) or
                config.get('wgTitle') != root['title'] or config.get('wgPageName') != root['title'].replace(' ', '_') or
                config.get('wgAction') != 'view' or config.get('wgIsArticle') is not True):
            raise ValueError('Table current identity mismatch')
        styles = root['styles']
        if not isinstance(styles, dict) or set(styles) != {'responses', 'receipt'} or not isinstance(styles['responses'], list) or not 1 <= len(styles['responses']) <= 16 or any(not isinstance(x, str) or not 0 < len(x.encode()) <= MAX_RESPONSE or '\0' in x for x in styles['responses']):
            raise ValueError('Invalid table style resources')
        style_receipt = table_root_transport_receipt(styles['receipt'], styles['responses'], 'text/css')
        # The acquisition fields were checked above; this temporary view calls
        # the unchanged finite served-style validator and never replaces input.
        neutral = dict(core=None, sources=style_receipt['sources'])
        sources = validate_observed_missing_style_set(dict(profile=MISSING_OBSERVED_SET_PROFILE, defaults=defaults.decode(), served_set=dict(responses=styles['responses'], receipt=json.dumps(neutral))), defaults, doc['wiki'])
        selected = validate_observed_style_head({'headhtml': response[:context.body_end]}, sources, doc['wiki'])
        if selected != list(sources):
            raise ValueError('Table stylesheet resources differ from ordered head')


def validate_current_expanded_operations(operations, doc, defaults):
    """Package current GET witnesses without granting native source equivalence.

    The native Book additionally validates the full observed ancestor graph,
    Missing phase, unique intrinsic syntax and live prepared-source projection.
    This boundary authenticates transport, source identities and resource custody;
    it never changes an Unknown phase or borrows a sibling page's observation.
    """
    if (doc['schema'] != 'wikidict.figure-page-observations.v8' or
            not isinstance(operations, list) or not 1 <= len(operations) <= 256 or
            len(operations) + len(doc['pages']) + len(doc.get('table_roots', [])) > 256):
        raise ValueError('Invalid current expanded operation inventory')
    fields = {'transport', 'temporal_scope', 'historical_equality_proven', 'javascript_outcome_proven',
              'raw_source', 'expanded_source', 'display_title', 'missing_dependency_metadata',
              'start', 'end', 'captured_styles', 'indexed_sources'}
    transport_fields = {'profile', 'page', 'mode', 'response_kind', 'response', 'prefix', 'receipt', 'styles'}
    page_fields = {'id', 'revision', 'namespace', 'title', 'model', 'raw_sha256', 'expanded_sha256'}
    seen = set()
    for operation in operations:
        if (not isinstance(operation, dict) or set(operation) != fields or
                operation['temporal_scope'] != 'current_anonymous_associated_retained_source' or
                operation['historical_equality_proven'] is not False or operation['javascript_outcome_proven'] is not False):
            raise ValueError('Invalid current expanded operation scope')
        for key in ('raw_source', 'expanded_source', 'display_title', 'missing_dependency_metadata'):
            value = operation[key]
            if (not isinstance(value, str) or len(value.encode()) > MAX_RESPONSE or '\0' in value or
                    (key != 'display_title' and not value)):
                raise ValueError('Invalid expanded operation source')
        transport = operation['transport']
        if (not isinstance(transport, dict) or not transport_fields <= set(transport) or
                set(transport) - transport_fields - {'original_received_prefix', 'encoded_gzip_base64'} or
                transport.get('original_received_prefix') is not None or transport.get('encoded_gzip_base64') is not None or
                transport['profile'] != 'source-parent-direct-get-v1' or transport['mode'] != 'current-canonical' or
                transport['response_kind'] != 'complete-response' or transport['styles'] is not None):
            raise ValueError('Unsupported expanded operation transport')
        page = transport['page']
        if (not isinstance(page, dict) or set(page) != page_fields or
                any(type(page[k]) is not int or not 0 < page[k] < 1 << 64 for k in ('id', 'revision')) or
                type(page['namespace']) is not int or page['namespace'] != 0 or page['model'] != 'wikitext' or
                not isinstance(page['title'], str) or not 0 < len(page['title'].encode()) <= 4096 or
                any(c in page['title'] for c in '\0\r\n\t') or page['id'] in seen):
            raise ValueError('Invalid or duplicate expanded operation page')
        seen.add(page['id'])
        raw = operation['raw_source'].encode(); expanded = operation['expanded_source'].encode()
        if page['raw_sha256'] != digest(raw) or page['expanded_sha256'] != digest(expanded):
            raise ValueError('Expanded operation source digest differs')
        start, end = operation['start'], operation['end']
        if type(start) is not int or type(end) is not int or not 0 <= start < end <= len(expanded):
            raise ValueError('Invalid expanded operation byte range')
        # Preserve byte offsets; native syntax and uniqueness checks remain final.
        selected = expanded[start:end].decode()
        if not selected.startswith('<span ') or not selected.endswith('</span>'):
            raise ValueError('Expanded operation is not a complete span')
        phase = decode(operation['missing_dependency_metadata'])
        if (not isinstance(phase, dict) or phase.get('schema') != 'wikidict.missing-dependency-phase.v1' or
                phase.get('output_sha256') != digest(expanded) or
                phase.get('display_title_sha256') != digest(operation['display_title'].encode())):
            raise ValueError('Expanded operation phase differs')
        for key, size in (('output', len(expanded)), ('display_title', len(operation['display_title'].encode()))):
            section = phase.get(key)
            if (not isinstance(section, dict) or type(section.get('unknown')) is not bool or
                    not isinstance(section.get('ranges'), list)):
                raise ValueError('Invalid expanded operation Missing phase')
            for interval in section['ranges']:
                if (not isinstance(interval, dict) or type(interval.get('start')) is not int or
                        type(interval.get('end')) is not int or not 0 <= interval['start'] < interval['end'] <= size or
                        (key == 'output' and interval['start'] < end and interval['end'] > start)):
                    raise ValueError('Expanded operation overlaps a missing range')
        response, prefix = transport['response'], transport['prefix']
        if (not isinstance(response, str) or not 0 < len(response.encode()) <= MAX_RESPONSE or '\0' in response or
                not isinstance(prefix, str) or not 0 < len(prefix.encode()) <= 512 * 1024 or not response.startswith(prefix)):
            raise ValueError('Invalid expanded operation response prefix')
        receipt = table_root_transport_receipt(transport['receipt'], [response], 'text/html')
        source = receipt['sources'][0]
        origin = 'https://' + doc['wiki'][:-len('wiktionary')].replace('_', '-') + '.wiktionary.org'
        expected_url = origin + '/wiki/' + urllib.parse.quote(page['title'].replace(' ', '_'), safe='-._~/:')
        if source['url'] != expected_url:
            raise ValueError('Expanded operation uses a different canonical page')
        if (source.get('accept_encoding') != 'gzip' or source.get('content_encoding') != 'gzip' or
                source['headers'].get('content-encoding') != 'gzip' or not isinstance(source.get('encoded'), dict) or
                set(source['encoded']) != {'bytes', 'path', 'sha256'} or
                type(source['encoded']['bytes']) is not int or not 0 < source['encoded']['bytes'] <= 64 * 1024 * 1024 or
                not isinstance(source['encoded']['sha256'], str) or re.fullmatch('[0-9a-f]{64}', source['encoded']['sha256']) is None or
                not isinstance(source['encoded']['path'], str) or not source['encoded']['path']):
            raise ValueError('Incomplete expanded operation encoded custody')
        body_end = expanded_operation_prefix(prefix, page)
        styles = operation['captured_styles']
        if not isinstance(styles, dict) or set(styles) != {'responses', 'receipt'} or not isinstance(styles['receipt'], str):
            raise ValueError('Invalid expanded operation styles')
        style_receipt = decode(styles['receipt'])
        if (not isinstance(style_receipt, dict) or set(style_receipt) != {'core', 'sources', 'unrequested', 'historical_equality_proven'} or
                style_receipt['core'] is not None or style_receipt['unrequested'] != [] or
                style_receipt['historical_equality_proven'] is not False or not isinstance(style_receipt['sources'], list) or
                any(not isinstance(s, dict) or not isinstance(s.get('retrieved_utc'), str) or not s['retrieved_utc'] for s in style_receipt['sources'])):
            raise ValueError('Incomplete expanded operation style receipt')
        neutral = dict(core=None, sources=style_receipt['sources'])
        sources = validate_observed_missing_style_set(dict(profile=MISSING_OBSERVED_SET_PROFILE, defaults=defaults.decode(),
            served_set=dict(responses=styles['responses'], receipt=json.dumps(neutral))), defaults, doc['wiki'])
        if validate_observed_style_head({'headhtml': prefix[:body_end]}, sources, doc['wiki']) != list(sources):
            raise ValueError('Expanded operation advertised styles differ')
        indexed = operation['indexed_sources']
        if not isinstance(indexed, list) or not 1 <= len(indexed) <= 128:
            raise ValueError('Invalid indexed expanded operation styles')
        for item in indexed:
            if (not isinstance(item, dict) or set(item) != {'base_url', 'byte_start', 'css_sha256', 'unknown_applicability'} or
                    not isinstance(item['base_url'], str) or '\0' in item['base_url'] or
                    type(item['byte_start']) is not int or not 0 <= item['byte_start'] < 1 << 64 or
                    type(item['unknown_applicability']) is not bool or not isinstance(item['css_sha256'], str) or
                    re.fullmatch('[0-9a-f]{64}', item['css_sha256']) is None):
                raise ValueError('Invalid indexed expanded operation style identity')


def expanded_operation_prefix(prefix, page):
    """Check the literal current identity; native prefix policy is also required."""
    class Prefix(HTMLParser):
        void = {'area', 'base', 'br', 'col', 'embed', 'hr', 'img', 'input', 'link', 'meta', 'param', 'source', 'track', 'wbr'}
        def __init__(self):
            super().__init__(convert_charrefs=True)
            self.path = []; self.html_classes = None; self.head_closed = False
            self.script = None; self.configs = []; self.body_end = None
            self.offsets = [0] + [i + 1 for i, c in enumerate(prefix) if c == '\n']
        def position(self):
            line, column = self.getpos(); return self.offsets[line - 1] + column
        def handle_starttag(self, tag, attrs):
            # Navigation and the complete outer chain remain original bytes.
            # The native prefix parser proves that chain up to ParserOutput.
            if self.body_end is not None: return
            values = dict(attrs)
            if len(values) != len(attrs):
                raise ValueError('Ambiguous expanded operation prefix')
            if tag == 'html':
                if self.path or self.html_classes is not None: raise ValueError('Repeated expanded operation HTML')
                self.html_classes = values.get('class', '')
            elif tag == 'head':
                if self.path != ['html'] or attrs or self.head_closed: raise ValueError('Misplaced expanded operation HEAD')
            elif tag == 'body':
                if self.path != ['html'] or not self.head_closed: raise ValueError('Misplaced expanded operation BODY')
                self.body_end = self.position() + len(self.get_starttag_text())
                return
            elif not self.path: raise ValueError('Expanded operation element outside HTML')
            if tag == 'script': self.script = (self.position() + len(self.get_starttag_text()), attrs, self.path == ['html', 'head'])
            if tag not in self.void:
                self.path.append(tag)
                if len(self.path) > 128: raise ValueError('Expanded operation prefix exceeds bounds')
        def handle_startendtag(self, tag, attrs):
            if self.body_end is not None: return
            if tag not in self.void: raise ValueError('Self-closing expanded operation container')
            self.handle_starttag(tag, attrs)
        def handle_endtag(self, tag):
            if self.body_end is not None: return
            if not self.path or self.path[-1] != tag:
                raise ValueError('Unbalanced expanded operation prefix')
            if tag == 'script' and self.script is not None:
                start, attrs, direct = self.script; self.script = None; text = prefix[start:self.position()]
                if 'RLCONF=' in text:
                    if attrs or not direct: raise ValueError('Indirect expanded operation configuration')
                    self.configs.append(table_root_configuration(text, self.html_classes))
            if tag == 'head': self.head_closed = True
            self.path.pop()
    parsed = Prefix(); parsed.feed(prefix); parsed.close()
    if parsed.body_end is None or len(parsed.configs) != 1:
        raise ValueError('Incomplete expanded operation prefix')
    root = re.search(r'<div\b[^<>]*>\Z', prefix, re.I)
    if root is None or root.start() < parsed.body_end:
        raise ValueError('Expanded operation prefix lacks its parser root')
    attributes = table_root_opening_attributes(root[0], 'div')
    if 'mw-parser-output' not in attributes.get('class', '').split():
        raise ValueError('Expanded operation prefix ends at a different root')
    config = parsed.configs[0]
    if (any(type(config.get(k)) is not int or config[k] != v for k, v in (
            ('wgArticleId', page['id']), ('wgRevisionId', page['revision']), ('wgCurRevisionId', page['revision']), ('wgNamespaceNumber', 0))) or
            config.get('wgTitle') != page['title'] or config.get('wgPageName') != page['title'].replace(' ', '_') or
            config.get('wgAction') != 'view' or config.get('wgIsArticle') is not True):
        raise ValueError('Expanded operation current identity differs')
    return parsed.body_end


def validate_supplied_page(page, wiki):
    request, receipt, response = (decode(page[name]) for name in ('request', 'receipt', 'response'))
    form = page['form_body'].encode('ascii')
    if not 1 <= len(form) <= 262144 or re.search(rb'%(?![0-9a-fA-F]{2})', form):
        raise ValueError('Invalid observation form body')
    if any(len(page[name].encode()) > MAX_RESPONSE for name in ('request', 'receipt', 'response')):
        raise ValueError('Oversized embedded observation')
    descriptor(form, request['form'])
    descriptor(page['request'].encode(), receipt['request'])
    descriptor(page['response'].encode(), receipt['response'])
    endpoint = 'https://' + wiki[:-len('wiktionary')].replace('_', '-') + '.wiktionary.org/w/api.php'
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
    if (page.get('text_class_scope') is True or page.get('image_map_no_link') is not None) and page.get('missing_head_context') is None and page.get('authored_head_context') is None:
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
    if 'missing_head_context' in page:
        parsed = validate_missing_head_context(page, parsed, wiki, source)
    if 'authored_head_context' in page:
        parsed = validate_authored_head_context(page, parsed, wiki, source)
    return source, parsed


def validate_literal_regions(regions, served, doc, defaults):
    # The native Book also checks the selected DIV in both rendered trees,
    # the preceding TemplateStyles and the exact live Worker source bytes.
    if not isinstance(regions, list) or not 1 <= len(regions) <= 256:
        raise ValueError('Invalid literal region inventory')
    sheets = {} if served is None else validate_observed_missing_style_set({
        'profile': MISSING_OBSERVED_SET_PROFILE,
        'defaults': defaults.decode(),
        'served_set': served,
    }, defaults, doc['wiki'])
    ordered_urls = list(sheets)
    used = set()
    seen_ids, seen_titles = set(), set()
    for region in regions:
        if (not isinstance(region, dict) or
                set(region) - {'screen_sheets'} != {'page', 'source_start', 'source_bytes', 'source_sha256', 'rendered_sha256'}):
            raise ValueError('Invalid literal region record')
        page = region['page']
        if (not isinstance(page, dict) or set(page) != {
                'namespace_id', 'page_id', 'revision_id', 'title', 'raw_sha256',
                'request', 'form_body', 'receipt', 'response', 'text_class_scope', 'occurrences', 'outer_context'} or
                type(page['namespace_id']) is not int or type(page['page_id']) is not int or page['page_id'] <= 0 or
                type(page['revision_id']) is not int or page['revision_id'] <= 0 or
                not isinstance(page['title'], str) or not page['title'] or
                page['text_class_scope'] is not True or page['occurrences'] != [] or
                not isinstance(page['outer_context'], dict) or page['outer_context'].get('selected_body') != 'full_get_root' or
                'current_identity' in page['outer_context'] or
                not all(isinstance(page[key], str) for key in ('request', 'form_body', 'receipt', 'response', 'raw_sha256')) or
                not re.fullmatch('[0-9a-f]{64}', page['raw_sha256'])):
            raise ValueError('Invalid literal region page identity')
        title = page['namespace_id'], page['title']
        if page['page_id'] in seen_ids or title in seen_titles:
            raise ValueError('Duplicate literal region page')
        seen_ids.add(page['page_id'])
        seen_titles.add(title)
        source, parsed = validate_supplied_page(page, doc['wiki'])
        start, size = region['source_start'], region['source_bytes']
        if (type(start) is not int or type(size) is not int or not 1 <= size <= 65536 or
                not 0 <= start <= len(source) - size or
                not isinstance(region['rendered_sha256'], str) or not re.fullmatch('[0-9a-f]{64}', region['rendered_sha256'])):
            raise ValueError('Invalid literal region source range or rendered identity')
        literal = source[start:start + size]
        if (digest(literal) != region['source_sha256'] or source.count(literal) != 1 or
                re.match(br'<div(?:[ \t\r\n]|>)', literal, re.I) is None or re.search(br'</div\s*>$', literal, re.I) is None):
            raise ValueError('Literal region differs from its unique supplied source')
        outer = page['outer_context']
        validate_outer_context(outer, page, doc['wiki'], parsed, literal_region=True)
        if 'screen_sheets' not in region:
            continue
        bindings = region['screen_sheets']
        if not isinstance(bindings, dict) or set(bindings) != {'get', 'supplied'}:
            raise ValueError('Invalid literal region stylesheet bindings')
        heads = {
            'get': figure_asset_get_head_urls(outer['response'], sheets, doc['wiki']),
            'supplied': validate_observed_style_head(parsed, sheets, doc['wiki']),
        }
        for arm, emitted in heads.items():
            order = bindings[arm]
            if (not isinstance(order, list) or
                    any(type(index) is not int or not 0 <= index < len(ordered_urls) for index in order) or
                    [ordered_urls[index] for index in order] != emitted):
                raise ValueError('Literal region stylesheet order differs from its emitted head')
            used.update(order)
    if used != set(range(len(ordered_urls))):
        raise ValueError('Unused literal region stylesheet response')


def validate_document(raw, namespace, defaults):
    if not 0 < len(raw) <= MAX_INPUT:
        raise ValueError('Invalid observation document size')
    doc = decode(raw)
    relation_style_contract = doc.get('schema') == 'wikidict.figure-page-observations.v11'
    missing_operation_contract = doc.get('schema') == 'wikidict.figure-page-observations.v10'
    poster_svg_contract = missing_operation_contract or doc.get('schema') == 'wikidict.figure-page-observations.v9'
    image_map_contract = doc.get('schema') == 'wikidict.figure-page-observations.v8'
    combined_contract = relation_style_contract or image_map_contract or poster_svg_contract or doc.get('schema') == 'wikidict.figure-page-observations.v7'
    page_style_contract = combined_contract
    svg_language_contract = combined_contract or doc.get('schema') == 'wikidict.figure-page-observations.v6'
    paint_contract = doc.get('schema') == 'wikidict.figure-page-observations.v3'
    poster_contract = poster_svg_contract or doc.get('schema') == 'wikidict.figure-page-observations.v5'
    class_contract = combined_contract or poster_contract or doc.get('schema') == 'wikidict.figure-page-observations.v4'
    class_scope_contract = class_contract or svg_language_contract
    expected_fields = {'schema', 'wiki', 'date', 'namespace_sha256', 'defaults_sha256', 'pages'}
    if image_map_contract and 'literal_regions' in doc:
        expected_fields.add('literal_regions')
        if 'literal_screen_resources' in doc:
            expected_fields.add('literal_screen_resources')
    if image_map_contract and 'current_get_expanded_operations' in doc:
        expected_fields.add('current_get_expanded_operations')
    if (image_map_contract or relation_style_contract) and 'table_roots' in doc:
        expected_fields.add('table_roots')
    if poster_contract:
        expected_fields.add('static_poster_styles')
    if paint_contract or (class_contract and 'missing_link_styles' in doc):
        expected_fields.add('missing_link_styles')
    if (set(doc) != expected_fields or
            doc.get('schema') not in ('wikidict.figure-page-observations.v1', 'wikidict.figure-page-observations.v2', 'wikidict.figure-page-observations.v3', 'wikidict.figure-page-observations.v4', 'wikidict.figure-page-observations.v5', 'wikidict.figure-page-observations.v6', 'wikidict.figure-page-observations.v7', 'wikidict.figure-page-observations.v8', 'wikidict.figure-page-observations.v9', 'wikidict.figure-page-observations.v10', 'wikidict.figure-page-observations.v11') or
            not re.fullmatch('[a-z0-9_]+wiktionary', doc.get('wiki', '')) or
            not re.fullmatch('[0-9]{8}', doc.get('date', '')) or
            doc.get('namespace_sha256') != digest(namespace) or
            doc.get('defaults_sha256') != digest(defaults) or
            not isinstance(doc.get('pages'), list) or len(doc['pages']) > 256 or
            (not doc['pages'] and not doc.get('table_roots') and not doc.get('current_get_expanded_operations') and not doc.get('literal_regions'))):
        raise ValueError('Invalid observation document identity')
    if 'literal_regions' in doc:
        if 'literal_screen_resources' in doc and not isinstance(doc['literal_screen_resources'], dict):
            raise ValueError('Invalid literal region stylesheet resources')
        validate_literal_regions(doc['literal_regions'], doc.get('literal_screen_resources'), doc, defaults)
    if 'current_get_expanded_operations' in doc:
        validate_current_expanded_operations(doc['current_get_expanded_operations'], doc, defaults)
    if 'table_roots' in doc:
        validate_table_roots(doc['table_roots'], doc, defaults)
    observed_styles = None
    if paint_contract or (class_contract and doc.get('missing_link_styles') is not None):
        value = doc['missing_link_styles']
        if (isinstance(value, dict) and value.get('profile') == MISSING_OBSERVED_SET_PROFILE and
                not combined_contract and doc.get('schema') != 'wikidict.figure-page-observations.v4'):
            raise ValueError('Observed stylesheet set requires v4 context or explicit v7 conjunction')
        observed_styles = validate_missing_link_styles(value, defaults, doc['wiki'])
    if poster_contract:
        validate_static_poster_styles(doc['static_poster_styles'], defaults, doc['wiki'])
    seen_ids, seen_titles = set(), set()
    proved_poster, proved_svg_language, proved_missing_operation = False, False, False
    proved_relation, proved_style_operation = False, False
    for page in doc['pages']:
        current_literal = 'current_get_literal' in page
        page_fields = {'namespace_id', 'page_id', 'revision_id', 'title', 'raw_sha256', 'occurrences'}
        if current_literal:
            if not image_map_contract or doc.get('missing_link_styles') is not None:
                raise ValueError('Current GET literal requires its explicit v8 operation contract')
            page_fields.add('current_get_literal')
        else:
            page_fields.update({'request', 'form_body', 'receipt', 'response'})
        if image_map_contract and 'image_map_no_link' in page:
            page_fields.add('image_map_no_link')
        if (relation_style_contract or image_map_contract or missing_operation_contract) and 'figure_style_operations' in page:
            page_fields.add('figure_style_operations')
        if image_map_contract and 'figure_block_renditions' in page:
            page_fields.add('figure_block_renditions')
        if image_map_contract and 'figure_style_assets' in page:
            page_fields.add('figure_style_assets')
        if image_map_contract and 'authored_style_operations' in page:
            page_fields.add('authored_style_operations')
        if image_map_contract and 'authored_head_context' in page:
            page_fields.add('authored_head_context')
        if class_scope_contract and 'text_class_scope' in page:
            page_fields.add('text_class_scope')
        if 'outer_context' in page:
            page_fields.add('outer_context')
        if class_scope_contract and 'missing_head_context' in page:
            page_fields.add('missing_head_context')
        if page_style_contract and 'page_styles' in page:
            page_fields.add('page_styles')
        if (combined_contract or doc.get('schema') == 'wikidict.figure-page-observations.v4') and 'missing_served_set' in page:
            page_fields.add('missing_served_set')
        if 'source_element_relations' in page:
            if (not relation_style_contract and doc.get('schema') != 'wikidict.figure-page-observations.v4' or
                    type(page['source_element_relations']) is not bool):
                raise ValueError('Source element relations require an explicit v4/v11 boolean')
            page_fields.add('source_element_relations')
            proved_relation = proved_relation or page['source_element_relations'] is True
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
        if current_literal:
            source, parsed = current_get_literal_view(page, doc['wiki'])
        else:
            source, parsed = validate_supplied_page(page, doc['wiki'])
        # Authored-only context carries its own page styles, never the inherited Missing paint policy.
        page_styles = None if 'authored_head_context' in page else page_missing_style_set(doc, page, defaults, observed_styles)
        if page.get('outer_context') is not None:
            if not class_scope_contract or text_scope is not True:
                raise ValueError('Outer context requires an admitted text class scope')
            selected_view = None if current_literal else validate_outer_context(page['outer_context'], page, doc['wiki'], parsed)
            if selected_view is not None:
                parsed = selected_view
            if page_styles is not None:
                validate_missing_style_head(parsed, page_styles, doc['wiki'])
        if page_style_contract and 'page_styles' in page:
            if (text_scope is not True or page.get('outer_context') is None or
                    not isinstance(page.get('page_styles'), dict) or
                    set(page['page_styles']) != {'responses', 'receipt'}):
                raise ValueError('Page styles require an exact source and outer context')
            selected_styles = validate_observed_missing_style_set({
                'profile': MISSING_OBSERVED_SET_PROFILE, 'defaults': defaults.decode(),
                'served_set': current_literal_style_view(page) if current_literal else page['page_styles'],
            }, defaults, doc['wiki'])
            # This uses only the common receipt/URL/head checks. No Missing
            # module policy or implicit media/paint callback is issued by v7.
            validate_observed_style_head(parsed, selected_styles, doc['wiki'])
        if 'figure_style_operations' in page:
            if missing_operation_contract:
                known_occurrences = page.get('occurrences')
                if not isinstance(known_occurrences, list):
                    raise ValueError('V10 operation requires a known Missing occurrence list')
            validate_figure_style_operations(page['figure_style_operations'], source, page, caption_bare_br=relation_style_contract)
            proved_style_operation = True
            if missing_operation_contract:
                for operation in page['figure_style_operations']:
                    matches = [known for known in known_occurrences if isinstance(known, dict) and
                               known.get('start') == operation['start'] and known.get('end') == operation['end']]
                    if (operation.get('media_kind') != 'missing' or len(matches) != 1 or
                            matches[0].get('missing_content') is not True):
                        raise ValueError('V10 operation requires its explicit known Missing occurrence')
                proved_missing_operation = True
        if 'authored_style_operations' in page:
            validate_authored_style_operations(page['authored_style_operations'], source, page, selected_styles if 'page_styles' in page else None, doc['wiki'])
        if 'figure_block_renditions' in page:
            validate_figure_block_renditions(page['figure_block_renditions'])
        if 'figure_style_assets' in page:
            validate_figure_style_assets(page['figure_style_assets'], page, parsed, selected_styles if 'page_styles' in page else None, doc['wiki'])
        occurrences = page.get('occurrences')
        if page.get('image_map_no_link') is not None:
            validate_image_map_no_link(page['image_map_no_link'], source, parsed['text'])
        minimum_occurrences = 0 if (page_style_contract and page.get('page_styles') is not None) or page.get('image_map_no_link') is not None else 1
        if not isinstance(occurrences, list) or not minimum_occurrences <= len(occurrences) <= 64:
            raise ValueError('Invalid selected occurrence count')
        files, intervals = set(), []
        for item in occurrences:
            missing = item.get('missing_content') is True
            poster = item.get('static_poster', False)
            language_fields = set(item) & {'svg_language', 'resolved_svg_language'}
            svg_language = item.get('svg_language', item.get('resolved_svg_language'))
            explicit_svg_width = (poster_svg_contract and language_fields == {'svg_language'} and item.get('width') is True)
            if language_fields:
                # Native Book additionally proves the language-bearing raster
                # URL, exact source options, logical axes and Registry model.
                if (len(language_fields) != 1 or not svg_language_contract or not isinstance(svg_language, str) or
                        not re.fullmatch('[a-z]+(?:-[a-z]+)*', svg_language) or
                        missing or poster or (item.get('width') and not explicit_svg_width) or
                        item.get('height', False) or item.get('anchor_attributes')):
                    raise ValueError('Invalid SVG language occurrence contract')
            image_fields = {'start', 'end', 'canonical_file', 'file_sha1', 'file_timestamp', 'original_width', 'original_height', 'width', 'anchor_attributes'}
            missing_fields = {'start', 'end', 'canonical_file', 'missing_content'}
            if (type(item.get('start')) is not int or type(item.get('end')) is not int or
                    not 0 <= item['start'] < item['end'] <= len(source) or
                    not isinstance(item.get('canonical_file'), str) or not item['canonical_file']):
                raise ValueError('Invalid selected occurrence range or file')
            if source_link_end(source, item['start']) != item['end']:
                raise ValueError('Selected occurrence is not one complete source link')
            if explicit_svg_width and source_svg_authored_width(source, item['start'], item['end']) is None:
                raise ValueError('Explicit SVG language requires an authored positive width')
            if missing:
                # This packages retained occurrence evidence only. The native
                # Book must separately validate Registry missing=true and HTML.
                if doc['schema'] not in ('wikidict.figure-page-observations.v2', 'wikidict.figure-page-observations.v3', 'wikidict.figure-page-observations.v4', 'wikidict.figure-page-observations.v5', 'wikidict.figure-page-observations.v7', 'wikidict.figure-page-observations.v8', 'wikidict.figure-page-observations.v9', 'wikidict.figure-page-observations.v10', 'wikidict.figure-page-observations.v11') or set(item) != missing_fields:
                    raise ValueError('Invalid missing occurrence contract')
            elif (set(item) != (image_fields | (language_fields if svg_language_contract else set()) |
                                  ({'height'} if 'height' in item else set()) |
                                  ({'static_poster'} if poster_contract and 'static_poster' in item else set()) |
                                  ({'missing_content'} if poster_contract and poster is True and item.get('missing_content') is False else set())) or
                    type(poster) is not bool or
                    (poster and (not poster_contract or not text_scope or page['namespace_id'] != 0 or
                                 page.get('outer_context') is None or
                                 page['outer_context'].get('profile') != 'mediawiki-vector-2022-1.48.0-wmf.4' or
                                 item.get('width') or item.get('anchor_attributes') or item.get('height', False))) or
                    type(item.get('height', False)) is not bool or
                    (item.get('height', False) and (item.get('width') or item.get('anchor_attributes'))) or
                    type(item.get('width')) is not bool or type(item.get('anchor_attributes')) is not bool or
                    not (item['width'] or item['anchor_attributes'] or item.get('height', False) or poster or svg_language is not None) or
                    not re.fullmatch('[0-9a-f]{40}', item.get('file_sha1', '')) or
                    not isinstance(item.get('file_timestamp'), str) or not item['file_timestamp'] or
                    type(item.get('original_width')) is not int or type(item.get('original_height')) is not int or
                    not 1 <= item['original_width'] <= 4294967295 or not 1 <= item['original_height'] <= 4294967295):
                raise ValueError('Invalid selected image occurrence identity')
            interval = item['start'], item['end']
            if item['canonical_file'] in files or any(a < interval[1] and interval[0] < b for a, b in intervals):
                raise ValueError('Duplicate or overlapping selected occurrence')
            files.add(item['canonical_file']); intervals.append(interval)
            proved_poster = proved_poster or poster
            proved_svg_language = proved_svg_language or svg_language is not None
    if poster_svg_contract and not (proved_poster and proved_svg_language):
        raise ValueError('Poster/SVG conjunction requires both independently validated occurrence kinds')
    if missing_operation_contract and not proved_missing_operation:
        raise ValueError('V10 conjunction requires an independently validated Missing operation')
    if relation_style_contract and not (proved_relation and proved_style_operation):
        raise ValueError('V11 conjunction requires validated source relations and own-page Figure operations')
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


def observation_source_contract(doc):
    contracts = []
    if doc.get('current_get_expanded_operations'):
        contracts.append('Independent current-anonymous expanded-operation witnesses; retained Unknown and source hashes; native Book must validate live source, ancestor and style custody; no historical or JavaScript equivalence')
    if any('current_get_literal' not in page for page in doc['pages']):
        contracts.append('Exact supplied full expansion/current parse; requested revision context; no parse-core or historical-transclusion inference')
    if any('current_get_literal' in page for page in doc['pages']):
        contracts.append('Canonical-current literal occurrence observations from authenticated full GETs; exact raw/expanded literal and selected frame; no supplied-parse response or full-expansion equivalence claimed')
    if doc.get('literal_regions'):
        contracts.append('Paired oldid and supplied literal region captures with ordered stylesheet receipts; native Book validates exact rooted source, rendered regions and live Writer custody')
    if doc.get('table_roots'):
        contracts.append('Independent canonical-current table roots with retained source; exact live source selection remains required by the native consumer; no supplied-parse response or current-expansion equivalence claimed for table roots')
    return ' | '.join(contracts)


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
                  source_contract=observation_source_contract(doc))
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
