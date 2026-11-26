#!/usr/bin/env python3
"""Build-only adapter for explicitly retained controlled capture inputs.

The observation is scoped to its captured component/initializer/stylesheets.
This adapter does not fetch, expand, or assert historical whole-page CSS.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re

def sha(b): return hashlib.sha256(b).hexdigest()
def pairs(items):
    out={}
    for key,value in items:
        if key in out: raise ValueError('duplicate JSON key: '+key)
        out[key]=value
    return out
def parse(b): return json.loads(b,object_pairs_hook=pairs)
def read(path, cap=2*1024*1024):
    path=Path(path)
    with path.open('rb') as f:
        first=os.fstat(f.fileno()); assert 0<first.st_size<=cap
        b=f.read(cap+1); last=os.fstat(f.fileno())
    def stamp(s): return [s.st_dev,s.st_ino,s.st_size,s.st_mtime_ns,s.st_ctime_ns]
    assert len(b)==first.st_size and stamp(first)==stamp(last)==stamp(path.stat())
    return b,dict(path=str(path.resolve()),sha256=sha(b),bytes=len(b),physical=stamp(first))
def reference(ref, actual):
    assert ref['sha256']==actual['sha256'] and ref['bytes']==actual['bytes']
def write(path,value):
    with Path(path).open('x') as f:
        json.dump(value,f,ensure_ascii=False,indent=2);f.write('\n');f.flush();os.fsync(f.fileno())

def issue(args):
    inputs={}; data={}
    for name in ('spec','namespace','raw','expanded','policy','binding','observed_html','reference_result','reference_closure','typed_fixture'):
        data[name],inputs[name]=read(getattr(args,name))
    spec=parse(data['spec']);binding=parse(data['binding']);result=parse(data['reference_result']);closure=parse(data['reference_closure'])
    policy=parse(data['policy']);typed=parse(data['typed_fixture'])
    assert spec['schema']=='a1.it.controlled-disclosure-original-input.v1'
    assert binding['schema']=='a1.it.actual-button-capture.v1'
    assert result['schema']=='wikidict.S4.IT-initialized-disclosure-reference.v1'
    assert spec['reference_scope']=='controlled_component_current_initializer_css'
    for v in (spec,binding,result):
        assert v['full_page_cascade_qualified'] is False and v['historical_deployment_qualified'] is False
    reference(binding['component'],inputs['observed_html']);reference(binding['source_result'],inputs['reference_result'])
    reference(binding['source_closure'],inputs['reference_closure']);reference(binding['typed_fixture'],inputs['typed_fixture'])
    reference(result['supplied_component'],inputs['observed_html'])
    reference(closure['result_files']['results/result.json'],inputs['reference_result'])
    assert closure['exit_code']==0 and closure['guard_child']==0 and closure['guard_guardian']==0
    assert closure['cleanup_complete'] is True and closure['initialized_button_observed'] is True and closure['errors']==[]
    assert policy==typed==spec['policy']
    assert spec['raw_sha256']==inputs['raw']['sha256'] and spec['expanded_sha256']==inputs['expanded']['sha256']
    assert spec['namespace_sha256']==inputs['namespace']['sha256']
    assert spec['observed_html_sha256']==inputs['observed_html']['sha256']
    assert spec['actual_reference_sha256']==inputs['reference_result']['sha256']
    assert spec['capture_binding_sha256']==inputs['binding']['sha256']
    assert policy['content_index']==1 and policy['button'] is not None and policy['direction'] is not None
    assert len(binding['states'])==10 and binding['actions']['real_clicks']==2
    assert len(binding['actions']['keyboard'])==4
    header={}
    for line in data['namespace'].decode().splitlines():
        if line.startswith('# ') and '\t' in line:
            k,v=line[2:].split('\t',1);k=k.replace('-','_')
            assert k not in header
            header[k]=v
    # Namespace TSV has one edition/date identity, never inferred from title.
    for key in ('wiki','dump_date'):
        if key not in header:
            m=re.search(r'^#\s*'+key.replace('_','[-_]')+r'\s*[:=\t]\s*(\S+)\s*$',data['namespace'].decode(),re.M)
            assert m,key
            header[key]=m[1]
    x=data['expanded'];h=data['observed_html']
    start,end,cs,ce=(spec[k] for k in ('owner_start','owner_end','content_start','content_end'))
    assert 0<=start<cs<ce<end<=len(x)
    assert x[start:].startswith(b'<div ') and x[cs:].startswith(b'<div ')
    opening_end=x.index(b'>',cs)+1
    # The authenticated source opener, caption, and direct-child opener agree;
    # parsed descendants are intentionally not equated to raw wikitext.
    assert h.startswith(x[start:opening_end])
    assert x[ce:end]==b'</div>' and x[end-12:ce]==b'</div>'
    for field,attr in (('expand_label',b'data-expandtext'),('collapse_label',b'data-collapsetext')):
        expected=attr+b'="'+policy[field].encode()+b'"'
        assert expected in x[start:x.index(b'>',start)+1]
    entry={key:spec[key] for key in ('namespace_id','title','page_id','revision_id','raw_sha256','expanded_sha256')}
    entry['captures']=[dict(owner_start=start,owner_end=end,content_start=cs,content_end=ce,
        owner_sha256=sha(x[start:end]),policy=policy,reference=dict(scope=spec['reference_scope'],
        full_page_cascade_qualified=False,historical_deployment_qualified=False,
        observed_html_sha256=inputs['observed_html']['sha256'],actual_reference_sha256=inputs['reference_result']['sha256'],
        capture_binding_sha256=inputs['binding']['sha256']))]
    value=dict(schema='wikidict.container-disclosure-captures.v1',wiki=header['wiki'],dump_date=header['dump_date'],
        namespace_sha256=inputs['namespace']['sha256'],pages=[entry])
    for name,old in inputs.items(): assert read(getattr(args,name))[1]==old
    write(args.output,value)
    write(args.receipt,dict(status='SOURCE_INPUT_ISSUED_NATIVE_UNRUN',inputs=inputs,output=read(args.output)[1],
        input_posts=True,scope=spec['reference_scope'],actual_reference_preserved=True,
        source_owner_range=[start,end],source_content_range=[cs,ce],source_opener_caption_child_prefix_equal=True,
        historical_deployment=False,full_page_cascade=False,ordinary_native=False,canonical_write=False))

if __name__=='__main__':
    parser=argparse.ArgumentParser()
    for name in ('spec','namespace','raw','expanded','policy','binding','observed-html','reference-result','reference-closure','typed-fixture','output','receipt'):
        parser.add_argument('--'+name,required=True,type=Path)
    issue(parser.parse_args())
