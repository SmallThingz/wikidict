#!/usr/bin/env python3
"""Check recovery fixtures against the live MediaWiki parse endpoint (read-only)."""
import argparse
from html.parser import HTMLParser
import json
from pathlib import Path
import time
import urllib.parse
import urllib.request

class VisibleText(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.parts = []
    def handle_data(self, data):
        self.parts.append(data)
    def handle_starttag(self, tag, attrs):
        if tag in {'p', 'div', 'li', 'br', 'tr'}:
            self.parts.append(' ')
    def handle_endtag(self, tag):
        if tag in {'p', 'div', 'li', 'tr'}:
            self.parts.append(' ')
    def text(self):
        return ' '.join(''.join(self.parts).split())

def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--endpoint', default='https://en.wiktionary.org/w/api.php')
    p.add_argument('--fixtures', type=Path, default=Path(__file__).parent/'fixtures/mediawiki_recovery.json')
    p.add_argument('--out', type=Path, required=True, help='Report file including the returned HTML')
    args = p.parse_args()
    results = []
    for case in json.loads(args.fixtures.read_text()):
        query = urllib.parse.urlencode(dict(action='parse', format='json', text=case['source'],
            contentmodel='wikitext', prop='text', disablelimitreport=1))
        request = urllib.request.Request(args.endpoint+'?'+query, headers={
            'User-Agent':'WikidictBuildTests/0.1 (https://github.com/SmallThingz/wikidict)'})
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                payload = json.load(response)
            html = payload['parse']['text']['*']
            parser = VisibleText(); parser.feed(html)
            actual = parser.text()
            result = dict(name=case['name'], passed=actual == case['text'], expected=case['text'], actual=actual, html=html)
        except Exception as error:
            result = dict(name=case['name'], passed=False, error=str(error))
        results.append(result)
        print(('PASS' if result['passed'] else 'FAIL')+' '+case['name'], flush=True)
        time.sleep(0.2)
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(dict(endpoint=args.endpoint, results=results), ensure_ascii=False, indent=2)+'\n')
    if not all(r['passed'] for r in results):
        raise SystemExit(1)
if __name__ == '__main__':
    main()
