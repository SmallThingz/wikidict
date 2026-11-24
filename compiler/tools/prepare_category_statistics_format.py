"""Bounded formatting of literal dated category counts; never query live categories."""
import argparse
import gzip
import hashlib
import io
import json
import math
from pathlib import Path
import re
import time
import unicodedata
import urllib.parse

import prepare_site_statistics_format as prior

e = prior.e
OUTPUT = 'category-statistics-format.json'
MANIFEST = 'category-statistics-format.manifest.json'
COMPLETE = 'category-statistics-format.complete.json'
SCHEMA = 'wikidict.category-statistics-format.v1'
CAPTURE_SCHEMA = 'wikidict.category-statistics-format-capture.v1'
BATCH_SIZE = 32
MAX_VALUES = 8192
MAX_ARTIFACTS = ((MAX_VALUES + BATCH_SIZE - 1) // BATCH_SIZE + 2) * 9 + 10
MAX_VALUE = (1 << 53) - 1
MAX_STATS_BYTES = 64 * 1024 * 1024
MAX_JSON_BYTES = 4 * 1024 * 1024

def digest(raw): return hashlib.sha256(raw).hexdigest()
def read(path, bound=1024*1024): return e.small(Path(path), bound)
def document(path, value): e.document(Path(path), value)
def encoded(value): return (json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(',', ':'))+'\n').encode()

def configuration(site_raw, stats_raw):
    return stream_configuration(site_raw, io.BytesIO(stats_raw))[0]


def stream_configuration(site_raw, stream, *, row_limit=MAX_STATS_BYTES):
    site = e.decode(site_raw)
    cfg = prior.profile.configuration(site, digest(site_raw))
    domain = {0}
    # Each accepted count belongs to the bounded formatting domain below.
    parsed_counts = {}
    seen = set()
    total_bytes = 0
    logical = hashlib.sha256()
    while raw_line := stream.readline(row_limit + 1):
        total_bytes += len(raw_line)
        if total_bytes > MAX_STATS_BYTES or len(raw_line) > row_limit or not raw_line.endswith(b'\n'):
            raise ValueError('Incomplete or excessive category statistics')
        logical.update(raw_line)
        try: fields = raw_line.decode('utf-8').rstrip('\n').split('\t')
        except UnicodeDecodeError as error: raise ValueError('Invalid category statistics UTF-8') from error
        title = hashlib.blake2b(fields[0].encode(),digest_size=16).digest()
        if len(fields) != 4 or not fields[0] or title in seen:
            raise ValueError('Invalid or duplicate category statistics row')
        seen.add(title)
        numbers = []
        for raw in fields[1:]:
            value = parsed_counts.get(raw)
            if value is None:
                if re.fullmatch('0|[1-9][0-9]*', raw) is None:
                    raise ValueError('Invalid category count')
                value = int(raw)
                if value > MAX_VALUE:
                    raise ValueError('Invalid category count')
                parsed_counts[raw] = value
            numbers.append(value)
        total, subcats, files = numbers
        if subcats + files > total: raise ValueError('Inconsistent category counts')
        domain.update((total, total-subcats-files, subcats, files))
        if len(domain) > MAX_VALUES: raise ValueError('Category count domain exceeds selected bound')
    if not total_bytes:
        raise ValueError('Incomplete category statistics')
    return {**{k: cfg[k] for k in ('wiki','date','content_language','namespace_registry_sha256','site_info_sha256')},
            'source_server_identity': {k: site['query']['general'][k] for k in ('wikiid','lang','generator')},
            'category_stats_sha256': logical.hexdigest(), 'raw_values': [str(n) for n in sorted(domain)]}, total_bytes

def queries(cfg):
    result = []
    for start in range(0, len(cfg['raw_values']), BATCH_SIZE):
        batch = cfg['raw_values'][start:start+BATCH_SIZE]
        number = len(result)+1
        begin = 'BEGIN-WIKIDICT-CATEGORY-FORMAT-V1-'+str(number)
        end = 'END-WIKIDICT-CATEGORY-FORMAT-V1-'+str(number)
        lines = [begin]
        for raw in batch:
            lines.extend((raw+'={{formatnum:'+raw+'}}',raw+'-RAW={{formatnum:'+raw+'|R}}'))
        lines.append(end)
        result.append(dict(action='expandtemplates',format='json',formatversion='2',prop='wikitext',
            title='API',uselang='en',maxlag='5',text='\n'.join(lines)))
    return result

def batch_profile(cfg, number, data):
    text = prior.date.clean_api(data).get('expandtemplates', {}).get('wikitext')
    if not isinstance(text, str) or '\r' in text: raise ValueError('Missing category formatting response')
    batch = cfg['raw_values'][(number-1)*BATCH_SIZE:number*BATCH_SIZE]
    lines = text.split('\n')
    if (not batch or len(lines)!=2*len(batch)+2 or lines[0]!='BEGIN-WIKIDICT-CATEGORY-FORMAT-V1-'+str(number)
            or lines[-1]!='END-WIKIDICT-CATEGORY-FORMAT-V1-'+str(number)):
        raise ValueError('Category formatting frame differs')
    values = []
    for index, raw in enumerate(batch):
        line, control = lines[1+2*index:3+2*index]
        if not line.startswith(raw+'=') or control!=raw+'-RAW='+raw:
            raise ValueError('Category formatting key/raw control differs')
        value = line[len(raw)+1:]
        if (not value or len(value.encode('utf-8'))>256
                or any(unicodedata.category(c) in ('Cc','Cs') for c in value)
                or any(c in value for c in '<>{}|[]')):
            raise ValueError('Unsupported category formatted value')
        values.append(dict(raw=raw,formatted=value))
    return values

def output(cfg, values):
    if [x['raw'] for x in values] != cfg['raw_values']: raise ValueError('Incomplete category formatting domain')
    return dict(schema=SCHEMA, **{k:cfg[k] for k in ('wiki','date','content_language',
        'namespace_registry_sha256','site_info_sha256','category_stats_sha256')},values=values)

def producer_paths():
    return {'capture-producer.py':Path(__file__), 'statistics-capture-helper.py':Path(prior.__file__),
        'statistics-profile-helper.py':Path(prior.profile.__file__),
        'date-numbering-helper.py':Path(prior.date.__file__), 'capture-evidence-helper.py':Path(e.__file__)}

def artifacts(root, *, stats_configuration=None):
    result = {}
    for path in root.iterdir():
        if path.name in (MANIFEST, COMPLETE): continue
        if path.is_symlink() or not path.is_file() or len(result)>=MAX_ARTIFACTS:
            raise ValueError('Unsafe or excessive category capture artifacts')
        if path.name == 'original-category-stats.tsv' and stats_configuration is not None:
            before = e.stamp(path)
            with path.open('rb') as source:
                encoded = source.peek(2)[:2] == b'\x1f\x8b'
                if encoded:
                    with gzip.GzipFile(fileobj=source) as decoded:
                        config, size = stream_configuration(read(root/'original-site-info.json'), decoded, row_limit=64*1024)
                else:
                    config, size = stream_configuration(read(root/'original-site-info.json'), source)
            if before != e.stamp(path):
                raise ValueError('Category statistics changed during replay')
            result[path.name] = dict(bytes=size, sha256=config['category_stats_sha256'])
            stats_configuration.append(config)
            continue
        raw = read(path, MAX_STATS_BYTES if path.name=='original-category-stats.tsv' else MAX_JSON_BYTES)
        result[path.name] = dict(bytes=len(raw),sha256=digest(raw))
    return result

def capture(site_path, stats_path, root, *, delay=1.0, wall_seconds=900, transport=None, sleep=time.sleep):
    site_path, stats_path, root = Path(site_path), Path(stats_path), Path(root)
    if not math.isfinite(delay) or not 0<=delay<=60 or type(wall_seconds) is not int or not 1<=wall_seconds<=900:
        raise ValueError('Invalid category capture bounds')
    stamps = [e.stamp(p) for p in (site_path,stats_path)]
    site_raw, stats_raw = read(site_path), read(stats_path, MAX_STATS_BYTES)
    cfg = configuration(site_raw, stats_raw)
    producers = {name:read(p,128*1024) for name,p in producer_paths().items()}
    root.mkdir(parents=True, exist_ok=False)
    deadline = time.monotonic()+wall_seconds
    try:
        e.put(root/'original-site-info.json',site_raw);e.put(root/'original-category-stats.tsv',stats_raw)
        for name, raw in producers.items(): e.put(root/name,raw)
        document(root/'requested.json',cfg)
        general = dict(action='query',format='json',formatversion='2',meta='siteinfo',siprop='general',maxlag='5')
        plan = [general, *queries(cfg), general]
        results, receipts = [], []
        for index, query in enumerate(plan):
            if index:
                if time.monotonic()+delay>=deadline: raise ValueError('Capture deadline reached')
                sleep(delay)
            parser = (lambda d: prior.identity(d,cfg)) if index in (0,len(plan)-1) else (lambda d,n=index:batch_profile(cfg,n,d))
            value, receipt = prior.observe(root,index+1,cfg,query,parser,transport or e.get_response,sleep,delay,deadline)
            results.append(value);receipts.append(receipt)
        if results[0]!=results[-1]: raise ValueError('Server identity changed during capture')
        value = output(cfg,[item for batch in results[1:-1] for item in batch])
        if ([e.stamp(p) for p in (site_path,stats_path)]!=stamps or read(site_path)!=site_raw
                or read(stats_path,MAX_STATS_BYTES)!=stats_raw
                or any(read(path,128*1024)!=producers[name] for name,path in producer_paths().items())):
            raise ValueError('Pinned category input or producer changed')
        raw = encoded(value)
        if len(raw)>MAX_JSON_BYTES: raise ValueError('Category formatted output exceeds bound')
        e.put(root/OUTPUT,raw)
        manifest = dict(schema=CAPTURE_SCHEMA,configuration=cfg,**{k:cfg[k] for k in ('wiki','date','content_language','namespace_registry_sha256')},
            output=OUTPUT,output_bytes=len(raw),output_sha256=digest(raw),server_identity=results[0],requests=receipts,
            temporal_scope='current-api-formatting-of-literal-dated-category-counts',cross_request_configuration_atomicity=False,
            retrieved_utc=e.utc(),artifacts=artifacts(root))
        document(root/MANIFEST,manifest);verify(root,complete=False)
        document(root/COMPLETE,dict(schema=CAPTURE_SCHEMA,manifest_sha256=digest(read(root/MANIFEST))))
        return manifest
    except BaseException as error:
        for name in (OUTPUT,MANIFEST,COMPLETE):
            path=root/name
            if path.exists(): path.rename(root/(name+'.unverified'))
        document(root/'failure.json',dict(error=str(error),ended_utc=e.utc()))
        raise

def verify(root, complete=True):
    root=Path(root);manifest=e.decode(read(root/MANIFEST))
    configs = []
    if manifest.get('schema')!=CAPTURE_SCHEMA or artifacts(root, stats_configuration=configs)!=manifest.get('artifacts') or len(configs) != 1:
        raise ValueError('Category capture artifact inventory differs')
    prior.validate_provenance(manifest['artifacts'], producer_paths())
    cfg = configs[0]
    if cfg!=manifest.get('configuration') or cfg!=e.decode(read(root/'requested.json')):
        raise ValueError('Category capture configuration differs')
    if any(manifest.get(k)!=cfg[k] for k in ('wiki','date','content_language','namespace_registry_sha256')):
        raise ValueError('Category manifest identity differs')
    general=dict(action='query',format='json',formatversion='2',meta='siteinfo',siprop='general',maxlag='5')
    plan=[general,*queries(cfg),general]
    if len(manifest['requests'])!=len(plan): raise ValueError('Incomplete category request inventory')
    results=[]
    for index,(item,query) in enumerate(zip(manifest['requests'],plan)):
        number=index+1;name=f'{number:02d}.request.json'
        if item.get('request')!=name or not re.fullmatch(f'{number:02d}-0[1-4]\\.receipt\\.json',item.get('receipt','')):
            raise ValueError('Category request identity differs')
        request=e.decode(read(root/name))
        if request!=dict(query=query,url=e.wiktionary_api(cfg['wiki'])+'?'+urllib.parse.urlencode(query)):
            raise ValueError('Category request differs')
        receipt=e.decode(read(root/item['receipt']))
        if receipt.get('accepted') is not True or receipt.get('status')!=200 or receipt.get('request')!=name:
            raise ValueError('Category accepted receipt differs')
        response=item['receipt'].replace('.receipt.json','.raw.json')
        if receipt.get('response')!=response: raise ValueError('Category response identity differs')
        raw=read(root/response,prior.MAX_RESPONSE)
        if len(raw)!=receipt['response_bytes'] or digest(raw)!=receipt['response_sha256']:
            raise ValueError('Category response bytes differ')
        data=e.decode(raw)
        results.append(prior.identity(data,cfg) if index in (0,len(plan)-1) else batch_profile(cfg,index,data))
    value=output(cfg,[item for batch in results[1:-1] for item in batch]);raw=encoded(value)
    if results[0]!=results[-1] or results[0]!=manifest.get('server_identity') or read(root/OUTPUT,MAX_JSON_BYTES)!=raw:
        raise ValueError('Category replay or identity differs')
    if manifest.get('output')!=OUTPUT or manifest.get('output_bytes')!=len(raw) or manifest.get('output_sha256')!=digest(raw):
        raise ValueError('Category output descriptor differs')
    if complete and e.decode(read(root/COMPLETE))!=dict(schema=CAPTURE_SCHEMA,manifest_sha256=digest(read(root/MANIFEST))):
        raise ValueError('Category completion differs')
    return manifest

def validate_snapshot(path,wiki=None,date=None):
    path=Path(path)
    if path.name!=OUTPUT: raise ValueError('Unexpected category formatting snapshot filename')
    manifest=verify(path.parent)
    if (wiki is not None and manifest['wiki']!=wiki) or (date is not None and manifest['date']!=date):
        raise ValueError('Category formatting edition/date differs')
    return manifest

def capture_artifacts(path,manifest=None):
    path=Path(path);actual=validate_snapshot(path)
    if manifest is not None and manifest!=actual: raise ValueError('Category manifest changed')
    result={name:row['sha256'] for name,row in actual['artifacts'].items()}
    for name in (MANIFEST,COMPLETE): result[name]=digest(read(path.parent/name))
    return result

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--site-info',type=Path);p.add_argument('--category-stats',type=Path)
    p.add_argument('--output',type=Path,required=True);p.add_argument('--verify',action='store_true');args=p.parse_args()
    if args.verify: verify(args.output)
    elif args.site_info and args.category_stats: capture(args.site_info,args.category_stats,args.output)
    else: p.error('--site-info and --category-stats required for capture')
