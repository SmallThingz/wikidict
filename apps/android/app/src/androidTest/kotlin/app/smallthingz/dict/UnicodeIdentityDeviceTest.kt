package app.smallthingz.dict

import androidx.test.platform.app.InstrumentationRegistry
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test

class UnicodeIdentityDeviceTest {
    @Test fun bomTitleHeadingAndSavedIdentitySurviveSQLiteRoundtrip(): Unit = runBlocking {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        assumeTrue(context.packageName.endsWith(".validation"))
        val library = LibraryStore.get(context)
        library.refreshCatalogs().join()
        val before = library.dictionaries.map { it.id }.toSet()
        val title = "\uFEFFword"
        val heading = "\uFEFFEnglish"
        val edition = "bomwiktionary-20261001"
        val learning = LearningStore.get(context)
        var historyKey: String? = null
        try {
            library.importFile(name={"$edition-93eaaad295c94f5b52113b9032a16310e01a620e52557e4db08d826914bef869.wikblb"}) {
                instrumentation.context.assets.open("bom-identities.wikblb")
            }.join()
            assertNull(library.error)
            val dictionary = library.dictionaries.single { it.id !in before }
            assertEquals(heading,dictionary.language)
            val hit = library.exact(title,heading,edition)!!
            assertEquals(title,hit.title);assertEquals(title,hit.recordKey);assertEquals(heading,hit.language)
            assertEquals(hit,library.search(title).single { it.dictionary == dictionary.id })
            assertNull(library.exact("word",heading,edition))
            val entry = library.read(hit)
            assertEquals(title,entry.title);assertEquals(heading,entry.language)
            assertEquals(hit.key,library.link(EntryLink(title),entry)!!.key)
            library.rememberWord(hit)
            assertEquals(hit.key,library.lastWord()!!.key)
            withContext(Dispatchers.Main) { learning.record(entry) }
            historyKey = entry.key
            val saved = learning.data.history.single { it.key == entry.key }
            assertEquals(title,saved.title);assertEquals(hit.key,library.savedWord(saved)!!.key)
            // A fresh connection reads exact persisted TEXT; only the bound RHS has a sentinel.
            context.openOrCreateDatabase("library.db",0,null).use { db ->
                db.rawQuery("SELECT w.title,w.record_key,d.language,typeof(w.title),hex(w.title) FROM words w JOIN dictionaries d ON d.id=w.dictionary WHERE w.dictionary=? AND w.normalized=substr(?,2)",arrayOf(dictionary.id,"x$title")).use { c ->
                    assertTrue(c.moveToFirst());assertEquals(title,c.getString(0));assertEquals(title,c.getString(1))
                    assertEquals(heading,c.getString(2));assertEquals("text",c.getString(3));assertEquals("EFBBBF776F7264",c.getString(4))
                }
                db.rawQuery("EXPLAIN QUERY PLAN SELECT title FROM words WHERE normalized=substr(?,2)",arrayOf("x$title")).use { c ->
                    val plans = buildList { while(c.moveToNext()) add(c.getString(3)) }
                    assertTrue(plans.toString(),plans.any { "word_lookup" in it && "SEARCH" in it })
                }
            }
        } finally {
            historyKey?.let { withContext(Dispatchers.Main) { learning.removeHistory(it) } }
            library.dictionaries.map { it.id }.filter { it !in before }.forEach { library.remove(it).join() }
        }
    }
}
