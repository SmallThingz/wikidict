"""Compare simple source definitions to their compiled language and ordered definition blocks."""
import bz2
from bisect import bisect_left
from collections import defaultdict
import hashlib
import json
import re
import sqlite3
import unicodedata
import xml.etree.ElementTree as ET


HEADING = re.compile(r'==\s*([^=\[\]{}<>|]+?)\s*==')
LINKED_HEADING = re.compile(r'==[ \t]*\[\[([^\[\]{}<>|#:_&=\'\n]+)\]\][ \t]*==')
STANDALONE_COMMENT = re.compile(r'^[ \t]*<!--([^<>\r\n]*)-->[ \t]*(?=\r?$)', re.MULTILINE)
LINK = re.compile(r'\[\[([^|:\[\]{}<>_&]+?)(?:\|([^|\[\]{}<>_&]+?))?\]\]')
PLAIN = re.compile(r"[^\[\]{}<>|&#=]+")
BARE_URL = re.compile(r'https?://[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+(?:/[A-Za-z0-9_./~-]*)?')
LABELED_URL = re.compile(r'\[(' + BARE_URL.pattern + r') ([^\[\]{}<>|&#=\n]+)\]')


def registry_link_trail(raw):
    """Read the same scalar, sequence and lookahead rules as the build-time tokenizer."""
    fields = {}
    for row in raw.decode('utf-8').splitlines():
        if row.startswith('# link-trail-'):
            key, separator, value = row[len('# link-trail-'):].partition('\t')
            if not separator or key not in ('ranges', 'sequences', 'not-double') or key in fields:
                raise ValueError('Invalid link-trail declaration')
            fields[key] = value
    if not fields:
        return None

    def scalar(value):
        if not re.fullmatch('[0-9A-Fa-f]{1,6}', value):
            raise ValueError('Invalid link-trail scalar')
        code = int(value, 16)
        if code > 0x10ffff or 0xd800 <= code <= 0xdfff:
            raise ValueError('Invalid link-trail scalar')
        return chr(code)

    sequences = []
    if 'sequences' in fields:
        for seq in fields['sequences'].split(','):
            chars = ''.join(scalar(value) for value in seq.split('+'))
            if len(chars) < 2:
                raise ValueError('Invalid link-trail sequence')
            sequences.append(chars)
    alternatives = [re.escape(seq) for seq in sorted(sequences, key=len, reverse=True)]
    intervals = []
    previous = -1
    ranges = fields.get('ranges', '0061-007A')
    for field in ranges.split(',') if ranges else ():
        start, dash, stop = field.partition('-')
        first, last = ord(scalar(start)), ord(scalar(stop if dash else start))
        if not previous < first <= last or (first <= 0xdfff and last >= 0xd800):
            raise ValueError('Invalid or overlapping link-trail range')
        intervals.append(re.escape(chr(first)) + '-' + re.escape(chr(last)))
        previous = last
    if intervals:
        alternatives.append('[' + ''.join(intervals) + ']')
    if 'not-double' in fields:
        guarded = [scalar(value) for value in fields['not-double'].split(',')]
        if len(guarded) != len(set(guarded)):
            raise ValueError('Duplicate guarded link-trail scalar')
        for char in guarded:
            token = re.escape(char)
            alternatives.append(token + '(?!' + token + ')')
    return re.compile('(?:' + '|'.join(alternatives) + ')+') if alternatives else re.compile('(?!)')


def simple_line(source, title, trail_rule=None, *, case_sensitive_titles=False):
    """Return visible prose and the code-point range of each authored link."""
    if '://' in source:
        if '[' in source:
            link = LABELED_URL.search(source)
            if link is None:
                return None
            before, after = source[:link.start()], source[link.end():]
            label = link[2]
            if (not label.strip() or label.strip() != label or '://' in label or
                    any("''" in part or '://' in part or (part and not PLAIN.fullmatch(part))
                        for part in (before, after)) or "''" in label):
                return None
            return before + label + after, ((len(before), len(before) + len(label), link[1], 'external'),)
        # This observer recognizes a terminal bare URL after simple prose. A
        # scheme elsewhere may have different delimiters or a bracketed label.
        url = BARE_URL.search(source)
        if url is None or url.end() != len(source) or source.endswith('.'):
            return None
        prefix = source[:url.start()]
        if prefix and (prefix[-1] not in ' .\t' or not PLAIN.fullmatch(prefix)
                       or "''" in prefix or '://' in prefix):
            return None
        return source, ((url.start(), url.end(), url[0], 'external'),)
    parts, links = [], []
    end = offset = 0
    for match in LINK.finditer(source):
        literal = source[end:match.start()]
        if literal and ("''" in literal or not PLAIN.fullmatch(literal)):
            return None
        target, label = match[1], match[2] or match[1]
        if '#' in target:
            page, _, fragment = target.partition('#')
            if (match[2] is None or not page or not fragment or '#' in fragment or
                    page.strip() != page or fragment.strip() != fragment):
                return None
        same_title = (unicodedata.normalize('NFC', target) == unicodedata.normalize('NFC', title)
                      if case_sensitive_titles else target.casefold() == title.casefold())
        if (target.strip() != target or same_title or "''" in label
                or (trail_rule is None and match.end() < len(source) and source[match.end()].isalpha())):
            # A self-link may lose its action. Link trails depend on the edition.
            return None
        parts.extend((literal, label))
        offset += len(literal)
        end = match.end()
        label_end = offset + len(label)
        trail = trail_rule.match(source, end) if trail_rule is not None else None
        if trail:
            if not PLAIN.fullmatch(trail[0]) or "''" in trail[0]:
                return None
            parts.append(trail[0])
            end = trail.end()
            links.append((offset, label_end + len(trail[0]), target, label_end))
            offset = label_end + len(trail[0])
        else:
            links.append((offset, label_end, target))
            offset = label_end
    tail = source[end:]
    if tail and ("''" in tail or not PLAIN.fullmatch(tail)):
        return None
    parts.append(tail)
    text = ''.join(parts)
    return (text, tuple(links)) if links or any(c.isalpha() for c in text) else None


def edge_padding(spans, *, leading):
    # Source lines discard unmarked whitespace around the body. Whitespace in
    # an explicit link label or emphasis run still belongs to its authored range.
    padding = 0
    for span in spans if leading else reversed(spans):
        if span.get('kind', 'text') != 'text' or span.get('bold') or span.get('italic'):
            break
        text = span['text'] + span.get('trail', '')
        body = text.lstrip() if leading else text.rstrip()
        padding += len(text) - len(body)
        if body:
            break
    return padding


def compiled_line(spans):
    parts, links = [], []
    offset = 0
    for span in spans:
        if span['kind'] not in ('text', 'link', 'external_link') or any(span.get(key) is not None for key in (
                'inline_action_group', 'inline_padding_group', 'inline_box_group', 'clipped_absolute', 'ruby', 'image')):
            return None
        text = span['text'] + span.get('trail', '')
        if span['kind'] == 'link':
            if span.get('trail'):
                return None
            target = span['target']
            fragment = span.get('target_fragment')
            if fragment is not None:
                # Older Reader exports store the same destination as page#section.
                if not isinstance(fragment, str) or '#' in target:
                    return None
                target += '#' + fragment
            links.append((offset, offset + len(text), target))
        elif span['kind'] == 'external_link':
            target = span.get('target') or ''
            if (span.get('trail') or not text or not BARE_URL.fullmatch(target) or
                    ('://' in text and text != target)):
                return None
            links.append((offset, offset + len(text), target, 'external'))
        parts.append(text)
        offset += len(text)
    text = ''.join(parts)
    leading = edge_padding(spans, leading=True)
    end = len(text) - edge_padding(spans, leading=False)
    return text[leading:end], tuple((start - leading, stop - leading, *action) for start, stop, *action in links)


def source_line(source, title, trail_rule=None, *, case_sensitive_titles=False):
    plain = simple_line(source, title, trail_rule, case_sensitive_titles=case_sensitive_titles)
    if plain is not None:
        return (*plain, None)
    # Paired markers can establish exact style ranges without expanding a page.
    parts = re.split(r"('{2,})", source)
    if (len(parts) == 9 and parts[1] == parts[7] and parts[3] == parts[5]
            and {parts[1], parts[3]} == {"''", "'''"}):
        before, left, middle, right, after = parts[::2]
        text = ''.join(parts[::2])
        if not all(piece.strip() for piece in (left, middle, right)) or not PLAIN.fullmatch(text) or '://' in text:
            return None
        start = len(before)
        inner = start + len(left)
        end = inner + len(middle)
        outer_style = 'italic' if parts[1] == "''" else 'bold'
        return text, (), ((start, inner, outer_style), (inner, end, 'bold-italic'),
                          (end, end + len(right), outer_style))
    if len(parts) < 5 or len(parts) % 4 != 1:
        return None
    boundaries = []
    styles = []
    offset = len(parts[0])
    for index in range(1, len(parts), 4):
        opening, marked, closing, after = parts[index:index + 4]
        style = {"''": 'italic', "'''": 'bold', "'''''": 'bold-italic'}.get(opening)
        if opening != closing or style is None or not marked.strip():
            return None
        boundaries.extend((offset, offset + len(marked)))
        styles.append(style)
        offset += len(marked) + len(after)
    unmarked = ''.join(parts[::2])
    if LABELED_URL.search(unmarked):
        return None  # Emphasis offsets require mapping through the bracketed URL and its label.
    plain = simple_line(unmarked, title, trail_rule, case_sensitive_titles=case_sensitive_titles)
    if plain is None:
        return None
    for action in plain[1]:
        if len(action) == 4 and action[3] == 'external':
            if any(action[0] < at < action[1] for at in boundaries):
                return None  # Emphasis split the URL token in the original source.
    links = iter(LINK.finditer(unmarked))
    link = next(links, None)
    removed = trail_end = 0
    display = []
    for at in boundaries:
        while link is not None and link.end() <= at:
            removed += len(link[0]) - len(link[2] or link[1])
            trail = trail_rule.match(unmarked, link.end()) if trail_rule is not None else None
            trail_end = trail.end() if trail else link.end()
            link = next(links, None)
        if at < trail_end or (link is not None and link.start() < at):
            return None  # A boundary inside link markup or its trail changes tokenization.
        display.append(at - removed)
    runs = tuple(zip(display[::2], display[1::2], styles, strict=True))
    return (*plain, runs[0] if len(runs) == 1 else runs)


def compiled_emphasis(spans):
    """Measure visible runs, merging adjacent spans that carry the same style."""
    text = ''.join(span['text'] for span in spans)
    first = edge_padding(spans, leading=True)
    last = len(text) - edge_padding(spans, leading=False)
    offset = 0
    runs = []
    for span in spans:
        if span.get('trail'):
            return None
        start = max(offset, first)
        offset += len(span['text'])
        end = min(offset, last)
        if start >= end or not (span.get('bold') or span.get('italic')):
            continue
        if span.get('bold') and span.get('italic'):
            style = 'bold-italic'
        else:
            style = 'bold' if span.get('bold') else 'italic'
        if runs and runs[-1][1:] == (start - first, style):
            runs[-1] = (runs[-1][0], end - first, style)
        else:
            runs.append((start - first, end - first, style))
    if not runs:
        return None
    if any(a[1] == b[0] for a, b in zip(runs, runs[1:])):
        # The supported nested source shape has real prose on both sides of
        # the inner run. A truncated or unrelated style transition cannot pass.
        if not (len(runs) == 3 and runs[0][1] == runs[1][0] and runs[1][1] == runs[2][0]
                and runs[0][2] == runs[2][2] != 'bold-italic' and runs[1][2] == 'bold-italic'):
            return None
    return runs[0] if len(runs) == 1 else tuple(runs)


def source_actions_match(expected, actual):
    """Permit a span break only at the source-proved boundary between label and trail."""
    pos = 0
    for action in expected:
        if pos == len(actual):
            return False
        if len(action) == 4 and isinstance(action[3], int):
            start, end, target, split = action
            if actual[pos] == (start, split, target):
                pos += 1
                if pos == len(actual):
                    return False
                start = split
            action = (start, end, target)
        if actual[pos] != action:
            return False
        pos += 1
    return pos == len(actual)


def definitions(text, title, headings, trail_rule=None, *, case_sensitive_titles=False):
    # Only inspect unambiguous source. Templates and protected or table text can
    # emit headings or consume later lines. Never assign those lines a language.
    if '#' not in text:
        return
    if '<!--' in text:
        # A complete, standalone editor comment contributes no visible content.
        # Leave its newline in place so witnesses retain the original line number.
        def remove_editor_comment(match):
            if len(match[0].splitlines()) != 1 or any(
                    marker in match[1] for marker in ('--', '{{', '}}', '[[', ']]', '{|', '|}', '__')):
                return match[0]
            return ''
        text = STANDALONE_COMMENT.sub(remove_editor_comment, text)
    if any(marker in text for marker in ('{{', '}}', '<', '>', '{|')):
        return
    lines = text.splitlines()
    if '__' in text and any('__' in line and not re.fullmatch(r'#[ \t]*_+[ \t]*', line) for line in lines):
        return
    owner = None
    for number, line in enumerate(lines, 1):
        if line.startswith('==') and not line.startswith('==='):
            source_heading = line.rstrip()
            heading = HEADING.fullmatch(source_heading) or LINKED_HEADING.fullmatch(source_heading)
            owner = heading[1] if heading and heading[1] in headings else None
        if not owner or not line.startswith('#'):
            continue
        body = line.lstrip('#')
        if body.startswith((':', '*', ';')):
            continue
        list_path = line[:len(line) - len(body)]
        witness = source_line(body.strip(), title, trail_rule, case_sensitive_titles=case_sensitive_titles)
        if witness is not None:
            yield owner, number, list_path, *witness


def localized_language_codes(raw):
    """Use unambiguous MediaWiki names, registered capitals and explicitly trusted headings."""
    lines = raw.decode('utf-8').splitlines()
    if not lines or lines[0] != '# wikidict-language-registry-v2' or '# mediawiki' not in lines:
        raise ValueError('Expected a v2 language registry with MediaWiki names')
    claims = defaultdict(set)
    candidates = {}
    local_headings = defaultdict(set)
    local_aliases = defaultdict(set)
    reviewed_aliases = defaultdict(set)
    mediawiki = False
    for line in lines[1:]:
        fields = line.split('\t')
        if line in ('# mediawiki', '# iso-639-3'):
            mediawiki = line == '# mediawiki'
        elif fields[0] == '# reviewed-alias' and len(fields) == 5:
            reviewed_aliases[fields[2]].add(fields[1])
        elif fields[0] == '# local-heading' and len(fields) == 3:
            local_headings[fields[2]].add(fields[1])
        elif fields[0] == '# local-alias' and len(fields) == 3:
            local_aliases[fields[2]].add(fields[1])
        elif len(fields) >= 2 and not line.startswith('#'):
            for name in fields:
                claims[name].add(fields[0])
            if mediawiki:
                name = fields[1]
                candidates[name] = (fields[0], name)
                initial = name[:1].upper()
                capitalized = initial + name[1:]
                if len(initial) == 1 and capitalized != name and capitalized in fields[2:]:
                    candidates[capitalized] = (fields[0], name)
    for spelling, owners in local_headings.items():
        # The native registry promotes an existing exact name. A local heading
        # cannot introduce a spelling or resolve conflicting owners.
        if (len(owners) == 1 and spelling not in owners and claims.get(spelling) == owners
                and local_aliases[spelling].issubset(owners)):
            candidates[spelling] = (next(iter(owners)), spelling)
    for spelling, owners in reviewed_aliases.items():
        claims[spelling].update(owners)
    return {spelling: code for spelling, (code, primary) in candidates.items()
            if spelling and claims[spelling] == claims[primary] == {code}}


class SourceDefinitions:
    def __init__(self, database, root, dumps, registry=None, checkpoint=None):
        self.owns_db = checkpoint is None
        self.db = sqlite3.connect(database) if self.owns_db else checkpoint.db
        self.matched_example = None
        # Most Reader titles can have no source witness (e.g. template-only
        # pages). A fixed occupancy table avoids SQLite calls for definite
        # misses. Collisions still go through the exact title/owner query.
        self._source_title_buckets = bytearray(65536)
        try:
            manifest = json.loads((root / 'complete.json').read_bytes())
            headings = set((root / 'languages.tsv').read_text().splitlines()[1:])
            self.codes = {}
            self.trail_rule = None
            self.registry_sha256 = None
            if registry is not None:
                raw = registry.read_bytes()
                self.registry_sha256 = hashlib.sha256(raw).hexdigest()
                if self.registry_sha256 != manifest['build_inputs'].get('auxiliary_snapshot_sha256', {}).get('language-registry'):
                    raise ValueError('Language registry differs from the selected build input')
                self.codes = localized_language_codes(raw)
                self.trail_rule = registry_link_trail(raw)
                headings.update(self.codes)
            members = {name: (size, sha1) for wiki, date, name, size, sha1 in manifest['build_inputs']['files']
                       if wiki == manifest['edition'] and date == manifest['date']
                       and '-pages-meta-current' in name and re.search(r'\.xml(?:-p[0-9]+p[0-9]+)?\.bz2$', name)}
            if not members or len(dumps) != len(members) or {path.name for path in dumps} != members.keys():
                raise ValueError('Expected every selected XML dump member exactly once')
            if checkpoint is not None and checkpoint.get('source_index'):
                self.inputs = {p.name: members[p.name][1] for p in dumps}
                self.matched_example = checkpoint.get('matched_example')
                for title, in self.db.execute('SELECT DISTINCT title FROM sense'):
                    self._source_title_buckets[hash(title) % len(self._source_title_buckets)] = 1
                self.has_definitions = self.db.execute('SELECT 1 FROM sense LIMIT 1').fetchone() is not None
                return
            if checkpoint is not None:
                self.db.execute('BEGIN IMMEDIATE')
            self.db.execute('CREATE TABLE sense (title, owner, code, line, list_path, text, links, emphasis, page, revision, matched INTEGER DEFAULT 0)')
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
            self.db.execute('CREATE INDEX by_owner ON sense (title, owner, line)')
            if checkpoint is not None:
                checkpoint.guard()
                checkpoint.put('source_index', True)
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
        insert = 'INSERT INTO sense (title,owner,code,line,list_path,text,links,emphasis,page,revision) VALUES (?,?,?,?,?,?,?,?,?,?)'
        rows = []
        characters = 0
        case_sensitive_titles = None
        for event, page in events:
            if event != 'end' or page.tag.rsplit('}', 1)[-1] != 'page':
                continue
            if case_sensitive_titles is None:
                # Look up the main namespace once per authenticated dump member.
                main = root.findall("{*}siteinfo/{*}namespaces/{*}namespace[@key='0']")
                case_sensitive_titles = len(main) == 1 and main[0].get('case') == 'case-sensitive'
            # Read each group of direct children once, preserving the first local
            # name just as ElementTree's wildcard find/findtext do.
            fields = {}
            for child in page:
                fields.setdefault(child.tag.rpartition('}')[2], child)
            if 'ns' in fields and fields['ns'].text == '0' and 'redirect' not in fields:
                title = fields['title'].text if 'title' in fields else None
                revision = fields.get('revision')
                if revision is None or not title:
                    raise ValueError('Main-namespace source page lacks a title or revision')
                origin = None
                for owner, n, list_path, text, links, emphasis in definitions(
                        revision.findtext('{*}text', ''), title, headings, self.trail_rule,
                        case_sensitive_titles=case_sensitive_titles):
                    if origin is None:
                        origin = page.findtext('{*}id'), revision.findtext('{*}id')
                        self._source_title_buckets[hash(title) % len(self._source_title_buckets)] = 1
                    actions = json.dumps(links, ensure_ascii=False)
                    rows.append((title, owner, self.codes.get(owner), n, list_path, text, actions,
                                 json.dumps(emphasis) if emphasis else None, *origin))
                    characters += len(title) + len(owner) + len(list_path) + len(text) + len(actions)
                    if len(rows) == 256 or characters >= 128 * 1024:
                        self.db.executemany(insert, rows)
                        rows.clear()
                        characters = 0
            root.remove(page)
        if rows:
            self.db.executemany(insert, rows)

    def observe(self, entry):
        if entry['kind'] != 'language':
            return
        if not self._source_title_buckets[hash(entry['title']) % len(self._source_title_buckets)]:
            return
        expected = self.db.execute('SELECT rowid,list_path,text,links,emphasis FROM sense WHERE title=? AND '
                                   '(code=? OR (code IS NULL AND owner=?)) ORDER BY line',
                                   (entry['title'], entry.get('language_code'), entry['language'])).fetchall()
        if not expected:
            return
        # Plain and directly linked senses must occupy a definition block in
        # order. A coincidental match in a translation or example cannot pass.
        positions = defaultdict(lambda: defaultdict(list))
        position = 0
        for section in entry['sections']:
            for block in section['blocks']:
                if block['kind'] == 'definition':
                    list_path = block.get('list_path')
                    witness = compiled_line(block['spans'])
                    if witness is not None:
                        text, actions = witness
                        if not any(span['text'] and (span.get('bold') or span.get('italic')) for span in block['spans']):
                            positions[(list_path, text, None)][actions].append(position)
                        elif (emphasis := compiled_emphasis(block['spans'])) is not None:
                            positions[(list_path, text, emphasis)][actions].append(position)
                    position += 1
        cursor = 0
        for rowid, list_path, text, links, emphasis in expected:
            actions = tuple(tuple(action) for action in json.loads(links))
            style = json.loads(emphasis) if emphasis else None
            if style:
                style = tuple(map(tuple, style)) if isinstance(style[0], list) else tuple(style)
            layouts = positions.get((list_path, text, style), {})
            if any(len(action) == 4 and isinstance(action[3], int) for action in actions):
                choices = (places for actual, places in layouts.items() if source_actions_match(actions, actual))
            else:
                choices = (layouts.get(actions, ()),)
            next_position = None
            for places in choices:
                index = bisect_left(places, cursor)
                if index < len(places) and (next_position is None or places[index] < next_position):
                    next_position = places[index]
            if next_position is not None:
                self.db.execute('UPDATE sense SET matched=1 WHERE rowid=?', (rowid,))
                if self.matched_example is None:
                    page, revision, line = self.db.execute('SELECT page,revision,line FROM sense WHERE rowid=?', (rowid,)).fetchone()
                    self.matched_example = dict(exact_title=entry['title'], owner_heading=entry['language'],
                                                visible_definition_witness=text, page=page, revision=revision, line=line)
                cursor = next_position + 1

    def report(self):
        count, matched = self.db.execute('SELECT count(*),coalesce(sum(matched),0) FROM sense').fetchone()
        missing = self.db.execute('SELECT title,owner,line,list_path,text,links,emphasis,page,revision FROM sense WHERE matched=0 ORDER BY rowid LIMIT 32')
        examples = []
        for title, owner, line, list_path, text, links, emphasis, page, revision in missing:
            actions = json.loads(links)
            target = actions[0][2] if len(actions) == 1 and actions[0][:2] == [0, len(text)] else None
            # The report describes authored links. The permissible span split is
            # an internal comparison detail, not a fourth action type.
            public_actions = [action[:3] if isinstance(action[-1], int) else action for action in actions]
            examples.append(dict(title=title, owner=owner, line=line, list_path=list_path, text=text, links=public_actions, emphasis=json.loads(emphasis) if emphasis else None, target=target, page=page, revision=revision))
        return dict(eligible=count, matched=matched, unmatched=count-matched, dump_sha1=self.inputs,
                    language_registry_sha256=self.registry_sha256,
                    has_source_evidence=count > 0,
                    examples=examples, matched_example=self.matched_example,
                    scope='Compare simple numbered lines under exact plain or unpiped linked language headings on template-free pages, ignoring standalone plain editor comments, to ordered definition blocks at their authored nesting depth. Compare the visible ranges of bold and italic text, including disjoint runs and plain text with one nested run. Require the registered code for a unique primary name or its explicitly listed initial-capital spelling. Unmatched items need source review; numbered examples and related terms can be intentional.')

    def unmatched_locations(self, *, after_examples):
        rows = self.db.execute('SELECT title,owner,page,revision,line FROM sense WHERE matched=0 '
                               'ORDER BY rowid LIMIT -1 OFFSET ?', (after_examples,))
        for title, owner, page, revision, line in rows:
            yield dict(title=title, owner=owner, page=page, revision=revision, line=line)

    def close(self):
        if self.owns_db:
            self.db.close()
