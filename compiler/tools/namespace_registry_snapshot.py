#!/usr/bin/env python3
"""Create an edition-local namespace registry from a verified capture.

Dated XML IDs/names/case are checked against the captured current API. Additional
API properties remain explicitly current-at-retrieval, not historical evidence.
Unclassified custom subject namespaces are retained as supplemental pages.
"""
import argparse
import hashlib
import json
import os
import xml.etree.ElementTree as ET
from pathlib import Path

HEADER = '# wikidict-namespace-registry-v1'
POLICY_VERSION = 1
# An edition ID plus the expected localized name is the admission proof.
# Other lexical subject namespaces remain available as supplemental records.
FEATURES = {
    'enwiktionary': {106:('Rhymes','rhymes'),110:('Thesaurus','thesaurus'),114:('Citations','citations'),116:('Sign gloss','sign_gloss'),118:('Reconstruction','reconstruction')},
    'frwiktionary': {106:('Thésaurus','thesaurus'),110:('Reconstruction','reconstruction'),114:('Rime','rhymes')},
    'dewiktionary': {104:('Thesaurus','thesaurus'),106:('Reim','rhymes'),110:('Rekonstruktion','reconstruction')},
    'eswiktionary': {110:('Tesauro','thesaurus')},
}

def field(value):
    if not isinstance(value,str) or any(c in value for c in '\t\r\n\0') or len(value.encode())>1024:
        raise ValueError('Invalid namespace field')
    return value

def flag(row,name,default=False):
    value=row.get(name,default)
    if type(value) is not bool:raise ValueError('Invalid namespace flag '+name)
    return '1' if value else '0'

def disposition(wiki,row):
    ns=row['id'];name=row.get('name',row.get('*',''));canonical=row.get('canonical',name)
    if ns==0:return 'main','dictionary_entries'
    if ns<0:return 'compile_only','virtual_namespace'
    # Subject/talk pairing is the existing MediaWiki namespace-ID convention;
    # it supplies no lexical feature classification for subject namespaces.
    if ns%2:return 'compile_only','discussion_namespace'
    if ns in (2,4,6,8,10,12,14,828):return 'compile_only','standard_build_input'
    if row.get('defaultcontentmodel')=='flow-board':return 'compile_only','discussion_storage'
    if (ns,canonical) in ((90,'Thread'),(92,'Summary'),(1728,'Event'),(710,'TimedText')):
        return 'compile_only','ancillary_site_input'
    proof=FEATURES.get(wiki,{}).get(ns)
    if proof is not None:
        expected,kind=proof
        if name!=expected:raise ValueError(f'Namespace semantic policy changed: {wiki} {ns}: {name!r} != {expected!r}')
        return kind,'verified_edition_feature'
    return 'supplemental','unclassified_subject_retained'

def render(wiki,date,api,inventory):
    general=api.get('general',{})
    if general.get('wikiid')!=wiki:raise ValueError('Edition mismatch')
    namespaces=api.get('namespaces');aliases=api.get('namespacealiases')
    if not isinstance(namespaces,dict) or not isinstance(aliases,list):raise ValueError('Missing namespace capture')
    byid={}
    for key,raw in namespaces.items():
        if not isinstance(raw,dict) or type(raw.get('id')) is not int:raise ValueError('Invalid namespace row')
        ns=raw['id']
        if str(ns)!=key or not -2147483648<=ns<=2147483647:raise ValueError('Invalid namespace ID/key')
        if ns in byid:raise ValueError('Duplicate namespace ID')
        byid[ns]=raw
    if 0 not in byid or 10 not in byid or 14 not in byid:raise ValueError('Missing required standard namespaces')
    dated={}
    for record in inventory:
        ns=record['id']
        if type(ns) is not int or ns in dated:raise ValueError('Invalid or duplicate dated namespace ID')
        dated[ns]=record
    if not dated or set(dated)!=set(byid):raise ValueError('Dated XML and API namespace ID sets disagree')
    for record in inventory:
        actual=byid.get(record['id'])
        if actual is None or actual.get('name',actual.get('*',''))!=record['name'] or actual.get('case')!=record['case']:
            raise ValueError('Dated XML and current namespace capture disagree')
    alias_by_id={ns:[] for ns in byid}
    for row in aliases:
        if not isinstance(row,dict) or type(row.get('id')) is not int or row['id'] not in byid:raise ValueError('Invalid namespace alias target')
        name=field(row.get('alias',row.get('*')))
        if not name:raise ValueError('Empty namespace alias')
        alias_by_id[row['id']].append(name)
    for row in byid.values():
        for name in (row.get('name',row.get('*','')),row.get('canonical',row.get('name',row.get('*',''))),*alias_by_id[row['id']]):
            field(name)
            if any(c in name for c in ':#[]{}|<>') or any(ord(c)<32 or ord(c)==127 for c in name):raise ValueError('Invalid namespace prefix')
    lines=[HEADER,'# wiki\t'+field(wiki),'# dump-date\t'+field(date),'# content-language\t'+field(general.get('lang',''))]
    roles={}
    for ns,row in sorted(byid.items()):
        name=field(row.get('name',row.get('*','')));canonical=field(row.get('canonical',name))
        if (ns==0)!=(name==''):raise ValueError('Invalid main namespace name')
        case=row.get('case')
        if case not in ('first-letter','case-sensitive'):raise ValueError('Unknown namespace case policy')
        role,reason=disposition(wiki,row)
        roles[str(ns)]={'name':name,'role':role,'reason':reason}
        columns=[str(ns),name,canonical,case,flag(row,'subpages'),flag(row,'content'),flag(row,'nonincludable',ns<0),field(row.get('defaultcontentmodel','')),role,reason,*sorted(set(alias_by_id[ns]))]
        lines.append('\t'.join(columns))
    return ('\n'.join(lines)+'\n').encode(),roles

def build(capture):
    capture=Path(capture)
    record=json.loads((capture/'capture.complete.json').read_text())
    for name,digest in record['artifacts'].items():
        if hashlib.sha256((capture/name).read_bytes()).hexdigest()!=digest:raise ValueError('Changed captured artifact '+name)
    if record.get('namespace_mismatches'):raise ValueError('Unresolved namespace mismatch')
    api=json.loads((capture/'namespace-siteinfo.raw.json').read_text())['query']
    xml=ET.fromstring((capture/'dump-siteinfo.xml').read_bytes())
    site=xml.find('{*}siteinfo')
    if site is None or site.findtext('{*}dbname')!=record['wiki']:raise ValueError('Dated XML edition mismatch')
    inventory=[{'id':int(row.attrib['key']),'name':row.text or '', 'case':row.attrib['case']} for row in site.findall('{*}namespaces/{*}namespace')]
    if sorted(inventory,key=lambda r:r['id'])!=sorted(record['dump_namespace_inventory'],key=lambda r:r['id']):raise ValueError('Capture inventory differs from hashed XML')
    output,roles=render(record['wiki'],record['date'],api,inventory)
    policy=json.dumps({'version':POLICY_VERSION,'features':FEATURES,'generic_subject_policy':'retain supplemental','standard_input_ids':[2,4,6,8,10,12,14,828]},ensure_ascii=False,sort_keys=True).encode()
    manifest={'wiki':record['wiki'],'date':record['date'],'output_sha256':hashlib.sha256(output).hexdigest(),
              'raw_siteinfo_sha256':record['artifacts']['namespace-siteinfo.raw.json'],'dump_siteinfo_sha256':record['artifacts']['dump-siteinfo.xml'],
              'semantic_policy_sha256':hashlib.sha256(policy).hexdigest(),'generator_sha256':hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),'retrieved_utc':record['retrieved_utc'],'source_url':record['siteinfo_source_url'],
              'supplementary_api_scope':record['siteinfo_temporal_scope'],'source_dump_files':[record['source_xml']],'roles':roles}
    target=capture/'namespace-registry.tsv';provenance=capture/'namespace-registry.manifest.json'
    if target.exists() and target.read_bytes()!=output:raise ValueError('Existing registry differs; use a new capture/output directory')
    if provenance.exists() and json.loads(provenance.read_text())!=manifest:raise ValueError('Existing registry provenance differs; use a new capture/output directory')
    if target.exists() and provenance.exists():return manifest
    temp=target.with_suffix('.part');temp.write_bytes(output);os.replace(temp,target)
    temp=provenance.with_suffix('.part');temp.write_text(json.dumps(manifest,ensure_ascii=False,indent=2)+'\n');os.replace(temp,provenance)
    return manifest

if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('capture',type=Path)
    args=parser.parse_args(); result=build(args.capture)
    print(result['wiki'],result['output_sha256'])
