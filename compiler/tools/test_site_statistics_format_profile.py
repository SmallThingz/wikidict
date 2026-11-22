import copy
import importlib.util
from pathlib import Path
import unittest
spec=importlib.util.spec_from_file_location('profile',Path(__file__).with_name('prepare_site_statistics_format_profile.py'))
m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)

class ExactProfileTests(unittest.TestCase):
    def fixture(self):
        site=dict(schema='wikidict.site-info.v2',wiki='enwiktionary',date='20261001',content_language='en',
                  namespace_registry_sha256='a'*64,query=dict(general=dict(wikiid='enwiktionary',lang='en'),
                  statistics={key:1234567 for key in m.KEYS}))
        return site,m.configuration(site,'b'*64)
    def response(self,c,formatted='1,234,567'):
        lines=[m.BEGIN]
        for key in m.KEYS:lines.extend((key+'='+formatted,key+'-RAW='+c['raw'][key]))
        return dict(expandtemplates=dict(wikitext='\n'.join(lines+[m.END])))
    def test_exact_locale_strings_preserved(self):
        _,c=self.fixture()
        for value in ('1,234,567','1.234.567','1\u202f234\u202f567','۱٬۲۳۴٬۵۶۷','12,34,567'):
            with self.subTest(value=value):
                p=m.profile(c,self.response(c,value))
                self.assertEqual([x['formatted'] for x in p['values']],[value]*7)
                self.assertEqual(p['site_info_sha256'],'b'*64)
    def test_literal_requests_never_live_counter_magic(self):
        _,c=self.fixture();q=m.query(c)
        self.assertEqual(q['text'].count('{{formatnum:1234567}}'),7)
        self.assertEqual(q['text'].count('{{formatnum:1234567|R}}'),7)
        self.assertNotIn('NUMBEROF',q['text'])
    def test_zero_and_u53_exact(self):
        site,_=self.fixture()
        for n in (0,m.MAX_VALUE):
            site['query']['statistics']={key:n for key in m.KEYS}
            c=m.configuration(site,'b'*64)
            self.assertTrue(all(v==str(n) for v in c['raw'].values()))
            m.profile(c,self.response(c,str(n)))
    def test_bad_counts_refused(self):
        site,_=self.fixture()
        for bad in (True,-1,m.MAX_VALUE+1,1.0,'1',None):
            value=copy.deepcopy(site);value['query']['statistics']['pages']=bad
            with self.subTest(bad=bad),self.assertRaises(ValueError):m.configuration(value,'b'*64)
    def test_missing_key_and_wrong_site_refused(self):
        site,_=self.fixture();del site['query']['statistics']['admins']
        with self.assertRaises(ValueError):m.configuration(site,'b'*64)
        site,_=self.fixture();site['query']['general']['wikiid']='dewiktionary'
        with self.assertRaises(ValueError):m.configuration(site,'b'*64)
    def test_raw_substitution_refused(self):
        _,c=self.fixture();r=self.response(c)
        r['expandtemplates']['wikitext']=r['expandtemplates']['wikitext'].replace('pages-RAW=1234567','pages-RAW=1234568')
        with self.assertRaises(ValueError):m.profile(c,r)
    def test_order_and_framing_refused(self):
        _,c=self.fixture();r=self.response(c);lines=r['expandtemplates']['wikitext'].split('\n')
        lines[1],lines[3]=lines[3],lines[1];r['expandtemplates']['wikitext']='\n'.join(lines)
        with self.assertRaises(ValueError):m.profile(c,r)
        with self.assertRaises(ValueError):m.profile(c,dict(expandtemplates=dict(wikitext='')))
    def test_warning_and_unusable_output_refused(self):
        _,c=self.fixture();r=self.response(c);r['warnings']={}
        with self.assertRaises(ValueError):m.profile(c,r)
        for value in ('','x'*257,'<span>1</span>','1\t234','{{NUMBEROFPAGES}}'):
            with self.subTest(value=value),self.assertRaises(ValueError):m.profile(c,self.response(c,value))

if __name__=='__main__':unittest.main()
