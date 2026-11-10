import argparse
import copy
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
            self.assertEqual(replay.call_count, 1)
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
            self.assertGreaterEqual(full.call_count, 3)
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
            # Both full content guards remain; member-name checking adds none.
            self.assertEqual(payload.call_count, 2)

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
            with self.assertRaisesRegex(ValueError, 'Figure capture differs from source replay'):
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

if __name__ == '__main__':
    unittest.main()
