package app.smallthingz.dict

import android.content.Context
import android.content.ContextWrapper
import android.database.DatabaseErrorHandler
import android.database.sqlite.SQLiteDatabase
import androidx.activity.compose.setContent
import androidx.compose.material3.MaterialTheme
import androidx.compose.ui.test.*
import androidx.test.platform.app.InstrumentationRegistry
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import java.io.File
import java.io.IOException
import java.util.UUID

/** Test-owned databases and preferences only; future device execution still requires normal custody. */
class EmptyEditionDeviceTest {
    @get:Rule val compose = createLegacyPhysicalComposeRule()
    private val summary = EmptyEditionInfo("aawiktionary-20261001", 101, "content://fixture/opaque", "a".repeat(64), "b".repeat(64))

    private class OwnedContext(base: Context) : ContextWrapper(base) {
        val token = "empty-edition-${UUID.randomUUID()}"
        val directory = File(base.cacheDir, token).apply { check(mkdir()) }
        private val preferenceNames = mutableSetOf<String>()
        override fun getApplicationContext(): Context = this
        override fun getFilesDir(): File = directory
        override fun getDatabasePath(name: String): File = File(directory, name)
        override fun openOrCreateDatabase(name: String, mode: Int, factory: SQLiteDatabase.CursorFactory?): SQLiteDatabase =
            SQLiteDatabase.openOrCreateDatabase(getDatabasePath(name), factory)
        override fun openOrCreateDatabase(name: String, mode: Int, factory: SQLiteDatabase.CursorFactory?, errorHandler: DatabaseErrorHandler?): SQLiteDatabase =
            SQLiteDatabase.openOrCreateDatabase(getDatabasePath(name).path, factory, errorHandler)
        override fun getSharedPreferences(name: String, mode: Int): android.content.SharedPreferences {
            val ownedName = "$token-$name"
            preferenceNames.add(ownedName)
            return baseContext.getSharedPreferences(ownedName, mode)
        }
        fun close() {
            preferenceNames.forEach { check(baseContext.deleteSharedPreferences(it)) }
            check(directory.deleteRecursively())
        }
    }

    private fun withDatabase(action: (OwnedContext, SQLiteDatabase) -> Unit) {
        val context = OwnedContext(InstrumentationRegistry.getInstrumentation().targetContext)
        try { LibraryDatabase(context).use { helper -> action(context, helper.writableDatabase) } }
        finally { context.close() }
    }

    @Test fun versionThreeUpgradeAddsSummariesWithoutChangingWordsOrDictionaryRows() {
        val context = OwnedContext(InstrumentationRegistry.getInstrumentation().targetContext)
        try {
            SQLiteDatabase.openOrCreateDatabase(context.getDatabasePath("library.db"), null).use { db ->
                LibraryDatabase(context, "unused.db").use { it.onCreate(db) }
                db.execSQL("DROP TABLE empty_editions")
                db.execSQL("INSERT INTO dictionaries VALUES('kept','Afar','aa','language',1,99,'otherwiktionary-20261001')")
                db.execSQL("INSERT INTO words VALUES('kept','Word','word',9,12,'Word','language')")
                db.version = 3
            }
            LibraryDatabase(context).use { helper ->
                val db = helper.writableDatabase
                assertEquals(4, db.version)
                assertTrue(readEmptyEditions(db).isEmpty())
                db.rawQuery("SELECT dictionary,title,normalized,payload,length,record_key,source_kind FROM words", null).use { c ->
                    assertTrue(c.moveToFirst())
                    assertEquals(listOf("kept", "Word", "word", "9", "12", "Word", "language"), (0..6).map { c.getString(it) })
                    assertFalse(c.moveToNext())
                }
                db.rawQuery("SELECT dictionary,title FROM word_choices", null).use { c ->
                    assertTrue(c.moveToFirst()); assertEquals("kept", c.getString(0)); assertEquals("Word", c.getString(1))
                }
                db.rawQuery("SELECT id,language,code,kind,count,bytes,edition FROM dictionaries", null).use { c ->
                    assertTrue(c.moveToFirst())
                    assertEquals(listOf("kept", "Afar", "aa", "language", "1", "99", "otherwiktionary-20261001"), (0..6).map { c.getString(it) })
                }
            }
        } finally { context.close() }
    }

    @Test fun summaryTransactionsAreIdempotentAndFailuresPreserveExistingLibrary() = withDatabase { _, db -> runBlocking {
        var visible = emptyList<EmptyEditionInfo>()
        suspend fun refresh() { visible = readEmptyEditions(db) }
        repeat(2) { mutateEmptyEditions(db, ::refresh) { registerEmptyEdition(db, summary) } }
        assertEquals(listOf(summary), visible)
        try {
            mutateEmptyEditions(db, ::refresh) {
                registerEmptyEdition(db, summary.copy(sourcePages = 102))
                throw IOException("controlled import failure before commit")
            }
            fail("Mutation should fail")
        } catch (_: IOException) { }
        assertEquals(listOf(summary), visible)
        db.execSQL("INSERT INTO dictionaries VALUES('kept','Afar','aa','language',1,99,'otherwiktionary-20261001')")
        try {
            mutateEmptyEditions(db, ::refresh) { registerEmptyEdition(db, summary.copy(edition = "otherwiktionary-20261001")) }
            fail("Installed dictionary must win")
        } catch (_: IllegalArgumentException) { }
        assertEquals(listOf(summary), visible)
        db.rawQuery("SELECT id FROM dictionaries", null).use { c -> assertTrue(c.moveToFirst()); assertEquals("kept", c.getString(0)) }
        mutateEmptyEditions(db, ::refresh) { db.delete("empty_editions", "edition=?", arrayOf(summary.edition)) }
        assertTrue(visible.isEmpty())
        db.rawQuery("SELECT id FROM dictionaries", null).use { c -> assertTrue(c.moveToFirst()); assertEquals("kept", c.getString(0)) }
    } }

    @Test fun normalLibrarySelectsSummaryKeepsItAcrossRevisionAndBackDoesNotCreateWordHistory() = runBlocking {
        val context = OwnedContext(InstrumentationRegistry.getInstrumentation().targetContext)
        var store: LibraryStore? = null
        try {
            context.getSharedPreferences("library", 0).edit().putStringSet("sources", emptySet()).commit()
            LibraryDatabase(context).use { helper ->
                registerEmptyEdition(helper.writableDatabase, summary)
                registerEmptyEdition(helper.writableDatabase, summary.copy(edition = "otherwiktionary-20261001"))
            }
            val library = LibraryStore::class.java.getDeclaredConstructor(Context::class.java).apply { isAccessible = true }.newInstance(context)
            store = library
            val learning = LearningStore::class.java.getDeclaredConstructor(Context::class.java).apply { isAccessible = true }.newInstance(context)
            val previousHistory = learning.data.history
            val scope = LibraryStore::class.java.getDeclaredField("scope").apply { isAccessible = true }.get(library) as CoroutineScope
            withTimeout(10_000) { scope.coroutineContext[Job]!!.children.toList().joinAll() }
            assertNull(library.initializationError)
            compose.runOnUiThread { compose.activity.setContent { MaterialTheme { DictApp(library, learning, onImport = {}) } } }
            compose.onNodeWithText(sourceLabel(summary.edition)).performClick()
            compose.onNodeWithText("Completed release").assertIsDisplayed()
            compose.onNodeWithText("101 source pages processed. This release contains no word entries to browse.").assertIsDisplayed()
            library.removeEmptyEdition("otherwiktionary-20261001").join()
            compose.onNodeWithText("Completed release").assertIsDisplayed()
            compose.runOnUiThread { compose.activity.onBackPressedDispatcher.onBackPressed() }
            compose.onNodeWithText("Dictionaries").assertIsDisplayed()
            compose.onNodeWithText(sourceLabel(summary.edition)).performClick()
            library.removeEmptyEdition(summary.edition).join()
            compose.onNodeWithText("Completed release").assertDoesNotExist()
            compose.onNodeWithText("Dictionaries").assertIsDisplayed()
            assertEquals(previousHistory, learning.data.history)
            assertTrue(library.dictionaries.isEmpty())
            assertTrue(library.search("").isEmpty())
            assertNull(library.random())
        } finally {
            compose.runOnUiThread { compose.activity.setContent {} }
            store?.let { library ->
                val scope = LibraryStore::class.java.getDeclaredField("scope").apply { isAccessible = true }.get(library) as CoroutineScope
                scope.coroutineContext[Job]!!.cancelAndJoin()
                (LibraryStore::class.java.getDeclaredField("helper").apply { isAccessible = true }.get(library) as LibraryDatabase).close()
            }
            context.close()
        }
    }
}
