import argparse
from pathlib import Path
import unittest
from unittest.mock import patch

import prepare_figure_metadata as figure
from test_prepare_figure_files import FigureFileTests


class CurrentSqlImageInfoTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        path = Path(__file__).parent/'testdata/current-file-observations/sh-sa-current.json.zst'
        cls.cases = figure.decode(figure.zstd.decompress(path.read_bytes()))

    def test_ordinary_current_capture_materialization_and_relocation(self):
        for wiki, case in self.cases.items():
            with self.subTest(wiki=wiki):
                inputs = FigureFileTests()
                inputs.setUp()
                self.addCleanup(inputs.doCleanups)
                inputs.wiki, inputs.date = wiki, '20261001'
                inputs.namespace.write_bytes(case['namespace'].encode())
                defaults = argparse.Namespace(wiki=wiki, date=inputs.date, namespace_registry=inputs.namespace,
                    primary_sources=inputs.primary, output=inputs.root/'own-defaults', delay=0,
                    wall_seconds=30, figure_defaults=True)
                envelope = figure.decode(case['selected_defaults'])
                with patch.object(figure.evidence, 'utc', return_value=envelope['retrieved_utc']):
                    figure.site_info.capture(defaults, transport=lambda *_: (200, {}, case['site_response'].encode()))
                self.assertEqual((defaults.output/figure.site_info.SNAPSHOT).read_text(), case['selected_defaults'])
                names = [title.split(':', 1)[1].replace(' ', '_').replace('\\','\\\\').replace("'", "\\'")
                         for title in case['batch']['requests']]
                args = inputs.args(links=names)
                args.defaults, args.figure_profile = defaults.output, figure.FIGURE_PROFILE_V4
                def transport(url, timeout):
                    from urllib.parse import parse_qs, urlsplit
                    self.assertEqual(parse_qs(urlsplit(url).query)['titles'], ['|'.join(case['batch']['requests'])])
                    return 200, {}, case['batch']['response'].encode()
                actual = figure.capture_files(args, transport=transport)
                self.assertEqual(inputs.stream_document(args.output)['records'], case['records'])
                output = inputs.root/'self-contained'
                figure.materialize_complete_capture(args.output/figure.MANIFEST, output, max_batches=1)
                args.output.rename(inputs.root/'original-unavailable')
                self.assertEqual(figure.verify(output)['coverage'], actual['coverage'])

    def test_scope_and_registered_media_refusals(self):
        for wiki, case in self.cases.items():
            with self.subTest(wiki=wiki):
                site = case['batch']['response'].encode()
                def rows(batch=None, *, namespace=case['namespace'], date='20261001', kind=figure.FIGURE_PROFILE_V4,
                         v6=True, header=site):
                    return figure.file_records([case['batch'] if batch is None else batch],namespace.encode(),
                        wiki,date,header,has_batches=True,record_limit=50,profile_kind=kind,
                        allow_compatible_epochs=True,current_file_supplements=v6)
                self.assertEqual(rows()['records'],case['records'])
                for options in ({'date':'20261002'},{'namespace':case['namespace']+'\n'},
                                {'kind':figure.FIGURE_PROFILE_V5},{'v6':False}):
                    with self.assertRaises(ValueError):
                        rows(**options)
                for field,value in (('observed_svg_width_px',250),('observed_svg_occurrences',[]),
                                    ('jpeg_metadata_only',True),('tiff_metadata_response',site.decode())):
                    with self.assertRaises(ValueError):
                        rows(dict(case['batch'],**{field:value}))
                for scope in ('generator','registration','epoch'):
                    data = figure.decode(site)
                    if scope == 'registration':
                        item = next(x for x in data['query']['extensions'] if x['name']=='TimedMediaHandler')
                        item['vcs-version'] = '0'*40
                    else:
                        key = 'generator' if scope == 'generator' else 'git-hash'
                        data['query']['general'][key] = 'changed' if scope=='generator' else figure.site_info.FIGURE_WMF5_CORE
                    with self.assertRaises(ValueError):
                        rows(dict(case['batch'],response=figure.encoded(data).decode()))
                other_wiki = next(w for w in self.cases if w!=wiki)
                date='20261001'
                plan = {'wiki':wiki,'date':date,'figure_profile':figure.FIGURE_PROFILE_V4,
                    'namespace_registry_sha256':figure.digest(case['namespace'].encode()),
                    'defaults':{figure.site_info.SNAPSHOT:figure.digest(case['selected_defaults'].encode())},
                    'query_inputs':[],'observed_batches':0,'observed':[],'replay_contract':figure.REPLAY_CONTRACT}
                self.assertTrue(figure.current_sql_file_plan(plan))
                for change in ({'date':'20261002'},{'wiki':other_wiki},{'metadata_mode':'lean-tiff-v1'},
                        {'replay_contract':figure.REPLAY_CONTRACT_V4},{'query_inputs':[{}]},
                        {'observed':[{}]},{'observed_batches':1},{'defaults':{}},
                        {'observed_defaults_response_sha256':figure.digest(case['site_response'].encode())}):
                    self.assertFalse(figure.current_sql_file_plan(dict(plan,**change)))
                raw=case['site_response'].encode()
                value=figure.decode(raw)
                for wrong_wiki, wrong_date, profile in [(other_wiki,date,figure.site_info.FIGURE_PROFILE),
                        (wiki,'20261002',figure.site_info.FIGURE_PROFILE),(wiki,date,figure.site_info.PROFILE)]:
                    with self.assertRaises(ValueError):
                        figure.site_info.response(value,wrong_wiki,wiki.removesuffix('wiktionary'),profile,
                            raw_sha=figure.digest(raw),date=wrong_date)
