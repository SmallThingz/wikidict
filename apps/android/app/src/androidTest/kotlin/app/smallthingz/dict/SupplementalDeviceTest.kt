package app.smallthingz.dict

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.File
import org.tukaani.xz.LZMA2Options
import org.tukaani.xz.XZOutputStream

@RunWith(AndroidJUnit4::class)
class SupplementalDeviceTest {
    @Test fun rawAndCompressedInstallPreserveUnicodeNamespaces() = runBlocking {
        val instrumentation=InstrumentationRegistry.getInstrumentation()
        val context=instrumentation.targetContext
        assumeTrue("Use -PisolatedValidation=true to avoid personal dictionaries", context.packageName.endsWith(".validation"))
        val library=LibraryStore.get(context)
        library.refreshCatalogs().join()
        val before=library.dictionaries.map { it.id }.toSet()
        val raw=instrumentation.context.assets.open("supplemental.wikblb").use { it.readBytes() }
        val packed=ByteArrayOutputStream().also { output -> XZOutputStream(output,LZMA2Options(1)).use { it.write(raw) } }.toByteArray()
        try {
            for (bytes in listOf(raw,packed)) {
                val installedBefore=library.dictionaries.map { it.id }.toSet()
                library.importFile { ByteArrayInputStream(bytes) }.join()
                assertNull(library.error)
                val extra=library.dictionaries.single { it.id !in installedBefore }
                assertEquals("supplemental",extra.kind);assertEquals(2,extra.count)
                val hits=library.search("ANNEXE:É").filter { it.dictionary==extra.id }
                assertEquals(listOf("Annexe:école"),hits.map { it.title })
                assertNull(library.exact("école"))
                for (title in listOf("Annexe:école","Appendix:école")) {
                    val hit=library.search(title).first { it.dictionary==extra.id && it.title==title }
                    val entry=library.read(hit)
                    assertEquals(title,entry.title)
                    assertEquals(title,entry.sections.single().blocks.single().spans.single().text)
                }
                val installed=File(context.filesDir,"dictionaries/${extra.id}.wikblb")
                assertArrayEquals(bytes,installed.readBytes())
                val validIds=library.dictionaries.map { it.id }
                for (tag in listOf(0,8,255)) {
                    val bad=raw.copyOf().also { it[8]=tag.toByte() }
                    library.importFile { ByteArrayInputStream(bad) }.join()
                    assertNotNull(library.error)
                    assertEquals(validIds,library.dictionaries.map { it.id })
                    assertEquals("Annexe:école",library.read(hits.single()).title)
                }
            }
        } finally {
            for (id in library.dictionaries.map { it.id }.filter { it !in before }) library.remove(id).join()
        }
    }
}
