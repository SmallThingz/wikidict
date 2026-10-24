package app.smallthingz.dict

import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.io.RandomAccessFile

class BlobDecoderTest {
    private fun producerEnvironment(name: String): String = System.getenv(name)?.takeIf { it.isNotEmpty() }
        ?: error("Required producer conformance input is absent: $name")
    private fun producerDigest(bytes: ByteArray): String = java.security.MessageDigest.getInstance("SHA-256")
        .digest(bytes).joinToString("") { "%02x".format(it.toInt() and 255) }
    private fun producerInput(name: String): File {
        val file = File(producerEnvironment(name)).canonicalFile
        require(file.isFile) { "Missing producer conformance file: $name" }
        val digest = java.security.MessageDigest.getInstance("SHA-256")
        file.inputStream().use { input ->
            val buffer = ByteArray(65536)
            while (true) { val n = input.read(buffer); if (n < 0) break; digest.update(buffer, 0, n) }
        }
        val actual = digest.digest().joinToString("") { "%02x".format(it.toInt() and 255) }
        require(actual == producerEnvironment(name + "_SHA256")) { "Producer input identity differs: $name" }
        return file
    }
    private fun producerJson(value: Any?): String = when (value) {
        null -> "null"
        is String -> buildString {
            append('"')
            for (character in value) when (character) {
                '"' -> append("\\\""); '\\' -> append("\\\\")
                '\n' -> append("\\n"); '\r' -> append("\\r"); '\t' -> append("\\t")
                else -> if (character.code < 32) append("\\u%04x".format(character.code)) else append(character)
            }
            append('"')
        }
        is Boolean, is Int, is Long -> value.toString()
        is Map<*, *> -> value.entries.joinToString(",", "{", "}") { (key, item) ->
            require(key is String); producerJson(key) + ":" + producerJson(item)
        }
        is Iterable<*> -> value.joinToString(",", "[", "]") { producerJson(it) }
        else -> error("Unsupported conformance projection value")
    }
    private fun producerSpan(span: Span): Map<String, Any?> = linkedMapOf(
        "kind" to span.kind, "text" to span.text, "target" to span.target, "trail" to span.trail,
        "language" to span.language, "classes" to span.classes, "direction" to span.direction,
        "explanation" to span.explanation, "foreground" to span.foreground, "background" to span.background,
        "bold" to span.bold, "italic" to span.italic, "code" to span.code, "small" to span.small,
        "superscript" to span.superscript, "subscript" to span.subscript, "strike" to span.strike,
        "underline" to span.underline, "role" to span.role)
    private fun producerTable(table: Table): Map<String, Any?> = linkedMapOf(
        "caption" to table.caption.map(::producerSpan),
        "geometry" to table.geometry?.let { geometry -> linkedMapOf(
            "border" to geometry.border, "cell_spacing" to geometry.cellSpacing, "cell_padding" to geometry.cellPadding,
            "width" to geometry.width?.let { linkedMapOf("unit" to if (it.unit == TableWidthUnit.Px) "px" else "percent", "value" to it.value) }) },
        "rows" to table.rows.map { row -> linkedMapOf("cells" to row.map { cell -> linkedMapOf<String, Any?>(
            "spans" to cell.spans.map(::producerSpan), "header" to cell.header, "colspan" to cell.colspan,
            "rowspan" to cell.rowspan, "background" to cell.background, "nested_table" to cell.nestedTable?.let(::producerTable))
                .also { fields -> cell.blocks?.let { blocks -> fields["blocks"] = blocks.map(::producerBlock) } } }) })
    private fun producerBlock(block: Block): Map<String, Any?> = linkedMapOf(
        "kind" to block.kind, "depth" to block.depth, "spans" to block.spans.map(::producerSpan),
        "feature" to block.feature?.let { linkedMapOf("kind" to it.kind, "language" to it.language,
            "data" to it.data, "tail_kind" to it.tailKind, "tail" to it.tail) },
        "list_path" to block.listPath, "number" to block.number, "level" to block.level,
        "anchor" to block.anchor, "anchor_fallback" to block.anchorFallback, "table" to block.table?.let(::producerTable))
    private fun producerEntry(entry: Entry): Map<String, Any?> = linkedMapOf(
        "title" to entry.title, "kind" to entry.kind, "language" to entry.language, "language_code" to entry.languageCode,
        "display_title" to entry.displayTitle.map(::producerSpan), "preamble_spans" to entry.preamble.map(::producerSpan),
        "sections" to entry.sections.map { linkedMapOf("level" to it.level, "title" to it.title,
            "anchor" to it.anchor, "anchor_fallback" to it.anchorFallback, "blocks" to it.blocks.map(::producerBlock)) },
        "references" to entry.references.map { linkedMapOf("number" to it.number, "group_number" to it.groupNumber,
            "group" to it.group, "spans" to it.spans.map(::producerSpan)) },
        "media" to entry.media.map { linkedMapOf("file" to it.file, "kind" to it.kind, "caption" to it.caption) })

    /** Configured producer case is a separate required run of the existing conformance target. */
    private fun requiredProducerConformance(version: Int) {
        require(version in 7..8)
        val prefix = "WIKBLB_DPR$version"
        fun name(suffix: String) = "${prefix}_$suffix"
        val fixtureTitle = if (version == 7) "geacen" else "cell-heading-regression"
        require(producerEnvironment(name("REQUIRED")) == "1")
        val blob = producerInput(name("BLOB"))
        val headerFile = producerInput(name("HEADER"))
        val payloadFile = producerInput(name("PAYLOAD"))
        val titleFile = producerInput(name("TITLE"))
        producerInput(name("CORE"))
        producerInput(name("SOURCE_FACTS"))
        producerInput(name("CASE"))
        val wantedTitle = titleFile.readBytes().decodeToString(throwOnInvalidSequence = true)
        require(wantedTitle == fixtureTitle)
        var selected: Entry? = null
        var selectedOffset = -1L
        var selectedLength = -1
        var actualHeader: Map<String, Any?>? = null
        RandomAccessFile(blob, "r").use { input ->
            fun nul(): String {
                val bytes = java.io.ByteArrayOutputStream()
                while (true) { val b = input.read(); require(b >= 0 && bytes.size() < 65536); if (b == 0) break; bytes.write(b) }
                return bytes.toByteArray().decodeToString(throwOnInvalidSequence = true)
            }
            fun size(): Int {
                var value = 0L; var shift = 0
                while (true) {
                    val b = input.read(); require(b >= 0 && shift < 35)
                    value = value or ((b and 127).toLong() shl shift)
                    if (b and 128 == 0) { require(shift == 0 || b != 0); break }; shift += 7
                }
                require(value in 4..128L * 1024 * 1024 && value <= input.length() - input.filePointer)
                return value.toInt()
            }
            val magic = ByteArray(8); input.readFully(magic); require(magic.decodeToString() == "WIKBLB08")
            val kind = blobKind(input.read()); require(kind != "alias")
            val code = if (kind == "language") nul() else ""
            val language = if (kind == "language") nul() else null
            val headerEnd = input.filePointer
            require(headerEnd <= 131080)
            input.seek(0); val headerBytes = ByteArray(headerEnd.toInt()); input.readFully(headerBytes)
            require(headerBytes.contentEquals(headerFile.readBytes()))
            actualHeader = linkedMapOf("kind" to kind, "language" to language, "language_code" to code)
            var recordCount = 0
            while (input.filePointer < input.length()) {
                val title = nul(); require(title.isNotEmpty())
                val length = size(); val offset = input.filePointer; recordCount++
                if (title == wantedTitle) {
                    require(selected == null) { "Producer fixture title is duplicated" }
                    val payload = ByteArray(length); input.readFully(payload)
                    require(payload.copyOfRange(0, 4).decodeToString() == "DPR$version")
                    require(payload.contentEquals(payloadFile.readBytes()))
                    selected = BlobDecoder.decode(payload, title, kind, language, code)
                    selectedOffset = offset; selectedLength = length
                } else input.seek(offset + length)
            }
            require(recordCount == 1 && selected != null) { "Genuine Writer fixture must contain its one selected record" }
        }
        val output = File(producerEnvironment(name("ACTUAL"))).canonicalFile
        require(output.parentFile.isDirectory && output.createNewFile()) { "Use a fresh owned output path" }
        output.writeText(producerJson(linkedMapOf(
            "schema" to "wikidict.android.dpr$version-producer-actual.v1",
            "case_sha256" to producerEnvironment(name("CASE_SHA256")),
            "blob_sha256" to producerEnvironment(name("BLOB_SHA256")),
            "header_sha256" to producerDigest(headerFile.readBytes()),
            "payload_sha256" to producerDigest(payloadFile.readBytes()),
            "core_sha256" to producerEnvironment(name("CORE_SHA256")),
            "source_facts_sha256" to producerEnvironment(name("SOURCE_FACTS_SHA256")),
            "record_offset" to selectedOffset, "record_length" to selectedLength,
            "header" to actualHeader, "entry" to producerEntry(checkNotNull(selected)))), Charsets.UTF_8)
    }

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
        val requiredVersions = listOf(7, 8).filter { System.getenv("WIKBLB_DPR${it}_REQUIRED") != null }
        if (requiredVersions.isNotEmpty()) {
            require(requiredVersions.size == 1) { "Select exactly one required producer case" }
            requiredProducerConformance(requiredVersions.single())
            return
        }
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
    private fun explanationFixture(version: Int, background: String? = null, backgroundPresence: Int? = null, foreground: String? = null, foregroundPresence: Int? = null,
        spanBackground: String? = null, spanBackgroundPresence: Int? = null, anchored: Boolean = false): ByteArray {
        val out = java.io.ByteArrayOutputStream()
        fun byte(v: Int) { out.write(v) }
        fun u32(v: Int) { repeat(4) { byte(v ushr (it * 8) and 255) } }
        fun string(v: String) { val b = v.toByteArray(Charsets.UTF_8); u32(b.size); out.write(b) }
        fun spans(label: String) {
            u32(1); byte(1); byte(1); byte(10)
            listOf(label, "glossary", "!", "en", "abbr", "ltr").forEach(::string)
            if (version >= 3) string("Meaning & <plain> \u2067معنى\u2069: $label")
            if (version >= 4) {
                byte(foregroundPresence ?: if (foreground == null) 0 else 1)
                if (foreground != null) string(foreground)
            }
            if (version >= 6) {
                byte(spanBackgroundPresence ?: if (spanBackground == null) 0 else 1)
                if (spanBackground != null) string(spanBackground)
            }
        }
        fun block(table: Boolean) {
            byte(if (table) 12 else 0); byte(0); byte(0)
            spans(if (table) "table-body" else "body")
            byte(0); string(""); string(""); byte(if (table) 1 else 0)
            if (table) {
                spans("caption"); u32(1); u32(1); byte(0); byte(1); byte(0); byte(1); byte(0)
                if (version >= 4) {
                    byte(backgroundPresence ?: if (background == null) 0 else 1)
                    if (background != null) string(background)
                }
                spans("cell")
            }
            if (version >= 5) { string(""); string("") }
        }
        out.write("DPR$version".toByteArray()); spans("display")
        u32(1); byte(3); string("Noun")
        if (version >= 5) { string(if (anchored) "Noun" else ""); string(if (anchored) "Noun_fallback" else "") }
        u32(2); block(false); block(true)
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
        val unknown = bytes.copyOf().also { it[3] = '7'.code.toByte() }
        assertThrows(Exception::class.java) { BlobDecoder.decode(unknown, "Word", "language", "English", "en") }
        val marker = "Meaning &".toByteArray()
        val start = bytes.asList().windowed(marker.size).indexOfFirst { it == marker.asList() }
        assertTrue(start >= 0)
        val invalid = bytes.copyOf().also { it[start] = 0xff.toByte() }
        assertThrows(Exception::class.java) { BlobDecoder.decode(invalid, "Word", "language", "English", "en") }
        assertThrows(Exception::class.java) { BlobDecoder.decode(bytes + byteArrayOf(0), "Word", "language", "English", "en") }
        for (color in listOf("", "red", "#FFF000", "#ff0", "#ff000000", "#gggggg", " #ffff00", "#ffff00 ", "background:#ffff00"))
            assertThrows(Exception::class.java) { BlobDecoder.decode(explanationFixture(6, spanBackground = color), "Word", "language", "English", "en") }
        assertThrows(Exception::class.java) { BlobDecoder.decode(explanationFixture(6, spanBackgroundPresence = 2), "Word", "language", "English", "en") }
        val painted = explanationFixture(6, background = "#fffdd0", foreground = "#008000", spanBackground = "#ffffe0")
        for (length in painted.indices) assertThrows(Exception::class.java) {
            BlobDecoder.decode(painted.copyOf(length), "Word", "language", "English", "en")
        }
        assertThrows(Exception::class.java) { BlobDecoder.decode(painted + byteArrayOf(0), "Word", "language", "English", "en") }
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
        for (version in 2..6) {
            val absent = BlobDecoder.decode(explanationFixture(version), "Word", "language", "English", "en")
            assertTrue(containers(absent).flatten().all { it.background == null })
            if (version >= 3) assertEquals(legacy, absent)
        }
        val backgroundOnly = BlobDecoder.decode(explanationFixture(6, spanBackground = "#ffffe0"), "Word", "language", "English", "en")
        containers(backgroundOnly).zip(before).forEach { (spans, original) ->
            assertNull(spans.single().foreground)
            assertEquals("#ffffe0", spans.single().background)
            assertEquals(original, spans.map { it.copy(background = null) })
        }
        val painted = BlobDecoder.decode(explanationFixture(6, background = "#fffdd0", foreground = "#008000", spanBackground = "#ffffe0", anchored = true), "Word", "language", "English", "en")
        containers(painted).zip(before).forEach { (spans, original) ->
            assertEquals("#008000", spans.single().foreground)
            assertEquals("#ffffe0", spans.single().background)
            assertEquals(original, spans.map { it.copy(foreground = null, background = null) })
        }
        assertEquals("#fffdd0", painted.sections.single().blocks[1].table!!.rows.single().single().background)
        assertEquals("Noun", painted.sections.single().anchor)
        assertEquals("Noun_fallback", painted.sections.single().anchorFallback)
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
