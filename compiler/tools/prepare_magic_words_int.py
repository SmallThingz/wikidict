#!/usr/bin/env python3
"""Derive the int-enabled magic-word profile from immutable v1 evidence offline."""
import argparse
import datetime as dt
import hashlib
import json
from pathlib import Path
import unicodedata

import prepare_magic_words as legacy

PROFILE = 'title-and-parser-functions-int-v1'
DERIVED_DIRECTORY = 'magic-words-parser-int-v1'
ARTIFACTS = legacy.DERIVED_ARTIFACTS
LEGACY_SHA256 = '9ba059831575307b2b9cd51f1fea3094808de9b46d8172cd8304b9cd780496a0'
PRODUCER_SHA256 = hashlib.sha256(Path(__file__).read_bytes()).hexdigest()


def require_producers(manifest=None):
    if (legacy.digest(Path(__file__).read_bytes()) != PRODUCER_SHA256
            or legacy.digest(Path(legacy.__file__).read_bytes()) != LEGACY_SHA256):
        raise ValueError('Int magic-word producer or legacy dependency changed')
    if manifest is not None and (
            manifest.get('generator_sha256') != PRODUCER_SHA256
            or manifest.get('dependency_sha256') != {'prepare_magic_words.py': LEGACY_SHA256}):
        raise ValueError('Int magic-word producer/dependency identity mismatch')


def render_snapshot(data, wiki, date, content_language):
    """Keep the complete legacy v2 projection; add only captured int aliases."""
    original, _ = legacy.render_snapshot(data, wiki, date, content_language,
                                         legacy.PARSER_PROFILE)
    records = [word for word in data['query']['magicwords'] if word['name'] == 'int']
    if len(records) != 1:
        raise ValueError('Expected exactly one captured int magic-word record')
    word = records[0]
    sensitive = word.get('case-sensitive', False)
    if type(sensitive) is not bool:
        raise ValueError('Invalid int magic-word case flag')
    aliases = word.get('aliases')
    if not isinstance(aliases, list) or not aliases or len(aliases) > 1000:
        raise ValueError('Missing or invalid int magic-word aliases')
    lines = original.decode('utf-8').split('\n')
    rows = set(lines[4:-1])
    for alias in aliases:
        if (not isinstance(alias, str) or not alias
                or len(alias.encode('utf-8')) > 1024
                or any(unicodedata.category(c) == 'Cc' for c in alias)):
            raise ValueError('Unsafe int magic-word alias')
        rows.add('int\t' + str(int(sensitive)) + '\t' + alias)
    output = ('\n'.join(lines[:4]) + '\n' + ''.join(row + '\n' for row in sorted(rows))).encode()
    if len(output) > legacy.MAX_TSV_BYTES:
        raise ValueError('Int magic-word table exceeds the native registry limit')
    return output, len(rows)


def validate_capture(manifest, blobs, wiki=None, date=None):
    if not isinstance(manifest, dict) or type(manifest.get('version')) is not int:
        raise ValueError('Invalid magic-word capture version')
    if manifest['version'] != 3:
        return legacy.validate_capture(manifest, blobs, wiki, date)
    if manifest.get('profile') != PROFILE:
        raise ValueError('Invalid int magic-word projection profile')
    require_producers(manifest)
    if (wiki is not None and manifest.get('wiki') != wiki
            or date is not None and manifest.get('date') != date):
        raise ValueError('Int magic-word capture differs from requested edition/date')
    wiki, date = manifest.get('wiki'), manifest.get('date')
    legacy.identity(wiki, date)
    if (not isinstance(manifest.get('artifacts'), dict)
            or set(manifest['artifacts']) != ARTIFACTS or set(blobs) != ARTIFACTS):
        raise ValueError('Incomplete int magic-word capture provenance')
    if any(legacy.digest(raw) != manifest['artifacts'][name] for name, raw in blobs.items()):
        raise ValueError('Changed int magic-word capture artifact')
    source_manifest = legacy.parse_json(blobs[legacy.SOURCE_MANIFEST])
    if (legacy.capture_profile(source_manifest)[0] != legacy.TITLE_PROFILE
            or source_manifest['version'] != 1):
        raise ValueError('Int derivation requires an original v1 source capture')
    source_blobs = {name: blobs[name] for name in legacy.ARTIFACTS}
    source_blobs['magic-words.tsv'] = blobs[legacy.SOURCE_TSV]
    legacy.validate_capture(source_manifest, source_blobs, wiki, date)
    source_identity = dict(profile=legacy.TITLE_PROFILE,
        manifest_sha256=legacy.digest(blobs[legacy.SOURCE_MANIFEST]),
        output_sha256=legacy.digest(blobs[legacy.SOURCE_TSV]))
    if manifest.get('source_capture') != source_identity:
        raise ValueError('Int magic-word original source identity mismatch')
    for key in ('wiki', 'date', 'content_language', 'temporal_scope',
                'retrieved_utc', 'source_url', 'raw_sha256'):
        if manifest.get(key) != source_manifest.get(key):
            raise ValueError('Int magic-word source provenance differs: ' + key)
    if legacy.timestamp(manifest.get('derived_utc')) < legacy.timestamp(manifest['retrieved_utc']):
        raise ValueError('Int derivation predates source retrieval')
    output, rows = render_snapshot(legacy.parse_json(blobs['magic-words.raw.json']),
                                  wiki, date, manifest['content_language'])
    if output != blobs['magic-words.tsv']:
        raise ValueError('Int magic-word output does not replay from raw capture')
    if (manifest.get('output_sha256') != legacy.digest(output)
            or manifest.get('output_bytes') != len(output) or manifest.get('rows') != rows
            or type(manifest.get('canonical_words')) is not int
            or manifest['canonical_words'] != legacy.canonical_word_count(output)):
        raise ValueError('Int magic-word output identity mismatch')
    return manifest


def validate_snapshot(path, wiki=None, date=None):
    path = Path(path)
    root = path.parent if path.name == 'magic-words.tsv' else path
    if root.is_symlink() or not root.is_dir():
        raise ValueError('Unsafe magic-word capture directory')
    manifest = legacy.parse_json(legacy.read_regular(root / 'magic-words.manifest.json'))
    if not isinstance(manifest, dict) or manifest.get('version') != 3:
        return legacy.validate_snapshot(path, wiki, date)
    blobs = {name: legacy.read_regular(root / name) for name in ARTIFACTS}
    return validate_capture(manifest, blobs, wiki, date)


def selected_snapshot_root(capture_root):
    root = Path(capture_root)
    derived = root / DERIVED_DIRECTORY
    if derived.exists() or derived.is_symlink():
        manifest = validate_snapshot(derived)
        if manifest['version'] != 3 or manifest.get('profile') != PROFILE:
            raise ValueError('Int capture directory requires the int projection')
        return derived
    return legacy.selected_snapshot_root(root)


def derive_snapshot(source, output, wiki=None, date=None):
    require_producers()
    source = Path(source)
    source = source.parent if source.name == 'magic-words.tsv' else source
    output = Path(output)
    original = legacy.validate_snapshot(source, wiki, date)
    if original['version'] != 1:
        raise ValueError('Int derivation requires an original v1 source capture')
    wiki, date = original['wiki'], original['date']
    blobs = {name: legacy.read_regular(source / name) for name in legacy.ARTIFACTS}
    source_manifest_raw = legacy.read_regular(source / 'magic-words.manifest.json')
    if legacy.parse_json(source_manifest_raw) != original:
        raise ValueError('Original capture changed during int derivation')
    legacy.validate_capture(original, blobs, wiki, date)
    source_identity = dict(profile=legacy.TITLE_PROFILE,
        manifest_sha256=legacy.digest(source_manifest_raw),
        output_sha256=legacy.digest(blobs['magic-words.tsv']))
    if output.exists() or output.is_symlink():
        existing = validate_snapshot(output, wiki, date)
        if existing.get('profile') != PROFILE or existing.get('source_capture') != source_identity:
            raise ValueError('Existing int derivation uses a different original capture')
        return existing, False
    tsv, rows = render_snapshot(legacy.parse_json(blobs['magic-words.raw.json']),
                               wiki, date, original['content_language'])
    artifacts = {**blobs, legacy.SOURCE_MANIFEST: source_manifest_raw,
                 legacy.SOURCE_TSV: blobs['magic-words.tsv'], 'magic-words.tsv': tsv}
    manifest = dict(version=3, profile=PROFILE, wiki=wiki, date=date,
        content_language=original['content_language'], temporal_scope=original['temporal_scope'],
        retrieved_utc=original['retrieved_utc'], source_url=original['source_url'],
        raw_sha256=original['raw_sha256'], output_sha256=legacy.digest(tsv), output_bytes=len(tsv),
        rows=rows, canonical_words=legacy.canonical_word_count(tsv), generator_sha256=PRODUCER_SHA256,
        dependency_sha256={'prepare_magic_words.py': LEGACY_SHA256},
        derived_utc=dt.datetime.now(dt.timezone.utc).isoformat(), source_capture=source_identity,
        artifacts={name: legacy.digest(body) for name, body in artifacts.items()})
    validate_capture(manifest, artifacts, wiki, date)
    require_producers()
    if (legacy.read_regular(source / 'magic-words.manifest.json') != source_manifest_raw
            or any(legacy.read_regular(source / name) != raw for name, raw in blobs.items())):
        raise ValueError('Original capture changed during int derivation')
    legacy.write_capture(output, artifacts, manifest)
    return validate_snapshot(output, wiki, date), True


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    derive = commands.add_parser('derive')
    derive.add_argument('source', type=Path)
    derive.add_argument('output', type=Path)
    verify = commands.add_parser('verify')
    verify.add_argument('path', type=Path)
    for command in (derive, verify):
        command.add_argument('--wiki')
        command.add_argument('--date')
    args = parser.parse_args()
    if args.command == 'derive':
        manifest, created = derive_snapshot(args.source, args.output, args.wiki, args.date)
        print(json.dumps(dict(manifest=manifest, created=created), ensure_ascii=False))
    else:
        print(json.dumps(validate_snapshot(args.path, args.wiki, args.date), ensure_ascii=False))


if __name__ == '__main__':
    main()
