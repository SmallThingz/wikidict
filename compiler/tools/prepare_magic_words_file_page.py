#!/usr/bin/env python3
"""Derive captured filepath/pagesize aliases without changing predecessor captures."""
import argparse
import datetime as dt
import hashlib
from pathlib import Path
import unicodedata

import prepare_magic_words_category as prior

legacy = prior.legacy
PROFILE = 'title-parser-statistics-category-file-page-v1'
VERSION = 10
DERIVED_DIRECTORY = 'magic-words-file-page-v1'
SOURCE_MANIFEST = 'magic-words.file-page-source.manifest.json'
SOURCE_TSV = 'magic-words.file-page-source.tsv'
WORDS = frozenset(('filepath', 'pagesize'))
CATEGORY_SHA256 = 'debefee6a63070e0b5bebc8e0f1f22635bce25c1e8a333f694a28a962508f06d'
PRODUCER_SHA256 = hashlib.sha256(Path(__file__).read_bytes()).hexdigest()


def require_producers():
    prior.require_producers()
    if (legacy.digest(Path(prior.__file__).read_bytes()) != CATEGORY_SHA256
            or legacy.digest(Path(__file__).read_bytes()) != PRODUCER_SHA256):
        raise ValueError('File/page alias producer changed')


def render_snapshot(data, wiki, date, language, source_version):
    renderer = prior.render_snapshot if source_version == 7 else prior.render_isbn_snapshot if source_version == 9 else None
    if renderer is None:
        raise ValueError('File/page aliases require category v7 or ISBN v9')
    original, _ = renderer(data, wiki, date, language)
    lines = original.decode().splitlines()
    rows, seen = set(lines[4:]), set()
    for word in data['query']['magicwords']:
        name = word['name']
        if name not in WORDS:
            continue
        aliases, flag = word.get('aliases'), word.get('case-sensitive', False)
        if (name in seen or type(flag) is not bool or not isinstance(aliases, list)
                or not 1 <= len(aliases) <= 1000):
            raise ValueError('Invalid file/page magic-word declaration')
        seen.add(name)
        used = set()
        for alias in aliases:
            if (not isinstance(alias, str) or not alias or len(alias.encode()) > 1024 or alias in used
                    or any(unicodedata.category(c) in ('Cc', 'Cs') for c in alias)):
                raise ValueError('Unsafe or duplicate file/page alias')
            used.add(alias)
            rows.add(name + '\t' + str(int(flag)) + '\t' + alias)
    output = ('\n'.join(lines[:4]) + '\n' + ''.join(row + '\n' for row in sorted(rows))).encode()
    if len(output) > legacy.MAX_TSV_BYTES:
        raise ValueError('File/page aliases exceed native registry bound')
    return output, len(rows)


def validate_capture(manifest, blobs, wiki=None, date=None):
    require_producers()
    if (not isinstance(manifest, dict) or type(manifest.get('version')) is not int
            or manifest['version'] != VERSION or manifest.get('profile') != PROFILE
            or manifest.get('generator_sha256') != PRODUCER_SHA256
            or manifest.get('dependency_sha256') != {'prepare_magic_words_category.py': CATEGORY_SHA256}):
        raise ValueError('Invalid file/page alias provenance')
    if (wiki is not None and manifest.get('wiki') != wiki) or (date is not None and manifest.get('date') != date):
        raise ValueError('File/page alias edition/date differs')
    wiki, date = manifest.get('wiki'), manifest.get('date')
    legacy.identity(wiki, date)
    original = legacy.parse_json(blobs[SOURCE_MANIFEST])
    version = original.get('version') if isinstance(original, dict) else None
    if type(version) is not int or version not in (7, 9):
        raise ValueError('Missing authenticated category/ISBN predecessor')
    source_artifacts = prior.ARTIFACTS if version == 7 else prior.ISBN_ARTIFACTS
    expected = source_artifacts | {SOURCE_MANIFEST, SOURCE_TSV}
    if (set(blobs) != expected or not isinstance(manifest.get('artifacts'), dict)
            or set(manifest['artifacts']) != expected
            or any(legacy.digest(raw) != manifest['artifacts'][name] for name, raw in blobs.items())):
        raise ValueError('File/page alias artifact inventory differs')
    source_blobs = {name:blobs[name] for name in source_artifacts}
    source_blobs['magic-words.tsv'] = blobs[SOURCE_TSV]
    prior.validate_capture(original, source_blobs, wiki, date)
    source_identity = dict(profile=original['profile'], manifest_sha256=legacy.digest(blobs[SOURCE_MANIFEST]),
                           output_sha256=legacy.digest(blobs[SOURCE_TSV]))
    if manifest.get('source_capture') != source_identity:
        raise ValueError('File/page alias source identity differs')
    for key in ('wiki', 'date', 'content_language', 'temporal_scope', 'retrieved_utc', 'source_url', 'raw_sha256'):
        if manifest.get(key) != original.get(key):
            raise ValueError('File/page alias predecessor identity differs: ' + key)
    if legacy.timestamp(manifest.get('derived_utc')) < legacy.timestamp(original['derived_utc']):
        raise ValueError('File/page alias derivation predates source')
    output, rows = render_snapshot(legacy.parse_json(blobs['magic-words.raw.json']), wiki, date,
                                   original['content_language'], version)
    if (blobs['magic-words.tsv'] != output or manifest.get('output_sha256') != legacy.digest(output)
            or type(manifest.get('output_bytes')) is not int or manifest['output_bytes'] != len(output)
            or type(manifest.get('rows')) is not int or manifest['rows'] != rows
            or type(manifest.get('canonical_words')) is not int
            or manifest['canonical_words'] != legacy.canonical_word_count(output)):
        raise ValueError('File/page alias output does not replay')
    return manifest


def validate_snapshot(path, wiki=None, date=None):
    path = Path(path); root = path.parent if path.name == 'magic-words.tsv' else path
    if root.is_symlink() or not root.is_dir():
        raise ValueError('Unsafe file/page alias capture root')
    manifest = legacy.parse_json(legacy.read_regular(root / 'magic-words.manifest.json'))
    if not isinstance(manifest, dict) or manifest.get('version') != VERSION:
        return prior.validate_snapshot(path, wiki, date)
    original = legacy.parse_json(legacy.read_regular(root / SOURCE_MANIFEST))
    version = original.get('version') if isinstance(original, dict) else None
    if type(version) is not int or version not in (7, 9):
        raise ValueError('Invalid alias predecessor version')
    names = (prior.ARTIFACTS if version == 7 else prior.ISBN_ARTIFACTS) | {SOURCE_MANIFEST, SOURCE_TSV}
    blobs = {name:legacy.read_regular(root / name) for name in names}
    return validate_capture(manifest, blobs, wiki, date)


def capture_artifacts(path, manifest=None):
    path = Path(path); root = path.parent if path.name == 'magic-words.tsv' else path
    actual = validate_snapshot(path)
    if manifest is not None and actual != manifest:
        raise ValueError('File/page alias manifest changed')
    return dict(actual['artifacts'], **{'magic-words.manifest.json':legacy.digest(legacy.read_regular(root / 'magic-words.manifest.json'))})


def selected_snapshot_root(root):
    root = Path(root); selected = root / DERIVED_DIRECTORY
    if selected.exists() or selected.is_symlink():
        manifest = validate_snapshot(selected)
        if manifest.get('version') != VERSION or manifest.get('profile') != PROFILE:
            raise ValueError('Preferred file/page aliases require their projection')
        return selected
    return prior.selected_snapshot_root(root)


def derive_snapshot(source, output, wiki=None, date=None):
    require_producers()
    source, output = Path(source), Path(output)
    source = source.parent if source.name == 'magic-words.tsv' else source
    original = prior.validate_snapshot(source, wiki, date)
    version = original.get('version')
    if version not in (7, 9):
        raise ValueError('Derivation requires authenticated category v7 or ISBN v9')
    wiki, date = original['wiki'], original['date']
    source_names = prior.ARTIFACTS if version == 7 else prior.ISBN_ARTIFACTS
    blobs = {name:legacy.read_regular(source / name) for name in source_names}
    source_raw = legacy.read_regular(source / 'magic-words.manifest.json')
    if legacy.parse_json(source_raw) != original:
        raise ValueError('Alias source changed')
    prior.validate_capture(original, blobs, wiki, date)
    identity = dict(profile=original['profile'], manifest_sha256=legacy.digest(source_raw),
                    output_sha256=legacy.digest(blobs['magic-words.tsv']))
    if output.exists() or output.is_symlink():
        existing = validate_snapshot(output, wiki, date)
        if existing.get('profile') != PROFILE or existing.get('source_capture') != identity:
            raise ValueError('Existing file/page aliases use a different predecessor')
        return existing, False
    if output.resolve().is_relative_to(source.resolve()):
        raise ValueError('Derivation cannot modify source generation')
    tsv, count = render_snapshot(legacy.parse_json(blobs['magic-words.raw.json']), wiki, date,
                                  original['content_language'], version)
    artifacts = dict(blobs, **{SOURCE_MANIFEST:source_raw, SOURCE_TSV:blobs['magic-words.tsv'], 'magic-words.tsv':tsv})
    manifest = {key:original[key] for key in ('wiki', 'date', 'content_language', 'temporal_scope', 'retrieved_utc', 'source_url', 'raw_sha256')}
    manifest.update(version=VERSION, profile=PROFILE, output_sha256=legacy.digest(tsv), output_bytes=len(tsv),
                    rows=count, canonical_words=legacy.canonical_word_count(tsv), generator_sha256=PRODUCER_SHA256,
                    dependency_sha256={'prepare_magic_words_category.py':CATEGORY_SHA256},
                    derived_utc=dt.datetime.now(dt.timezone.utc).isoformat(), source_capture=identity,
                    artifacts={name:legacy.digest(raw) for name, raw in artifacts.items()})
    validate_capture(manifest, artifacts, wiki, date)
    if (legacy.read_regular(source / 'magic-words.manifest.json') != source_raw
            or any(legacy.read_regular(source / name) != raw for name, raw in blobs.items())):
        raise ValueError('Alias predecessor changed during derivation')
    legacy.write_capture(output, artifacts, manifest)
    return validate_snapshot(output, wiki, date), True


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('source', type=Path); p.add_argument('output', type=Path)
    p.add_argument('--wiki'); p.add_argument('--date'); args = p.parse_args()
    derive_snapshot(args.source, args.output, args.wiki, args.date)


if __name__ == '__main__':
    main()
