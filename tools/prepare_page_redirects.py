#!/usr/bin/env python3
"""Derive authoritative page redirects from the same pinned SQL dump as the XML."""
import hashlib
import json
import os
from pathlib import Path
import re
import sqlite3
import stat

import category_tree_snapshot

SCHEMA = 'wikidict-page-redirects-v1'
FIELDS = ('wiki', 'date', 'name', 'url', 'size', 'sha1')
MAX_SQL_BYTES = 64 * 1024 * 1024
MAX_OUTPUT_BYTES = 256 * 1024 * 1024
MAX_ROWS = 4_000_000
MAX_LINE = 64 * 1024


def sha256(path):
    h = hashlib.sha256()
    with Path(path).open('rb') as stream:
        while data := stream.read(1024 * 1024):
            h.update(data)
    return h.hexdigest()


def stamp(path):
    path = Path(path)
    for parent in (path, *path.parents):
        if parent.is_symlink():
            raise ValueError('Symlink in redirect input/output path')
    st = path.lstat()
    if not stat.S_ISREG(st.st_mode):
        raise ValueError('Redirect artifact is not a regular file')
    return (st.st_dev, st.st_ino, st.st_size, st.st_mtime_ns, st.st_ctime_ns)


def source_identity(items, downloads):
    if not items:
        raise ValueError('No redirect dump inputs')
    wiki, date = items[0]['wiki'], items[0]['date']
    if (not re.fullmatch(r'[a-z0-9_]+wiktionary', wiki)
            or not re.fullmatch(r'[0-9]{8}', date)
            or any((i['wiki'], i['date']) != (wiki, date) for i in items)):
        raise ValueError('Mixed or invalid redirect wiki/date')
    name = wiki + '-' + date + '-redirect.sql.gz'
    selected = [i for i in items if i['name'] == name]
    if not selected:
        return None
    if len(selected) != 1:
        raise ValueError('Expected one pinned redirect SQL input')
    item = selected[0]
    path = Path(downloads) / wiki / date / name
    initial = stamp(path)
    if (type(item['size']) is not int or not 0 < item['size'] <= MAX_SQL_BYTES
            or initial[2] != item['size'] or not re.fullmatch('[0-9a-f]{40}', item['sha1'])):
        raise ValueError('Invalid redirect SQL size/checksum')
    h1, h256 = hashlib.sha1(), hashlib.sha256()
    with os.fdopen(os.open(path, os.O_RDONLY | os.O_NOFOLLOW), 'rb') as stream:
        opened = os.fstat(stream.fileno())
        if (opened.st_dev, opened.st_ino, opened.st_size, opened.st_mtime_ns, opened.st_ctime_ns) != initial:
            raise ValueError('Redirect SQL changed before hashing')
        while block := stream.read(1024 * 1024):
            h1.update(block); h256.update(block)
    if stamp(path) != initial or h1.hexdigest() != item['sha1']:
        raise ValueError('Redirect SQL changed or disagrees with pinned download')
    return dict(schema=SCHEMA, source={key: item[key] for key in FIELDS},
                sql_sha256=h256.hexdigest(), generator_sha256=sha256(Path(__file__)),
                parser_sha256=sha256(Path(category_tree_snapshot.__file__)))


def header(identity):
    source = identity['source']
    return ('# ' + SCHEMA + '\n# wiki\t' + source['wiki']
            + '\n# dump-date\t' + source['date']
            + '\n# sql-sha256\t' + identity['sql_sha256'] + '\n').encode()


def checked_row(key, namespace, title, interwiki, fragment):
    if type(key) is not int or not 0 < key <= 0xffffffff:
        raise ValueError('Invalid redirect source page ID')
    if type(namespace) is not int or not -(1 << 31) <= namespace < (1 << 31):
        raise ValueError('Invalid redirect target namespace')
    # SQL NULL and the empty string both denote no interwiki prefix/fragment.
    interwiki = b'' if interwiki is None else interwiki
    fragment = b'' if fragment is None else fragment
    for value in (title, interwiki, fragment):
        if not isinstance(value, bytes) or b'\0' in value:
            raise ValueError('Invalid redirect text field')
        value.decode('utf-8', errors='strict')
    if not title or len(title) > 4096 or len(interwiki) > 255 or len(fragment) > 255:
        raise ValueError('Oversized or empty redirect target')
    return key, namespace, title, interwiki, fragment


def wire_row(record):
    key, namespace, title, interwiki, fragment = checked_row(*record)
    return (str(key) + '\t' + str(namespace) + '\t' + title.hex() + '\t'
            + interwiki.hex() + '\t' + fragment.hex() + '\n').encode()


def validate_wire(path, identity):
    initial = stamp(path)
    if initial[2] > MAX_OUTPUT_BYTES:
        raise ValueError('Oversized derived redirect snapshot')
    digest, count, previous = hashlib.sha256(), 0, 0
    with Path(path).open('rb') as stream:
        first = stream.read(len(header(identity)))
        digest.update(first)
        if first != header(identity):
            raise ValueError('Redirect snapshot identity mismatch')
        while True:
            line = stream.readline(MAX_LINE + 1)
            digest.update(line)
            if len(line) > MAX_LINE or not line.endswith(b'\n'):
                raise ValueError('Incomplete or oversized redirect row')
            if line.startswith(b'# end\t'):
                if line != ('# end\t' + str(count) + '\n').encode() or stream.read(1):
                    raise ValueError('Redirect footer count or EOF mismatch')
                break
            columns = line[:-1].split(b'\t')
            if len(columns) != 5:
                raise ValueError('Malformed derived redirect row')
            record = checked_row(int(columns[0]), int(columns[1]),
                                 *(bytes.fromhex(value.decode('ascii')) for value in columns[2:]))
            if record[0] <= previous or wire_row(record) != line:
                raise ValueError('Duplicate, unsorted or noncanonical redirect row')
            count += 1; previous = record[0]
            if count > MAX_ROWS:
                raise ValueError('Too many redirect rows')
    if stamp(path) != initial:
        raise ValueError('Derived redirect snapshot changed during validation')
    return dict(row_count=count, output_bytes=initial[2], output_sha256=digest.hexdigest())


def prepare_from_dumps(items, downloads, workspace, expected_identity=None):
    identity = source_identity(items, downloads)
    if expected_identity is not None and identity != expected_identity:
        raise ValueError('Redirect SQL differs from planned build input')
    if identity is None:
        return None
    source = identity['source']
    sql = Path(downloads) / source['wiki'] / source['date'] / source['name']
    before = stamp(sql)
    folder = Path(workspace) / 'derived-page-redirects'
    for parent in (folder, *folder.parents):
        if parent.is_symlink():
            raise ValueError('Unsafe redirect workspace')
    folder.mkdir(parents=True, exist_ok=True)
    output, proof = folder / 'page-redirects.tsv', folder / 'page-redirects.provenance.json'
    for path in (output, proof):
        if path.is_symlink():raise ValueError('Unsafe derived redirect artifact')
        if path.exists():stamp(path)
    if output.exists() and proof.exists():
        try:
            proof_stamp = stamp(proof)
            if proof_stamp[2] > 1024 * 1024:
                raise ValueError('Oversized redirect provenance')
            recorded = json.loads(proof.read_bytes())
            if (recorded.get('identity') == identity and recorded.get('output') == validate_wire(output, identity)
                    and stamp(proof) == proof_stamp and stamp(sql) == before):
                return output
        except (ValueError, KeyError, OSError):
            pass
    # Sorting is disk-backed, so a high redirect count does not grow a Python map.
    database = folder / ('sort-' + str(os.getpid()) + '.sqlite')
    temporary = output.with_name(output.name + '.part-' + str(os.getpid()))
    temporary_proof = proof.with_name(proof.name + '.part-' + str(os.getpid()))
    if any(path.exists() or path.is_symlink() for path in (database, temporary, temporary_proof)):
        raise ValueError('Unsafe existing redirect conversion temporary')
    connection = sqlite3.connect(database)
    try:
        connection.execute('PRAGMA journal_mode=OFF')
        connection.execute('PRAGMA synchronous=OFF')
        connection.execute('PRAGMA cache_size=-8192')
        connection.execute('PRAGMA temp_store=FILE')
        connection.execute('PRAGMA mmap_size=0')
        connection.execute('PRAGMA threads=0')
        connection.execute('CREATE TABLE redirects(id INTEGER PRIMARY KEY, ns INTEGER, title BLOB, interwiki BLOB, fragment BLOB)')
        count = 0
        for record in category_tree_snapshot.rows(sql, ('rd_from', 'rd_namespace', 'rd_title', 'rd_interwiki', 'rd_fragment')):
            record = checked_row(*record)
            count += 1
            if count > MAX_ROWS:
                raise ValueError('Too many SQL redirect rows')
            try:
                connection.execute('INSERT INTO redirects VALUES(?,?,?,?,?)', record)
            except sqlite3.IntegrityError as error:
                raise ValueError('Duplicate redirect source page ID') from error
        connection.commit()
        with temporary.open('xb') as out:
            out.write(header(identity))
            for record in connection.execute('SELECT id,ns,title,interwiki,fragment FROM redirects ORDER BY id'):
                out.write(wire_row(record))
                if out.tell() > MAX_OUTPUT_BYTES - MAX_LINE:
                    raise ValueError('Derived redirect output exceeds admission bound')
            out.write(('# end\t' + str(count) + '\n').encode())
            out.flush(); os.fsync(out.fileno())
        observed = validate_wire(temporary, identity)
        if stamp(sql) != before or source_identity(items, downloads) != identity:
            raise ValueError('Redirect input changed during conversion')
        record = dict(identity=identity, output=observed)
        with temporary_proof.open('x', encoding='utf-8') as out:
            out.write(json.dumps(record, sort_keys=True, indent=2) + '\n')
            out.flush(); os.fsync(out.fileno())
        os.replace(temporary, output)
        os.replace(temporary_proof, proof)
        return output
    finally:
        connection.close()
        database.unlink(missing_ok=True)
        temporary.unlink(missing_ok=True)
        temporary_proof.unlink(missing_ok=True)
