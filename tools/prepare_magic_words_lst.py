#!/usr/bin/env python3
"""Derive captured LST inclusion aliases from immutable language-profile evidence offline."""
import argparse
import datetime as dt
import hashlib
import json
from pathlib import Path
import unicodedata

import prepare_magic_words_language as prior

legacy = prior.legacy

PROFILE = 'title-and-parser-functions-lst-v1'
DERIVED_DIRECTORY = 'magic-words-parser-lst-v1'
SOURCE_MANIFEST = 'magic-words.language-source.manifest.json'
SOURCE_TSV = 'magic-words.language-source.tsv'
ARTIFACTS = prior.ARTIFACTS | {SOURCE_MANIFEST, SOURCE_TSV}
LANGUAGE_SHA256 = 'da7b83092268130b4ff733ff6e6ea4b18aac9f3a3be24fb6c55b056db7be8127'
INT_SHA256 = prior.INT_SHA256
LEGACY_SHA256 = prior.LEGACY_SHA256
PRODUCER_SHA256 = hashlib.sha256(Path(__file__).read_bytes()).hexdigest()


def require_producers(manifest=None):
    prior.require_producers()
    if (legacy.digest(Path(__file__).read_bytes()) != PRODUCER_SHA256
            or legacy.digest(Path(prior.__file__).read_bytes()) != LANGUAGE_SHA256):
        raise ValueError('LST magic-word producer or language dependency changed')
    dependencies = {'prepare_magic_words.py': LEGACY_SHA256,
                    'prepare_magic_words_int.py': INT_SHA256,
                    'prepare_magic_words_language.py': LANGUAGE_SHA256}
    if manifest is not None and (
            manifest.get('generator_sha256') != PRODUCER_SHA256
            or manifest.get('dependency_sha256') != dependencies):
        raise ValueError('LST magic-word producer/dependency identity mismatch')


def render_snapshot(data, wiki, date, content_language):
    """Keep the complete validated language projection; add only captured lst aliases."""
    original, count = prior.render_snapshot(data, wiki, date, content_language)
    records = [word for word in data['query']['magicwords'] if word['name'] == 'lst']
    if not records:
        return original, count
    if len(records) != 1:
        raise ValueError('Duplicate captured LST magic-word record')
    word = records[0]
    sensitive = word.get('case-sensitive', False)
    if type(sensitive) is not bool:
        raise ValueError('Invalid LST magic-word case flag')
    aliases = word.get('aliases')
    if not isinstance(aliases, list) or not aliases or len(aliases) > 1000:
        raise ValueError('Missing or invalid LST magic-word aliases')
    lines = original.decode('utf-8').split('\n')
    rows = set(lines[4:-1])
    for alias in aliases:
        if (not isinstance(alias, str) or not alias
                or len(alias.encode('utf-8')) > 1024
                or any(unicodedata.category(c) == 'Cc' for c in alias)):
            raise ValueError('Unsafe LST magic-word alias')
        rows.add('lst\t' + str(int(sensitive)) + '\t' + alias)
    output = ('\n'.join(lines[:4]) + '\n' + ''.join(row + '\n' for row in sorted(rows))).encode()
    if len(output) > legacy.MAX_TSV_BYTES:
        raise ValueError('LST magic-word table exceeds the native registry limit')
    return output, len(rows)


def validate_capture(manifest, blobs, wiki=None, date=None):
    if not isinstance(manifest, dict) or type(manifest.get('version')) is not int:
        raise ValueError('Invalid magic-word capture version')
    if manifest['version'] != 5:
        return prior.validate_capture(manifest, blobs, wiki, date)
    if manifest.get('profile') != PROFILE:
        raise ValueError('Invalid LST magic-word projection profile')
    require_producers(manifest)
    if (wiki is not None and manifest.get('wiki') != wiki
            or date is not None and manifest.get('date') != date):
        raise ValueError('LST magic-word capture differs from requested edition/date')
    wiki, date = manifest.get('wiki'), manifest.get('date')
    legacy.identity(wiki, date)
    if (not isinstance(manifest.get('artifacts'), dict)
            or set(manifest['artifacts']) != ARTIFACTS or set(blobs) != ARTIFACTS):
        raise ValueError('Incomplete LST magic-word capture provenance')
    if any(legacy.digest(raw) != manifest['artifacts'][name] for name, raw in blobs.items()):
        raise ValueError('Changed LST magic-word capture artifact')
    original = legacy.parse_json(blobs[SOURCE_MANIFEST])
    if (not isinstance(original, dict) or original.get('version') != 4
            or original.get('profile') != prior.PROFILE):
        raise ValueError('LST derivation requires an authenticated language capture')
    original_blobs = {name: blobs[name] for name in prior.ARTIFACTS}
    original_blobs['magic-words.tsv'] = blobs[SOURCE_TSV]
    prior.validate_capture(original, original_blobs, wiki, date)
    source_identity = dict(profile=prior.PROFILE,
        manifest_sha256=legacy.digest(blobs[SOURCE_MANIFEST]),
        output_sha256=legacy.digest(blobs[SOURCE_TSV]))
    if manifest.get('source_capture') != source_identity:
        raise ValueError('LST magic-word language source identity mismatch')
    for key in ('wiki', 'date', 'content_language', 'temporal_scope',
                'retrieved_utc', 'source_url', 'raw_sha256'):
        if manifest.get(key) != original.get(key):
            raise ValueError('LST magic-word source provenance differs: ' + key)
    if legacy.timestamp(manifest.get('derived_utc')) < legacy.timestamp(original['derived_utc']):
        raise ValueError('LST derivation predates language derivation')
    output, rows = render_snapshot(legacy.parse_json(blobs['magic-words.raw.json']),
                                  wiki, date, manifest['content_language'])
    if output != blobs['magic-words.tsv']:
        raise ValueError('LST magic-word output does not replay from raw capture')
    if (manifest.get('output_sha256') != legacy.digest(output)
            or manifest.get('output_bytes') != len(output) or manifest.get('rows') != rows
            or type(manifest.get('canonical_words')) is not int
            or manifest['canonical_words'] != legacy.canonical_word_count(output)):
        raise ValueError('LST magic-word output identity mismatch')
    return manifest


def validate_snapshot(path, wiki=None, date=None):
    path = Path(path)
    root = path.parent if path.name == 'magic-words.tsv' else path
    if root.is_symlink() or not root.is_dir():
        raise ValueError('Unsafe magic-word capture directory')
    manifest = legacy.parse_json(legacy.read_regular(root / 'magic-words.manifest.json'))
    if not isinstance(manifest, dict) or manifest.get('version') != 5:
        return prior.validate_snapshot(path, wiki, date)
    blobs = {name: legacy.read_regular(root / name) for name in ARTIFACTS}
    return validate_capture(manifest, blobs, wiki, date)


def selected_snapshot_root(capture_root):
    root = Path(capture_root)
    derived = root / DERIVED_DIRECTORY
    if derived.exists() or derived.is_symlink():
        manifest = validate_snapshot(derived)
        if manifest['version'] != 5 or manifest.get('profile') != PROFILE:
            raise ValueError('LST capture directory requires the LST projection')
        return derived
    raise ValueError('Missing required LST magic-word projection: ' + str(derived))


def capture_artifacts(path, manifest=None):
    path = Path(path)
    root = path.parent if path.name == 'magic-words.tsv' else path
    actual = validate_snapshot(path)
    if manifest is not None and manifest != actual:
        raise ValueError('Magic-word capture changed during artifact validation')
    result = dict(actual['artifacts'])
    result['magic-words.manifest.json'] = legacy.digest(
        legacy.read_regular(root / 'magic-words.manifest.json'))
    return result


def derive_snapshot(source, output, wiki=None, date=None):
    require_producers()
    source = Path(source)
    source = source.parent if source.name == 'magic-words.tsv' else source
    output = Path(output)
    original = prior.validate_snapshot(source, wiki, date)
    if original['version'] != 4 or original.get('profile') != prior.PROFILE:
        raise ValueError('LST derivation requires an authenticated language capture')
    wiki, date = original['wiki'], original['date']
    blobs = {name: legacy.read_regular(source / name) for name in prior.ARTIFACTS}
    source_manifest_raw = legacy.read_regular(source / 'magic-words.manifest.json')
    if legacy.parse_json(source_manifest_raw) != original:
        raise ValueError('Language capture changed during LST derivation')
    prior.validate_capture(original, blobs, wiki, date)
    source_identity = dict(profile=prior.PROFILE,
        manifest_sha256=legacy.digest(source_manifest_raw),
        output_sha256=legacy.digest(blobs['magic-words.tsv']))
    if output.exists() or output.is_symlink():
        existing = validate_snapshot(output, wiki, date)
        if existing.get('profile') != PROFILE or existing.get('source_capture') != source_identity:
            raise ValueError('Existing LST derivation uses a different language capture')
        return existing, False
    tsv, rows = render_snapshot(legacy.parse_json(blobs['magic-words.raw.json']),
                               wiki, date, original['content_language'])
    artifacts = {**blobs, SOURCE_MANIFEST: source_manifest_raw,
                 SOURCE_TSV: blobs['magic-words.tsv'], 'magic-words.tsv': tsv}
    manifest = dict(version=5, profile=PROFILE, wiki=wiki, date=date,
        content_language=original['content_language'], temporal_scope=original['temporal_scope'],
        retrieved_utc=original['retrieved_utc'], source_url=original['source_url'],
        raw_sha256=original['raw_sha256'], output_sha256=legacy.digest(tsv), output_bytes=len(tsv),
        rows=rows, canonical_words=legacy.canonical_word_count(tsv), generator_sha256=PRODUCER_SHA256,
        dependency_sha256={'prepare_magic_words.py': LEGACY_SHA256,
                           'prepare_magic_words_int.py': INT_SHA256,
                           'prepare_magic_words_language.py': LANGUAGE_SHA256},
        derived_utc=dt.datetime.now(dt.timezone.utc).isoformat(), source_capture=source_identity,
        artifacts={name: legacy.digest(body) for name, body in artifacts.items()})
    validate_capture(manifest, artifacts, wiki, date)
    require_producers()
    if (legacy.read_regular(source / 'magic-words.manifest.json') != source_manifest_raw
            or any(legacy.read_regular(source / name) != raw for name, raw in blobs.items())):
        raise ValueError('Language capture changed during LST derivation')
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
