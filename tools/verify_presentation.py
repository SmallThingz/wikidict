#!/usr/bin/env python3
"""Flag supported decoded CLI views for manual review; never semantic acceptance.

This is an opt-in per-title diagnostic, not a production completion gate. Its
command/view counts expose scan cost. Raw DAL1 alias presentation is not exposed
by the CLI; aliases are covered only through its selected, one-hop export view.
"""
import argparse
import gzip
import hashlib
import io
import json
import math
import re
import os
import select
import shutil
import stat
import struct
import sqlite3
import tempfile
import subprocess
import time
from concurrent.futures import ThreadPoolExecutor
from contextlib import ExitStack, contextmanager
from pathlib import Path
import reviewed_nonlexical as nonlexical

try:
    from compression import zstd
except ImportError:
    zstd = None

MARKUP = re.compile(r'\[\[|\]\]|\{\{|\}\}|</?[A-Za-z][^>]*>|\{\||\|}')
# Decoded spans do not preserve reliable nowiki/source provenance. Intentional
# literal spellings need source-backed disposition, including code=true spans.
# A switch name needs a word character other than its underscore delimiters.
BEHAVIOR_SWITCH = re.compile(r'(?<!_)_{2,}[^\W_]\w*__')
ERROR_PROSE = re.compile(r'\b(?:Lua|Script|Parser|Scribunto)\s+error\b', re.IGNORECASE)
UNAVAILABLE_TEMPLATE = re.compile(r'\[(?:missing template\]|unavailable template:)', re.IGNORECASE)
RENDER_DIAGNOSTIC = re.compile(r'\[(?:malformed (?:template|link|table)|missing parameter|render (?:nesting limit|output truncated))\]')
FEATURE_KINDS = ('thesaurus', 'citations', 'reconstruction', 'rhymes',
                 'sign-gloss', 'supplemental')
SUPPORTED_KINDS = ('language', *FEATURE_KINDS)


class ScanError(ValueError):
    pass


def diagnostic_categories(text):
    found = []
    if ('[' in text or ']' in text or '{' in text or '}' in text or '<' in text) and MARKUP.search(text):
        found.append('source-markup')
    if '__' in text and BEHAVIOR_SWITCH.search(text):
        found.append('behavior-switch')
    if 'error' in text.lower() and ERROR_PROSE.search(text):
        found.append('error-prose')
    if '[' in text:
        if UNAVAILABLE_TEMPLATE.search(text):
            found.append('unavailable-template')
        if RENDER_DIAGNOSTIC.search(text):
            found.append('render-diagnostic')
    return found


def inline_text_parts(spans, path, start=0):
    """Yield inline prose in authored order, or a separate Ruby reading context."""
    for index, span in enumerate(spans, start):
        text = span['text']
        trail = span.get('trail', '')
        if span['kind'] == 'line_break':
            yield '\n' + text + trail + '\n'
            continue
        yield text
        if isinstance(span.get('ruby'), dict):
            yield f'{path}[{index}].ruby', span['ruby']
        for key in ('inline_action_group', 'inline_padding_group', 'inline_box_group'):
            group = span.get(key)
            if not isinstance(group, dict):
                continue
            group_path = f'{path}[{index}].{key}'
            children = group['spans']
            cursor = 0
            for overlay_index, overlay in enumerate(group.get('overlays', [])):
                content = overlay.get('content')
                if content is None:
                    continue
                boundary = content['before_child']
                require(natural(boundary) and cursor <= boundary <= len(children),
                        f'invalid overlay child position in {group_path}')
                yield from inline_text_parts(children[cursor:boundary], group_path + '.spans', cursor)
                yield from inline_text_parts(content['spans'], f'{group_path}.overlays[{overlay_index}].content.spans')
                cursor = boundary
            tail = children[cursor:] if cursor else children
            yield from inline_text_parts(tail, group_path + '.spans', cursor)
        yield trail


def text_fields(value, path='entry'):
    if isinstance(value, dict):
        for key, child in value.items():
            if key in ('text', 'caption', 'title', 'trail') and isinstance(child, str):
                yield path + '.' + key, child
            elif isinstance(child, (dict, list)):
                yield from text_fields(child, path + '.' + key)
    elif isinstance(value, list):
        if value and all(isinstance(span, dict) and 'text' in span and 'kind' in span for span in value):
            # Annotations and fallbacks are read separately from neighboring prose.
            parts = []
            saw_ruby = False
            for part in inline_text_parts(value, path):
                if isinstance(part, str):
                    parts.append(part)
                else:
                    if any(parts):
                        yield path, ''.join(parts)
                    parts.clear()
                    ruby_path, ruby = part
                    yield from text_fields(ruby, ruby_path)
                    saw_ruby = True
            if not saw_ruby or any(parts):
                yield path, ''.join(parts)
            return
        for index, child in enumerate(value):
            if isinstance(child, (dict, list)):
                yield from text_fields(child, f'{path}[{index}]')



def destination_fields(action, path, internal_kind, external_kind):
    if not isinstance(action, dict) or action.get('kind') not in (internal_kind, external_kind):
        return
    if isinstance(action.get('target'), str):
        yield 'target', path + '.target', action['target']
    if action['kind'] == internal_kind and isinstance(action.get('target_fragment'), str):
        yield 'target', path + '.target_fragment', action['target_fragment']


def attribute_fields(value, path='entry'):
    """Walk decoded annotations and link destinations independently of visible prose."""
    if isinstance(value, dict):
        if 'kind' in value and 'text' in value:
            if isinstance(value.get('explanation'), str) and value['explanation']:
                yield 'explanation', path + '.explanation', value['explanation']
            clipped = value.get('clipped_absolute')
            if isinstance(clipped, dict):
                # The native Reader omits these children from paint but exposes
                # their text and actions to accessibility. Keep the runs separate.
                for child_path, text in text_fields(clipped['children'], path + '.clipped_absolute.children'):
                    yield 'clipped_text', child_path, text
            # Match the native Reader's effectiveAdvisory. An explicit empty
            # image title suppresses advice inherited from the surrounding span.
            image = value.get('image')
            if isinstance(image, dict) and isinstance(image.get('alt'), str):
                yield 'image_alt', path + '.image.alt', image['alt']
            if isinstance(image, dict) and image.get('tooltip') is not None:
                tooltip, origin = image['tooltip'], '.image.tooltip'
            else:
                tooltip, origin = value.get('tooltip'), '.tooltip'
            if isinstance(tooltip, str) and tooltip:
                yield 'tooltip', path + origin, tooltip
            image_map = image.get('map') if isinstance(image, dict) else None
            if isinstance(image_map, dict):
                map_path = path + '.image.map'
                for i, region in enumerate(image_map.get('regions', [])):
                    yield from destination_fields(region.get('action'), f'{map_path}.regions[{i}].action',
                                                  'internal', 'external')
                yield from destination_fields(image_map.get('default_action'), map_path + '.default_action',
                                              'internal', 'external')
        if value.get('kind') in ('link', 'external_link'):
            yield from destination_fields(value, path, 'link', 'external_link')
        for key, child in value.items():
            if isinstance(child, (dict, list)):
                yield from attribute_fields(child, path + '.' + key)
    elif isinstance(value, list):
        for index, child in enumerate(value):
            if isinstance(child, (dict, list)):
                yield from attribute_fields(child, f'{path}[{index}]')


def annotation_fields(value, path='entry'):
    return ((p, text) for field, p, text in attribute_fields(value, path) if field in ('explanation', 'tooltip'))


def unresolved_action_target(target):
    # Inspect semantic destinations once; never percent-decode or scan title/redirect metadata.
    return '{{' in target or '}}' in target


def action_fields(value, path='entry'):
    return ((p, target) for field, p, target in attribute_fields(value, path) if field == 'target')


def require(condition, message):
    if not condition:
        raise ScanError(message)


def natural(value):
    return type(value) is int and value >= 0


def present(root, stem):
    return any((root / (stem + suffix)).is_file() for suffix in ('', '.xz'))


def source_lookup_key(kind, full_title):
    # alias_codec.validate41-45: only these five source namespaces drop the
    # first (possibly localized) namespace prefix. Main/supplemental retain it.
    require(isinstance(full_title, str) and full_title, 'invalid alias source title')
    if kind not in ('language', 'supplemental'):
        prefix, separator, key = full_title.partition(':')
        require(prefix and separator and key, 'feature alias source lacks namespace')
        return key
    return full_title


def coverage_rows(root):
    path = root / 'namespace-coverage.json'
    if not path.exists():
        return None
    coverage = json.loads(path.read_text())
    require(coverage.get('version') in (1, 2) and isinstance(coverage.get('namespaces'), list),
            'invalid namespace coverage')
    nonlexical.check_publication(root)
    rows, ids = coverage['namespaces'], set()
    for row in rows:
        require(natural(row['id']) and row['id'] not in ids and
                all(natural(row[field]) for field in ('expanded_pages', 'fallback_pages', 'alias_pages')),
                'invalid namespace alias accounting')
        require(row['alias_pages'] <= row['expanded_pages'] + row['fallback_pages'],
                'namespace aliases exceed completed pages')
        ids.add(row['id'])
    return rows


def language_catalog(query, page_size):
    if page_size is None:
        return query('languages')
    rows = []
    total = None
    while total is None or len(rows) < total:
        offset = len(rows)
        page = query('languages', '--catalog-page-size', str(page_size), '--offset', str(offset))
        require(page.get('schema') == 'dict.languages.page.v1' and
                natural(page.get('offset')) and page['offset'] == offset and
                natural(page.get('total_headings')), 'invalid catalog page metadata')
        if total is None:
            total = page['total_headings']
        require(total == page['total_headings'], 'catalog size changed during scan')
        batch = page.get('accounting')
        require(isinstance(batch, list) and len(batch) == min(page_size, total - offset),
                'incomplete catalog page')
        for row in batch:
            require(isinstance(row, dict) and isinstance(row.get('heading'), str) and row['heading'] and
                    natural(row.get('records')) and isinstance(row.get('code'), str), 'invalid catalog row')
            code = row['code']
            classification = 'translingual' if code == 'mul' else 'language' if code else 'unverified'
            require(row.get('classification') == classification, 'invalid catalog row classification')
            require(not rows or rows[-1]['heading'] < row['heading'], 'catalog headings out of order')
            rows.append(row)
    return dict(languages=[row['heading'] for row in rows], accounting=rows)


def emitted_views(root, catalog, query):
    """Native catalog accounting owns language names; fixed filenames own kinds."""
    headings, accounting = catalog['languages'], catalog['accounting']
    require(isinstance(headings, list) and all(isinstance(x, str) and x for x in headings),
            'invalid language catalog')
    require(len(set(headings)) == len(headings), 'duplicate language owner')
    require(isinstance(accounting, list), 'missing language accounting')
    owners = {}
    for row in accounting:
        heading, records = row['heading'], row['records']
        require(heading not in owners and isinstance(heading, str) and natural(records),
                'duplicate or invalid language accounting')
        owners[heading] = records
    require(set(owners) == set(headings), 'catalog/accounting owner mismatch')
    names = {hashlib.sha256(x.encode()).hexdigest() + '.wikblb' for x in headings}
    language_dir = root / 'languages'
    if language_dir.exists():
        actual = {x.name.removesuffix('.xz') for x in language_dir.iterdir()
                  if x.name.endswith(('.wikblb', '.wikblb.xz'))}
        require(actual == names, 'language payload inventory/catalog mismatch')
    else:
        require(not headings, 'language payload directory missing')
    views = [dict(kind='language', language=x, minimum_records=owners[x], neutral=False)
             for x in headings]
    rows = coverage_rows(root)
    for kind in FEATURE_KINDS:
        exists = present(root, kind + '.wikblb')
        expected = any(row['kind'] == kind.replace('-', '_') and
                       row['expanded_pages'] + row['fallback_pages'] > 0 for row in rows or [])
        require(exists or not expected, 'namespace coverage selects missing fixed-kind payload: ' + kind)
        if exists:
            views.append(dict(kind=kind, language=None, minimum_records=0, neutral=False))
    if not headings and present(root, 'aliases.wikblb'):
        # The neutral store is valid only for main-namespace aliases. Feature
        # alias-only stores have their own emitted empty fixed-kind blob.
        if rows is None:
            # Synthetic Reader roots need not have producer coverage. The
            # existing neutral stats view authenticates main aliases directly;
            # command errors remain errors, never an inferred empty selection.
            stats = query('stats', '--kind', 'language', '--language', 'neutral-alias-view')
            count = stats.get('record_count')
            require(stats.get('operation') == 'stats' and stats.get('kind') == 'language' and
                    stats.get('language') is None and natural(count) and count > 0 and
                    stats.get('total_matches') == count,
                    'invalid neutral alias stats')
            main_aliases = count
        else:
            main_aliases = sum(row['alias_pages'] for row in rows if row['kind'] == 'language')
        if main_aliases:
            views.insert(0, dict(kind='language', language=None,
                                 minimum_records=main_aliases, neutral=True))
    return views


def scan(root, query, export_page=None, *, observe_record=None, audit_references=False, row_factory=list,
         catalog_page_size=None, audit_alias_references=False):
    require(root.is_dir(), 'root does not exist')
    result = dict(records=0, issues=row_factory(), annotations=row_factory(), views=[], search_matches=0,
                  duplicate_destinations=0, alias_views=0, commands=0, image_alternatives=0,
                  diagnostic_only=True, semantic_acceptance=False, scan_complete=False,
                  scope=dict(record_kinds=list(SUPPORTED_KINDS),
                             inventory='native language accounting and emitted fixed-kind files',
                             aliases='selected CLI export view, including one-hop follows; not raw DAL1 coverage',
                             protected_literal_provenance=False,
                             annotations='decoded plain attribute text; separate literal evidence, never markup execution or lexical body',
                             behavior_aliases='literal double-underscore word pattern; not an exhaustive registry'),
                  status_meaning='failed: review candidates; passed: no candidates in supported views; error: incomplete scan')

    def ask(*parts):
        result['commands'] += 1
        value = query(*parts)
        require(isinstance(value, dict), 'non-object CLI response')
        return value

    destinations = {}
    destination_references = {}
    for view in emitted_views(root, language_catalog(ask, catalog_page_size), ask):
        summary = dict(view, matches=0, unique_records=0, duplicate_destinations=0)
        result['views'].append(summary)
        # Args requires a nonempty language; this reserved selector is only a
        # neutral-store transport argument, never an inferred record owner.
        language_arg = 'neutral-alias-view' if view['neutral'] else view['language']
        selection = ['--kind', view['kind']]
        if language_arg is not None:
            selection += ['--language', language_arg]
        offset, expected_total, previous = 0, None, None
        while True:
            page = ask('search', *selection, '--case-sensitive', '--limit', '1000',
                       '--offset', str(offset), '--', '')
            require(page.get('kind') == view['kind'].replace('-', '_') and
                    page.get('language') == view['language'], 'search selection owner mismatch')
            total = page['total_matches']
            require(natural(total) and natural(page.get('record_count')) and page['record_count'] == total and
                    natural(page.get('offset')) and page['offset'] == offset and type(page.get('has_more')) is bool,
                    'invalid search pagination metadata')
            if expected_total is None:
                expected_total = total
                require(total >= view['minimum_records'], 'view lost catalog records')
            require(total == expected_total, 'search total changed during scan')
            matches = page['matches']
            require(isinstance(matches, list) and len(matches) <= 1000 and offset + len(matches) <= total,
                    'invalid search page')
            require(page['has_more'] == (offset + len(matches) < total), 'inconsistent has_more')
            require(matches or not page['has_more'], 'nonprogressing search page')
            page_exports = iter(export_page(selection, matches)) if export_page is not None else None
            for match in matches:
                title = match['title']
                require(isinstance(title, str) and title and (previous is None or title > previous),
                        'duplicate or nonprogressing owner/title')
                previous = title
                summary['matches'] += 1
                result['search_matches'] += 1
                if page_exports is None:
                    exported = ask('export', *selection, '--case-sensitive', '--', title)
                else:
                    result['commands'] += 1  # Same logical export count; transport is reported separately.
                    exported = next(page_exports, None)
                    require(isinstance(exported, dict), 'incomplete batch export')
                require(exported.get('kind') == view['kind'].replace('-', '_') and
                        exported.get('language') == view['language'], 'export selection owner mismatch')
                entries = exported['entries']
                reference, reused = exported.get('audit_reference'), exported.get('audit_reused')
                require(audit_references or reference is reused is None, 'unexpected audit reference')
                require(isinstance(entries, list) and len(entries) == (0 if reused is not None else 1),
                        'missing or ambiguous export')
                entry = reused if reused is not None else entries[0]
                actual_kind, owner, actual_title = entry['kind'], entry.get('language'), entry['title']
                require(actual_kind in (*[x.replace('-', '_') for x in SUPPORTED_KINDS], 'alias') and
                        (owner is None or isinstance(owner, str)) and isinstance(actual_title, str) and actual_title,
                        'invalid exported record identity')
                if actual_kind == 'language':
                    require(owner is not None and owner == view['language'] and view['kind'] == 'language',
                            'exported language owner mismatch')
                redirect = entry.get('redirect')
                if redirect is not None:
                    require(isinstance(redirect, dict) and
                            source_lookup_key(view['kind'], redirect.get('source_title')) == title,
                            'alias source/query mismatch')
                    result['alias_views'] += 1
                else:
                    require(actual_title == title and actual_kind == view['kind'].replace('-', '_'),
                            'unjoined export destination')
                identity = (actual_kind, owner, actual_title)
                if reference is not None:
                    require(isinstance(reference, str) and re.fullmatch('[0-9a-f]{64}', reference) is not None and
                            view['kind'] == 'language' and owner is None and redirect is not None,
                            'invalid destination audit reference')
                    if actual_kind == 'alias':
                        require(audit_alias_references and redirect.get('followed') is False and
                                redirect['source_title'] == actual_title == title, 'invalid alias audit reference')
                    else:
                        require(actual_kind != 'language' and redirect.get('followed') is True,
                                'invalid cross-feature audit reference')
                if reused is not None:
                    require(reference in destination_references and destination_references[reference] == identity and
                            identity in destinations, 'unknown or conflicting destination reference')
                    summary['duplicate_destinations'] += 1
                    result['duplicate_destinations'] += 1
                    exported = entries = entry = redirect = None
                    continue
                # A followed alias changes routing metadata, not destination
                # content. Scan that content once while retaining query joins
                # on its first issue occurrence and explicit duplicate counts.
                content = {key: value for key, value in entry.items() if key != 'redirect'}
                digest = hashlib.sha256(json.dumps(content, ensure_ascii=False, sort_keys=True).encode()).digest()
                if reference is not None:
                    require(destination_references.setdefault(reference, identity) == identity,
                            'conflicting destination reference')
                if identity in destinations:
                    require(destinations[identity] == digest, 'conflicting duplicate destination')
                    summary['duplicate_destinations'] += 1
                    result['duplicate_destinations'] += 1
                    exported = entries = entry = content = redirect = None
                    continue
                destinations[identity] = digest
                result['records'] += 1
                summary['unique_records'] += 1
                if observe_record is not None:
                    observe_record(entry)
                for path, text in text_fields(content):
                    categories = diagnostic_categories(text)
                    if categories:
                        result['issues'].append(dict(kind=actual_kind, language=owner, title=actual_title,
                            view_kind=view['kind'], view_language=view['language'], query_title=title,
                            source_title=redirect['source_title'] if redirect else title,
                            redirect=redirect, path=path, text=text[:500], categories=categories))
                for field, path, text in attribute_fields(content):
                    if field in ('image_alt', 'clipped_text'):
                        if field == 'image_alt':
                            result['image_alternatives'] += 1
                        categories = diagnostic_categories(text)
                        if categories:
                            result['issues'].append(dict(kind=actual_kind, language=owner, title=actual_title,
                                view_kind=view['kind'], view_language=view['language'], query_title=title,
                                source_title=redirect['source_title'] if redirect else title,
                                redirect=redirect, path=path, text=text[:500], categories=categories,
                                interpretation='image-alternative' if field == 'image_alt' else 'clipped-semantic-text'))
                    elif field in ('explanation', 'tooltip'):
                        result['annotations'].append(dict(kind=actual_kind, language=owner, title=actual_title,
                            view_kind=view['kind'], view_language=view['language'], query_title=title,
                            source_title=redirect['source_title'] if redirect else title,
                            redirect=redirect, path=path, text=text[:500], text_length=len(text),
                            text_truncated=len(text) > 500, spelling_matches=diagnostic_categories(text),
                            interpretation='decoded-plain-attribute', lexical_body=False,
                            runtime_markup=False, review_issue=False))
                    elif unresolved_action_target(text):
                        result['issues'].append(dict(kind=actual_kind, language=owner, title=actual_title,
                            view_kind=view['kind'], view_language=view['language'], query_title=title,
                            source_title=redirect['source_title'] if redirect else title,
                            redirect=redirect, path=path, text=text[:500],
                            categories=['unresolved-action-target'], nonwaivable=True))
                # Release the decoded response before requesting the next line.
                # Audit summaries retain only their existing hashes/snippets.
                exported = entries = entry = content = redirect = text = None
            if page_exports is not None:
                require(next(page_exports, None) is None, 'unexpected extra batch export')
            offset += len(matches)
            if not page['has_more']:
                break
        require(offset == expected_total, 'incomplete view')
    result['view_count'] = len(result['views'])
    result['scan_complete'] = True
    result['status'] = 'failed' if result['issues'] else 'passed'
    return result


def cli_query(binary, root, *parts):
    argv = [str(binary.resolve()), parts[0], '--root', str(root),
            '--format', 'json', *parts[1:]]
    try:
        payload = subprocess.check_output(argv, timeout=60)
    except subprocess.CalledProcessError as error:
        # main.zig225 returns 1 for a genuine empty search. No other command or
        # nonempty/error response is accepted; scan still checks owner/offset.
        if error.returncode != 1 or parts[0] != 'search':
            raise
        value = json.loads(error.output)
        require(isinstance(value, dict) and value.get('operation') == 'search' and
                value.get('query') == '' and value.get('total_matches') == 0 and
                value.get('record_count') == 0 and value.get('offset') == 0 and
                value.get('matches') == [] and value.get('has_more') is False,
                'nonempty or malformed rc1 search response')
        return value
    return json.loads(payload)


def prepare_index_directories(root):
    # Ordinary Store writes indexes only beneath these two existing source
    # directories. Create their empty cache directories before binding source
    # directory timestamps; this does not read or warm any dictionary index.
    for parent in (Path(root), Path(root) / 'languages'):
        if not parent.is_dir():
            continue
        cache = parent / '.dict-cache'
        try:
            cache.mkdir()
        except FileExistsError:
            require(cache.is_dir() and not cache.is_symlink(), 'invalid derived index directory')
        except PermissionError:
            # Ordinary read-only Store also continues without saving a cache.
            # A later permission/member change is still caught by the snapshot.
            pass


def dictionary_snapshot(root):
    root = str(Path(root).absolute())
    rows, seen = [], set()
    ancestor_identities = {}

    def state(path, follow):
        value = os.stat(path) if follow else os.lstat(path)
        return (value.st_dev, value.st_ino, value.st_mode, value.st_uid,
                value.st_gid, value.st_nlink, value.st_size,
                value.st_mtime_ns, value.st_ctime_ns)

    def remember_ancestors(parent):
        # Fresh identities are still bound once per snapshot. Strings avoid
        # reconstructing/hashing the same Path parents for every source member.
        while parent not in ancestor_identities:
            ancestor_identities[parent] = state(parent, False)[:5]
            parent = os.path.dirname(parent)

    def visit(path, depth, resolved_parent=None, lexical_parent=None):
        require(depth <= 16, 'dictionary directory depth exceeded')
        lexical = state(path, False)
        is_link = stat.S_ISLNK(lexical[2])
        target = state(path, True) if is_link else lexical
        if resolved_parent is None or is_link:
            resolved = str(Path(path).resolve(strict=True))
        elif resolved_parent == lexical_parent:
            resolved = path
        else:
            resolved = os.path.join(resolved_parent, os.path.basename(path))
        remember_ancestors(lexical_parent if lexical_parent is not None else os.path.dirname(path))
        if resolved != path:
            remember_ancestors(os.path.dirname(resolved))
        row = (path, resolved, lexical, target)
        if stat.S_ISDIR(target[2]):
            identity = target[:2]
            require(identity not in seen, 'dictionary directory alias or cycle')
            seen.add(identity)
            names = sorted(name for name in os.listdir(path) if name != '.dict-cache')
            cache = os.path.join(path, '.dict-cache')
            try:
                cache_state = state(cache, False)
            except FileNotFoundError:
                cache_identity = None
            else:
                require(stat.S_ISDIR(cache_state[2]), 'derived cache directory changed type')
                cache_identity = cache_state[:5]
            rows.append((*row, names, cache_identity))
            for name in names:
                visit(os.path.join(path, name), depth + 1, resolved, path)
        else:
            require(stat.S_ISREG(target[2]), 'nonregular dictionary member')
            rows.append(row)
        if is_link:
            require(target == state(path, True), 'dictionary link target changed during snapshot')
        require(lexical == state(path, False), 'dictionary member changed during snapshot')
    visit(root, 0)
    for parent, identity in ancestor_identities.items():
        require(identity == state(parent, False)[:5], 'dictionary ancestor changed during snapshot')
    return rows, {Path(parent): identity for parent, identity in ancestor_identities.items()}


def process_birth(pid):
    # Popen owns exactly this child. A timeout may signal only that PID with
    # this still-current kernel birth, never a group or a reused PID.
    return int(Path(f'/proc/{pid}/stat').read_text().rsplit(')', 1)[1].split()[19])


def export_spool(storage, mode):
    if zstd is not None:
        return zstd.ZstdFile(storage, mode, level=1 if mode == 'wb' else None)
    return gzip.GzipFile(fileobj=storage, mode=mode, compresslevel=1, mtime=0)


def compress_exports(stream, storage):
    with stream, export_spool(storage, 'wb') as compressed:
        # An empty successful child must still produce a readable empty frame.
        compressed.write(b'')
        shutil.copyfileobj(stream, compressed, length=128 * 1024)


def wait_export_child(process, timeout):
    """Wait for the owned child without timed waitpid sleep polling when possible."""
    pidfd_open = getattr(os, 'pidfd_open', None)
    if pidfd_open is None or not hasattr(select, 'poll'):
        return process.wait(timeout=timeout)
    try:
        fd = pidfd_open(process.pid)
    except OSError:
        return process.wait(timeout=timeout)
    try:
        poller = select.poll()
        poller.register(fd, select.POLLIN)
        events = poller.poll(math.ceil(timeout * 1000))
        if not events:
            code = process.poll()
            if code is None:
                raise subprocess.TimeoutExpired(process.args, timeout)
            return code
        if not events[0][1] & (select.POLLIN | select.POLLHUP):
            raise OSError('Export child pidfd did not report exit')
        return process.wait()
    finally:
        os.close(fd)


def stop_export_child(process, birth):
    try:
        if process.poll() is None and birth is not None:
            require(process_birth(process.pid) == birth, 'export child identity changed')
            process.kill()
    finally:
        process.wait()


@contextmanager
def checked_export_stream(argv):
    # The CLI can emit megabytes of repeated JSON per title. Retain the whole
    # batch until the child succeeds, spilling only compressed bytes to disk.
    with tempfile.SpooledTemporaryFile(max_size=2 * 1024 * 1024) as storage:
        read_fd, write_fd = os.pipe()
        with os.fdopen(read_fd, 'rb') as stream, os.fdopen(write_fd, 'wb', buffering=0) as writer:
            with ThreadPoolExecutor(max_workers=1) as pool:
                copied = pool.submit(compress_exports, stream, storage)
                try:
                    process = subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=writer)
                finally:
                    writer.close()
                birth = None
                try:
                    birth = process_birth(process.pid)
                    code = wait_export_child(process, 60)
                except BaseException:
                    stop_export_child(process, birth)
                    raise
                copied.result()
                require(code == 0, f'export batch failed with status {code}')
        storage.seek(0)
        with export_spool(storage, 'rb') as decoded:
            yield decoded


def exchange_export_batch(process, titles, hints, storage, alias_references=False):
    mode = 0 if hints is None else 2 if alias_references else 1
    process.stdin.write(bytes((len(titles), mode)))
    if hints is not None:
        process.stdin.write(''.join(hints).encode('ascii'))
    for title in titles:
        encoded = title.encode('utf-8')
        process.stdin.write(struct.pack('<I', len(encoded)))
        process.stdin.write(encoded)
    process.stdin.flush()
    at_line_start = True
    with export_spool(storage, 'wb') as compressed:
        while part := process.stdout.readline(128 * 1024):
            if at_line_start and part == b'\n':
                return True
            compressed.write(part)
            at_line_start = part.endswith(b'\n')
    return False


@contextmanager
def checked_export_session(argv, *, alias_references=False):
    """One native Store for the current selection, one transaction per request."""
    with ThreadPoolExecutor(max_workers=1) as pool:
        process = subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE)
        with process.stdin, process.stdout:
            birth = None
            stopped = False

            @contextmanager
            def batch(titles, hints):
                nonlocal stopped
                with tempfile.SpooledTemporaryFile(max_size=2 * 1024 * 1024) as storage:
                    deadline = time.monotonic() + 60
                    try:
                        exchange = pool.submit(exchange_export_batch, process, titles, hints, storage, alias_references)
                        if not exchange.result(timeout=60):
                            code = wait_export_child(process, max(0, deadline - time.monotonic()))
                            require(code == 0, f'export batch failed with status {code}')
                            raise ScanError('export session ended without completing the batch')
                    except BaseException as error:
                        stopped = True
                        try:
                            stop_export_child(process, birth)
                        finally:
                            # Release storage only after the transfer has joined.
                            pool.shutdown(wait=True)
                        if isinstance(error, (TimeoutError, subprocess.TimeoutExpired)):
                            raise subprocess.TimeoutExpired(argv, 60) from error
                        raise
                    storage.seek(0)
                    with export_spool(storage, 'rb') as decoded:
                        yield decoded

            try:
                birth = process_birth(process.pid)
                yield batch
                process.stdin.close()
                code = wait_export_child(process, 60)
                require(code == 0, f'export session failed with status {code}')
            except BaseException:
                if not stopped:
                    if birth is None:
                        # No request has been sent. EOF lets an unproved child
                        # terminate without a signal, even if birth lookup failed.
                        process.stdin.close()
                        process.stdout.close()
                    stop_export_child(process, birth)
                raise


def batch_exports(binary, root, selection, matches, batch_size, unchanged, reference_hints=None, session=None):
    require(1 <= batch_size <= 64, 'invalid export batch size')
    offset = 0
    while offset < len(matches):
        titles, total = [], 0
        for match in matches[offset:offset + batch_size]:
            title = match['title']
            require(isinstance(title, str) and title, 'invalid batch query title')
            size = len(title.encode('utf-8'))
            if size > 65536:
                break
            if total + size > 65536:
                break
            titles.append(title)
            total += size
        if not titles:
            # Preserve the ordinary CLI's argument domain beyond the bounded
            # batch interface; no title is skipped or truncated.
            title = matches[offset]['title']
            unchanged()
            value = cli_query(binary, root, 'export', *selection, '--case-sensitive', '--', title)
            unchanged()
            yield value
            value = None
            offset += 1
            continue
        unchanged()
        hints = [reference_hints.get(title, '0' * 64) for title in titles] if reference_hints is not None else None
        if session is None:
            argv = [str(binary.resolve()), 'export', '--root', str(root),
                    '--format', 'json', *selection, '--batch', '--case-sensitive']
            if hints is not None:
                argv.extend(['--audit-reference-hints', ''.join(hints)])
            stream = checked_export_stream([*argv, '--', *titles])
        else:
            stream = session(titles, hints)
        with stream as spool:
            unchanged()
            for index, title in enumerate(titles):
                line = spool.readline()
                require(bool(line) and line.endswith(b'\n'), 'incomplete export batch')
                value = json.loads(line)
                line = None
                reference = None
                if hints is not None:
                    require(isinstance(value, dict) and set(value) == {'response', 'reference', 'reused'},
                            'invalid audit reference envelope')
                    value, reference, reused = value['response'], value['reference'], value['reused']
                    require(isinstance(value, dict) and (reference is None or isinstance(reference, str) and
                            re.fullmatch('[0-9a-f]{64}', reference) is not None), 'invalid audit reference')
                    if reused is not None:
                        require(isinstance(reused, dict) and set(reused) == {'kind', 'title', 'redirect'} and
                                reference == hints[index] and reference == reference_hints.get(title),
                                'unsolicited audit reference')
                    value.update(audit_reference=reference, audit_reused=reused)
                require(isinstance(value, dict) and value.get('schema') == 'dict.results.v1' and
                        value.get('operation') == 'lookup' and value.get('query') == title and
                        value.get('match_mode') == 'exact-utf8', 'batch response/query mismatch')
                yield value
                if reference is not None:
                    reference_hints[title] = reference
                value = None
            require(spool.read(1) == b'', 'unexpected extra batch response')
        offset += len(titles)


def nested_json(value):
    return json.dumps(value, ensure_ascii=False, indent=2).replace('\n', '\n  ')


def row_body(rows):
    return nested_json(rows).removeprefix('[').removesuffix('\n  ]')


class ReportRows:
    """Keep small results in memory and spool large diagnostic arrays as formatted JSON."""

    def __init__(self, resources):
        self.resources = resources
        self.pending = []
        self.count = 0
        self.storage = None
        self.writer = None

    def __len__(self):
        return self.count

    def append(self, row):
        if len(self.pending) == 128:
            self.flush()
        self.pending.append(row)
        self.count += 1

    def flush(self):
        if self.writer is None:
            self.storage = self.resources.enter_context(tempfile.SpooledTemporaryFile(max_size=2 * 1024 * 1024))
            self.writer = self.resources.enter_context(export_spool(self.storage, 'wb'))
        else:
            self.writer.write(b',')
        self.writer.write(row_body(self.pending).encode('utf-8'))
        self.pending.clear()

    def chunks(self):
        if self.writer is None:
            yield nested_json(self.pending)
            return
        if self.pending:
            self.flush()
        self.writer.close()
        self.storage.seek(0)
        yield '['
        with io.TextIOWrapper(export_spool(self.storage, 'rb'), encoding='utf-8', newline='') as stream:
            while chunk := stream.read(128 * 1024):
                yield chunk
        yield '\n  ]'


def report_chunks(result):
    """Use the standard JSON encoder on bounded slices of the large top-level arrays."""

    if not result:
        yield '{}\n'
        return
    yield '{\n'
    for index, (key, value) in enumerate(result.items()):
        if index:
            yield ',\n'
        yield '  ' + json.dumps(key, ensure_ascii=False) + ': '
        if isinstance(value, ReportRows):
            yield from value.chunks()
        elif isinstance(value, list) and len(value) > 128:
            yield '['
            for offset in range(0, len(value), 128):
                if offset:
                    yield ','
                yield row_body(value[offset:offset + 128])
            yield '\n  ]'
        else:
            yield nested_json(value)
    yield '\n}\n'


def write_report(path, result):
    path.parent.mkdir(parents=True, exist_ok=True)
    with ExitStack() as resources:
        stream = resources.enter_context(path.open('wb'))
        if path.suffix == '.gz':
            stream = resources.enter_context(gzip.GzipFile(filename='', fileobj=stream, mode='wb',
                                                         compresslevel=1, mtime=0))
        for part in report_chunks(result):
            stream.write(part.encode('utf-8'))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    installed_reader = Path('zig-out/bin/wikidict')
    parser.add_argument('--binary', type=Path, default=installed_reader)
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--report', type=Path, required=True, help='JSON report path. A .gz suffix writes gzip-compressed JSON.')
    parser.add_argument('--summary-json', action='store_true', help='Print counts and status as JSON after writing the full report.')
    parser.add_argument('--definition-dump', type=Path, action='append',
                        help='Compare simple numbered definitions to the selected original XML. Supply every .xml.bz2 part.')
    parser.add_argument('--definition-registry', type=Path,
                        help='Match literal localized headings by code using the selected build’s language-registry.tsv.')
    parser.add_argument('--batch-size', type=int, choices=range(1, 65),
                        help='Exact exports per Reader process (default: 32 with the installed wikidict, 1 with another binary)')
    parser.add_argument('--audit-reference-hints', action='store_true',
                        help='Reuse confirmed fixed-feature redirect bodies with a compatible Reader')
    parser.add_argument('--audit-export-session', action='store_true',
                        help='Reuse the Store across batches on an unchanged view with a compatible Reader')
    parser.add_argument('--audit-alias-references', action='store_true',
                        help='Reuse validated redirect bodies when the target is absent in the selected language')
    parser.add_argument('--catalog-page-size', type=int, metavar='N',
                        help='Read N language indexes per native catalog request (1–1000)')
    args = parser.parse_args()
    if args.audit_alias_references and not (args.audit_reference_hints and args.audit_export_session):
        parser.error('--audit-alias-references requires --audit-reference-hints and --audit-export-session')
    if args.catalog_page_size is not None and not 1 <= args.catalog_page_size <= 1000:
        parser.error('--catalog-page-size must be between 1 and 1000')
    if args.definition_registry and not args.definition_dump:
        parser.error('--definition-registry requires --definition-dump')
    if args.batch_size is None:
        args.batch_size = 32 if args.binary.resolve() == installed_reader.resolve() else 1
    if args.audit_reference_hints and args.batch_size == 1:
        parser.error('--audit-reference-hints requires batch export')
    if args.audit_export_session and args.batch_size == 1:
        parser.error('--audit-export-session requires batch export')

    with ExitStack() as report_files:
        return run_audit(args, report_files)


def run_audit(args, report_files):
    def query(*parts):
        return cli_query(args.binary, args.root, *parts)

    try:
        exports = None
        if args.batch_size > 1 or args.definition_dump:
            prepare_index_directories(args.root)
            before = dictionary_snapshot(args.root)
            binary_before = dictionary_snapshot(args.binary)
            def unchanged():
                require(dictionary_snapshot(args.root) == before, 'dictionary source changed during audit')
                require(dictionary_snapshot(args.binary) == binary_before, 'CLI binary changed during audit')
            if args.batch_size > 1:
                hints = {} if args.audit_reference_hints else None
                selected, exchange = None, None
                def exports(selection, matches):
                    def send(titles, batch_hints):
                        nonlocal selected, exchange
                        if selection != selected:
                            sessions.close()
                            unchanged()
                            argv = [str(args.binary.resolve()), 'export', '--root', str(args.root),
                                    '--format', 'json', *selection, '--batch-session', '--case-sensitive']
                            exchange = sessions.enter_context(checked_export_session(argv, alias_references=args.audit_alias_references))
                            selected = selection
                        return exchange(titles, batch_hints)
                    return batch_exports(args.binary, args.root, selection, matches, args.batch_size,
                                         unchanged, hints, send if args.audit_export_session else None)
        with ExitStack() as resources:
            sessions = resources.enter_context(ExitStack())
            review = None
            if args.definition_dump:
                from source_definition_audit import SourceDefinitions
                review = SourceDefinitions('', args.root, args.definition_dump, args.definition_registry)
                resources.callback(review.close)
            result = scan(args.root, query, exports, observe_record=review.observe if review and review.has_definitions else None,
                          audit_references=args.audit_reference_hints, row_factory=lambda: ReportRows(report_files),
                          catalog_page_size=args.catalog_page_size, audit_alias_references=args.audit_alias_references)
            if review is not None:
                definitions = review.report()
                result['source_definitions'] = definitions
                if definitions['unmatched']:
                    result['status'] = 'failed'
                examples = len(definitions['examples'])
                if definitions['unmatched'] > examples:
                    locations = ReportRows(report_files)
                    for location in review.unmatched_locations(after_examples=examples):
                        locations.append(location)
                    result['additional_unmatched_definitions'] = locations
        if args.batch_size > 1 or args.definition_dump:
            unchanged()
        if args.batch_size > 1:
            result['export_transport'] = dict(mode='guarded-native-json-lines', batch_size=args.batch_size,
                timeout_seconds=60, immutable_source_guard=True, logical_commands=result['commands'])
    except (OSError, subprocess.SubprocessError, sqlite3.Error, ValueError, KeyError, TypeError) as error:
        result = dict(status='error', scan_complete=False, diagnostic_only=True,
                      semantic_acceptance=False, error=f'{type(error).__name__}: {error}')
    write_report(args.report, result)
    if args.summary_json:
        summary = {k: result[k] for k in ('status', 'scan_complete', 'semantic_acceptance', 'error', 'records') if k in result}
        if 'issues' in result:
            summary['review_fields'] = len(result['issues'])
        if 'source_definitions' in result:
            summary.update({k: result['source_definitions'][k] for k in ('eligible', 'matched', 'unmatched', 'matched_example')})
        print(json.dumps(summary, ensure_ascii=False))
    elif result['status'] == 'error':
        print(f"PRESENTATION_AUDIT error {result['error'][:500]}")
    else:
        print(f"PRESENTATION_AUDIT {result['status']} records={result['records']} "
              f"issues={len(result['issues'])} views={result['view_count']} commands={result['commands']}")
        if 'source_definitions' in result:
            score = result['source_definitions']
            print(f"SOURCE_DEFINITIONS matched={score['matched']} eligible={score['eligible']} "
                  f"unmatched={score['unmatched']}")
    return 2 if result['status'] == 'error' else int(result['status'] == 'failed')


if __name__ == '__main__':
    raise SystemExit(main())
