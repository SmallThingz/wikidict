import copy
import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock
import urllib.parse

import prepare_parser_function_facts as facts
from test_prepare_file_metadata import registry_bytes, present_page, absent_page

WIKI = 'arwiktionary'
DATE = '20261001'
TITLE = 'ملف:Example.svg'
GENERAL = {'wikiid':WIKI, 'lang':'ar', 'git-hash':facts.CORE}
SITE = facts.encoded({'query':{'general':GENERAL}})
FUNCTION_URL = '//upload.wikimedia.org/wikipedia/commons/a/ab/example.ogg?utm_campaign=api'


def observation(query, pages, **extra):
    query = dict(sorted(query.items()))
    request = dict(schema='wikidict.existing-metadata-transport-request.v1', wiki=WIKI, date=DATE,
                   expected_core=facts.CORE, query=query,
                   url=facts.evidence.wiktionary_api(WIKI)+'?'+urllib.parse.urlencode(query))
    raw = facts.encoded({'batchcomplete':True, 'query':dict(general=GENERAL, extensions=[], pages=pages, **extra)})
    receipt = dict(accepted=True, status=200, url=request['url'], request_count=1, core_revision=facts.CORE,
                   response='response01.raw.json', response_bytes=len(raw), response_sha256=facts.digest(raw))
    return facts.encoded(request), facts.encoded(receipt), raw, 'response01.raw.json'


def file_observation(titles=None, pages=None, **extra):
    return observation(dict(facts.FILE_QUERY, titles='|'.join(titles or [TITLE])), pages or [present_page(TITLE, 123, 45)], **extra)


def page_observation():
    return observation(dict(facts.PAGE_QUERY, revids='37'), [dict(title='Water', ns=0, pageid=9,
        revisions=[dict(revid=37, parentid=36, size=91234, timestamp='2026-10-01T01:02:03Z')])])


def function_observation(names=None, values=None):
    names = ['Example.svg'] if names is None else names
    values = [FUNCTION_URL] if values is None else values
    query = dict(facts.VALUE_QUERY, title='Water', text='\n'.join([facts.BEGIN,
        *(str(i)+'\t{{filepath:'+name+'}}' for i,name in enumerate(names)), facts.END]))
    query = dict(sorted(query.items()))
    authority = dict(kind='separate-observation-and-primary-source', revision=facts.CORE,
                     same_response_core_observed=False)
    request = dict(schema='wikidict.existing-metadata-transport-request.v1', wiki=WIKI, date=DATE,
        core_authority=authority, query=query,
        framing=dict(begin=facts.BEGIN,end=facts.END,separator='\n',field_separator='\t',
                     ordered_files=names,exact_lines=len(names)+2,trailing_newline=False),
        url=facts.evidence.wiktionary_api(WIKI)+'?'+urllib.parse.urlencode(query))
    raw = facts.encoded({'expandtemplates':{'wikitext':'\n'.join([facts.BEGIN,
        *(str(i)+'\t'+value for i,value in enumerate(values)),facts.END])}})
    receipt = dict(accepted=True,status=200,url=request['url'],request_count=1,
        core_authority=authority,same_response_core_observed=False,
        response='response01.raw.json',response_bytes=len(raw),response_sha256=facts.digest(raw))
    return facts.encoded(request),facts.encoded(receipt),raw,'response01.raw.json'


def replace_request(item, change):
    request, receipt = facts.decode(item[0]), facts.decode(item[1])
    change(request)
    request['query']=dict(sorted(request['query'].items()))
    request['url']=facts.evidence.wiktionary_api(WIKI)+'?'+urllib.parse.urlencode(request['query'])
    receipt['url']=request['url']
    return facts.encoded(request),facts.encoded(receipt),*item[2:]


def replace_response(item, change):
    request, receipt, raw, name = item
    data = facts.decode(raw); change(data); raw = facts.encoded(data)
    record = facts.decode(receipt); record.update(response_bytes=len(raw), response_sha256=facts.digest(raw))
    return request, facts.encoded(record), raw, name


class ParserFunctionFactsTests(unittest.TestCase):
    def project(self, observations):
        return facts.project(registry_bytes(), SITE, observations, WIKI, DATE)

    def inputs(self, root):
        source = root/'sources'; source.mkdir()
        namespace = source/'namespace.tsv'; namespace.write_bytes(registry_bytes())
        site = source/'site.json'; site.write_bytes(SITE)
        triples = []
        for i, item in enumerate((file_observation(), page_observation(), function_observation())):
            folder = source/str(i); folder.mkdir()
            paths = [folder/'request.json', folder/'receipt.json', folder/item[3]]
            for path, raw in zip(paths, item[:3]):path.write_bytes(raw)
            triples.append(tuple(paths))
        return namespace, site, triples

    def test_full_url_and_exact_revision_size_are_observed_without_derivation(self):
        value = self.project([file_observation(), page_observation(), function_observation()])
        self.assertEqual(value['schema'], facts.SCHEMA)
        self.assertEqual(value['files'], [dict(title=TITLE, canonical_title=TITLE, size_argument='',
            exists=True, url=FUNCTION_URL, sha1='a'*40)])
        self.assertEqual(value['pages'], [dict(title='Water', namespace=0, page_id=9, revision_id=37, size=91234)])
        self.assertEqual(value['formats'], [])
        self.assertEqual(value['namespace_sha256'], facts.digest(registry_bytes()))
        self.assertEqual(value['site_info_sha256'], facts.digest(SITE))

    def test_alias_and_explicit_negative_preserve_requested_keys(self):
        alias, missing = 'ملف:Alias.svg', 'ملف:Missing.svg'
        obs = file_observation([alias, missing], [present_page(TITLE), absent_page(missing)],
                               redirects=[dict(**{'from':alias, 'to':TITLE})])
        rows = {row['title']:row for row in self.project([obs,function_observation(['Alias.svg'])])['files']}
        self.assertEqual(rows[alias]['canonical_title'], TITLE)
        self.assertEqual(rows[missing], dict(title=missing, size_argument='', canonical_title='', exists=False, url='', sha1=''))
        for change in (lambda d:d['query']['pages'][1].pop('missing'),
                       lambda d:d['query']['pages'][1].update(imagerepository='unknown')):
            with self.assertRaises(ValueError):self.project([replace_response(obs, change)])

    def test_duplicate_alias_conflict_omission_and_hidden_file_refuse(self):
        with self.assertRaises(ValueError):self.project([file_observation(), file_observation()])
        for change in (lambda d:d['query'].update(pages=[]),
                       lambda d:d['query']['pages'][0]['imageinfo'][0].update(filehidden=True),
                       lambda d:d['query']['pages'][0]['imageinfo'][0].update(canonicaltitle='File:Different.svg'),
                       lambda d:d['query']['pages'][0]['imageinfo'][0].update(url='javascript:evil')):
            with self.subTest(change=change), self.assertRaises(ValueError):self.project([replace_response(file_observation(), change)])
        second = replace_response(file_observation(), lambda d:d['query']['pages'][0]['imageinfo'][0].update(sha1='b'*40))
        second=replace_request(second,lambda r:r['query'].update(titles='ملف:Alias.svg'))
        second=replace_response(second,lambda d:d['query'].update(redirects=[{'from':'ملف:Alias.svg','to':TITLE}]))
        with self.assertRaisesRegex(ValueError,'Conflicting canonical'):self.project([file_observation(),second])

    def test_builtin_value_is_required_and_preserved_without_url_rewriting(self):
        api=file_observation(); direct=function_observation()
        before=(api,direct)
        with self.assertRaisesRegex(ValueError,'observed builtin'):self.project([api])
        self.assertEqual(self.project([api,direct])['files'][0]['url'],FUNCTION_URL)
        self.assertEqual((api,direct),before)
        self.assertNotEqual(FUNCTION_URL,present_page(TITLE)['imageinfo'][0]['url'])
        for value in ('',FUNCTION_URL.replace('/a/ab/','/different/'),
                      FUNCTION_URL.replace('upload.wikimedia.org','example.org'),
                      'javascript:bad','//user:password@example.org/path'):
            with self.subTest(value=value),self.assertRaises(ValueError):
                self.project([api,function_observation(values=[value])])
        with self.assertRaisesRegex(ValueError,'Duplicate filepath value'):
            self.project([api,direct,direct])

    def test_builtin_exact_frame_no_options_and_false_core_boundary(self):
        api,direct=file_observation(),function_observation()
        output=facts.decode(direct[2])['expandtemplates']['wikitext']
        for value in (output+'\n',output+'extra',output.replace('0\t','1\t'),
                      output.replace(facts.END,'extra\n'+facts.END)):
            changed=replace_response(direct,lambda d:d['expandtemplates'].update(wikitext=value))
            with self.subTest(value=value),self.assertRaises(ValueError):self.project([api,changed])
        for name in ('Example.svg|250px','{{Example.svg}}','Example.svg|nowiki'):
            with self.subTest(name=name),self.assertRaises(ValueError):
                self.project([api,function_observation([name])])
        for change in (lambda r:r.update(core_revision=facts.CORE),
                       lambda r:r.update(same_response_core_observed=True),
                       lambda r:r.update(url='https://example.org/'),
                       lambda r:r.update(core_authority=dict(kind='invented'))):
            receipt=facts.decode(direct[1]);change(receipt)
            with self.assertRaises(ValueError):self.project([api,(direct[0],facts.encoded(receipt),*direct[2:])])
        for change in (lambda r:r['framing'].update(ordered_files=['Else.svg']),
                       lambda r:r['framing'].update(exact_lines=True),
                       lambda r:r['query'].update(text=r['query']['text']+'\n{{other}}')):
            with self.assertRaises(ValueError):self.project([api,replace_request(direct,change)])

    def test_literal_namespace_like_filename_and_ordered_multifile_values(self):
        second='ملف:File:Literal.svg'
        other_url=FUNCTION_URL.replace('example.ogg','literal.svg')
        page=present_page(second);page['imageinfo'][0]['url']='https:'+other_url
        api=file_observation([TITLE,second],[present_page(TITLE),page])
        direct=function_observation(['Example.svg','File:Literal.svg'],[FUNCTION_URL,other_url])
        rows={row['title']:row for row in self.project([api,direct])['files']}
        self.assertEqual(rows[second]['url'],other_url)
        self.assertEqual(rows[second]['canonical_title'],second)
        with self.assertRaises(ValueError):self.project([api,function_observation(
            ['Example.svg','File:Literal.svg'],[other_url,FUNCTION_URL])])

    def test_receipt_query_core_and_namespace_tampering_refuse(self):
        item=file_observation()
        for change in (lambda r:r.update(status=403),lambda r:r.update(response_sha256='0'*64),
                       lambda r:r.update(response='elsewhere.json'),lambda r:r.update(response_bytes=True)):
            receipt=facts.decode(item[1]);change(receipt)
            with self.assertRaises(ValueError):self.project([(item[0],facts.encoded(receipt),*item[2:])])
        for field,value in (('iiurlwidth','250'),('iiprop','url'),('titles',TITLE+'|'+TITLE)):
            request=facts.decode(item[0]);request['query'][field]=value
            request['url']=facts.evidence.wiktionary_api(WIKI)+'?'+urllib.parse.urlencode(request['query'])
            with self.assertRaises(ValueError):self.project([(facts.encoded(request),*item[1:])])
        for change in (lambda d:d['query']['general'].update(**{'git-hash':'0'*40}),
                       lambda d:d.update(error={'code':'maxlag'}),lambda d:d.update(**{'continue':{}})):
            with self.assertRaises(ValueError):self.project([replace_response(item,change)])
        with self.assertRaises(ValueError):facts.project(registry_bytes().replace(WIKI.encode(),b'huwiktionary'),SITE,[item],WIKI,DATE)

    def test_revision_selection_size_type_hidden_and_missing_fail_closed(self):
        for change in (lambda d:d['query']['pages'][0]['revisions'][0].update(revid=38),
                       lambda d:d['query']['pages'][0]['revisions'][0].update(size=True),
                       lambda d:d['query']['pages'][0]['revisions'][0].update(size=-1),
                       lambda d:d['query']['pages'][0]['revisions'][0].update(size=2**63),
                       lambda d:d['query']['pages'][0]['revisions'][0].update(texthidden=True),
                       lambda d:d['query']['pages'][0]['revisions'][0].pop('size'),
                       lambda d:d['query'].update(badrevids={'37':{'missing':True}})):
            with self.subTest(change=change),self.assertRaises(ValueError):self.project([replace_response(page_observation(),change)])
        with self.assertRaises(ValueError):self.project([page_observation(),page_observation()])

    def test_offline_publication_replays_complete_exact_evidence_and_parent_is_immutable(self):
        with tempfile.TemporaryDirectory()as tmp:
            root=Path(tmp);namespace,site,triples=self.inputs(root)
            before={p:p.read_bytes()for p in (root/'sources').rglob('*')if p.is_file()}
            with mock.patch.object(facts.evidence,'get_response',side_effect=AssertionError('No network')):
                record=facts.derive(namespace,site,triples,root/'derived',WIKI,DATE)
                self.assertEqual(facts.verify(root/'derived'),record)
                self.assertEqual(facts.validate_snapshot(root/'derived'/facts.OUTPUT,WIKI,DATE),record)
                artifacts=facts.capture_artifacts(root/'derived'/facts.OUTPUT,record)
            self.assertIn(facts.COMPLETE,artifacts)
            self.assertEqual(before,{p:p.read_bytes()for p in before})
            output=facts.decode((root/'derived'/facts.OUTPUT).read_bytes())
            self.assertEqual(output['pages'][0]['size'],91234)
            with self.assertRaises(ValueError):facts.derive(namespace,site,triples,root/'derived',WIKI,DATE)
            with self.assertRaises(ValueError):facts.derive(namespace,site,triples,triples[0][0].parent/'nested',WIKI,DATE)
            self.assertFalse((triples[0][0].parent/'nested').exists())

    def test_coherent_output_tamper_extra_artifact_and_incomplete_capture_refuse(self):
        for mode in ('output','extra','complete'):
            with self.subTest(mode=mode),tempfile.TemporaryDirectory()as tmp:
                root=Path(tmp);namespace,site,triples=self.inputs(root);out=root/'derived'
                facts.derive(namespace,site,triples,out,WIKI,DATE)
                if mode=='extra':(out/'unexpected').write_bytes(b'x')
                elif mode=='complete':(out/facts.COMPLETE).unlink()
                else:
                    value=facts.decode((out/facts.OUTPUT).read_bytes());value['pages'][0]['size']+=1
                    raw=facts.encoded(value);(out/facts.OUTPUT).write_bytes(raw)
                    m=facts.decode((out/facts.MANIFEST).read_bytes());m.update(output_bytes=len(raw),output_sha256=facts.digest(raw))
                    m['artifacts'][facts.OUTPUT]=dict(bytes=len(raw),sha256=facts.digest(raw))
                    encoded=facts.encoded(m);(out/facts.MANIFEST).write_bytes(encoded)
                    (out/facts.COMPLETE).write_bytes(facts.encoded(dict(schema=facts.CAPTURE_SCHEMA,manifest_sha256=facts.digest(encoded))))
                with self.assertRaises(FileNotFoundError if mode=='complete' else ValueError):facts.verify(out)

    def test_invalid_observation_does_not_publish_or_modify_inputs(self):
        with tempfile.TemporaryDirectory()as tmp:
            root=Path(tmp);namespace,site,triples=self.inputs(root)
            receipt=facts.decode(triples[0][1].read_bytes());receipt['accepted']=False
            triples[0][1].write_bytes(facts.encoded(receipt))
            before={p:p.read_bytes()for p in (root/'sources').rglob('*')if p.is_file()}
            with self.assertRaises(ValueError):facts.derive(namespace,site,triples,root/'derived',WIKI,DATE)
            self.assertFalse((root/'derived').exists());self.assertEqual(before,{p:p.read_bytes()for p in before})

    def test_strict_json_rejects_duplicate_and_nonfinite_fields(self):
        for raw in (b'{"size":1,"size":2}',b'{"size":NaN}',b'{"size":1e400}'):
            with self.assertRaises(ValueError):facts.decode(raw)


if __name__=='__main__':unittest.main()
