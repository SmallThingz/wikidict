package app.smallthingz.dict

import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteTransactionListener
import android.os.Looper
import kotlinx.coroutines.*
import kotlinx.coroutines.sync.Mutex
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.io.IOException
import java.util.UUID

@RunWith(AndroidJUnit4::class)
class InstallTransactionDeviceTest {
    private val id = "test-dictionary"
    private val bytes = "tiny synthetic dictionary bytes"

    private fun withDatabase(fullSchema: Boolean = false, block: (SQLiteDatabase, File) -> Unit) {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val directory = File(context.cacheDir, "install-transaction-${UUID.randomUUID()}")
        check(directory.mkdir())
        var database: SQLiteDatabase? = null
        try {
            val db = SQLiteDatabase.openOrCreateDatabase(File(directory, "test.db"), null)
            database = db
            assertTrue(db.enableWriteAheadLogging())
            if (fullSchema) {
                // Use the real schema on this test-owned connection; never open the app database.
                LibraryDatabase(context, "unused-${UUID.randomUUID()}.db").use { it.onCreate(db) }
            } else db.execSQL("CREATE TABLE dictionaries(id TEXT PRIMARY KEY)")
            val file = File(directory, "$id.wikblb").apply { writeText(bytes) }
            block(db, file)
        } finally {
            try {
                val db = database
                if (db != null && db.isOpen) {
                    try { if (db.inTransaction()) db.endTransaction() }
                    finally { db.close() }
                }
            } finally {
                assertTrue("Owned test directory must be removed", directory.deleteRecursively())
            }
        }
    }

    private fun insert(db: SQLiteDatabase) {
        db.execSQL("INSERT INTO dictionaries(id) VALUES(?)", arrayOf(id))
    }

    private fun rows(db: SQLiteDatabase): List<String> =
        db.rawQuery("SELECT id FROM dictionaries ORDER BY id", null).use { cursor ->
            buildList { while (cursor.moveToNext()) add(cursor.getString(0)) }
        }

    @Test fun realCommitListenerRollbackRemovesConfirmedOrphan() = withDatabase { db, file ->
        val failure = IllegalStateException("test commit listener refuses commit")
        db.beginTransactionWithListener(object : SQLiteTransactionListener {
            override fun onBegin() = Unit
            override fun onCommit() { throw failure }
            override fun onRollback() = Unit
        })
        insert(db)
        db.setTransactionSuccessful()
        val caught = assertThrows(IllegalStateException::class.java) {
            finishDictionaryInstall(null, file, { db.endTransaction() },
                registered = {
                    assertTrue(file.exists())
                    committedDictionaryRegistration(db, id).also { assertFalse(db.inTransaction()) }
                }, refresh = { throw AssertionError("Rolled-back row must not be shown") })
        }
        assertSame(failure, caught)
        assertTrue(rows(db).isEmpty())
        assertFalse(file.exists())
    }

    @Test fun realCommitThenBoundaryExceptionKeepsBytesAndRefreshes() = withDatabase { db, file ->
        val failure = IOException("test boundary after real COMMIT")
        var visible = emptyList<String>()
        db.beginTransaction()
        insert(db)
        db.setTransactionSuccessful()
        val caught = assertThrows(IOException::class.java) {
            finishDictionaryInstall(null, file,
                endTransaction = { db.endTransaction(); throw failure },
                registered = { committedDictionaryRegistration(db, id) },
                refresh = { visible = rows(db) })
        }
        assertSame(failure, caught)
        assertEquals(listOf(id), visible)
        assertEquals(listOf(id), rows(db))
        assertEquals(bytes, file.readText())
        assertFalse(db.inTransaction())
    }

    @Test fun activeRealTransactionRetainsBytesUntilOutcomeIsKnown() = withDatabase { db, file ->
        val failure = IOException("test boundary before transaction end")
        db.beginTransaction()
        insert(db)
        val caught = assertThrows(IOException::class.java) {
            finishDictionaryInstall(null, file, { throw failure },
                { committedDictionaryRegistration(db, id) },
                { throw AssertionError("Active transaction cannot claim committed registration") })
        }
        assertSame(failure, caught)
        assertTrue(db.inTransaction())
        assertEquals(bytes, file.readText())
        // The fixture finally rolls this unmarked, test-owned transaction back.
    }

    @Test fun unavailableRealDatabaseRetainsBytesAndOriginalError() = withDatabase { db, file ->
        val failure = IOException("test failure after rollback and connection close")
        db.beginTransaction()
        insert(db)
        val caught = assertThrows(IOException::class.java) {
            finishDictionaryInstall(null, file,
                { db.endTransaction(); db.close(); throw failure },
                { committedDictionaryRegistration(db, id) },
                { throw AssertionError("Unavailable database cannot claim refresh") })
        }
        assertSame(failure, caught)
        assertEquals(1, caught.suppressed.size)
        assertFalse(db.isOpen)
        assertEquals(bytes, file.readText())
    }

    @Test fun completedAbsenceProofThenBoundaryFailureDoesNotDelete() = withDatabase { db, file ->
        val failure = IOException("test failure after rollback")
        val proofFailure = IOException("test boundary before completed proof is returned")
        db.beginTransaction()
        insert(db)
        val caught = assertThrows(IOException::class.java) {
            finishDictionaryInstall(null, file, { db.endTransaction(); throw failure },
                registered = {
                    assertEquals(false, committedDictionaryRegistration(db, id))
                    assertFalse(db.inTransaction())
                    throw proofFailure
                }, refresh = { throw AssertionError("Failed proof cannot claim refresh") })
        }
        assertSame(failure, caught)
        assertArrayEquals(arrayOf<Throwable>(proofFailure), caught.suppressed)
        assertTrue(rows(db).isEmpty())
        assertEquals(bytes, file.readText())
    }

    @Test fun normalAndAlreadyInstalledTransactionsRefreshRealCommittedRows() = withDatabase { db, file ->
        var visible = emptyList<String>()
        var refreshes = 0
        db.beginTransaction()
        insert(db)
        db.setTransactionSuccessful()
        finishDictionaryInstall(null, file, { db.endTransaction() },
            { throw AssertionError("Successful commit needs no failure reconciliation") },
            { visible = rows(db); refreshes++ })
        assertEquals(listOf(id), visible)

        visible = emptyList()
        db.beginTransaction() // Mirrors the validated already-installed early-return path.
        finishDictionaryInstall(null, null, { db.endTransaction() },
            { throw AssertionError("No new placement needs no failure reconciliation") },
            { visible = rows(db); refreshes++ })
        assertEquals(listOf(id), visible)
        assertEquals(2, refreshes)
        assertEquals(bytes, file.readText())
        assertFalse(db.inTransaction())
    }

    @Test fun cancellationAfterRealInsertAndRemovalPublishesBeforeOwnerRelease() = withDatabase(fullSchema = true) { db, _ ->
        runBlocking { withTimeout(5_000) {
            val operations = LibraryOperationOwner(Mutex())
            val dictionary = DictionaryInfo(id, "French", "fr", "language", 1, bytes.length.toLong(), "arwiktionary-20261001")
            var visible = emptyList<DictionaryInfo>()
            var revision = 0
            val events = mutableListOf<String>()
            for ((index, removing) in listOf(false, true).withIndex()) {
                val label = if (removing) "remove" else "insert"
                val owner = launch(Dispatchers.IO) {
                    try {
                        operations.run {
                            val currentOwner = currentCoroutineContext().job
                            try {
                                db.beginTransaction()
                                try {
                                    if (removing) {
                                        assertEquals(1, db.delete("dictionaries", "id=?", arrayOf(id)))
                                    } else {
                                        db.execSQL("INSERT INTO dictionaries VALUES(?,?,?,?,?,?,?)", arrayOf<Any>(
                                            dictionary.id, dictionary.language, dictionary.code, dictionary.kind,
                                            dictionary.count, dictionary.bytes, dictionary.edition))
                                    }
                                    db.setTransactionSuccessful()
                                } finally { db.endTransaction() }
                                assertFalse(db.inTransaction())
                                assertEquals(if (removing) emptyList<String>() else listOf(id), rows(db))
                                // Exact cancellation boundary: COMMIT returned, publication has not started.
                                currentOwner.cancel(CancellationException("after $label commit"))
                                publishLibrarySnapshot(db) { values ->
                                    assertSame(Looper.getMainLooper(), Looper.myLooper())
                                    assertSame(currentOwner, operations.active)
                                    visible = values
                                    revision++
                                    events += "$label published"
                                }
                                fail("Cancellation must remain observable after committed-state publication")
                            } finally { events += "$label cleanup" }
                        }
                    } catch (cancelled: CancellationException) {
                        assertFalse(currentCoroutineContext().isActive)
                        assertNull(operations.active)
                        events += "$label cancelled"
                        throw cancelled
                    }
                }
                owner.join()
                assertTrue(owner.isCancelled)
                assertNull(operations.active)
                assertEquals(index + 1, revision)
                assertEquals(if (removing) emptyList<DictionaryInfo>() else listOf(dictionary), visible)
                assertEquals(listOf("$label published", "$label cleanup", "$label cancelled"), events.takeLast(3))
                assertEquals(if (removing) emptyList<String>() else listOf(id), rows(db))
            }
        } }
    }
}
