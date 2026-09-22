import json
from pathlib import Path
import struct
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True
from verify_wikimedia import (decode_reply, select_pages, source_at, render_signature,
                              unresolved_syntax, dependency_revisions, compare)


class VerifyWikimediaTest(unittest.TestCase):
    def setUp(self):
        Path('.tmp').mkdir(exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(dir='.tmp')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def test_protocol_lengths_errors_and_utf8(self):
        source, title = 'école'.encode(), '字'.encode()
        payload = b'\0' + struct.pack('<II', len(source), len(title)) + source + title
        self.assertEqual(decode_reply(payload), ('école', '字'))
        for bad in (b'', b'\2x', payload[:-1], payload + b'x'):
            with self.assertRaises(ValueError):
                decode_reply(bad)
        with self.assertRaisesRegex(ValueError, 'noncanonical'):
            decode_reply(b'\2')
        with self.assertRaisesRegex(RuntimeError, 'expand: bad: detail'):
            decode_reply(b'\1' + struct.pack('<III', 6, 3, 6) + b'expandbaddetail')

    def test_sampling_is_reproducible_and_excludes_redirects_and_namespaces(self):
        index = self.root / 'index'
        lines = []
        for n in range(100):
            lines.append(f'0\t1\tword{n}\t\t{n}\t{100+n}\ttime\tuser\twikitext\t0\t1\t0\n')
        lines += ['0\t1\tredirect\ttarget\t101\t201\ttime\tuser\twikitext\t0\t1\t0\n',
                  '0\t1\tModule:M\t\t102\t202\ttime\tuser\tScribunto\t828\t1\t0\n']
        index.write_text(''.join(lines))
        a = select_pages(index, 10, 42, ['word99'])
        self.assertEqual(a, select_pages(index, 10, 42, ['word99']))
        self.assertEqual(a[3], 100)
        self.assertEqual(len(a[0]), 10)
        self.assertEqual(a[1]['word99']['ordinal'], 99)
        self.assertEqual(a[2]['Module:M'], 202)
        self.assertTrue(any(p['ordinal'] > 50 for p in a[0]))

    def test_xml_decoding_is_single_pass(self):
        dump = self.root / 'dump.xml'
        raw = b'&amp;lt; &lt;nowiki&gt; &#xE9;'
        dump.write_bytes(b'prefix' + raw)
        self.assertEqual(source_at(dump, dict(offset=6, length=len(raw), decode=True)), '&lt; <nowiki> é')

    def test_render_comparison_keeps_semantic_attributes_and_whitespace(self):
        def sig(text):
            return render_signature(dict(text=text))
        self.assertEqual(sig('<p a="1" b="2">A&amp;B</p><!--time-->'), sig('<p b="2" a="1">A&B</p>'))
        self.assertNotEqual(sig('<pre>a b</pre>'), sig('<pre>a  b</pre>'))
        self.assertNotEqual(sig('<a href="/a">a</a>'), sig('<a href="/b">a</a>'))
        self.assertNotEqual(sig('<p class="error">bad</p>'), sig('<p>bad</p>'))
        self.assertTrue(unresolved_syntax('{{x}}'))
        self.assertFalse(unresolved_syntax('<nowiki>{{literal}}</nowiki>'))

    def test_server_cannot_rescue_unexpanded_local_template(self):
        class Worker:
            def expand(self, page, source):
                return '{{unexpanded}}', ''
        class API:
            def call(self, **params):
                return {'expandtemplates': {'wikitext': 'answer'}}
            def parse(self, title, source):
                return {'text': '<p>answer</p>'}
        case = dict(name='probe', page=dict(title='cat', revision=42), source='source', independent=True, expected_error=False)
        result = compare(case, Worker(), API(), self.root / 'case', True)
        self.assertEqual(result['status'], 'expansion_mismatch')
        self.assertTrue(result['render_equal'])

    def test_drift_is_unresolved_not_passed(self):
        class API:
            def call(self, **params):
                return {'query': {'pages': [{'title': 'Module:A', 'revisions': [{'revid': 2}]}]}}
        results = [dict(status='expansion_mismatch', dependencies=['Module:A']),
                   dict(status='expansion_mismatch', dependencies=[])]
        dependency_revisions(API(), results, {'Module:A': 1})
        self.assertEqual(results[0]['status'], 'mismatch_with_dependency_drift')
        self.assertEqual(results[1]['status'], 'mismatch')


if __name__ == '__main__':
    unittest.main()
