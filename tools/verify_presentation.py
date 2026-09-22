#!/usr/bin/env python3
"""Audit decoded presentation text for source markup (diagnostic export only)."""
import argparse
import json
import re
import subprocess
from pathlib import Path

MARKUP = re.compile(r'\[\[|\]\]|\{\{|\}\}|</?[A-Za-z][^>]*>|\{\||\|\}')

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

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, default=Path('zig-out/bin/dict'))
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--report', type=Path, required=True)
    args = parser.parse_args()
    def query(*parts):
        return json.loads(subprocess.check_output([str(args.binary.resolve()), parts[0], '--root', str(args.root), '--format', 'json', *parts[1:]], timeout=60))
    issues, records = [], 0
    for language in query('languages')['languages']:
        offset = 0
        while True:
            page = query('search', '--language', language, '--limit', '1000', '--offset', str(offset))
            for match in page['matches']:
                for entry in query('export', '--language', language, '--', match['title'])['entries']:
                    records += 1
                    for path, text in text_fields(entry):
                        if MARKUP.search(text):
                            issues.append(dict(language=language, title=entry['title'], path=path, text=text[:500]))
            if not page['has_more']: break
            offset += len(page['matches'])
    result = dict(records=records, issues=issues, status='failed' if issues else 'passed')
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n')
    print(f"PRESENTATION_AUDIT {result['status']} records={records} issues={len(issues)}")
    return bool(issues)

if __name__ == '__main__':
    raise SystemExit(main())
