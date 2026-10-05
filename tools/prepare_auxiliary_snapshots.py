#!/usr/bin/env python3
"""Prepare verified offline category/interwiki snapshots from dated captures.

One edition at a time; publish completion last. Use the corpus resource wrapper
when running this across the full inventory. SQLite remains disposable scratch.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import sqlite3
import subprocess
import sys
import time
from types import SimpleNamespace
import category_stats_snapshot as stats
import category_tree_snapshot as tree
from download_wiktionaries import render_interwiki_map, validate_item


def sha(path):
    with path.open('rb') as stream:return hashlib.file_digest(stream,'sha256').hexdigest()


def put(path, data):
    if path.exists():
        if path.read_bytes()!=data:raise ValueError(f'Existing snapshot differs: {path}')
        return
    part=path.with_name(path.name+'.part')
    with part.open('xb') as stream:stream.write(data);stream.flush();os.fsync(stream.fileno())
    os.replace(part,path)


def document(path, value):
    put(path,(json.dumps(value,sort_keys=True,indent=2)+'\n').encode())


def verify_sql(manifest, downloads, wiki, date, table):
    name=f'{wiki}-{date}-{table}.sql.gz'
    matches=[r for r in manifest['files'] if r.get('wiki')==wiki and r.get('date')==date and r.get('name')==name]
    if len(matches)!=1:raise ValueError(f'Missing/ambiguous source {name}')
    record=matches[0];validate_item(record)
    path=downloads/wiki/date/name
    size,sha1,sha256=stats.fingerprint(path)
    if size!=record['size'] or sha1!=record['sha1']:raise ValueError(f'Unverified SQL: {path}')
    return path,dict(record,sha256=sha256)


def interwiki(capture, record):
    raw=(capture/'namespace-siteinfo.raw.json').read_bytes()
    if hashlib.sha256(raw).hexdigest()!=record['artifacts']['namespace-siteinfo.raw.json']:raise ValueError('Changed captured API')
    data=json.loads(raw)
    if data.get('query',{}).get('general',{}).get('wikiid')!=record['wiki']:raise ValueError('Interwiki edition mismatch')
    tsv,count=render_interwiki_map(data)
    provenance={'wiki':record['wiki'],'kind':'current-siteinfo-interwikimap','retrieved_utc':record['retrieved_utc'],
        'source_url':record['siteinfo_source_url'],'rows':count,'raw_bytes':len(raw),'raw_sha256':hashlib.sha256(raw).hexdigest(),
        'tsv_bytes':len(tsv),'tsv_sha256':hashlib.sha256(tsv).hexdigest(),'dump_date':None,
        'transcludability_note':'Missing API trans flags are represented as false'}
    put(capture/'interwiki-map.raw.json',raw)
    put(capture/'interwiki-map.tsv',tsv)
    document(capture/'interwiki-map.provenance.json',provenance)
    return count


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--manifest',type=Path,required=True)
    p.add_argument('--downloads',type=Path,required=True)
    p.add_argument('--scratch',type=Path,required=True)
    p.add_argument('--project',type=Path,default=Path('.'))
    p.add_argument('--category-tree',action='store_true')
    p.add_argument('--wikis',nargs='*')
    args=p.parse_args()
    manifest=json.loads(args.manifest.read_text())
    roots=manifest['auxiliary_capture_roots']
    scripts=[Path(__file__),Path(stats.__file__),Path(tree.__file__),Path(__file__).with_name('download_wiktionaries.py')]
    producer={path.name:sha(path) for path in scripts}
    args.scratch.mkdir(parents=True,exist_ok=True)
    results=[]
    failures=[]
    for wiki,raw_root in sorted(roots.items()):
        if args.wikis and wiki not in args.wikis:continue
        start=time.monotonic()
        result={'wiki':wiki,'status':'failed'}
        try:
            if Path(raw_root).is_absolute() or '..' in Path(raw_root).parts:raise ValueError('Unsafe capture root')
            capture=args.project/raw_root
            record=json.loads((capture/'capture.complete.json').read_text())
            date=record['date']
            if record['wiki']!=wiki:raise ValueError('Capture identity mismatch')
            xml=capture/'dump-siteinfo.xml'
            if sha(xml)!=record['artifacts']['dump-siteinfo.xml']:raise ValueError('Changed captured XML')
            if record['source_xml'] not in manifest['files']:raise ValueError('Captured XML is not in dated inventory')
            result['interwiki_rows']=interwiki(capture,record)
            category_source,_=verify_sql(manifest,args.downloads,wiki,date,'category')
            output=capture/'category-stats.tsv';provenance=capture/'category-stats.manifest.json'
            if output.exists() or provenance.exists():
                old=json.loads(provenance.read_text())
                if old.get('output_sha256')!=sha(output) or old.get('source_sha256')!=sha(category_source) or old.get('generator_sha256')!=producer[Path(stats.__file__).name] or old.get('parser_sha256')!=producer[Path(tree.__file__).name]:raise ValueError('Existing category stats identity differs')
            else:
                stats.build(SimpleNamespace(category_sql=category_source,download_manifest=args.manifest,wiki=wiki,date=date,output=output,output_manifest=provenance))
            result['category_rows']=json.loads(provenance.read_text())['rows']
            if args.category_tree:
                sources={};paths={}
                for table in ('page','linktarget','categorylinks'):
                    paths[table],sources[table]=verify_sql(manifest,args.downloads,wiki,date,table)
                output=capture/'category-tree.tsv';provenance=capture/'category-tree.manifest.json'
                expected={'wiki':wiki,'date':date,'sources':sources,'dump_siteinfo_sha256':sha(xml),'producer':producer,
                    'ordering_policy':'target,kind,sortkey,from_id; first 200 per main/pages scope'}
                if output.exists() or provenance.exists():
                    old=json.loads(provenance.read_text())
                    if any(old.get(k)!=v for k,v in expected.items()) or old.get('output_sha256')!=sha(output):raise ValueError('Existing category tree identity differs')
                else:
                    if shutil.disk_usage(args.scratch).free<4*1024**3:raise ValueError('Insufficient scratch disk headroom')
                    scratch=args.scratch/(wiki+'-'+date)
                    scratch.mkdir(exist_ok=False)
                    database=scratch/'category-tree.sqlite'
                    temporary=scratch/'category-tree.tsv'
                    subprocess.run([sys.executable,'-B',str(Path(tree.__file__)),
                        '--xml',str(xml),'--page',str(paths['page']),'--linktarget',str(paths['linktarget']),
                        '--categorylinks',str(paths['categorylinks']),'--database',str(database),'--output',str(temporary)],check=True)
                    db=sqlite3.connect('file:'+str(database)+'?mode=ro',uri=True)
                    try:expected['input_rows']={name:db.execute('SELECT count(*) FROM '+name).fetchone()[0] for name in ('pages','targets','links')}
                    finally:db.close()
                    expected.update(output_sha256=sha(temporary),output_bytes=temporary.stat().st_size)
                    with temporary.open('rb') as stream:expected['scope_rows']=sum(1 for _ in stream)
                    if {path.name:sha(path) for path in scripts}!=producer:raise ValueError('Producer changed during generation')
                    # Publish a completed derived file, then provenance. Discovery
                    # must require the pair; an orphan is never a reusable success.
                    os.replace(temporary,output)
                    document(provenance,expected)
                    database.unlink()
                    scratch.rmdir()
                result['category_tree_scope_rows']=json.loads(provenance.read_text())['scope_rows']
            if {path.name:sha(path) for path in scripts}!=producer:raise ValueError('Producer changed during generation')
            marker={'wiki':wiki,'date':date,'producer':producer,'category_tree':args.category_tree,
                    'artifacts':{name:sha(capture/name) for name in ('category-stats.tsv','category-stats.manifest.json','interwiki-map.tsv','interwiki-map.raw.json','interwiki-map.provenance.json')}}
            if args.category_tree:marker['artifacts'].update({name:sha(capture/name) for name in ('category-tree.tsv','category-tree.manifest.json')})
            document(capture/('auxiliary-all.complete.json' if args.category_tree else 'auxiliary-basic.complete.json'),marker)
            result['status']='complete'
        except Exception as error:
            result['error']=str(error);failures.append(wiki)
        result['seconds']=round(time.monotonic()-start,3)
        results.append(result)
        print(json.dumps(result),flush=True)
    report={'producer':producer,'requested':len(results),'complete':sum(r['status']=='complete' for r in results),'failed':failures,'results':results}
    document(args.scratch/('all-results.json' if args.category_tree else 'basic-results.json'),report)
    if failures:raise SystemExit(f'{len(failures)} auxiliary editions failed')

if __name__=='__main__':main()
