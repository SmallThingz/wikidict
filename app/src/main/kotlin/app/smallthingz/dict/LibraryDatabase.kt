package app.smallthingz.dict

import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper

/** Keep old installations intact; unscoped dictionaries never gain guessed redirect associations. */
internal class LibraryDatabase(context: Context, name: String = "library.db") : SQLiteOpenHelper(context, name, null, 2) {
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
