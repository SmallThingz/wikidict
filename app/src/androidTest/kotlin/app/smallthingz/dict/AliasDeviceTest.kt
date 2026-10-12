package app.smallthingz.dict

import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import org.tukaani.xz.LZMA2Options
import org.tukaani.xz.XZOutputStream

@RunWith(AndroidJUnit4::class)
class AliasDeviceTest {
    private val instrumentation get() = InstrumentationRegistry.getInstrumentation()
    private val context get() = instrumentation.targetContext
    private fun isolated() = assumeTrue("Use the isolated validation app", context.packageName.endsWith(".validation"))
    private fun asset(name: String) = instrumentation.context.assets.open(name).use { it.readBytes() }
    private val englishName = "ba118bf7fc9c1aedc1edb28a0aa86e0b43b681f222af6616e13c43be87815b06.wikblb"
    private fun compressed(bytes: ByteArray) = ByteArrayOutputStream().also { output ->
        XZOutputStream(output,LZMA2Options(1)).use { it.write(bytes) }
    }.toByteArray()

    @Test fun legacySelectionsKeepTheirOriginalUnscopedContextAndDeclineAmbiguity(): Unit = runBlocking {
        isolated()
        val library = LibraryStore.get(context)
        library.refreshCatalogs().join()
        val before = library.dictionaries.map { it.id }.toSet()
        val prefs = context.getSharedPreferences("library",0)
        val lastKeys = listOf("lastTitle","lastLanguage","lastDictionary","lastRecordKey","lastContextDictionary","lastEdition")
        val oldPrefs = lastKeys.associateWith { prefs.getString(it,null) }
        val bytes = asset("compiled-alias-targets.wikblb")
        val legacy = SavedWord("legacy-English-animus","animus","English","language","")
        suspend fun install(name: String, raw: ByteArray): DictionaryInfo {
            val ids = library.dictionaries.map { it.id }.toSet()
            library.importFile(name={name}) { ByteArrayInputStream(raw) }.join()
            assertNull(library.error)
            return library.dictionaries.single { it.id !in ids }
        }
        try {
            val scoped = install("legacywiktionary-20261001-$englishName",bytes)
            assertNull(library.savedWord(legacy))
            prefs.edit().apply { lastKeys.forEach(::remove);putString("lastTitle","animus");putString("lastLanguage","English") }.commit()
            assertNull(library.lastWord())
            assertEquals(scoped.id,library.savedWord(legacy.copy(edition="legacywiktionary-20261001"))!!.dictionary)
            val unscoped = install("legacy-English.wikblb",bytes)
            assertEquals(unscoped.id,library.savedWord(legacy)!!.dictionary)
            assertEquals(unscoped.id,library.lastWord()!!.dictionary)
            assertNull(library.savedWord(legacy.copy(language="French")))
            assertNull(library.savedWord(legacy.copy(kind="rhymes",language=null)))
            assertNull(library.savedWord(legacy.copy(title="Animus")))
            install("legacy-English.wikblb.xz",compressed(bytes))
            assertNull(library.savedWord(legacy));assertNull(library.lastWord())
        } finally {
            prefs.edit().apply { oldPrefs.forEach { (key,value) -> putString(key,value) } }.commit()
            library.dictionaries.map { it.id }.filter { it !in before }.forEach { library.remove(it).join() }
        }
    }

    @Test fun compiledAliasesFollowOneEdgeWithinTheirEditionAndLanguage() = runBlocking {
        isolated()
        val library = LibraryStore.get(context)
        library.refreshCatalogs().join()
        val before = library.dictionaries.map { it.id }.toSet()
        val aliases = asset("compiled-aliases.wikblb")
        val targets = asset("compiled-alias-targets.wikblb")
        suspend fun install(name: String, bytes: ByteArray): DictionaryInfo {
            val old = library.dictionaries.map { it.id }.toSet()
            library.importFile(name={name}) { ByteArrayInputStream(bytes) }.join()
            assertNull(library.error)
            return library.dictionaries.single { it.id !in old }
        }
        suspend fun selected(id: String, title: String) = library.search(title).first { it.dictionary == id && it.title == title }
        try {
            val redirects = install("bgwiktionary-20261001-aliases.wikblb", aliases)
            assertEquals(6,redirects.count)
            assertEquals(listOf("Animus","ChainA","ChainB","Combustible","County seat","Gainst"),
                library.search("").filter { it.dictionary == redirects.id }.map { it.title })
            val missing = library.read(selected(redirects.id,"Animus"))
            assertEquals("Animus",missing.title);assertFalse(missing.redirect!!.followed)
            val foreign = install("arwiktionary-20261001-$englishName",targets)
            assertFalse(library.read(selected(redirects.id,"Animus")).redirect!!.followed)
            val correct = install("bgwiktionary-20261001-$englishName.xz",compressed(targets))
            assertNotEquals(foreign.id,correct.id)
            for ((from,to) in listOf("Animus" to "animus","Combustible" to "combustible","County seat" to "county seat","Gainst" to "gainst")) {
                val hit = selected(redirects.id,from)
                assertEquals("English",hit.language)
                val entry = library.read(hit)
                assertEquals(to,entry.title);assertTrue(entry.redirect!!.followed)
                assertEquals(from,entry.redirect.source)
                assertEquals("Target definition.",entry.clue())
                assertEquals("bgwiktionary-20261001",entry.edition)
            }
            val chain = library.read(selected(redirects.id,"ChainA"))
            assertEquals("ChainB",chain.title);assertTrue(chain.redirect!!.followed)
            assertEquals("Incoming",chain.redirect.fragment)
            assertEquals("gainst#Noun",chain.preamble.single().target)
            assertTrue(chain.sections.isEmpty())
            library.rememberWord(selected(redirects.id,"ChainA"))
            assertEquals(redirects.id,library.lastWord()!!.dictionary)
            val french = targets.copyOf().also { bytes ->
                "fr".toByteArray().copyInto(bytes,9)
                "French".toByteArray().copyInto(bytes,12)
                // French is one byte shorter than English; remove the old terminator below.
                bytes[18] = 0
            }
            val frenchBytes = french.copyOfRange(0,19) + french.copyOfRange(20,french.size)
            val frenchName = java.security.MessageDigest.getInstance("SHA-256").digest("French".toByteArray()).joinToString("") { "%02x".format(it) } + ".wikblb"
            val frenchInfo = install("bgwiktionary-20261001-$frenchName",frenchBytes)
            val sameAlias = library.search("Animus").filter { it.dictionary == redirects.id && it.title == "Animus" }
            assertEquals(setOf("English","French"),sameAlias.map { it.language }.toSet())
            assertEquals(2,sameAlias.map { it.key }.distinct().size)
            assertEquals(2,sameAlias.map { library.read(it).key }.distinct().size)
            val englishEntry = library.read(sameAlias.single { it.language == "English" })
            val learning = LearningStore.get(context)
            kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.Main) { learning.record(englishEntry);learning.toggleBookmark(englishEntry) }
            val bookmark = learning.data.bookmarks.single { it.key == englishEntry.key }
            assertEquals("Animus",bookmark.title)
            assertEquals(correct.id,library.savedWord(bookmark)!!.contextDictionary)
            library.remove(correct.id).join()
            assertNull(library.lastWord())
            assertNull(library.savedWord(bookmark))
            kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.Main) { learning.removeBookmark(bookmark.key);learning.removeHistory(bookmark.key) }
            library.remove(frenchInfo.id).join()
            assertFalse(library.read(selected(redirects.id,"Animus")).redirect!!.followed)
            val unscoped = install("aliases.wikblb",compressed(aliases))
            val unscopedTargets = install("English.wikblb",targets)
            assertFalse(library.read(selected(unscoped.id,"Animus")).redirect!!.followed)
            val localAlias = library.link("animus",library.read(selected(unscoped.id,"Animus")))!!
            assertEquals(unscoped.id,localAlias.dictionary)
            assertFalse(library.read(localAlias).redirect!!.followed)
            assertEquals(unscoped.id,library.link("ChainB",library.read(selected(unscoped.id,"ChainA")))!!.dictionary)
            assertEquals(unscopedTargets.id,library.link("gainst",library.read(selected(unscopedTargets.id,"animus")))!!.dictionary)
            assertEquals("ChainB",library.read(selected(unscoped.id,"ChainA")).title)
            val ids = library.dictionaries.map { it.id }
            for ((name,bytes) in listOf("testwiktionary-20261001-aliases.wikblb" to targets,
                "arwiktionary-20261001-aliases.wikblb" to targets,
                "testwiktionary-20261001-${"0".repeat(64)}.wikblb" to targets,
                "testwiktionary-20261001-supplemental.wikblb" to aliases)) {
                library.importFile(name={name}) { ByteArrayInputStream(bytes) }.join()
                assertNotNull(library.error);assertEquals(ids,library.dictionaries.map { it.id })
                assertEquals("animus",library.read(selected(foreign.id,"animus")).title)
            }
            for (bad in listOf(aliases.copyOf(aliases.size-1),aliases+byteArrayOf(0),
                aliases.copyOf().also { it[10]='2'.code.toByte() })) {
                library.importFile(name={"testwiktionary-20261001-aliases.wikblb"}) { ByteArrayInputStream(bad) }.join()
                assertNotNull(library.error);assertEquals(ids,library.dictionaries.map { it.id })
            }
            val empty = "WIKBLB08".toByteArray()+byteArrayOf(7)
            val feature = install("testwiktionary-20261001-supplemental.wikblb",empty)
            assertEquals(0,feature.count)
            assertEquals("supplemental",feature.kind)
        } finally {
            library.dictionaries.map { it.id }.filter { it !in before }.forEach { library.remove(it).join() }
        }
    }

    @Test fun versionOneDatabaseUpgradePreservesExistingRowsWithoutGuessingEdition() {
        isolated()
        val name = "alias-upgrade-test.db"
        context.deleteDatabase(name)
        try {
            val old = object: SQLiteOpenHelper(context,name,null,1) {
                override fun onCreate(db: SQLiteDatabase) {
                    db.execSQL("CREATE TABLE dictionaries(id TEXT PRIMARY KEY,language TEXT,code TEXT,kind TEXT,count INTEGER,bytes INTEGER)")
                    db.execSQL("CREATE TABLE words(dictionary TEXT,title TEXT,normalized TEXT,payload INTEGER,length INTEGER)")
                    db.execSQL("INSERT INTO dictionaries VALUES('existing','English','en','language',1,40)")
                    db.execSQL("INSERT INTO words VALUES('existing','Word','word',20,20)")
                }
                override fun onUpgrade(db: SQLiteDatabase,oldVersion: Int,newVersion: Int) = Unit
            }
            old.writableDatabase;old.close()
            val next = LibraryDatabase(context,name)
            try {
                next.readableDatabase.rawQuery("SELECT dictionary,title,edition,record_key,kind FROM word_choices",null).use { c ->
                    assertTrue(c.moveToFirst());assertEquals("existing",c.getString(0));assertEquals("Word",c.getString(1))
                    assertEquals("",c.getString(2));assertEquals("Word",c.getString(3));assertEquals("language",c.getString(4))
                    assertFalse(c.moveToNext())
                }
                assertEquals(2,next.readableDatabase.version)
            } finally {
                next.close()
            }
        } finally { context.deleteDatabase(name) }
    }
}
