#!/usr/bin/env python3
"""Build every fully downloaded snapshot; publish verified extreme-XZ blobs."""
import argparse
import bz2
try:
    from compression import zstd
except ImportError:
    zstd = None
import concurrent.futures
from collections import deque
from contextlib import contextmanager
import fcntl
import hashlib
import tempfile
import json
import os
import re
from pathlib import Path
import shutil
import subprocess
import sys
import threading
import time
from compress_blobs import compress, compress_many, default_workers, verify_round_trip
from download_wiktionaries import digest, language_registry_snapshot, validate_item, write_language_registry, select_manifest_files

PROJECT = Path(__file__).resolve().parent.parent
SHARD_THRESHOLD_COMPRESSED_BYTES = 512 * 1024 * 1024
SHARD_PAGES = 100_000
SHARD_RETRIES = 3
SHARD_STATE_VERSION = 2
AUXILIARY_SNAPSHOT_NAMES = (
    'commons-data', 'category-stats', 'interface-messages', 'category-tree',
    'wikibase-sitelinks', 'wikibase-entity-text', 'file-metadata',
    'transclusion-redirects', 'namespace-registry', 'language-registry', 'magic-words',
)
MAX_TOTAL_BUILD_WORKERS = 8
MAX_PIPELINE_WORKERS = 4
MAX_PAGE_EXPANSION_WORKERS = 8
MAX_EXPANSION_TIMEOUT_MS = 3_600_000
MAX_PAGE_INDEX_LINE_BYTES = 1024 * 1024
MAX_PAGE_COVERAGE_BYTES = 64 * 1024
MEMORY_PER_BUILD_WORKER = 1536 * 1024 * 1024
CPU_UTILIZATION_TARGET = 0.75
RESOURCE_ADMISSION_WAIT_SECONDS = 10 * 60
RESOURCE_ADMISSION_POLL_SECONDS = 5

def expansion_deadline_args(value):
    if value is None:
        return []
    if type(value) is not int or not 1 <= value <= MAX_EXPANSION_TIMEOUT_MS:
        raise ValueError('Expansion timeout must be 1 through 3600000 milliseconds')
    return ['--expansion-timeout-ms',str(value)]


def acquire_build_resource_lock(path):
    """Serialize corpus envelopes so two snapshots cannot spend the same RAM."""
    from build_resource_limits import ContainmentUnavailable
    path.parent.mkdir(parents=True,exist_ok=True)
    fd=os.open(path,os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW,0o600)
    lock=os.fdopen(fd,'r+')
    try:
        fcntl.flock(lock,fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        lock.close()
        raise ContainmentUnavailable('Another Wikidict corpus build holds the resource lock') from None
    except BaseException:
        lock.close()
        raise
    return lock

def load_average():
    try:return max(0.0,os.getloadavg()[0])
    except OSError:return None

def safe_worker_budget(owned_workers=0):
    cpu=max(1,os.cpu_count() or 1)
    load=load_average()
    if load is None:
        cpu_workers=cpu
    else:
        external_load=max(0.0,load-owned_workers)
        cpu_workers=max(0,int(cpu*CPU_UTILIZATION_TARGET-external_load))
    from build_resource_limits import CHILD_CGROUP, MAX_BUILD_MEMORY, SUPERVISOR_CHILD_RESERVE, child_memory_limit_bytes
    memory_limit=MAX_BUILD_MEMORY
    if CHILD_CGROUP in os.environ:
        try:
            group_limit = child_memory_limit_bytes()
        except (OSError, ValueError):
            return 0
        if group_limit is None:
            return 0
        if type(group_limit) is not int or group_limit<=0:
            return 0
        memory_limit=min(memory_limit,group_limit)
    memory_workers=max(0,memory_limit-SUPERVISOR_CHILD_RESERVE)//MEMORY_PER_BUILD_WORKER
    return min(MAX_TOTAL_BUILD_WORKERS,cpu_workers,memory_workers)

def default_build_threads():
    return max(1,min(MAX_PIPELINE_WORKERS,safe_worker_budget()))

def ensure_language_registry(downloads, output, edition, date):
    source = downloads / edition / date / 'language-registry.tsv'
    if source.is_file():
        return source
    cached = output / edition / (date + '.language-registry.tsv')
    if cached.is_file():
        return cached
    content_language, text = language_registry_snapshot(edition)
    cached.parent.mkdir(parents=True, exist_ok=True)
    temp = cached.with_suffix(cached.suffix + '.part')
    temp.write_text(text, encoding='utf-8')
    os.replace(temp, cached)
    return cached


def sha256_file(path):
    with path.open('rb') as source:
        return hashlib.file_digest(source, 'sha256').hexdigest()


def read_small_json(path, max_bytes=64*1024):
    if path.is_symlink(): raise ValueError(f'Unsafe snapshot provenance path: {path}')
    with path.open('rb') as source:
        raw=source.read(max_bytes+1)
    if len(raw)>max_bytes: raise ValueError(f'Oversized snapshot provenance: {path}')
    return json.loads(raw)


def read_snapshot_sha(path):
    if path.is_symlink(): raise ValueError(f'Unsafe snapshot identity path: {path}')
    with path.open('rb') as source: raw=source.read(66)
    if not re.fullmatch(rb'[0-9a-f]{64}\n',raw):
        raise ValueError(f'Invalid snapshot identity: {path}')
    return raw[:64].decode('ascii')


def copy_verified_snapshot(source, destination, expected_sha):
    """Pin small external configuration bytes for the entire edition build."""
    if destination.is_symlink(): raise ValueError(f'Unsafe external snapshot path: {destination}')
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary=destination.with_name(destination.name+'.part')
    if temporary.exists() or temporary.is_symlink(): raise ValueError(f'Unsafe external snapshot path: {temporary}')
    try:
        shutil.copyfile(source,temporary)
        if sha256_file(temporary)!=expected_sha:
            raise ValueError('External snapshot changed while copying')
        os.replace(temporary,destination)
    finally:
        temporary.unlink(missing_ok=True)
    return destination


def validate_interwiki_provenance(snapshot, edition, expected_sha):
    provenance=snapshot.with_name('interwiki-map.provenance.json')
    if not provenance.is_file(): return
    record=read_small_json(provenance)
    if (not isinstance(record,dict) or record.get('wiki')!=edition or
            record.get('tsv_sha256')!=expected_sha or record.get('dump_date') is not None):
        raise ValueError('Interwiki map provenance differs from requested edition or bytes')
    raw=snapshot.with_name('interwiki-map.raw.json')
    if record.get('kind')=='current-siteinfo-interwikimap' and not raw.is_file():
        raise ValueError('Current interwiki map raw response is missing')
    if raw.is_file() and sha256_file(raw)!=record.get('raw_sha256'):
        raise ValueError('Interwiki map raw response differs from provenance')


def verified_auxiliary_hashes(snapshots, edition=None, date=None):
    hashes={}
    for name, source in sorted((snapshots or {}).items()):
        if name not in AUXILIARY_SNAPSHOT_NAMES:
            raise ValueError(f'Unknown auxiliary snapshot: {name}')
        path=Path(source).resolve(strict=True)
        if not path.is_file(): raise ValueError(f'Auxiliary snapshot is not a file: {path}')
        sha=sha256_file(path)
        if name=='magic-words':
            from prepare_magic_words import validate_snapshot
            validate_snapshot(path,edition,date)
        manifest=path.with_name(name+'.manifest.json')
        if manifest.is_file():
            record=read_small_json(manifest)
            if (not isinstance(record,dict) or
                    record.get('output_sha256',record.get('tsv_sha256'))!=sha or
                    ('tsv_sha256' in record and record['tsv_sha256']!=sha) or
                    (edition is not None and record.get('wiki')!=edition) or
                    (date is not None and record.get('date')!=date)):
                raise ValueError(f'Auxiliary snapshot differs from provenance: {path}')
        if name=='namespace-registry':
            with path.open(encoding='utf-8') as stream:header=[stream.readline().rstrip('\n') for _ in range(3)]
            if header[0]!='# wikidict-namespace-registry-v1' or (edition is not None and header[1]!='# wiki\t'+edition) or (date is not None and header[2]!='# dump-date\t'+date):
                raise ValueError('Namespace registry identifies a different edition or date')
        hashes[name]=sha
    return hashes



SOURCE_FIELDS=('wiki','date','name','url','size','sha1')

def selected_source(record, selected):
    if not isinstance(record,dict):raise ValueError('Invalid captured source identity')
    identity={key:record.get(key) for key in SOURCE_FIELDS}
    matches=[item for item in selected if item.get('name')==identity['name']]
    if len(matches)!=1 or {key:matches[0].get(key) for key in SOURCE_FIELDS}!=identity:
        raise ValueError('Captured source differs from selected dump inventory')
    return identity


def validate_capture_artifacts(root, record, required=()):
    artifacts=record.get('artifacts')
    if not isinstance(artifacts,dict) or any(name not in artifacts for name in required):raise ValueError('Missing capture artifact inventory')
    for name,digest in artifacts.items():
        if not isinstance(name,str) or Path(name).name!=name or name in ('.','..'):raise ValueError('Unsafe capture artifact name')
        path=root/name
        if not path.is_file() or not path.resolve().is_relative_to(root) or sha256_file(path)!=digest:raise ValueError('Missing or changed capture artifact: '+name)


def validate_captured_snapshot(name,path,capture,selected):
    record=read_small_json(path.with_name(name+'.manifest.json'))
    if name=='namespace-registry':
        if record.get('source_dump_files')!=[capture['source_xml']]:raise ValueError('Namespace source differs from capture')
        for key,artifact in [('raw_siteinfo_sha256','namespace-siteinfo.raw.json'),('dump_siteinfo_sha256','dump-siteinfo.xml')]:
            if record.get(key)!=capture['artifacts'][artifact]:raise ValueError('Namespace capture hash mismatch')
        if record.get('retrieved_utc')!=capture.get('retrieved_utc') or record.get('source_url')!=capture.get('siteinfo_source_url') or record.get('supplementary_api_scope')!=capture.get('siteinfo_temporal_scope'):raise ValueError('Namespace API observation mismatch')
    elif name=='category-stats':
        source=selected_source(dict(wiki=record.get('wiki'),date=record.get('date'),name=record.get('source'),url=record.get('source_url'),size=record.get('source_bytes'),sha1=record.get('source_sha1')),selected)
        if not source['name'].endswith('-category.sql.gz'):raise ValueError('Invalid category statistics source')
        if record.get('output')!=path.name or record.get('output_bytes')!=path.stat().st_size:raise ValueError('Category statistics output mismatch')
    elif name=='category-tree':
        sources=record.get('sources',{})
        if set(sources)!=set(('page','linktarget','categorylinks')):raise ValueError('Invalid category tree source inventory')
        for kind,source in sources.items():
            source=selected_source(source,selected)
            if not source['name'].endswith('-'+kind+'.sql.gz'):raise ValueError('Invalid category tree source table')
        if record.get('dump_siteinfo_sha256')!=capture['artifacts']['dump-siteinfo.xml'] or record.get('output_bytes')!=path.stat().st_size:raise ValueError('Category tree capture mismatch')


def resolve_edition_snapshot_options(manifest, groups, downloads, overrides=None):
    """Resolve each edition independently; never reuse another edition's captures."""
    captures=manifest.get('auxiliary_capture_roots',{})
    if not isinstance(captures,dict):raise ValueError('Invalid auxiliary capture roots')
    records=manifest.get('language_registries',[])
    if not isinstance(records,list):raise ValueError('Invalid language registry inventory')
    languages={}
    for record in records:
        if not isinstance(record,dict):raise ValueError('Invalid language registry record')
        key=(record.get('wiki'),record.get('date'))
        if key in languages:raise ValueError('Duplicate language registry identity')
        languages[key]=record
    result={}
    for edition,date in groups:
        snapshots={}
        captured=captures.get(edition)
        if captured is not None:
            if not isinstance(captured,str) or Path(captured).is_absolute() or '..' in Path(captured).parts:raise ValueError('Unsafe auxiliary capture root')
            root=(PROJECT/captured).resolve(strict=True)
            record=read_small_json(root/'capture.complete.json',2*1024*1024)
            if record.get('wiki')!=edition or record.get('date')!=date:raise ValueError('Auxiliary capture edition/date mismatch')
            if not root.is_relative_to(PROJECT.resolve()):raise ValueError('Capture root escapes project')
            selected=groups[(edition,date)]
            if len({item['name'] for item in selected})!=len(selected):raise ValueError('Duplicate selected source')
            source=selected_source(record.get('source_xml'),selected)
            if '-pages-meta-current' not in source['name']:raise ValueError('Capture lacks full-namespace XML')
            if record.get('namespace_mismatches')!=[]:raise ValueError('Capture namespace mismatch')
            for source in record.get('page_table_files',[]):selected_source(source,selected)
            validate_capture_artifacts(root,record,('dump-siteinfo.xml','namespace-siteinfo.raw.json','pagetable-dumpstatus.raw.json'))
            capture=record
            for marker in ('auxiliary-basic.complete.json','auxiliary-all.complete.json'):
                if (root/marker).exists():validate_capture_artifacts(root,read_small_json(root/marker))
            for name in AUXILIARY_SNAPSHOT_NAMES:
                path=root/(name+'.tsv')
                sidecar=root/(name+'.manifest.json')
                present=[p.exists() or p.is_symlink() for p in (path,sidecar)]
                if any(present) and (not all(present) or not path.is_file() or not sidecar.is_file()):raise ValueError(f'Uncommitted auxiliary snapshot: {path}')
                if all(present):snapshots[name]=path
            from prepare_magic_words import selected_snapshot_root
            magic_root=selected_snapshot_root(root)
            if magic_root.exists() or magic_root.is_symlink():
                if magic_root.is_symlink() or not magic_root.is_dir():raise ValueError('Unsafe magic-word capture root')
                path=magic_root/'magic-words.tsv'
                from prepare_magic_words import validate_snapshot
                validate_snapshot(path,edition,date)
                snapshots['magic-words']=path
        elif (downloads/edition/date/'namespace-registry.tsv').is_file():
            snapshots['namespace-registry']=downloads/edition/date/'namespace-registry.tsv'
        snapshots.update(overrides or {})
        if 'namespace-registry' not in snapshots:raise ValueError(f'Missing namespace registry for {edition}/{date}')
        if 'language-registry' not in snapshots:
            record=languages.get((edition,date))
            if record is None or record.get('name')!='language-registry.tsv':raise ValueError(f'Missing pinned language registry for {edition}/{date}')
            path=downloads/edition/date/record['name']
            if not path.is_file() or path.stat().st_size!=record.get('size') or sha256_file(path)!=record.get('sha256'):
                raise ValueError(f'Unverified language registry: {path}')
            snapshots['language-registry']=path.resolve(strict=True)
        language_record=languages.get((edition,date))
        language=Path(snapshots['language-registry'])
        if not language_record or language_record.get('name')!='language-registry.tsv' or language.stat().st_size!=language_record.get('size') or sha256_file(language)!=language_record.get('sha256'):raise ValueError('Language registry differs from pinned inventory')
        if captured is not None:
            for name,path in snapshots.items():
                if name!='language-registry':validate_captured_snapshot(name,Path(path),capture,selected)
        verified_auxiliary_hashes(snapshots,edition,date)
        result[(edition,date)]={'auxiliary_snapshots':snapshots}
        if captured is not None:
            triple=[root/name for name in ('interwiki-map.tsv','interwiki-map.raw.json','interwiki-map.provenance.json')]
            present=[p.exists() or p.is_symlink() for p in triple]
            if any(present) and (not all(present) or not all(p.is_file() for p in triple)):raise ValueError('Uncommitted interwiki snapshot')
        if captured is not None and (root/'interwiki-map.tsv').is_file():
            path=root/'interwiki-map.tsv'
            if not (root/'interwiki-map.provenance.json').is_file():raise ValueError('Uncommitted interwiki snapshot')
            validate_interwiki_provenance(path,edition,sha256_file(path))
            interwiki=read_small_json(root/'interwiki-map.provenance.json')
            if interwiki.get('raw_sha256')!=capture['artifacts']['namespace-siteinfo.raw.json'] or interwiki.get('retrieved_utc')!=capture.get('retrieved_utc') or interwiki.get('source_url')!=capture.get('siteinfo_source_url') or interwiki.get('kind')!='current-siteinfo-interwikimap' or 'dump_date' not in interwiki:raise ValueError('Interwiki API observation mismatch')
            if interwiki.get('tsv_bytes')!=path.stat().st_size or interwiki.get('raw_bytes')!=(root/'interwiki-map.raw.json').stat().st_size:raise ValueError('Interwiki artifact size mismatch')
            result[(edition,date)]['interwiki_snapshot']=path
    return result


def pipeline_snapshot_args(registry, snapshots):
    merged=dict(snapshots or {})
    merged.setdefault('language-registry',registry)
    return auxiliary_snapshot_args(merged)


def pinned_auxiliary_snapshots(snapshots, hashes, destination, capture_hashes=None):
    pinned={}
    for name,source in sorted((snapshots or {}).items()):
        source=Path(source)
        pinned[name]=copy_verified_snapshot(source,destination/(name+'.tsv'),hashes[name])
        if name=='magic-words':
            # Keep the immutable API observation with the private TSV copy so
            # revalidation after a long build still checks the captured source.
            from prepare_magic_words import validate_snapshot
            capture=validate_snapshot(source)
            for filename in sorted((set(capture['artifacts'])|{'magic-words.manifest.json'})-{'magic-words.tsv'}):
                path=source.with_name(filename)
                expected=((capture_hashes or {}).get(name) if filename=='magic-words.manifest.json'
                          else capture['artifacts'][filename])
                copy_verified_snapshot(path,destination/path.name,expected or sha256_file(path))
            validate_snapshot(pinned[name])
    return pinned


def auxiliary_snapshot_args(snapshots):
    return [piece for name,path in sorted((snapshots or {}).items())
            for piece in ('--'+name+'-snapshot',str(path))]


def source_fingerprint():
    """Hash build-relevant source so resumed shards never cross code revisions."""
    checksum=hashlib.sha256()
    files=[]
    for name in ('build.zig','build.zig.zon'):
        path=PROJECT/name
        if path.is_file(): files.append(path)
    for folder in ('src','tools'):
        root=PROJECT/folder
        if not root.is_dir(): continue
        files.extend(path for path in root.rglob('*') if path.is_file() and path.suffix in ('.zig','.py','.c','.h','.zon'))
    for path in sorted(files,key=lambda x:x.relative_to(PROJECT).as_posix()):
        checksum.update(path.relative_to(PROJECT).as_posix().encode())
        checksum.update(b'\0')
        with path.open('rb') as source:
            while chunk:=source.read(1024*1024): checksum.update(chunk)
        checksum.update(b'\0')
    return checksum.hexdigest()


def build_input_identity(items, zig, auxiliary_hashes, interwiki_sha, expansion_timeout_ms, auxiliary_snapshots=None):
    executable=shutil.which(zig)
    if executable is None:raise ValueError('Zig compiler executable is unavailable')
    identity=dict(version=1, source=source_fingerprint(),
                files=sorted([[i['wiki'],i['date'],i['name'],i['size'],i['sha1']] for i in items]),
                zig_sha256=sha256_file(Path(executable)),
                auxiliary_snapshot_sha256=auxiliary_hashes or {},
                interwiki_map_sha256=interwiki_sha, expansion_timeout_ms=expansion_timeout_ms)
    if auxiliary_snapshots and 'magic-words' in auxiliary_snapshots:
        manifest=Path(auxiliary_snapshots['magic-words']).with_name('magic-words.manifest.json')
        identity['auxiliary_capture_sha256']={'magic-words':sha256_file(manifest)}
    return identity


def require_build_identity(recorded, expected):
    if recorded!=expected:
        raise ValueError('Build inputs or compiler changed; rebuild in a new output directory (existing output preserved)')


def persist_build_identity(staging, identity):
    if identity is None:return
    if source_fingerprint()!=identity['source']:
        raise ValueError('Compiler source changed during build; refusing publication')
    path=staging/BUILD_IDENTITY_NAME
    temporary=path.with_suffix('.part')
    temporary.write_text(json.dumps(identity,sort_keys=True)+'\n')
    os.replace(temporary,path)


@contextmanager
def _remove_partial_stage_on_error(*paths):
    try:
        yield
    except BaseException:
        for path in paths:
            try: path.unlink(missing_ok=True)
            except OSError: pass
        raise


STAGE_TARGET_BYTES=256*1024
STAGE_MAX_MEMBER_BYTES=64*1024*1024
STAGE_PARALLEL_MAX_BYTES=8*1024*1024
STAGE_PARALLEL_PART_WORKERS=4
STAGE_PART_QUEUE_BYTES=512*1024*1024


def _stage_seekable_dump_serial(items, downloads, scratch, metadata=None):
    """Repack full-namespace dumps into bounded, page-aligned Zstandard frames.

    The downloaded meta-current parts are not indexed by page. A whole part can
    expand past the native reader's 128 MiB member limit, so a part boundary is
    not a safe stream boundary. Keep XML only in bounded memory while writing
    compressed members and their real offsets to scratch.
    """
    if zstd is None:
        raise RuntimeError('Python 3.14 compression.zstd is required for staged Zstandard dumps')
    parts=[]
    for item in sorted(items,key=lambda x:x['name']):
        source=downloads/item['wiki']/item['date']/item['name']
        with source.open('rb',buffering=0) as f:
            if f.read(3)!=b'BZh': raise ValueError(f'Expected bzip2 dump part: {source}')
        parts.append(source)
    if not parts: raise ValueError('No dump parts')
    dump=scratch/'pages.xml.zst'
    index=scratch/'pages-index.txt.bz2'
    target_bytes=STAGE_TARGET_BYTES
    max_member_bytes=STAGE_MAX_MEMBER_BYTES  # Strictly below the native reader's 128 MiB cap.
    open_tag=b'<page>'
    close_tag=b'</page>'
    started=time.monotonic()
    pages=members=xml_bytes=0
    dump_hash=hashlib.sha256()
    pending=bytearray()
    batch=bytearray()
    # Four ordinary members may compress concurrently. Large pages take the
    # original synchronous path after draining the queue, preserving order.
    max_parallel_bytes=STAGE_PARALLEL_MAX_BYTES
    max_queued_batches=4
    with _remove_partial_stage_on_error(dump,index), \
         dump.open('wb',buffering=0) as out, bz2.open(index,'wb',compresslevel=1) as offsets, \
         concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        queued=deque()

        def write_member(member, raw_len):
            nonlocal members
            info=zstd.get_frame_info(member)
            if info.decompressed_size!=raw_len or zstd.get_frame_size(member)!=len(member):
                raise ValueError('Staged Zstandard member is not one known-size frame')
            offsets.write(f'{out.tell()}:{members+1}:member{members}\n'.encode())
            if out.write(member)!=len(member): raise OSError('Short staged dump write')
            dump_hash.update(member)
            members+=1

        def finish_oldest():
            future,raw_len=queued.popleft()
            write_member(future.result(),raw_len)

        def flush():
            if not batch: return
            if len(batch)>max_parallel_bytes:
                while queued: finish_oldest()
                raw=bytes(batch)
                write_member(zstd.compress(raw,level=1),len(raw))
                batch.clear()
                return
            if len(queued)==max_queued_batches: finish_oldest()
            raw=bytes(batch)
            batch.clear()
            queued.append((pool.submit(zstd.compress,raw,level=1),len(raw)))

        for source in parts:
            with bz2.open(source,'rb') as inp:
                while chunk:=inp.read(1024*1024):
                    xml_bytes+=len(chunk)
                    pending.extend(chunk)
                    consumed=0
                    while (end:=pending.find(close_tag,consumed))>=0:
                        start=pending.find(open_tag,consumed)
                        if start<0 or start>end:
                            raise ValueError(f'Unexpected XML page close: {source}')
                        cut=end+len(close_tag)
                        page_bytes=cut-consumed
                        if page_bytes>max_member_bytes:
                            raise ValueError(f'XML page exceeds bounded Zstandard member: {source}')
                        if len(batch)+page_bytes>max_member_bytes: flush()
                        batch.extend(memoryview(pending)[consumed:cut])
                        consumed=cut
                        pages+=1
                        if len(batch)>=target_bytes: flush()
                    # Move the unfinished suffix once per read, rather than once per page.
                    del pending[:consumed]
                    if len(pending)>max_member_bytes:
                        raise ValueError(f'Unterminated or oversized XML page: {source}')
            # A split archive part may continue an XML page in the next part.
        if b'<page>' in pending:
            raise ValueError('Truncated XML page at end of dump')
        if len(batch)+len(pending)>max_member_bytes: flush()
        batch.extend(pending)
        flush()
        while queued: finish_oldest()
        if members==0:
            write_member(zstd.compress(b'',level=1),0)
    if metadata is not None:
        metadata.update({'source_pages':pages,'dump_codec':'zstd','dump_stream_kind':'multistream-zstd','dump_size':dump.stat().st_size,'dump_sha256':dump_hash.hexdigest(),
                         'index_size':index.stat().st_size,'index_sha256':sha256_file(index)})
    print(f'Staged Zstandard dump: pages={pages} members={members} xml_bytes={xml_bytes} compressed_bytes={dump.stat().st_size} seconds={time.monotonic()-started:.1f}',flush=True)
    return dump


class _SplitPageAcrossParts(Exception):
    pass


class _CancelledParallelStage(Exception):
    pass


class _PartFrameQueue:
    def __init__(self, cancelled, capacity):
        self.items=deque()
        self.bytes=0
        self.capacity=capacity
        self.cancelled=cancelled
        self.condition=threading.Condition()

    def put_frame(self, frame):
        with self.condition:
            while self.bytes+len(frame)>self.capacity and not self.cancelled.is_set():
                self.condition.wait(timeout=0.1)
            if self.cancelled.is_set(): raise _CancelledParallelStage()
            self.items.append(frame)
            self.bytes+=len(frame)
            self.condition.notify_all()

    def put_control(self, value):
        with self.condition:
            self.items.append(value)
            self.condition.notify_all()

    def get(self):
        with self.condition:
            while not self.items and not self.cancelled.is_set():
                self.condition.wait(timeout=0.1)
            if not self.items: raise _CancelledParallelStage()
            item=self.items.popleft()
            if isinstance(item,bytes): self.bytes-=len(item)
            self.condition.notify_all()
            return item

    def wake(self):
        with self.condition: self.condition.notify_all()


def _stage_seekable_dump_parallel(items, downloads, scratch, metadata=None):
    """Decode independent bzip2 parts concurrently into bounded frame queues.

    At most four part queues can hold frames, each capped at 512 MiB. The
    writer drains the current queue while its producer runs and preserves the
    original part order. No uncompressed or compressed intermediate reaches
    disk. Split XML pages use the existing serial framer instead.
    """
    if zstd is None:
        raise RuntimeError('Python 3.14 compression.zstd is required for staged Zstandard dumps')
    parts=[]
    for item in sorted(items,key=lambda x:x['name']):
        source=downloads/item['wiki']/item['date']/item['name']
        with source.open('rb',buffering=0) as stream:
            if stream.read(3)!=b'BZh': raise ValueError(f'Expected bzip2 dump part: {source}')
        parts.append(source)
    if len(parts)<2: return _stage_seekable_dump_serial(items,downloads,scratch,metadata)
    started=time.monotonic()
    dump=scratch/'pages.xml.zst'
    index=scratch/'pages-index.txt.bz2'
    open_tag=b'<page>'
    close_tag=b'</page>'
    cancelled=threading.Event()
    queues=[_PartFrameQueue(cancelled,STAGE_PART_QUEUE_BYTES) for _ in parts]

    def stage_part(source,output):
        try:
            if cancelled.is_set(): return
            pending=bytearray()
            batch=bytearray()
            pages=xml_bytes=0
            def flush():
                if not batch: return
                raw=bytes(batch)
                frame=zstd.compress(raw,level=1)
                info=zstd.get_frame_info(frame)
                if info.decompressed_size!=len(raw) or zstd.get_frame_size(frame)!=len(frame):
                    raise ValueError('Staged Zstandard member is not one known-size frame')
                output.put_frame(frame)
                batch.clear()

            with bz2.open(source,'rb') as inp:
                while chunk:=inp.read(1024*1024):
                    xml_bytes+=len(chunk)
                    pending.extend(chunk)
                    consumed=0
                    while (end:=pending.find(close_tag,consumed))>=0:
                        start=pending.find(open_tag,consumed)
                        if start<0 or start>end: raise _SplitPageAcrossParts(source)
                        cut=end+len(close_tag)
                        page_bytes=cut-consumed
                        if page_bytes>STAGE_MAX_MEMBER_BYTES:
                            raise ValueError(f'XML page exceeds bounded Zstandard member: {source}')
                        if len(batch)+page_bytes>STAGE_MAX_MEMBER_BYTES: flush()
                        batch.extend(memoryview(pending)[consumed:cut])
                        consumed=cut
                        pages+=1
                        if len(batch)>=STAGE_TARGET_BYTES: flush()
                    del pending[:consumed]
                    if len(pending)>STAGE_MAX_MEMBER_BYTES:
                        raise ValueError(f'Unterminated or oversized XML page: {source}')
            if b'<page>' in pending or any(pending.endswith(open_tag[:n]) for n in range(1,len(open_tag))):
                raise _SplitPageAcrossParts(source)
            if len(batch)+len(pending)>STAGE_MAX_MEMBER_BYTES: flush()
            batch.extend(pending)
            flush()
            output.put_control((pages,xml_bytes))
        except BaseException as exc:
            output.put_control(exc)

    try:
        with (concurrent.futures.ThreadPoolExecutor(max_workers=STAGE_PARALLEL_PART_WORKERS) as pool,
              _remove_partial_stage_on_error(dump,index),
              dump.open('wb',buffering=0) as out,
              bz2.open(index,'wb',compresslevel=1) as offsets_out):
            members=pages=xml_bytes=0
            dump_hash=hashlib.sha256()
            futures=[]
            try:
                for i in range(min(STAGE_PARALLEL_PART_WORKERS,len(parts))):
                    futures.append(pool.submit(stage_part,parts[i],queues[i]))
                for part_index,output in enumerate(queues):
                    while True:
                        item=output.get()
                        if isinstance(item,bytes):
                            offsets_out.write(f'{out.tell()}:{members+1}:member{members}\n'.encode())
                            if out.write(item)!=len(item): raise OSError('Short staged dump write')
                            dump_hash.update(item)
                            members+=1
                        elif isinstance(item,BaseException):
                            raise item
                        else:
                            part_pages,part_xml_bytes=item
                            pages+=part_pages
                            xml_bytes+=part_xml_bytes
                            break
                    next_index=part_index+STAGE_PARALLEL_PART_WORKERS
                    if next_index<len(parts):
                        futures.append(pool.submit(stage_part,parts[next_index],queues[next_index]))
                for future in futures: future.result()
                if members==0:
                    frame=zstd.compress(b'',level=1)
                    if zstd.get_frame_info(frame).decompressed_size!=0 or zstd.get_frame_size(frame)!=len(frame):
                        raise ValueError('Empty Zstandard frame lacks known size')
                    offsets_out.write(b'0:1:member0\n')
                    if out.write(frame)!=len(frame): raise OSError('Short staged dump write')
                    dump_hash.update(frame)
                    members=1
            except BaseException:
                cancelled.set()
                for output in queues: output.wake()
                for future in futures: future.cancel()
                raise
        if metadata is not None:
            metadata.update({'source_pages':pages,'dump_codec':'zstd','dump_stream_kind':'multistream-zstd',
                             'dump_size':dump.stat().st_size,'dump_sha256':dump_hash.hexdigest(),
                             'index_size':index.stat().st_size,'index_sha256':sha256_file(index)})
        print(f'Staged parallel Zstandard dump: pages={pages} members={members} xml_bytes={xml_bytes} compressed_bytes={dump.stat().st_size} seconds={time.monotonic()-started:.1f}',flush=True)
        return dump
    except _SplitPageAcrossParts:
        dump.unlink(missing_ok=True)
        index.unlink(missing_ok=True)
        print('XML page crosses archive part boundary; using serial stage',flush=True)
        return _stage_seekable_dump_serial(items,downloads,scratch,metadata)


def _stage_seekable_dump(items, downloads, scratch, metadata=None):
    return _stage_seekable_dump_parallel(items,downloads,scratch,metadata)


def phase_identity(items):
    first=items[0] if items else None
    if isinstance(first,dict):
        return first.get('wiki','unknown'),first.get('date','unknown')
    return 'unknown','unknown'


def stage_seekable_dump(items, downloads, scratch, metadata=None):
    edition,date=phase_identity(items)
    with build_phase(edition,date,'repack',parts=len(items)):
        return _stage_seekable_dump(items,downloads,scratch,metadata)


def count_page_index_rows(path):
    return inspect_page_index(path)['rows']


def index_identity(stat):
    return dict(device_major=os.major(stat.st_dev),device_minor=os.minor(stat.st_dev),inode=stat.st_ino,size=stat.st_size,mtime_ns=stat.st_mtime_ns)


def inspect_page_index(path):
    count=offset=0
    offsets={}
    digest=hashlib.sha256()
    with path.open('rb') as source:
        identity=index_identity(os.fstat(source.fileno()))
        while True:
            line=source.readline(MAX_PAGE_INDEX_LINE_BYTES+1)
            if not line: break
            if len(line)>MAX_PAGE_INDEX_LINE_BYTES:
                raise ValueError('Page index line exceeds size limit')
            digest.update(line)
            if line.rstrip(b'\n') and not line.startswith(b'#'):
                if count % SHARD_PAGES == 0: offsets[count]=0 if count==0 else offset
                count+=1
            offset+=len(line)
        if index_identity(os.fstat(source.fileno()))!=identity:
            raise ValueError('Page index changed during inspection')
    if index_identity(path.stat())!=identity:
        raise ValueError('Page index replaced during inspection')
    return dict(rows=count,sha256=digest.hexdigest(),identity=identity,offsets=offsets)


def validate_page_coverage(root, start=0, limit=None, expected=None, offset=0, source_pages=None, require_total=False):
    try:
        with (root/'page-coverage.json').open('rb') as source:
            data=source.read(MAX_PAGE_COVERAGE_BYTES+1)
        if len(data)>MAX_PAGE_COVERAGE_BYTES:
            raise ValueError('Page coverage exceeds size limit')
        record=json.loads(data)
    except (OSError,ValueError) as error:
        raise ValueError(f'Missing or invalid page coverage: {root}') from error
    if not isinstance(record,dict) or type(record.get('version')) is not int or record['version']!=1:
        raise ValueError(f'Invalid page coverage version: {root}')
    required={'version','start_page','requested_limit','pages_seen','index_byte_offset','page_index_identity'}
    if not required.issubset(record):
        raise ValueError(f'Missing required page coverage fields: {root}')
    for key in ('start_page','pages_seen','index_byte_offset'):
        if type(record.get(key)) is not int or record[key]<0:
            raise ValueError(f'Invalid page coverage {key}: {root}')
    identity=record.get('page_index_identity')
    if not isinstance(identity,dict) or any(type(identity.get(k)) is not int for k in ('device_major','device_minor','inode','size','mtime_ns')):
        raise ValueError(f'Invalid page index identity: {root}')
    requested=record.get('requested_limit')
    if requested is not None and (type(requested) is not int or requested<0):
        raise ValueError(f'Invalid requested page limit: {root}')
    if record['start_page']!=start or requested!=limit or record['index_byte_offset']!=offset:
        raise ValueError(f'Page selection mismatch: {root}')
    count=limit if limit is not None else (expected['rows'] if expected is not None else source_pages)
    if count is not None and record['pages_seen']!=count:
        raise ValueError(f'Incomplete page coverage: {root}')
    if expected is not None and identity!=expected['identity']:
        raise ValueError(f'Page index identity mismatch: {root}')
    if require_total:
        total=record.get('expected_input_pages')
        if type(total) is not int or total<0 or record['pages_seen']!=total:
            raise ValueError(f'Unverified total page coverage: {root}')
        if 'page_index_rows' in record and (type(record['page_index_rows']) is not int or record['page_index_rows']!=total):
            raise ValueError(f'Inconsistent index page total: {root}')
    return record


def require_index_identity(path, expected):
    if index_identity(path.stat())!=expected['identity']:
        raise ValueError('Page index changed between shards')


def cleanup_dead_private_shards(shards_root):
    """Remove only a private shard whose exact native writer PID is gone.

    The edition lock excludes another controller, but subprocesses do not hold
    it. A detached native builder can survive its controller, so lock ownership
    alone is never evidence that its private output is inactive.
    """
    for partial in shards_root.iterdir():
        matched=re.fullmatch(r'\.[0-9]{8}\.part-([0-9]+)',partial.name)
        if not matched: continue
        if partial.is_symlink() or not partial.is_dir():
            raise ValueError(f'Unsafe partial shard: {partial}')
        pid=int(matched.group(1))
        try:
            with open(f'/proc/{pid}/stat','rb') as process:
                process.read(1)
        except FileNotFoundError:
            pass
        except OSError as error:
            raise ValueError(f'Cannot establish private shard owner death: {partial}') from error
        else:
            raise ValueError(f'Native builder PID still exists; preserve partial shard: {partial}')
        shutil.rmtree(partial)


def shard_state(items, registry, now_unix=None, interwiki_snapshot=None, auxiliary_snapshots=None):
    state={
        'version':SHARD_STATE_VERSION,
        'edition':items[0]['wiki'],
        'date':items[0]['date'],
        'files':[[item['name'],item['size'],item['sha1']] for item in sorted(items,key=lambda x:x['name'])],
        'registry_sha256':sha256_file(registry),
        'source':source_fingerprint(),
        'shard_pages':SHARD_PAGES,
    }
    if now_unix is not None: state['now_unix']=now_unix
    if interwiki_snapshot is not None:
        state['interwiki_map_sha256']=sha256_file(interwiki_snapshot)
    if auxiliary_snapshots:
        state['auxiliary_snapshot_sha256']=verified_auxiliary_hashes(auxiliary_snapshots,items[0]['wiki'],items[0]['date'])
    return state


def dump_input_fingerprint(items):
    """The repack depends on XML input bytes and its staging format only."""
    if not items: raise ValueError('No dump parts')
    files=[]
    for item in sorted(items,key=lambda x:x['name']):
        files.append([item['wiki'],item['date'],item['name'],item['size'],item['sha1']])
    state={'version':DUMP_STAGING_VERSION,'files':files}
    return hashlib.sha256(json.dumps(state,sort_keys=True,separators=(',',':')).encode()).hexdigest()


def validate_now_unix(value):
    if value is not None and (type(value) is not int or not 0 < value <= (1 << 63) - 1):
        raise ValueError('Build time must be a positive signed 64-bit Unix timestamp')
    return value


def prepare_shard_workspace(workspace, expected, now_unix=None):
    expected=dict(expected)
    embedded=expected.pop('now_unix',None)
    if now_unix is None: now_unix=embedded
    elif embedded is not None and embedded!=now_unix: raise ValueError('Conflicting build timestamps')
    validate_now_unix(now_unix)
    if workspace.is_symlink(): raise ValueError(f'Unsafe shard workspace: {workspace}')
    state_path=workspace/'state.json'
    if state_path.is_file():
        try: existing=json.loads(state_path.read_text())
        except (OSError,json.JSONDecodeError): existing=None
        comparable={k:v for k,v in existing.items() if k!='now_unix'} if isinstance(existing,dict) else None
        if comparable==expected and type(existing.get('now_unix')) is int and 0<existing['now_unix']<=(1<<63)-1 and (now_unix is None or existing['now_unix']==now_unix):
            return existing['now_unix']
    if workspace.exists():
        if not workspace.is_dir() or workspace.is_symlink(): raise ValueError(f'Unsafe shard workspace: {workspace}')
        cache=workspace/'input'
        if cache.is_symlink(): raise ValueError(f'Unsafe cached dump path: {cache}')
        # Compiler/registry changes invalidate the expander and shards, but
        # the verified compressed XML repack has independent inputs.
        for child in workspace.iterdir():
            if child.name=='input' and child.is_dir(): continue
            if child.is_dir() and not child.is_symlink(): shutil.rmtree(child)
            else: child.unlink()
    else:
        workspace.mkdir(parents=True)
    now_unix=now_unix if now_unix is not None else int(time.time())
    state=dict(expected,now_unix=now_unix)
    temp=state_path.with_suffix('.part')
    temp.write_text(json.dumps(state,sort_keys=True)+'\n')
    os.replace(temp,state_path)
    return now_unix


def cached_shard_dump(items, downloads, workspace):
    """Reuse only a completed, content-verified repack for these XML inputs."""
    edition,date=phase_identity(items)
    cache=workspace/'input'
    dump=cache/'pages.xml.zst'
    index=cache/'pages-index.txt.bz2'
    marker=cache/'.complete.json'
    with build_phase(edition,date,'cache_verification') as result:
        if cache.is_symlink(): raise ValueError(f'Unsafe cached dump path: {cache}')
        input_hash=dump_input_fingerprint(items)
        if cache.is_dir() and not any(path.is_symlink() for path in (dump,index,marker)):
            try:
                record=json.loads(marker.read_text())
                valid=isinstance(record,dict) and record.get('version')==DUMP_STAGING_VERSION and record.get('input_sha256')==input_hash
                valid=valid and record.get('dump_codec')=='zstd' and record.get('dump_stream_kind')=='multistream-zstd'
                valid=valid and type(record.get('source_pages')) is int and record['source_pages']>=0
                for label,path in (('dump',dump),('index',index)):
                    valid=valid and path.is_file() and type(record.get(label+'_size')) is int and record[label+'_size']>0
                    valid=valid and path.stat().st_size==record[label+'_size']
                    valid=valid and sha256_file(path)==record.get(label+'_sha256')
                if valid:
                    result['cache_hit']=True
                    result['compressed_bytes']=record['dump_size']
                    print(f'Reusing verified staged dump: {dump}',flush=True)
                    return dump
            except (OSError,ValueError,json.JSONDecodeError):
                pass
        result['cache_hit']=False
    if cache.exists():
        if not cache.is_dir(): raise ValueError(f'Unsafe cached dump path: {cache}')
        shutil.rmtree(cache)
    cache.mkdir()
    metadata={}
    stage_seekable_dump(items,downloads,cache,metadata)
    record=dict(metadata,version=DUMP_STAGING_VERSION,input_sha256=input_hash)
    temp=marker.with_suffix('.part')
    temp.write_text(json.dumps(record,sort_keys=True)+'\n')
    os.replace(temp,marker)
    return dump


def expander_ready(root, auxiliary_hashes=None, interwiki_sha=None):
    marker=root/'.incomplete'
    expander=root/'.bundle-expander'
    try: ready=marker.read_text()=='expander ready'
    except OSError: return False
    if not (ready and not (expander/'.incomplete').exists() and (expander/'page-index.tsv').is_file() and (expander/'dict-bundle-expander').is_file() and (expander/'namespace-registry.tsv').is_file()):return False
    try:
        if interwiki_sha is not None and sha256_file(expander/'interwiki-map.tsv')!=interwiki_sha:return False
        if interwiki_sha is None and (expander/'interwiki-map.tsv').exists():return False
        return all(sha256_file(expander/(name+'.tsv'))==digest for name,digest in (auxiliary_hashes or {}).items())
    except OSError:return False


def run_checked(command):
    subprocess.run(command,cwd=PROJECT,check=True)


def phase_event(edition, date, name, event, **fields):
    try:
        record=dict(edition=edition,date=date,phase=name,event=event,**fields)
        print('BUILD_PHASE '+json.dumps(record,sort_keys=True,separators=(',',':')),flush=True)
    except Exception:
        # Observability must never change the result of a build stage.
        pass


@contextmanager
def build_phase(edition, date, name, **fields):
    started=time.monotonic()
    phase_event(edition,date,name,'start',**fields)
    result=dict(fields)
    status='failure'
    try:
        yield result
        status='success'
    finally:
        phase_event(edition,date,name,'end',status=status,seconds=round(time.monotonic()-started,3),**result)


def timed_run(command, edition, date, phase, **fields):
    with build_phase(edition,date,phase,**fields):
        run_checked(command)


def build_sharded(dump, staging, workspace, registry, zig, workers, items, now_unix, expansion_workers=None, interwiki_snapshot=None, interwiki_sha=None, auxiliary_snapshots=None, auxiliary_hashes=None, expansion_timeout_ms=None, build_identity=None):
    timeout_args=expansion_deadline_args(expansion_timeout_ms)
    edition,date=items[0]['wiki'],items[0]['date']
    workers=min(workers,MAX_PIPELINE_WORKERS)
    expansion_workers=workers if expansion_workers is None else expansion_workers
    if type(expansion_workers) is not int or not 1 <= expansion_workers <= MAX_PAGE_EXPANSION_WORKERS:
        raise ValueError('Invalid page expansion worker count')
    expander_build=workspace/'expander'
    if not expander_ready(expander_build,auxiliary_hashes,interwiki_sha):
        if expander_build.exists(): shutil.rmtree(expander_build)
        staged=json.loads((workspace/'input/.complete.json').read_text())
        extraction_cache=workspace/'input'/'extraction-cache'
        timed_run([zig,'build','-j1','-Doptimize=fast','build-dictionary','--',str(dump),str(expander_build),
                     *(['--interwiki-map-snapshot',str(interwiki_snapshot)] if interwiki_snapshot else []),
                     *pipeline_snapshot_args(registry,auxiliary_snapshots),
                     '--llvm-workers',str(workers),
                     '--parse-workers',str(min(workers,64)),'--page-workers',str(min(workers,16)),'--expander-only',
                     '--extraction-cache-root',str(extraction_cache),
                     '--verified-dump-sha256',staged['dump_sha256'],
                     '--verified-index-sha256',staged['index_sha256']],
                  edition,date,'expander_build')
    expander=expander_build/'.bundle-expander'
    with build_phase(edition,date,'page_index_count') as result:
        index_path=expander/'page-index.tsv'
        index=inspect_page_index(index_path)
        indexed_pages=index['rows']
        result['pages']=indexed_pages
        result['sha256']=index['sha256']
    cache_record=json.loads((workspace/'input/.complete.json').read_text())
    if type(cache_record.get('source_pages')) is not int or cache_record['source_pages']<0:
        raise ValueError('Staged dump lacks a verified source page count')
    if indexed_pages!=cache_record['source_pages']:
        raise ValueError('Page index count differs from staged source pages')

    shards_root=workspace/'shards';shards_root.mkdir(exist_ok=True)
    cleanup_dead_private_shards(shards_root)
    shard_paths=[]
    # A verified or complete-but-unmarked contiguous prefix is reusable after
    # a crash. The native continuous builder owns only an absent suffix, so it
    # cannot replace an existing shard directory.
    shard_starts=list(range(0,indexed_pages,SHARD_PAGES))
    prefix=[]
    for start in shard_starts:
        shard=shards_root/f'{start:08d}'
        if not shard.exists(): break
        limit=min(SHARD_PAGES,indexed_pages-start)
        require_index_identity(index_path,index)
        try:
            validate_page_coverage(shard,start,limit,index,index['offsets'][start])
        except ValueError:
            print(f'Rebuilding shard with invalid coverage {items[0]["wiki"]} start={start}',flush=True)
            shutil.rmtree(shard)
            break
        # A verifier failure can be a transient resource/tool failure. Preserve
        # the existing shard and stop; only invalid coverage permits deletion.
        timed_run([zig,'build','-j1','-Doptimize=fast','verify-blobs','--',str(shard)],
                  edition,date,'resume_shard_verify',start_page=start,pages=limit)
        require_index_identity(index_path,index)
        marker=shard/'.verified'
        if not marker.is_file(): marker.write_text('verified\n')
        prefix.append(shard)
    missing_starts=shard_starts[len(prefix):]
    shard_paths=list(prefix)
    continuous_handled=not missing_starts
    # A noncontiguous set of completed shards can arise from older builds.
    # Preserve those outputs and use the existing single-shard fallback.
    if missing_starts and all(not (shards_root/f'{start:08d}').exists() for start in missing_starts):
        first=missing_starts[0]
        require_index_identity(index_path,index)
        timed_run([zig,'build','-j1','-Doptimize=fast','build-blobs','--',str(dump),str(shards_root),
                   '--expander-root',str(expander),'--start-page',str(first),
                   '--limit-pages',str(indexed_pages-first),
                   '--index-byte-offset',str(index['offsets'][first]),
                   '--shard-pages',str(SHARD_PAGES),
                   '--workers',str(expansion_workers),'--now-unix',str(now_unix),*timeout_args],
                  edition,date,'continuous_shard_build',start_page=first,pages=indexed_pages-first)
        require_index_identity(index_path,index)
        for start in missing_starts:
            shard=shards_root/f'{start:08d}'
            limit=min(SHARD_PAGES,indexed_pages-start)
            validate_page_coverage(shard,start,limit,index,index['offsets'][start])
            timed_run([zig,'build','-j1','-Doptimize=fast','verify-blobs','--',str(shard)],
                      edition,date,'shard_verify',start_page=start,pages=limit)
            (shard/'.verified').write_text('verified\n')
            require_index_identity(index_path,index)
        shard_paths=prefix+[shards_root/f'{start:08d}' for start in missing_starts]
        continuous_handled=True
    if not continuous_handled:
        shard_paths=[]
        for start in range(0,indexed_pages,SHARD_PAGES):
            limit=min(SHARD_PAGES,indexed_pages-start)
            offset=index['offsets'][start]
            require_index_identity(index_path,index)
            shard=shards_root/f'{start:08d}'
            marker=shard/'.verified'
            if shard.exists():
                try:
                    validate_page_coverage(shard,start,limit,index,offset)
                except ValueError:
                    print(f'Rebuilding shard with invalid coverage {items[0]["wiki"]} start={start}',flush=True)
                    shutil.rmtree(shard)
                else:
                    timed_run([zig,'build','-j1','-Doptimize=fast','verify-blobs','--',str(shard)],
                              edition,date,'resume_shard_verify',start_page=start,pages=limit)
                    require_index_identity(index_path,index)
                    if not marker.is_file(): marker.write_text('verified\n')
                    shard_paths.append(shard);continue
            last_error=None
            for attempt in range(1,SHARD_RETRIES+1):
                if shard.exists(): shutil.rmtree(shard)
                try:
                    timed_run([zig,'build','-j1','-Doptimize=fast','build-blobs','--',str(dump),str(shard),
                                 '--expander-root',str(expander),'--start-page',str(start),'--limit-pages',str(limit),
                                 '--index-byte-offset',str(offset),
                                 '--workers',str(expansion_workers),'--now-unix',str(now_unix),*timeout_args],
                              edition,date,'shard_build',start_page=start,pages=limit,attempt=attempt)
                except subprocess.CalledProcessError as error:
                    last_error=error
                    print(f'Retrying failed shard builder {items[0]["wiki"]} start={start} attempt={attempt}/{SHARD_RETRIES}',flush=True)
                    continue
                require_index_identity(index_path,index)
                try:
                    validate_page_coverage(shard,start,limit,index,offset)
                except ValueError as error:
                    last_error=error
                    print(f'Retrying shard with invalid coverage {items[0]["wiki"]} start={start} attempt={attempt}/{SHARD_RETRIES}',flush=True)
                    continue
                # Preserve a completed shard if verification fails because of
                # a transient tool/resource error. The next run revalidates it.
                timed_run([zig,'build','-j1','-Doptimize=fast','verify-blobs','--',str(shard)],
                          edition,date,'shard_verify',start_page=start,pages=limit,attempt=attempt)
                require_index_identity(index_path,index)
                marker.write_text('verified\n')
                last_error=None
                break
            if last_error is not None: raise last_error
            shard_paths.append(shard)

    require_index_identity(index_path,index)
    actual_pages=sum(validate_page_coverage(path,start,min(SHARD_PAGES,indexed_pages-start),index,index['offsets'][start])['pages_seen']
                     for path,start in zip(shard_paths,range(0,indexed_pages,SHARD_PAGES)))
    if actual_pages!=indexed_pages: raise ValueError('Incomplete total shard page coverage')
    if staging.exists(): shutil.rmtree(staging)
    timed_run([zig,'build','-j1','-Doptimize=fast','merge-blobs','--',str(staging),*[str(path) for path in shard_paths]],
              edition,date,'merge',shards=len(shard_paths))
    timed_run([zig,'build','-j1','-Doptimize=fast','verify-blobs','--',str(staging)],
              edition,date,'merged_verify',shards=len(shard_paths))
    coverage=dict(version=1,start_page=0,requested_limit=None,index_byte_offset=0,pages_seen=actual_pages,
                  expected_input_pages=indexed_pages,page_index_identity=index['identity'],page_index_sha256=index['sha256'],page_index_rows=indexed_pages)
    (staging/'page-coverage.json').write_text(json.dumps(coverage,sort_keys=True)+'\n')
    plan=expander_build/'compile-plan.tsv'
    if plan.is_file(): shutil.copyfile(plan,staging/'compile-plan.tsv')
    if interwiki_snapshot is not None:
        if sha256_file(interwiki_snapshot)!=interwiki_sha:
            raise ValueError('Interwiki map snapshot changed during build')
        (staging/INTERWIKI_SHA_NAME).write_text(interwiki_sha+'\n')
    if auxiliary_hashes:
        if verified_auxiliary_hashes(auxiliary_snapshots)!=auxiliary_hashes:
            raise ValueError('Auxiliary snapshot changed during build')
        (staging/AUXILIARY_SHA_NAME).write_text(json.dumps(auxiliary_hashes,sort_keys=True)+'\n')
    (staging/NOW_UNIX_NAME).write_text(json.dumps(now_unix)+'\n')
    persist_build_identity(staging,build_identity)
    (staging/VERIFIED_MARKER).write_text(VERIFIED_CONTENT)
    # The merged staging tree is now the sole verified publication source.
    # Drop raw shards and the transient expander before XZ publication so peak
    # disk usage is not shards + merged raw + compressed output simultaneously.
    if workspace.exists(): shutil.rmtree(workspace)


def build(items, downloads, output, zig, compression_workers=None, expansion_workers=None, interwiki_snapshot=None, auxiliary_snapshots=None, expansion_timeout_ms=None, now_unix=None):
    validate_now_unix(now_unix)
    timeout_args=expansion_deadline_args(expansion_timeout_ms)
    for item in items:
        validate_item(item)
    edition, date = items[0]['wiki'], items[0]['date']
    with build_phase(edition,date,'edition_build') as result:
        parent = output / edition
        parent.mkdir(parents=True, exist_ok=True)
        # Keep the inode: deleting lock files permits two independent locks.
        with (parent / (date + '.lock')).open('a') as lock:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                raise ValueError(f'Build already running: {parent / date}') from None
            mode=build_locked(items, downloads, output, zig, compression_workers, expansion_workers, interwiki_snapshot, auxiliary_snapshots, **({'expansion_timeout_ms':expansion_timeout_ms} if expansion_timeout_ms is not None else {}), **({'now_unix':now_unix} if now_unix is not None else {}))
            result['execution_mode']=mode
            return mode


def validate_fallback_report(path):
    if not path.is_file():
        raise ValueError(f'Missing fallback report: {path}')
    count = 0
    seen = set()
    with path.open(encoding='utf-8') as lines:
        for line_number, line in enumerate(lines, 1):
            if not line.strip():
                raise ValueError(f'Blank fallback report record at {path}:{line_number}')
            try:
                record = json.loads(line)
            except json.JSONDecodeError as error:
                raise ValueError(f'Invalid fallback report JSON at {path}:{line_number}: {error.msg}') from None
            namespace = record.get('namespace') if isinstance(record, dict) else None
            title = record.get('title') if isinstance(record, dict) else None
            reasons = record.get('reasons') if isinstance(record, dict) else None
            if type(namespace) is not int or namespace < 0 or not isinstance(title, str):
                raise ValueError(f'Invalid fallback page identity at {path}:{line_number}')
            if not isinstance(reasons, list) or not reasons or any(not isinstance(reason, str) or not reason for reason in reasons):
                raise ValueError(f'Invalid fallback reasons at {path}:{line_number}')
            if len(set(reasons)) != len(reasons):
                raise ValueError(f'Duplicate fallback reason at {path}:{line_number}')
            for reason in reasons:
                parts = reason.split(':')
                if len(parts) in (2, 3) and parts[0] == 'expansion_error' and parts[-1] in ('Timeout', 'OutOfMemory'):
                    kind = 'timeout' if parts[-1] == 'Timeout' else 'out of memory'
                    raise ValueError(f'Operational expansion {kind} at {path}:{line_number}; rebuild this output')
                if len(parts)==3 and parts[0]=='expansion_error' and parts[1]!='expand':
                    raise ValueError(f'Infrastructure expansion failure at {path}:{line_number}; rebuild this output')
            key = (namespace, title)
            if key in seen:
                raise ValueError(f'Duplicate fallback page at {path}:{line_number}: {namespace}:{title}')
            seen.add(key)
            count += 1
    return count

BUILD_IDENTITY_NAME = '.build-inputs.json'
VERIFIED_MARKER = '.verified-blobs'
INTERWIKI_SHA_NAME = '.interwiki-map.sha256'
AUXILIARY_SHA_NAME = '.auxiliary-snapshots.sha256.json'
NOW_UNIX_NAME = '.build-now-unix.json'
# Bump this when page framing, member encoding or index semantics change; the
# input cache identity and published artifacts both include this contract.
DUMP_STAGING_VERSION = 'page-aligned-zstd-parallel-v2'
VERIFIED_CONTENT = f'dump-staging-version={DUMP_STAGING_VERSION}\n'

def require_current_staging_version(path, version):
    if version != DUMP_STAGING_VERSION:
        raise ValueError(f'Outdated dump staging at {path}; rebuild in a new output directory (existing output preserved)')

def publication_inventory(root):
    """Pin verified data bytes so resume cannot bless missing or changed output."""
    required={'languages.tsv','page-coverage.json','namespace-coverage.json','fallback-pages.jsonl'}
    metadata=required|{'compile-plan.tsv','module-compile-plan.tsv',BUILD_IDENTITY_NAME,
                       INTERWIKI_SHA_NAME,AUXILIARY_SHA_NAME,NOW_UNIX_NAME}
    if root.is_symlink() or not root.is_dir():raise ValueError('Unsafe publication directory')
    pending=[root];files=[]
    while pending:
        for path in pending.pop().iterdir():
            name=path.relative_to(root).as_posix()
            if path.is_symlink():raise ValueError('Unsafe publication artifact: '+name)
            if path.is_dir():
                # Reader indexes live beside root feature blobs or language blobs.
                if name in ('.dict-cache','languages/.dict-cache'):continue
                if path.name=='.bundle-expander':raise ValueError('Transient compiler tree in publication')
                pending.append(path)
            else:files.append(path)
    inventory={}
    for path in sorted(files):
        name=path.relative_to(root).as_posix()
        if path.is_symlink():raise ValueError('Unsafe publication artifact: '+name)
        if name in ('complete.json',VERIFIED_MARKER):continue
        if not path.is_file() or (name not in metadata and not name.endswith('.wikblb.xz')):
            raise ValueError('Unexpected publication artifact: '+name)
        before=index_identity(path.stat())
        digest=sha256_file(path)
        if index_identity(path.stat())!=before:raise ValueError('Publication artifact changed while reading: '+name)
        inventory[name]={'size':before['size'],'sha256':digest}
    if not required.issubset(inventory):raise ValueError('Missing required publication report or language manifest')
    return inventory

def validate_namespace_coverage(root, expected_rows, namespace_snapshot=None):
    if type(expected_rows) is not int or expected_rows<0:raise ValueError('Missing expected namespace row count')
    path=root/'namespace-coverage.json'
    try:report=read_small_json(path,8*1024*1024)
    except (OSError,ValueError,json.JSONDecodeError) as error:raise ValueError('Missing or invalid namespace coverage') from error
    if not isinstance(report,dict) or report.get('version')!=1 or not isinstance(report.get('namespaces'),list):raise ValueError('Invalid namespace coverage')
    expected_routes=None
    if namespace_snapshot is not None:
        expected_hash=sha256_file(Path(namespace_snapshot))
        if report.get('registry_sha256')!=expected_hash:raise ValueError('Namespace coverage registry mismatch')
        expected_routes={}
        for line in Path(namespace_snapshot).read_text(encoding='utf-8').splitlines():
            if not line or line.startswith('#'):continue
            columns=line.split('\t')
            if len(columns)<10:raise ValueError('Invalid namespace registry row')
            ns=int(columns[0]);role=columns[8]
            kind={'main':'language','compile_only':None,'supplemental':'supplemental','rhymes':'rhymes','thesaurus':'thesaurus','citations':'citations','sign_gloss':'sign_gloss','reconstruction':'reconstruction'}.get(role,'INVALID')
            if ns in expected_routes or kind=='INVALID':raise ValueError('Invalid namespace registry routing')
            expected_routes[ns]=(columns[1],kind)
    counters=('input_rows','compile_only_rows','source_unavailable_rows','dispatched_rows','expanded_pages','fallback_pages','duplicate_rows')
    totals={key:0 for key in counters};seen=set()
    for row in report['namespaces']:
        if not isinstance(row,dict):raise ValueError('Invalid namespace coverage row')
        ns=row.get('id');name=row.get('name');kind=row.get('kind')
        if type(ns) is not int or not 0<=ns<2**32 or ns in seen or not isinstance(name,str):raise ValueError('Invalid namespace coverage identity')
        if kind not in (None,'language','thesaurus','citations','reconstruction','rhymes','sign_gloss','supplemental'):raise ValueError('Invalid namespace coverage routing')
        if expected_routes is not None and expected_routes.get(ns)!=(name,kind):raise ValueError('Namespace coverage routing differs from registry')
        seen.add(ns)
        for key in counters:
            value=row.get(key)
            if type(value) is not int or not 0<=value<2**64:raise ValueError('Invalid namespace coverage counter')
            totals[key]+=value
        if row['input_rows']!=row['compile_only_rows']+row['source_unavailable_rows']+row['dispatched_rows'] or row['dispatched_rows']!=row['expanded_pages']+row['fallback_pages']+row['duplicate_rows']:raise ValueError('Incomplete namespace coverage')
        if (kind is None and row['input_rows']!=row['compile_only_rows']) or (kind is not None and row['compile_only_rows']!=0):raise ValueError('Invalid namespace coverage disposition')
        if (kind=='language')!=(ns==0) or (ns==0)!=(name==''):raise ValueError('Invalid main namespace coverage')
    if totals['input_rows']!=expected_rows:raise ValueError('Namespace coverage does not match selected rows')
    return totals


def _publish_verified_staging(staging, target, edition, date, compression_workers=None, interwiki_sha=None, auxiliary_hashes=None, build_identity=None, namespace_snapshot=None):
    marker = staging / VERIFIED_MARKER
    if not marker.is_file():
        raise ValueError(f'Unverified staging directory: {staging}')
    if marker.read_text() != VERIFIED_CONTENT:
        require_current_staging_version(staging, None)
    if build_identity is not None:
        require_build_identity(read_small_json(staging/BUILD_IDENTITY_NAME) if (staging/BUILD_IDENTITY_NAME).is_file() else None,build_identity)
        if source_fingerprint()!=build_identity['source']:raise ValueError('Compiler source changed during build; refusing publication')
    recorded=read_snapshot_sha(staging/INTERWIKI_SHA_NAME) if (staging/INTERWIKI_SHA_NAME).is_file() else None
    if recorded!=interwiki_sha:
        raise ValueError('Verified staging uses a different interwiki map snapshot')
    auxiliary_record=read_small_json(staging/AUXILIARY_SHA_NAME) if (staging/AUXILIARY_SHA_NAME).is_file() else {}
    if auxiliary_record!=(auxiliary_hashes or {}):
        raise ValueError('Verified staging uses different auxiliary snapshots')
    recorded_now=read_small_json(staging/NOW_UNIX_NAME) if (staging/NOW_UNIX_NAME).is_file() else None
    validate_now_unix(recorded_now)
    coverage=validate_page_coverage(staging,require_total=True)
    fallback_pages = validate_fallback_report(staging / 'fallback-pages.jsonl')
    namespace_totals=validate_namespace_coverage(staging,coverage['pages_seen'],namespace_snapshot)
    if namespace_snapshot is not None and namespace_totals['fallback_pages']!=fallback_pages:raise ValueError('Namespace fallback totals differ from fallback report')
    for part in staging.rglob('*.xz.part'):
        part.unlink()
    raw = sorted(staging.rglob('*.wikblb'))
    compressed = sorted(staging.rglob('*.wikblb.xz'))
    logical = {str(path) for path in raw}
    logical.update(str(path)[:-3] for path in compressed)
    pending = []
    for blob in raw:
        compressed_path = Path(str(blob) + '.xz')
        if compressed_path.exists():
            verify_round_trip(blob, compressed_path)
            blob.unlink()
        else:
            pending.append(blob)
    if pending:
        workers = compression_workers or default_build_threads()
        compress_many(pending, 1024*1024, workers)
    compressed = sorted(staging.rglob('*.wikblb.xz'))
    if len(compressed) != len(logical) or list(staging.rglob('*.wikblb')) or list(staging.rglob('*.xz.part')):
        raise ValueError(f'Incomplete compressed publication: {staging}')
    inventory=publication_inventory(staging)
    metadata = {'edition':edition,'date':date,'dump_staging_version':DUMP_STAGING_VERSION,
        'dump_codec':'zstd','dump_stream_kind':'multistream-zstd',
        'status':'built' if compressed else 'empty', 'fallback_pages':fallback_pages,
        'fallback_report':'fallback-pages.jsonl', 'compression':'xz -6; 1 MiB blocks','blobs':len(compressed),
        'input_pages':coverage['pages_seen'],'page_coverage_report':'page-coverage.json',
        'namespace_coverage_report':'namespace-coverage.json','namespace_coverage_totals':namespace_totals,
        'publication_files':inventory}
    if build_identity is not None:metadata['build_inputs']=build_identity
    if recorded_now is not None: metadata['now_unix']=recorded_now
    if interwiki_sha is not None: metadata['interwiki_map_sha256']=interwiki_sha
    if auxiliary_hashes: metadata['auxiliary_snapshot_sha256']=auxiliary_hashes
    (staging / 'complete.json').write_text(json.dumps(metadata)+'\n')
    os.rename(staging, target)
    (target/VERIFIED_MARKER).unlink()
    print(f'Published: {target}', flush=True)
    return len(compressed),fallback_pages


def publish_verified_staging(staging, target, edition, date, compression_workers=None, interwiki_sha=None, auxiliary_hashes=None, build_identity=None, namespace_snapshot=None):
    with build_phase(edition,date,'publish') as result:
        blobs,fallback_pages=_publish_verified_staging(staging,target,edition,date,compression_workers,interwiki_sha,auxiliary_hashes,build_identity,namespace_snapshot)
        result.update(blobs=blobs,fallback_pages=fallback_pages)

def build_locked(items, downloads, output, zig, compression_workers=None, expansion_workers=None, interwiki_snapshot=None, auxiliary_snapshots=None, expansion_timeout_ms=None, now_unix=None):
    validate_now_unix(now_unix)
    for item in items:validate_item(item)
    timeout_args=expansion_deadline_args(expansion_timeout_ms)
    phase_edition,phase_date=phase_identity(items)
    auxiliary_snapshots=dict(auxiliary_snapshots or {})
    registry=Path(auxiliary_snapshots.get('language-registry',downloads/phase_edition/phase_date/'language-registry.tsv'))
    namespace=Path(auxiliary_snapshots.get('namespace-registry',downloads/phase_edition/phase_date/'namespace-registry.tsv'))
    if not registry.is_file():raise ValueError('Missing pinned language registry')
    if not namespace.is_file():raise ValueError('Missing namespace registry')
    auxiliary_snapshots.update({'language-registry':registry,'namespace-registry':namespace})
    auxiliary_hashes=verified_auxiliary_hashes(auxiliary_snapshots,phase_edition,phase_date)
    with build_phase(phase_edition,phase_date,'verify_downloads',files=len(items)) as result:
        verified_bytes=0
        for item in items:
            validate_item(item)
            source = downloads / item['wiki'] / item['date'] / item['name']
            if not source.is_file() or source.stat().st_size != item['size'] or digest(source) != item['sha1']:
                raise ValueError(f'Missing or unverified download: {source}')
            verified_bytes+=item['size']
        result['verified_bytes']=verified_bytes
    xml = [x for x in items if '-pages-meta-current' in x['name'] and re.search(r'\.xml(?:-p[0-9]+p[0-9]+)?\.bz2$', x['name'])]
    if not xml:
        raise ValueError('No full-namespace current XML in snapshot')
    edition,date=items[0]['wiki'],items[0]['date']
    if interwiki_snapshot is not None:
        interwiki_snapshot=Path(interwiki_snapshot).resolve(strict=True)
        if not interwiki_snapshot.is_file(): raise ValueError('Interwiki map snapshot is not a file')
        interwiki_sha=sha256_file(interwiki_snapshot)
        validate_interwiki_provenance(interwiki_snapshot,edition,interwiki_sha)
    else:
        interwiki_sha=None
    auxiliary_hashes=verified_auxiliary_hashes(auxiliary_snapshots,edition,date)
    build_identity=build_input_identity(items,zig,auxiliary_hashes,interwiki_sha,expansion_timeout_ms,auxiliary_snapshots)
    target = output / edition / date
    if (target / 'complete.json').exists():
        try:
            metadata=read_small_json(target/'complete.json',8*1024*1024)
        except (OSError,json.JSONDecodeError):
            metadata={}
        if not isinstance(metadata,dict): metadata={}
        require_current_staging_version(target,metadata.get('dump_staging_version'))
        if metadata.get('edition')!=edition or metadata.get('date')!=date:
            raise ValueError('Existing output identifies a different edition or date')
        if now_unix is not None and metadata.get('now_unix')!=now_unix:
            raise ValueError('Existing output uses a different or unrecorded build time; choose a new output directory')
        if metadata.get('interwiki_map_sha256')!=interwiki_sha:
            raise ValueError('Existing output uses a different interwiki map snapshot; choose a new output directory')
        if metadata.get('auxiliary_snapshot_sha256',{})!=auxiliary_hashes:
            raise ValueError('Existing output uses different auxiliary snapshots; choose a new output directory')
        require_build_identity(metadata.get('build_inputs'),build_identity)
        coverage=validate_page_coverage(target,require_total=True)
        if type(metadata.get('input_pages')) is not int or metadata['input_pages']!=coverage['pages_seen']:
            raise ValueError('Existing output page total differs from coverage')
        namespace_totals=validate_namespace_coverage(target,metadata['input_pages'],namespace)
        fallback_pages=validate_fallback_report(target/'fallback-pages.jsonl')
        if (type(metadata.get('fallback_pages')) is not int or metadata['fallback_pages']!=fallback_pages or
                namespace_totals['fallback_pages']!=fallback_pages or
                metadata.get('namespace_coverage_totals')!=namespace_totals):
            raise ValueError('Existing output namespace or fallback totals differ from reports')
        for field,name in (('page_coverage_report','page-coverage.json'),
                           ('namespace_coverage_report','namespace-coverage.json'),
                           ('fallback_report','fallback-pages.jsonl')):
            if metadata.get(field)!=name:raise ValueError('Existing output identifies a different coverage report')
        inventory=publication_inventory(target)
        recorded=metadata.get('publication_files')
        if (not isinstance(recorded,dict) or any(not isinstance(value,dict) or
                type(value.get('size')) is not int for value in recorded.values()) or recorded!=inventory):
            raise ValueError('Existing output publication inventory is missing or changed')
        blobs=sum(name.endswith('.wikblb.xz') for name in inventory)
        if (type(metadata.get('blobs')) is not int or metadata['blobs']!=blobs or
                metadata.get('status')!=('built' if blobs else 'empty')):
            raise ValueError('Existing output blob inventory differs from completion metadata')
        workspace=target.with_name(date+'.shards')
        if workspace.exists():
            if not workspace.is_dir() or workspace.is_symlink(): raise ValueError(f'Unsafe shard workspace: {workspace}')
            shutil.rmtree(workspace)
        (target/VERIFIED_MARKER).unlink(missing_ok=True)
        print(f'Already built: {target}', flush=True)
        return 'existing_output'
    target.parent.mkdir(parents=True, exist_ok=True)
    staging = target.with_name(date + '.building')
    if staging.exists():
        if not staging.is_dir() or staging.is_symlink():
            raise ValueError(f'Unsafe incomplete build path: {staging}')
        if (staging / VERIFIED_MARKER).is_file():
            recorded_now=read_small_json(staging/NOW_UNIX_NAME) if (staging/NOW_UNIX_NAME).is_file() else None
            if now_unix is not None and recorded_now!=now_unix:
                raise ValueError('Verified staging uses a different or unrecorded build time')
            print(f'Resuming verified publication: {staging}', flush=True)
            publish_verified_staging(staging, target, edition, date, compression_workers, interwiki_sha, auxiliary_hashes, build_identity=build_identity, namespace_snapshot=namespace)
            return 'resumed_publication'
        print(f'Retrying incomplete build: {staging}', flush=True)
        shutil.rmtree(staging)
    workers = min(compression_workers or default_build_threads(),MAX_PIPELINE_WORKERS)
    workspace=target.with_name(date+'.shards')
    compressed_bytes=sum(item['size'] for item in xml)
    if compressed_bytes>=SHARD_THRESHOLD_COMPRESSED_BYTES:
        print(f'Sharding {edition}: {compressed_bytes:,} compressed bytes in {SHARD_PAGES:,}-page chunks',flush=True)
        expected=shard_state(items,registry,interwiki_snapshot=interwiki_snapshot,auxiliary_snapshots=auxiliary_snapshots)
        now_unix=prepare_shard_workspace(workspace,expected,now_unix)
        dump=cached_shard_dump(xml,downloads,workspace)
        pinned=copy_verified_snapshot(interwiki_snapshot,workspace/'interwiki-map.tsv',interwiki_sha) if interwiki_snapshot else None
        aux_pinned=pinned_auxiliary_snapshots(auxiliary_snapshots,auxiliary_hashes,workspace,build_identity.get('auxiliary_capture_sha256'))
        build_sharded(dump,staging,workspace,registry,zig,workers,items,now_unix,expansion_workers,pinned,interwiki_sha,aux_pinned,auxiliary_hashes, build_identity=build_identity, **({'expansion_timeout_ms':expansion_timeout_ms} if expansion_timeout_ms is not None else {}))
    else:
        now_unix=now_unix if now_unix is not None else int(time.time())
        (PROJECT / '.tmp').mkdir(exist_ok=True)
        scratch = Path(tempfile.mkdtemp(prefix=f'build-{edition}-{date}-', dir=PROJECT / '.tmp'))
        try:
            source_metadata={}
            dump = stage_seekable_dump(xml,downloads,scratch,source_metadata)
            pinned=copy_verified_snapshot(interwiki_snapshot,scratch/'interwiki-map.tsv',interwiki_sha) if interwiki_snapshot else None
            aux_pinned=pinned_auxiliary_snapshots(auxiliary_snapshots,auxiliary_hashes,scratch,build_identity.get('auxiliary_capture_sha256'))
            timed_run([zig,'build','-j1','-Doptimize=fast','build-dictionary','--',str(dump),str(staging),
                         *(['--interwiki-map-snapshot',str(pinned)] if pinned else []),
                         *pipeline_snapshot_args(registry,aux_pinned),
                         '--llvm-workers',str(workers),'--parse-workers',str(min(workers,64)),
                         '--page-workers',str(min(workers,16)),'--now-unix',str(now_unix),*timeout_args],edition,date,'dictionary_build')
            coverage=validate_page_coverage(staging,source_pages=source_metadata['source_pages'])
            coverage['expected_input_pages']=source_metadata['source_pages']
            (staging/'page-coverage.json').write_text(json.dumps(coverage,sort_keys=True)+'\n')
            timed_run([zig,'build','-j1','-Doptimize=fast','verify-blobs','--',str(staging)],
                      edition,date,'dictionary_verify')
            if interwiki_sha is not None:
                if sha256_file(pinned)!=interwiki_sha: raise ValueError('Interwiki map snapshot changed during build')
                (staging/INTERWIKI_SHA_NAME).write_text(interwiki_sha+'\n')
            if auxiliary_hashes:
                if verified_auxiliary_hashes(aux_pinned)!=auxiliary_hashes:
                    raise ValueError('Auxiliary snapshot changed during build')
                (staging/AUXILIARY_SHA_NAME).write_text(json.dumps(auxiliary_hashes,sort_keys=True)+'\n')
            (staging/NOW_UNIX_NAME).write_text(json.dumps(now_unix)+'\n')
            persist_build_identity(staging,build_identity)
            (staging / VERIFIED_MARKER).write_text(VERIFIED_CONTENT)
        finally:
            shutil.rmtree(scratch)
    (staging/NOW_UNIX_NAME).write_text(json.dumps(now_unix)+'\n')
    publish_verified_staging(staging, target, edition, date, compression_workers, interwiki_sha, auxiliary_hashes, build_identity=build_identity, namespace_snapshot=namespace)
    if workspace.exists(): shutil.rmtree(workspace)
    return 'pipeline_run_may_reuse_verified_inputs_or_shards'

def build_groups(groups, downloads, output, zig, threads, jobs, expansion_workers=None, interwiki_snapshot=None, auxiliary_snapshots=None, expansion_timeout_ms=None, now_unix=None, edition_options=None, admission_wait_seconds=RESOURCE_ADMISSION_WAIT_SECONDS):
    from build_resource_limits import MAX_WATCHDOG_WALL_SECONDS
    validate_now_unix(now_unix)
    timeout_args=expansion_deadline_args(expansion_timeout_ms)
    if type(admission_wait_seconds) is not int or not 1 <= admission_wait_seconds <= MAX_WATCHDOG_WALL_SECONDS:
        raise ValueError('Resource admission wait must be a positive finite number of seconds, up to seven days')
    pending=list(sorted(groups.items()))
    failures=[]
    admission_workers=threads if expansion_workers is None or expansion_workers>MAX_PIPELINE_WORKERS else max(threads,expansion_workers)
    admission_deadline=None
    admission_report_at=0
    with concurrent.futures.ThreadPoolExecutor(max_workers=jobs) as pool:
        active={}
        while pending or active:
            while pending and len(active)<jobs:
                active_workers=len(active)*admission_workers
                live_budget=safe_worker_budget(active_workers)
                if live_budget < active_workers+admission_workers:
                    break
                if admission_deadline is not None and time.monotonic() >= admission_deadline:
                    break
                key,group=pending.pop(0)
                options={}
                if expansion_workers is not None: options['expansion_workers']=expansion_workers
                if expansion_timeout_ms is not None: options['expansion_timeout_ms']=expansion_timeout_ms
                if now_unix is not None: options['now_unix']=now_unix
                if interwiki_snapshot is not None: options['interwiki_snapshot']=interwiki_snapshot
                if auxiliary_snapshots: options['auxiliary_snapshots']=auxiliary_snapshots
                if edition_options is not None:
                    if key not in edition_options:raise ValueError(f'Missing edition inputs: {key}')
                    options.update(edition_options[key])
                future=pool.submit(build,group,downloads,output,zig,threads,**options)
                active[future]=key
                admission_deadline=None
                admission_report_at=0
            if not active:
                if pending:
                    now=time.monotonic()
                    if admission_deadline is None:
                        admission_deadline=now+admission_wait_seconds
                    remaining=admission_deadline-now
                    if remaining <= 0:
                        print(f'STOPPED before {pending[0][0][0]}: resource admission deadline expired after {admission_wait_seconds} seconds; budget {live_budget}, need {admission_workers}',flush=True)
                        failures.extend(key for key,_ in pending)
                        break
                    if now >= admission_report_at:
                        print(f'WAITING before {pending[0][0][0]}: resource pressure allows {live_budget} workers, need {admission_workers}; admission deadline in {remaining:.0f} seconds',flush=True)
                        admission_report_at=now+30
                    time.sleep(min(RESOURCE_ADMISSION_POLL_SECONDS,remaining))
                    continue
                break
            done,_=concurrent.futures.wait(active,timeout=1,return_when=concurrent.futures.FIRST_COMPLETED)
            if not done:continue
            for future in done:
                key=active.pop(future)
                try:future.result()
                except Exception as e:
                    failures.append(key);print(f'FAILED {key}: {e}',flush=True)
    return failures


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--downloads','--in',type=Path,default=PROJECT/'data/dumps',metavar='DIR')
    p.add_argument('--output','--out',type=Path,default=PROJECT/'data/dictionaries',metavar='DIR')
    p.add_argument('--zig',default=shutil.which('zig') or 'zig')
    p.add_argument('--resource-mode',choices=('cgroup','watchdog'),default='cgroup',
                   help='Resource supervisor: strict cgroup (default), or explicit best-effort 8 GiB process-tree watchdog with a two-hour deadline')
    p.add_argument('--build-timeout-seconds',type=int,help='Explicit watchdog build deadline, up to seven days; default two hours')
    p.add_argument('--threads',type=int,default=default_build_threads(),help='Workers per edition (up to 4 within CPU load and fixed 8 GiB aggregate cap)')
    p.add_argument('--jobs',type=int,help='Concurrent editions (up to two within CPU load and capped aggregate worker budget)')
    p.add_argument('--expansion-workers',type=int,help='Workers per sharded page expansion; default follows --threads, opt-in 5-8 requires watchdog and one edition job')
    p.add_argument('--expansion-timeout-ms',type=int,help='Explicit per-page wall deadline, 1 through 3600000 ms; default 60000. Timeouts fail the build rather than publish empty pages.')
    p.add_argument('--wikis',nargs='+',help='Build only these edition IDs')
    p.add_argument('--now-unix',type=int,help='Pin build-time MediaWiki time for repeatable complete builds')
    p.add_argument('--interwiki-map-snapshot',type=Path,
                   help='Current siteinfo interwiki-map.tsv; its SHA-256 is part of the shard identity')
    for name in AUXILIARY_SNAPSHOT_NAMES:
        p.add_argument('--'+name+'-snapshot',type=Path,
                       help='Optional '+name+' TSV; its SHA-256 is part of the shard identity')
    a=p.parse_args()
    try:
        expansion_deadline_args(a.expansion_timeout_ms)
        validate_now_unix(a.now_unix)
    except ValueError as error: p.error(str(error))
    if a.build_timeout_seconds is not None:
        from build_resource_limits import MAX_WATCHDOG_WALL_SECONDS
        if a.resource_mode!='watchdog' or not 0<a.build_timeout_seconds<=MAX_WATCHDOG_WALL_SECONDS:
            p.error('Explicit build deadline requires watchdog mode and must be 1 through '+str(MAX_WATCHDOG_WALL_SECONDS)+' seconds')
    budget=safe_worker_budget()
    if budget < 1:p.error('No worker budget within CPU load and the verified build memory cap (at most 8 GiB)')
    worker_limit=min(budget,MAX_PIPELINE_WORKERS)
    if not 1 <= a.threads <= worker_limit:p.error(f'Threads must be 1 through {worker_limit} on this host')
    expansion_workers=a.threads if a.expansion_workers is None else a.expansion_workers
    if not 1 <= expansion_workers <= MAX_PAGE_EXPANSION_WORKERS:
        p.error(f'Expansion workers must be 1 through {MAX_PAGE_EXPANSION_WORKERS}')
    if expansion_workers>MAX_PIPELINE_WORKERS:
        if a.resource_mode!='watchdog':p.error('More than four expansion workers requires explicit watchdog mode')
        if expansion_workers>len(os.sched_getaffinity(0)):
            p.error('Expansion workers exceed the watchdog CPU affinity')
    admission_workers=a.threads if expansion_workers>MAX_PIPELINE_WORKERS else max(a.threads,expansion_workers)
    if a.jobs is None:a.jobs=1 if expansion_workers>MAX_PIPELINE_WORKERS else min(2,max(1,budget//admission_workers))
    if expansion_workers>MAX_PIPELINE_WORKERS and a.jobs!=1:
        p.error('More than four expansion workers requires exactly one edition job')
    if not 1 <= a.jobs <= 16:p.error('Jobs must be 1 through 16')
    if a.jobs*admission_workers > budget:p.error(f'jobs × workers must not exceed safe host budget {budget}')
    try:
        manifest=json.loads((a.downloads/'manifest.json').read_text())
        items=select_manifest_files(manifest,a.wikis)
    except ValueError as error: p.error(str(error))
    groups={}
    for item in items:
        validate_item(item)
        groups.setdefault((item['wiki'],item['date']),[]).append(item)
    if a.wikis:
        missing=set(a.wikis)-{key[0] for key in groups}
        if missing:p.error(f'Unknown editions: {", ".join(sorted(missing))}')
        groups={key:group for key,group in groups.items() if key[0] in a.wikis}
    auxiliary={name:getattr(a,name.replace('-','_')+'_snapshot').resolve()
               for name in AUXILIARY_SNAPSHOT_NAMES
               if getattr(a,name.replace('-','_')+'_snapshot') is not None}
    if (a.interwiki_map_snapshot is not None or auxiliary) and len(groups)!=1:
        p.error('Auxiliary snapshots require exactly one edition')
    print(f'Building {len(groups)} editions with up to {a.jobs} concurrent jobs and {a.threads} workers per edition',flush=True)
    options={}
    if a.resource_mode=='watchdog':
        from build_resource_limits import WATCHDOG_WALL_SECONDS
        # The outer watchdog still enforces its original global wall deadline,
        # including time already spent building or waiting for worker admission.
        options['admission_wait_seconds']=a.build_timeout_seconds or WATCHDOG_WALL_SECONDS
    if a.expansion_timeout_ms is not None: options['expansion_timeout_ms']=a.expansion_timeout_ms
    if a.now_unix is not None: options['now_unix']=a.now_unix
    if a.interwiki_map_snapshot: options['interwiki_snapshot']=a.interwiki_map_snapshot.resolve()
    try: options['edition_options']=resolve_edition_snapshot_options(manifest,groups,a.downloads.resolve(),auxiliary)
    except (ValueError,OSError) as error:p.error(str(error))
    if a.interwiki_map_snapshot:
        for value in options['edition_options'].values():value['interwiki_snapshot']=a.interwiki_map_snapshot.resolve()
    failures=build_groups(groups,a.downloads.resolve(),a.output.resolve(),a.zig,a.threads,a.jobs,
                          None if a.expansion_workers is None else expansion_workers,**options)
    if failures:raise SystemExit(f'{len(failures)} editions failed or were not started; no incomplete editions were published')
def cli():
    from build_resource_limits import ContainmentUnavailable, inside_envelope, inside_watchdog, supervise, supervise_watchdog
    try:
        route=argparse.ArgumentParser(add_help=False)
        route.add_argument('--resource-mode',choices=('cgroup','watchdog'),default='cgroup')
        route.add_argument('--expansion-workers',type=int)
        route.add_argument('--build-timeout-seconds',type=int)
        routing=route.parse_known_args()[0]
        mode=routing.resource_mode
        if routing.build_timeout_seconds is not None:
            from build_resource_limits import MAX_WATCHDOG_WALL_SECONDS
            if mode!='watchdog' or not 0<routing.build_timeout_seconds<=MAX_WATCHDOG_WALL_SECONDS:
                raise ContainmentUnavailable('Explicit build deadline requires watchdog mode and a finite bound up to seven days')
        if '-h' in sys.argv[1:] or '--help' in sys.argv[1:]:
            main()
        else:
            watchdog_child=inside_watchdog()
            if watchdog_child and mode!='watchdog':
                raise ContainmentUnavailable('Watchdog child requires explicit --resource-mode=watchdog')
            if mode=='watchdog':
                if watchdog_child:
                    main()
                else:
                    with acquire_build_resource_lock(PROJECT/'.tmp'/'build-resources.lock'):
                        options={'wall_seconds':routing.build_timeout_seconds if routing.build_timeout_seconds is not None else 7200}
                        if routing.expansion_workers is not None and routing.expansion_workers>MAX_PIPELINE_WORKERS:
                            options['max_cpus']=8
                        raise SystemExit(supervise_watchdog(**options))
            elif inside_envelope():
                main()
            else:
                with acquire_build_resource_lock(PROJECT/'.tmp'/'build-resources.lock'):
                    raise SystemExit(supervise())
    except ContainmentUnavailable as error:
        raise SystemExit(str(error)) from error
    except KeyboardInterrupt:
        raise SystemExit('Build interrupted; private build process tree stopped') from None

if __name__=='__main__':cli()
