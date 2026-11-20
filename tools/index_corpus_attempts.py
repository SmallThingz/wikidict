"""Index physically closed full-edition invocations from the retained native driver."""
import argparse
import csv
import fcntl
import hashlib
import json
import math
import os
import re
import tempfile
from pathlib import Path

from corpus_controller import _hashed_phase_lines


def checked(reference):
    data = Path(reference['path']).read_bytes()
    if len(data) != reference['bytes'] or hashlib.sha256(data).hexdigest() != reference['sha256']:
        raise ValueError(reference['path'])
    return data


CLOSURE = Path('direct-runtime01/independent-closure01.json')


def attempt_key(base, path):
    # Keep the published legacy keys. Other owners retain receipts in their
    # own directories, so give those an explicit workspace-relative identity.
    relative = path.relative_to(Path.cwd()) if path.is_relative_to(Path.cwd()) else path
    if (len(relative.parts) < 4 or Path(*relative.parts[-2:]) != CLOSURE
            or not re.fullmatch(r'runtime[0-9]{2,}', relative.parts[-3])):
        raise ValueError(f'Invalid attempt closure: {path}')
    if path.is_relative_to(base):
        local = path.relative_to(base)
        if len(local.parts) != 4:
            raise ValueError(f'Invalid attempt closure: {path}')
        family, run = local.parts[:2]
        return family if run == 'runtime01' else f'{family}/{run}'
    return ('absolute:' if relative.is_absolute() else 'path:') + relative.parents[1].as_posix()


def guardian_whole(path, closure, result):
    """Recover whole-build scope from the guardian's authenticated invocation.

    Generic guardian closures also cover tests and metadata jobs. Only a direct
    selected build_wiktionaries invocation with one dated input is accepted here.
    Historical source files need not still exist: the closed source guard and
    its immutable command/catalog describe the invocation that actually ran.
    """
    def sibling(key, name):
        ref = closure[key]
        if Path(ref['path']).resolve(strict=True) != path.parent / name:
            raise ValueError(f'Guardian {key} belongs to a different attempt: {path}')
        return json.loads(checked(ref))

    start = sibling('start', 'start.json')
    owner = sibling('owner_result', 'owner-result.json')
    watchdog = sibling('watchdog', 'watchdog.json')
    code = result['returncode']
    if (any(closure.get(k) is not True for k in (
            'source_after', 'source_lease_released', 'allocation_released',
            'local_proc_absent', 'ps_absent', 'host_namespace_identity_absent'))
            or owner.get('source_after') is not True
            or owner['returncode'] != code or watchdog['child_exit_status'] != code
            or closure.get('terminal') != code or not closure.get('reaped')):
        raise ValueError(f'Incomplete guardian closure: {path}')
    command = json.loads(checked(start['input_authority']))
    if (command['argv'] != result['argv'] or command['cwd'] != result['cwd']
            or command['env'] != result['environment']
            or command['source_refs'] != start['source_refs']
            or Path(command['qualification_root']).resolve(strict=True) != path.parents[1]):
        raise ValueError(f'Guardian command differs: {path}')
    argv = result['argv']

    def option(name):
        if argv.count(name) != 1 or argv.index(name) + 1 == len(argv):
            raise ValueError(f'Expected one {name}: {path}')
        return argv[argv.index(name) + 1]

    catalog = json.loads(checked(command['current_python_catalog']))
    if json.loads(option('--python-tooling-json')) != catalog:
        raise ValueError(f'Python catalog differs: {path}')
    builder = catalog['modules']['build_wiktionaries']
    script = builder['path']
    if (argv.count(script) != 1 or argv.index(script) >= argv.index('--python-tooling-json')
            or any(arg in ('-c', '-m') for arg in argv[:argv.index(script)])
            or not any(all(ref.get(k) == builder[k] for k in ('path', 'bytes', 'sha256'))
                       for ref in command['source_refs'])):
        raise ValueError(f'Not a direct selected Builder: {path}')
    forbidden = ('--limit-pages', '--page-limit', '--presentation-audit-limit', '--presentation-audit-pages',
                 '--expander-only', '--prepare-only', '--indexed-page-outputs')
    if any(arg.split('=', 1)[0] in forbidden for arg in argv):
        raise ValueError(f'Partial build cannot be indexed as whole: {path}')
    edition = option('--wikis')
    after_wiki = argv.index('--wikis') + 2
    if after_wiki < len(argv) and not argv[after_wiki].startswith('--'):
        raise ValueError(f'Expected one wiki argument: {path}')
    manifest_path = Path(option('--input-manifest'))
    raw = manifest_path.read_bytes()
    if hashlib.sha256(raw).hexdigest() != option('--input-manifest-sha256'):
        raise ValueError(f'Input manifest differs: {path}')
    manifest = json.loads(raw)
    if manifest['requested_editions'] != [edition]:
        raise ValueError(f'Expected one complete edition: {path}')
    dates = {item['date'] for item in manifest['files'] if item['wiki'] == edition}
    if len(dates) != 1:
        raise ValueError(f'Ambiguous input date: {path}')
    output = Path(option('--output')) / edition / dates.pop()
    checked(result['stderr'])
    return {**closure, 'whole_edition_selected': True, 'page_limit': None,
            'presentation_audit_limit': None, 'edition_output': str(output),
            'command_returncode': code, 'ordinary_producer_passed': code == 0}


def read_execution(base, path, guardian=False):
    data = path.read_bytes()
    closure = json.loads(data)
    if not guardian and (not closure.get('whole_edition_selected') or any(closure.get(k) is not None for k in ('page_limit', 'presentation_audit_limit'))):
        return None
    if Path(closure['result']['path']).resolve(strict=True) != path.parents[1] / 'result01.json':
        raise ValueError(f'Result belongs to a different attempt: {path}')
    result = json.loads(checked(closure['result']))
    if guardian:
        closure = guardian_whole(path, closure, result)
    output = Path(closure['edition_output'])
    edition = output.parent.name
    if not edition.endswith('wiktionary') or not output.name.isdigit():
        raise ValueError(f'Invalid edition/date in {output}')
    argv = result['argv']
    if '--wikis' in argv and argv[argv.index('--wikis') + 1] != edition:
        raise ValueError(f'Edition differs in {path}')
    if closure['command_returncode'] != result['returncode'] or not closure['reaped']:
        raise ValueError(f'Command closure differs in {path}')
    # Hash the full stream, retaining only the two records that clock this edition.
    stdout = result['stdout']
    digest = hashlib.sha256()
    phases = []
    with Path(stdout['path']).open('rb') as stream:
        for line in _hashed_phase_lines(stream, digest, 1024 * 1024):
            phase = json.loads(line.removeprefix('BUILD_PHASE '))
            if phase['phase'] == 'edition_build':
                if (phase['edition'], phase['date']) != (edition, output.name) or len(phases) == 2:
                    raise ValueError(f'Unexpected edition phase in {path}')
                phases.append(phase)
        if stream.tell() != stdout['bytes'] or digest.hexdigest() != stdout['sha256']:
            raise ValueError(f'Build log differs: {stdout["path"]}')
    if [p['event'] for p in phases] not in ([], ['start'], ['start', 'end']):
        raise ValueError(f'Ambiguous production clock in {path}')
    end = phases[-1] if phases and phases[-1]['event'] == 'end' else None
    if guardian and result['returncode'] == 0 and end is None:
        raise ValueError(f'Successful guardian lacks a production clock: {path}')
    if end and (not math.isfinite(end['seconds']) or end['seconds'] < 0
                or end['status'] not in ('success', 'failure')
                or (end['status'] == 'success') != bool(closure['ordinary_producer_passed'])):
        raise ValueError(f'Production outcome differs in {path}')
    return dict(edition=edition, attempt=attempt_key(base, path),
                command_exit=result['returncode'], ordinary_build_passed=bool(closure['ordinary_producer_passed']),
                production_status=end['status'] if end else 'no-terminal-production-clock',
                production_seconds=f"{end['seconds']:.3f}" if end else '',
                command_seconds=f"{result['elapsed_seconds']:.3f}", closed_unix=closure['closed_unix'],
                stdout_sha256=stdout['sha256'], closure_sha256=hashlib.sha256(data).hexdigest(),
                closure_path=str(path.relative_to(Path.cwd()) if path.is_relative_to(Path.cwd()) else path))


def merge_rows(out, base, rows):
    previous = {}
    if out.exists():
        with out.open(newline='') as stream:
            for row in csv.DictReader(stream, delimiter='\t'):
                name = row['attempt']
                if name in previous or name != attempt_key(base, Path.cwd() / row['closure_path']):
                    raise ValueError(f'Ambiguous existing attempt {name}')
                previous[name] = row
    additions = []
    for row in rows:
        saved = previous.get(row['attempt'])
        if saved is None:
            additions.append(row)
        elif saved != {key: str(value) for key, value in row.items()}:
            raise ValueError(f"Existing attempt differs: {row['attempt']}")
    if not additions:
        return 0
    rows = [*previous.values(), *additions]
    with tempfile.NamedTemporaryFile(mode='w', dir=out.parent, newline='', delete=False) as stream:
        try:
            writer = csv.DictWriter(stream, fieldnames=rows[0].keys(), delimiter='\t', lineterminator='\n')
            writer.writeheader()
            writer.writerows(rows)
            stream.flush()
            os.fchmod(stream.fileno(), 0o644)
            os.replace(stream.name, out)
        finally:
            Path(stream.name).unlink(missing_ok=True)
    return len(additions)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--receipts', type=Path, required=True, help='Directory of attempts under the working directory')
    parser.add_argument('--output', type=Path, required=True, help='New or existing TSV index')
    parser.add_argument('--add', metavar='ATTEMPT', nargs='+', help='Read only the named attempt directories')
    parser.add_argument('--add-closure', type=Path, action='append', default=[],
                        help='Also read this exact whole-edition owner closure; no directory scan')
    parser.add_argument('--add-guardian-closure', type=Path, action='append', default=[],
                        help='Read an exact generic guardian closure and authenticate its direct whole-build command')
    args = parser.parse_args()
    base = args.receipts.resolve(strict=True)
    if args.add and any(Path(name).name != name or name in ('', '.', '..') for name in args.add):
        parser.error('Expected an attempt directory name')
    families = ([base / name for name in set(args.add or [])]
                if args.add or args.add_closure or args.add_guardian_closure else base.iterdir())
    rows = []
    for family in families:
        found = [read_execution(base, path) for path in family.glob('runtime[0-9]*/' + str(CLOSURE))]
        if args.add and not any(found):
            raise ValueError(f'No closed full-edition run in {family}')
        rows.extend(row for row in found if row is not None)
    for path in sorted({path.resolve(strict=True) for path in args.add_closure}):
        row = read_execution(base, path)
        if row is None:
            raise ValueError(f'Not a closed full-edition run: {path}')
        rows.append(row)
    for path in sorted({path.resolve(strict=True) for path in args.add_guardian_closure}):
        rows.append(read_execution(base, path, guardian=True))
    if not rows:
        raise ValueError('No closed full-edition runs found')
    selected = {}
    for row in rows:
        prior = selected.setdefault(row['closure_path'], row)
        if prior != row:
            raise ValueError(f"Closure changed during selection: {row['closure_path']}")
    rows = list(selected.values())
    rows.sort(key=lambda row: (row['edition'], row['closed_unix'], row['attempt']))
    directory = os.open(args.output.parent, os.O_RDONLY | os.O_DIRECTORY)
    try:
        fcntl.flock(directory, fcntl.LOCK_EX)
        added = merge_rows(args.output, base, rows)
    finally:
        os.close(directory)
    print(f'{added} new full-edition invocations')


if __name__ == '__main__':
    main()
