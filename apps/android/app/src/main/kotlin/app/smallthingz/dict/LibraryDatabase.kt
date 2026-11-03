package app.smallthingz.dict

import android.content.Context
import android.icu.lang.UCharacter
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper

internal fun foldSearchKey(value: String): String = UCharacter.foldCase(value, true)

/** Exclusive upper bound in SQLite BINARY order for a valid Unicode prefix. */
internal fun searchPrefixUpperBound(prefix: String): String? {
    var end = prefix.length
    while (end > 0) {
        val scalar = Character.codePointBefore(prefix, end)
        val start = end - Character.charCount(scalar)
        if (scalar < 0x10ffff) {
            val next = if (scalar == 0xd7ff) 0xe000 else scalar + 1
            return prefix.substring(0, start) + String(Character.toChars(next))
        }
        end = start
    }
    // Empty and all-maximum-scalar prefixes have no finite exclusive upper bound.
    return null
}

/** Keep old installations intact; unscoped dictionaries never gain guessed redirect associations. */
internal class LibraryDatabase(context: Context, name: String = "library.db") : SQLiteOpenHelper(context, name, null, 3) {
    override fun onCreate(db: SQLiteDatabase) {
        db.execSQL("CREATE TABLE dictionaries(id TEXT PRIMARY KEY,language TEXT,code TEXT,kind TEXT,count INTEGER,bytes INTEGER,edition TEXT NOT NULL DEFAULT '')")
        db.execSQL("CREATE TABLE words(dictionary TEXT,title TEXT,normalized TEXT,payload INTEGER,length INTEGER,record_key TEXT NOT NULL,source_kind TEXT NOT NULL)")
        db.execSQL("CREATE INDEX word_lookup ON words(normalized,title)")
        db.execSQL("CREATE INDEX word_dictionary ON words(dictionary)")
        finishSchema(db)
    }
    override fun onUpgrade(db: SQLiteDatabase, oldVersion: Int, newVersion: Int) {
        if (oldVersion < 2) {
            db.execSQL("ALTER TABLE dictionaries ADD COLUMN edition TEXT NOT NULL DEFAULT ''")
            db.execSQL("ALTER TABLE words ADD COLUMN record_key TEXT NOT NULL DEFAULT ''")
            db.execSQL("ALTER TABLE words ADD COLUMN source_kind TEXT NOT NULL DEFAULT ''")
            db.execSQL("UPDATE words SET record_key=title, source_kind=(SELECT kind FROM dictionaries WHERE id=words.dictionary)")
            finishSchema(db)
        }
        if (oldVersion < 3) rekeySearch(db)
    }
    private fun rekeySearch(db: SQLiteDatabase) {
        // SQLiteOpenHelper encloses the upgrade and version change in one transaction.
        // Close each bounded read before updating; row IDs and all original fields stay intact.
        var after: Long? = null
        db.compileStatement("UPDATE words SET normalized=CAST(? AS TEXT) WHERE rowid=?").use { update ->
            while (true) {
                val rows = db.rawQuery(
                    if (after == null) "SELECT rowid,title FROM words ORDER BY rowid LIMIT 128"
                    else "SELECT rowid,title FROM words WHERE rowid>? ORDER BY rowid LIMIT 128",
                    after?.let { arrayOf(it.toString()) },
                ).use { cursor -> buildList {
                    while (cursor.moveToNext()) add(cursor.getLong(0) to cursor.getString(1))
                } }
                if (rows.isEmpty()) break
                for ((rowid, title) in rows) {
                    // bindBlob + CAST retains an initial U+FEFF, just like imported titles.
                    update.bindBlob(1, foldSearchKey(title).toByteArray(Charsets.UTF_8))
                    update.bindLong(2, rowid)
                    check(update.executeUpdateDelete() == 1) { "Search index row disappeared" }
                }
                after = rows.last().first
            }
        }
    }
    private fun finishSchema(db: SQLiteDatabase) {
        db.execSQL("CREATE UNIQUE INDEX scoped_dictionary ON dictionaries(edition,kind,language) WHERE edition<>''")
        db.execSQL("CREATE INDEX word_record ON words(dictionary,record_key)")
        db.execSQL("""CREATE VIEW word_choices AS
            SELECT w.dictionary,w.title,w.normalized,w.payload,w.length,w.record_key,d.kind,d.language,d.edition,
                   NULL AS context_dictionary,w.rowid AS wordid
              FROM words w JOIN dictionaries d ON d.id=w.dictionary WHERE d.kind<>'alias'
            UNION ALL
            SELECT w.dictionary,w.title,w.normalized,w.payload,w.length,w.record_key,w.source_kind,
                   CASE WHEN w.source_kind='language' THEN COALESCE(c.language,'') ELSE w.source_kind END,
                   d.edition,c.id,w.rowid
              FROM words w JOIN dictionaries d ON d.id=w.dictionary
              LEFT JOIN dictionaries c ON d.edition<>'' AND c.edition=d.edition AND c.kind=w.source_kind
             WHERE d.kind='alias'""")
    }
}
