package app.smallthingz.dict

import java.io.File
import java.io.ByteArrayInputStream
import org.junit.Assert.*
import org.junit.Test

class AliasDecoderTest {
    private fun records(name: String = "compiled-aliases.wikblb"): List<Pair<String, ByteArray>> {
        val input = ByteArrayInputStream(BlobSource(File("src/androidTest/assets/$name")).use { it.stream().readBytes() })
        require(input.readNBytes(8).decodeToString() == "WIKBLB08" && input.read() == 8)
        return buildList {
            while (input.available() > 0) {
                val title = java.io.ByteArrayOutputStream()
                while (true) { val b = input.read(); require(b >= 0); if (b == 0) break; title.write(b) }
                var size = 0; var shift = 0
                while (true) { val b = input.read(); require(b >= 0 && shift < 28); size = size or ((b and 127) shl shift); if (b and 128 == 0) break; shift += 7 }
                add(title.toByteArray().decodeToString() to input.readNBytes(size).also { require(it.size == size) })
            }
        }
    }
    @Test fun coreProducedAliasesPreserveCaseKeysFragmentsAndCompiledPresentation() {
        val decoded = records().map { (key, bytes) -> AliasDecoder.decode(bytes, key) }
        assertEquals(listOf("Animus", "ChainA", "ChainB", "Combustible", "County seat", "Gainst"), decoded.map { it.sourceTitle })
        assertEquals(listOf("animus", "ChainB", "gainst", "combustible", "county seat", "gainst"), decoded.map { it.targetTitle })
        assertEquals("Incoming", decoded[1].fragment)
        assertEquals("Noun", decoded[2].fragment)
        assertEquals("gainst#Noun", decoded[2].entry().preamble.single().target)
        decoded.forEach { assertEquals("language", it.sourceKind); assertEquals(0L, it.sourceNamespace); assertEquals(it.sourceTitle, it.entry().title) }
    }
    @Test fun everyTruncationTrailingBytesAndIdentityMismatchAreRejected() {
        for ((key, bytes) in records()) {
            for (end in bytes.indices) assertThrows(Exception::class.java) { AliasDecoder.decode(bytes.copyOf(end), key) }
            assertThrows(Exception::class.java) { AliasDecoder.decode(bytes + byteArrayOf(0), key) }
            assertThrows(Exception::class.java) { AliasDecoder.decode(bytes, "2" + key.drop(1)) }
            assertThrows(Exception::class.java) { AliasDecoder.decode(bytes, key + "x") }
            for ((position, value) in listOf(0 to 0, 4 to 1, 8 to 8, 9 to 2, 14 to 8)) {
                assertThrows(Exception::class.java) { AliasDecoder.decode(bytes.copyOf().also { it[position] = value.toByte() }, key) }
            }
            val presentation = bytes.copyOf()
            val at = presentation.indices.first { index -> index + 4 <= presentation.size && presentation.copyOfRange(index,index+4).contentEquals("DPR2".toByteArray()) }
            presentation[at] = 0
            assertThrows(Exception::class.java) { AliasDecoder.decode(presentation,key) }
        }
    }
    @Test fun acquisitionScopeRequiresTheExactPublishedFilename() {
        assertEquals("arwiktionary-20261001", dictionaryEdition("arwiktionary-20261001-aliases.wikblb.xz"))
        assertEquals("zh-min-nanwiktionary-20260901", dictionaryEdition("zh-min-nanwiktionary-20260901-" + "a".repeat(64) + ".wikblb"))
        for (name in listOf("aliases.wikblb", "arwiktionary-20261001-unknown.wikblb", "arwiktionary-20261301-aliases.wikblb",
            "../arwiktionary-20261001-aliases.wikblb", "arwiktionary-20261001-aliases.wikblb.xz.bad", "English.wikblb")) {
            assertEquals(name, "", dictionaryEdition(name))
        }
    }
    @Test fun realAfrikaansAliasesPreserveLeadingBomAsTitleData() {
        val entries = records("af-aliases.wikblb.xz").map { (key,bytes) -> AliasDecoder.decode(bytes,key) }
        assertEquals(88,entries.size)
        val title = "\uFEFF's-Gravenhage"
        val bom = entries.single { it.sourceTitle == title }
        assertEquals(title,bom.sourceKey)
        assertEquals(title,bom.entry().title)
    }
    @Test fun canonicalAcquisitionNameMustMatchKindAndExactHeadingBytes() {
        val english = "ba118bf7fc9c1aedc1edb28a0aa86e0b43b681f222af6616e13c43be87815b06"
        validateDictionaryFilename("enwiktionary-20261001-$english.wikblb.xz","language","English")
        validateDictionaryFilename("aawiktionary-20261001-ea554ca0ecd0803ff93048c2ddf4cc5274283af2024217f18e058c715367e7d8.wikblb","language","Qaf\u00e1r af")
        for (heading in listOf("english","English ","\uFEFFEnglish","Unclassified"))
            assertThrows(Exception::class.java) { validateDictionaryFilename("enwiktionary-20261001-$english.wikblb","language",heading) }
        assertThrows(Exception::class.java) { validateDictionaryFilename("enwiktionary-20261001-aliases.wikblb","language","English") }
        assertThrows(Exception::class.java) { validateDictionaryFilename("enwiktionary-20261001-$english.wikblb","alias","") }
        validateDictionaryFilename("enwiktionary-20261001-sign-gloss.wikblb","sign_gloss","")
    }
}
