"""Compare simple source definitions to their compiled language and ordered definition blocks."""
import bz2
from bisect import bisect_left
from collections import defaultdict
import hashlib
import json
import re
import sqlite3
import xml.etree.ElementTree as ET


HEADING = re.compile(r'==\s*([^=\[\]{}<>|]+?)\s*==')
LINK = re.compile(r'\[\[([^|#:\[\]{}<>_&]+?)(?:\|([^|\[\]{}<>_&]+?))?\]\]')
PLAIN = re.compile(r"[^\[\]{}<>|&#=]+")
BARE_URL = re.compile(r'https?://[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+(?:/[A-Za-z0-9_./~-]*)?')


def simple_line(source, title):
    """Return visible prose and the code-point range of each authored link."""
    if BARE_URL.fullmatch(source) and not source.endswith('.'):
        return source, ((0, len(source), source, 'external'),)
    parts, links = [], []
    end = offset = 0
    for match in LINK.finditer(source):
        literal = source[end:match.start()]
        if literal and ("''" in literal or not PLAIN.fullmatch(literal)):
            return None
        target, label = match[1], match[2] or match[1]
        if (target.strip() != target or target.casefold() == title.casefold() or "''" in label
                or (match.end() < len(source) and source[match.end()].isalpha())):
            # A self-link may lose its action. Link trails depend on the edition.
            return None
        parts.extend((literal, label))
        offset += len(literal)
        links.append((offset, offset + len(label), target))
        offset += len(label)
        end = match.end()
    tail = source[end:]
    if tail and ("''" in tail or not PLAIN.fullmatch(tail)):
        return None
    parts.append(tail)
    text = ''.join(parts)
    return (text, tuple(links)) if links or any(c.isalpha() for c in text) else None


def compiled_line(spans):
    parts, links = [], []
    offset = 0
    for span in spans:
        if span['kind'] not in ('text', 'link', 'external_link') or any(span.get(key) is not None for key in (
                'inline_action_group', 'inline_padding_group', 'inline_box_group', 'ruby', 'image')):
            return None
        text = span['text'] + span.get('trail', '')
        if span['kind'] == 'link':
            if span.get('target_fragment') or span.get('trail'):
                return None
            links.append((offset, offset + len(text), span['target']))
        elif span['kind'] == 'external_link':
            if span.get('trail') or text != span.get('target') or not BARE_URL.fullmatch(text):
                return None
            links.append((offset, offset + len(text), span['target'], 'external'))
        parts.append(text)
        offset += len(text)
    text = ''.join(parts)
    leading = len(text) - len(text.lstrip())
    return text.strip(), tuple((start - leading, end - leading, *action) for start, end, *action in links)


def source_line(source, title):
    plain = simple_line(source, title)
    if plain is not None:
        return (*plain, None)
    # One balanced emphasis pair outside link syntax. Links may be entirely
    # inside or outside the emphasis. Never interpret apostrophes in a target.
    parts = re.split(r"('{2,})", source)
    if len(parts) != 5:
        return None
    before, opening, marked, closing, after = parts
    if opening != closing or opening not in ("''", "'''") or not marked.strip():
        return None
    unmarked = before + marked + after
    plain = simple_line(unmarked, title)
    if plain is None:
        return None
    boundaries = [len(before), len(before) + len(marked)]
    display_offsets = boundaries.copy()
    for link in LINK.finditer(unmarked):
        for i, at in enumerate(boundaries):
            if link.start() < at < link.end():
                return None
            if link.end() <= at:
                display_offsets[i] -= len(link[0]) - len(link[2] or link[1])
    return (*plain, (*display_offsets, 'italic' if opening == "''" else 'bold'))


def compiled_emphasis(spans):
    """Return the single visible emphasis range, if this block has exactly one."""
    text = ''.join(span['text'] for span in spans)
    first = len(text) - len(text.lstrip())
    last = len(text.rstrip())
    offset = 0
    interval = None
    for span in spans:
        if span.get('trail'):
            return None
        start = max(offset, first)
        offset += len(span['text'])
        end = min(offset, last)
        if start >= end or not (span.get('bold') or span.get('italic')):
            continue
        if span.get('bold') and span.get('italic'):
            return None
        style = 'bold' if span.get('bold') else 'italic'
        if interval is None:
            interval = (start - first, end - first, style)
        elif interval[1:] == (start - first, style):
            interval = (interval[0], end - first, style)
        else:
            return None
    return interval


def definitions(text, title, headings):
    # Only inspect unambiguous source. Templates and protected or table text can
    # emit headings or consume later lines. Never assign those lines a language.
    lines = text.splitlines()
    if any(marker in text for marker in ('{{', '}}', '<', '>', '{|')):
        return
    if '__' in text and any('__' in line and not re.fullmatch(r'#[ \t]*_+[ \t]*', line) for line in lines):
        return
    owner = None
    for number, line in enumerate(lines, 1):
        if line.startswith('==') and not line.startswith('==='):
            heading = HEADING.fullmatch(line.rstrip())
            owner = heading[1] if heading and heading[1] in headings else None
        if not owner or not line.startswith('#'):
            continue
        body = line.lstrip('#')
        if body.startswith((':', '*', ';')):
            continue
        list_path = line[:len(line) - len(body)]
        witness = source_line(body.strip(), title)
        if witness is not None:
            yield owner, number, list_path, *witness


def localized_language_codes(raw):
    """Use exact primary MediaWiki labels only if no other code claims that spelling."""
    lines = raw.decode('utf-8').splitlines()
    if not lines or lines[0] != '# wikidict-language-registry-v2' or '# mediawiki' not in lines:
        raise ValueError('Expected a v2 language registry with MediaWiki names')
    claims = defaultdict(set)
    primary = {}
    mediawiki = False
    for line in lines[1:]:
        fields = line.split('\t')
        if line in ('# mediawiki', '# iso-639-3'):
            mediawiki = line == '# mediawiki'
        elif fields[0] == '# reviewed-alias' and len(fields) == 5:
            claims[fields[2]].add(fields[1])
        elif len(fields) >= 2 and not line.startswith('#'):
            for name in fields:
                claims[name].add(fields[0])
            if mediawiki:
                primary[fields[1]] = fields[0]
    return {name: code for name, code in primary.items() if name and claims[name] == {code}}


class SourceDefinitions:
    def __init__(self, database, root, dumps, registry=None):
        self.db = sqlite3.connect(database)
        try:
            self.db.execute('CREATE TABLE sense (title, owner, code, line, list_path, text, links, emphasis, page, revision, matched INTEGER DEFAULT 0)')
            self.db.execute('CREATE INDEX by_owner ON sense (title, owner, line)')
            manifest = json.loads((root / 'complete.json').read_bytes())
            headings = set((root / 'languages.tsv').read_text().splitlines()[1:])
            self.codes = {}
            self.registry_sha256 = None
            if registry is not None:
                raw = registry.read_bytes()
                self.registry_sha256 = hashlib.sha256(raw).hexdigest()
                if self.registry_sha256 != manifest['build_inputs'].get('auxiliary_snapshot_sha256', {}).get('language-registry'):
                    raise ValueError('Language registry differs from the selected build input')
                self.codes = localized_language_codes(raw)
                headings.update(self.codes)
            members = {name: (size, sha1) for wiki, date, name, size, sha1 in manifest['build_inputs']['files']
                       if wiki == manifest['edition'] and date == manifest['date']
                       and '-pages-meta-current' in name and re.search(r'\.xml(?:-p[0-9]+p[0-9]+)?\.bz2$', name)}
            if not members or len(dumps) != len(members) or {path.name for path in dumps} != members.keys():
                raise ValueError('Expected every selected XML dump member exactly once')
            self.inputs = {}
            for path in dumps:
                with path.open('rb') as raw:
                    size, expected = members[path.name]
                    if path.stat().st_size != size:
                        raise ValueError(f'Dump size differs: {path.name}')
                    digest = hashlib.sha1()

                    class CompressedInput:
                        def read(self, count=-1):
                            data = raw.read(count)
                            digest.update(data)
                            return data

                    with bz2.BZ2File(CompressedInput()) as xml:
                        self._read_pages(xml, headings)
                    if digest.hexdigest() != expected:
                        raise ValueError(f'Dump SHA-1 differs: {path.name}')
                    self.inputs[path.name] = expected
            self.db.commit()
            self.has_definitions = self.db.execute('SELECT 1 FROM sense LIMIT 1').fetchone() is not None
        except (ET.ParseError, EOFError, sqlite3.Error) as error:
            self.close()
            raise ValueError(f'Could not index source definitions: {error}') from error
        except BaseException:
            self.close()
            raise

    def _read_pages(self, xml, headings):
        events = ET.iterparse(xml, events=('start', 'end'))
        _, root = next(events)
        for event, page in events:
            if event != 'end' or page.tag.rsplit('}', 1)[-1] != 'page':
                continue
            if page.findtext('{*}ns') == '0' and page.find('{*}redirect') is None:
                title = page.findtext('{*}title')
                revision = page.find('{*}revision')
                if revision is None or not title:
                    raise ValueError('Main-namespace source page lacks a title or revision')
                self.db.executemany('INSERT INTO sense (title,owner,code,line,list_path,text,links,emphasis,page,revision) VALUES (?,?,?,?,?,?,?,?,?,?)',
                    ((title, owner, self.codes.get(owner), n, list_path, text, json.dumps(links, ensure_ascii=False), json.dumps(emphasis) if emphasis else None,
                      page.findtext('{*}id'), revision.findtext('{*}id'))
                     for owner, n, list_path, text, links, emphasis in definitions(revision.findtext('{*}text', ''), title, headings)))
            root.remove(page)

    def observe(self, entry):
        if entry['kind'] != 'language':
            return
        expected = self.db.execute('SELECT rowid,list_path,text,links,emphasis FROM sense WHERE title=? AND '
                                   '(code=? OR (code IS NULL AND owner=?)) ORDER BY line',
                                   (entry['title'], entry.get('language_code'), entry['language'])).fetchall()
        if not expected:
            return
        # Plain and directly linked senses must occupy a definition block in
        # order. A coincidental match in a translation or example cannot pass.
        positions = defaultdict(list)
        styled = any(row[-1] is not None for row in expected)
        position = 0
        for section in entry['sections']:
            for block in section['blocks']:
                if block['kind'] == 'definition':
                    list_path = block.get('list_path')
                    witness = compiled_line(block['spans'])
                    if witness is not None:
                        positions[(list_path, *witness, None)].append(position)
                        if styled and (emphasis := compiled_emphasis(block['spans'])) is not None:
                            positions[(list_path, *witness, emphasis)].append(position)
                    position += 1
        cursor = 0
        for rowid, list_path, text, links, emphasis in expected:
            actions = tuple(tuple(action) for action in json.loads(links))
            candidates = positions.get((list_path, text, actions, tuple(json.loads(emphasis)) if emphasis else None), ())
            index = bisect_left(candidates, cursor)
            if index < len(candidates):
                self.db.execute('UPDATE sense SET matched=1 WHERE rowid=?', (rowid,))
                cursor = candidates[index] + 1

    def report(self):
        count, matched = self.db.execute('SELECT count(*),coalesce(sum(matched),0) FROM sense').fetchone()
        missing = self.db.execute('SELECT title,owner,line,list_path,text,links,emphasis,page,revision FROM sense WHERE matched=0 ORDER BY rowid LIMIT 32')
        examples = []
        for title, owner, line, list_path, text, links, emphasis, page, revision in missing:
            actions = json.loads(links)
            target = actions[0][2] if len(actions) == 1 and actions[0][:2] == [0, len(text)] else None
            examples.append(dict(title=title, owner=owner, line=line, list_path=list_path, text=text, links=actions, emphasis=json.loads(emphasis) if emphasis else None, target=target, page=page, revision=revision))
        return dict(eligible=count, matched=matched, unmatched=count-matched, dump_sha1=self.inputs,
                    language_registry_sha256=self.registry_sha256,
                    has_source_evidence=count > 0,
                    examples=examples,
                    scope='Compare simple numbered lines under literal language headings on template-free pages to ordered definition blocks at their authored nesting depth. A single bold or italic run must occupy its exact source range. Where a verified registry supplies a unique primary name, require its code. Unmatched items need source review; numbered examples and related terms can be intentional.')

    def close(self):
        self.db.close()
