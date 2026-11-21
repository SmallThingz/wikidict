package app.smallthingz.dict

import android.database.sqlite.SQLiteDatabase
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext

internal fun createEmptyEditionSchema(db: SQLiteDatabase) {
    db.execSQL("CREATE TABLE empty_editions(edition TEXT PRIMARY KEY NOT NULL,source_pages INTEGER NOT NULL,source_uri TEXT NOT NULL,marker_sha256 TEXT NOT NULL,catalog_sha256 TEXT NOT NULL)")
}

internal fun readEmptyEditions(db: SQLiteDatabase): List<EmptyEditionInfo> =
    db.rawQuery("SELECT edition,source_pages,source_uri,marker_sha256,catalog_sha256 FROM empty_editions ORDER BY edition", null).use { c ->
        buildList { while (c.moveToNext()) add(EmptyEditionInfo(c.getString(0), c.getLong(1), c.getString(2), c.getString(3), c.getString(4))) }
    }

internal fun registerEmptyEdition(db: SQLiteDatabase, edition: EmptyEditionInfo) {
    require(!db.rawQuery("SELECT 1 FROM dictionaries WHERE edition=? LIMIT 1", arrayOf(edition.edition)).use { it.moveToFirst() }) {
        "This edition already has installed dictionary files. Its contents were kept."
    }
    db.execSQL("INSERT OR REPLACE INTO empty_editions VALUES(?,?,?,?,?)",
        arrayOf<Any>(edition.edition, edition.sourcePages, edition.sourceUri, edition.markerSha256, edition.catalogSha256))
}

internal suspend fun mutateEmptyEditions(db: SQLiteDatabase, refresh: suspend () -> Unit, mutation: () -> Unit) {
    var failure: Throwable? = null
    db.beginTransaction()
    try {
        currentCoroutineContext().ensureActive()
        mutation()
        currentCoroutineContext().ensureActive()
        db.setTransactionSuccessful()
    } catch (error: Throwable) {
        failure = error
    } finally {
        // A cancellation or uncertain commit still publishes what SQLite actually retained.
        try { db.endTransaction() } catch (error: Throwable) {
            if (failure == null) failure = error else failure.addSuppressed(error)
        }
        try {
            check(!db.inTransaction()) { "Cannot confirm the edition update; the previous view was kept." }
            withContext(NonCancellable) { refresh() }
        } catch (error: Throwable) {
            if (failure == null) failure = error else failure.addSuppressed(error)
        }
    }
    failure?.let { throw it }
    currentCoroutineContext().ensureActive()
}
