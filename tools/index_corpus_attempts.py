"""Index physically closed full-edition invocations from the retained native driver."""
import argparse
import csv
from collections import defaultdict
from decimal import Decimal
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


def failed_builder_import(stderr, builder, modules):
    """Identify a single top-level import failure in the selected builder."""
    lines = stderr.decode('utf-8', errors='replace').splitlines()
    if len(lines) != 4 or lines[0] != 'Traceback (most recent call last):':
        return False
    frame = re.fullmatch(r'  File "([^"]+)", line ([1-9][0-9]*), in <module>', lines[1])
    error = re.fullmatch(r"ImportError: cannot import name '(\w+)' from '(\w+)' \((.+)\)", lines[3])
    if not frame or frame[1] != builder['path'] or not error or modules.get(error[2], {}).get('path') != error[3]:
        return False
    # A missing historical source or an unrelated traceback cannot establish
    # when production stopped. Match the actual unindented import in the file.
    try:
        source = checked(builder).decode().splitlines()
        statement = source[int(frame[2]) - 1]
    except (OSError, ValueError, IndexError):
        return False
    prefix = f'from {error[2]} import '
    return (statement.startswith(prefix) and lines[2] == '    ' + statement
            and error[1] in [name.strip() for name in statement[len(prefix):].split(',')]
            and 'def main():' in source[int(frame[2]):])


def attempt_key(base, path):
    # Keep the published legacy keys. Other owners retain receipts in their
    # own directories, so give those an explicit workspace-relative identity.
    relative = path.relative_to(Path.cwd()) if path.is_relative_to(Path.cwd()) else path
    if len(relative.parts) < 4 or Path(*relative.parts[-2:]) != CLOSURE:
        raise ValueError(f'Invalid attempt closure: {path}')
    if path.is_relative_to(base):
        local = path.relative_to(base)
        if len(local.parts) != 4 or not re.fullmatch(r'runtime[0-9]{2,}', local.parts[1]):
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
    joined = closure.get('terminal') == code and closure.get('reaped') is True
    # A failed payload can have an independently witnessed exit even when the
    # enclosing RD session lost its terminal. Keep that distinction in the TSV.
    failed_child_only = (type(code) is int and code != 0 and closure.get('reaped') is False
                         and closure.get('terminal') is None and closure.get('original_rd_terminal_known') is False
                         and closure.get('original_rd_reaped') is False and closure.get('original_rd_terminal') is None
                         and bool(closure.get('rd_receipt_gap')) and closure.get('errors') == []
                         and watchdog.get('cleanup_complete') is True and watchdog.get('guardian_exit_status') == 0
                         and watchdog.get('termination_reason') == 'child_exit')
    if (any(closure.get(k) is not True for k in (
            'source_after', 'source_lease_released', 'allocation_released',
            'local_proc_absent', 'ps_absent', 'host_namespace_identity_absent'))
            or owner.get('source_after') is not True
            or owner['returncode'] != code or watchdog['child_exit_status'] != code
            or not (joined or failed_child_only)):
        raise ValueError(f'Incomplete guardian closure: {path}')
    command = json.loads(checked(start['input_authority']))
    refs = command['source_refs']
    if 'source_refs_ref' in start:
        encoded = json.dumps(refs, sort_keys=True, separators=(',', ':')).encode()
        if (start['source_refs_ref'] != start['input_authority'] or len(refs) < 2
                or start['source_refs'] != refs[:2] or start.get('source_ref_count') != len(refs)
                or start.get('source_refs_sha256') != hashlib.sha256(encoded).hexdigest()):
            raise ValueError(f'Guardian source list differs: {path}')
    elif refs != start['source_refs']:
        raise ValueError(f'Guardian source list differs: {path}')
    if (command['argv'] != result['argv'] or command['cwd'] != result['cwd']
            or command['env'] != result['environment']
            or Path(command['qualification_root']).resolve(strict=True) != path.parents[1]):
        raise ValueError(f'Guardian command differs: {path}')
    argv = result['argv']

    def option(name):
        if argv.count(name) != 1 or argv.index(name) + 1 == len(argv):
            raise ValueError(f'Expected one {name}: {path}')
        return argv[argv.index(name) + 1]

    catalog = json.loads(option('--python-tooling-json'))
    manifest_path = Path(option('--input-manifest'))
    manifest_hash = option('--input-manifest-sha256')
    catalog_ref = command.get('current_python_catalog')
    if catalog_ref is None and 'selection' in command:
        selection = command['selection']
        if selection not in command['source_refs']:
            raise ValueError(f'Edition selection was not guarded: {path}')
        catalog_ref = json.loads(checked(selection))['python_tooling']
    if catalog_ref is not None:
        if json.loads(checked(catalog_ref)) != catalog:
            raise ValueError(f'Python catalog differs: {path}')
    else:
        # Older drivers put the manifest in the selection. Exact-snapshot builds
        # pin it directly in the command and list the auxiliary files separately.
        selection = command.get('input_selection')
        if (not isinstance(selection, dict) or not {'path', 'bytes', 'sha256'} <= selection.keys()
                or not any(all(ref.get(key) == value for key, value in selection.items()) for ref in refs)):
            raise ValueError(f'Missing guarded whole-edition selection: {path}')
        inputs = json.loads(checked(selection))
        if 'manifest' in inputs and command.get('input_step') == 'ordinary_whole':
            manifest_ref = inputs['manifest']
        elif set(inputs) == {'snapshots'} and argv.count('--exact-snapshot-selection') == 1:
            snapshots = inputs['snapshots']
            flags = [arg for arg in argv if arg.startswith('--') and arg.split('=', 1)[0].endswith('-snapshot')]
            if (not isinstance(snapshots, dict) or not snapshots
                    or sorted(flags) != sorted('--' + name + '-snapshot' for name in snapshots)
                    or any(ref not in refs or option('--' + name + '-snapshot') != ref['path']
                           for name, ref in snapshots.items())):
                raise ValueError(f'Guarded snapshots differ from selected arguments: {path}')
            matches = [ref for ref in refs if ref['path'] == str(manifest_path)]
            if len(matches) != 1:
                raise ValueError(f'Expected one guarded input manifest: {path}')
            manifest_ref = matches[0]
        else:
            raise ValueError(f'Missing guarded whole-edition selection: {path}')
        if (manifest_ref not in refs or manifest_ref['path'] != str(manifest_path)
                or manifest_ref['sha256'] != manifest_hash or manifest_path.stat().st_size != manifest_ref['bytes']):
            raise ValueError(f'Selected input manifest differs: {path}')
        guarded = {(ref['path'], ref['bytes'], ref['sha256']) for ref in refs}
        bootstrap = dict(zip(('build_resource_limits', 'build_watchdog_guardian'), refs[:2]))
        for name, ref in [('selector', catalog['selector']), *catalog['modules'].items()]:
            if (ref['path'], ref['bytes'], ref['sha256']) in guarded:
                continue
            # Some failed invocations selected a private Python catalog and ran
            # the watchdog from a separate installation of the same two modules.
            # Count the command only when both original payloads still verify.
            owner_ref = bootstrap.get(name)
            if (code != 0 and owner_ref is not None
                    and Path(owner_ref['path']).name == Path(ref['path']).name == name + '.py'
                    and (owner_ref['bytes'], owner_ref['sha256']) == (ref['bytes'], ref['sha256'])):
                checked(owner_ref)
                checked(ref)
                continue
            raise ValueError(f'Unguarded Python catalog member: {ref["path"]}')
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
    raw = manifest_path.read_bytes()
    if hashlib.sha256(raw).hexdigest() != manifest_hash:
        raise ValueError(f'Input manifest differs: {path}')
    manifest = json.loads(raw)
    if manifest['requested_editions'] != [edition]:
        raise ValueError(f'Expected one complete edition: {path}')
    dates = {item['date'] for item in manifest['files'] if item['wiki'] == edition}
    if len(dates) != 1:
        raise ValueError(f'Ambiguous input date: {path}')
    output = Path(option('--output')) / edition / dates.pop()
    # Diagnostics can span an entire edition. Verify the stream without
    # retaining it alongside the parsed source and tool records.
    stderr = result['stderr']
    with Path(stderr['path']).open('rb') as stream:
        if os.fstat(stream.fileno()).st_size != stderr['bytes']:
            raise ValueError(stderr['path'])
        diagnostic = None
        if code != 0 and result['stdout']['bytes'] == 0 and stderr['bytes'] <= 8192:
            diagnostic = stream.read()
        digest = (hashlib.sha256(diagnostic) if diagnostic is not None else hashlib.file_digest(stream, 'sha256')).hexdigest()
        if digest != stderr['sha256'] or os.fstat(stream.fileno()).st_size != stderr['bytes']:
            raise ValueError(stderr['path'])
    return {**closure, 'whole_edition_selected': True, 'page_limit': None,
            'presentation_audit_limit': None, 'edition_output': str(output),
            'failed_builder_import': diagnostic is not None and failed_builder_import(diagnostic, builder, catalog['modules']),
            'failed_child_only': failed_child_only,
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
    child_only = guardian and closure['failed_child_only']
    if closure['command_returncode'] != result['returncode'] or not (closure['reaped'] or child_only):
        raise ValueError(f'Command closure differs in {path}')
    # Hash the full stream while keeping bounded evidence for the two clocks.
    stdout = result['stdout']
    digest = hashlib.sha256()
    phases = []
    preflight_events = []
    last_phase = None
    with Path(stdout['path']).open('rb') as stream:
        for line in _hashed_phase_lines(stream, digest, 1024 * 1024):
            phase = json.loads(line.removeprefix('BUILD_PHASE '))
            last_phase = phase
            if phase['phase'] == 'selected_snapshot_resolution' and len(preflight_events) < 3:
                same_edition = (phase.get('edition'), phase.get('date')) == (edition, output.name)
                preflight_events.append(phase['event'] if same_edition and phase.get('scope') == 'pre_edition' else None)
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
    # The builder resolves snapshots before entering edition_build. An empty log
    # or an interrupted build still leaves its production time unknown.
    preflight_failed = (preflight_events == ['start', 'end'] and last_phase['phase'] == 'selected_snapshot_resolution'
                        and last_phase.get('status') == 'failure')
    failed_before_build = (not phases and not closure['ordinary_producer_passed'] and result['returncode'] != 0
                           and (preflight_failed or (guardian and closure['failed_builder_import'])))
    status = end['status'] if end else 'no-terminal-production-clock'
    return dict(edition=edition, attempt=attempt_key(base, path),
                command_exit=result['returncode'], ordinary_build_passed=bool(closure['ordinary_producer_passed']),
                production_status='failed-before-production' if failed_before_build else status,
                production_seconds=f"{end['seconds']:.3f}" if end else '',
                command_seconds=f"{result['elapsed_seconds']:.3f}", closed_unix=closure['closed_unix'],
                stdout_sha256=stdout['sha256'], closure_sha256=hashlib.sha256(data).hexdigest(),
                closure_path=str(path.relative_to(Path.cwd()) if path.is_relative_to(Path.cwd()) else path),
                closure_join='original-terminal-unknown' if child_only else 'reaped')


def refresh_retry_times(path, attempts):
    # Keep the historical and selected-output columns from the existing edition
    # inventory. Recompute later attempts from the index, including failures.
    groups = defaultdict(list)
    for attempt in attempts:
        groups[attempt['edition']].append(attempt)
    with path.open(newline='') as stream:
        editions = list(csv.DictReader(stream, delimiter='\t'))
    names = {row['edition'] for row in editions}
    if len(names) != len(editions) or groups.keys() - names:
        raise ValueError(f'Edition inventory differs: {path}')
    changed = False
    for row in editions:
        records = groups[row['edition']]
        clocked = [r for r in records if r['production_seconds']]
        statuses = [r['production_status'] for r in records]
        for record in records:
            status = record['production_status']
            if status not in ('success', 'failure', 'failed-before-production', 'no-terminal-production-clock'):
                raise ValueError(f'Unknown production status: {status}')
            if (status in ('success', 'failure')) != bool(record['production_seconds']):
                raise ValueError(f"Invalid production clock for {row['edition']}")
        later = sum((Decimal(r['production_seconds']) for r in clocked), Decimal(0))
        total = later + Decimal(row['known_seconds_through_351']) + Decimal(row['recovered_additional_success_seconds'])
        rate = ''
        if (row['selected_status'] in ('built', 'empty') and row['selected_input_xml_pages'] and total > 0
                and int(row['unknown_durations_through_351']) == 0
                and 'no-terminal-production-clock' not in statuses):
            rate = f"{Decimal(row['selected_input_xml_pages']) / total:.3f}"
        updated = dict(later_measured_successes=str(statuses.count('success')),
                       later_measured_failures=str(statuses.count('failure')),
                       later_unclocked_invocations=str(len(records) - len(clocked)),
                       later_measured_production_seconds=f'{later:.3f}', total_known_attempt_seconds=f'{total:.3f}',
                       selected_pages_per_recorded_attempt_second=rate)
        if any(row[key] != value for key, value in updated.items()):
            row.update(updated)
            changed = True
    return editions if changed else None


def merge_rows(out, base, rows, retry_times=None):
    previous = {}
    migrated = False
    if out.exists():
        with out.open(newline='') as stream:
            for row in csv.DictReader(stream, delimiter='\t'):
                if 'closure_join' not in row:
                    # The previous schema admitted only reaped closures.
                    row['closure_join'] = 'reaped'
                    migrated = True
                name = row['attempt']
                if name in previous or name != attempt_key(base, Path.cwd() / row['closure_path']):
                    raise ValueError(f'Ambiguous existing attempt {name}')
                previous[name] = row
    additions = []
    reclassified = False
    for row in rows:
        saved = previous.get(row['attempt'])
        if saved is None:
            additions.append(row)
        else:
            checked_row = {key: str(value) for key, value in row.items()}
            if saved == checked_row:
                continue
            if (row['production_status'] != 'failed-before-production'
                    or saved != {**checked_row, 'production_status': 'no-terminal-production-clock'}):
                raise ValueError(f"Existing attempt differs: {row['attempt']}")
            previous[row['attempt']] = checked_row
            reclassified = True
    rows = [*previous.values(), *additions]
    retry_rows = refresh_retry_times(retry_times, rows) if retry_times else None
    if additions or reclassified or migrated:
        write_rows(out, rows)
    if retry_rows:
        write_rows(retry_times, retry_rows)
    return len(additions)


def write_rows(out, rows):
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


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--receipts', type=Path, required=True, help='Directory of attempts under the working directory')
    parser.add_argument('--output', type=Path, required=True, help='New or existing TSV index')
    parser.add_argument('--retry-times', type=Path, help='Refresh the existing per-edition retry timing TSV alongside the index')
    parser.add_argument('--add', metavar='ATTEMPT', nargs='+', help='Read only the named attempt directories')
    parser.add_argument('--add-closure', type=Path, action='append', default=[],
                        help='Also read this exact whole-edition owner closure; no directory scan')
    parser.add_argument('--add-guardian-closure', type=Path, action='append', default=[],
                        help='Read an exact generic guardian closure and authenticate its direct whole-build command')
    args = parser.parse_args()
    if args.retry_times and (args.retry_times.resolve() == args.output.resolve()
                             or args.retry_times.resolve().parent != args.output.resolve().parent):
        parser.error('Retry times and the attempt index must be distinct files in the same directory')
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
        added = merge_rows(args.output, base, rows, args.retry_times)
    finally:
        os.close(directory)
    print(f'{added} new full-edition invocations')


if __name__ == '__main__':
    main()
