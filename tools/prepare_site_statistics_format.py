"""Bounded capture lifecycle for the immutable pinned-statistics profile proposal."""
import argparse
import hashlib
import importlib.util
import json
import math
from pathlib import Path
import sys
import time
import urllib.parse

TOOLS = next(p / 'tools' for p in Path(__file__).resolve().parents if (p / 'tools/prepare_date_numbering.py').is_file())
sys.path.insert(0, str(TOOLS))
import prepare_date_numbering as date
e = date.evidence
spec = importlib.util.spec_from_file_location('format_profile', Path(__file__).with_name('prepare_site_statistics_format_profile.py'))
profile = importlib.util.module_from_spec(spec)
spec.loader.exec_module(profile)
OUTPUT = 'site-statistics-format.json'
MANIFEST = 'site-statistics-format.manifest.json'
COMPLETE = 'site-statistics-format.complete.json'
MAX_ARTIFACTS = 48
MAX_RESPONSE = 64 * 1024

def digest(raw): return hashlib.sha256(raw).hexdigest()
def read(path, bound=1024*1024): return e.small(Path(path), bound)
def document(path, value): e.document(Path(path), value)
def identity(data, cfg):
    general = date.clean_api(data).get('query', {}).get('general', {})
    if (general.get('wikiid') != cfg['wiki'] or general.get('lang') != cfg['content_language']
            or not isinstance(general.get('generator'), str) or not general['generator']):
        raise ValueError('Formatting server identity differs')
    return {key: general[key] for key in ('wikiid','lang','generator')}

def observe(root, number, cfg, query, parser, transport, sleep, delay, deadline):
    name = f'{number:02d}.request.json'
    url = e.wiktionary_api(cfg['wiki']) + '?' + urllib.parse.urlencode(query)
    if len(url.encode()) > 7168: raise ValueError('Request URL exceeds bound')
    document(root/name, dict(url=url,query=query))
    for attempt in range(1,5):
        remaining=deadline-time.monotonic()
        if remaining<=0: raise ValueError('Capture deadline reached')
        stem=f'{number:02d}-{attempt:02d}'
        receipt=dict(request=name,started_utc=e.utc(),accepted=False)
        retry=False;headers={}
        try:
            status,headers,raw=transport(url,min(30,remaining))
            if len(raw)>2*1024*1024+1:raise ValueError('Response transport exceeds bound')
            receipt.update(status=status,response=stem+'.raw.json',response_bytes=len(raw),response_sha256=digest(raw))
            e.put(root/receipt['response'],raw)
            if len(raw)>MAX_RESPONSE:raise ValueError('Response exceeds bound')
            if status!=200:
                retry=status in (429,500,502,503,504)
                raise ValueError('HTTP status '+str(status))
            data=e.decode(raw)
            if isinstance(data,dict) and isinstance(data.get('error'),dict):
                retry=data['error'].get('code') in ('maxlag','ratelimited','readonly')
            value=parser(data)
            if time.monotonic()>=deadline:raise ValueError('Capture deadline reached')
            receipt.update(accepted=True,ended_utc=e.utc())
            document(root/(stem+'.receipt.json'),receipt)
            return value,dict(request=name,receipt=stem+'.receipt.json')
        except (OSError,ValueError) as error:
            retry=retry or isinstance(error,OSError)
            receipt.update(error=str(error),ended_utc=e.utc())
            document(root/(stem+'.receipt.json'),receipt)
            if not retry or attempt==4:raise
            retry_after=next((v for k,v in headers.items() if k.lower()=='retry-after'),'')
            if retry_after and not str(retry_after).isdigit():raise ValueError('Unsupported Retry-After') from error
            wait=max(delay,2**(attempt-1),int(retry_after or 0))
            if wait>60 or time.monotonic()+wait>=deadline:raise ValueError('Retry exceeds deadline') from error
            sleep(wait)

def artifacts(root):
    out={}
    for path in root.iterdir():
        if path.name in (MANIFEST,COMPLETE):continue
        if path.is_symlink() or not path.is_file():raise ValueError('Unsafe capture artifact')
        if len(out)>=MAX_ARTIFACTS:raise ValueError('Artifact count exceeds bound')
        raw=read(path,2*1024*1024+1)
        out[path.name]=dict(bytes=len(raw),sha256=digest(raw))
    return out

def capture(site_path, root, *, delay=1.0, wall_seconds=300, transport=None, sleep=time.sleep):
    site_path,root=Path(site_path),Path(root)
    if not math.isfinite(delay) or not 0<=delay<=60 or type(wall_seconds)is not int or not 1<=wall_seconds<=900:
        raise ValueError('Invalid capture bounds')
    stamp=e.stamp(site_path);raw=read(site_path);cfg=profile.configuration(e.decode(raw),digest(raw))
    producer=read(Path(__file__),128*1024);parser=read(Path(profile.__file__),128*1024)
    dependencies={name:read(Path(module.__file__),128*1024) for name,module in (('date-numbering-helper.py',date),('capture-evidence-helper.py',e))}
    root.mkdir(parents=True,exist_ok=False)
    deadline=time.monotonic()+wall_seconds
    try:
        e.put(root/'original-site-info.json',raw)
        e.put(root/'capture-producer.py',producer);e.put(root/'profile-producer.py',parser)
        for name,data in dependencies.items():e.put(root/name,data)
        document(root/'requested.json',cfg)
        general=dict(action='query',format='json',formatversion='2',meta='siteinfo',siprop='general',maxlag='5')
        before,r1=observe(root,1,cfg,general,lambda d:identity(d,cfg),transport or e.get_response,sleep,delay,deadline)
        if time.monotonic()+delay>=deadline:raise ValueError('Capture deadline reached')
        sleep(delay)
        value,r2=observe(root,2,cfg,profile.query(cfg),lambda d:profile.profile(cfg,d),transport or e.get_response,sleep,delay,deadline)
        if time.monotonic()+delay>=deadline:raise ValueError('Capture deadline reached')
        sleep(delay)
        after,r3=observe(root,3,cfg,general,lambda d:identity(d,cfg),transport or e.get_response,sleep,delay,deadline)
        if before!=after:raise ValueError('Server identity changed during capture')
        if e.stamp(site_path)!=stamp or read(site_path)!=raw or read(Path(__file__),128*1024)!=producer or read(Path(profile.__file__),128*1024)!=parser:
            raise ValueError('Pinned input or producer changed')
        if any(read(Path(module.__file__),128*1024)!=dependencies[name] for name,module in (('date-numbering-helper.py',date),('capture-evidence-helper.py',e))):
            raise ValueError('Capture helper dependency changed')
        e.put(root/OUTPUT,profile.encoded(value))
        manifest=dict(schema='wikidict.site-statistics-format-capture.v1',configuration=cfg,
            wiki=cfg['wiki'],date=cfg['date'],content_language=cfg['content_language'],
            namespace_registry_sha256=cfg['namespace_registry_sha256'],
            output=OUTPUT,output_bytes=len(profile.encoded(value)),output_sha256=digest(profile.encoded(value)),
            original_site_info=dict(path=str(site_path.absolute()),bytes=len(raw),sha256=digest(raw)),
            server_identity=before,requests=[r1,r2,r3],temporal_scope='current-api-formatting-of-pinned-site-info-counts',
            cross_request_configuration_atomicity=False,retrieved_utc=e.utc(),artifacts=artifacts(root))
        document(root/MANIFEST,manifest)
        verify(root,complete=False)
        document(root/COMPLETE,dict(schema=manifest['schema'],manifest_sha256=digest(read(root/MANIFEST))))
        return manifest
    except BaseException as error:
        for name in (OUTPUT,MANIFEST,COMPLETE):
            path=root/name
            if path.exists():path.rename(root/(name+'.unverified'))
        document(root/'failure.json',dict(error=str(error),ended_utc=e.utc()))
        raise

def verify(root,complete=True):
    root=Path(root);manifest=e.decode(read(root/MANIFEST))
    if manifest.get('schema')!='wikidict.site-statistics-format-capture.v1' or artifacts(root)!=manifest['artifacts']:
        raise ValueError('Capture artifact inventory differs')
    selected_producers={'capture-producer.py':Path(__file__),'profile-producer.py':Path(profile.__file__),
        'date-numbering-helper.py':Path(date.__file__),'capture-evidence-helper.py':Path(e.__file__)}
    for name,path in selected_producers.items():
        if read(root/name,128*1024)!=read(path,128*1024):raise ValueError('Capture producer identity differs')
    raw=read(root/'original-site-info.json');cfg=profile.configuration(e.decode(raw),digest(raw))
    if cfg!=manifest['configuration'] or cfg!=e.decode(read(root/'requested.json')):raise ValueError('Pinned configuration differs')
    if any(manifest.get(key)!=cfg[key] for key in ('wiki','date','content_language','namespace_registry_sha256')):
        raise ValueError('Manifest site identity differs')
    original=manifest['original_site_info']
    if original['bytes']!=len(raw) or original['sha256']!=digest(raw):raise ValueError('Original descriptor differs')
    expected_general=dict(action='query',format='json',formatversion='2',meta='siteinfo',siprop='general',maxlag='5')
    results=[]
    if len(manifest['requests'])!=3:raise ValueError('Incomplete request inventory')
    for number,(item,query) in enumerate(zip(manifest['requests'],[expected_general,profile.query(cfg),expected_general]),1):
        expected_name=f'{number:02d}.request.json'
        if item['request']!=expected_name or not __import__('re').fullmatch(f'{number:02d}-0[1-4]\\.receipt\\.json',item['receipt']):
            raise ValueError('Request identity differs')
        request=e.decode(read(root/item['request']))
        if request!=dict(query=query,url=e.wiktionary_api(cfg['wiki'])+'?'+urllib.parse.urlencode(query)):raise ValueError('Request differs')
        receipt=e.decode(read(root/item['receipt']))
        if receipt.get('accepted') is not True or receipt.get('status')!=200 or receipt.get('request')!=item['request']:
            raise ValueError('Accepted receipt differs')
        expected_response=item['receipt'].replace('.receipt.json','.raw.json')
        if receipt.get('response')!=expected_response:raise ValueError('Response identity differs')
        response=read(root/expected_response,MAX_RESPONSE)
        if len(response)!=receipt['response_bytes'] or digest(response)!=receipt['response_sha256']:raise ValueError('Response bytes differ')
        data=e.decode(response)
        results.append(profile.profile(cfg,data) if number==2 else identity(data,cfg))
    if results[0]!=results[2] or results[0]!=manifest['server_identity'] or read(root/OUTPUT)!=profile.encoded(results[1]):
        raise ValueError('Replayed formatting or server identity differs')
    if (manifest.get('output')!=OUTPUT or manifest.get('output_bytes')!=len(read(root/OUTPUT))
            or manifest.get('output_sha256')!=digest(read(root/OUTPUT))):raise ValueError('Output descriptor differs')
    if complete:
        marker=e.decode(read(root/COMPLETE))
        if marker!=dict(schema=manifest['schema'],manifest_sha256=digest(read(root/MANIFEST))):raise ValueError('Completion differs')
    return manifest

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--site-info',type=Path);p.add_argument('--output',type=Path,required=True)
    p.add_argument('--verify',action='store_true')
    args=p.parse_args()
    if args.verify:verify(args.output)
    elif args.site_info:capture(args.site_info,args.output)
    else:p.error('--site-info required for capture')


def validate_snapshot(path, wiki=None, date=None):
    path=Path(path)
    if path.name!=OUTPUT:raise ValueError('Unexpected formatting snapshot filename')
    manifest=verify(path.parent)
    if (wiki is not None and manifest['wiki']!=wiki) or (date is not None and manifest['date']!=date):
        raise ValueError('Formatting snapshot edition/date differs')
    return manifest

def capture_artifacts(path, manifest=None):
    path=Path(path);validated=validate_snapshot(path)
    if manifest is not None and manifest!=validated:raise ValueError('Formatting manifest changed')
    result={name:row['sha256'] for name,row in validated['artifacts'].items()}
    for name in (MANIFEST,COMPLETE):result[name]=digest(read(path.parent/name))
    return result
