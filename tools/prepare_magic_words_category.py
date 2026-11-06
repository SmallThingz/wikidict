#!/usr/bin/env python3
"""Derive category aliases offline while preserving every immutable predecessor projection."""
import argparse
import datetime as dt
import hashlib
import json
from pathlib import Path
import unicodedata

import prepare_magic_words_statistics as prior

legacy = prior.legacy

PROFILE = 'title-parser-statistics-category-v1'
ISBN_PROFILE = 'title-parser-statistics-category-isbn-v1'
ISBN_DIRECTORY = 'magic-words-isbn-v1'
ISBN_SOURCE_MANIFEST = 'magic-words.category-source.manifest.json'
ISBN_SOURCE_TSV = 'magic-words.category-source.tsv'
CATEGORY_WORDS = frozenset(('pagesincategory', 'pagesincategory_all', 'pagesincategory_pages', 'pagesincategory_subcats', 'pagesincategory_files', 'rawsuffix'))
DERIVED_DIRECTORY = 'magic-words-category-v1'
SOURCE_MANIFEST = 'magic-words.statistics-source.manifest.json'
SOURCE_TSV = 'magic-words.statistics-source.tsv'
ARTIFACTS = prior.ARTIFACTS | {SOURCE_MANIFEST, SOURCE_TSV}
ISBN_ARTIFACTS = ARTIFACTS | {ISBN_SOURCE_MANIFEST, ISBN_SOURCE_TSV}
STATISTICS_SHA256 = '10b2ada03838fdc65b7e2131f0fb6f9581dec18b05f1febcbb40dbd12320e652'
LST_SHA256 = prior.LST_SHA256
LANGUAGE_SHA256 = prior.LANGUAGE_SHA256
INT_SHA256 = prior.INT_SHA256
LEGACY_SHA256 = prior.LEGACY_SHA256
# Immutable canonical category-v7 preimage; its raw/TSV chain is replayed below.
CATEGORY_V7_PRODUCER_SHA256 = '374e289d3dd186391322fc223860c66b8e0a395041d7aee5c8d2a90d79e3c9de'
PRODUCER_SHA256 = hashlib.sha256(Path(__file__).read_bytes()).hexdigest()


def require_producers(manifest=None):
    prior.require_producers()
    if (legacy.digest(Path(__file__).read_bytes()) != PRODUCER_SHA256
            or legacy.digest(Path(prior.__file__).read_bytes()) != STATISTICS_SHA256):
        raise ValueError('Category magic-word producer or statistics dependency changed')
    dependencies = {'prepare_magic_words.py': LEGACY_SHA256,
                    'prepare_magic_words_int.py': INT_SHA256,
                    'prepare_magic_words_language.py': LANGUAGE_SHA256,
                    'prepare_magic_words_lst.py': LST_SHA256, 'prepare_magic_words_statistics.py': STATISTICS_SHA256}
    if manifest is not None:
        allowed = {PRODUCER_SHA256}
        if manifest.get('version') == 7:
            allowed.add(CATEGORY_V7_PRODUCER_SHA256)
        if (manifest.get('generator_sha256') not in allowed
                or manifest.get('dependency_sha256') != dependencies):
            raise ValueError('Category magic-word producer/dependency identity mismatch')


def render_snapshot(data, wiki, date, content_language):
    """Retain every statistics/parser/title row and add only captured category tokens."""
    original, _ = prior.render_snapshot(data, wiki, date, content_language)
    lines = original.decode('utf-8').split('\n')
    rows = set(lines[4:-1])
    seen = set()
    for word in data['query']['magicwords']:
        name = word['name']
        if name not in CATEGORY_WORDS:
            continue
        if name in seen:
            raise ValueError('Duplicate captured category magic-word record')
        seen.add(name)
        sensitive = word.get('case-sensitive', False)
        if type(sensitive) is not bool:
            raise ValueError('Invalid category magic-word case flag')
        aliases = word.get('aliases')
        if not isinstance(aliases, list) or not aliases or len(aliases) > 1000:
            raise ValueError('Missing or invalid category magic-word aliases')
        for alias in aliases:
            if (not isinstance(alias, str) or not alias
                    or len(alias.encode('utf-8')) > 1024
                    or any(unicodedata.category(c) == 'Cc' for c in alias)):
                raise ValueError('Unsafe category magic-word alias')
            rows.add(name + '\t' + str(int(sensitive)) + '\t' + alias)
    output = ('\n'.join(lines[:4]) + '\n' + ''.join(row + '\n' for row in sorted(rows))).encode()
    if len(output) > legacy.MAX_TSV_BYTES:
        raise ValueError('Category magic-word table exceeds the native registry limit')
    return output, len(rows)


def render_isbn_snapshot(data, wiki, date, content_language):
    original, original_rows = render_snapshot(data, wiki, date, content_language)
    words = [word for word in data['query']['magicwords'] if word['name'] == 'isbn']
    if not words:
        return original, original_rows
    if len(words) != 1:
        raise ValueError('ISBN projection requires at most one captured isbn record')
    word = words[0]
    sensitive = word.get('case-sensitive', False)
    aliases = word.get('aliases')
    if (type(sensitive) is not bool or not isinstance(aliases, list)
            or not aliases or len(aliases) > 1000):
        raise ValueError('Invalid captured isbn record')
    lines = original.decode('utf-8').split('\n')
    rows = set(lines[4:-1])
    seen_aliases = set()
    for alias in aliases:
        if (not isinstance(alias, str) or not alias
                or len(alias.encode('utf-8')) > 1024
                or any(unicodedata.category(c) == 'Cc' for c in alias)):
            raise ValueError('Unsafe isbn magic-word alias')
        if alias in seen_aliases:
            raise ValueError('Duplicate ISBN magic-word alias')
        seen_aliases.add(alias)
        rows.add('isbn\t' + str(int(sensitive)) + '\t' + alias)
    output = ('\n'.join(lines[:4]) + '\n' + ''.join(row + '\n' for row in sorted(rows))).encode()
    if len(output) > legacy.MAX_TSV_BYTES:
        raise ValueError('ISBN magic-word table exceeds the native registry limit')
    return output, len(rows)


def validate_capture(manifest, blobs, wiki=None, date=None):
    if not isinstance(manifest, dict) or type(manifest.get('version')) is not int:
        raise ValueError('Invalid magic-word capture version')
    if manifest['version'] not in (7, 9):
        return prior.validate_capture(manifest, blobs, wiki, date)
    isbn_profile = manifest['version'] == 9
    profile = ISBN_PROFILE if isbn_profile else PROFILE
    artifacts = ISBN_ARTIFACTS if isbn_profile else ARTIFACTS
    source_manifest = ISBN_SOURCE_MANIFEST if isbn_profile else SOURCE_MANIFEST
    source_tsv = ISBN_SOURCE_TSV if isbn_profile else SOURCE_TSV
    source_profile = PROFILE if isbn_profile else prior.PROFILE
    source_artifacts = ARTIFACTS if isbn_profile else prior.ARTIFACTS
    if manifest.get('profile') != profile:
        raise ValueError('Invalid Category magic-word projection profile')
    require_producers(manifest)
    if (wiki is not None and manifest.get('wiki') != wiki
            or date is not None and manifest.get('date') != date):
        raise ValueError('Category magic-word capture differs from requested edition/date')
    wiki, date = manifest.get('wiki'), manifest.get('date')
    legacy.identity(wiki, date)
    if (not isinstance(manifest.get('artifacts'), dict)
            or set(manifest['artifacts']) != artifacts or set(blobs) != artifacts):
        raise ValueError('Incomplete Category magic-word capture provenance')
    if any(legacy.digest(raw) != manifest['artifacts'][name] for name, raw in blobs.items()):
        raise ValueError('Changed Category magic-word capture artifact')
    original = legacy.parse_json(blobs[source_manifest])
    if (not isinstance(original, dict) or original.get('version') != (7 if isbn_profile else 6)
            or original.get('profile') != source_profile):
        raise ValueError('Magic-word derivation requires its authenticated predecessor')
    original_blobs = {name: blobs[name] for name in source_artifacts}
    original_blobs['magic-words.tsv'] = blobs[source_tsv]
    validator = validate_capture if isbn_profile else prior.validate_capture
    validator(original, original_blobs, wiki, date)
    source_identity = dict(profile=source_profile,
        manifest_sha256=legacy.digest(blobs[source_manifest]),
        output_sha256=legacy.digest(blobs[source_tsv]))
    if manifest.get('source_capture') != source_identity:
        raise ValueError('Category magic-word statistics source identity mismatch')
    for key in ('wiki', 'date', 'content_language', 'temporal_scope',
                'retrieved_utc', 'source_url', 'raw_sha256'):
        if manifest.get(key) != original.get(key):
            raise ValueError('Category magic-word source provenance differs: ' + key)
    if legacy.timestamp(manifest.get('derived_utc')) < legacy.timestamp(original['derived_utc']):
        raise ValueError('Category derivation predates statistics derivation')
    renderer = render_isbn_snapshot if isbn_profile else render_snapshot
    output, rows = renderer(legacy.parse_json(blobs['magic-words.raw.json']),
                            wiki, date, manifest['content_language'])
    if output != blobs['magic-words.tsv']:
        raise ValueError('Category magic-word output does not replay from raw capture')
    if (manifest.get('output_sha256') != legacy.digest(output)
            or manifest.get('output_bytes') != len(output) or manifest.get('rows') != rows
            or type(manifest.get('canonical_words')) is not int
            or manifest['canonical_words'] != legacy.canonical_word_count(output)):
        raise ValueError('Category magic-word output identity mismatch')
    return manifest


def validate_snapshot(path, wiki=None, date=None):
    path = Path(path)
    root = path.parent if path.name == 'magic-words.tsv' else path
    if root.is_symlink() or not root.is_dir():
        raise ValueError('Unsafe magic-word capture directory')
    manifest = legacy.parse_json(legacy.read_regular(root / 'magic-words.manifest.json'))
    if not isinstance(manifest, dict) or manifest.get('version') not in (7, 9):
        return prior.validate_snapshot(path, wiki, date)
    artifacts = ISBN_ARTIFACTS if manifest['version'] == 9 else ARTIFACTS
    blobs = {name: legacy.read_regular(root / name) for name in artifacts}
    return validate_capture(manifest, blobs, wiki, date)


def selected_snapshot_root(capture_root):
    root = Path(capture_root)
    isbn_root = root / ISBN_DIRECTORY
    if isbn_root.exists() or isbn_root.is_symlink():
        manifest = validate_snapshot(isbn_root)
        if manifest['version'] != 9 or manifest.get('profile') != ISBN_PROFILE:
            raise ValueError('ISBN capture directory requires the isbn projection')
        return isbn_root
    derived = root / DERIVED_DIRECTORY
    if derived.exists() or derived.is_symlink():
        manifest = validate_snapshot(derived)
        if manifest['version'] != 7 or manifest.get('profile') != PROFILE:
            raise ValueError('Category capture directory requires the category projection')
        return derived
    return prior.selected_snapshot_root(root)


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


def derive_snapshot(source, output, wiki=None, date=None, *, include_isbn=False):
    require_producers()
    source = Path(source)
    source = source.parent if source.name == 'magic-words.tsv' else source
    output = Path(output)
    profile = ISBN_PROFILE if include_isbn else PROFILE
    version = 9 if include_isbn else 7
    source_profile = PROFILE if include_isbn else prior.PROFILE
    source_artifacts = ARTIFACTS if include_isbn else prior.ARTIFACTS
    source_manifest = ISBN_SOURCE_MANIFEST if include_isbn else SOURCE_MANIFEST
    source_tsv = ISBN_SOURCE_TSV if include_isbn else SOURCE_TSV
    source_validator = validate_snapshot if include_isbn else prior.validate_snapshot
    original = source_validator(source, wiki, date)
    if original['version'] != (7 if include_isbn else 6) or original.get('profile') != source_profile:
        raise ValueError('Magic-word derivation requires its authenticated predecessor')
    wiki, date = original['wiki'], original['date']
    blobs = {name: legacy.read_regular(source / name) for name in source_artifacts}
    source_manifest_raw = legacy.read_regular(source / 'magic-words.manifest.json')
    if legacy.parse_json(source_manifest_raw) != original:
        raise ValueError('statistics capture changed during category derivation')
    validator = validate_capture if include_isbn else prior.validate_capture
    validator(original, blobs, wiki, date)
    source_identity = dict(profile=source_profile,
        manifest_sha256=legacy.digest(source_manifest_raw),
        output_sha256=legacy.digest(blobs['magic-words.tsv']))
    if output.exists() or output.is_symlink():
        existing = validate_snapshot(output, wiki, date)
        if existing.get('profile') != profile or existing.get('source_capture') != source_identity:
            raise ValueError('Existing Category derivation uses a different statistics capture')
        return existing, False
    renderer = render_isbn_snapshot if include_isbn else render_snapshot
    tsv, rows = renderer(legacy.parse_json(blobs['magic-words.raw.json']),
                        wiki, date, original['content_language'])
    artifacts = {**blobs, source_manifest: source_manifest_raw,
                 source_tsv: blobs['magic-words.tsv'], 'magic-words.tsv': tsv}
    manifest = dict(version=version, profile=profile, wiki=wiki, date=date,
        content_language=original['content_language'], temporal_scope=original['temporal_scope'],
        retrieved_utc=original['retrieved_utc'], source_url=original['source_url'],
        raw_sha256=original['raw_sha256'], output_sha256=legacy.digest(tsv), output_bytes=len(tsv),
        rows=rows, canonical_words=legacy.canonical_word_count(tsv), generator_sha256=PRODUCER_SHA256,
        dependency_sha256={'prepare_magic_words.py': LEGACY_SHA256,
                           'prepare_magic_words_int.py': INT_SHA256,
                           'prepare_magic_words_language.py': LANGUAGE_SHA256,
                    'prepare_magic_words_lst.py': LST_SHA256, 'prepare_magic_words_statistics.py': STATISTICS_SHA256},
        derived_utc=dt.datetime.now(dt.timezone.utc).isoformat(), source_capture=source_identity,
        artifacts={name: legacy.digest(body) for name, body in artifacts.items()})
    validate_capture(manifest, artifacts, wiki, date)
    require_producers()
    if (legacy.read_regular(source / 'magic-words.manifest.json') != source_manifest_raw
            or any(legacy.read_regular(source / name) != raw for name, raw in blobs.items())):
        raise ValueError('statistics capture changed during category derivation')
    legacy.write_capture(output, artifacts, manifest)
    return validate_snapshot(output, wiki, date), True


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    derive = commands.add_parser('derive')
    derive.add_argument('source', type=Path)
    derive.add_argument('output', type=Path)
    derive.add_argument('--include-isbn', action='store_true',
                        help='Derive the isbn profile from an immutable category v7 capture')
    verify = commands.add_parser('verify')
    verify.add_argument('path', type=Path)
    for command in (derive, verify):
        command.add_argument('--wiki')
        command.add_argument('--date')
    args = parser.parse_args()
    if args.command == 'derive':
        manifest, created = derive_snapshot(args.source, args.output, args.wiki, args.date,
                                           include_isbn=args.include_isbn)
        print(json.dumps(dict(manifest=manifest, created=created), ensure_ascii=False))
    else:
        print(json.dumps(validate_snapshot(args.path, args.wiki, args.date), ensure_ascii=False))


if __name__ == '__main__':
    main()
