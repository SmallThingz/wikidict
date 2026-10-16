#!/usr/bin/env python3
"""Flag supported decoded CLI views for manual review; never semantic acceptance.

This is an opt-in per-title diagnostic, not a production completion gate. Its
command/view counts expose scan cost. Raw DAL1 alias presentation is not exposed
by the CLI; aliases are covered only through its selected, one-hop export view.
"""
import argparse
import hashlib
import json
import re
import subprocess
from pathlib import Path

MARKUP = re.compile(r'\[\[|\]\]|\{\{|\}\}|</?[A-Za-z][^>]*>|\{\||\|}')
# Decoded spans do not preserve reliable nowiki/source provenance. Intentional
# literal spellings need source-backed disposition, including code=true spans.
BEHAVIOR_SWITCH = re.compile(r'__\w+__')
ERROR_PROSE = re.compile(r'\b(?:Lua|Script|Parser|Scribunto)\s+error\b', re.IGNORECASE)
UNAVAILABLE_TEMPLATE = re.compile(r'\[unavailable template:', re.IGNORECASE)
FEATURE_KINDS = ('thesaurus', 'citations', 'reconstruction', 'rhymes',
                 'sign-gloss', 'supplemental')
SUPPORTED_KINDS = ('language', *FEATURE_KINDS)


class ScanError(ValueError):
    pass


def diagnostic_categories(text):
    return [name for name, pattern in (
        ('source-markup', MARKUP), ('behavior-switch', BEHAVIOR_SWITCH),
        ('error-prose', ERROR_PROSE), ('unavailable-template', UNAVAILABLE_TEMPLATE)
    ) if pattern.search(text)]


def text_fields(value, path='entry'):
    if isinstance(value, dict):
        for key, child in value.items():
            if key in ('text', 'caption', 'title', 'trail') and isinstance(child, str):
                yield path + '.' + key, child
            else:
                yield from text_fields(child, path + '.' + key)
    elif isinstance(value, list):
        if value and all(isinstance(span, dict) and 'text' in span and 'kind' in span for span in value):
            yield path, ''.join(span['text'] + span.get('trail', '') for span in value)
            return
        for index, child in enumerate(value):
            yield from text_fields(child, f'{path}[{index}]')


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
    require(coverage.get('version') == 1 and isinstance(coverage.get('namespaces'), list),
            'invalid namespace coverage')
    rows, ids = coverage['namespaces'], set()
    for row in rows:
        require(natural(row['id']) and row['id'] not in ids and
                all(natural(row[field]) for field in ('expanded_pages', 'fallback_pages', 'alias_pages')),
                'invalid namespace alias accounting')
        require(row['alias_pages'] <= row['expanded_pages'] + row['fallback_pages'],
                'namespace aliases exceed completed pages')
        ids.add(row['id'])
    return rows


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


def scan(root, query):
    require(root.is_dir(), 'root does not exist')
    result = dict(records=0, issues=[], views=[], search_matches=0,
                  duplicate_destinations=0, alias_views=0, commands=0,
                  diagnostic_only=True, semantic_acceptance=False, scan_complete=False,
                  scope=dict(record_kinds=list(SUPPORTED_KINDS),
                             inventory='native language accounting and emitted fixed-kind files',
                             aliases='selected CLI export view, including one-hop follows; not raw DAL1 coverage',
                             protected_literal_provenance=False,
                             behavior_aliases='literal double-underscore word pattern; not an exhaustive registry'),
                  status_meaning='failed: review candidates; passed: no candidates in supported views; error: incomplete scan')

    def ask(*parts):
        result['commands'] += 1
        value = query(*parts)
        require(isinstance(value, dict), 'non-object CLI response')
        return value

    destinations = {}
    for view in emitted_views(root, ask('languages'), ask):
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
            for match in matches:
                title = match['title']
                require(isinstance(title, str) and title and (previous is None or title > previous),
                        'duplicate or nonprogressing owner/title')
                previous = title
                summary['matches'] += 1
                result['search_matches'] += 1
                exported = ask('export', *selection, '--case-sensitive', '--', title)
                require(exported.get('kind') == view['kind'].replace('-', '_') and
                        exported.get('language') == view['language'], 'export selection owner mismatch')
                entries = exported['entries']
                require(isinstance(entries, list) and len(entries) == 1, 'missing or ambiguous export')
                entry = entries[0]
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
                # A followed alias changes routing metadata, not destination
                # content. Scan that content once while retaining query joins
                # on its first issue occurrence and explicit duplicate counts.
                content = {key: value for key, value in entry.items() if key != 'redirect'}
                identity = (actual_kind, owner, actual_title)
                digest = hashlib.sha256(json.dumps(content, ensure_ascii=False, sort_keys=True).encode()).digest()
                if identity in destinations:
                    require(destinations[identity] == digest, 'conflicting duplicate destination')
                    summary['duplicate_destinations'] += 1
                    result['duplicate_destinations'] += 1
                    continue
                destinations[identity] = digest
                result['records'] += 1
                summary['unique_records'] += 1
                for path, text in text_fields(content):
                    categories = diagnostic_categories(text)
                    if categories:
                        result['issues'].append(dict(kind=actual_kind, language=owner, title=actual_title,
                            view_kind=view['kind'], view_language=view['language'], query_title=title,
                            source_title=redirect['source_title'] if redirect else title,
                            redirect=redirect, path=path, text=text[:500], categories=categories))
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


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, default=Path('zig-out/bin/dict'))
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--report', type=Path, required=True)
    args = parser.parse_args()

    def query(*parts):
        return cli_query(args.binary, args.root, *parts)

    try:
        result = scan(args.root, query)
    except (OSError, subprocess.SubprocessError, ValueError, KeyError, TypeError) as error:
        result = dict(status='error', scan_complete=False, diagnostic_only=True,
                      semantic_acceptance=False, error=f'{type(error).__name__}: {error}')
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n')
    if result['status'] == 'error':
        print(f"PRESENTATION_AUDIT error {result['error'][:500]}")
    else:
        print(f"PRESENTATION_AUDIT {result['status']} records={result['records']} "
              f"issues={len(result['issues'])} views={result['view_count']} commands={result['commands']}")
    return 2 if result['status'] == 'error' else int(bool(result['issues']))


if __name__ == '__main__':
    raise SystemExit(main())
