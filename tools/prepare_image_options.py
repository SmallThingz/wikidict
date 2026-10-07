#!/usr/bin/env python3
"""Derive image option aliases from an existing authenticated behavior capture."""
import argparse
import json
from pathlib import Path
import unicodedata
import prepare_behavior_switches as behavior
import prepare_magic_words as magic

PROFILE = 'image-options-v1'
HEADER = '# wikidict-image-options-v1'
MAX_ROWS = 10000
# Parser::getImageParams keeps literal frame options ahead of argument options,
# and img_width after internal options (T372935). Alias order within each ID is
# the captured MediaWiki order used by MagicWordArray's anchored alternatives.
IDS = tuple('''img_left img_right img_center img_none img_baseline img_sub img_super
img_top img_text_top img_middle img_bottom img_text_bottom img_thumbnail img_framed
img_frameless img_border img_manualthumb img_upright img_link img_alt img_class
img_width img_page img_lang img_lossy timedmedia_thumbtime timedmedia_starttime
 timedmedia_endtime timedmedia_disablecontrols timedmedia_loop timedmedia_muted'''.split())
PRODUCER_SHA256 = magic.digest(Path(__file__).read_bytes())

def render(raw, wiki, date, content_language, namespace_registry_sha256, behavior_switches_sha256):
    query = magic.parse_json(raw).get('query', {})
    general = query.get('general', {})
    if general.get('wikiid') != wiki or general.get('lang') != content_language:
        raise ValueError('Image option source identity mismatch')
    words = query.get('magicwords')
    if not isinstance(words, list): raise ValueError('Missing image option inventory')
    selected = {}
    for word in words:
        name = word.get('name')
        if name not in IDS: continue
        if name in selected: raise ValueError('Duplicate image option identity')
        flag = word.get('case-sensitive', False)
        if type(flag) is not bool: raise ValueError('Invalid image option case flag')
        aliases = word.get('aliases')
        if not isinstance(aliases, list) or not aliases: raise ValueError('Missing image option aliases')
        for alias in aliases:
            if (not isinstance(alias, str) or not alias or len(alias.encode()) > 1024
                    or any(unicodedata.category(c) == 'Cc' and c not in '\n\r\t' for c in alias)
                    or alias.count('$1') > 1 or '$' in alias.replace('$1', '')):
                raise ValueError('Invalid image option alias pattern')
        selected[name] = (int(flag), aliases)
    if not {'img_thumbnail', 'img_alt', 'img_width'} <= selected.keys():
        raise ValueError('Incomplete image option inventory')
    rows = [(name, flag, alias) for name in IDS if name in selected
            for flag, aliases in [selected[name]] for alias in aliases]
    if len(rows) > MAX_ROWS: raise ValueError('Image option table exceeds native row bound')
    result = (HEADER + '\n# wiki\t' + wiki + '\n# dump-date\t' + date
              + '\n# content-language\t' + content_language
              + '\n# namespace-registry-sha256\t' + namespace_registry_sha256
              + '\n# behavior-switches-sha256\t' + behavior_switches_sha256 + '\n'
              + ''.join('%s\t%d\t%s\n' % (name, flag, json.dumps(alias, ensure_ascii=False)) for name, flag, alias in rows)).encode()
    if len(result) > magic.MAX_TSV_BYTES: raise ValueError('Image option table exceeds native byte bound')
    return result

def validate_snapshot(path, wiki=None, date=None, *, behavior_capture=None):
    path = Path(path); root = path.parent if path.name == 'image-options.tsv' else path
    if root.is_symlink() or not root.is_dir(): raise ValueError('Unsafe image option capture')
    prior = Path(behavior_capture) if behavior_capture is not None else root
    source = behavior.validate_snapshot(prior, wiki, date)
    raw = magic.read_regular(prior / 'behavior-source-magic-words.raw.json')
    manifest = magic.parse_json(magic.read_regular(root / 'image-options.manifest.json'))
    identity = {key: source[key] for key in ('wiki', 'date', 'content_language')}
    expected_metadata = dict(version=1, profile=PROFILE, **identity,
        namespace_registry_sha256=source['namespace_registry_sha256'],
        behavior_switches_sha256=magic.digest(magic.read_regular(prior / 'behavior-switches.tsv')),
        behavior_manifest_sha256=magic.digest(magic.read_regular(prior / 'behavior-switches.manifest.json')),
        raw_sha256=magic.digest(raw), temporal_scope=source['temporal_scope'],
        retrieved_utc=source['retrieved_utc'], generator_sha256=PRODUCER_SHA256)
    if type(manifest.get('version')) is not int or any(manifest.get(k) != v for k, v in expected_metadata.items()):
        raise ValueError('Image option manifest identity/provenance mismatch')
    expected = render(raw, namespace_registry_sha256=source['namespace_registry_sha256'], behavior_switches_sha256=expected_metadata['behavior_switches_sha256'], **identity)
    actual = magic.read_regular(root / 'image-options.tsv', magic.MAX_TSV_BYTES)
    if actual != expected or magic.digest(actual) != manifest.get('output_sha256'):
        raise ValueError('Changed image option table')
    return manifest

def derive_snapshot(source, output, wiki=None, date=None):
    source, output = Path(source), Path(output)
    prior = behavior.validate_snapshot(source, wiki, date)
    if output.exists() or output.is_symlink(): raise ValueError('Refusing to replace image option derivation')
    raw = magic.read_regular(source / 'behavior-source-magic-words.raw.json')
    identity = {key: prior[key] for key in ('wiki', 'date', 'content_language')}
    table = render(raw, namespace_registry_sha256=prior['namespace_registry_sha256'], behavior_switches_sha256=magic.digest(magic.read_regular(source / 'behavior-switches.tsv')), **identity)
    manifest = dict(version=1, profile=PROFILE, **identity,
        namespace_registry_sha256=prior['namespace_registry_sha256'],
        behavior_switches_sha256=magic.digest(magic.read_regular(source / 'behavior-switches.tsv')),
        behavior_manifest_sha256=magic.digest(magic.read_regular(source / 'behavior-switches.manifest.json')),
        raw_sha256=magic.digest(raw), temporal_scope=prior['temporal_scope'],
        retrieved_utc=prior['retrieved_utc'], generator_sha256=PRODUCER_SHA256,
        output_sha256=magic.digest(table))
    output.mkdir(parents=True)
    (output / 'image-options.tsv').write_bytes(table)
    (output / 'image-options.manifest.json').write_bytes(magic.document(manifest))
    return validate_snapshot(output, prior['wiki'], prior['date'], behavior_capture=source)

def capture_artifacts(path, record=None, *, behavior_capture=None):
    path = Path(path); root = path.parent if path.name == 'image-options.tsv' else path
    actual = validate_snapshot(root, behavior_capture=behavior_capture)
    if record is not None and record != actual: raise ValueError('Image option capture changed')
    prior = Path(behavior_capture) if behavior_capture is not None else root
    return {**behavior.capture_artifacts(prior),
            **{name: magic.digest(magic.read_regular(root / name))
               for name in ('image-options.tsv', 'image-options.manifest.json')}}

if __name__ == '__main__':
    parser = argparse.ArgumentParser(); parser.add_argument('source'); parser.add_argument('output')
    args = parser.parse_args()
    print(json.dumps(derive_snapshot(args.source, args.output), sort_keys=True))
