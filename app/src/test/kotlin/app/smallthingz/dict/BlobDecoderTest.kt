package app.smallthingz.dict

import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.io.RandomAccessFile

class BlobDecoderTest {
    private fun records(): List<Pair<String, ByteArray>> = RandomAccessFile(File("src/debug/assets/English.wikblb"), "r").use { f ->
        fun nul(): String { val b = java.io.ByteArrayOutputStream(); while(true) { val v=f.read(); require(v>=0); if(v==0)break; b.write(v) }; return b.toByteArray().decodeToString() }
        val magic=ByteArray(8);f.readFully(magic);assertEquals("WIKBLB08",magic.decodeToString());assertEquals(1,f.read());assertEquals("en",nul());assertEquals("English",nul())
        buildList { while(f.filePointer<f.length()) { val title=nul();var size=0;var shift=0;while(true){val v=f.read();size=size or ((v and 127) shl shift);if(v and 128==0)break;shift+=7};val b=ByteArray(size);f.readFully(b);add(title to b) } }
    }
    @Test fun supplementalKindIsValidatedAndFullTitlesStayDistinct() {
        assertEquals(listOf("language", "thesaurus", "citations", "reconstruction", "rhymes", "sign_gloss", "supplemental", "alias"), (1..8).map(::blobKind))
        for (tag in listOf(-1, 0, 9, 255)) assertThrows(Exception::class.java) { blobKind(tag) }
        RandomAccessFile(File("src/androidTest/assets/supplemental.wikblb"), "r").use { f ->
            val magic = ByteArray(8); f.readFully(magic); assertEquals("WIKBLB08", magic.decodeToString())
            assertEquals("supplemental", blobKind(f.read()))
            val titles = mutableListOf<String>()
            while (f.filePointer < f.length()) {
                val text = java.io.ByteArrayOutputStream()
                while (true) { val v=f.read(); require(v>=0); if(v==0)break; text.write(v) }
                val title=text.toByteArray().decodeToString(); titles.add(title)
                var size=0; var shift=0
                while(true) { val v=f.read(); require(v>=0 && shift<28); size=size or ((v and 127) shl shift); if(v and 128==0)break; shift+=7 }
                val payload=ByteArray(size); f.readFully(payload)
                val entry=BlobDecoder.decode(payload,title,"supplemental",null,"")
                assertEquals(title,entry.title)
                assertEquals(title,entry.sections.single().blocks.single().spans.single().text)
            }
            assertEquals(listOf("Annexe:école", "Appendix:école"),titles)
        }
    }

    @Test fun everyRealCorpusRecordDecodesDirectly() {
        val records=records();assertTrue(records.size>20)
        records.forEach { (title,payload)-> val e=BlobDecoder.decode(payload,title,"language","English","en");assertEquals(title,e.title);assertTrue(e.sections.isNotEmpty()) }
        val cat=records.first{it.first=="cat"}.let{BlobDecoder.decode(it.second,it.first,"language","English","en")}
        assertTrue(cat.sections.any{it.title.startsWith("Etymology")});assertTrue(cat.media.any{it.kind=="audio"});assertTrue(cat.media.any{it.kind=="image"})
        // This historical fixture has a real parent definition, not a media fallback.
        assertEquals("Terms relating to animals.", cat.clue())
    }
    @Test fun truncatedUnknownAndTrailingPayloadsAreRejected() {
        val bytes=records().first().second
        for(n in listOf(0,3,10,bytes.size-1)) assertThrows(Exception::class.java){BlobDecoder.decode(bytes.copyOf(n),"bad","language","English","en")}
        assertThrows(Exception::class.java){BlobDecoder.decode(bytes+byteArrayOf(0),"bad","language","English","en")}
        assertThrows(Exception::class.java){BlobDecoder.decode("{\"entries\":[]}".toByteArray(),"bad","language","English","en")}
        val huge=bytes.copyOf();for(i in 4..7)huge[i]=(-1).toByte()
        assertThrows(Exception::class.java){BlobDecoder.decode(huge,"bad","language","English","en")}
    }
    @Test fun catalogueAcceptsBareAndVerifiedLinksAndRejectsUnsafeRows() {
        assertEquals("English", Catalog.parse("# catalogue\nhttps://example.org/English.wikblb\n").single().label)
        assertEquals(123L,Catalog.parse("https://example.org/en.wikblb\tEnglish\t123\t"+"a".repeat(64)).single().bytes)
        for(row in listOf("http://example.org/a.wikblb","file:///a.wikblb","https://user:secret@example.org/a","https:///a","https://example.org/a\tA\t-1","https://example.org/a\tA\t1\tbad")) assertThrows(Exception::class.java){Catalog.parse(row)}
        assertThrows(Exception::class.java){Catalog.parse("asset://English.wikblb")}
        assertEquals(1,Catalog.parse("asset://English.wikblb",true).size)
    }
    private fun explanationFixture(version: Int, background: String? = null, backgroundPresence: Int? = null, foreground: String? = null, foregroundPresence: Int? = null): ByteArray {
        val out = java.io.ByteArrayOutputStream()
        fun byte(v: Int) { out.write(v) }
        fun u32(v: Int) { repeat(4) { byte(v ushr (it * 8) and 255) } }
        fun string(v: String) { val b = v.toByteArray(Charsets.UTF_8); u32(b.size); out.write(b) }
        fun spans(label: String) {
            u32(1); byte(1); byte(1); byte(10)
            listOf(label, "glossary", "!", "en", "abbr", "ltr").forEach(::string)
            if (version >= 3) string("Meaning & <plain> \u2067معنى\u2069: $label")
            if (version == 4) {
                byte(foregroundPresence ?: if (foreground == null) 0 else 1)
                if (foreground != null) string(foreground)
            }
        }
        fun block(table: Boolean) {
            byte(if (table) 12 else 0); byte(0); byte(0)
            spans(if (table) "table-body" else "body")
            byte(0); string(""); string(""); byte(if (table) 1 else 0)
            if (table) {
                spans("caption"); u32(1); u32(1); byte(0); byte(1); byte(0); byte(1); byte(0)
                if (version == 4) {
                    byte(backgroundPresence ?: if (background == null) 0 else 1)
                    if (background != null) string(background)
                }
                spans("cell")
            }
        }
        out.write("DPR$version".toByteArray()); spans("display")
        u32(1); byte(3); string("Noun"); u32(2); block(false); block(true)
        spans("preamble"); u32(0); u32(0)
        u32(1); u32(1); u32(1); string(""); string(""); spans("reference"); u32(0)
        return out.toByteArray()
    }
    @Test fun legacyAndExplainedWirePreserveAllSpanContainersAndCompactText() {
        val explained = BlobDecoder.decode(explanationFixture(3), "Word", "language", "English", "en")
        val lists = listOf(explained.displayTitle, explained.preamble,
            explained.sections.single().blocks[0].spans, explained.sections.single().blocks[1].spans,
            explained.sections.single().blocks[1].table!!.caption,
            explained.sections.single().blocks[1].table!!.rows.single().single().spans,
            explained.references.single().spans)
        assertEquals(7, lists.size)
        lists.forEach { spans ->
            val span = spans.single()
            assertEquals("Meaning & <plain> \u2067معنى\u2069: " + span.text, span.explanation)
            assertEquals(span.text + "!", textOf(spans))
            assertEquals("glossary", span.target); assertEquals("ltr", span.direction)
            assertTrue(span.italic && span.small); assertEquals("label", span.role)
        }
        val legacy = BlobDecoder.decode(explanationFixture(2), "Word", "language", "English", "en")
        assertTrue(legacy.abbreviations.isEmpty())
        assertEquals(textOf(explained.displayTitle), textOf(legacy.displayTitle))
        records().forEach { (title, payload) ->
            assertEquals("DPR2", payload.copyOfRange(0, 4).decodeToString())
            assertTrue(BlobDecoder.decode(payload, title, "language", "English", "en").abbreviations.isEmpty())
        }
    }
    @Test fun explainedWireRejectsTruncatedMalformedUtf8AndUnsupportedVersions() {
        val bytes = explanationFixture(3)
        for (length in listOf(0, 3, 8, bytes.size - 1)) assertThrows(Exception::class.java) {
            BlobDecoder.decode(bytes.copyOf(length), "Word", "language", "English", "en")
        }
        val unknown = bytes.copyOf().also { it[3] = '6'.code.toByte() }
        assertThrows(Exception::class.java) { BlobDecoder.decode(unknown, "Word", "language", "English", "en") }
        val marker = "Meaning &".toByteArray()
        val start = bytes.asList().windowed(marker.size).indexOfFirst { it == marker.asList() }
        assertTrue(start >= 0)
        val invalid = bytes.copyOf().also { it[start] = 0xff.toByte() }
        assertThrows(Exception::class.java) { BlobDecoder.decode(invalid, "Word", "language", "English", "en") }
        assertThrows(Exception::class.java) { BlobDecoder.decode(bytes + byteArrayOf(0), "Word", "language", "English", "en") }
    }

    @Test fun cellBackgroundWirePreservesEveryOtherEntryFieldAndLegacyRecords() {
        val legacy = BlobDecoder.decode(explanationFixture(3), "Word", "language", "English", "en")
        val absent = BlobDecoder.decode(explanationFixture(4), "Word", "language", "English", "en")
        assertEquals(legacy, absent)
        val colored = BlobDecoder.decode(explanationFixture(4, "#12ab34"), "Word", "language", "English", "en")
        val cell = colored.sections.single().blocks[1].table!!.rows.single().single()
        assertEquals("#12ab34", cell.background)
        val cleared = colored.copy(sections = colored.sections.map { section -> section.copy(blocks = section.blocks.map { block ->
            block.copy(table = block.table?.let { table -> table.copy(rows = table.rows.map { row -> row.map { it.copy(background = null) } }) })
        }) })
        assertEquals(legacy, cleared)
        assertNull(BlobDecoder.decode(explanationFixture(2), "Word", "language", "English", "en")
            .sections.single().blocks[1].table!!.rows.single().single().background)
    }
    @Test fun cellBackgroundWireRejectsMalformedPresenceColorAndIncompleteRecords() {
        for (color in listOf("", "red", "#FFF000", "#ff0", "#ff000000", "#gggggg", " #ffff00", "#ffff00 ", "background:#ffff00"))
            assertThrows(Exception::class.java) { BlobDecoder.decode(explanationFixture(4, color), "Word", "language", "English", "en") }
        assertThrows(Exception::class.java) { BlobDecoder.decode(explanationFixture(4, backgroundPresence = 2), "Word", "language", "English", "en") }
        val bytes = explanationFixture(4, "#12ab34")
        for (length in bytes.indices) assertThrows(Exception::class.java) {
            BlobDecoder.decode(bytes.copyOf(length), "Word", "language", "English", "en")
        }
        assertThrows(Exception::class.java) { BlobDecoder.decode(bytes + byteArrayOf(0), "Word", "language", "English", "en") }
    }

    @Test fun spanForegroundWirePreservesAllContainersExplanationsAndActions() {
        val legacy = BlobDecoder.decode(explanationFixture(3), "Word", "language", "English", "en")
        val colored = BlobDecoder.decode(explanationFixture(4, foreground = "#008000"), "Word", "language", "English", "en")
        fun containers(entry: Entry) = listOf(entry.displayTitle, entry.preamble,
            entry.sections.single().blocks[0].spans, entry.sections.single().blocks[1].spans,
            entry.sections.single().blocks[1].table!!.caption,
            entry.sections.single().blocks[1].table!!.rows.single().single().spans,
            entry.references.single().spans)
        val before = containers(legacy)
        val after = containers(colored)
        assertEquals(7, after.size)
        after.zip(before).forEach { (spans, original) ->
            assertEquals("#008000", spans.single().foreground)
            assertEquals(original, spans.map { it.copy(foreground = null) })
            assertEquals(textOf(original), textOf(spans))
        }
        assertEquals(legacy, BlobDecoder.decode(explanationFixture(4), "Word", "language", "English", "en"))
        for (color in listOf("", "green", "#00800A", "#080", "#ff008000", " #008000"))
            assertThrows(Exception::class.java) { BlobDecoder.decode(explanationFixture(4, foreground = color), "Word", "language", "English", "en") }
        assertThrows(Exception::class.java) { BlobDecoder.decode(explanationFixture(4, foregroundPresence = 2), "Word", "language", "English", "en") }
        val bytes = explanationFixture(4, "#eeeeee", foreground = "#008000")
        for (length in bytes.indices) assertThrows(Exception::class.java) {
            BlobDecoder.decode(bytes.copyOf(length), "Word", "language", "English", "en")
        }
    }

}
