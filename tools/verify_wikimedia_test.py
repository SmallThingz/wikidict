import json
from pathlib import Path
import struct
import sys
import tempfile
import unittest
from types import SimpleNamespace

sys.dont_write_bytecode = True
from verify_wikimedia import (decode_reply, select_pages, source_at, render_signature,
                              unresolved_syntax, dependency_revisions, compare, request_payload, NativeWorker)


class VerifyWikimediaTest(unittest.TestCase):
    def setUp(self):
        Path('.tmp').mkdir(exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(dir='.tmp')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def test_selected_identity_preserves_exact_binary_row_offset(self):
        index = self.root / 'index'
        header = b'# raw fixture\n\n'
        first = '0\t1\técole\t\t11\t21\ttime\tuser\twikitext\t0\t1\t0\n'.encode()
        second = b"1\t1\tAcara:Wikilatih Wikioca'\t\t8451\t32521\ttime\tuser\twikitext\t0\t1\t0"
        index.write_bytes(header + first + second)
        selected, targets, _, population = select_pages(index, 2, 42, ['école', "Acara:Wikilatih Wikioca'"])
        self.assertEqual(population, 2)
        self.assertEqual(selected[0]['index_offset'], len(header))
        exact = targets["Acara:Wikilatih Wikioca'"]
        self.assertEqual((exact['ordinal'], exact['index_offset'], exact['page_id'], exact['revision'], exact['namespace']),
                         (1, len(header + first), 8451, 32521, 0))
        self.assertEqual(index.read_bytes()[exact['index_offset']:], second)

    def test_v4_request_serializes_selected_identity_and_fragment(self):
        page = dict(title="Acara:Wikilatih Wikioca'", ordinal=7, index_offset=123,
                    page_id=8451, revision=32521, namespace=0)
        payload = request_payload('root', 'dump.xml', 42, page, 'redirect tail')
        header = struct.unpack('<BqQQQQIIIII', payload[:61])
        self.assertEqual(header[:7], (4, 42, 7, 123, 8451, 32521, 0))
        self.assertEqual(header[7:], (4, 8, len(page['title'].encode()), 13))
        self.assertEqual(payload[61:], b'rootdump.xml' + page['title'].encode() + b'redirect tail')
        for key in ('index_offset', 'page_id', 'revision', 'namespace'):
            missing = dict(page)
            del missing[key]
            with self.assertRaises(KeyError):
                request_payload('root', 'dump', 42, missing, '')
        for key, value in (('index_offset', -1), ('revision', 2**64), ('namespace', 2**32)):
            with self.assertRaises(ValueError):
                request_payload('root', 'dump', 42, dict(page, **{key: value}), '')

    def test_native_ready_handshake_is_once_per_child(self):
        success = b'\0' + struct.pack('<II', 1, 0) + b'\0x'
        def worker_with(frames):
            worker = NativeWorker(None, None, None, 42, 1, None)
            worker.child = SimpleNamespace(stdout=object())
            pieces = []
            for frame in frames:
                pieces.extend((struct.pack('<I', len(frame)), frame))
            def transfer(pipe, size, writing, deadline):
                value = pieces.pop(0)
                self.assertFalse(writing)
                self.assertEqual(size, len(value))
                return value
            worker.transfer = transfer
            return worker
        worker = worker_with([b'\3', success, success])
        self.assertEqual(worker.read_reply(1), ('x', ''))
        self.assertTrue(worker.ready_received)
        self.assertEqual(worker.read_reply(1), ('x', ''))
        with self.assertRaisesRegex(ValueError, 'before readiness'):
            worker_with([success]).read_reply(1)
        with self.assertRaisesRegex(ValueError, 'Duplicate'):
            worker_with([b'\3', b'\3']).read_reply(1)
        failure = b'\1' + struct.pack('<III', 6, 3, 0) + b'assetsbad'
        with self.assertRaisesRegex(RuntimeError, 'assets: bad'):
            worker_with([failure]).read_reply(1)

    def test_current_success_metadata_variants_keep_output_and_validate_lengths(self):
        for tag, metadata in ((4, [b'poem']), (5, [b'missing']), (6, [b'poem', b'missing'])):
            payload = bytes([tag]) + struct.pack('<II', 1, 0) + b'\0'
            payload += struct.pack('<' + 'I' * len(metadata), *map(len, metadata))
            payload += b'x' + b''.join(metadata)
            self.assertEqual(decode_reply(payload), ('x', ''))
            with self.assertRaises(ValueError):
                decode_reply(payload[:-1])
        with self.assertRaisesRegex(ValueError, 'metadata length'):
            decode_reply(b'\4' + struct.pack('<II', 1, 0) + b'\0' + struct.pack('<I', 0) + b'x')

    def test_protocol_lengths_errors_and_utf8(self):
        source, title = 'école'.encode(), '字'.encode()
        payload = b'\0' + struct.pack('<II', len(source), len(title)) + b'\0' + source + title
        self.assertEqual(decode_reply(payload), ('école', '字'))
        for bad in (b'', b'\2x', payload[:-1], payload + b'x',
                    payload[:9], payload[:9] + payload[10:],
                    payload[:9] + b'\2' + payload[10:]):
            with self.assertRaises(ValueError):
                decode_reply(bad)
        with self.assertRaisesRegex(RuntimeError, 'Native expansion unverified'):
            decode_reply(payload[:9] + b'\1' + payload[10:])
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
