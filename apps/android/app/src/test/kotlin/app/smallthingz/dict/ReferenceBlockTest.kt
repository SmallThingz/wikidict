package app.smallthingz.dict

import org.junit.Assert.*
import org.junit.Test
import java.io.ByteArrayOutputStream

class ReferenceBlockTest {
    private data class Item(val id: Long, val spans: List<Span> = emptyList(), val blocks: List<Block>? = null,
        val kind: ReferenceKind = ReferenceKind.Note, val presence: Int? = null)

    // Independent literal B/C/D writer. D adds only the image border flag;
    // C and D retain the optional ordered reference blocks and table styles.
    private class Wire(val styles: Boolean, val imageBorders: Boolean = false) {
        val out = ByteArrayOutputStream()
        fun byte(n: Int) { out.write(n) }
        fun u32(n: Long) { repeat(4) { byte((n ushr (it * 8)).toInt() and 255) } }
        fun u16(n: Int) { byte(n and 255); byte(n ushr 8) }
        fun image(value: InlineImage?) {
            if (!styles) { require(value == null); return }
            byte(if (value == null) 0 else 1); if (value == null) return
            require(imageBorders || !value.border)
            string(value.file)
            byte((if (value.widthPx != null) 1 else 0) or (if (value.heightPx != null) 2 else 0) or
                (if (value.alt != null) 4 else 0) or (if (value.tooltip != null) 8 else 0) or (if (value.border) 16 else 0))
            value.widthPx?.let(::u32); value.heightPx?.let(::u32); value.alt?.let(::string); value.tooltip?.let(::string)
        }
        fun length(value: StyleLength) { byte(if (value.unit == StyleLengthUnit.Px) 0 else 1); u32(value.value.toRawBits().toLong()) }
        fun edges(value: StyleEdges) { listOf(value.top, value.right, value.bottom, value.left).forEach(::length) }
        fun border(value: StyleBorder) {
            when (value) {
                StyleBorder.None -> byte(0)
                is StyleBorder.Solid -> { byte(1); length(value.width); string(value.color) }
            }
        }
        fun cellStyle(value: CellStyle?) {
            if (!styles) { require(value == null); return }
            byte(if (value == null) 0 else 1); if (value == null) return
            byte((if (value.border != null) 1 else 0) or (if (value.padding != null) 2 else 0) or (if (value.textAlign != null) 4 else 0))
            value.border?.let(::border); value.padding?.let(::edges)
            value.textAlign?.let { byte(when (it) { CellTextAlign.Left -> 0; CellTextAlign.Center -> 1; CellTextAlign.Right -> 2 }) }
        }
        fun tableStyle(value: TableStyle?) {
            if (!styles) { require(value == null); return }
            byte(if (value == null) 0 else 1); if (value == null) return
            byte((if (value.background != null) 1 else 0) or (if (value.border != null) 2 else 0) or (if (value.collapse != null) 4 else 0) or (if (value.margins != null) 8 else 0))
            value.background?.let(::string); value.border?.let(::border)
            value.collapse?.let { byte(if (it == TableCollapse.Separate) 0 else 1) }; value.margins?.let(::edges)
        }
        fun string(s: String) { val b = s.toByteArray(Charsets.UTF_8); u32(b.size.toLong()); out.write(b) }
        fun spans(values: List<Span>) {
            u32(values.size.toLong())
            values.forEach { s ->
                byte(listOf("text", "link", "external_link", "line_break").indexOf(s.kind))
                byte(listOf("normal", "label", "pronunciation", "headword", "example", "quotation", "citation", "reference").indexOf(s.role))
                byte((if (s.bold) 1 else 0) or (if (s.italic) 2 else 0) or (if (s.code) 4 else 0) or
                    (if (s.small) 8 else 0) or (if (s.superscript) 16 else 0) or (if (s.subscript) 32 else 0) or
                    (if (s.strike) 64 else 0) or (if (s.underline) 128 else 0))
                listOf(s.text, s.target, s.trail, s.language, s.classes, s.direction, s.explanation).forEach(::string)
                listOf(s.foreground, s.background).forEach { value -> byte(if (value == null) 0 else 1); value?.let(::string) }
                byte(if (s.fontScale == null) 0 else 1)
                s.fontScale?.let { u32(it.toRawBits().toLong()); byte(if (s.fontScaleBasis == FontScaleBasis.NormalBody) 1 else 0) }
                image(s.image)
            }
        }
        fun table(t: Table?) {
            byte(if (t == null) 0 else 1)
            if (t == null) return
            require(t.geometry == null)
            byte(0); spans(t.caption); u32(t.rows.size.toLong())
            t.rows.forEach { row -> u32(row.size.toLong()); row.forEach { cell ->
                byte(if (cell.header) 1 else 0); u16(cell.colspan); u16(cell.rowspan)
                byte(if (cell.background == null) 0 else 1); cell.background?.let(::string)
                spans(cell.spans); table(cell.nestedTable)
                byte(if (cell.blocks == null) 0 else 1); cell.blocks?.let(::blocks)
                cellStyle(cell.style)
            } }
            tableStyle(t.style)
        }
        fun blocks(values: List<Block>) { u32(values.size.toLong()); values.forEach(::block) }
        fun block(b: Block) {
            byte(listOf("paragraph", "blank", "definition", "example", "quotation", "list_item", "list_detail", "indent", "term", "heading", "preformatted", "rule", "table").indexOf(b.kind))
            byte(b.depth); byte(b.level); spans(b.spans)
            byte(if (b.feature == null) 0 else 1)
            b.feature?.let { listOf(it.kind, it.language, it.data, it.tailKind, it.tail).forEach(::string) }
            string(b.listPath); string(b.number); table(b.table); string(b.anchor); string(b.anchorFallback)
        }
    }
    private fun fixture(version: Char, items: List<Item>, sections: List<Section> = emptyList(),
        display: List<Span> = emptyList(), preamble: List<Span> = emptyList(), media: List<Media> = emptyList()): ByteArray = Wire(version in "CD", version == 'D').apply {
        out.write("DPR$version".toByteArray(Charsets.US_ASCII))
        spans(display); u32(sections.size.toLong())
        sections.forEach { byte(it.level); string(it.title); string(it.anchor); string(it.anchorFallback); blocks(it.blocks) }
        spans(preamble); u32(0); u32(0)
        u32(items.size.toLong())
        items.forEach { item ->
            byte(if (item.kind == ReferenceKind.Note) 0 else 1); u32(item.id)
            if (item.kind == ReferenceKind.Note) { u32(1); string("") }
            string("notes"); spans(item.spans)
            if (version in "CD") {
                byte(item.presence ?: if (item.blocks == null) 0 else 1)
                item.blocks?.let(::blocks)
            }
        }
        u32(media.size.toLong()); media.forEach { string(it.file); byte(if (it.kind == "image") 0 else 1); string(it.caption) }
    }.out.toByteArray()
    private fun decode(b: ByteArray) = BlobDecoder.decode(b, "Reference blocks", "language", "English", "en")
    private fun heading(label: String, anchor: String) = Block("heading", 0,
        listOf(Span("text", label)), level = 3, anchor = anchor, anchorFallback = anchor.lowercase())
    private fun tableBlock(vararg blocks: Block): Block {
        val cell = Cell(emptyList(), false, 1, 1, blocks = blocks.toList())
        return Block("table", 0, emptyList(), table = Table(emptyList(), listOf(listOf(cell))))
    }

    @Test fun dprcRetainsOrderedReferenceBlocksEmptyAuthorityAndAllInheritedSpanFields() {
        val rich = Span("link", "Target", "Target", trail = "!", language = "hr", bold = true,
            explanation = "An explanation", foreground = "#123456", background = "#abcdef",
            fontScale = 1f, fontScaleBasis = FontScaleBasis.NormalBody)
        val zero = Span("text", "zero", fontScale = 0f)
        val context = Span("text", "relative", fontScale = 1.25f)
        val nestedCell = Cell(listOf(Span("text", "Nested cell")), false, 1, 1)
        val nestedTable = Block("table", 0, emptyList(), table = Table(emptyList(), listOf(listOf(nestedCell))))
        val cell = Cell(emptyList(), false, 1, 1,
            blocks = listOf(Block("preformatted", 0, listOf(zero)), nestedTable))
        val content = listOf(
            heading("Reference heading", "Reference_heading"),
            Block("list_item", 2, listOf(rich), listPath = "*#", number = "3"),
            Block("list_detail", 2, listOf(context), listPath = "*#:"),
            Block("table", 0, emptyList(), table = Table(listOf(Span("text", "Caption")), listOf(listOf(cell)))),
            Block("paragraph", 0, listOf(Span("text", "After table"))))
        val entry = decode(fixture('C', listOf(
            Item(2, blocks = content, kind = ReferenceKind.Fragment), Item(1, blocks = emptyList()),
            Item(3, spans = listOf(Span("text", "Legacy inline"))))))
        assertEquals(listOf(2L, 1L, 3L), entry.references.map { it.number })
        assertEquals(content, entry.references[0].blocks)
        assertTrue(entry.references[0].spans.isEmpty())
        assertEquals(emptyList<Block>(), entry.references[1].blocks)
        assertNull(entry.references[2].blocks)
        assertEquals("Legacy inline", textOf(entry.references[2].spans))
        assertEquals(listOf(null, "[notes 1]", "[notes 1]"), entry.references.map(::referenceLabel))
        val runs = mutableListOf<Pair<List<Span>, Boolean>>()
        entry.references[0].visitSpanRuns { spans, literal -> if (spans.isNotEmpty()) runs.add(spans to literal) }
        assertEquals(listOf("Reference heading", "Target!", "relative", "Caption", "zero", "Nested cell", "After table"), runs.map { textOf(it.first) })
        assertEquals(listOf(false, false, false, false, true, false, false), runs.map { it.second })
        assertEquals(rich, runs[1].first.single())
        assertEquals(0f, runs[4].first.single().fontScale)
    }

    @Test fun dprcRejectsMixedModeInvalidPresenceTruncationCountsAndExcessiveTableDepth() {
        val text = listOf(Span("text", "Legacy"))
        assertEquals(decode(fixture('B', listOf(Item(1, spans = text)))).references,
            decode(fixture('C', listOf(Item(1, spans = text)))).references)
        assertThrows(IllegalArgumentException::class.java) { Reference(1, 1, "", text, blocks = emptyList()) }
        assertThrows(Exception::class.java) { decode(fixture('C', listOf(Item(1, spans = text, blocks = emptyList())))) }
        assertThrows(Exception::class.java) { decode(fixture('C', listOf(Item(1, presence = 2)))) }
        val valid = fixture('C', listOf(Item(2, blocks = listOf(heading("Body", "Body")), kind = ReferenceKind.Fragment)))
        for (length in valid.indices) assertThrows(Exception::class.java) { decode(valid.copyOf(length)) }
        val oversizedCount = fixture('C', listOf(Item(1, blocks = emptyList()))).copyOf()
        // The final eight bytes are the authoritative block count and media count.
        repeat(4) { oversizedCount[oversizedCount.size - 8 + it] = 0xff.toByte() }
        assertThrows(Exception::class.java) { decode(oversizedCount) }
        fun nested(depth: Int): Block = if (depth == 0) Block("paragraph", 0, listOf(Span("text", "Leaf")))
            else tableBlock(nested(depth - 1))
        assertNotNull(decode(fixture('C', listOf(Item(1, blocks = listOf(nested(MaxTableDepth)))))))
        assertThrows(Exception::class.java) { decode(fixture('C', listOf(Item(1, blocks = listOf(nested(MaxTableDepth + 1)))))) }
    }

    @Test fun referenceBlockWalkersRetainActionsMediaAnnotationsWhitespaceAndEmptyAuthority() {
        val annotation = Span("link", "abbr.", "Target", explanation = "Expanded meaning")
        val media = Span("link", "Audio", "File:Tone.ogg", classes = "wikidict-media")
        val content = listOf(Block("paragraph", 0, listOf(annotation)), tableBlock(
                Block("preformatted", 0, listOf(Span("text", "  literal\n text  "))),
                Block("paragraph", 0, listOf(media))))
        val reference = Reference(2, null, "notes", emptyList(), ReferenceKind.Fragment, content)
        val entry = Entry("word", emptyList(), "language", "English", "en", emptyList(), listOf(reference),
            media = listOf(Media("Tone.ogg", "audio", "Audio")))
        assertEquals(listOf("abbr."), entry.abbreviations.map { it.label })
        assertEquals("Expanded meaning", entry.abbreviations.single().explanation)
        assertEquals(setOf("Tone.ogg"), inlineMediaFiles(entry))
        val actions = mutableListOf<String>()
        val text = StringBuilder()
        reference.visitSpanRuns { spans, literal ->
            val displayed = if (literal) spans else compactSpans(spans)
            displayed.forEach { text.append(it.text).append(it.trail); if (it.target.isNotEmpty()) actions.add(it.target) }
        }
        assertEquals(listOf("Target", "File:Tone.ogg"), actions)
        assertTrue(text.contains("  literal\n text  "))
        assertTrue(entry.copy(references = listOf(reference.copy(blocks = emptyList()))).abbreviations.isEmpty())
        assertTrue(inlineMediaFiles(entry.copy(references = listOf(reference.copy(blocks = emptyList())))).isEmpty())
    }

    @Test fun referenceBlockHeadingsUseAuthoredIdsAndNestedPathsWithoutInventingFragmentTargets() {
        val nested = tableBlock(heading("Nested", "Nested_2"))
        val refs = listOf(Reference(2, null, "notes", emptyList(), ReferenceKind.Fragment,
            listOf(heading("Citation heading", "Citation_heading"), nested)),
            Reference(9, 1, "notes", emptyList(), blocks = emptyList()))
        val entry = Entry("word", emptyList(), "language", "English", "en", listOf(
            Section(3, "Noun", listOf(Block("definition", 1, listOf(Span("text", "Meaning")))), anchor = "Noun")), refs)
        val direct = headingDestination(entry, "#Citation_heading")!!
        assertEquals(0, direct.referenceIndex)
        assertEquals("reference-2", direct.rowKey)
        assertEquals("reference-2/block-0", direct.path)
        val destination = headingDestination(entry, "#Nested_2")!!
        assertEquals(0, destination.referenceIndex)
        assertEquals("reference-2/block-1/table/cell-0/block-0", destination.path)
        assertTrue(destination.compiledId)
        assertNull(referenceScrollIndex(entry, "#reference-2", setOf("references")))
        assertEquals(metadataReferencesStartIndex(entry, setOf("heading-0", "references")) + 2,
            referenceScrollIndex(entry, "#reference-9", setOf("heading-0", "references")))
        val authored = entry.copy(sections = listOf(Section(3, "Actual", emptyList(), anchor = "reference-9")))
        assertNull(headingDestination(authored, "#reference-9")!!.referenceIndex)
        val ambiguous = entry.copy(sections = listOf(Section(3, "Duplicate", emptyList(), anchor = "Citation_heading")))
        assertNull(headingDestination(ambiguous, "#Citation_heading"))
    }

    @Test fun dprcStylesRetainUnitsZeroPhysicalAlignmentAndRejectMalformedSuffixes() {
        fun px(value: Float) = StyleLength(StyleLengthUnit.Px, value)
        fun em(value: Float) = StyleLength(StyleLengthUnit.Em, value)
        val cellStyle = CellStyle(StyleBorder.Solid(px(1f), "#abcdef"),
            StyleEdges(em(0.2f), px(0f), em(0.2f), px(0f)), CellTextAlign.Center)
        val tableStyle = TableStyle("#f9f9f9", StyleBorder.Solid(px(1f), "#aaaaaa"), TableCollapse.Collapse,
            StyleEdges(px(10f), px(10f), px(10f), px(10f)))
        val table = Table(emptyList(), listOf(listOf(Cell(listOf(Span("text", "Header")), true, 1, 1,
            background = "#f2f2f2", style = cellStyle))), style = tableStyle)
        // Styles alone need C even when every reference retains its null block mode.
        val sections = listOf(Section(2, "Style", listOf(Block("table", 0, emptyList(), table = table))))
        val valid = fixture('C', listOf(Item(1, spans = listOf(Span("text", "Legacy note")))), sections)
        val entry = decode(valid)
        assertEquals(table, entry.sections.single().blocks.single().table)
        assertNull(entry.references.single().blocks)
        assertEquals("Legacy note", textOf(entry.references.single().spans))
        val inherited = table.copy(style = null, rows = listOf(listOf(table.rows[0][0].copy(style = null))))
        val oldSections = listOf(Section(2, "Style", listOf(Block("table", 0, emptyList(), table = inherited))))
        assertEquals(inherited, decode(fixture('B', emptyList(), oldSections)).sections.single().blocks.single().table)
        fun find(text: String): Int {
            val bytes = text.toByteArray()
            return valid.indices.first { at -> at + bytes.size <= valid.size && valid.copyOfRange(at, at + bytes.size).contentEquals(bytes) }
        }
        val cellColor = find("#abcdef"); val tableColor = find("#f9f9f9"); val outerColor = find("#aaaaaa")
        for ((at, value) in listOf(cellColor - 12 to 2, cellColor - 11 to 0, cellColor - 11 to 8,
                cellColor - 10 to 2, cellColor - 9 to 2, cellColor + 27 to 3,
                tableColor - 6 to 2, tableColor - 5 to 0, tableColor - 5 to 16,
                outerColor + 7 to 2, outerColor + 8 to 2, cellColor + 1 to 'A'.code)) {
            val bad = valid.copyOf(); bad[at] = value.toByte()
            assertThrows(Exception::class.java) { decode(bad) }
        }
        for (value in listOf(-1f, Float.NaN, Float.POSITIVE_INFINITY)) {
            val bad = valid.copyOf()
            java.nio.ByteBuffer.wrap(bad).order(java.nio.ByteOrder.LITTLE_ENDIAN).putFloat(cellColor - 8, value)
            assertThrows(Exception::class.java) { decode(bad) }
        }
        for (length in valid.indices) assertThrows(Exception::class.java) { decode(valid.copyOf(length)) }
        assertThrows(IllegalArgumentException::class.java) { TableStyle() }
        assertThrows(IllegalArgumentException::class.java) { CellStyle() }
        assertThrows(IllegalArgumentException::class.java) { StyleLength(StyleLengthUnit.Em, Float.NaN) }
        assertThrows(IllegalArgumentException::class.java) { StyleBorder.Solid(px(1f), "#ABCDEF") }
    }

    @Test fun dprcInlineImagesRetainEmptyOccurrencesAttributesActionsAndEverySpanSink() {
        val q = Span("link", "", "File:Vraagteken-2.svg", image = InlineImage("Vraagteken-2.svg", 15))
        val x = Span("external_link", "", "https://example.org/x", image = InlineImage("X mark.svg", 15, alt = "איקס", tooltip = "איקס"))
        val yes = Span("text", "", image = InlineImage("Yes check.svg", 15, alt = "", tooltip = ""))
        val repeated = q.copy(target = "Target", image = q.image!!.copy(widthPx = 30, alt = "", tooltip = ""))
        val zero = q.copy(fontScale = 0f, small = true)
        val nested = Table(emptyList(), listOf(listOf(Cell(listOf(yes), false, 1, 1))))
        val table = Table(listOf(yes), listOf(listOf(Cell(listOf(x), false, 1, 1),
            Cell(emptyList(), false, 1, 1, blocks = listOf(Block("paragraph", 0, listOf(repeated)))),
            Cell(emptyList(), false, 1, 1, nestedTable = nested))))
        val heading = Block("heading", 0, listOf(Span("text", "Heading"), zero), level = 3, anchor = "Heading")
        val sections = listOf(Section(3, "Heading", listOf(heading, Block("paragraph", 0,
            listOf(Span("text", "Before "), x, Span("text", " After"))), Block("table", 0, emptyList(), table = table))))
        val media = listOf(Media("Vraagteken-2.svg", "image", "Body preferred caption"),
            Media("X mark.svg", "image", "איקס"), Media("Yes check.svg", "image", "וי"))
        val entry = decode(fixture('C', listOf(Item(1, spans = listOf(q)),
            Item(2, blocks = listOf(Block("paragraph", 0, listOf(x))), kind = ReferenceKind.Fragment)),
            sections, display = listOf(q), preamble = listOf(x), media = media))
        assertEquals(sections, entry.sections)
        assertEquals(media, entry.media)
        assertEquals(listOf("Vraagteken-2.svg", "X mark.svg", "Vraagteken-2.svg", "X mark.svg", "Yes check.svg",
            "X mark.svg", "Vraagteken-2.svg", "Yes check.svg", "Vraagteken-2.svg", "X mark.svg"), inlineImageOccurrences(entry).map { it.file })
        assertNull(inlineImageOccurrences(entry).first().alt)
        assertEquals("", inlineImageOccurrences(entry)[4].alt)
        assertEquals("Heading", textOf(entry.sections.single().blocks.first().spans))
        assertEquals("Before After", textOf(entry.sections.single().blocks[1].spans))
        assertEquals(zero, entry.readingRows.first().headingBlock!!.spans.last())
        assertEquals(setOf("Vraagteken-2.svg", "X mark.svg", "Yes check.svg"), inlineMediaFiles(entry))
        assertEquals("Body preferred caption", entry.media.first().caption)
        assertEquals(repeated, entry.sections.single().blocks[2].table!!.rows[0][1].blocks!!.single().spans.single())
    }

    @Test fun dprdBorderIsOccurrenceLocalAcrossEverySpanSinkAndPreservesCompleteFields() {
        // Synthetic wire fixture; actual Italian Writer output is a separate conformance input.
        val plain = Span("link", "", "File:Controlled.svg", image = InlineImage("Controlled.svg", 40))
        val bordered = plain.copy(explanation = "Source detail", foreground = "#123456", background = "#abcdef",
            fontScale = 0f, fontScaleBasis = FontScaleBasis.NormalBody, bold = true, small = true,
            image = plain.image!!.copy(alt = "", tooltip = "Authored tooltip", border = true))
        val internal = bordered.copy(target = "Target#Section")
        val external = bordered.copy(kind = "external_link", target = "https://example.org/x")
        val unlinked = bordered.copy(kind = "text", target = "", image = bordered.image!!.copy(tooltip = ""))
        val px = StyleLength(StyleLengthUnit.Px, 1f)
        val nested = Table(listOf(plain), listOf(listOf(Cell(listOf(unlinked), false, 1, 1))))
        val table = Table(listOf(bordered), listOf(listOf(
            Cell(listOf(external), false, 1, 1, style = CellStyle(border = StyleBorder.Solid(px, "#123456"))),
            Cell(emptyList(), false, 1, 1, blocks = listOf(Block("paragraph", 0, listOf(internal)))),
            Cell(emptyList(), false, 1, 1, nestedTable = nested))), style = TableStyle(background = "#abcdef"))
        val sections = listOf(Section(3, "Heading", listOf(
            Block("heading", 0, listOf(bordered), level = 3, anchor = "Heading"),
            Block("paragraph", 0, listOf(plain, unlinked)), Block("table", 0, emptyList(), table = table)), "Heading"))
        val referenceBlocks = listOf(Block("table", 0, emptyList(), table = table), Block("paragraph", 0, listOf(bordered)))
        val media = listOf(Media("Controlled.svg", "image", "Catalogue remains independent"))
        val entry = decode(fixture('D', listOf(Item(1, spans = listOf(external)),
            Item(2, blocks = referenceBlocks, kind = ReferenceKind.Fragment)), sections,
            display = listOf(bordered), preamble = listOf(plain, unlinked), media = media))
        assertEquals(listOf(bordered), entry.displayTitle)
        assertEquals(listOf(plain, unlinked), entry.preamble)
        assertEquals(sections, entry.sections)
        assertEquals(listOf(external), entry.references[0].spans)
        assertEquals(referenceBlocks, entry.references[1].blocks)
        assertEquals(ReferenceKind.Fragment, entry.references[1].kind)
        assertEquals(media, entry.media)
        val occurrences = inlineImageOccurrences(entry)
        assertEquals(18, occurrences.size)
        assertEquals(14, occurrences.count { it.border })
        assertEquals(4, occurrences.count { !it.border })
        assertTrue(occurrences.all { it.widthPx == 40L && it.heightPx == null })
        assertEquals(setOf("Controlled.svg"), inlineMediaFiles(entry))
    }

    @Test fun dprdRejectsUnknownBitsTruncationAndBorderFlagInOlderPayload() {
        val image = InlineImage("Controlled.svg", 40, alt = "", tooltip = "", border = true)
        val span = Span("link", "", "File:Controlled.svg", image = image)
        val media = listOf(Media(image.file, "image", "Independent caption"))
        val valid = fixture('D', emptyList(), display = listOf(span), media = media)
        assertEquals(image, decode(valid).displayTitle.single().image)
        for (length in valid.indices) assertThrows(Exception::class.java) { decode(valid.copyOf(length)) }
        val marker = Wire(true, true).apply { string(image.file) }.out.toByteArray()
        val at = valid.indices.first { it + marker.size <= valid.size && valid.copyOfRange(it, it + marker.size).contentEquals(marker) }
        val flags = at + marker.size
        for (unknown in listOf(0x20, 0x40, 0x80, 0xe0)) {
            val bad = valid.copyOf(); bad[flags] = (bad[flags].toInt() or unknown).toByte()
            assertThrows(Exception::class.java) { decode(bad) }
        }
        val old = valid.copyOf(); old[3] = 'C'.code.toByte()
        assertThrows(Exception::class.java) { decode(old) }
        val unbordered = span.copy(image = image.copy(border = false))
        assertEquals(decode(fixture('C', emptyList(), display = listOf(unbordered), media = media)),
            decode(fixture('D', emptyList(), display = listOf(unbordered), media = media)))
    }

    @Test fun dprcInlineImagesRejectMalformedFramingDedicatedTextAndMissingOrAmbiguousAssets() {
        val image = InlineImage("Question.svg", 0xffff_ffffL, 0xffff_ffffL, "", "")
        val span = Span("link", "", "File:Question.svg", image = image)
        val asset = Media("Question.svg", "image", "Unchanged catalog caption")
        val valid = fixture('C', listOf(Item(1, spans = listOf(span))), media = listOf(asset))
        assertEquals(image, decode(valid).references.single().spans.single().image)
        for (length in valid.indices) assertThrows(Exception::class.java) { decode(valid.copyOf(length)) }
        val marker = Wire(true).apply { string(image.file) }.out.toByteArray()
        val at = valid.indices.first { it + marker.size <= valid.size && valid.copyOfRange(it, it + marker.size).contentEquals(marker) }
        val flags = at + marker.size
        for ((offset, value) in listOf(at - 1 to 2, flags to 16)) {
            val bad = valid.copyOf(); bad[offset] = value.toByte(); assertThrows(Exception::class.java) { decode(bad) }
        }
        for (offset in listOf(flags + 1, flags + 5)) {
            val bad = valid.copyOf(); repeat(4) { bad[offset + it] = 0 }; assertThrows(Exception::class.java) { decode(bad) }
        }
        for (assets in listOf(emptyList(), listOf(asset.copy(kind = "audio")), listOf(asset, asset),
                listOf(asset) + List(128) { Media("unused$it.png", "image", "") })) {
            assertThrows(Exception::class.java) { decode(fixture('C', listOf(Item(1, spans = listOf(span))), media = assets)) }
        }
        assertEquals(129, decode(fixture('B', emptyList(), media = List(129) { Media("legacy$it.png", "image", "") })).media.size)
        for (bad in listOf("", " leading.svg", "trailing.svg ", "under_score.svg", "bad|name.svg", "bad#name.svg", "bad\u0080.svg")) {
            assertThrows(IllegalArgumentException::class.java) { InlineImage(bad) }
        }
        assertNotNull(InlineImage("File:合法/שם.svg", alt = "[]{}<>|#_", tooltip = ""))
        assertThrows(IllegalArgumentException::class.java) { span.copy(kind = "line_break") }
        assertThrows(IllegalArgumentException::class.java) { span.copy(kind = "text") }
        assertThrows(IllegalArgumentException::class.java) { span.copy(target = "") }
        assertThrows(IllegalArgumentException::class.java) { span.copy(text = "not dedicated") }
        assertThrows(IllegalArgumentException::class.java) { span.copy(trail = " ") }
        assertThrows(IllegalArgumentException::class.java) { InlineImage("Question.svg", 0) }
    }

    @Test fun imageOnlyCompactionAndHeadingAuthorityNeverInventFilenameAltOrTooltipText() {
        val image = Span("text", "", image = InlineImage("Question.svg", 15, alt = "Alt", tooltip = "Tooltip"))
        assertEquals(listOf(image), compactSpans(listOf(Span("text", " "), image, Span("text", " "))))
        val block = Block("paragraph", 0, listOf(Span("text", "A "), image, Span("text", " B")))
        assertEquals(listOf("A ", "", " B"), ordinaryInlineDisplaySpans(block).map { it.text })
        val heading = Block("heading", 0, listOf(Span("text", "Known heading"), image), level = 3, anchor = "Known_heading")
        assertEquals(heading, sectionHeadingCompanion(Section(3, "Known heading", listOf(heading))))
        val blankHeading = heading.copy(spans = listOf(image), anchor = "Authored_empty")
        assertNull(sectionHeadingCompanion(Section(3, "", listOf(blankHeading))))
        assertEquals("", textOf(blankHeading.spans))
        assertTrue(readingRows(listOf(Section(3, "", listOf(blankHeading)))).any { it.block == blankHeading })
        assertEquals(listOf(image, image), compactSpans(listOf(image, image)))
    }
}
