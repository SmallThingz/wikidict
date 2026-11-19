"""Local transactional checkpoints for the sequential presentation audit."""
import fcntl
from itertools import islice
import json
import os
from pathlib import Path
import sqlite3
import stat
import zlib

APPLICATION_ID = 0x57444131


def encode(value):
    return json.dumps(value, ensure_ascii=False, separators=(',', ':'))


class AuditCheckpoint:
    def __init__(self, resources, path, binding):
        fd = os.open(path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600)
        lock = resources.enter_context(os.fdopen(fd, 'rb'))
        current = os.fstat(fd)
        if not stat.S_ISREG(current.st_mode) or current.st_nlink != 1 or current.st_uid != os.geteuid():
            raise ValueError('Audit checkpoint must be one owned regular file')
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        named = path.lstat()
        if (named.st_dev, named.st_ino) != (current.st_dev, current.st_ino):
            raise ValueError('Audit checkpoint pathname changed')
        self.db = sqlite3.connect(path)
        resources.callback(self.db.close)
        application, = self.db.execute('PRAGMA application_id').fetchone()
        if application != APPLICATION_ID and (application or self.db.execute('SELECT 1 FROM sqlite_schema LIMIT 1').fetchone()):
            raise ValueError('File is not a Reader audit checkpoint')
        if self.db.execute('PRAGMA journal_mode=WAL').fetchone() != ('wal',):
            raise ValueError('Audit checkpoint requires local SQLite WAL support')
        self.db.execute('PRAGMA synchronous=FULL')
        self.db.execute('BEGIN IMMEDIATE')
        self.db.execute('CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL) WITHOUT ROWID')
        prior = self.get('binding')
        if prior is not None and prior != binding:
            raise ValueError('Audit checkpoint inputs or settings differ')
        if prior is None:
            self.db.execute(f'PRAGMA application_id={APPLICATION_ID}')
            self.put('binding', binding)
            self.db.execute('CREATE TABLE maps (kind TEXT, key TEXT, value NOT NULL, PRIMARY KEY (kind,key)) WITHOUT ROWID')
            self.db.execute('CREATE TABLE report (seq INTEGER PRIMARY KEY, kind TEXT NOT NULL, value NOT NULL, row_count INTEGER NOT NULL DEFAULT 1)')
            self.db.execute('CREATE INDEX report_kind ON report(kind,seq)')
            self.db.execute('CREATE TABLE views (seq INTEGER PRIMARY KEY, value TEXT NOT NULL)')
        elif 'row_count' not in {col[1] for col in self.db.execute('PRAGMA table_info(report)')}:
            self.db.execute('ALTER TABLE report ADD COLUMN row_count INTEGER NOT NULL DEFAULT 1')
        self.db.commit()
        self.review = None
        self.page_rows = {}

    def get(self, key, default=None):
        row = self.db.execute('SELECT value FROM meta WHERE key=?', (key,)).fetchone()
        return json.loads(row[0]) if row is not None else default

    def put(self, key, value):
        self.db.execute('INSERT OR REPLACE INTO meta VALUES (?,?)', (key, encode(value)))

    def rows(self, kind, *, paged=False):
        if not paged:
            return CheckpointRows(self.db, kind)
        if kind not in self.page_rows:
            self.page_rows[kind] = CheckpointRows(self.db, kind, paged=True)
        return self.page_rows[kind]

    def mapping(self, kind):
        return CheckpointMap(self.db, kind)

    def view_summaries(self):
        return [json.loads(value) for value, in self.db.execute('SELECT value FROM views ORDER BY seq')]

    def save_page(self, result, index, summary, cursor):
        for rows in self.page_rows.values():
            rows.flush()
        self.db.execute('INSERT OR REPLACE INTO views VALUES (?,?)', (index, encode(summary)))
        self.put('counts', {key: result[key] for key in ('records', 'search_matches', 'duplicate_destinations',
                                                        'alias_views', 'commands', 'image_alternatives')})
        self.put('cursor', cursor)
        if self.review is not None:
            self.put('matched_example', self.review.matched_example)
        self.db.commit()


class CheckpointMap:
    def __init__(self, db, kind):
        self.db, self.kind = db, kind

    def _row(self, key):
        return self.db.execute('SELECT value FROM maps WHERE kind=? AND key=?', (self.kind, encode(key))).fetchone()

    def __contains__(self, key):
        return self._row(key) is not None

    def __getitem__(self, key):
        row = self._row(key)
        if row is None:
            raise KeyError(key)
        value = row[0] if isinstance(row[0], bytes) else json.loads(row[0])
        return tuple(value) if self.kind == 'references' else value

    def __setitem__(self, key, value):
        stored = value if isinstance(value, bytes) else encode(value)
        self.db.execute('INSERT INTO maps VALUES (?,?,?) ON CONFLICT(kind,key) DO UPDATE SET value=excluded.value '
                        'WHERE maps.value != excluded.value', (self.kind, encode(key), stored))

    def get(self, key, default=None):
        try:
            return self[key]
        except KeyError:
            return default

    def setdefault(self, key, value):
        try:
            return self[key]
        except KeyError:
            self[key] = value
            return value


class CheckpointRows:
    def __init__(self, db, kind, *, paged=False):
        self.db, self.kind = db, kind
        self.pending = [] if paged else None
        self.count = db.execute('SELECT coalesce(sum(row_count),0) FROM report WHERE kind=?', (kind,)).fetchone()[0]

    def __len__(self):
        return self.count

    def append(self, row):
        value = encode(row)
        if self.pending is None:
            self.db.execute('INSERT INTO report(kind,value) VALUES (?,?)', (self.kind, value))
        else:
            self.pending.append(value)
            if len(self.pending) == 128:
                self.flush()
        self.count += 1

    def flush(self):
        if not self.pending:
            return
        # Keep small tails directly readable. Larger groups share titles, field paths and JSON keys.
        if len(self.pending) < 8:
            self.db.executemany('INSERT INTO report(kind,value) VALUES (?,?)',
                                ((self.kind, value) for value in self.pending))
        else:
            data = zlib.compress(('[' + ','.join(self.pending) + ']').encode('utf-8'), level=1)
            self.db.execute('INSERT INTO report(kind,value,row_count) VALUES (?,?,?)',
                            (self.kind, data, len(self.pending)))
        self.pending.clear()

    def _rows(self):
        for payload, count in self.db.execute('SELECT value,row_count FROM report WHERE kind=? ORDER BY seq', (self.kind,)):
            if type(count) is int and count == 1 and isinstance(payload, str):
                yield json.loads(payload)
                continue
            if type(count) is not int or not 8 <= count <= 128 or not isinstance(payload, bytes):
                raise ValueError('Invalid audit row group')
            try:
                batch = json.loads(zlib.decompress(payload))
            except zlib.error as error:
                raise ValueError('Invalid compressed audit rows') from error
            if not isinstance(batch, list) or len(batch) != count:
                raise ValueError('Invalid audit row count')
            yield from batch

    def chunks(self, nested_json, row_body):
        self.flush()
        items = self._rows()
        rows = list(islice(items, 128))
        if len(self) <= 128:
            yield nested_json(rows)
            return
        yield '['
        while rows:
            yield row_body(rows)
            rows = list(islice(items, 128))
            if rows:
                yield ','
        yield '\n  ]'


def file_binding(path):
    path = Path(path).absolute()
    def identity(st):
        return [st.st_dev, st.st_ino, st.st_mode, st.st_size, st.st_mtime_ns, st.st_ctime_ns]
    target = path.stat()
    if not stat.S_ISREG(target.st_mode):
        raise ValueError(f'Checkpoint input is not a regular file: {path}')
    return [str(path), str(path.resolve(strict=True)), identity(path.lstat()), identity(target)]
