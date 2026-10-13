"""Authenticated private artifact roots for build-time output and cleanup."""
from contextlib import contextmanager
import os
from pathlib import Path
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
