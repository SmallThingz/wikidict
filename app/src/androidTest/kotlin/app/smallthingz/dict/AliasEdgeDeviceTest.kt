package app.smallthingz.dict

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.io.ByteArrayInputStream
import java.io.File
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference

/** These synthetic files were independently replayed through the current core C ABI. */
@RunWith(AndroidJUnit4::class)
class AliasEdgeDeviceTest {
    @Test fun realAfrikaansBomAndUnclassifiedRecordsRemainReadableWithoutGuessedLanguage() = runBlocking {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        assumeTrue(context.packageName.endsWith(".validation"))
        val library = LibraryStore.get(context)
        library.refreshCatalogs().join()
        val before = library.dictionaries.map { it.id }.toSet()
        try {
            library.importFile(name={"afwiktionary-20261001-aliases.wikblb.xz"}) { instrumentation.context.assets.open("af-aliases.wikblb.xz") }.join()
            assertNull(library.error)
            val af = library.dictionaries.singleOrNull { it.id !in before }
                ?: error("AF import did not add exactly one dictionary: before=$before after=${library.dictionaries.map { it.id }}")
            assertEquals(88,af.count)
            val hits = library.search("",500).filter { it.dictionary == af.id }
            assertEquals(88,hits.size)
            hits.forEach { assertNotNull(library.read(it).redirect) }
            val bom = hits.singleOrNull { it.title == "\uFEFF's-Gravenhage" }
                ?: error("AF BOM title absent: ${hits.filter { "Gravenhage" in it.title }.map { it.title.toCharArray().map { c -> c.code.toString(16) } }}; SQL=" +
                    context.openOrCreateDatabase("library.db",0,null).use { db -> db.rawQuery("SELECT hex(title),hex(record_key) FROM words WHERE dictionary=? AND title LIKE '%Gravenhage%'",arrayOf(af.id)).use { c -> buildList { while(c.moveToNext()) add(c.getString(0)+":"+c.getString(1)) } } })
            assertEquals(bom.title,library.read(bom).redirect!!.source)
            val original = instrumentation.context.assets.open("compiled-alias-targets.wikblb").use { it.readBytes() }
            val unclassified = "WIKBLB08".toByteArray()+byteArrayOf(1,0)+"Unclassified\u0000".toByteArray()+original.copyOfRange(20,original.size)
            val hash = java.security.MessageDigest.getInstance("SHA-256").digest("Unclassified".toByteArray()).joinToString("") { "%02x".format(it) }
            library.importFile(name={"unknownwiktionary-20261001-$hash.wikblb"}) { ByteArrayInputStream(unclassified) }.join()
            assertNull(library.error)
            val result = library.read(library.exact("animus","Unclassified","unknownwiktionary-20261001")!!)
            assertEquals("Unclassified",result.language);assertEquals("",result.languageCode)
            kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.Main) {
                SpeechPlayback.close()
                SpeechPlayback.play(context,result.title,result.languageCode)
                assertNull(SpeechPlayback.active)
                assertEquals("This entry has no identified language for speech.",SpeechPlayback.error)
                SpeechPlayback.stop()
                assertNull(SpeechPlayback.error)
            }
        } finally {
            library.dictionaries.map { it.id }.filter { it !in before }.forEach { library.remove(it).join() }
        }
    }

    @Test fun cyclesMissingTargetsCrossKindsAndDisplayedTargetLinksMatchCore() = runBlocking {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        assumeTrue(context.packageName.endsWith(".validation"))
        val library = LibraryStore.get(context)
        library.refreshCatalogs().join()
        val before = library.dictionaries.map { it.id }.toSet()
        suspend fun install(name: String, bytes: ByteArray): DictionaryInfo {
            val ids = library.dictionaries.map { it.id }.toSet()
            library.importFile(name={name}) { ByteArrayInputStream(bytes) }.join()
            assertNull(library.error)
            return library.dictionaries.single { it.id !in ids }
        }
        fun asset(name: String) = instrumentation.context.assets.open(name).use { it.readBytes() }
        try {
            val aliases = install("edgewiktionary-20261001-aliases.wikblb",asset("alias-edges.wikblb"))
            install("edgewiktionary-20261001-ba118bf7fc9c1aedc1edb28a0aa86e0b43b681f222af6616e13c43be87815b06.wikblb",asset("compiled-alias-targets.wikblb"))
            val rhymes = install("edgewiktionary-20261001-rhymes.wikblb",asset("alias-rhymes.wikblb"))
            val emptyFeature = install("edgewiktionary-20261001-supplemental.wikblb","WIKBLB08".toByteArray()+byteArrayOf(7))
            assertEquals(0,emptyFeature.count)
            suspend fun entry(title: String) = library.read(library.search(title).single { it.dictionary == aliases.id && it.title == title })
            for ((source,target,followed) in listOf(
                Triple("CycleA","CycleB",true),Triple("Self","Self",true),Triple("Missing","Missing",false),
                Triple("Feature","target",true),Triple("Appendix:bridge","target",true),
                Triple("Appendix:unknown","Appendix:unknown",false),Triple("main","Rhymes:main",false))) {
                val result = entry(source)
                assertEquals(source,target,result.title)
                assertEquals(source,followed,result.redirect!!.followed)
            }
            assertEquals("CycleA",entry("CycleA").preamble.single().target)
            val noLanguage = entry("chain")
            assertEquals("Missing",noLanguage.title)
            assertTrue(noLanguage.redirect!!.followed)
            assertEquals("language",noLanguage.navigationKind)
            assertNull(noLanguage.navigationLanguage)
            assertNull(library.link("animus",noLanguage))
            val feature = entry("Feature")
            assertEquals("rhymes",feature.kind)
            assertEquals("Rhymes",feature.redirect!!.fragment)
            val link = library.link("next",feature)!!
            assertEquals(rhymes.id,link.dictionary)
            assertEquals("rhymes",library.read(link).kind)
            assertEquals("edgewiktionary-20261001",library.read(link).edition)
            for ((tag,name) in listOf(2 to "thesaurus",3 to "citations",4 to "reconstruction",5 to "rhymes",6 to "sign-gloss",7 to "supplemental")) {
                assertEquals(0,install("emptywiktionary-20261001-$name.wikblb","WIKBLB08".toByteArray()+byteArrayOf(tag.toByte())).count)
            }
            val valid = library.dictionaries.map { it.id }
            val emptyLanguage = "WIKBLB08".toByteArray()+byteArrayOf(1)+"en\u0000English\u0000".toByteArray()
            library.importFile { ByteArrayInputStream(emptyLanguage) }.join()
            assertNotNull(library.error);assertEquals(valid,library.dictionaries.map { it.id })
        } finally {
            library.dictionaries.map { it.id }.filter { it !in before }.forEach { library.remove(it).join() }
        }
    }

    @Test fun cancelledEmptyAuxiliaryImportPreservesInstalledDictionary() = runBlocking {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        assumeTrue(context.packageName.endsWith(".validation"))
        val library = LibraryStore.get(context)
        library.refreshCatalogs().join()
        val before = library.dictionaries.map { it.id }.toSet()
        val edition = "cancel${UUID.randomUUID().toString().replace("-", "")}wiktionary-20261001"
        val directory = File(context.filesDir, "dictionaries")
        val owner = AtomicReference<Job>()
        val ownerReady = CountDownLatch(1)
        val cancelledAtName = AtomicBoolean(false)
        var importing: Job? = null
        try {
            library.importFile(name = {
                "$edition-ba118bf7fc9c1aedc1edb28a0aa86e0b43b681f222af6616e13c43be87815b06.wikblb"
            }) { instrumentation.context.assets.open("compiled-alias-targets.wikblb") }.join()
            assertNull(library.error)
            val installed = library.dictionaries.single { it.id !in before }
            assertEquals(edition, installed.edition)
            val hit = library.search("animus", 500).single { it.dictionary == installed.id && it.title == "animus" }
            assertEquals("animus", library.read(hit).title)
            val installedFile = File(directory, "${installed.id}.wikblb")
            val installedBytes = installedFile.readBytes()
            val expectedIds = library.dictionaries.map { it.id }.toSet()
            val partialsBefore = directory.listFiles().orEmpty().filter { it.extension == "part" }.map { it.name }.toSet()

            val pending = library.importFile(name = {
                check(ownerReady.await(5, TimeUnit.SECONDS)) { "Import owner was not published" }
                // The checksum has returned. Cancel this exact owner before install starts.
                checkNotNull(owner.get()).cancel(CancellationException("cancel before auxiliary publication"))
                cancelledAtName.set(true)
                "$edition-supplemental.wikblb"
            }) { ByteArrayInputStream("WIKBLB08".toByteArray() + byteArrayOf(7)) }
            importing = pending
            owner.set(pending)
            ownerReady.countDown()
            withTimeout(10_000) { pending.join() }

            assertTrue(cancelledAtName.get())
            assertTrue(pending.isCancelled)
            assertNull(library.error)
            assertNull(library.busy)
            assertNull(library.transferDetail)
            assertEquals(expectedIds, library.dictionaries.map { it.id }.toSet())
            assertArrayEquals(installedBytes, installedFile.readBytes())
            assertEquals("animus", library.read(hit).title)
            assertEquals(partialsBefore, directory.listFiles().orEmpty().filter { it.extension == "part" }.map { it.name }.toSet())
        } finally {
            ownerReady.countDown()
            importing?.cancel()
            importing?.join()
            library.dictionaries.filter { it.edition == edition && it.id !in before }.forEach { library.remove(it.id).join() }
        }
    }
}
