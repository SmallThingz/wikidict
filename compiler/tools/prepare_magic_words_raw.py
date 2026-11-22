#!/usr/bin/env python3
"""Derive captured RAW transclusion aliases offline; retain the exact predecessor."""
import argparse
import datetime as dt
import hashlib
import json
from pathlib import Path
import unicodedata
import prepare_magic_words_category as category

legacy = category.legacy
VERSION = 11
PROFILE = 'captured-raw-transclusion-v1'
SOURCE_MANIFEST = 'magic-words.raw-source.manifest.json'
SOURCE_TSV = 'magic-words.raw-source.tsv'
PRODUCER_SHA256 = hashlib.sha256(Path(__file__).read_bytes()).hexdigest()


def predecessor(manifest):
    if manifest.get('version') in (7, 9):
        return category
    raise ValueError('RAW derivation requires an authenticated category predecessor')


def render_snapshot(data, old_tsv):
    # Predecessor validation authenticates edition/general identity and every
    # existing row. This projection adds only the observed RAW record.
    records = [word for word in data['query']['magicwords'] if word['name'] == 'raw']
    if len(records) != 1:
        raise ValueError('RAW projection requires exactly one captured raw record')
    word = records[0]
    sensitive = word.get('case-sensitive', False)
    aliases = word.get('aliases')
    if type(sensitive) is not bool or not isinstance(aliases, list) or not aliases or len(aliases) > 1000:
        raise ValueError('Invalid captured RAW record')
    rows = set(old_tsv.decode('utf-8').splitlines()[4:])
    if any(row.startswith('raw\t') for row in rows):
        raise ValueError('Predecessor already contains RAW aliases')
    seen = set()
    for alias in aliases:
        if (not isinstance(alias, str) or not alias or len(alias.encode()) > 1024
                or any(unicodedata.category(c) == 'Cc' for c in alias)
                or alias[-1] not in ':：' or any(c in ':：' for c in alias[:-1])
                or len(alias) == 1 or alias in seen):
            raise ValueError('Unsupported or duplicate captured RAW prefix')
        seen.add(alias)
        rows.add('raw\t' + str(int(sensitive)) + '\t' + alias)
    head = old_tsv.decode('utf-8').splitlines()[:4]
    output = ('\n'.join(head) + '\n' + ''.join(row+'\n' for row in sorted(rows))).encode()
    if len(output) > legacy.MAX_TSV_BYTES:
        raise ValueError('RAW magic-word table exceeds the native registry limit')
    return output, len(rows)


def validate_capture(manifest, blobs, wiki=None, date=None):
    if not isinstance(manifest, dict) or manifest.get('version') != VERSION or manifest.get('profile') != PROFILE:
        raise ValueError('Invalid RAW projection profile')
    if manifest.get('generator_sha256') != PRODUCER_SHA256:
        raise ValueError('RAW producer identity mismatch')
    if (wiki is not None and manifest.get('wiki') != wiki or date is not None and manifest.get('date') != date):
        raise ValueError('RAW projection differs from requested edition/date')
    if not isinstance(manifest.get('artifacts'),dict) or set(blobs) != set(manifest['artifacts']):
        raise ValueError('Incomplete RAW projection artifacts')
    if any(legacy.digest(raw) != manifest['artifacts'][name] for name,raw in blobs.items()):
        raise ValueError('Changed RAW projection artifact')
    old = legacy.parse_json(blobs[SOURCE_MANIFEST])
    prior = predecessor(old)
    if set(blobs) != set(old['artifacts']) | {SOURCE_MANIFEST,SOURCE_TSV}:
        raise ValueError('RAW projection contains unexpected artifacts')
    old_blobs = {name:blobs[name] for name in old['artifacts']}
    old_blobs['magic-words.tsv'] = blobs[SOURCE_TSV]
    prior.validate_capture(old,old_blobs,wiki,date)
    expected_source = dict(profile=old['profile'],manifest_sha256=legacy.digest(blobs[SOURCE_MANIFEST]),output_sha256=legacy.digest(blobs[SOURCE_TSV]))
    if manifest.get('source_capture') != expected_source:
        raise ValueError('RAW predecessor binding mismatch')
    for key in ('wiki','date','content_language','temporal_scope','retrieved_utc','source_url','raw_sha256'):
        if manifest.get(key) != old.get(key):
            raise ValueError('RAW predecessor identity mismatch: '+key)
    if legacy.timestamp(manifest.get('derived_utc')) < legacy.timestamp(old['derived_utc']):
        raise ValueError('RAW derivation predates its predecessor')
    output,rows=render_snapshot(legacy.parse_json(blobs['magic-words.raw.json']),blobs[SOURCE_TSV])
    if (blobs['magic-words.tsv'] != output or manifest.get('output_sha256') != legacy.digest(output)
            or manifest.get('output_bytes') != len(output) or manifest.get('rows') != rows
            or manifest.get('canonical_words') != legacy.canonical_word_count(output)):
        raise ValueError('RAW output does not replay from captured aliases')
    return manifest


def validate_snapshot(path,wiki=None,date=None):
    path=Path(path);path=path.parent if path.name=='magic-words.tsv' else path
    manifest=legacy.parse_json(legacy.read_regular(path/'magic-words.manifest.json'))
    old=legacy.parse_json(legacy.read_regular(path/SOURCE_MANIFEST))
    predecessor(old)
    names=(category.ARTIFACTS if old['version']==7 else category.ISBN_ARTIFACTS) | {SOURCE_MANIFEST,SOURCE_TSV}
    blobs={name:legacy.read_regular(path/name) for name in names}
    return validate_capture(manifest,blobs,wiki,date)


def capture_artifacts(path,manifest=None):
    path=Path(path);path=path.parent if path.name=='magic-words.tsv' else path
    actual=validate_snapshot(path)
    if manifest is not None and manifest!=actual:raise ValueError('RAW capture changed during validation')
    return {**actual['artifacts'],'magic-words.manifest.json':legacy.digest(legacy.read_regular(path/'magic-words.manifest.json'))}


def derive_snapshot(source,output,wiki=None,date=None):
    source=Path(source);source=source.parent if source.name=='magic-words.tsv' else source
    output=Path(output)
    old_raw=legacy.read_regular(source/'magic-words.manifest.json');old=legacy.parse_json(old_raw)
    prior=predecessor(old);prior.validate_snapshot(source,wiki,date)
    blobs={name:legacy.read_regular(source/name) for name in old['artifacts']}
    prior.validate_capture(old,blobs,wiki,date)
    identity=dict(profile=old['profile'],manifest_sha256=legacy.digest(old_raw),output_sha256=legacy.digest(blobs['magic-words.tsv']))
    if output.exists() or output.is_symlink():
        existing=validate_snapshot(output,wiki,date)
        if existing.get('source_capture') != identity:raise ValueError('Existing RAW output has a different predecessor')
        return existing,False
    tsv,rows=render_snapshot(legacy.parse_json(blobs['magic-words.raw.json']),blobs['magic-words.tsv'])
    artifacts={**blobs,SOURCE_MANIFEST:old_raw,SOURCE_TSV:blobs['magic-words.tsv'],'magic-words.tsv':tsv}
    manifest={key:old[key] for key in ('wiki','date','content_language','temporal_scope','retrieved_utc','source_url','raw_sha256')}
    manifest.update(version=VERSION,profile=PROFILE,generator_sha256=PRODUCER_SHA256,
        derived_utc=dt.datetime.now(dt.timezone.utc).isoformat(),source_capture=identity,
        output_sha256=legacy.digest(tsv),output_bytes=len(tsv),rows=rows,canonical_words=legacy.canonical_word_count(tsv),
        artifacts={name:legacy.digest(raw) for name,raw in artifacts.items()})
    validate_capture(manifest,artifacts,wiki,date)
    if legacy.read_regular(source/'magic-words.manifest.json') != old_raw or any(legacy.read_regular(source/name) != raw for name,raw in blobs.items()):
        raise ValueError('RAW predecessor changed during derivation')
    legacy.write_capture(output,artifacts,manifest)
    return validate_snapshot(output,wiki,date),True


def main():
    parser=argparse.ArgumentParser(description=__doc__);sub=parser.add_subparsers(dest='command',required=True)
    derive=sub.add_parser('derive');derive.add_argument('source',type=Path);derive.add_argument('output',type=Path)
    verify=sub.add_parser('verify');verify.add_argument('path',type=Path)
    for command in (derive,verify):command.add_argument('--wiki');command.add_argument('--date')
    args=parser.parse_args()
    result=derive_snapshot(args.source,args.output,args.wiki,args.date)[0] if args.command=='derive' else validate_snapshot(args.path,args.wiki,args.date)
    print(json.dumps(result,ensure_ascii=False,sort_keys=True))
if __name__=='__main__':main()
