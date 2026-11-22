#!/usr/bin/env python3
"""Derive edition behavior controls offline from a verified saved siteinfo capture."""
import argparse
import json
from pathlib import Path
import unicodedata
import prepare_magic_words as magic

PROFILE = 'behavior-switches-v1'
MAX_ROWS = 10000
IDS = frozenset('notoc forcetoc toc noeditsection nogallery hiddencat index noindex newsectionlink nonewsectionlink nocontentconvert notitleconvert staticredirect expectunusedcategory expectunusedtemplate expectshortpage noglobal nomediaviewercarousel disambiguation expectedUnconnectedPage archivedtalk notalk keeptitle expectwithoutscans'.split())
PRODUCER_SHA256 = magic.digest(Path(__file__).read_bytes())

def render(raw, wiki, date, content_language, namespace_registry_sha256="0" * 64):
    language = content_language
    data = magic.parse_json(raw)
    query = data.get('query', {})
    general = query.get('general', {})
    if general.get('wikiid') != wiki or general.get('lang') != language:
        raise ValueError('Behavior source identity mismatch')
    words = query.get('magicwords')
    if not isinstance(words, list): raise ValueError('Missing magic-word inventory')
    rows, seen = set(), set()
    for word in words:
        name = word.get('name')
        if name not in IDS: continue
        if name in seen: raise ValueError('Duplicate behavior identity')
        seen.add(name)
        flag = word.get('case-sensitive', False)
        if type(flag) is not bool: raise ValueError('Invalid case flag')
        aliases = word.get('aliases')
        if not isinstance(aliases, list) or not aliases: raise ValueError('Missing behavior aliases')
        for alias in aliases:
            if not isinstance(alias, str) or not alias or len(alias.encode()) > 1024 or any(unicodedata.category(c) == 'Cc' for c in alias):
                raise ValueError('Invalid behavior alias')
            rows.add((name, int(flag), alias))
    if len(rows) > MAX_ROWS: raise ValueError('Behavior table exceeds native row bound')
    required = {'notoc', 'forcetoc', 'toc', 'noeditsection'}
    if not required <= seen: raise ValueError('Incomplete core behavior inventory')
    text = '# wikidict-behavior-switches-v1\n# wiki\t%s\n# dump-date\t%s\n# content-language\t%s\n' % (wiki, date, language)
    text += '# namespace-registry-sha256\t' + namespace_registry_sha256 + '\n'
    text += ''.join('%s\t%d\t%s\n' % row for row in sorted(rows))
    result = text.encode()
    if len(result) > magic.MAX_TSV_BYTES: raise ValueError('Behavior table exceeds native bound')
    return result

def namespace_binding(registry_bytes, sidecar_bytes, source_blobs, source):
    record=magic.parse_json(sidecar_bytes)
    digest=magic.digest(registry_bytes)
    complete=magic.parse_json(source_blobs['namespace-capture.complete.json'])
    dumped=complete.get('artifacts',{}).get('dump-siteinfo.xml')
    raw_digest=magic.digest(source_blobs['namespace-siteinfo.raw.json'])
    if not dumped or record.get('wiki')!=source['wiki'] or record.get('date')!=source['date'] or record.get('output_sha256')!=digest:
        raise ValueError('Selected namespace registry identity/output mismatch')
    if record.get('raw_siteinfo_sha256')!=raw_digest or record.get('dump_siteinfo_sha256')!=dumped:
        raise ValueError('Selected namespace registry differs from authenticated capture')
    lines=registry_bytes.decode('utf-8').splitlines()
    if lines[:3]!=['# wikidict-namespace-registry-v1','# wiki\t'+source['wiki'],'# dump-date\t'+source['date']]:
        raise ValueError('Selected namespace registry header mismatch')
    return digest

def validate_snapshot(path, wiki=None, date=None):
    path = Path(path); root = path.parent if path.name == 'behavior-switches.tsv' else path
    if root.is_symlink() or not root.is_dir(): raise ValueError('Unsafe behavior capture')
    manifest = magic.parse_json(magic.read_regular(root / 'behavior-switches.manifest.json'))
    source_manifest = magic.read_regular(root / 'behavior-source-magic-words.manifest.json')
    source = magic.parse_json(source_manifest)
    _, source_names = magic.capture_profile(source)
    source_blobs = {name: magic.read_regular(root / ('behavior-source-' + name)) for name in source_names}
    source = magic.validate_capture(source, source_blobs, wiki, date)
    identity = dict(wiki=source['wiki'], date=source['date'], content_language=source['content_language'])
    if type(manifest.get('version')) is not int or manifest.get('version') != 1 or manifest.get('profile') != PROFILE or any(manifest.get(k) != v for k,v in identity.items()):
        raise ValueError('Behavior manifest identity mismatch')

    if manifest.get('source_manifest_sha256') != magic.digest(source_manifest): raise ValueError('Changed behavior source manifest')
    if manifest.get('raw_sha256') != magic.digest(source_blobs['magic-words.raw.json']): raise ValueError('Behavior raw source mismatch')
    if any(manifest.get(key) != source.get(key) for key in ('temporal_scope', 'retrieved_utc')): raise ValueError('Behavior retrieval provenance mismatch')
    namespace_sha=namespace_binding(magic.read_regular(root/'behavior-source-namespace-registry.tsv'), magic.read_regular(root/'behavior-source-namespace-registry.manifest.json'), source_blobs, source)
    if manifest.get('namespace_registry_sha256')!=namespace_sha: raise ValueError('Behavior namespace binding mismatch')
    expected = render(source_blobs['magic-words.raw.json'], namespace_registry_sha256=namespace_sha, **identity)
    actual = magic.read_regular(root / 'behavior-switches.tsv', magic.MAX_TSV_BYTES)
    if actual != expected or magic.digest(actual) != manifest.get('output_sha256'): raise ValueError('Changed behavior table')
    if manifest.get('generator_sha256') != PRODUCER_SHA256: raise ValueError('Behavior producer mismatch')
    return manifest

def derive_snapshot(source, output, wiki=None, date=None, namespace_registry=None):
    source, output = Path(source), Path(output)
    original = magic.validate_snapshot(source, wiki, date)
    if output.exists() or output.is_symlink(): raise ValueError('Refusing to replace behavior derivation')
    source_manifest = magic.read_regular(source / 'magic-words.manifest.json')
    if magic.parse_json(source_manifest) != original: raise ValueError('Source changed during derivation')
    _, artifacts = magic.capture_profile(original)
    blobs = {name: magic.read_regular(source / name) for name in artifacts}
    magic.validate_capture(original, blobs, original['wiki'], original['date'])
    identity = {k: original[k] for k in ('wiki','date','content_language')}
    if namespace_registry is None: raise ValueError('Behavior derivation requires selected namespace registry')
    namespace_registry=Path(namespace_registry)
    namespace_bytes=magic.read_regular(namespace_registry)
    namespace_sidecar=magic.read_regular(namespace_registry.with_name('namespace-registry.manifest.json'))
    namespace_sha=namespace_binding(namespace_bytes, namespace_sidecar, blobs, original)
    tsv = render(blobs['magic-words.raw.json'], namespace_registry_sha256=namespace_sha, **identity)
    manifest = dict(version=1, profile=PROFILE, namespace_registry_sha256=namespace_sha, **identity, temporal_scope=original['temporal_scope'], retrieved_utc=original['retrieved_utc'], source_manifest_sha256=magic.digest(source_manifest), raw_sha256=magic.digest(blobs['magic-words.raw.json']), output_sha256=magic.digest(tsv), generator_sha256=PRODUCER_SHA256)
    # Write only a fresh caller-selected directory. Embedded source is replayable.
    output.mkdir(parents=True)
    for name, raw in {**blobs, 'magic-words.manifest.json':source_manifest}.items(): (output/('behavior-source-' + name)).write_bytes(raw)
    (output/'behavior-source-namespace-registry.tsv').write_bytes(namespace_bytes)
    (output/'behavior-source-namespace-registry.manifest.json').write_bytes(namespace_sidecar)
    (output/'behavior-switches.tsv').write_bytes(tsv)
    (output/'behavior-switches.manifest.json').write_bytes(magic.document(manifest))
    return validate_snapshot(output, original['wiki'], original['date'])

def capture_artifacts(path, record=None):
    path=Path(path);root=path.parent if path.name=='behavior-switches.tsv' else path
    manifest=validate_snapshot(root)
    if record is not None and manifest != record: raise ValueError('Behavior capture changed')
    source=magic.parse_json(magic.read_regular(root/'behavior-source-magic-words.manifest.json'))
    _, names=magic.capture_profile(source)
    names={'behavior-source-'+name for name in names} | {'behavior-source-magic-words.manifest.json', 'behavior-switches.tsv', 'behavior-switches.manifest.json', 'behavior-source-namespace-registry.tsv', 'behavior-source-namespace-registry.manifest.json'}
    return {name:magic.digest(magic.read_regular(root/name)) for name in names}

if __name__ == '__main__':
    parser=argparse.ArgumentParser();parser.add_argument('source');parser.add_argument('output');parser.add_argument('namespace_registry');args=parser.parse_args()
    print(json.dumps(derive_snapshot(args.source,args.output,namespace_registry=args.namespace_registry),sort_keys=True))
