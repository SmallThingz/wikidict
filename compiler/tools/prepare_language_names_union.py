#!/usr/bin/env python3
"""Offline union of authenticated autonyms and disjoint explicit profiles.

Each child keeps its complete provenance and unchanged validator. Native TSV v1
allows new profiles after the original bytes, including its autonym suffix.

Union manifests bind the exact generator and dependency versions. Archived
unions must be verified in their original authenticated tooling context;
changing the producer does not reinterpret an existing manifest.
"""
import argparse
import hashlib
import json
from pathlib import Path
import tempfile

import prepare_file_metadata as evidence
import prepare_language_names_autonyms as autonyms
import prepare_language_names_generic as generic

SCHEMA = 'wikidict.language-names-profile-union.v1'
KIND = 'language-names'
COMPLETE = KIND + '.complete.json'
MANIFEST = KIND + '.manifest.json'
TSV = KIND + '.tsv'
MAX_FILE = 4 * 1024 * 1024
MAX_TOTAL = 64 * 1024 * 1024
MAX_MANIFEST = 256 * 1024
MAX_FILES = 1024
DEPENDENCIES = {
    'prepare_language_names_autonyms.py': 'bf84f0c4ff9549a054e213704031bab06bb0e6c0f6564183c44ee888a901d904',
    'prepare_language_names_generic.py': 'bbe9020879766923c63021b93016aa0edb5331be0b996671351cb4f953e6ebc3',
    'prepare_file_metadata.py': 'cc8684fd9d0b8e38d4ccf53730cb0863249b2706132c474a2c5c42c0e738d802',
}


def identity(raw):
    return dict(size=len(raw), sha256=hashlib.sha256(raw).hexdigest())


def producer():
    modules = {'prepare_language_names_autonyms.py': autonyms,
               'prepare_language_names_generic.py': generic,
               'prepare_file_metadata.py': evidence}
    for name, digest in DEPENDENCIES.items():
        if identity(autonyms.regular(Path(modules[name].__file__)))['sha256'] != digest:
            raise ValueError('Union dependency changed: ' + name)
    return dict(generator_sha256=identity(autonyms.regular(Path(__file__)))['sha256'],
                dependency_sha256=DEPENDENCIES)


def safe_root(path):
    path = Path(path).absolute()
    if any(p.is_symlink() for p in (path, *path.parents)) or not path.is_dir():
        raise ValueError('Unsafe capture directory')
    return path


def selected_profiles(values):
    if not isinstance(values, (tuple, list)) or not 1 <= len(values) <= 21:
        raise ValueError('Invalid explicit profile selection')
    if any(not generic.code(x) or x == '-' for x in values) or len(set(values)) != len(values):
        raise ValueError('Invalid or duplicate explicit profile')
    return sorted(values)


def sections(raw):
    """Check native keys/counts while retaining authenticated escaped row bytes."""
    if len(raw) > MAX_FILE or not raw.endswith(b'\n') or b'\0' in raw:
        raise ValueError('Invalid or excessive TSV')
    lines = raw.decode('utf-8').split('\n')
    if len(lines) < 5 or lines[0] != '# wikidict-language-names-v1':
        raise ValueError('Invalid TSV header')
    if any(not lines[i].startswith(prefix) for i, prefix in enumerate(
            ('# wiki\t', '# dump-date\t', '# content-language\t'), 1)):
        raise ValueError('Invalid TSV identity')
    header = ('\n'.join(lines[:4]) + '\n').encode()
    blocks, directions, seen, current, expected = {}, {}, set(), None, 0
    for line in lines[4:-1]:
        fields = line.split('\t')
        if fields[0] == 'C' and len(fields) == 4:
            if current is not None and len(seen) != expected:
                raise ValueError('Incomplete profile')
            display, mode, count = fields[1:]
            if not count.isascii() or not count.isdecimal() or int(count) > 20031:
                raise ValueError('Invalid profile count')
            key = (display, mode)
            if key in blocks or (key != ('-', 'dir') and
                    (mode not in generic.SCOPES or not (generic.code(display) or key == ('-', 'single')))):
                raise ValueError('Invalid or duplicate profile key')
            if key != ('-', 'dir') and sum(k != ('-', 'dir') for k in blocks) >= 64:
                raise ValueError('Too many profiles')
            current, expected, seen = key, int(count), set()
            blocks[key] = [line]
        elif fields[0] == 'N' and len(fields) == 5:
            key = (fields[1], fields[2])
            if key != current or key == ('-', 'dir') or not generic.code(fields[3]):
                raise ValueError('Name outside declared profile')
            if fields[3] in seen or len(seen) >= expected:
                raise ValueError('Duplicate or excessive name')
            # Original validators authenticate names and their exact escaping.
            seen.add(fields[3]); blocks[key].append(line)
        elif fields[0] == 'D' and len(fields) == 3:
            if current != ('-', 'dir') or not generic.code(fields[1]) or fields[2] not in ('ltr', 'rtl'):
                raise ValueError('Invalid direction row')
            if fields[1] in seen or len(seen) >= expected:
                raise ValueError('Duplicate or excessive direction')
            seen.add(fields[1]); directions[fields[1]] = fields[2]; blocks[current].append(line)
        else:
            raise ValueError('Invalid TSV row')
    if current is None or len(seen) != expected or ('-', 'dir') not in blocks:
        raise ValueError('Incomplete snapshot')
    return header, {k: ('\n'.join(v) + '\n').encode() for k, v in blocks.items()}, directions


def compose(base, addition, profiles):
    profiles = selected_profiles(profiles)
    header, old, directions = sections(base)
    new_header, new, new_directions = sections(addition)
    wanted = {(display, mode) for display in profiles for mode in generic.SCOPES}
    if header != new_header or any(new_directions.get(code) != value for code, value in directions.items()):
        raise ValueError('Snapshot identity or direction conflict')
    if set(new) != wanted | {('-', 'dir')} or wanted & set(old):
        raise ValueError('Unexpected, reserved, duplicate or overwriting profile')
    if len(set(old) | wanted) - 1 > 64:
        raise ValueError('Native profile limit exceeded')
    result = base + b''.join(new[(display, mode)] for display in profiles for mode in generic.SCOPES)
    sections(result)
    return result


def unadopted_directions(base, addition):
    old = sections(base)[2]
    new = sections(addition)[2]
    return {code: new[code] for code in sorted(new.keys() - old.keys())}


def child(root, helper):
    root = safe_root(root)
    manifest = helper.validate_snapshot(root / TSV)
    if manifest.get('schema') != helper.SCHEMA:
        raise ValueError('Unexpected child schema')
    names = sorted(set(manifest['artifacts']) | {MANIFEST, COMPLETE})
    if not 1 <= len(names) <= MAX_FILES:
        raise ValueError('Excessive child inventory')
    files, total = {}, 0
    for name in names:
        autonyms.safe_name(name)
        raw = autonyms.regular(root / name, MAX_FILE)
        total += len(raw)
        if total > MAX_TOTAL:
            raise ValueError('Excessive child evidence')
        files[name] = identity(raw)
    return manifest, files


def scratch():
    # The unchanged autonym validator also uses tempfile's default location.
    project = Path(evidence.__file__).resolve().parent.parent
    if project.name == 'compiler' and (project.parent / 'renderer/src').is_dir():
        project = project.parent
    root = project / '.tmp'
    parent = safe_root(Path(tempfile.gettempdir()))
    if not parent.is_relative_to(root):
        raise ValueError('Set task-owned TMPDIR inside repository .tmp')
    return parent


def replay(root, record, role, helper):
    files = record['files']
    if not isinstance(files, dict) or not 1 <= len(files) <= MAX_FILES:
        raise ValueError('Invalid archived inventory')
    total = 0
    with tempfile.TemporaryDirectory(prefix='names-union-', dir=scratch()) as temp:
        temp = Path(temp)
        for name, expected in sorted(files.items()):
            autonyms.safe_name(name)
            raw = autonyms.regular(root / (role + '.' + name), MAX_FILE)
            total += len(raw)
            if total > MAX_TOTAL or identity(raw) != expected:
                raise ValueError('Archived child changed or excessive')
            # Disposable replay files need no durable fsync; real artifacts do.
            with (temp / name).open('xb') as stream:
                stream.write(raw)
        manifest, actual_files = child(temp, helper)
        if actual_files != files or identity(autonyms.regular(temp / MANIFEST)) != record['manifest']:
            raise ValueError('Replayed child differs')
        return manifest, autonyms.regular(temp / TSV)


def inventory(root):
    result, total = {}, 0
    for path in root.iterdir():
        if path.name in (MANIFEST, COMPLETE):
            continue
        if path.name != TSV and not path.name.startswith(('base.', 'addition.')):
            raise ValueError('Unexpected union artifact')
        if len(result) >= 2 * MAX_FILES + 1:
            raise ValueError('Excessive union inventory')
        raw = autonyms.regular(path, MAX_FILE); total += len(raw)
        if total > MAX_TOTAL:
            raise ValueError('Excessive union evidence')
        result[path.name] = identity(raw)
    return dict(sorted(result.items()))


def validate_snapshot(path, wiki=None, date=None, require_complete=True):
    path = Path(path); root = safe_root(path.parent)
    if path.name != TSV:
        raise ValueError('Invalid union filename')
    raw = autonyms.regular(root / MANIFEST, MAX_MANIFEST); m = evidence.decode(raw)
    if (m.get('schema') != SCHEMA or m.get('kind') != KIND or m.get('header_version') != 1 or
            any(m.get(k) != v for k, v in producer().items()) or
            m.get('temporal_scope') != 'independent-current-api-observations' or
            m.get('atomic_observation') is not False or m.get('native_resolution_proven') is not False or
            m.get('corpus_query_closure_proven') is not False):
        raise ValueError('Unreviewed union producer or scope')
    if require_complete and evidence.decode(autonyms.regular(root / COMPLETE, MAX_MANIFEST)) != dict(schema=SCHEMA, manifest_sha256=identity(raw)['sha256']):
        raise ValueError('Union completion differs')
    if m.get('artifacts') != inventory(root) or set(m['children']) != {'base', 'addition'}:
        raise ValueError('Union inventory differs')
    expected_names = {TSV}
    for role in ('base', 'addition'):
        files = m['children'][role]['files']
        if not isinstance(files, dict) or not 1 <= len(files) <= MAX_FILES:
            raise ValueError('Invalid archived inventory')
        expected_names.update(role + '.' + autonyms.safe_name(name) for name in files)
    if set(m['artifacts']) != expected_names:
        raise ValueError('Unreferenced or missing child artifact')
    if selected_profiles(m['profiles_added']) != m['profiles_added']:
        raise ValueError('Noncanonical profile selection')
    old, base = replay(root, m['children']['base'], 'base', autonyms)
    added, addition = replay(root, m['children']['addition'], 'addition', generic)
    for key in ('wiki', 'date', 'content_language', 'namespace_registry_sha256'):
        if old[key] != added[key] or m.get(key) != old[key]:
            raise ValueError('Child identity differs')
    if (wiki is not None and wiki != old['wiki']) or (date is not None and date != old['date']):
        raise ValueError('Requested union identity differs')
    expected = compose(base, addition, m['profiles_added'])
    if (autonyms.regular(path) != expected or m.get('base_output') != identity(base) or
            m.get('output') != identity(expected) or m.get('output_bytes') != len(expected) or
            m.get('output_sha256') != identity(expected)['sha256'] or
            m.get('old_bytes_preserved_as_prefix') is not True or
            m.get('direction_policy') != 'preserve-base-confirm-overlap-new-directions-evidence-only' or
            m.get('unadopted_direction_rows') != unadopted_directions(base, addition)):
        raise ValueError('Union projection differs')
    return m


def union(base, addition, output, profiles):
    scratch()
    base, addition = safe_root(base), safe_root(addition)
    old, old_files = child(base, autonyms); added, new_files = child(addition, generic)
    if any(old[k] != added[k] for k in ('wiki', 'date', 'content_language', 'namespace_registry_sha256')):
        raise ValueError('Child identity differs')
    raw = autonyms.regular(base / TSV); extra = autonyms.regular(addition / TSV)
    profiles = selected_profiles(profiles); result = compose(raw, extra, profiles)
    output = Path(output).absolute(); safe_root(output.parent)
    output.mkdir(exist_ok=False)
    children = {}
    for role, source, files in (('base', base, old_files), ('addition', addition, new_files)):
        children[role] = dict(files=files, manifest=identity(autonyms.regular(source / MANIFEST)))
        for name, expected in files.items():
            data = autonyms.regular(source / name)
            if identity(data) != expected:
                raise ValueError('Child changed during archival')
            evidence.put(output / (role + '.' + name), data)
    evidence.put(output / TSV, result)
    m = dict(schema=SCHEMA, kind=KIND, header_version=1, **producer(),
             **{k: old[k] for k in ('wiki', 'date', 'content_language', 'namespace_registry_sha256')},
             children=children, profiles_added=profiles, base_output=identity(raw),
             output=identity(result), output_bytes=len(result),
             output_sha256=identity(result)['sha256'], old_bytes_preserved_as_prefix=True,
             direction_policy='preserve-base-confirm-overlap-new-directions-evidence-only',
             unadopted_direction_rows=unadopted_directions(raw, extra),
             temporal_scope='independent-current-api-observations', atomic_observation=False,
             native_resolution_proven=False, corpus_query_closure_proven=False,
             artifacts=inventory(output))
    if len(evidence.encoded(m)) > MAX_MANIFEST:
        raise ValueError('Excessive union manifest')
    evidence.document(output / MANIFEST, m)
    validate_snapshot(output / TSV, require_complete=False)
    evidence.document(output / COMPLETE, dict(schema=SCHEMA, manifest_sha256=identity(autonyms.regular(output / MANIFEST))['sha256']))
    return validate_snapshot(output / TSV)


def capture_artifacts(path, manifest=None):
    validated = validate_snapshot(path)
    if manifest is not None and manifest != validated:
        raise ValueError('Union changed')
    result = {name: row['sha256'] for name, row in validated['artifacts'].items()}
    for name in (MANIFEST, COMPLETE):
        result[name] = identity(autonyms.regular(Path(path).parent / name))['sha256']
    return result


if __name__ == '__main__':
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('base', type=Path); p.add_argument('addition', type=Path)
    p.add_argument('output', type=Path); p.add_argument('--profile', action='append', required=True)
    args = p.parse_args()
    print(json.dumps(union(args.base, args.addition, args.output, args.profile), sort_keys=True))
