import io
import json
from pathlib import Path
import struct
import sys
import tempfile
import unittest
import urllib.error
from email.utils import formatdate
from unittest import mock
from types import SimpleNamespace

sys.dont_write_bytecode = True
from verify_wikimedia import (decode_reply, select_pages, source_at, render_signature,
                              unresolved_syntax, dependency_revisions, compare, request_payload, NativeWorker, API)


class VerifyWikimediaTest(unittest.TestCase):
    def setUp(self):
        Path('.tmp').mkdir(exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(dir='.tmp')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def test_endpoint_backoff_preserves_cached_checks_and_defers_other_cases(self):
        api = API('https://example.invalid/api', self.root, 0.5, 2, 'offline-test')
        ok = lambda: self.api_response({'ok': 1})
        unavailable = urllib.error.HTTPError(api.endpoint, 429, 'slow down', {'Retry-After': '90'}, io.BytesIO())
        with mock.patch('verify_wikimedia.time.monotonic', return_value=1000) as clock, \
                mock.patch('verify_wikimedia.time.sleep') as sleep, \
                mock.patch('verify_wikimedia.urllib.request.urlopen', side_effect=[ok(), unavailable, ok()]) as fetch:
            self.assertEqual(api.call(title='cached'), {'ok': 1})
            clock.return_value += 1
            with self.assertRaisesRegex(RuntimeError, '90.0s remaining'):
                api.call(title='first')
            self.assertEqual(api.call(title='cached'), {'ok': 1})
            clock.return_value += 45
            with self.assertRaisesRegex(RuntimeError, '45.0s remaining'):
                api.call(title='second')
            sleep.assert_not_called()
            self.assertEqual(fetch.call_count, 2)
            clock.return_value += 45
            self.assertEqual(api.call(title='second'), {'ok': 1})
            self.assertEqual(fetch.call_count, 3)

    @staticmethod
    def api_response(data, headers=None):
        response = io.BytesIO(json.dumps(data).encode())
        response.headers = headers or {}
        return response

    def test_maxlag_http_date_paces_the_next_request_from_response_time(self):
        api = API('https://example.invalid/api', self.root, 0.5, 2, 'offline-test')
        maxlag = self.api_response({'error': {'code': 'maxlag'}}, {'Retry-After': formatdate(1017, usegmt=True)})
        with mock.patch('verify_wikimedia.time.time', return_value=1000), \
                mock.patch('verify_wikimedia.time.monotonic', return_value=2000) as clock, \
                mock.patch('verify_wikimedia.time.sleep', side_effect=lambda delay: setattr(clock, 'return_value', clock.return_value + delay)) as sleep, \
                mock.patch('verify_wikimedia.urllib.request.urlopen', side_effect=[maxlag, self.api_response({'ok': 1})]):
            self.assertEqual(api.call(title='delayed'), {'ok': 1})
            sleep.assert_called_once_with(17)

    def test_last_error_still_defers_next_case(self):
        api = API('https://example.invalid/api', self.root, 0.5, 2, 'offline-test')
        errors = [urllib.error.HTTPError(api.endpoint, 503, 'busy', {'Retry-After': delay}, io.BytesIO())
                  for delay in ('0', '0', '120')]
        with mock.patch('verify_wikimedia.time.monotonic', return_value=1000), \
                mock.patch('verify_wikimedia.time.sleep'), \
                mock.patch('verify_wikimedia.urllib.request.urlopen', side_effect=errors) as fetch:
            with self.assertRaises(urllib.error.HTTPError):
                api.call(title='first')
            with self.assertRaisesRegex(RuntimeError, '120.0s remaining'):
                api.call(title='second')
            self.assertEqual(fetch.call_count, 3)

    def test_unrecognized_retry_after_prevents_another_request(self):
        api = API('https://example.invalid/api', self.root, 0.5, 2, 'offline-test')
        maxlag = self.api_response({'error': {'code': 'maxlag'}}, {'Retry-After': 'later'})
        with mock.patch('verify_wikimedia.urllib.request.urlopen', return_value=maxlag) as fetch:
            with self.assertRaisesRegex(ValueError, 'Unrecognized Retry-After'):
                api.call(title='first')
            with self.assertRaisesRegex(RuntimeError, 'deferred'):
                api.call(title='second')
            self.assertEqual(fetch.call_count, 1)

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

    def test_v5_request_serializes_selected_identity_and_fragment(self):
        page = dict(title="Acara:Wikilatih Wikioca'", ordinal=7, index_offset=123,
                    page_id=8451, revision=32521, namespace=0)
        payload = request_payload('root', 'dump.xml', 42, page, 'redirect tail')
        header = struct.unpack('<BqQQQQIIIII', payload[:61])
        self.assertEqual(header[:7], (5, 42, 7, 123, 8451, 32521, 0))
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

    @staticmethod
    def timed(payload, cpu_ns):
        return b'\x85' + payload + struct.pack('<Q', cpu_ns)

    def worker_with(self, frames):
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

    def test_native_ready_handshake_is_once_per_child(self):
        success = b'\0' + struct.pack('<II', 1, 0) + b'\0x'
        worker = self.worker_with([self.timed(b'\3', 10), self.timed(success, 20), self.timed(success, 20)])
        self.assertEqual(worker.read_reply(1), ('x', ''))
        self.assertTrue(worker.ready_received)
        self.assertEqual(worker.last_reply_cpu_ns, 20)
        self.assertEqual(worker.read_reply(1), ('x', ''))
        with self.assertRaisesRegex(ValueError, 'before readiness'):
            self.worker_with([self.timed(success, 20)]).read_reply(1)
        with self.assertRaisesRegex(ValueError, 'Duplicate'):
            self.worker_with([self.timed(b'\3', 10), self.timed(b'\3', 20)]).read_reply(1)
        failure = b'\1' + struct.pack('<III', 6, 3, 0) + b'assetsbad'
        worker = self.worker_with([self.timed(failure, 5)])
        with self.assertRaisesRegex(RuntimeError, 'assets: bad'):
            worker.read_reply(1)
        self.assertEqual(worker.last_reply_cpu_ns, 5)
        self.assertFalse(worker.ready_received)

    def test_timed_envelope_rejects_legacy_truncation_and_regression(self):
        success = b'\0' + struct.pack('<II', 1, 0) + b'\0x'
        ready = self.timed(b'\3', 10)
        for bad in (b'\3', success, b'\x84' + ready[1:], ready[:-1], ready + b'x',
                    self.timed(b'\3x', 10), self.timed(b'\x85', 10)):
            with self.subTest(frame=bad):
                worker = self.worker_with([bad])
                with self.assertRaises(ValueError):
                    worker.read_reply(1)
                self.assertIsNone(worker.last_reply_cpu_ns)
        worker = self.worker_with([ready, self.timed(success, 9)])
        with self.assertRaisesRegex(ValueError, 'CPU stamp regressed'):
            worker.read_reply(1)
        self.assertIsNone(worker.last_reply_cpu_ns)
        for size in (0, 32 * 1024 * 1024 + 1):
            worker = self.worker_with([])
            worker.transfer = lambda *args: struct.pack('<I', size)
            with self.assertRaisesRegex(ValueError, 'reply length'):
                worker.read_reply(1)

    def test_timed_variants_preserve_metadata_errors_and_cpu(self):
        for tag, metadata in ((0, []), (4, [b'poem']), (5, [b'missing']), (6, [b'poem', b'missing'])):
            payload = bytes([tag]) + struct.pack('<II', 2, 3) + b'\0'
            payload += struct.pack('<' + 'I' * len(metadata), *map(len, metadata))
            payload += 'é字'.encode() + b''.join(metadata)
            worker = self.worker_with([self.timed(b'\3', 0), self.timed(payload, 2**64 - 1)])
            self.assertEqual(worker.read_reply(1), ('é', '字'))
            self.assertEqual(worker.last_reply_cpu_ns, 2**64 - 1)
            bad = self.worker_with([self.timed(b'\3', 0), self.timed(payload[:-1], 5)])
            with self.assertRaises(ValueError):
                bad.read_reply(1)
            self.assertIsNone(bad.last_reply_cpu_ns)
        for payload, message in ((b'\1' + struct.pack('<III', 6, 3, 6) + b'expandbaddetail', 'expand: bad: detail'),
                                 (b'\0' + struct.pack('<II', 1, 0) + b'\1x', 'Native expansion unverified')):
            worker = self.worker_with([self.timed(b'\3', 10), self.timed(payload, 15)])
            with self.assertRaisesRegex(RuntimeError, message):
                worker.read_reply(1)
            self.assertEqual(worker.last_reply_cpu_ns, 15)
        with self.assertRaisesRegex(ValueError, 'noncanonical'):
            self.worker_with([self.timed(b'\3', 0), self.timed(b'\2', 5)]).read_reply(1)

    def test_expand_keeps_deadline_identity_and_error_cleanup(self):
        page = dict(title='title', ordinal=7, index_offset=123, page_id=8451, revision=32521, namespace=0)
        success = b'\0' + struct.pack('<II', 1, 0) + b'\0x'
        worker = NativeWorker(Path('worker'), 'root', 'dump', 42, 2.5, None)
        child = mock.Mock()
        frames = [self.timed(b'\3', 10), self.timed(success, 20)]
        pieces = [piece for frame in frames for piece in (struct.pack('<I', len(frame)), frame)]
        expected = request_payload('root', 'dump', 42, page, 'exact source')
        def transfer(pipe, value, writing, deadline):
            self.assertEqual(deadline, 1002.5)
            if writing:
                self.assertIs(pipe, child.stdin)
                self.assertEqual(value, struct.pack('<I', len(expected)) + expected)
                return b''
            self.assertIs(pipe, child.stdout)
            piece = pieces.pop(0)
            self.assertEqual(len(piece), value)
            return piece
        worker.transfer = transfer
        with mock.patch('verify_wikimedia.subprocess.Popen', return_value=child) as popen, \
             mock.patch('verify_wikimedia.os.set_blocking'), \
             mock.patch('verify_wikimedia.time.monotonic', return_value=1000):
            self.assertEqual(worker.expand(page, 'exact source'), ('x', ''))
            self.assertEqual(popen.call_args.args, (['worker'],))
            self.assertEqual(worker.last_reply_cpu_ns, 20)
            worker.transfer = mock.Mock(side_effect=TimeoutError('deadline'))
            with self.assertRaisesRegex(TimeoutError, 'deadline'):
                worker.expand(page, 'exact source')
        child.kill.assert_called_once()
        child.wait.assert_called_once()
        child.stdin.close.assert_called_once()
        child.stdout.close.assert_called_once()
        self.assertIsNone(worker.child)
        self.assertFalse(worker.ready_received)
        self.assertIsNone(worker._child_cpu_ns)
        self.assertIsNone(worker.last_reply_cpu_ns)
        # A new child may start from a smaller cumulative CPU stamp.
        fresh = self.worker_with([self.timed(b'\3', 1), self.timed(success, 2)])
        worker.child, worker.transfer = fresh.child, fresh.transfer
        self.assertEqual(worker.read_reply(1), ('x', ''))
        self.assertEqual(worker.last_reply_cpu_ns, 2)

    def test_completed_failure_keeps_cpu_stamp_after_child_cleanup(self):
        failure = b'\1' + struct.pack('<III', 6, 3, 6) + b'expandbaddetail'
        worker = self.worker_with([self.timed(b'\3', 10), self.timed(failure, 15)])
        read = worker.transfer
        worker.transfer = lambda pipe, value, writing, deadline: b'' if writing else read(pipe, value, writing, deadline)
        child = mock.Mock()
        worker.child = child
        worker.root, worker.dump = 'root', 'dump'
        page = dict(title='title', ordinal=1, index_offset=10, page_id=2, revision=3, namespace=0)
        with self.assertRaisesRegex(RuntimeError, 'expand: bad: detail'):
            worker.expand(page, 'exact source')
        self.assertEqual(worker.last_reply_cpu_ns, 15)
        self.assertIsNone(worker._child_cpu_ns)
        self.assertFalse(worker.ready_received)
        child.kill.assert_called_once()
        child.wait.assert_called_once()
        with self.assertRaises(KeyError):
            worker.expand({}, 'source')
        self.assertIsNone(worker.last_reply_cpu_ns)

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
