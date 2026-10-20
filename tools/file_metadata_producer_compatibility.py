"""Exact consumer compatibility for retained selected file metadata; never rewrites provenance.

The selected namespace change only appends optional interwiki support. Python
File/Media normalization remains byte-identical. Both current verifier sources
are pinned as well as every producer dependency; all evidence replay remains in
the ordinary verifiers. This is not freshly captured input authority.
"""
import hashlib
from pathlib import Path

HISTORICAL_DEPENDENCIES = {'src/shared/namespace_registry.zig': 'e414e4a1c86079ecff6c391a8dd030eeff518b30034a6f31dd71243a885febec', 'src/shared/title_case.zig': 'a2c5544973883ab3addd858e901c60bcbbeab06dc5b15befe3f032a12b8491e2', 'tools/category_tree_snapshot.py': '780ad35f32eaaeb274f1e8bcf916b1ae23135dd895f8ed787d46fb8bb49fcad4', 'tools/download_wiktionaries.py': '061472228c81890c4eecc670ea643c8793cb5928cde7854fa4896f5c3c3b29d2', 'tools/prepare_file_metadata.py': 'd2a09c741c3fb12ee1a59ea5ce6eeb9611105ffa782d90ca25d3a7b37acf23ab'}
CURRENT_SOURCE_HASHES = {'src/shared/namespace_registry.zig': '7a4392a8f08737b19c80b146eeb4c6be1c0d57e15ea21961e8bdc83d00de7181', 'src/shared/title_case.zig': 'a2c5544973883ab3addd858e901c60bcbbeab06dc5b15befe3f032a12b8491e2', 'tools/category_tree_snapshot.py': '780ad35f32eaaeb274f1e8bcf916b1ae23135dd895f8ed787d46fb8bb49fcad4', 'tools/download_wiktionaries.py': '061472228c81890c4eecc670ea643c8793cb5928cde7854fa4896f5c3c3b29d2', 'tools/prepare_file_metadata.py': 'd2a09c741c3fb12ee1a59ea5ce6eeb9611105ffa782d90ca25d3a7b37acf23ab', 'tools/prepare_file_metadata_v2.py': '66b701ae514aea4d0c8634d27e48ec221f4695f1a7e03f19526b9c18356974e4', 'tools/prepare_file_metadata_union.py': '747a688c4fc04dcfe466f06790c5711f0a6cc9d1ded0c0b2b946664711fe3ca1'}
HISTORICAL_CAPTURE_GENERATOR = '1c00f03e637c706bc26523d7f65ba4a9e23efc1bc87213d1f148540707688ff9'
HISTORICAL_UNION_GENERATOR = 'c34dd2e7ca239392b529a07c2716b3302e0eac9cc4149476b015649c224a9589'

# Exact selected198 metadata audit: seven standalone captures plus EN union children.
HISTORICAL_CAPTURE_EDITIONS = frozenset(('azwiktionary', 'bclwiktionary', 'bewwiktionary', 'bgwiktionary', 'bjnwiktionary', 'bnwiktionary', 'cawiktionary', 'enwiktionary'))

def _source_hashes(repository):
    result = {}
    for name in CURRENT_SOURCE_HASHES:
        path = Path(repository) / name
        if path.is_symlink() or not path.is_file():
            return None
        before = path.stat()
        raw = path.read_bytes()
        after = path.stat()
        stamp = lambda s: (s.st_dev, s.st_ino, s.st_size, s.st_mtime_ns, s.st_ctime_ns)
        if stamp(before) != stamp(after):
            return None
        result[name] = hashlib.sha256(raw).hexdigest()
    return result


def matches(manifest, current, kind, repository):
    # Preserve the ordinary exact-producer path for newly captured data.
    if all(manifest.get(key) == value for key, value in current.items()):
        return True
    allowed = HISTORICAL_CAPTURE_EDITIONS if kind == 'capture' else ('enwiktionary',) if kind == 'union' else ()
    if manifest.get('wiki') not in allowed or manifest.get('date') != '20261001':
        return False
    if _source_hashes(repository) != CURRENT_SOURCE_HASHES:
        return False
    dependencies = dict(HISTORICAL_DEPENDENCIES)
    dependencies['src/shared/namespace_registry.zig'] = CURRENT_SOURCE_HASHES['src/shared/namespace_registry.zig']
    old_capture = dict(generator_sha256=HISTORICAL_CAPTURE_GENERATOR, dependency_sha256=HISTORICAL_DEPENDENCIES)
    new_capture = dict(generator_sha256=CURRENT_SOURCE_HASHES['tools/prepare_file_metadata_v2.py'], dependency_sha256=dependencies)
    old = old_capture if kind == 'capture' else dict(generator_sha256=HISTORICAL_UNION_GENERATOR, capture_producer=old_capture)
    new = new_capture if kind == 'capture' else dict(generator_sha256=CURRENT_SOURCE_HASHES['tools/prepare_file_metadata_union.py'], capture_producer=new_capture)
    return current == new and all(manifest.get(key) == value for key, value in old.items())
