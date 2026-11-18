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
PLAIN = re.compile(r"[^\[\]{}<>|&'#=]+")


def definitions(text, title, headings):
    # Only inspect unambiguous source. Templates and protected or table text can
    # emit headings or consume later lines. Never assign those lines a language.
    if any(marker in text for marker in ('{{', '}}', '<', '>', '{|', '__')):
        return
    owner = None
    for number, line in enumerate(text.splitlines(), 1):
        if line.startswith('==') and not line.startswith('==='):
            heading = HEADING.fullmatch(line.rstrip())
            owner = heading[1] if heading and heading[1] in headings else None
        if not owner or not line.startswith('#') or line.startswith(('##', '#:', '#*', '#;')):
            continue
        content = line[1:].strip()
        link = LINK.fullmatch(content)
        if link:
            target, display = link[1], link[2] or link[1]
            if target.strip() != target or target.casefold() == title.casefold():
                continue
            yield owner, number, display, target
        elif PLAIN.fullmatch(content) and any(c.isalpha() for c in content):
            yield owner, number, content, None


class SourceDefinitions:
    def __init__(self, database, root, dumps):
        self.db = sqlite3.connect(database)
        try:
            self.db.execute('CREATE TABLE sense (title, owner, line, text, target, page, revision, matched INTEGER DEFAULT 0)')
            self.db.execute('CREATE INDEX by_owner ON sense (title, owner, line)')
            manifest = json.loads((root / 'complete.json').read_bytes())
            headings = set((root / 'languages.tsv').read_text().splitlines()[1:])
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
                self.db.executemany('INSERT INTO sense (title,owner,line,text,target,page,revision) VALUES (?,?,?,?,?,?,?)',
                    ((title, owner, n, text, target, page.findtext('{*}id'), revision.findtext('{*}id'))
                     for owner, n, text, target in definitions(revision.findtext('{*}text', ''), title, headings)))
            root.remove(page)

    def observe(self, entry):
        if entry['kind'] != 'language':
            return
        expected = self.db.execute('SELECT rowid,text,target FROM sense WHERE title=? AND owner=? ORDER BY line',
                                   (entry['title'], entry['language'])).fetchall()
        if not expected:
            return
        # Plain and directly linked senses must occupy a definition block in
        # order. A coincidental match in a translation or example cannot pass.
        positions = defaultdict(list)
        position = 0
        for section in entry['sections']:
            for block in section['blocks']:
                if block['kind'] == 'definition' and block.get('list_path') == '#':
                    spans = block['spans']
                    # The exported text of an outer span omits its nested children.
                    # A simple source line cannot attest those extra words or actions.
                    if any(s.get(key) is not None for s in spans for key in (
                        'inline_action_group', 'inline_padding_group', 'inline_box_group', 'ruby', 'image'
                    )):
                        continue
                    text = ''.join(s['text'] + s.get('trail', '') for s in spans).strip()
                    links = [s for s in spans if s['kind'] == 'link']
                    if all(s['kind'] == 'text' for s in spans):
                        positions[text, None].append(position)
                    elif (len(links) == 1 and all(s['kind'] in ('text', 'link') for s in spans)
                          and links[0]['text'] == text and not links[0].get('target_fragment')):
                        positions[text, links[0]['target']].append(position)
                    position += 1
        cursor = 0
        for rowid, text, target in expected:
            candidates = positions.get((text, target), ())
            index = bisect_left(candidates, cursor)
            if index < len(candidates):
                self.db.execute('UPDATE sense SET matched=1 WHERE rowid=?', (rowid,))
                cursor = candidates[index] + 1

    def report(self):
        count, matched = self.db.execute('SELECT count(*),coalesce(sum(matched),0) FROM sense').fetchone()
        missing = self.db.execute('SELECT title,owner,line,text,target,page,revision FROM sense WHERE matched=0 ORDER BY rowid LIMIT 32')
        return dict(eligible=count, matched=matched, unmatched=count-matched, dump_sha1=self.inputs,
                    has_source_evidence=count > 0,
                    examples=[dict(zip(('title','owner','line','text','target','page','revision'), row)) for row in missing],
                    scope='Compare simple numbered source lines under literal emitted language headings on template-free pages to ordered definition blocks. Unmatched items require source review; a numbered example or related term can be intentional.')

    def close(self):
        self.db.close()
