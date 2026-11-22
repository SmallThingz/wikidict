"""Authenticated private artifact roots for build-time output and cleanup."""
from contextlib import contextmanager
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import stat

_ACTIVE = None
_ACTIVE_PATHS = ()

def require(ok, message):
    if not ok:
        raise ValueError(message)

def canonical(path):
    path = Path(path)
    require(path.is_absolute() and str(path) == os.path.normpath(str(path))
            and '..' not in path.parts, 'Artifact path must be absolute and canonical')
    return path

def repository_path(path, repository):
    path = canonical(path)
    require(path.is_relative_to(Path(repository) / 'data')
            and not any(p.is_symlink() for p in (path, *path.parents)),
            'Use explicit non-symlink repository data paths')
    return path


EXECUTION_ROLES = ('state', 'output', 'raw', 'cache')
_FORMAT_SOURCE_NAMES = frozenset('alias_codec blob_catalog blob_files blob_format blob_root document_ir namespace_coverage part_kind presentation_codec presentation_types wikitext_syntax'.split())


def repository_root_from_tool(origin):
    tools = Path(origin).resolve().parent
    return tools.parent.parent if tools.name == 'tools' and tools.parent.name == 'compiler' else tools.parent


def producer_relative_path(name):
    """Map a former source name to its actual four-product repository path."""
    path = Path(name)
    require(not path.is_absolute() and '..' not in path.parts and path.parts,
            'Source name must be repository relative')
    parts = path.parts
    if path == Path('apps/android/app/src/main/cpp/egyptian_shape.cpp'):
        return 'renderer/src/shaping/android/egyptian_shape.cpp'
    if parts[0] == 'apps' and len(parts) >= 2:
        return str(Path('renderer' if parts[1] == 'shared' else parts[1], *parts[2:]))
    if parts[0] == 'src' and len(parts) >= 2:
        if parts[1] in ('decoder', 'ffi', 'frontend', 'native'):
            return str(Path('renderer') / path)
        if parts[1] == 'encoder' and ((len(parts) == 3 and path.suffix == '.zig' and path.stem in _FORMAT_SOURCE_NAMES)
                or str(path) in ('src/encoder/testdata/el-cell-line-height/modern.table.json', 'src/encoder/testdata/el-cell-line-height/ancient.table.json')):
            return str(Path('renderer/src/format', *parts[2:]))
        return str(Path('compiler') / path)
    if parts[0] == 'tools':
        return str(Path('compiler') / path)
    if parts[0] == 'docs':
        return str(Path('renderer' if path.name in ('reader-parity.md', 'rendering-validation.md') else 'compiler') / path)
    return str(path)


def producer_source_path(root, name):
    """Read the selected checkout's layout, including retained old projections."""
    root = Path(root)
    return root / (producer_relative_path(name) if (root / 'compiler/tools').is_dir() else name)


def source_inventory_key(inventory, name):
    """Choose one explicitly recorded spelling; never fill a manifest from disk."""
    candidates = {name, producer_relative_path(name)}
    selected = candidates.intersection(inventory)
    require(len(selected) == 1, 'Missing or ambiguous source inventory path: ' + name)
    return selected.pop()


_LEGACY_WRITER_PRODUCT_EMBED_FILES = (
    'tools/reviewed_language_aliases.json',
    'tools/testdata/shy-nom-owner/langues.lua',
    'tools/testdata/shy-nom-owner/section-langue.lua',
    'tools/testdata/shy-nom-owner/bases.lua',
    'tools/testdata/shy-nom-owner/langue.wikitext',
    'tools/testdata/fr-named-owner/langue.wikitext',
    'tools/testdata/yi-source-category/interwiktionary.wikitext',
    'tools/testdata/yi-source-category/interwiki.wikitext',
)
WRITER_PRODUCT_EMBED_FILES = tuple(producer_relative_path(name) for name in _LEGACY_WRITER_PRODUCT_EMBED_FILES)
PRODUCER_SOURCE_FILES = ('build.zig', 'build.zig.zon', *WRITER_PRODUCT_EMBED_FILES)
PRODUCER_SOURCE_DIRECTORIES = ('compiler/src', 'compiler/tools', 'renderer/src')


def producer_source_inputs(root):
    if (Path(root) / 'compiler/tools').is_dir():
        return PRODUCER_SOURCE_FILES, PRODUCER_SOURCE_DIRECTORIES
    return ('build.zig', 'build.zig.zon', *_LEGACY_WRITER_PRODUCT_EMBED_FILES), ('src', 'tools')


def writer_product_source_inputs(manifest):
    """Select product embeds from an explicit future Writer source inventory.

    Never repair an incomplete inventory by reading the current checkout: its
    files may differ from the retained source selected for that Writer.
    """
    require(isinstance(manifest, dict), 'Writer source inventory must be a mapping')
    selected = {}
    for original in _LEGACY_WRITER_PRODUCT_EMBED_FILES:
        name = source_inventory_key(manifest, original)
        row = manifest.get(name)
        require(isinstance(row, dict), 'Missing Writer product source: ' + name)
        require(type(row.get('bytes')) is int and row['bytes'] >= 0
                and isinstance(row.get('sha256'), str)
                and re.fullmatch(r'[0-9a-f]{64}', row['sha256']) is not None
                and type(row.get('mode')) is int and 0 <= row['mode'] <= 0o7777,
                'Writer product source must bind bytes, SHA256 and mode: ' + name)
        selected[name] = dict(row)
    return selected


def execution_parent(repository):
    return Path(repository) / 'data/corpus-executions'


def refuse_execution_destinations(repository, paths):
    """Only the explicitly owned route may write in the execution namespace."""
    reserved = execution_parent(repository)
    selected = []
    for value in paths:
        if value is None:
            continue
        path = Path(value).absolute()
        for candidate in (path, path.resolve()):
            require(not candidate.is_relative_to(reserved) and not reserved.is_relative_to(candidate),
                    'Execution destination requires an explicit execution root')
        selected.append(path.resolve())
    if selected:
        mounts = execution_mounts()
        reserved_regions = execution_mount_regions(reserved.resolve(), mounts)
        for path in selected:
            for device, region in execution_mount_regions(path, mounts):
                require(not any(device == other_device and
                                (region.is_relative_to(other) or other.is_relative_to(region))
                                for other_device, other in reserved_regions),
                        'Default destination aliases the execution namespace')


def execution_mounts():
    # A bind mount can alias a writable subtree without a symlink or realpath change.
    mounts = []
    for line in Path('/proc/self/mountinfo').read_text().splitlines():
        fields = line.split()
        require(len(fields) >= 10 and '-' in fields[6:]
                and re.fullmatch(r'[0-9]+:[0-9]+', fields[2]), 'Invalid mount identity record')
        root, point = (re.sub(r'\\([0-7]{3})', lambda m: chr(int(m[1], 8)), value)
                       for value in fields[3:5])
        mounts.append((canonical(point), tuple(map(int, fields[2].split(':'))), root))
    require(mounts, 'Missing mount identity records')
    return mounts


def execution_mount_points():
    return [point for point, _, _ in execution_mounts()]


def execution_mount_regions(path, mounts):
    parents = [record for record in mounts if path.is_relative_to(record[0])]
    require(parents, 'Destination has no mount identity')
    point, device, root = max(parents, key=lambda record: len(record[0].parts))
    require(all(record == (point, device, root) for record in parents if record[0] == point),
            'Destination has ambiguous stacked mounts')
    # Descendant mount points can redirect writes even when the selected root
    # itself is disjoint. Compare only these mount records, never walk outputs.
    # Namespaced kernel mounts can expose noncanonical filesystem roots. Such
    # roots matter only when the mount participates in this destination.
    return [(device, canonical(root) / path.relative_to(point))] + [
        (device, canonical(root)) for point, device, root in mounts if point.is_relative_to(path)]


def execution_paths(spec, repository, source, *, artifact_spec, state, output, raw,
                    cache, downloads, manifest, manifest_sha256):
    """Bind one edition's mutable destinations; never infer ownership from a name."""
    require(isinstance(spec, dict) and set(spec) == {'root', *EXECUTION_ROLES},
            'Execution root must bind its root and all four role directories')
    roots = {name: OwnedArtifactRoot(identity) for name, identity in spec.items()}
    root = roots['root'].path
    repository, source = canonical(repository), canonical(source)
    require(root.parent == execution_parent(repository)
            and re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_-]{0,79}', root.name) is not None,
            'Execution root must be a direct child of the execution namespace')
    require((source == repository or source.is_relative_to(repository / '.tmp'))
            and source.resolve() == source and source.is_dir()
            and not any(p.is_symlink() for p in (source, *source.parents)),
            'Independent execution requires a canonical producer source')
    source_files, source_directories = producer_source_inputs(source)
    source_domains = ((source,) if source != repository else
                      tuple(source / name for name in (*source_files, *source_directories)))
    for path in source_domains:
        require(path.resolve() == path and not any(p.is_symlink() for p in (path, *path.parents)),
                'Execution source domain contains an alias')
    require(artifact_spec == spec['root'], 'Execution artifact root differs')
    identities = {(owner.spec['device'], owner.spec['inode']) for owner in roots.values()}
    require(len(identities) == len(roots), 'Execution directories alias the same inode')
    for name in EXECUTION_ROLES:
        require(roots[name].path == root / name
                and roots[name].spec['device'] == roots['root'].spec['device'],
                'Execution role must be a direct private child on the bound device')
    selected = dict(state=state, output=output, raw=raw, cache=cache)
    for name, value in selected.items():
        require(value is not None and canonical(value) == roots[name].path,
                'Execution destination differs from its owned role: ' + name)
    downloads = canonical(downloads)
    require(downloads.is_relative_to(repository / 'data')
            and downloads.resolve() == downloads and downloads.is_dir()
            and not any(p.is_symlink() for p in (downloads, *downloads.parents)),
            'Execution downloads must be a canonical read-only input directory')
    # In particular, a mount at the reserved namespace's parent can alias an
    # ordinary output while all selected path strings remain disjoint. Permit
    # the bound workspace's own mount, but no crossings or nested mounts in
    # these selected input/source/output domains.
    require(not any(point != repository and point.is_relative_to(repository)
                    and any(path.is_relative_to(point) or point.is_relative_to(path)
                            for path in (root, downloads, *source_domains))
                    for point in execution_mount_points()),
            'Execution source/input/output contains a mount alias')
    for path in (downloads, *source_domains):
        require(not path.is_relative_to(root) and not root.is_relative_to(path)
                and (not path.exists() or (path.stat().st_dev, path.stat().st_ino) not in identities),
                'Execution input/source overlaps a mutable destination')
    manifest = canonical(manifest)
    require(manifest == root / 'manifest.json', 'Execution manifest must be owned by the execution root')
    info = manifest.lstat()
    require(stat.S_ISREG(info.st_mode) and info.st_nlink == 1 and info.st_uid == os.geteuid()
            and not info.st_mode & 0o222 and 0 < info.st_size <= 16 * 1024 * 1024,
            'Execution manifest must be a private read-only regular file')
    payload = manifest.read_bytes()
    require(isinstance(manifest_sha256, str)
            and hashlib.sha256(payload).hexdigest() == manifest_sha256,
            'Execution manifest identity changed')
    data = json.loads(payload)
    editions = data.get('requested_editions') if isinstance(data, dict) else None
    require(isinstance(editions, list) and len(editions) == 1
            and isinstance(editions[0], str) and re.fullmatch(r'[a-z0-9_]+wiktionary', editions[0])
            and isinstance(data.get('files'), list) and data['files']
            and all(isinstance(row, dict) and row.get('wiki') == editions[0] for row in data['files']),
            'Independent execution requires exactly one manifest edition')
    after = manifest.lstat()
    require((info.st_dev, info.st_ino, info.st_mode, info.st_size, info.st_mtime_ns, info.st_ctime_ns)
            == (after.st_dev, after.st_ino, after.st_mode, after.st_size, after.st_mtime_ns, after.st_ctime_ns),
            'Execution manifest changed during validation')
    for owner in roots.values():
        owner.check()
    return dict(root=root, edition=editions[0], **{name: roots[name].path for name in EXECUTION_ROLES})

class OwnedArtifactRoot:
    def __init__(self, spec):
        require(isinstance(spec, dict) and set(spec) == {'path', 'device', 'inode', 'uid', 'mode'},
                'Artifact root identity fields differ')
        require(all(type(spec[k]) is int for k in ('device', 'inode', 'uid', 'mode'))
                and spec['device'] > 0 and spec['inode'] > 0
                and spec['uid'] == os.geteuid() and spec['mode'] == 0o700,
                'Artifact root must be privately owned by this user')
        self.spec = dict(spec)
        self.path = canonical(spec['path'])
        self.check()

    def matches(self, info):
        return (stat.S_ISDIR(info.st_mode) and
                (info.st_dev, info.st_ino, info.st_uid, stat.S_IMODE(info.st_mode)) ==
                tuple(self.spec[k] for k in ('device', 'inode', 'uid', 'mode')))

    def check(self):
        require(not any(p.is_symlink() for p in (self.path, *self.path.parents)),
                'Artifact root contains a symlink')
        require(self.matches(self.path.lstat()), 'Artifact root identity changed')

    def check_path(self, path, *, final_symlink=False):
        self.check()
        path = canonical(path)
        require(path != self.path and path.is_relative_to(self.path),
                'Artifact path escapes the bound root')
        nodes = []
        node = path
        while node != self.path:
            nodes.append(node)
            node = node.parent
        for node in reversed(nodes):
            try:
                info = node.lstat()
            except FileNotFoundError:
                continue
            require((node == path and final_symlink) or not stat.S_ISLNK(info.st_mode),
                    'Artifact path contains a symlink')
            require(info.st_dev == self.spec['device'] and info.st_uid == self.spec['uid'],
                    'Artifact path device or owner differs')
        return path

    @contextmanager
    def parent_fd(self, path, *, final_symlink=False):
        path = self.check_path(path, final_symlink=final_symlink)
        flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
        fd = os.open(self.path, flags)
        try:
            require(self.matches(os.fstat(fd)), 'Opened artifact root identity changed')
            for name in path.relative_to(self.path).parts[:-1]:
                next_fd = os.open(name, flags, dir_fd=fd)
                os.close(fd)
                fd = next_fd
                info = os.fstat(fd)
                require(info.st_dev == self.spec['device'] and info.st_uid == self.spec['uid'],
                        'Opened artifact parent device or owner differs')
            yield fd, path.name
            self.check()
        finally:
            os.close(fd)

    def remove_tree(self, path):
        require(getattr(shutil.rmtree, 'avoids_symlink_attacks', False),
                'FD-anchored artifact cleanup is unavailable')
        with self.parent_fd(path) as (fd, name):
            shutil.rmtree(name, dir_fd=fd)

    def unlink(self, path, *, missing_ok=False):
        with self.parent_fd(path, final_symlink=True) as (fd, name):
            try:
                os.unlink(name, dir_fd=fd)
            except FileNotFoundError:
                if not missing_ok:
                    raise

def validate_pipeline_paths(cfg, repository):
    for key in ('downloads', 'state_directory'):
        repository_path(cfg[key], repository)
    spec = cfg.get('artifact_root')
    if spec is None:
        for key in ('output', 'raw_shard_root'):
            repository_path(cfg[key], repository)
        return None
    root = OwnedArtifactRoot(spec)
    output = root.check_path(cfg['output'])
    raw = root.check_path(cfg['raw_shard_root'])
    require(not output.is_relative_to(raw) and not raw.is_relative_to(output),
            'Output and raw artifact roots overlap')
    for path in (output, raw):
        require(not path.exists() or path.is_dir(), 'Artifact role root is not a directory')
    return root

def configure_artifact_root(spec, output, raw_shard_root=None):
    global _ACTIVE, _ACTIVE_PATHS
    if spec is None:
        _ACTIVE, _ACTIVE_PATHS = None, ()
        return
    root = OwnedArtifactRoot(spec)
    paths = [root.check_path(output)]
    if raw_shard_root is not None:
        paths.append(root.check_path(raw_shard_root))
        require(not paths[0].is_relative_to(paths[1]) and not paths[1].is_relative_to(paths[0]),
                'Output and raw artifact roots overlap')
    require(all(not p.exists() or p.is_dir() for p in paths),
            'Artifact role root is not a directory')
    _ACTIVE, _ACTIVE_PATHS = root, tuple(paths)

def artifact_path(path, *, final_symlink=False):
    if _ACTIVE is None:
        return Path(path)
    path = _ACTIVE.check_path(path, final_symlink=final_symlink)
    require(any(path.is_relative_to(root) for root in _ACTIVE_PATHS),
            'Cleanup path is outside selected output and raw roots')
    return path

def remove_artifact_tree(path):
    path = artifact_path(path)
    if _ACTIVE is None:
        shutil.rmtree(path)
    else:
        _ACTIVE.remove_tree(path)

def unlink_artifact(path, *, missing_ok=False):
    path = artifact_path(path, final_symlink=True)
    if _ACTIVE is None:
        path.unlink(missing_ok=missing_ok)
    else:
        _ACTIVE.unlink(path, missing_ok=missing_ok)
