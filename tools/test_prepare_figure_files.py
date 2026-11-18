import argparse
import copy
import contextlib
import errno
import io
import os
import gzip
import hashlib
import json
import threading
import time
from pathlib import Path
import unittest
from unittest.mock import patch
from urllib.parse import parse_qs, urlsplit

import prepare_figure_metadata as figure
import prepare_file_metadata_v2 as metadata
import test_prepare_figure_metadata as occurrence_tests
import build_wiktionaries as builder


class FigureFileTests(unittest.TestCase):
    setUp = occurrence_tests.FigureInputTests.setUp
    write_projection = occurrence_tests.FigureInputTests.write_projection
    stage = occurrence_tests.FigureInputTests.stage

    def test_jpeg_supplement_joins_canonical_identity_without_inventing_requested_aliases(self):
        names,responses,full,bases,supplement=self.jpeg_supplement_fixture()
        alias='ملف:lowercase-request.jpg'
        old=json.loads(bases[0]['response'])
        old['query']['normalized']=[dict(**{'from':alias,'to':names[0]})]
        bases[0]=dict(requests=[alias],response=figure.encoded(old).decode())
        plain,_,_=self.epoch_document(bases)
        complete,_,_=self.epoch_document(bases+[supplement])
        self.assertEqual(plain['records'],complete['records'])
        self.assertEqual({r['requested_file'] for r in complete['records']},{alias,names[1]})
        extra=copy.deepcopy(old)
        extra_alias='ملف:other-request.jpg'
        extra['query']['normalized']=[dict(**{'from':extra_alias,'to':names[0]})]
        extra['query']['pages'][0]['imageinfo'][0]['metadata']=[{'name':'Orientation','value':6}]
        with self.assertRaises(ValueError):
            self.epoch_document(bases+[dict(requests=[extra_alias],response=figure.encoded(extra).decode()),supplement])
        for bad in (False,None,True):
            record=self.write_normal_retained('ambiguous-'+str(bad),full,names)
            data=json.loads(record.read_bytes());data.update(schema='wikidict.retained-jpeg-metadata-supplement.v1',jpeg_metadata_only=bad,observed_svg_width_px=200)
            record.write_bytes(figure.encoded(data))
            with self.assertRaises(ValueError):figure.retained_metadata_batch(record,self.wiki,self.date,self.namespace.read_bytes())

    def jpeg_supplement_fixture(self):
        names = ['ملف:First.jpg', 'ملف:Second.jpg']
        responses = []
        for name in names:
            value = self.response(name)
            value['query']['general']['git-hash'] = figure.FIGURE_CURRENT_CORE
            info = value['query']['pages'][0]['imageinfo'][0]
            info.update(mime='image/jpeg', mediatype='BITMAP')
            info.pop('metadata', None)
            responses.append(value)
        full = copy.deepcopy(responses[0])
        full['query']['pages'] += copy.deepcopy(responses[1]['query']['pages'])
        for page in full['query']['pages']:
            page['imageinfo'][0]['metadata'] = [{'name':'Orientation', 'value':1}]
        bases = [self.batch(name, value) for name,value in zip(names,responses)]
        supplement = dict(requests=names, response=figure.encoded(full).decode(), jpeg_metadata_only=True)
        return names, responses, full, bases, supplement

    def test_jpeg_supplement_preserves_complete_base_facts_raw_and_provider(self):
        names, responses, full, bases, supplement = self.jpeg_supplement_fixture()
        before = copy.deepcopy(bases)
        plain,_,_ = self.epoch_document(bases)
        complete,raw,site = self.epoch_document(bases+[supplement])
        self.assertEqual(complete['records'],plain['records'])
        self.assertEqual(b''.join(figure.provider_chunks(complete)),b''.join(figure.provider_chunks(plain)))
        self.assertEqual(bases,before)
        self.assertEqual(complete,figure.verify_figure_file_document(complete,raw,self.namespace.read_bytes(),self.wiki,self.date,site))
        self.assertEqual(json.loads(raw)['batches'][-1]['response'],figure.encoded(full).decode())
        self.assertEqual(len(complete['records']),2)

    def test_jpeg_supplement_rejects_contradictions_foreign_identity_and_unbound_rows(self):
        names,responses,full,bases,supplement = self.jpeg_supplement_fixture()
        for mode in range(12):
            with self.subTest(mode=mode):
                selected = copy.deepcopy(bases)
                extra = copy.deepcopy(supplement)
                response = copy.deepcopy(full)
                image = response['query']['pages'][0]['imageinfo'][0]
                if mode == 0:
                    old=json.loads(selected[0]['response']);old['query']['pages'][0]['imageinfo'][0]['metadata']=[{'name':'Orientation','value':6}];selected[0]['response']=figure.encoded(old).decode()
                elif mode == 1:image['sha1']='1'*40
                elif mode == 2:image['width']+=1
                elif mode == 3:image['size']+=1
                elif mode == 4:response['query']['pages'][0]['imagerepository']='local'
                elif mode == 5:image['metadata']=[{'name':'Orientation','value':6}]
                elif mode == 6:image.pop('metadata')
                elif mode == 7:extra['jpeg_metadata_only']=False
                elif mode == 8:response['query']['pages'].append(copy.deepcopy(response['query']['pages'][0]))
                elif mode == 9:extra['requests']=extra['requests'][:1]
                elif mode == 10:selected=[extra]+selected
                elif mode == 11:selected.append(extra)
                extra['response']=figure.encoded(response).decode()
                with self.assertRaises(ValueError):self.epoch_document(selected+[extra])
        for value in (None,[],{},[{'name':'Orientation','value':True}],[{'name':'_error','value':'0'},{'name':'Orientation','value':1}]):
            self.assertFalse(figure.jpeg_unrotated_metadata({'metadata':value}))
        self.assertTrue(figure.jpeg_unrotated_metadata({'metadata':[{'name':'_error','value':'0'}]}))

    def test_jpeg_supplement_normal_retained_capture_replays_without_http_or_parent_changes(self):
        self.epoch_defaults()
        names,responses,full,bases,supplement=self.jpeg_supplement_fixture()
        args=self.args(links=('First.jpg','Second.jpg'));args.figure_profile=figure.FIGURE_PROFILE_V4;args.batch_size=1
        def transport(url,timeout):
            title=parse_qs(urlsplit(url).query)['titles'][0]
            return 200,{},figure.encoded(responses[names.index(title)])
        parent_manifest=figure.capture_files(args,transport=transport,sleep=lambda _:None,target_contract=figure.REPLAY_CONTRACT_V4)
        parent=args.output;before={p.name:p.read_bytes() for p in parent.iterdir()}
        path=self.write_normal_retained('jpeg-companion',full,names)
        record=json.loads(path.read_bytes());record.update(schema='wikidict.retained-jpeg-metadata-supplement.v1',jpeg_metadata_only=True);path.write_bytes(figure.encoded(record))
        self.assertEqual(figure.retained_metadata_batch(path,self.wiki,self.date,self.namespace.read_bytes()),supplement)
        args.output=self.root/'jpeg-successor';args.reuse=[parent];args.reuse_batch=[path]
        manifest=figure.capture_files(args,transport=lambda *_:self.fail('JPEG supplement must not refetch'),target_contract=figure.REPLAY_CONTRACT_V4)
        self.assertEqual(figure.verify(args.output),manifest)
        self.assertEqual(self.stream_document(parent)['records'],self.stream_document(args.output)['records'])
        self.assertEqual((parent/figure.PROVIDER).read_bytes(),(args.output/figure.PROVIDER).read_bytes())
        self.assertEqual(before,{p.name:p.read_bytes() for p in parent.iterdir()})
        self.assertEqual(figure.verify(parent),parent_manifest)

    def test_two_slot_v4_resume_keeps_profile_and_exact_pending_authority(self):
        original_args,original_response=self.args,self.response
        def args(*values,**options):
            result=original_args(*values,**options);result.figure_profile=figure.FIGURE_PROFILE_V4
            return result
        def response(*values,**options):
            result=original_response(*values,**options)
            result['query']['general']['git-hash']=figure.FIGURE_CURRENT_CORE
            result['query']['pages'][0]['imageinfo'][0].update(mime='image/gif',mediatype='BITMAP')
            return result
        with patch.object(self,'args',side_effect=args),patch.object(self,'response',side_effect=response):
            self.test_two_slot_closed_prefix_reuses_accepted_lookahead_without_refetch()
        document=self.stream_document(self.root/'prepared-only')
        self.assertEqual(document['source_profile']['kind'],figure.FIGURE_PROFILE_V4)
        self.assertEqual(len(document['records']),4)
        self.assertTrue(all(row['mime']=='image/gif' and row['state']=='eligible' for row in document['records']))

    def overlap_clock(self):
        lock, value = threading.Lock(), [0.0]
        def now():
            with lock:
                return value[0]
        def advance(seconds):
            with lock:
                value[0] += seconds
        return now, advance


    def overlap_wall_stop(self):
        args = self.args(links=('Example.svg', 'Second.svg', 'Third.svg', 'Zlast.svg'))
        args.batch_size, args.max_inflight, args.wall_seconds = 1, 2, 3
        now, advance = self.overlap_clock()
        third, calls = threading.Event(), []
        def transport(url, timeout):
            title = parse_qs(urlsplit(url).query)['titles'][0]
            calls.append(title)
            if title.endswith('Second.svg'):
                self.assertTrue(third.wait(5), 'lookahead did not run concurrently')
                advance(0.5)
                raise OSError('temporary connection loss')
            if title.endswith('Third.svg'):
                third.set()
            return 200, {}, figure.encoded(self.response(title))
        with patch.object(figure.time, 'monotonic', side_effect=now):
            with self.assertRaisesRegex(ValueError, 'Retry exceeds bounded capture wait/deadline'):
                figure.capture_files(args, transport=transport, sleep=advance)
        self.assertEqual(calls[0], 'ملف:Example.svg')
        self.assertEqual(sorted(calls[1:]), ['ملف:Second.svg', 'ملف:Third.svg'])
        failure = json.loads((args.output/'figure-failure-0001.json').read_text())
        self.assertEqual((failure['committed_batches'], failure['pending_http']), (1, [2, 3]))
        self.assertFalse((args.output/figure.COMPLETE).exists())
        self.complete_resume_proof(args, 1)
        args.wall_seconds = 30
        return args


    def test_two_slots_overlap_but_publish_in_plan_order_at_one_start_per_second(self):
        args = self.args(links=('Example.svg', 'Second.svg', 'Third.svg', 'Zlast.svg'))
        args.batch_size, args.max_inflight = 1, 2
        second, third, starts, finishes = threading.Event(), threading.Event(), [], []
        active, peak, lock = [0], [0], threading.Lock()
        def transport(url, timeout):
            title = parse_qs(urlsplit(url).query)['titles'][0]
            with lock:
                starts.append((title, time.monotonic()));active[0] += 1;peak[0] = max(peak[0], active[0])
            self.assertFalse((args.output/figure.COMPLETE).exists())
            if title.endswith('Second.svg'):
                second.set()
                self.assertTrue(third.wait(5), 'second slot was never dispatched')
            if title.endswith('Third.svg'):
                self.assertTrue(second.wait(5), 'other transport did not enter')
                finishes.append(title);third.set()
            else:
                finishes.append(title)
            with lock:
                active[0] -= 1
            return 200, {}, figure.encoded(self.response(title))
        # Real monotonic start times avoid a fake clock jumping past an admitted
        # worker before that worker enters its transport. A small oversleep is
        # permitted by the policy; the asserted start interval remains one second.
        result = figure.capture_files(args, transport=transport, sleep=lambda seconds:time.sleep(seconds+0.01))
        self.assertEqual(peak[0], 2)
        self.assertEqual(active[0], 0)
        self.assertTrue(all(right[1]-left[1] >= 1 for left, right in zip(starts, starts[1:])))
        self.assertLess(finishes.index('ملف:Third.svg'), finishes.index('ملف:Second.svg'))
        batches = list(figure.stream_values(args.output/figure.ROLES['figure-sizing-raw'], figure.RAW_STREAM_SCHEMA))[1:]
        self.assertEqual([row['requests'][0] for row in batches],
            ['ملف:Example.svg','ملف:Second.svg','ملف:Third.svg','ملف:Zlast.svg'])
        self.assertEqual(json.loads((args.output/figure.PLAN).read_text())['max_inflight'], 2)
        self.assertEqual(figure.verify(args.output), result)


    def test_two_slots_retry_after_pauses_all_new_starts_and_preserves_attempt_evidence(self):
        root = self.root/'retry-slots';root.mkdir()
        registry = figure.evidence.Registry(self.namespace.read_bytes(), self.wiki, self.date)
        sleep = lambda seconds:time.sleep(seconds+0.01)
        pacing = metadata.RequestStartPacing(1, sleep)
        second, paused = threading.Event(), threading.Event()
        starts, attempts, pauses = [], {}, []
        real_pause = pacing.pause
        def pause(seconds):
            real_pause(seconds);pauses.append((time.monotonic(),seconds));paused.set()
        pacing.pause = pause
        def transport(url, timeout):
            title = parse_qs(urlsplit(url).query)['titles'][0]
            starts.append((title, time.monotonic()));attempts[title] = attempts.get(title, 0)+1
            if title.endswith('First.svg') and attempts[title] == 1:
                self.assertTrue(second.wait(5))
                return 429, {'Retry-After': '5'}, b'{"error":{"code":"ratelimited"}}'
            if title.endswith('Second.svg'):
                second.set();self.assertTrue(paused.wait(5))
            return 200, {}, figure.encoded(self.response(title))
        def request(number):
            title = ['ملف:First.svg', 'ملف:Second.svg', 'ملف:Third.svg'][number-1]
            titles=[title]
            metadata.document(root/f'file-metadata.request-{number:06d}.json',dict(titles=titles,
                query=metadata.query_for(self.wiki,titles,figure_axes=True),
                url=metadata.query_url(self.wiki,titles,figure_axes=True)))
            return metadata.request_batch(root, number, titles, registry, transport, sleep, time.monotonic()+30, 1,
                pacing, figure_axes=True, prepared_request=True)
        slots = metadata.OrderedRequestBatches(request, 1, 3, pacing, warm=True)
        try:
            refs = [slots.next(number)[1] for number in (1, 2, 3)]
        finally:
            error = slots.close()
        self.assertIsNone(error)
        self.assertEqual(sorted(title for title, _ in starts[:2]), ['ملف:First.svg', 'ملف:Second.svg'])
        self.assertEqual(len(pauses),1)
        self.assertTrue(all(start >= pauses[0][0]+5 for _, start in starts[2:]))
        self.assertTrue(all(right[1]-left[1] >= 1 for left, right in zip(starts, starts[1:])))
        self.assertEqual(refs[0]['accepted_receipt'], 'file-metadata.response-000001-02.receipt.json')
        failed = json.loads((root/'file-metadata.response-000001-01.receipt.json').read_text())
        self.assertEqual((failed['accepted'], failed['status'], failed['headers']['retry-after']), (False, 429, '5'))
        self.assertTrue((root/'file-metadata.response-000001-01.raw.json').exists())


    def test_two_slots_join_inflight_and_never_hide_access_failure_under_wall_stop(self):
        pacing = metadata.RequestStartPacing(1, lambda _: None)
        second, release, joined = threading.Event(), threading.Event(), threading.Event()
        calls, result = [], []
        def request(number):
            calls.append(number)
            if number == 1:
                self.assertTrue(second.wait(5))
                raise ValueError('Capture wall deadline reached')
            second.set();self.assertTrue(release.wait(5))
            raise ValueError('API HTTP status 403')
        slots = metadata.OrderedRequestBatches(request, 1, 3, pacing, warm=True,
            wall_errors=figure.WALL_ERRORS)
        def collect():
            try:
                slots.next(1)
            except BaseException as error:
                result.append(slots.close(error))
            finally:
                joined.set()
        worker = threading.Thread(target=collect)
        worker.start()
        try:
            self.assertTrue(second.wait(5))
            self.assertFalse(joined.wait(0.05), 'cleanup returned before in-flight request joined')
            release.set();worker.join(5)
        finally:
            release.set();worker.join(5)
        self.assertFalse(worker.is_alive())
        self.assertEqual(calls, [1, 2])
        self.assertEqual(str(result[0]), 'API HTTP status 403')
        self.assertTrue(pacing.stopped)
        with self.assertRaises(metadata.RequestStopped):
            pacing.wait(100)


    def test_two_slot_closed_prefix_reuses_accepted_lookahead_without_refetch(self):
        args = self.overlap_wall_stop()
        prefix = (args.output/figure.ROLES['figure-sizing-raw']).read_bytes()
        accepted = (args.output/'file-metadata.response-000003-01.raw.json').read_bytes()
        original_failure = (args.output/'figure-failure-0001.json').read_bytes()
        calls = []
        now, advance = self.overlap_clock()
        def transport(url, timeout):
            title = parse_qs(urlsplit(url).query)['titles'][0];calls.append(title)
            self.assertNotIn(title, ('ملف:Example.svg', 'ملف:Third.svg'))
            return 200, {}, figure.encoded(self.response(title))
        with patch.object(figure.time, 'monotonic', side_effect=now):
            result = figure.capture_files(args, transport=transport, sleep=advance)
        self.assertEqual(calls, ['ملف:Second.svg', 'ملف:Zlast.svg'])
        self.assertTrue((args.output/figure.ROLES['figure-sizing-raw']).read_bytes().startswith(prefix))
        batches = list(figure.stream_values(args.output/figure.ROLES['figure-sizing-raw'], figure.RAW_STREAM_SCHEMA))[1:]
        self.assertEqual(batches[2]['response'].encode(), accepted)
        self.assertEqual((args.output/'figure-failure-0001.json').read_bytes(), original_failure)
        self.assertEqual(figure.verify(args.output), result)
        # A deadline can occur after immutable request preparation but before
        # transport. That exact zero-attempt request is reusable, not evidence
        # that an HTTP call happened or permission to drop a pending name.
        args.output=self.root/'prepared-only';args.resume=None;args.wall_seconds=1
        now,advance=self.overlap_clock();calls.clear()
        def initial(url,timeout):
            title=parse_qs(urlsplit(url).query)['titles'][0];calls.append(title)
            return 200,{},figure.encoded(self.response(title))
        with patch.object(figure.time,'monotonic',side_effect=now):
            with self.assertRaisesRegex(ValueError,'Capture wall deadline reached'):
                figure.capture_files(args,transport=initial,sleep=advance)
        self.assertEqual(calls,['ملف:Example.svg'])
        self.assertTrue((args.output/'file-metadata.request-000002.json').exists())
        self.assertFalse(list(args.output.glob('file-metadata.response-000002-*')))
        self.complete_resume_proof(args,1);args.wall_seconds=30;calls.clear()
        now,advance=self.overlap_clock()
        with patch.object(figure.time,'monotonic',side_effect=now):
            prepared_result=figure.capture_files(args,transport=initial,sleep=advance)
        self.assertEqual(sorted(calls),['ملف:Second.svg','ملف:Third.svg','ملف:Zlast.svg'])
        self.assertEqual(figure.verify(args.output),prepared_result)


    def test_two_slot_repeated_resume_preserves_four_attempt_limit(self):
        args = self.overlap_wall_stop()
        accepted=(args.output/'file-metadata.response-000003-01.raw.json').read_bytes()
        accepted_receipt=(args.output/'file-metadata.response-000003-01.receipt.json').read_bytes()
        args.wall_seconds = 1
        now, advance = self.overlap_clock()
        calls = []
        class ImmediatePool:
            def __init__(self,**kwargs):pass
            def submit(self,function,*values):
                from concurrent.futures import Future
                future=Future()
                try:future.set_result(function(*values))
                except BaseException as error:future.set_exception(error)
                return future
            def shutdown(self,**kwargs):pass
        def transport(url, timeout):
            title = parse_qs(urlsplit(url).query)['titles'][0];calls.append(title)
            self.assertEqual(title, 'ملف:Second.svg')
            raise OSError('temporary connection loss')
        # Force the head to stop before next() can queue its already accepted
        # lookahead. No request or response bytes may disappear on this stop.
        with patch.object(figure.time, 'monotonic', side_effect=now),patch.object(metadata,'ThreadPoolExecutor',ImmediatePool):
            with self.assertRaisesRegex(ValueError, 'Retry exceeds bounded capture wait/deadline'):
                figure.capture_files(args, transport=transport, sleep=advance)
        self.assertEqual(len(calls), 1)
        failure=json.loads((args.output/'figure-failure-0002.json').read_text())
        self.assertEqual(failure['pending_http'],[2,3])
        self.assertEqual((args.output/'file-metadata.response-000003-01.raw.json').read_bytes(),accepted)
        self.assertEqual((args.output/'file-metadata.response-000003-01.receipt.json').read_bytes(),accepted_receipt)
        self.complete_resume_proof(args, 2)
        args.wall_seconds = 30
        now, advance = self.overlap_clock()
        with patch.object(figure.time, 'monotonic', side_effect=now):
            with self.assertRaisesRegex(OSError, 'temporary connection loss'):
                figure.capture_files(args, transport=transport, sleep=advance)
        self.assertEqual(len(calls), 3)
        self.assertTrue((args.output/'file-metadata.response-000002-04.receipt.json').exists())
        self.assertFalse((args.output/'file-metadata.response-000002-05.receipt.json').exists())
        self.assertFalse((args.output/figure.COMPLETE).exists())


    def test_two_slot_resume_rejects_changed_pending_evidence_and_unclosed_sources(self):
        args = self.overlap_wall_stop()
        saved = {path.name: path.read_bytes() for path in args.output.iterdir()}
        failure_path = args.output/'figure-failure-0001.json'
        for mode in ('raw', 'request', 'receipt', 'pending', 'extra', 'orphan', 'core', 'alias', 'unclosed', 'access', 'oversized'):
            with self.subTest(mode=mode):
                for path in args.output.iterdir():
                    if path.name not in saved:path.unlink()
                for name, raw in saved.items():(args.output/name).write_bytes(raw)
                if mode == 'raw':(args.output/'file-metadata.response-000003-01.raw.json').write_bytes(b'{}')
                elif mode == 'request':
                    path=args.output/'file-metadata.request-000003.json';data=json.loads(path.read_text());data['titles']=['ملف:Other.svg'];path.write_bytes(figure.encoded(data))
                elif mode == 'receipt':
                    path=args.output/'file-metadata.response-000003-01.receipt.json';data=json.loads(path.read_text());data['status']=403;path.write_bytes(figure.encoded(data))
                elif mode == 'extra':(args.output/'uncommitted-response.json').write_bytes(b'{}')
                elif mode in ('orphan', 'core', 'alias'):
                    failure=json.loads(failure_path.read_text())
                    if mode == 'orphan':
                        changed={'file-metadata.response-000003-02.raw.json': b'{}'}
                    else:
                        raw_name='file-metadata.response-000003-01.raw.json'
                        receipt_name='file-metadata.response-000003-01.receipt.json'
                        response=json.loads((args.output/raw_name).read_text())
                        if mode == 'core':response['query']['general']['git-hash']=figure.FIGURE_COMPATIBLE_CORE
                        else:response['query']['pages'][0]['imageinfo'][0].update(canonicaltitle='ملف:Example.svg',sha1='b'*40)
                        raw=figure.encoded(response)
                        receipt=json.loads((args.output/receipt_name).read_text())
                        receipt.update(response_bytes=len(raw),response_sha256=figure.digest(raw))
                        changed={raw_name:raw,receipt_name:figure.encoded(receipt)}
                    for name, raw in changed.items():
                        (args.output/name).write_bytes(raw)
                        failure['artifacts'][name]={'bytes':len(raw),'sha256':figure.digest(raw)}
                    failure_path.write_bytes(figure.encoded(failure));self.complete_resume_proof(args,1)
                elif mode == 'unclosed':
                    data=json.loads(args.resume.read_text());closure=json.loads(data['closure_raw']);closure['reaped']=False
                    raw=figure.encoded(closure);data.update(closure_raw=raw.decode(),closure={'bytes':len(raw),'sha256':figure.digest(raw)});args.resume.write_bytes(figure.encoded(data))
                else:
                    data=json.loads(failure_path.read_text())
                    if mode == 'pending':data['pending_http']=[3]
                    else:data['error']='API HTTP status 403' if mode=='access' else 'Oversized API response'
                    failure_path.write_bytes(figure.encoded(data));self.complete_resume_proof(args,1)
                with self.assertRaises((ValueError,OSError)):
                    figure.capture_files(args,transport=lambda *_:self.fail('invalid pending evidence dispatched HTTP'))
                self.assertFalse((args.output/figure.COMPLETE).exists())


    def height_observation_fixture(self, specifications=((323, 415, 250, 194),)):
        from urllib.parse import quote, urlencode
        response = self.response()
        response['query']['general']['git-hash'] = figure.FIGURE_CURRENT_CORE
        response['query']['pages'] = []
        observations, names = [], []
        for index, (width, height, requested, expected) in enumerate(specifications):
            name = 'ملف:Example.svg' if index == 0 else f'ملف:Height{index}.svg'
            page = copy.deepcopy(self.response(name)['query']['pages'][0])
            page['imageinfo'][0].update(width=width, height=height, sha1=f'{index+1:040x}')
            response['query']['pages'].append(page);names.append(name)
            query = {'action':'parse','contentmodel':'wikitext','format':'json','formatversion':'2',
                'maxlag':'5','prop':'text','text':f'[[{name}|x{requested}px|thumb|right|caption]]','title':f'Page {index}'}
            request = {'controlled_single_token':True,'full_historical_page_render':False,
                'input_data':{'path':'fixture.json','bytes':2,'sha256':figure.digest(b'{}')},
                'query':query,'request_count':1,'url':figure.wiktionary_api(self.wiki)+'?'+urlencode(query)}
            html = ('<div class="mw-parser-output"><figure typeof="mw:File/Thumb" class="mw-halign-right">'
                f'<a class="mw-file-description" href="/wiki/{quote(name.replace(" ","_"))}">'
                f'<img class="mw-file-element" src="//thumb.wikimedia.org/retained.png" width="{expected}" '
                f'height="{requested}" data-file-width="{width}" data-file-height="{height}" />'
                '</a><figcaption>caption</figcaption></figure><!-- retained observation --></div>')
            raw = figure.encoded({'parse':{'title':query['title'],'pageid':index+1,'text':html}})
            receipt = {'accepted':True,'status':200,'request_count':1,'response':'response01.raw.json',
                'response_bytes':len(raw),'response_sha256':figure.digest(raw)}
            observations.append({'request':figure.encoded(request).decode(),
                'receipt':figure.encoded(receipt).decode(),'response':raw.decode()})
        batch = {'requests':names,'response':figure.encoded(response).decode(),
            'observed_svg_occurrences':observations}
        return response, batch

    def write_height_observation(self, response, batch, name='height-observations', *, original_profile=False):
        path = self.write_normal_retained(name, response, batch['requests'])
        record = json.loads(path.read_text());record['observed_svg_occurrences'] = []
        if original_profile:
            from urllib.parse import urlencode
            for filename in tuple(record['artifacts']):
                if filename != metadata.NAMESPACE:
                    (path.parent/filename).unlink();record['artifacts'].pop(filename)
            directory=path.parent/'identity01';directory.mkdir()
            query=metadata.query_for(self.wiki,batch['requests'],figure_axes=True)
            request={'controlled_render':False,'historical_page_render':False,
                'input_data':{'path':'fixture.json','bytes':2,'sha256':figure.digest(b'{}')},
                'query':query,'request_count':1,'url':figure.wiktionary_api(self.wiki)+'?'+urlencode(query)}
            raw=figure.encoded(response)
            receipt={'accepted':True,'status':200,'request_count':1,'response':'response01.raw.json',
                'response_bytes':len(raw),'response_sha256':figure.digest(raw)}
            for filename,data in (('request01.json',figure.encoded(request)),('receipt01.json',figure.encoded(receipt)),('response01.raw.json',raw)):
                (directory/filename).write_bytes(data)
                record['artifacts'][directory.name+'/'+filename]={'size':len(data),'sha256':figure.digest(data)}
            record['batch']={'request':'identity01/request01.json','accepted_receipt':'identity01/receipt01.json'}
        for index, item in enumerate(batch['observed_svg_occurrences']):
            directory = path.parent/f'parse{index+1:02d}';directory.mkdir()
            names = {'request':'request01.json','receipt':'receipt01.json','response':'response01.raw.json'}
            selected = {}
            for key, filename in names.items():
                raw = item[key].encode();(directory/filename).write_bytes(raw)
                relative = directory.name+'/'+filename
                record['artifacts'][relative] = {'size':len(raw),'sha256':figure.digest(raw)}
                selected[key] = relative
            record['observed_svg_occurrences'].append(selected)
        path.write_bytes(figure.encoded(record))
        return path

    def height_document(self, response, supplement, *, first=None):
        plain = {'requests':supplement['requests'],'response':figure.encoded(response).decode()}
        batches = [plain if first is None else first, supplement]
        raw = figure.encoded({'schema':figure.RAW_BATCHES_SCHEMA,'batches':batches})
        return figure.figure_file_document(raw,self.namespace.read_bytes(),self.wiki,self.date,
            figure.encoded(response),profile_kind=figure.FIGURE_PROFILE_V4), raw

    def test_svg_height_observations_preserve_exact_context_and_php_rounding(self):
        specifications = ((495,552,250,224),(323,415,250,194),(285,366,200,156),(420,500,200,168))
        response,batch = self.height_observation_fixture(specifications)
        document,raw = self.height_document(response,batch)
        reduced=figure.file_records(json.loads(raw)['batches'],self.namespace.read_bytes(),self.wiki,self.date,
            figure.encoded(response),has_batches=True,record_limit=50,profile_kind=figure.FIGURE_PROFILE_V4)
        self.assertEqual((reduced['base_batches'],reduced['observed_batches']),(1,1))
        for index,row in enumerate(document['records']):
            occurrence = row['observed_svg_heights'][0]
            expected = specifications[index]
            self.assertEqual((row['original_width'],row['original_height']),expected[:2])
            self.assertEqual((occurrence['observed_width_px'],occurrence['observed_height_px']),(expected[3],expected[2]))
            self.assertEqual((occurrence['wiki'],occurrence['title'],occurrence['options'],occurrence['batch']),
                (self.wiki,f'Page {index}',f'x{expected[2]}px|thumb|right|caption',1))
            self.assertIs(occurrence['parse_core_binding_proven'],False)
            self.assertNotIn('observed_svg_width_px',row)
        self.assertEqual(document['records'][1]['observed_svg_heights'][0]['observed_height_px'],250)
        self.assertEqual(figure.verify_figure_file_document(document,raw,self.namespace.read_bytes(),
            self.wiki,self.date,figure.encoded(response)),document)
        with self.assertRaises(ValueError):
            figure.figure_file_document(raw,self.namespace.read_bytes(),self.wiki,self.date,figure.encoded(response))
        forged = copy.deepcopy(document);forged['records'][0]['observed_svg_heights'][0]['parse_core_binding_proven']=True
        with self.assertRaises(ValueError):
            figure.verify_figure_file_document(forged,raw,self.namespace.read_bytes(),self.wiki,self.date,figure.encoded(response))

    def test_svg_height_observation_rejects_rehashed_context_receipt_and_html_changes(self):
        response,batch = self.height_observation_fixture()
        mutations = ('page','wiki','query','duplicate-query','status','bytes','hash','axes','height','width',
            'duplicate-img','duplicate-attr','unquoted-attr','style','enclosing-dimensions','rich-caption',
            'other-file','empty-src','wrong-class','malformed-html','closing-junk','entity-dimension','entity-class',
            'detached-root','many-attrs','angle-attr','multiline-angle-attr','nul-attr',
            'entity-href','encoded-href-query','bad-comment','outside-entity','nul-caption',
            'extra-token','second-size','upscale')
        for mode in mutations:
            changed = copy.deepcopy(batch);item=changed['observed_svg_occurrences'][0]
            request,receipt,answer = (json.loads(item[key]) for key in ('request','receipt','response'))
            if mode=='page':answer['parse']['title']='Different page'
            elif mode=='wiki':request['url']=request['url'].replace('ar.wiktionary.org','de.wiktionary.org')
            elif mode=='query':request['query']['prop']='text|images'
            elif mode=='duplicate-query':request['url']+='&title=Page+0'
            elif mode=='status':receipt['status']=403
            elif mode=='axes':answer['parse']['text']=answer['parse']['text'].replace('data-file-width="323"','data-file-width="324"')
            elif mode=='height':answer['parse']['text']=answer['parse']['text'].replace('height="250"','height="249"')
            elif mode=='width':answer['parse']['text']=answer['parse']['text'].replace('width="194"','width="195"')
            elif mode=='duplicate-img':answer['parse']['text']=answer['parse']['text'].replace('</a>','<img class="mw-file-element" src="x" /></a>')
            elif mode=='duplicate-attr':answer['parse']['text']=answer['parse']['text'].replace('width="194"','width="194" WIDTH="194"')
            elif mode=='unquoted-attr':answer['parse']['text']=answer['parse']['text'].replace('width="194"','width=194')
            elif mode=='style':answer['parse']['text']=answer['parse']['text'].replace('<img ','<img style="width:194px" ')
            elif mode=='enclosing-dimensions':answer['parse']['text']=answer['parse']['text'].replace('<figure ','<figure width="194" ')
            elif mode=='rich-caption':answer['parse']['text']=answer['parse']['text'].replace('>caption</figcaption>','><b>caption</b></figcaption>')
            elif mode=='other-file':answer['parse']['text']=answer['parse']['text'].replace('Example.svg','Other.svg')
            elif mode=='empty-src':answer['parse']['text']=answer['parse']['text'].replace('//thumb.wikimedia.org/retained.png','')
            elif mode=='wrong-class':answer['parse']['text']=answer['parse']['text'].replace('mw-file-element','ordinary-image')
            elif mode=='malformed-html':answer['parse']['text']=answer['parse']['text'].replace('</a>','')
            elif mode=='closing-junk':answer['parse']['text']=answer['parse']['text'].replace('</a>','</a bogus>')
            elif mode=='entity-dimension':answer['parse']['text']=answer['parse']['text'].replace('width="194"','width="&#49;94"')
            elif mode=='entity-class':answer['parse']['text']=answer['parse']['text'].replace('mw-file-element','mw-file-eleme&#110;t')
            elif mode=='detached-root':answer['parse']['text']=answer['parse']['text'].replace('<div class="mw-parser-output">','<div></div>').removesuffix('</div>')
            elif mode=='many-attrs':answer['parse']['text']=answer['parse']['text'].replace('<img ','<img '+''.join(f'attr{n}="x" ' for n in range(33)))
            elif mode=='angle-attr':answer['parse']['text']=answer['parse']['text'].replace('<img ','<img alt="<invalid>" ')
            elif mode=='multiline-angle-attr':answer['parse']['text']=answer['parse']['text'].replace('<img ','<img data-note="line\n<" ')
            elif mode=='nul-attr':answer['parse']['text']=answer['parse']['text'].replace('<img ','<img alt="\0" ')
            elif mode=='entity-href':answer['parse']['text']=answer['parse']['text'].replace('Example.svg','Ex&#97;mple.svg')
            elif mode=='encoded-href-query':answer['parse']['text']=answer['parse']['text'].replace('Example.svg','Example.svg%3Fx')
            elif mode=='bad-comment':answer['parse']['text']=answer['parse']['text'].replace('retained observation','bad -- comment')
            elif mode=='outside-entity':answer['parse']['text']='&nbsp;'+answer['parse']['text']
            elif mode=='nul-caption':answer['parse']['text']=answer['parse']['text'].replace('>caption</figcaption>','>cap\0tion</figcaption>')
            elif mode in ('extra-token','second-size','upscale'):
                from urllib.parse import urlencode
                if mode=='extra-token':request['query']['text']+='[[File:Other.svg]]'
                elif mode=='second-size':request['query']['text']=request['query']['text'].replace('|thumb','|200px|thumb')
                else:request['query']['text']=request['query']['text'].replace('x250px','x500px')
                request['url']=figure.wiktionary_api(self.wiki)+'?'+urlencode(request['query'])
            item['request']=figure.encoded(request).decode();item['response']=figure.encoded(answer).decode()
            receipt.update(response_bytes=len(item['response'].encode()),response_sha256=figure.digest(item['response'].encode()))
            if mode=='bytes':receipt['response_bytes']+=1
            if mode=='hash':receipt['response_sha256']='0'*64
            item['receipt']=figure.encoded(receipt).decode()
            with self.subTest(mode=mode),self.assertRaises(ValueError):self.height_document(response,changed)

    def test_svg_height_supplements_refuse_alias_duplicate_order_and_identity_shortcuts(self):
        response,batch=self.height_observation_fixture()
        plain={'requests':batch['requests'],'response':figure.encoded(response).decode()}
        for mode in ('duplicate-context','duplicate-request','no-base','base-after','mixed-observations','stale-file','alias','unknown-profile'):
            changed=copy.deepcopy(batch);base=copy.deepcopy(plain);source=copy.deepcopy(response)
            batches=[base,changed]
            if mode=='duplicate-context':changed['observed_svg_occurrences']*=2
            elif mode=='duplicate-request':changed['requests']*=2
            elif mode=='no-base':batches=[changed]
            elif mode=='base-after':batches=[base,changed,base]
            elif mode=='mixed-observations':changed['observed_svg_width_px']=250
            elif mode=='stale-file':
                updated=copy.deepcopy(source);updated['query']['pages'][0]['imageinfo'][0]['sha1']='f'*40
                changed['response']=figure.encoded(updated).decode()
            elif mode=='alias':
                source['query']['redirects']=[{'from':'ملف:Alias.svg','to':'ملف:Example.svg'}]
                base.update(requests=['ملف:Alias.svg'],response=figure.encoded(source).decode())
                changed.update(requests=['ملف:Alias.svg'],response=figure.encoded(source).decode())
            raw=figure.encoded({'schema':figure.RAW_BATCHES_SCHEMA,'batches':batches})
            with self.subTest(mode=mode),self.assertRaises(ValueError):
                figure.figure_file_document(raw,self.namespace.read_bytes(),self.wiki,self.date,figure.encoded(source),
                    profile_kind=figure.FIGURE_PROFILE_V3 if mode=='unknown-profile' else figure.FIGURE_PROFILE_V4)
        # Canonical enrichment does not turn an ordinary alias into occurrence authority.
        response['query']['redirects']=[{'from':'ملف:Alias.svg','to':'ملف:Example.svg'}]
        plain.update(requests=['ملف:Alias.svg','ملف:Example.svg'],response=figure.encoded(response).decode())
        batch['response']=figure.encoded(response).decode()
        document,_=self.height_document(response,batch,first=plain)
        alias=next(row for row in document['records'] if row['requested_file']=='ملف:Alias.svg')
        self.assertNotIn('observed_svg_heights',alias)

    def test_retained_svg_occurrence_import_preserves_original_triples_and_bounds_paths(self):
        response,batch=self.height_observation_fixture(((323,415,250,194),(420,500,200,168)))
        path=self.write_height_observation(response,batch)
        before={str(p.relative_to(path.parent)):p.read_bytes() for p in path.parent.rglob('*') if p.is_file()}
        imported=figure.retained_metadata_batch(path,self.wiki,self.date,self.namespace.read_bytes())
        self.assertEqual(imported,batch)
        actual_profile=self.write_height_observation(response,batch,name='original-identity-profile',original_profile=True)
        self.assertEqual(figure.retained_metadata_batch(actual_profile,self.wiki,self.date,self.namespace.read_bytes()),batch)
        actual_record=actual_profile.read_bytes();actual_request=actual_profile.parent/'identity01/request01.json'
        original_request=actual_request.read_bytes()
        for mode in ('query','url','duplicate-url','controlled','count'):
            changed=json.loads(original_request)
            if mode=='query':changed['query']['iiprop']+='|url'
            elif mode=='url':changed['url']=changed['url'].replace('ar.wiktionary.org','de.wiktionary.org')
            elif mode=='duplicate-url':changed['url']+='&action=query'
            elif mode=='controlled':changed['controlled_render']=True
            elif mode=='count':changed['request_count']=2
            data=figure.encoded(changed);actual_request.write_bytes(data)
            declared=json.loads(actual_record);declared['artifacts']['identity01/request01.json']={'size':len(data),'sha256':figure.digest(data)}
            actual_profile.write_bytes(figure.encoded(declared))
            with self.subTest(identity=mode),self.assertRaises(ValueError):
                figure.retained_metadata_batch(actual_profile,self.wiki,self.date,self.namespace.read_bytes())
        actual_request.write_bytes(original_request);actual_profile.write_bytes(actual_record)
        self.assertEqual(before,{str(p.relative_to(path.parent)):p.read_bytes() for p in path.parent.rglob('*') if p.is_file()})
        original=path.read_bytes();record=json.loads(original)
        with patch.object(figure,'STREAM_RAW_LINE_LIMIT',len(figure.stream_encoded(batch))-1),self.assertRaisesRegex(ValueError,'aggregate'):
            figure.retained_metadata_batch(path,self.wiki,self.date,self.namespace.read_bytes())
        for mode in ('path','unknown','missing','symlink','receipt-name'):
            changed=copy.deepcopy(record);response_path=path.parent/'parse01/response01.raw.json'
            response_bytes=response_path.read_bytes()
            if mode=='path':changed['observed_svg_occurrences'][0]['response']='../response01.raw.json'
            elif mode=='unknown':changed['artifacts']['unexpected.json']={'size':2,'sha256':figure.digest(b'{}')};(path.parent/'unexpected.json').write_bytes(b'{}')
            elif mode=='missing':changed['artifacts'].pop('parse01/response01.raw.json')
            elif mode=='symlink':
                response_path.unlink();response_path.symlink_to(path.parent/'parse02/response01.raw.json')
            else:
                receipt_path=path.parent/'parse01/receipt01.json';saved=receipt_path.read_bytes()
                receipt=json.loads(saved);receipt['response']='other.json';receipt_path.write_bytes(figure.encoded(receipt))
                changed['artifacts']['parse01/receipt01.json']={'size':receipt_path.stat().st_size,'sha256':figure.digest(receipt_path.read_bytes())}
            path.write_bytes(figure.encoded(changed))
            with self.subTest(mode=mode),self.assertRaises((ValueError,OSError)):
                figure.retained_metadata_batch(path,self.wiki,self.date,self.namespace.read_bytes())
            path.write_bytes(original)
            if mode=='symlink':response_path.unlink();response_path.write_bytes(response_bytes)
            if mode=='receipt-name':receipt_path.write_bytes(saved)
            if mode=='unknown':(path.parent/'unexpected.json').unlink()
        # Separate records may not silently duplicate the same page/options authority.
        second=self.write_height_observation(response,batch,name='second-height-observations')
        with self.assertRaisesRegex(ValueError,'Duplicate explicit SVG occurrence'):
            figure.select_reuse_batches((path,second),self.wiki,self.date,self.namespace.read_bytes())

    def test_normal_resolver_reprojects_complete_parent_with_exact_svg_context_offline(self):
        inputs=self.normal_build_inputs();response,batch=self.height_observation_fixture()
        args=argparse.Namespace(wiki=self.wiki,date=self.date,defaults=self.root/'figure-defaults',
            dumpstatus=self.root/'pagetable-dumpstatus.raw.json',
            sql=[inputs['downloads']/self.wiki/self.date/row['name'] for row in inputs['selected_inputs'] if row['name'].endswith('.sql.gz')],
            output=self.root/'height-parent',reuse=[],batch_size=50,delay=1,wall_seconds=30)
        original=figure.capture_files(args,transport=lambda *_:(200,{},figure.encoded(response)))
        observation=self.write_height_observation(response,batch,original_profile=True)
        other_batch=copy.deepcopy(batch)
        other=other_batch['observed_svg_occurrences'][0]
        request=json.loads(other['request']);request['query']['title']='Second exact page'
        from urllib.parse import urlencode
        request['url']=figure.wiktionary_api(self.wiki)+'?'+urlencode(request['query'])
        answer=json.loads(other['response']);answer['parse']['title']='Second exact page'
        other['request']=figure.encoded(request).decode();other['response']=figure.encoded(answer).decode()
        receipt=json.loads(other['receipt']);receipt.update(response_bytes=len(other['response'].encode()),
            response_sha256=figure.digest(other['response'].encode()));other['receipt']=figure.encoded(receipt).decode()
        second=self.write_height_observation(response,other_batch,name='second-page')
        before={p.name:p.read_bytes() for p in args.output.iterdir()}
        selected=(args.output/figure.MANIFEST,observation,second)
        with patch.object(figure.evidence,'get_response',side_effect=AssertionError('retained SVG was refetched')):
            paths=builder.resolve_figure_snapshot_options(self.root,inputs['manifest'],inputs['selected_inputs'],
                inputs['downloads'],self.namespace,{},metadata_network='allow',figure_reuse_batches=selected)
            cached=builder.resolve_figure_snapshot_options(self.root,inputs['manifest'],inputs['selected_inputs'],
                inputs['downloads'],self.namespace,{},metadata_network='offline',figure_reuse_batches=selected)
        self.assertEqual(paths,cached)
        result=figure.verify(self.root/'figure-inputs');document=self.stream_document(self.root/'figure-inputs')
        self.assertEqual(document['source_profile']['kind'],figure.FIGURE_PROFILE_V4)
        self.assertEqual(document['records'][0]['observed_svg_heights'][0]['observed_height_px'],250)
        self.assertEqual(result['coverage']['observed_svg_height_occurrences'],2)
        self.assertEqual((document['records_count'],document['base_batches'],document['observed_batches']),(1,1,2))
        self.assertEqual([item['title'] for item in document['records'][0]['observed_svg_heights']],['Page 0','Second exact page'])
        self.assertIs(result['coverage']['parse_core_binding_proven'],False)
        self.assertFalse(result['coverage']['whole_edition_occurrence_coverage'])
        self.assertEqual((self.root/'figure-inputs'/figure.PROVIDER).read_bytes(),before[figure.PROVIDER])
        self.assertEqual(before,{p.name:p.read_bytes() for p in args.output.iterdir()})
        self.assertEqual(figure.verify(args.output),original)

    def test_normal_resolver_reuses_empty_complete_parent_without_source_authority(self):
        old_args=self.args
        with patch.object(self,'args',side_effect=lambda:old_args(links=())):
            inputs=self.normal_build_inputs()
        args=argparse.Namespace(wiki=self.wiki,date=self.date,defaults=self.root/'figure-defaults',
            dumpstatus=self.root/'pagetable-dumpstatus.raw.json',
            sql=[inputs['downloads']/self.wiki/self.date/row['name'] for row in inputs['selected_inputs'] if row['name'].endswith('.sql.gz')],
            output=self.root/'empty-parent',reuse=[],batch_size=50,delay=1,wall_seconds=30)
        original=figure.capture_files(args,transport=lambda *_:self.fail('empty source made HTTP'))
        before={p.name:p.read_bytes() for p in args.output.iterdir()}
        with patch.object(figure.evidence,'get_response',side_effect=AssertionError('empty parent made HTTP')):
            paths=builder.resolve_figure_snapshot_options(self.root,inputs['manifest'],inputs['selected_inputs'],
                inputs['downloads'],self.namespace,{},metadata_network='allow',
                figure_reuse_batches=(args.output/figure.MANIFEST,))
        self.assertEqual(set(paths),{*figure.ROLES,'file-metadata'})
        document=self.stream_document(self.root/'figure-inputs')
        self.assertEqual(document['records'],[])
        self.assertIsNone(document['source_profile'])
        self.assertEqual(figure.verify(self.root/'figure-inputs')['coverage']['files'],0)
        self.assertEqual(figure.verify(args.output),original)
        self.assertEqual(before,{p.name:p.read_bytes() for p in args.output.iterdir()})

    def test_stream_request_plan_and_journal_exceed_legacy_ten_thousand_batches(self):
        count=10001
        names=[f'ملف:Planned-{number:05d}.svg' for number in range(count)]
        batches=list(metadata.title_batches(self.wiki,names,1,figure_axes=True))
        self.assertEqual(len(batches),count)
        self.assertEqual([name for batch in batches for name in batch],names)
        self.assertTrue(all(len(metadata.query_url(self.wiki,batch,figure_axes=True).encode())<=metadata.MAX_URL for batch in batches))
        path=self.root/'large-request-journal.json'
        with path.open('wb') as output:
            output.write(figure.stream_encoded({'schema':figure.REQUEST_STREAM_SCHEMA,'batches':count}))
            for number in range(count):output.write(figure.stream_encoded({'fixture_sequence':number}))
        self.assertEqual([row['fixture_sequence'] for row in figure.source_records(path,count)],list(range(count)))
        with self.assertRaises(ValueError):list(figure.source_records(path,count-1))
        # The bounded legacy whole-array route keeps its old ceiling.
        with self.assertRaisesRegex(ValueError,'request inventory'):
            figure.replay_file_requests(self.root,[{}]*count,self.wiki,self.date)

    def gif_response(self, title='ملف:Geometry.gif', *, width=100, height=100, frames=None):
        response = self.response(title)
        response['query']['general']['git-hash'] = figure.FIGURE_CURRENT_CORE
        info = response['query']['pages'][0]['imageinfo'][0]
        info.update(mime='image/gif', mediatype='BITMAP', width=width, height=height)
        info['metadata'] = [] if frames is None else [
            {'name': 'frameCount', 'value': frames}, {'name': 'looped', 'value': True},
            {'name': 'duration', 'value': 1.25}]
        return response

    def test_gif_v4_geometry_preserves_v3_policy_and_does_not_certify_animation(self):
        for frames in (None, 1, 49, 1000000000):
            response = self.gif_response(frames=frames)
            batch = self.batch('ملف:Geometry.gif', response)
            raw = figure.encoded({'schema': figure.RAW_BATCHES_SCHEMA, 'batches': [batch]})
            site = figure.encoded(response)
            old = figure.figure_file_document(raw, self.namespace.read_bytes(), self.wiki, self.date, site)
            new = figure.figure_file_document(raw, self.namespace.read_bytes(), self.wiki, self.date, site,
                profile_kind=figure.FIGURE_PROFILE_V4)
            self.assertEqual((old['records'][0]['state'], new['records'][0]['state']), ('unsupported', 'eligible'))
            self.assertEqual({k:v for k,v in old['records'][0].items() if k != 'state'},
                {k:v for k,v in new['records'][0].items() if k != 'state'})
            self.assertEqual((new['records'][0]['original_width'],new['records'][0]['original_height']), (100,100))
            self.assertFalse({'width_px','height_px','animated','frameCount','duration','thumbnail_pixels'} & new['records'][0].keys())
            self.assertEqual(figure.verify_figure_file_document(old, raw, self.namespace.read_bytes(),self.wiki,self.date,site), old)
            self.assertEqual(figure.verify_figure_file_document(new, raw, self.namespace.read_bytes(),self.wiki,self.date,site), new)
            self.assertEqual(old['source_profile']['kind'], figure.FIGURE_PROFILE_V3)
            self.assertNotIn('image/gif',old['source_profile']['handler_families'])
            self.assertEqual(new['source_profile']['gif_handler_sha256'], 'f9ba4542bcbfbcdaee7db0c99a463b3f97e9e1e82b0e11adcae927c6638dbf52')

    def test_gif_v4_exact_source_profile_type_axes_and_revision_guards_remain(self):
        for mode in ('old-core','other-core','wrong-type','zero-axis','unknown-mime','future-revision'):
            response=self.gif_response();info=response['query']['pages'][0]['imageinfo'][0]
            if mode=='old-core':response['query']['general']['git-hash']=self.core
            elif mode=='other-core':response['query']['general']['git-hash']=figure.FIGURE_COMPATIBLE_CORE
            elif mode=='wrong-type':info['mediatype']='AUDIO'
            elif mode=='zero-axis':info['width']=0
            elif mode=='unknown-mime':info['mime']='application/octet-stream'
            elif mode=='future-revision':info['timestamp']='2999-01-01T00:00:00Z'
            raw=figure.encoded({'schema':figure.RAW_BATCHES_SCHEMA,'batches':[self.batch('ملف:Geometry.gif',response)]})
            with self.subTest(mode=mode):
                if mode in ('zero-axis','unknown-mime'):
                    document=figure.figure_file_document(raw,self.namespace.read_bytes(),self.wiki,self.date,figure.encoded(response),profile_kind=figure.FIGURE_PROFILE_V4)
                    self.assertEqual(document['records'][0]['state'],'unsupported')
                else:
                    with self.assertRaises(ValueError):
                        figure.figure_file_document(raw,self.namespace.read_bytes(),self.wiki,self.date,figure.encoded(response),profile_kind=figure.FIGURE_PROFILE_V4)
        response=self.gif_response();site=figure.encoded(response)
        raw=figure.encoded({'schema':figure.RAW_BATCHES_SCHEMA,'batches':[self.batch('ملف:Geometry.gif',response)]})
        document=figure.figure_file_document(raw,self.namespace.read_bytes(),self.wiki,self.date,site,profile_kind=figure.FIGURE_PROFILE_V4)
        for field in ('gif_handler_sha256','main_config_schema_sha256','kind'):
            changed=copy.deepcopy(document);changed['source_profile'][field]='unproved'
            with self.subTest(field=field),self.assertRaises(ValueError):
                figure.verify_figure_file_document(changed,raw,self.namespace.read_bytes(),self.wiki,self.date,site)

    def test_complete_v3_stream_reprojects_gif_offline_with_immutable_parent_and_provider(self):
        args=self.args(links=('Geometry.gif','Missing.ogg'))
        args.output=self.root/'gif-v3'
        response=self.gif_response(frames=50)
        response['query']['pages'].append({'title':'ملف:Missing.ogg','ns':6,'missing':True,'imagerepository':''})
        original=figure.capture_files(args,transport=lambda *_:(200,{},figure.encoded(response)))
        parent=args.output;before={p.name:p.read_bytes() for p in parent.iterdir()}
        self.assertEqual(original['coverage']['unsupported'],1)
        args.output=self.root/'gif-v4';args.reuse=[parent];args.figure_profile=figure.FIGURE_PROFILE_V4
        result=figure.capture_files(args,transport=lambda *_:self.fail('offline GIF reprojection made HTTP'))
        document=self.stream_document(args.output)
        self.assertEqual(document['source_profile']['kind'],figure.FIGURE_PROFILE_V4)
        self.assertEqual({r['requested_file']:r['state'] for r in document['records']},
            {'ملف:Geometry.gif':'eligible','ملف:Missing.ogg':'missing'})
        self.assertEqual((args.output/figure.PROVIDER).read_bytes(),before[figure.PROVIDER])
        old_batches=list(figure.stream_values(parent/figure.ROLES['figure-sizing-raw'],figure.RAW_STREAM_SCHEMA))
        new_batches=list(figure.stream_values(args.output/figure.ROLES['figure-sizing-raw'],figure.RAW_STREAM_SCHEMA))
        self.assertEqual(old_batches,new_batches)
        self.assertEqual(figure.verify(args.output),result)
        self.assertEqual(figure.verify(parent),original)
        self.assertEqual(before,{p.name:p.read_bytes() for p in parent.iterdir()})
        snapshots={role:args.output/name for role,name in {**figure.ROLES,'file-metadata':figure.PROVIDER}.items()}
        self.assertEqual(set(figure.verify_tuple(snapshots,self.wiki,self.date)),set(snapshots))
        plan=json.loads((args.output/figure.PLAN).read_text());self.assertEqual(plan['figure_profile'],figure.FIGURE_PROFILE_V4)
        plan.pop('figure_profile');(args.output/figure.PLAN).write_bytes(figure.encoded(plan))
        with self.assertRaises(ValueError):figure.verify(args.output)

    def test_v4_selection_is_explicit_and_does_not_add_svg_observed_width_or_tiff_authority(self):
        response=self.response();response['query']['general']['git-hash']=figure.FIGURE_CURRENT_CORE
        raw=figure.encoded({'schema':figure.RAW_BATCHES_SCHEMA,'batches':[self.batch(response=response)]})
        old=figure.figure_file_document(raw,self.namespace.read_bytes(),self.wiki,self.date,figure.encoded(response))
        new=figure.figure_file_document(raw,self.namespace.read_bytes(),self.wiki,self.date,figure.encoded(response),profile_kind=figure.FIGURE_PROFILE_V4)
        self.assertEqual(old['records'],new['records'])
        self.assertNotIn('observed_svg_width_px',new['records'][0])
        image=response['query']['pages'][0]['imageinfo'][0]
        image.update(mime='image/tiff',mediatype='BITMAP',metadata=[])
        raw=figure.encoded({'schema':figure.RAW_BATCHES_SCHEMA,'batches':[self.batch(response=response)]})
        new=figure.figure_file_document(raw,self.namespace.read_bytes(),self.wiki,self.date,figure.encoded(response),profile_kind=figure.FIGURE_PROFILE_V4)
        self.assertEqual(new['records'][0]['state'],'unsupported')
        args=self.args();args.figure_profile='unreviewed-profile'
        with self.assertRaisesRegex(ValueError,'Unreviewed selected'):
            figure.capture_files(args,transport=lambda *_:self.fail('unknown profile made HTTP'))
        self.assertFalse(args.output.exists())

    def stream_document(self, root):
        values = figure.stream_values(root/figure.ROLES['figure-sizing'], figure.FILES_STREAM_SCHEMA)
        header = next(values)
        return dict(header, records=list(values))

    def complete_stream_fixture(self, args=None):
        args = args or self.args(links=('Example.svg', 'Missing.ogg'))
        args.output = self.root/'complete-original'
        args.batch_size = 1
        base, observed, _ = self.svg_observation()
        clock = [0.0]
        def transport(url, timeout):
            title = parse_qs(urlsplit(url).query)['titles'][0]
            response = copy.deepcopy(base)
            if title != base['query']['pages'][0]['title']:
                response['query']['pages'] = [{'title': title, 'ns': 6, 'missing': True, 'imagerepository': ''}]
            return 200, {}, figure.encoded(response)
        with patch.object(figure.time, 'monotonic', side_effect=lambda: clock[0]):
            result = figure.capture_files(args, transport=transport,
                sleep=lambda delay: clock.__setitem__(0, clock[0]+delay))
        observation = self.write_svg_observation(observed)
        return args, observation, result

    def batched_observation_fixture(self):
        args = self.args(links=('Alias.svg', 'Example.svg', 'Missing.ogg', 'Second.svg'))
        args.output = self.root/'batch-original'
        base, _, _ = self.svg_observation(figure.FIGURE_CURRENT_CORE)
        second = copy.deepcopy(base['query']['pages'][0])
        second['title'] = 'ملف:Second.svg'
        second['imageinfo'][0].update(canonicaltitle=second['title'], width=48, height=48, sha1='b'*40)
        base['query']['pages'].append(second)
        base['query']['redirects'] = [{'from': 'ملف:Alias.svg', 'to': second['title']}]
        observed = copy.deepcopy(base)
        for page in observed['query']['pages']:
            image = page['imageinfo'][0]
            height = 228 if page['title'] == 'ملف:Example.svg' else 250
            image.update(url='https://upload.wikimedia.org/original.svg?utm_content=original',
                thumburl='https://thumb.wikimedia.org/rendered.png?utm_content=thumbnail',
                thumbwidth=250, thumbheight=height, thumbattribs={'width': 250, 'height': height})
        base['query']['pages'].append({'title': 'ملف:Missing.ogg', 'ns': 6, 'missing': True, 'imagerepository': ''})
        figure.capture_files(args, transport=lambda *_: (200, {}, figure.encoded(base)))
        record = self.write_svg_observation(observed)
        titles = ['ملف:Example.svg', 'ملف:Alias.svg']
        self.rewrite_observed_batch(record, observed, titles)
        return args, record, observed, titles

    def rewrite_observed_batch(self, record_path, response, titles, *, request_count=1):
        from urllib.parse import urlencode
        root = record_path.parent
        raw = figure.encoded(response)
        (root/'response01.raw.json').write_bytes(raw)
        receipt = json.loads((root/'receipt01.json').read_text())
        receipt.update(response_bytes=len(raw), response_sha256=figure.digest(raw), request_count=request_count)
        (root/'receipt01.json').write_bytes(figure.encoded(receipt))
        request = json.loads((root/'request01.json').read_text())
        request.update(titles=titles, request_count=request_count)
        request['query']['titles'] = '|'.join(titles)
        request['url'] = figure.wiktionary_api(self.wiki)+'?'+urlencode(request['query'])
        (root/'request01.json').write_bytes(figure.encoded(request))
        record = json.loads(record_path.read_text())
        for name in record['artifacts']:
            data = (root/name).read_bytes()
            record['artifacts'][name] = {'size': len(data), 'sha256': figure.digest(data)}
        record_path.write_bytes(figure.encoded(record))

    def test_retained_svg_optional_thumbmime_preserves_exact_existing_observation(self):
        from urllib.parse import urlencode
        _, record, response, titles = self.batched_observation_fixture()
        original = figure.retained_metadata_batch(record, self.wiki, self.date, self.namespace.read_bytes())
        request_path = record.parent/'request01.json'
        request = json.loads(request_path.read_text())
        request['query']['iiprop'] += '|thumbmime'
        request['url'] = figure.wiktionary_api(self.wiki)+'?'+urlencode(request['query'])
        request_path.write_bytes(figure.encoded(request))
        self.rewrite_observed_batch(record, response, titles)
        before = {path.name: path.read_bytes() for path in record.parent.iterdir() if path.is_file()}
        actual = figure.retained_metadata_batch(record, self.wiki, self.date, self.namespace.read_bytes())
        self.assertEqual(actual, original)
        self.assertEqual(actual['observed_svg_width_px'], 250)
        self.assertEqual(before, {path.name: path.read_bytes() for path in record.parent.iterdir() if path.is_file()})


    def test_retained_svg_optional_thumbmime_does_not_relax_query_receipt_or_raster_proof(self):
        from urllib.parse import urlencode
        _, record, response, titles = self.batched_observation_fixture()
        root = record.parent
        original = {path.name: path.read_bytes() for path in root.iterdir() if path.is_file()}
        for defect in ('extra-property', 'duplicate-thumbmime', 'url-mismatch', 'wrong-width', 'unaccepted', 'missing-raster'):
            for name, body in original.items(): (root/name).write_bytes(body)
            request = json.loads((root/'request01.json').read_text())
            request['query']['iiprop'] += '|thumbmime'
            if defect == 'extra-property': request['query']['iiprop'] += '|extmetadata'
            if defect == 'duplicate-thumbmime': request['query']['iiprop'] += '|thumbmime'
            if defect == 'wrong-width': request['query']['iiurlwidth'] = '251'
            request['url'] = figure.wiktionary_api(self.wiki)+'?'+urlencode(request['query'])
            if defect == 'url-mismatch': request['url'] += '&unexpected=1'
            (root/'request01.json').write_bytes(figure.encoded(request))
            data = copy.deepcopy(response)
            if defect == 'missing-raster':
                image = data['query']['pages'][0]['imageinfo'][0]
                image.pop('thumbwidth'); image['thumbmime'] = 'image/png'
            self.rewrite_observed_batch(record, data, titles)
            # rewrite_observed_batch deliberately rebuilds the URL; change and
            # rebind it afterward to exercise semantic, rather than hash, refusal.
            if defect == 'url-mismatch':
                request = json.loads((root/'request01.json').read_text())
                request['url'] += '&unexpected=1'
                (root/'request01.json').write_bytes(figure.encoded(request))
            if defect == 'unaccepted':
                receipt = json.loads((root/'receipt01.json').read_text()); receipt['accepted'] = False
                (root/'receipt01.json').write_bytes(figure.encoded(receipt))
            proof = json.loads(record.read_text())
            for name in proof['artifacts']:
                body = (root/name).read_bytes()
                proof['artifacts'][name] = {'size':len(body),'sha256':figure.digest(body)}
            record.write_bytes(figure.encoded(proof))
            with self.subTest(defect=defect), self.assertRaises(ValueError):
                figure.retained_metadata_batch(record, self.wiki, self.date, self.namespace.read_bytes())


    def test_batched_observations_augment_complete_facts_with_aliases_without_refetch(self):
        args, record, response, titles = self.batched_observation_fixture()
        parent = args.output
        before = {p.name: p.read_bytes() for p in parent.iterdir()}
        selected = figure.select_reuse_batches((parent/figure.MANIFEST, record),
            self.wiki, self.date, self.namespace.read_bytes())
        self.assertEqual(len(selected), 2)
        args.output = self.root/'batch-augmented';args.reuse = [parent];args.reuse_batch = [record]
        result = figure.capture_files(args, transport=lambda *_: self.fail('batched facts were recaptured'))
        document = self.stream_document(args.output)
        self.assertEqual((document['base_batches'], document['observed_batches']), (1, 1))
        self.assertEqual(result['coverage']['observed_svg_files'], 3)  # Two canonical files, one alias.
        self.assertEqual(result['coverage']['provider']['negative_rows'], 1)
        for row in document['records']:
            if row['state'] == 'eligible':
                self.assertEqual((row['observed_svg_width_px'], row['observed_batch']), (250, 1))
        batches = list(figure.stream_values(args.output/figure.ROLES['figure-sizing-raw'], figure.RAW_STREAM_SCHEMA))
        self.assertEqual(batches[-1], {'requests': titles, 'response': figure.encoded(response).decode(), 'observed_svg_width_px': 250})
        self.assertEqual((args.output/figure.PROVIDER).read_bytes(), before[figure.PROVIDER])
        self.assertEqual(figure.verify(args.output), result)
        self.assertEqual(before, {p.name: p.read_bytes() for p in parent.iterdir()})

    def test_batched_observations_refuse_mixed_missing_stale_and_unknown_file_authority(self):
        args, record, observed, titles = self.batched_observation_fixture()
        for mode in ('bitmap', 'missing', 'mime', 'axes', 'width', 'sha1', 'timestamp', 'core', 'unrequested'):
            response = copy.deepcopy(observed)
            page = response['query']['pages'][1]
            image = page['imageinfo'][0]
            if mode == 'bitmap':image.update(mime='image/jpeg', mediatype='BITMAP')
            if mode == 'missing':response['query']['pages'][1] = {'title': page['title'], 'ns': 6, 'missing': True, 'imagerepository': ''}
            if mode == 'mime':image.update(mime='application/octet-stream', mediatype='UNKNOWN')
            if mode == 'axes':image.pop('width')
            if mode == 'width':image['thumbwidth'] = 249
            if mode == 'sha1':image['sha1'] = 'c'*40
            if mode == 'timestamp':image['timestamp'] = '2020-01-01T00:00:00Z'
            if mode == 'core':response['query']['general']['git-hash'] = figure.FIGURE_COMPATIBLE_CORE
            if mode == 'unrequested':response['query']['pages'].append(self.response('ملف:Unknown.svg')['query']['pages'][0])
            self.rewrite_observed_batch(record, response, titles)
            with self.subTest(mode=mode), self.assertRaises(ValueError):
                figure.select_reuse_batches((args.output/figure.MANIFEST, record),
                    self.wiki, self.date, self.namespace.read_bytes())

    def test_batched_observation_bounds_and_duplicate_canonical_requests_remain_strict(self):
        _, record, response, titles = self.batched_observation_fixture()
        for selected in (titles+titles[:1], titles+['ملف:Second.svg'], [f'ملف:Case{i}.svg' for i in range(51)]):
            self.rewrite_observed_batch(record, response, selected)
            with self.subTest(titles=selected), self.assertRaises(ValueError):
                figure.retained_metadata_batch(record, self.wiki, self.date, self.namespace.read_bytes())
        self.rewrite_observed_batch(record, response, titles, request_count=2)
        with self.assertRaises(ValueError):
            figure.retained_metadata_batch(record, self.wiki, self.date, self.namespace.read_bytes())
        # The existing request-count field counts HTTP requests, not titles.
        many = copy.deepcopy(response);many['query']['pages'] = [];many['query'].pop('redirects')
        names = [f'ملف:Case{i:02}.svg' for i in range(50)]
        for name in names:
            page = copy.deepcopy(response['query']['pages'][1]);page['title'] = name
            page['imageinfo'][0]['canonicaltitle'] = name
            many['query']['pages'].append(page)
        self.rewrite_observed_batch(record, many, names)
        batch = figure.retained_metadata_batch(record, self.wiki, self.date, self.namespace.read_bytes())
        self.assertEqual(batch['requests'], names)
        self.assertEqual(batch['observed_svg_width_px'], 250)
        request = json.loads((record.parent/'request01.json').read_text())
        self.assertLessEqual(len(request['url'].encode()), metadata.MAX_URL)
        with patch.object(metadata, 'MAX_URL', len(request['url'].encode())-1), self.assertRaises(ValueError):
            figure.retained_metadata_batch(record, self.wiki, self.date, self.namespace.read_bytes())
        with patch.object(figure, 'MAX_RESPONSE', len(figure.encoded(many))-1), self.assertRaises(ValueError):
            figure.retained_metadata_batch(record, self.wiki, self.date, self.namespace.read_bytes())

    def complete_resume_proof(self, args, number):
        failure_path = args.output/f'figure-failure-{number:04d}.json'
        descriptor = {'path': failure_path.name, 'bytes': failure_path.stat().st_size,
            'sha256': figure.digest(failure_path.read_bytes())}
        plan = json.loads((args.output/figure.PLAN).read_text())
        closure = {'outcome': 'FAILED-PHYSICALLY-SOURCE-CLOSED', 'source_after': True, 'reaped': True,
            'dual_proc_absence': True, 'ps_absence': True, 'allocation_released': True, 'terminal': 1,
            'capture_failure': descriptor, 'capture_root': str(args.output.resolve()),
            'capture_plan_sha256': figure.digest(figure.encoded(plan))}
        raw = figure.encoded(closure)
        proof = {'schema': 'wikidict.figure-closed-wall-stop.v1', 'source_root': str(args.output.resolve()),
            'plan_sha256': closure['capture_plan_sha256'], 'failure': descriptor,
            'closure_raw': raw.decode(), 'closure': {'bytes': len(raw), 'sha256': figure.digest(raw)}}
        args.resume = args.output/f'figure-resume-{number:04d}.json'
        args.resume.write_bytes(figure.encoded(proof))

    def test_complete_stream_reuse_adds_observation_without_refetch_or_parent_mutation(self):
        args, observation, _ = self.complete_stream_fixture()
        parent = args.output
        before = {p.name: p.read_bytes() for p in parent.iterdir()}
        args.output = self.root/'augmented'
        args.reuse = [parent]
        args.reuse_batch = [observation]
        result = figure.capture_files(args, transport=lambda *_: self.fail('complete base was refetched'))
        self.assertEqual(result['coverage']['files'], 2)
        self.assertEqual(result['coverage']['observed_svg_files'], 1)
        self.assertEqual((args.output/figure.PROVIDER).read_bytes(), before[figure.PROVIDER])
        batches = list(figure.stream_values(args.output/figure.ROLES['figure-sizing-raw'], figure.RAW_STREAM_SCHEMA))
        original = list(figure.stream_values(parent/figure.ROLES['figure-sizing-raw'], figure.RAW_STREAM_SCHEMA))
        self.assertEqual(batches[1:3], original[1:])
        self.assertEqual((batches[0]['base_batches'], batches[0]['observed_batches']), (2, 1))
        self.assertEqual(figure.verify(args.output), result)
        self.assertEqual(before, {p.name: p.read_bytes() for p in parent.iterdir()})
        self.assertEqual(len(json.loads((args.output/figure.PLAN).read_text())['complete_captures']), 1)
        self.assertFalse(list(args.output.glob('file-metadata.request-*.json')))

    def test_complete_stream_reuse_refuses_tampered_truncated_and_nested_sources(self):
        args, _, _ = self.complete_stream_fixture()
        parent = args.output
        before = {p.name: p.read_bytes() for p in parent.iterdir()}
        for number, (name, changed) in enumerate((
                (figure.ROLES['figure-sizing-raw'], before[figure.ROLES['figure-sizing-raw']][:-1]),
                (figure.ROLES['figure-sizing'], before[figure.ROLES['figure-sizing']]+b'{}\n'),
                (figure.COMPLETE, figure.encoded({'schema': figure.SCHEMA, 'manifest_sha256': '0'*64})))):
            (parent/name).write_bytes(changed)
            args.output = self.root/f'refused-complete-{number}'
            args.reuse = [parent]
            with self.subTest(name=name), self.assertRaises(ValueError):
                figure.capture_files(args, transport=lambda *_: self.fail('invalid complete source made HTTP'))
            (parent/name).write_bytes(before[name])
        for use_manifest in (False, True):
            args.output = parent/'nested'/'output'
            args.reuse = [] if use_manifest else [parent]
            args.reuse_batch = [parent/figure.MANIFEST] if use_manifest else []
            with self.assertRaisesRegex(ValueError, 'modify'):
                figure.capture_files(args, transport=lambda *_: self.fail('nested output made HTTP'))
            self.assertFalse((parent/'nested').exists())
        self.assertEqual(before, {p.name: p.read_bytes() for p in parent.iterdir()})

    def test_complete_stream_reuse_rechecks_cached_entry_set_and_batch_order(self):
        args, observation, _ = self.complete_stream_fixture()
        parent = args.output
        cache = {}
        source = figure.read_complete_capture(parent/figure.MANIFEST, cache)
        extra = parent/'unexpected.txt';extra.write_bytes(b'new entry')
        with self.assertRaisesRegex(ValueError, 'changed'):
            figure.read_complete_capture(parent/figure.MANIFEST, cache)
        with self.assertRaisesRegex(ValueError, 'changed'):
            figure.check_prefix_cache(cache)
        extra.unlink()
        with self.assertRaisesRegex(ValueError, 'changed'):
            figure.read_complete_capture(parent/figure.MANIFEST, cache)
        # Removing the entry does not restore the directory's physical stamp.
        # A new request scope fully verifies the restored parent before reuse.
        cache = {}
        source = figure.read_complete_capture(parent/figure.MANIFEST, cache)
        reference = {'kind': 'complete-stream', 'path': str(parent/figure.MANIFEST),
            'sha256': source['manifest_sha256'], 'batch': 0}
        first = figure.complete_stream_batch(reference, cache)
        with self.assertRaisesRegex(ValueError, 'identity differs'):
            figure.replay_source(self.root/'elsewhere', dict(reference, batch=1), first,
                self.wiki, self.date, self.namespace.read_bytes(), set(), cache)
        with self.assertRaises(ValueError):
            figure.complete_stream_batch(dict(reference, batch=2), cache)
        args.output = self.root/'ordered';args.reuse = [parent];args.reuse_batch = [observation]
        figure.capture_files(args, transport=lambda *_: self.fail('complete source made HTTP'))
        # Removing the source from a coherently rehashed publication plan cannot
        # discard its journal lineage or turn it into a partial reuse claim.
        plan = json.loads((args.output/figure.PLAN).read_text());plan['complete_captures'] = []
        (args.output/figure.PLAN).write_bytes(figure.encoded(plan))
        manifest = json.loads((args.output/figure.MANIFEST).read_text())
        manifest['artifacts'] = figure.payload(args.output)
        (args.output/figure.MANIFEST).write_bytes(figure.encoded(manifest))
        (args.output/figure.COMPLETE).write_bytes(figure.encoded({'schema': figure.SCHEMA,
            'manifest_sha256': figure.digest(figure.encoded(manifest))}))
        with self.assertRaisesRegex(ValueError, 'omitted, duplicated, or out of order'):
            figure.verify(args.output)

    def test_complete_stream_reuse_rejects_mixed_core_identity_and_duplicate_observations(self):
        args, observation, _ = self.complete_stream_fixture()
        parent = args.output
        original = {p.name: p.read_bytes() for p in observation.parent.iterdir()}
        for number, mode in enumerate(('core', 'sha1')):
            response = json.loads(original['response01.raw.json'])
            if mode == 'core':response['query']['general']['git-hash'] = figure.FIGURE_CURRENT_CORE
            else:response['query']['pages'][0]['imageinfo'][0]['sha1'] = 'b'*40
            raw = figure.encoded(response)
            (observation.parent/'response01.raw.json').write_bytes(raw)
            receipt = json.loads(original['receipt01.json']);receipt.update(response_bytes=len(raw), response_sha256=figure.digest(raw))
            (observation.parent/'receipt01.json').write_bytes(figure.encoded(receipt))
            record = json.loads(original[observation.name])
            for name in ('receipt01.json', 'response01.raw.json'):
                data = (observation.parent/name).read_bytes()
                record['artifacts'][name] = {'size': len(data), 'sha256': figure.digest(data)}
            observation.write_bytes(figure.encoded(record))
            with self.subTest(mode=mode), self.assertRaises(ValueError):
                figure.select_reuse_batches((parent/figure.MANIFEST, observation), self.wiki,
                    self.date, self.namespace.read_bytes())
        for name, raw in original.items():(observation.parent/name).write_bytes(raw)
        with self.assertRaisesRegex(ValueError, 'Duplicate'):
            figure.select_reuse_batches((parent/figure.MANIFEST, observation, observation),
                self.wiki, self.date, self.namespace.read_bytes())
        args.output = self.root/'once';args.reuse = [parent];args.reuse_batch = [observation]
        figure.capture_files(args, transport=lambda *_: self.fail('complete source made HTTP'))
        with self.assertRaisesRegex(ValueError, 'Duplicate explicit observed'):
            figure.select_reuse_batches((args.output/figure.MANIFEST, observation),
                self.wiki, self.date, self.namespace.read_bytes())

    def test_complete_stream_augmentation_resumes_twice_with_exact_prefix(self):
        args, observation, _ = self.complete_stream_fixture()
        parent = args.output
        original = {p.name: p.read_bytes() for p in parent.iterdir()}
        args.output = self.root/'resuming';args.reuse = [parent];args.reuse_batch = [observation]
        args.wall_seconds = 1
        replay = figure.replay_source
        prefixes = []
        for number in (1, 2):
            clock = [0.0]
            def stop_after(root, source, *rest, **kwargs):
                result = replay(root, source, *rest, **kwargs)
                if root == args.output and source.get('kind') == 'complete-stream' and source['batch'] == number-1:
                    clock[0] = 2.0
                return result
            with patch.object(figure.time, 'monotonic', side_effect=lambda: clock[0]), \
                    patch.object(figure, 'replay_source', side_effect=stop_after):
                with self.assertRaisesRegex(ValueError, 'Capture wall deadline reached'):
                    figure.capture_files(args, transport=lambda *_: self.fail('resume refetched base'))
            raw = (args.output/figure.ROLES['figure-sizing-raw']).read_bytes()
            if prefixes:self.assertTrue(raw.startswith(prefixes[-1]))
            prefixes.append(raw)
            failure = json.loads((args.output/f'figure-failure-{number:04d}.json').read_text())
            self.assertEqual(failure['committed_batches'], number)
            self.complete_resume_proof(args, number)
        args.wall_seconds = 30
        result = figure.capture_files(args, transport=lambda *_: self.fail('resume refetched base'))
        self.assertTrue((args.output/figure.ROLES['figure-sizing-raw']).read_bytes().startswith(prefixes[-1]))
        self.assertEqual(len(result['resumes']), 2)
        self.assertEqual(result['coverage']['observed_svg_files'], 1)
        self.assertEqual(figure.verify(args.output), result)
        self.assertEqual(original, {p.name: p.read_bytes() for p in parent.iterdir()})

    def test_normal_resolver_reuses_complete_stream_manifest_and_cached_supplements(self):
        old_args = self.args
        with patch.object(self, 'args', side_effect=lambda: old_args(links=('Example.svg', 'Missing.ogg'))):
            inputs = self.normal_build_inputs()
        args = argparse.Namespace(wiki=self.wiki, date=self.date, defaults=self.root/'figure-defaults',
            dumpstatus=self.root/'pagetable-dumpstatus.raw.json',
            sql=[inputs['downloads']/self.wiki/self.date/row['name'] for row in inputs['selected_inputs'] if row['name'].endswith('.sql.gz')],
            output=self.root/'unused',
            reuse=[], batch_size=1, delay=1, wall_seconds=30)
        args, observation, _ = self.complete_stream_fixture(args)
        selected = (args.output/figure.MANIFEST, observation)
        with patch.object(figure.evidence, 'get_response', side_effect=AssertionError('complete base was refetched')):
            paths = builder.resolve_figure_snapshot_options(self.root, inputs['manifest'], inputs['selected_inputs'],
                inputs['downloads'], self.namespace, {}, metadata_network='allow', figure_reuse_batches=selected)
            reused = builder.resolve_figure_snapshot_options(self.root, inputs['manifest'], inputs['selected_inputs'],
                inputs['downloads'], self.namespace, {}, metadata_network='offline', figure_reuse_batches=selected)
        self.assertEqual(paths, reused)
        self.assertEqual(set(paths), {*figure.ROLES, 'file-metadata'})
        self.assertEqual(figure.verify(self.root/'figure-inputs')['coverage']['observed_svg_files'], 1)

    def test_complete_stream_aliases_share_one_observation_and_refuse_duplicate_authority(self):
        args = self.args(links=('Alias.svg', 'Example.svg'));args.batch_size = 1
        args.output = self.root/'alias-original'
        base, observed, _ = self.svg_observation()
        clock = [0.0]
        def transport(url, timeout):
            title = parse_qs(urlsplit(url).query)['titles'][0]
            response = copy.deepcopy(base)
            if title != 'ملف:Example.svg':
                response['query']['redirects'] = [{'from': title, 'to': 'ملف:Example.svg'}]
            return 200, {}, figure.encoded(response)
        with patch.object(figure.time, 'monotonic', side_effect=lambda: clock[0]):
            figure.capture_files(args, transport=transport,
                sleep=lambda delay: clock.__setitem__(0, clock[0]+delay))
        original = args.output
        observation = self.write_svg_observation(observed)
        args.output = self.root/'alias-augmented';args.reuse = [original];args.reuse_batch = [observation]
        figure.capture_files(args, transport=lambda *_: self.fail('alias source was refetched'))
        document = self.stream_document(args.output)
        self.assertEqual(len(document['records']), 2)
        self.assertTrue(all(row['observed_svg_width_px'] == 250 for row in document['records']))
        selected = figure.select_reuse_batches((args.output/figure.MANIFEST,),
            self.wiki, self.date, self.namespace.read_bytes())
        self.assertEqual(len(selected), 1)
        with self.assertRaisesRegex(ValueError, 'Duplicate explicit observed'):
            figure.select_reuse_batches((args.output/figure.MANIFEST, observation),
                self.wiki, self.date, self.namespace.read_bytes())

    def verify_changed_projection(self, root, document):
        path = root/figure.ROLES['figure-sizing']
        path.unlink()
        figure.write_projection_stream(path, document)
        return figure.verify_stream_document(path, root/figure.ROLES['figure-sizing-raw'],
            self.namespace.read_bytes(), self.wiki, self.date,
            (root/figure.ROLES['figure-sizing-site']).read_bytes())

    def response(self, title='ملف:Example.svg'):
        value = copy.deepcopy(self.api)
        value['query']['extensions'] = copy.deepcopy(self.site_api['query']['extensions'])
        page = value['query']['pages'][0]
        page['title'] = title
        page['imageinfo'][0]['canonicaltitle'] = title
        return value

    def project(self, batches, site=None):
        raw = figure.encoded({'schema': figure.RAW_BATCHES_SCHEMA, 'batches': batches})
        return figure.figure_file_document(raw, self.namespace.read_bytes(), self.wiki,
            self.date, figure.encoded(site or self.site_api))

    def batch(self, title='ملف:Example.svg', response=None):
        return {'requests': [title], 'response': figure.encoded(response or self.response(title)).decode()}

    def inventory(self, image=(), links=('Example.svg',)):
        status, paths = {'jobs': {}}, []
        for table, names in (('image', image), ('imagelinks', links)):
            field = 'img_name' if table == 'image' else 'il_to'
            sql = f'CREATE TABLE `{table}` (\n  `{field}` varbinary(255) NOT NULL\n);\n'
            if names:
                sql += f'INSERT INTO `{table}` VALUES '+','.join("('"+n+"')" for n in names)+';\n'
            raw = gzip.compress(sql.encode(), mtime=0)
            path = self.root / f'{self.wiki}-{self.date}-{table}.sql.gz'
            path.write_bytes(raw)
            status['jobs'][table+'table'] = {'status': 'done', 'files': {path.name: {
                'size': len(raw), 'sha1': hashlib.sha1(raw).hexdigest(),
                'url': f'/{self.wiki}/{self.date}/{path.name}'}}}
            paths.append(path)
        status_path = self.root / 'dumpstatus.json'
        status_path.write_bytes(figure.encoded(status))
        return paths, status_path

    def args(self, *, image=(), links=('Example.svg',), reuse=()):
        paths, status = self.inventory(image, links)
        return argparse.Namespace(wiki=self.wiki, date=self.date, defaults=self.root/'defaults',
            dumpstatus=status, sql=paths, output=self.root/'files', reuse=list(reuse),
            batch_size=50, delay=1, wall_seconds=30, metadata_mode='full')

    def test_logical_axes_authority_preserves_exact_revision_and_negative_states(self):
        good = self.batch()
        missing = self.response('ملف:Missing.svg')
        missing['query']['pages'][0] = {'title': 'ملف:Missing.svg', 'ns': 6,
            'missing': True, 'imagerepository': ''}
        unsupported = self.response('ملف:Audio.ogg')
        unsupported['query']['pages'][0]['imageinfo'][0].update(mime='audio/ogg', mediatype='AUDIO', width=0, height=0)
        result = self.project([good, self.batch('ملف:Missing.svg', missing), self.batch('ملف:Audio.ogg', unsupported)])
        states = {row['requested_file']: row['state'] for row in result['records']}
        self.assertEqual(states, {'ملف:Example.svg': 'eligible', 'ملف:Missing.svg': 'missing', 'ملف:Audio.ogg': 'unsupported'})
        row = next(row for row in result['records'] if row['state'] == 'eligible')
        self.assertEqual((row['original_width'], row['original_height']), (800, 600))
        self.assertNotIn('width_px', row)
        self.assertNotIn('height_px', row)

    def test_each_response_owns_timestamp_and_raw_pages_are_accounted(self):
        early = self.response()
        early['curtimestamp'] = '2020-01-01T00:00:00Z'
        later = self.response('ملف:Later.svg')
        with self.assertRaises(ValueError):
            self.project([self.batch(response=early), self.batch('ملف:Later.svg', later)])
        for field, value in (('git-hash', '0'*40), ('wikiid', 'enwiktionary'), ('lang', 'en')):
            changed = self.response();changed['query']['general'][field] = value
            with self.assertRaises(ValueError):self.project([self.batch(response=changed)])
        changed = self.response();changed['query']['pages'].append(self.response('ملف:Unrequested.svg')['query']['pages'][0])
        with self.assertRaises(ValueError):self.project([self.batch(response=changed)])
        changed = self.response();changed['query']['extensions'][0]['vcs-version'] = '0'*40
        with self.assertRaises(ValueError):self.project([self.batch(response=changed)])

    def test_validated_aliases_share_identical_canonical_facts_only(self):
        def alias(name):
            response = self.response('ملف:Canonical.svg')
            response['query']['redirects'] = [{'from': name, 'to': 'ملف:Canonical.svg'}]
            return response
        a, c = alias('ملف:A.svg'), alias('ملف:C.svg')
        result = self.project([self.batch('ملف:A.svg', a), self.batch('ملف:C.svg', c)])
        self.assertEqual({row['canonical_file'] for row in result['records']}, {'ملف:Canonical.svg'})
        for field, value in (('width', 799), ('sha1', 'b'*40), ('timestamp', '2020-01-01T00:00:00Z'), ('mime', 'image/png')):
            self.assertNotEqual(c['query']['pages'][0]['imageinfo'][0][field], value)
            changed = copy.deepcopy(c);changed['query']['pages'][0]['imageinfo'][0][field] = value
            with self.assertRaises(ValueError):self.project([self.batch('ملف:A.svg', a), self.batch('ملف:C.svg', changed)])
        absent = self.response('ملف:Canonical.svg')
        absent['query']['pages'][0] = {'title': 'ملف:Canonical.svg', 'ns': 6, 'imagerepository': '', 'missing': True}
        with self.assertRaises(ValueError):self.project([self.batch('ملف:A.svg', a), self.batch('ملف:Canonical.svg', absent)])
        absent['query']['redirects'] = [{'from': 'ملف:C.svg', 'to': 'ملف:Canonical.svg'}]
        with self.assertRaises(ValueError):self.project([self.batch('ملف:A.svg', a), self.batch('ملف:C.svg', absent)])
        with self.assertRaises(ValueError):self.project([self.batch('ملف:A.svg', a), self.batch('ملف:A.svg', a)])
        cyclic = alias('ملف:A.svg');cyclic['query']['redirects'].append({'from': 'ملف:Canonical.svg', 'to': 'ملف:A.svg'})
        with self.assertRaises(ValueError):self.project([self.batch('ملف:A.svg', cyclic)])

    def test_tiff_without_single_page_proof_is_explicitly_unsupported(self):
        response = self.response('ملف:Example.tif')
        response['query']['pages'][0]['imageinfo'][0].update(mime='image/tiff', mediatype='BITMAP', pagecount=2)
        self.assertEqual(self.project([self.batch('ملف:Example.tif', response)])['records'][0]['state'], 'unsupported')

    def test_empty_dated_inventory_is_no_authority_without_http(self):
        args = self.args(links=())
        with patch.object(figure.evidence, 'get_response', side_effect=AssertionError('empty inventory made HTTP')):
            result = figure.capture_files(args)
        self.assertEqual(result['coverage']['files'], 0)
        self.assertFalse(result['coverage']['whole_edition_occurrence_coverage'])
        document = self.stream_document(args.output)
        self.assertIsNone(document['source_profile'])
        self.assertEqual(document['records'], [])
        self.assertEqual(figure.verify(args.output), result)
        document['records'] = self.project([self.batch()])['records']
        with self.assertRaises(ValueError):
            self.verify_changed_projection(args.output, document)

    def test_reused_capture_avoids_http_and_preserves_original_inputs(self):
        self.api['query']['extensions'] = copy.deepcopy(self.site_api['query']['extensions'])
        self.write_projection()
        reused = self.stage()
        before = {p.name: p.read_bytes() for p in reused.iterdir()}
        args = self.args(reuse=[reused])
        result = figure.capture_files(args, transport=lambda *_: self.fail('retained file was recaptured'))
        self.assertEqual(result['coverage']['eligible'], 1)
        self.assertEqual(result['coverage']['files'], 1)
        self.assertEqual(before, {p.name: p.read_bytes() for p in reused.iterdir()})
        self.assertEqual(figure.verify(args.output), result)
        selected = result['source_dump_files']
        for role, name in figure.ROLES.items():
            builder._validate_captured_snapshot_context(role, args.output/name, {}, selected,
                                                       None, (result, {}))
        changed = copy.deepcopy(selected)
        changed[0]['sha1'] = '0'*40
        with self.assertRaisesRegex(ValueError, 'differs from selected dump'):
            builder._validate_captured_snapshot_context('figure-sizing', args.output/'figure-sizing.json',
                                                       {}, changed, None, (result, {}))
        (args.sql[1]).write_bytes(b'changed keeper')
        with self.assertRaises(ValueError):figure.verify(args.output)

    def test_missing_file_batch_uses_existing_transport_and_full_replay(self):
        args = self.args(links=('Example.svg', 'Second.svg'))
        args.batch_size = 1
        calls = []
        def transport(url, timeout):
            calls.append(url)
            self.assertIn('curtimestamp=1', url)
            self.assertIn('mime', url)
            title = parse_qs(urlsplit(url).query)['titles'][0]
            return 200, {}, figure.encoded(self.response(title))
        clock = [0.0]
        with patch.object(figure.time, 'monotonic', side_effect=lambda: clock[0]):
            result = figure.capture_files(args, transport=transport,
                                          sleep=lambda delay: clock.__setitem__(0, clock[0] + delay))
        self.assertEqual(len(calls), 2)
        self.assertEqual(result['coverage']['eligible'], 2)
        self.assertEqual(figure.verify(args.output), result)
        changed = self.stream_document(args.output)
        changed['records'][0]['original_width'] = 900
        with self.assertRaises(ValueError):
            self.verify_changed_projection(args.output, changed)

    def test_capture_rejects_unknown_source_before_next_batch_and_preserves_response(self):
        args = self.args(links=('Example.svg', 'Second.svg'));args.batch_size = 1
        changed = self.response();changed['query']['general']['git-hash'] = '0'*40
        calls = []
        def transport(url, timeout):
            calls.append(url)
            return 200, {}, figure.encoded(changed)
        with self.assertRaisesRegex(ValueError, 'different source versions'):
            figure.capture_files(args, transport=transport, sleep=lambda _: None)
        self.assertEqual(len(calls), 1)
        self.assertEqual((args.output/'file-metadata.response-000001-01.raw.json').read_bytes(), figure.encoded(changed))
        failure = json.loads((args.output/'figure-failure-0001.json').read_text())
        self.assertEqual(failure['committed_batches'], 0)
        self.assertFalse((args.output/figure.COMPLETE).exists())


    def test_target_id_schema_joins_only_selected_namespace_six_rows(self):
        paths, status_path = self.inventory(links=())
        status = json.loads(status_path.read_text())
        def replace(table, sql):
            path = self.root/f'{self.wiki}-{self.date}-{table}.sql.gz'
            raw = gzip.compress(sql.encode(), mtime=0)
            path.write_bytes(raw)
            status['jobs'][table+'table'] = {'status': 'done', 'files': {path.name: {
                'size': len(raw), 'sha1': hashlib.sha1(raw).hexdigest(),
                'url': f'/{self.wiki}/{self.date}/{path.name}'}}}
            return path
        replace('imagelinks', 'CREATE TABLE `imagelinks` (\n  `il_target_id` bigint NOT NULL\n);\n'
            'INSERT INTO `imagelinks` VALUES (17),(17);\n')
        target = replace('linktarget', 'CREATE TABLE `linktarget` (\n  `lt_id` bigint NOT NULL,\n'
            '  `lt_namespace` int NOT NULL,\n  `lt_title` varbinary(255) NOT NULL\n);\n'
            "INSERT INTO `linktarget` VALUES (1,14,'Unused_category'),(17,6,'Example.svg');\n")
        result = figure.source_inventory(self.namespace.read_bytes(), self.wiki, self.date,
                                        figure.encoded(status), [*paths, target])
        self.assertEqual(result['titles'], ['ملف:Example.svg'])
        self.assertEqual(result['imagelinks_mode'], 'il_target_id-to-linktarget-namespace6')
        with self.assertRaisesRegex(ValueError, 'requires.*linktarget'):
            figure.source_inventory(self.namespace.read_bytes(), self.wiki, self.date,
                                    figure.encoded(status), paths)
        for rows in ("(17,14,'Example.svg')", "(18,6,'Example.svg')", "(17,6,'Example.svg'),(17,6,'Conflict.svg')"):
            sql = 'CREATE TABLE `linktarget` (\n  `lt_id` bigint NOT NULL,\n  `lt_namespace` int NOT NULL,\n  `lt_title` varbinary(255) NOT NULL\n);\n'
            replace('linktarget', sql+'INSERT INTO `linktarget` VALUES '+rows+';\n')
            with self.assertRaises(ValueError):
                figure.source_inventory(self.namespace.read_bytes(), self.wiki, self.date,
                                        figure.encoded(status), [*paths, target])

    def test_global_target_stream_exceeds_seed_row_limit_and_checks_late_rows(self):
        paths, status_path = self.inventory(links=())
        status = json.loads(status_path.read_text())
        def replace(table, fields, rows):
            path = self.root/f'{self.wiki}-{self.date}-{table}.sql.gz'
            sql = f'CREATE TABLE `{table}` (\n'+fields+'\n);\n'
            sql += f'INSERT INTO `{table}` VALUES '+rows+';\n'
            raw = gzip.compress(sql.encode(), mtime=0)
            path.write_bytes(raw)
            status['jobs'][table+'table'] = {'status': 'done', 'files': {path.name: {
                'size': len(raw), 'sha1': hashlib.sha1(raw).hexdigest(),
                'url': f'/{self.wiki}/{self.date}/{path.name}'}}}
            return path
        replace('imagelinks', '  `il_target_id` bigint NOT NULL', '(17),(17)')
        fields = ('  `lt_id` bigint NOT NULL,\n  `lt_namespace` int NOT NULL,\n'
                  '  `lt_title` varbinary(255) NOT NULL')
        good = "(17,6,'Example.svg'),(1,14,'Unused'),(2,0,'Unused'),(3,6,'Unreferenced.svg')"
        target = replace('linktarget', fields, good)
        original = figure.evidence.sql_rows
        observed = []
        def tracking_rows(path, wanted):
            for row in original(path, wanted):
                if Path(path) == target:
                    observed.append(row[0])
                yield row
        with patch.object(figure.evidence, 'MAX_SQL_ROWS', 2), patch.object(
                figure.evidence, 'sql_rows', side_effect=tracking_rows):
            result = figure.source_inventory(self.namespace.read_bytes(), self.wiki, self.date,
                                            figure.encoded(status), [*paths, target])
        self.assertEqual(result['titles'], ['ملف:Example.svg'])
        self.assertEqual(observed, [17, 1, 2, 3])
        # An identical late duplicate is invalid too; resolution is not an EOF.
        for rows in (good+",(17,6,'Example.svg')", good+",(17,6,'Conflict.svg')",
                     good+",(0,14,'Invalid')", "(18,6,'Absent.svg')",
                     "(17,14,'Not_a_file')"):
            replace('linktarget', fields, rows)
            with patch.object(figure.evidence, 'MAX_SQL_ROWS', 2):
                with self.assertRaises(ValueError):
                    figure.source_inventory(self.namespace.read_bytes(), self.wiki, self.date,
                                            figure.encoded(status), [*paths, target])

    def test_full_selected_sql_stream_keeps_late_identity_checks_without_row_ceiling(self):
        paths, status_path = self.inventory(links=())
        status = json.loads(status_path.read_text())
        def replace(table, fields, rows):
            path = self.root/f'{self.wiki}-{self.date}-{table}.sql.gz'
            sql = f'CREATE TABLE `{table}` (\n'+fields+'\n);\n'
            sql += f'INSERT INTO `{table}` VALUES '+rows+';\n'
            raw = gzip.compress(sql.encode(), mtime=0)
            path.write_bytes(raw)
            status['jobs'][table+'table'] = {'status': 'done', 'files': {path.name: {
                'size': len(raw), 'sha1': hashlib.sha1(raw).hexdigest(),
                'url': f'/{self.wiki}/{self.date}/{path.name}'}}}
            return path
        replace('imagelinks', '  `il_target_id` bigint NOT NULL', '(17),(18),(17),(18)')
        target = replace('linktarget', '  `lt_id` bigint NOT NULL,\n  `lt_namespace` int NOT NULL,\n'
            '  `lt_title` varbinary(255) NOT NULL', "(17,6,'One.svg'),(18,6,'Two.svg')")
        with patch.object(figure, 'MAX_TITLES', 1), patch.object(figure.evidence, 'MAX_SQL_ROWS', 1):
            result = figure.source_inventory(self.namespace.read_bytes(), self.wiki, self.date,
                                             figure.encoded(status), [*paths, target])
        self.assertEqual(len(result['titles']), 2)
        replace('imagelinks', '  `il_target_id` bigint NOT NULL', '(17),(18),(0)')
        with self.assertRaisesRegex(ValueError, 'Invalid imagelinks target'):
            figure.source_inventory(self.namespace.read_bytes(), self.wiki, self.date,
                                    figure.encoded(status), [*paths, target])
        self.assertFalse((self.root/'files'/figure.COMPLETE).exists())

    def streamed_sql_fixture(self):
        paths, status_path = self.inventory(links=())
        status = json.loads(status_path.read_text())
        def replace(table, sql):
            path = self.root/f'{self.wiki}-{self.date}-{table}.sql.gz'
            raw = gzip.compress(sql.encode() if isinstance(sql, str) else sql, compresslevel=1, mtime=0)
            path.write_bytes(raw)
            status['jobs'][table+'table'] = {'status': 'done', 'files': {path.name: {
                'size': len(raw), 'sha1': hashlib.sha1(raw).hexdigest(),
                'url': f'/{self.wiki}/{self.date}/{path.name}'}}}
            return path
        replace('imagelinks', 'CREATE TABLE `imagelinks` (\n  `il_target_id` bigint NOT NULL\n);\n'
            'INSERT INTO `imagelinks` VALUES (17);\n')
        sql = ('CREATE TABLE `linktarget` (\n  `lt_id` bigint NOT NULL,\n'
            '  `lt_namespace` int NOT NULL,\n  `lt_title` varbinary(255) NOT NULL\n);\n'
            "INSERT INTO `linktarget` VALUES (17,6,'Example.svg');\n")
        target = replace('linktarget', sql)
        return [*paths, target], status, target, sql, replace

    def test_official_sql_above_seed_copy_cap_uses_bounded_hash_and_decode_reads(self):
        import random
        paths, status, target, sql, replace = self.streamed_sql_fixture()
        random_bytes = random.Random(631)
        padding = b''.join(b'-- '+random_bytes.randbytes(32768).hex().encode()+b'\n' for _ in range(40))
        replace('linktarget', sql.encode()+padding)
        self.assertGreater(target.stat().st_size, 1024*1024)
        hash_reads, sql_reads = [], []
        original_open, original_gzip = Path.open, gzip.open
        class Guard:
            def __init__(guard, stream, *, hashing):
                guard.stream, guard.hashing = stream, hashing
            def __enter__(guard):return guard
            def __exit__(guard, *args):return guard.stream.__exit__(*args)
            def __getattr__(guard, name):return getattr(guard.stream, name)
            def read(guard, size=-1):
                self.assertTrue(guard.hashing)
                self.assertGreater(size, 0);self.assertLessEqual(size, 1024*1024)
                raw = guard.stream.read(size);hash_reads.append(len(raw));return raw
            def readline(guard, size=-1):
                self.assertFalse(guard.hashing)
                self.assertEqual(size, 16*1024*1024+1)
                raw = guard.stream.readline(size);sql_reads.append(len(raw));return raw
        def guarded_open(path, *args, **kwargs):
            stream = original_open(path, *args, **kwargs)
            return Guard(stream, hashing=True) if path == target else stream
        def guarded_gzip(path, *args, **kwargs):
            stream = original_gzip(path, *args, **kwargs)
            return Guard(stream, hashing=False) if Path(path) == target else stream
        with patch.object(figure.evidence, 'MAX_INPUT', 16), patch.object(Path, 'open', guarded_open), \
                patch.object(gzip, 'open', guarded_gzip):
            result = figure.source_inventory(self.namespace.read_bytes(), self.wiki, self.date,
                figure.encoded(status), paths)
        self.assertEqual(result['titles'], ['ملف:Example.svg'])
        self.assertEqual(sum(hash_reads), target.stat().st_size)
        self.assertGreaterEqual(len([n for n in hash_reads if n]), 2)
        self.assertEqual(hash_reads[-1], 0)
        self.assertEqual(sql_reads[-1], 0)
        self.assertEqual(sum(sql_reads), len(sql.encode())+len(padding))

    def test_official_sql_size_url_status_and_hash_remain_required(self):
        paths, status, target, _, _ = self.streamed_sql_fixture()
        original = copy.deepcopy(status)
        fingerprint = figure.evidence.fingerprint
        for mode in ('bool-size', 'wrong-size', 'zero-size', 'url', 'job', 'invalid-sha1'):
            status = copy.deepcopy(original)
            job = status['jobs']['linktargettable'];item = job['files'][target.name]
            if mode == 'bool-size':item['size'] = True
            if mode == 'wrong-size':item['size'] += 1
            if mode == 'zero-size':item['size'] = 0
            if mode == 'url':item['url'] += '.other'
            if mode == 'job':job['status'] = 'waiting'
            if mode == 'invalid-sha1':item['sha1'] = 'not-a-sha1'
            def guarded(path):
                if path == target:self.fail('invalid official authority reached full hashing')
                return fingerprint(path)
            with self.subTest(mode=mode), patch.object(figure.evidence, 'fingerprint', side_effect=guarded), \
                    self.assertRaisesRegex(ValueError, 'exact dated dumpstatus authority'):
                figure.source_inventory(self.namespace.read_bytes(), self.wiki, self.date,
                    figure.encoded(status), paths)
        status = copy.deepcopy(original);status['jobs']['linktargettable']['files'][target.name]['sha1'] = '0'*40
        with self.assertRaisesRegex(ValueError, 'exact dated dumpstatus authority'):
            figure.source_inventory(self.namespace.read_bytes(), self.wiki, self.date,
                figure.encoded(status), paths)

    def test_large_sql_admission_retains_gzip_line_eof_and_late_duplicate_guards(self):
        paths, status, target, sql, replace = self.streamed_sql_fixture()
        for mode in ('gzip-trailer', 'sql-tail', 'line', 'late-duplicate'):
            data = sql
            if mode == 'sql-tail':data += "INSERT INTO `linktarget` VALUES (18,14,'Unfinished')"
            if mode == 'line':data += '-- '+'x'*(16*1024*1024)+'\n'
            if mode == 'late-duplicate':data += "-- after the selected target was resolved\nINSERT INTO `linktarget` VALUES (17,6,'Example.svg');\n"
            replace('linktarget', data)
            if mode == 'gzip-trailer':
                raw = target.read_bytes()[:-8];target.write_bytes(raw)
                status['jobs']['linktargettable']['files'][target.name].update(size=len(raw), sha1=hashlib.sha1(raw).hexdigest())
            with self.subTest(mode=mode), patch.object(figure.evidence, 'MAX_INPUT', 1), \
                    self.assertRaises((ValueError, EOFError, gzip.BadGzipFile)):
                figure.source_inventory(self.namespace.read_bytes(), self.wiki, self.date,
                    figure.encoded(status), paths)
        self.assertFalse((self.root/'files'/figure.COMPLETE).exists())


    def test_encoded_stream_record_limit_stops_before_second_request_and_retains_response(self):
        args = self.args(links=('Example.svg', 'Second.svg'));args.batch_size = 1
        response = self.response()
        response['query']['pages'][0]['imageinfo'][0]['metadata'] = [
            {'name': 'description', 'value': '\\"' * 8192}]
        raw = figure.encoded(response)
        first_batch = {'requests': ['\u0645\u0644\u0641:Example.svg'], 'response': raw.decode()}
        limit = len(figure.stream_encoded(first_batch))-1
        self.assertLess(len(raw), limit)
        calls = []
        def transport(url, timeout):
            calls.append(url)
            return 200, {}, raw
        with patch.object(figure, 'STREAM_RAW_LINE_LIMIT', limit):
            with self.assertRaisesRegex(ValueError, 'response record exceeds'):
                figure.capture_files(args, transport=transport, sleep=lambda _: None)
        self.assertEqual(len(calls), 1)
        self.assertEqual((args.output/'file-metadata.response-000001-01.raw.json').read_bytes(), raw)
        self.assertTrue((args.output/figure.FILE_REQUESTS).is_file())
        self.assertFalse((args.output/figure.COMPLETE).exists())


    def test_shared_batch_preserves_audio_positive_and_explicit_negative_provider_facts(self):
        args = self.args()
        log = self.root/'observed.log'
        log.write_text('warning: file metadata missing: title=ملف:Audio.ogg\n'
                       'warning: file metadata snapshot unavailable: title=ملف:Missing.svg\n')
        args.log = [log]
        calls = []
        def transport(url, timeout):
            calls.append(url)
            titles = parse_qs(urlsplit(url).query)['titles'][0].split('|')
            response = self.response();response['query']['pages'] = []
            for title in titles:
                page = self.response(title)['query']['pages'][0]
                if title.endswith('Audio.ogg'):
                    page['imageinfo'][0].update(mime='audio/ogg', mediatype='AUDIO', width=0, height=0)
                elif title.endswith('Missing.svg'):
                    page = {'title': title, 'ns': 6, 'missing': True, 'imagerepository': ''}
                response['query']['pages'].append(page)
            return 200, {}, figure.encoded(response)
        result = figure.capture_files(args, transport=transport)
        self.assertEqual(len(calls), 1)
        raw = (args.output/figure.PROVIDER).read_bytes()
        self.assertTrue(raw.startswith(b'# wikidict-file-metadata-v2\n'))
        rows = {parts[0]: parts[1:] for parts in (line.split('\t') for line in raw.decode().splitlines()[1:])}
        self.assertEqual(rows['ملف:Audio.ogg'], ['1', '0', '0', 'AUDIO', 'ملف:Audio.ogg'])
        self.assertEqual(rows['ملف:Missing.svg'], ['0', '0', '0', '-', '-'])
        self.assertEqual(result['coverage']['unsupported'], 1)
        self.assertEqual(result['coverage']['provider'], {'header_version': 2, 'rows': 3,
            'positive_rows': 2, 'negative_rows': 1, 'sql_files': 1, 'observed_query_files': 2,
            'observed_only_files': 2, 'corpus_query_closure_proven': False})
        self.assertEqual(figure.verify(args.output), result)
        self.assertEqual(json.loads((args.output/figure.INVENTORY).read_text())['titles'], ['ملف:Example.svg'])
        copied = json.loads((args.output/figure.QUERY_INPUTS).read_text())[0]
        self.assertEqual((args.output/copied['path']).read_bytes(), log.read_bytes())
        # Rehashing a dropped positive audio row cannot turn unsupported Figure
        # policy into an authoritative negative Lua existence result.
        changed = raw.replace('ملف:Audio.ogg\t1\t0\t0\tAUDIO\tملف:Audio.ogg'.encode(),
                              'ملف:Audio.ogg\t0\t0\t0\t-\t-'.encode())
        self.assertNotEqual(changed, raw)
        (args.output/figure.PROVIDER).write_bytes(changed)
        result['outputs']['file-metadata'] = figure.digest(changed)
        result['artifacts'] = figure.payload(args.output)
        (args.output/figure.MANIFEST).write_bytes(figure.encoded(result))
        (args.output/figure.COMPLETE).write_bytes(figure.encoded({'schema': figure.SCHEMA,
            'manifest_sha256': figure.digest((args.output/figure.MANIFEST).read_bytes())}))
        with self.assertRaisesRegex(ValueError, 'Provider TSV differs'):
            figure.verify(args.output)

    def test_shared_capture_normal_discovery_validation_and_single_copy(self):
        args = self.args()
        args.output = self.root/'figure-inputs'
        result = figure.capture_files(args, transport=lambda *_: (200, {}, figure.encoded(self.response())))
        with patch.object(figure, 'verify', wraps=figure.verify) as replay:
            selected = builder.discover_auxiliary_generation(self.root, 'figure-inputs',
                tuple(figure.ROLES), self.wiki, self.date)
            self.assertEqual(replay.call_count, 1)
        self.assertEqual(set(selected), {*figure.ROLES, 'file-metadata'})
        with patch.object(figure, 'verify', wraps=figure.verify) as replay:
            hashes, captures = builder._validated_auxiliary_state(selected, self.wiki, self.date,
                captured_selection=({}, result['source_dump_files'], None))
            # Discovery already published the exact guarded interpreter-local tuple.
            self.assertEqual(replay.call_count, 0)
        identities = builder._project_auxiliary_capture_identities(captures)
        target = self.root/'pinned'
        with patch.object(builder, 'copy_verified_snapshot', wraps=builder.copy_verified_snapshot) as copies:
            pinned = builder.pinned_auxiliary_snapshots(selected, hashes, target, *identities)
        self.assertEqual({path.parent for path in pinned.values()}, {target/'figure-inputs'})
        destinations = [call.args[1] for call in copies.call_args_list]
        self.assertEqual(len(destinations), len(set(destinations)))
        self.assertEqual(figure.verify(target/'figure-inputs'), result)
        self.assertEqual(builder.auxiliary_manifest_filename('file-metadata', pinned['file-metadata']), figure.MANIFEST)
        with self.assertRaisesRegex(ValueError, 'requires its Provider'):
            builder._validated_auxiliary_state({k: v for k, v in selected.items() if k != 'file-metadata'})
        changed = copy.deepcopy(result['source_dump_files']);changed[0]['sha1'] = '0'*40
        with self.assertRaisesRegex(ValueError, 'differs from selected dump'):
            builder._validated_auxiliary_state(selected, self.wiki, self.date,
                captured_selection=({}, changed, None))

    def test_observed_query_copy_cannot_change_under_rehashed_package(self):
        args = self.args()
        log = self.root/'queries.log'
        log.write_text('warning: file metadata missing: title=ملف:Example.svg\n')
        args.log = [log]
        result = figure.capture_files(args, transport=lambda *_: (200, {}, figure.encoded(self.response())))
        query_path = args.output/json.loads((args.output/figure.QUERY_INPUTS).read_text())[0]['path']
        query_path.write_text('warning: file metadata missing: title=ملف:Unknown.svg\n')
        result['artifacts'] = figure.payload(args.output)
        (args.output/figure.MANIFEST).write_bytes(figure.encoded(result))
        with self.assertRaisesRegex(ValueError, 'Observed file query source changed'):
            figure.verify(args.output, require_complete=False)

    def test_retained_request_batch_is_replayed_once_without_recapture(self):
        args = self.args()
        donor = self.root/'retained-batch';donor.mkdir()
        (donor/metadata.NAMESPACE).write_bytes(self.namespace.read_bytes())
        registry = figure.evidence.Registry(self.namespace.read_bytes(), self.wiki, self.date)
        _, batch = metadata.request_batch(donor, 1, ['ملف:Example.svg'], registry,
            lambda *_: (200, {}, figure.encoded(self.response())), lambda _: None,
            figure.time.monotonic()+30, 1, figure_axes=True)
        artifacts = {path.name: {'size': path.stat().st_size, 'sha256': figure.digest(path.read_bytes())}
                     for path in donor.iterdir()}
        record = {'wiki': self.wiki, 'date': self.date, 'batch': batch, 'artifacts': artifacts}
        identity = donor/'selected-facts-result.json';identity.write_bytes(figure.encoded(record))
        args.reuse_batch = [identity]
        before = {path.name: path.read_bytes() for path in donor.iterdir()}
        result = figure.capture_files(args, transport=lambda *_: self.fail('retained facts were recaptured'))
        self.assertEqual(result['coverage']['provider']['positive_rows'], 1)
        self.assertEqual(before, {path.name: path.read_bytes() for path in donor.iterdir()})
        self.assertEqual(figure.verify(args.output), result)
        receipt_path = donor/batch['accepted_receipt']
        receipt = json.loads(receipt_path.read_text());receipt['status'] = 403
        receipt_path.write_bytes(figure.encoded(receipt))
        record['artifacts'][receipt_path.name] = {'size': receipt_path.stat().st_size,
                                                'sha256': figure.digest(receipt_path.read_bytes())}
        identity.write_bytes(figure.encoded(record))
        with self.assertRaisesRegex(ValueError, 'accepted receipt'):
            figure.retained_metadata_batch(identity, self.wiki, self.date, self.namespace.read_bytes())

    def test_unknown_query_result_never_becomes_negative_or_complete(self):
        args = self.args(links=())
        log = self.root/'queries.log'
        log.write_text('warning: file metadata missing: title=ملف:Unknown.svg\n')
        args.log = [log]
        response = self.response('ملف:Unknown.svg')
        response['query']['pages'][0]['filehidden'] = True
        with self.assertRaisesRegex(ValueError, 'inaccessible'):
            figure.capture_files(args, transport=lambda *_: (200, {}, figure.encoded(response)))
        self.assertTrue((args.output/'file-metadata.response-000001-01.raw.json').is_file())
        self.assertTrue((args.output/figure.QUERY_INPUTS).is_file())
        self.assertFalse((args.output/figure.PROVIDER).exists())
        self.assertFalse((args.output/figure.COMPLETE).exists())

    def test_empty_shared_capture_is_header_only_and_legacy_stage_stays_four_roles(self):
        args = self.args(links=())
        result = figure.capture_files(args, transport=lambda *_: self.fail('empty inventory made HTTP'))
        self.assertEqual((args.output/figure.PROVIDER).read_bytes(), (metadata.HEADER+'\n').encode())
        self.assertEqual(result['coverage']['provider']['rows'], 0)
        self.assertFalse(result['coverage']['provider']['corpus_query_closure_proven'])
        self.write_projection()
        legacy = self.stage('legacy')
        self.assertFalse((legacy/figure.PROVIDER).exists())
        self.assertEqual(set(figure.verify(legacy)['outputs']), set(figure.ROLES))

    def test_observed_query_seed_bounds_and_duplicate_inputs_precede_http(self):
        args = self.args()
        log = self.root/'queries.log';log.write_bytes(b'ignored log row\n')
        args.log = [log, log]
        with self.assertRaisesRegex(ValueError, 'duplicate'):
            figure.capture_files(args, transport=lambda *_: self.fail('invalid seeds made HTTP'))
        self.assertFalse(args.output.exists())
        args.log = [log]
        original = figure.evidence.stamp
        def oversized(path):
            value = original(path)
            return (*value[:2], figure.MAX_METADATA + 1, *value[3:]) if Path(path) == log else value
        with patch.object(figure.evidence, 'stamp', side_effect=oversized):
            with self.assertRaisesRegex(ValueError, 'exceed'):
                figure.capture_files(args, transport=lambda *_: self.fail('oversized seed made HTTP'))
        self.assertFalse(args.output.exists())

    def test_combined_sql_and_observed_queries_preserve_all_selected_names(self):
        args = self.args()
        log = self.root/'queries.log'
        log.write_text('warning: file metadata missing: title=\u0645\u0644\u0641:Other.svg\n')
        args.log = [log]
        def transport(url, timeout):
            titles = parse_qs(urlsplit(url).query)['titles'][0].split('|')
            response = self.response();response['query']['pages'] = [self.response(t)['query']['pages'][0] for t in titles]
            return 200, {}, figure.encoded(response)
        with patch.object(figure, 'MAX_TITLES', 1), patch.object(figure.evidence, 'MAX_TITLES', 1):
            result = figure.capture_files(args, transport=transport)
        self.assertEqual(result['coverage']['files'], 2)
        self.assertEqual(result['coverage']['provider']['observed_only_files'], 1)
        self.assertEqual(figure.verify(args.output), result)


    def test_inventory_rejects_malformed_authority_and_changes_after_hashing(self):
        paths, status = self.inventory()
        for value in (None, {'jobs': None}, {'jobs': {'imagetable': []}},
                      {'jobs': {'imagetable': {'files': {paths[0].name: None}}}}):
            with self.assertRaises(ValueError):
                figure.source_inventory(self.namespace.read_bytes(), self.wiki, self.date,
                                        figure.encoded(value), paths)
        original = figure.evidence.sql_rows
        def changing_rows(path, fields):
            yield from original(path, fields)
            if Path(path) == paths[1]:
                with paths[0].open('ab') as stream:
                    stream.write(b'changed after authentication')
        with patch.object(figure.evidence, 'sql_rows', side_effect=changing_rows):
            with self.assertRaisesRegex(ValueError, 'changed during inventory'):
                figure.source_inventory(self.namespace.read_bytes(), self.wiki, self.date,
                                        status.read_bytes(), paths)

    def svg_observation(self, core=None):
        base = self.response()
        base['query']['general']['git-hash'] = core or figure.FIGURE_COMPATIBLE_CORE
        image = base['query']['pages'][0]['imageinfo'][0]
        image.update(width=103, height=94)
        observed = copy.deepcopy(base)
        observed['query']['pages'][0]['imageinfo'][0].update(
            url='https://upload.wikimedia.org/original.svg?utm_content=original',
            thumburl='https://thumb.wikimedia.org/rendered.png?utm_content=thumbnail',
            thumbwidth=250, thumbheight=228, thumbattribs={'width': 250, 'height': 228})
        supplement = self.batch(response=observed)
        supplement['observed_svg_width_px'] = 250
        return base, observed, supplement

    def test_observed_svg_width_is_corroborated_without_changing_base_identity(self):
        for core in (figure.FIGURE_COMPATIBLE_CORE, figure.FIGURE_CURRENT_CORE):
            with self.subTest(core=core):
                base, observed, supplement = self.svg_observation(core)
                document = self.project([self.batch(response=base), supplement], site=base)
                row = document['records'][0]
                self.assertEqual((row['batch'], row['observed_batch'], row['observed_svg_width_px']), (0, 1, 250))
                self.assertEqual((row['original_width'], row['original_height']), (103, 94))
                self.assertEqual(row['file_sha1'], base['query']['pages'][0]['imageinfo'][0]['sha1'])
                self.assertEqual(document['core_revision'], core)
                self.assertTrue(figure.figure_source_compatible(document['core_revision'], self.core))
                self.assertFalse(figure.figure_source_compatible(document['core_revision'], '0'*40))
                self.assertNotIn('observed_svg_width_px', self.project([self.batch(response=base)], site=base)['records'][0])
                raw = figure.encoded({'schema': figure.RAW_BATCHES_SCHEMA, 'batches': [self.batch(response=base), supplement]})
                self.assertEqual(figure.verify_figure_file_document(document, raw, self.namespace.read_bytes(), self.wiki, self.date, figure.encoded(base)), document)
                false_projection = copy.deepcopy(document);false_projection['records'][0]['observed_svg_width_px'] = 500
                with self.assertRaises(ValueError):
                    figure.verify_figure_file_document(false_projection, raw, self.namespace.read_bytes(), self.wiki, self.date, figure.encoded(base))

    def test_observed_svg_refuses_bitmap_native_url_wrong_axes_identity_and_ordinary_duplicates(self):
        base, observed, supplement = self.svg_observation()
        for key, value in (('thumbheight', 229), ('thumbwidth', 251), ('thumbattribs', {'width': 250, 'height': 229}),
                           ('thumburl', 'https://upload.wikimedia.org/original.svg?utm_content=thumbnail'),
                           ('thumburl', 'https://user@thumb.wikimedia.org/rendered.png'),
                           ('sha1', '0'*40), ('timestamp', '2020-01-01T00:00:00Z'), ('thumberror', 'failed')):
            changed = copy.deepcopy(observed)
            changed['query']['pages'][0]['imageinfo'][0][key] = value
            other = dict(supplement, response=figure.encoded(changed).decode())
            with self.subTest(key=key, value=value), self.assertRaises(ValueError):
                self.project([self.batch(response=base), other], site=base)
        jpeg_base, jpeg_observed = copy.deepcopy(base), copy.deepcopy(observed)
        for response in (jpeg_base, jpeg_observed):
            response['query']['pages'][0]['imageinfo'][0].update(mime='image/jpeg', mediatype='BITMAP')
        with self.assertRaises(ValueError):
            self.project([self.batch(response=jpeg_base), dict(supplement, response=figure.encoded(jpeg_observed).decode())], site=base)
        with self.assertRaises(ValueError):self.project([supplement], site=base)
        with self.assertRaises(ValueError):self.project([self.batch(response=base), self.batch(response=observed)], site=base)
        with self.assertRaises(ValueError):self.project([self.batch(response=base), supplement, supplement], site=base)
        wrong_core = copy.deepcopy(observed);wrong_core['query']['general']['git-hash'] = self.core
        with self.assertRaises(ValueError):
            self.project([self.batch(response=base), dict(supplement, response=figure.encoded(wrong_core).decode())], site=base)

    def write_svg_observation(self, response):
        from urllib.parse import urlencode
        donor = self.root/'observed-svg';donor.mkdir()
        name = response['query']['pages'][0]['title']
        query = {'action': 'query', 'format': 'json', 'formatversion': '2', 'meta': 'siteinfo',
            'siprop': 'general|extensions', 'prop': 'imageinfo',
            'iiprop': 'size|sha1|timestamp|canonicaltitle|mediatype|mime|metadata|url',
            'iilimit': '1', 'redirects': '1', 'maxlag': '5', 'titles': name, 'curtimestamp': '1', 'iiurlwidth': '250'}
        request = {'fixed_verified_batch_contract': False, 'request_count': 1, 'titles': [name],
                   'query': query, 'url': figure.wiktionary_api(self.wiki)+'?'+urlencode(query)}
        raw = figure.encoded(response)
        receipt = {'accepted': True, 'status': 200, 'request_count': 1, 'response': 'response01.raw.json',
                   'response_bytes': len(raw), 'response_sha256': figure.digest(raw)}
        for filename, data in ((metadata.NAMESPACE, self.namespace.read_bytes()), ('request01.json', figure.encoded(request)),
                               ('receipt01.json', figure.encoded(receipt)), ('response01.raw.json', raw)):
            (donor/filename).write_bytes(data)
        record = {'wiki': self.wiki, 'date': self.date, 'observed_svg_width_px': 250,
                  'batch': {'request': 'request01.json', 'accepted_receipt': 'receipt01.json'},
                  'artifacts': {p.name: {'size': p.stat().st_size, 'sha256': figure.digest(p.read_bytes())} for p in donor.iterdir()}}
        path = donor/'retained-observation.json';path.write_bytes(figure.encoded(record))
        return path

    def test_observed_request_reuse_keeps_original_audio_negative_and_never_recaptures(self):
        base, observed, supplement = self.svg_observation()
        audio = 'ملف:Missing.ogg'
        base['query']['pages'].append({'title': audio, 'ns': 6, 'missing': True, 'imagerepository': ''})
        args = self.args(links=('Example.svg', 'Missing.ogg'))
        donor = self.root/'original-two-facts';donor.mkdir()
        (donor/metadata.NAMESPACE).write_bytes(self.namespace.read_bytes())
        registry = figure.evidence.Registry(self.namespace.read_bytes(), self.wiki, self.date)
        _, batch = metadata.request_batch(donor, 1, ['ملف:Example.svg', audio], registry,
            lambda *_: (200, {}, figure.encoded(base)), lambda _: None,
            figure.time.monotonic()+30, 1, figure_axes=True)
        record = {'wiki': self.wiki, 'date': self.date, 'batch': batch,
                  'artifacts': {p.name: {'size': p.stat().st_size, 'sha256': figure.digest(p.read_bytes())} for p in donor.iterdir()}}
        identity = donor/'selected-facts.json';identity.write_bytes(figure.encoded(record))
        observation = self.write_svg_observation(observed)
        args.reuse_batch = [observation, identity]  # Import order must not lose the base facts.
        before = {str(p): p.read_bytes() for directory in (donor, observation.parent) for p in directory.iterdir()}
        result = figure.capture_files(args, transport=lambda *_: self.fail('retained source was recaptured'))
        self.assertEqual(result['coverage']['provider']['positive_rows'], 1)
        self.assertEqual(result['coverage']['provider']['negative_rows'], 1)
        self.assertEqual(result['coverage']['observed_svg_files'], 1)
        self.assertEqual((args.output/figure.ROLES['figure-siteinfo']).read_bytes(), (self.root/'defaults'/figure.site_info.SNAPSHOT).read_bytes())
        self.assertEqual(figure.verify(args.output), result)
        self.assertEqual(before, {str(p): p.read_bytes() for directory in (donor, observation.parent) for p in directory.iterdir()})
        projection = self.stream_document(args.output)
        self.assertEqual(projection['core_revision'], figure.FIGURE_COMPATIBLE_CORE)
        self.assertEqual(next(row for row in projection['records'] if row['requested_file'] == audio)['state'], 'missing')

    def test_observed_request_query_and_receipt_are_replayed_after_coherent_rehash(self):
        _, observed, _ = self.svg_observation()
        path = self.write_svg_observation(observed)
        original = json.loads(path.read_text())
        original_request = json.loads((path.parent/'request01.json').read_text())
        original_receipt = json.loads((path.parent/'receipt01.json').read_text())
        for mode in range(5):
            request, receipt = copy.deepcopy(original_request), copy.deepcopy(original_receipt)
            if mode == 0:request['query']['iiurlwidth'] = '251'
            if mode == 1:request['url'] += '&iiurlwidth=250'
            if mode == 2:receipt['status'] = 403
            if mode == 3:request['fixed_verified_batch_contract'] = True
            if mode == 4:request['url'] = request['url'].replace('ar.wiktionary.org', 'en.wiktionary.org')
            (path.parent/'request01.json').write_bytes(figure.encoded(request))
            (path.parent/'receipt01.json').write_bytes(figure.encoded(receipt))
            record = copy.deepcopy(original)
            for name in ('request01.json', 'receipt01.json'):
                data = (path.parent/name).read_bytes();record['artifacts'][name] = {'size': len(data), 'sha256': figure.digest(data)}
            path.write_bytes(figure.encoded(record))
            with self.subTest(mode=mode), self.assertRaises(ValueError):
                figure.retained_metadata_batch(path, self.wiki, self.date, self.namespace.read_bytes())


    def test_stream_records_preserve_all_bytes_above_legacy_aggregate_limit(self):
        args = self.args(links=('Example.svg', 'Second.svg'));args.batch_size = 1
        responses = []
        def transport(url, timeout):
            title = parse_qs(urlsplit(url).query)['titles'][0]
            response = self.response(title)
            response['query']['pages'][0]['imageinfo'][0]['metadata'] = [{'name': 'description', 'value': 'x'*4096}]
            raw = figure.encoded(response);responses.append(raw)
            return 200, {}, raw
        with patch.object(figure, 'MAX_METADATA', 1), patch.object(figure, 'MAX_BATCHES', 1):
            result = figure.capture_files(args, transport=transport, sleep=lambda _: None)
        self.assertEqual(result['coverage']['files'], 2)
        batches = list(figure.stream_values(args.output/figure.ROLES['figure-sizing-raw'], figure.RAW_STREAM_SCHEMA))[1:]
        self.assertEqual([b['response'].encode() for b in batches], responses)
        self.assertFalse(list(args.output.glob('file-metadata.response-*.raw.json')))
        self.assertEqual(len(list(args.output.glob('file-metadata.response-*.receipt.json'))), 2)
        self.assertTrue(all(row['url'].startswith('https://dumps.wikimedia.org/') for row in result['source_dump_files']))
        self.assertEqual(figure.verify(args.output), result)

    def test_stream_lf_counts_hash_and_exact_eof_are_required(self):
        for raw in (b'{"value":1e400}\n', b'{"value":-1e400}\n', b'{"value":NaN}\n', b'{"value":Infinity}\n'):
            with self.assertRaisesRegex(ValueError, 'Nonfinite'):
                figure.stream_decode(raw)
        self.assertEqual(figure.stream_decode(b'{"value":1.5}\n'), {'value': 1.5})
        args = self.args()
        figure.capture_files(args, transport=lambda *_: (200, {}, figure.encoded(self.response())))
        projection_path = args.output/figure.ROLES['figure-sizing']
        raw_path = args.output/figure.ROLES['figure-sizing-raw']
        original = projection_path.read_bytes()
        lines = original.splitlines(keepends=True)
        header = json.loads(lines[0])
        bad_headers = []
        for key, value in (('records_count', True), ('records_count', 1.0), ('records_count', 2),
                           ('base_batches', 0), ('observed_batches', 2), ('raw_bytes', raw_path.stat().st_size+1),
                           ('raw_sha256', '0'*64)):
            changed = dict(header);changed[key] = value;bad_headers.append(figure.stream_encoded(changed)+b''.join(lines[1:]))
        for invalid in [original[:-1], original+b'{}\n', original+b'\n', original.replace(b'\n',b'\r\n',1),
                        b'\xef\xbb\xbf'+original, *bad_headers]:
            with self.subTest(prefix=invalid[:30]):
                projection_path.write_bytes(invalid)
                with self.assertRaises((ValueError, StopIteration)):
                    figure.verify_stream_document(projection_path, raw_path, self.namespace.read_bytes(),
                        self.wiki, self.date, (args.output/figure.ROLES['figure-sizing-site']).read_bytes())
        projection_path.write_bytes(original)
        self.assertEqual(len(figure.verify_stream_document(projection_path, raw_path,
            self.namespace.read_bytes(), self.wiki, self.date,
            (args.output/figure.ROLES['figure-sizing-site']).read_bytes())['records']), 1)
        requests = args.output/figure.FILE_REQUESTS
        original_requests = requests.read_bytes()
        with patch.object(figure, 'STREAM_HEADER_LIMIT', len(original_requests.splitlines(keepends=True)[0])):
            requests.write_bytes(b' '+original_requests)
            with self.assertRaisesRegex(ValueError, 'header exceeds'):
                list(figure.source_records(requests, 1))
        requests.write_bytes(original_requests)

    def make_wall_stop(self):
        args = self.args(links=('Example.svg', 'Second.svg'));args.batch_size = 1;args.wall_seconds = 1
        clock, calls = [0.0], []
        def transport(url, timeout):
            calls.append(parse_qs(urlsplit(url).query)['titles'][0])
            return 200, {}, figure.encoded(self.response(calls[-1]))
        with patch.object(figure.time, 'monotonic', side_effect=lambda: clock[0]):
            with self.assertRaisesRegex(ValueError, 'Capture wall deadline reached'):
                figure.capture_files(args, transport=transport,
                    sleep=lambda delay: clock.__setitem__(0, clock[0]+delay))
        self.assertEqual(calls, ['\u0645\u0644\u0641:Example.svg'])
        self.assertFalse((args.output/'file-metadata.request-000002.json').exists())
        failure_path = args.output/'figure-failure-0001.json'
        failure = json.loads(failure_path.read_text())
        self.assertEqual(failure['committed_batches'], 1)
        descriptor = {'path': failure_path.name, 'bytes': failure_path.stat().st_size,
                      'sha256': figure.digest(failure_path.read_bytes())}
        plan = json.loads((args.output/figure.PLAN).read_text())
        closure = {'outcome': 'FAILED-PHYSICALLY-SOURCE-CLOSED', 'source_after': True, 'reaped': True,
            'dual_proc_absence': True, 'ps_absence': True, 'allocation_released': True, 'terminal': 1,
            'capture_failure': descriptor, 'capture_root': str(args.output.resolve()),
            'capture_plan_sha256': figure.digest(figure.encoded(plan))}
        raw = figure.encoded(closure)
        proof = {'schema': 'wikidict.figure-closed-wall-stop.v1', 'source_root': str(args.output.resolve()),
            'plan_sha256': closure['capture_plan_sha256'], 'failure': descriptor,
            'closure_raw': raw.decode(), 'closure': {'bytes': len(raw), 'sha256': figure.digest(raw)}}
        args.resume = args.output/figure.RESUME
        args.resume.write_bytes(figure.encoded(proof))
        args.wall_seconds = 30
        return args, proof

    def test_closed_pacing_wall_stop_resumes_without_refetch_and_preserves_prefix(self):
        args, _ = self.make_wall_stop()
        prefix = (args.output/figure.ROLES['figure-sizing-raw']).read_bytes()
        failure = (args.output/'figure-failure-0001.json').read_bytes()
        calls = []
        def transport(url, timeout):
            calls.append(parse_qs(urlsplit(url).query)['titles'][0])
            return 200, {}, figure.encoded(self.response(calls[-1]))
        result = figure.capture_files(args, transport=transport, sleep=lambda _: None)
        self.assertEqual(calls, ['\u0645\u0644\u0641:Second.svg'])
        self.assertTrue((args.output/figure.ROLES['figure-sizing-raw']).read_bytes().startswith(prefix))
        self.assertEqual((args.output/'figure-failure-0001.json').read_bytes(), failure)
        self.assertEqual(figure.verify(args.output), result)

    def test_resume_refuses_unclosed_changed_source_and_uncommitted_evidence(self):
        args, proof = self.make_wall_stop()
        original = args.resume.read_bytes()
        changed = copy.deepcopy(proof)
        closure = json.loads(changed['closure_raw']);closure['dual_proc_absence'] = False
        raw = figure.encoded(closure);changed['closure_raw'] = raw.decode()
        changed['closure'] = {'bytes': len(raw), 'sha256': figure.digest(raw)}
        args.resume.write_bytes(figure.encoded(changed))
        with self.assertRaisesRegex(ValueError, 'physical/source closure'):
            figure.capture_files(args, transport=lambda *_: self.fail('unclosed prefix made HTTP'))
        args.resume.write_bytes(original)
        with patch.object(figure, 'capture_source', return_value={'generator_sha256':'0'*64}):
            with self.assertRaisesRegex(ValueError, 'resume source'):
                figure.capture_files(args, transport=lambda *_: self.fail('changed source made HTTP'))
        (args.output/'uncommitted.raw').write_bytes(b'preserve me')
        with self.assertRaisesRegex(ValueError, 'uncommitted artifacts'):
            figure.capture_files(args, transport=lambda *_: self.fail('uncommitted prefix made HTTP'))
        self.assertEqual((args.output/'uncommitted.raw').read_bytes(), b'preserve me')

    def test_resume_never_turns_access_refusal_into_retry_permission(self):
        args, proof = self.make_wall_stop()
        failure_path = args.output/proof['failure']['path']
        failure = json.loads(failure_path.read_text());failure['error'] = 'API HTTP status 403'
        raw = figure.encoded(failure);failure_path.write_bytes(raw)
        proof['failure'].update(bytes=len(raw), sha256=figure.digest(raw))
        closure = json.loads(proof['closure_raw']);closure['capture_failure'] = proof['failure']
        raw = figure.encoded(closure);proof['closure_raw'] = raw.decode()
        proof['closure'] = {'bytes': len(raw), 'sha256': figure.digest(raw)}
        args.resume.write_bytes(figure.encoded(proof))
        with self.assertRaisesRegex(ValueError, 'closed wall-stop'):
            figure.capture_files(args, transport=lambda *_: self.fail('access refusal retried'))
        self.assertFalse((args.output/figure.COMPLETE).exists())


    def normal_build_inputs(self):
        args = self.args()
        downloads = self.root/'downloads'
        folder = downloads/self.wiki/self.date
        folder.mkdir(parents=True)
        sql = []
        selected = []
        from download_wiktionaries import BASE
        for source in args.sql:
            path = folder/source.name
            source.rename(path)
            sql.append(path)
            raw = path.read_bytes()
            selected.append(dict(wiki=self.wiki,date=self.date,name=path.name,
                url=BASE+'/'+self.wiki+'/'+self.date+'/'+path.name,size=len(raw),sha1=hashlib.sha1(raw).hexdigest()))
        xml = dict(wiki=self.wiki,date=self.date,name=self.wiki+'-'+self.date+'-pages-meta-current.xml.bz2',
            url=BASE+'/'+self.wiki+'/'+self.date+'/'+self.wiki+'-'+self.date+'-pages-meta-current.xml.bz2',size=1,sha1=hashlib.sha1(b'x').hexdigest())
        selected.append(xml)
        status = self.root/'pagetable-dumpstatus.raw.json'
        args.dumpstatus.rename(status)
        (self.root/'capture.complete.json').write_bytes(figure.encoded(dict(wiki=self.wiki,date=self.date,
            namespace_mismatches=[],source_xml=xml,artifacts={status.name:figure.digest(status.read_bytes())})))
        (self.root/'defaults').rename(self.root/'figure-defaults')
        return dict(capture_root=self.root,manifest={'files':selected,'requested_editions':[self.wiki],'failures':[]},
            selected_inputs=selected,downloads=downloads,namespace_registry=self.namespace)

    def normal_capture_result(self, call, selected):
        # Only the capture boundary is stubbed: SQL replay and defaults validation
        # are real. Full streamed capture/replay is qualified by its own controls.
        root=call.output
        root.mkdir(exist_ok=True)
        outputs={}
        for role,filename in {**figure.ROLES,'file-metadata':figure.PROVIDER}.items():
            data=('fixture '+role).encode();(root/filename).write_bytes(data);outputs[role]=figure.digest(data)
        source=[row for row in selected if row['name'].endswith('.sql.gz')]
        record=dict(schema=figure.SCHEMA,wiki=self.wiki,date=self.date,source_dump_files=source,
            namespace_registry_sha256=figure.digest(self.namespace.read_bytes()),outputs=outputs)
        (root/figure.MANIFEST).write_bytes(figure.encoded(record))
        (root/figure.COMPLETE).write_bytes(figure.encoded(dict(schema=figure.SCHEMA,
            manifest_sha256=figure.digest((root/figure.MANIFEST).read_bytes()))))
        return record

    def test_normal_preparation_uses_real_sql_and_defaults_with_one_private_inventory(self):
        inputs=self.normal_build_inputs()
        def capture(call):
            self.assertEqual(call.output,self.root/'figure-inputs')
            self.assertEqual((call.wiki,call.date),(self.wiki,self.date))
            self.assertEqual(call.defaults,self.root/'figure-defaults')
            self.assertEqual((call.reuse,call.reuse_batch,call.log),([],[],[]))
            self.assertEqual((call.batch_size,call.delay,call.wall_seconds),(50,1,86400))
            inventory,stamps=call.prepared_inventory
            self.assertEqual(inventory['namespace_registry_sha256'],figure.digest(self.namespace.read_bytes()))
            self.assertEqual(set(stamps),set(call.sql))
            self.assertEqual(set(inventory['titles']),{'ملف:Example.svg'})
            self.assertIsNone(call.resume)
            return self.normal_capture_result(call,inputs['selected_inputs'])
        with patch.object(figure,'capture_files',side_effect=capture) as collect,patch.object(figure.site_info,'capture') as defaults,patch.object(figure,'source_inventory',wraps=figure.source_inventory) as replay:
            selected=figure.prepare_for_build(**inputs,network=True)
        collect.assert_called_once();defaults.assert_not_called();self.assertEqual(replay.call_count,1)
        self.assertEqual(set(selected),{*figure.ROLES,'file-metadata'})
        self.assertEqual({path.parent for path in selected.values()},{self.root/'figure-inputs'})

    def test_normal_offline_cache_reuse_joins_selected_manifest_and_namespace(self):
        inputs=self.normal_build_inputs();root=self.root/'figure-inputs';root.mkdir()
        (root/figure.COMPLETE).write_text('published fixture marker')
        record=dict(source_dump_files=[row for row in inputs['selected_inputs'] if row['name'].endswith('.sql.gz')],
            namespace_registry_sha256=figure.digest(self.namespace.read_bytes()))
        verified={role:(record,{}) for role in {*figure.ROLES,'file-metadata'}}
        with patch.object(figure,'verify_tuple',return_value=verified) as verify,patch.object(figure,'capture_files') as collect,patch.object(figure.site_info,'capture') as defaults:
            selected=figure.prepare_for_build(**inputs)
        verify.assert_called_once();collect.assert_not_called();defaults.assert_not_called()
        self.assertEqual(set(selected),set(verified))
        record['source_dump_files'][0]=dict(record['source_dump_files'][0],sha1='0'*40)
        with patch.object(figure,'verify_tuple',return_value=verified),patch.object(figure,'capture_files') as collect,self.assertRaisesRegex(ValueError,'official SQL'):
            figure.prepare_for_build(**inputs,network=True)
        collect.assert_not_called()

    def test_normal_missing_or_changed_official_sql_never_makes_http(self):
        inputs=self.normal_build_inputs()
        for case in ('unselected','wrong-sha','changed-bytes'):
            with self.subTest(case=case):
                selected=copy.deepcopy(inputs['selected_inputs'])
                paths=sorted((inputs['downloads']/self.wiki/self.date).glob('*.sql.gz'))
                original=paths[0].read_bytes()
                if case=='unselected':selected=[row for row in selected if not row['name'].endswith('-image.sql.gz')]
                elif case=='wrong-sha':selected[0]['sha1']='0'*40
                else:paths[0].write_bytes(bytes([original[0]^1])+original[1:])
                selected_manifest=dict(inputs['manifest'],files=selected)
                with patch.object(figure,'capture_files') as collect,patch.object(figure.site_info,'capture') as defaults,self.assertRaises((ValueError,OSError,EOFError)):
                    figure.prepare_for_build(**dict(inputs,manifest=selected_manifest,selected_inputs=selected),network=True)
                collect.assert_not_called();defaults.assert_not_called();paths[0].write_bytes(original)

    def test_normal_invalid_published_capture_and_unproved_prefix_never_fall_back(self):
        inputs=self.normal_build_inputs();root=self.root/'figure-inputs';root.mkdir()
        with patch.object(figure,'capture_files') as collect,patch.object(figure.site_info,'capture') as defaults,self.assertRaisesRegex(ValueError,'resume proof'):
            figure.prepare_for_build(**inputs,network=True)
        collect.assert_not_called();defaults.assert_not_called()
        (root/figure.COMPLETE).write_text('invalid')
        with patch.object(figure,'verify_tuple',side_effect=ValueError('invalid published source')),patch.object(figure,'capture_files') as collect,patch.object(figure.site_info,'capture') as defaults,self.assertRaisesRegex(ValueError,'invalid published'):
            figure.prepare_for_build(**inputs,network=True)
        collect.assert_not_called();defaults.assert_not_called()

    def test_normal_offline_missing_capture_and_wrong_edition_do_not_acquire(self):
        inputs=self.normal_build_inputs()
        with patch.object(figure,'capture_files') as collect,patch.object(figure.site_info,'capture') as defaults:
            with self.assertRaisesRegex(ValueError,'offline'):
                figure.prepare_for_build(**inputs)
            selected=copy.deepcopy(inputs['selected_inputs']);selected[0]['wiki']='enwiktionary'
            with self.assertRaises(ValueError):figure.prepare_for_build(**dict(inputs,selected_inputs=selected),network=True)
        collect.assert_not_called();defaults.assert_not_called()

    def test_normal_resume_passes_exact_proof_and_cannot_fetch_new_defaults(self):
        inputs=self.normal_build_inputs();root=self.root/'figure-inputs';root.mkdir()
        (root/'figure-failure-0001.json').write_text('closed stop fixture')
        proof=root/'figure-resume.json';proof.write_text('callee passes existing proof to the capture verifier')
        (root/figure.PLAN).write_bytes(figure.encoded({'metadata_mode':'full','figure_profile':figure.FIGURE_PROFILE_V4}))
        def resume(call):
            self.assertEqual(call.resume,proof)
            self.assertEqual((call.metadata_mode,call.figure_profile),('full',figure.FIGURE_PROFILE_V4))
            return self.normal_capture_result(call,inputs['selected_inputs'])
        with patch.object(figure,'capture_files',side_effect=resume) as collect,patch.object(figure.site_info,'capture') as defaults:
            figure.prepare_for_build(**inputs,network=True)
        collect.assert_called_once();defaults.assert_not_called()

    def test_normal_missing_reviewed_defaults_sources_refuses_before_capture(self):
        inputs=self.normal_build_inputs()
        (self.root/'figure-defaults').rename(self.root/'unselected-original-defaults')
        with patch.object(figure,'capture_files') as collect,patch.object(figure.site_info,'capture') as defaults,self.assertRaises((ValueError,OSError)):
            figure.prepare_for_build(**inputs,network=True)
        collect.assert_not_called();defaults.assert_not_called()

    def test_normal_namespace_or_sql_drift_after_preflight_is_not_published(self):
        inputs=self.normal_build_inputs();original=self.namespace.read_bytes()
        def capture(call):
            result=self.normal_capture_result(call,inputs['selected_inputs'])
            self.namespace.write_bytes(original+b'\n')
            return result
        with patch.object(figure,'capture_files',side_effect=capture),self.assertRaisesRegex(ValueError,'changed before publication'):
            figure.prepare_for_build(**inputs,network=True)

    def test_normal_resume_uses_latest_failure_proof_without_old_fallback(self):
        inputs=self.normal_build_inputs();root=self.root/'figure-inputs';root.mkdir()
        (root/'figure-failure-0001.json').write_text('first closed stop')
        first=root/'figure-resume.json';first.write_text('first proof preserved')
        (root/'figure-failure-0002.json').write_text('second closed stop')
        (root/figure.PLAN).write_bytes(figure.encoded({'metadata_mode':'lean-tiff-v1'}))
        with patch.object(figure,'capture_files') as collect,self.assertRaisesRegex(ValueError,'Latest Figure failure'):
            figure.prepare_for_build(**inputs,network=True)
        collect.assert_not_called()
        latest=root/'figure-resume-0002.json';latest.write_text('second proof')
        def resume(call):
            self.assertEqual(call.resume,latest)
            self.assertEqual(first.read_text(),'first proof preserved')
            self.assertEqual((call.metadata_mode,call.figure_profile),('lean-tiff-v1',figure.FIGURE_PROFILE_V3))
            return self.normal_capture_result(call,inputs['selected_inputs'])
        with patch.object(figure,'capture_files',side_effect=resume):
            figure.prepare_for_build(**inputs,network=True)

    def test_normal_acquires_defaults_from_existing_reviewed_leaves_without_new_source_copy(self):
        inputs=self.normal_build_inputs()
        (self.root/'figure-defaults').rename(self.root/'unselected-original-defaults')
        real_capture=figure.site_info.capture
        figure.site_info.capture(argparse.Namespace(wiki=self.wiki,date=self.date,namespace_registry=self.namespace,
            primary_sources=self.primary,output=self.root/'site-info',delay=0,wall_seconds=30,figure_defaults=False),
            transport=lambda *_:(200,{},figure.encoded(self.data)),sleep=lambda _:None)
        original={path.name:path.read_bytes()for path in (self.root/'site-info').iterdir()}
        def defaults(call):
            self.assertEqual(call.primary_sources,self.root/'site-info')
            self.assertEqual(call.primary_sources_prefix,'site-info.source-')
            self.assertEqual(call.namespace_registry,self.namespace)
            self.assertTrue(call.figure_defaults)
            return real_capture(call,transport=lambda *_:(200,{},figure.encoded(self.data)),sleep=lambda _:None)
        with patch.object(figure.site_info,'capture',side_effect=defaults) as default_capture,patch.object(figure,'capture_files',side_effect=lambda call:self.normal_capture_result(call,inputs['selected_inputs'])):
            figure.prepare_for_build(**inputs,network=True)
        default_capture.assert_called_once()
        self.assertEqual(original,{path.name:path.read_bytes()for path in (self.root/'site-info').iterdir()})
        prepared=figure.site_info.validate_snapshot(self.root/'figure-defaults'/figure.site_info.SNAPSHOT,self.wiki,self.date)
        self.assertEqual(prepared['profile'],figure.site_info.FIGURE_PROFILE)

    def test_normal_resolver_prepares_and_reuses_real_five_role_stream(self):
        inputs = self.normal_build_inputs()
        calls = []
        def transport(url, timeout):
            calls.append(url)
            return 200, {}, figure.encoded(self.response())
        with patch.object(figure.evidence, 'get_response', side_effect=transport):
            paths = builder.resolve_figure_snapshot_options(self.root, inputs['manifest'],
                inputs['selected_inputs'], inputs['downloads'], self.namespace, {}, metadata_network='allow')
        self.assertEqual(len(calls), 1)
        self.assertEqual(set(paths), {*figure.ROLES, 'file-metadata'})
        result = figure.verify(self.root/'figure-inputs')
        self.assertEqual(result['coverage']['files'], 1)
        self.assertTrue(all(row['url'].startswith('https://dumps.wikimedia.org/') for row in result['source_dump_files']))
        with patch.object(figure.evidence, 'get_response', side_effect=AssertionError('published capture recaptured')):
            reused = builder.resolve_figure_snapshot_options(self.root, inputs['manifest'],
                inputs['selected_inputs'], inputs['downloads'], self.namespace, {}, metadata_network='offline')
        self.assertEqual(paths, reused)


    def write_normal_retained(self, name, response, titles, *, wiki=None, namespace=None):
        wiki = wiki or self.wiki
        namespace = namespace or self.namespace.read_bytes()
        donor = self.root/name;donor.mkdir()
        (donor/metadata.NAMESPACE).write_bytes(namespace)
        registry = figure.evidence.Registry(namespace, wiki, self.date)
        _, batch = metadata.request_batch(donor, 1, titles, registry,
            lambda *_: (200, {}, figure.encoded(response)), lambda _: None,
            figure.time.monotonic()+30, 1, figure_axes=True)
        record = {'wiki': wiki, 'date': self.date, 'batch': batch,
            'artifacts': {p.name: {'size': p.stat().st_size, 'sha256': figure.digest(p.read_bytes())} for p in donor.iterdir()}}
        path = donor/'selected-facts.json';path.write_bytes(figure.encoded(record))
        return path

    def test_normal_resolver_imports_base_and_observed_batch_without_refetch_and_checks_cached_plan(self):
        old_args = self.args
        with patch.object(self, 'args', side_effect=lambda: old_args(links=('Example.svg', 'Missing.ogg'))):
            inputs = self.normal_build_inputs()
        base, observation, _ = self.svg_observation()
        missing = '\u0645\u0644\u0641:Missing.ogg'
        base['query']['pages'].append({'title': missing, 'ns': 6, 'missing': True, 'imagerepository': ''})
        original = self.write_normal_retained('normal-retained', base, ['\u0645\u0644\u0641:Example.svg', missing])
        observed = self.write_svg_observation(observation)
        before = {str(p): p.read_bytes() for root in (original.parent, observed.parent) for p in root.iterdir()}
        selected = (observed, original)
        with patch.object(figure.evidence, 'get_response', side_effect=AssertionError('retained batch was refetched')):
            paths = builder.resolve_figure_snapshot_options(self.root, inputs['manifest'], inputs['selected_inputs'],
                inputs['downloads'], self.namespace, {}, metadata_network='allow', figure_reuse_batches=selected)
        result = figure.verify(self.root/'figure-inputs')
        self.assertEqual(result['coverage']['observed_svg_files'], 1)
        self.assertEqual(result['coverage']['provider']['negative_rows'], 1)
        self.assertEqual(set(paths), {*figure.ROLES, 'file-metadata'})
        with patch.object(figure.evidence, 'get_response', side_effect=AssertionError('cached capture made HTTP')):
            reused = builder.resolve_figure_snapshot_options(self.root, inputs['manifest'], inputs['selected_inputs'],
                inputs['downloads'], self.namespace, {}, metadata_network='offline', figure_reuse_batches=selected)
        self.assertEqual(reused, paths)
        self.assertEqual(before, {str(p): p.read_bytes() for root in (original.parent, observed.parent) for p in root.iterdir()})
        # A different declared record is not silently ignored by a completed cache.
        different = original.with_name('other-declaration.json');different.write_bytes(original.read_bytes())
        with patch.object(figure.evidence, 'get_response', side_effect=AssertionError('cache mismatch made HTTP')):
            with self.assertRaisesRegex(ValueError, 'does not contain'):
                builder.resolve_figure_snapshot_options(self.root, inputs['manifest'], inputs['selected_inputs'],
                    inputs['downloads'], self.namespace, {}, metadata_network='allow', figure_reuse_batches=(different, observed))
        self.assertEqual(figure.verify(self.root/'figure-inputs'), result)

    def test_explicit_batch_selection_authenticates_unrelated_editions_and_rejects_wrong_or_duplicate_records(self):
        original = self.write_normal_retained('selection-base', self.response(), ['\u0645\u0644\u0641:Example.svg'])
        unrelated = self.response();unrelated['query']['general'].update(wikiid='dewiktionary', server='https://de.wiktionary.org')
        namespace = self.namespace.read_bytes().replace(('# wiki\t'+self.wiki).encode(), b'# wiki\tdewiktionary')
        foreign = self.write_normal_retained('selection-foreign', unrelated,
            ['\u0645\u0644\u0641:Example.svg'], wiki='dewiktionary', namespace=namespace)
        selected = figure.select_reuse_batches((foreign, original), self.wiki, self.date, self.namespace.read_bytes())
        self.assertEqual([row['path'] for row in selected], [str(original)])
        with self.assertRaisesRegex(ValueError, 'Duplicate'):
            figure.select_reuse_batches((original, original), self.wiki, self.date, self.namespace.read_bytes())
        alias_b = self.response('ملف:B.svg')
        alias_b['query']['redirects'] = [{'from': 'ملف:A.svg', 'to': 'ملف:B.svg'}]
        alias_c = self.response('ملف:C.svg')
        alias_c['query']['redirects'] = [{'from': 'ملف:B.svg', 'to': 'ملف:C.svg'}]
        first_alias = self.write_normal_retained('alias-b', alias_b, ['ملف:A.svg'])
        second_alias = self.write_normal_retained('alias-c', alias_c, ['ملف:B.svg'])
        with self.assertRaisesRegex(ValueError, 'canonical alias'):
            figure.select_reuse_batches((first_alias, second_alias), self.wiki, self.date, self.namespace.read_bytes())
        raw = original.read_bytes();record = json.loads(raw)
        record['date'] = '20260901';original.write_bytes(figure.encoded(record))
        with self.assertRaises(ValueError):
            figure.select_reuse_batches((original,), self.wiki, self.date, self.namespace.read_bytes())
        original.write_bytes(raw)
        foreign_record = json.loads(foreign.read_bytes())
        receipt_path = foreign.parent/foreign_record['batch']['accepted_receipt']
        receipt = json.loads(receipt_path.read_text());receipt['status'] = 403
        receipt_path.write_bytes(figure.encoded(receipt))
        foreign_record['artifacts'][receipt_path.name] = {'size': receipt_path.stat().st_size, 'sha256': figure.digest(receipt_path.read_bytes())}
        foreign.write_bytes(figure.encoded(foreign_record))
        with self.assertRaisesRegex(ValueError, 'accepted receipt'):
            figure.select_reuse_batches((foreign, original), self.wiki, self.date, self.namespace.read_bytes())

    def test_observed_basename_validation_preserves_fixed_batch_contract_and_rejects_paths(self):
        _, observation, _ = self.svg_observation()
        path = self.write_svg_observation(observation)
        original = json.loads(path.read_bytes())
        self.assertEqual(figure.retained_metadata_batch(path, self.wiki, self.date,
            self.namespace.read_bytes())['observed_svg_width_px'], 250)
        for name in ('../request01.json', '/request01.json', 'nested/request01.json', '..', 'request%2f01.json'):
            with self.subTest(name=name):
                changed = copy.deepcopy(original)
                changed['artifacts'][name] = changed['artifacts'].pop('request01.json')
                path.write_bytes(figure.encoded(changed))
                with self.assertRaisesRegex(ValueError, 'Unsafe observed'):
                    figure.retained_metadata_batch(path, self.wiki, self.date, self.namespace.read_bytes())
        path.write_bytes(figure.encoded(original))
        fixed = self.write_normal_retained('fixed-names', self.response(), ['\u0645\u0644\u0641:Example.svg'])
        record = json.loads(fixed.read_text())
        old_name = record['batch']['request']
        record['artifacts']['request01.json'] = record['artifacts'].pop(old_name)
        (fixed.parent/'request01.json').write_bytes((fixed.parent/old_name).read_bytes())
        record['batch']['request'] = 'request01.json'
        fixed.write_bytes(figure.encoded(record))
        with self.assertRaisesRegex(ValueError, 'Unsafe file metadata'):
            figure.retained_metadata_batch(fixed, self.wiki, self.date, self.namespace.read_bytes())


    def combined_response(self, titles, *, light=False):
        value = self.response(titles[0])
        value['query']['pages'] = [self.response(title)['query']['pages'][0] for title in titles]
        if light:
            for page in value['query']['pages']:
                info = page['imageinfo'][0]
                info.pop('metadata', None)
                info.update(mime='image/vnd.djvu', mediatype='BITMAP')
        return value

    def make_oversize_prefix(self, *, normal=False):
        names = ('A.svg', 'B.svg', 'C.djvu', 'D.svg')
        inputs = None
        if normal:
            old_args = self.args
            with patch.object(self, 'args', side_effect=lambda: old_args(links=names)):
                inputs = self.normal_build_inputs()
            args = argparse.Namespace(wiki=self.wiki, date=self.date, defaults=self.root/'figure-defaults',
                dumpstatus=self.root/'pagetable-dumpstatus.raw.json',
                sql=[inputs['downloads']/self.wiki/self.date/row['name'] for row in inputs['selected_inputs'] if row['name'].endswith('.sql.gz')],
                output=self.root/'figure-inputs', reuse=[], batch_size=2, delay=1, wall_seconds=30, metadata_mode='full')
        else:
            args = self.args(links=names);args.batch_size = 2
        calls, clock = [], [0.0]
        def transport(url, timeout):
            titles = parse_qs(urlsplit(url).query)['titles'][0].split('|')
            calls.append(titles)
            if len(calls) == 2:
                return 200, {}, b'{' + b' ' * figure.MAX_RESPONSE
            return 200, {}, figure.encoded(self.combined_response(titles))
        with patch.object(figure.time, 'monotonic', side_effect=lambda:clock[0]):
            with self.assertRaisesRegex(ValueError, 'Oversized API response'):
                figure.capture_files(args, transport=transport, sleep=lambda d:clock.__setitem__(0,clock[0]+d))
        self.assertEqual(len(calls), 2)
        old_root = args.output
        failure_path = old_root/'figure-failure-0001.json'
        failure = json.loads(failure_path.read_text())
        self.assertEqual(failure['committed_batches'], 1)
        def descriptor(path):
            raw = path.read_bytes()
            return {'path':str(path.resolve()), 'bytes':len(raw), 'sha256':figure.digest(raw)}
        closure = {'outcome':'FAILED-PHYSICALLY-SOURCE-CLOSED', 'source_after':True, 'reaped':True,
            'dual_proc_absence':True, 'ps_absence':True, 'allocation_released':True, 'terminal':1,
            'capture_root':str(old_root.resolve()), 'capture_plan_sha256':failure['plan_sha256'],
            'capture_failure':descriptor(failure_path), 'committed_batches':1,
            'actual_request':descriptor(old_root/'file-metadata.request-000002.json'),
            'actual_receipt':descriptor(old_root/'file-metadata.response-000002-01.receipt.json'),
            'actual_response':descriptor(old_root/'file-metadata.response-000002-01.raw.json'),
            'raw_stream':descriptor(old_root/figure.ROLES['figure-sizing-raw'])}
        closure_path = self.root/'closed-prefix-closure.json';closure_path.write_bytes(figure.encoded(closure))
        kept = self.root/'closed-prefix-original';old_root.rename(kept)
        proof = {'schema':figure.CLOSED_PREFIX_SCHEMA, 'wiki':self.wiki, 'date':self.date,
            'source_root':str(kept.resolve()), 'original_root':str(old_root.resolve()),
            'closure':descriptor(closure_path), 'light_titles':['ملف:C.djvu']}
        proof_dir = self.root/'prefix-reference';proof_dir.mkdir()
        proof_path = proof_dir/'closed-prefix.json';proof_path.write_bytes(figure.encoded(proof))
        args.reuse_batch = [proof_path]
        return args, proof_path, inputs

    def test_closed_oversize_prefix_replays_before_http_and_keeps_exact_remaining_coverage(self):
        args, proof_path, _ = self.make_oversize_prefix()
        record = json.loads(proof_path.read_text())
        original = Path(record['source_root'])
        before = {p.name:p.read_bytes() for p in original.iterdir()}
        prefix = figure.read_closed_prefix(proof_path)
        self.assertEqual(len(prefix['document']['records']), 2)
        self.assertEqual(prefix['failed_titles'], ['ملف:C.djvu', 'ملف:D.svg'])
        calls, clock = [], [0.0]
        def transport(url, timeout):
            query = parse_qs(urlsplit(url).query)
            titles = query['titles'][0].split('|');light = 'metadata' not in query['iiprop'][0].split('|')
            calls.append((titles, light))
            return 200, {}, figure.encoded(self.combined_response(titles, light=light))
        with patch.object(figure.time, 'monotonic', side_effect=lambda:clock[0]):
            result = figure.capture_files(args, transport=transport, sleep=lambda d:clock.__setitem__(0,clock[0]+d))
        self.assertEqual(calls, [(['ملف:D.svg'], False), (['ملف:C.djvu'], True)])
        self.assertEqual(result['coverage']['files'], 4)
        document = self.stream_document(args.output)
        self.assertEqual({r['requested_file'] for r in document['records']}, {'ملف:A.svg','ملف:B.svg','ملف:C.djvu','ملف:D.svg'})
        self.assertEqual(next(r['state'] for r in document['records'] if r['requested_file']=='ملف:C.djvu'), 'unsupported')
        self.assertEqual(figure.verify(args.output), result)
        self.assertEqual(before, {p.name:p.read_bytes() for p in original.iterdir()})
        self.assertIn(b'C.djvu', (args.output/figure.PROVIDER).read_bytes())
        self.assertEqual(figure.select_reuse_batches((proof_path,), self.wiki, self.date, self.namespace.read_bytes())[0]['kind'], 'closed-prefix')

    def test_metadata_light_never_authorizes_tiff_supported_zero_axes_or_unknown_identity(self):
        for mime, media, width, height in [('image/tiff','BITMAP',800,600),('image/png','BITMAP',0,0),('image/svg+xml','DRAWING',0,600),('', 'BITMAP',800,600),('image/vnd.djvu','MULTIPAGE',800,600)]:
            with self.subTest(mime=mime):
                response = self.response('ملف:Candidate.bin')
                info = response['query']['pages'][0]['imageinfo'][0]
                info.pop('metadata', None);info.update(mime=mime,mediatype=media,width=width,height=height)
                with self.assertRaises(ValueError):
                    figure.validate_metadata_light(self.batch('ملف:Candidate.bin', response), self.namespace.read_bytes(), self.wiki, self.date)
        missing = self.response('ملف:Missing.bin')
        missing['query']['pages'][0] = {'title':'ملف:Missing.bin','ns':6,'missing':True,'imagerepository':''}
        self.assertEqual(figure.validate_metadata_light(self.batch('ملف:Missing.bin', missing), self.namespace.read_bytes(), self.wiki, self.date)['records'][0]['state'], 'missing')
        light = self.combined_response(['ملف:Candidate.djvu'], light=True)
        self.assertEqual(figure.validate_metadata_light(self.batch('ملف:Candidate.djvu', light), self.namespace.read_bytes(), self.wiki, self.date)['records'][0]['state'], 'unsupported')

    def test_closed_prefix_output_cannot_mutate_preserved_source_before_refusal(self):
        args, proof_path, _ = self.make_oversize_prefix()
        root = Path(json.loads(proof_path.read_text())['source_root'])
        before = {p.name:p.read_bytes() for p in root.iterdir()}
        args.output = root/'nested'/'new-capture'
        with self.assertRaisesRegex(ValueError, 'cannot modify its closed prefix'):
            figure.capture_files(args, transport=lambda *_:self.fail('nested output made HTTP'))
        self.assertEqual(before, {p.name:p.read_bytes() for p in root.iterdir()})
        self.assertFalse((root/'nested').exists())

    def test_closed_prefix_rejects_changed_plan_prefix_and_unclosed_receipt_before_http(self):
        args, proof_path, _ = self.make_oversize_prefix()
        proof = json.loads(proof_path.read_text());original = Path(proof['source_root'])
        for filename in (figure.PLAN, figure.ROLES['figure-sizing-raw'], figure.FILE_REQUESTS):
            path=original/filename;raw=path.read_bytes();path.write_bytes(raw+b' ')
            with self.assertRaises(ValueError):figure.read_closed_prefix(proof_path)
            path.write_bytes(raw)
        closure_path=Path(proof['closure']['path']);old=closure_path.read_bytes()
        closure=json.loads(old);closure['allocation_released']=False
        closure_path.write_bytes(figure.encoded(closure));proof['closure'].update(bytes=closure_path.stat().st_size,sha256=figure.digest(closure_path.read_bytes()))
        proof_path.write_bytes(figure.encoded(proof))
        with self.assertRaisesRegex(ValueError,'physical and source closure'):
            figure.capture_files(args,transport=lambda *_:self.fail('unclosed prefix made HTTP'))
        self.assertFalse((args.output/figure.COMPLETE).exists())

    def test_closed_prefix_rejects_omitted_members_and_access_refusal_even_when_rehashed(self):
        _, proof_path, _ = self.make_oversize_prefix()
        proof=json.loads(proof_path.read_text());root=Path(proof['source_root'])
        closure_path=Path(proof['closure']['path']);closure=json.loads(closure_path.read_text())
        failure_path=root/'figure-failure-0001.json';failure=json.loads(failure_path.read_text())
        request_path=root/Path(closure['actual_request']['path']).name
        receipt_path=root/Path(closure['actual_receipt']['path']).name
        original_request=request_path.read_bytes();original_receipt=receipt_path.read_bytes()
        def refresh(path, field):
            raw=path.read_bytes();identity={'bytes':len(raw),'sha256':figure.digest(raw)}
            failure['artifacts'][path.name]=identity;closure[field].update(identity)
            failure_path.write_bytes(figure.encoded(failure));raw=failure_path.read_bytes()
            closure['capture_failure'].update(bytes=len(raw),sha256=figure.digest(raw))
            closure_path.write_bytes(figure.encoded(closure));raw=closure_path.read_bytes()
            proof['closure'].update(bytes=len(raw),sha256=figure.digest(raw));proof_path.write_bytes(figure.encoded(proof))
        request=json.loads(original_request);request['titles']=['ملف:C.djvu']
        request['query']=metadata.query_for(self.wiki,request['titles'],figure_axes=True)
        request['url']=metadata.query_url(self.wiki,request['titles'],figure_axes=True)
        request_path.write_bytes(figure.encoded(request));refresh(request_path,'actual_request')
        with self.assertRaisesRegex(ValueError,'next uncommitted batch'):figure.read_closed_prefix(proof_path)
        request_path.write_bytes(original_request);refresh(request_path,'actual_request')
        receipt=json.loads(original_receipt);receipt['status']=403;receipt['error']='API HTTP status 403'
        receipt_path.write_bytes(figure.encoded(receipt));refresh(receipt_path,'actual_receipt')
        with self.assertRaisesRegex(ValueError,'oversized HTTP 200'):figure.read_closed_prefix(proof_path)

    def test_normal_resolver_consumes_closed_prefix_and_reuses_complete_plan_offline(self):
        args, proof_path, inputs = self.make_oversize_prefix(normal=True)
        calls=[]
        def transport(url, timeout):
            query=parse_qs(urlsplit(url).query);titles=query['titles'][0].split('|')
            light='metadata' not in query['iiprop'][0].split('|');calls.append((titles,light))
            return 200,{},figure.encoded(self.combined_response(titles,light=light))
        with patch.object(figure.evidence,'get_response',side_effect=transport):
            paths=builder.resolve_figure_snapshot_options(self.root,inputs['manifest'],inputs['selected_inputs'],
                inputs['downloads'],self.namespace,{},metadata_network='allow',figure_reuse_batches=(proof_path,))
        self.assertEqual(calls,[(['ملف:D.svg'],False),(['ملف:C.djvu'],True)])
        with patch.object(figure.evidence,'get_response',side_effect=AssertionError('complete prefix recaptured')):
            reused=builder.resolve_figure_snapshot_options(self.root,inputs['manifest'],inputs['selected_inputs'],
                inputs['downloads'],self.namespace,{},metadata_network='offline',figure_reuse_batches=(proof_path,))
        self.assertEqual(paths,reused)
        generation = self.root/'figure-inputs'
        plan_path = generation/figure.PLAN;old_plan=plan_path.read_bytes()
        manifest_path = generation/figure.MANIFEST;old_manifest=manifest_path.read_bytes()
        marker_path = generation/figure.COMPLETE;old_marker=marker_path.read_bytes()
        plan=json.loads(old_plan);plan['metadata_light_titles']=[]
        plan_path.write_bytes(figure.encoded(plan))
        manifest=json.loads(old_manifest)
        manifest['artifacts'][figure.PLAN]={'bytes':plan_path.stat().st_size,'sha256':figure.digest(plan_path.read_bytes())}
        manifest_path.write_bytes(figure.encoded(manifest))
        marker_path.write_bytes(figure.encoded({'schema':figure.SCHEMA,'manifest_sha256':figure.digest(manifest_path.read_bytes())}))
        with self.assertRaisesRegex(ValueError,'metadata-light scope'):
            figure.verify(generation)
        plan_path.write_bytes(old_plan);manifest_path.write_bytes(old_manifest);marker_path.write_bytes(old_marker)
        plan_path=self.root/'figure-inputs'/figure.PLAN;plan=json.loads(plan_path.read_text());plan['closed_prefixes']=[]
        plan_path.write_bytes(figure.encoded(plan))
        with self.assertRaises(ValueError):figure.require_reuse_coverage(self.root/'figure-inputs',figure.select_reuse_batches((proof_path,),self.wiki,self.date,self.namespace.read_bytes()))


    def make_svg_oversize_lookahead(self, *, normal=False):
        names = ('A.svg', 'B.svg', 'C.svg', 'D.svg', 'E.svg', 'F.svg')
        inputs = None
        if normal:
            old_args = self.args
            with patch.object(self, 'args', side_effect=lambda: old_args(links=names)):
                inputs = self.normal_build_inputs()
            args = argparse.Namespace(wiki=self.wiki, date=self.date, defaults=self.root/'figure-defaults',
                dumpstatus=self.root/'pagetable-dumpstatus.raw.json',
                sql=[inputs['downloads']/self.wiki/self.date/row['name'] for row in inputs['selected_inputs'] if row['name'].endswith('.sql.gz')],
                output=self.root/'figure-inputs', reuse=[], batch_size=2, delay=1, wall_seconds=30, metadata_mode='full')
        else:
            args = self.args(links=names)
            args.batch_size = 2
        args.max_inflight, args.figure_profile = 2, figure.FIGURE_PROFILE_V4
        lookahead_done, calls = threading.Event(), []
        def transport(url, timeout):
            titles = parse_qs(urlsplit(url).query)['titles'][0].split('|')
            calls.append(titles)
            if titles[0].endswith('C.svg'):
                self.assertTrue(lookahead_done.wait(5), 'accepted lookahead never entered transport')
                return 200, {}, b'{' + b' ' * figure.MAX_RESPONSE
            value = self.combined_response(titles)
            value['query']['general']['git-hash'] = figure.FIGURE_CURRENT_CORE
            if titles[0].endswith('E.svg'):
                lookahead_done.set()
            return 200, {}, figure.encoded(value)
        with self.assertRaisesRegex(ValueError, 'Oversized API response'):
            figure.capture_files(args, transport=transport)
        self.assertEqual(calls[0], ['ملف:A.svg','ملف:B.svg'])
        self.assertEqual(sorted(calls[1:]), [['ملف:C.svg','ملف:D.svg'], ['ملف:E.svg','ملف:F.svg']])
        old_root = args.output
        failure_path = old_root/'figure-failure-0001.json'
        failure = json.loads(failure_path.read_bytes())
        self.assertEqual((failure['committed_batches'], failure['pending_http']), (1, [2,3]))
        def descriptor(path):
            raw = path.read_bytes()
            return {'path':str(path.resolve()), 'bytes':len(raw), 'sha256':figure.digest(raw)}
        closure = {'outcome':'FAILED-PHYSICALLY-SOURCE-CLOSED', 'source_after':True, 'reaped':True,
            'dual_proc_absence':True, 'ps_absence':True, 'allocation_released':True, 'terminal':1,
            'capture_root':str(old_root.resolve()), 'capture_plan_sha256':failure['plan_sha256'],
            'capture_failure':descriptor(failure_path), 'committed_batches':1,
            'actual_request':descriptor(old_root/'file-metadata.request-000002.json'),
            'actual_receipt':descriptor(old_root/'file-metadata.response-000002-01.receipt.json'),
            'actual_response':descriptor(old_root/'file-metadata.response-000002-01.raw.json'),
            'raw_stream':descriptor(old_root/figure.ROLES['figure-sizing-raw'])}
        closure_path = self.root/'svg-oversize-closure.json'
        closure_path.write_bytes(figure.encoded(closure))
        kept = self.root/'svg-oversize-preserved'
        old_root.rename(kept)
        proof = {'schema':figure.CLOSED_PREFIX_SCHEMA, 'wiki':self.wiki, 'date':self.date,
            'source_root':str(kept.resolve()), 'original_root':str(old_root.resolve()),
            'closure':descriptor(closure_path), 'light_titles':['ملف:C.svg','ملف:D.svg']}
        reference_dir = self.root/'svg-oversize-reference'
        reference_dir.mkdir()
        reference = reference_dir/'closed-prefix.json'
        reference.write_bytes(figure.encoded(proof))
        args.reuse_batch = [reference]
        return args, reference, inputs

    def svg_light_transport(self, calls):
        def transport(url, timeout):
            query = parse_qs(urlsplit(url).query)
            titles = query['titles'][0].split('|')
            self.assertEqual(len(titles), 1)
            self.assertIn(titles[0], ('ملف:C.svg','ملف:D.svg'))
            self.assertEqual(query['iiprop'], ['size|sha1|timestamp|canonicaltitle|mediatype|mime'])
            calls.append(titles[0])
            value = self.combined_response(titles)
            value['query']['general']['git-hash'] = figure.FIGURE_CURRENT_CORE
            for page in value['query']['pages']:
                page['imageinfo'][0].pop('metadata', None)
            return 200, {}, figure.encoded(value)
        return transport

    def refresh_closed_svg_failure(self, reference):
        proof = json.loads(reference.read_bytes())
        root, closure_path = Path(proof['source_root']), Path(proof['closure']['path'])
        closure = json.loads(closure_path.read_bytes())
        failure_path = root/Path(closure['capture_failure']['path']).name
        failure = json.loads(failure_path.read_bytes())
        failure['artifacts'] = figure.payload(root)
        failure['artifacts'].pop(failure_path.name)
        failure_path.write_bytes(figure.encoded(failure))
        closure['capture_failure'].update(bytes=failure_path.stat().st_size, sha256=figure.digest(failure_path.read_bytes()))
        closure_path.write_bytes(figure.encoded(closure))
        proof['closure'].update(bytes=closure_path.stat().st_size, sha256=figure.digest(closure_path.read_bytes()))
        reference.write_bytes(figure.encoded(proof))

    def test_metadata_light_preserves_supported_svg_identity_without_metadata(self):
        for mime in ('image/svg+xml', 'image/svg'):
            response = self.response('ملف:Geometry.bin')
            response['query']['general']['git-hash'] = figure.FIGURE_CURRENT_CORE
            info = response['query']['pages'][0]['imageinfo'][0]
            info.update(mime=mime, mediatype='DRAWING')
            info.pop('metadata', None)
            batch = self.batch('ملف:Geometry.bin', response)
            result = figure.validate_metadata_light(batch, self.namespace.read_bytes(), self.wiki, self.date)
            row = result['records'][0]
            self.assertEqual((row['state'], row['mime'], row['original_width'], row['original_height']), ('eligible',mime,800,600))
            self.assertEqual((row['file_sha1'],row['file_timestamp'],row['canonical_file']),
                             (info['sha1'],info['timestamp'],info['canonicaltitle']))
            for field in ('sha1', 'timestamp', 'canonicaltitle', 'mime', 'mediatype', 'width', 'height'):
                changed = copy.deepcopy(response)
                changed['query']['pages'][0]['imageinfo'][0].pop(field)
                with self.subTest(mime=mime,field=field), self.assertRaises(ValueError):
                    figure.validate_metadata_light(self.batch('ملف:Geometry.bin', changed), self.namespace.read_bytes(), self.wiki, self.date)
        for mime,media in [('image/tiff','BITMAP'),('image/png','BITMAP'),('image/jpeg','BITMAP'),('image/gif','BITMAP')]:
            response = self.response('ملف:Not-svg.bin')
            info = response['query']['pages'][0]['imageinfo'][0]
            info.update(mime=mime,mediatype=media);info.pop('metadata',None)
            # v3 GIF remains the existing explicitly unsupported geometry case.
            if mime == 'image/gif':
                self.assertEqual(figure.validate_metadata_light(self.batch('ملف:Not-svg.bin',response),self.namespace.read_bytes(),self.wiki,self.date)['records'][0]['state'],'unsupported')
            else:
                with self.subTest(mime=mime),self.assertRaises(ValueError):
                    figure.validate_metadata_light(self.batch('ملف:Not-svg.bin',response),self.namespace.read_bytes(),self.wiki,self.date)

    def test_closed_oversize_reuses_two_slot_accepted_lookahead_without_refetch(self):
        args, reference, _ = self.make_svg_oversize_lookahead()
        original = Path(json.loads(reference.read_bytes())['source_root'])
        before = {p.name:p.read_bytes() for p in original.iterdir()}
        prefix = figure.read_closed_prefix(reference)
        self.assertEqual((len(prefix['offsets']),prefix['batch_count']), (1,2))
        self.assertEqual(len(prefix['document']['records']),4)
        self.assertEqual(prefix['document']['source_profile']['kind'],figure.FIGURE_PROFILE_V4)
        calls = []
        result = figure.capture_files(args,transport=self.svg_light_transport(calls))
        self.assertEqual(sorted(calls),['ملف:C.svg','ملف:D.svg'])
        batches = list(figure.stream_values(args.output/figure.ROLES['figure-sizing-raw'],figure.RAW_STREAM_SCHEMA))[1:]
        original_lines = before[figure.ROLES['figure-sizing-raw']].splitlines(keepends=True)
        self.assertEqual(len(original_lines), 2)
        self.assertEqual(batches[0], figure.raw_record_decode(original_lines[1],
            figure.raw_record_encoding(figure.stream_decode(original_lines[0]))))
        self.assertEqual(batches[1]['response'].encode(),before['file-metadata.response-000003-01.raw.json'])
        self.assertEqual(batches[1]['requests'],['ملف:E.svg','ملف:F.svg'])
        self.assertEqual(result['coverage']['files'],6)
        self.assertEqual(result['coverage']['eligible'],6)
        self.assertEqual(figure.verify(args.output),result)
        self.assertEqual(before,{p.name:p.read_bytes() for p in original.iterdir()})

    def test_closed_oversize_lookahead_rejects_rehashed_missing_extra_and_rejected_evidence(self):
        _, reference, _ = self.make_svg_oversize_lookahead()
        proof = json.loads(reference.read_bytes());root=Path(proof['source_root']);closure=Path(proof['closure']['path'])
        before={p:p.read_bytes() for p in (*root.iterdir(),reference,closure)}
        for mode in ('undeclared','orphan','refused','truncated','unaccepted'):
            with self.subTest(mode=mode):
                failure_path=root/'figure-failure-0001.json';failure=json.loads(failure_path.read_bytes())
                receipt_path=root/'file-metadata.response-000003-01.receipt.json'
                raw_path=root/'file-metadata.response-000003-01.raw.json'
                if mode=='undeclared':failure['pending_http']=[2];failure_path.write_bytes(figure.encoded(failure))
                elif mode=='orphan':(root/'file-metadata.response-000003-02.raw.json').write_bytes(b'{}')
                elif mode=='unaccepted':receipt_path.unlink();raw_path.unlink()
                else:
                    receipt=json.loads(receipt_path.read_bytes())
                    if mode=='refused':receipt.update(accepted=False,status=403,error='API HTTP status 403')
                    else:
                        raw_path.write_bytes(raw_path.read_bytes().rstrip()[:-1])
                        receipt.update(response_bytes=raw_path.stat().st_size,response_sha256=figure.digest(raw_path.read_bytes()))
                    receipt_path.write_bytes(figure.encoded(receipt))
                self.refresh_closed_svg_failure(reference)
                with self.assertRaises((ValueError,OSError)):
                    figure.read_closed_prefix(reference)
                for path in root.iterdir():
                    if path not in before:path.unlink()
                for path,raw in before.items():path.write_bytes(raw)

    def test_closed_oversize_lookahead_rejects_planned_title_core_and_alias_conflicts(self):
        _, reference, _ = self.make_svg_oversize_lookahead()
        proof=json.loads(reference.read_bytes());root=Path(proof['source_root']);closure=Path(proof['closure']['path'])
        before={p:p.read_bytes() for p in (*root.iterdir(),reference,closure)}
        for mode in ('wrong-plan','core','canonical-conflict'):
            with self.subTest(mode=mode):
                request_path=root/'file-metadata.request-000003.json';raw_path=root/'file-metadata.response-000003-01.raw.json'
                receipt_path=root/'file-metadata.response-000003-01.receipt.json'
                if mode=='wrong-plan':
                    request=json.loads(request_path.read_bytes());request['titles']=['ملف:A.svg','ملف:F.svg']
                    request['query']=metadata.query_for(self.wiki,request['titles'],figure_axes=True)
                    request['url']=metadata.query_url(self.wiki,request['titles'],figure_axes=True)
                    request_path.write_bytes(figure.encoded(request))
                else:
                    response=json.loads(raw_path.read_bytes())
                    if mode=='core':response['query']['general']['git-hash']='0'*40
                    else:
                        response['query']['redirects']=[{'from':'ملف:E.svg','to':'ملف:A.svg'}]
                        page=response['query']['pages'][0];page['title']='ملف:A.svg'
                        page['imageinfo'][0].update(canonicaltitle='ملف:A.svg',width=801)
                    raw_path.write_bytes(figure.encoded(response))
                    receipt=json.loads(receipt_path.read_bytes());receipt.update(response_bytes=raw_path.stat().st_size,response_sha256=figure.digest(raw_path.read_bytes()))
                    receipt_path.write_bytes(figure.encoded(receipt))
                self.refresh_closed_svg_failure(reference)
                with self.assertRaises(ValueError):figure.read_closed_prefix(reference)
                for path,raw in before.items():path.write_bytes(raw)

    def test_closed_oversize_svg_transition_resumes_without_repeating_accepted_requests(self):
        args,reference,_=self.make_svg_oversize_lookahead()
        original=Path(json.loads(reference.read_bytes())['source_root'])
        before={p.name:p.read_bytes() for p in original.iterdir()}
        args.wall_seconds=1
        now,advance=self.overlap_clock();calls=[]
        class ImmediatePool:
            def __init__(self,**kwargs):pass
            def submit(self,function,*values):
                from concurrent.futures import Future
                future=Future()
                try:future.set_result(function(*values))
                except BaseException as error:future.set_exception(error)
                return future
            def shutdown(self,**kwargs):pass
        with patch.object(figure.time,'monotonic',side_effect=now),patch.object(metadata,'ThreadPoolExecutor',ImmediatePool):
            with self.assertRaisesRegex(ValueError,'Capture wall deadline reached'):
                figure.capture_files(args,transport=self.svg_light_transport(calls),sleep=advance)
        self.assertEqual(calls,['ملف:C.svg'])
        self.complete_resume_proof(args,1);args.wall_seconds=30
        now,advance=self.overlap_clock()
        with patch.object(figure.time,'monotonic',side_effect=now),patch.object(metadata,'ThreadPoolExecutor',ImmediatePool):
            result=figure.capture_files(args,transport=self.svg_light_transport(calls),sleep=advance)
        self.assertEqual(calls,['ملف:C.svg','ملف:D.svg'])
        self.assertEqual(result['coverage']['files'],6)
        self.assertEqual(figure.verify(args.output),result)
        self.assertEqual(before,{p.name:p.read_bytes() for p in original.iterdir()})

    def test_normal_resolver_continues_svg_oversize_with_accepted_lookahead_v4(self):
        _,reference,inputs=self.make_svg_oversize_lookahead(normal=True)
        original=Path(json.loads(reference.read_bytes())['source_root'])
        before={p.name:p.read_bytes() for p in original.iterdir()};calls=[]
        with patch.object(figure.evidence,'get_response',side_effect=self.svg_light_transport(calls)):
            paths=builder.resolve_figure_snapshot_options(self.root,inputs['manifest'],inputs['selected_inputs'],
                inputs['downloads'],self.namespace,{},metadata_network='allow',figure_reuse_batches=(reference,))
        self.assertEqual(sorted(calls),['ملف:C.svg','ملف:D.svg'])
        self.assertEqual(self.stream_document(self.root/'figure-inputs')['source_profile']['kind'],figure.FIGURE_PROFILE_V4)
        with patch.object(figure.evidence,'get_response',side_effect=AssertionError('accepted capture refetched')):
            reused=builder.resolve_figure_snapshot_options(self.root,inputs['manifest'],inputs['selected_inputs'],
                inputs['downloads'],self.namespace,{},metadata_network='offline',figure_reuse_batches=(reference,))
        self.assertEqual(paths,reused)
        self.assertEqual(set(paths),{*figure.ROLES,'file-metadata'})
        self.assertEqual(before,{p.name:p.read_bytes() for p in original.iterdir()})

    def lean_response(self, titles, *, metadata_requested=False):
        result = self.response(titles[0]);result['query']['pages'] = []
        result['query']['general']['git-hash'] = figure.FIGURE_CURRENT_CORE
        for title in titles:
            page = self.response(title)['query']['pages'][0]
            info = page['imageinfo'][0]
            if title.endswith('.tif'):
                info.update(mime='image/tiff', mediatype='BITMAP', pagecount=1)
                # A missing local description is still a positive shared file.
                page['missing'] = True;page['imagerepository'] = 'shared'
                if metadata_requested:
                    info['metadata'] = [
                        {'name': 'TIFF_METADATA_VERSION', 'value': '1.4'},
                        *({'name': key, 'value': 1} for key in ('page_count', 'first_page', 'last_page')),
                        {'name': 'page_data', 'value': [{'name': 1, 'value': [
                            {'name': 'page', 'value': 1}, {'name': 'width', 'value': 800},
                            {'name': 'height', 'value': 600}]}]}]
            elif title.endswith('.png'):
                info.update(mime='image/png', mediatype='BITMAP')
            elif title.endswith('.jpg'):
                info.update(mime='image/jpeg', mediatype='BITMAP')
            elif title.endswith('.gif'):
                info.update(mime='image/gif', mediatype='BITMAP')
            elif title.endswith('.ogg'):
                info.update(mime='audio/ogg', mediatype='AUDIO', width=0, height=0)
            elif title.endswith('Zero.svg'):
                info.update(width=0, height=0)
            elif title.endswith('Missing.svg'):
                page = {'title': title, 'ns': 6, 'missing': True, 'imagerepository': ''}
            if metadata_requested and 'imageinfo' in page and not title.endswith('.tif'):
                page['imageinfo'][0]['metadata'] = [{'name': 'irrelevant', 'value': 'retained only in full query'}]
            result['query']['pages'].append(page)
        return result

    def lean_transport(self, calls):
        def transport(url, timeout):
            query = parse_qs(urlsplit(url).query)
            titles = query['titles'][0].split('|')
            full = 'metadata' in query['iiprop'][0].split('|')
            calls.append((titles, full))
            return 200, {}, figure.encoded(self.lean_response(titles, metadata_requested=full))
        return transport

    def lean_capture_args(self, links=('A.png', 'B.tif')):
        args = self.args(links=links)
        args.metadata_mode = 'lean-tiff-v1'
        args.figure_profile = figure.FIGURE_PROFILE_V4
        return args

    def test_lean_companion_preserves_mixed_full_metadata_projection_and_provider(self):
        titles = ['ملف:'+name for name in ('A.png','B.jpg','C.svg','D.gif','E.ogg','F.tif','Missing.svg','Zero.svg')]
        lean = self.lean_response(titles)
        full = self.lean_response(titles, metadata_requested=True)
        raw = figure.encoded(lean).decode()
        batch = {'requests': titles, 'response': raw,
                 'tiff_metadata_response': figure.encoded(self.lean_response(['ملف:F.tif'], metadata_requested=True)).decode()}
        for profile in (figure.FIGURE_PROFILE_V3, figure.FIGURE_PROFILE_V4):
            with self.subTest(profile=profile):
                actual = figure.validate_lean_batch(batch, self.namespace.read_bytes(), self.wiki, self.date, profile)
                expected = figure.file_records(({'requests': titles, 'response': figure.encoded(full).decode()},),
                    self.namespace.read_bytes(), self.wiki, self.date, figure.encoded(full),
                    has_batches=True, record_limit=50, profile_kind=profile)
                self.assertEqual(actual['records'], expected['records'])
                self.assertEqual(b''.join(figure.provider_chunks(actual)), b''.join(figure.provider_chunks(expected)))
                states = {row['requested_file']: row['state'] for row in actual['records']}
                self.assertEqual(states['ملف:F.tif'], 'eligible')
                self.assertEqual(states['ملف:D.gif'], 'eligible' if profile == figure.FIGURE_PROFILE_V4 else 'unsupported')
                self.assertEqual(states['ملف:Missing.svg'], 'missing')
                self.assertEqual(states['ملف:Zero.svg'], 'unsupported')
                self.assertEqual(batch['response'], raw)

    def test_lean_companion_rejects_identity_subset_source_and_competing_authorities(self):
        titles = ['ملف:A.png', 'ملف:B.tif']
        original = {'requests': titles, 'response': figure.encoded(self.lean_response(titles)).decode(),
            'tiff_metadata_response': figure.encoded(self.lean_response(['ملف:B.tif'], metadata_requested=True)).decode()}
        def validate(batch):
            return figure.validate_lean_batch(batch, self.namespace.read_bytes(), self.wiki, self.date, figure.FIGURE_PROFILE_V4)
        validate(original)
        mutations = [
            ('sha1', 'b'*40), ('timestamp', '2020-01-01T00:00:00Z'), ('width', 799), ('height', 599),
            ('size', 17), ('mime', 'image/png'), ('mediatype', 'DRAWING'), ('canonicaltitle', 'ملف:Else.tif'),
            ('pagecount', 2), ('pagecount', True), ('pagecount', None), ('pagecount', '1')]
        for key, value in mutations:
            with self.subTest(field=key, value=value):
                batch = copy.deepcopy(original);other = json.loads(batch['tiff_metadata_response'])
                other['query']['pages'][0]['imageinfo'][0][key] = value
                batch['tiff_metadata_response'] = figure.encoded(other).decode()
                with self.assertRaises(ValueError):validate(batch)
        for mode in ('extra','missing','core','extensions','repository','hidden','no-metadata','no-pagecount','base-metadata','null','empty','width-supplement','height-supplement'):
            with self.subTest(mode=mode):
                batch = copy.deepcopy(original);other = json.loads(batch['tiff_metadata_response'])
                page = other['query']['pages'][0]
                if mode == 'extra':other['query']['pages'].append(self.lean_response(['ملف:Extra.tif'])['query']['pages'][0])
                elif mode == 'missing':other['query']['pages'] = []
                elif mode == 'core':other['query']['general']['git-hash'] = '0'*40
                elif mode == 'extensions':other['query']['extensions'][0]['vcs-version'] = '0'*40
                elif mode == 'repository':page['imagerepository'] = 'local'
                elif mode == 'hidden':page['imageinfo'][0]['filehidden'] = True
                elif mode == 'no-metadata':del page['imageinfo'][0]['metadata']
                elif mode == 'no-pagecount':del page['imageinfo'][0]['pagecount']
                elif mode == 'base-metadata':
                    base = json.loads(batch['response']);base['query']['pages'][1]['imageinfo'][0]['metadata'] = []
                    batch['response'] = figure.encoded(base).decode()
                elif mode == 'width-supplement':batch['observed_svg_width_px'] = 250
                elif mode == 'height-supplement':batch['observed_svg_occurrences'] = []
                batch['tiff_metadata_response'] = None if mode == 'null' else '' if mode == 'empty' else figure.encoded(other).decode()
                with self.assertRaises(ValueError):validate(batch)
        for malformed in (None, [], 'bad', [{'name': 'page_count', 'value': 2}]):
            batch = copy.deepcopy(original);other = json.loads(batch['tiff_metadata_response'])
            other['query']['pages'][0]['imageinfo'][0]['metadata'] = malformed
            batch['tiff_metadata_response'] = figure.encoded(other).decode()
            rows = validate(batch)['records']
            self.assertEqual(next(row for row in rows if row['mime']=='image/tiff')['state'], 'unsupported')
        batch = copy.deepcopy(original)
        for key in ('response','tiff_metadata_response'):
            data = json.loads(batch[key])
            for page in data['query']['pages']:
                page.get('imageinfo',[{}])[0].pop('pagecount',None)
            batch[key] = figure.encoded(data).decode()
        self.assertEqual(next(row for row in validate(batch)['records'] if row['mime']=='image/tiff')['state'],'unsupported')

    def test_explicit_lean_archives_two_original_responses_and_gates_companion_generator(self):
        args = self.lean_capture_args();calls=[];now,advance=self.overlap_clock()
        with patch.object(figure.time,'monotonic',side_effect=now):
            result = figure.capture_files(args, transport=self.lean_transport(calls), sleep=advance)
        self.assertEqual(calls, [(['ملف:A.png','ملف:B.tif'],False),(['ملف:B.tif'],True)])
        self.assertEqual(json.loads((args.output/figure.PLAN).read_bytes())['metadata_mode'],'lean-tiff-v1')
        batches = list(figure.stream_values(args.output/figure.ROLES['figure-sizing-raw'],figure.RAW_STREAM_SCHEMA))
        self.assertEqual(batches[1]['response'],figure.encoded(self.lean_response(calls[0][0])).decode())
        self.assertEqual(batches[1]['tiff_metadata_response'],figure.encoded(self.lean_response(calls[1][0],metadata_requested=True)).decode())
        self.assertFalse(list(args.output.glob('file-metadata.*raw.json')))
        self.assertTrue((args.output/'file-metadata.tiff-request-000001.json').exists())
        self.assertEqual(figure.verify(args.output),result)
        document = self.stream_document(args.output)
        # The historical companion gate predates compressed records. Build a
        # coherent plain fixture so its generator, not its encoding, is refused.
        header = dict(batches[0]); header.pop('record_encoding')
        plain = b''.join(figure.stream_encoded(row) for row in (header, *batches[1:]))
        (args.output/figure.ROLES['figure-sizing-raw']).write_bytes(plain)
        document['raw_bytes'] = len(plain); document['raw_sha256'] = figure.digest(plain)
        self.verify_changed_projection(args.output, document)
        document['generator_sha256'] = '0'*64
        document.pop('replay_contract')  # Historical schema still uses its exact generator gate.
        with self.assertRaisesRegex(ValueError,'companion'):
            self.verify_changed_projection(args.output,document)

    def first_tiff_wall_stop(self, *, slots=1):
        args = self.lean_capture_args(('A.tif',));args.max_inflight=slots;args.wall_seconds=1
        args.output=self.root/f'lean-wall-{slots}'
        now,advance=self.overlap_clock();calls=[]
        with patch.object(figure.time,'monotonic',side_effect=now):
            with self.assertRaisesRegex(ValueError,'Capture wall deadline reached'):
                figure.capture_files(args,transport=self.lean_transport(calls),sleep=advance)
        self.assertEqual(calls,[(['ملف:A.tif'],False)])
        failure=json.loads((args.output/'figure-failure-0001.json').read_bytes())
        self.assertEqual((failure['committed_batches'],failure['pending_http']),(0,[1]))
        self.assertEqual(len((args.output/figure.ROLES['figure-sizing-raw']).read_bytes().splitlines()),1)
        self.assertFalse((args.output/figure.COMPLETE).exists())
        self.complete_resume_proof(args,1);args.wall_seconds=30
        return args

    def test_lean_first_tiff_followup_wall_resume_keeps_zero_commit_and_never_refetches_base(self):
        for slots in (1,2):
            with self.subTest(slots=slots):
                args=self.first_tiff_wall_stop(slots=slots)
                original=(args.output/'file-metadata.response-000001-01.raw.json').read_bytes()
                receipt=(args.output/'file-metadata.response-000001-01.receipt.json').read_bytes()
                calls=[];now,advance=self.overlap_clock()
                with patch.object(figure.time,'monotonic',side_effect=now):
                    figure.capture_files(args,transport=self.lean_transport(calls),sleep=advance)
                self.assertEqual(calls,[(['ملف:A.tif'],True)])
                batch=list(figure.stream_values(args.output/figure.ROLES['figure-sizing-raw'],figure.RAW_STREAM_SCHEMA))[1]
                self.assertEqual(batch['response'].encode(),original)
                self.assertEqual((args.output/'file-metadata.response-000001-01.receipt.json').read_bytes(),receipt)
                figure.verify(args.output)

    def test_lean_followup_repeated_resume_preserves_four_attempts_and_refuses_orphans(self):
        args=self.first_tiff_wall_stop();calls=[]
        def fail(url,timeout):
            query=parse_qs(urlsplit(url).query);self.assertIn('metadata',query['iiprop'][0].split('|'))
            calls.append(url);raise OSError('temporary TIFF transport loss')
        for number in (2,3):
            args.wall_seconds=1;now,advance=self.overlap_clock()
            with patch.object(figure.time,'monotonic',side_effect=now):
                with self.assertRaisesRegex(ValueError,'Retry exceeds bounded capture wait/deadline'):
                    figure.capture_files(args,transport=fail,sleep=advance)
            self.complete_resume_proof(args,number)
        args.wall_seconds=30;now,advance=self.overlap_clock()
        with patch.object(figure.time,'monotonic',side_effect=now):
            with self.assertRaisesRegex(OSError,'temporary TIFF transport loss'):
                figure.capture_files(args,transport=fail,sleep=advance)
        self.assertEqual(len(calls),4)
        self.assertTrue((args.output/'file-metadata.tiff-response-000001-04.receipt.json').exists())
        self.assertFalse((args.output/'file-metadata.tiff-response-000001-05.receipt.json').exists())
        self.assertFalse((args.output/figure.COMPLETE).exists())
        # A coherently inventoried orphan still lacks an actual attempt receipt.
        other=self.first_tiff_wall_stop(slots=2)
        orphan=other.output/'file-metadata.tiff-response-000001-01.raw.json';orphan.write_bytes(b'{}')
        failure_path=other.output/'figure-failure-0001.json';failure=json.loads(failure_path.read_bytes())
        failure['artifacts'][orphan.name]={'bytes':2,'sha256':figure.digest(b'{}')}
        failure_path.write_bytes(figure.encoded(failure));self.complete_resume_proof(other,1)
        with self.assertRaisesRegex(ValueError,'Unaccounted'):
            figure.capture_files(other,transport=lambda *_:self.fail('orphan permitted HTTP'))

    def test_lean_two_slot_resume_preserves_completed_tiff_lookahead_in_plan_order(self):
        args=self.lean_capture_args(('A.png','B.tif','C.tif'));args.batch_size=1;args.max_inflight=2;args.wall_seconds=8
        now,advance=self.overlap_clock();completed=threading.Event();calls=[]
        base=self.lean_transport(calls)
        def transport(url,timeout):
            query=parse_qs(urlsplit(url).query);title=query['titles'][0]
            full='metadata' in query['iiprop'][0].split('|')
            if title.endswith('B.tif') and full:
                self.assertTrue(completed.wait(5),'TIFF lookahead did not finish')
                advance(8);raise OSError('temporary TIFF transport loss')
            result=base(url,timeout)
            if title.endswith('C.tif') and full:completed.set()
            return result
        with patch.object(figure.time,'monotonic',side_effect=now):
            with self.assertRaisesRegex(ValueError,'Retry exceeds bounded capture wait/deadline'):
                figure.capture_files(args,transport=transport,sleep=advance)
        failure=json.loads((args.output/'figure-failure-0001.json').read_bytes())
        self.assertEqual((failure['committed_batches'],failure['pending_http']),(1,[2,3]))
        base_raw=(args.output/'file-metadata.response-000003-01.raw.json').read_bytes()
        tiff_raw=(args.output/'file-metadata.tiff-response-000003-01.raw.json').read_bytes()
        self.complete_resume_proof(args,1);args.wall_seconds=30;calls=[];now,advance=self.overlap_clock()
        with patch.object(figure.time,'monotonic',side_effect=now):
            figure.capture_files(args,transport=self.lean_transport(calls),sleep=advance)
        self.assertEqual(calls,[(['ملف:B.tif'],True)])
        batches=list(figure.stream_values(args.output/figure.ROLES['figure-sizing-raw'],figure.RAW_STREAM_SCHEMA))[1:]
        self.assertEqual([b['requests'][0] for b in batches],['ملف:A.png','ملف:B.tif','ملف:C.tif'])
        self.assertEqual(batches[-1]['response'].encode(),base_raw)
        self.assertEqual(batches[-1]['tiff_metadata_response'].encode(),tiff_raw)
        self.assertTrue(all(row['state']=='eligible' for row in self.stream_document(args.output)['records']))
        figure.verify(args.output)

    def test_lean_tiff_retry_after_uses_shared_start_interval_and_refuses_access_retry(self):
        args=self.lean_capture_args(('A.tif',));now,advance=self.overlap_clock();starts=[];attempt=[0]
        def transport(url,timeout):
            query=parse_qs(urlsplit(url).query);full='metadata' in query['iiprop'][0].split('|')
            starts.append((now(),full))
            if full:
                attempt[0]+=1
                if attempt[0]==1:return 429,{'Retry-After':'3'},b'{"error":{"code":"ratelimited"}}'
            return 200,{},figure.encoded(self.lean_response(query['titles'][0].split('|'),metadata_requested=full))
        with patch.object(figure.time,'monotonic',side_effect=now):
            figure.capture_files(args,transport=transport,sleep=advance)
        self.assertEqual(starts,[(0.0,False),(1.0,True),(4.0,True)])
        figure.verify(args.output)
        other=self.lean_capture_args(('A.tif',));other.output=self.root/'access-refusal';calls=[]
        def refusal(url,timeout):
            query=parse_qs(urlsplit(url).query);full='metadata' in query['iiprop'][0].split('|');calls.append(full)
            return (403,{},b'forbidden') if full else (200,{},figure.encoded(self.lean_response(['ملف:A.tif'])))
        now,advance=self.overlap_clock()
        with patch.object(figure.time,'monotonic',side_effect=now):
            with self.assertRaisesRegex(ValueError,'API HTTP status 403'):
                figure.capture_files(other,transport=refusal,sleep=advance)
        self.assertEqual(calls,[False,True]);self.complete_resume_proof(other,1)
        with self.assertRaisesRegex(ValueError,'closed wall-stop'):
            figure.capture_files(other,transport=lambda *_:self.fail('403 was retried'))

    def test_normal_resolver_defaults_to_full_metadata_and_replays_complete_without_transport(self):
        old = self.args
        names = ('Legacy.jpg', 'Rotated.jpg', 'Unknown.jpg', 'B.tif')
        with patch.object(self, 'args', side_effect=lambda: old(links=names)):
            inputs = self.normal_build_inputs()
        metadata_values = {'ملف:Legacy.jpg': [{'name': '_error', 'value': '0'}],
                           'ملف:Rotated.jpg': [{'name': 'Orientation', 'value': 6}],
                           'ملف:Unknown.jpg': None}
        calls, responses = [], []
        def transport(url, timeout):
            query = parse_qs(urlsplit(url).query)
            titles = query['titles'][0].split('|')
            self.assertIn('metadata', query['iiprop'][0].split('|'))
            calls.append(titles)
            response = self.lean_response(titles, metadata_requested=True)
            for page in response['query']['pages']:
                if page['title'] in metadata_values:
                    page['imageinfo'][0].update(width=200, height=144,
                                               metadata=metadata_values[page['title']])
            raw = figure.encoded(response); responses.append(raw)
            return 200, {}, raw
        with patch.object(figure.evidence, 'get_response', side_effect=transport):
            paths = builder.resolve_figure_snapshot_options(self.root, inputs['manifest'], inputs['selected_inputs'],
                inputs['downloads'], self.namespace, {}, metadata_network='allow')
        self.assertEqual(len(calls), 1)
        self.assertEqual(set(calls[0]), {'ملف:' + name for name in names})
        root = self.root/'figure-inputs'
        self.assertEqual(json.loads((root/figure.PLAN).read_bytes()).get('metadata_mode', 'full'), 'full')
        batches = list(figure.stream_values(root/figure.ROLES['figure-sizing-raw'], figure.RAW_STREAM_SCHEMA))
        self.assertEqual(len(batches), 2)
        self.assertNotIn('tiff_metadata_response', batches[1])
        self.assertEqual(batches[1]['response'].encode(), responses[0])
        pages = json.loads(batches[1]['response'])['query']['pages']
        self.assertEqual({p['title']: p['imageinfo'][0]['metadata'] for p in pages if p['title'] in metadata_values},
                         metadata_values)
        self.assertEqual({r['requested_file']: r['state'] for r in self.stream_document(root)['records']},
                         {'ملف:' + name: 'eligible' for name in names})
        # Retaining null/rotated metadata does not assert a native no-rotation grant.
        with patch.object(figure.evidence, 'get_response', side_effect=AssertionError('complete capture refetched')):
            repeated = builder.resolve_figure_snapshot_options(self.root, inputs['manifest'], inputs['selected_inputs'],
                inputs['downloads'], self.namespace, {}, metadata_network='offline')
        self.assertEqual(paths, repeated)

    def test_full_metadata_defaults_cover_direct_and_cli_capture(self):
        args = self.args(links=('Legacy.jpg',)); del args.metadata_mode
        calls = []
        def transport(url, timeout):
            query = parse_qs(urlsplit(url).query)
            self.assertIn('metadata', query['iiprop'][0].split('|'))
            calls.append(query['titles'][0])
            response = self.lean_response(calls[-1].split('|'), metadata_requested=True)
            response['query']['pages'][0]['imageinfo'][0]['metadata'] = [{'name': '_error', 'value': '0'}]
            return 200, {}, figure.encoded(response)
        result = figure.capture_files(args, transport=transport)
        self.assertEqual(calls, ['ملف:Legacy.jpg'])
        self.assertEqual(figure.verify(args.output), result)
        batch = list(figure.stream_values(args.output/figure.ROLES['figure-sizing-raw'], figure.RAW_STREAM_SCHEMA))[1]
        self.assertEqual(json.loads(batch['response'])['query']['pages'][0]['imageinfo'][0]['metadata'],
                         [{'name': '_error', 'value': '0'}])
        argv = ['prepare_figure_metadata.py', 'capture-files', '--wiki', args.wiki, '--date', args.date,
                '--defaults', str(args.defaults), '--dumpstatus', str(args.dumpstatus), '--output', str(args.output)]
        for path in args.sql:
            argv.extend(['--sql', str(path)])
        for extra, expected in (([], 'full'), (['--metadata-mode', 'lean-tiff-v1'], 'lean-tiff-v1')):
            with patch.object(figure.sys, 'argv', argv + extra), patch.object(figure, 'capture_files', return_value=result) as capture, patch('builtins.print'):
                figure.main()
            selected = capture.call_args.args[0]
            self.assertEqual((selected.metadata_mode, selected.max_inflight, selected.figure_profile),
                             (expected, 2, figure.FIGURE_PROFILE_V3))




    def replay_contract_fixture(self):
        titles = ['ملف:A.png', 'ملف:B.tif']
        batch = {'requests': titles, 'response': figure.encoded(self.lean_response(titles)).decode(),
            'tiff_metadata_response': figure.encoded(self.lean_response(['ملف:B.tif'], metadata_requested=True)).decode()}
        raw = figure.encoded({'schema': figure.RAW_BATCHES_SCHEMA, 'batches': [batch]})
        site = batch['response'].encode()
        document = figure.figure_file_document(raw, self.namespace.read_bytes(), self.wiki, self.date,
            site, profile_kind=figure.FIGURE_PROFILE_V4)
        return document, raw, site

    def test_explicit_replay_contract_preserves_tiff_facts_across_generator_provenance(self):
        document, raw, site = self.replay_contract_fixture()
        self.assertEqual(document['replay_contract'], figure.REPLAY_CONTRACT)
        before = raw
        for generator in ('a'*64, 'b'*64):
            changed = copy.deepcopy(document);changed['generator_sha256'] = generator
            result = figure.verify_figure_file_document(changed, raw, self.namespace.read_bytes(), self.wiki, self.date, site)
            self.assertEqual(result['generator_sha256'], generator)
            self.assertEqual(result['records'], document['records'])
            self.assertEqual(b''.join(figure.provider_chunks(result)), b''.join(figure.provider_chunks(document)))
        self.assertEqual(raw, before)
        legacy = copy.deepcopy(document);legacy.pop('replay_contract')
        legacy['generator_sha256'] = figure.LEGACY_TIFF_GENERATOR
        self.assertEqual(figure.verify_figure_file_document(legacy, raw, self.namespace.read_bytes(), self.wiki, self.date, site), legacy)
        legacy['generator_sha256'] = 'a'*64
        with self.assertRaisesRegex(ValueError, 'companion'):
            figure.verify_figure_file_document(legacy, raw, self.namespace.read_bytes(), self.wiki, self.date, site)

    def test_explicit_replay_contract_rejects_unknown_contract_features_and_false_facts(self):
        document, raw, site = self.replay_contract_fixture()
        def verify(value, source=raw):
            return figure.verify_figure_file_document(value, source, self.namespace.read_bytes(), self.wiki, self.date, site)
        for mode in ('contract', 'null', 'digest', 'feature', 'fact', 'raw-feature', 'core'):
            with self.subTest(mode=mode):
                value = copy.deepcopy(document);source = raw
                if mode == 'contract':value['replay_contract'] += '-future'
                elif mode == 'null':value['replay_contract'] = None
                elif mode == 'digest':value['generator_sha256'] = 'unknown'
                elif mode == 'feature':value['future_feature'] = True
                elif mode == 'fact':value['records'][0]['original_width'] += 1
                else:
                    envelope = json.loads(raw)
                    if mode == 'raw-feature':envelope['batches'][0]['future_feature'] = True
                    else:
                        response = json.loads(envelope['batches'][0]['response'])
                        response['query']['general']['git-hash'] = '0'*40
                        envelope['batches'][0]['response'] = figure.encoded(response).decode()
                    source = figure.encoded(envelope);value['raw_sha256'] = figure.digest(source)
                with self.assertRaises(ValueError):verify(value,source)

    def test_explicit_stream_replay_contract_preserves_provenance_and_unknown_refusal(self):
        args = self.lean_capture_args();calls = [];now,advance = self.overlap_clock()
        with patch.object(figure.time, 'monotonic', side_effect=now):
            figure.capture_files(args, transport=self.lean_transport(calls), sleep=advance)
        document = self.stream_document(args.output)
        self.assertEqual(document['replay_contract'], figure.REPLAY_CONTRACT)
        for generator in ('a'*64, 'b'*64):
            changed = copy.deepcopy(document);changed['generator_sha256'] = generator
            self.verify_changed_projection(args.output, changed)
            self.assertEqual(self.stream_document(args.output)['generator_sha256'], generator)
        header = {key:value for key,value in document.items() if key != 'records'}
        for contract in (None, 'unsupported'):
            changed = copy.deepcopy(header);changed['replay_contract'] = contract
            with self.assertRaises(ValueError):figure.validate_stream_header(changed, figure.FILES_STREAM_SCHEMA, 2**64-1)
        changed = copy.deepcopy(header);changed['future_feature'] = True
        with self.assertRaises(ValueError):figure.validate_stream_header(changed, figure.FILES_STREAM_SCHEMA, 2**64-1)

    def zstd_test_envelope(self, raw, **changes):
        frame = figure.zstd.compress(raw, level=1)
        value = {'encoding': 'zstd', 'raw_bytes': len(raw), 'raw_sha256': figure.digest(raw),
            'data': figure.base64.b64encode(frame).decode('ascii')}
        value.update(changes)
        return figure.stream_encoded(value)

    def test_zstd_record_exact_unicode_control_roundtrip_and_small_plain_fallback(self):
        batch = {'requests': ['File:é.svg'], 'response': '{"text":"λ\\n\\t\\u0000"}'+(' '*4096)}
        original = figure.stream_encoded(batch)
        archived = figure.raw_record_encoded(batch)
        self.assertLess(len(archived), len(original))
        envelope = figure.stream_decode(archived)
        self.assertEqual((envelope['raw_bytes'], envelope['raw_sha256']), (len(original), figure.digest(original)))
        self.assertEqual(figure.raw_record_decode(archived, figure.RAW_RECORD_ENCODING), batch)
        self.assertEqual(figure.stream_encoded(figure.raw_record_decode(archived, figure.RAW_RECORD_ENCODING)), original)
        small = {'requests': [], 'response': '{}'}
        self.assertEqual(figure.raw_record_encoded(small), figure.stream_encoded(small))
        self.assertEqual(figure.raw_record_decode(figure.stream_encoded(small), None), small)
        with self.assertRaises(ValueError):figure.raw_record_decode(archived, None)
        with patch.object(figure, 'STREAM_RAW_LINE_LIMIT', len(original)-1), self.assertRaises(ValueError):
            figure.raw_record_encoded(batch)

    def test_zstd_record_rejects_envelope_frame_and_exact_decoded_line_corruption(self):
        raw = figure.stream_encoded({'requests':['File:A.svg'], 'response':'x'*4096})
        original = json.loads(self.zstd_test_envelope(raw))
        frame = figure.base64.b64decode(original['data'])
        checksum = figure.zstd.compress(raw, options={figure.zstd.CompressionParameter.compression_level:1,
            figure.zstd.CompressionParameter.checksum_flag:1})
        unknown_size = figure.zstd.compress(raw, options={figure.zstd.CompressionParameter.content_size_flag:0})
        dictionary_at = 5 if frame[4] & 0x20 else 6
        dictionary_frame = (frame[:4]+bytes([frame[4]|1])+frame[5:dictionary_at]+
            b'\x01'+frame[dictionary_at:])
        frames = [frame[:-1], frame+b'x', frame+frame, b'\x50\x2a\x4d\x18\x00\x00\x00\x00'+frame,
                  b'bad!'+frame[4:], unknown_size, dictionary_frame, checksum[:-1]+bytes([checksum[-1]^1])]
        variants = []
        for key,value in [('encoding','gzip'),('raw_bytes',True),('raw_bytes',1.0),('raw_bytes',0),
                ('raw_bytes',figure.STREAM_RAW_LINE_LIMIT+1),('raw_bytes',len(raw)+1),
                ('raw_sha256','0'*64),('raw_sha256','A'*64),('data','%%%%'),('data',42)]:
            changed=dict(original);changed[key]=value;variants.append(figure.stream_encoded(changed))
        variants.extend(figure.stream_encoded(dict(original,data=figure.base64.b64encode(data).decode())) for data in frames)
        variants.extend([figure.stream_encoded(dict(original, requests=[])),
            figure.stream_encoded({key:value for key,value in original.items() if key!='data'}),
            figure.stream_encoded(dict(original,data=original['data']+'='))])
        invalid_raws = [raw[:-1], raw+b'\n', b' '+raw.replace(b'{',b'{\n',1),
            raw.replace(b'\n',b'\r\n'), b'\xef\xbb\xbf'+raw, b'{"response":"\xff"}\n',
            b'{"response":"\x00"}\n', b'{"requests":[],"requests":[]}\n',
            figure.stream_encoded(original)]
        variants.extend(self.zstd_test_envelope(value) for value in invalid_raws)
        for number,value in enumerate(variants):
            with self.subTest(number=number),self.assertRaises(ValueError):
                figure.raw_record_decode(value, figure.RAW_RECORD_ENCODING)
        self.assertEqual(figure.raw_record_decode(self.zstd_test_envelope(raw,
            data=figure.base64.b64encode(checksum).decode()),figure.RAW_RECORD_ENCODING),figure.stream_decode(raw))

    def test_zstd_stream_contract_gate_and_plain_v1_parity_preserve_tiff_provider(self):
        document, aggregate, site = self.replay_contract_fixture()
        legacy_document=dict(document,replay_contract=figure.REPLAY_CONTRACT_V1)
        self.assertEqual(figure.verify_figure_file_document(legacy_document,aggregate,
            self.namespace.read_bytes(),self.wiki,self.date,site),legacy_document)
        batch = json.loads(aggregate)['batches'][0]
        header = {'schema':figure.RAW_STREAM_SCHEMA, **{key:document[key] for key in
            ('wiki','core_revision','namespace_registry_sha256')},
            'records_count':len(document['records']),'base_batches':1,'observed_batches':0}
        plain=self.root/'plain.raw';compressed=self.root/'compressed.raw';projection=self.root/'compressed.projection'
        plain.write_bytes(figure.stream_encoded(header)+figure.stream_encoded(batch))
        compressed.write_bytes(figure.stream_encoded(dict(header,record_encoding=figure.RAW_RECORD_ENCODING))+
            figure.raw_record_encoded(batch))
        kwargs={'profile_kind':figure.FIGURE_PROFILE_V4}
        left=figure.figure_stream_document(plain,self.namespace.read_bytes(),self.wiki,self.date,site,**kwargs)
        right=figure.figure_stream_document(compressed,self.namespace.read_bytes(),self.wiki,self.date,site,**kwargs)
        self.assertEqual(left['records'],right['records'])
        self.assertEqual(b''.join(figure.provider_chunks(left)),b''.join(figure.provider_chunks(right)))
        self.assertLess(right['raw_bytes'],left['raw_bytes'])
        for contract,path,expected in [(figure.REPLAY_CONTRACT,compressed,right),
                (figure.REPLAY_CONTRACT_V1,plain,left),(None,plain,left)]:
            selected=copy.deepcopy(expected)
            if contract is None:
                selected.pop('replay_contract');selected['generator_sha256']=figure.LEGACY_TIFF_GENERATOR
            else:selected['replay_contract']=contract
            if projection.exists():projection.unlink()
            figure.write_projection_stream(projection,selected)
            self.assertEqual(figure.verify_stream_document(projection,path,self.namespace.read_bytes(),
                self.wiki,self.date,site)['records'],document['records'])
        for contract in (figure.REPLAY_CONTRACT_V1,None):
            selected=copy.deepcopy(right)
            if contract is None:
                selected.pop('replay_contract');selected['generator_sha256']=figure.LEGACY_TIFF_GENERATOR
            else:selected['replay_contract']=contract
            projection.unlink();figure.write_projection_stream(projection,selected)
            with self.assertRaises(ValueError):figure.verify_stream_document(projection,compressed,
                self.namespace.read_bytes(),self.wiki,self.date,site)
        first,body=compressed.read_bytes().split(b'\n',1)
        for marker in (None,'future'):
            value=json.loads(first);value['record_encoding']=marker
            compressed.write_bytes(figure.stream_encoded(value)+body)
            with self.assertRaises(ValueError):list(figure.stream_values(compressed,figure.RAW_STREAM_SCHEMA))
        compressed.write_bytes(figure.stream_encoded(header)+body)
        with self.assertRaises(ValueError):list(figure.stream_values(compressed,figure.RAW_STREAM_SCHEMA))

    def test_zstd_complete_capture_reuses_physical_offsets_and_preserves_original(self):
        args,observation,original_manifest=self.complete_stream_fixture()
        parent=args.output;before={p.name:p.read_bytes() for p in parent.iterdir()}
        rawlines=before[figure.ROLES['figure-sizing-raw']].splitlines(keepends=True)
        self.assertEqual(json.loads(rawlines[0])['record_encoding'],figure.RAW_RECORD_ENCODING)
        self.assertTrue(any('encoding' in json.loads(line) for line in rawlines[1:]))
        cache={};complete=figure.read_complete_capture(parent/figure.MANIFEST,cache)
        for number,(offset,size,sha) in enumerate(complete['offsets']):
            physical=before[figure.ROLES['figure-sizing-raw']][offset:offset+size]
            self.assertEqual(figure.digest(physical),sha)
            reference={'kind':'complete-stream','path':str(parent/figure.MANIFEST),
                'sha256':complete['manifest_sha256'],'batch':number}
            self.assertEqual(figure.complete_stream_batch(reference,cache),
                figure.raw_record_decode(physical,figure.RAW_RECORD_ENCODING))
        args.output=self.root/'compressed-child';args.reuse=[parent];args.reuse_batch=[observation]
        result=figure.capture_files(args,transport=lambda *_:self.fail('compressed parent refetched'))
        self.assertEqual(figure.verify(args.output),result)
        self.assertEqual(result['coverage']['observed_svg_files'],1)
        self.assertEqual(figure.verify(parent),original_manifest)
        self.assertEqual(before,{p.name:p.read_bytes() for p in parent.iterdir()})

    def test_zstd_resume_preserves_committed_physical_bytes_and_accepted_lookahead(self):
        self.test_two_slot_closed_prefix_reuses_accepted_lookahead_without_refetch()
        raw=(self.root/'prepared-only'/figure.ROLES['figure-sizing-raw']).read_bytes()
        first,record,*_=raw.splitlines(keepends=True)
        self.assertEqual(json.loads(first)['record_encoding'],figure.RAW_RECORD_ENCODING)
        self.assertEqual(json.loads(record)['encoding'],'zstd')

    def test_zstd_unmarked_plain_checkpoint_resumes_without_rewriting_prefix(self):
        args,_=self.make_wall_stop()
        raw_path=args.output/figure.ROLES['figure-sizing-raw']
        header_line,body=raw_path.read_bytes().split(b'\n',1)
        header=json.loads(header_line);header.pop('record_encoding')
        # Construct an authenticated legacy-format checkpoint; production never
        # rewrites a retained capture to upgrade its encoding during resume.
        prefix=figure.stream_encoded(header)+figure.stream_encoded(
            figure.raw_record_decode(body,figure.RAW_RECORD_ENCODING))
        raw_path.write_bytes(prefix)
        failure_path=args.output/'figure-failure-0001.json'
        failure=json.loads(failure_path.read_bytes())
        failure['artifacts'][figure.ROLES['figure-sizing-raw']]={'bytes':len(prefix),'sha256':figure.digest(prefix)}
        failure_path.write_bytes(figure.encoded(failure))
        args.resume.unlink();self.complete_resume_proof(args,1)
        calls=[]
        def transport(url,timeout):
            title=parse_qs(urlsplit(url).query)['titles'][0];calls.append(title)
            return 200,{},figure.encoded(self.response(title))
        result=figure.capture_files(args,transport=transport,sleep=lambda _:None)
        self.assertEqual(calls,['ملف:Second.svg'])
        lines=raw_path.read_bytes().splitlines(keepends=True)
        self.assertTrue(raw_path.read_bytes().startswith(prefix))
        self.assertNotIn('record_encoding',json.loads(lines[0]))
        self.assertTrue(all('encoding' not in json.loads(line) for line in lines[1:]))
        self.assertEqual(figure.verify(args.output),result)

    def test_zstd_normal_cached_resolver_uses_existing_tiff_validators(self):
        self.test_normal_resolver_defaults_to_full_metadata_and_replays_complete_without_transport()
        raw_path=self.root/'figure-inputs'/figure.ROLES['figure-sizing-raw']
        with raw_path.open('rb') as source:
            self.assertEqual(json.loads(source.readline())['record_encoding'],figure.RAW_RECORD_ENCODING)
            self.assertEqual(json.loads(source.readline())['encoding'],'zstd')

    def test_inventory_replay_parses_once_returns_owned_values_and_restarts_per_invocation(self):
        paths, status = self.inventory()
        namespace, raw = self.namespace.read_bytes(), status.read_bytes()
        cache = {}
        with patch.object(figure, 'source_inventory', wraps=figure.source_inventory) as parse:
            first = figure.verified_source_inventory(namespace, self.wiki, self.date, raw, paths, cache)
            expected = copy.deepcopy(first)
            first['titles'].append('injected')
            first['sources'][0]['sha256'] = '0'*64
            second = figure.verified_source_inventory(namespace, self.wiki, self.date, raw, paths, cache)
            self.assertEqual(second, expected)
            self.assertEqual(parse.call_count, 1)
            second['sources'].clear()
            self.assertEqual(figure.verified_source_inventory(namespace, self.wiki, self.date, raw, paths, cache), expected)
            self.assertEqual(figure.verified_source_inventory(namespace, self.wiki, self.date, raw, paths, {}), expected)
            self.assertEqual(parse.call_count, 2)
        forged = copy.deepcopy(expected); forged['titles'].append('injected')
        with self.assertRaisesRegex(ValueError, 'differs from exact dated SQL replay'):
            figure.verify_inventory(forged, namespace, self.wiki, self.date, inventory_cache=cache)

    def test_inventory_replay_reauthenticates_sql_bytes_inode_symlink_and_members(self):
        for mode in ('bytes', 'inode', 'symlink', 'missing'):
            with self.subTest(mode=mode):
                paths, status = self.inventory()
                cache = {}
                figure.verified_source_inventory(self.namespace.read_bytes(), self.wiki, self.date, status.read_bytes(), paths, cache)
                path = paths[0]
                if mode == 'bytes':
                    path.write_bytes(path.read_bytes()+b'changed')
                elif mode == 'inode':
                    other = path.with_suffix('.replacement'); other.write_bytes(path.read_bytes()); other.replace(path)
                elif mode == 'symlink':
                    other = path.with_suffix('.original'); path.rename(other); path.symlink_to(other)
                else:
                    path.unlink()
                with self.assertRaises((ValueError, OSError)):
                    figure.verified_source_inventory(self.namespace.read_bytes(), self.wiki, self.date, status.read_bytes(), paths, cache)
                with self.assertRaises((ValueError, OSError)):
                    figure.check_inventory_replay_cache(cache)
                if path.is_symlink(): path.unlink()

    def test_inventory_replay_content_guard_does_not_depend_only_on_stamps(self):
        paths, status = self.inventory()
        cache = {}
        figure.verified_source_inventory(self.namespace.read_bytes(), self.wiki, self.date, status.read_bytes(), paths, cache)
        # Simulate a filesystem observation that fails to reveal the write.
        authority = figure.inventory_physical_authority(tuple(sorted(paths)))
        paths[0].write_bytes(paths[0].read_bytes()+b'changed')
        with patch.object(figure, 'inventory_physical_authority', return_value=authority):
            with self.assertRaisesRegex(ValueError, 'SQL bytes changed'):
                figure.check_inventory_replay_cache(cache)

    def test_inventory_replay_context_and_external_path_changes_require_new_semantics(self):
        paths, status = self.inventory()
        namespace, raw = self.namespace.read_bytes(), status.read_bytes()
        cache = {}
        original = figure.verified_source_inventory(namespace, self.wiki, self.date, raw, paths, cache)
        changed_status = json.loads(raw); changed_status['selected-observation'] = 'different authority'
        with patch.object(figure, 'source_inventory', wraps=figure.source_inventory) as parse:
            changed = figure.verified_source_inventory(namespace, self.wiki, self.date, figure.encoded(changed_status), paths, cache)
            self.assertNotEqual(changed['dumpstatus_sha256'], original['dumpstatus_sha256'])
            other = self.root/'other-sql'; other.mkdir()
            copies = []
            for path in paths:
                copied = other/path.name; copied.write_bytes(path.read_bytes()); copies.append(copied)
            relocated = figure.verified_source_inventory(namespace, self.wiki, self.date, raw, copies, cache)
            self.assertEqual(relocated['titles'], original['titles'])
            self.assertNotEqual(relocated['sources'], original['sources'])
            self.assertEqual(parse.call_count, 2)
            for ns, wiki, date, members in ((b'invalid namespace', self.wiki, self.date, paths),
                    (namespace, 'enwiktionary', self.date, paths),
                    (namespace, self.wiki, '20261002', paths),
                    (namespace, self.wiki, self.date, paths[:1]),
                    (namespace, self.wiki, self.date, [*paths, paths[0]])):
                with self.assertRaises(ValueError):
                    figure.verified_source_inventory(ns, wiki, date, raw, members, cache)
            self.assertEqual(parse.call_count, 7)
        figure.check_inventory_replay_cache(cache)

    def test_inventory_replay_rejects_helper_source_and_same_byte_inode_changes(self):
        paths, status = self.inventory()
        original = Path(figure.__file__).read_bytes()
        helper = self.root/'selected-figure-helper.py'
        for mode in ('bytes', 'inode'):
            with self.subTest(mode=mode):
                helper.write_bytes(original)
                with patch.object(figure, '__file__', str(helper)):
                    cache = {}
                    figure.verified_source_inventory(self.namespace.read_bytes(), self.wiki, self.date, status.read_bytes(), paths, cache)
                    if mode == 'bytes': helper.write_bytes(original+b'\n# changed source\n')
                    else:
                        replacement = helper.with_suffix('.replacement'); replacement.write_bytes(original); replacement.replace(helper)
                    with self.assertRaisesRegex(ValueError, 'source or helper changed'):
                        figure.check_inventory_replay_cache(cache)

    def test_inventory_replay_initial_invalid_sql_never_populates_cache(self):
        paths, status = self.inventory()
        raw = gzip.compress(b'CREATE TABLE `imagelinks` (\n  `unexpected` bigint NOT NULL\n);\n', mtime=0)
        paths[1].write_bytes(raw)
        authority = json.loads(status.read_bytes())
        authority['jobs']['imagelinkstable']['files'][paths[1].name].update(size=len(raw), sha1=hashlib.sha1(raw).hexdigest())
        cache = {}
        with self.assertRaisesRegex(ValueError, 'Unsupported or ambiguous imagelinks'):
            figure.verified_source_inventory(self.namespace.read_bytes(), self.wiki, self.date, figure.encoded(authority), paths, cache)
        self.assertEqual(cache, {})

    def test_inventory_replay_complete_capture_and_final_validation_share_only_sql_proof(self):
        args, observation, _ = self.complete_stream_fixture()
        parent = args.output
        original = {p.name:p.read_bytes() for p in parent.iterdir()}
        args.output = self.root/'inventory-reused'; args.reuse = [parent]; args.reuse_batch = [observation]
        with patch.object(figure, 'source_inventory', wraps=figure.source_inventory) as parse, \
                patch.object(figure, 'verify_stream_document', wraps=figure.verify_stream_document) as full:
            result = figure.capture_files(args, transport=lambda *_:self.fail('retained source refetched'))
            self.assertEqual(parse.call_count, 1)
            self.assertEqual([Path(call.args[0]).parent for call in full.call_args_list], [parent, args.output])
        self.assertEqual((args.output/figure.PROVIDER).read_bytes(), original[figure.PROVIDER])
        self.assertEqual(original, {p.name:p.read_bytes() for p in parent.iterdir()})
        with patch.object(figure, 'source_inventory', wraps=figure.source_inventory) as parse:
            self.assertEqual(figure.verify(args.output), result)
            self.assertEqual(parse.call_count, 1)
        self.assertEqual(len(list(figure.stream_values(args.output/figure.ROLES['figure-sizing-raw'], figure.RAW_STREAM_SCHEMA))), 4)

    def test_inventory_replay_prepared_inventory_does_not_seed_semantic_cache(self):
        args, _, _ = self.complete_stream_fixture()
        parent = args.output
        inventory = figure.inventory_document(parent/figure.INVENTORY)
        inventory['titles'].append('injected')
        args.prepared_inventory = (inventory, {path.resolve():figure.evidence.stamp(path) for path in args.sql})
        args.output = self.root/'forged-prepared'; args.reuse = [parent]
        with patch.object(figure, 'source_inventory', wraps=figure.source_inventory) as parse:
            with self.assertRaisesRegex(ValueError, 'Complete Figure input selection differs'):
                figure.capture_files(args, transport=lambda *_:self.fail('forged source made HTTP'))
            self.assertEqual(parse.call_count, 1)
        self.assertFalse((args.output/figure.COMPLETE).exists())

    def test_inventory_replay_final_guard_refuses_late_sql_mutation_before_complete(self):
        args = self.args()
        original = figure.write_projection_stream
        def changed(*values, **options):
            result = original(*values, **options)
            args.sql[0].write_bytes(args.sql[0].read_bytes()+b'late mutation')
            return result
        with patch.object(figure, 'write_projection_stream', side_effect=changed):
            with self.assertRaisesRegex(ValueError, 'source or helper changed'):
                figure.capture_files(args, transport=lambda *_:(200, {}, figure.encoded(self.response())), sleep=lambda _:None)
        self.assertFalse((args.output/figure.COMPLETE).exists())
        self.assertTrue((args.output/'figure-failure-0001.json').exists())

    def logged_query_response(self, titles):
        value = self.response()
        value['query']['general']['git-hash'] = figure.FIGURE_CURRENT_CORE
        value['query']['pages'] = []
        value['query'].pop('redirects', None)
        seen = set()
        for title in titles:
            canonical = 'ملف:FR-estimation.ogg' if title in ('ملف:Alias.ogg', 'ملف:Fr-estimation.ogg') else title
            if canonical != title:
                value['query'].setdefault('redirects', []).append({'from': title, 'to': canonical})
            if canonical in seen:
                continue
            seen.add(canonical)
            if canonical == 'ملف:Missing.ogg':
                page = {'title': canonical, 'ns': 6, 'missing': True, 'imagerepository': ''}
            else:
                page = self.response(canonical)['query']['pages'][0]
                page['imageinfo'][0].update(mime='audio/ogg', mediatype='AUDIO', width=0, height=0)
            value['query']['pages'].append(page)
        return value

    def logged_query_parent(self):
        old_args = self.args
        with patch.object(self, 'args', side_effect=lambda: old_args(links=('FR-estimation.ogg',))):
            inputs = self.normal_build_inputs()
        args = argparse.Namespace(wiki=self.wiki, date=self.date, defaults=self.root/'figure-defaults',
            dumpstatus=self.root/'pagetable-dumpstatus.raw.json',
            sql=[inputs['downloads']/self.wiki/self.date/row['name'] for row in inputs['selected_inputs'] if row['name'].endswith('.sql.gz')],
            output=self.root/'logged-parent', reuse=[], reuse_batch=[], batch_size=50, delay=1,
            wall_seconds=30, figure_profile=figure.FIGURE_PROFILE_V4, metadata_mode='full')
        old_log = self.root/'original-query.log'
        old_log.write_text('warning: file metadata missing: title=ملف:Old.ogg\n')
        args.log = [old_log]
        def parent_transport(url, timeout):
            names = parse_qs(urlsplit(url).query)['titles'][0].split('|')
            self.assertEqual(names, ['ملف:FR-estimation.ogg', 'ملف:Old.ogg'])
            return 200, {}, figure.encoded(self.logged_query_response(names))
        figure.capture_files(args, transport=parent_transport)
        parent = args.output
        original = {p.name: p.read_bytes() for p in parent.iterdir()}
        query_inputs = json.loads(original[figure.QUERY_INPUTS])
        new_log = self.root/'failed-build.log'
        new_log.write_text('warning: file metadata snapshot unavailable: title=ملف:Fr-estimation.ogg\n'
                           'warning: file metadata missing: title=ملف:Alias.ogg\n'
                           'warning: file metadata missing: title=ملف:Missing.ogg\n'
                           'warning: file metadata snapshot unavailable: title=ملف:Fr-estimation.ogg\n')
        args.output = self.root/'figure-inputs'
        args.reuse = [parent]
        args.log = [*(Path(row['source_path']) for row in query_inputs), new_log]
        return args, parent, original, inputs

    def test_logged_query_append_preserves_parent_audio_aliases_and_explicit_absence(self):
        args, parent, original, _ = self.logged_query_parent()
        calls = []
        def transport(url, timeout):
            names = parse_qs(urlsplit(url).query)['titles'][0].split('|')
            calls.append(names)
            self.assertEqual(names, ['ملف:Alias.ogg', 'ملف:Fr-estimation.ogg', 'ملف:Missing.ogg'])
            return 200, {}, figure.encoded(self.logged_query_response(names))
        result = figure.capture_files(args, transport=transport)
        self.assertEqual(len(calls), 1)
        old = self.stream_document(parent)
        new = self.stream_document(args.output)
        old_facts = {row['requested_file']: row for row in old['records']}
        new_facts = {row['requested_file']: row for row in new['records']}
        for name, row in old_facts.items():
            self.assertEqual(new_facts[name], row)
        self.assertEqual(set(new_facts), {'ملف:FR-estimation.ogg', 'ملف:Old.ogg',
            'ملف:Fr-estimation.ogg', 'ملف:Alias.ogg', 'ملف:Missing.ogg'})
        self.assertEqual(new_facts['ملف:Alias.ogg']['canonical_file'], 'ملف:FR-estimation.ogg')
        self.assertEqual(new_facts['ملف:Fr-estimation.ogg']['canonical_file'], 'ملف:FR-estimation.ogg')
        self.assertEqual(new_facts['ملف:Fr-estimation.ogg']['state'], 'unsupported')
        self.assertEqual(new_facts['ملف:Missing.ogg']['state'], 'missing')
        rows = {parts[0]: parts[1:] for parts in
                (line.split('\t') for line in (args.output/figure.PROVIDER).read_text().splitlines()[1:])}
        self.assertEqual(rows['ملف:FR-estimation.ogg'], ['1', '0', '0', 'AUDIO', 'ملف:FR-estimation.ogg'])
        self.assertEqual(rows['ملف:Fr-estimation.ogg'], ['1', '0', '0', 'AUDIO', 'ملف:FR-estimation.ogg'])
        self.assertEqual(rows['ملف:Alias.ogg'], ['1', '0', '0', 'AUDIO', 'ملف:FR-estimation.ogg'])
        self.assertEqual(rows['ملف:Missing.ogg'], ['0', '0', '0', '-', '-'])
        before = list(figure.stream_values(parent/figure.ROLES['figure-sizing-raw'], figure.RAW_STREAM_SCHEMA))
        after = list(figure.stream_values(args.output/figure.ROLES['figure-sizing-raw'], figure.RAW_STREAM_SCHEMA))
        self.assertEqual(after[1:len(before)], before[1:])
        self.assertEqual(result['coverage']['provider'], {'header_version':2, 'rows':5,
            'positive_rows':4, 'negative_rows':1, 'sql_files':1, 'observed_query_files':4,
            'observed_only_files':4, 'corpus_query_closure_proven':False})
        self.assertEqual(figure.verify(args.output), result)
        self.assertEqual(original, {p.name:p.read_bytes() for p in parent.iterdir()})

    def test_logged_query_append_retained_ordinary_record_reaches_normal_offline_five_roles(self):
        args, parent, original, inputs = self.logged_query_parent()
        names = ['ملف:Alias.ogg', 'ملف:Fr-estimation.ogg', 'ملف:Missing.ogg']
        record = self.write_normal_retained('audio-observation', self.logged_query_response(names), names)
        args.reuse_batch = [record]
        result = figure.capture_files(args, transport=lambda *_:self.fail('Retained records refetched'))
        with patch.object(figure.evidence, 'get_response', side_effect=AssertionError('Offline normal path fetched')):
            paths = builder.resolve_figure_snapshot_options(self.root, inputs['manifest'], inputs['selected_inputs'],
                inputs['downloads'], self.namespace, {}, metadata_network='offline',
                figure_reuse_batches=[parent/figure.MANIFEST, record])
        self.assertEqual(set(paths), {*figure.ROLES, 'file-metadata'})
        self.assertEqual({p.parent for p in paths.values()}, {args.output})
        self.assertEqual(figure.verify(args.output), result)
        self.assertEqual(original, {p.name:p.read_bytes() for p in parent.iterdir()})
        self.assertFalse(list(args.output.glob('file-metadata.request-*.json')))

    def test_logged_query_append_requires_exact_old_query_prefix_before_new_requests(self):
        args, parent, original, _ = self.logged_query_parent()
        old_log, new_log = args.log
        changed = self.root/'changed-old.log'
        changed.write_bytes(old_log.read_bytes()+b'additional old-log byte\n')
        for index, logs in enumerate(([new_log], [new_log, old_log], [changed, new_log])):
            with self.subTest(index=index):
                args.output = self.root/f'bad-log-prefix-{index}'
                args.log = logs
                with self.assertRaisesRegex(ValueError, 'Complete Figure input selection differs'):
                    figure.capture_files(args, transport=lambda *_:self.fail('Changed selection made HTTP'))
                self.assertFalse((args.output/figure.COMPLETE).exists())
        self.assertEqual(original, {p.name:p.read_bytes() for p in parent.iterdir()})

    def test_logged_query_append_rejects_unlogged_names_and_replacement_of_parent_facts(self):
        args, parent, original, _ = self.logged_query_parent()
        for index, name in enumerate(('ملف:Unlogged.ogg', 'ملف:FR-estimation.ogg')):
            with self.subTest(name=name):
                record = self.write_normal_retained(f'bad-retained-{index}', self.logged_query_response([name]), [name])
                args.output = self.root/f'bad-observed-selection-{index}'
                args.reuse_batch = [record]
                with self.assertRaisesRegex(ValueError, 'duplicate or unselected'):
                    figure.capture_files(args, transport=lambda *_:self.fail('Unselected request made HTTP'))
                self.assertFalse((args.output/figure.COMPLETE).exists())
        self.assertEqual(original, {p.name:p.read_bytes() for p in parent.iterdir()})

    def test_logged_query_append_rehashed_old_log_change_fails_final_parent_replay(self):
        args, parent, original, _ = self.logged_query_parent()
        names = ['ملف:Alias.ogg', 'ملف:Fr-estimation.ogg', 'ملف:Missing.ogg']
        args.reuse_batch = [self.write_normal_retained('new-audio', self.logged_query_response(names), names)]
        result = figure.capture_files(args, transport=lambda *_:self.fail('Retained response refetched'))
        queries = json.loads((args.output/figure.QUERY_INPUTS).read_text())
        path = args.output/queries[0]['path']
        path.write_bytes(path.read_bytes()+b'coherently rehashed extra comment\n')
        queries[0].update(figure.evidence.fingerprint(path))
        (args.output/figure.QUERY_INPUTS).write_bytes(figure.encoded(queries))
        plan = json.loads((args.output/figure.PLAN).read_text())
        plan['query_inputs'] = queries
        (args.output/figure.PLAN).write_bytes(figure.encoded(plan))
        result['artifacts'] = figure.payload(args.output)
        (args.output/figure.MANIFEST).write_bytes(figure.encoded(result))
        (args.output/figure.COMPLETE).write_bytes(figure.encoded({'schema':figure.SCHEMA,
            'manifest_sha256':figure.digest((args.output/figure.MANIFEST).read_bytes())}))
        with self.assertRaisesRegex(ValueError, 'Complete Figure input selection differs'):
            figure.verify(args.output)
        self.assertEqual(original, {p.name:p.read_bytes() for p in parent.iterdir()})

    def test_logged_query_append_changed_parent_or_conflicting_alias_cannot_publish(self):
        args, parent, original, _ = self.logged_query_parent()
        raw_path = parent/figure.ROLES['figure-sizing-raw']
        raw_path.write_bytes(original[raw_path.name][:-1])
        with self.assertRaises(ValueError):
            figure.capture_files(args, transport=lambda *_:self.fail('Changed parent made HTTP'))
        self.assertFalse((args.output/figure.COMPLETE).exists())
        raw_path.write_bytes(original[raw_path.name])
        args.output = self.root/'conflicting-alias'
        names = ['ملف:Alias.ogg', 'ملف:Fr-estimation.ogg', 'ملف:Missing.ogg']
        value = self.logged_query_response(names)
        other = next(page for page in value['query']['pages'] if page['title'] == 'ملف:FR-estimation.ogg')
        other['imageinfo'][0]['sha1'] = 'b'*40
        with self.assertRaisesRegex(ValueError, 'Conflicting canonical file facts'):
            figure.capture_files(args, transport=lambda *_:(200, {}, figure.encoded(value)))
        self.assertFalse((args.output/figure.COMPLETE).exists())
        self.assertEqual(original, {p.name:p.read_bytes() for p in parent.iterdir()})

    def test_logged_query_append_resume_keeps_parent_prefix_and_only_queries_new_names(self):
        args, parent, original, _ = self.logged_query_parent()
        args.wall_seconds = 1
        clock = [0.0]
        replay = figure.replay_source
        def stop_after_parent(root, source, *rest, **options):
            result = replay(root, source, *rest, **options)
            if root == args.output and source['kind'] == 'complete-stream':
                clock[0] = 2.0
            return result
        with patch.object(figure.time, 'monotonic', side_effect=lambda:clock[0]), \
                patch.object(figure, 'replay_source', side_effect=stop_after_parent):
            with self.assertRaisesRegex(ValueError, 'Capture wall deadline reached'):
                figure.capture_files(args, transport=lambda *_:self.fail('Expired request reached HTTP'))
        prefix = (args.output/figure.ROLES['figure-sizing-raw']).read_bytes()
        self.assertEqual(json.loads((args.output/'figure-failure-0001.json').read_text())['committed_batches'], 1)
        self.complete_resume_proof(args, 1)
        args.wall_seconds = 30
        calls = []
        def transport(url, timeout):
            names = parse_qs(urlsplit(url).query)['titles'][0].split('|')
            calls.append(names)
            return 200, {}, figure.encoded(self.logged_query_response(names))
        result = figure.capture_files(args, transport=transport)
        self.assertEqual(calls, [['ملف:Alias.ogg', 'ملف:Fr-estimation.ogg', 'ملف:Missing.ogg']])
        self.assertTrue((args.output/figure.ROLES['figure-sizing-raw']).read_bytes().startswith(prefix))
        self.assertEqual(figure.verify(args.output), result)
        self.assertEqual(original, {p.name:p.read_bytes() for p in parent.iterdir()})

    def test_stream_membership_does_not_add_a_payload_hash_pass(self):
        args = self.args()
        figure.capture_files(args, transport=lambda *_: (200, {}, figure.encoded(self.response())), sleep=lambda _: None)
        paths = {role: args.output/name for role, name in dict(figure.ROLES, **{'file-metadata': figure.PROVIDER}).items()}
        with patch.object(figure, 'payload', wraps=figure.payload) as payload, \
             patch.object(figure, 'verify_stream_document', wraps=figure.verify_stream_document) as semantic:
            figure.verify_tuple(paths, self.wiki, self.date)
            semantic.assert_called_once()
            # One final payload guard remains; member-name checking adds none.
            self.assertEqual(payload.call_count, 1)

    def test_stream_membership_refuses_missing_extra_and_nonregular_members(self):
        args = self.args()
        figure.capture_files(args, transport=lambda *_: (200, {}, figure.encoded(self.response())), sleep=lambda _: None)
        paths = {role: args.output/name for role, name in dict(figure.ROLES, **{'file-metadata': figure.PROVIDER}).items()}
        raw = paths['figure-sizing-raw']; original_raw = raw.read_bytes()
        unexpected = args.output/'unaccounted.raw'
        original = figure.check_prefix_cache
        for change in ('missing', 'extra', 'directory', 'symlink'):
            with self.subTest(change=change):
                def mutate(cache):
                    original(cache)
                    if change == 'missing': raw.unlink()
                    elif change == 'extra': unexpected.write_bytes(b'unaccounted\n')
                    elif change == 'directory': unexpected.mkdir()
                    else: unexpected.symlink_to(raw)
                try:
                    with patch.object(figure, 'check_prefix_cache', side_effect=mutate):
                        message = 'regular, non-symlink' if change in ('directory', 'symlink') else 'Unexpected or incomplete streamed Figure evidence'
                        with self.assertRaisesRegex(ValueError, message):
                            figure.verify_tuple(paths, self.wiki, self.date)
                finally:
                    if change == 'missing': raw.write_bytes(original_raw)
                    elif change == 'directory': unexpected.rmdir()
                    else: unexpected.unlink()

    def test_stream_membership_preserves_final_payload_content_authentication(self):
        args = self.args()
        figure.capture_files(args, transport=lambda *_: (200, {}, figure.encoded(self.response())), sleep=lambda _: None)
        paths = {role: args.output/name for role, name in dict(figure.ROLES, **{'file-metadata': figure.PROVIDER}).items()}
        original = figure.replay_stream_capture
        completed = []
        def mutate(*values, **options):
            result = original(*values, **options); completed.append(True)
            raw = paths['figure-sizing-raw']; value = raw.read_bytes()
            raw.write_bytes(value[:-2]+bytes([value[-2]^1])+value[-1:])
            return result
        with patch.object(figure, 'replay_stream_capture', side_effect=mutate):
            with self.assertRaisesRegex(ValueError, 'Figure verified raw changed before content authentication'):
                figure.verify_tuple(paths, self.wiki, self.date)
        self.assertEqual(completed, [True])

    def test_stream_membership_preserves_rehashed_projection_semantic_refusal(self):
        args = self.args()
        manifest = figure.capture_files(args, transport=lambda *_: (200, {}, figure.encoded(self.response())), sleep=lambda _: None)
        paths = {role: args.output/name for role, name in dict(figure.ROLES, **{'file-metadata': figure.PROVIDER}).items()}
        path = paths['figure-sizing']; rows = [json.loads(line) for line in path.read_text().splitlines()]
        rows[1]['original_width'] += 1
        path.write_bytes(b''.join(figure.stream_encoded(row) for row in rows))
        manifest['outputs']['figure-sizing'] = figure.digest(path.read_bytes())
        manifest['artifacts'] = figure.payload(args.output)
        manifest_path = args.output/figure.MANIFEST
        manifest_path.write_bytes(figure.encoded(manifest))
        (args.output/figure.COMPLETE).write_bytes(figure.encoded(dict(schema=figure.SCHEMA,
            manifest_sha256=figure.digest(manifest_path.read_bytes()))))
        with self.assertRaisesRegex(ValueError, 'projection stream record differs from exact raw replay'):
            figure.verify_tuple(paths, self.wiki, self.date)

    def decimal_tiff_response(self):
        response = self.lean_response(['ملف:B.tif'], metadata_requested=True)
        info = response['query']['pages'][0]['imageinfo'][0]
        info.update(width=4928, height=3868)
        page = next(row['value'] for row in info['metadata'] if row['name']=='page_data')[0]['value']
        for row in page:
            if row['name'] in ('width','height'):row['value']=str(info[row['name']])
        return response

    def test_tiff_decimal_axes_accept_only_canonical_positive_u32_dimensions(self):
        original = self.decimal_tiff_response()['query']['pages'][0]['imageinfo'][0]
        with self.assertRaisesRegex(ValueError, 'single-page TIFF axes'):
            figure._figure_tiff_page_axes(original,4928,3868)
        figure._figure_tiff_page_axes(original,4928,3868,allow_decimal_axes=True)
        for value in (4928,'4928'):
            image=copy.deepcopy(original)
            page=next(row['value'] for row in image['metadata'] if row['name']=='page_data')[0]['value']
            next(row for row in page if row['name']=='width')['value']=value
            figure._figure_tiff_page_axes(image,4928,3868,allow_decimal_axes=True)
        for value in ('','0','04928','+4928','-4928',' 4928','4928 ','4928\n','4928.0','4.928e3','٤٩٢٨','4294967296','999999999999999999999',True,4928.0,None,-1,0,'4927'):
            with self.subTest(value=value):
                image=copy.deepcopy(original)
                page=next(row['value'] for row in image['metadata'] if row['name']=='page_data')[0]['value']
                next(row for row in page if row['name']=='width')['value']=value
                with self.assertRaisesRegex(ValueError,'single-page TIFF axes'):
                    figure._figure_tiff_page_axes(image,4928,3868,allow_decimal_axes=True)
        image=copy.deepcopy(original)
        page=next(row['value'] for row in image['metadata'] if row['name']=='page_data')[0]['value']
        next(row for row in page if row['name']=='width')['value']='4294967295'
        figure._figure_tiff_page_axes(image,2**32-1,3868,allow_decimal_axes=True)
        # The old positive occurrence schema has no v4 selector.
        legacy = self.decimal_tiff_response()
        integer = copy.deepcopy(legacy)
        info = integer['query']['pages'][0]['imageinfo'][0]
        page = next(row['value'] for row in info['metadata'] if row['name']=='page_data')[0]['value']
        for row in page:
            if row['name'] in ('width', 'height'):
                row['value'] = int(row['value'])
        site = figure.encoded(integer)
        profile = dict(figure.FIGURE_SOURCE_PROFILES[figure.FIGURE_CURRENT_CORE], site_raw_sha256=figure.digest(site))
        requests = [dict(canonical_file='ملف:B.tif', format='thumbnail', width_px=200, height_px=None)]
        valid = figure.figure_sizing_document(figure.encoded(integer), self.namespace.read_bytes(), self.wiki, self.date, requests, profile, site)
        self.assertEqual(valid['records'][0]['original_width'], 4928)
        with self.assertRaisesRegex(ValueError, 'single-page TIFF axes'):
            figure.figure_sizing_document(figure.encoded(legacy), self.namespace.read_bytes(), self.wiki, self.date, requests, profile, site)

    def test_tiff_decimal_axes_do_not_coerce_count_page_version_or_conflicting_metadata(self):
        original=self.decimal_tiff_response()['query']['pages'][0]['imageinfo'][0]
        for mode in ('pagecount','page_count','first_page','last_page','page','version','duplicate-width','extra-page','errors'):
            with self.subTest(mode=mode):
                image=copy.deepcopy(original);metadata_rows=image['metadata']
                pages=next(row['value'] for row in metadata_rows if row['name']=='page_data')
                page=pages[0]['value']
                if mode=='pagecount':image['pagecount']='1'
                elif mode in ('page_count','first_page','last_page'):
                    next(row for row in metadata_rows if row['name']==mode)['value']='1'
                elif mode=='page':next(row for row in page if row['name']=='page')['value']='1'
                elif mode=='version':next(row for row in metadata_rows if row['name']=='TIFF_METADATA_VERSION')['value']=1.4
                elif mode=='duplicate-width':page.append(copy.deepcopy(next(row for row in page if row['name']=='width')))
                elif mode=='extra-page':pages.append(copy.deepcopy(pages[0]))
                else:metadata_rows.append({'name':'errors','value':[]})
                with self.assertRaises(ValueError):
                    figure._figure_tiff_page_axes(image,4928,3868,allow_decimal_axes=True)

    def test_tiff_decimal_replay_contract_preserves_old_unsupported_facts(self):
        response=self.decimal_tiff_response();site=figure.encoded(response)
        raw=figure.encoded({'schema':figure.RAW_BATCHES_SCHEMA,'batches':[self.batch('ملف:B.tif',response)]})
        options=dict(profile_kind=figure.FIGURE_PROFILE_V4)
        old=figure.figure_file_document(raw,self.namespace.read_bytes(),self.wiki,self.date,site,
            allow_decimal_tiff_axes=False,**options)
        self.assertEqual(old['records'][0]['state'],'unsupported')
        for contract in (None,figure.REPLAY_CONTRACT_V1,figure.REPLAY_CONTRACT_V2,figure.REPLAY_CONTRACT_V3):
            document=copy.deepcopy(old)
            if contract is None:document.pop('replay_contract')
            else:document['replay_contract']=contract
            self.assertEqual(figure.verify_figure_file_document(document,raw,self.namespace.read_bytes(),self.wiki,self.date,site),document)
            wrong=copy.deepcopy(document);wrong['records'][0]['state']='eligible'
            with self.assertRaisesRegex(ValueError,'exact batch replay'):
                figure.verify_figure_file_document(wrong,raw,self.namespace.read_bytes(),self.wiki,self.date,site)
        new=figure.figure_file_document(raw,self.namespace.read_bytes(),self.wiki,self.date,site,**options)
        self.assertEqual(new['replay_contract'],figure.REPLAY_CONTRACT)
        self.assertEqual(new['records'][0]['state'],'eligible')
        self.assertEqual(figure.verify_figure_file_document(new,raw,self.namespace.read_bytes(),self.wiki,self.date,site),new)
        self.assertEqual(b''.join(figure.provider_chunks(old)),b''.join(figure.provider_chunks(new)))
        wrong=copy.deepcopy(new);wrong['records'][0]['state']='unsupported'
        with self.assertRaisesRegex(ValueError,'exact batch replay'):
            figure.verify_figure_file_document(wrong,raw,self.namespace.read_bytes(),self.wiki,self.date,site)

    def test_tiff_decimal_normal_parent_carry_preserves_legacy_bytes_and_promotes_only_new_projection(self):
        args=self.args(links=('B.tif',));args.figure_profile=figure.FIGURE_PROFILE_V4
        records=figure.file_records
        def integer_only(*values,**options):
            options['allow_decimal_tiff_axes']=False
            return records(*values,**options)
        with patch.object(figure,'file_records',side_effect=integer_only):
            manifest=figure.capture_files(args,transport=lambda *_:(200,{},figure.encoded(self.decimal_tiff_response())),sleep=lambda _:None)
        parent=args.output;projection_path=parent/figure.ROLES['figure-sizing']
        document=self.stream_document(parent)
        self.assertEqual(document['records'][0]['state'],'unsupported')
        document['replay_contract']=figure.REPLAY_CONTRACT_V3
        projection_path.unlink();figure.write_projection_stream(projection_path,document)
        plan=json.loads((parent/figure.PLAN).read_bytes());plan['replay_contract']=figure.REPLAY_CONTRACT_V3
        (parent/figure.PLAN).write_bytes(figure.encoded(plan))
        manifest['outputs']['figure-sizing']=figure.digest(projection_path.read_bytes())
        manifest['artifacts']=figure.payload(parent)
        (parent/figure.MANIFEST).write_bytes(figure.encoded(manifest))
        (parent/figure.COMPLETE).write_bytes(figure.encoded(dict(schema=figure.SCHEMA,manifest_sha256=figure.digest((parent/figure.MANIFEST).read_bytes()))))
        before={p.name:p.read_bytes() for p in parent.iterdir()}
        self.assertEqual(figure.verify(parent),manifest)
        args.output=self.root/'decimal-successor';args.reuse=[parent];args.reuse_batch=[]
        successor=figure.capture_files(args,transport=lambda *_:self.fail('Retained TIFF parent made HTTP'))
        current=self.stream_document(args.output)
        self.assertEqual(current['replay_contract'],figure.REPLAY_CONTRACT)
        self.assertEqual(current['records'][0],dict(document['records'][0],state='eligible'))
        self.assertEqual((args.output/figure.PROVIDER).read_bytes(),(parent/figure.PROVIDER).read_bytes())
        self.assertEqual(figure.verify(args.output),successor)
        self.assertEqual(before,{p.name:p.read_bytes() for p in parent.iterdir()})


    def epoch_defaults(self):
        data = copy.deepcopy(self.data)
        data['query']['general']['git-hash'] = figure.FIGURE_CURRENT_CORE
        output = self.root/'epoch-defaults'
        args = argparse.Namespace(wiki=self.wiki, date=self.date,
            namespace_registry=self.namespace, primary_sources=self.primary,
            output=output, delay=0, wall_seconds=30, figure_defaults=True)
        figure.site_info.capture(args, transport=lambda *_:(200, {}, figure.encoded(data)), sleep=lambda _:None)
        (self.root/'defaults').rename(self.root/'legacy-defaults')
        output.rename(self.root/'defaults')


    def epoch_response(self, titles, core, *, full=False):
        value = self.lean_response(titles, metadata_requested=full)
        value['query']['general']['git-hash'] = core
        return value


    def epoch_document(self, batches, *, anchor=None):
        anchor = anchor or figure.FIGURE_CURRENT_CORE
        site = copy.deepcopy(self.site_api)
        site['query']['general']['git-hash'] = anchor
        raw = figure.encoded({'schema':figure.RAW_BATCHES_SCHEMA, 'batches':batches})
        return figure.figure_file_document(raw, self.namespace.read_bytes(), self.wiki, self.date,
            figure.encoded(site), profile_kind=figure.FIGURE_PROFILE_V4), raw, figure.encoded(site)


    def make_source_epoch_prefix(self, *, normal=False):
        self.epoch_defaults()
        names = ('A.png', 'B.ogg', 'C.ogg', 'Zlast.png')
        inputs = None
        if normal:
            original_args = self.args
            with patch.object(self, 'args', side_effect=lambda:original_args(links=names)):
                inputs = self.normal_build_inputs()
            args = argparse.Namespace(wiki=self.wiki, date=self.date, defaults=self.root/'figure-defaults',
                dumpstatus=self.root/'pagetable-dumpstatus.raw.json',
                sql=[inputs['downloads']/self.wiki/self.date/row['name'] for row in inputs['selected_inputs'] if row['name'].endswith('.sql.gz')],
                output=self.root/'figure-inputs', reuse=[], delay=1, wall_seconds=30)
        else:
            args = self.args(links=names)
        args.metadata_mode, args.figure_profile = 'lean-tiff-v1', figure.FIGURE_PROFILE_V4
        args.batch_size, args.max_inflight = 1, 2
        calls, third = [], threading.Event()
        now, advance = self.overlap_clock()
        original_compatible = figure.figure_source_compatible
        def transport(url, timeout):
            title = parse_qs(urlsplit(url).query)['titles'][0]
            calls.append(title)
            if title.endswith('B.ogg'):
                self.assertTrue(third.wait(5), 'second accepted slot did not run')
            if title.endswith('C.ogg'):
                third.set()
            core = figure.FIGURE_CURRENT_CORE if title.endswith('A.png') else figure.FIGURE_RESPONSE_CORE
            return 200, {}, figure.encoded(self.epoch_response([title], core))
        # Model the old producer's exact rejected boundary, while all capture,
        # HTTP archives, pending slots and immutable closure descriptors are real.
        with patch.object(figure, 'figure_source_compatible', side_effect=lambda a,b:
                a != figure.FIGURE_RESPONSE_CORE and original_compatible(a,b)), \
                patch.object(figure.time, 'monotonic', side_effect=now):
            with self.assertRaisesRegex(ValueError, 'Lean Figure and defaults source versions differ'):
                figure.capture_files(args, transport=transport, sleep=advance)
        self.assertEqual(calls[0], 'ملف:A.png')
        self.assertEqual(sorted(calls[1:]), ['ملف:B.ogg', 'ملف:C.ogg'])
        old_root = args.output
        failure_path = old_root/'figure-failure-0001.json'
        failure = json.loads(failure_path.read_text())
        self.assertEqual((failure['committed_batches'],failure['pending_http']), (1,[2,3]))
        def descriptor(path):
            raw = path.read_bytes()
            return {'path':str(path.resolve()),'bytes':len(raw),'sha256':figure.digest(raw)}
        closure = dict(outcome='FAILED-PHYSICALLY-SOURCE-CLOSED', source_after=True,
            reaped=True, dual_proc_absence=True, ps_absence=True, allocation_released=True,
            terminal=1, detail=failure['error'], committed_batches=1,
            retained_metadata={'failure':descriptor(failure_path),
                'plan':descriptor(old_root/figure.PLAN), 'journal':descriptor(old_root/figure.FILE_REQUESTS)})
        closure_path=self.root/'source-closure.json';closure_path.write_bytes(figure.encoded(closure))
        kept=self.root/'source-prefix-original';old_root.rename(kept)
        proof=dict(schema=figure.SOURCE_PREFIX_SCHEMA,wiki=self.wiki,date=self.date,
            source_root=str(kept.resolve()),original_root=str(old_root.resolve()),
            closure=descriptor(closure_path),source_epochs=[figure.FIGURE_CURRENT_CORE, figure.FIGURE_RESPONSE_CORE])
        proof_dir=self.root/'source-prefix-reference';proof_dir.mkdir()
        proof_path=proof_dir/'source-prefix.json';proof_path.write_bytes(figure.encoded(proof))
        args.reuse_batch=[proof_path]
        return args,proof_path,inputs


    def rebind_source_epoch_fixture(self, proof_path):
        proof=json.loads(proof_path.read_text());root=Path(proof['source_root'])
        failure_path=root/'figure-failure-0001.json'
        failure=json.loads(failure_path.read_text())
        for name in failure['artifacts']:
            data=(root/name).read_bytes()
            failure['artifacts'][name]={'bytes':len(data),'sha256':figure.digest(data)}
        failure['plan_sha256']=figure.digest((root/figure.PLAN).read_bytes())
        failure_path.write_bytes(figure.encoded(failure))
        closure_path=Path(proof['closure']['path']);closure=json.loads(closure_path.read_text())
        for ref in closure['retained_metadata'].values():
            data=(root/Path(ref['path']).name).read_bytes()
            ref.update(bytes=len(data),sha256=figure.digest(data))
        closure_path.write_bytes(figure.encoded(closure))
        data=closure_path.read_bytes();proof['closure'].update(bytes=len(data),sha256=figure.digest(data))
        proof_path.write_bytes(figure.encoded(proof))


    def test_response_epochs_v3_preserves_old_new_mixed_raw_and_provider(self):
        titles=['ملف:A.png','ملف:B.ogg']
        for cores in ((figure.FIGURE_CURRENT_CORE,)*2,(figure.FIGURE_RESPONSE_CORE,)*2,
                      (figure.FIGURE_CURRENT_CORE, figure.FIGURE_RESPONSE_CORE)):
            with self.subTest(cores=cores):
                batches=[self.batch(t,self.epoch_response([t],core)) for t,core in zip(titles,cores)]
                doc,raw,site=self.epoch_document(batches,anchor=cores[0])
                self.assertEqual(doc['core_revision'],cores[0])
                self.assertEqual(doc['replay_contract'],figure.REPLAY_CONTRACT)
                self.assertEqual(figure.verify_figure_file_document(doc,raw,
                    self.namespace.read_bytes(),self.wiki,self.date,site),doc)
                expected=[self.batch(t,self.epoch_response([t],figure.FIGURE_CURRENT_CORE)) for t in titles]
                prior,_,_=self.epoch_document(expected)
                self.assertEqual(doc['records'],prior['records'])
                self.assertEqual(figure.provider_tsv(doc),figure.provider_tsv(prior))
                self.assertEqual([json.loads(b['response'])['query']['general']['git-hash'] for b in batches],list(cores))
                for contract in (None,figure.REPLAY_CONTRACT_V1,figure.REPLAY_CONTRACT_V2):
                    changed=copy.deepcopy(doc)
                    if contract is None:changed.pop('replay_contract')
                    else:changed['replay_contract']=contract
                    if figure.FIGURE_RESPONSE_CORE in cores:
                        with self.assertRaises(ValueError):
                            figure.verify_figure_file_document(changed,raw,
                                self.namespace.read_bytes(),self.wiki,self.date,site)


    def test_response_epochs_reject_unknown_core_media_time_language_and_false_profile(self):
        title='ملف:B.ogg';base=self.epoch_response([title],figure.FIGURE_RESPONSE_CORE)
        variants=[]
        for field,value in (('git-hash','0'*40),('lang','en'),('wikiid','enwiktionary')):
            bad=copy.deepcopy(base);bad['query']['general'][field]=value;variants.append(bad)
        bad=copy.deepcopy(base);bad['query']['extensions'][0]['vcs-version']='0'*40;variants.append(bad)
        bad=copy.deepcopy(base);bad['curtimestamp']='2000-01-01T00:00:00Z';variants.append(bad)
        for index,bad in enumerate(variants):
            with self.subTest(index=index),self.assertRaises(ValueError):
                self.epoch_document([self.batch(title,bad)])
        doc,raw,site=self.epoch_document([self.batch(title,base)])
        doc['source_profile']['kind']=figure.FIGURE_PROFILE_V3
        with self.assertRaises(ValueError):
            figure.verify_figure_file_document(doc,raw,self.namespace.read_bytes(),self.wiki,self.date,site)


    def test_response_epochs_tiff_companion_stays_same_epoch_and_html_occurrences_refuse(self):
        title='ملف:F.tif';core=figure.FIGURE_RESPONSE_CORE
        base=self.epoch_response([title],core)
        companion=self.epoch_response([title],core,full=True)
        batch=self.batch(title,base);batch['tiff_metadata_response']=figure.encoded(companion).decode()
        doc,_,_=self.epoch_document([batch]);self.assertEqual(doc['records'][0]['state'],'eligible')
        for changed in (figure.FIGURE_CURRENT_CORE,'0'*40):
            bad=copy.deepcopy(companion);bad['query']['general']['git-hash']=changed
            broken=dict(batch,tiff_metadata_response=figure.encoded(bad).decode())
            with self.assertRaises(ValueError):self.epoch_document([broken])
        response,observed=self.height_observation_fixture()
        base={'requests':observed['requests'],'response':observed['response']}
        self.epoch_document([base,observed])
        response['query']['general']['git-hash']=core
        observed['response']=figure.encoded(response).decode()
        with self.assertRaisesRegex(ValueError,'do not grant HTML occurrence'):
            self.epoch_document([base,observed])


    def test_source_epoch_closed_prefix_carries_both_accepted_slots_without_refetch(self):
        args,proof_path,_=self.make_source_epoch_prefix()
        root=Path(json.loads(proof_path.read_text())['source_root'])
        before={p.name:p.read_bytes() for p in root.iterdir()}
        prefix=figure.read_closed_prefix(proof_path)
        self.assertEqual(prefix['batch_count'],3)
        self.assertEqual([row['state'] for row in prefix['document']['records']],['eligible','unsupported','unsupported'])
        calls=[];now,advance=self.overlap_clock()
        def transport(url,timeout):
            titles=parse_qs(urlsplit(url).query)['titles'][0].split('|');calls.append(titles)
            return 200,{},figure.encoded(self.epoch_response(titles,figure.FIGURE_RESPONSE_CORE))
        with patch.object(figure.time,'monotonic',side_effect=now):
            result=figure.capture_files(args,transport=transport,sleep=advance)
        self.assertEqual(calls,[['ملف:Zlast.png']])
        doc=self.stream_document(args.output)
        self.assertEqual(doc['core_revision'],figure.FIGURE_CURRENT_CORE)
        self.assertEqual(doc['replay_contract'],figure.REPLAY_CONTRACT)
        self.assertEqual(doc['records'][:3],prefix['document']['records'])
        self.assertEqual(figure.verify(args.output),result)
        self.assertEqual(before,{p.name:p.read_bytes() for p in root.iterdir()})
        self.assertIn(b'B.ogg',(args.output/figure.PROVIDER).read_bytes())
        self.assertFalse((root/figure.COMPLETE).exists())


    def test_source_epoch_closed_prefix_normal_resolver_keeps_five_roles_and_defaults(self):
        args,proof_path,inputs=self.make_source_epoch_prefix(normal=True)
        now,advance=self.overlap_clock();calls=[]
        def transport(url,timeout):
            titles=parse_qs(urlsplit(url).query)['titles'][0].split('|');calls.append(titles)
            return 200,{},figure.encoded(self.epoch_response(titles,figure.FIGURE_RESPONSE_CORE))
        with patch.object(figure.time,'monotonic',side_effect=now):
            result=figure.capture_files(args,transport=transport,sleep=advance)
        self.assertEqual(calls,[['ملف:Zlast.png']])
        defaults=(args.output/figure.ROLES['figure-siteinfo']).read_bytes()
        with patch.object(figure.evidence,'get_response',side_effect=AssertionError('offline resolver fetched')):
            selected=figure.prepare_for_build(**inputs,network=False)
            hashes,_=builder._validated_auxiliary_state(selected,self.wiki,self.date,
                captured_selection=({},result['source_dump_files'],None))
        self.assertEqual(set(hashes),{*figure.ROLES,'file-metadata'})
        self.assertEqual((args.output/figure.ROLES['figure-siteinfo']).read_bytes(),defaults)


    def test_source_epoch_closed_prefix_stale_cache_members_and_output_overlap_refuse(self):
        args,proof_path,_=self.make_source_epoch_prefix()
        root=Path(json.loads(proof_path.read_text())['source_root']);cache={}
        figure.read_closed_prefix(proof_path,cache)
        body=root/'file-metadata.response-000002-01.raw.json';original=body.read_bytes()
        replacement=root/'replacement';replacement.write_bytes(original);replacement.replace(body)
        with self.assertRaises(ValueError):figure.check_prefix_cache(cache)
        with self.assertRaises(ValueError):figure.read_closed_prefix(proof_path,cache)
        extra=root/'unaccounted';extra.write_bytes(b'x')
        with self.assertRaises(ValueError):figure.read_closed_prefix(proof_path,{})
        extra.unlink()
        args.output=root/'nested'/'output'
        with self.assertRaisesRegex(ValueError,'cannot modify its closed prefix'):
            figure.capture_files(args,transport=lambda *_:self.fail('overlap fetched'))
        self.assertFalse((root/'nested').exists())


    def test_source_epoch_closed_prefix_rehashed_pending_corruption_and_incomplete_proof_refuse(self):
        _,proof_path,_=self.make_source_epoch_prefix()
        root=Path(json.loads(proof_path.read_text())['source_root'])
        originals={p:p.read_bytes() for p in [*root.iterdir(),proof_path,self.root/'source-closure.json']}
        body=root/'file-metadata.response-000002-01.raw.json'
        receipt=root/'file-metadata.response-000002-01.receipt.json'
        def restore():
            for path,data in originals.items():path.write_bytes(data)
        for label in ('core','media','identity','tiff','receipt','pending','order','source','closure'):
            restore()
            with self.subTest(label=label):
                value=json.loads(body.read_text())
                if label=='core':value['query']['general']['git-hash']='0'*40
                elif label=='media':value['query']['extensions'][0]['vcs-version']='0'*40
                elif label=='identity':value['query']['pages'][0]['title']='ملف:Other.ogg'
                elif label=='tiff':value['query']['pages'][0]['imageinfo'][0].update(mime='image/tiff',mediatype='BITMAP',width=800,height=600)
                if label in ('core','media','identity','tiff'):
                    body.write_bytes(figure.encoded(value))
                    r=json.loads(receipt.read_text());r['response_bytes']=len(body.read_bytes());r['response_sha256']=figure.digest(body.read_bytes())
                    receipt.write_bytes(figure.encoded(r))
                if label=='receipt':
                    r=json.loads(receipt.read_text());r['status']=403;receipt.write_bytes(figure.encoded(r))
                if label=='pending':
                    p=root/'figure-failure-0001.json';v=json.loads(p.read_text());v['pending_http']=[2];p.write_bytes(figure.encoded(v))
                if label=='order':
                    p=root/figure.FILE_REQUESTS;rows=p.read_bytes().splitlines(keepends=True);rows[1]=rows[1].replace(b'000001',b'000002');p.write_bytes(b''.join(rows))
                if label=='source':
                    p=root/'figure-failure-0001.json';v=json.loads(p.read_text());v['source']['generator_sha256']='0'*64;p.write_bytes(figure.encoded(v))
                self.rebind_source_epoch_fixture(proof_path)
                if label=='closure':
                    p=self.root/'source-closure.json';v=json.loads(p.read_text());v['allocation_released']=False;p.write_bytes(figure.encoded(v))
                    v=json.loads(proof_path.read_text());v['closure'].update(bytes=p.stat().st_size,sha256=figure.digest(p.read_bytes()));proof_path.write_bytes(figure.encoded(v))
                with self.assertRaises(ValueError):
                    figure.read_closed_prefix(proof_path,{})
        restore()
        self.assertEqual(figure.read_closed_prefix(proof_path,{})['batch_count'],3)


    def test_source_epoch_prefix_requires_explicit_closed_source_failure_not_wall_resume(self):
        args,proof_path,_=self.make_source_epoch_prefix()
        root=Path(json.loads(proof_path.read_text())['source_root'])
        proof=json.loads(proof_path.read_text());proof['source_epochs'].reverse();proof_path.write_bytes(figure.encoded(proof))
        with self.assertRaisesRegex(ValueError,'Invalid closed Figure source transition'):
            figure.read_closed_prefix(proof_path)
        failure=json.loads((root/'figure-failure-0001.json').read_text())
        self.assertEqual(failure['resumes'],[])
        self.assertNotIn(failure['error'],figure.WALL_ERRORS)
        args.output=root
        self.complete_resume_proof(args,1)
        raw=args.resume.read_bytes()
        reference={'path':args.resume.name,'bytes':len(raw),'sha256':figure.digest(raw)}
        plan=json.loads((root/figure.PLAN).read_text())
        with self.assertRaisesRegex(ValueError,'not an authenticated closed wall-stop prefix'):
            figure.read_resume(root,reference,plan,live=True)


    def test_stream_verification_returns_exact_retained_contract_and_generator(self):
        document, aggregate, site = self.replay_contract_fixture()
        batch = json.loads(aggregate)['batches'][0]
        header = {'schema': figure.RAW_STREAM_SCHEMA,
            **{key: document[key] for key in ('wiki', 'core_revision', 'namespace_registry_sha256')},
            'records_count': len(document['records']), 'base_batches': 1, 'observed_batches': 0}
        plain = self.root/'retained-header-plain.raw'
        compressed = self.root/'retained-header-compressed.raw'
        projection = self.root/'retained-header.projection'
        plain.write_bytes(figure.stream_encoded(header)+figure.stream_encoded(batch))
        compressed.write_bytes(figure.stream_encoded(dict(header, record_encoding=figure.RAW_RECORD_ENCODING))+
            figure.raw_record_encoded(batch))
        for contract in (None, figure.REPLAY_CONTRACT_V1, figure.REPLAY_CONTRACT_V2, figure.REPLAY_CONTRACT):
            with self.subTest(contract=contract):
                raw = compressed if contract in (figure.REPLAY_CONTRACT_V2, figure.REPLAY_CONTRACT) else plain
                selected = figure.figure_stream_document(raw, self.namespace.read_bytes(), self.wiki,
                    self.date, site, profile_kind=figure.FIGURE_PROFILE_V4)
                if contract is None:
                    selected.pop('replay_contract')
                    selected['generator_sha256'] = figure.LEGACY_TIFF_GENERATOR
                else:
                    selected['replay_contract'] = contract
                    selected['generator_sha256'] = 'a'*64
                if projection.exists():
                    projection.unlink()
                figure.write_projection_stream(projection, selected)
                before = projection.read_bytes()
                verified = figure.verify_stream_document(projection, raw, self.namespace.read_bytes(),
                    self.wiki, self.date, site)
                self.assertEqual(verified, selected)
                self.assertEqual(figure.provider_tsv(verified), figure.provider_tsv(document))
                self.assertEqual(projection.read_bytes(), before)


    def test_legacy_v2_parent_reuse_keeps_contract_authority_and_refuses_plan_mismatch(self):
        self.epoch_defaults()
        args = self.args(links=('A.png',))
        args.figure_profile = figure.FIGURE_PROFILE_V4
        response = self.epoch_response(['ملف:A.png'], figure.FIGURE_CURRENT_CORE, full=True)
        figure.capture_files(args, transport=lambda *_: (200, {}, figure.encoded(response)))
        parent = args.output
        projection_path = parent/figure.ROLES['figure-sizing']
        plan_path = parent/figure.PLAN
        projection = self.stream_document(parent)
        plan = json.loads(plan_path.read_text())
        # Model the older producer's complete v2 output, whose plan predates the
        # v3 marker. Keep the entire valid raw/request/default/SQL lineage.
        projection['replay_contract'] = figure.REPLAY_CONTRACT_V2
        projection['generator_sha256'] = 'a'*64
        plan.pop('replay_contract')
        def publish_fixture(selected, capture_plan):
            projection_path.unlink()
            figure.write_projection_stream(projection_path, selected)
            plan_path.write_bytes(figure.encoded(capture_plan))
            manifest = json.loads((parent/figure.MANIFEST).read_text())
            manifest['artifacts'] = figure.payload(parent)
            manifest['outputs'] = {role: figure.evidence.fingerprint(parent/name)['sha256']
                for role, name in figure.output_roles(parent).items()}
            (parent/figure.MANIFEST).write_bytes(figure.encoded(manifest))
            (parent/figure.COMPLETE).write_bytes(figure.encoded({'schema': figure.SCHEMA,
                'manifest_sha256': figure.digest((parent/figure.MANIFEST).read_bytes())}))
            return manifest
        original = publish_fixture(projection, plan)
        self.assertEqual(figure.verify(parent), original)
        self.assertEqual(figure.verify_stream_document(projection_path,
            parent/figure.ROLES['figure-sizing-raw'], self.namespace.read_bytes(), self.wiki, self.date,
            (parent/figure.ROLES['figure-sizing-site']).read_bytes()), projection)
        before = {path.name: path.read_bytes() for path in parent.iterdir()}
        args.output = self.root/'retained-header-child'
        args.reuse = [parent]
        result = figure.capture_files(args, transport=lambda *_: self.fail('complete parent was refetched'))
        current = self.stream_document(args.output)
        self.assertEqual(current['replay_contract'], figure.REPLAY_CONTRACT)
        self.assertEqual(current['records'], projection['records'])
        self.assertEqual((args.output/figure.PROVIDER).read_bytes(), before[figure.PROVIDER])
        self.assertEqual(figure.verify(args.output), result)
        self.assertEqual(figure.verify(parent), original)
        self.assertEqual({path.name: path.read_bytes() for path in parent.iterdir()}, before)
        for changed in ('projection', 'plan'):
            with self.subTest(changed=changed):
                selected, capture_plan = copy.deepcopy(projection), copy.deepcopy(plan)
                if changed == 'projection':
                    selected['replay_contract'] = figure.REPLAY_CONTRACT
                else:
                    capture_plan['replay_contract'] = figure.REPLAY_CONTRACT
                publish_fixture(selected, capture_plan)
                with self.assertRaisesRegex(ValueError, 'response epoch contract differs from capture plan'):
                    figure.verify(parent)
                for name, data in before.items():
                    (parent/name).write_bytes(data)
        self.assertEqual(figure.verify(parent), original)
        self.assertEqual({path.name: path.read_bytes() for path in parent.iterdir()}, before)


    def registered_epoch(self, value, core=None):
        value = copy.deepcopy(value)
        core = core or figure.FIGURE_REGISTRATION_CORE
        value['query']['general']['git-hash'] = core
        for extension in value['query']['extensions']:
            if extension.get('type') == 'media' and extension['name'] == 'TimedMediaHandler':
                extension['vcs-version'] = (figure.FIGURE_REGISTRATION_TMH if core == figure.FIGURE_REGISTRATION_CORE
                    else figure.FIGURE_GIF_PROFILE['media_extensions']['TimedMediaHandler'])
        return value


    def registered_document(self, batches, anchor=None):
        site = self.registered_epoch(self.site_api, anchor)
        raw = figure.encoded({'schema': figure.RAW_BATCHES_SCHEMA, 'batches': batches})
        document = figure.figure_file_document(raw, self.namespace.read_bytes(), self.wiki,
            self.date, figure.encoded(site), profile_kind=figure.FIGURE_PROFILE_V4)
        return document, raw, figure.encoded(site)


    def test_registered_epoch_mixed_stream_preserves_exact_raw_and_provider(self):
        titles = ['ملف:A.png', 'ملف:B.gif', 'ملف:C.ogg']
        cores = (figure.FIGURE_CURRENT_CORE, figure.FIGURE_RESPONSE_CORE, figure.FIGURE_REGISTRATION_CORE)
        batches = [self.batch(title, self.registered_epoch(self.lean_response([title]), core))
            for title, core in zip(titles, cores)]
        document, aggregate, site = self.registered_document(batches)
        self.assertEqual(document['core_revision'], figure.FIGURE_REGISTRATION_CORE)
        self.assertEqual(document['source_profile']['media_extensions']['TimedMediaHandler'], figure.FIGURE_REGISTRATION_TMH)
        old, _, _ = self.epoch_document([self.batch(title, self.epoch_response([title], figure.FIGURE_CURRENT_CORE)) for title in titles])
        self.assertEqual(document['records'], old['records'])
        self.assertEqual(document['records'][-1]['state'], 'unsupported')
        self.assertEqual(figure.provider_tsv(document), figure.provider_tsv(old))
        self.assertEqual(figure.verify_figure_file_document(document, aggregate, self.namespace.read_bytes(), self.wiki, self.date, site), document)
        header = {'schema': figure.RAW_STREAM_SCHEMA,
            **{key: document[key] for key in ('wiki', 'core_revision', 'namespace_registry_sha256')},
            'records_count': len(document['records']), 'base_batches': 3, 'observed_batches': 0,
            'record_encoding': figure.RAW_RECORD_ENCODING}
        raw = self.root/'registered.raw'; projection = self.root/'registered.projection'
        raw.write_bytes(figure.stream_encoded(header)+b''.join(figure.raw_record_encoded(batch) for batch in batches))
        streamed = figure.figure_stream_document(raw, self.namespace.read_bytes(), self.wiki, self.date, site, profile_kind=figure.FIGURE_PROFILE_V4)
        figure.write_projection_stream(projection, streamed)
        self.assertEqual(figure.verify_stream_document(projection, raw, self.namespace.read_bytes(), self.wiki, self.date, site), streamed)
        self.assertEqual(streamed['records'], document['records'])
        self.assertEqual([json.loads(batch['response'])['query']['general']['git-hash'] for batch in batches], list(cores))
        for contract in (None, figure.REPLAY_CONTRACT_V1, figure.REPLAY_CONTRACT_V2):
            changed = copy.deepcopy(document)
            if contract is None: changed.pop('replay_contract')
            else: changed['replay_contract'] = contract
            with self.subTest(contract=contract), self.assertRaises(ValueError):
                figure.verify_figure_file_document(changed, aggregate, self.namespace.read_bytes(), self.wiki, self.date, site)


    def test_registered_epoch_rejects_core_registration_anchor_and_profile_mismatches(self):
        title = 'ملف:A.png'; response = self.registered_epoch(self.lean_response([title]))
        variants = []
        for key, value in (('git-hash', '0'*40), ('git-hash', figure.FIGURE_CURRENT_CORE), ('lang', 'en'), ('wikiid', 'enwiktionary')):
            bad = copy.deepcopy(response); bad['query']['general'][key] = value; variants.append(bad)
        old_revision = figure.FIGURE_GIF_PROFILE['media_extensions']['TimedMediaHandler']
        for revision in (old_revision, '0'*40):
            bad = copy.deepcopy(response)
            next(x for x in bad['query']['extensions'] if x['name'] == 'TimedMediaHandler')['vcs-version'] = revision
            variants.append(bad)
        for action in ('missing', 'duplicate', 'extra'):
            bad = copy.deepcopy(response); extensions = bad['query']['extensions']
            entry = next(x for x in extensions if x['name'] == 'TimedMediaHandler')
            if action == 'missing': extensions.remove(entry)
            elif action == 'duplicate': extensions.append(copy.deepcopy(entry))
            else: extensions.append(dict(entry, name='Unreviewed media'))
            variants.append(bad)
        for index, bad in enumerate(variants):
            with self.subTest(index=index), self.assertRaises(ValueError):
                self.registered_document([self.batch(title, bad)], figure.FIGURE_CURRENT_CORE)
        document, raw, site = self.registered_document([self.batch(title, response)])
        for changed in ('profile', 'site', 'kind'):
            forged = copy.deepcopy(document); forged_site = site
            if changed == 'profile': forged['source_profile']['media_extensions']['TimedMediaHandler'] = old_revision
            elif changed == 'kind': forged['source_profile']['kind'] = figure.FIGURE_PROFILE_V3
            else:
                value = json.loads(site); value['query']['general']['git-hash'] = figure.FIGURE_CURRENT_CORE
                forged_site = figure.encoded(value); forged['source_profile']['site_raw_sha256'] = figure.digest(forged_site)
            with self.subTest(changed=changed), self.assertRaises(ValueError):
                figure.verify_figure_file_document(forged, raw, self.namespace.read_bytes(), self.wiki, self.date, forged_site)


    def test_registered_epoch_width_and_height_keep_exact_observation_context(self):
        base, observed, supplement = self.svg_observation(figure.FIGURE_CURRENT_CORE)
        observed = self.registered_epoch(observed)
        supplement = dict(supplement, response=figure.encoded(observed).decode())
        document, _, _ = self.registered_document([self.batch(response=base), supplement], figure.FIGURE_CURRENT_CORE)
        self.assertEqual(document['records'][0]['observed_svg_width_px'], 250)
        self.assertEqual(document['core_revision'], figure.FIGURE_CURRENT_CORE)
        response, height_batch = self.height_observation_fixture()
        original_base = {'requests': height_batch['requests'], 'response': figure.encoded(response).decode()}
        response = self.registered_epoch(response)
        height_batch = dict(height_batch, response=figure.encoded(response).decode())
        document, raw, site = self.registered_document([original_base, height_batch])
        observation = document['records'][0]['observed_svg_heights'][0]
        self.assertIs(observation['parse_core_binding_proven'], False)
        self.assertEqual(figure.verify_figure_file_document(document, raw, self.namespace.read_bytes(), self.wiki, self.date, site), document)
        forged = copy.deepcopy(document); forged['records'][0]['observed_svg_heights'][0]['parse_core_binding_proven'] = True
        with self.assertRaises(ValueError):
            figure.verify_figure_file_document(forged, raw, self.namespace.read_bytes(), self.wiki, self.date, site)
        bad = copy.deepcopy(height_batch)
        request = json.loads(bad['observed_svg_occurrences'][0]['request']); request['query']['title'] = 'Different context'
        bad['observed_svg_occurrences'][0]['request'] = figure.encoded(request).decode()
        with self.assertRaises(ValueError): self.registered_document([original_base, bad])


    def test_registered_epoch_tiff_companion_requires_the_actual_batch_registration(self):
        title = 'ملف:F.tif'
        base = self.registered_epoch(self.lean_response([title]))
        companion = self.registered_epoch(self.lean_response([title], metadata_requested=True))
        batch = dict(self.batch(title, base), tiff_metadata_response=figure.encoded(companion).decode())
        document, _, _ = self.registered_document([batch], figure.FIGURE_CURRENT_CORE)
        self.assertEqual(document['records'][0]['state'], 'eligible')
        for changed in (self.registered_epoch(companion, figure.FIGURE_CURRENT_CORE), self.epoch_response([title], figure.FIGURE_REGISTRATION_CORE, full=True)):
            with self.assertRaises(ValueError):
                self.registered_document([dict(batch, tiff_metadata_response=figure.encoded(changed).decode())], figure.FIGURE_CURRENT_CORE)


    def test_registered_epoch_complete_parent_append_preserves_defaults_and_parent(self):
        self.epoch_defaults()
        base, observed, _ = self.svg_observation(figure.FIGURE_CURRENT_CORE)
        args = self.args(); args.figure_profile = figure.FIGURE_PROFILE_V4
        figure.capture_files(args, transport=lambda *_: (200, {}, figure.encoded(base)))
        parent = args.output; before = {path.name: path.read_bytes() for path in parent.iterdir()}
        retained = self.write_svg_observation(self.registered_epoch(observed))
        args.output = self.root/'registered-parent-child'; args.reuse = [parent]; args.reuse_batch = [retained]
        result = figure.capture_files(args, transport=lambda *_: self.fail('authenticated parent or observation was refetched'))
        document = self.stream_document(args.output)
        self.assertEqual(document['core_revision'], figure.FIGURE_CURRENT_CORE)
        self.assertEqual(document['records'][0]['observed_svg_width_px'], 250)
        self.assertEqual((args.output/figure.PROVIDER).read_bytes(), before[figure.PROVIDER])
        self.assertEqual((args.output/figure.ROLES['figure-siteinfo']).read_bytes(), before[figure.ROLES['figure-siteinfo']])
        self.assertEqual({path.name: path.read_bytes() for path in parent.iterdir()}, before)
        self.assertEqual(figure.verify(args.output), result)


    def test_registered_epoch_upfit_parent_append_preserves_exact_context_and_provider(self):
        self.epoch_defaults()
        response, batch = self.height_observation_fixture(((108, 121, 200, 178),))
        args = self.args(); args.figure_profile = figure.FIGURE_PROFILE_V4
        original = figure.capture_files(args, transport=lambda *_: (200, {}, figure.encoded(response)))
        parent = args.output
        before = {path.name: path.read_bytes() for path in parent.iterdir()}
        current = self.registered_epoch(response)
        current_batch = dict(batch, response=figure.encoded(current).decode())
        retained = self.write_height_observation(current, current_batch, original_profile=True)
        args.output = self.root/'registered-upfit-child'; args.reuse = [parent]; args.reuse_batch = [retained]
        result = figure.capture_files(args, transport=lambda *_: self.fail('verified parent or observation was refetched'))
        document = self.stream_document(args.output)
        self.assertEqual(document['core_revision'], figure.FIGURE_CURRENT_CORE)
        self.assertEqual((document['records_count'], document['base_batches'], document['observed_batches']), (1, 1, 1))
        observation = document['records'][0]['observed_svg_heights'][0]
        self.assertEqual((observation['observed_width_px'], observation['observed_height_px']), (178, 200))
        self.assertIs(observation['parse_core_binding_proven'], False)
        self.assertEqual((args.output/figure.PROVIDER).read_bytes(), before[figure.PROVIDER])
        self.assertEqual((args.output/figure.ROLES['figure-siteinfo']).read_bytes(), before[figure.ROLES['figure-siteinfo']])
        self.assertEqual({path.name: path.read_bytes() for path in parent.iterdir()}, before)
        self.assertEqual(figure.verify(parent), original)
        self.assertEqual(figure.verify(args.output), result)
        aggregate, raw, site = self.registered_document([
            {'requests': batch['requests'], 'response': figure.encoded(response).decode()}, current_batch],
            figure.FIGURE_CURRENT_CORE)
        for contract in (None, figure.REPLAY_CONTRACT_V1, figure.REPLAY_CONTRACT_V2):
            legacy = copy.deepcopy(aggregate)
            if contract is None: legacy.pop('replay_contract')
            else: legacy['replay_contract'] = contract
            with self.subTest(legacy_contract=contract), self.assertRaises(ValueError):
                figure.verify_figure_file_document(legacy, raw, self.namespace.read_bytes(), self.wiki, self.date, site)
        for label, bad in (('wrong_registration', self.epoch_response(batch['requests'], figure.FIGURE_REGISTRATION_CORE)),
                           ('unproved_height_epoch', self.registered_epoch(response, figure.FIGURE_RESPONSE_CORE))):
            changed = dict(current_batch, response=figure.encoded(bad).decode())
            with self.subTest(changed=label), self.assertRaises(ValueError):
                self.registered_document([{'requests': batch['requests'], 'response': figure.encoded(response).decode()}, changed])




    def test_closed_prefix_membership_keeps_initial_hashes_without_payload_rehash(self):
        _, proof_path, _ = self.make_oversize_prefix()
        root = Path(json.loads(proof_path.read_text())['source_root'])
        raw_path = root / figure.ROLES['figure-sizing-raw']
        with patch.object(figure, 'prefix_identity', wraps=figure.prefix_identity) as hashes, \
                patch.object(figure, 'payload', side_effect=AssertionError('membership rehashed payload')):
            prefix = figure.read_closed_prefix(proof_path, {})
        self.assertEqual(prefix['batch_count'], 1)
        self.assertEqual([row['requested_file'] for row in prefix['document']['records']],
                         ['ملف:A.svg', 'ملف:B.svg'])
        self.assertEqual(sum(Path(call.args[0]) == raw_path for call in hashes.call_args_list), 1)
        raw = raw_path.read_bytes()
        raw_path.write_bytes(raw + b' ')
        with self.assertRaisesRegex(ValueError, 'artifact changed'):
            figure.read_closed_prefix(proof_path, {})

    def test_closed_prefix_membership_rejects_extra_missing_symlink_and_nonregular_members(self):
        _, proof_path, _ = self.make_oversize_prefix()
        root = Path(json.loads(proof_path.read_text())['source_root'])
        extra = root / 'unexpected-member'
        raw_path = root / figure.ROLES['figure-sizing-raw']
        for kind in ('regular', 'directory', 'symlink', 'fifo'):
            with self.subTest(kind=kind):
                if kind == 'regular':
                    extra.write_bytes(b'extra')
                elif kind == 'directory':
                    extra.mkdir()
                elif kind == 'symlink':
                    extra.symlink_to(raw_path)
                else:
                    figure.os.mkfifo(extra)
                try:
                    with self.assertRaises(ValueError):
                        figure.read_closed_prefix(proof_path, {})
                finally:
                    extra.rmdir() if kind == 'directory' else extra.unlink()
        moved = self.root / 'held-prefix-raw.json'
        raw_path.rename(moved)
        try:
            with self.assertRaises((ValueError, OSError)):
                figure.read_closed_prefix(proof_path, {})
            raw_path.symlink_to(moved)
            with self.assertRaisesRegex(ValueError, 'regular, non-symlink'):
                figure.read_closed_prefix(proof_path, {})
            raw_path.unlink()
        finally:
            moved.rename(raw_path)

    def test_closed_prefix_membership_keeps_end_guard_for_late_content_and_inode_changes(self):
        _, proof_path, _ = self.make_oversize_prefix()
        root = Path(json.loads(proof_path.read_text())['source_root'])
        raw_path = root / figure.ROLES['figure-sizing-raw']
        raw = raw_path.read_bytes()
        original = figure.file_records
        for kind in ('content', 'replacement'):
            with self.subTest(kind=kind):
                def mutate_after_replay(*args, **kwargs):
                    result = original(*args, **kwargs)
                    if kind == 'content':
                        raw_path.write_bytes(raw + b' ')
                    else:
                        replacement = self.root / 'replacement-prefix-raw.json'
                        replacement.write_bytes(raw)
                        replacement.replace(raw_path)
                    return result
                with patch.object(figure, 'file_records', side_effect=mutate_after_replay):
                    with self.assertRaisesRegex(ValueError, 'changed during replay'):
                        figure.read_closed_prefix(proof_path, {})
                raw_path.write_bytes(raw)

    def test_closed_prefix_membership_keeps_final_cache_guard_and_fresh_authentication(self):
        _, proof_path, _ = self.make_oversize_prefix()
        root = Path(json.loads(proof_path.read_text())['source_root'])
        cache = {}
        prefix = figure.read_closed_prefix(proof_path, cache)
        receipt = root / 'file-metadata.response-000002-01.receipt.json'
        raw = receipt.read_bytes()
        receipt.write_bytes(raw + b' ')
        with self.assertRaisesRegex(ValueError, 'changed during use'):
            figure.check_prefix_cache(cache)
        with self.assertRaisesRegex(ValueError, 'artifact changed'):
            figure.read_closed_prefix(proof_path, {})
        receipt.write_bytes(raw)
        raw_path = prefix['raw_path']
        with patch.object(figure, 'prefix_identity', wraps=figure.prefix_identity) as hashes:
            fresh = figure.read_closed_prefix(proof_path, {})
        self.assertEqual(fresh['document'], prefix['document'])
        self.assertEqual(sum(Path(call.args[0]) == raw_path for call in hashes.call_args_list), 1)


    @staticmethod
    def retained_tallrik_info():
        return json.loads((Path(__file__).parent/'testdata/sr-tallrik-default-page/info.json').read_text())

    def default_page_tiff_response(self):
        response = self.decimal_tiff_response()
        actual = self.retained_tallrik_info()
        image = response['query']['pages'][0]['imageinfo'][0]
        image.update(width=actual['width'], height=actual['height'], pagecount=actual['pagecount'], metadata=actual['metadata'])
        return response

    def test_tiff_default_page_uses_complete_retained_first_page_axes(self):
        image = self.retained_tallrik_info()
        self.assertEqual((image['width'], image['height'], image['pagecount']), (5616, 3744, 2))
        self.assertEqual(image['sha1'], '753d28feb48496362ce2eaf285c85cba5b51f0f5')
        figure._figure_tiff_default_page_axes(image, 5616, 3744)
        with self.assertRaises(ValueError):
            figure._figure_tiff_page_axes(image, 5616, 3744, allow_decimal_axes=True)
        for mode in ('count-string', 'count-mismatch', 'first-not-one', 'last-mismatch', 'duplicate-page', 'missing-page', 'page-number', 'wrong-first-axis', 'zero-later-axis', 'duplicate-width', 'error'):
            with self.subTest(mode=mode):
                changed = copy.deepcopy(image)
                metadata_rows = changed['metadata']
                field = lambda name: next(row for row in metadata_rows if row['name'] == name)
                pages = field('page_data')['value']
                axis = lambda page, name: next(row for row in pages[page]['value'] if row['name'] == name)
                if mode == 'count-string': changed['pagecount'] = '2'
                elif mode == 'count-mismatch': field('page_count')['value'] = 1
                elif mode == 'first-not-one': field('first_page')['value'] = 2
                elif mode == 'last-mismatch': field('last_page')['value'] = 3
                elif mode == 'duplicate-page': pages[1]['name'] = 1
                elif mode == 'missing-page': pages.pop()
                elif mode == 'page-number': axis(1, 'page')['value'] = 1
                elif mode == 'wrong-first-axis': axis(0, 'width')['value'] = 5615
                elif mode == 'zero-later-axis': axis(1, 'height')['value'] = 0
                elif mode == 'duplicate-width': pages[0]['value'].append(copy.deepcopy(axis(0, 'width')))
                else: metadata_rows.append({'name':'errors', 'value':[]})
                with self.assertRaises(ValueError): figure._figure_tiff_default_page_axes(changed, 5616, 3744)
        # The other page may have different axes; only the absent-option first
        # page determines this grant, not a guessed common box for all pages.
        pages = next(row['value'] for row in image['metadata'] if row['name'] == 'page_data')
        next(row for row in pages[1]['value'] if row['name'] == 'width')['value'] = '123'
        figure._figure_tiff_default_page_axes(image, 5616, 3744)

    def test_tiff_default_page_replay_is_separate_from_all_old_eligible_facts(self):
        response = self.default_page_tiff_response(); site = figure.encoded(response)
        raw = figure.encoded({'schema':figure.RAW_BATCHES_SCHEMA, 'batches':[self.batch('ملف:B.tif', response)]})
        options = dict(profile_kind=figure.FIGURE_PROFILE_V4)
        legacy = figure.figure_file_document(raw, self.namespace.read_bytes(), self.wiki, self.date, site,
            allow_default_tiff_page=False, **options)
        self.assertEqual(legacy['records'][0]['state'], 'unsupported')
        for contract in (None, figure.REPLAY_CONTRACT_V1, figure.REPLAY_CONTRACT_V2, figure.REPLAY_CONTRACT_V3, figure.REPLAY_CONTRACT_V4):
            document = copy.deepcopy(legacy)
            if contract is None: document.pop('replay_contract')
            else: document['replay_contract'] = contract
            self.assertEqual(figure.verify_figure_file_document(document, raw, self.namespace.read_bytes(), self.wiki, self.date, site), document)
            for state in ('eligible', 'tiff_default_page'):
                wrong = copy.deepcopy(document); wrong['records'][0]['state'] = state
                with self.assertRaisesRegex(ValueError, 'exact batch replay'):
                    figure.verify_figure_file_document(wrong, raw, self.namespace.read_bytes(), self.wiki, self.date, site)
        current = figure.figure_file_document(raw, self.namespace.read_bytes(), self.wiki, self.date, site, **options)
        self.assertEqual(current['replay_contract'], 'wikidict.figure-files-replay.v6')
        self.assertEqual(current['records'], [dict(legacy['records'][0], state='tiff_default_page')])
        self.assertEqual(figure.verify_figure_file_document(current, raw, self.namespace.read_bytes(), self.wiki, self.date, site), current)
        self.assertEqual(b''.join(figure.provider_chunks(current)), b''.join(figure.provider_chunks(legacy)))
        wrong = copy.deepcopy(current); wrong['records'][0]['state'] = 'eligible'
        with self.assertRaisesRegex(ValueError, 'exact batch replay'):
            figure.verify_figure_file_document(wrong, raw, self.namespace.read_bytes(), self.wiki, self.date, site)

    def test_tiff_default_page_stream_parent_keeps_old_bytes_and_provider(self):
        args = self.args(links=('B.tif',)); args.figure_profile = figure.FIGURE_PROFILE_V4
        records = figure.file_records
        def old_records(*values, **options):
            options['allow_default_tiff_page'] = False
            return records(*values, **options)
        with patch.object(figure, 'file_records', side_effect=old_records):
            manifest = figure.capture_files(args, transport=lambda *_:(200, {}, figure.encoded(self.default_page_tiff_response())), sleep=lambda _:None)
        parent = args.output; path = parent/figure.ROLES['figure-sizing']
        document = self.stream_document(parent); self.assertEqual(document['records'][0]['state'], 'unsupported')
        document['replay_contract'] = figure.REPLAY_CONTRACT_V4
        path.unlink(); figure.write_projection_stream(path, document)
        plan = json.loads((parent/figure.PLAN).read_bytes()); plan['replay_contract'] = figure.REPLAY_CONTRACT_V4
        (parent/figure.PLAN).write_bytes(figure.encoded(plan))
        manifest['outputs']['figure-sizing'] = figure.digest(path.read_bytes()); manifest['artifacts'] = figure.payload(parent)
        (parent/figure.MANIFEST).write_bytes(figure.encoded(manifest))
        (parent/figure.COMPLETE).write_bytes(figure.encoded(dict(schema=figure.SCHEMA, manifest_sha256=figure.digest((parent/figure.MANIFEST).read_bytes()))))
        before = {p.name:p.read_bytes() for p in parent.iterdir()}
        self.assertEqual(figure.verify(parent), manifest)
        args.output = self.root/'default-page-successor'; args.reuse = [parent]; args.reuse_batch = []
        successor = figure.capture_files(args, transport=lambda *_:self.fail('Retained TIFF default-page parent made HTTP'))
        current = self.stream_document(args.output)
        self.assertEqual(current['records'], [dict(document['records'][0], state='tiff_default_page')])
        self.assertEqual((args.output/figure.PROVIDER).read_bytes(), (parent/figure.PROVIDER).read_bytes())
        self.assertEqual(figure.verify(args.output), successor)
        self.assertEqual(before, {p.name:p.read_bytes() for p in parent.iterdir()})

    def test_peili_default_page_keeps_actual_identity_axes_and_old_singleton_refusal(self):
        image = json.loads((Path(__file__).parent/'testdata/th-peili-default-page/info.json').read_text())
        self.assertEqual((image['sha1'], image['timestamp']),
            ('e7d13180d4c41c4be04563c24a85628ab60e570a', '2014-11-21T01:36:36Z'))
        self.assertEqual((image['width'], image['height'], image['pagecount']), (2414, 3570, 2))
        figure._figure_tiff_default_page_axes(image, 2414, 3570)
        for decimal in (False, True):
            with self.assertRaises(ValueError):
                figure._figure_tiff_page_axes(image, 2414, 3570, allow_decimal_axes=decimal)
        for width, height in ((190, 281), (3570, 2414)):
            with self.assertRaises(ValueError):
                figure._figure_tiff_default_page_axes(image, width, height)
        changed = copy.deepcopy(image)
        pages = next(row['value'] for row in changed['metadata'] if row['name'] == 'page_data')
        next(row for row in pages[1]['value'] if row['name'] == 'width')['value'] = 123
        next(row for row in pages[1]['value'] if row['name'] == 'height')['value'] = 456
        figure._figure_tiff_default_page_axes(changed, 2414, 3570)
        next(row for row in pages[0]['value'] if row['name'] == 'width')['value'] = 123
        with self.assertRaises(ValueError):
            figure._figure_tiff_default_page_axes(changed, 2414, 3570)


    def hu_epoch(self, value):
        value = self.registered_epoch(value)
        value['query']['general']['git-hash'] = figure.FIGURE_LATEST_REGISTRATION_CORE
        return value

    def test_latest_registered_epoch_preserves_mixed_missing_facts_and_stream(self):
        titles = ['\u0645\u0644\u0641:Old.png', '\u0645\u0644\u0641:Missing.ogg']
        old = self.batch(titles[0], self.epoch_response([titles[0]], figure.FIGURE_CURRENT_CORE))
        missing = self.hu_epoch(self.logged_query_response([titles[1]]))
        batches = [old, self.batch(titles[1], missing)]
        for anchor in (figure.FIGURE_CURRENT_CORE, figure.FIGURE_LATEST_REGISTRATION_CORE):
            with self.subTest(anchor=anchor):
                site = self.registered_epoch(self.site_api, anchor) if anchor == figure.FIGURE_CURRENT_CORE else self.hu_epoch(self.site_api)
                site = figure.encoded(site)
                raw = figure.encoded({'schema': figure.RAW_BATCHES_SCHEMA, 'batches': batches})
                doc = figure.figure_file_document(raw, self.namespace.read_bytes(), self.wiki, self.date, site, profile_kind=figure.FIGURE_PROFILE_V4)
                self.assertEqual(doc['replay_contract'], figure.REPLAY_CONTRACT)
                self.assertEqual([(x['requested_file'], x['state'], x['batch']) for x in doc['records']],
                    [(titles[1], 'missing', 1), (titles[0], 'eligible', 0)])
                self.assertEqual(doc['records'][0]['original_width'], 0)
                self.assertIn((titles[1]+'\t0\t0\t0\t-\t-\n').encode(), figure.provider_tsv(doc))
                self.assertEqual(figure.verify_figure_file_document(doc, raw, self.namespace.read_bytes(), self.wiki, self.date, site), doc)
                header = {'schema': figure.RAW_STREAM_SCHEMA,
                    **{key: doc[key] for key in ('wiki', 'core_revision', 'namespace_registry_sha256')},
                    'records_count': 2, 'base_batches': 2, 'observed_batches': 0,
                    'record_encoding': figure.RAW_RECORD_ENCODING}
                raw_path = self.root/('latest-'+anchor+'.raw'); projection = self.root/('latest-'+anchor+'.projection')
                raw_path.write_bytes(figure.stream_encoded(header)+b''.join(figure.raw_record_encoded(batch) for batch in batches))
                streamed = figure.figure_stream_document(raw_path, self.namespace.read_bytes(), self.wiki, self.date, site, profile_kind=figure.FIGURE_PROFILE_V4)
                figure.write_projection_stream(projection, streamed)
                self.assertEqual(figure.verify_stream_document(projection, raw_path, self.namespace.read_bytes(), self.wiki, self.date, site), streamed)
                self.assertEqual(streamed['records'], doc['records'])
                for contract in (None, figure.REPLAY_CONTRACT_V1, figure.REPLAY_CONTRACT_V2):
                    bad = copy.deepcopy(doc)
                    if contract is None: bad.pop('replay_contract')
                    else: bad['replay_contract'] = contract
                    with self.assertRaises(ValueError):
                        figure.verify_figure_file_document(bad, raw, self.namespace.read_bytes(), self.wiki, self.date, site)

    def test_latest_registered_epoch_refuses_changed_pairs_context_and_unproved_authority(self):
        title = '\u0645\u0644\u0641:Missing.ogg'
        response = self.hu_epoch(self.logged_query_response([title]))
        changes = []
        for key, value in (('git-hash', '0'*40), ('git-hash', figure.FIGURE_CURRENT_CORE), ('lang', 'en'), ('wikiid', 'enwiktionary')):
            bad = copy.deepcopy(response); bad['query']['general'][key] = value; changes.append(bad)
        for revision in (figure.FIGURE_GIF_PROFILE['media_extensions']['TimedMediaHandler'], '0'*40):
            bad = copy.deepcopy(response)
            next(x for x in bad['query']['extensions'] if x['name'] == 'TimedMediaHandler')['vcs-version'] = revision
            changes.append(bad)
        bad = copy.deepcopy(response); bad['query']['extensions'].append(copy.deepcopy(bad['query']['extensions'][0])); changes.append(bad)
        bad = copy.deepcopy(response); bad['query']['pages'][0]['imagerepository'] = 'shared'; changes.append(bad)
        for index, bad in enumerate(changes):
            with self.subTest(index=index), self.assertRaises(ValueError):
                self.registered_document([self.batch(title, bad)], figure.FIGURE_CURRENT_CORE)
        latest = figure.FIGURE_LATEST_REGISTRATION_CORE
        self.assertNotIn(latest, figure.FIGURE_SOURCE_PROFILES)
        self.assertIsNone(figure.figure_profile(latest, figure.FIGURE_PROFILE_V3))
        positive = self.hu_epoch(self.lean_response(['\u0645\u0644\u0641:Present.ogg']))
        doc, _, _ = self.registered_document([self.batch('\u0645\u0644\u0641:Present.ogg', positive)], figure.FIGURE_CURRENT_CORE)
        self.assertEqual(doc['records'][0]['state'], 'unsupported')
        original, height = self.height_observation_fixture()
        height = dict(height, response=figure.encoded(self.hu_epoch(original)).decode())
        with self.assertRaises(ValueError):
            self.registered_document([self.batch(response=original), height], figure.FIGURE_CURRENT_CORE)

    def test_latest_registered_epoch_normal_parent_append_keeps_all_old_facts_and_v3(self):
        args, parent, before, _ = self.logged_query_parent()
        names = ['\u0645\u0644\u0641:Missing-%d.ogg'%index for index in range(8)]
        args.log[-1].write_text(''.join('warning: file metadata missing: title='+name+'\n' for name in names))
        response = self.hu_epoch(self.logged_query_response(names))
        response['query']['pages'] = [{'title': name, 'ns': 6, 'missing': True, 'imagerepository': ''} for name in names]
        retained = self.write_normal_retained('latest-missing-eight', response, names)
        args.reuse_batch = [retained]
        result = figure.capture_files(args, transport=lambda *_: self.fail('Verified parent or retained files refetched'))
        old = self.stream_document(parent); new = self.stream_document(args.output)
        old_rows = {row['requested_file']: row for row in old['records']}
        new_rows = {row['requested_file']: row for row in new['records']}
        self.assertEqual({name:new_rows[name] for name in old_rows}, old_rows)
        self.assertEqual(set(new_rows)-set(old_rows), set(names))
        self.assertTrue(all(new_rows[name]['state'] == 'missing' for name in names))
        self.assertEqual(new['replay_contract'], figure.REPLAY_CONTRACT)
        self.assertEqual(new['core_revision'], old['core_revision'])
        self.assertEqual(new['source_profile'], old['source_profile'])
        old_provider = before[figure.PROVIDER].splitlines()
        new_provider = (args.output/figure.PROVIDER).read_bytes().splitlines()
        self.assertTrue(set(old_provider).issubset(new_provider))
        old_raw = list(figure.stream_values(parent/figure.ROLES['figure-sizing-raw'], figure.RAW_STREAM_SCHEMA))
        new_raw = list(figure.stream_values(args.output/figure.ROLES['figure-sizing-raw'], figure.RAW_STREAM_SCHEMA))
        self.assertEqual(new_raw[1:len(old_raw)], old_raw[1:])
        self.assertEqual((args.output/figure.ROLES['figure-siteinfo']).read_bytes(), before[figure.ROLES['figure-siteinfo']])
        self.assertEqual(before, {path.name:path.read_bytes() for path in parent.iterdir()})
        self.assertEqual(figure.verify(args.output), result)


    def wmf4_epoch(self, response):
        response = copy.deepcopy(response)
        response['query']['general']['git-hash'] = figure.FIGURE_WMF4_CORE
        revisions = figure.FIGURE_WMF4_PROFILE['media_extensions']
        for extension in response['query']['extensions']:
            if extension.get('type') == 'media':
                extension['vcs-version'] = revisions[extension['name']]
        return response

    def wmf4_document(self, batches, anchor=None):
        site = (self.wmf4_epoch(self.site_api) if anchor == figure.FIGURE_WMF4_CORE
                else self.registered_epoch(self.site_api, figure.FIGURE_CURRENT_CORE))
        raw = figure.encoded({'schema': figure.RAW_BATCHES_SCHEMA, 'batches': batches})
        site = figure.encoded(site)
        document = figure.figure_file_document(raw, self.namespace.read_bytes(), self.wiki,
            self.date, site, profile_kind=figure.FIGURE_PROFILE_V4)
        return document, raw, site

    def test_byte_equal_wmf4_core_preserves_real_echo_parent_facts_and_provider(self):
        core = 'bb3b6755d485f60478c87c907f0557c53117142d'
        self.assertIs(figure.figure_profile(core, figure.FIGURE_PROFILE_V4), figure.FIGURE_WMF4_PROFILE)
        original = self.wmf4_epoch
        def observed(response):
            value = original(response)
            value['query']['general']['git-hash'] = core
            return value
        with patch.object(self, 'wmf4_epoch', side_effect=observed):
            self.test_wmf4_normal_parent_svg_append_preserves_all_old_facts_and_provider()
        batches = list(figure.stream_values(self.root/'wmf4-parent-child'/figure.ROLES['figure-sizing-raw'], figure.RAW_STREAM_SCHEMA))
        self.assertEqual(json.loads(batches[-1]['response'])['query']['general']['git-hash'], core)

    def test_byte_equal_wmf4_core_refuses_unproved_neighbors_profiles_and_registration(self):
        core = 'bb3b6755d485f60478c87c907f0557c53117142d'
        self.assertEqual(figure.FIGURE_WMF4_CORES, (figure.FIGURE_WMF4_CORE, core,
                         '93f1cdcc57c0891fb208c960a9f7fff6ca1ca35c'))
        self.assertIsNone(figure.figure_profile(core, figure.FIGURE_PROFILE_V3))
        self.assertEqual(figure.figure_profile(core, figure.FIGURE_PROFILE_V5)['webp_handler_core_revision'], figure.FIGURE_CURRENT_CORE)
        title = 'ملف:Example.svg'
        good = self.wmf4_epoch(self.epoch_response([title], figure.FIGURE_CURRENT_CORE))
        good['query']['general']['git-hash'] = core
        for defect in ('unknown-core', *figure.FIGURE_WMF4_PROFILE['media_extensions']):
            bad = copy.deepcopy(good)
            if defect == 'unknown-core': bad['query']['general']['git-hash'] = '0'*40
            else:
                for row in bad['query']['extensions']:
                    if row['name'] == defect: row['vcs-version'] = '0'*40
            with self.subTest(defect=defect), self.assertRaises(ValueError):
                self.wmf4_document([self.batch(title, bad)])

    def test_wmf4_registered_svg_width_preserves_mixed_epochs_and_stream(self):
        base, observed, supplement = self.svg_observation(figure.FIGURE_CURRENT_CORE)
        observed = self.wmf4_epoch(observed)
        supplement = dict(supplement, response=figure.encoded(observed).decode())
        batches = [self.batch(response=base), supplement]
        for anchor in (figure.FIGURE_CURRENT_CORE, figure.FIGURE_WMF4_CORE):
            with self.subTest(anchor=anchor):
                doc, raw, site = self.wmf4_document(batches, anchor)
                self.assertEqual(doc['replay_contract'], figure.REPLAY_CONTRACT)
                self.assertEqual(doc['core_revision'], anchor)
                row = doc['records'][0]
                self.assertEqual((row['state'], row['batch'], row['observed_batch'], row['observed_svg_width_px']),
                                 ('eligible', 0, 1, 250))
                self.assertEqual(figure.verify_figure_file_document(doc, raw, self.namespace.read_bytes(), self.wiki, self.date, site), doc)
                header = {'schema': figure.RAW_STREAM_SCHEMA,
                    **{key: doc[key] for key in ('wiki', 'core_revision', 'namespace_registry_sha256')},
                    'records_count': 1, 'base_batches': 1, 'observed_batches': 1,
                    'record_encoding': figure.RAW_RECORD_ENCODING}
                raw_path = self.root/('wmf4-'+anchor+'.raw')
                projection = self.root/('wmf4-'+anchor+'.projection')
                raw_path.write_bytes(figure.stream_encoded(header)+b''.join(figure.raw_record_encoded(batch) for batch in batches))
                streamed = figure.figure_stream_document(raw_path, self.namespace.read_bytes(), self.wiki, self.date, site,
                    profile_kind=figure.FIGURE_PROFILE_V4)
                figure.write_projection_stream(projection, streamed)
                self.assertEqual(figure.verify_stream_document(projection, raw_path, self.namespace.read_bytes(), self.wiki, self.date, site), streamed)
                self.assertEqual(streamed['records'], doc['records'])
                for contract in (None, figure.REPLAY_CONTRACT_V1, figure.REPLAY_CONTRACT_V2):
                    bad = copy.deepcopy(doc)
                    if contract is None: bad.pop('replay_contract')
                    else: bad['replay_contract'] = contract
                    with self.subTest(contract=contract), self.assertRaises(ValueError):
                        figure.verify_figure_file_document(bad, raw, self.namespace.read_bytes(), self.wiki, self.date, site)

    def test_wmf4_registered_epoch_refuses_changed_pairs_and_unproved_profiles(self):
        title = '\u0645\u0644\u0641:Present.png'
        response = self.wmf4_epoch(self.epoch_response([title], figure.FIGURE_CURRENT_CORE))
        variants = []
        for name in figure.FIGURE_WMF4_PROFILE['media_extensions']:
            for revision in (figure.FIGURE_GIF_PROFILE['media_extensions'][name], '0'*40):
                bad = copy.deepcopy(response)
                next(x for x in bad['query']['extensions'] if x['name'] == name)['vcs-version'] = revision
                variants.append(bad)
        for key, value in (('git-hash', figure.FIGURE_CURRENT_CORE), ('git-hash', '0'*40), ('lang', 'en'), ('wikiid', 'enwiktionary')):
            bad = copy.deepcopy(response); bad['query']['general'][key] = value; variants.append(bad)
        for mode in ('missing', 'duplicate', 'extra'):
            bad = copy.deepcopy(response); extensions = bad['query']['extensions']
            media = next(x for x in extensions if x.get('type') == 'media')
            if mode == 'missing': extensions.remove(media)
            elif mode == 'duplicate': extensions.append(copy.deepcopy(media))
            else: extensions.append(dict(media, name='Unknown media handler'))
            variants.append(bad)
        for index, bad in enumerate(variants):
            with self.subTest(index=index), self.assertRaises(ValueError):
                self.wmf4_document([self.batch(title, bad)])
        doc, raw, site = self.wmf4_document([self.batch(title, response)], figure.FIGURE_WMF4_CORE)
        for key, value in (('kind', figure.FIGURE_PROFILE_V3), ('kind', 'wikimedia-imagehandler-v5'),
                           ('bitmap_handler_sha256', '0'*64)):
            bad = copy.deepcopy(doc); bad['source_profile'][key] = value
            with self.subTest(profile=key, value=value), self.assertRaises(ValueError):
                figure.verify_figure_file_document(bad, raw, self.namespace.read_bytes(), self.wiki, self.date, site)
        self.assertIsNone(figure.figure_profile(figure.FIGURE_WMF4_CORE, figure.FIGURE_PROFILE_V3))
        self.assertEqual(figure.figure_profile(figure.FIGURE_WMF4_CORE, figure.FIGURE_PROFILE_V5)['webp_handler_core_revision'], figure.FIGURE_CURRENT_CORE)
        base, height = self.height_observation_fixture()
        height = dict(height, response=figure.encoded(self.wmf4_epoch(base)).decode())
        with self.assertRaises(ValueError): self.wmf4_document([self.batch(response=base), height])

    def test_wmf4_retains_reference_v4_scope_and_unsupported_webp_audio(self):
        self.assertEqual({k:v for k,v in figure.FIGURE_WMF4_PROFILE.items() if k != 'media_extensions'},
                         {k:v for k,v in figure.FIGURE_GIF_PROFILE.items() if k != 'media_extensions'})
        self.assertNotIn('image/webp', figure.FIGURE_WMF4_PROFILE['handler_families'])
        title = '\u0645\u0644\u0641:Present.png'
        for mime, mediatype in (('image/webp', 'BITMAP'), ('audio/ogg', 'AUDIO')):
            response = self.wmf4_epoch(self.epoch_response([title], figure.FIGURE_CURRENT_CORE))
            response['query']['pages'][0]['imageinfo'][0].update(mime=mime, mediatype=mediatype)
            doc, raw, site = self.wmf4_document([self.batch(title, response)], figure.FIGURE_WMF4_CORE)
            self.assertEqual(doc['records'][0]['state'], 'unsupported')
            self.assertEqual(figure.verify_figure_file_document(doc, raw, self.namespace.read_bytes(), self.wiki, self.date, site), doc)
            bad = copy.deepcopy(doc); bad['records'][0]['state'] = 'eligible'
            with self.assertRaises(ValueError):
                figure.verify_figure_file_document(bad, raw, self.namespace.read_bytes(), self.wiki, self.date, site)

    def test_wmf4_normal_parent_svg_append_preserves_all_old_facts_and_provider(self):
        self.epoch_defaults()
        base, observed, _ = self.svg_observation(figure.FIGURE_CURRENT_CORE)
        args = self.args(); args.figure_profile = figure.FIGURE_PROFILE_V4
        figure.capture_files(args, transport=lambda *_: (200, {}, figure.encoded(base)))
        parent = args.output; before = {path.name: path.read_bytes() for path in parent.iterdir()}
        old = self.stream_document(parent)
        retained = self.write_svg_observation(self.wmf4_epoch(observed))
        args.output = self.root/'wmf4-parent-child'; args.reuse = [parent]; args.reuse_batch = [retained]
        result = figure.capture_files(args, transport=lambda *_: self.fail('Authenticated parent or observation refetched'))
        new = self.stream_document(args.output)
        expected = copy.deepcopy(old['records'])
        expected[0].update(observed_svg_width_px=250, observed_batch=1)
        self.assertEqual(new['records'], expected)
        self.assertEqual((new['core_revision'], new['source_profile']), (old['core_revision'], old['source_profile']))
        self.assertEqual((new['base_batches'], new['observed_batches'], new['replay_contract']),
                         (1, 1, figure.REPLAY_CONTRACT))
        self.assertEqual((args.output/figure.PROVIDER).read_bytes(), before[figure.PROVIDER])
        self.assertEqual((args.output/figure.ROLES['figure-siteinfo']).read_bytes(), before[figure.ROLES['figure-siteinfo']])
        self.assertEqual(before, {path.name: path.read_bytes() for path in parent.iterdir()})
        self.assertEqual(figure.verify(args.output), result)



class CaptureParentReplayTests(unittest.TestCase):
    def setUp(self):
        self.fixture = FigureFileTests()
        self.fixture.setUp()
        self.addCleanup(self.fixture.doCleanups)

    def successor(self, name):
        args, observation, _ = self.fixture.complete_stream_fixture()
        parent = args.output
        args.output = self.fixture.root / name
        args.reuse = [parent]
        args.reuse_batch = [observation]
        return args, parent

    def test_capture_parent_proof_rejects_late_member_content_inode_and_membership_changes(self):
        args, parent = self.successor('changed-parent')
        original_verify = figure.verify
        target = parent / figure.PROVIDER
        original = target.read_bytes()
        for number, mutation in enumerate(('content', 'inode', 'extra', 'missing')):
            args.output = self.fixture.root / ('changed-parent-' + str(number))
            changed = False
            def verify(root, *values, **options):
                nonlocal changed
                if Path(root) == args.output and not options.get('require_complete', True):
                    self.assertIn(('complete-stream', str(parent / figure.MANIFEST)), options['retained_cache'])
                    changed = True
                    if mutation == 'content':
                        target.write_bytes(original + b'changed')
                    elif mutation == 'inode':
                        replacement = self.fixture.root / 'replacement-provider'
                        replacement.write_bytes(original)
                        replacement.replace(target)
                    elif mutation == 'extra':
                        (parent / 'unexpected-member').write_bytes(b'extra')
                    else:
                        target.unlink()
                return original_verify(root, *values, **options)
            try:
                with self.subTest(mutation=mutation), patch.object(figure, 'verify', side_effect=verify):
                    with self.assertRaisesRegex(ValueError, 'changed'):
                        figure.capture_files(args, transport=lambda *_:self.fail('retained parent refetched'))
                self.assertTrue(changed)
                self.assertFalse((args.output / figure.COMPLETE).exists())
                self.assertTrue((args.output / 'figure-failure-0001.json').exists())
            finally:
                target.write_bytes(original)
                extra = parent / 'unexpected-member'
                if extra.exists():
                    extra.unlink()

    def test_capture_parent_proof_keeps_full_rehashed_destination_semantic_validation(self):
        args, parent = self.successor('rehashed-destination')
        original_verify = figure.verify
        injected = False
        def verify(root, *values, **options):
            nonlocal injected
            if Path(root) == args.output and not options.get('require_complete', True):
                self.assertIn(('complete-stream', str(parent / figure.MANIFEST)), options['retained_cache'])
                document = self.fixture.stream_document(args.output)
                document['records'][0]['original_width'] += 1
                path = args.output / figure.ROLES['figure-sizing']
                path.unlink()
                figure.write_projection_stream(path, document)
                manifest = json.loads((args.output / figure.MANIFEST).read_bytes())
                manifest['artifacts'] = figure.payload(args.output)
                manifest['outputs']['figure-sizing'] = figure.digest(path.read_bytes())
                (args.output / figure.MANIFEST).write_bytes(figure.encoded(manifest))
                injected = True
            return original_verify(root, *values, **options)
        with patch.object(figure, 'verify', side_effect=verify):
            with self.assertRaisesRegex(ValueError, 'projection stream record differs from exact raw replay'):
                figure.capture_files(args, transport=lambda *_:self.fail('retained parent refetched'))
        self.assertTrue(injected)
        self.assertFalse((args.output / figure.COMPLETE).exists())
        self.assertTrue((args.output / 'figure-failure-0001.json').exists())

    def test_capture_parent_proof_does_not_escape_failed_or_successful_invocation(self):
        args, parent = self.successor('failed-final-verification')
        original_verify = figure.verify
        class FinalFailure(RuntimeError):
            pass
        def fail_final(root, *values, **options):
            result = original_verify(root, *values, **options)
            if Path(root) == args.output:
                raise FinalFailure('injected after full destination verification')
            return result
        with patch.object(figure, 'verify', side_effect=fail_final):
            with self.assertRaisesRegex(FinalFailure, 'after full destination'):
                figure.capture_files(args, transport=lambda *_:self.fail('retained parent refetched'))
        self.assertFalse((args.output / figure.COMPLETE).exists())
        args.output = self.fixture.root / 'fresh-after-failure'
        with patch.object(figure, 'verify_stream_document', wraps=figure.verify_stream_document) as full:
            manifest = figure.capture_files(args, transport=lambda *_:self.fail('retained parent refetched'))
            self.assertEqual([Path(call.args[0]).parent for call in full.call_args_list], [parent, args.output])
        with patch.object(figure, 'verify_stream_document', wraps=figure.verify_stream_document) as full:
            self.assertEqual(figure.verify(args.output), manifest)
            self.assertEqual([Path(call.args[0]).parent for call in full.call_args_list], [args.output, parent])

class FigureOutputDigestTests(unittest.TestCase):
    def setUp(self):
        self.fixture = FigureFileTests()
        self.fixture.setUp()
        self.addCleanup(self.fixture.doCleanups)
        self.args = self.fixture.args()
        self.manifest = figure.capture_files(self.args,
            transport=lambda *_: (200, {}, figure.encoded(self.fixture.response())), sleep=lambda _: None)
        self.paths = {role: self.args.output / name for role, name in figure.output_roles(self.args.output).items()}

    def test_output_digests_use_one_fresh_payload_and_tuple_keeps_exact_final_guard(self):
        legacy = self.fixture.stage('legacy-four-role-capture')
        original_replay, original_fingerprint, original_payload = figure.replay, figure.evidence.fingerprint, figure.payload
        for root in (self.args.output, legacy):
            paths = {role: root / name for role, name in figure.output_roles(root).items()}
            for tuple_boundary in (False, True):
                with self.subTest(roles=len(paths), tuple_boundary=tuple_boundary):
                    semantic_done, reads, payload_boundaries = False, [], []
                    def replay(*values, **options):
                        nonlocal semantic_done
                        result = original_replay(*values, **options)
                        semantic_done = True
                        return result
                    def fingerprint(path):
                        if semantic_done and Path(path) in paths.values():
                            reads.append(Path(path))
                        return original_fingerprint(path)
                    def payload(path, **options):
                        payload_boundaries.append((Path(path), semantic_done))
                        return original_payload(path, **options)
                    with patch.object(figure, 'replay', side_effect=replay) as semantic, \
                            patch.object(figure.evidence, 'fingerprint', side_effect=fingerprint), \
                            patch.object(figure, 'payload', side_effect=payload):
                        if tuple_boundary:
                            result = figure.verify_tuple(paths, self.fixture.wiki, self.fixture.date)
                            self.assertEqual(set(result), set(paths))
                        else:
                            result = figure.verify(root)
                            self.assertEqual(set(result['outputs']), set(paths))
                    semantic.assert_called_once()
                    expected = 1
                    # Legacy occurrence replay still hashes its membership
                    # before returning. The changed boundary begins afterward.
                    legacy_membership = [(root, False)] if root == legacy else []
                    self.assertEqual(payload_boundaries, legacy_membership + [(root, True)] * expected)
                    self.assertEqual({path: reads.count(path) for path in paths.values()},
                                     {path: (0 if root != legacy and path == paths['figure-sizing-raw'] else expected)
                                      for path in paths.values()})

    def test_output_digest_reuse_refuses_late_content_inode_and_member_changes(self):
        root = self.args.output
        target = self.paths['file-metadata']
        saved = {path.name: path.read_bytes() for path in root.iterdir()}
        original_payload = figure.payload
        for mutation in ('content', 'restored-content', 'inode', 'missing', 'extra', 'symlink', 'directory', 'root'):
            with self.subTest(mutation=mutation):
                invoked = False
                old_root = root.with_name('old-root')
                replacement = root.with_name('replacement-provider')
                def payload(path, **options):
                    nonlocal invoked
                    result = original_payload(path, **options)
                    self.assertEqual(Path(path), root)
                    invoked = True
                    if mutation in ('content', 'restored-content'):
                        target.write_bytes(saved[target.name] + b'changed')
                        if mutation == 'restored-content': target.write_bytes(saved[target.name])
                    elif mutation == 'inode':
                        replacement.write_bytes(saved[target.name]); replacement.replace(target)
                    elif mutation == 'missing': target.unlink()
                    elif mutation == 'extra': (root / 'unexpected-member').write_bytes(b'extra')
                    elif mutation == 'symlink':
                        replacement.write_bytes(saved[target.name]); target.unlink(); target.symlink_to(replacement)
                    elif mutation == 'directory': target.unlink(); target.mkdir()
                    else:
                        root.rename(old_root); root.mkdir()
                        for name, raw in saved.items(): (root / name).write_bytes(raw)
                    return result
                try:
                    with patch.object(figure, 'payload', side_effect=payload):
                        with self.assertRaises((ValueError, OSError)):
                            figure.verify(root)
                    self.assertTrue(invoked)
                finally:
                    for path in root.iterdir():
                        if path.is_dir() and not path.is_symlink(): path.rmdir()
                        else: path.unlink()
                    if old_root.exists():
                        root.rmdir(); old_root.rename(root)
                    else:
                        for name, raw in saved.items(): (root / name).write_bytes(raw)
                    if replacement.exists(): replacement.unlink()

    def test_output_digest_reuse_still_hashes_content_when_stamps_are_unchanged(self):
        target = self.paths['file-metadata']
        stamp = figure.evidence.stamp(target)
        original_replay, original_stamp = figure.replay, figure.evidence.stamp
        def replay(*values, **options):
            result = original_replay(*values, **options)
            target.write_bytes(target.read_bytes()[:-1] + b'!')
            return result
        def unchanged(path):
            return stamp if Path(path) == target else original_stamp(path)
        with patch.object(figure, 'replay', side_effect=replay), \
                patch.object(figure.evidence, 'stamp', side_effect=unchanged):
            with self.assertRaisesRegex(ValueError, 'Figure capture differs from source replay'):
                figure.verify(self.args.output)

    def test_output_digest_reuse_preserves_change_during_actual_hash_read_refusal(self):
        target = self.paths['file-metadata']
        original_replay, original_open = figure.replay, Path.open
        semantic_done, changed = False, False
        def replay(*values, **options):
            nonlocal semantic_done
            result = original_replay(*values, **options); semantic_done = True
            return result
        class ChangingReader:
            def __init__(self, stream): self.stream = stream
            def __enter__(self): self.stream.__enter__(); return self
            def __exit__(self, *values): return self.stream.__exit__(*values)
            def read(self, count):
                nonlocal changed
                raw = self.stream.read(count)
                if raw and not changed:
                    with original_open(target, 'ab') as output: output.write(b'changed')
                    changed = True
                return raw
        def open_file(path, *values, **options):
            stream = original_open(path, *values, **options)
            if semantic_done and Path(path) == target and values == ('rb',):
                return ChangingReader(stream)
            return stream
        with patch.object(figure, 'replay', side_effect=replay), patch.object(Path, 'open', open_file):
            with self.assertRaisesRegex(ValueError, 'Input changed while hashing'):
                figure.verify(self.args.output)
        self.assertTrue(changed)

    def test_output_digest_reuse_keeps_role_digest_and_independent_final_content_checks(self):
        root = self.args.output
        manifest_path, marker_path = root / figure.MANIFEST, root / figure.COMPLETE
        original_manifest, original_marker = manifest_path.read_bytes(), marker_path.read_bytes()
        altered = json.loads(original_manifest)
        altered['outputs']['file-metadata'] = '0' * 64
        manifest_path.write_bytes(figure.encoded(altered))
        marker_path.write_bytes(figure.encoded(dict(schema=figure.SCHEMA,
            manifest_sha256=figure.digest(manifest_path.read_bytes()))))
        with self.assertRaisesRegex(ValueError, 'Figure capture differs from source replay'):
            figure.verify(root)
        manifest_path.write_bytes(original_manifest); marker_path.write_bytes(original_marker)
        original_verify, original_stamp = figure.verify, figure.evidence.stamp
        target = self.paths['file-metadata']; stamp = original_stamp(target)
        def verify(*values, **options):
            result = original_verify(*values, **options)
            target.write_bytes(target.read_bytes()[:-1] + b'!')
            return result
        def unchanged(path):
            return stamp if Path(path) == target else original_stamp(path)
        with patch.object(figure, 'verify', side_effect=verify), \
                patch.object(figure.evidence, 'stamp', side_effect=unchanged):
            with self.assertRaisesRegex(ValueError, 'Figure source capture changed during validation'):
                figure.verify_tuple(self.paths, self.fixture.wiki, self.fixture.date)


    def test_raw_digest_reuse_refuses_changes_after_semantic_completion(self):
        target = self.paths['figure-sizing-raw']
        saved = target.read_bytes()
        original_replay = figure.replay
        for mutation in ('content', 'restored-content', 'inode'):
            with self.subTest(mutation=mutation):
                def replay(*values, **options):
                    result = original_replay(*values, **options)
                    if mutation == 'inode':
                        replacement = target.with_name('raw-replacement')
                        replacement.write_bytes(saved); replacement.replace(target)
                    else:
                        target.write_bytes(saved + b'changed')
                        if mutation == 'restored-content': target.write_bytes(saved)
                    return result
                try:
                    with patch.object(figure, 'replay', side_effect=replay):
                        with self.assertRaisesRegex(ValueError, 'verified raw changed'):
                            figure.verify(self.args.output)
                finally:
                    target.write_bytes(saved)

    def test_raw_stream_identity_requires_complete_eof_and_exact_bytes(self):
        target = self.paths['figure-sizing-raw']
        raw = target.read_bytes()
        identity = {}
        values = figure.stream_values(target, figure.RAW_STREAM_SCHEMA, identity_out=identity)
        next(values); values.close()
        self.assertEqual(identity, {})
        list(figure.stream_values(target, figure.RAW_STREAM_SCHEMA, identity_out=identity))
        self.assertEqual(identity, {'size': len(raw), 'sha256': figure.digest(raw)})
        identity = {}
        target.write_bytes(raw + b' ')
        with self.assertRaisesRegex(ValueError, 'Trailing Figure stream'):
            list(figure.stream_values(target, figure.RAW_STREAM_SCHEMA, identity_out=identity))
        self.assertEqual(identity, {})
        target.write_bytes(raw)

    def test_raw_digest_proof_is_not_published_on_late_semantic_failure(self):
        original_replay = figure.replay
        proof = {}
        # A malformed complete manifest is a late replay refusal after streams.
        path = self.args.output / figure.MANIFEST
        manifest = json.loads(path.read_bytes()); manifest['capture_format'] = 'wrong'
        path.write_bytes(figure.encoded(manifest))
        with self.assertRaises(ValueError):
            original_replay(self.args.output, self.fixture.wiki, self.fixture.date,
                           _raw_payload_out=proof)
        self.assertEqual(proof, {})


class FigureStreamDigestTests(unittest.TestCase):
    def setUp(self):
        self.fixture = FigureFileTests()
        self.fixture.setUp()
        self.addCleanup(self.fixture.doCleanups)
        self.args = self.fixture.args()
        self.manifest = figure.capture_files(self.args,
            transport=lambda *_: (200, {}, figure.encoded(self.fixture.response())), sleep=lambda _: None)
        self.raw = self.args.output / figure.ROLES['figure-sizing-raw']
        self.original = self.raw.read_bytes()
        self.paths = {role: self.args.output / name for role, name in figure.output_roles(self.args.output).items()}

    def test_stream_digest_plain_encoded_empty_parity_without_second_raw_read(self):
        values = list(figure.stream_values(self.raw, figure.RAW_STREAM_SCHEMA))
        header, batches = values[0], values[1:]
        expected_records = self.fixture.stream_document(self.args.output)['records']
        original_open, original_fingerprint = Path.open, figure.evidence.fingerprint
        for mode in ('plain', 'encoded', 'empty'):
            with self.subTest(mode=mode):
                selected = dict(header)
                if mode == 'plain': selected.pop('record_encoding', None)
                if mode == 'empty': selected.update(records_count=0, base_batches=0, observed_batches=0)
                encoding = figure.raw_record_encoding(selected)
                raw = figure.stream_encoded(selected) + b''.join(
                    figure.raw_record_encoded(batch, encoding) for batch in (() if mode == 'empty' else batches))
                self.raw.write_bytes(raw)
                opens = []
                def open_file(path, *args, **kwargs):
                    if Path(path) == self.raw: opens.append((args, kwargs))
                    return original_open(path, *args, **kwargs)
                def fingerprint(path):
                    if Path(path) == self.raw: self.fail('raw identity reread after stream consumption')
                    return original_fingerprint(path)
                with patch.object(Path, 'open', open_file), patch.object(figure.evidence, 'fingerprint', side_effect=fingerprint):
                    document = figure.figure_stream_document(self.raw, self.fixture.namespace.read_bytes(),
                        self.fixture.wiki, self.fixture.date, self.paths['figure-sizing-site'].read_bytes())
                self.assertEqual(opens, [(('rb',), {})])
                self.assertEqual(document['raw_bytes'], len(raw))
                self.assertEqual(document['raw_sha256'], hashlib.sha256(raw).hexdigest())
                self.assertEqual(document['records'], [] if mode == 'empty' else expected_records)
                identity = {}
                self.assertEqual(list(figure.stream_values(self.raw, figure.RAW_STREAM_SCHEMA, identity_out=identity)),
                                 [selected, *(() if mode == 'empty' else batches)])
                self.assertEqual(identity, dict(size=len(raw), sha256=hashlib.sha256(raw).hexdigest()))

    def test_stream_digest_is_not_published_on_close_truncation_or_trailing_bytes(self):
        for advances in (1, 2):
            identity = {}
            iterator = figure.stream_values(self.raw, figure.RAW_STREAM_SCHEMA, identity_out=identity)
            for _ in range(advances): next(iterator)
            self.assertEqual(identity, {})
            iterator.close()
            self.assertEqual(identity, {})
        lines = self.original.splitlines(keepends=True)
        count_header = json.loads(lines[0]); count_header['base_batches'] += 1
        for invalid in (self.original[:-1], self.original + b'\n', self.original + b'{}\n',
                        figure.stream_encoded(count_header) + b''.join(lines[1:]),
                        lines[0] + b'{bad json}\n'):
            with self.subTest(invalid=invalid[-32:]):
                self.raw.write_bytes(invalid); identity = {}
                with self.assertRaises((ValueError, StopIteration)):
                    list(figure.stream_values(self.raw, figure.RAW_STREAM_SCHEMA, identity_out=identity))
                self.assertEqual(identity, {})

    def test_stream_digest_refuses_replacement_before_open_and_mutation_while_yielded(self):
        original_stamp = figure.evidence.stamp
        replacement = self.raw.with_name('replacement-raw')
        called = False
        def replaced_before_open(path):
            nonlocal called
            result = original_stamp(path)
            if Path(path) == self.raw and not called:
                called = True; replacement.write_bytes(self.original); replacement.replace(self.raw)
            return result
        identity = {}
        with patch.object(figure.evidence, 'stamp', side_effect=replaced_before_open):
            with self.assertRaisesRegex(ValueError, 'replaced before reading'):
                list(figure.stream_values(self.raw, figure.RAW_STREAM_SCHEMA, identity_out=identity))
        self.assertTrue(called); self.assertEqual(identity, {})
        for mutation in ('content', 'restored-content', 'same-bytes-inode', 'symlink'):
            with self.subTest(mutation=mutation):
                self.raw.write_bytes(self.original); identity = {}
                iterator = figure.stream_values(self.raw, figure.RAW_STREAM_SCHEMA, identity_out=identity)
                next(iterator)
                try:
                    if mutation in ('content', 'restored-content'):
                        self.raw.write_bytes(self.original + b'changed')
                        if mutation == 'restored-content': self.raw.write_bytes(self.original)
                    else:
                        replacement.write_bytes(self.original)
                        if mutation == 'same-bytes-inode': replacement.replace(self.raw)
                        else:
                            self.raw.unlink(); self.raw.symlink_to(replacement)
                    with self.assertRaises((ValueError, OSError)):
                        list(iterator)
                    self.assertEqual(identity, {})
                finally:
                    iterator.close()
                    if self.raw.is_symlink(): self.raw.unlink()
                    if replacement.exists(): replacement.unlink()
                    self.raw.write_bytes(self.original)

    def test_stream_digest_checks_opened_file_after_exact_eof_even_with_stale_path_stamp(self):
        original_open, original_stamp = Path.open, figure.evidence.stamp
        prior = original_stamp(self.raw); changed = False
        class ChangingReader:
            def __init__(self, stream): self.stream = stream
            def __enter__(self): self.stream.__enter__(); return self
            def __exit__(self, *args): return self.stream.__exit__(*args)
            def fileno(self): return self.stream.fileno()
            def readline(self, count): return self.stream.readline(count)
            def read(self, count):
                nonlocal changed
                raw = self.stream.read(count)
                if count == 1 and not raw and not changed:
                    with original_open(self_test.raw, 'ab') as output: output.write(b'changed')
                    changed = True
                return raw
        self_test = self
        def open_file(path, *args, **kwargs):
            stream = original_open(path, *args, **kwargs)
            return ChangingReader(stream) if Path(path) == self.raw and args == ('rb',) else stream
        def unchanged(path): return prior if Path(path) == self.raw else original_stamp(path)
        identity = {}
        with patch.object(Path, 'open', open_file), patch.object(figure.evidence, 'stamp', side_effect=unchanged):
            with self.assertRaisesRegex(ValueError, 'changed during reading'):
                list(figure.stream_values(self.raw, figure.RAW_STREAM_SCHEMA, identity_out=identity))
        self.assertTrue(changed); self.assertEqual(identity, {})

    def test_stream_digest_keeps_independent_tuple_payload_authentication(self):
        original_verify, original_stamp, original_fingerprint = figure.verify, figure.evidence.stamp, figure.evidence.fingerprint
        prior = original_stamp(self.raw); semantic_done = False; final_reads = []
        def verify(*args, **kwargs):
            nonlocal semantic_done
            result = original_verify(*args, **kwargs)
            self.raw.write_bytes(self.original[:-1] + b' ')
            semantic_done = True
            return result
        def unchanged(path): return prior if semantic_done and Path(path) == self.raw else original_stamp(path)
        def fingerprint(path):
            if semantic_done and Path(path) == self.raw: final_reads.append(Path(path))
            return original_fingerprint(path)
        with patch.object(figure, 'verify', side_effect=verify), \
                patch.object(figure.evidence, 'stamp', side_effect=unchanged), \
                patch.object(figure.evidence, 'fingerprint', side_effect=fingerprint):
            with self.assertRaisesRegex(ValueError, 'Figure source capture changed during validation'):
                figure.verify_tuple(self.paths, self.fixture.wiki, self.fixture.date)
        self.assertEqual(final_reads, [])







class TerminalHttpOriginTests(unittest.TestCase):
    def setUp(self):
        self.fixture = FigureFileTests()
        self.fixture.setUp()
        self.addCleanup(self.fixture.doCleanups)
        self.root = self.fixture.root/'materialized-terminal-fixture'
        self.root.mkdir()
        self.ids = ['figure-origin-'+letter*64 for letter in ('a','b')]
        self.plan = {'metadata_mode':figure.MATERIALIZED_HTTP_MODE,
                     'materialized_http_origins':[{'id':identifier} for identifier in self.ids]}
        # Resolver-only declarations: full origin provenance is checked by the
        # separately composed materialization verifier, not these leaf tests.
        (self.root/figure.PLAN).write_bytes(figure.encoded(self.plan))
        for identifier in self.ids: (self.root/identifier).mkdir()

    def terminal(self, index, title, *, lean=False, stage='', retry=False):
        root = self.root/self.ids[index]
        registry = figure.evidence.Registry(self.fixture.namespace.read_bytes(),self.fixture.wiki,self.fixture.date)
        if lean or stage:
            response = self.fixture.epoch_response([title],figure.FIGURE_CURRENT_CORE,full=bool(stage))
        else:
            response = self.fixture.response(title)
        calls=[]
        def transport(*unused):
            calls.append(True)
            if retry and len(calls)==1: return 503,{},b'fixture temporary failure'
            return 200,{},figure.encoded(response)
        _, reference = metadata.request_batch(root,1,[title],registry,transport,lambda _:None,
            figure.time.monotonic()+30,1,figure_axes=True,figure_metadata_light=lean,artifact_stage=stage)
        names, raw, artifacts, accepted = figure.captured_http_stage(root,reference,self.fixture.wiki,light=lean,stage=stage)
        accepted[0].unlink()
        source = dict(kind='http-archived-lean' if lean else 'http-archived',batch=reference,artifacts=artifacts)
        return source,dict(requests=names,response=raw.decode())

    def scoped(self, index, source):
        result=copy.deepcopy(source);prefix=self.ids[index]+'/'
        for key in ('batch','tiff_batch'):
            if key in result: result[key]={field:prefix+name for field,name in result[key].items()}
        for key in ('artifacts','tiff_artifacts'):
            if key in result: result[key]=[prefix+name for name in result[key]]
        return result

    def replay(self, source, batch, files=None, *, plan=None, root=None):
        return figure.replay_source(self.root if root is None else root,source,batch,
            self.fixture.wiki,self.fixture.date,self.fixture.namespace.read_bytes(),
            set() if files is None else files,profile_kind=figure.FIGURE_PROFILE_V4,
            allow_compatible_epochs=True,origin_plan=self.plan if plan is None else plan)

    def test_colliding_leaf_numbers_keep_exact_receipts_and_separate_global_authority(self):
        sources=[];batches=[];before={}
        for index,title in enumerate(('\u0645\u0644\u0641:A.svg','\u0645\u0644\u0641:B.svg')):
            source,batch=self.terminal(index,title,retry=True)
            sources.append(self.scoped(index,source));batches.append(batch)
            before.update({str(p.relative_to(self.root)):p.read_bytes() for p in (self.root/self.ids[index]).iterdir()})
        self.assertEqual(Path(sources[0]['batch']['request']).name,Path(sources[1]['batch']['request']).name)
        files=set();archived={}
        for source,batch in zip(sources,batches):
            archived.update(self.replay(source,batch,files))
        self.assertEqual(files,set(before))
        self.assertEqual(set(archived),{identifier+'/file-metadata.response-000001-02.raw.json' for identifier in self.ids})
        for index,identifier in enumerate(self.ids):
            row=archived[identifier+'/file-metadata.response-000001-02.raw.json']
            raw=batches[index]['response'].encode()
            self.assertEqual(row,{'bytes':len(raw),'sha256':figure.digest(raw)})
        self.assertEqual(before,{str(p.relative_to(self.root)):p.read_bytes() for identifier in self.ids for p in (self.root/identifier).iterdir()})
        with self.assertRaisesRegex(ValueError,'Duplicate contained'):
            self.replay(sources[0],batches[0],files)

    def test_lean_tiff_companion_is_same_origin_and_archive_join_is_namespaced(self):
        source,batch=self.terminal(0,'\u0645\u0644\u0641:F.tif',lean=True)
        followup,full=self.terminal(0,'\u0645\u0644\u0641:F.tif',stage='tiff')
        source.update(tiff_batch=followup['batch'],tiff_artifacts=followup['artifacts'])
        batch['tiff_metadata_response']=full['response']
        scoped=self.scoped(0,source);files=set();archived={}
        archived.update(self.replay(scoped,batch,files))
        prefix=self.ids[0]+'/'
        self.assertEqual(archived[('tiff-titles',prefix+'file-metadata.response-000001-01.raw.json')],batch['requests'])
        self.assertIn(prefix+'file-metadata.tiff-response-000001-01.raw.json',archived)
        mixed=copy.deepcopy(scoped)
        for key in ('tiff_batch','tiff_artifacts'):
            if isinstance(mixed[key],dict):mixed[key]={k:v.replace(self.ids[0],self.ids[1]) for k,v in mixed[key].items()}
            else:mixed[key]=[v.replace(self.ids[0],self.ids[1]) for v in mixed[key]]
        with self.assertRaisesRegex(ValueError,'mixed origin'):self.replay(mixed,batch)
        missing=dict(batch);missing.pop('tiff_metadata_response')
        with self.assertRaises(ValueError):self.replay(scoped,missing)

    def test_origin_mode_declaration_and_path_boundaries_refuse(self):
        source,batch=self.terminal(0,'\u0645\u0644\u0641:A.svg')
        scoped=self.scoped(0,source)
        for plan in ({'metadata_mode':'full'},dict(self.plan,materialized_http_origins=[]),
                     dict(self.plan,materialized_http_origins=[{'id':self.ids[0]},{'id':self.ids[0]}])):
            with self.subTest(plan=plan),self.assertRaises(ValueError):self.replay(scoped,batch,plan=plan)
        with self.assertRaisesRegex(ValueError,'lacks its origin namespace'):self.replay(source,batch)
        for invalid in ('../file-metadata.request-000001.json',self.ids[0]+'/nested/file-metadata.request-000001.json',
                        '/'+self.ids[0]+'/file-metadata.request-000001.json',
                        self.ids[1]+'/file-metadata.request-000001.json'):
            changed=copy.deepcopy(scoped);changed['batch']['request']=invalid
            with self.subTest(path=invalid),self.assertRaises(ValueError):self.replay(changed,batch)
        local=self.root/self.ids[0];held=self.fixture.root/'original-origin';local.rename(held);local.symlink_to(held,target_is_directory=True)
        with self.assertRaises(ValueError):self.replay(scoped,batch)
        local.unlink();held.rename(local)
        request=local/source['batch']['request'];saved=self.fixture.root/'original-request';request.rename(saved);request.symlink_to(saved)
        with self.assertRaises(ValueError):self.replay(scoped,batch)

    def test_flat_leaf_route_and_received_bytes_remain_strict(self):
        source,batch=self.terminal(0,'\u0645\u0644\u0641:A.svg',retry=True)
        local=self.root/self.ids[0]
        self.replay(source,batch,plan={'metadata_mode':'full'},root=local)
        scoped=self.scoped(0,source)
        receipt_path=local/source['batch']['accepted_receipt'];raw=receipt_path.read_bytes()
        receipt=json.loads(raw)
        for key,value in (('request','file-metadata.request-000002.json'),
                          ('response','file-metadata.response-000002-02.raw.json'),
                          ('response_sha256','0'*64),('accepted',False),('status',403)):
            changed=dict(receipt);changed[key]=value;receipt_path.write_bytes(figure.encoded(changed))
            with self.subTest(field=key),self.assertRaises(ValueError):self.replay(scoped,batch)
        receipt_path.write_bytes(raw)
        duplicate=local/receipt['response'];duplicate.write_bytes(batch['response'].encode())
        with self.assertRaisesRegex(ValueError,'Unretired duplicate accepted response'):
            self.replay(scoped,batch)
        duplicate.unlink()
        rejected=local/'file-metadata.response-000001-01.receipt.json';rejected.unlink()
        with self.assertRaises((ValueError,OSError)):self.replay(scoped,batch)

    def test_custody_allows_only_declared_regular_one_level_members(self):
        self.terminal(0,'\u0645\u0644\u0641:A.svg');self.terminal(1,'\u0645\u0644\u0641:B.svg')
        for name in (figure.MANIFEST,figure.COMPLETE):(self.root/name).write_bytes(b'root marker fixture')
        child_manifest=self.root/self.ids[0]/figure.MANIFEST;child_manifest.write_bytes(b'origin manifest fixture')
        members,directories=figure.capture_member_paths(self.root)
        self.assertEqual(set(members),{figure.PLAN,*(str(p.relative_to(self.root)) for identifier in self.ids for p in (self.root/identifier).iterdir())})
        self.assertEqual(set(figure.payload(self.root)),set(members))
        self.assertIn(self.ids[0]+'/'+figure.MANIFEST,members)
        self.assertEqual(set(directories),{self.root,*(self.root/identifier for identifier in self.ids)})
        all_members,dirs=figure.capture_member_paths(self.root,include_markers=True)
        prefix={'root':self.root,'stamps':{p:figure.evidence.stamp(p) for p in all_members.values()},
                'directory_stamp':dirs[self.root],'member_directories':dirs}
        figure.check_prefix_cache({'fixture':prefix})
        local=self.root/self.ids[0];local.chmod(local.stat().st_mode ^ 0o1000)
        with self.assertRaises(ValueError):figure.check_prefix_cache({'fixture':prefix})
        deep=local/'nested';deep.mkdir()
        with self.assertRaises(ValueError):figure.capture_member_paths(self.root)
        deep.rmdir()
        unknown=self.root/('figure-origin-'+'c'*64);unknown.mkdir()
        with self.assertRaises(ValueError):figure.capture_member_paths(self.root)
        unknown.rmdir()
        link=local/'file-metadata.extra.json';link.symlink_to(child_manifest)
        with self.assertRaises(ValueError):figure.payload(self.root)

    def test_existing_lexical_plan_avoids_per_frame_plan_rereads(self):
        source,batch=self.terminal(0,'\u0645\u0644\u0641:A.svg');scoped=self.scoped(0,source)
        original=figure.inventory_document
        def read(path):
            if Path(path)==self.root/figure.PLAN:self.fail('reloaded the already parsed plan for one HTTP frame')
            return original(path)
        with patch.object(figure,'inventory_document',side_effect=read):
            self.replay(scoped,batch)

    def test_origin_directory_mutation_during_leaf_validation_refuses(self):
        source,batch=self.terminal(0,'\u0645\u0644\u0641:A.svg');scoped=self.scoped(0,source)
        local=self.root/self.ids[0];original=figure.replay_http_source;changed=[]
        def replay(root,*values,**options):
            result=original(root,*values,**options)
            if Path(root)==local and not changed:
                local.chmod(local.stat().st_mode ^ 0o1000);changed.append(True)
            return result
        files=set()
        with patch.object(figure,'replay_http_source',side_effect=replay):
            with self.assertRaisesRegex(ValueError,'directory changed during replay'):
                self.replay(scoped,batch,files)
        self.assertEqual(changed,[True]);self.assertEqual(files,set())





class OfflineFigureMaterializationTests(unittest.TestCase):
    def setUp(self):
        self.fixture = FigureFileTests()
        self.fixture.setUp()
        self.addCleanup(self.fixture.doCleanups)
        self.root = self.fixture.root

    def complete(self):
        args, _, _ = self.fixture.complete_stream_fixture()
        return args

    def epoch_complete(self):
        args, proof, _ = self.fixture.make_source_epoch_prefix()
        now, advance = self.fixture.overlap_clock()
        def transport(url, timeout):
            titles = parse_qs(urlsplit(url).query)['titles'][0].split('|')
            return 200, {}, figure.encoded(self.fixture.epoch_response(titles, figure.FIGURE_RESPONSE_CORE))
        with patch.object(figure.time, 'monotonic', side_effect=now):
            figure.capture_files(args, transport=transport, sleep=advance)
        return args, proof

    def materialize(self, args):
        output = self.root/'self-contained'
        with patch.object(figure.evidence, 'get_response', side_effect=AssertionError('offline materialization fetched')):
            manifest = figure.materialize_complete_capture(args.output/figure.MANIFEST, output)
        return output, manifest

    def verify_both(self, output):
        manifest = figure.verify(output)
        paths = {role: output/name for role, name in {**figure.ROLES, 'file-metadata': figure.PROVIDER}.items()}
        self.assertEqual(set(figure.verify_tuple(paths, self.fixture.wiki, self.fixture.date)), set(paths))
        return manifest

    def rebind(self, output, plan):
        (output/figure.PLAN).write_bytes(figure.encoded(plan))
        manifest = json.loads((output/figure.MANIFEST).read_text())
        raw = (output/figure.PLAN).read_bytes()
        manifest['artifacts'][figure.PLAN] = {'bytes':len(raw),'sha256':figure.digest(raw)}
        (output/figure.MANIFEST).write_bytes(figure.encoded(manifest))
        (output/figure.COMPLETE).write_bytes(figure.encoded({'schema':figure.SCHEMA,
            'manifest_sha256':figure.digest((output/figure.MANIFEST).read_bytes())}))

    def test_materialization_verifies_source_without_retaining_unused_projection_document(self):
        args=self.complete();source=args.output/figure.MANIFEST
        before={name:(args.output/name).read_bytes()
                for name in (*figure.ROLES.values(),figure.PROVIDER,figure.INVENTORY)}
        read_complete=figure.read_complete_capture;verify=figure.verify
        document_requests=[];verified=[]
        def read_without_document(path,*values,**options):
            selected=Path(path)==source
            if selected:document_requests.append(options.get('include_document',True))
            result=read_complete(path,*values,**options)
            if selected:self.assertNotIn('document',result)
            return result
        def verify_source(path,*values,**options):
            verified.append(Path(path))
            return verify(path,*values,**options)
        with (patch.object(figure,'read_complete_capture',side_effect=read_without_document),
              patch.object(figure,'verify',side_effect=verify_source)):
            output,manifest=self.materialize(args)
            for name,raw in before.items():self.assertEqual((output/name).read_bytes(),raw)
            self.assertEqual(self.verify_both(output),manifest)
            self.assertIn(args.output,verified)
            projection=args.output/figure.ROLES['figure-sizing']
            rows=[json.loads(line) for line in projection.read_text().splitlines()]
            record=next(row for row in rows[1:] if row.get('original_width') is not None)
            record['original_width']+=1
            projection.write_bytes(b''.join(figure.stream_encoded(row) for row in rows))
            forged=json.loads(source.read_text())
            forged['outputs']['figure-sizing']=figure.digest(projection.read_bytes())
            forged['artifacts']=figure.payload(args.output)
            source.write_bytes(figure.encoded(forged))
            (args.output/figure.COMPLETE).write_bytes(figure.encoded(dict(schema=figure.SCHEMA,
                manifest_sha256=figure.digest(source.read_bytes()))))
            refused=self.root/'rehashed-source-refused'
            with self.assertRaisesRegex(ValueError,'projection stream record differs from exact raw replay'):
                figure.materialize_complete_capture(source,refused)
            self.assertFalse(refused.exists())
        self.assertGreaterEqual(len(document_requests),2)
        self.assertEqual(set(document_requests),{False})
        self.assertGreaterEqual(verified.count(args.output),2)

    def test_complete_origin_is_independent_of_original_payloads(self):
        args = self.complete()
        original = {p.name:p.read_bytes() for p in args.output.iterdir()}
        output, manifest = self.materialize(args)
        self.assertEqual(original, {p.name:p.read_bytes() for p in args.output.iterdir()})
        for name in (*figure.ROLES.values(), figure.PROVIDER):
            self.assertEqual((output/name).read_bytes(), original[name])
        plan = json.loads((output/figure.PLAN).read_text())
        self.assertEqual(plan['metadata_mode'], 'materialized-http-origins-v1')
        self.assertEqual(len(plan['materialized_http_origins']), 1)
        args.output.rename(self.root/'predecessor-unavailable')
        with patch.object(figure.evidence, 'get_response', side_effect=AssertionError('verification fetched')):
            self.assertEqual(self.verify_both(output), manifest)

    def test_source_epochs_pending_slots_and_colliding_receipt_leaves_survive_without_ancestors(self):
        args, proof = self.epoch_complete()
        prefix = json.loads(proof.read_text())
        origin = Path(prefix['source_root'])
        output, manifest = self.materialize(args)
        plan = json.loads((output/figure.PLAN).read_text())
        origins = plan['materialized_http_origins']
        self.assertEqual(len(origins), 2)
        self.assertTrue(any(row['pending'] and len(row['pending']) == 2 for row in origins))
        receipts = []
        for row in origins:
            for name, reference in row['files'].items():
                if 'response-000001-' in name and name.endswith('.receipt.json'):
                    receipts.append((reference['path'], (output/reference['path']).read_bytes()))
        self.assertEqual(len(receipts), 2)
        self.assertNotEqual(receipts[0][0], receipts[1][0])
        for row in origins:
            source = Path(row['source_reference']['path'])
            if source.name == figure.MANIFEST:
                original_root = source.parent
            else:
                original_root = Path(json.loads(source.read_text())['source_root'])
            for name, reference in row['files'].items():
                self.assertEqual((output/reference['path']).read_bytes(), (original_root/name).read_bytes())
        args.output.rename(self.root/'completed-parent-unavailable')
        origin.rename(self.root/'closed-parent-unavailable')
        proof.rename(proof.with_suffix('.unavailable'))
        self.assertEqual(self.verify_both(output), manifest)

    def test_unbound_duplicate_and_traversing_origins_refuse_even_with_rehashed_manifest(self):
        args = self.complete(); output, _ = self.materialize(args)
        original = json.loads((output/figure.PLAN).read_text())
        for mutation in ('duplicate', 'missing-plan', 'traversal', 'unknown-root'):
            plan = copy.deepcopy(original); row = plan['materialized_http_origins'][0]
            if mutation == 'duplicate': plan['materialized_http_origins'].append(copy.deepcopy(row))
            elif mutation == 'missing-plan': row.pop('plan')
            elif mutation == 'traversal': row['authority']['path'] = '../authority.json'
            else: plan['materialized_root'] = 'figure-origin-'+'0'*64
            with self.subTest(mutation=mutation):
                self.rebind(output, plan)
                with self.assertRaises((ValueError, KeyError)): figure.verify(output)
        self.rebind(output, original)
        self.verify_both(output)

    def test_origin_epoch_and_frame_echo_changes_refuse(self):
        args, _ = self.epoch_complete(); output, _ = self.materialize(args)
        original = json.loads((output/figure.PLAN).read_text())
        for mutation in ('epoch', 'frame-map', 'mode'):
            plan = copy.deepcopy(original)
            row = next(row for row in plan['materialized_http_origins'] if row['pending'])
            if mutation == 'epoch': row['epochs'] = []
            elif mutation == 'frame-map': row['frame_map'] = list(reversed(row['frame_map']))
            else: plan['metadata_mode'] = 'lean-tiff-v1'
            with self.subTest(mutation=mutation):
                self.rebind(output, plan)
                with self.assertRaises(ValueError): figure.verify(output)
        self.rebind(output, original)
        self.verify_both(output)

    def test_missing_original_receipt_and_origin_symlink_refuse(self):
        args = self.complete(); output, _ = self.materialize(args)
        plan = json.loads((output/figure.PLAN).read_text()); row=plan['materialized_http_origins'][0]
        reference = next(value for name,value in row['files'].items() if name.endswith('.receipt.json'))
        path = output/reference['path']; original=path.read_bytes(); path.unlink()
        with self.assertRaises((ValueError, FileNotFoundError)): figure.verify(output)
        path.write_bytes(original)
        directory=output/row['id']; saved=output.parent/'saved-origin'; directory.rename(saved); directory.symlink_to(saved,target_is_directory=True)
        try:
            with self.assertRaises(ValueError): figure.verify(output)
        finally:
            directory.unlink(); saved.rename(directory)
        self.verify_both(output)

    def test_rematerialize_source_epoch_retains_pending_and_unique_failed_evidence(self):
        args,proof=self.epoch_complete();first,_=self.materialize(args)
        before={name:(first/name).read_bytes() for name in (*figure.ROLES.values(),figure.PROVIDER)}
        prefix=json.loads(proof.read_bytes());origin=Path(prefix['source_root'])
        args.output.rename(self.root/'complete-unavailable')
        origin.rename(self.root/'closed-unavailable');proof.rename(proof.with_suffix('.unavailable'))
        second=self.root/'rematerialized-epoch'
        manifest=figure.materialize_complete_capture(first/figure.MANIFEST,second)
        first.rename(self.root/'first-unavailable')
        self.assertEqual(self.verify_both(second),manifest)
        for name,raw in before.items():self.assertEqual((second/name).read_bytes(),raw)
        plan=json.loads((second/figure.PLAN).read_bytes())
        closed=next(row for row in plan['materialized_http_origins'] if row['pending'])
        self.assertEqual(len(closed['pending']),2)
        (second/closed['failure']['path']).unlink()
        with self.assertRaises((ValueError,FileNotFoundError)):figure.verify(second)

    def test_linked_current_payloads_preserve_source_bytes_modes_and_inodes(self):
        args=self.complete();output=self.root/'linked-current';observations={}
        names={figure.ROLES['figure-sizing'],figure.ROLES['figure-sizing-raw'],figure.PROVIDER,figure.INVENTORY}
        members=figure.capture_member_paths(args.output,include_markers=True)[0]
        before={name:(path.read_bytes(),path.stat()) for name,path in members.items()}
        manifest=figure.materialize_complete_capture(args.output/figure.MANIFEST,output,
            link_current_payloads=True,observations=observations)
        self.assertEqual(observations['operation'],'materialize-complete')
        self.assertTrue(observations['complete'])
        self.assertTrue(observations['source_complete_verified'])
        self.assertTrue(observations['source_content_mode_inode_preserved'])
        self.assertEqual({row['path'] for row in observations['linked_members']},names)
        for name,(raw,old) in before.items():
            after=members[name].stat()
            self.assertEqual(members[name].read_bytes(),raw)
            for field in ('st_dev','st_ino','st_mode','st_uid','st_gid','st_size','st_mtime_ns'):
                self.assertEqual(getattr(after,field),getattr(old,field))
            self.assertEqual(after.st_nlink,old.st_nlink+(name in names))
            if name in names:
                self.assertEqual((output/name).stat().st_ino,old.st_ino)
                row=next(r for r in observations['linked_members'] if r['path']==name)
                self.assertEqual(row['before']['st_nlink'],old.st_nlink)
                self.assertEqual(row['after']['st_ctime_ns'],after.st_ctime_ns)
                self.assertEqual(row['sha256_before'],figure.digest(raw))
                self.assertEqual(row['sha256_after'],figure.digest(raw))
            else:self.assertEqual(after.st_ctime_ns,old.st_ctime_ns)
        self.assertEqual(self.verify_both(output),manifest)
        self.verify_both(args.output)

    def test_link_mode_requires_explicit_fresh_custody_observations(self):
        args=self.complete();output=self.root/'not-created'
        for options in ({'link_current_payloads':1,'observations':{}},
                        {'link_current_payloads':True},
                        {'link_current_payloads':True,'observations':{'complete':True}}):
            with self.subTest(options=options),self.assertRaises(ValueError):
                figure.materialize_complete_capture(args.output/figure.MANIFEST,output,**options)
            self.assertFalse(output.exists())

    def test_link_mode_does_not_fallback_to_copy_across_filesystems(self):
        args=self.complete();output=self.root/'no-fallback';observations={}
        before={p:p.stat().st_nlink for p in args.output.iterdir()}
        with patch.object(figure.os,'link',side_effect=OSError(errno.EXDEV,'cross-device')):
            with self.assertRaises(OSError):
                figure.materialize_complete_capture(args.output/figure.MANIFEST,output,
                    link_current_payloads=True,observations=observations)
        self.assertFalse((output/figure.COMPLETE).exists())
        self.assertFalse(observations['complete'])
        self.assertEqual(observations['linked_members'],[])
        self.assertEqual({p:p.stat().st_nlink for p in before},before)

    def assert_link_mutation_refuses(self, mutation):
        args=self.complete();output=self.root/'refused-link';observations={};link=os.link
        def changed(source,destination,**kwargs):
            link(source,destination,**kwargs)
            if mutation=='mode':Path(source).chmod((Path(source).stat().st_mode&0o777)^0o100)
            elif mutation=='nlink':link(source,self.root/'unowned-extra-link')
            else:
                other=args.output/figure.ROLES['figure-sizing-site']
                other.chmod((other.stat().st_mode&0o777)^0o100)
        with patch.object(figure.os,'link',side_effect=changed):
            with self.assertRaises(ValueError):
                figure.materialize_complete_capture(args.output/figure.MANIFEST,output,
                    link_current_payloads=True,observations=observations)
        self.assertFalse((output/figure.COMPLETE).exists())
        self.assertFalse(observations['complete'])
        self.assertTrue(observations['linked_members'])

    def test_link_mode_refuses_source_mode_change(self):
        self.assert_link_mutation_refuses('mode')

    def test_link_mode_refuses_unowned_link_count_change(self):
        self.assert_link_mutation_refuses('nlink')

    def test_link_mode_refuses_other_source_member_change(self):
        self.assert_link_mutation_refuses('other')

    def test_link_mode_refuses_mutation_after_complete_output_replay(self):
        args=self.complete();output=self.root/'changed-after-verify';observations={};verify=figure.verify
        def changed(root,*positional,**kwargs):
            result=verify(root,*positional,**kwargs)
            if Path(root)==output:
                with (output/figure.ROLES['figure-sizing-raw']).open('ab') as stream:stream.write(b' ')
            return result
        with patch.object(figure,'verify',side_effect=changed):
            with self.assertRaises(ValueError):
                figure.materialize_complete_capture(args.output/figure.MANIFEST,output,
                    link_current_payloads=True,observations=observations)
        self.assertFalse((output/figure.COMPLETE).exists())
        self.assertFalse(observations['complete'])
        self.assertTrue(all('sha256_after' not in row for row in observations['linked_members']))

    def test_linked_cli_keeps_manifest_stdout_shape_and_explicit_stderr_custody(self):
        args=self.complete();output=self.root/'linked-command';stderr=io.StringIO()
        command=argparse.Namespace(source=args.output/figure.MANIFEST,output=output,
            max_batches=64,max_input_bytes=64*1024*1024,link_current_payloads=True)
        with contextlib.redirect_stderr(stderr):manifest=figure.materialize_command(command)
        observations=json.loads(stderr.getvalue())
        self.assertTrue(observations['complete'])
        self.assertEqual(len(observations['linked_members']),4)
        self.assertEqual(self.verify_both(output),manifest)

    def failed_link_case(self, *, cleanup=False, mutation=None):
        args=self.complete();output=self.root/'failed-current';observations={};link=os.link
        names={figure.ROLES['figure-sizing'],figure.ROLES['figure-sizing-raw'],figure.PROVIDER,figure.INVENTORY}
        before={name:((args.output/name).read_bytes(),(args.output/name).stat()) for name in names}
        targets=[]
        def fail_third(source,destination,**kwargs):
            if len(targets)==2:
                first=Path(targets[0]);original=args.output/first.name
                if mutation=='extra':link(original,self.root/'foreign-extra-link')
                elif mutation=='replacement':first.unlink();first.write_bytes(b'foreign target')
                elif mutation=='source':original.write_bytes(original.read_bytes()+b' ')
                elif mutation=='directory':output.rename(self.root/'retained-old-output');output.mkdir()
                raise OSError(errno.ENOSPC,'injected third-link failure')
            link(source,destination,**kwargs);targets.append(str(destination))
        with patch.object(figure.os,'link',side_effect=fail_third),self.assertRaises(OSError):
            figure.materialize_complete_capture(args.output/figure.MANIFEST,output,
                link_current_payloads=True,cleanup_failed_links=cleanup,observations=observations)
        self.assertFalse(observations['complete'])
        self.assertFalse(observations['new_output_adoption_allowed'])
        self.assertTrue(observations['source_complete_verified'])
        self.assertEqual({row['path'] for row in observations['original_members']},names)
        self.assertFalse((output/figure.COMPLETE).exists())
        return args,output,observations,before,targets

    def test_failed_links_record_all_originals_and_exact_remaining_targets(self):
        args,output,observations,before,targets=self.failed_link_case()
        self.assertTrue(observations['failed_link_recovery_verified'])
        self.assertTrue(observations['source_content_mode_inode_preserved'])
        self.assertEqual(len(observations['linked_members']),2)
        self.assertEqual(observations['removed_owned_links'],[])
        self.assertEqual({row['target'] for row in observations['remaining_owned_links']},set(targets))
        identity=output.stat()
        self.assertEqual(observations['output_root'],dict(path=str(output),device=identity.st_dev,
            inode=identity.st_ino,mode=identity.st_mode,uid=identity.st_uid))
        for row in observations['original_members']:
            name=row['path'];raw,original=before[name];after=(args.output/name).stat()
            self.assertEqual(row['sha256_before'],figure.digest(raw))
            self.assertEqual(row['sha256_after'],figure.digest(raw))
            for key in ('st_dev','st_ino','st_mode','st_uid','st_gid','st_size','st_mtime_ns'):
                self.assertEqual(row['before'][key],getattr(original,key))
                self.assertEqual(row['after'][key],getattr(original,key))
            self.assertEqual(after.st_nlink,original.st_nlink+(str(output/name) in targets))
        for row in observations['remaining_owned_links']:
            target=Path(row['target']);source=args.output/row['path']
            self.assertEqual(target.stat().st_ino,source.stat().st_ino)
            self.assertEqual(row['stamp'],next(r['after'] for r in observations['original_members'] if r['path']==row['path']))
        self.verify_both(args.output)

    def test_failed_links_explicit_cleanup_records_removals_and_empty_remaining(self):
        args,output,observations,before,targets=self.failed_link_case(cleanup=True)
        self.assertTrue(observations['failed_link_recovery_verified'])
        self.assertTrue(observations['source_content_mode_inode_preserved'])
        self.assertEqual(observations['remaining_owned_links'],[])
        self.assertEqual({row['target'] for row in observations['removed_owned_links']},set(targets))
        self.assertEqual(len(observations['removed_owned_links']),2)
        for row in observations['removed_owned_links']:
            self.assertFalse(Path(row['target']).exists())
            self.assertEqual(row['after']['st_nlink'],row['before']['st_nlink']-1)
            for key in ('st_dev','st_ino','st_mode','st_uid','st_gid','st_size','st_mtime_ns'):
                self.assertEqual(row['after'][key],row['before'][key])
        for row in observations['original_members']:
            raw,original=before[row['path']]
            self.assertEqual(row['after']['st_nlink'],original.st_nlink)
            self.assertEqual(row['sha256_after'],figure.digest(raw))
            self.assertEqual((args.output/row['path']).read_bytes(),raw)
        self.verify_both(args.output)

    def test_failed_link_cleanup_refuses_foreign_link_count(self):
        args,output,observations,before,targets=self.failed_link_case(cleanup=True,mutation='extra')
        self.assertFalse(observations['failed_link_recovery_verified'])
        self.assertEqual(observations['removed_owned_links'],[])
        self.assertTrue((self.root/'foreign-extra-link').is_file())
        self.assertTrue(all(Path(path).is_file() for path in targets))
        self.assertTrue(observations['source_content_mode_inode_preserved'])
        self.verify_both(args.output)

    def test_failed_link_cleanup_refuses_replaced_destination(self):
        args,output,observations,before,targets=self.failed_link_case(cleanup=True,mutation='replacement')
        self.assertFalse(observations['failed_link_recovery_verified'])
        self.assertEqual(observations['removed_owned_links'],[])
        self.assertEqual(Path(targets[0]).read_bytes(),b'foreign target')
        self.assertTrue(Path(targets[1]).is_file())
        self.verify_both(args.output)

    def test_failed_link_cleanup_refuses_changed_original_bytes(self):
        args,output,observations,before,targets=self.failed_link_case(cleanup=True,mutation='source')
        self.assertFalse(observations['failed_link_recovery_verified'])
        self.assertFalse(observations['source_content_mode_inode_preserved'])
        self.assertEqual(observations['removed_owned_links'],[])
        self.assertTrue(all(Path(path).is_file() for path in targets))
        self.assertTrue(any(row['sha256_after'] is None for row in observations['original_members']))

    def test_failed_links_without_mutation_record_all_four_originals(self):
        args=self.complete();output=self.root/'never-linked';observations={}
        with patch.object(figure.os,'link',side_effect=OSError(errno.EXDEV,'cross-device')),self.assertRaises(OSError):
            figure.materialize_complete_capture(args.output/figure.MANIFEST,output,
                link_current_payloads=True,cleanup_failed_links=True,observations=observations)
        self.assertTrue(observations['failed_link_recovery_verified'])
        self.assertEqual(len(observations['original_members']),4)
        for key in ('linked_members','remaining_owned_links','removed_owned_links'):
            self.assertEqual(observations[key],[])
        for row in observations['original_members']:
            self.assertEqual(row['before'],row['after'])
            self.assertEqual(row['sha256_before'],row['sha256_after'])
        self.verify_both(args.output)

    def test_failed_link_cleanup_refuses_published_output_marker(self):
        args=self.complete();output=self.root/'published-then-failed';observations={};document=figure.evidence.document
        def fail_marker(path,*values,**kwargs):
            result=document(path,*values,**kwargs)
            if Path(path)==output/figure.COMPLETE:raise OSError(errno.EIO,'injected marker publication failure')
            return result
        with patch.object(figure.evidence,'document',side_effect=fail_marker),self.assertRaises(OSError):
            figure.materialize_complete_capture(args.output/figure.MANIFEST,output,
                link_current_payloads=True,cleanup_failed_links=True,observations=observations)
        self.assertFalse(observations['complete'])
        self.assertFalse(observations['new_output_adoption_allowed'])
        self.assertFalse(observations['failed_link_recovery_verified'])
        self.assertEqual(observations['removed_owned_links'],[])
        self.assertEqual(len(observations['remaining_owned_links']),4)
        self.assertTrue((output/figure.COMPLETE).is_file())
        self.verify_both(args.output)

    def test_failed_link_cleanup_refuses_output_directory_replacement(self):
        args,output,observations,before,targets=self.failed_link_case(cleanup=True,mutation='directory')
        self.assertFalse(observations['failed_link_recovery_verified'])
        self.assertEqual(observations['removed_owned_links'],[])
        self.assertNotEqual(observations['output_root']['inode'],output.stat().st_ino)
        for path in targets:self.assertTrue((self.root/'retained-old-output'/Path(path).name).is_file())
        self.verify_both(args.output)

    def interrupted_owned_cleanup(self, mutation):
        args=self.complete();output=self.root/'interrupted-cleanup';observations={}
        link=os.link;unlink=Path.unlink;lstat=Path.lstat;targets=[];removed=[];injected=False
        def fail_third(source,destination,**kwargs):
            if len(targets)==2:raise OSError(errno.ENOSPC,'injected materialization failure')
            link(source,destination,**kwargs);targets.append(Path(destination))
        def remove(path,*values,**kwargs):
            if path.parent==output:
                if mutation=='error' and removed:raise OSError(errno.EIO,'injected second cleanup failure')
                result=unlink(path,*values,**kwargs);removed.append(path.name);return result
            return unlink(path,*values,**kwargs)
        def observe(path,*values,**kwargs):
            nonlocal injected
            result=lstat(path,*values,**kwargs)
            if (not injected and len(removed)==1 and path==args.output/removed[0] and
                    mutation in ('marker','source')):
                injected=True
                if mutation=='marker':(output/figure.COMPLETE).write_bytes(b'foreign marker')
                else:path.write_bytes(path.read_bytes()+b' ')
            return result
        with (patch.object(figure.os,'link',side_effect=fail_third),
              patch.object(Path,'unlink',new=remove),patch.object(Path,'lstat',new=observe),
              self.assertRaises(OSError)):
            figure.materialize_complete_capture(args.output/figure.MANIFEST,output,
                link_current_payloads=True,cleanup_failed_links=True,observations=observations)
        self.assertEqual(len(removed),1)
        self.assertEqual(len(observations['removed_owned_links']),1)
        self.assertEqual(len(observations['remaining_owned_links']),1)
        self.assertTrue(targets[1].is_file())
        self.assertFalse(targets[0].exists())
        self.assertFalse(observations['complete'])
        self.assertFalse(observations['new_output_adoption_allowed'])
        self.assertIn('cleanup_error',observations)
        for row in observations['original_members']:
            actual=(args.output/row['path']).stat()
            self.assertEqual(row['after'],{name:getattr(actual,name) for name in row['after']})
        return args,output,observations,targets

    def test_interrupted_owned_cleanup_refreshes_final_source_and_remaining_links(self):
        args,output,observations,targets=self.interrupted_owned_cleanup('error')
        self.assertTrue(observations['failed_link_recovery_verified'])
        self.assertTrue(observations['source_content_mode_inode_preserved'])
        self.assertEqual(observations['remaining_owned_links'][0]['target'],str(targets[1]))
        self.assertEqual(observations['removed_owned_links'][0]['target'],str(targets[0]))
        for row in observations['original_members']:
            self.assertEqual(row['sha256_before'],row['sha256_after'])
            self.assertEqual(row['after']['st_nlink'],row['before']['st_nlink']+(row['path']==targets[1].name))
        self.verify_both(args.output)

    def test_owned_cleanup_rechecks_marker_between_removals(self):
        args,output,observations,targets=self.interrupted_owned_cleanup('marker')
        self.assertFalse(observations['failed_link_recovery_verified'])
        self.assertTrue(observations['source_content_mode_inode_preserved'])
        self.assertEqual((output/figure.COMPLETE).read_bytes(),b'foreign marker')
        self.verify_both(args.output)

    def test_owned_cleanup_rechecks_prior_source_between_removals(self):
        args,output,observations,targets=self.interrupted_owned_cleanup('source')
        self.assertFalse(observations['failed_link_recovery_verified'])
        self.assertFalse(observations['source_content_mode_inode_preserved'])
        changed=next(row for row in observations['original_members'] if row['path']==targets[0].name)
        self.assertNotEqual(changed['after']['st_size'],changed['before']['st_size'])
        self.assertIsNone(changed['sha256_after'])
        self.assertFalse((output/figure.COMPLETE).exists())

    def test_bounds_and_unresolved_resume_authority_refuse_before_output_creation(self):
        args = self.complete(); output=self.root/'not-created'
        with self.assertRaisesRegex(ValueError, 'bound|oversized'):
            figure.materialize_complete_capture(args.output/figure.MANIFEST,output,max_input_bytes=1)
        self.assertFalse(output.exists())
        manifest=json.loads((args.output/figure.MANIFEST).read_text())
        manifest['resumes']=[{'unresolved':True}]
        (args.output/figure.MANIFEST).write_bytes(figure.encoded(manifest))
        with self.assertRaisesRegex(ValueError, 'resume'):
            figure.materialize_complete_capture(args.output/figure.MANIFEST,output)
        self.assertFalse(output.exists())


    def test_mixed_full_and_lean_origins_keep_original_modes_and_oversized_rejection_evidence(self):
        args, proof, _ = self.fixture.make_oversize_prefix()
        args.metadata_mode = 'lean-tiff-v1'
        clock = [0.0]
        def transport(url, timeout):
            query = parse_qs(urlsplit(url).query)
            titles = query['titles'][0].split('|')
            light = 'metadata' not in query['iiprop'][0].split('|')
            return 200, {}, figure.encoded(self.fixture.combined_response(titles, light=light))
        with patch.object(figure.time, 'monotonic', side_effect=lambda:clock[0]):
            figure.capture_files(args, transport=transport, sleep=lambda delay:clock.__setitem__(0,clock[0]+delay))
        original = Path(json.loads(proof.read_text())['source_root'])
        output, manifest = self.materialize(args)
        plan = json.loads((output/figure.PLAN).read_text())
        modes = {json.loads((output/row['plan']['path']).read_text()).get('metadata_mode','full') for row in plan['materialized_http_origins']}
        self.assertEqual(modes, {'full', 'lean-tiff-v1'})
        closed = next(row for row in plan['materialized_http_origins'] if row['failure'])
        rejected = next(name for name in closed['files'] if name.endswith('000002-01.raw.json'))
        self.assertEqual((output/closed['files'][rejected]['path']).read_bytes(), (original/rejected).read_bytes())
        args.output.rename(self.root/'complete-unavailable')
        original.rename(self.root/'oversized-unavailable')
        proof.rename(proof.with_suffix('.unavailable'))
        self.assertEqual(self.verify_both(output), manifest)
        missing = output/closed['files'][rejected]['path']; missing.unlink()
        with self.assertRaises((ValueError, FileNotFoundError)): figure.verify(output)

    def test_rehashed_origin_plan_cannot_omit_its_declared_predecessor(self):
        args, _ = self.epoch_complete(); output, _ = self.materialize(args)
        plan=json.loads((output/figure.PLAN).read_text())
        row=next(row for row in plan['materialized_http_origins'] if row['id']==plan['materialized_root'])
        old_id=row['id']; old_directory=output/old_id
        original_plan=json.loads((output/row['plan']['path']).read_text())
        self.assertEqual(len(original_plan['closed_prefixes']),1)
        original_plan['closed_prefixes']=[]
        raw=figure.encoded(original_plan);(output/row['plan']['path']).write_bytes(raw)
        row['plan'].update(bytes=len(raw),sha256=figure.digest(raw))
        authority=json.loads((output/row['authority']['path']).read_text())
        authority['artifacts'][figure.PLAN]={'bytes':len(raw),'sha256':figure.digest(raw)}
        raw=figure.encoded(authority);(output/row['authority']['path']).write_bytes(raw)
        row['authority'].update(bytes=len(raw),sha256=figure.digest(raw))
        row['source_reference']['sha256']=figure.digest(raw)
        marker=figure.encoded({'schema':figure.SCHEMA,'manifest_sha256':figure.digest(raw)})
        (output/row['complete']['path']).write_bytes(marker)
        row['complete'].update(bytes=len(marker),sha256=figure.digest(marker))
        new_id='figure-origin-'+figure.digest(raw)
        def replace(value):
            if isinstance(value,str):return new_id+value[len(old_id):] if value.startswith(old_id) else value
            if isinstance(value,list):return [replace(item) for item in value]
            if isinstance(value,dict):return {key:replace(item) for key,item in value.items()}
            return value
        plan=replace(plan);old_directory.rename(output/new_id)
        lines=(output/figure.FILE_REQUESTS).read_bytes().splitlines(keepends=True)
        (output/figure.FILE_REQUESTS).write_bytes(b''.join(figure.stream_encoded(replace(figure.stream_decode(line))) for line in lines))
        (output/figure.PLAN).write_bytes(figure.encoded(plan))
        manifest=json.loads((output/figure.MANIFEST).read_text());manifest['artifacts']=figure.payload(output)
        (output/figure.MANIFEST).write_bytes(figure.encoded(manifest))
        (output/figure.COMPLETE).write_bytes(figure.encoded({'schema':figure.SCHEMA,
            'manifest_sha256':figure.digest((output/figure.MANIFEST).read_bytes())}))
        with self.assertRaisesRegex(ValueError,'predecessor selection differs'):
            figure.verify(output)


class MaterializedFigureConsumerTests(unittest.TestCase):
    setUp = OfflineFigureMaterializationTests.setUp
    complete = OfflineFigureMaterializationTests.complete
    materialize = OfflineFigureMaterializationTests.materialize
    verify_both = OfflineFigureMaterializationTests.verify_both

    def paths(self, root):
        return {role:root/name for role,name in {**figure.ROLES,'file-metadata':figure.PROVIDER}.items()}

    def test_normal_staging_keeps_contained_bytes_and_full_verification_without_parent_payloads(self):
        args=self.complete();output,_=self.materialize(args)
        args.output.rename(self.root/'original-payload-unavailable')
        paths=self.paths(output)
        key=lambda selected:tuple(sorted((role,str(path.absolute())) for role,path in selected.items()))
        with patch.object(builder,'_FIGURE_TUPLE_REPLAYS',{}), \
                patch.object(figure,'verify_tuple',wraps=figure.verify_tuple) as replay, \
                patch.object(builder,'copy_verified_snapshot',wraps=builder.copy_verified_snapshot) as copied:
            guard=builder.figure_tuple_guard(figure,output)
            self.assertIsNotNone(guard)
            members,directories=figure.capture_member_paths(output,include_markers=True)
            self.assertTrue({str(path) for path in members.values()} <= set(guard[1]))
            self.assertTrue({str(path) for path in directories} <= set(guard[2]))
            original=builder.validated_figure_tuple(paths,self.fixture.wiki,self.fixture.date)
            self.assertEqual(replay.call_count,1)
            self.assertEqual(set(builder._FIGURE_TUPLE_REPLAYS),{key(paths)})
            pinned=builder.pinned_auxiliary_snapshots(paths,
                {role:builder.sha256_file(path) for role,path in paths.items()},self.root/'normal-stage')
            staged=next(iter(pinned.values())).parent
            self.assertNotEqual(staged,output)
            self.assertEqual(replay.call_count,2)
            self.assertEqual(copied.call_count,len(members))
            self.assertEqual(set(figure.capture_member_paths(staged,include_markers=True)[0]),set(members))
            for name,path in members.items():self.assertEqual((staged/name).read_bytes(),path.read_bytes())
            self.assertEqual(set(builder._FIGURE_TUPLE_REPLAYS),{key(paths),key(pinned)})
            output.rename(self.root/'materialized-source-unavailable')
            self.assertEqual(builder.validated_figure_tuple(pinned,self.fixture.wiki,self.fixture.date),original)
            self.assertEqual(replay.call_count,2)

    def test_normal_staging_refuses_contained_destination_symlink_without_external_writes(self):
        args=self.complete();output,_=self.materialize(args)
        paths=self.paths(output);plan=json.loads((output/figure.PLAN).read_text())
        destination=self.root/'unsafe-stage';folder=destination/'figure-inputs';folder.mkdir(parents=True)
        external=self.root/'external';external.mkdir()
        (folder/plan['materialized_root']).symlink_to(external,target_is_directory=True)
        with patch.object(builder,'_FIGURE_TUPLE_REPLAYS',{}):
            with self.assertRaisesRegex(ValueError,'Unsafe contained Figure staging directory'):
                builder.pinned_auxiliary_snapshots(paths,
                    {role:builder.sha256_file(path) for role,path in paths.items()},destination)
        self.assertEqual(list(external.iterdir()),[])
        self.verify_both(output)

    def test_materialization_releases_owned_documents_but_keeps_stamps_and_offsets(self):
        args=self.complete();root_key=('complete-stream',str(args.output/figure.MANIFEST))
        original=figure.read_complete_capture;held={}
        def read(path,cache=None,**options):
            result=original(path,cache,**options)
            if Path(path)==args.output/figure.MANIFEST:
                self.assertIs(options.get('include_document'),False)
                self.assertNotIn('document',result)
                held.update(cache=cache,stamps=dict(result['stamps']),offsets=list(result['offsets']))
            return result
        with patch.object(figure,'read_complete_capture',side_effect=read):output,_=self.materialize(args)
        self.assertTrue(held)
        self.assertTrue(all(value is None or 'document' not in value for value in held['cache'].values()))
        self.assertEqual(held['cache'][root_key]['stamps'],held['stamps'])
        self.assertEqual(held['cache'][root_key]['offsets'],held['offsets'])
        figure.check_prefix_cache(held['cache'])
        self.verify_both(output)

    def test_original_source_change_after_document_release_still_prevents_completion(self):
        args=self.complete();root_key=('complete-stream',str(args.output/figure.MANIFEST))
        original=figure.check_prefix_cache;changed=[]
        def check(cache):
            value=cache.get(root_key)
            if isinstance(value,dict) and 'document' not in value and not changed:
                path=args.output/figure.PLAN;path.write_bytes(path.read_bytes()+b' ');changed.append(path)
            return original(cache)
        with patch.object(figure,'check_prefix_cache',side_effect=check):
            with self.assertRaisesRegex(ValueError,'changed'):self.materialize(args)
        self.assertTrue(changed)
        self.assertFalse((self.root/'self-contained'/figure.COMPLETE).exists())


class FixedSiteProfileTests(unittest.TestCase):
    setUp = FigureFileTests.setUp
    write_projection = FigureFileTests.write_projection
    response = FigureFileTests.response
    project = FigureFileTests.project
    batch = FigureFileTests.batch

    def test_fixed_site_is_checked_once_and_every_response_is_checked(self):
        batches = [self.batch('ملف:Profile%d.svg' % i) for i in range(8)]
        registration = figure._figure_site_registration
        with patch.object(figure, '_figure_site_registration', wraps=registration) as registrations:
            result = self.project(batches)
        self.assertEqual(len(result['records']), 8)
        self.assertEqual(registrations.call_count, 9)
        self.assertEqual(registrations.call_args_list[0].args[0], self.site_api)
        self.assertEqual([call.args[0] for call in registrations.call_args_list[1:]],
                         [json.loads(batch['response']) for batch in batches])

    def test_invalid_fixed_site_is_rejected_before_any_response(self):
        site = copy.deepcopy(self.site_api)
        site['query']['extensions'][0]['vcs-version'] = '0' * 40
        original = figure._figure_site_registration
        with patch.object(figure, '_figure_site_registration', wraps=original) as checked, \
                patch.object(figure.metadata, 'classify_response') as classified:
            with self.assertRaises(ValueError):
                self.project([self.batch()], site=site)
        self.assertEqual(checked.call_count, 1)
        self.assertEqual(checked.call_args.args[0], site)
        classified.assert_not_called()

    def test_later_response_keeps_server_core_language_and_registration_guards(self):
        title = 'ملف:Later.svg'
        for field, value in (('server', 'https://invalid.example'),
                             ('git-hash', '0' * 40), ('lang', 'en'),
                             ('media-registration', '0' * 40)):
            response = self.response(title)
            if field == 'media-registration':
                response['query']['extensions'][0]['vcs-version'] = value
            else:
                response['query']['general'][field] = value
            with self.subTest(field=field), self.assertRaises(ValueError):
                self.project([self.batch(), self.batch(title, response)])

class LeanMaterializationVerificationTests(unittest.TestCase):
    setUp = OfflineFigureMaterializationTests.setUp
    complete = OfflineFigureMaterializationTests.complete
    epoch_complete = OfflineFigureMaterializationTests.epoch_complete
    materialize = OfflineFigureMaterializationTests.materialize
    verify_both = OfflineFigureMaterializationTests.verify_both
    rebind = OfflineFigureMaterializationTests.rebind

    def test_materialization_uses_authenticated_plan_for_every_terminal_frame(self):
        args = self.complete()
        original = figure.terminal_http_origin
        calls = []
        def origin(root, source, *, origin_plan=None):
            if Path(root) == args.output:
                self.assertIsNotNone(origin_plan, 'reloaded a plan already authenticated by this operation')
                calls.append((source, origin_plan))
            return original(root, source, origin_plan=origin_plan)
        with patch.object(figure, 'terminal_http_origin', side_effect=origin):
            output, manifest = self.materialize(args)
        self.assertTrue(calls)
        for name in (*figure.ROLES.values(), figure.PROVIDER):
            self.assertEqual((output/name).read_bytes(), (args.output/name).read_bytes())
        self.assertEqual(self.verify_both(output), manifest)

    def test_plan_reuse_still_refuses_source_mutation_during_frame_resolution(self):
        args = self.complete()
        original = figure._verified_contained_http_leaf
        original_read = figure.read_complete_capture
        changed, verified = [], []
        plan_path = args.output/figure.PLAN
        plan_before = plan_path.read_bytes()
        def read(path, cache=None, **options):
            result = original_read(path, cache, **options)
            if Path(path) == args.output/figure.MANIFEST:
                verified.append(True)
            return result
        def leaf(node, slot, batch, cache, namespace, source_stamps):
            result = original(node, slot, batch, cache, namespace, source_stamps)
            # Mutate after actual complete verification and successful contained
            # leaf authentication, before the materializer's final source fence.
            if node['root'] == args.output and verified and not changed:
                self.assertIs(result, True)
                plan_path.write_bytes(plan_before+b' ')
                changed.append(plan_path)
            return result
        with patch.object(figure, 'read_complete_capture', side_effect=read), \
                patch.object(figure, '_verified_contained_http_leaf', side_effect=leaf):
            with self.assertRaisesRegex(ValueError, 'changed'):
                self.materialize(args)
        self.assertTrue(verified)
        self.assertEqual(changed, [plan_path])
        self.assertEqual(plan_path.read_bytes(), plan_before+b' ')
        self.assertFalse((self.root/'self-contained').exists())
        self.assertFalse((self.root/'self-contained'/figure.COMPLETE).exists())

    def test_fresh_output_has_one_full_replay_and_keeps_normal_verification(self):
        args = self.complete()
        original = figure.verify
        calls = []
        def counted(root, *values, **options):
            calls.append((Path(root), options.get('require_complete', True)))
            return original(root, *values, **options)
        with patch.object(figure, 'verify', side_effect=counted):
            output, manifest = self.materialize(args)
        self.assertEqual([complete for root, complete in calls if root == output], [False])
        self.assertEqual(self.verify_both(output), manifest)

    def test_output_changes_during_verify_or_marker_publication_are_refused(self):
        args = self.complete()
        for boundary in ('verification', 'publication', 'publication-sql'):
            with self.subTest(boundary=boundary):
                output = self.root / ('lean-tamper-' + boundary)
                original_verify, original_document = figure.verify, figure.evidence.document
                def verify(root, *values, **options):
                    value = original_verify(root, *values, **options)
                    if Path(root) == output and boundary == 'verification':
                        with (output/figure.PROVIDER).open('ab') as stream:stream.write(b'\n')
                    return value
                def document(path, value):
                    result = original_document(path, value)
                    if Path(path) == output/figure.COMPLETE:
                        if boundary == 'publication':
                            with (output/figure.PROVIDER).open('ab') as stream:stream.write(b'\n')
                        elif boundary == 'publication-sql':
                            with Path(args.sql[0]).open('ab') as stream:stream.write(b'\0')
                    return result
                with patch.object(figure, 'verify', side_effect=verify), \
                        patch.object(figure.evidence, 'document', side_effect=document):
                    with self.assertRaisesRegex(ValueError, 'external authority changed during' if boundary == 'publication-sql' else 'output changed during'):
                        figure.materialize_complete_capture(args.output/figure.MANIFEST, output)



class MaterializedRootReplayTests(unittest.TestCase):
    setUp = OfflineFigureMaterializationTests.setUp
    complete = OfflineFigureMaterializationTests.complete
    epoch_complete = OfflineFigureMaterializationTests.epoch_complete
    materialize = OfflineFigureMaterializationTests.materialize
    verify_both = OfflineFigureMaterializationTests.verify_both
    rebind = OfflineFigureMaterializationTests.rebind


    def counted_verify(self, helper, output):
        raw_path = output/figure.ROLES['figure-sizing-raw']
        fingerprints = []
        original = helper.evidence.fingerprint
        def fingerprint(path):
            if Path(path) == raw_path:
                fingerprints.append(Path(path))
            return original(path)
        semantic_scopes = {'capture': 0, 'lean-titles': 0, 'lean-final': 0}
        active = []
        original_records = helper.file_records
        def records(*args, **options):
            semantic_scopes[active[-1] if active else 'capture'] += 1
            return original_records(*args, **options)
        def scoped(function, name):
            def call(*args, **options):
                active.append(name)
                try:
                    return function(*args, **options)
                finally:
                    self.assertEqual(active.pop(), name)
            return call
        original_replay = helper.replay_source
        def source_replay(root, source, *args, **options):
            if source.get('kind') == 'http-archived-lean':
                return scoped(original_replay, 'lean-final')(root, source, *args, **options)
            return original_replay(root, source, *args, **options)
        with patch.object(helper, 'raw_record_decode', wraps=helper.raw_record_decode) as decoded, \
                patch.object(helper, 'file_records', side_effect=records), \
                patch.object(helper, 'lean_tiff_titles', side_effect=scoped(helper.lean_tiff_titles, 'lean-titles')), \
                patch.object(helper, 'replay_source', side_effect=source_replay), \
                patch.object(helper.evidence, 'fingerprint', side_effect=fingerprint):
            result = helper.verify(output)
        self.assertEqual(active, [])
        return result, {'raw_decodes': decoded.call_count, 'semantic_passes': sum(semantic_scopes.values()),
                        'semantic_scopes': semantic_scopes, 'raw_fingerprints': len(fingerprints)}

    def verify_counts(self, output, manifest, origins):
        after, counts = self.counted_verify(figure, output)
        with (output/figure.ROLES['figure-sizing-raw']).open('rb') as source:
            header = figure.stream_decode(source.readline())
        frames = header['base_batches']+header['observed_batches']
        self.assertEqual(after, manifest)
        plan = json.loads((output/figure.PLAN).read_text())
        self.assertEqual(len(plan['materialized_http_origins']), origins)
        ancestor_frames = sum(len(row['frame_map']) for row in plan['materialized_http_origins']
                              if row['id'] != plan['materialized_root'])
        self.assertEqual(counts['raw_decodes'], 2*frames+ancestor_frames)
        self.assertEqual(counts['semantic_scopes']['capture'], origins)
        sources = list(figure.source_records(output/figure.FILE_REQUESTS, frames))
        lean_frames = sum(source['kind'] == 'http-archived-lean' for source in sources)
        lean_companions = sum(source['kind'] == 'http-archived-lean' and 'tiff_batch' in source for source in sources)
        self.assertEqual(counts['semantic_scopes']['lean-titles'], lean_frames)
        self.assertEqual(counts['semantic_scopes']['lean-final'], lean_companions)
        # Complete semantic streams now carry the exact raw digest to payload.
        self.assertEqual(counts['raw_fingerprints'], 0)

    def test_root_reuse_matches_original_manifest_and_eliminates_one_raw_semantic_pass(self):
        args = self.complete()
        output, manifest = self.materialize(args)
        args.output.rename(self.root/'predecessor-unavailable')
        self.verify_counts(output, manifest, 1)
        self.assertEqual(self.verify_both(output), manifest)

    def test_epoch_ancestor_replay_is_retained_and_root_reuse_matches_original(self):
        args, proof = self.epoch_complete()
        origin = Path(json.loads(proof.read_text())['source_root'])
        output, manifest = self.materialize(args)
        args.output.rename(self.root/'complete-unavailable')
        origin.rename(self.root/'closed-unavailable')
        proof.rename(proof.with_suffix('.unavailable'))
        self.verify_counts(output, manifest, 2)

    def test_different_semantic_context_falls_back_to_original_replay(self):
        args = self.complete()
        output, manifest = self.materialize(args)
        original = figure.validate_materialized_echo
        observed = []
        def validate(state, plan, wiki, date, namespace, *, root_record_count=None, verified_batches=None):
            self.assertIsNotNone(root_record_count)
            def decline(site, **options):
                result = root_record_count(site, **options)
                self.assertEqual(result, options['record_limit'])
                for field, value in (
                        ('site', site+b' '), ('has_batches', not options['has_batches']),
                        ('record_limit', options['record_limit']+1), ('profile_kind', 'unreviewed-profile'),
                        ('allow_compatible_epochs', not options['allow_compatible_epochs']),
                        ('allow_tiff_companion', not options['allow_tiff_companion']),
                        ('allow_decimal_tiff_axes', not options['allow_decimal_tiff_axes']),
                        ('allow_default_tiff_page', not options['allow_default_tiff_page'])):
                    changed = dict(options)
                    if field == 'site':
                        self.assertIsNone(root_record_count(value, **changed))
                    else:
                        changed[field] = value
                        self.assertIsNone(root_record_count(site, **changed))
                observed.append(True)
                return None
            return original(state, plan, wiki, date, namespace, root_record_count=decline, verified_batches=verified_batches)
        with patch.object(figure, 'validate_materialized_echo', side_effect=validate):
            result, counts = self.counted_verify(figure, output)
        self.assertEqual(observed, [True])
        self.assertEqual(result, manifest)
        self.assertEqual(counts['semantic_passes'], 2)

    def test_reuse_refuses_in_place_replacement_symlink_and_directory_mutations(self):
        import os
        args = self.complete()
        output, manifest = self.materialize(args)
        raw_path = output/figure.ROLES['figure-sizing-raw']
        raw = raw_path.read_bytes()
        original = figure.validate_materialized_echo
        for mutation in ('same-inode', 'replacement', 'symlink', 'directory'):
            with self.subTest(mutation=mutation):
                self.assertEqual(figure.verify(output), manifest)
                info = raw_path.stat()
                directory_mode = output.stat().st_mode
                reached = []
                def validate(*values, **options):
                    reached.append(True)
                    if mutation == 'same-inode':
                        raw_path.write_bytes(raw)
                        os.utime(raw_path, ns=(info.st_atime_ns, info.st_mtime_ns))
                        self.assertEqual(raw_path.stat().st_ino, info.st_ino)
                        self.assertEqual(raw_path.stat().st_size, info.st_size)
                        self.assertEqual(raw_path.stat().st_mtime_ns, info.st_mtime_ns)
                        self.assertNotEqual(raw_path.stat().st_ctime_ns, info.st_ctime_ns)
                    elif mutation == 'replacement':
                        replacement = self.root/'replacement.raw'
                        replacement.write_bytes(raw)
                        os.replace(replacement, raw_path)
                    elif mutation == 'symlink':
                        target = self.root/'symlink-target.raw'
                        target.write_bytes(raw)
                        raw_path.unlink()
                        raw_path.symlink_to(target)
                    else:
                        output.chmod(directory_mode ^ 0o1000)
                    return original(*values, **options)
                try:
                    with patch.object(figure, 'validate_materialized_echo', side_effect=validate):
                        with self.assertRaises(ValueError):
                            figure.verify(output)
                    self.assertEqual(reached, [True])
                finally:
                    if raw_path.is_symlink(): raw_path.unlink()
                    raw_path.write_bytes(raw)
                    output.chmod(directory_mode)
        self.assertEqual(figure.verify(output), manifest)

    def test_reuse_end_guard_refuses_mutation_after_original_semantic_validation(self):
        import os
        args = self.complete()
        output, manifest = self.materialize(args)
        raw_path = output/figure.ROLES['figure-sizing-raw']
        raw = raw_path.read_bytes()
        original = figure.validate_materialized_echo
        for mutation in ('raw', 'directory'):
            with self.subTest(mutation=mutation):
                info = raw_path.stat()
                mode = output.stat().st_mode
                completed = []
                def validate(*values, **options):
                    result = original(*values, **options)
                    completed.append(True)
                    if mutation == 'raw':
                        raw_path.write_bytes(raw)
                        os.utime(raw_path, ns=(info.st_atime_ns, info.st_mtime_ns))
                    else:
                        output.chmod(mode ^ 0o1000)
                    return result
                try:
                    with patch.object(figure, 'validate_materialized_echo', side_effect=validate):
                        with self.assertRaisesRegex(ValueError, 'identity changed after root semantic reuse'):
                            figure.verify(output)
                    self.assertEqual(completed, [True])
                finally:
                    raw_path.write_bytes(raw)
                    output.chmod(mode)
        self.assertEqual(figure.verify(output), manifest)

    def test_raw_projection_receipt_and_source_corruption_keep_original_refusals(self):
        args = self.complete()
        output, manifest = self.materialize(args)
        plan = json.loads((output/figure.PLAN).read_text())
        row = plan['materialized_http_origins'][0]
        receipt = next(value['path'] for name, value in row['files'].items() if name.endswith('.receipt.json'))
        for name in (figure.ROLES['figure-sizing-raw'], figure.ROLES['figure-sizing'], receipt, figure.FILE_REQUESTS):
            path = output/name
            raw = path.read_bytes()
            with self.subTest(member=name):
                try:
                    path.write_bytes(b'!' + raw[1:])
                    with self.assertRaises((ValueError, KeyError)):
                        figure.verify(output)
                finally:
                    path.write_bytes(raw)
        self.assertEqual(figure.verify(output), manifest)

    def test_indexed_ancestor_refuses_mutation_while_its_file_descriptor_is_open(self):
        import os
        args, _ = self.epoch_complete()
        output, manifest = self.materialize(args)
        raw_path = output/figure.ROLES['figure-sizing-raw']
        raw = raw_path.read_bytes()
        original = figure.validate_materialized_echo
        for mutation in ('same-inode', 'replacement'):
            with self.subTest(mutation=mutation):
                changed = []
                def validate(*values, root_record_count=None, verified_batches=None, **options):
                    self.assertIsNotNone(verified_batches)
                    def indexed(selected):
                        for batch in verified_batches(selected):
                            if not changed:
                                info = raw_path.stat()
                                if mutation == 'same-inode':
                                    raw_path.write_bytes(raw)
                                    os.utime(raw_path, ns=(info.st_atime_ns, info.st_mtime_ns))
                                else:
                                    replacement = self.root/'indexed-replacement.raw'
                                    replacement.write_bytes(raw)
                                    os.replace(replacement, raw_path)
                                changed.append(True)
                            yield batch
                    return original(*values, root_record_count=root_record_count, verified_batches=indexed, **options)
                try:
                    with patch.object(figure, 'validate_materialized_echo', side_effect=validate):
                        with self.assertRaisesRegex(ValueError, 'changed'):
                            figure.verify(output)
                    self.assertEqual(changed, [True])
                finally:
                    raw_path.write_bytes(raw)
        self.assertEqual(figure.verify(output), manifest)

    def test_unselected_corruption_trailing_count_and_invalid_maps_still_refuse(self):
        args, _ = self.epoch_complete()
        output, manifest = self.materialize(args)
        raw_path = output/figure.ROLES['figure-sizing-raw']
        raw = raw_path.read_bytes()
        lines = raw.splitlines(keepends=True)
        plan = json.loads((output/figure.PLAN).read_text())
        origin = next(row for row in plan['materialized_http_origins'] if row['id'] != plan['materialized_root'])
        unselected = next(number for number in range(len(lines)-1) if number not in origin['frame_map'])
        bad_line = list(lines)
        bad_line[unselected+1] = b'!'+bad_line[unselected+1][1:]
        bad_header = figure.stream_decode(lines[0])
        bad_header['base_batches'] += 1
        for kind, changed in (('unselected', b''.join(bad_line)), ('trailing', raw+b'{}\n'),
                              ('count', figure.stream_encoded(bad_header)+b''.join(lines[1:]))):
            with self.subTest(kind=kind):
                try:
                    raw_path.write_bytes(changed)
                    with self.assertRaises((ValueError, KeyError, StopIteration)):
                        figure.verify(output)
                finally:
                    raw_path.write_bytes(raw)
        for kind in ('root-reordered', 'ancestor-reordered', 'ancestor-subset'):
            with self.subTest(kind=kind):
                changed = copy.deepcopy(plan)
                row = next(row for row in changed['materialized_http_origins']
                           if (row['id'] == changed['materialized_root']) == (kind == 'root-reordered'))
                self.assertGreater(len(row['frame_map']), 1)
                row['frame_map'] = row['frame_map'][:-1] if kind == 'ancestor-subset' else list(reversed(row['frame_map']))
                try:
                    self.rebind(output, changed)
                    with self.assertRaises((ValueError, KeyError)):
                        figure.verify(output)
                finally:
                    self.rebind(output, plan)
        self.assertEqual(figure.verify(output), manifest)

    def test_ordinary_capture_keeps_full_verification_without_index_allocation(self):
        args = self.complete()
        manifest = json.loads((args.output/figure.MANIFEST).read_text())
        original = figure.stream_values
        collectors = []
        def values(*args, **options):
            collectors.append(options.get('record_offsets'))
            return original(*args, **options)
        with patch.object(figure, 'stream_values', side_effect=values):
            after = figure.verify(args.output)
        self.assertEqual(after, manifest)
        self.assertTrue(collectors)
        self.assertTrue(all(value is None for value in collectors))


    def test_current_api_index_preserves_identity_completion_and_open_file_refusal(self):
        import os
        args = self.complete()
        raw = args.output/figure.ROLES['figure-sizing-raw']
        identity, offsets = {}, []
        iterator = figure.stream_values(raw, figure.RAW_STREAM_SCHEMA, identity_out=identity, record_offsets=offsets)
        next(iterator); next(iterator)
        iterator.close()
        self.assertEqual(identity, {})
        identity, offsets = {}, []
        values = list(figure.stream_values(raw, figure.RAW_STREAM_SCHEMA, identity_out=identity, record_offsets=offsets))
        expected = figure.evidence.fingerprint(raw)
        self.assertEqual(identity, {'size': expected['size'], 'sha256': expected['sha256']})
        self.assertEqual(len(offsets), len(values)-1)
        with raw.open('rb') as stream:
            for offset, size, sha in offsets:
                stream.seek(offset)
                self.assertEqual(figure.digest(stream.read(size)), sha)
        for invalid in ({}, [(0, 1, '0'*64)], ()):
            with self.subTest(index=invalid), self.assertRaises(ValueError):
                list(figure.stream_values(raw, figure.RAW_STREAM_SCHEMA, record_offsets=invalid))
        identity, offsets = {}, []
        iterator = figure.stream_values(raw, figure.RAW_STREAM_SCHEMA, identity_out=identity, record_offsets=offsets)
        next(iterator); next(iterator)
        replacement = self.root/'indexed-current-replacement.raw'
        replacement.write_bytes(raw.read_bytes())
        os.replace(replacement, raw)
        with self.assertRaises(ValueError):
            list(iterator)
        self.assertEqual(identity, {})

    def test_materialized_current_tiff_options_keep_semantic_policy(self):
        for mode in ('decimal', 'default-page'):
            with self.subTest(mode=mode):
                response = (self.fixture.decimal_tiff_response() if mode == 'decimal'
                            else self.fixture.default_page_tiff_response())
                args = self.fixture.args(links=('B.tif',))
                args.output = self.root/('complete-tiff-'+mode)
                now, advance = self.fixture.overlap_clock()
                def transport(url, timeout):
                    self.assertEqual(parse_qs(urlsplit(url).query)['titles'], ['ملف:B.tif'])
                    return 200, {}, figure.encoded(response)
                with patch.object(figure.time, 'monotonic', side_effect=now):
                    figure.capture_files(args, transport=transport, sleep=advance)
                output = self.root/('materialized-tiff-'+mode)
                manifest = figure.materialize_complete_capture(args.output/figure.MANIFEST, output)
                self.verify_counts(output, manifest, 1)
                document = self.fixture.stream_document(output)
                self.assertEqual(document['replay_contract'], figure.REPLAY_CONTRACT)
                self.assertEqual(document['records'][0]['state'], 'eligible' if mode == 'decimal' else 'tiff_default_page')

class MaterializedBorrowTests(unittest.TestCase):
    setUp = MaterializedFigureConsumerTests.setUp
    complete = MaterializedFigureConsumerTests.complete
    materialize = MaterializedFigureConsumerTests.materialize
    verify_both = MaterializedFigureConsumerTests.verify_both
    paths = MaterializedFigureConsumerTests.paths

    def borrower(self):
        value=builder.RetainedNativeToolRoles.__new__(builder.RetainedNativeToolRoles)
        value.inputs={};value.input_identities={};value.directories={};value.tools={}
        return value

    def selection(self):
        args=self.complete();output,_=self.materialize(args)
        args.output.rename(self.root/'predecessor-unavailable')
        paths=self.paths(output)
        hashes={role:builder.sha256_file(path) for role,path in paths.items()}
        builder._FIGURE_TUPLE_REPLAYS.clear()
        return output,paths,hashes

    def test_nested_capture_borrows_after_one_full_validation_and_guards_every_member(self):
        output,paths,hashes=self.selection();roles=self.borrower()
        with patch.object(figure,'verify_tuple',wraps=figure.verify_tuple) as replay, patch.object(builder,'copy_verified_snapshot',wraps=builder.copy_verified_snapshot) as copied:
            pinned=builder.pinned_auxiliary_snapshots(paths,hashes,self.root/'destination',borrower=roles)
        self.assertEqual(pinned,paths);self.assertEqual(replay.call_count,1);self.assertEqual(copied.call_count,0)
        members,directories=figure.capture_member_paths(output,include_markers=True)
        self.assertTrue(any('/' in name for name in members))
        self.assertTrue(set(members.values())<=set(roles.inputs))
        self.assertTrue(set(directories)<=set(roles.borrowed_capture_directories))
        roles.require_unchanged()
        member=next(path for name,path in members.items() if '/' in name)
        member.write_bytes(member.read_bytes()+b' ')
        with self.assertRaises(ValueError):roles.require_unchanged()

    def refusal(self,kind):
        output,paths,hashes=self.selection();roles=self.borrower()
        builder.validated_figure_tuple(paths)
        members,_=figure.capture_member_paths(output,include_markers=True)
        member=next(path for name,path in members.items() if '/' in name)
        if kind=='changed':member.write_bytes(member.read_bytes()+b' ')
        elif kind=='missing':member.unlink()
        elif kind=='extra':(member.parent/'unexpected.json').write_bytes(b'{}')
        elif kind=='symlink':
            raw=member.read_bytes();member.unlink();external=self.root/'external.json';external.write_bytes(raw);member.symlink_to(external)
        with patch.object(builder,'copy_verified_snapshot',wraps=builder.copy_verified_snapshot) as copied:
            with self.assertRaises((ValueError,OSError)):
                builder.pinned_auxiliary_snapshots(paths,hashes,self.root/'destination',borrower=roles)
        self.assertEqual(copied.call_count,0)
        self.assertFalse((self.root/'destination').exists())

    def test_changed_member_refuses(self):self.refusal('changed')
    def test_missing_member_refuses(self):self.refusal('missing')
    def test_extra_member_refuses(self):self.refusal('extra')
    def test_symlink_member_refuses(self):self.refusal('symlink')


    def test_same_figure_capture_binds_once_per_staging_invocation(self):
        output,paths,hashes=self.selection();roles=self.borrower();timing={}
        with patch.object(roles,'bind_capture',wraps=roles.bind_capture) as binding, patch.object(figure,'verify_tuple',wraps=figure.verify_tuple) as replay, patch.object(builder,'copy_verified_snapshot',wraps=builder.copy_verified_snapshot) as copied:
            pinned=builder.pinned_auxiliary_snapshots(paths,hashes,self.root/'once',borrower=roles,phase_outcome=timing)
        self.assertEqual(pinned,paths);self.assertEqual(binding.call_count,1)
        self.assertEqual(replay.call_count,1);self.assertEqual(copied.call_count,0)
        self.assertEqual(timing['capture_bindings'],1)
        self.assertEqual(timing['reused_capture_bindings'],len(paths)-1)
        members,directories=figure.capture_member_paths(output,include_markers=True)
        self.assertTrue(set(members.values())<=set(roles.inputs))
        self.assertTrue(set(directories)<=set(roles.borrowed_capture_directories))
        roles.require_unchanged()
        self.assertFalse((self.root/'once').exists())

    def test_capture_binding_reuse_does_not_escape_invocation_or_cross_roots(self):
        import shutil
        output,paths,hashes=self.selection();roles=self.borrower()
        other=self.root/'other-capture';shutil.copytree(output,other)
        other_paths=self.paths(other)
        with patch.object(roles,'bind_capture',wraps=roles.bind_capture) as binding:
            first=builder.pinned_auxiliary_snapshots(paths,hashes,self.root/'first',borrower=roles)
            again=builder.pinned_auxiliary_snapshots(paths,hashes,self.root/'again',borrower=roles)
            second=builder.pinned_auxiliary_snapshots(other_paths,hashes,self.root/'second',borrower=roles)
        self.assertEqual(first,paths);self.assertEqual(again,paths);self.assertEqual(second,other_paths)
        self.assertEqual([call.args[0] for call in binding.call_args_list],[output,output,other])
        self.assertTrue(set(paths.values())|set(other_paths.values())<=set(roles.inputs))
        roles.require_unchanged()

    def test_reused_binding_still_refuses_in_place_mutation_before_return(self):
        output,paths,hashes=self.selection();roles=self.borrower()
        members,_=figure.capture_member_paths(output,include_markers=True)
        member=next(path for name,path in members.items() if '/' in name)
        original=roles.bind_capture
        def changed(*args,**kwargs):
            original(*args,**kwargs)
            member.write_bytes(member.read_bytes()+b' ')
        with patch.object(roles,'bind_capture',side_effect=changed) as binding, patch.object(builder,'copy_verified_snapshot',wraps=builder.copy_verified_snapshot) as copied:
            with self.assertRaises(ValueError):
                builder.pinned_auxiliary_snapshots(paths,hashes,self.root/'changed',borrower=roles)
        self.assertEqual(binding.call_count,1);self.assertEqual(copied.call_count,0)
        self.assertFalse((self.root/'changed').exists())

    def test_reused_binding_still_refuses_same_bytes_root_replacement(self):
        import shutil
        output,paths,hashes=self.selection();roles=self.borrower()
        original=roles.bind_capture
        def replaced(*args,**kwargs):
            original(*args,**kwargs)
            held=self.root/'original-held';output.rename(held);shutil.copytree(held,output)
        with patch.object(roles,'bind_capture',side_effect=replaced) as binding, patch.object(builder,'copy_verified_snapshot',wraps=builder.copy_verified_snapshot) as copied:
            with self.assertRaises(ValueError):
                builder.pinned_auxiliary_snapshots(paths,hashes,self.root/'replaced',borrower=roles)
        self.assertEqual(binding.call_count,1);self.assertEqual(copied.call_count,0)
        self.assertFalse((self.root/'replaced').exists())

    def test_reused_binding_still_refuses_new_contained_member(self):
        output,paths,hashes=self.selection();roles=self.borrower()
        members,_=figure.capture_member_paths(output,include_markers=True)
        member=next(path for name,path in members.items() if '/' in name)
        original=roles.bind_capture
        def extra(*args,**kwargs):
            original(*args,**kwargs)
            (member.parent/'unexpected.json').write_bytes(b'{}')
        with patch.object(roles,'bind_capture',side_effect=extra) as binding:
            with self.assertRaises(ValueError):
                builder.pinned_auxiliary_snapshots(paths,hashes,self.root/'extra',borrower=roles)
        self.assertEqual(binding.call_count,1);self.assertFalse((self.root/'extra').exists())

    def test_changed_replay_descriptor_cannot_reuse_its_mutable_identity(self):
        output,paths,hashes=self.selection();roles=self.borrower()
        builder.validated_figure_tuple(paths)
        original=roles.bind_capture;bound=False;mutated=False
        class ChangedDescriptor(dict):
            def get(cache,key,default=None):
                nonlocal mutated
                value=super().get(key,default)
                if bound and not mutated and value is not None:
                    identity=next(iter(value[0][1].values()))[1]
                    identity['sha256']='0'*64 if identity['sha256']!='0'*64 else '1'*64
                    mutated=True
                return value
        cache=ChangedDescriptor(builder._FIGURE_TUPLE_REPLAYS)
        def binding(*args,**kwargs):
            nonlocal bound
            original(*args,**kwargs);bound=True
        try:
            with patch.object(builder,'_FIGURE_TUPLE_REPLAYS',cache), patch.object(roles,'bind_capture',side_effect=binding) as calls:
                with self.assertRaises(ValueError):
                    builder.pinned_auxiliary_snapshots(paths,hashes,self.root/'descriptor',borrower=roles)
            self.assertTrue(mutated);self.assertEqual(calls.call_count,2)
            self.assertFalse((self.root/'descriptor').exists())
        finally:
            builder._FIGURE_TUPLE_REPLAYS.clear()

    def test_provider_phase_timers_preserve_hashes_and_validation_errors(self):
        import io
        from contextlib import redirect_stdout
        path=self.root/'language-registry.tsv';path.write_bytes(b'unchanged provider bytes\n')
        snapshots={'language-registry':path}
        for failure in (False,True):
            with self.subTest(failure=failure):
                stream=io.StringIO()
                with patch.object(builder,'validated_figure_tuple',return_value={}), patch.object(builder,'validated_auxiliary_capture',side_effect=ValueError('provider refusal') if failure else None,return_value=None), redirect_stdout(stream):
                    if failure:
                        with self.assertRaisesRegex(ValueError,'provider refusal'):
                            builder._validated_auxiliary_state(snapshots,'enwiktionary','20261001')
                    else:
                        hashes,captures=builder._validated_auxiliary_state(snapshots,'enwiktionary','20261001')
                        self.assertEqual(hashes,{'language-registry':builder.sha256_file(path)})
                        self.assertEqual(captures,{})
                rows=[json.loads(line.removeprefix('BUILD_PHASE ')) for line in stream.getvalue().splitlines()]
                self.assertEqual([(row['provider'],row['event']) for row in rows],[('figure-tuple','start'),('figure-tuple','end'),('language-registry','start'),('language-registry','end')])
                self.assertTrue(all(row['phase']=='auxiliary_provider_verification' for row in rows))
                self.assertEqual(rows[-1]['status'],'failure' if failure else 'success')
                self.assertGreaterEqual(rows[-1]['seconds'],0)

    def test_snapshot_resolution_timer_is_pre_edition_and_preserves_failure(self):
        import io
        from contextlib import redirect_stdout
        language=self.root/'language-registry.tsv';language.write_bytes(b'language bytes\n')
        namespace=self.root/'namespace-registry.tsv';namespace.write_bytes(b'namespace bytes\n')
        snapshots={'language-registry':language,'namespace-registry':namespace}
        manifest={'language_registries':[dict(wiki='enwiktionary',date='20261001',name=language.name,size=language.stat().st_size,sha256=builder.sha256_file(language))]}
        groups={('enwiktionary','20261001'):[]}
        for failure in (False,True):
            with self.subTest(failure=failure):
                stream=io.StringIO()
                with patch.object(builder,'derived_registry_paths',return_value={}), patch.object(builder,'verified_auxiliary_hashes',side_effect=ValueError('selection refusal') if failure else None,return_value={}) as validate, redirect_stdout(stream):
                    if failure:
                        with self.assertRaisesRegex(ValueError,'selection refusal'):
                            builder.resolve_edition_snapshot_options(manifest,groups,self.root,snapshots)
                    else:
                        actual=builder.resolve_edition_snapshot_options(manifest,groups,self.root,snapshots)
                        self.assertEqual(actual,{('enwiktionary','20261001'):{'auxiliary_snapshots':snapshots}})
                validate.assert_called_once_with(snapshots,'enwiktionary','20261001',captured_selection=None)
                rows=[json.loads(line.removeprefix('BUILD_PHASE ')) for line in stream.getvalue().splitlines()]
                self.assertEqual([row['event'] for row in rows],['start','end'])
                self.assertTrue(all(row['phase']=='selected_snapshot_resolution' and row['scope']=='pre_edition' for row in rows))
                self.assertEqual(rows[-1]['status'],'failure' if failure else 'success')
                self.assertGreaterEqual(rows[-1]['seconds'],0)



class GeneratedProjectionTests(unittest.TestCase):
    def setUp(self):
        self.fixture = FigureFileTests()
        self.fixture.setUp()
        self.addCleanup(self.fixture.doCleanups)
        self.serial = 0

    def capture(self):
        self.serial += 1
        args = self.fixture.args(links=('Example.svg', 'Second.svg'))
        args.output = self.fixture.root / ('generation-' + str(self.serial))
        args.batch_size = 1
        def transport(url, timeout):
            title = parse_qs(urlsplit(url).query)['titles'][0]
            return 200, {}, figure.encoded(self.fixture.response(title))
        manifest = figure.capture_files(args, transport=transport, sleep=lambda _: None)
        return args, manifest

    def remove_projection(self, root):
        path = root / figure.ROLES['figure-sizing']
        data, st = path.read_bytes(), path.stat()
        request = dict(header=json.loads(data.splitlines()[0]), mode=figure.stat.S_IMODE(st.st_mode),
                       mtime_ns=st.st_mtime_ns)
        path.unlink()
        (root / figure.COMPLETE).unlink()
        return request, data

    def test_generated_projection_full_capture_equals_normal_with_one_derivation(self):
        args, manifest = self.capture()
        before = {p.name: p.read_bytes() for p in args.output.iterdir()}
        with patch.object(figure, 'figure_stream_document', wraps=figure.figure_stream_document) as derive:
            self.assertEqual(figure.verify(args.output), manifest)
            self.assertEqual(derive.call_count, 1)
        request, original = self.remove_projection(args.output)
        with patch.object(figure, 'figure_stream_document', wraps=figure.figure_stream_document) as derive, \
                patch.object(figure, 'verify_provider_stream', wraps=figure.verify_provider_stream) as provider, \
                patch.object(figure, 'verify_inventory', wraps=figure.verify_inventory) as inventory, \
                patch.object(figure, 'replay_source', wraps=figure.replay_source) as sources, \
                patch.object(figure, 'payload', wraps=figure.payload) as payload:
            result = figure.verify(args.output, require_complete=False, regenerate_projection=request)
            self.assertEqual(result, manifest)
            self.assertEqual(derive.call_count, 1)
            self.assertEqual(provider.call_count, 1)
            self.assertEqual(inventory.call_count, 1)
            self.assertEqual(sources.call_count, 2)
            self.assertEqual(payload.call_count, 1)
        projection = args.output / figure.ROLES['figure-sizing']
        self.assertEqual(projection.read_bytes(), original)
        self.assertEqual(projection.stat().st_mtime_ns, request['mtime_ns'])
        self.assertEqual(figure.stat.S_IMODE(projection.stat().st_mode), request['mode'])
        self.assertFalse((args.output / figure.COMPLETE).exists())
        self.assertEqual({p.name: p.read_bytes() for p in args.output.iterdir()},
                         {name: data for name, data in before.items() if name != figure.COMPLETE})

    def test_generated_projection_retains_legacy_and_current_reducer_options(self):
        args, _ = self.capture()
        root = args.output
        raw = root / figure.ROLES['figure-sizing-raw']
        values = list(figure.stream_values(raw, figure.RAW_STREAM_SCHEMA))
        raw_header, batches = values[0], values[1:]
        plain = root / 'context.raw'
        plain.write_bytes(figure.stream_encoded({k: v for k, v in raw_header.items() if k != 'record_encoding'}) +
                          b''.join(figure.stream_encoded(batch) for batch in batches))
        projection = root / 'context.projection'
        namespace = self.fixture.namespace.read_bytes()
        site = (root / figure.ROLES['figure-sizing-site']).read_bytes()
        for contract in (None, figure.REPLAY_CONTRACT_V1, figure.REPLAY_CONTRACT_V2,
                         figure.REPLAY_CONTRACT_V3, figure.REPLAY_CONTRACT_V4, figure.REPLAY_CONTRACT):
            with self.subTest(contract=contract):
                options = dict(profile_kind=figure.FIGURE_PROFILE_V3,
                    allow_tiff_companion=contract is not None,
                    allow_encoded=contract in (figure.REPLAY_CONTRACT_V2, figure.REPLAY_CONTRACT_V3,
                                               figure.REPLAY_CONTRACT_V4, figure.REPLAY_CONTRACT),
                    allow_compatible_epochs=contract in (figure.REPLAY_CONTRACT_V3, figure.REPLAY_CONTRACT_V4, figure.REPLAY_CONTRACT),
                    allow_decimal_tiff_axes=contract in (figure.REPLAY_CONTRACT_V4, figure.REPLAY_CONTRACT),
                    allow_default_tiff_page=contract == figure.REPLAY_CONTRACT)
                document = figure.figure_stream_document(plain, namespace, self.fixture.wiki, self.fixture.date, site, **options)
                document['generator_sha256'] = 'a' * 64
                if contract is None: document.pop('replay_contract')
                else: document['replay_contract'] = contract
                request = dict(header={k: v for k, v in document.items() if k != 'records'}, mode=0o644, mtime_ns=123000000000)
                figure.write_projection_stream(projection, document)
                normal = figure.verify_stream_document(projection, plain, namespace, self.fixture.wiki, self.fixture.date, site)
                original = projection.read_bytes(); projection.unlink()
                with patch.object(figure, 'figure_stream_document', wraps=figure.figure_stream_document) as derive:
                    regenerated = figure.verify_stream_document(projection, plain, namespace, self.fixture.wiki,
                        self.fixture.date, site, regenerate_projection=request)
                    derive.assert_called_once_with(plain, namespace, self.fixture.wiki, self.fixture.date, site, **options)
                self.assertEqual(regenerated, normal)
                self.assertEqual(figure.provider_tsv(regenerated), figure.provider_tsv(normal))
                self.assertEqual(projection.read_bytes(), original)
                projection.unlink()

    def test_generated_projection_refuses_wrong_header_and_nonrequest_trust(self):
        args, _ = self.capture()
        request, original = self.remove_projection(args.output)
        for mutation in ('digest', 'count', 'namespace', 'contract', 'records', 'mode', 'mtime', 'extra'):
            selected = copy.deepcopy(request)
            if mutation == 'digest': selected['header']['raw_sha256'] = '0' * 64
            elif mutation == 'count': selected['header']['records_count'] += 1
            elif mutation == 'namespace': selected['header']['namespace_registry_sha256'] = '0' * 64
            elif mutation == 'contract': selected['header']['replay_contract'] = 'unproved-contract'
            elif mutation == 'records': selected['header']['records'] = []
            elif mutation == 'mode': selected['mode'] = True
            elif mutation == 'mtime': selected['mtime_ns'] = -1
            else: selected['trusted_document'] = {'records': []}
            with self.subTest(mutation=mutation), self.assertRaises(ValueError):
                figure.verify(args.output, require_complete=False, regenerate_projection=selected)
            self.assertFalse((args.output / figure.ROLES['figure-sizing']).exists())
            self.assertFalse((args.output / figure.COMPLETE).exists())
        with self.assertRaisesRegex(ValueError, 'incomplete capture'):
            figure.verify(args.output, regenerate_projection=request)
        projection = args.output / figure.ROLES['figure-sizing']; projection.write_bytes(original)
        with self.assertRaisesRegex(ValueError, 'absent owned sibling'):
            figure.verify(args.output, require_complete=False, regenerate_projection=request)
        self.assertEqual(projection.read_bytes(), original)

    def test_generated_projection_validates_all_raw_rows_count_and_trailer_before_write(self):
        args, _ = self.capture()
        request, _ = self.remove_projection(args.output)
        path = args.output / figure.ROLES['figure-sizing-raw']
        original = path.read_bytes(); lines = original.splitlines(keepends=True)
        header = json.loads(lines[0]); header['base_batches'] += 1
        invalids = [original[:-1], original + b'{}\n',
                    figure.stream_encoded(header) + b''.join(lines[1:]),
                    b''.join(lines[:-1]) + b'{malformed-unselected-row}\n']
        for invalid in invalids:
            path.write_bytes(invalid)
            with self.subTest(tail=invalid[-32:]), self.assertRaises((ValueError, StopIteration)):
                figure.verify(args.output, require_complete=False, regenerate_projection=request)
            self.assertFalse((args.output / figure.ROLES['figure-sizing']).exists())
            self.assertFalse((args.output / figure.COMPLETE).exists())
        path.write_bytes(original)

    def test_generated_projection_compares_written_records_and_keeps_failed_output_unpublished(self):
        args, _ = self.capture()
        request, _ = self.remove_projection(args.output)
        original_write = figure.write_projection_stream
        def corrupt(path, document, **options):
            changed = copy.deepcopy(document)
            changed['records'][0]['original_width'] += 1
            return original_write(path, changed, **options)
        with patch.object(figure, 'write_projection_stream', side_effect=corrupt), \
                self.assertRaisesRegex(ValueError, 'record differs from exact raw replay'):
            figure.verify(args.output, require_complete=False, regenerate_projection=request)
        self.assertFalse((args.output / figure.COMPLETE).exists())
        with self.assertRaises(FileNotFoundError) as missing:
            figure.verify(args.output)
        self.assertEqual(missing.exception.filename, str(args.output / figure.COMPLETE))
        document = self.fixture.stream_document(args.output)
        document['records'] = [document['records'][0], document['records'][0]]
        incomplete_identity = {}
        with self.assertRaisesRegex(ValueError, 'not strictly ordered'):
            figure.write_projection_stream(self.fixture.root / 'partial.projection', document,
                                           identity_out=incomplete_identity)
        self.assertEqual(incomplete_identity, {})

    def test_generated_projection_rejects_raw_and_written_identity_mutation(self):
        for mutation in ('raw-in-place', 'raw-rename', 'projection-in-place', 'projection-rename',
                         'root-mode', 'complete-marker'):
            with self.subTest(mutation=mutation):
                args, _ = self.capture()
                request, _ = self.remove_projection(args.output)
                original_write = figure.write_projection_stream
                root_mode = figure.stat.S_IMODE(args.output.stat().st_mode)
                def mutate(path, document, **options):
                    result = original_write(path, document, **options)
                    if mutation == 'root-mode':
                        figure.os.chmod(args.output, root_mode ^ 0o020)
                        return result
                    if mutation == 'complete-marker':
                        marker = dict(schema=figure.SCHEMA,
                            manifest_sha256=figure.digest((args.output / figure.MANIFEST).read_bytes()))
                        (args.output / figure.COMPLETE).write_bytes(figure.encoded(marker))
                        return result
                    target = args.output / figure.ROLES['figure-sizing-raw'] if mutation.startswith('raw-') else Path(path)
                    data, before = target.read_bytes(), target.stat()
                    if mutation.endswith('rename'):
                        replacement = self.fixture.root / 'replacement'
                        replacement.write_bytes(data)
                        figure.os.utime(replacement, ns=(before.st_atime_ns, before.st_mtime_ns))
                        replacement.replace(target)
                    else:
                        target.write_bytes(data[:-2] + b' \n')
                        figure.os.utime(target, ns=(before.st_atime_ns, before.st_mtime_ns))
                    return result
                try:
                    with patch.object(figure, 'write_projection_stream', side_effect=mutate), self.assertRaises(ValueError):
                        figure.verify(args.output, require_complete=False, regenerate_projection=request)
                finally:
                    figure.os.chmod(args.output, root_mode)
                self.assertEqual((args.output / figure.COMPLETE).exists(), mutation == 'complete-marker')

    def test_generated_projection_keeps_provider_provenance_and_final_membership_checks(self):
        for mutation in ('provider', 'receipt', 'extra-member'):
            with self.subTest(mutation=mutation):
                args, _ = self.capture()
                request, _ = self.remove_projection(args.output)
                if mutation == 'provider':
                    path = args.output / figure.PROVIDER; path.write_bytes(path.read_bytes() + b'not-a-row\n')
                elif mutation == 'receipt':
                    path = next(args.output.glob('file-metadata.response-*.receipt.json'))
                    receipt = json.loads(path.read_bytes()); receipt['status'] = 403
                    path.write_bytes(figure.encoded(receipt))
                else:
                    (args.output / 'unaccounted-member').write_bytes(b'extra')
                with self.assertRaises(ValueError):
                    figure.verify(args.output, require_complete=False, regenerate_projection=request)
                self.assertFalse((args.output / figure.COMPLETE).exists())

    def test_generated_projection_does_not_regenerate_a_complete_parent(self):
        args, _ = self.capture()
        parent = args.output
        parent_bytes = {p.name: p.read_bytes() for p in parent.iterdir()}
        args.output = self.fixture.root / 'generation-child'
        args.reuse = [parent]
        manifest = figure.capture_files(args, transport=lambda *_: self.fail('Parent capture refetched'), sleep=lambda _: None)
        request, original = self.remove_projection(args.output)
        with patch.object(figure, 'verify_stream_document', wraps=figure.verify_stream_document) as verify:
            self.assertEqual(figure.verify(args.output, require_complete=False, regenerate_projection=request), manifest)
        child_calls = [call for call in verify.call_args_list if call.args[0].parent == args.output]
        parent_calls = [call for call in verify.call_args_list if call.args[0].parent == parent]
        self.assertEqual(len(child_calls), 1); self.assertEqual(len(parent_calls), 1)
        self.assertEqual(child_calls[0].kwargs['regenerate_projection'], request)
        self.assertNotIn('regenerate_projection', parent_calls[0].kwargs)
        self.assertEqual((args.output / figure.ROLES['figure-sizing']).read_bytes(), original)
        self.assertEqual({p.name: p.read_bytes() for p in parent.iterdir()}, parent_bytes)



class OfflinePolicyReprojectionTests(unittest.TestCase):
    def setUp(self):
        self.fixture = FigureFileTests()
        self.fixture.setUp()
        self.addCleanup(self.fixture.doCleanups)
        self.serial = 0

    def legacy(self, *, contract=None, multipage=False):
        self.serial += 1
        args = self.fixture.args(links=('B.tif', 'Example.svg'))
        args.output = self.fixture.root / ('policy-parent-' + str(self.serial))
        args.batch_size = 1
        template = self.fixture.decimal_tiff_response()
        if multipage:
            image = template['query']['pages'][0]['imageinfo'][0]
            image['pagecount'] = 2
            for row in image['metadata']:
                if row['name'] in ('page_count', 'last_page'): row['value'] = 2
                elif row['name'] == 'page_data':
                    second = copy.deepcopy(row['value'][0]); second['name'] = 2
                    next(axis for axis in second['value'] if axis['name']=='page')['value'] = 2
                    row['value'].append(second)
        def transport(url, timeout):
            title = parse_qs(urlsplit(url).query)['titles'][0]
            response = copy.deepcopy(template)
            response['query']['pages'][0]['title'] = title
            image = response['query']['pages'][0]['imageinfo'][0]
            image['canonicaltitle'] = title
            if title.endswith('.svg'):
                image.update(mime='image/svg+xml', mediatype='DRAWING', width=300, height=250)
            return 200, {}, figure.encoded(response)
        now, advance = self.fixture.overlap_clock()
        with patch.object(figure.time, 'monotonic', side_effect=now):
            manifest = figure.capture_files(args, transport=transport, sleep=advance)
        root = args.output
        raw = root / figure.ROLES['figure-sizing-raw']
        values = list(figure.stream_values(raw, figure.RAW_STREAM_SCHEMA))
        values[0].pop('record_encoding', None)
        raw.write_bytes(b''.join(figure.stream_encoded(value) for value in values))
        document = figure.figure_stream_document(raw, self.fixture.namespace.read_bytes(), self.fixture.wiki,
            self.fixture.date, (root / figure.ROLES['figure-sizing-site']).read_bytes(),
            profile_kind=figure.FIGURE_PROFILE_V3, allow_tiff_companion=contract is not None,
            allow_encoded=False, allow_compatible_epochs=contract == figure.REPLAY_CONTRACT_V3,
            allow_decimal_tiff_axes=False, allow_default_tiff_page=False)
        if contract is None:
            document.pop('replay_contract')
        else:
            document['replay_contract'] = contract
        (root / figure.ROLES['figure-sizing']).unlink()
        figure.write_projection_stream(root / figure.ROLES['figure-sizing'], document)
        plan = json.loads((root / figure.PLAN).read_text())
        if contract is None:
            plan.pop('replay_contract', None)
        else:
            plan['replay_contract'] = contract
        (root / figure.PLAN).write_bytes(figure.encoded(plan))
        inventory = figure.inventory_document(root / figure.INVENTORY)
        titles = figure.provider_query_titles(root, figure.decode((root / figure.QUERY_INPUTS).read_bytes()),
            self.fixture.namespace.read_bytes(), self.fixture.wiki, self.fixture.date)
        manifest['coverage'] = figure.file_coverage(document, inventory, titles)
        manifest['artifacts'] = figure.payload(root)
        manifest['outputs'] = {role: manifest['artifacts'][name]['sha256'] for role, name in figure.output_roles(root).items()}
        (root / figure.MANIFEST).write_bytes(figure.encoded(manifest))
        (root / figure.COMPLETE).write_bytes(figure.encoded(dict(schema=figure.SCHEMA,
            manifest_sha256=figure.digest((root / figure.MANIFEST).read_bytes()))))
        self.assertEqual(figure.verify(root), manifest)
        self.assertEqual(next(row for row in document['records'] if row['requested_file'].endswith('.tif'))['state'], 'unsupported')
        return root, document

    def reproject(self, source, *, label='output', **options):
        output = self.fixture.root / (label + '-' + str(self.serial))
        observations = {}
        with patch.object(figure.evidence, 'get_response', side_effect=AssertionError('offline operation fetched')):
            manifest = figure.reproject_capture(source, output, observations=observations, **options)
        return output, manifest, observations

    def test_reprojection_promotes_decimal_tiff_with_exact_linked_originals_and_normal_tuple(self):
        for contract in (None, figure.REPLAY_CONTRACT_V3):
            with self.subTest(contract=contract):
                source, old = self.legacy(contract=contract)
                original = {p.name: p.read_bytes() for p in source.iterdir()}
                identities = {p.name: p.stat() for p in source.iterdir()}
                output, manifest, observations = self.reproject(source)
                self.assertTrue(observations['complete'])
                self.assertEqual(observations['original_contract'], contract)
                self.assertEqual({p.name: p.read_bytes() for p in source.iterdir()}, original)
                paths = {role: output/name for role, name in figure.output_roles(output).items()}
                self.assertEqual(set(figure.verify_tuple(paths, self.fixture.wiki, self.fixture.date)), set(paths))
                self.assertEqual(figure.verify(output), manifest)
                current = self.fixture.stream_document(output)
                self.assertEqual(current['replay_contract'], figure.REPLAY_CONTRACT_V4)
                expected = copy.deepcopy(old['records'])
                next(row for row in expected if row['requested_file'].endswith('.tif'))['state'] = 'eligible'
                self.assertEqual(current['records'], expected)
                old_plan = json.loads(original[figure.PLAN])
                self.assertEqual(json.loads((output/figure.PLAN).read_text()), dict(old_plan, replay_contract=figure.REPLAY_CONTRACT_V4))
                owned = {figure.PLAN, figure.ROLES['figure-sizing'], figure.MANIFEST, figure.COMPLETE}
                self.assertEqual({row['path'] for row in observations['linked_members']}, set(original)-owned)
                for name, before in identities.items():
                    after, linked = (source/name).stat(), (output/name).stat()
                    self.assertEqual((after.st_ino, after.st_mode, after.st_mtime_ns),
                                     (before.st_ino, before.st_mode, before.st_mtime_ns))
                    if name in owned:
                        self.assertNotEqual(after.st_ino, linked.st_ino)
                        self.assertEqual(after.st_nlink, before.st_nlink)
                    else:
                        self.assertEqual(after.st_ino, linked.st_ino)
                        self.assertEqual(after.st_nlink, before.st_nlink+1)
                        row = next(row for row in observations['linked_members'] if row['path']==name)
                        self.assertEqual(row['sha256_before'], row['sha256_after'])
                        self.assertEqual(row['after']['st_ctime_ns'], after.st_ctime_ns)

    def test_reprojection_preserves_multipage_refusal_and_exact_v4_options(self):
        source, old = self.legacy(multipage=True)
        derive = figure.figure_stream_document
        calls, consumed = [], []
        take = figure._ReprojectionRecords.take
        def observe(*args, **kwargs):
            calls.append((Path(args[0]), dict(kwargs)))
            return derive(*args, **kwargs)
        def consume(records, raw_path, *args, **kwargs):
            consumed.append((Path(raw_path), dict(kwargs)))
            return take(records, raw_path, *args, **kwargs)
        with patch.object(figure, 'figure_stream_document', side_effect=observe), \
                patch.object(figure._ReprojectionRecords, 'take', new=consume):
            output, _, _ = self.reproject(source)
        actual = self.fixture.stream_document(output)
        self.assertEqual(actual['records'], old['records'])
        selected = [options for path, options in calls if path.parent==output]
        self.assertEqual(len(selected), 1)
        self.assertEqual([options for path, options in consumed if path.parent == output], selected)
        self.assertTrue(all(options == dict(profile_kind=figure.FIGURE_PROFILE_V3, allow_tiff_companion=True,
            allow_encoded=True, allow_compatible_epochs=True, allow_decimal_tiff_axes=True,
            allow_default_tiff_page=False) for options in selected))

    def test_reprojection_refuses_bad_source_members_before_output(self):
        for mode in ('missing-provider', 'extra', 'symlink', 'corrupt-raw', 'wrong-plan'):
            with self.subTest(mode=mode):
                source, _ = self.legacy()
                if mode == 'missing-provider': (source/figure.PROVIDER).unlink()
                elif mode == 'extra': (source/'unexpected').write_bytes(b'extra')
                elif mode == 'symlink':
                    p=source/figure.PROVIDER; saved=self.fixture.root/('provider-'+str(self.serial));p.rename(saved);p.symlink_to(saved)
                elif mode == 'corrupt-raw':
                    p=source/figure.ROLES['figure-sizing-raw'];p.write_bytes(p.read_bytes()+b'{}\n')
                else:
                    plan=json.loads((source/figure.PLAN).read_text());plan['replay_contract']=figure.REPLAY_CONTRACT_V4
                    (source/figure.PLAN).write_bytes(figure.encoded(plan))
                output=self.fixture.root/('refused-'+str(self.serial))
                with self.assertRaises((ValueError, FileNotFoundError)):
                    figure.reproject_capture(source, output)
                self.assertFalse(output.exists())

    def test_reprojection_refuses_paths_contracts_and_noop_without_links(self):
        source, _ = self.legacy()
        output=self.fixture.root/'fresh'
        with patch.object(figure.os, 'link', side_effect=AssertionError('unexpected link')):
            for destination in (source, source/'child', Path('relative-output')):
                with self.subTest(destination=destination), self.assertRaises(ValueError):
                    figure.reproject_capture(source,destination)
            for contract in (None, figure.REPLAY_CONTRACT, 'v4', {}, True):
                with self.subTest(contract=contract), self.assertRaises(ValueError):
                    figure.reproject_capture(source,output,target_contract=contract)
            with self.assertRaises(ValueError):
                figure.reproject_capture(source,output,observations={'complete':True})
        output, _, _ = self.reproject(source)
        with patch.object(figure.os, 'link', side_effect=AssertionError('unexpected link')), self.assertRaises(ValueError):
            figure.reproject_capture(output,self.fixture.root/'noop')

    def test_reprojection_refuses_link_time_mutations_and_retains_partial_observations(self):
        for mode in ('bytes', 'mode', 'source-replace', 'destination-replace', 'extra-link'):
            with self.subTest(mode=mode):
                source, _ = self.legacy()
                link=figure.os.link;changed=False;observations={}
                def mutate(left,right,**kwargs):
                    nonlocal changed
                    link(left,right,**kwargs)
                    if changed:return
                    changed=True;p=Path(left);q=Path(right)
                    if mode=='bytes':p.write_bytes(p.read_bytes()+b' ')
                    elif mode=='mode':p.chmod(0o400)
                    elif mode in ('source-replace','destination-replace'):
                        target=p if mode=='source-replace' else q
                        replacement=self.fixture.root/('replacement-'+str(self.serial));replacement.write_bytes(target.read_bytes())
                        figure.os.replace(replacement,target)
                    else:link(p,self.fixture.root/('unexpected-link-'+str(self.serial)))
                output=self.fixture.root/('mutated-'+str(self.serial))
                with patch.object(figure.os,'link',side_effect=mutate),self.assertRaises(ValueError):
                    figure.reproject_capture(source,output,observations=observations)
                self.assertTrue(observations['linked_members'])
                self.assertFalse(observations['complete'])
                self.assertFalse((output/figure.COMPLETE).exists())

    def test_reprojection_verifies_written_projection_provider_and_publication(self):
        for mode in ('projection', 'provider', 'root-mode', 'late-marker', 'late-mode'):
            with self.subTest(mode=mode):
                source,_=self.legacy();output=self.fixture.root/('verification-'+str(self.serial))
                write=figure.write_projection_stream;verify=figure.verify
                def writer(path,document,**kwargs):
                    if mode=='projection':
                        document=copy.deepcopy(dict(document,records=list(document['records'])))
                        next(row for row in document['records'] if row['requested_file'].endswith('.tif'))['state']='unsupported'
                    result=write(path,document,**kwargs)
                    if mode=='provider':(output/figure.PROVIDER).write_bytes(b'corrupted\n')
                    if mode=='root-mode':output.chmod(0o777)
                    return result
                def verification(root,*args,**kwargs):
                    result=verify(root,*args,**kwargs)
                    if Path(root)==output:
                        if mode=='late-marker':figure.evidence.document(output/figure.COMPLETE,dict(schema=figure.SCHEMA,manifest_sha256=figure.digest((output/figure.MANIFEST).read_bytes())))
                        elif mode=='late-mode':(output/figure.PLAN).chmod(0o400)
                    return result
                with patch.object(figure,'write_projection_stream',side_effect=writer),patch.object(figure,'verify',side_effect=verification),self.assertRaises(ValueError):
                    figure.reproject_capture(source,output)
                if mode!='late-marker':self.assertFalse((output/figure.COMPLETE).exists())


class StaticWebPProfileTests(unittest.TestCase):
    def setUp(self):
        self.fixture = FigureFileTests()
        self.fixture.setUp()
        self.addCleanup(self.fixture.doCleanups)

    def response(self, title='ملف:A.webp'):
        value = self.fixture.response(title)
        value['query']['general']['git-hash'] = figure.FIGURE_CURRENT_CORE
        image = value['query']['pages'][0]['imageinfo'][0]
        image.update(width=350, height=350, mime='image/webp', mediatype='BITMAP', metadata=[
            {'name':'compression','value':'lossy'}, {'name':'animated','value':False},
            {'name':'transparency','value':False}, {'name':'width','value':350}, {'name':'height','value':350},
            {'name':'media-metadata','value':[{'name':'Orientation','value':1}]},
            {'name':'metadata','value':[{'name':'_MW_WEBP_VERSION','value':2}]}])
        return value

    def document(self, response, profile=None, *, site=None):
        title = response['query']['pages'][0]['title']
        raw = figure.encoded({'schema':figure.RAW_BATCHES_SCHEMA,
            'batches':[self.fixture.batch(title,response)]})
        site = figure.encoded(response) if site is None else site
        document = figure.figure_file_document(raw,self.fixture.namespace.read_bytes(),self.fixture.wiki,
            self.fixture.date,site,profile_kind=profile or figure.FIGURE_PROFILE_V5)
        return document, raw, site

    def verify(self, document, raw, site):
        return figure.verify_figure_file_document(document,raw,self.fixture.namespace.read_bytes(),
            self.fixture.wiki,self.fixture.date,site)

    def test_static_webp_profile_is_explicit_and_preserves_old_projection_and_provider(self):
        response = self.response()
        current, raw, site = self.document(response)
        self.assertEqual(current['records'][0]['state'],'eligible')
        self.assertEqual(current['source_profile']['webp_handler_core_revision'],figure.FIGURE_CURRENT_CORE)
        self.verify(current,raw,site)
        for profile in (figure.FIGURE_PROFILE_V3,figure.FIGURE_PROFILE_V4):
            old, original, _ = self.document(response,profile)
            self.assertEqual(original,raw)
            self.assertEqual(old['records'][0],dict(current['records'][0],state='unsupported'))
            self.verify(old,raw,site)
            self.assertEqual(b''.join(figure.provider_chunks(old)),b''.join(figure.provider_chunks(current)))
        for key,value in (('webp_handler_sha256','0'*64),('webp_handler_core_revision',figure.FIGURE_REGISTRATION_CORE)):
            changed=copy.deepcopy(current);changed['source_profile'][key]=value
            with self.assertRaisesRegex(ValueError,'exact batch replay'):
                self.verify(changed,raw,site)
        for contract in (None,figure.REPLAY_CONTRACT_V1,figure.REPLAY_CONTRACT_V2):
            changed=copy.deepcopy(current)
            if contract is None:changed.pop('replay_contract')
            else:changed['replay_contract']=contract
            with self.assertRaisesRegex(ValueError,'replay contract v3'):
                self.verify(changed,raw,site)

    def test_static_webp_requires_explicit_unambiguous_static_metadata(self):
        original=self.response()
        modes=('animated','missing-animated','integer-animated','frameCount','duration','looped','unknown',
            'compression','width','boolean-width','string-width','height','duplicate','missing','error',
            'version','boolean-version','version-map','orientation','string-orientation','media-error','media-duplicate',
            'transparency','bits','thumberror')
        for mode in modes:
            with self.subTest(mode=mode):
                response=copy.deepcopy(original);image=response['query']['pages'][0]['imageinfo'][0];fields=image['metadata']
                row=lambda name:next(item for item in fields if item['name']==name)
                if mode=='animated':row('animated')['value']=True
                elif mode=='missing-animated':fields.remove(row('animated'))
                elif mode=='integer-animated':row('animated')['value']=0
                elif mode in ('frameCount','duration','looped','unknown','error'):fields.append({'name':mode,'value':0})
                elif mode=='compression':row('compression')['value']='unknown'
                elif mode in ('width','boolean-width','string-width'):row('width')['value']={'width':349,'boolean-width':True,'string-width':'350'}[mode]
                elif mode=='height':row('height')['value']=0
                elif mode=='duplicate':fields.append(copy.deepcopy(row('width')))
                elif mode=='missing':image.pop('metadata')
                elif mode=='version':row('metadata')['value'][0]['value']=4
                elif mode=='boolean-version':row('metadata')['value'][0]['value']=True
                elif mode=='version-map':row('metadata')['value'].append({'name':'other','value':3})
                elif mode in ('orientation','string-orientation'):row('media-metadata')['value'][0]['value']=6 if mode=='orientation' else '1'
                elif mode=='media-error':row('media-metadata')['value'].append({'name':'errors','value':[]})
                elif mode=='media-duplicate':row('media-metadata')['value'].append({'name':'Orientation','value':1})
                elif mode=='transparency':row('transparency')['value']=0
                elif mode=='bits':fields.append({'name':'bits','value':16})
                else:image['thumberror']='failed'
                document,raw,site=self.document(response)
                self.assertEqual(document['records'][0]['state'],'unsupported')
                self.verify(document,raw,site)
                forged=copy.deepcopy(document);forged['records'][0]['state']='eligible'
                with self.assertRaisesRegex(ValueError,'exact batch replay'):
                    self.verify(forged,raw,site)
        for version in (2,3):
            response=self.response();image=response['query']['pages'][0]['imageinfo'][0]
            next(row for row in image['metadata'] if row['name']=='metadata')['value'][0]['value']=version
            next(row for row in image['metadata'] if row['name']=='compression')['value']='lossless'
            self.assertEqual(self.document(response)[0]['records'][0]['state'],'eligible')

    def test_static_webp_epoch_scope_keeps_other_image_profiles_and_registrations(self):
        anchor=self.response();site=figure.encoded(anchor)
        for core in (figure.FIGURE_RESPONSE_CORE,figure.FIGURE_REGISTRATION_CORE):
            response=self.response();response['query']['general']['git-hash']=core
            if core==figure.FIGURE_REGISTRATION_CORE:
                next(item for item in response['query']['extensions'] if item['name']=='TimedMediaHandler')['vcs-version']=figure.FIGURE_REGISTRATION_TMH
            document,raw,_=self.document(response,site=site)
            self.assertEqual(document['records'][0]['state'],'unsupported');self.verify(document,raw,site)
            forged=copy.deepcopy(document);forged['records'][0]['state']='eligible'
            with self.assertRaisesRegex(ValueError,'exact batch replay'):self.verify(forged,raw,site)
        response=self.response();response['query']['general']['git-hash']='0'*40
        with self.assertRaises(ValueError):self.document(response,site=site)
        svg=self.fixture.response('ملف:B.svg');svg['query']['general']['git-hash']=figure.FIGURE_REGISTRATION_CORE
        next(item for item in svg['query']['extensions'] if item['name']=='TimedMediaHandler')['vcs-version']=figure.FIGURE_REGISTRATION_TMH
        raw=figure.encoded({'schema':figure.RAW_BATCHES_SCHEMA,'batches':[
            self.fixture.batch('ملف:A.webp',anchor),self.fixture.batch('ملف:B.svg',svg)]})
        document=figure.figure_file_document(raw,self.fixture.namespace.read_bytes(),self.fixture.wiki,self.fixture.date,site,profile_kind=figure.FIGURE_PROFILE_V5)
        self.assertEqual([row['state'] for row in document['records']],['eligible','eligible'])
        self.verify(document,raw,site)
        svg['query']['extensions'][0]['vcs-version']='0'*40
        bad=figure.encoded({'schema':figure.RAW_BATCHES_SCHEMA,'batches':[self.fixture.batch('ملف:B.svg',svg)]})
        with self.assertRaises(ValueError):figure.figure_file_document(bad,self.fixture.namespace.read_bytes(),self.fixture.wiki,self.fixture.date,site,profile_kind=figure.FIGURE_PROFILE_V5)

    def test_static_webp_normal_parent_promotion_preserves_original_capture_and_provider(self):
        args=self.fixture.args(links=('A.webp',));args.figure_profile=figure.FIGURE_PROFILE_V4
        figure.capture_files(args,transport=lambda *_:(200,{},figure.encoded(self.response())),sleep=lambda _:None)
        parent=args.output;before={p.name:p.read_bytes() for p in parent.iterdir()}
        old=self.fixture.stream_document(parent)
        self.assertEqual(old['records'][0]['state'],'unsupported')
        args.output=self.fixture.root/'static-webp-successor';args.reuse=[parent];args.figure_profile=figure.FIGURE_PROFILE_V5
        manifest=figure.capture_files(args,transport=lambda *_:self.fail('Retained WebP parent refetched'))
        current=self.fixture.stream_document(args.output)
        self.assertEqual(current['records'][0],dict(old['records'][0],state='eligible'))
        self.assertEqual(current['source_profile']['kind'],figure.FIGURE_PROFILE_V5)
        self.assertEqual((args.output/figure.PROVIDER).read_bytes(),(parent/figure.PROVIDER).read_bytes())
        self.assertEqual(figure.verify(args.output),manifest)
        self.assertEqual(before,{p.name:p.read_bytes() for p in parent.iterdir()})
        paths={role:args.output/name for role,name in dict(figure.ROLES,**{'file-metadata':figure.PROVIDER}).items()}
        self.assertEqual(set(figure.verify_tuple(paths,self.fixture.wiki,self.fixture.date)),set(paths))

class ExplicitProfileReprojectionTests(StaticWebPProfileTests):
    def parent(self, *, animated=False, core=None):
        args = self.fixture.args(links=('A.webp', 'Example.svg'))
        args.figure_profile = figure.FIGURE_PROFILE_V4
        args.batch_size = 1
        if core in figure.FIGURE_WMF4_CORES:
            # A normal compatible defaults capture; the original fixture uses0470.
            defaults = copy.deepcopy(self.fixture.data)
            defaults['query']['general']['git-hash'] = figure.FIGURE_CURRENT_CORE
            selected = argparse.Namespace(wiki=self.fixture.wiki, date=self.fixture.date,
                namespace_registry=self.fixture.namespace, primary_sources=self.fixture.primary,
                output=self.fixture.root/'compatible-defaults', delay=0, wall_seconds=30,
                figure_defaults=True)
            occurrence_tests.site.capture(selected,
                transport=lambda *_: (200, {}, figure.encoded(defaults)), sleep=lambda _: None)
            args.defaults = selected.output
        def transport(url, timeout):
            title = parse_qs(urlsplit(url).query)['titles'][0]
            response = self.response(title) if title.endswith('.webp') else self.fixture.response(title)
            response['query']['general']['git-hash'] = core or figure.FIGURE_CURRENT_CORE
            if core in figure.FIGURE_WMF4_CORES:
                extensions = figure.FIGURE_WMF4_PROFILE['media_extensions']
                for row in response['query']['extensions']:
                    if row['name'] in extensions:
                        row['vcs-version'] = extensions[row['name']]
            if title.endswith('.webp') and animated:
                image = response['query']['pages'][0]['imageinfo'][0]
                next(row for row in image['metadata'] if row['name'] == 'animated')['value'] = True
            return 200, {}, figure.encoded(response)
        now, advance = self.fixture.overlap_clock()
        with patch.object(figure.time, 'monotonic', side_effect=now):
            manifest = figure.capture_files(args, transport=transport, sleep=advance)
        root = args.output
        document = self.fixture.stream_document(root)
        document['replay_contract'] = figure.REPLAY_CONTRACT_V4
        (root / figure.ROLES['figure-sizing']).unlink()
        figure.write_projection_stream(root / figure.ROLES['figure-sizing'], document)
        plan = json.loads((root / figure.PLAN).read_text())
        plan['replay_contract'] = figure.REPLAY_CONTRACT_V4
        (root / figure.PLAN).write_bytes(figure.encoded(plan))
        manifest['artifacts'] = figure.payload(root)
        manifest['outputs'] = {role: manifest['artifacts'][name]['sha256'] for role, name in figure.output_roles(root).items()}
        (root / figure.MANIFEST).write_bytes(figure.encoded(manifest))
        (root / figure.COMPLETE).write_bytes(figure.encoded(dict(schema=figure.SCHEMA,
            manifest_sha256=figure.digest((root / figure.MANIFEST).read_bytes()))))
        self.assertEqual(figure.verify(root), manifest)
        return root, document

    def upgrade(self, root, **options):
        output = root.with_name(root.name + '-profile-v5')
        observations = {}
        with patch.object(figure.evidence, 'get_response', side_effect=AssertionError('offline profile fetched')):
            manifest = figure.reproject_capture(root, output, target_profile=figure.FIGURE_PROFILE_V5,
                observations=observations, **options)
        return output, manifest, observations

    def test_explicit_v5_reprojection_keeps_v4_contract_parent_and_provider(self):
        root, old = self.parent()
        before = {p.name: p.read_bytes() for p in root.iterdir()}
        stamps = {p.name: p.stat() for p in root.iterdir()}
        output, manifest, observations = self.upgrade(root)
        self.assertEqual({p.name: p.read_bytes() for p in root.iterdir()}, before)
        current = self.fixture.stream_document(output)
        expected = copy.deepcopy(old['records'])
        next(row for row in expected if row['mime'] == 'image/webp')['state'] = 'eligible'
        self.assertEqual(current['records'], expected)
        self.assertEqual(current['replay_contract'], figure.REPLAY_CONTRACT_V4)
        self.assertEqual(current['source_profile']['kind'], figure.FIGURE_PROFILE_V5)
        self.assertEqual(json.loads((output / figure.PLAN).read_text()),
            dict(json.loads(before[figure.PLAN]), figure_profile=figure.FIGURE_PROFILE_V5))
        self.assertEqual((output / figure.PROVIDER).read_bytes(), before[figure.PROVIDER])
        self.assertEqual(figure.verify(output), manifest)
        paths = {role: output / name for role, name in figure.output_roles(output).items()}
        self.assertEqual(set(figure.verify_tuple(paths, self.fixture.wiki, self.fixture.date)), set(paths))
        self.assertTrue(observations['complete'])
        self.assertEqual(observations['original_profile'], figure.FIGURE_PROFILE_V4)
        self.assertEqual(observations['target_profile'], figure.FIGURE_PROFILE_V5)
        owned = {figure.PLAN, figure.ROLES['figure-sizing'], figure.MANIFEST, figure.COMPLETE}
        self.assertEqual({row['path'] for row in observations['linked_members']}, set(before) - owned)
        for name, stamp in stamps.items():
            actual, linked = (root / name).stat(), (output / name).stat()
            self.assertEqual((actual.st_ino, actual.st_mode, actual.st_mtime_ns),
                             (stamp.st_ino, stamp.st_mode, stamp.st_mtime_ns))
            self.assertEqual(actual.st_nlink, stamp.st_nlink + (name not in owned))
            if name not in owned:
                self.assertEqual(actual.st_ino, linked.st_ino)
                row = next(row for row in observations['linked_members'] if row['path'] == name)
                self.assertEqual(row['sha256_before'], row['sha256_after'])
                self.assertEqual(row['after']['st_ctime_ns'], actual.st_ctime_ns)
            else:
                self.assertNotEqual(actual.st_ino, linked.st_ino)

    def test_profile_reprojection_refuses_implicit_unknown_noop_and_downgrade_before_links(self):
        root, _ = self.parent()
        original = {p.name: (p.read_bytes(), p.stat()) for p in root.iterdir()}
        for number, options in enumerate(({}, {'target_profile': 'unknown'},
                {'target_profile': figure.FIGURE_PROFILE_V3}, {'target_profile': figure.FIGURE_PROFILE_V4},
                {'target_profile': figure.FIGURE_PROFILE_V5, 'target_contract': 'wikidict.figure-files-replay.v6'})):
            with self.subTest(options=options):
                output = root.with_name('refused-profile-' + str(number))
                with self.assertRaises(ValueError): figure.reproject_capture(root, output, **options)
                self.assertFalse(output.exists())
                for name, (raw, stamp) in original.items():
                    self.assertEqual((root/name).read_bytes(), raw)
                    self.assertEqual((root/name).stat().st_nlink, stamp.st_nlink)
                    self.assertEqual((root/name).stat().st_ctime_ns, stamp.st_ctime_ns)
        output, _, _ = self.upgrade(root)
        with self.assertRaisesRegex(ValueError, 'existing V4 profile'):
            figure.reproject_capture(output, root.with_name('noop-v5'), target_profile=figure.FIGURE_PROFILE_V5)
        self.assertFalse(root.with_name('noop-v5').exists())

    def test_profile_reprojection_keeps_animated_webp_unsupported(self):
        root, old = self.parent(animated=True)
        output, _, _ = self.upgrade(root)
        self.assertEqual(self.fixture.stream_document(output)['records'], old['records'])
        self.assertEqual(next(row for row in old['records'] if row['mime'] == 'image/webp')['state'], 'unsupported')

    def test_profile_reprojection_keeps_wmf4_webp_unsupported_and_other_family_exact(self):
        root, old = self.parent(core=figure.FIGURE_WMF4_CORE)
        output, _, _ = self.upgrade(root)
        self.assertEqual(self.fixture.stream_document(output)['records'], old['records'])
        self.assertEqual([row['state'] for row in old['records']], ['unsupported', 'eligible'])

    def test_profile_reprojection_rejects_forged_profile_and_written_projection(self):
        root, _ = self.parent()
        real = figure.write_projection_stream
        def forged(path, document):
            document['source_profile']['webp_handler_sha256'] = '0' * 64
            return real(path, document)
        output = root.with_name('forged-profile')
        with patch.object(figure, 'write_projection_stream', side_effect=forged):
            with self.assertRaises(ValueError):
                figure.reproject_capture(root, output, target_profile=figure.FIGURE_PROFILE_V5)
        self.assertFalse((output / figure.COMPLETE).exists())
        figure.verify(root)
        self.assertEqual(len(self.fixture.stream_document(root)['records']), 2)



class LeanFrameReplayReuseTests(unittest.TestCase):
    def setUp(self):
        self.fixture = FigureFileTests()
        self.fixture.setUp()
        self.addCleanup(self.fixture.doCleanups)
        self.root = self.fixture.root / 'lean-replay'
        self.root.mkdir()
        self.number = 0
        self.namespace = self.fixture.namespace.read_bytes()

    def frame(self, titles, *, tiff=False):
        self.number += 1
        registry = figure.evidence.Registry(self.namespace, self.fixture.wiki, self.fixture.date)
        def stage(names, light, suffix):
            response = self.fixture.lean_response(names, metadata_requested=not light)
            _, reference = metadata.request_batch(self.root, self.number, names, registry,
                lambda *_: (200, {}, figure.encoded(response)), lambda _: None,
                figure.time.monotonic()+30, 1, figure_axes=True,
                figure_metadata_light=light, artifact_stage=suffix)
            accepted_names, raw, artifacts, accepted = figure.captured_http_stage(
                self.root, reference, self.fixture.wiki, light=light, stage=suffix)
            accepted[0].unlink()
            return reference, artifacts, accepted_names, raw.decode()
        reference, artifacts, names, raw = stage(titles, True, '')
        source = dict(kind='http-archived-lean', batch=reference, artifacts=artifacts)
        batch = dict(requests=names, response=raw)
        if tiff:
            ref, files, _, raw = stage([title for title in titles if title.endswith('.tif')], False, 'tiff')
            source.update(tiff_batch=ref, tiff_artifacts=files)
            batch['tiff_metadata_response'] = raw
        return source, batch

    def eager_replay(self, original):
        # Retained pre-change leaf branch: source/HTTP checks are deliberately
        # real. Scoped recursion and every non-lean branch use the common path.
        def replay(root, source, batch, wiki, date, namespace, http_files, prefix_cache=None,
                   *, profile_kind=figure.FIGURE_PROFILE_V3, inventory_cache=None,
                   allow_compatible_epochs=False, origin_plan=None):
            if source.get('kind') != 'http-archived-lean' or '/' in source.get('batch', {}).get('accepted_receipt', ''):
                return original(root, source, batch, wiki, date, namespace, http_files, prefix_cache,
                    profile_kind=profile_kind, inventory_cache=inventory_cache,
                    allow_compatible_epochs=allow_compatible_epochs, origin_plan=origin_plan)
            expected = {'kind', 'batch', 'artifacts'}
            if 'tiff_metadata_response' in batch:
                expected.update(('tiff_batch', 'tiff_artifacts'))
            if set(source) != expected:
                raise ValueError('Invalid lean Figure request evidence')
            base = {'requests': batch['requests'], 'response': batch['response']}
            name, identity = figure.replay_http_source(root, source, base, wiki, http_files, light=True)
            titles = figure.lean_tiff_titles(base, namespace, wiki, date, profile_kind,
                allow_compatible_epochs=allow_compatible_epochs)
            if bool(titles) != ('tiff_metadata_response' in batch):
                raise ValueError('Archived lean Figure response lacks its required TIFF evidence')
            if titles:
                followup = {'kind': source['kind'], 'batch': source['tiff_batch'], 'artifacts': source['tiff_artifacts']}
                tiff_name, tiff_identity = figure.replay_http_source(root, followup,
                    {'requests': titles, 'response': batch['tiff_metadata_response']}, wiki, http_files,
                    light=False, stage='tiff')
            figure.validate_lean_batch(batch, namespace, wiki, date, profile_kind,
                allow_compatible_epochs=allow_compatible_epochs)
            archived = {name: identity}
            if titles:
                archived[tiff_name] = tiff_identity
                archived[('tiff-titles', name)] = list(titles)
            return archived
        return replay

    def pair(self, source, batch, *, valid=True, epochs=True):
        before = copy.deepcopy((source, batch))
        evidence_before = {p.name:p.read_bytes() for p in self.root.iterdir()}
        results = []
        original = figure.replay_source
        for eager in (True, False):
            files, archives = set(), {}
            call = self.eager_replay(original) if eager else original
            with patch.object(figure, 'file_records', wraps=figure.file_records) as reduce:
                wall, cpu = time.perf_counter(), time.process_time()
                if valid:
                    archives.update(call(self.root, source, batch, self.fixture.wiki, self.fixture.date,
                         self.namespace, files, profile_kind=figure.FIGURE_PROFILE_V4,
                         allow_compatible_epochs=epochs, origin_plan={}))
                else:
                    with self.assertRaises(ValueError):
                        call(self.root, source, batch, self.fixture.wiki, self.fixture.date,
                             self.namespace, files, profile_kind=figure.FIGURE_PROFILE_V4,
                             allow_compatible_epochs=epochs, origin_plan={})
                timing = dict(wall_seconds=time.perf_counter()-wall, cpu_seconds=time.process_time()-cpu)
                results.append((files, archives, reduce.call_count, timing))
            self.assertEqual((source, batch), before)
            self.assertEqual({p.name:p.read_bytes() for p in self.root.iterdir()}, evidence_before)
        if valid:
            self.assertEqual(results[0][:2], results[1][:2])
        return results

    def rebind_response(self, source, batch, key='response'):
        reference = source['batch' if key == 'response' else 'tiff_batch']
        path = self.root/reference['accepted_receipt']
        receipt = figure.decode(path.read_bytes())
        raw = batch[key].encode()
        receipt.update(response_bytes=len(raw), response_sha256=figure.digest(raw))
        path.write_bytes(figure.encoded(receipt))

    def complete(self):
        args = self.fixture.lean_capture_args(('A.png', 'B.tif', 'C.svg', 'Missing.svg'))
        now, advance = self.fixture.overlap_clock()
        with patch.object(figure.time, 'monotonic', side_effect=now):
            figure.capture_files(args, transport=self.fixture.lean_transport([]), sleep=advance)
        output = self.fixture.root/'materialized-reuse'
        figure.materialize_complete_capture(args.output/figure.MANIFEST, output)
        return output

    def test_lean_frame_reuse_preserves_complete_projection_provider_and_evidence(self):
        output = self.complete()
        before = {str(p.relative_to(output)):p.read_bytes() for p in output.rglob('*') if p.is_file()}
        paths = {role:output/name for role,name in {**figure.ROLES, 'file-metadata':figure.PROVIDER}.items()}
        original = figure.replay_source
        with patch.object(figure, 'replay_source', side_effect=self.eager_replay(original)):
            expected = figure.verify_tuple(paths, self.fixture.wiki, self.fixture.date)
        actual = figure.verify_tuple(paths, self.fixture.wiki, self.fixture.date)
        self.assertEqual(actual, expected)
        self.assertEqual(before, {str(p.relative_to(output)):p.read_bytes() for p in output.rglob('*') if p.is_file()})
        source, batch = self.frame(['ملف:A.png', 'ملف:Missing.svg', 'ملف:Zero.svg'])
        pair = self.pair(source, batch)
        self.assertEqual([row[2] for row in pair], [3, 1])

    def test_lean_frame_reuse_keeps_complete_tiff_companion_validation(self):
        source, batch = self.frame(['ملف:A.png', 'ملف:B.tif'], tiff=True)
        self.assertEqual([row[2] for row in self.pair(source, batch)], [3, 2])
        original = copy.deepcopy(batch)
        receipt_path = self.root/source['tiff_batch']['accepted_receipt']
        receipt = receipt_path.read_bytes()
        for field, value in (('sha1', 'b'*40), ('timestamp', '2020-01-01T00:00:00Z'), ('width', 799)):
            bad = copy.deepcopy(original)
            data = figure.decode(bad['tiff_metadata_response'].encode())
            data['query']['pages'][0]['imageinfo'][0][field] = value
            bad['tiff_metadata_response'] = figure.encoded(data).decode()
            self.rebind_response(source, bad, 'tiff_metadata_response')
            self.pair(source, bad, valid=False)
            receipt_path.write_bytes(receipt)
        missing = dict(batch);missing.pop('tiff_metadata_response')
        self.pair(source, missing, valid=False)
        bad = copy.deepcopy(batch)
        data = figure.decode(bad['tiff_metadata_response'].encode());data['query']['pages'] = []
        bad['tiff_metadata_response'] = figure.encoded(data).decode()
        self.rebind_response(source, bad, 'tiff_metadata_response')
        self.pair(source, bad, valid=False)

    def test_lean_frame_reuse_rejects_extra_shapes_and_invalid_base_semantics(self):
        source, batch = self.frame(['ملف:A.png'])
        for key, value in (('unexpected', True), ('observed_svg_width_px', 250),
                           ('observed_svg_occurrences', []), ('tiff_metadata_response', '{}')):
            self.pair(source, dict(batch, **{key:value}), valid=False)
        receipt_path = self.root/source['batch']['accepted_receipt'];receipt = receipt_path.read_bytes()
        for mutation in ('unrequested_metadata', 'unknown_core', 'duplicate_title', 'wrong_language'):
            bad = copy.deepcopy(batch);data = figure.decode(bad['response'].encode())
            if mutation == 'unrequested_metadata':data['query']['pages'][0]['imageinfo'][0]['metadata'] = []
            elif mutation == 'unknown_core':data['query']['general']['git-hash'] = 'f'*40
            elif mutation == 'duplicate_title':data['query']['pages'].append(copy.deepcopy(data['query']['pages'][0]))
            else:data['query']['general']['lang'] = 'fr'
            bad['response'] = figure.encoded(data).decode();self.rebind_response(source,bad)
            self.pair(source,bad,valid=False);receipt_path.write_bytes(receipt)

    def test_lean_frame_reuse_keeps_receipt_request_and_origin_guards(self):
        source, batch = self.frame(['ملف:A.png'])
        self.pair(source,batch)
        for name in (source['batch']['accepted_receipt'],source['batch']['request']):
            path=self.root/name;raw=path.read_bytes();value=figure.decode(raw)
            if name==source['batch']['accepted_receipt']:value['response_sha256']='0'*64
            else:value['titles']=['ملف:Different.png']
            path.write_bytes(figure.encoded(value));self.pair(source,batch,valid=False);path.write_bytes(raw)
        bad=copy.deepcopy(source);bad['artifacts'].append('unrelated.json')
        (self.root/'unrelated.json').write_text('{}')
        self.pair(bad,batch,valid=False)
        terminal=TerminalHttpOriginTests();terminal.setUp();self.addCleanup(terminal.doCleanups)
        scoped_source,scoped_batch=terminal.terminal(0,'ملف:A.svg',lean=True)
        scoped=terminal.scoped(0,scoped_source)
        terminal.replay(scoped,scoped_batch)
        mixed=copy.deepcopy(scoped);mixed['batch']['request']=mixed['batch']['request'].replace(terminal.ids[0],terminal.ids[1])
        with self.assertRaises(ValueError):terminal.replay(mixed,scoped_batch)

    def test_lean_frame_reuse_keeps_source_mutation_end_guards(self):
        output=self.complete();original=figure.replay_source;lean=figure.lean_tiff_titles
        plan=figure.decode((output/figure.PLAN).read_bytes())
        request=next(output/name for row in plan['materialized_http_origins'] for name in (ref['path'] for ref in row['files'].values()) if name.endswith('request-000001.json'))
        raw=request.read_bytes();parent=request.parent;mode=parent.stat().st_mode & 0o777
        for eager in (True,False):
            for mutation in ('bytes','replacement','directory_mode'):
                changed=[False]
                def mutate(*args,**kwargs):
                    result=lean(*args,**kwargs)
                    if not changed[0]:
                        changed[0]=True
                        if mutation=='bytes':request.write_bytes(raw+b' ')
                        elif mutation=='replacement':
                            request.rename(request.with_suffix('.held'));request.write_bytes(raw)
                        else:parent.chmod(0o777 if mode!=0o777 else 0o755)
                    return result
                with patch.object(figure,'lean_tiff_titles',side_effect=mutate), patch.object(figure,'replay_source',side_effect=self.eager_replay(original) if eager else original):
                    with self.assertRaises((ValueError,FileNotFoundError)):figure.verify(output)
                self.assertTrue(changed[0])
                if mutation=='replacement':request.unlink();request.with_suffix('.held').rename(request)
                else:request.write_bytes(raw)
                parent.chmod(mode)
                figure.verify(output)

    def test_lean_frame_reuse_reports_bounded_fifty_title_comparison(self):
        samples=[]
        for index in range(8):
            titles=['ملف:Frame%02d-file%02d.png'%(index,n) for n in range(50)]
            source,batch=self.frame(titles)
            pair=self.pair(source,batch)
            self.assertEqual([row[2] for row in pair],[3,1])
            samples.append(dict(response_bytes=len(batch['response'].encode()),before=pair[0][3],after=pair[1][3]))
        summary=dict(scope='Eight temporary 50-title frames; paired author-control observations, not FR speedup',
            frames=len(samples),titles=400,response_bytes=sum(x['response_bytes'] for x in samples),
            reducers_before=24,reducers_after=8,
            before={key:sum(x['before'][key] for x in samples) for key in ('wall_seconds','cpu_seconds')},
            after={key:sum(x['after'][key] for x in samples) for key in ('wall_seconds','cpu_seconds')})
        print('LEAN_FRAME_REUSE_MEASUREMENT '+json.dumps(summary,sort_keys=True),flush=True)


class DefaultPageReplayReprojectionTests(unittest.TestCase):
    def setUp(self):
        self.fixture = FigureFileTests()
        self.fixture.setUp()
        self.addCleanup(self.fixture.doCleanups)
        self.serial = 0

    def seal(self, root, manifest):
        manifest['artifacts'] = figure.payload(root)
        manifest['outputs'] = {role: manifest['artifacts'][name]['sha256']
                               for role, name in figure.output_roles(root).items()}
        (root / figure.MANIFEST).write_bytes(figure.encoded(manifest))
        (root / figure.COMPLETE).write_bytes(figure.encoded(dict(schema=figure.SCHEMA,
            manifest_sha256=figure.digest((root / figure.MANIFEST).read_bytes()))))

    def parent(self, contract, *, malformed=False, observed=False):
        self.serial += 1
        args = self.fixture.args(links=('B.tif', 'C.tif', 'Example.svg'))
        args.output = self.fixture.root / ('default-parent-' + str(self.serial))
        args.figure_profile = figure.FIGURE_PROFILE_V4
        args.batch_size = 1
        peili = json.loads((Path(__file__).parent / 'testdata/th-peili-default-page/info.json').read_text())
        svg, svg_observed, _ = self.fixture.svg_observation(figure.FIGURE_CURRENT_CORE)
        def transport(url, timeout):
            title = parse_qs(urlsplit(url).query)['titles'][0]
            response = copy.deepcopy(svg if title.endswith('.svg') else self.fixture.decimal_tiff_response())
            page = response['query']['pages'][0]
            page['title'] = title
            image = page['imageinfo'][0]
            image['canonicaltitle'] = title
            if title.endswith('B.tif'):
                image.update({key: copy.deepcopy(peili[key]) for key in
                              ('sha1', 'timestamp', 'width', 'height', 'pagecount', 'metadata')})
                if malformed:
                    pages = next(row['value'] for row in image['metadata'] if row['name'] == 'page_data')
                    next(row for row in pages[0]['value'] if row['name'] == 'width')['value'] = 123
            return 200, {}, figure.encoded(response)
        now, advance = self.fixture.overlap_clock()
        with patch.object(figure.time, 'monotonic', side_effect=now):
            manifest = figure.capture_files(args, transport=transport, sleep=advance)
        if observed:
            args.reuse = [args.output]
            args.reuse_batch = [self.fixture.write_svg_observation(svg_observed)]
            args.output = self.fixture.root / ('default-observed-' + str(self.serial))
            manifest = figure.capture_files(args, transport=lambda *_: self.fail('Observation refetched parent'))
        root = args.output
        document = figure.figure_stream_document(root / figure.ROLES['figure-sizing-raw'],
            self.fixture.namespace.read_bytes(), self.fixture.wiki, self.fixture.date,
            (root / figure.ROLES['figure-sizing-site']).read_bytes(), profile_kind=figure.FIGURE_PROFILE_V4,
            allow_tiff_companion=True, allow_encoded=True, allow_compatible_epochs=True,
            allow_decimal_tiff_axes=contract in (figure.REPLAY_CONTRACT_V4, figure.REPLAY_CONTRACT),
            allow_default_tiff_page=contract == figure.REPLAY_CONTRACT)
        document['replay_contract'] = contract
        (root / figure.ROLES['figure-sizing']).unlink()
        figure.write_projection_stream(root / figure.ROLES['figure-sizing'], document)
        plan = json.loads((root / figure.PLAN).read_bytes())
        plan['replay_contract'] = contract
        (root / figure.PLAN).write_bytes(figure.encoded(plan))
        inventory = figure.inventory_document(root / figure.INVENTORY)
        titles = figure.provider_query_titles(root, figure.decode((root / figure.QUERY_INPUTS).read_bytes()),
            self.fixture.namespace.read_bytes(), self.fixture.wiki, self.fixture.date)
        manifest['coverage'] = figure.file_coverage(document, inventory, titles)
        self.seal(root, manifest)
        self.assertEqual(figure.verify(root), manifest)
        return root, document, manifest

    def upgrade(self, root, *, label='default-v6', **options):
        output = self.fixture.root / (label + '-' + str(self.serial))
        observations = {}
        with patch.object(figure.evidence, 'get_response', side_effect=AssertionError('Offline v6 fetched')):
            manifest = figure.reproject_capture(root, output, target_contract=figure.REPLAY_CONTRACT,
                                               observations=observations, **options)
        return output, manifest, observations

    def test_v6_reprojection_advances_v3_and_v4_with_complete_linked_parent_parity(self):
        for contract in (figure.REPLAY_CONTRACT_V3, figure.REPLAY_CONTRACT_V4):
            with self.subTest(contract=contract):
                root, old, _ = self.parent(contract)
                before = {p.name: p.read_bytes() for p in root.iterdir()}
                stamps = {p.name: p.stat() for p in root.iterdir()}
                output, manifest, observations = self.upgrade(root)
                current = self.fixture.stream_document(output)
                expected = copy.deepcopy(old)
                expected.update(replay_contract=figure.REPLAY_CONTRACT,
                                generator_sha256=figure.producer()['generator_sha256'])
                for row in expected['records']:
                    if row['requested_file'].endswith('B.tif'): row['state'] = 'tiff_default_page'
                    elif row['requested_file'].endswith('C.tif'): row['state'] = 'eligible'
                self.assertEqual(current, expected)
                self.assertEqual(figure.verify(output), manifest)
                roles = {role: output/name for role, name in figure.output_roles(output).items()}
                self.assertEqual(set(figure.verify_tuple(roles, self.fixture.wiki, self.fixture.date)), set(roles))
                self.assertEqual(json.loads((output / figure.PLAN).read_bytes()),
                                 dict(json.loads(before[figure.PLAN]), replay_contract=figure.REPLAY_CONTRACT))
                self.assertEqual({p.name: p.read_bytes() for p in root.iterdir()}, before)
                self.assertEqual((output / figure.PROVIDER).read_bytes(), before[figure.PROVIDER])
                self.assertTrue(observations['complete'])
                self.assertEqual((observations['original_contract'], observations['target_contract']),
                                 (contract, figure.REPLAY_CONTRACT))
                self.assertEqual(observations['original_profile'], observations['target_profile'])
                owned = {figure.PLAN, figure.ROLES['figure-sizing'], figure.MANIFEST, figure.COMPLETE}
                self.assertEqual({r['path'] for r in observations['linked_members']}, set(before)-owned)
                for name, stamp in stamps.items():
                    after, linked = (root/name).stat(), (output/name).stat()
                    self.assertEqual((after.st_ino, after.st_mode, after.st_mtime_ns),
                                     (stamp.st_ino, stamp.st_mode, stamp.st_mtime_ns))
                    self.assertEqual(after.st_nlink, stamp.st_nlink + (name not in owned))
                    self.assertEqual(after.st_ino == linked.st_ino, name not in owned)

    def test_v6_reprojection_preserves_observed_svg_and_existing_v4_refusal(self):
        root, old, _ = self.parent(figure.REPLAY_CONTRACT_V3, observed=True)
        old_svg = next(row for row in old['records'] if row['mime'] == 'image/svg+xml')
        self.assertEqual(old_svg['observed_svg_width_px'], 250)
        output, _, _ = self.upgrade(root)
        current = self.fixture.stream_document(output)
        self.assertEqual(next(row for row in current['records'] if row['mime'] == 'image/svg+xml'), old_svg)
        self.assertEqual(current['observed_batches'], old['observed_batches'])
        legacy_output = self.fixture.root / 'explicit-old-v4'
        figure.reproject_capture(root, legacy_output)
        legacy = self.fixture.stream_document(legacy_output)
        self.assertEqual(legacy['replay_contract'], figure.REPLAY_CONTRACT_V4)
        self.assertEqual(next(row for row in legacy['records'] if row['requested_file'].endswith('B.tif'))['state'], 'unsupported')
        self.assertEqual(next(row for row in legacy['records'] if row['mime'] == 'image/svg+xml'), old_svg)

    def test_v6_reprojection_keeps_malformed_default_page_unsupported_and_exact_options(self):
        root, old, _ = self.parent(figure.REPLAY_CONTRACT_V4, malformed=True)
        derive = figure.figure_stream_document
        calls, consumed = [], []
        take = figure._ReprojectionRecords.take
        def observe(*args, **kwargs):
            calls.append((Path(args[0]), dict(kwargs)))
            return derive(*args, **kwargs)
        def consume(records, raw_path, *args, **kwargs):
            consumed.append((Path(raw_path), dict(kwargs)))
            return take(records, raw_path, *args, **kwargs)
        with patch.object(figure, 'figure_stream_document', side_effect=observe), \
                patch.object(figure._ReprojectionRecords, 'take', new=consume):
            output, _, _ = self.upgrade(root)
        self.assertEqual(self.fixture.stream_document(output)['records'], old['records'])
        selected = [options for path, options in calls if path.parent == output]
        self.assertEqual(len(selected), 1)
        self.assertEqual([options for path, options in consumed if path.parent == output], selected)
        self.assertTrue(all(options == dict(profile_kind=figure.FIGURE_PROFILE_V4,
            allow_tiff_companion=True, allow_encoded=True, allow_compatible_epochs=True,
            allow_decimal_tiff_axes=True, allow_default_tiff_page=True) for options in selected))

    def test_v6_reprojection_refuses_unsupported_source_and_profile_combinations_before_links(self):
        root, _, _ = self.parent(figure.REPLAY_CONTRACT_V3)
        with patch.object(figure.os, 'link', side_effect=AssertionError('Invalid policy created link')):
            for options in ({'target_contract':'wikidict.figure-files-replay.v5'},
                            {'target_contract':figure.REPLAY_CONTRACT, 'target_profile':figure.FIGURE_PROFILE_V5},
                            {'target_contract':figure.REPLAY_CONTRACT, 'target_profile':figure.FIGURE_PROFILE_V4}):
                with self.subTest(options=options), self.assertRaises(ValueError):
                    figure.reproject_capture(root, self.fixture.root/'invalid-policy', **options)
            self.assertFalse((self.fixture.root/'invalid-policy').exists())
        for contract in (None, figure.REPLAY_CONTRACT_V1, figure.REPLAY_CONTRACT_V2, figure.REPLAY_CONTRACT):
            with self.subTest(contract=contract):
                if contract == figure.REPLAY_CONTRACT:
                    source, _, _ = self.parent(contract)
                else:
                    legacy = OfflinePolicyReprojectionTests()
                    legacy.setUp()
                    self.addCleanup(legacy.doCleanups)
                    source, _ = legacy.legacy(contract=contract)
                output = source.with_name(source.name + '-refused-v6')
                with patch.object(figure.os, 'link', side_effect=AssertionError('Noop/old source created link')), self.assertRaises(ValueError):
                    figure.reproject_capture(source, output, target_contract=figure.REPLAY_CONTRACT)
                self.assertFalse(output.exists())

    def test_v6_reprojection_keeps_source_mutation_and_plan_contract_refusals(self):
        root, _, manifest = self.parent(figure.REPLAY_CONTRACT_V3)
        plan = json.loads((root/figure.PLAN).read_bytes())
        plan['replay_contract'] = figure.REPLAY_CONTRACT_V4
        (root/figure.PLAN).write_bytes(figure.encoded(plan))
        self.seal(root, manifest)
        with patch.object(figure.os, 'link', side_effect=AssertionError('Invalid source created link')), self.assertRaises(ValueError):
            self.upgrade(root)
        root, _, _ = self.parent(figure.REPLAY_CONTRACT_V3)
        output = self.fixture.root/'source-mutated'
        link = figure.os.link
        observations = {}
        changed = False
        def mutate(left, right, **options):
            nonlocal changed
            link(left, right, **options)
            if not changed:
                changed = True
                Path(left).write_bytes(Path(left).read_bytes()+b' ')
        with patch.object(figure.os,'link',side_effect=mutate), self.assertRaises(ValueError):
            figure.reproject_capture(root, output, target_contract=figure.REPLAY_CONTRACT, observations=observations)
        self.assertTrue(observations['linked_members'])
        self.assertFalse(observations['complete'])
        self.assertFalse((output/figure.COMPLETE).exists())

    def test_v6_reprojection_rejects_wrong_written_state_provider_and_directory_mode(self):
        for mode in ('eligible', 'unsupported', 'provider', 'root-mode'):
            with self.subTest(mode=mode):
                root, _, _ = self.parent(figure.REPLAY_CONTRACT_V3)
                output = self.fixture.root/('written-'+str(self.serial))
                write = figure.write_projection_stream
                changed = []
                def writer(path, document, **options):
                    self.assertEqual(Path(path), output/figure.ROLES['figure-sizing'])
                    if mode in ('eligible','unsupported'):
                        # The real writer receives independent records lazily.
                        # Materialize only this small test input before copying.
                        document = copy.deepcopy(dict(document, records=list(document['records'])))
                        row = next(row for row in document['records'] if row['requested_file'].endswith('B.tif'))
                        self.assertEqual(row['state'], 'tiff_default_page')
                        row['state'] = mode
                    result = write(path, document, **options)
                    if mode == 'provider': (output/figure.PROVIDER).write_bytes(b'corrupt\n')
                    elif mode == 'root-mode': output.chmod(0o777)
                    changed.append(mode)
                    return result
                with patch.object(figure,'write_projection_stream',side_effect=writer), self.assertRaises(ValueError) as refused:
                    figure.reproject_capture(root, output, target_contract=figure.REPLAY_CONTRACT)
                self.assertEqual(changed, [mode])
                if mode in ('eligible','unsupported'):
                    self.assertRegex(str(refused.exception), 'projection stream record differs from exact raw replay')
                    written = figure.stream_values(output/figure.ROLES['figure-sizing'], figure.FILES_STREAM_SCHEMA)
                    next(written)
                    rows = list(written)
                    self.assertEqual(next(row for row in rows if row['requested_file'].endswith('B.tif'))['state'], mode)
                elif mode == 'provider':
                    self.assertEqual((output/figure.PROVIDER).read_bytes(), b'corrupt\n')
                else:
                    self.assertEqual(figure.stat.S_IMODE(output.stat().st_mode), 0o777)
                self.assertFalse((output/figure.COMPLETE).exists())


class MaterializedPolicyReprojectionTests(unittest.TestCase):
    def capture(self, *, epochs=False, contract=None):
        self.fixture = FigureFileTests()
        self.fixture.setUp()
        self.addCleanup(self.fixture.doCleanups)
        self.root = self.fixture.root
        if epochs:
            donor = OfflineFigureMaterializationTests()
            donor.fixture, donor.root = self.fixture, self.root
            args, proof = donor.epoch_complete()
        else:
            proof = None
            self.fixture.epoch_defaults()
            args = self.fixture.args(links=('B.tif', 'Example.svg'))
            args.metadata_mode = 'lean-tiff-v1'
            args.figure_profile = figure.FIGURE_PROFILE_V4
            args.batch_size = 1
            now, advance = self.fixture.overlap_clock()
            def transport(url, timeout):
                query = parse_qs(urlsplit(url).query)
                titles = query['titles'][0].split('|')
                full = 'metadata' in query['iiprop'][0].split('|')
                response = self.fixture.lean_response(titles, metadata_requested=full)
                for page in response['query']['pages']:
                    if page['title'].endswith('.tif'):
                        page['imageinfo'][0].update(width=4928, height=3868)
                        if full:
                            page['imageinfo'][0] = copy.deepcopy(self.fixture.decimal_tiff_response()['query']['pages'][0]['imageinfo'][0])
                return 200, {}, figure.encoded(response)
            with patch.object(figure.time, 'monotonic', side_effect=now):
                figure.capture_files(args, transport=transport, sleep=advance)
        root = args.output
        selected = figure.REPLAY_CONTRACT_V3 if contract is None else contract
        plan = json.loads((root/figure.PLAN).read_bytes())
        plan['replay_contract'] = selected
        (root/figure.PLAN).write_bytes(figure.encoded(plan))
        document = figure.figure_stream_document(root/figure.ROLES['figure-sizing-raw'],
            self.fixture.namespace.read_bytes(), self.fixture.wiki, self.fixture.date,
            (root/figure.ROLES['figure-sizing-site']).read_bytes(), profile_kind=figure.FIGURE_PROFILE_V4,
            allow_tiff_companion=True, allow_encoded=True, allow_compatible_epochs=True,
            allow_decimal_tiff_axes=selected == figure.REPLAY_CONTRACT_V4, allow_default_tiff_page=False)
        document['replay_contract'] = selected
        (root/figure.ROLES['figure-sizing']).unlink()
        figure.write_projection_stream(root/figure.ROLES['figure-sizing'], document)
        manifest = json.loads((root/figure.MANIFEST).read_bytes())
        inventory = figure.inventory_document(root/figure.INVENTORY)
        titles = figure.provider_query_titles(root, figure.decode((root/figure.QUERY_INPUTS).read_bytes()),
            self.fixture.namespace.read_bytes(), self.fixture.wiki, self.fixture.date)
        manifest['coverage'] = figure.file_coverage(document, inventory, titles)
        manifest['artifacts'] = figure.payload(root)
        manifest['outputs'] = {role: manifest['artifacts'][name]['sha256'] for role, name in figure.output_roles(root).items()}
        (root/figure.MANIFEST).write_bytes(figure.encoded(manifest))
        (root/figure.COMPLETE).write_bytes(figure.encoded(dict(schema=figure.SCHEMA,
            manifest_sha256=figure.digest((root/figure.MANIFEST).read_bytes()))))
        self.assertEqual(figure.verify(root), manifest)
        source = self.root/'materialized-parent'
        figure.materialize_complete_capture(root/figure.MANIFEST, source)
        root.rename(self.root/'complete-parent-unavailable')
        if proof is not None:
            original = Path(json.loads(proof.read_bytes())['source_root'])
            original.rename(self.root/'closed-parent-unavailable')
            proof.rename(proof.with_suffix('.unavailable'))
        figure.verify(source)
        return source, document

    def reproject(self, source, output, **options):
        with patch.object(figure.evidence, 'get_response', side_effect=AssertionError('offline operation fetched')):
            return figure.reproject_capture(source, output, **options)

    def test_materialized_decimal_reprojection_preserves_origins_and_old_context(self):
        source, old = self.capture()
        members, _ = figure.capture_member_paths(source, include_markers=True)
        original = {name: path.read_bytes() for name, path in members.items()}
        identities = {name: path.stat() for name, path in members.items()}
        plan = json.loads(original[figure.PLAN])
        self.assertEqual(plan['metadata_mode'], figure.MATERIALIZED_HTTP_MODE)
        self.assertEqual(len(plan['materialized_http_origins']), 1)
        self.assertEqual(old['source_profile']['kind'], figure.FIGURE_PROFILE_V4)
        self.assertEqual(next(row for row in old['records'] if row['requested_file'].endswith('.tif'))['state'], 'unsupported')
        output, observations, contexts = self.root/'reprojected', {}, []
        validate = figure.validate_materialized_echo
        def observe(state, selected_plan, wiki, date, namespace, *, root_record_count=None, verified_batches=None):
            def context(site, **options):
                result = root_record_count(site, **options)
                if selected_plan['replay_contract'] == figure.REPLAY_CONTRACT_V4:
                    contexts.append((options['allow_decimal_tiff_axes'], options['allow_default_tiff_page'], result))
                return result
            return validate(state, selected_plan, wiki, date, namespace,
                root_record_count=context, verified_batches=verified_batches)
        with patch.object(figure, 'validate_materialized_echo', side_effect=observe):
            manifest = self.reproject(source, output, observations=observations)
        self.assertTrue(contexts)
        self.assertTrue(all(row == (False, False, None) for row in contexts))
        current = self.fixture.stream_document(output)
        expected = copy.deepcopy(old['records'])
        next(row for row in expected if row['requested_file'].endswith('.tif'))['state'] = 'eligible'
        self.assertEqual(current['records'], expected)
        self.assertEqual(json.loads((output/figure.PLAN).read_bytes()), dict(plan, replay_contract=figure.REPLAY_CONTRACT_V4))
        self.assertEqual(figure.verify(output), manifest)
        paths = {role: output/name for role, name in figure.output_roles(output).items()}
        self.assertEqual(set(figure.verify_tuple(paths, self.fixture.wiki, self.fixture.date)), set(paths))
        self.assertEqual({name: path.read_bytes() for name, path in members.items()}, original)
        self.assertTrue(observations['complete'])
        owned = {figure.PLAN, figure.ROLES['figure-sizing'], figure.MANIFEST, figure.COMPLETE}
        self.assertEqual({row['path'] for row in observations['linked_members']}, set(members)-owned)
        for name, before in identities.items():
            after, linked = (source/name).stat(), (output/name).stat()
            self.assertEqual((after.st_dev, after.st_ino, after.st_mode, after.st_size, after.st_mtime_ns),
                             (before.st_dev, before.st_ino, before.st_mode, before.st_size, before.st_mtime_ns))
            if name in owned:
                self.assertNotEqual(after.st_ino, linked.st_ino)
                self.assertEqual(after.st_nlink, before.st_nlink)
            else:
                self.assertEqual(after.st_ino, linked.st_ino)
                self.assertEqual(after.st_nlink, before.st_nlink+1)
        figure.verify(source)
        source.rename(self.root/'materialized-parent-unavailable')
        self.assertEqual(figure.verify(output), manifest)

    def test_materialized_epoch_reprojection_keeps_pending_receipts_and_ancestry(self):
        source, old = self.capture(epochs=True)
        plan = json.loads((source/figure.PLAN).read_bytes())
        self.assertEqual(len(plan['materialized_http_origins']), 2)
        self.assertTrue(any(len(row['pending']) == 2 for row in plan['materialized_http_origins']))
        output = self.root/'reprojected'
        manifest = self.reproject(source, output)
        self.assertEqual(json.loads((output/figure.PLAN).read_bytes()), dict(plan, replay_contract=figure.REPLAY_CONTRACT_V4))
        self.assertEqual(self.fixture.stream_document(output)['records'], old['records'])
        for row in plan['materialized_http_origins']:
            for descriptor in row['files'].values():
                self.assertEqual((source/descriptor['path']).read_bytes(), (output/descriptor['path']).read_bytes())
        source.rename(self.root/'materialized-parent-unavailable')
        self.assertEqual(figure.verify(output), manifest)

    def test_materialized_reprojection_refuses_changed_origin_proof_before_links(self):
        for mutation in ('receipt', 'frame-map', 'epoch', 'missing-origin', 'symlink'):
            with self.subTest(mutation=mutation):
                source, _ = self.capture(epochs=True)
                plan = json.loads((source/figure.PLAN).read_bytes())
                origin = next(row for row in plan['materialized_http_origins'] if row['pending'])
                if mutation == 'receipt':
                    reference = next(value for name, value in origin['files'].items() if name.endswith('.receipt.json'))
                    path = source/reference['path']; receipt = json.loads(path.read_bytes()); receipt['status'] = 403
                    path.write_bytes(figure.encoded(receipt))
                elif mutation == 'missing-origin':
                    (source/origin['plan']['path']).unlink()
                elif mutation == 'symlink':
                    path=source/origin['id'];saved=self.root/'saved-origin';path.rename(saved);path.symlink_to(saved, target_is_directory=True)
                else:
                    if mutation == 'frame-map': origin['frame_map'] = []
                    else: origin['epochs'] = []
                    donor=OfflineFigureMaterializationTests(); donor.rebind(source, plan)
                output = self.root/'refused'
                with patch.object(figure.os, 'link', side_effect=AssertionError('unexpected link')), self.assertRaises((ValueError, FileNotFoundError)):
                    self.reproject(source, output)
                self.assertFalse(output.exists())

    def test_materialized_reprojection_refuses_other_contract_or_profile_transitions(self):
        for original_contract, options in ((figure.REPLAY_CONTRACT_V3, {'target_contract': figure.REPLAY_CONTRACT}),
                (figure.REPLAY_CONTRACT_V3, {'target_profile': figure.FIGURE_PROFILE_V5}),
                (figure.REPLAY_CONTRACT_V4, {}),
                (figure.REPLAY_CONTRACT_V4, {'target_profile': figure.FIGURE_PROFILE_V5})):
            with self.subTest(original=original_contract, options=options):
                source, _ = self.capture(contract=original_contract)
                output = self.root/'refused'
                with patch.object(figure.os, 'link', side_effect=AssertionError('unexpected link')), self.assertRaises(ValueError):
                    self.reproject(source, output, **options)
                self.assertFalse(output.exists())

    def test_materialized_reprojection_fences_nested_directories_from_creation(self):
        for mutation in ('mode', 'replacement', 'symlink', 'source-mode'):
            with self.subTest(mutation=mutation):
                source, _ = self.capture()
                plan = json.loads((source/figure.PLAN).read_bytes())
                output = self.root/'refused'; origin = plan['materialized_root']; observations = {}
                writer = figure.write_projection_stream
                def write(path, document, **options):
                    result = writer(path, document, **options)
                    directory = (source if mutation == 'source-mode' else output)/origin
                    if mutation in ('mode', 'source-mode'): directory.chmod(0o777)
                    else:
                        saved=self.root/'saved-output-origin';directory.rename(saved)
                        if mutation == 'symlink': directory.symlink_to(saved, target_is_directory=True)
                        else:
                            directory.mkdir(mode=0o700)
                            for member in saved.iterdir(): figure.os.link(member, directory/member.name)
                    return result
                with patch.object(figure, 'write_projection_stream', side_effect=write), self.assertRaisesRegex(ValueError, 'directory|source changed'):
                    self.reproject(source, output, observations=observations)
                self.assertFalse(observations['complete'])
                self.assertFalse((output/figure.COMPLETE).exists())

    def test_materialized_reprojection_keeps_full_written_and_final_identity_refusals(self):
        for mutation in ('projection', 'provider', 'receipt', 'late-directory'):
            with self.subTest(mutation=mutation):
                source, _ = self.capture()
                output = self.root/'refused'; observations = {}
                plan = json.loads((source/figure.PLAN).read_bytes())
                origin = plan['materialized_http_origins'][0]
                receipt = next(value['path'] for name, value in origin['files'].items() if name.endswith('.receipt.json'))
                writer, verifier = figure.write_projection_stream, figure.verify
                def write(path, document, **options):
                    if mutation == 'projection':
                        document = copy.deepcopy(dict(document, records=list(document['records'])))
                        next(row for row in document['records'] if row['requested_file'].endswith('.tif'))['state'] = 'unsupported'
                    result = writer(path, document, **options)
                    if mutation == 'provider': (output/figure.PROVIDER).write_bytes(b'corrupt\n')
                    elif mutation == 'receipt':
                        target=output/receipt;replacement=self.root/'replacement-receipt'
                        replacement.write_bytes(target.read_bytes());figure.os.replace(replacement, target)
                    return result
                def verify(root, **options):
                    result = verifier(root, **options)
                    if Path(root) == output and mutation == 'late-directory': (output/origin['id']).chmod(0o777)
                    return result
                with patch.object(figure, 'write_projection_stream', side_effect=write), patch.object(figure, 'verify', side_effect=verify), self.assertRaises(ValueError):
                    self.reproject(source, output, observations=observations)
                self.assertFalse(observations['complete'])
                self.assertFalse((output/figure.COMPLETE).exists())


class EqualMediaBehaviorMemberTests(unittest.TestCase):
    core = '93f1cdcc57c0891fb208c960a9f7fff6ca1ca35c'
    prior = 'bb3b6755d485f60478c87c907f0557c53117142d'

    def setUp(self):
        self.fixture = FigureFileTests()
        self.fixture.setUp()
        self.addCleanup(self.fixture.doCleanups)

    def response(self, title, core):
        value = self.fixture.wmf4_epoch(self.fixture.epoch_response([title], figure.FIGURE_CURRENT_CORE))
        value['query']['general']['git-hash'] = core
        return value

    def document(self, response, profile=figure.FIGURE_PROFILE_V4):
        title = response['query']['pages'][0]['title']
        site = figure.encoded(self.fixture.registered_epoch(self.fixture.site_api, figure.FIGURE_CURRENT_CORE))
        raw = figure.encoded(dict(schema=figure.RAW_BATCHES_SCHEMA, batches=[self.fixture.batch(title, response)]))
        document = figure.figure_file_document(raw, self.fixture.namespace.read_bytes(), self.fixture.wiki,
            self.fixture.date, site, profile_kind=profile)
        self.assertEqual(figure.verify_figure_file_document(document, raw, self.fixture.namespace.read_bytes(),
            self.fixture.wiki, self.fixture.date, site), document)
        return document, raw, site

    def test_equal_media_member_preserves_normal_parent_provider_and_actual_echo(self):
        self.assertIs(figure.figure_profile(self.core, figure.FIGURE_PROFILE_V4), figure.FIGURE_WMF4_PROFILE)
        convert = self.fixture.wmf4_epoch
        def observed(response):
            value = convert(response)
            value['query']['general']['git-hash'] = self.core
            return value
        with patch.object(self.fixture, 'wmf4_epoch', side_effect=observed):
            self.fixture.test_wmf4_normal_parent_svg_append_preserves_all_old_facts_and_provider()
        root = self.fixture.root/'wmf4-parent-child'
        batches = list(figure.stream_values(root/figure.ROLES['figure-sizing-raw'], figure.RAW_STREAM_SCHEMA))
        self.assertEqual(json.loads(batches[-1]['response'])['query']['general']['git-hash'], self.core)
        self.assertEqual(json.loads(batches[1]['response'])['query']['general']['git-hash'], figure.FIGURE_CURRENT_CORE)
        self.assertEqual(self.fixture.stream_document(root)['core_revision'], figure.FIGURE_CURRENT_CORE)

    def test_equal_media_member_keeps_prior_v4_v5_families_and_exact_records(self):
        for profile in (figure.FIGURE_PROFILE_V4, figure.FIGURE_PROFILE_V5):
            for suffix in ('png', 'jpg', 'gif', 'svg'):
                title = '\u0645\u0644\u0641:Present.'+suffix
                with self.subTest(profile=profile, suffix=suffix):
                    previous, _, _ = self.document(self.response(title, self.prior), profile)
                    current, raw, _ = self.document(self.response(title, self.core), profile)
                    self.assertEqual(current['records'], previous['records'])
                    self.assertEqual(current['records'][0]['state'], 'eligible')
                    self.assertEqual(current['source_profile'], previous['source_profile'])
                    self.assertEqual(json.loads(json.loads(raw)['batches'][0]['response'])['query']['general']['git-hash'], self.core)
        self.assertIsNone(figure.figure_profile(self.core, figure.FIGURE_PROFILE_V3))
        for core in ('0'*40, self.core[:-1]+'0'):
            with self.subTest(core=core), self.assertRaises(ValueError):
                self.document(self.response('\u0645\u0644\u0641:Present.png', core))

    def test_equal_media_member_keeps_each_registration_context_and_height_refusal(self):
        convert = self.fixture.wmf4_epoch
        def observed(response):
            value = convert(response)
            value['query']['general']['git-hash'] = self.core
            return value
        with patch.object(self.fixture, 'wmf4_epoch', side_effect=observed):
            self.fixture.test_wmf4_registered_epoch_refuses_changed_pairs_and_unproved_profiles()
        title='\u0645\u0644\u0641:Present.png'
        good=self.response(title, self.core)
        self.document(good)
        for name in figure.FIGURE_WMF4_PROFILE['media_extensions']:
            bad=copy.deepcopy(good)
            next(row for row in bad['query']['extensions'] if row['name']==name)['vcs-version']='0'*40
            with self.subTest(name=name), self.assertRaises(ValueError):self.document(bad)

    def test_equal_media_member_does_not_grant_webp_stl_audio_or_other_handlers(self):
        for core in (self.prior, self.core):
            for profile in (figure.FIGURE_PROFILE_V4, figure.FIGURE_PROFILE_V5):
                for mime, media in (('image/webp', 'BITMAP'), ('application/sla', '3D'),
                                    ('audio/ogg', 'AUDIO'), ('application/pdf', 'OFFICE')):
                    with self.subTest(core=core, profile=profile, mime=mime):
                        response=self.response('\u0645\u0644\u0641:Present.png', core)
                        response['query']['pages'][0]['imageinfo'][0].update(mime=mime, mediatype=media)
                        document, raw, site=self.document(response, profile)
                        self.assertEqual(document['records'][0]['state'], 'unsupported')
                        bad=copy.deepcopy(document);bad['records'][0]['state']='eligible'
                        with self.assertRaises(ValueError):
                            figure.verify_figure_file_document(bad, raw, self.fixture.namespace.read_bytes(),
                                self.fixture.wiki, self.fixture.date, site)


class ReviewedDeployment992adTests(EqualMediaBehaviorMemberTests):
    def test_revalidated_defaults_survive_real_five_role_capture_and_offline_reuse(self):
        f = self.fixture
        inputs = f.normal_build_inputs()
        (f.root/'figure-defaults').rename(f.root/'original-defaults')
        data = copy.deepcopy(f.data)
        data['query']['general']['git-hash'] = self.core
        args = argparse.Namespace(wiki=f.wiki, date=f.date, namespace_registry=f.namespace,
            primary_sources=f.primary, output=f.root/'figure-defaults', delay=0, wall_seconds=30, figure_defaults=True)
        site = figure.site_info
        with patch.object(site, 'CORE_PROFILES', tuple(x for x in site.CORE_PROFILES if x != self.core)):
            with self.assertRaisesRegex(ValueError, 'source mismatch'):
                site.capture(args, transport=lambda *_:(200, {}, figure.encoded(data)), sleep=lambda _:None)
        original = {p.name:p.read_bytes() for p in args.output.iterdir()}
        site.revalidate(args.output, figure.digest(original['site-info.failure.json']))
        calls = []
        def transport(url, timeout):
            calls.append(url)
            self.assertIn('imageinfo', url)
            return 200, {}, figure.encoded(self.response('\u0645\u0644\u0641:Example.svg', self.core))
        with patch.object(figure.evidence, 'get_response', side_effect=transport):
            paths = builder.resolve_figure_snapshot_options(f.root, inputs['manifest'],
                inputs['selected_inputs'], inputs['downloads'], f.namespace, {}, metadata_network='allow')
        self.assertEqual(len(calls), 1)
        self.assertEqual(set(paths), {*figure.ROLES, 'file-metadata'})
        result = figure.verify(f.root/'figure-inputs')
        self.assertEqual(result['coverage']['files'], 1)
        for name, raw in original.items():
            self.assertEqual(raw, (args.output/name).read_bytes())
            self.assertEqual(raw, (f.root/'figure-inputs'/name).read_bytes())
        with patch.object(figure.evidence, 'get_response', side_effect=AssertionError('no recapture')):
            reused = builder.resolve_figure_snapshot_options(f.root, inputs['manifest'],
                inputs['selected_inputs'], inputs['downloads'], f.namespace, {}, metadata_network='offline')
        self.assertEqual(paths, reused)

    core = '992ad5e3679f848254828e823860ba8b3ad3b39b'
    prior = '93f1cdcc57c0891fb208c960a9f7fff6ca1ca35c'

    def test_normal_resolver_selects_existing_v4_after_offline_defaults_revalidation(self):
        f = self.fixture
        inputs = f.normal_build_inputs()
        (f.root/'figure-defaults').rename(f.root/'original-defaults')
        data = copy.deepcopy(f.data)
        data['query']['general']['git-hash'] = self.core
        args = argparse.Namespace(wiki=f.wiki, date=f.date, namespace_registry=f.namespace,
            primary_sources=f.primary, output=f.root/'figure-defaults', delay=0, wall_seconds=30, figure_defaults=True)
        site = figure.site_info
        with patch.object(site, 'CORE_PROFILES', tuple(x for x in site.CORE_PROFILES if x != self.core)):
            with self.assertRaisesRegex(ValueError, 'source mismatch'):
                site.capture(args, transport=lambda *_:(200, {}, figure.encoded(data)), sleep=lambda _:None)
        retained = {p.name:p.read_bytes() for p in args.output.iterdir()}
        with patch.object(site.evidence, 'get_response', side_effect=AssertionError('no defaults refetch')):
            site.revalidate(args.output, figure.digest(retained['site-info.failure.json']))
        def capture(call):
            self.assertEqual(call.figure_profile, figure.FIGURE_PROFILE_V4)
            self.assertEqual(call.defaults, args.output)
            self.assertEqual(call.metadata_mode, 'full')
            self.assertEqual({p.name:p.read_bytes() for p in args.output.iterdir() if p.name in retained}, retained)
            return f.normal_capture_result(call, inputs['selected_inputs'])
        with patch.object(site, 'capture', side_effect=AssertionError('no defaults refetch')), \
                patch.object(figure, 'capture_files', side_effect=capture) as collect:
            selected = figure.prepare_for_build(**inputs, network=True)
        collect.assert_called_once()
        self.assertEqual(set(selected), {*figure.ROLES, 'file-metadata'})




class ReviewedDeploymentBfe249Tests(ReviewedDeployment992adTests):
    core = 'bfe24921d500b20f2938fb8fe2a09cf5cac80161'
    prior = '992ad5e3679f848254828e823860ba8b3ad3b39b'

class CaptureReplayContractTests(unittest.TestCase):
    def setUp(self):
        self.donor = DefaultPageReplayReprojectionTests()
        self.donor.setUp()
        self.addCleanup(self.donor.doCleanups)
        self.fixture = self.donor.fixture

    def args(self, label):
        args = self.fixture.args(links=('B.tif', 'C.tif', 'Example.svg'))
        args.output = self.fixture.root / label
        args.figure_profile = figure.FIGURE_PROFILE_V4
        args.batch_size = 1
        return args

    def capture(self, label, contract=None):
        args = self.args(label)
        peili = json.loads((Path(__file__).parent/'testdata/th-peili-default-page/info.json').read_text())
        svg, _, _ = self.fixture.svg_observation(figure.FIGURE_CURRENT_CORE)
        def transport(url, timeout):
            title = parse_qs(urlsplit(url).query)['titles'][0]
            response = copy.deepcopy(svg if title.endswith('.svg') else self.fixture.decimal_tiff_response())
            page = response['query']['pages'][0]; page['title'] = title
            info = page['imageinfo'][0]; info['canonicaltitle'] = title
            if title.endswith('B.tif'):
                info.update({key: copy.deepcopy(peili[key]) for key in
                             ('sha1', 'timestamp', 'width', 'height', 'pagecount', 'metadata')})
            return 200, {}, figure.encoded(response)
        now, advance = self.fixture.overlap_clock()
        options = {} if contract is None else {'target_contract': contract}
        with patch.object(figure.time, 'monotonic', side_effect=now):
            manifest = figure.capture_files(args, transport=transport, sleep=advance, **options)
        return args, manifest

    def members(self, root):
        return {name: path.read_bytes() for name,path in figure.capture_member_paths(root,include_markers=True)[0].items()}

    def test_capture_explicit_v4_keeps_decimal_policy_without_default_page_grant(self):
        args, manifest = self.capture('explicit-v4', figure.REPLAY_CONTRACT_V4)
        doc = self.fixture.stream_document(args.output)
        self.assertEqual(doc['replay_contract'], figure.REPLAY_CONTRACT_V4)
        self.assertEqual(json.loads((args.output/figure.PLAN).read_bytes())['replay_contract'], figure.REPLAY_CONTRACT_V4)
        states = {row['requested_file'].split(':',1)[1]: row['state'] for row in doc['records']}
        self.assertEqual(states, {'B.tif':'unsupported', 'C.tif':'eligible', 'Example.svg':'eligible'})
        self.assertEqual(figure.verify(args.output),manifest)
        self.assertEqual(set(figure.verify_tuple({role:args.output/name for role,name in figure.output_roles(args.output).items()})),set(figure.output_roles(args.output)))
        # The same retained axes are deliberately admitted as default-page only
        # by the v6 reducer. Neither contract is a mere header label.
        other, _ = self.capture('default-v6')
        otherdoc = self.fixture.stream_document(other.output)
        expected = copy.deepcopy(doc['records'])
        next(row for row in expected if row['requested_file'].endswith('B.tif'))['state']='tiff_default_page'
        self.assertEqual(otherdoc['records'],expected)
        self.assertEqual((args.output/figure.PROVIDER).read_bytes(),(other.output/figure.PROVIDER).read_bytes())

    def test_capture_default_and_explicit_v6_have_exact_complete_output_bytes(self):
        with patch.object(metadata,'utc',return_value='2026-10-01T00:00:00+00:00'):
            left, lm = self.capture('default')
            right, rm = self.capture('explicit-v6', figure.REPLAY_CONTRACT)
        self.assertEqual(lm,rm)
        self.assertEqual(self.members(left.output),self.members(right.output))
        self.assertEqual(figure.verify(left.output),lm)
        self.assertEqual(figure.verify(right.output),rm)

    def test_capture_v4_appends_observation_to_materialized_parent_without_origin_change(self):
        parent, old, _ = self.donor.parent(figure.REPLAY_CONTRACT_V4)
        materialized = self.fixture.root/'materialized-v4'
        figure.materialize_complete_capture(parent/figure.MANIFEST,materialized)
        parent.rename(self.fixture.root/'original-unavailable')
        original = self.members(materialized)
        self.assertEqual(json.loads(original[figure.PLAN])['metadata_mode'],figure.MATERIALIZED_HTTP_MODE)
        _, observed, _ = self.fixture.svg_observation(figure.FIGURE_CURRENT_CORE)
        record = self.fixture.write_svg_observation(observed)
        args = self.args('materialized-appended-v4');args.reuse=[materialized];args.reuse_batch=[record]
        manifest = figure.capture_files(args,transport=lambda *_:self.fail('Retained append fetched'),target_contract=figure.REPLAY_CONTRACT_V4)
        self.assertEqual(self.members(materialized),original)
        doc = self.fixture.stream_document(args.output)
        self.assertEqual(doc['replay_contract'],figure.REPLAY_CONTRACT_V4)
        self.assertEqual(len(doc['records']),len(old['records']))
        expected = copy.deepcopy(old['records'])
        next(row for row in expected if row['requested_file'].endswith('Example.svg')).update(
            observed_svg_width_px=250, observed_batch=doc['base_batches'])
        self.assertEqual(doc['records'],expected)
        self.assertEqual((args.output/figure.PROVIDER).read_bytes(),original[figure.PROVIDER])
        plan=json.loads((args.output/figure.PLAN).read_bytes())
        self.assertEqual(plan['replay_contract'],figure.REPLAY_CONTRACT_V4)
        self.assertEqual(plan['complete_captures'],[dict(kind='complete-stream',path=str(materialized/figure.MANIFEST),sha256=figure.digest(original[figure.MANIFEST]))])
        self.assertEqual(figure.verify(args.output),manifest)

    def consolidated_observation(self, slots=1):
        parent, _, _ = self.donor.parent(figure.REPLAY_CONTRACT_V4)
        materialized = self.fixture.root/'materialized-parent'
        figure.materialize_complete_capture(parent/figure.MANIFEST,materialized)
        parent.rename(self.fixture.root/'original-unavailable')
        _, observed, _ = self.fixture.svg_observation(figure.FIGURE_CURRENT_CORE)
        record = self.fixture.write_svg_observation(observed)
        args = self.args('observed-current');args.reuse=[materialized];args.reuse_batch=[record]
        args.max_inflight=slots
        figure.capture_files(args,transport=lambda *_:self.fail('Retained append fetched'),target_contract=figure.REPLAY_CONTRACT_V4)
        before = self.members(args.output); parent_before = self.members(materialized)
        output = self.fixture.root/'consolidated-current'
        with patch.object(figure.evidence,'get_response',side_effect=AssertionError('Materialization fetched')):
            figure.materialize_complete_capture(args.output/figure.MANIFEST,output)
        self.assertEqual(self.members(args.output),before)
        self.assertEqual(self.members(materialized),parent_before)
        return args.output,materialized,output,record,before

    def verify_consolidated(self, output):
        manifest=figure.verify(output)
        paths={role:output/name for role,name in figure.output_roles(output).items()}
        self.assertEqual(set(figure.verify_tuple(paths)),set(paths))
        return manifest

    def rebind_consolidated_plan(self, output, plan):
        OfflineFigureMaterializationTests.rebind(self,output,plan)

    def test_materialize_observed_materialized_parent_preserves_current_bytes_without_ancestor_payloads(self):
        source,parent,output,record,before=self.consolidated_observation()
        for name in (*figure.ROLES.values(),figure.PROVIDER,figure.INVENTORY):
            self.assertEqual((output/name).read_bytes(),before[name])
        old=json.loads(before[figure.PLAN]);plan=json.loads((output/figure.PLAN).read_bytes())
        self.assertEqual(plan['base_batches'],old['base_batches'])
        self.assertEqual(plan['observed_batches'],1)
        self.assertEqual(plan['observed'],old['observed'])
        self.assertEqual(plan['complete_captures'],[])
        self.assertEqual(plan['retained'],[])
        self.assertTrue(any(json.loads((output/row['plan']['path']).read_bytes()).get('metadata_mode')==figure.MATERIALIZED_HTTP_MODE for row in plan['materialized_http_origins']))
        for row in plan['materialized_http_origins']:
            self.assertFalse(set(row['files']) & {figure.ROLES['figure-sizing-raw'],figure.ROLES['figure-sizing'],figure.PROVIDER})
        source.rename(source.with_name('observed-source-unavailable'))
        parent.rename(parent.with_name('materialized-parent-unavailable'))
        with patch.object(figure,'read_complete_capture',side_effect=AssertionError('Consolidation reopened an ancestor')):
            self.verify_consolidated(output)
        repeated=self.fixture.root/'consolidated-again'
        figure.materialize_complete_capture(output/figure.MANIFEST,repeated)
        output.rename(output.with_name('consolidated-source-unavailable'))
        self.verify_consolidated(repeated)
        for name in (*figure.ROLES.values(),figure.PROVIDER,figure.INVENTORY):
            self.assertEqual((repeated/name).read_bytes(),before[name])
        self.assertTrue(record.is_file())

    def test_materialized_observation_keeps_two_slot_http_plan_separate(self):
        source,parent,output,_,before=self.consolidated_observation(slots=2)
        plan=json.loads((output/figure.PLAN).read_bytes())
        self.assertEqual(plan['max_inflight'],2)
        self.assertEqual(plan['observed_batches'],1)
        source.rename(source.with_name('source-unavailable'));parent.rename(parent.with_name('parent-unavailable'))
        self.verify_consolidated(output)
        for name in (*figure.ROLES.values(),figure.PROVIDER,figure.INVENTORY):
            self.assertEqual((output/name).read_bytes(),before[name])
        plan['planned_requests_sha256']='0'*64
        self.rebind_consolidated_plan(output,plan)
        with self.assertRaisesRegex(ValueError,'occupied-slot'):figure.verify(output)

    def test_linked_observed_consolidation_preserves_old_names_and_new_tuple_replay(self):
        source,parent,_,record,before=self.consolidated_observation(slots=2)
        output=self.fixture.root/'linked-observed';observations={}
        names={figure.ROLES['figure-sizing'],figure.ROLES['figure-sizing-raw'],figure.PROVIDER,figure.INVENTORY}
        identities={name:(source/name).stat() for name in names}
        figure.materialize_complete_capture(source/figure.MANIFEST,output,
            link_current_payloads=True,observations=observations)
        parent.rename(parent.with_name('ancestor-unavailable'))
        for name,old in identities.items():
            self.assertEqual((source/name).stat().st_ino,old.st_ino)
            self.assertEqual((output/name).stat().st_ino,old.st_ino)
            self.assertEqual((source/name).stat().st_nlink,old.st_nlink+1)
            self.assertEqual((source/name).read_bytes(),before[name])
        self.verify_consolidated(output)
        self.assertTrue(source.is_dir())
        self.assertTrue(record.is_file())
        self.assertTrue(observations['complete'])

    def test_materialized_http_plan_uses_one_resolution_traversal_with_exact_observed_tuple(self):
        import sys
        source,parent,reference,_,before=self.consolidated_observation(slots=2)
        raw_path=source/figure.ROLES['figure-sizing-raw']
        values=figure.stream_values(raw_path,figure.RAW_STREAM_SCHEMA)
        try:
            header=next(values)
            count=header['base_batches']+header['observed_batches']
            frames=figure.source_records(reference/figure.FILE_REQUESTS,count)
            planned=[batch['requests'] for batch,frame in zip(values,frames,strict=True)
                     if frame['kind'] in ('http-archived','http-archived-light','http-archived-lean')]
        finally:
            values.close()
        self.assertEqual(header['observed_batches'],1)
        self.assertEqual(len(planned),header['base_batches'])
        expected_digest=figure.digest(figure.encoded(planned))
        expected_manifest=json.loads((reference/figure.MANIFEST).read_bytes())
        self.assertEqual(json.loads((reference/figure.PLAN).read_bytes())['planned_requests_sha256'],expected_digest)
        expected_tuple=figure.verify_tuple({role:reference/name for role,name in figure.output_roles(reference).items()})
        original=figure.stream_values; materialize=figure.materialize_complete_capture
        for linked in (False,True):
            with self.subTest(linked=linked):
                traversals=[]
                def counted(path,schema,**options):
                    direct=Path(path)==raw_path and sys._getframe(1).f_code is materialize.__code__
                    values=original(path,schema,**options)
                    if not direct:return values
                    consumed=[0];traversals.append(consumed)
                    def records():
                        try:
                            yield next(values)
                            for batch in values:
                                consumed[0]+=1
                                yield batch
                        finally:values.close()
                    return records()
                output=self.fixture.root/('single-plan-linked' if linked else 'single-plan-copied')
                observations={}
                with patch.object(figure,'stream_values',new=counted):
                    manifest=materialize(source/figure.MANIFEST,output,
                        link_current_payloads=linked,observations=observations)
                self.assertEqual(traversals,[[count]])
                self.assertEqual(manifest,expected_manifest)
                self.assertEqual(json.loads((output/figure.PLAN).read_bytes())['planned_requests_sha256'],expected_digest)
                actual_tuple=figure.verify_tuple({role:output/name for role,name in figure.output_roles(output).items()})
                self.assertEqual(actual_tuple,expected_tuple)
                for name in (*figure.ROLES.values(),figure.PROVIDER,figure.INVENTORY):
                    self.assertEqual((output/name).read_bytes(),before[name])
                self.assertEqual(self.members(source),before)
                if linked:
                    self.assertTrue(observations['complete'])
                    self.assertEqual(len(observations['linked_members']),4)
                    self.assertEqual(len(observations['remaining_owned_links']),4)

    def test_materialized_http_plan_reuse_keeps_post_resolution_source_and_marker_fences(self):
        import sys
        source,_,_,_,before=self.consolidated_observation(slots=2)
        raw_path=source/figure.ROLES['figure-sizing-raw']
        original=figure.stream_values; materialize=figure.materialize_complete_capture
        for name in (figure.ROLES['figure-sizing-raw'],figure.FILE_REQUESTS,figure.COMPLETE):
            with self.subTest(member=name):
                target=source/name; raw=target.read_bytes(); changed=[]; traversals=[]
                def mutate_after_resolution(path,schema,**options):
                    direct=Path(path)==raw_path and sys._getframe(1).f_code is materialize.__code__
                    values=original(path,schema,**options)
                    if not direct:return values
                    traversals.append(True)
                    def records():
                        try:yield from values
                        finally:values.close()
                        target.write_bytes(raw+b'\n');changed.append(name)
                    return records()
                output=self.fixture.root/('changed-plan-'+str(len(name)))
                try:
                    with patch.object(figure,'stream_values',new=mutate_after_resolution):
                        with self.assertRaisesRegex(ValueError,'changed'):
                            materialize(source/figure.MANIFEST,output)
                    self.assertEqual(traversals,[True])
                    self.assertEqual(changed,[name])
                    self.assertFalse(output.exists())
                    self.assertEqual(target.read_bytes(),raw+b'\n')
                finally:target.write_bytes(raw)
                self.assertEqual(self.members(source),before)

    def test_materialized_observation_and_origin_partition_tampering_refuses(self):
        _,_,output,_,_=self.consolidated_observation()
        original=json.loads((output/figure.PLAN).read_bytes())
        for mutation in ('observation-hash','observation-path','observation-count','partition','frame','omit-origin','wrapper-frame'):
            plan=copy.deepcopy(original)
            if mutation=='observation-hash':plan['observed'][0]['sha256']='0'*64
            elif mutation=='observation-path':plan['observed'][0]['path']+='.other'
            elif mutation=='observation-count':plan['observed_batches']=0
            elif mutation=='partition':
                plan['base_batches']+=1;plan['observed_batches']=0;plan['observed']=[]
            elif mutation=='frame':
                next(row for row in plan['materialized_http_origins'] if row['id']==plan['materialized_root'])['frame_map'].reverse()
            elif mutation=='omit-origin':plan['materialized_http_origins'].pop()
            else:
                row=next(row for row in plan['materialized_http_origins'] if json.loads((output/row['plan']['path']).read_bytes()).get('metadata_mode')==figure.MATERIALIZED_HTTP_MODE)
                row['frame_map'][0]=999
            with self.subTest(mutation=mutation):
                self.rebind_consolidated_plan(output,plan)
                with self.assertRaises((ValueError,KeyError)):figure.verify(output)
        self.rebind_consolidated_plan(output,original)
        self.verify_consolidated(output)

    def test_materialized_original_observation_and_imported_receipt_remain_required(self):
        source,parent,output,record,_=self.consolidated_observation()
        source.rename(source.with_name('source-unavailable'));parent.rename(parent.with_name('parent-unavailable'))
        original=record.read_bytes();record.write_bytes(original+b' ')
        with self.assertRaises(ValueError):figure.verify(output)
        record.write_bytes(original)
        plan=json.loads((output/figure.PLAN).read_bytes())
        ref=next(ref for row in plan['materialized_http_origins'] for name,ref in row['files'].items() if name.endswith('.receipt.json'))
        receipt=output/ref['path'];raw=receipt.read_bytes();receipt.write_bytes(raw+b' ')
        with self.assertRaises(ValueError):figure.verify(output)
        receipt.write_bytes(raw)
        self.verify_consolidated(output)

    def test_capture_target_contract_refuses_unknown_values_before_source_or_transport(self):
        args=self.args('invalid-contract')
        with patch.object(figure.site_info,'validate_snapshot',side_effect=AssertionError('Invalid target read source')):
            for contract in (None, True, figure.REPLAY_CONTRACT_V3, 'wikidict.figure-files-replay.v5', [], {}):
                with self.subTest(contract=contract),self.assertRaisesRegex(ValueError,'Unsupported Figure capture replay contract'):
                    figure.capture_files(args,transport=lambda *_:self.fail('Invalid target fetched'),target_contract=contract)
        self.assertFalse(args.output.exists())
        self.assertFalse(args.output.with_name('.'+args.output.name+'.capture.lock').exists())

    def test_capture_v4_resume_contract_is_bound_and_unchanged_resume_succeeds(self):
        original=figure.capture_files
        def v4(*args,**kwargs):
            return original(*args,**kwargs,target_contract=figure.REPLAY_CONTRACT_V4)
        with patch.object(figure,'capture_files',new=v4):
            args=self.fixture.overlap_wall_stop()
        self.assertEqual(json.loads((args.output/figure.PLAN).read_bytes())['replay_contract'],figure.REPLAY_CONTRACT_V4)
        before=self.members(args.output)
        with self.assertRaisesRegex(ValueError,'resume source, input or request plan changed'):
            original(args,transport=lambda *_:self.fail('Mismatched resume fetched'))
        self.assertEqual(self.members(args.output),before)
        now,advance=self.fixture.overlap_clock()
        def transport(url,timeout):
            title=parse_qs(urlsplit(url).query)['titles'][0]
            return 200,{},figure.encoded(self.fixture.response(title))
        with patch.object(figure.time,'monotonic',side_effect=now):
            manifest=original(args,transport=transport,sleep=advance,target_contract=figure.REPLAY_CONTRACT_V4)
        self.assertEqual(self.fixture.stream_document(args.output)['replay_contract'],figure.REPLAY_CONTRACT_V4)
        self.assertEqual(figure.verify(args.output),manifest)

    def test_capture_v4_keeps_full_parent_and_written_projection_refusals(self):
        parent, _, _ = self.donor.parent(figure.REPLAY_CONTRACT_V4)
        args=self.args('refused-parent');args.reuse=[parent]
        marker=parent/figure.COMPLETE;before=marker.read_bytes()
        marker.write_bytes(figure.encoded(dict(schema=figure.SCHEMA,manifest_sha256='0'*64)))
        with self.assertRaisesRegex(ValueError,'Incomplete'):
            figure.capture_files(args,transport=lambda *_:self.fail('Bad parent fetched'),target_contract=figure.REPLAY_CONTRACT_V4)
        marker.write_bytes(before)
        writer=figure.write_projection_stream
        def wrong(path,document):
            document=copy.deepcopy(document)
            next(row for row in document['records'] if row['requested_file'].endswith('B.tif'))['state']='tiff_default_page'
            return writer(path,document)
        args.output=self.fixture.root/'refused-written-policy'
        with patch.object(figure,'write_projection_stream',new=wrong),self.assertRaises(ValueError):
            figure.capture_files(args,transport=lambda *_:self.fail('Retained bad projection fetched'),target_contract=figure.REPLAY_CONTRACT_V4)
        self.assertFalse((args.output/figure.COMPLETE).exists())


class CaptureTupleLifetimeTests(unittest.TestCase):
    def setUp(self):
        self.fixture = FigureFileTests()
        self.fixture.setUp()
        self.addCleanup(self.fixture.doCleanups)
        cache = patch.object(builder, '_FIGURE_TUPLE_REPLAYS', {})
        cache.start()
        self.addCleanup(cache.stop)

    successor = CaptureParentReplayTests.successor

    def paths(self, root):
        return {role: root / name for role, name in figure.output_roles(root).items()}

    def cache_key(self, root):
        return tuple(sorted((role, str(path.absolute())) for role, path in self.paths(root).items()))

    def offline(self, *_):
        self.fail('A complete retained batch was fetched again')

    def test_capture_tuple_matches_cold_output_and_replays_each_ancestor_once(self):
        args, parent = self.successor('cold-output')
        before = {p.name: p.read_bytes() for p in parent.iterdir()}
        with patch.object(figure, 'verify_stream_document', wraps=figure.verify_stream_document) as replay:
            cold_manifest = figure.capture_files(args, transport=self.offline)
            cold_tuple = builder.verified_figure_tuple(figure, self.paths(args.output), args.wiki, args.date)
            self.assertEqual([Path(c.args[0]).parent for c in replay.call_args_list],
                             [parent, args.output, args.output, parent])
        cold = args.output
        args.output = self.fixture.root / 'owned-output'
        held = []
        original_tuple = figure.verify_tuple
        def tuple_replay(*values, **options):
            held.append((options['retained_cache'], options['inventory_cache']))
            ancestors = [value for key, value in options['retained_cache'].items()
                         if type(key) is tuple and len(key) == 2 and key[0] == 'complete-stream']
            self.assertTrue(ancestors)
            for complete in ancestors:
                self.assertNotIn('document', complete)
                self.assertIn('inventory', complete)
                self.assertTrue(complete['offsets'] and complete['stamps'])
            return original_tuple(*values, **options)
        with patch.object(figure, 'verify_stream_document', wraps=figure.verify_stream_document) as replay, \
                patch.object(figure, 'verify_tuple', side_effect=tuple_replay):
            owned_manifest = builder.capture_figure_files(args, transport=self.offline)
            owned_tuple = builder.verified_figure_tuple(figure, self.paths(args.output), args.wiki, args.date)
            self.assertEqual([Path(c.args[0]).parent for c in replay.call_args_list],
                             [parent, args.output, args.output])
        self.assertEqual(cold_manifest, owned_manifest)
        self.assertEqual(cold_tuple, owned_tuple)
        self.assertEqual({p.name: p.read_bytes() for p in cold.iterdir()},
                         {p.name: p.read_bytes() for p in args.output.iterdir()})
        self.assertEqual(before, {p.name: p.read_bytes() for p in parent.iterdir()})
        self.assertTrue(held)
        self.assertTrue(all(not retained and not inventory for retained, inventory in held))
        self.assertEqual(len(builder._FIGURE_TUPLE_REPLAYS[self.cache_key(args.output)]), 2)
        with patch.object(figure, 'verify', wraps=figure.verify) as replay:
            hashes, captures = builder._validated_auxiliary_state(self.paths(args.output), args.wiki, args.date,
                captured_selection=({}, owned_manifest['source_dump_files'], None))
            self.assertEqual(replay.call_count, 0)
        self.assertEqual(hashes, owned_manifest['outputs'])
        self.assertEqual(set(captures), set(self.paths(args.output)))

    def test_capture_tuple_rejects_coherently_rehashed_false_destination(self):
        args, _ = self.successor('false-output')
        original_tuple = figure.verify_tuple
        held = []
        def corrupt(paths, *values, **options):
            held.append((options['retained_cache'], options['inventory_cache']))
            document = self.fixture.stream_document(args.output)
            document['records'][0]['original_width'] += 1
            path = args.output / figure.ROLES['figure-sizing']
            path.unlink()
            figure.write_projection_stream(path, document)
            manifest = json.loads((args.output / figure.MANIFEST).read_bytes())
            manifest['artifacts'] = figure.payload(args.output)
            manifest['outputs']['figure-sizing'] = figure.digest(path.read_bytes())
            (args.output / figure.MANIFEST).write_bytes(figure.encoded(manifest))
            (args.output / figure.COMPLETE).write_bytes(figure.encoded({
                'schema': figure.SCHEMA, 'manifest_sha256': figure.digest(figure.encoded(manifest))}))
            return original_tuple(paths, *values, **options)
        with patch.object(figure, 'verify_tuple', side_effect=corrupt):
            with self.assertRaisesRegex(ValueError, 'projection stream record differs from exact raw replay'):
                builder.capture_figure_files(args, transport=self.offline)
        self.assertNotIn(self.cache_key(args.output), builder._FIGURE_TUPLE_REPLAYS)
        self.assertTrue(held and all(not a and not b for a, b in held))

    def test_capture_tuple_rechecks_nested_parent_receipt_sql_and_member_identities(self):
        args, ancestor = self.successor('middle')
        figure.capture_files(args, transport=self.offline)
        middle = args.output
        args.reuse, args.reuse_batch = [middle], []
        original_tuple = figure.verify_tuple
        for kind in ('content', 'inode', 'mode', 'missing', 'extra', 'receipt', 'sql'):
            args.output = self.fixture.root / ('mutated-' + kind)
            target = ancestor / figure.PROVIDER
            if kind == 'receipt':
                target = next(ancestor.glob('file-metadata.response-*.receipt.json'))
            elif kind == 'sql':
                target = Path(args.sql[0])
            raw, mode = target.read_bytes(), target.stat().st_mode & 0o7777
            extra = ancestor / 'unexpected-member'
            held = []
            def mutate(*values, **options):
                held.append((options['retained_cache'], options['inventory_cache']))
                result = original_tuple(*values, **options)
                if kind == 'inode':
                    replacement = self.fixture.root / 'replacement'
                    replacement.write_bytes(raw)
                    replacement.replace(target)
                elif kind == 'mode':
                    target.chmod(mode ^ 0o100)
                elif kind == 'missing':
                    target.unlink()
                elif kind == 'extra':
                    extra.write_bytes(b'extra')
                else:
                    target.write_bytes(raw + b'changed')
                return result
            try:
                with self.subTest(kind=kind), patch.object(figure, 'verify_tuple', side_effect=mutate):
                    with self.assertRaises((ValueError, FileNotFoundError)):
                        builder.capture_figure_files(args, transport=self.offline)
                self.assertNotIn(self.cache_key(args.output), builder._FIGURE_TUPLE_REPLAYS)
                self.assertTrue(held and all(not a and not b for a, b in held))
            finally:
                target.write_bytes(raw)
                target.chmod(mode)
                if extra.exists():
                    extra.unlink()

    def test_capture_tuple_callback_failure_and_capture_failure_clear_owned_caches(self):
        args, _ = self.successor('callback-failure')
        original_tuple, original_verify = figure.verify_tuple, figure.verify
        held = []
        class CallbackFailure(RuntimeError):
            pass
        def fail_after_tuple(*values, **options):
            held.append((options['retained_cache'], options['inventory_cache']))
            original_tuple(*values, **options)
            raise CallbackFailure('after completed tuple replay')
        with patch.object(figure, 'verify_tuple', side_effect=fail_after_tuple):
            with self.assertRaisesRegex(CallbackFailure, 'after completed tuple replay'):
                builder.capture_figure_files(args, transport=self.offline)
        self.assertNotIn(self.cache_key(args.output), builder._FIGURE_TUPLE_REPLAYS)
        self.assertTrue(held and all(not a and not b for a, b in held))
        self.assertTrue((args.output / figure.COMPLETE).exists())
        self.assertFalse(list(args.output.glob('figure-failure-*.json')))
        args.output = self.fixture.root / 'capture-failure'
        held.clear()
        def fail_before_complete(root, *values, **options):
            result = original_verify(root, *values, **options)
            if Path(root) == args.output and options.get('require_complete') is False:
                held.append((options['retained_cache'], options['inventory_cache']))
                raise CallbackFailure('before capture completion')
            return result
        with patch.object(figure, 'verify', side_effect=fail_before_complete):
            with self.assertRaisesRegex(CallbackFailure, 'before capture completion'):
                builder.capture_figure_files(args, transport=self.offline)
        self.assertFalse((args.output / figure.COMPLETE).exists())
        self.assertNotIn(self.cache_key(args.output), builder._FIGURE_TUPLE_REPLAYS)
        self.assertTrue(held and all(not a and not b for a, b in held))

    def test_capture_tuple_checks_after_callback_return_and_before_publication(self):
        args, _ = self.successor('publication-root-mutation')
        original_document, original_verify = figure.evidence.document, figure.verify
        for kind in ('root-mode', 'same-byte-inode', 'extra-member', 'validation-mode'):
            args.output = self.fixture.root / ('publication-' + kind)
            def change_output():
                if kind in ('root-mode', 'validation-mode'):
                    args.output.chmod(args.output.stat().st_mode ^ 0o100)
                elif kind == 'same-byte-inode':
                    target = args.output / figure.PROVIDER
                    replacement = self.fixture.root / 'provider-replacement'
                    replacement.write_bytes(target.read_bytes())
                    replacement.replace(target)
                else:
                    (args.output / 'unexpected-member').write_bytes(b'extra')
            def publish(path, value):
                result = original_document(path, value)
                if Path(path) == args.output / figure.COMPLETE and kind != 'validation-mode':
                    change_output()
                return result
            def finish_validation(root, *values, **options):
                result = original_verify(root, *values, **options)
                if Path(root) == args.output and options.get('require_complete') is False and kind == 'validation-mode':
                    change_output()
                return result
            with self.subTest(kind=kind), patch.object(figure.evidence, 'document', side_effect=publish), \
                    patch.object(figure, 'verify', side_effect=finish_validation), \
                    patch.object(figure, 'verify_tuple', wraps=figure.verify_tuple) as tuple_replay:
                with self.assertRaisesRegex(ValueError, 'output changed during'):
                    builder.capture_figure_files(args, transport=self.offline)
                self.assertEqual(tuple_replay.call_count, 0)
            self.assertNotIn(self.cache_key(args.output), builder._FIGURE_TUPLE_REPLAYS)
        args.output = self.fixture.root / 'late-root-mutation'
        original_capture = figure.capture_files
        def after_callback(*values, **options):
            result = original_capture(*values, **options)
            target = args.output / figure.PROVIDER
            target.write_bytes(target.read_bytes() + b'late mutation')
            return result
        with patch.object(figure, 'capture_files', side_effect=after_callback):
            with self.assertRaisesRegex(ValueError, 'before tuple publication'):
                builder.capture_figure_files(args, transport=self.offline)
        self.assertNotIn(self.cache_key(args.output), builder._FIGURE_TUPLE_REPLAYS)

    def test_capture_tuple_cache_retains_policy_role_and_edition_refusals(self):
        args, _ = self.successor('policy-output')
        manifest = builder.capture_figure_files(args, transport=self.offline,
                                              target_contract=figure.REPLAY_CONTRACT_V4)
        self.assertEqual(self.fixture.stream_document(args.output)['replay_contract'], figure.REPLAY_CONTRACT_V4)
        self.assertEqual(json.loads((args.output / figure.PLAN).read_bytes())['replay_contract'], figure.REPLAY_CONTRACT_V4)
        paths = self.paths(args.output)
        with self.assertRaisesRegex(ValueError, 'edition/date mismatch'):
            builder.verified_figure_tuple(figure, paths, 'otherwiktionary', args.date)
        with self.assertRaisesRegex(ValueError, 'requires its Provider'):
            builder.verified_figure_tuple(figure, {k: v for k, v in paths.items() if k != 'file-metadata'},
                                          args.wiki, args.date)
        changed = copy.deepcopy(manifest['source_dump_files'])
        changed[0]['sha1'] = '0' * 40
        with self.assertRaisesRegex(ValueError, 'differs from selected dump'):
            builder._validated_auxiliary_state(paths, args.wiki, args.date,
                                               captured_selection=({}, changed, None))

    def test_capture_tuple_unknown_readset_uses_ordinary_cold_validation(self):
        args, parent = self.successor('unknown-readset')
        with patch.object(builder, 'figure_tuple_guard', return_value=None), \
                patch.object(figure, 'verify_stream_document', wraps=figure.verify_stream_document) as replay:
            result = builder.capture_figure_files(args, transport=self.offline)
            self.assertEqual([Path(c.args[0]).parent for c in replay.call_args_list],
                             [parent, args.output, args.output, parent])
        self.assertNotIn(self.cache_key(args.output), builder._FIGURE_TUPLE_REPLAYS)
        self.assertEqual(figure.verify(args.output), result)


class IncompleteCaptureCompletionTests(unittest.TestCase):
    setUp = CaptureTupleLifetimeTests.setUp
    successor = CaptureParentReplayTests.successor
    offline = CaptureTupleLifetimeTests.offline
    paths = CaptureTupleLifetimeTests.paths

    def unfinished(self, name):
        self.fixture = FigureFileTests()
        self.fixture.setUp()
        self.addCleanup(self.fixture.doCleanups)
        args, parent = self.successor(name)
        manifest = figure.capture_files(args, transport=self.offline)
        (args.output / figure.COMPLETE).unlink()
        return args, parent, manifest

    def finish(self, args):
        return figure.complete_capture(args.output,
            manifest_sha256=figure.digest((args.output / figure.MANIFEST).read_bytes()),
            wiki=args.wiki, date=args.date)

    def test_capture_releases_generated_and_parent_graphs_before_final_replay(self):
        import sys
        import weakref
        args, parent = self.successor('early-release')
        original_verify = figure.verify
        original_provider = figure.verify_provider_stream
        original_source = figure.replay_source
        records = {}
        seen = []
        class Records(list):
            pass
        def provider(path, projection):
            projection['records'] = Records(projection['records'])
            records[Path(path).parent] = weakref.ref(projection['records'])
            return original_provider(path, projection)
        def source(root, *values, **options):
            if Path(root) in records:
                self.assertIsNone(records[Path(root)]())
                seen.append(Path(root))
            return original_source(root, *values, **options)
        def verify(root, *values, **options):
            if Path(root) == args.output and options.get('require_complete') is False:
                self.assertNotIn('document', sys._getframe(1).f_locals)
                complete = [v for k,v in options['retained_cache'].items()
                            if type(k) is tuple and k[0] == 'complete-stream']
                self.assertTrue(complete)
                for value in complete:
                    self.assertNotIn('document', value)
                    self.assertTrue(value['offsets'] and value['stamps'])
            return original_verify(root, *values, **options)
        with patch.object(figure, 'verify_provider_stream', new=provider), \
                patch.object(figure, 'replay_source', new=source), \
                patch.object(figure, 'verify', new=verify):
            manifest = builder.capture_figure_files(args, transport=self.offline)
        self.assertIn(parent, seen)
        self.assertIn(args.output, seen)
        self.assertTrue(all(reference() is None for reference in records.values()))
        self.assertEqual(figure.verify(args.output), manifest)

    def test_complete_capture_replays_full_bytes_and_inserts_only_marker(self):
        args, parent, manifest = self.unfinished('completion')
        original = {p.name: p.read_bytes() for p in args.output.iterdir()}
        parent_original = {p.name: p.read_bytes() for p in parent.iterdir()}
        stamps = {p.name: figure.evidence.stamp(p) for p in args.output.iterdir()}
        with patch.object(figure, 'verify_stream_document', wraps=figure.verify_stream_document) as replay:
            result = self.finish(args)
        self.assertEqual([Path(c.args[0]).parent for c in replay.call_args_list], [args.output, parent])
        self.assertEqual(result, manifest)
        self.assertEqual({p.name: p.read_bytes() for p in args.output.iterdir() if p.name != figure.COMPLETE}, original)
        self.assertEqual({p.name: figure.evidence.stamp(p) for p in args.output.iterdir() if p.name != figure.COMPLETE}, stamps)
        self.assertEqual({p.name: p.read_bytes() for p in parent.iterdir()}, parent_original)
        self.assertEqual((args.output / figure.COMPLETE).read_bytes(), figure.encoded({
            'schema': figure.SCHEMA, 'manifest_sha256': figure.digest(original[figure.MANIFEST])}))
        cold = figure.verify_tuple(self.paths(args.output), args.wiki, args.date)
        self.assertEqual(set(cold), {*figure.ROLES, 'file-metadata'})
        self.assertTrue(all(row[0]['outputs'] == manifest['outputs'] for row in cold.values()))

    def test_complete_capture_requires_exact_selection_absent_marker_and_exclusive_lock(self):
        import fcntl
        args, _, _ = self.unfinished('selection')
        sha = figure.digest((args.output / figure.MANIFEST).read_bytes())
        for changes in ({'manifest_sha256':'0'*64}, {'wiki':'otherwiktionary'}, {'date':'20000101'}):
            values = dict(manifest_sha256=sha, wiki=args.wiki, date=args.date)
            values.update(changes)
            with self.subTest(changes=changes), self.assertRaisesRegex(ValueError, 'selection differs'):
                figure.complete_capture(args.output, **values)
            self.assertFalse((args.output / figure.COMPLETE).exists())
        lock = args.output.with_name('.'+args.output.name+'.capture.lock')
        with lock.open('rb') as stream:
            fcntl.flock(stream.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            with self.assertRaises(BlockingIOError):
                self.finish(args)
        self.assertFalse((args.output / figure.COMPLETE).exists())
        self.finish(args)
        with self.assertRaisesRegex(ValueError, 'requires an incomplete capture'):
            self.finish(args)
        link = self.fixture.root / 'aliased-output'
        link.symlink_to(args.output, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, 'Unsafe incomplete'):
            figure.complete_capture(link, manifest_sha256=sha, wiki=args.wiki, date=args.date)

    def test_complete_capture_refuses_rehashed_false_projection_and_missing_provider(self):
        args, _, _ = self.unfinished('false-projection')
        document = self.fixture.stream_document(args.output)
        document['records'][0]['original_width'] += 1
        projection = args.output / figure.ROLES['figure-sizing']
        projection.unlink()
        figure.write_projection_stream(projection, document)
        manifest = json.loads((args.output / figure.MANIFEST).read_bytes())
        manifest['artifacts'] = figure.payload(args.output)
        manifest['outputs']['figure-sizing'] = figure.digest(projection.read_bytes())
        (args.output / figure.MANIFEST).write_bytes(figure.encoded(manifest))
        with self.assertRaisesRegex(ValueError, 'differs from exact raw replay'):
            self.finish(args)
        self.assertFalse((args.output / figure.COMPLETE).exists())
        args, _, _ = self.unfinished('missing-provider')
        (args.output / figure.PROVIDER).unlink()
        with self.assertRaises((ValueError, FileNotFoundError)):
            self.finish(args)
        self.assertFalse((args.output / figure.COMPLETE).exists())

    def test_complete_capture_rechecks_output_parent_and_sql_after_full_validation(self):
        for kind in ('root-mode', 'provider-inode', 'extra-member', 'ancestor-receipt', 'sql'):
            args, parent, _ = self.unfinished('late-'+kind)
            original_verify = figure.verify
            held = []
            def mutate(root, *values, **options):
                result = original_verify(root, *values, **options)
                if Path(root) == args.output:
                    held.append((options['retained_cache'], options['inventory_cache']))
                    if kind == 'root-mode':
                        args.output.chmod(args.output.stat().st_mode ^ 0o020)
                    elif kind == 'provider-inode':
                        path = args.output / figure.PROVIDER
                        replacement = self.fixture.root / 'provider-replacement'
                        replacement.write_bytes(path.read_bytes())
                        replacement.replace(path)
                    elif kind == 'extra-member':
                        (args.output / 'extra').write_bytes(b'extra')
                    else:
                        path = (next(parent.glob('file-metadata.response-*.receipt.json'))
                                if kind == 'ancestor-receipt' else Path(args.sql[0]))
                        path.write_bytes(path.read_bytes()+b'changed')
                return result
            # Each case owns an independent fixture because SQL mutation is deliberate.
            with self.subTest(kind=kind), patch.object(figure, 'verify', new=mutate), \
                    self.assertRaises((ValueError, FileNotFoundError)):
                self.finish(args)
            self.assertFalse((args.output / figure.COMPLETE).exists())
            self.assertTrue(held and all(not a and not b for a,b in held))

    def test_complete_capture_failure_clears_caches_and_removes_only_owned_marker(self):
        args, _, _ = self.unfinished('verify-failure')
        original_verify = figure.verify
        held = []
        class Stop(RuntimeError):
            pass
        def fail(root, *values, **options):
            result = original_verify(root, *values, **options)
            if Path(root) == args.output:
                held.append((options['retained_cache'], options['inventory_cache']))
                raise Stop('after full verification')
            return result
        with patch.object(figure, 'verify', new=fail), self.assertRaisesRegex(Stop, 'after full'):
            self.finish(args)
        self.assertFalse((args.output / figure.COMPLETE).exists())
        self.assertTrue(held and all(not a and not b for a,b in held))
        original_fsync = figure.os.fsync
        def late_change(fd):
            original_fsync(fd)
            args.output.chmod(args.output.stat().st_mode ^ 0o020)
        with patch.object(figure.os, 'fsync', new=late_change), \
                self.assertRaisesRegex(ValueError, 'completion publication'):
            self.finish(args)
        self.assertFalse((args.output / figure.COMPLETE).exists())
        def replace_marker(fd):
            original_fsync(fd)
            path = args.output / figure.COMPLETE
            replacement = self.fixture.root / 'foreign-same-byte-marker'
            replacement.write_bytes(path.read_bytes())
            replacement.chmod(0o600)
            replacement.replace(path)
        with patch.object(figure.os, 'fsync', new=replace_marker), \
                self.assertRaisesRegex(ValueError, 'marker identity changed'):
            self.finish(args)
        # A foreign replacement is refused and retained as evidence, never
        # deleted under ownership of our now-unlinked creation FD.
        self.assertTrue((args.output / figure.COMPLETE).is_file())
        (args.output / figure.COMPLETE).unlink()
        # A clean successor can still finish the same unchanged payloads.
        self.finish(args)
        self.assertTrue((args.output / figure.COMPLETE).is_file())


class CompleteSelectionDocumentTests(unittest.TestCase):
    def fresh(self):
        fixture = FigureFileTests()
        fixture.setUp()
        self.addCleanup(fixture.doCleanups)
        args, observation, manifest = fixture.complete_stream_fixture()
        return fixture, args, observation, manifest

    def offline(self, *_):
        self.fail('Selection or completion attempted HTTP')

    def test_validation_only_cold_parent_verifies_all_records_without_reloading_them(self):
        fixture, args, _, manifest = self.fresh()
        parent = args.output
        expected = fixture.stream_document(parent)
        before = {p.name: p.read_bytes() for p in parent.iterdir()}
        original = figure.stream_values
        traversals = []
        def stream(path, schema, **options):
            values = original(path, schema, **options)
            count = [0]
            if Path(path) == parent / figure.ROLES['figure-sizing']:
                traversals.append(count)
            try:
                yield next(values)
                for value in values:
                    count[0] += 1
                    yield value
            finally:
                values.close()
        cache, inventory = {}, {}
        with patch.object(figure, 'stream_values', new=stream), \
                patch.object(figure, 'verify', wraps=figure.verify) as verify:
            result = figure.read_complete_capture(parent / figure.MANIFEST, cache,
                inventory_cache=inventory, include_document=False)
        self.assertEqual(verify.call_count, 1)
        self.assertEqual([count[0] for count in traversals], [len(expected['records']), 0])
        self.assertNotIn('document', result)
        self.assertEqual(result['projection_header'], {k:v for k,v in expected.items() if k != 'records'})
        self.assertEqual(result['manifest'], manifest)
        self.assertTrue(result['offsets'] and result['stamps'] and inventory)
        for number in range(len(result['offsets'])):
            reference = dict(kind='complete-stream', path=str(parent / figure.MANIFEST),
                             sha256=result['manifest_sha256'], batch=number)
            self.assertEqual(figure.complete_stream_batch(reference, cache)['requests'],
                             list(figure.stream_values(parent / figure.ROLES['figure-sizing-raw'],
                                                       figure.RAW_STREAM_SCHEMA))[number + 1]['requests'])
        figure.check_prefix_cache(cache)
        figure.check_inventory_replay_cache(inventory)
        self.assertEqual(before, {p.name: p.read_bytes() for p in parent.iterdir()})

    def test_mixed_validation_then_selection_loads_exact_document_once_without_reverification(self):
        fixture, args, _, _ = self.fresh()
        path = args.output / figure.MANIFEST
        expected = fixture.stream_document(args.output)
        cache, inventory = {}, {}
        lean = figure.read_complete_capture(path, cache, inventory_cache=inventory, include_document=False)
        proof = {key:value for key,value in lean.items()}
        with patch.object(figure, 'verify', wraps=figure.verify) as verify, \
                patch.object(figure, 'stream_values', wraps=figure.stream_values) as stream:
            selected = figure.read_complete_capture(path, cache, inventory_cache=inventory)
            self.assertIs(selected, lean)
            self.assertEqual(selected['document'], expected)
            again = figure.read_complete_capture(path, cache, inventory_cache=inventory)
            validation = figure.read_complete_capture(path, cache, include_document=False)
            self.assertIs(again['document'], selected['document'])
            self.assertIs(validation, selected)
            self.assertEqual(verify.call_count, 0)
            self.assertEqual(stream.call_count, 1)
        self.assertEqual({key:value for key,value in selected.items() if key != 'document'}, proof)
        # Existing direct callers still receive the selection document by default.
        cold = figure.read_complete_capture(path)
        self.assertEqual(cold, selected)
        figure.check_prefix_cache(cache)
        figure.check_inventory_replay_cache(inventory)

    def test_nested_completion_keeps_full_replay_and_never_retains_selection_documents(self):
        fixture, args, observation, _ = self.fresh()
        parent = args.output
        args.output = fixture.root / 'selection-child'
        args.reuse = [parent]
        args.reuse_batch = [observation]
        figure.capture_files(args, transport=self.offline)
        child = args.output
        args.output = fixture.root / 'completion-grandchild'
        args.reuse = [child]
        args.reuse_batch = []
        manifest = figure.capture_files(args, transport=self.offline)
        (args.output / figure.COMPLETE).unlink()
        original = {p.name: p.read_bytes() for p in args.output.iterdir()}
        original_read = figure.read_complete_capture
        held, roots = [], set()
        def read(path, cache=None, **options):
            result = original_read(path, cache, **options)
            self.assertIs(options.get('include_document'), False)
            self.assertNotIn('document', result)
            roots.add(Path(path).parent)
            held.append(cache)
            return result
        with patch.object(figure, 'read_complete_capture', new=read), \
                patch.object(figure, 'verify_stream_document', wraps=figure.verify_stream_document) as replay:
            result = figure.complete_capture(args.output,
                manifest_sha256=figure.digest(original[figure.MANIFEST]), wiki=args.wiki, date=args.date)
        self.assertEqual(result, manifest)
        self.assertEqual(roots, {parent, child})
        self.assertEqual([Path(c.args[0]).parent for c in replay.call_args_list],
                         [args.output, child, parent])
        self.assertTrue(held and all(not cache for cache in held))
        self.assertEqual(original, {p.name:p.read_bytes() for p in args.output.iterdir() if p.name != figure.COMPLETE})
        self.assertEqual(figure.verify(args.output), manifest)
        self.assertEqual((args.output / figure.COMPLETE).read_bytes(), figure.encoded({
            'schema':figure.SCHEMA, 'manifest_sha256':figure.digest(original[figure.MANIFEST])}))

    def test_validation_only_cold_path_still_rejects_semantic_and_context_corruption(self):
        for kind in ('projection', 'provider', 'receipt', 'sql'):
            fixture, args, _, _ = self.fresh()
            parent = args.output
            if kind == 'projection':
                document = fixture.stream_document(parent)
                document['records'][0]['original_width'] += 1
                path = parent / figure.ROLES['figure-sizing']
                path.unlink()
                figure.write_projection_stream(path, document)
                manifest = json.loads((parent / figure.MANIFEST).read_bytes())
                manifest['artifacts'] = figure.payload(parent)
                manifest['outputs']['figure-sizing'] = figure.digest(path.read_bytes())
                (parent / figure.MANIFEST).write_bytes(figure.encoded(manifest))
                (parent / figure.COMPLETE).write_bytes(figure.encoded({
                    'schema':figure.SCHEMA, 'manifest_sha256':figure.digest(figure.encoded(manifest))}))
            elif kind == 'provider':
                (parent / figure.PROVIDER).unlink()
            else:
                path = (next(parent.glob('file-metadata.response-*.receipt.json'))
                        if kind == 'receipt' else Path(args.sql[0]))
                path.write_bytes(path.read_bytes() + b'changed')
            cache = {}
            with self.subTest(kind=kind), self.assertRaises((ValueError, FileNotFoundError)):
                figure.read_complete_capture(parent / figure.MANIFEST, cache, include_document=False)
            self.assertNotIn(('complete-stream', str(parent / figure.MANIFEST)), cache)

    def test_late_selection_rechecks_projection_members_receipts_sql_and_directory(self):
        for kind in ('projection-inode', 'ancestor-receipt', 'member', 'sql', 'root-mode'):
            fixture, args, _, _ = self.fresh()
            parent = args.output
            cache, inventory = {}, {}
            lean = figure.read_complete_capture(parent / figure.MANIFEST, cache,
                inventory_cache=inventory, include_document=False)
            original_stream = figure.stream_values
            mutated = []
            def stream(path, schema, **options):
                yield from original_stream(path, schema, **options)
                if Path(path) == parent / figure.ROLES['figure-sizing']:
                    if kind == 'projection-inode':
                        replacement = fixture.root / 'same-byte-projection'
                        replacement.write_bytes(Path(path).read_bytes())
                        replacement.replace(path)
                    elif kind == 'member':
                        (parent / 'extra-member').write_bytes(b'extra')
                    elif kind == 'root-mode':
                        parent.chmod(parent.stat().st_mode ^ 0o020)
                    else:
                        target = (next(parent.glob('file-metadata.response-*.receipt.json'))
                                  if kind == 'ancestor-receipt' else Path(args.sql[0]))
                        target.write_bytes(target.read_bytes() + b'changed')
                    mutated.append(kind)
            with self.subTest(kind=kind), patch.object(figure, 'stream_values', new=stream), \
                    self.assertRaises((ValueError, FileNotFoundError)):
                figure.read_complete_capture(parent / figure.MANIFEST, cache, inventory_cache=inventory)
            self.assertEqual(mutated, [kind])
            self.assertNotIn('document', lean)
            self.assertNotIn(('complete-stream', str(parent / figure.MANIFEST)), cache)

    def test_late_selection_parse_failure_publishes_no_document_and_next_scope_is_cold(self):
        _, args, _, _ = self.fresh()
        path = args.output / figure.MANIFEST
        cache = {}
        lean = figure.read_complete_capture(path, cache, include_document=False)
        original_stream = figure.stream_values
        class Stop(RuntimeError):
            pass
        def interrupted(path, schema, **options):
            values = original_stream(path, schema, **options)
            try:
                yield next(values)
                raise Stop('selection interrupted')
            finally:
                values.close()
        with patch.object(figure, 'stream_values', new=interrupted), self.assertRaisesRegex(Stop, 'interrupted'):
            figure.read_complete_capture(path, cache)
        self.assertNotIn('document', lean)
        self.assertNotIn(('complete-stream', str(path)), cache)
        with patch.object(figure, 'verify', wraps=figure.verify) as verify:
            selected = figure.read_complete_capture(path, cache)
        self.assertEqual(verify.call_count, 1)
        self.assertTrue(selected['document']['records'])
        self.assertEqual(selected['manifest_sha256'], lean['manifest_sha256'])

    def test_mixed_selection_without_inventory_proof_revalidates_sql_before_and_after_loading(self):
        for kind in ('ordinary', 'changed-before', 'changed-during', 'empty-supplied-cache'):
            fixture, args, _, _ = self.fresh()
            parent = args.output
            cache = {}
            lean = figure.read_complete_capture(parent / figure.MANIFEST, cache, include_document=False)
            original_stream = figure.stream_values
            target = Path(args.sql[0])
            if kind in ('changed-before', 'empty-supplied-cache'):
                target.write_bytes(target.read_bytes() + b'changed')
            loaded = []
            def stream(path, schema, **options):
                yield from original_stream(path, schema, **options)
                if Path(path) == parent / figure.ROLES['figure-sizing'] and 'identity_out' in options:
                    loaded.append(True)
                    if kind == 'changed-during':
                        target.write_bytes(target.read_bytes() + b'changed')
            options = {'inventory_cache': {}} if kind == 'empty-supplied-cache' else {}
            with self.subTest(kind=kind), patch.object(figure, 'stream_values', new=stream), \
                    patch.object(figure, 'source_inventory', wraps=figure.source_inventory) as inventory:
                if kind == 'ordinary':
                    result = figure.read_complete_capture(parent / figure.MANIFEST, cache, **options)
                    self.assertIs(result, lean)
                    self.assertEqual(result['document'], fixture.stream_document(parent))
                    self.assertEqual(loaded, [True])
                else:
                    with self.assertRaises((ValueError, FileNotFoundError)):
                        figure.read_complete_capture(parent / figure.MANIFEST, cache, **options)
                    self.assertNotIn('document', lean)
                    self.assertNotIn(('complete-stream', str(parent / figure.MANIFEST)), cache)
                    self.assertEqual(bool(loaded), kind == 'changed-during')
                self.assertEqual(inventory.call_count, 1)


class FigureBatchSiteReuseTests(unittest.TestCase):
    setUp = FigureFileTests.setUp
    write_projection = FigureFileTests.write_projection
    response = FigureFileTests.response
    batch = FigureFileTests.batch
    project = FigureFileTests.project

    def raw_wrapper_reference(self):
        registration = figure._figure_site_registration
        def replay(site, general, wiki, approved):
            raw = figure.encoded(site)
            with patch.object(figure, '_figure_site_registration', new=registration):
                return figure._figure_site_profile(raw, general, wiki,
                    dict(approved, site_raw_sha256=figure.digest(raw)), approved)
        return patch.object(figure, '_figure_site_registration', new=replay)

    def test_batch_site_reuse_preserves_complete_facts_and_avoids_second_decode(self):
        names = ['\u0645\u0644\u0641:First.svg', '\u0645\u0644\u0641:Second.svg']
        batches = [self.batch(name) for name in names]
        original = copy.deepcopy(batches)
        targets = {batch['response'].encode(): index for index, batch in enumerate(batches)}
        decode, digest = figure.decode, figure.digest
        def run(reference):
            counts = {'decodes': [0, 0], 'digests': [0, 0]}
            def counted_decode(raw):
                if raw in targets:
                    counts['decodes'][targets[raw]] += 1
                return decode(raw)
            def counted_digest(raw):
                if raw in targets:
                    counts['digests'][targets[raw]] += 1
                return digest(raw)
            with patch.object(figure, 'decode', new=counted_decode), \
                    patch.object(figure, 'digest', new=counted_digest):
                if reference:
                    with self.raw_wrapper_reference():
                        result = self.project(batches)
                else:
                    result = self.project(batches)
            return result, counts
        expected, before = run(True)
        actual, after = run(False)
        self.assertEqual(actual, expected)
        self.assertEqual(b''.join(figure.provider_chunks(actual)),
                         b''.join(figure.provider_chunks(expected)))
        self.assertEqual(batches, original)
        self.assertEqual([row['requested_file'] for row in actual['records']], names)
        self.assertEqual([(row['state'], row['original_width'], row['original_height'])
                          for row in actual['records']], [('eligible', 800, 600)] * 2)
        self.assertEqual(before, {'decodes': [2, 2], 'digests': [2, 2]})
        self.assertEqual(after, {'decodes': [1, 1], 'digests': [0, 0]})
        print(json.dumps({'figure_batch_response_operation_counts':
            {'raw_wrapper_reference': before, 'decoded_caller': after},
            'whole_tuple_timing_claimed': False}, sort_keys=True))

    def test_batch_site_reuse_keeps_each_response_refusal_and_duplicate_json(self):
        title = '\u0645\u0644\u0641:Second.svg'
        for mode in ('server', 'language', 'core', 'extensions', 'duplicate-extension',
                     'missing-extensions', 'timestamp', 'warning', 'error', 'duplicate-json'):
            with self.subTest(mode=mode):
                response = self.response(title)
                general = response['query']['general']
                if mode == 'server':
                    general['server'] = 'https://foreign.invalid'
                elif mode == 'language':
                    general['lang'] = 'fr'
                elif mode == 'core':
                    general['git-hash'] = '0' * 40
                elif mode == 'extensions':
                    response['query']['extensions'] = []
                elif mode == 'duplicate-extension':
                    response['query']['extensions'].append(copy.deepcopy(response['query']['extensions'][0]))
                elif mode == 'missing-extensions':
                    del response['query']['extensions']
                elif mode == 'timestamp':
                    response['curtimestamp'] = '2026-13-05T23:00:00Z'
                elif mode == 'warning':
                    response['warnings'] = {}
                elif mode == 'error':
                    response['errors'] = []
                batch = self.batch(title, response)
                if mode == 'duplicate-json':
                    batch['response'] = '{"curtimestamp":"2026-10-05T23:00:00Z",' + batch['response'][1:]
                batches = [self.batch(), batch]
                original = copy.deepcopy(batches)
                with self.raw_wrapper_reference():
                    with self.assertRaises(ValueError) as expected:
                        self.project(batches)
                with self.assertRaises(ValueError) as actual:
                    self.project(batches)
                self.assertEqual(str(actual.exception), str(expected.exception))
                self.assertEqual(batches, original)

    def test_raw_site_wrapper_error_order_and_first_invalid_batch_stay_exact(self):
        raw = figure.encoded(self.site_api)
        approved = figure.FIGURE_SOURCE_PROFILES[self.core]
        general = self.site_api['query']['general']
        profile = dict(approved, site_raw_sha256=figure.digest(raw))
        with patch.object(figure, 'decode', side_effect=AssertionError('profile must fail before parsing')):
            with self.assertRaisesRegex(ValueError, 'Unreviewed or changed figure sizing source profile'):
                figure._figure_site_profile(b'{', general, self.wiki, profile, approved)
        duplicate = '{"curtimestamp":"2026-10-05T23:00:00Z",' + raw.decode()[1:]
        duplicated_profile = dict(approved, site_raw_sha256=figure.digest(duplicate.encode()))
        with self.assertRaisesRegex(ValueError, 'Duplicate JSON key'):
            figure._figure_site_profile(duplicate.encode(), general, self.wiki, duplicated_profile, approved)
        response = self.response()
        response['warnings'] = {}
        batch = self.batch(response=response)
        def source():
            yield batch
            raise AssertionError('an invalid registration must stop before the next batch')
        with self.assertRaisesRegex(ValueError, 'Unknown figure site registration evidence'):
            figure.file_records(source(), self.namespace.read_bytes(), self.wiki, self.date,
                raw, has_batches=True, record_limit=50)

    def test_registration_reuse_checks_same_bytes_once_with_complete_result_parity(self):
        raw=figure.encoded(self.site_api)
        batches=[self.batch(),self.batch('\u0645\u0644\u0641:Second.svg')]
        before=copy.deepcopy(batches); registration=copy.deepcopy(self.site_api)
        self.assertTrue(all(batch['response'].encode()!=raw for batch in batches))
        approved=figure.FIGURE_SOURCE_PROFILES[self.core]
        profile=dict(approved,site_raw_sha256=figure.digest(raw))
        decode,digest,validate=figure.decode,figure.digest,figure._figure_site_registration
        def original_registration(site,general,wiki,selected):
            if site==registration:
                with patch.object(figure,'_figure_site_registration',new=validate):
                    return figure._figure_site_profile(raw,general,wiki,profile,selected)
            return validate(site,general,wiki,selected)
        def run(reference):
            counts={'decode':0,'digest':0}
            def counted_decode(value):
                if value==raw:counts['decode']+=1
                return decode(value)
            def counted_digest(value):
                if value==raw:counts['digest']+=1
                return digest(value)
            with patch.object(figure,'decode',new=counted_decode),patch.object(figure,'digest',new=counted_digest):
                if reference:
                    with patch.object(figure,'_figure_site_registration',new=original_registration):
                        result=figure.file_records(batches,self.namespace.read_bytes(),self.wiki,self.date,
                            raw,has_batches=True,record_limit=50)
                else:
                    result=figure.file_records(batches,self.namespace.read_bytes(),self.wiki,self.date,
                        raw,has_batches=True,record_limit=50)
            return result,counts
        expected,old_counts=run(True);actual,new_counts=run(False)
        self.assertEqual(actual,expected)
        self.assertEqual(actual['source_profile'],profile)
        self.assertEqual(b''.join(figure.provider_chunks(actual)),b''.join(figure.provider_chunks(expected)))
        self.assertEqual(old_counts,{'decode':2,'digest':2})
        self.assertEqual(new_counts,{'decode':1,'digest':1})
        self.assertEqual(batches,before);self.assertEqual(self.site_api,registration)
        self.assertEqual(figure.encoded(self.site_api),raw)
        print(json.dumps({'registration_operations':{'original_wrapper':old_counts,'decoded_caller':new_counts},
            'whole_tuple_timing_claimed':False},sort_keys=True))

    def test_registration_reuse_preserves_edition_source_registration_and_json_refusals(self):
        batches=[self.batch()];before=copy.deepcopy(batches)
        for mode in ('edition','server','core','language','extensions','duplicate-extension',
                     'missing-extensions','timestamp','missing-timestamp','warning','duplicate-json'):
            with self.subTest(mode=mode):
                site=copy.deepcopy(self.site_api);general=site['query']['general']
                if mode=='edition':general['wikiid']='frwiktionary'
                elif mode=='server':general['server']='https://foreign.invalid'
                elif mode=='core':general['git-hash']='0'*40
                elif mode=='language':general['lang']='fr'
                elif mode=='extensions':site['query']['extensions']=[]
                elif mode=='duplicate-extension':site['query']['extensions'].append(copy.deepcopy(site['query']['extensions'][0]))
                elif mode=='missing-extensions':del site['query']['extensions']
                elif mode=='timestamp':site['curtimestamp']='2026-13-05T23:00:00Z'
                elif mode=='missing-timestamp':del site['curtimestamp']
                elif mode=='warning':site['warnings']={}
                raw=figure.encoded(site)
                if mode=='duplicate-json':raw=b'{"curtimestamp":"2026-10-05T23:00:00Z",'+raw[1:]
                original=bytes(raw);site_before=copy.deepcopy(site)
                with self.assertRaises(ValueError):
                    figure.file_records(batches,self.namespace.read_bytes(),self.wiki,self.date,
                        raw,has_batches=True,record_limit=50)
                self.assertEqual(raw,original);self.assertEqual(site,site_before);self.assertEqual(batches,before)

    def test_registration_reuse_keeps_no_batch_and_external_profile_hash_contracts(self):
        raw=figure.encoded(self.site_api);namespace=self.namespace.read_bytes()
        decode,digest=figure.decode,figure.digest;counts={'decode':0,'digest':0}
        def counted_decode(value):
            if value==raw:counts['decode']+=1
            return decode(value)
        def counted_digest(value):
            if value==raw:counts['digest']+=1
            return digest(value)
        with patch.object(figure,'decode',new=counted_decode),patch.object(figure,'digest',new=counted_digest), \
                patch.object(figure,'_figure_site_registration',side_effect=AssertionError('no-batch registration changed')), \
                patch.object(figure,'_figure_site_profile',side_effect=AssertionError('no-batch profile changed')):
            result=figure.file_records((),namespace,self.wiki,self.date,raw,has_batches=False,record_limit=0)
        self.assertEqual(result,dict(wiki=self.wiki,content_language=self.site_api['query']['general']['lang'],
            core_revision=self.core,namespace_registry_sha256=figure.digest(namespace),source_profile=None,
            records=[],base_batches=0,observed_batches=0))
        self.assertEqual(counts,{'decode':1,'digest':0})
        approved=figure.FIGURE_SOURCE_PROFILES[self.core]
        profile=dict(approved,site_raw_sha256='0'*64)
        with patch.object(figure,'decode',side_effect=AssertionError('external hash must refuse before parsing')):
            with self.assertRaisesRegex(ValueError,'Unreviewed or changed figure sizing source profile'):
                figure._figure_site_profile(raw,self.site_api['query']['general'],self.wiki,profile,approved)
        self.assertEqual(figure.encoded(self.site_api),raw)



class StaticWebPOptionalMediaTests(unittest.TestCase):
    setUp = StaticWebPProfileTests.setUp
    response = StaticWebPProfileTests.response
    document = StaticWebPProfileTests.document
    verify = StaticWebPProfileTests.verify

    def retained_info(self):
        raw = (Path(__file__).parent / 'testdata/en-static-webp/abc-rose-page.json').read_bytes()
        self.assertEqual((len(raw), hashlib.sha256(raw).hexdigest()), (1027, '652b6470a978ad55afbee83aa2cbfbe6b3d9ee96074ee022f0308970c2687f37'))
        page = json.loads(raw)
        self.assertEqual(page['title'], 'File:ABC with rose syrup.webp')
        info = page['imageinfo'][0]
        self.assertEqual((info['width'], info['height']), (1080, 1920))
        self.assertNotIn('media-metadata', {row['name']: row['value'] for row in info['metadata']})
        return info

    def controlled_response(self, info):
        # Retain the actual metadata/axes in the established controlled page envelope.
        response = self.response()
        target = response['query']['pages'][0]['imageinfo'][0]
        target.update(width=info['width'], height=info['height'], metadata=copy.deepcopy(info['metadata']))
        return response

    def test_retained_absent_and_present_media_preserve_static_profile_and_old_contracts(self):
        info = self.retained_info(); before = copy.deepcopy(info)
        self.assertIsNone(figure._figure_static_webp_axes(info, 1080, 1920))
        for value in (None, [], [{'name':'Orientation', 'value':1}]):
            for version in (2, 3):
                with self.subTest(media=value, version=version):
                    selected = copy.deepcopy(info)
                    next(x for x in selected['metadata'] if x['name']=='metadata')['value'][0]['value'] = version
                    if value is not None: selected['metadata'].append({'name':'media-metadata', 'value':value})
                    document, raw, site = self.document(self.controlled_response(selected))
                    self.assertEqual(document['records'][0]['state'], 'eligible')
                    self.verify(document, raw, site)
                    for profile in (figure.FIGURE_PROFILE_V3, figure.FIGURE_PROFILE_V4):
                        old, original, _ = self.document(self.controlled_response(selected), profile)
                        self.assertEqual(original, raw)
                        self.assertEqual(old['records'][0], dict(document['records'][0], state='unsupported'))
                        self.verify(old, raw, site)
                        self.assertEqual(b''.join(figure.provider_chunks(old)), b''.join(figure.provider_chunks(document)))
        self.assertEqual(info, before)

    def test_present_invalid_duplicate_or_animated_media_remains_unsupported(self):
        original = self.retained_info()
        cases = [('null', None), ('mapping', {}), ('string', ''), ('boolean', False),
                 ('malformed-row', [{'name':'Orientation'}]),
                 ('extra-row-key', [{'name':'Orientation', 'value':1, 'extra':0}]),
                 ('duplicate-orientation', [{'name':'Orientation','value':1}, {'name':'Orientation','value':1}])]
        cases += [('error-'+key, [{'name':key, 'value':False}]) for key in ('_error','error','errors','warnings')]
        cases += [('orientation-'+repr(value), [{'name':'Orientation','value':value}]) for value in (None, True, '1', 0, 2, 6)]
        for name, media in cases:
            with self.subTest(case=name):
                info = copy.deepcopy(original); info['metadata'].append({'name':'media-metadata','value':media})
                with self.assertRaises(ValueError): figure._figure_static_webp_axes(info, 1080, 1920)
                document, raw, site = self.document(self.controlled_response(info))
                self.assertEqual(document['records'][0]['state'], 'unsupported'); self.verify(document, raw, site)
                forged = copy.deepcopy(document); forged['records'][0]['state'] = 'eligible'
                with self.assertRaisesRegex(ValueError, 'exact batch replay'): self.verify(forged, raw, site)
        for mode in ('duplicate-field', 'animated', 'missing-static', 'wrong-width', 'wrong-version'):
            with self.subTest(mode=mode):
                info = copy.deepcopy(original); rows = info['metadata']
                if mode=='duplicate-field': rows.extend([{'name':'media-metadata','value':[]}, {'name':'media-metadata','value':[]}])
                elif mode=='animated': next(x for x in rows if x['name']=='animated')['value'] = True
                elif mode=='missing-static': rows[:] = [x for x in rows if x['name']!='animated']
                elif mode=='wrong-width': next(x for x in rows if x['name']=='width')['value'] = 1079
                else: next(x for x in rows if x['name']=='metadata')['value'][0]['value'] = 4
                with self.assertRaises(ValueError): figure._figure_static_webp_axes(info, 1080, 1920)
                document, raw, site = self.document(self.controlled_response(info))
                self.assertEqual(document['records'][0]['state'], 'unsupported'); self.verify(document, raw, site)


class StaticWebPPinnedRepairTests(unittest.TestCase):
    def historical_parent(self):
        owner = ExplicitProfileReprojectionTests()
        owner.setUp(); self.addCleanup(owner.doCleanups)
        response = owner.response
        def absent(title='ملف:A.webp'):
            value = response(title)
            rows = value['query']['pages'][0]['imageinfo'][0]['metadata']
            rows[:] = [row for row in rows if row['name'] != 'media-metadata']
            return value
        owner.response = absent
        current = figure._figure_static_webp_axes
        def legacy(info, width, height):
            # Reproduce only the exact preserved historical absent-field bug.
            fields = figure._figure_metadata_map(info.get('metadata'))
            figure._figure_metadata_map(fields.get('media-metadata'))
            return current(info, width, height)
        with patch.object(figure, '_figure_static_webp_axes', side_effect=legacy):
            source, _ = owner.parent()
            parent, _, _ = owner.upgrade(source)
        old = owner.fixture.stream_document(parent)
        self.assertEqual(old['source_profile']['kind'], figure.FIGURE_PROFILE_V5)
        self.assertEqual(old['replay_contract'], figure.REPLAY_CONTRACT_V4)
        self.assertEqual(next(r for r in old['records'] if r['mime']=='image/webp')['state'], 'unsupported')
        return owner, parent, old

    def test_pinned_same_v5_repair_derives_all_raw_and_preserves_original_members(self):
        owner, source, old = self.historical_parent()
        before = {p.name:p.read_bytes() for p in source.iterdir()}
        inodes = {p.name:(p.stat().st_dev,p.stat().st_ino,p.stat().st_mode) for p in source.iterdir()}
        with self.assertRaises(ValueError): figure.verify(source)
        output = source.with_name(source.name+'-repair')
        observations = {}
        with patch.object(figure.evidence, 'get_response', side_effect=AssertionError('offline repair fetched')):
            manifest = figure.reproject_capture(source, output,
                repair_manifest_sha256=figure.digest(before[figure.MANIFEST]), observations=observations)
        current = owner.fixture.stream_document(output)
        expected = copy.deepcopy(old['records'])
        next(r for r in expected if r['mime']=='image/webp')['state']='eligible'
        self.assertEqual(current['records'], expected)
        self.assertEqual(current['source_profile'], old['source_profile'])
        self.assertEqual(current['replay_contract'], old['replay_contract'])
        self.assertEqual((output/figure.PROVIDER).read_bytes(), before[figure.PROVIDER])
        self.assertEqual(figure.verify(output), manifest)
        self.assertEqual(before, {p.name:p.read_bytes() for p in source.iterdir()})
        self.assertEqual(inodes, {p.name:(p.stat().st_dev,p.stat().st_ino,p.stat().st_mode) for p in source.iterdir()})
        self.assertTrue(observations['complete'])
        self.assertFalse(observations['old_projection_semantically_trusted'])

    def test_pinned_repair_refuses_missing_identity_or_corrupt_original_before_output(self):
        for mode in ('absent-auth','wrong-hash','invalid-hash','manifest','raw','projection','complete','contract','profile'):
            with self.subTest(mode=mode):
                owner, source, _ = self.historical_parent()
                expected = figure.digest((source/figure.MANIFEST).read_bytes())
                options = dict(repair_manifest_sha256=expected)
                if mode=='absent-auth': options.clear()
                elif mode=='wrong-hash': options['repair_manifest_sha256']='0'*64
                elif mode=='invalid-hash': options['repair_manifest_sha256']=True
                elif mode=='contract': options['target_contract']=figure.REPLAY_CONTRACT
                elif mode=='profile': options['target_profile']=figure.FIGURE_PROFILE_V5
                elif mode=='complete': (source/figure.COMPLETE).unlink()
                else:
                    name = {'manifest':figure.MANIFEST,'raw':figure.ROLES['figure-sizing-raw'],'projection':figure.ROLES['figure-sizing']}[mode]
                    path=source/name; raw=path.read_bytes(); path.unlink();path.write_bytes(raw+b' ')
                output=source.with_name(source.name+'-refused')
                with self.assertRaises((ValueError, FileNotFoundError)):
                    figure.reproject_capture(source, output, **options)
                self.assertFalse(output.exists())

    def test_invalid_regenerated_projection_never_publishes_complete(self):
        owner, source, _ = self.historical_parent()
        before = {p.name:p.read_bytes() for p in source.iterdir()}
        output=source.with_name(source.name+'-invalid')
        writer=figure.write_projection_stream
        def corrupt(path, document, **kwargs):
            values=dict(document)
            values['records']=(dict(row,state='unsupported') if row['mime']=='image/webp' else row for row in document['records'])
            return writer(path, values, **kwargs)
        with patch.object(figure,'write_projection_stream',side_effect=corrupt), self.assertRaises(ValueError):
            figure.reproject_capture(source, output, repair_manifest_sha256=figure.digest(before[figure.MANIFEST]))
        self.assertTrue(output.exists())
        self.assertFalse((output/figure.COMPLETE).exists())
        self.assertEqual(before, {p.name:p.read_bytes() for p in source.iterdir()})


class ReprojectionRecordReuseTests(unittest.TestCase):
    def source(self):
        self.owner = ExplicitProfileReprojectionTests()
        self.owner.setUp()
        self.addCleanup(self.owner.doCleanups)
        root, _ = self.owner.parent()
        namespace = (root / (figure.site_info.PREFIX + 'namespace-registry.tsv')).read_bytes()
        site = (root / figure.ROLES['figure-sizing-site']).read_bytes()
        args = (root / figure.ROLES['figure-sizing-raw'], namespace,
                self.owner.fixture.wiki, self.owner.fixture.date, site)
        options = dict(profile_kind=figure.FIGURE_PROFILE_V4, allow_tiff_companion=True,
            allow_encoded=True, allow_compatible_epochs=True, allow_decimal_tiff_axes=True,
            allow_default_tiff_page=False)
        return root, args, options

    def test_exact_written_records_compare_independently_and_transfer_once(self):
        root, args, options = self.source()
        real = figure.figure_stream_document
        with patch.object(figure, 'figure_stream_document', wraps=real) as derive:
            owned = figure._ReprojectionRecords(*args, figure.REPLAY_CONTRACT_V4, **options)
            self.assertEqual(derive.call_count, 1)
            projection = root / 'comparison.json'
            owned.write(projection)
            reused = figure.verify_stream_document(projection, *args, _reprojection_records=owned)
            self.assertEqual(derive.call_count, 1)
            self.assertIsNone(owned._document)
            ordinary = figure.verify_stream_document(projection, *args)
            self.assertEqual(derive.call_count, 2)
            self.assertEqual(reused, ordinary)
            with self.assertRaisesRegex(ValueError, 'already consumed'):
                figure.verify_stream_document(projection, *args, _reprojection_records=owned)
            with self.assertRaisesRegex(ValueError, 'Invalid private'):
                figure.verify_stream_document(projection, *args, _reprojection_records=ordinary)

    def test_context_options_and_source_identity_cannot_borrow_records(self):
        root, args, options = self.source()
        for mode in ('path', 'namespace', 'wiki', 'date', 'site', 'contract', 'profile', 'encoded', 'decimal'):
            with self.subTest(mode=mode):
                owned = figure._ReprojectionRecords(*args, figure.REPLAY_CONTRACT_V4, **options)
                selected = list(args); selected_options = dict(options); contract = figure.REPLAY_CONTRACT_V4
                if mode == 'path': selected[0] = root / 'foreign.raw.json'
                elif mode == 'namespace': selected[1] += b'\n'
                elif mode == 'wiki': selected[2] = 'enwiktionary'
                elif mode == 'date': selected[3] = '19990101'
                elif mode == 'site': selected[4] += b' '
                elif mode == 'contract': contract = figure.REPLAY_CONTRACT
                elif mode == 'profile': selected_options['profile_kind'] = figure.FIGURE_PROFILE_V5
                elif mode == 'encoded': selected_options['allow_encoded'] = False
                else: selected_options['allow_decimal_tiff_axes'] = False
                with self.assertRaisesRegex(ValueError, 'context differs'):
                    owned.take(*selected, contract, **selected_options)
        for mode in ('same-byte-replacement', 'raw-content', 'hardlink'):
            with self.subTest(mode=mode):
                # Fresh genuine fixtures avoid restoring a mutated authority.
                fresh, selected, current_options = self.source()
                owned = figure._ReprojectionRecords(*selected, figure.REPLAY_CONTRACT_V4, **current_options)
                raw = selected[0]
                if mode == 'same-byte-replacement':
                    value = raw.read_bytes(); raw.unlink(); raw.write_bytes(value)
                elif mode == 'raw-content':
                    with raw.open('ab') as stream: stream.write(b' ')
                else: figure.os.link(raw, fresh / 'extra-link.raw')
                with self.assertRaisesRegex(ValueError, 'source changed'):
                    owned.take(*selected, figure.REPLAY_CONTRACT_V4, **current_options)

    def test_corrupt_writer_header_record_and_partial_write_never_complete(self):
        for mode in ('header', 'record', 'partial'):
            with self.subTest(mode=mode):
                root, _, _ = self.source()
                before = {p.name: p.read_bytes() for p in root.iterdir()}
                output = root.with_name(root.name + '-corrupt-' + mode)
                real = figure.write_projection_stream
                def corrupt(path, document, **kwargs):
                    if mode == 'header': document['source_profile']['webp_handler_sha256'] = '0' * 64
                    elif mode == 'record':
                        rows = iter(document['records']); first = next(rows)
                        first['original_width'] += 1
                        document['records'] = figure.itertools.chain((first,), rows)
                    else:
                        Path(path).write_bytes(b'partial projection\n')
                        raise OSError('controlled partial writer failure')
                    return real(path, document, **kwargs)
                with patch.object(figure, 'write_projection_stream', side_effect=corrupt):
                    with self.assertRaises((ValueError, OSError)):
                        figure.reproject_capture(root, output, target_profile=figure.FIGURE_PROFILE_V5)
                self.assertTrue(output.exists())
                self.assertFalse((output / figure.COMPLETE).exists())
                self.assertEqual(before, {p.name: p.read_bytes() for p in root.iterdir()})

    def test_raw_change_during_independent_projection_read_is_refused(self):
        root, args, options = self.source()
        owned = figure._ReprojectionRecords(*args, figure.REPLAY_CONTRACT_V4, **options)
        projection = root / 'read-race.json'
        owned.write(projection)
        real = figure.stream_values
        changed = []
        def change_source_after_record(path, schema, **kwargs):
            for value in real(path, schema, **kwargs):
                yield value
                if Path(path) == projection and 'requested_file' in value and not changed:
                    with args[0].open('ab') as stream: stream.write(b' ')
                    changed.append(True)
        with patch.object(figure, 'stream_values', side_effect=change_source_after_record):
            with self.assertRaisesRegex(ValueError, 'source changed'):
                figure.verify_stream_document(projection, *args, _reprojection_records=owned)
        self.assertTrue(changed)
        self.assertIsNone(owned._document)

    def test_output_derives_once_and_releases_records_before_source_replay(self):
        import weakref
        root, _, _ = self.source()
        output = root.with_name(root.name + '-record-reuse')
        selected_raw = output / figure.ROLES['figure-sizing-raw']
        init, derive, replay_source = figure._ReprojectionRecords.__init__, figure.figure_stream_document, figure.replay_source
        holders, weak_records, derivations, source_calls = [], [], [], []
        class Records(list): pass
        def observed_init(owned, *args, **kwargs):
            init(owned, *args, **kwargs)
            records = Records(owned._document['records'])
            owned._document['records'] = records
            holders.append(owned); weak_records.append(weakref.ref(records))
        def observed_derive(path, *args, **kwargs):
            derivations.append(Path(path))
            return derive(path, *args, **kwargs)
        def observed_source(*args, **kwargs):
            if Path(args[0]) == output:
                source_calls.append(True)
                self.assertEqual(len(holders), 1)
                self.assertTrue(all(item._document is None for item in holders))
                self.assertTrue(all(item() is None for item in weak_records))
            return replay_source(*args, **kwargs)
        with patch.object(figure._ReprojectionRecords, '__init__', observed_init), \
                patch.object(figure, 'figure_stream_document', side_effect=observed_derive), \
                patch.object(figure, 'replay_source', side_effect=observed_source):
            manifest = figure.reproject_capture(root, output, target_profile=figure.FIGURE_PROFILE_V5)
        self.assertEqual(derivations.count(selected_raw), 1)
        self.assertTrue(source_calls)
        self.assertEqual(figure.verify(output), manifest)


class CompleteRawIndexReuseTests(unittest.TestCase):
    fresh = CompleteSelectionDocumentTests.fresh

    def test_verified_offsets_preserve_plain_and_encoded_batches_without_index_only_decode(self):
        for encoded in (False, True):
            fixture, args, _, _ = self.fresh()
            root = args.output
            raw_path = root / figure.ROLES['figure-sizing-raw']
            if not encoded:
                values = list(figure.stream_values(raw_path, figure.RAW_STREAM_SCHEMA))
                header = dict(values[0])
                header.pop('record_encoding')
                raw_path.write_bytes(b''.join(figure.stream_encoded(row) for row in (header, *values[1:])))
                document = fixture.stream_document(root)
                document.update(raw_bytes=raw_path.stat().st_size, raw_sha256=figure.digest(raw_path.read_bytes()))
                projection = root / figure.ROLES['figure-sizing']
                projection.unlink()
                figure.write_projection_stream(projection, document)
                manifest = json.loads((root / figure.MANIFEST).read_bytes())
                manifest['artifacts'] = figure.payload(root)
                for role in ('figure-sizing-raw', 'figure-sizing'):
                    manifest['outputs'][role] = manifest['artifacts'][figure.ROLES[role]]['sha256']
                manifest_raw = figure.encoded(manifest)
                (root / figure.MANIFEST).write_bytes(manifest_raw)
                (root / figure.COMPLETE).write_bytes(figure.encoded({
                    'schema': figure.SCHEMA, 'manifest_sha256': figure.digest(manifest_raw)}))
            before = {p.name:p.read_bytes() for p in root.iterdir()}
            expected = list(figure.stream_values(raw_path, figure.RAW_STREAM_SCHEMA))[1:]
            document = fixture.stream_document(root)
            cache = {}
            with self.subTest(encoded=encoded), \
                    patch.object(figure, 'raw_record_decode', wraps=figure.raw_record_decode) as decode:
                result = figure.read_complete_capture(root / figure.MANIFEST, cache)
            # The semantic derivation and source-echo traversal both remain;
            # there is no third decoding pass solely to make this index.
            self.assertEqual(decode.call_count, 2 * len(expected))
            self.assertEqual(result['document'], document)
            self.assertEqual(len(result['offsets']), len(expected))
            physical = before[figure.ROLES['figure-sizing-raw']]
            for number, ((offset, size, sha), batch) in enumerate(zip(result['offsets'], expected, strict=True)):
                self.assertEqual(figure.digest(physical[offset:offset+size]), sha)
                reference = dict(kind='complete-stream', path=str(root / figure.MANIFEST),
                                 sha256=result['manifest_sha256'], batch=number)
                self.assertEqual(figure.complete_stream_batch(reference, cache), batch)
            figure.check_prefix_cache(cache)
            self.assertEqual(before, {p.name:p.read_bytes() for p in root.iterdir()})

    def test_failed_or_truncated_raw_verification_publishes_no_index_or_cache_entry(self):
        for kind in ('malformed', 'truncated', 'trailing', 'foreign-wiki', 'late-authentication'):
            _, args, _, _ = self.fresh()
            root = args.output
            raw_path = root / figure.ROLES['figure-sizing-raw']
            lines = raw_path.read_bytes().splitlines(keepends=True)
            if kind == 'malformed':
                lines[1] = b'{"encoding":}\n'
            elif kind == 'truncated':
                lines = lines[:-1]
            elif kind == 'trailing':
                lines.append(b'{}\n')
            elif kind == 'foreign-wiki':
                header = json.loads(lines[0])
                header['wiki'] = 'enwiktionary'
                self.assertNotEqual(header['wiki'], args.wiki)
                lines[0] = figure.stream_encoded(header)
            else:
                manifest = json.loads((root / figure.MANIFEST).read_bytes())
                manifest['artifacts'][figure.ROLES['figure-sizing-raw']]['sha256'] = '0' * 64
                raw = figure.encoded(manifest)
                (root / figure.MANIFEST).write_bytes(raw)
                (root / figure.COMPLETE).write_bytes(figure.encoded({
                    'schema': figure.SCHEMA, 'manifest_sha256': figure.digest(raw)}))
            if kind != 'late-authentication':
                raw_path.write_bytes(b''.join(lines))
            output, cache = {}, {}
            with self.subTest(kind=kind), self.assertRaises(ValueError):
                figure.verify(root, _raw_index_out=output)
            self.assertEqual(output, {})
            with self.assertRaises(ValueError):
                figure.read_complete_capture(root / figure.MANIFEST, cache, include_document=False)
            self.assertNotIn(('complete-stream', str(root / figure.MANIFEST)), cache)

    def test_input_changes_during_indexing_and_after_verification_remain_refused(self):
        for kind in ('raw-during', 'receipt-during', 'raw-after'):
            fixture, args, _, _ = self.fresh()
            root = args.output
            raw_path = root / figure.ROLES['figure-sizing-raw']
            stream, verify = figure.stream_values, figure.verify
            mutations = []
            def mutate():
                if kind == 'receipt-during':
                    receipt = next(root.glob('file-metadata.response-*.receipt.json'))
                    receipt.write_bytes(receipt.read_bytes() + b'changed')
                else:
                    replacement = fixture.root / 'same-bytes-different-inode'
                    replacement.write_bytes(raw_path.read_bytes())
                    replacement.replace(raw_path)
                mutations.append(kind)
            def indexed(path, schema, **options):
                yield from stream(path, schema, **options)
                if Path(path) == raw_path and options.get('record_offsets') is not None:
                    if kind != 'raw-after':
                        mutate()
            def completed(*args, **options):
                result = verify(*args, **options)
                if kind == 'raw-after':
                    mutate()
                return result
            cache = {}
            with self.subTest(kind=kind), patch.object(figure, 'stream_values', new=indexed), \
                    patch.object(figure, 'verify', new=completed), self.assertRaises(ValueError):
                figure.read_complete_capture(root / figure.MANIFEST, cache, include_document=False)
            self.assertEqual(mutations, [kind])
            self.assertNotIn(('complete-stream', str(root / figure.MANIFEST)), cache)




class VerifiedContainedHttpReuseTests(unittest.TestCase):
    @contextlib.contextmanager
    def fixture(self, replay=False):
        donor=CaptureReplayContractTests() if replay else OfflineFigureMaterializationTests()
        donor.setUp()
        try:yield donor
        finally:donor.doCleanups()

    @staticmethod
    def members(root):
        return {path.relative_to(root).as_posix():path.read_bytes()
                for path in root.rglob('*') if path.is_file()}

    def test_contained_http_reuse_matches_replay_for_direct_and_imported_copy_and_links(self):
        import sys
        for imported in (False,True):
            for linked in (False,True):
                with self.subTest(imported=imported,linked=linked),self.fixture() as donor:
                    args=donor.complete();source=args.output
                    if imported:
                        contained=donor.root/'contained-input'
                        figure.materialize_complete_capture(source/figure.MANIFEST,contained)
                        source=contained
                    before=self.members(source)
                    counts={'baseline_resolve':0,'candidate_resolve':0,'reuse':0,'indexed_frame':0}
                    replay_source=figure.replay_source;reuse=figure._verified_contained_http_leaf
                    indexed=figure.complete_stream_batch;arm=['baseline']
                    def replay(*args,**kwargs):
                        if sys._getframe(1).f_code.co_name=='resolve':counts[arm[0]+'_resolve']+=1
                        return replay_source(*args,**kwargs)
                    def checked_reuse(*args,**kwargs):
                        value=reuse(*args,**kwargs)
                        if value:counts['reuse']+=1
                        return value
                    def checked_frame(*args,**kwargs):
                        if sys._getframe(1).f_code is reuse.__code__:counts['indexed_frame']+=1
                        return indexed(*args,**kwargs)
                    outputs=[];manifests=[]
                    with patch.object(figure,'replay_source',new=replay),patch.object(figure,'complete_stream_batch',new=checked_frame):
                        for label in ('baseline','candidate'):
                            arm[0]=label;output=donor.root/label;observations={}
                            with patch.object(figure,'_verified_contained_http_leaf',
                                    new=(lambda *args,**kwargs:False) if label=='baseline' else checked_reuse):
                                manifests.append(figure.materialize_complete_capture(source/figure.MANIFEST,output,
                                    link_current_payloads=linked,observations=observations))
                            outputs.append(output)
                            if linked:
                                self.assertEqual({row['path'] for row in observations['linked_members']},
                                    {*figure.ROLES.values(),figure.PROVIDER,figure.INVENTORY}&
                                    {figure.ROLES['figure-sizing'],figure.ROLES['figure-sizing-raw'],figure.PROVIDER,figure.INVENTORY})
                                self.assertTrue(observations['complete'])
                    self.assertGreater(counts['baseline_resolve'],0)
                    self.assertEqual(counts['candidate_resolve'],0)
                    self.assertGreater(counts['reuse'],0)
                    self.assertEqual(counts['indexed_frame'],counts['reuse'])
                    self.assertEqual(manifests[0],manifests[1])
                    self.assertEqual(self.members(outputs[0]),self.members(outputs[1]))
                    self.assertEqual(self.members(source),before)
                    for output,manifest in zip(outputs,manifests):self.assertEqual(donor.verify_both(output),manifest)
                    print('CONTAINED_HTTP_REUSE '+json.dumps(dict(imported=imported,linked=linked,
                        counts=counts,parity=True,production_timing_claimed=False),sort_keys=True))

    def test_mutations_after_first_complete_proof_refuse_before_output(self):
        for change in ('member','journal','source-object','frame','foreign-container','after-reuse'):
            with self.subTest(change=change),self.fixture() as donor:
                args=donor.complete();source=args.output
                if change=='foreign-container':
                    contained=donor.root/'contained-input'
                    figure.materialize_complete_capture(source/figure.MANIFEST,contained);source=contained
                output=donor.root/'refused';original=figure._verified_contained_http_leaf;changed=[]
                def mutate(node,slot,batch,cache,namespace,stamps):
                    if changed:return original(node,slot,batch,cache,namespace,stamps)
                    if change=='foreign-container' and 'imported_row'not in node:
                        return original(node,slot,batch,cache,namespace,stamps)
                    changed.append(True);value=node['sources'][slot]
                    if change=='member':
                        member=node['root']/value['artifacts'][0];member.write_bytes(member.read_bytes()+b' ')
                    elif change=='journal':
                        member=node['root']/figure.FILE_REQUESTS;member.write_bytes(member.read_bytes()+b' ')
                    elif change=='source-object':value['batch']['request']='foreign-request.json'
                    elif change=='frame':
                        batch=copy.deepcopy(batch);batch['requests']=['File:Foreign.svg']
                    elif change=='foreign-container':node['container']=donor.root/'foreign-container'
                    verdict=original(node,slot,batch,cache,namespace,stamps)
                    if change=='after-reuse':
                        self.assertTrue(verdict)
                        member=node['root']/value['artifacts'][0];member.write_bytes(member.read_bytes()+b' ')
                    return verdict
                with patch.object(figure,'_verified_contained_http_leaf',new=mutate):
                    with self.assertRaises(ValueError):figure.materialize_complete_capture(source/figure.MANIFEST,output)
                self.assertEqual(changed,[True]);self.assertFalse(output.exists())

    def test_external_and_pending_sources_keep_original_validation(self):
        import sys
        with self.fixture(replay=True) as donor:
            current,parent,_,record,before=donor.consolidated_observation()
            output=donor.fixture.root/'external-kept';calls=[];reuse=figure._verified_contained_http_leaf
            replay_source=figure.replay_source
            def checked_reuse(node,slot,batch,*args,**kwargs):
                verdict=reuse(node,slot,batch,*args,**kwargs)
                if node['sources'][slot]['kind']=='retained-request':self.assertFalse(verdict)
                return verdict
            def checked_replay(root,source,*args,**kwargs):
                if sys._getframe(1).f_code.co_name=='resolve':calls.append(source['kind'])
                return replay_source(root,source,*args,**kwargs)
            with patch.object(figure,'_verified_contained_http_leaf',new=checked_reuse),patch.object(figure,'replay_source',new=checked_replay):
                figure.materialize_complete_capture(current/figure.MANIFEST,output)
            self.assertIn('retained-request',calls)
            donor.verify_consolidated(output)
            self.assertEqual(donor.members(current),before)
        with self.fixture() as donor:
            args,proof=donor.epoch_complete();reads=[];read=figure.read_closed_prefix
            def checked_prefix(path,*args,**kwargs):
                reads.append(Path(path));return read(path,*args,**kwargs)
            output=donor.root/'pending-kept'
            with patch.object(figure,'read_closed_prefix',new=checked_prefix):
                manifest=figure.materialize_complete_capture(args.output/figure.MANIFEST,output)
            self.assertIn(proof,reads);self.assertEqual(donor.verify_both(output),manifest)
        for kind in ('retained-request','closed-prefix','unknown'):
            node=dict(sources=[dict(kind=kind)],committed=1)
            self.assertFalse(figure._verified_contained_http_leaf(node,0,{}, {},b'',{}))
        node=dict(sources=[],pending=[dict(kind='http-archived')],committed=0)
        self.assertFalse(figure._verified_contained_http_leaf(node,0,{}, {},b'',{}))


class FigureCanonicalTitleReuseTests(unittest.TestCase):
    write_projection = FigureFileTests.write_projection
    response = FigureFileTests.response
    batch = FigureFileTests.batch

    def setUp(self):
        from test_prepare_file_metadata import registry_bytes
        FigureFileTests.setUp(self)
        self.namespace.write_bytes(registry_bytes(media_case='first-letter', file_case='first-letter'))

    def run_records(self, batches, site, function=None, *, record_limit=100000):
        return (figure.file_records if function is None else function)(
            batches, self.namespace.read_bytes(), self.wiki, self.date, site,
            has_batches=True, record_limit=record_limit, profile_kind=figure.FIGURE_PROFILE_V4,
            allow_compatible_epochs=True)

    def normalization_fixture(self):
        response=self.response()
        response['query']['general']['git-hash']=figure.FIGURE_CURRENT_CORE
        positive=copy.deepcopy(response['query']['pages'][0])
        positive['title']='Media:response_name.svg'
        positive['imageinfo'][0]['canonicaltitle']=': File:canon_name\u200e.svg'
        unsupported=copy.deepcopy(positive)
        unsupported['title']='fIlE:unsupported_body.bin'
        unsupported['imageinfo'][0].update(canonicaltitle='Media:unsupported_body.bin',
            mime='application/octet-stream',mediatype='UNKNOWN')
        requests=['\u0645\u0644\u0641:Positive.svg','\u0645\u0644\u0641:Alias.svg','\u0645\u0644\u0641:Unsupported.bin']
        mappings=[{'from':name,'to':positive['title']} for name in requests[:2]]
        mappings.append({'from':requests[2],'to':unsupported['title']})
        pages=[positive,unsupported]
        expected={requests[0]:('eligible','\u0645\u0644\u0641:Canon name.svg'),
                  requests[1]:('eligible','\u0645\u0644\u0641:Canon name.svg'),
                  requests[2]:('unsupported','\u0645\u0644\u0641:Unsupported body.bin')}
        for index,(raw,canonical) in enumerate((
                ('Media:negative_name.svg','Negative name.svg'),
                ('fIlE:lower_case.svg','Lower case.svg'),
                ('\u0645\u0644\u0641:\u200eghost_\u200fentry.svg','Ghost entry.svg'),
                (': File:  spaced_file.svg','Spaced file.svg'),
                ('Media:e\u0301cho.svg','\u00c9cho.svg'))):
            title=f'\u0645\u0644\u0641:Missing{index}.svg'
            requests.append(title);mappings.append({'from':title,'to':raw})
            pages.append(dict(title=raw,ns=6,missing=True,imagerepository=''))
            expected[title]=('missing','\u0645\u0644\u0641:'+canonical)
        response['query'].update(pages=pages,redirects=mappings)
        return [dict(requests=requests,response=figure.encoded(response).decode())],figure.encoded(response),expected

    def refusal_cases(self):
        batches,site,_=self.normalization_fixture()
        for mode,message in (
                ('positive-response-title','Unsupported or invalid File/Media title: Article'),
                ('missing-response-title','Unsupported or invalid File/Media title: Article'),
                ('unstable-positive-canonical','Unstable or unsafe canonical file title'),
                ('invalid-positive-canonical','Unsupported or invalid File/Media title: File:bad|name.svg'),
                ('oversized-positive-canonical','Invalid or oversized file title'),
                ('wrong-mediatype','Source handler and MediaWiki type conflict')):
            changed=copy.deepcopy(batches)
            response=json.loads(changed[0]['response'])
            if mode.endswith('response-title'):
                selected=0 if mode.startswith('positive') else 2
                old=response['query']['pages'][selected]['title']
                response['query']['pages'][selected]['title']='Article'
                for mapping in response['query']['redirects']:
                    if mapping['to']==old:mapping['to']='Article'
            elif mode=='unstable-positive-canonical':
                response['query']['pages'][0]['imageinfo'][0]['canonicaltitle']='File:e\u200e\u0301.svg'
            elif mode=='invalid-positive-canonical':
                response['query']['pages'][0]['imageinfo'][0]['canonicaltitle']='File:bad|name.svg'
            elif mode=='oversized-positive-canonical':
                response['query']['pages'][0]['imageinfo'][0]['canonicaltitle']='File:'+'x'*4096
            elif mode=='wrong-mediatype':
                response['query']['pages'][0]['imageinfo'][0]['mediatype']='BITMAP'
            changed[0]['response']=figure.encoded(response).decode()
            yield mode,changed,site,message

    def title_call_census(self, helper, batches, site):
        original=helper.evidence.Registry.file_title
        calls=[]
        def counted(registry,title):
            calls.append(title)
            return original(registry,title)
        with patch.object(helper.evidence.Registry,'file_title',new=counted):
            result=self.run_records(batches,site,helper.file_records)
        return result,calls

    def test_positive_canonical_title_reuses_validated_result_and_preserves_missing_normalization(self):
        batches,site,expected=self.normalization_fixture()
        before=copy.deepcopy(batches)
        result,calls=self.title_call_census(figure,batches,site)
        self.assertEqual({row['requested_file']:(row['state'],row['canonical_file']) for row in result['records']},expected)
        self.assertEqual(len(calls),3*6+5*3)
        self.assertNotIn('-',calls)
        self.assertEqual(result['base_batches'],1)
        self.assertEqual(result['observed_batches'],0)
        self.assertTrue(all(row['canonical_file']!='-' for row in result['records']))
        raw=figure.encoded({'schema':figure.RAW_BATCHES_SCHEMA,'batches':batches})
        document=figure.figure_file_document(raw,self.namespace.read_bytes(),self.wiki,self.date,site,
            profile_kind=figure.FIGURE_PROFILE_V4)
        self.assertEqual(document['records'],result['records'])
        self.assertEqual(figure.verify_figure_file_document(document,raw,self.namespace.read_bytes(),self.wiki,self.date,site),document)
        provider=b''.join(figure.provider_chunks(result)).decode()
        for title,(state,canonical) in expected.items():
            fields=next(line.split('\t') for line in provider.splitlines() if line.startswith(title+'\t'))
            self.assertEqual(fields[-1],'-' if state=='missing' else canonical)
        self.assertEqual(batches,before)

    def test_positive_canonical_reuse_keeps_response_title_stability_and_source_refusals(self):
        for mode,batches,site,message in self.refusal_cases():
            before=copy.deepcopy(batches)
            with self.subTest(mode=mode),self.assertRaises(ValueError) as refused:
                self.run_records(batches,site)
            self.assertEqual(str(refused.exception),message)
            self.assertEqual(batches,before)
        batches,site,_=self.normalization_fixture()
        for field,value in (('wiki','enwiktionary'),('date','20261002'),
                ('namespace',self.namespace.read_bytes()+b'bad\n'),('site',b'{}'),
                ('record_limit',1),('profile_kind','unproved')):
            args=[batches,self.namespace.read_bytes(),self.wiki,self.date,site]
            options=dict(has_batches=True,record_limit=100000,profile_kind=figure.FIGURE_PROFILE_V4,allow_compatible_epochs=True)
            if field in ('wiki','date','namespace','site'):
                args[{'namespace':1,'wiki':2,'date':3,'site':4}[field]]=value
            else:options[field]=value
            with self.subTest(field=field),self.assertRaises((ValueError,KeyError)):
                figure.file_records(*args,**options)

    def test_positive_canonical_reuse_keeps_final_alias_join_and_failure_propagation(self):
        a,b,c=('\u0645\u0644\u0641:'+name+'.svg' for name in ('A','B','C'))
        first,second=self.response(b),self.response(a)
        for response in (first,second):response['query']['general']['git-hash']=figure.FIGURE_CURRENT_CORE
        first['query']['redirects']=[{'from':a,'to':b}]
        second['query']['redirects']=[{'from':c,'to':a}]
        selected=[self.batch(a,first),self.batch(c,second)]
        for rows in (selected,list(reversed(selected))):
            with self.assertRaisesRegex(ValueError,'^Requested file conflicts with an authenticated canonical alias$'):
                self.run_records(rows,figure.encoded(first))
        batches,site,_=self.normalization_fixture()
        before=copy.deepcopy(batches)
        failure=MemoryError('classifier allocation refused')
        with patch.object(figure.metadata,'classify_response',side_effect=failure):
            with self.assertRaises(MemoryError) as refused:self.run_records(batches,site)
        self.assertIs(refused.exception,failure)
        def interrupted():
            yield from batches
            raise ValueError('late source iteration failed')
        with self.assertRaisesRegex(ValueError,'^late source iteration failed$'):self.run_records(interrupted(),site)
        self.assertEqual(batches,before)
        self.assertEqual(len(self.run_records(batches,site)['records']),8)

    def select_ascii_namespace_fixture(self):
        # A synthetic ASCII File namespace keeps the measured task from relying
        # on the Arabic namespace's mandatory native NFC work. This is no capture.
        self.wiki='frwiktionary'
        raw=self.namespace.read_bytes().replace(b'# wiki\tarwiktionary',b'# wiki\tfrwiktionary')
        raw=raw.replace(b'# content-language\tar',b'# content-language\tfr')
        raw=raw.replace('\u0645\u0644\u0641'.encode(),b'Fichier')
        self.namespace.write_bytes(raw)
        for response in (self.api,self.site_api):
            response['query']['general'].update(wikiid=self.wiki,lang='fr',server='https://fr.wiktionary.org',rtl=False,
                **{'git-hash':figure.FIGURE_CURRENT_CORE})

    def many_record_fixture(self, *, count=8192, missing=0, mapped=0):
        response=self.response('Fichier:Seed.svg')
        pages=[];requests=[];mappings=[]
        for index in range(count):
            requested=f'Fichier:Entry{index:05d}.svg'
            response_title=requested
            canonical=requested
            if index<mapped:
                requested=f'Fichier:Alias{index:05d}.svg'
                response_title=f'Media:source_e\u0301_{index:05d}.svg'
                canonical=f': File:e\u0301preuve_{index:05d}.svg'
                mappings.append({'from':requested,'to':response_title})
            if index>=count-missing:
                page=dict(title=response_title,ns=6,missing=True,imagerepository='')
            else:
                page=copy.deepcopy(response['query']['pages'][0]);page['title']=response_title
                page['imageinfo'][0].update(canonicaltitle=canonical,sha1=f'{index+1:040x}')
            requests.append(requested);pages.append(page)
        batches=[]
        for offset in range(0,count,50):
            selected=copy.deepcopy(response)
            selected['query']['pages']=pages[offset:offset+50]
            requested=requests[offset:offset+50]
            redirects=[row for row in mappings if row['from'] in requested]
            if redirects:selected['query']['redirects']=redirects
            batches.append(dict(requests=requested,response=figure.encoded(selected).decode()))
        return batches,figure.encoded(response)

    def stream_fixture(self, helper, batches, site, label):
        namespace=self.namespace.read_bytes()
        document=self.run_records(batches,site,helper.file_records)
        header={'schema':helper.RAW_STREAM_SCHEMA,**{key:document[key] for key in
            ('wiki','core_revision','namespace_registry_sha256')},'records_count':len(document['records']),
            'base_batches':document['base_batches'],'observed_batches':document['observed_batches'],
            'record_encoding':helper.RAW_RECORD_ENCODING}
        raw,projection=self.root/(label+'.raw'),self.root/(label+'.projection')
        with raw.open('wb') as output:
            output.write(helper.stream_encoded(header))
            for batch in batches:output.write(helper.raw_record_encoded(batch))
        expected=helper.figure_stream_document(raw,namespace,self.wiki,self.date,site,profile_kind=helper.FIGURE_PROFILE_V4)
        helper.write_projection_stream(projection,expected)
        self.assertEqual(helper.verify_stream_document(projection,raw,namespace,self.wiki,self.date,site),expected)
        return raw,projection,expected

    def test_positive_canonical_reuse_keeps_full_stream_projection_comparison(self):
        self.select_ascii_namespace_fixture()
        batches,site=self.many_record_fixture(count=64,missing=5,mapped=8)
        raw,projection,expected=self.stream_fixture(figure,batches,site,'canonical-stream')
        before=(raw.read_bytes(),projection.read_bytes())
        self.assertEqual(sum(row['state']=='missing' for row in expected['records']),5)
        self.assertEqual(sum(row['requested_file']!=row['canonical_file'] for row in expected['records']),8)
        self.assertEqual(figure.verify_stream_document(projection,raw,self.namespace.read_bytes(),self.wiki,self.date,site),expected)
        self.assertEqual((raw.read_bytes(),projection.read_bytes()),before)
        changed=copy.deepcopy(expected);changed['records'][0]['canonical_file']='Fichier:Forged.svg'
        projection.unlink();figure.write_projection_stream(projection,changed)
        with self.assertRaisesRegex(ValueError,'Figure projection stream record differs from exact raw replay'):
            figure.verify_stream_document(projection,raw,self.namespace.read_bytes(),self.wiki,self.date,site)


def measure_canonical_title_reuse(baseline,candidate):
    """Explicit paired full-verifier task; never substitutes candidate for baseline."""
    if baseline is candidate or baseline.file_records.__code__ is candidate.file_records.__code__:
        raise AssertionError('paired measurement requires distinct authenticated source endpoints')
    case=FigureCanonicalTitleReuseTests('test_positive_canonical_reuse_keeps_full_stream_projection_comparison')
    rows,errors,census=[],[],{}
    try:
        case.setUp()
        batches,site,_=case.normalization_fixture()
        expected=None
        for arm,helper,wanted in (('baseline',baseline,3*7+5*3),('candidate',candidate,3*6+5*3)):
            result,calls=case.title_call_census(helper,batches,site)
            case.assertEqual(len(calls),wanted)
            if expected is None:expected=result
            else:case.assertEqual(result,expected)
            census[arm]=dict(positive_rows=3,missing_rows=5,title_calls=len(calls))
        del result,expected
        for mode,batches,site,message in case.refusal_cases():
            before=copy.deepcopy(batches);outcomes=[]
            for helper in (baseline,candidate):
                with case.assertRaises(ValueError) as refused:case.run_records(batches,site,helper.file_records)
                outcomes.append((type(refused.exception).__name__,str(refused.exception)))
                case.assertEqual(batches,before)
            case.assertEqual(outcomes,[('ValueError',message)]*2)
            errors.append(dict(case=mode,exception=outcomes[0]))
        case.select_ascii_namespace_fixture()
        namespace=case.namespace.read_bytes();fixtures=[]
        # Validate all synthetic fixtures under both real sources before clocks.
        for label,missing,mapped in (('ascii-positive',0,0),('current-positive-missing-ratio',59,0),('ratio-with-unicode-mapped-aliases',59,64)):
            batches,site=case.many_record_fixture(missing=missing,mapped=mapped)
            raw,projection,expected=case.stream_fixture(baseline,batches,site,label)
            case.assertEqual(candidate.verify_stream_document(projection,raw,namespace,case.wiki,case.date,site),expected)
            fixtures.append((label,batches,site,raw,projection,expected,missing,mapped))
        for label,batches,site,raw,projection,expected,missing,mapped in fixtures:
            before=copy.deepcopy(batches)
            raw_before,projection_before=raw.read_bytes(),projection.read_bytes()
            stamps=tuple(figure.evidence.stamp(path) for path in (raw,projection,case.namespace))
            output=figure.encoded(expected);provider=b''.join(figure.provider_chunks(expected))
            for arm,helper in (('baseline',baseline),('candidate',candidate),('candidate',candidate),('baseline',baseline)):
                wall,cpu=time.perf_counter_ns(),time.process_time_ns()
                result=helper.verify_stream_document(projection,raw,namespace,case.wiki,case.date,site)
                cpu,wall=time.process_time_ns()-cpu,time.perf_counter_ns()-wall
                case.assertEqual(result,expected)
                case.assertEqual(figure.encoded(result),output)
                case.assertEqual(b''.join(figure.provider_chunks(result)),provider)
                case.assertEqual(batches,before)
                case.assertEqual((raw.read_bytes(),projection.read_bytes(),case.namespace.read_bytes()),(raw_before,projection_before,namespace))
                case.assertEqual(tuple(figure.evidence.stamp(path) for path in (raw,projection,case.namespace)),stamps)
                rows.append(dict(case=label,arm=arm,cpu_ns=cpu,wall_ns=wall,records=len(result['records']),
                    missing=missing,positive=len(result['records'])-missing,mapped_unicode_titles=mapped,
                    output_sha256=figure.digest(output),provider_sha256=figure.digest(provider)))
                del result
        return dict(rows=rows,errors=errors,untimed_title_call_census=census,output_and_input_parity=True,
            scope='Unprofiled verify_stream_document; raw decode, full file semantics and exact projection comparison. Fixture validation, comparisons and disposal excluded.',
            retained_fr_counts=dict(files=1316399,positive=1306861,missing=9538),
            fixture_scope='Synthetic ASCII canonical namespace; missing ratio rounded to59/8192; Unicode/alias rate is explicit stress coverage, not a measured FR distribution.',
            whole_fr_timing_claimed=False)
    finally:
        case.doCleanups()




class FigureOriginLifetimeTests(unittest.TestCase):
    setUp = OfflineFigureMaterializationTests.setUp
    epoch_complete = OfflineFigureMaterializationTests.epoch_complete
    materialize = OfflineFigureMaterializationTests.materialize

    @staticmethod
    def lifetime_trace(helper, output, *, allocations=False):
        import ast
        import inspect
        import sys
        import textwrap
        import tracemalloc
        outer = helper.validate_materialized_echo
        codes = {value.co_name:value for value in outer.__code__.co_consts
                 if isinstance(value, type(outer.__code__))}
        source, first = inspect.getsourcelines(outer)
        parsed = ast.parse(textwrap.dedent(''.join(source)))
        visit = next(node for node in parsed.body[0].body
                     if isinstance(node, ast.FunctionDef) and node.name == 'visit')
        check = next(node for node in visit.body if isinstance(node, ast.If) and
                     any(isinstance(part, ast.Name) and part.id == 'original_count'
                         for part in ast.walk(node.test)) and isinstance(node.test, ast.BoolOp))
        check_line = first + check.lineno - 1
        rows = []
        def observe(frame, event, arg):
            if frame.f_code is codes['visit'] and event == 'call':
                parent = frame.f_back
                if parent is not None and parent.f_code is codes['ordinary_origin']:
                    values = parent.f_locals
                    rows.append(dict(boundary='ancestor-entry',
                        retained_names_live='retained_names' in values,
                        remaining_live='remaining' in values,
                        planned_batches=len(values['planned']),
                        traced_current_bytes=tracemalloc.get_traced_memory()[0] if allocations else None))
            elif frame.f_code is codes['visit'] and event == 'line' and frame.f_lineno == check_line:
                values = frame.f_locals
                rows.append(dict(boundary='post-count',
                    original_document_live='original_document' in values,
                    original_count=values['original_count'],
                    traced_current_bytes=tracemalloc.get_traced_memory()[0] if allocations else None))
            return observe if frame.f_code in codes.values() else None
        previous = sys.gettrace()
        try:
            sys.settrace(observe)
            result = helper.verify(output)
        finally:
            sys.settrace(previous)
        return result, rows

    def test_full_epoch_caller_releases_dead_locals_before_ancestor_and_failure_checks(self):
        args, _ = self.epoch_complete()
        output, expected = self.materialize(args)
        result, rows = self.lifetime_trace(figure, output)
        self.assertEqual(result, expected)
        ancestors = [row for row in rows if row['boundary'] == 'ancestor-entry']
        counts = [row for row in rows if row['boundary'] == 'post-count']
        self.assertTrue(ancestors)
        self.assertTrue(counts)
        self.assertTrue(all(not row['retained_names_live'] and not row['remaining_live'] for row in ancestors))
        self.assertTrue(all(not row['original_document_live'] for row in counts))
        self.assertEqual(figure.verify(output), expected)

    def test_ancestral_semantic_memory_error_still_propagates_without_mutating_inputs(self):
        import sys
        args, _ = self.epoch_complete()
        output, expected = self.materialize(args)
        original = figure.file_records
        visit = next(value for value in figure.validate_materialized_echo.__code__.co_consts
                     if isinstance(value, type(original.__code__)) and value.co_name == 'visit')
        members = figure.capture_member_paths(output, include_markers=True)[0]
        before = {name:(figure.evidence.stamp(path),figure.digest(path.read_bytes()))
                  for name,path in members.items()}
        reached = []
        def refuse(*values, **options):
            if sys._getframe(1).f_code is visit:
                reached.append(options['record_limit'])
                raise MemoryError('owned ancestral allocation failure')
            return original(*values, **options)
        with patch.object(figure, 'file_records', new=refuse):
            with self.assertRaisesRegex(MemoryError, 'owned ancestral allocation failure'):
                figure.verify(output)
        self.assertTrue(reached)
        self.assertEqual({name:(figure.evidence.stamp(path),figure.digest(path.read_bytes()))
                          for name,path in members.items()}, before)
        self.assertEqual(figure.verify(output), expected)

    def bounded_nested_complete(self, records=2048):
        # The ordinary capture and retained-complete route own every plan,
        # journal, projection, marker and HTTP receipt in this temporary fixture.
        names = tuple('Lifetime%05d.svg' % number for number in range(records))
        args = self.fixture.args(links=names)
        args.output = self.root/'lifetime-parent'
        registry = figure.evidence.Registry(self.fixture.namespace.read_bytes(), self.fixture.wiki, self.fixture.date)
        titles = sorted((registry.file_title(registry.specs[6]['name'] + ':' + name) for name in names), key=lambda title:title.encode())
        planned_requests = sum(1 for _ in figure.metadata.title_batches(
            self.fixture.wiki, titles, args.batch_size, figure_axes=True))
        # This fixture advances a fake clock at each normal paced request.
        # Its deadline must cover the selected batch count, not the two-row default.
        args.wall_seconds = max(args.wall_seconds, (planned_requests + 1) * args.delay)
        clock = [0.0]
        def transport(url, timeout):
            titles = parse_qs(urlsplit(url).query)['titles'][0].split('|')
            response = self.fixture.response(titles[0])
            response['query']['pages'] = [self.fixture.response(title)['query']['pages'][0] for title in titles]
            return 200, {}, figure.encoded(response)
        with patch.object(figure.time, 'monotonic', side_effect=lambda:clock[0]):
            figure.capture_files(args, transport=transport,
                sleep=lambda delay:clock.__setitem__(0,clock[0]+delay))
        self.assertEqual(json.loads((args.output/figure.PLAN).read_text())['base_batches'], planned_requests)
        parent = args.output
        args.output = self.root/'lifetime-child'
        args.reuse = [parent]
        figure.capture_files(args, transport=lambda *_:self.fail('retained complete parent was fetched'))
        output, expected = self.materialize(args)
        plan = json.loads((output/figure.PLAN).read_text())
        self.assertEqual(len(plan['materialized_http_origins']), 2)
        self.assertEqual(expected['coverage']['files'], records)
        self.assertEqual(figure.verify(output), expected)
        return output, expected, tuple(Path(path) for path in args.sql)


def measure_figure_origin_lifetimes(baseline, candidate):
    """One bounded real verifier; CPU and traced allocation arms stay separate."""
    import tracemalloc
    if baseline is candidate or baseline.validate_materialized_echo.__code__ is candidate.validate_materialized_echo.__code__:
        raise AssertionError('paired measurement requires distinct authenticated sources')
    case = FigureOriginLifetimeTests('test_full_epoch_caller_releases_dead_locals_before_ancestor_and_failure_checks')
    rows, memory_rows, census = [], [], {}
    try:
        case.setUp()
        output, expected, sql = case.bounded_nested_complete()
        members = candidate.capture_member_paths(output, include_markers=True)[0]
        paths = tuple(members.values()) + sql + (case.fixture.namespace,)
        before = {str(path):(candidate.evidence.stamp(path),candidate.digest(path.read_bytes())) for path in paths}
        for arm,helper,released in (('baseline',baseline,False),('candidate',candidate,True)):
            result,events = case.lifetime_trace(helper,output)
            case.assertEqual(result,expected)
            ancestors = [row for row in events if row['boundary']=='ancestor-entry']
            counts = [row for row in events if row['boundary']=='post-count']
            case.assertTrue(ancestors);case.assertTrue(counts)
            case.assertTrue(all(row['retained_names_live'] is not released and row['remaining_live'] is not released for row in ancestors))
            if released:case.assertTrue(all(not row['original_document_live'] for row in counts))
            else:case.assertTrue(any(row['original_document_live'] for row in counts))
            census[arm]=events
            del result,events,ancestors,counts
        for arm,helper in (('baseline',baseline),('candidate',candidate),('candidate',candidate),('baseline',baseline)):
            wall,cpu=time.perf_counter_ns(),time.process_time_ns()
            result=helper.verify(output)
            cpu,wall=time.process_time_ns()-cpu,time.perf_counter_ns()-wall
            case.assertEqual(result,expected)
            rows.append(dict(arm=arm,cpu_ns=cpu,wall_ns=wall,records=2048,origins=2,
                             manifest_sha256=candidate.digest(candidate.encoded(result))))
            del result
        case.assertFalse(tracemalloc.is_tracing())
        for arm,helper in (('baseline',baseline),('candidate',candidate),('candidate',candidate),('baseline',baseline)):
            tracemalloc.start(1)
            try:
                result,events=case.lifetime_trace(helper,output,allocations=True)
                current,peak=tracemalloc.get_traced_memory()
            finally:
                tracemalloc.stop()
            case.assertEqual(result,expected)
            memory_rows.append(dict(arm=arm,traced_current_bytes=current,traced_peak_bytes=peak,
                                    boundaries=events,records=2048,origins=2))
            del result,events
        case.assertEqual({str(path):(candidate.evidence.stamp(path),candidate.digest(path.read_bytes())) for path in paths},before)
        return dict(rows=rows,allocation_rows=memory_rows,untimed_lifetime_census=census,
            output_and_input_parity=True,
            scope='Unprofiled full verify CPU ABBA and separate tracemalloc full verify ABBA; setup, validation, comparison and result disposal outside CPU clocks.',
            allocation_scope='Python traced allocations with test-local boundary observation, not RSS/PSS or a production swapping attribution.',
            fixture_scope='2048 positive ordinary records, 50-title batches, two exact complete origins through maintained capture/reuse/materialize; bounded ancestry topology, not full FR scale.',
            whole_fr_timing_claimed=False)
    finally:
        case.doCleanups()


class FigureInventorySourceHandoffTests(unittest.TestCase):
    setUp = OfflineFigureMaterializationTests.setUp
    complete = OfflineFigureMaterializationTests.complete

    def snapshot(self, root, sql=()):
        members = figure.capture_member_paths(root, include_markers=True)[0]
        paths = tuple(members.values()) + tuple(Path(path) for path in sql) + (self.fixture.namespace,)
        return {str(path):(figure.evidence.stamp(path),figure.digest(path.read_bytes())) for path in paths}

    def counted_verify(self, helper, root):
        original = helper.inventory_document
        reads = []
        def read(path):
            if Path(path) == root/helper.INVENTORY:
                reads.append(Path(path).stat().st_size)
            return original(path)
        with patch.object(helper, 'inventory_document', new=read):
            result = helper.verify(root)
        return result, reads

    def test_stream_source_handoff_uses_one_inventory_decode_and_keeps_owned_ordered_sources(self):
        args = self.complete()
        expected = figure.verify(args.output)
        before = self.snapshot(args.output, args.sql)
        replay = figure.replay_stream_capture
        outputs = []
        def observe(*values, **options):
            handoff = options.get('_inventory_sources_out')
            self.assertEqual(handoff, {})
            result = replay(*values, **options)
            self.assertEqual(set(handoff), {'path','stamp','sources'})
            self.assertIs(type(handoff['sources']), tuple)
            self.assertTrue(all(type(row) is tuple and len(row)==6 for row in handoff['sources']))
            self.assertTrue(all(type(value) in (str,int) for row in handoff['sources'] for value in row))
            outputs.append(handoff)
            return result
        with patch.object(figure, 'replay_stream_capture', new=observe):
            actual, reads = self.counted_verify(figure, args.output)
        self.assertEqual(actual, expected)
        self.assertEqual(reads, [(args.output/figure.INVENTORY).stat().st_size])
        keys = ('wiki','date','name','url','size','sha1')
        selected = [dict(zip(keys,row,strict=True)) for row in outputs[0]['sources']]
        for row in selected:row['url']='https://dumps.wikimedia.org'+row['url']
        self.assertEqual(selected, expected['source_dump_files'])
        selected[0]['sha1']='0'*40
        outputs[0].clear()
        repeated, reads = self.counted_verify(figure, args.output)
        self.assertEqual(repeated, expected)
        self.assertEqual(len(reads),1)
        self.assertEqual(len(figure.replay(args.output,self.fixture.wiki,self.fixture.date)),2)
        self.assertEqual(self.snapshot(args.output,args.sql),before)
        with patch.object(figure,'inventory_document',wraps=figure.inventory_document) as read:
            complete=figure.read_complete_capture(args.output/figure.MANIFEST,{},include_document=False)
        self.assertNotIn('document',complete)
        self.assertEqual(complete['manifest'],expected)
        self.assertEqual(sum(Path(call.args[0])==args.output/figure.INVENTORY for call in read.call_args_list),2)

    def test_stream_source_handoff_preserves_source_selection_order_and_failure_propagation(self):
        args = self.complete()
        path,marker=args.output/figure.MANIFEST,args.output/figure.COMPLETE
        original,complete=path.read_bytes(),marker.read_bytes()
        expected=json.loads(original)
        cases=[('order',list(reversed(expected['source_dump_files'])))]
        for key,value in (('wiki','enwiktionary'),('date','20261002'),('name','foreign.sql.gz'),
                          ('url','/unbound'),('size',0),('sha1','0'*40)):
            selected=copy.deepcopy(expected['source_dump_files']);selected[0][key]=value
            cases.append((key,selected))
        for name,selected in cases:
            with self.subTest(field=name):
                changed=copy.deepcopy(expected);changed['source_dump_files']=selected
                path.write_bytes(figure.encoded(changed))
                marker.write_bytes(figure.encoded(dict(schema=figure.SCHEMA,manifest_sha256=figure.digest(path.read_bytes()))))
                try:
                    with self.assertRaisesRegex(ValueError,'^Figure file source selection differs from the verified inventory$'):
                        figure.verify(args.output)
                finally:
                    path.write_bytes(original);marker.write_bytes(complete)
        handoff={}
        failure=MemoryError('inventory semantic allocation refused')
        with patch.object(figure,'verify_inventory',side_effect=failure):
            with self.assertRaises(MemoryError) as refused:
                figure.replay(args.output,self.fixture.wiki,self.fixture.date,_inventory_sources_out=handoff)
        self.assertIs(refused.exception,failure)
        self.assertEqual(handoff,{})
        for invalid in ([],{'sources':()}):
            with self.assertRaisesRegex(ValueError,'empty dictionary'):
                figure.replay(args.output,self.fixture.wiki,self.fixture.date,_inventory_sources_out=invalid)
        self.assertEqual(figure.verify(args.output),expected)

    def test_stream_source_handoff_refuses_inventory_mutation_before_and_after_publication(self):
        args=self.complete();path=args.output/figure.INVENTORY
        original=path.read_bytes();replacement=self.root/'inventory-replacement'
        verify_inventory=figure.verify_inventory;stream=figure.replay_stream_capture
        for boundary in ('semantic-validation','replay-return'):
            for mode in ('same-bytes','replacement','symlink'):
                reached=[];handoffs=[]
                def mutate():
                    reached.append(True)
                    if mode=='same-bytes':path.write_bytes(original)
                    elif mode=='replacement':
                        replacement.write_bytes(original);replacement.replace(path)
                    else:
                        path.rename(replacement);path.symlink_to(replacement)
                def verified(*values,**options):
                    result=verify_inventory(*values,**options)
                    if not reached:mutate()
                    return result
                def replayed(*values,**options):
                    handoffs.append(options['_inventory_sources_out'])
                    result=stream(*values,**options)
                    if boundary=='replay-return':mutate()
                    return result
                with self.subTest(boundary=boundary,mode=mode):
                    try:
                        with patch.object(figure,'replay_stream_capture',new=replayed), contextlib.ExitStack() as stack:
                            if boundary=='semantic-validation':stack.enter_context(patch.object(figure,'verify_inventory',new=verified))
                            with self.assertRaises(ValueError):figure.verify(args.output)
                        self.assertEqual(reached,[True])
                        self.assertEqual(len(handoffs),1)
                        if boundary=='semantic-validation':self.assertEqual(handoffs,[{}])
                        else:self.assertIn('sources',handoffs[0])
                    finally:
                        if path.is_symlink():path.unlink()
                        path.write_bytes(original)
                        if replacement.exists():replacement.unlink()
        # The existing raw-index output must also stay private when the new
        # inventory fence refuses an otherwise completed stream replay.
        handoff,raw_index={},{}
        def changed_inventory(*values,**options):
            result=verify_inventory(*values,**options)
            path.write_bytes(original)
            return result
        try:
            with patch.object(figure,'verify_inventory',new=changed_inventory):
                with self.assertRaisesRegex(ValueError,'^Figure inventory changed during source replay$'):
                    figure.replay(args.output,self.fixture.wiki,self.fixture.date,
                                  _raw_index_out=raw_index,_inventory_sources_out=handoff)
            self.assertEqual(raw_index,{})
            self.assertEqual(handoff,{})
        finally:path.write_bytes(original)
        self.assertEqual(figure.verify(args.output)['coverage']['files'],2)

    def test_stream_source_handoff_keeps_final_sql_payload_and_canonical_inventory_checks(self):
        args=self.complete();expected=figure.verify(args.output)
        stream=figure.replay_stream_capture
        for kind in ('sql','payload'):
            path=Path(args.sql[0]) if kind=='sql' else args.output/figure.PROVIDER
            original=path.read_bytes();reached=[]
            def late(*values,**options):
                result=stream(*values,**options)
                self.assertIn('sources',options['_inventory_sources_out'])
                reached.append(True);path.write_bytes(original+b'changed')
                return result
            with self.subTest(kind=kind):
                try:
                    with patch.object(figure,'replay_stream_capture',new=late):
                        with self.assertRaises(ValueError):figure.verify(args.output)
                    self.assertEqual(reached,[True])
                finally:path.write_bytes(original)
        inventory=args.output/figure.INVENTORY;raw=inventory.read_bytes()
        changed=json.loads(raw);changed['titles'].append('injected')
        inventory.write_bytes(figure.encoded(changed))
        try:
            with self.assertRaisesRegex(ValueError,'differs from exact dated SQL replay'):
                figure.verify(args.output)
        finally:inventory.write_bytes(raw)
        self.assertEqual(figure.verify(args.output),expected)

    def bounded_complete(self, records=2048):
        names=tuple('Inventory%05d.svg'%number for number in range(records))
        args=self.fixture.args(links=names)
        args.output=self.root/'inventory-sources-complete'
        registry=figure.evidence.Registry(self.fixture.namespace.read_bytes(),self.fixture.wiki,self.fixture.date)
        titles=sorted((registry.file_title(registry.specs[6]['name']+':'+name) for name in names),key=lambda title:title.encode())
        planned=sum(1 for _ in figure.metadata.title_batches(self.fixture.wiki,titles,args.batch_size,figure_axes=True))
        args.wall_seconds=max(args.wall_seconds,(planned+1)*args.delay)
        clock=[0.0]
        def transport(url,timeout):
            selected=parse_qs(urlsplit(url).query)['titles'][0].split('|')
            response=self.fixture.response(selected[0])
            response['query']['pages']=[self.fixture.response(title)['query']['pages'][0] for title in selected]
            return 200,{},figure.encoded(response)
        with patch.object(figure.time,'monotonic',side_effect=lambda:clock[0]):
            expected=figure.capture_files(args,transport=transport,sleep=lambda delay:clock.__setitem__(0,clock[0]+delay))
        self.assertEqual(json.loads((args.output/figure.PLAN).read_text())['base_batches'],planned)
        self.assertEqual(expected['coverage']['files'],records)
        self.assertEqual(figure.verify(args.output),expected)
        return args,expected


def measure_figure_inventory_source_handoff(baseline,candidate):
    """Full verification, with the removed decode counted outside measurement."""
    import tracemalloc
    if baseline is candidate or baseline.verify.__code__ is candidate.verify.__code__:
        raise AssertionError('paired measurement requires distinct authenticated sources')
    case=FigureInventorySourceHandoffTests('test_stream_source_handoff_uses_one_inventory_decode_and_keeps_owned_ordered_sources')
    rows,memory_rows,census=[],[],{}
    try:
        case.setUp()
        args,expected=case.bounded_complete()
        before=case.snapshot(args.output,args.sql)
        for arm,helper,count in (('baseline',baseline,2),('candidate',candidate,1)):
            result,reads=case.counted_verify(helper,args.output)
            case.assertEqual(result,expected)
            case.assertEqual(len(reads),count)
            census[arm]=dict(inventory_decodes=count,inventory_decode_bytes=sum(reads),inventory_file_bytes=reads[0])
            del result,reads
        for arm,helper in (('baseline',baseline),('candidate',candidate),('candidate',candidate),('baseline',baseline)):
            wall,cpu=time.perf_counter_ns(),time.process_time_ns()
            result=helper.verify(args.output)
            cpu,wall=time.process_time_ns()-cpu,time.perf_counter_ns()-wall
            case.assertEqual(result,expected)
            rows.append(dict(arm=arm,cpu_ns=cpu,wall_ns=wall,records=2048,
                             manifest_sha256=candidate.digest(candidate.encoded(result))))
            del result
        case.assertFalse(tracemalloc.is_tracing())
        for arm,helper in (('baseline',baseline),('candidate',candidate),('candidate',candidate),('baseline',baseline)):
            tracemalloc.start(1)
            try:
                result=helper.verify(args.output)
                current,peak=tracemalloc.get_traced_memory()
            finally:tracemalloc.stop()
            case.assertEqual(result,expected)
            memory_rows.append(dict(arm=arm,traced_current_bytes=current,traced_peak_bytes=peak,records=2048))
            del result
        case.assertEqual(case.snapshot(args.output,args.sql),before)
        return dict(rows=rows,allocation_rows=memory_rows,untimed_inventory_census=census,
            output_and_input_parity=True,
            scope='Unprofiled full verify CPU ABBA and separate tracemalloc full verify ABBA; setup, validation, comparisons and result disposal outside clocks.',
            fixture_scope='2048 ordinary positive records through maintained capture and full verify; exact inventory source-selection reload under test, not a full FR timing/peak model.',
            allocation_scope='Python traced allocations, not RSS/PSS or a paging attribution.',whole_fr_timing_claimed=False)
    finally:case.doCleanups()


class FigureMaterializationPhaseProgressTests(unittest.TestCase):
    setUp = OfflineFigureMaterializationTests.setUp
    complete = OfflineFigureMaterializationTests.complete
    phases = ('metadata_ancestry_load','source_verify','frame_resolution',
              'output_write','output_verify','publish_final_custody')

    class FlushedLog(io.StringIO):
        def __init__(self):
            super().__init__()
            self.flushed=[]
        def flush(self):
            self.flushed.append(self.getvalue())
            return super().flush()

    class BrokenLog:
        def write(self,value):raise OSError('diagnostic pipe closed')
        def flush(self):pass

    def events(self,log):
        return [json.loads(line) for line in log.getvalue().splitlines()]

    def assert_events(self,events,finished,active=None):
        expected=[]
        for name in finished:
            expected.extend((('phase-start',name),('phase-end',name)))
        if active is not None:expected.append(('phase-start',active))
        self.assertEqual([(row['event'],row['phase']) for row in events],expected)
        for row in events:
            self.assertEqual(row['operation'],'materialize-complete')
            keys={'operation','event','phase'}
            if row['event']=='phase-end':
                keys.update(('wall_seconds','process_cpu_seconds'))
                for key in ('wall_seconds','process_cpu_seconds'):
                    self.assertIs(type(row[key]),float)
                    self.assertGreaterEqual(row[key],0)
            self.assertEqual(set(row),keys)

    def source_snapshot(self,args):
        members=figure.capture_member_paths(args.output,include_markers=True)[0]
        paths=tuple(members.values())+tuple(Path(path) for path in args.sql)
        return {str(path):(figure.evidence.stamp(path),figure.digest(path.read_bytes())) for path in paths}

    def test_default_off_and_fixed_stage_progress_preserve_output_and_inputs(self):
        args=self.complete();before=self.source_snapshot(args)
        quiet=self.root/'quiet-materialized';output=self.root/'progress-materialized'
        silent=io.StringIO()
        with contextlib.redirect_stderr(silent), patch.object(figure.time,'process_time',side_effect=AssertionError('disabled progress read CPU clock')):
            expected=figure.materialize_complete_capture(args.output/figure.MANIFEST,quiet)
        self.assertEqual(silent.getvalue(),'')
        self.assertEqual(self.source_snapshot(args),before)
        log=self.FlushedLog();stdout=io.StringIO()
        with contextlib.redirect_stderr(log),contextlib.redirect_stdout(stdout):
            actual=figure.materialize_complete_capture(args.output/figure.MANIFEST,output,phase_progress=True)
        self.assertEqual(actual,expected)
        self.assertEqual(figure.verify(output),expected)
        self.assertEqual(figure.payload(output),figure.payload(quiet))
        self.assertEqual(self.source_snapshot(args),before)
        self.assertEqual(stdout.getvalue(),'')
        self.assert_events(self.events(log),self.phases)
        self.assertEqual(len(log.flushed),12)
        self.assertTrue(all(len(value.splitlines())==index+1 for index,value in enumerate(log.flushed)))
        for invalid in (1,None,'yes'):
            with self.assertRaisesRegex(ValueError,'^Invalid Figure phase progress selection$'):
                figure.materialize_complete_capture(args.output/figure.MANIFEST,self.root/'invalid-progress',phase_progress=invalid)
        self.assertFalse((self.root/'invalid-progress').exists())

    def test_source_failure_keeps_flushed_start_and_original_exception_without_output(self):
        args=self.complete();before=self.source_snapshot(args)
        original=figure.read_complete_capture
        failure=MemoryError('owned complete verification allocation refused')
        log=self.FlushedLog();observations={};output=self.root/'refused-before-output'
        def refuse(*values,**options):
            self.assert_events(self.events(log),self.phases[:1],self.phases[1])
            self.assertEqual(len(log.flushed),3)
            raise failure
        with contextlib.redirect_stderr(log),patch.object(figure,'read_complete_capture',new=refuse):
            with self.assertRaises(MemoryError) as caught:
                figure.materialize_complete_capture(args.output/figure.MANIFEST,output,
                    observations=observations,phase_progress=True)
        self.assertIs(caught.exception,failure)
        self.assertFalse(output.exists())
        self.assertFalse(observations['complete'])
        self.assertFalse(observations['source_complete_verified'])
        self.assert_events(self.events(log),self.phases[:1],self.phases[1])
        self.assertEqual(self.source_snapshot(args),before)
        # Logging cannot replace that same primary validator failure.
        with contextlib.redirect_stderr(self.BrokenLog()),patch.object(figure,'read_complete_capture',side_effect=failure):
            with self.assertRaises(MemoryError) as caught:
                figure.materialize_complete_capture(args.output/figure.MANIFEST,self.root/'broken-log-refusal',phase_progress=True)
        self.assertIs(caught.exception,failure)
        self.assertFalse((self.root/'broken-log-refusal').exists())
        self.assertEqual(self.source_snapshot(args),before)
        self.assertIs(figure.read_complete_capture,original)

    def test_output_failure_keeps_owned_cleanup_and_broken_diagnostics_do_not_change_success(self):
        args=self.complete();source=args.output/figure.MANIFEST
        names=(*figure.ROLES.values(),figure.PROVIDER,figure.INVENTORY)
        contents={name:(args.output/name).read_bytes() for name in names}
        identities={name:(args.output/name).stat() for name in names}
        original_verify=figure.verify
        outcomes=[]
        for enabled in (False,True):
            output=self.root/('failed-output-'+str(enabled));observations={};log=self.FlushedLog()
            failure=ValueError('owned fresh output verification refused')
            def verify(root,*values,**options):
                if Path(root)==output:raise failure
                return original_verify(root,*values,**options)
            with contextlib.redirect_stderr(log),patch.object(figure,'verify',new=verify):
                with self.assertRaises(ValueError) as caught:
                    figure.materialize_complete_capture(source,output,link_current_payloads=True,
                        cleanup_failed_links=True,observations=observations,phase_progress=enabled)
            self.assertIs(caught.exception,failure)
            self.assertFalse((output/figure.COMPLETE).exists())
            self.assertFalse(observations['complete'])
            self.assertTrue(observations['source_complete_verified'])
            self.assertTrue(observations['failed_link_recovery_verified'])
            self.assertFalse(observations['new_output_adoption_allowed'])
            self.assertEqual(len(observations['linked_members']),4)
            self.assertEqual(len(observations['removed_owned_links']),4)
            self.assertEqual(observations['remaining_owned_links'],[])
            self.assertEqual(observations['custody_errors'],[])
            outcomes.append({key:observations[key] for key in ('complete','source_complete_verified',
                'failed_link_recovery_verified','new_output_adoption_allowed','custody_errors')})
            if enabled:self.assert_events(self.events(log),self.phases[:4],self.phases[4])
            else:self.assertEqual(log.getvalue(),'')
            self.assertEqual({name:(args.output/name).read_bytes() for name in names},contents)
            for name,before in identities.items():
                after=(args.output/name).stat()
                self.assertEqual((after.st_dev,after.st_ino,after.st_mode,after.st_size,after.st_mtime_ns,after.st_nlink),
                                 (before.st_dev,before.st_ino,before.st_mode,before.st_size,before.st_mtime_ns,before.st_nlink))
        self.assertEqual(outcomes[0],outcomes[1])
        output=self.root/'closed-diagnostic-pipe'
        with contextlib.redirect_stderr(self.BrokenLog()):
            manifest=figure.materialize_complete_capture(source,output,phase_progress=True)
        self.assertEqual(figure.verify(output),manifest)

    def test_cli_progress_preserves_stdout_summary_and_final_custody_record(self):
        args=self.complete();output=self.root/'cli-progress';stdout=io.StringIO();log=self.FlushedLog()
        argv=['prepare_figure_metadata.py','materialize-complete','--source',str(args.output/figure.MANIFEST),
              '--output',str(output),'--link-current-payloads','--phase-progress']
        with patch.object(figure.sys,'argv',argv),contextlib.redirect_stdout(stdout),contextlib.redirect_stderr(log):
            figure.main()
        manifest=figure.verify(output)
        self.assertEqual(json.loads(stdout.getvalue()),{key:manifest[key] for key in ('schema','wiki','date','coverage')})
        records=self.events(log)
        self.assert_events(records[:-1],self.phases)
        custody=records[-1]
        self.assertEqual(custody['operation'],'materialize-complete')
        self.assertTrue(custody['complete'])
        self.assertTrue(custody['new_output_adoption_allowed'])
        self.assertFalse(custody['failed_link_recovery_verified'])
        self.assertNotIn('phase',custody)
        self.assertNotIn('event',custody)
        self.assertEqual(len(custody['linked_members']),4)
        self.assertEqual(len(log.flushed),13)


class FigureTupleFinalIdentityTests(unittest.TestCase):
    setUp = FigureOutputDigestTests.setUp

    def test_tuple_refuses_late_file_marker_membership_and_root_identity_changes(self):
        root = self.args.output
        target = self.paths['file-metadata']
        saved = {path.name: path.read_bytes() for path in root.iterdir()}
        original_verify = figure.verify
        root_mode = root.stat().st_mode & 0o777
        target_mode = target.stat().st_mode & 0o777
        mutations = ('content', 'restored-content', 'inode', 'missing', 'extra',
                     'symlink', 'directory', 'mode', 'hardlink', 'root', 'root-mode',
                     'manifest', 'marker')
        for mutation in mutations:
            with self.subTest(mutation=mutation):
                reached = []
                old_root = root.with_name('tuple-old-root')
                replacement = root.with_name('tuple-replacement-provider')
                def verify(*values, **options):
                    result = original_verify(*values, **options)
                    reached.append(mutation)
                    if mutation in ('content', 'restored-content'):
                        target.write_bytes(saved[target.name] + b'changed')
                        if mutation == 'restored-content':
                            target.write_bytes(saved[target.name])
                    elif mutation == 'inode':
                        replacement.write_bytes(saved[target.name])
                        replacement.replace(target)
                    elif mutation == 'missing':
                        target.unlink()
                    elif mutation == 'extra':
                        (root / 'unexpected-member').write_bytes(b'extra')
                    elif mutation == 'symlink':
                        replacement.write_bytes(saved[target.name])
                        target.unlink()
                        target.symlink_to(replacement)
                    elif mutation == 'directory':
                        target.unlink()
                        target.mkdir()
                    elif mutation == 'mode':
                        target.chmod(target_mode ^ 0o100)
                    elif mutation == 'hardlink':
                        os.link(target, replacement)
                    elif mutation == 'root':
                        root.rename(old_root)
                        root.mkdir(mode=root_mode)
                        for name, raw in saved.items():
                            (root / name).write_bytes(raw)
                    elif mutation == 'root-mode':
                        root.chmod(root_mode ^ 0o100)
                    elif mutation == 'manifest':
                        (root / figure.MANIFEST).write_bytes(saved[figure.MANIFEST] + b' ')
                    else:
                        (root / figure.COMPLETE).write_bytes(saved[figure.COMPLETE] + b' ')
                    return result
                try:
                    with patch.object(figure, 'verify', side_effect=verify):
                        with self.assertRaises((ValueError, OSError)):
                            figure.verify_tuple(self.paths, self.fixture.wiki, self.fixture.date)
                    self.assertEqual(reached, [mutation])
                finally:
                    root.chmod(root_mode)
                    for path in root.iterdir():
                        if path.is_dir() and not path.is_symlink():
                            path.rmdir()
                        else:
                            path.unlink()
                    if old_root.exists():
                        root.rmdir()
                        old_root.rename(root)
                    else:
                        for name, raw in saved.items():
                            (root / name).write_bytes(raw)
                    target.chmod(target_mode)
                    if replacement.exists():
                        replacement.unlink()

    def test_tuple_refuses_replaced_contained_origin_directory_after_full_verification(self):
        fixture = OfflineFigureMaterializationTests()
        fixture.setUp()
        self.addCleanup(fixture.doCleanups)
        args, _ = fixture.epoch_complete()
        output, _ = fixture.materialize(args)
        paths = {role: output / name for role, name in figure.output_roles(output).items()}
        origin = next(path for path in output.iterdir() if path.is_dir())
        old_origin = output.parent / 'tuple-old-origin'
        original_verify = figure.verify
        reached = []
        def verify(*values, **options):
            result = original_verify(*values, **options)
            origin.rename(old_origin)
            origin.mkdir()
            for path in old_origin.iterdir():
                (origin / path.name).write_bytes(path.read_bytes())
            reached.append(origin)
            return result
        with patch.object(figure, 'verify', side_effect=verify):
            with self.assertRaises((ValueError, OSError)):
                figure.verify_tuple(paths, fixture.fixture.wiki, fixture.fixture.date)
        self.assertEqual(reached, [origin])


class FigureRegistrationDecodeReuseTests(unittest.TestCase):
    def setUp(self):
        self.fixture = FigureFileTests()
        self.fixture.setUp()
        self.addCleanup(self.fixture.doCleanups)
        self.namespace = self.fixture.namespace.read_bytes()

    def reduce(self, batches, site):
        return figure.file_records(iter(batches), self.namespace, self.fixture.wiki,
            self.fixture.date, site, has_batches=True, record_limit=100)

    def test_equal_registration_response_is_read_only_and_keeps_both_validations(self):
        batch = self.fixture.batch()
        raw = batch['response'].encode()
        original_decode = figure.decode
        decoded, snapshots = [], []
        def decode(value):
            result = original_decode(value)
            if value == raw:
                decoded.append(result)
                snapshots.append(copy.deepcopy(result))
            return result
        with patch.object(figure, 'decode', side_effect=decode), \
                patch.object(figure, '_figure_site_registration', wraps=figure._figure_site_registration) as checked:
            actual = self.reduce([batch], raw)
        self.assertEqual(len(decoded), 1)
        self.assertEqual(decoded, snapshots)
        self.assertEqual(checked.call_count, 2)
        self.assertIs(checked.call_args_list[0].args[0], decoded[0])
        self.assertIs(checked.call_args_list[1].args[0], decoded[0])
        self.assertEqual(actual['records'], self.fixture.project([batch])['records'])
        self.assertEqual(batch['response'].encode(), raw)

    def test_distinct_second_response_is_decoded_and_validated_independently(self):
        batches = [self.fixture.batch('ملف:DecodeA.svg'), self.fixture.batch('ملف:DecodeB.svg')]
        raw = [batch['response'].encode() for batch in batches]
        original_decode = figure.decode
        calls = []
        def decode(value):
            if value in raw:
                calls.append(value)
            return original_decode(value)
        with patch.object(figure, 'decode', side_effect=decode), \
                patch.object(figure, '_figure_site_registration', wraps=figure._figure_site_registration) as checked:
            actual = self.reduce(batches, raw[0])
        self.assertEqual(calls, raw)
        self.assertEqual(checked.call_count, 3)
        self.assertEqual(actual['records'], self.fixture.project(batches)['records'])
        bad = copy.deepcopy(batches)
        response = json.loads(bad[1]['response'])
        response['query']['extensions'][0]['vcs-version'] = '0' * 40
        bad[1]['response'] = figure.encoded(response).decode()
        with self.assertRaises(ValueError):
            self.reduce(bad, raw[0])

    def test_equal_and_distinct_responses_keep_malformed_and_nonfinite_refusals(self):
        original = self.fixture.response()
        for mutation in ('wiki', 'registration', 'timestamp', 'width', 'duplicate', 'nonfinite'):
            with self.subTest(mutation=mutation):
                response = copy.deepcopy(original)
                if mutation == 'wiki':
                    response['query']['general']['wikiid'] = 'enwiktionary'
                elif mutation == 'registration':
                    response['query']['extensions'][0]['vcs-version'] = '0' * 40
                elif mutation == 'timestamp':
                    del response['query']['pages'][0]['imageinfo'][0]['timestamp']
                elif mutation == 'width':
                    response['query']['pages'][0]['imageinfo'][0]['width'] = '250'
                raw = figure.encoded(response)
                if mutation == 'duplicate':
                    raw = b'{"query":null,' + raw[1:]
                elif mutation == 'nonfinite':
                    response['query']['pages'][0]['imageinfo'][0]['width'] = float('nan')
                    raw = (json.dumps(response, ensure_ascii=False, sort_keys=True) + '\n').encode()
                batch = {'requests': ['ملف:Example.svg'], 'response': raw.decode()}
                for site in (raw, figure.encoded(self.fixture.site_api)):
                    with self.subTest(equal=(site == raw)), self.assertRaises((ValueError, KeyError, TypeError)):
                        self.reduce([batch], site)


    def test_mutable_site_inputs_keep_independent_decode_and_generator_mutation_refusal(self):
        batch = self.fixture.batch()
        original = batch['response'].encode()
        for site in (bytearray(original),):
            with self.subTest(site_type=type(site).__name__):
                with patch.object(figure, 'decode', wraps=figure.decode) as decoded, \
                        patch.object(figure, '_figure_site_registration', wraps=figure._figure_site_registration) as checked:
                    actual = self.reduce([batch], site)
                self.assertEqual(decoded.call_count, 2)
                self.assertIsNot(checked.call_args_list[0].args[0], checked.call_args_list[1].args[0])
                self.assertEqual(actual['records'], self.fixture.project([batch])['records'])
        # The existing fixed-site digest requires bytes; strings already failed.
        with self.assertRaises(TypeError):
            self.reduce([batch], original.decode())
        site = bytearray(original)
        response = json.loads(batch['response'])
        response['query']['extensions'][0]['vcs-version'] = '0' * 40
        changed = figure.encoded(response)
        reached = []
        def batches():
            site[:] = changed
            reached.append(True)
            yield dict(batch, response=changed.decode())
        with self.assertRaises(ValueError):
            self.reduce(batches(), site)
        self.assertEqual(reached, [True])


    def test_nonbytes_response_encoding_keeps_original_decode_domain(self):
        original = self.fixture.batch()
        raw = original['response'].encode()
        class BytesSubclass(bytes):
            pass
        for kind in (bytearray, BytesSubclass, memoryview):
            with self.subTest(encoded_type=kind.__name__):
                transformed = kind(raw)
                class Response(str):
                    def encode(self, *values, **options):
                        return transformed
                batch = dict(original, response=Response(original['response']))
                if kind is memoryview:
                    with self.assertRaises(TypeError):
                        self.reduce([batch], raw)
                else:
                    with patch.object(figure, 'decode', wraps=figure.decode) as decoded, \
                            patch.object(figure, '_figure_site_registration', wraps=figure._figure_site_registration) as checked:
                        actual = self.reduce([batch], raw)
                    self.assertEqual(decoded.call_count, 2)
                    self.assertIsNot(checked.call_args_list[0].args[0], checked.call_args_list[1].args[0])
                    self.assertEqual(actual['records'], self.fixture.project([original])['records'])
                self.assertEqual(bytes(transformed), raw)


def measure_figure_registration_decode(baseline, candidate, selection):
    """Bounded actual retained full-metadata frames, not a whole-FR timing claim."""
    import gc
    import tracemalloc
    if tracemalloc.is_tracing():
        raise ValueError('Registration decode measurement requires unprofiled entry')
    raw_path = Path(selection['raw_path'])
    namespace_path = Path(selection['namespace']['path'])
    fields = ('st_dev', 'st_ino', 'st_mode', 'st_nlink', 'st_uid', 'st_gid',
              'st_size', 'st_mtime_ns', 'st_ctime_ns')
    def physical(path):
        value = path.lstat()
        return tuple(getattr(value, name) for name in fields)
    before = physical(raw_path)
    if list(before) != selection['raw_stamp']:
        raise ValueError('Selected retained response stream identity changed')
    namespace = namespace_path.read_bytes()
    if (len(namespace) != selection['namespace']['bytes'] or
            hashlib.sha256(namespace).hexdigest() != selection['namespace']['sha256']):
        raise ValueError('Selected retained namespace changed')
    batches = []
    with raw_path.open('rb') as source:
        header = source.readline(baseline.STREAM_HEADER_LIMIT + 1)
        if hashlib.sha256(header).hexdigest() != selection['header_sha256']:
            raise ValueError('Selected retained response header changed')
        encoding = baseline.raw_record_encoding(baseline.stream_decode(header))
        for row in selection['frames']:
            source.seek(row['offset'])
            raw = source.read(row['bytes'])
            if len(raw) != row['bytes'] or hashlib.sha256(raw).hexdigest() != row['sha256']:
                raise ValueError('Selected retained response frame changed')
            batches.append(baseline.raw_record_decode(raw, encoding))
    if physical(raw_path) != before:
        raise ValueError('Selected retained response stream changed during setup')
    snapshots = copy.deepcopy(batches)
    response_bytes = [batch['response'].encode() for batch in batches]
    def run(helper, values=batches):
        return [helper.file_records(iter((batch,)), namespace, selection['wiki'],
            selection['date'], batch['response'].encode(), has_batches=True, record_limit=50,
            profile_kind=helper.FIGURE_PROFILE_V4, allow_compatible_epochs=True,
            allow_tiff_companion=True, allow_decimal_tiff_axes=True, allow_default_tiff_page=False)
            for batch in values]
    expected = run(baseline)
    actual = run(candidate)
    if actual != expected or batches != snapshots:
        raise AssertionError('Retained full-caller output or input parity differs')
    census = []
    targets = set(response_bytes)
    for name, helper in (('baseline', baseline), ('candidate', candidate)):
        original_decode = helper.decode
        counts = {'calls': 0, 'bytes': 0}
        def decode(raw):
            if raw in targets:
                counts['calls'] += 1
                counts['bytes'] += len(raw)
            return original_decode(raw)
        with patch.object(helper, 'decode', side_effect=decode):
            result = run(helper)
        if result != expected:
            raise AssertionError('Instrumented full-caller parity differs')
        census.append(dict(arm=name, **counts))
        del result
    if (census[0]['calls'] != 2 * len(batches) or census[1]['calls'] != len(batches) or
            census[0]['bytes'] != 2 * sum(map(len, response_bytes)) or
            census[1]['bytes'] != sum(map(len, response_bytes))):
        raise AssertionError('Actual retained response decode census differs')
    errors = []
    for mutation in ('wrong-wiki', 'missing-file-timestamp', 'duplicate-key', 'nonfinite'):
        batch = copy.deepcopy(batches[0])
        response = json.loads(batch['response'])
        if mutation == 'wrong-wiki':
            response['query']['general']['wikiid'] = 'invalidwiktionary'
        elif mutation == 'missing-file-timestamp':
            del response['query']['pages'][0]['imageinfo'][0]['timestamp']
        raw = baseline.encoded(response)
        if mutation == 'duplicate-key':
            raw = b'{"query":null,' + raw[1:]
        elif mutation == 'nonfinite':
            response['query']['pages'][0]['imageinfo'][0]['width'] = float('nan')
            raw = (json.dumps(response, ensure_ascii=False, sort_keys=True) + '\n').encode()
        batch['response'] = raw.decode()
        observed = []
        for helper in (baseline, candidate):
            try:
                run(helper, [batch])
            except Exception as error:
                observed.append((type(error).__name__, str(error)))
            else:
                raise AssertionError('Malformed actual retained response was accepted')
        if observed[0] != observed[1]:
            raise AssertionError('Malformed retained response error parity differs')
        errors.append(dict(mutation=mutation, error=observed[0]))
    del actual
    rows, allocation_rows = [], []
    for traced, output in ((False, rows), (True, allocation_rows)):
        for name, helper in (('baseline', baseline), ('candidate', candidate),
                             ('candidate', candidate), ('baseline', baseline)):
            gc.collect()
            if traced:
                tracemalloc.start()
            try:
                wall, cpu = time.perf_counter_ns(), time.process_time_ns()
                result = run(helper)
                cpu, wall = time.process_time_ns() - cpu, time.perf_counter_ns() - wall
                if traced:
                    current, peak = tracemalloc.get_traced_memory()
            finally:
                if traced:
                    tracemalloc.stop()
            output.append(dict(arm=name, cpu_ns=cpu, wall_ns=wall,
                **(dict(current_bytes=current, peak_bytes=peak) if traced else {})))
            # Equality and result disposal stay outside both clocks.
            if result != expected:
                raise AssertionError('Timed full-caller output parity differs')
            del result
    if batches != snapshots or physical(raw_path) != before or namespace_path.read_bytes() != namespace:
        raise AssertionError('Retained measurement input changed')
    return dict(scope='32 retained FR full-metadata response frames through complete file_records per-frame caller; full-metadata sensitivity, not lean distribution or whole-FR phase attribution',
        frames=len(batches), request_titles=sum(len(batch['requests']) for batch in batches),
        response_bytes=sum(map(len, response_bytes)), parity=True, input_after=True,
        census=census, error_parity=errors, rows=rows, allocation_rows=allocation_rows)


class FigureUtcKeyTests(unittest.TestCase):
    @staticmethod
    def legacy(value):
        import re
        from datetime import datetime
        match = re.fullmatch(r'([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2})(?:\.([0-9]+))?Z', value) if isinstance(value, str) else None
        if match is None:
            raise ValueError('Noncanonical figure source UTC timestamp')
        base = match.group(1)
        datetime.strptime(base, '%Y-%m-%dT%H:%M:%S')
        return base, (match.group(2) or '').rstrip('0')

    @staticmethod
    def outcome(function, value):
        try:
            return 'value', function(value)
        except Exception as error:
            return 'error', type(error), str(error)

    def test_native_utc_key_preserves_exact_calendar_fraction_keys_and_errors(self):
        for base in ('0001-01-01T00:00:00', '1900-02-28T23:59:59',
                     '2000-02-29T00:00:00', '2400-02-29T12:34:56', '9999-12-31T23:59:59'):
            for fraction in ('', '.0', '.000000000', '.1', '.0100', '.123456789012345678900'):
                value = base + fraction + 'Z'
                self.assertEqual(figure._figure_utc_key(value), self.legacy(value))
                self.assertEqual(figure._figure_utc_key(value), (base, fraction.lstrip('.').rstrip('0')))
        base = '2026-10-01T00:00:00'
        self.assertLess(figure._figure_utc_key(base+'.000099999999999Z'), figure._figure_utc_key(base+'.0001Z'))
        self.assertEqual(figure._figure_utc_key(base+'.100000000Z'), figure._figure_utc_key(base+'.1Z'))
        values = [None, False, 0, b'2026-10-01T00:00:00Z', [], {}, '',
            '0000-01-01T00:00:00Z', '1900-02-29T00:00:00Z', '2026-02-30T00:00:00Z',
            '2026-00-01T00:00:00Z', '2026-13-01T00:00:00Z', '2026-01-00T00:00:00Z',
            '2026-01-32T00:00:00Z', '2026-01-01T24:00:00Z', '2026-01-01T00:60:00Z',
            '2026-01-01T24:00:00.0Z', '2026-01-01T24:00:00.000000000000Z',
            '2026-01-01T24:00:00.1234567890123456789Z', '2026-12-31T24:00:00Z',
            '0001-01-01T24:00:00Z', '9999-12-31T24:00:00.0Z',
            '2000-02-28T24:00:00Z', '2000-02-29T24:00:00Z',
            '2026-01-01T24:00:01Z', '2026-01-01T24:01:00Z',
            '2026-01-01T99:00:00Z', '2026-01-01T00:99:00Z', '2026-01-01T00:00:99Z',
            '2026-01-01T00:00:60Z', '2026-01-01T00:00:61Z', '2026-01-01T00:00:00.Z',
            '2026-01-01 00:00:00Z', '2026-01-01T00:00:00+00:00', '2026-01-01T00:00:00z',
            '2026-01-01T00:00:00Z\n', '２０２６-01-01T00:00:00Z', '-001-01-01T00:00:00Z']
        for value in values:
            with self.subTest(value=value):
                expected = self.outcome(self.legacy, value)
                self.assertEqual(expected[0], 'error')
                self.assertEqual(self.outcome(figure._figure_utc_key, value), expected)

    def test_native_utc_key_uses_fast_parser_only_after_syntax_and_preserves_fallback(self):
        from types import SimpleNamespace
        native = figure.datetime
        direct = unittest.mock.Mock(wraps=native.fromisoformat)
        legacy = unittest.mock.Mock(wraps=native.strptime)
        calendar = SimpleNamespace(fromisoformat=direct, strptime=legacy)
        with patch.object(figure, 'datetime', calendar):
            self.assertEqual(figure._figure_utc_key('2026-10-01T00:00:00.123456789Z'),
                             ('2026-10-01T00:00:00', '123456789'))
            self.assertEqual((direct.call_count, legacy.call_count), (1, 0))
            direct.reset_mock();legacy.reset_mock()
            expected = self.outcome(self.legacy, '1900-02-29T00:00:00Z')
            self.assertEqual(self.outcome(figure._figure_utc_key, '1900-02-29T00:00:00Z'), expected)
            self.assertEqual((direct.call_count, legacy.call_count), (1, 1))
            direct.reset_mock();legacy.reset_mock()
            with self.assertRaisesRegex(ValueError, 'Noncanonical figure source UTC timestamp'):
                figure._figure_utc_key('2026-10-01T00:00:00+00:00')
            self.assertEqual((direct.call_count, legacy.call_count), (0, 0))
            direct.side_effect = ValueError('native parser rejection')
            self.assertEqual(figure._figure_utc_key('2026-10-01T00:00:00Z'),
                             self.legacy('2026-10-01T00:00:00Z'))
            self.assertEqual((direct.call_count, legacy.call_count), (1, 1))
            direct.reset_mock();legacy.reset_mock()
            failure = MemoryError('native parser allocation')
            direct.side_effect = failure
            with self.assertRaises(MemoryError) as caught:
                figure._figure_utc_key('2026-10-01T00:00:00Z')
            self.assertIs(caught.exception, failure)
            self.assertEqual((direct.call_count, legacy.call_count), (1, 0))

    def test_native_utc_key_preserves_real_file_document_provider_and_future_refusal(self):
        fixture = FigureFileTests();fixture.setUp();self.addCleanup(fixture.doCleanups)
        for timestamp, valid in (('2000-02-29T00:00:00Z', True),
                                 ('2026-10-05T22:59:59.1234567890123456789Z', True),
                                 ('2026-10-06T00:00:00Z', False),
                                 ('1900-02-29T00:00:00Z', False)):
            value = fixture.response()
            value['query']['pages'][0]['imageinfo'][0]['timestamp'] = timestamp
            batch = fixture.batch(response=value)
            before = copy.deepcopy(batch)
            def project(_):
                document = fixture.project([batch])
                return document, b''.join(figure.provider_chunks(document))
            with patch.object(figure, '_figure_utc_key', new=self.legacy):
                expected = self.outcome(project, None)
            actual = self.outcome(project, None)
            self.assertEqual(actual, expected)
            self.assertEqual(actual[0], 'value' if valid else 'error')
            if valid:
                self.assertEqual(actual[1][0]['records'][0]['file_timestamp'], timestamp)
            self.assertEqual(batch, before)


def measure_figure_utc_key(baseline, candidate, selection):
    """Two authentic lean frames per fresh replay walk; no corpus extrapolation."""
    import gc
    import tempfile
    import tracemalloc
    if tracemalloc.is_tracing():
        raise ValueError('UTC key measurement requires unprofiled entry')
    fields = ('st_dev', 'st_ino', 'st_mode', 'st_nlink', 'st_uid', 'st_gid',
              'st_size', 'st_mtime_ns', 'st_ctime_ns')
    def physical(path):
        value = path.lstat()
        return tuple(getattr(value, name) for name in fields)
    originals, stamps = {}, {}
    for row in [selection['namespace'], *selection['files']]:
        path = Path(row['path'])
        before = physical(path)
        raw = path.read_bytes()
        if (len(raw) != row['bytes'] or hashlib.sha256(raw).hexdigest() != row['sha256'] or
                physical(path) != before):
            raise ValueError('Retained lean replay input changed')
        originals[path], stamps[path] = raw, before
    namespace = originals[Path(selection['namespace']['path'])]
    operations = 16
    with tempfile.TemporaryDirectory(prefix='figure-utc-key-') as temporary:
        root = Path(temporary)
        for row in selection['files']:
            path = Path(row['path'])
            (root/path.name).write_bytes(originals[path])
        pairs = []
        for reference in selection['references']:
            names, raw, artifacts, accepted = baseline.captured_http_stage(root, reference,
                selection['wiki'], light=True)
            # Only this task's temporary raw copy is retired. Original evidence stays intact.
            accepted[0].unlink()
            source = dict(kind='http-archived-lean', batch=reference, artifacts=artifacts)
            pairs.append((source, dict(requests=names, response=raw.decode())))
        if len(pairs) != 2 or any(len(batch['requests']) != 50 for _, batch in pairs):
            raise AssertionError('Retained two-frame task shape changed')
        before_pairs = copy.deepcopy(pairs)
        files_before = {path.name:(path.read_bytes(), physical(path)) for path in root.iterdir()}
        def run(helper, count=operations):
            results = []
            for _ in range(count):
                files, archives = set(), {}
                for source, batch in pairs:
                    frame = helper.replay_source(root, source, batch, selection['wiki'], selection['date'],
                        namespace, files, profile_kind=helper.FIGURE_PROFILE_V4,
                        allow_compatible_epochs=True, origin_plan={})
                    if frame is None:
                        # Historical UTC baseline predates the archive return API.
                        helper.record_http_archive(root, source, batch, archives, origin_plan={})
                    else:
                        archives.update(frame)
                results.append((files, archives))
            return results
        expected = run(baseline)
        actual = run(candidate)
        if actual != expected or pairs != before_pairs:
            raise AssertionError('Retained replay authority/output/input parity differs')
        del actual
        documents, census = [], []
        for name, helper in (('baseline', baseline), ('candidate', candidate)):
            captured = []
            original_records = helper.file_records
            def records(*args, **options):
                result = original_records(*args, **options)
                captured.append((result, b''.join(helper.provider_chunks(result))))
                return result
            with patch.object(helper, 'file_records', side_effect=records):
                result = run(helper, 1)
            if result != expected[:1]:
                raise AssertionError('Retained semantic census changes replay result')
            documents.append(captured)
            del result
            from types import SimpleNamespace
            original_calendar = helper.datetime
            counts = dict(native=0, legacy=0)
            def native(value):
                counts['native'] += 1
                return original_calendar.fromisoformat(value)
            def legacy(value, format):
                counts['legacy'] += 1
                return original_calendar.strptime(value, format)
            with patch.object(helper, 'datetime', SimpleNamespace(fromisoformat=native, strptime=legacy)):
                result = run(helper, 1)
            if result != expected[:1]:
                raise AssertionError('Calendar-call census changes replay result')
            census.append(dict(arm=name, **counts))
            del result
        if documents[0] != documents[1] or len(documents[0]) != 2:
            raise AssertionError('Complete semantic records/provider parity differs')
        if census != [dict(arm='baseline', native=0, legacy=106), dict(arm='candidate', native=102, legacy=4)]:
            raise AssertionError('Actual two-frame Figure calendar-call census differs')
        del documents
        errors = []
        source, batch = pairs[-1]
        receipt_path = root/source['batch']['accepted_receipt']
        receipt_original = receipt_path.read_bytes()
        response_original = batch['response']
        for mutation in ('wrong-wiki', 'missing-timestamp', 'unrequested-metadata', 'duplicate-key'):
            data = baseline.decode(response_original.encode())
            if mutation == 'wrong-wiki': data['query']['general']['wikiid'] = 'invalidwiktionary'
            elif mutation == 'missing-timestamp': del data['query']['pages'][0]['imageinfo'][0]['timestamp']
            elif mutation == 'unrequested-metadata': data['query']['pages'][0]['imageinfo'][0]['metadata'] = []
            raw = baseline.encoded(data)
            if mutation == 'duplicate-key': raw = b'{"query":null,' + raw[1:]
            batch['response'] = raw.decode()
            receipt = baseline.decode(receipt_original)
            receipt.update(response_bytes=len(raw), response_sha256=baseline.digest(raw))
            receipt_path.write_bytes(baseline.encoded(receipt))
            observed = []
            for helper in (baseline, candidate):
                try:
                    run(helper, 1)
                except Exception as error:
                    observed.append((type(error).__name__, str(error)))
                else:
                    raise AssertionError('Invalid retained replay response accepted')
            if observed[0] != observed[1]:
                raise AssertionError('Retained replay error parity differs')
            errors.append(dict(mutation=mutation, error=observed[0]))
            batch['response'] = response_original
            receipt_path.write_bytes(receipt_original)
        # Fixture mutations are fully restored and revalidated before all clocks.
        if run(baseline) != expected or run(candidate) != expected or pairs != before_pairs:
            raise AssertionError('Restored retained replay differs')
        files_before = {path.name:(path.read_bytes(), physical(path)) for path in root.iterdir()}
        rows, allocation_rows = [], []
        for traced, output in ((False, rows), (True, allocation_rows)):
            for name, helper in (('baseline', baseline), ('candidate', candidate),
                                 ('candidate', candidate), ('baseline', baseline)):
                gc.collect()
                if traced: tracemalloc.start()
                try:
                    wall, cpu = time.perf_counter_ns(), time.process_time_ns()
                    result = run(helper)
                    cpu, wall = time.process_time_ns()-cpu, time.perf_counter_ns()-wall
                    if traced: current, peak = tracemalloc.get_traced_memory()
                finally:
                    if traced: tracemalloc.stop()
                output.append(dict(arm=name, cpu_ns=cpu, wall_ns=wall,
                    **(dict(current_bytes=current, peak_bytes=peak) if traced else {})))
                if result != expected:
                    raise AssertionError('Timed retained replay output parity differs')
                del result
        if (pairs != before_pairs or
                {path.name:(path.read_bytes(), physical(path)) for path in root.iterdir()} != files_before):
            raise AssertionError('Retained replay task mutated its inputs')
    for path, raw in originals.items():
        if physical(path) != stamps[path] or path.read_bytes() != raw:
            raise AssertionError('Original retained input changed during qualification')
    return dict(scope='16 independent ordinary replay_source walks over the same two authentic FR lean HTTP frames; isolated UTC validation change, not full verify or whole-FR timing',
        operations=operations, frames_per_operation=len(pairs), unique_request_titles=100,
        response_bytes_per_operation=sum(len(batch['response'].encode()) for _, batch in pairs),
        parity=True, input_after=True, census=census, error_parity=errors,
        rows=rows, allocation_rows=allocation_rows)


class HttpArchiveReplayIdentityTests(unittest.TestCase):
    def terminal(self):
        fixture = TerminalHttpOriginTests()
        fixture.setUp()
        self.addCleanup(fixture.doCleanups)
        return fixture

    def test_frame_returns_exact_archive_with_one_receipt_read_and_response_hash(self):
        for kind in ('full', 'light', 'lean', 'tiff'):
            with self.subTest(kind=kind):
                fixture = self.terminal()
                title = 'ملف:F.tif' if kind == 'tiff' else 'ملف:Unicode-\u00e9.svg'
                source, batch = fixture.terminal(0, title, lean=kind != 'full')
                if kind == 'light':
                    source['kind'] = 'http-archived-light'
                if kind == 'tiff':
                    followup, full = fixture.terminal(0, title, stage='tiff')
                    source.update(tiff_batch=followup['batch'], tiff_artifacts=followup['artifacts'])
                    batch['tiff_metadata_response'] = full['response']
                scoped = fixture.scoped(0, source)
                root = fixture.root / fixture.ids[0]
                references = [source['batch']] + ([source['tiff_batch']] if kind == 'tiff' else [])
                receipts = {root/ref['accepted_receipt']: figure.decode((root/ref['accepted_receipt']).read_bytes())
                            for ref in references}
                raws = [batch['response'].encode()] + ([batch['tiff_metadata_response'].encode()] if kind == 'tiff' else [])
                prefix = fixture.ids[0] + '/'
                expected = {prefix+receipt['response']: {'bytes': len(raw), 'sha256': figure.digest(raw)}
                            for receipt, raw in zip(receipts.values(), raws, strict=True)}
                if kind == 'tiff':
                    expected[('tiff-titles', prefix+next(iter(receipts.values()))['response'])] = list(batch['requests'])
                before = copy.deepcopy((scoped, batch))
                files_before = {p.name:p.read_bytes() for p in root.iterdir()}
                original_small, original_digest = figure.small, figure.digest
                reads, hashes = [], []
                def small(path, *args, **options):
                    reads.append(Path(path))
                    return original_small(path, *args, **options)
                def digest(raw):
                    if raw in raws:
                        hashes.append(raw)
                    return original_digest(raw)
                original_http = figure.replay_http_source
                def http(*values, **options):
                    # Count HTTP authentication only; semantic reducers still
                    # hash their independent site registration outside this call.
                    with patch.object(figure, 'digest', side_effect=digest):
                        return original_http(*values, **options)
                with patch.object(figure, 'small', side_effect=small), patch.object(figure, 'replay_http_source', side_effect=http):
                    actual = fixture.replay(scoped, batch)
                self.assertEqual(actual, expected)
                self.assertEqual({p:reads.count(p) for p in receipts}, {p:1 for p in receipts})
                self.assertEqual([hashes.count(raw) for raw in raws], [1]*len(raws))
                self.assertEqual((scoped, batch), before)
                self.assertEqual({p.name:p.read_bytes() for p in root.iterdir()}, files_before)
                self.assertFalse(hasattr(figure, 'record_http_archive'))

    def test_returned_identity_is_fresh_and_cannot_authorize_changed_receipt(self):
        fixture = self.terminal()
        source, batch = fixture.terminal(0, 'ملف:F.tif', lean=True)
        followup, full = fixture.terminal(0, 'ملف:F.tif', stage='tiff')
        source.update(tiff_batch=followup['batch'], tiff_artifacts=followup['artifacts'])
        batch['tiff_metadata_response'] = full['response']
        scoped = fixture.scoped(0, source)
        expected = fixture.replay(scoped, batch)
        returned = fixture.replay(scoped, batch)
        name = next(name for name in returned if isinstance(name, str))
        returned[name]['sha256'] = '0'*64
        returned[('tiff-titles', name)].append('ملف:Foreign.tif')
        self.assertEqual(fixture.replay(scoped, batch), expected)
        self.assertEqual(batch['requests'], ['ملف:F.tif'])
        path = fixture.root/fixture.ids[0]/source['batch']['accepted_receipt']
        saved = path.read_bytes()
        receipt = figure.decode(saved)
        for field, value in (('response_sha256', '0'*64), ('response_bytes', receipt['response_bytes']+1),
                             ('accepted', 1), ('request', 'file-metadata.request-000002.json')):
            with self.subTest(field=field):
                changed = dict(receipt, **{field:value})
                path.write_bytes(figure.encoded(changed))
                with self.assertRaises(ValueError):
                    fixture.replay(scoped, batch)
                path.write_bytes(saved)
        path.write_bytes(b'{"accepted":true,' + saved[1:])
        with self.assertRaises(ValueError):
            fixture.replay(scoped, batch)
        path.write_bytes(saved)
        self.assertEqual(fixture.replay(scoped, batch), expected)

    def test_tuple_final_guard_rejects_between_stage_receipt_and_request_mutation(self):
        for mutation in ('receipt-content', 'receipt-restored', 'receipt-inode', 'request-content', 'request-inode'):
            with self.subTest(mutation=mutation):
                fixture = FigureOutputDigestTests()
                fixture.setUp()
                self.addCleanup(fixture.doCleanups)
                root = fixture.args.output
                original = figure.replay_source
                reached = []
                def replay(local, source, *args, **options):
                    archived = original(local, source, *args, **options)
                    if Path(local) == root and archived and not reached:
                        key = 'request' if mutation.startswith('request') else 'accepted_receipt'
                        path = root/source['batch'][key]
                        raw = path.read_bytes()
                        reached.append((path, raw))
                        if mutation.endswith('inode'):
                            replacement = root.parent/'replaced-http-evidence'
                            replacement.write_bytes(raw)
                            replacement.replace(path)
                        else:
                            path.write_bytes(raw+b' ')
                            if mutation.endswith('restored'):
                                path.write_bytes(raw)
                    return archived
                with patch.object(figure, 'replay_source', side_effect=replay):
                    with self.assertRaises((ValueError, OSError)):
                        figure.verify_tuple(fixture.paths, fixture.fixture.wiki, fixture.fixture.date)
                self.assertEqual(len(reached), 1)
                path, raw = reached[0]
                path.write_bytes(raw)
                self.assertEqual(set(figure.verify_tuple(fixture.paths, fixture.fixture.wiki, fixture.fixture.date)), set(fixture.paths))

    def test_resume_keeps_original_receipt_hash_after_archive_handoff(self):
        fixture = FigureFileTests()
        fixture.setUp()
        self.addCleanup(fixture.doCleanups)
        args, _ = fixture.make_wall_stop()
        original = figure.replay_source
        changed = []
        def replay(root, source, *values, **options):
            archived = original(root, source, *values, **options)
            if archived and not changed:
                receipt = Path(root)/source['batch']['accepted_receipt']
                receipt.write_bytes(receipt.read_bytes()+b' ')
                changed.append(receipt)
            return archived
        with patch.object(figure, 'replay_source', side_effect=replay):
            with self.assertRaisesRegex(ValueError, 'Figure checkpoint evidence changed'):
                figure.capture_files(args, transport=lambda *_: self.fail('changed prefix reached transport'), sleep=lambda _:None)
        self.assertEqual(len(changed), 1)
        self.assertFalse((args.output/figure.COMPLETE).exists())

    def test_stream_archive_merge_keeps_duplicate_identity_refusal(self):
        fixture = FigureFileTests()
        fixture.setUp()
        self.addCleanup(fixture.doCleanups)
        args, _, _ = fixture.complete_stream_fixture()
        original = figure.replay_source
        returned = []
        def replay(*values, **options):
            archived = original(*values, **options)
            if archived:
                returned.append(archived)
                if len(returned) == 2:
                    return returned[0]
            return archived
        with patch.object(figure, 'replay_source', side_effect=replay):
            with self.assertRaisesRegex(ValueError, 'Duplicate contained Figure HTTP archive identity'):
                figure.verify(args.output)
        self.assertEqual(len(returned), 2)
        self.assertNotEqual(set(returned[0]), set(returned[1]))

    def test_retained_source_validates_without_http_archive_identity(self):
        fixture = FigureFileTests()
        fixture.setUp()
        self.addCleanup(fixture.doCleanups)
        args, observation, _ = fixture.complete_stream_fixture()
        namespace = fixture.namespace.read_bytes()
        batch = figure.retained_metadata_batch(observation, fixture.wiki, fixture.date, namespace)
        source = {'kind':'retained-request', 'path':str(observation.resolve()),
                  'sha256':figure.digest(observation.read_bytes())}
        files = set()
        self.assertEqual(figure.replay_source(args.output, source, batch, fixture.wiki, fixture.date,
                                             namespace, files, origin_plan={}), {})
        self.assertEqual(files, set())
        bad = dict(source, sha256='0'*64)
        with self.assertRaisesRegex(ValueError, 'Retained Figure request changed'):
            figure.replay_source(args.output, bad, batch, fixture.wiki, fixture.date, namespace, set(), origin_plan={})


def measure_figure_http_archive(baseline, candidate, selection):
    """Existing 32 real full-metadata frames through the normal HTTP leaf replay."""
    import gc
    import tracemalloc
    if tracemalloc.is_tracing():
        raise ValueError('HTTP archive measurement requires unprofiled entry')
    fields = ('st_dev', 'st_ino', 'st_mode', 'st_nlink', 'st_uid', 'st_gid',
              'st_size', 'st_mtime_ns', 'st_ctime_ns')
    def physical(path):
        value = path.lstat()
        return [getattr(value, name) for name in fields]
    raw_selection = selection['raw_selection']
    raw_path = Path(raw_selection['raw_path'])
    request_selection = selection['requests']
    request_path = Path(request_selection['path'])
    origin = raw_path.parent/selection['origin']
    namespace_path = Path(selection['namespace']['path'])
    namespace_stamp = physical(namespace_path)
    namespace = namespace_path.read_bytes()
    if (len(namespace) != selection['namespace']['bytes'] or
            hashlib.sha256(namespace).hexdigest() != selection['namespace']['sha256'] or
            physical(namespace_path) != namespace_stamp):
        raise ValueError('Selected retained namespace changed')
    def bounded_rows(path, stamp, rows):
        if physical(path) != stamp:
            raise ValueError('Selected retained frame stream identity changed')
        values = []
        with path.open('rb') as stream:
            if [getattr(os.fstat(stream.fileno()), name) for name in fields] != stamp:
                raise ValueError('Selected retained frame stream fd differs')
            for row in rows:
                stream.seek(row['offset'])
                raw = stream.read(row['bytes'])
                if len(raw) != row['bytes'] or hashlib.sha256(raw).hexdigest() != row['sha256']:
                    raise ValueError('Selected retained frame bytes changed')
                values.append(raw)
            if [getattr(os.fstat(stream.fileno()), name) for name in fields] != stamp:
                raise ValueError('Selected retained frame stream fd changed')
        if physical(path) != stamp:
            raise ValueError('Selected retained frame stream changed')
        return values
    if physical(origin) != selection['origin_stamp'] or origin.is_symlink():
        raise ValueError('Selected retained HTTP origin changed')
    header_size = raw_selection['frames'][0]['offset']
    raw_rows = [{'offset':0, 'bytes':header_size, 'sha256':raw_selection['header_sha256']},
                *raw_selection['frames']]
    raw_records = bounded_rows(raw_path, raw_selection['raw_stamp'], raw_rows)
    source_records = bounded_rows(request_path, request_selection['stamp'], request_selection['rows'])
    encoding = baseline.raw_record_encoding(baseline.stream_decode(raw_records[0]))
    header = baseline.stream_decode(source_records[0])
    if header != request_selection['rows'][0]['value'] or header['schema'] != baseline.REQUEST_STREAM_SCHEMA:
        raise ValueError('Selected retained request header changed')
    source_rows = [baseline.stream_decode(raw) for raw in source_records[1:]]
    if source_rows != [row['value'] for row in request_selection['rows'][1:]]:
        raise ValueError('Selected retained request source selection differs')
    batches = [baseline.raw_record_decode(raw, encoding) for raw in raw_records[1:]]
    if len(batches) != 32 or len(source_rows) != 32 or any(len(batch['requests']) != 50 for batch in batches):
        raise ValueError('Selected retained 32-frame task shape changed')
    originals = {}
    for row in selection['http_files']:
        path = Path(row['path'])
        if physical(path) != row['stamp'] or path.parent != origin or path.is_symlink():
            raise ValueError('Selected retained HTTP evidence identity changed')
        raw = path.read_bytes()
        if (len(raw) != row['bytes'] or hashlib.sha256(raw).hexdigest() != row['sha256'] or
                physical(path) != row['stamp']):
            raise ValueError('Selected retained HTTP evidence changed')
        originals[path] = raw
    prefix = selection['origin']+'/'
    pairs = []
    for source, batch in zip(source_rows, batches, strict=True):
        if (source['kind'] != 'http-archived' or set(source) != {'kind','batch','artifacts'} or
                any(not name.startswith(prefix) or '/' in name[len(prefix):] for name in source['artifacts']) or
                set(source['batch'].values()) != set(source['artifacts'])):
            raise ValueError('Selected retained full HTTP origin shape differs')
        leaf = dict(source, artifacts=[name[len(prefix):] for name in source['artifacts']],
                    batch={key:name[len(prefix):] for key,name in source['batch'].items()})
        pairs.append((leaf, batch))
    if {origin/name for source,_ in pairs for name in source['artifacts']} != set(originals):
        raise ValueError('Selected retained HTTP members differ')
    snapshots = copy.deepcopy(pairs)
    operations = 32
    def run(helper, count=operations, values=pairs):
        results = []
        for _ in range(count):
            files, archived = set(), {}
            for source, batch in values:
                frame = helper.replay_source(origin, source, batch, raw_selection['wiki'], raw_selection['date'],
                    namespace, files, profile_kind=helper.FIGURE_PROFILE_V4,
                    allow_compatible_epochs=True, origin_plan={})
                if helper is baseline:
                    if frame is not None:
                        raise AssertionError('Historical baseline archive API changed')
                    helper.record_http_archive(origin, source, batch, archived, origin_plan={})
                else:
                    for name, identity in frame.items():
                        if name in archived:
                            raise ValueError('Duplicate contained Figure HTTP archive identity')
                        archived[name] = identity
            results.append((files, baseline.encoded(archived)))
        return results
    expected = run(baseline)
    if run(candidate) != expected or pairs != snapshots:
        raise AssertionError('Retained HTTP archive/output/input parity differs')
    # Complete metadata and provider comparison is outside the archive clocks.
    semantic = []
    for helper in (baseline, candidate):
        documents = [helper.file_records(iter((batch,)), namespace, raw_selection['wiki'], raw_selection['date'],
            batch['response'].encode(), has_batches=True, record_limit=50,
            profile_kind=helper.FIGURE_PROFILE_V4, allow_compatible_epochs=True,
            allow_tiff_companion=True, allow_decimal_tiff_axes=True, allow_default_tiff_page=False)
            for _,batch in pairs]
        semantic.append((documents, [b''.join(helper.provider_chunks(document)) for document in documents]))
    if semantic[0] != semantic[1]:
        raise AssertionError('Retained full metadata/provider parity differs')
    del semantic
    targets = {batch['response'].encode() for _,batch in pairs}
    receipt_paths = {origin/source['batch']['accepted_receipt'] for source,_ in pairs}
    census = []
    for name, helper in (('baseline', baseline), ('candidate', candidate)):
        original_small, original_digest = helper.small, helper.digest
        counts = dict(receipt_reads=0, response_hashes=0, response_hash_bytes=0)
        def small(path, *values, **options):
            if Path(path) in receipt_paths:
                counts['receipt_reads'] += 1
            return original_small(path, *values, **options)
        def digest(raw):
            if raw in targets:
                counts['response_hashes'] += 1
                counts['response_hash_bytes'] += len(raw)
            return original_digest(raw)
        with patch.object(helper, 'small', side_effect=small), patch.object(helper, 'digest', side_effect=digest):
            if run(helper, 1) != expected[:1]:
                raise AssertionError('Instrumented HTTP archive parity differs')
        census.append(dict(arm=name, **counts))
    response_bytes = sum(len(batch['response'].encode()) for _,batch in pairs)
    if census != [dict(arm=name, receipt_reads=n*32, response_hashes=n*32, response_hash_bytes=n*response_bytes)
                   for name,n in (('baseline',2),('candidate',1))]:
        raise AssertionError('Retained HTTP duplicate-operation census differs')
    errors = []
    for mutation in ('response-bytes', 'request-titles', 'source-receipt'):
        source, batch = copy.deepcopy(pairs[0])
        if mutation == 'response-bytes': batch['response'] += ' '
        elif mutation == 'request-titles': batch['requests'][0] += 'changed'
        else: source['batch']['accepted_receipt'] = 'file-metadata.response-999999-01.receipt.json'
        observed = []
        for helper in (baseline,candidate):
            try: run(helper,1,[(source,batch)])
            except Exception as error: observed.append((type(error).__name__,str(error)))
            else: raise AssertionError('Mismatched retained HTTP frame accepted')
        if observed[0] != observed[1]:
            raise AssertionError('Retained HTTP error parity differs')
        errors.append(dict(mutation=mutation,error=observed[0]))
    rows = []
    for name,helper in (('baseline',baseline),('candidate',candidate),('candidate',candidate),('baseline',baseline)):
        gc.collect()
        wall,cpu = time.perf_counter_ns(),time.process_time_ns()
        result = run(helper)
        cpu,wall = time.process_time_ns()-cpu,time.perf_counter_ns()-wall
        rows.append(dict(arm=name,cpu_ns=cpu,wall_ns=wall))
        if result != expected:
            raise AssertionError('Timed retained HTTP archive parity differs')
        del result
    if pairs != snapshots or physical(origin) != selection['origin_stamp']:
        raise AssertionError('Retained HTTP task inputs changed')
    if (physical(namespace_path) != namespace_stamp or namespace_path.read_bytes() != namespace or
            bounded_rows(raw_path,raw_selection['raw_stamp'],raw_rows) != raw_records or
            bounded_rows(request_path,request_selection['stamp'],request_selection['rows']) != source_records):
        raise AssertionError('Retained HTTP frame/namespace input changed')
    for row in selection['http_files']:
        path = Path(row['path'])
        if physical(path) != row['stamp'] or path.read_bytes() != originals[path] or physical(path) != row['stamp']:
            raise AssertionError('Retained original HTTP evidence changed')
    return dict(scope='32 authentic full-metadata FR frames with original request/receipt evidence through ordinary flat HTTP replay_source and archive handoff; 32 independent walks per CPU arm. Contained-origin dispatch and full tuple are outside clocks; no whole-edition claim.',
        operations=operations,frames_per_operation=32,request_titles=1600,response_bytes_per_operation=response_bytes,
        parity=True,input_after=True,semantic_provider_parity=True,census=census,error_parity=errors,rows=rows)




class CompleteParentBatchSingleReadTests(unittest.TestCase):
    fresh = CompleteSelectionDocumentTests.fresh

    def test_replay_checks_parent_once_per_batch_without_repeating_cold_verification(self):
        fixture, args, _, _ = self.fresh()
        root = args.output
        expected = list(figure.stream_values(root / figure.ROLES['figure-sizing-raw'], figure.RAW_STREAM_SCHEMA))[1:]
        manifest = json.loads((root / figure.MANIFEST).read_bytes())
        cache, inventory = {}, {}
        original = figure.read_complete_capture
        with patch.object(figure, 'read_complete_capture', wraps=original) as read, \
                patch.object(figure, 'verify', wraps=figure.verify) as verify:
            for number, batch in enumerate(expected):
                reference = dict(kind='complete-stream', path=str(root / figure.MANIFEST),
                                 sha256=figure.digest((root / figure.MANIFEST).read_bytes()), batch=number)
                self.assertEqual(figure.replay_source(fixture.root / 'destination', reference, batch,
                    fixture.wiki, fixture.date, fixture.namespace.read_bytes(), set(), cache,
                    inventory_cache=inventory), {})
            self.assertEqual(read.call_count, len(expected))
            self.assertEqual(verify.call_count, 1)
        self.assertTrue(cache and inventory)
        self.assertEqual(manifest, json.loads((root / figure.MANIFEST).read_bytes()))
        figure.check_prefix_cache(cache)
        figure.check_inventory_replay_cache(inventory)

    def test_replay_single_parent_read_retains_cached_mutation_and_context_refusals(self):
        for mutation in ('member', 'manifest', 'marker', 'raw', 'raw-replacement'):
            fixture, args, _, _ = self.fresh()
            root = args.output
            cache, inventory = {}, {}
            complete = figure.read_complete_capture(root / figure.MANIFEST, cache,
                inventory_cache=inventory, include_document=False)
            reference = dict(kind='complete-stream', path=str(root / figure.MANIFEST),
                             sha256=complete['manifest_sha256'], batch=0)
            batch = figure.complete_stream_batch(reference, cache)
            with self.subTest(mutation=mutation):
                with self.assertRaises(ValueError):
                    figure.replay_source(fixture.root / 'destination', reference, batch,
                        'foreignwiktionary', fixture.date, fixture.namespace.read_bytes(), set(), cache,
                        inventory_cache=inventory)
                if mutation == 'member':
                    (root / 'unexpected.txt').write_bytes(b'new member')
                elif mutation == 'raw-replacement':
                    raw = root / figure.ROLES['figure-sizing-raw']
                    replacement = fixture.root / 'same-byte-raw'
                    replacement.write_bytes(raw.read_bytes())
                    replacement.replace(raw)
                else:
                    name = {'manifest': figure.MANIFEST, 'marker': figure.COMPLETE,
                            'raw': figure.ROLES['figure-sizing-raw']}[mutation]
                    path = root / name
                    data = path.read_bytes()
                    path.write_bytes(data[:-1] + bytes([data[-1] ^ 1]))
                with patch.object(figure, 'verify', side_effect=AssertionError('Cached mutation reparsed')):
                    with self.assertRaises(ValueError):
                        figure.replay_source(fixture.root / 'destination', reference, batch,
                            fixture.wiki, fixture.date, fixture.namespace.read_bytes(), set(), cache,
                            inventory_cache=inventory)


class FigureHttpSingleTraversalTests(unittest.TestCase):
    setUp = FigureStreamDigestTests.setUp

    def verify_counted(self, fused, *, indexed=False):
        original = figure.stream_values
        calls = []
        def values(path, schema, **options):
            if Path(path) == self.raw and schema == figure.RAW_STREAM_SCHEMA:
                calls.append((path, options))
            return original(path, schema, **options)
        index = {} if indexed else None
        with contextlib.ExitStack() as stack:
            stack.enter_context(patch.object(figure, 'stream_values', side_effect=values))
            if not fused:
                stack.enter_context(patch.object(figure, '_HttpBatchReplay', return_value=None))
            result = figure.verify(self.args.output, _raw_index_out=index)
        return result, index, len(calls)

    def test_http_single_stream_matches_two_pass_manifest_index_and_full_tuple(self):
        before, old_index, old_calls = self.verify_counted(False, indexed=True)
        after, new_index, new_calls = self.verify_counted(True, indexed=True)
        self.assertEqual(before, after)
        self.assertEqual(old_index, new_index)
        self.assertEqual((old_calls, new_calls), (2, 1))
        with patch.object(figure, '_HttpBatchReplay', return_value=None):
            old_tuple = figure.verify_tuple(self.paths, self.fixture.wiki, self.fixture.date)
        self.assertEqual(old_tuple, figure.verify_tuple(self.paths, self.fixture.wiki, self.fixture.date))

    def test_http_single_stream_keeps_outer_projection_error_before_http_error(self):
        projection = self.paths['figure-sizing']
        raw = projection.read_bytes()
        lines = raw.splitlines(keepends=True)
        header = json.loads(lines[0]); header['raw_sha256'] = '0' * 64
        projection.write_bytes(figure.stream_encoded(header) + b''.join(lines[1:]))
        try:
            for fused, expected_calls in ((False, 0), (True, 1)):
                with self.subTest(fused=fused), contextlib.ExitStack() as stack:
                    if not fused:
                        stack.enter_context(patch.object(figure, '_HttpBatchReplay', return_value=None))
                    replay = stack.enter_context(patch.object(figure, 'replay_source', side_effect=ValueError('first HTTP failure')))
                    with self.assertRaisesRegex(ValueError, 'projection stream header differs from exact raw replay'):
                        figure.verify(self.args.output)
                    self.assertEqual(replay.call_count, expected_calls)
        finally:
            projection.write_bytes(raw)

    def test_http_single_stream_keeps_inventory_error_before_http_error(self):
        for fused, expected_calls in ((False, 0), (True, 1)):
            with self.subTest(fused=fused), contextlib.ExitStack() as stack:
                if not fused:
                    stack.enter_context(patch.object(figure, '_HttpBatchReplay', return_value=None))
                replay = stack.enter_context(patch.object(figure, 'replay_source', side_effect=ValueError('first HTTP failure')))
                stack.enter_context(patch.object(figure, 'verify_inventory', side_effect=ValueError('outer SQL failure')))
                with self.assertRaisesRegex(ValueError, '^outer SQL failure$'):
                    figure.verify(self.args.output)
                self.assertEqual(replay.call_count, expected_calls)

    def test_http_single_stream_preserves_source_failure_and_raw_eof_priority(self):
        for fused in (False, True):
            with self.subTest(fused=fused), contextlib.ExitStack() as stack:
                if not fused:
                    stack.enter_context(patch.object(figure, '_HttpBatchReplay', return_value=None))
                stack.enter_context(patch.object(figure, 'replay_source', side_effect=ValueError('first HTTP failure')))
                with self.assertRaisesRegex(ValueError, '^first HTTP failure$'):
                    figure.verify(self.args.output)
        self.raw.write_bytes(self.original + b'\n')
        try:
            for fused in (False, True):
                with self.subTest(trailing=fused), contextlib.ExitStack() as stack:
                    if not fused:
                        stack.enter_context(patch.object(figure, '_HttpBatchReplay', return_value=None))
                    stack.enter_context(patch.object(figure, 'replay_source', side_effect=ValueError('first HTTP failure')))
                    with self.assertRaisesRegex(ValueError, 'Trailing Figure stream records or bytes'):
                        figure.verify(self.args.output)
        finally:
            self.raw.write_bytes(self.original)

    def test_http_single_stream_rejects_late_raw_mutation_without_publishing_digest(self):
        original_inventory = figure.verify_inventory
        for fused in (False, True):
            with self.subTest(fused=fused), contextlib.ExitStack() as stack:
                self.raw.write_bytes(self.original)
                if not fused:
                    stack.enter_context(patch.object(figure, '_HttpBatchReplay', return_value=None))
                def changed(*values, **options):
                    result = original_inventory(*values, **options)
                    self.raw.write_bytes(self.original + b'changed')
                    return result
                stack.enter_context(patch.object(figure, 'verify_inventory', side_effect=changed))
                with self.assertRaises((ValueError, StopIteration)):
                    figure.verify(self.args.output)
        self.raw.write_bytes(self.original)

    def test_http_single_stream_falls_back_for_light_source_and_retains_no_response_graph(self):
        journal = self.args.output / figure.FILE_REQUESTS
        raw = journal.read_bytes(); lines = raw.splitlines(keepends=True)
        source = json.loads(lines[1]); source['kind'] = 'http-archived-light'
        journal.write_bytes(lines[0] + figure.stream_encoded(source) + b''.join(lines[2:]))
        try:
            original = figure.stream_values
            calls = []
            def values(path, schema, **options):
                if Path(path) == self.raw and schema == figure.RAW_STREAM_SCHEMA: calls.append(path)
                return original(path, schema, **options)
            with patch.object(figure, 'stream_values', side_effect=values):
                with self.assertRaises(ValueError):
                    figure.verify(self.args.output)
            self.assertEqual(len(calls), 2)
        finally:
            journal.write_bytes(raw)
        states = []
        original_consume = figure._HttpBatchReplay.consume
        def consume(state, header, batch):
            original_consume(state, header, batch)
            self.assertIsNone(state.error)
            self.assertTrue(all(set(summary) == {'requests'} for summary, _, _ in state.frames))
            self.assertTrue(all('response' not in source for _, source, _ in state.frames))
            states.append(len(state.frames))
        with patch.object(figure._HttpBatchReplay, 'consume', consume):
            figure.verify(self.args.output)
        self.assertTrue(states)

    def test_http_single_stream_malformed_plan_does_not_preempt_outer_failure(self):
        plan = self.args.output / figure.PLAN
        saved = plan.read_bytes()
        try:
            for value in ([], None, 'not an object', 3):
                plan.write_bytes(figure.encoded(value))
                for fused in (False, True):
                    with self.subTest(value=value, fused=fused), contextlib.ExitStack() as stack:
                        if not fused:
                            stack.enter_context(patch.object(figure, '_HttpBatchReplay', return_value=None))
                        stack.enter_context(patch.object(figure, 'verify_inventory', side_effect=ValueError('outer SQL failure')))
                        with self.assertRaisesRegex(ValueError, '^outer SQL failure$'):
                            figure.verify(self.args.output)
        finally:
            plan.write_bytes(saved)

if __name__ == '__main__':
    unittest.main()
