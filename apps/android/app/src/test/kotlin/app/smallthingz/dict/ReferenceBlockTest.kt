package app.smallthingz.dict

import org.junit.Assert.*
import org.junit.Test
import java.io.ByteArrayOutputStream

class ReferenceBlockTest {
    private data class Item(val id: Long, val spans: List<Span> = emptyList(), val blocks: List<Block>? = null,
        val kind: ReferenceKind = ReferenceKind.Note, val presence: Int? = null)

    // Independent literal B/C/D/E/F/G/H/I writer. G keeps F fields with a dynamic catalog;
    // C and D retain the optional ordered reference blocks and table styles.
    private class Wire(val styles: Boolean, val imageBorders: Boolean = false, val blockLayouts: Boolean = false, val targetFragments: Boolean = false, val tooltips: Boolean = false, val blockStyles: Boolean = false) {
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
                is StyleBorder.Edges -> error("This legacy binary fixture does not encode per-edge borders")
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
            require(blockLayouts || value.floatSide == null)
            byte((if (value.background != null) 1 else 0) or (if (value.border != null) 2 else 0) or (if (value.collapse != null) 4 else 0) or (if (value.margins != null) 8 else 0) or (if (value.floatSide != null) 16 else 0))
            value.background?.let(::string); value.border?.let(::border)
            value.collapse?.let { byte(if (it == TableCollapse.Separate) 0 else 1) }; value.margins?.let(::edges)
            value.floatSide?.let { byte(if (it == TableFloatSide.Left) 0 else 1) }
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
                if (targetFragments) { byte(if (s.targetFragment == null) 0 else 1); s.targetFragment?.let(::string) }
                else require(s.targetFragment == null)
                if (tooltips) { byte(if (s.tooltip == null) 0 else 1); s.tooltip?.let(::string) }
                else require(s.tooltip == null)
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
            require(blockLayouts || b.textAlign == null)
            if (blockLayouts) {
                byte(if (b.textAlign == null) 0 else 1)
                b.textAlign?.let { byte(when (it) { CellTextAlign.Left -> 0; CellTextAlign.Center -> 1; CellTextAlign.Right -> 2 }) }
            }
            if (blockStyles) {
                byte(if (b.style == null) 0 else 1)
                b.style?.let { style ->
                    byte((if (style.margins != null) 1 else 0) or (if (style.padding != null) 2 else 0))
                    style.margins?.let(::edges); style.padding?.let(::edges)
                }
            } else require(b.style == null)
        }
    }
    private fun fixture(version: Char, items: List<Item>, sections: List<Section> = emptyList(),
        display: List<Span> = emptyList(), preamble: List<Span> = emptyList(), media: List<Media> = emptyList()): ByteArray = Wire(version in "CDEFGHI", version in "DEFGHI", version in "EFGHI", version in "FGHI", version in "HI", version == 'I').apply {
        out.write("DPR$version".toByteArray(Charsets.US_ASCII))
        spans(display); u32(sections.size.toLong())
        sections.forEach { byte(it.level); string(it.title); string(it.anchor); string(it.anchorFallback); blocks(it.blocks) }
        spans(preamble); u32(0); u32(0)
        u32(items.size.toLong())
        items.forEach { item ->
            byte(if (item.kind == ReferenceKind.Note) 0 else 1); u32(item.id)
            if (item.kind == ReferenceKind.Note) { u32(1); string("") }
            string("notes"); spans(item.spans)
            if (version in "CDEFGHI") {
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

    @Test fun dpriKeepsParagraphEdgesAtEveryBlockSinkAndInheritsHComponentsAndCatalogs() {
        val px = StyleLength(StyleLengthUnit.Px, 0f)
        val em = StyleLength(StyleLengthUnit.Em, 1.6f)
        val edges = StyleEdges(px, px, StyleLength(StyleLengthUnit.Em, .5f), em)
        val link = Span("link", "entry", "literal#title", targetFragment = "", tooltip = "Advice", italic = true)
        val image = Span("text", "", image = InlineImage("Asset.svg", 30, alt = "", border = true), tooltip = "")
        val paragraph = Block("paragraph", 0, listOf(link, image), textAlign = CellTextAlign.Right,
            style = BlockStyle(margins = edges, padding = edges))
        val empty = Block("paragraph", 0, emptyList(), style = BlockStyle(padding = StyleEdges(px, px, px, px)))
        val cell = tableBlock(paragraph, empty)
        val nested = Block("table", 0, emptyList(), table = Table(emptyList(), listOf(listOf(
            Cell(emptyList(), false, 1, 1, nestedTable = cell.table)))))
        val sections = listOf(Section(2, "Body", listOf(paragraph, empty, cell, nested)))
        val items = listOf(Item(1, blocks = listOf(paragraph, cell)),
            Item(2, blocks = listOf(empty, nested), kind = ReferenceKind.Fragment))
        val media = listOf(Media("Asset.svg", "image", "")) + List(279) { Media("$it.ogg", "audio", "") }
        val decoded = decode(fixture('I', items, sections, media = media))
        assertEquals(sections, decoded.sections)
        assertEquals(items.map { it.blocks }, decoded.references.map { it.blocks })
        assertEquals(media, decoded.media)
        assertEquals(link, decoded.sections.first().blocks.first().spans.first())
        assertEquals(27, Wire(true, true, true, true, true, true).apply {
            block(Block("paragraph", 0, emptyList())) }.out.size())
        assertEquals(37, Wire(true, true, true, true, true, true).apply {
            spans(listOf(Span("text", ""))) }.out.size() - 4)
        val old = fixture('H', emptyList(), sections = listOf(Section(2, "Body", listOf(paragraph.copy(style = null)))), media = media)
        assertNull(decode(old).sections.single().blocks.single().style)
        assertArrayEquals(old, fixture('H', emptyList(), sections = listOf(Section(2, "Body", listOf(paragraph.copy(style = null)))), media = media))
    }

    @Test fun dpriRejectsMalformedEdgesAndNonParagraphContextsWithoutNarrowingEmptyParagraphs() {
        val zero = StyleLength(StyleLengthUnit.Px, 0f)
        val edges = StyleEdges(zero, zero, zero, zero)
        val styled = Block("paragraph", 0, emptyList(), style = BlockStyle(padding = edges))
        val bytes = fixture('I', emptyList(), sections = listOf(Section(2, "", listOf(styled))))
        val start = Wire(true, true, true, true, true, true).apply {
            out.write("DPRI".toByteArray()); spans(emptyList()); u32(1); byte(2)
            string(""); string(""); string(""); u32(1)
        }.out.size()
        val presence = start + 26
        assertEquals(1, bytes[presence].toInt()); assertEquals(2, bytes[presence + 1].toInt())
        fun changed(index: Int, value: Int) = bytes.copyOf().apply { this[index] = value.toByte() }
        assertThrows(IllegalStateException::class.java) { decode(changed(presence, 2)) }
        for (mask in listOf(0, 4, 255)) assertThrows(IllegalArgumentException::class.java) { decode(changed(presence + 1, mask)) }
        assertThrows(IllegalStateException::class.java) { decode(changed(presence + 2, 2)) }
        for (value in listOf(-1f, Float.NaN, Float.POSITIVE_INFINITY)) {
            val invalid = bytes.copyOf(); val bits = value.toRawBits()
            repeat(4) { invalid[presence + 3 + it] = (bits ushr (it * 8)).toByte() }
            assertThrows(IllegalArgumentException::class.java) { decode(invalid) }
        }
        for (size in presence..presence + 21) assertThrows(IllegalArgumentException::class.java) { decode(bytes.copyOf(size)) }
        for (kind in listOf(1, 2, 5, 9, 10, 11, 12)) assertThrows(IllegalArgumentException::class.java) { decode(changed(start, kind)) }
        assertThrows(IllegalArgumentException::class.java) { decode(changed(start + 1, 1)) }
        assertThrows(IllegalArgumentException::class.java) { BlockStyle() }
        assertThrows(IllegalArgumentException::class.java) { styled.copy(listPath = "*") }
        assertThrows(IllegalArgumentException::class.java) { styled.copy(table = Table(emptyList(), emptyList())) }
        assertThrows(IllegalArgumentException::class.java) { styled.copy(feature = Feature("x", "", "", "", "")) }
        assertEquals(styled, decode(bytes).sections.single().blocks.single())
        assertEquals(styled.copy(number = "kept", level = 3),
            decode(fixture('I', emptyList(), sections = listOf(Section(2, "", listOf(styled.copy(number = "kept", level = 3)))))).sections.single().blocks.single())
    }

    @Test fun dprhRetainsNullableAdviceAcrossEverySinkAndAllInheritedGFields() {
        val values = listOf(
            Span("link", "Legacy", "page#inside", explanation = "Expansion", tooltip = null, targetFragment = ""),
            Span("text", "Suppressed", explanation = "Expansion", tooltip = "", fontScale = 0f, fontScaleBasis = FontScaleBasis.NormalBody),
            Span("external_link", "Authored", "https://example.invalid/", italic = true, background = "#ccffff", tooltip = "<literal> & \"quoted\"\nsecond line"),
            Span("link", "", "File:Asset.svg", image = InlineImage("Asset.svg", 15, alt = "Authored alt", tooltip = "Own image advice", border = true), tooltip = "Enclosing advice"))
        val paragraph = Block("paragraph", 0, values)
        val nested = Table(values, listOf(listOf(Cell(values, false, 1, 1))))
        val table = Table(values, listOf(listOf(Cell(values, false, 1, 1),
            Cell(emptyList(), false, 1, 1, nestedTable = nested),
            Cell(emptyList(), true, 1, 1, blocks = listOf(paragraph)))), style = TableStyle(floatSide = TableFloatSide.Left))
        val sections = listOf(Section(3, "Typed advice", listOf(paragraph,
            Block("table", 0, emptyList(), table = table, textAlign = CellTextAlign.Right))))
        val catalog = listOf(Media("Asset.svg", "image", "")) + List(279) { Media("Audio$it.ogg", "audio", "") }
        val entry = decode(fixture('H', listOf(Item(1, spans = values), Item(2, blocks = listOf(paragraph))),
            sections, values, values, catalog))
        val runs = buildList<List<Span>> {
            add(entry.displayTitle); add(entry.preamble)
            entry.sections.forEach { section -> section.blocks.forEach { it.visitSpanRuns { spans, _ -> if (spans.isNotEmpty()) add(spans) } } }
            entry.references.forEach { it.visitSpanRuns { spans, _ -> if (spans.isNotEmpty()) add(spans) } }
        }
        assertEquals(10, runs.size)
        runs.forEach { assertEquals(values, it) }
        assertEquals(10, entry.inlineImages.size)
        assertEquals(catalog, entry.media)
        assertEquals(table, entry.sections.single().blocks[1].table)
        assertEquals(CellTextAlign.Right, entry.sections.single().blocks[1].textAlign)
        assertEquals(listOf(null, "", values[2].tooltip, "Enclosing advice"), entry.displayTitle.map { it.tooltip })
    }

    @Test fun dprhRejectsInvalidPresenceTruncationUtf8AndOversizeWhileGStaysNullable() {
        val plain = Span("text", "x")
        assertEquals(37, Wire(true, true, true, true, true).apply { spans(listOf(Span("text", ""))) }.out.size() - 4)
        assertEquals(36, Wire(true, true, true, true).apply { spans(listOf(Span("text", ""))) }.out.size() - 4)
        assertNull(decode(fixture('H', emptyList(), display = listOf(Span("text", "")))).displayTitle.single().tooltip)
        val prefix = Wire(true, true, true, true).apply {
            out.write("DPRH".toByteArray(Charsets.US_ASCII)); spans(listOf(plain))
        }.out.size()
        val absent = fixture('H', emptyList(), display = listOf(plain))
        assertEquals(0, absent[prefix].toInt())
        val invalid = absent.copyOf(); invalid[prefix] = 2
        assertThrows(IllegalStateException::class.java) { decode(invalid) }
        assertThrows(IllegalArgumentException::class.java) { decode(absent.copyOf(prefix)) }
        val present = fixture('H', emptyList(), display = listOf(plain.copy(tooltip = "z")))
        assertEquals(1, present[prefix].toInt())
        assertThrows(IllegalArgumentException::class.java) { decode(present.copyOf(prefix + 3)) }
        val oversized = present.copyOf()
        repeat(4) { oversized[prefix + 1 + it] = ((32 * 1024 * 1024 + 1) ushr (it * 8)).toByte() }
        assertThrows(IllegalArgumentException::class.java) { decode(oversized) }
        val malformed = present.copyOf(); malformed[prefix + 5] = 0xff.toByte()
        assertThrows(java.nio.charset.CharacterCodingException::class.java) { decode(malformed) }
        val empty = decode(fixture('H', emptyList(), display = listOf(plain.copy(tooltip = ""))))
        assertEquals("", empty.displayTitle.single().tooltip)
        val old = fixture('G', emptyList(), display = listOf(plain))
        assertNull(decode(old).displayTitle.single().tooltip)
        assertEquals(old.toList(), fixture('G', emptyList(), display = listOf(plain.copy())).toList())
        val current = present.copyOf(); current[3] = 'K'.code.toByte()
        assertEquals(decode(present), decode(current))
        val unknown = present.copyOf(); unknown[3] = 0xff.toByte()
        assertThrows(IllegalArgumentException::class.java) { decode(unknown) }
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
        assertNotNull(decode(fixture('C', listOf(Item(1, blocks = listOf(nested(LegacyMaxTableDepth)))))))
        assertThrows(Exception::class.java) { decode(fixture('C', listOf(Item(1, blocks = listOf(nested(LegacyMaxTableDepth + 1)))))) }
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
        val occurrences = rasterImageOccurrences(entry).map { it.image }
        assertEquals(listOf("Vraagteken-2.svg", "X mark.svg", "Vraagteken-2.svg", "X mark.svg", "Yes check.svg",
            "X mark.svg", "Vraagteken-2.svg", "Yes check.svg", "Vraagteken-2.svg", "X mark.svg"), occurrences.map { it.file })
        assertNull(occurrences.first().alt)
        assertEquals("", occurrences[4].alt)
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
        val occurrences = rasterImageOccurrences(entry).map { it.image }
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

    @Test fun dpreRetainsBlockAlignmentNestedFloatsAndAllCanonicalDBorderFields() {
        val image = Span("link", "", "File:EU.svg", image = InlineImage("EU.svg", 13, 12, " ", " ", border = true),
            fontScale = 0f, fontScaleBasis = FontScaleBasis.NormalBody, foreground = "#123456")
        val numberBlocks = listOf(Block("paragraph", 0, listOf(Span("text", "one"))),
            Block("paragraph", 0, listOf(Span("text", "two", fontScale = 2f)), textAlign = CellTextAlign.Center),
            Block("paragraph", 0, listOf(Span("link", "three", "Target"))))
        val cell = Cell(emptyList(), false, 2, 1, blocks = numberBlocks,
            style = CellStyle(textAlign = CellTextAlign.Right))
        val px0 = StyleLength(StyleLengthUnit.Px, 0f)
        val margins = StyleEdges(px0, px0, px0, StyleLength(StyleLengthUnit.Px, 20f))
        val table = Table(emptyList(), listOf(listOf(cell)), style = TableStyle(margins = margins, floatSide = TableFloatSide.Right))
        val blocks = listOf(Block("table", 0, emptyList(), table = table),
            Block("paragraph", 0, listOf(image), textAlign = CellTextAlign.Left),
            heading("After", "After").copy(textAlign = CellTextAlign.Right))
        val items = listOf(Item(2, blocks = blocks, kind = ReferenceKind.Fragment))
        val sections = listOf(Section(2, "EU", blocks))
        assertThrows(IllegalArgumentException::class.java) { decode(fixture('E', items, sections)) }
        val media = listOf(Media("EU.svg", "image", ""))
        val encoded = fixture('E', items, sections, media = media)
        val entry = decode(encoded)
        assertEquals(media, entry.media)
        assertEquals(blocks, entry.sections.single().blocks)
        assertEquals(blocks, entry.references.single().blocks)
        assertEquals(listOf(null, CellTextAlign.Center, null), entry.sections.single().blocks[0].table!!.rows[0][0].blocks!!.map { it.textAlign })
        assertEquals(CellTextAlign.Right, entry.sections.single().blocks[0].table!!.rows[0][0].style!!.textAlign)
        assertTrue(entry.sections.single().blocks[1].spans.single().image!!.border)
        assertEquals(" ", entry.sections.single().blocks[1].spans.single().image!!.alt)
        assertEquals(TableFloatSide.Left, TableStyle(floatSide = TableFloatSide.Left).floatSide)
        // New fields are allowed on all block kinds; no consumer-invented kind restriction.
        for (kind in listOf("blank", "definition", "example", "quotation", "list_item", "list_detail", "indent", "term", "preformatted", "rule")) {
            val block = Block(kind, 0, emptyList(), textAlign = CellTextAlign.Center)
            assertEquals(block, decode(fixture('E', listOf(Item(1, blocks = listOf(block))))).references.single().blocks!!.single())
        }
    }

    @Test fun dpreKeepsLegacyDefaultsAndRejectsMalformedLayoutSuffixes() {
        val old = listOf(Block("paragraph", 0, listOf(Span("text", "Legacy"))))
        assertEquals(decode(fixture('D', listOf(Item(1, blocks = old)))).references,
            decode(fixture('E', listOf(Item(1, blocks = old)))).references)
        val marker = "E_tail"
        val block = Block("heading", 0, listOf(Span("text", "Aligned")), level = 3, anchorFallback = marker, textAlign = CellTextAlign.Center)
        val valid = fixture('E', listOf(Item(1, blocks = listOf(block))))
        assertEquals(block, decode(valid).references.single().blocks!!.single())
        fun locate(bytes: ByteArray, text: String): Int {
            val needle = text.toByteArray()
            return bytes.indices.single { it + needle.size <= bytes.size && bytes.copyOfRange(it, it + needle.size).contentEquals(needle) }
        }
        val suffix = locate(valid, marker) + marker.length
        for ((at, value) in listOf(suffix to 2, suffix + 1 to 3, suffix + 1 to 255)) {
            val bad = valid.copyOf(); bad[at] = value.toByte()
            assertThrows(Exception::class.java) { decode(bad) }
        }
        for (length in valid.indices) assertThrows(Exception::class.java) { decode(valid.copyOf(length)) }
        val table = Table(emptyList(), listOf(listOf(Cell(emptyList(), false, 1, 1))),
            style = TableStyle(background = "#123abc", floatSide = TableFloatSide.Right))
        val floated = fixture('E', listOf(Item(1, blocks = listOf(Block("table", 0, emptyList(), table = table)))))
        assertEquals(table, decode(floated).references.single().blocks!!.single().table)
        val color = locate(floated, "#123abc")
        for ((at, value) in listOf(color - 5 to 32, color + 7 to 2, color + 7 to 255)) {
            val bad = floated.copyOf(); bad[at] = value.toByte()
            assertThrows(Exception::class.java) { decode(bad) }
        }
        // C/D must not silently consume E's new table flag or suffix.
        for (version in listOf('C', 'D')) {
            val bad = floated.copyOf(); bad[3] = version.code.toByte()
            assertThrows(Exception::class.java) { decode(bad) }
        }
        val nullBlock = fixture('E', listOf(Item(1, blocks = listOf(Block("blank", 0, emptyList())))))
        // Even an empty E block needs its alignment presence byte.
        assertEquals(26, Wire(true, true, true).apply { block(Block("blank", 0, emptyList())) }.out.size())
        assertThrows(Exception::class.java) { decode(nullBlock.copyOf(nullBlock.size - 5)) }
    }

    @Test fun dprfPreservesSeparateComponentsAcrossRecursiveSinksAndInheritedLayout() {
        val links = listOf(Span("link", "legacy", "Page#Noun"),
            Span("link", "literal", "Special:Booksources/9780306406157#%23?&語", targetFragment = ""),
            Span("link", "fragment", "Page#literal", targetFragment = "Noun#語"),
            Span("link", "local", targetFragment = "reference-1"),
            Span("link", "", "File:Controlled.svg#literal", image = InlineImage("Controlled.svg", 20, border = true), targetFragment = "Caption"))
        val paragraph = Block("paragraph", 0, links, textAlign = CellTextAlign.Center)
        val inner = Table(links, listOf(listOf(Cell(links, false, 1, 1))))
        val outer = Table(links, listOf(listOf(Cell(links, false, 1, 1), Cell(emptyList(), false, 1, 1, nestedTable = inner),
            Cell(emptyList(), false, 1, 1, blocks = listOf(paragraph)))),
            style = TableStyle(floatSide = TableFloatSide.Right))
        val blocks = listOf(paragraph, Block("table", 0, emptyList(), table = outer))
        val sections = listOf(Section(2, "Body", blocks, "Body"))
        val items = listOf(Item(1, spans = links), Item(2, blocks = blocks),
            Item(3, spans = links, kind = ReferenceKind.Fragment), Item(4, blocks = blocks, kind = ReferenceKind.Fragment))
        val media = listOf(Media("Controlled.svg", "image", "caption"))
        for (version in "FG") {
            val catalog = if (version == 'F') media else media + List(279) { Media("Audio$it.ogg", "audio", "") }
            val entry = decode(fixture(version, items, sections, links, links, catalog))
            assertEquals(links, entry.displayTitle)
            assertEquals(links, entry.preamble)
            assertEquals(sections, entry.sections)
            assertEquals(listOf(Reference(1, 1, "notes", links), Reference(2, 1, "notes", emptyList(), blocks = blocks),
                Reference(3, null, "notes", links, ReferenceKind.Fragment),
                Reference(4, null, "notes", emptyList(), ReferenceKind.Fragment, blocks)), entry.references)
            assertEquals(catalog, entry.media)
        }
        val legacy = links.take(1)
        assertEquals(decode(fixture('E', emptyList(), display = legacy)).displayTitle,
            decode(fixture('F', emptyList(), display = legacy)).displayTitle)
    }

    @Test fun dprfRejectsInvalidKindPresenceTruncationAndLegacyRelabeling() {
        val span = Span("link", "label", "Title#literal", targetFragment = "")
        for (version in "FG") {
            val valid = fixture(version, emptyList(), display = listOf(span))
            val spanBytes = Wire(true, true, true, true).apply { spans(listOf(span)) }.out.size()
            val presence = 4 + spanBytes - 5
            assertEquals(1, valid[presence].toInt())
            for (tag in listOf(0, 2, 3)) {
                val bad = valid.copyOf(); bad[8] = tag.toByte()
                assertThrows(IllegalArgumentException::class.java) { decode(bad) }
            }
            for (value in listOf(2, 255)) {
                val bad = valid.copyOf(); bad[presence] = value.toByte()
                assertThrows(Exception::class.java) { decode(bad) }
            }
            val huge = valid.copyOf(); repeat(4) { huge[presence + 1 + it] = 0xff.toByte() }
            assertThrows(Exception::class.java) { decode(huge) }
            val utf8 = fixture(version, emptyList(), display = listOf(span.copy(targetFragment = "G")))
            utf8[presence + 5] = 0xff.toByte()
            assertThrows(Exception::class.java) { decode(utf8) }
            val legacy = valid.copyOf(); legacy[3] = 'E'.code.toByte()
            assertThrows(Exception::class.java) { decode(legacy) }
            for (length in valid.indices) assertThrows(Exception::class.java) { decode(valid.copyOf(length)) }
            assertThrows(Exception::class.java) { decode(valid + byteArrayOf(0)) }
        }
        // Count admission must include F's mandatory presence byte, even for an empty span.
        assertEquals(36, Wire(true, true, true, true).apply { spans(listOf(Span("link", ""))) }.out.size() - 4)
    }

    @Test fun dprgRetainsSharedCountByteAndStringBoundsWithoutASeparateCatalogCeiling() {
        val empty = fixture('G', emptyList())
        // The final u32 is the media count. Reject a hostile count before allocating its List.
        val huge = empty.copyOf()
        repeat(4) { huge[huge.size - 4 + it] = 0xff.toByte() }
        assertThrows(IllegalArgumentException::class.java) { decode(huge) }
        // Enough bytes for count(9), but one item beyond the inherited shared budget.
        val overBudget = (1 shl 20) + 1
        val exhausted = empty.copyOf(empty.size + 9 * overBudget)
        repeat(4) { exhausted[empty.size - 4 + it] = (overBudget ushr (it * 8)).toByte() }
        assertThrows(IllegalArgumentException::class.java) { decode(exhausted) }
        val truncated = fixture('G', emptyList(), media = listOf(Media("Asset.svg", "image", "")))
        assertThrows(IllegalArgumentException::class.java) { decode(truncated.copyOf(truncated.size - 1)) }
        val span = Span("link", "", "File:Asset.svg", image = InlineImage("Asset.svg", 30))
        val valid = fixture('G', emptyList(), display = listOf(span), media = listOf(Media("Asset.svg", "image", "")))
        assertEquals(span, decode(valid).displayTitle.single())
        // First span's text byte-length is directly after kind, role and flags.
        val oversized = valid.copyOf()
        repeat(4) { oversized[11 + it] = ((32 * 1024 * 1024 + 1) ushr (it * 8)).toByte() }
        assertThrows(IllegalArgumentException::class.java) { decode(oversized) }
        val unknown = valid.copyOf(); unknown[3] = 'K'.code.toByte()
        assertThrows(IllegalArgumentException::class.java) { decode(unknown) }
    }

    @Test fun typedCatalogCapacityIsVersionedAndCountsAudioWithoutCappingMediaOnlyEntries() {
        fun catalog(count: Int) = List(count) { Media("Asset$it.svg", "image", "caption$it") }
        fun spans(count: Int) = catalog(count).map { Span("link", "", "File:${it.file}", image = InlineImage(it.file, 30)) }
        for (version in "CD") {
            val expected = catalog(128)
            val bytes = fixture(version, emptyList(), display = spans(128), media = expected)
            assertEquals(expected, decode(bytes).media)
            assertEquals(spans(128), decode(bytes).displayTitle)
            assertThrows(IllegalArgumentException::class.java) {
                decode(fixture(version, emptyList(), display = spans(129), media = catalog(129)))
            }
        }
        for (version in "EF") for (count in listOf(128, 129, 193, 256)) {
            val entry = decode(fixture(version, emptyList(), display = spans(count), media = catalog(count)))
            assertEquals(catalog(count), entry.media)
            assertEquals(spans(count), entry.displayTitle)
            assertEquals(count, entry.inlineImages.size)
        }
        for (version in "EF") assertThrows(IllegalArgumentException::class.java) {
            decode(fixture(version, emptyList(), display = spans(257), media = catalog(257)))
        }
        for (count in listOf(256, 257, 280, 1025)) {
            val entry = decode(fixture('G', emptyList(), display = spans(count), media = catalog(count)))
            assertEquals(catalog(count), entry.media)
            assertEquals(spans(count), entry.displayTitle)
            assertEquals(count, entry.inlineImages.size)
        }
        val image = spans(1)
        fun mixed(count: Int) = catalog(1) + List(count - 1) { Media("Audio$it.ogg", "audio", "audio caption") }
        for ((version, limit) in listOf('C' to 128, 'D' to 128, 'E' to 256, 'F' to 256)) {
            assertEquals(mixed(limit), decode(fixture(version, emptyList(), display = image, media = mixed(limit))).media)
            assertThrows(IllegalArgumentException::class.java) {
                decode(fixture(version, emptyList(), display = image, media = mixed(limit + 1)))
            }
        }
        assertEquals(mixed(280), decode(fixture('G', emptyList(), display = image, media = mixed(280))).media)
        for (version in "BCDEFG") {
            assertEquals(catalog(257), decode(fixture(version, emptyList(), media = catalog(257))).media)
        }
    }

    @Test fun typedCatalogCapacityFindsEverySinkAndPreservesCatalogRejections() {
        val image = Span("link", "", "File:Asset.svg", image = InlineImage("Asset.svg", 30))
        val paragraph = Block("paragraph", 0, listOf(image))
        val media = listOf(Media("Asset.svg", "image", "caption")) + List(128) { Media("Audio$it.ogg", "audio", "") }
        fun section(block: Block) = listOf(Section(2, "Body", listOf(block)))
        fun atEverySink(version: Char, assets: List<Media>): List<ByteArray> = listOf(
            fixture(version, emptyList(), display = listOf(image), media = assets),
            fixture(version, emptyList(), preamble = listOf(image), media = assets),
            fixture(version, emptyList(), sections = section(paragraph), media = assets),
            fixture(version, emptyList(), sections = section(tableBlock(paragraph)), media = assets),
            fixture(version, emptyList(), sections = section(Block("table", 0, emptyList(),
                table = Table(listOf(image), listOf(listOf(Cell(emptyList(), false, 1, 1)))))), media = assets),
            fixture(version, emptyList(), sections = section(Block("table", 0, emptyList(),
                table = Table(emptyList(), listOf(listOf(Cell(listOf(image), false, 1, 1)))))), media = assets),
            fixture(version, emptyList(), sections = section(Block("table", 0, emptyList(),
                table = Table(emptyList(), listOf(listOf(Cell(emptyList(), false, 1, 1,
                    nestedTable = Table(emptyList(), listOf(listOf(Cell(listOf(image), false, 1, 1)))))))))), media = assets),
            fixture(version, listOf(Item(1, spans = listOf(image))), media = assets),
            fixture(version, listOf(Item(1, blocks = listOf(paragraph))), media = assets))
        atEverySink('E', media).forEach { bytes ->
            val entry = decode(bytes)
            assertEquals(media, entry.media)
            assertEquals(listOf(image.image!!), entry.inlineImages)
        }
        for (version in "CD") atEverySink(version, media).forEach { bytes ->
            assertThrows(IllegalArgumentException::class.java) { decode(bytes) }
        }
        for (bad in listOf(media.drop(1), media + media.first(), listOf(media.first().copy(kind = "audio")) + media.drop(1))) {
            atEverySink('E', bad).forEach { bytes -> assertThrows(IllegalArgumentException::class.java) { decode(bytes) } }
        }
        val large = media + List(151) { Media("Extra$it.ogg", "audio", "") }
        assertEquals(280, large.size)
        atEverySink('G', large).forEach { bytes ->
            val entry = decode(bytes)
            assertEquals(large, entry.media)
            assertEquals(listOf(image.image!!), entry.inlineImages)
        }
        for (version in "EF") atEverySink(version, large).forEach { bytes ->
            assertThrows(IllegalArgumentException::class.java) { decode(bytes) }
        }
        for (bad in listOf(large.drop(1), large + large.first(), listOf(large.first().copy(kind = "audio")) + large.drop(1))) {
            atEverySink('G', bad).forEach { bytes -> assertThrows(IllegalArgumentException::class.java) { decode(bytes) } }
        }
    }

    @Test fun controlledSourceCatalog280KeepsWidthsActionsAndBodyReferenceOrderWithoutNativeOutputClaim() {
        // Only names, source-first order and first explicit widths are authenticated by
        // source-media280.json SHA256866de9084a53a5f086b8d954c823d2a24ae27be00f813ee104c4024df7b06cab.
        // The following body, references and component actions are controlled wire data,
        // NOT a native-produced Ispanija catalog, body or Writer/Reader conformance result.
        val assets: List<Pair<String, Long?>> = listOf(
            "LocationSpain.png" to 250L,
            "Wikipedia-logo-v2-lt.svg" to 50L,
            "Flag of Lithuania.svg" to 45L,
            "Flag of Spain.svg" to 185L,
            "Spain CIA map.png" to 115L,
            "Toledo - 02.jpg" to 185L,
            "Flag of Aragon.svg" to 21L,
            "Flag of Asturias.svg" to 21L,
            "Flag of the Basque Country.svg" to 21L,
            "Flag of Extremadura, Spain (with coat of arms).svg" to 21L,
            "Flag of Galicia.svg" to 21L,
            "Flag of Catalonia.svg" to 21L,
            "Bandera de León.svg" to 21L,
            "Flag of the Valencian Community (2x3).svg" to 21L,
            "Flag of Žemaitija.svg" to 23L,
            "Flag of Latvia.svg" to 21L,
            "Unofficial Flag of Latgale.svg" to 21L,
            "Flag of Estonia.svg" to 21L,
            "Flag of the Livonians.svg" to 21L,
            "Võro lipp.png" to 21L,
            "Flag of Abazinia.svg" to 21L,
            "Flag of the Republic of Abkhazia.svg" to 21L,
            "Flag of the Nahuas.svg" to 21L,
            "Flag of Hidalgo.svg" to 21L,
            "Flag of San Luis Potosi.svg" to 21L,
            "Flag of Aceh, Indonesia.svg" to 21L,
            "Flag of Adygea.svg" to 21L,
            "Flag of South Africa.svg" to 21L,
            "Banner of the Qulla Suyu (1979).svg" to 21L,
            "Flag of Ireland.svg" to 21L,
            "Flag of Ashanti.svg" to 21L,
            "Flag of Albania.svg" to 21L,
            "Alemannische fahnevorschlag.png" to 21L,
            "flag of Ethiopia.svg" to 21L,
            "Flag blue.png" to null,
            "Flag of the United Kingdom.svg" to 21L,
            "Flag of Wessex.svg" to 21L,
            "Flag of the Arab League.svg" to 21L,
            "Flag of Egypt.svg" to 21L,
            "Flag of Saudi Arabia.svg" to 21L,
            "Flag of Morocco.svg" to 21L,
            "Flag of the Cooperation Council for the Arab States of the Gulf.svg" to 21L,
            "Flag of the Syriac-Aramaic People.svg" to 21L,
            "Flag of Armenia.svg" to 21L,
            "Flag of Western Armenia.svg" to 21L,
            "Drapeau arpitan.svg" to 21L,
            "Aromanian flag.svg" to 21L,
            "Flag of Awadh.svg" to 23L,
            "Avar flag (ethnic).svg" to 21L,
            "Flag of Azerbaijan.svg" to 21L,
            "Flag of South Azerbaijan.svg" to 21L,
            "Flag of Bali.svg" to 21L,
            "Flag of Belarus (1918, 1991–1995).svg" to 21L,
            "Flag of Bashkortostan.svg" to 21L,
            "Flag of Bavaria (lozengy).svg" to 21L,
            "Flag of Bangladesh.svg" to 21L,
            "Flag of Bicol.svg" to 21L,
            "Flag of Vanuatu.svg" to 21L,
            "Flag of Manipur.svg" to 21L,
            "Flag of India.svg" to 21L,
            "Flag of Bosnia and Herzegovina.svg" to 21L,
            "Flag of Bhutan.svg" to 21L,
            "Flag of Brittany.svg" to 21L,
            "Flag of Bulgaria.svg" to 21L,
            "Flag of Buryatia.svg" to 21L,
            "Flag of the Philippines.svg" to 21L,
            "Flag of Guam.svg" to 21L,
            "Flag of the Chechen Republic.svg" to 21L,
            "Flag of the Czech Republic.svg" to 21L,
            "Flag of the Cherokee Nation.svg" to 21L,
            "Roma flag.svg" to 21L,
            "Flag of the Romani people.svg" to 21L,
            "Flag of Chuvashia.svg" to 21L,
            "Flag of Denmark.svg" to 21L,
            "Flag of Nepal.svg" to 23L,
            "Flag of the Zhuang people.svg" to 21L,
            "Flag of Emilia.svg" to 21L,
            "Erzya Flag.svg" to 21L,
            "Flag of Esperanto.svg" to 21L,
            "Flag of the Ewe people.svg" to 21L,
            "Flag of the Faroe Islands.svg" to 21L,
            "Flag of Flanders.svg" to 21L,
            "Bandiere dal Friûl.svg" to 21L,
            "Frisian flag.svg" to 21L,
            "Nordfriesischeflagge.svg" to 21L,
            "DEU Saterland Flag.svg" to 21L,
            "Flag of Nigeria.svg" to 21L,
            "Flag of Gagauzia.svg" to 21L,
            "Flag of Gilaks.svg" to 21L,
            "Gothic flag.svg" to 21L,
            "Flag of Greece.svg" to 21L,
            "Flag of Pontus.svg" to 21L,
            "Owl of Minerva.svg" to 23L,
            "Flag of Greenland.svg" to 21L,
            "Guarani flag.svg" to 21L,
            "Flag of Haiti.svg" to 21L,
            "Flag of the Hausa people.svg" to 21L,
            "Flag of Hawaii.svg" to 21L,
            "Flag of Israel.svg" to 21L,
            "Flag of Fiji.svg" to 21L,
            "Hunsrik language flag.png" to 21L,
            "Flag of Ido.svg" to 21L,
            "Flag of Indonesia.svg" to 21L,
            "Flag of Ingushetia.svg" to 21L,
            "150px-Interlingua-Logo.png" to 21L,
            "Flag of Interlingue.svg" to 21L,
            "Flag of Nunavut.svg" to 21L,
            "Flag of Alaska.svg" to 21L,
            "Flag of Iceland.svg" to 21L,
            "Flag of Italy.svg" to 21L,
            "Flag of Sakha.svg" to 21L,
            "Flag of Jamaica.svg" to 21L,
            "Flag of Japan.svg" to 21L,
            "Proposed Yiddish flag.svg" to 21L,
            "Flag of the Yoruba people.svg" to 21L,
            "Flag of Kabardino-Balkaria.svg" to 21L,
            "Flag of Togo (3-2).svg" to 21L,
            "Flag of Kabyle.svg" to 21L,
            "Flag of Kalmykia.svg" to 21L,
            "Flag of the Kannada people.svg" to 21L,
            "Pampanga Flag.png" to 21L,
            "Flag of Karachay-Cherkessia and Kabardino-Balkaria.png" to 21L,
            "Flag of Karakalpakstan.svg" to 21L,
            "Flag of Georgia.svg" to 21L,
            "POL Kaszuby flag.svg" to 21L,
            "Flag of Kazakhstan.svg" to 21L,
            "Flag of Cambodia.svg" to 21L,
            "Flag of Rwanda.svg" to 21L,
            "Flag of Chinese language.png" to 21L,
            "Chinese Character \"史\" (Shi).png" to 23L,
            "Flag of the People's Republic of China.svg" to 21L,
            "Lang-zht.png" to 21L,
            "Taiwan-China.png" to 21L,
            "Flag of Kyrgyzstan.svg" to 21L,
            "Flag of Burundi.svg" to 21L,
            "Flag of Komi.svg" to 21L,
            "Flag of the Kingdom of Kongo according to Giovanni Cavazzi da Montecuccolo.svg" to 21L,
            "Flag of Goa.svg" to 21L,
            "Flag of South Korea.svg" to 21L,
            "Flag of Cornwall.svg" to 21L,
            "Flag of Corsica.svg" to 21L,
            "Flag of Transkei.svg" to 21L,
            "Flag of Kotava.svg" to 21L,
            "Flag of the Crimean Tatar people.svg" to 21L,
            "Flag of Croatia.svg" to 21L,
            "Flag of Kurdistan.svg" to 21L,
            "Ladino Flag.svg" to 21L,
            "Flag of Ladinia.svg" to 21L,
            "Flag of Laos.svg" to 21L,
            "Flag of Poland.svg" to 21L,
            "Lezgian flag.svg" to 21L,
            "Flag of Liguria.svg" to 21L,
            "Flag of Limburg (Netherlands).svg" to 21L,
            "Flag of Lingua Franca Nova.svg" to 21L,
            "Flag of Luxembourg.svg" to 21L,
            "Lojbanlogo.svg" to 21L,
            "Flag of Lombardy.svg" to 21L,
            "Vexilloid of the Roman Empire.svg" to 24L,
            "Flag of North Macedonia.svg" to 21L,
            "Flag of Madagascar.svg" to 21L,
            "..Kerala Flag(INDIA).png" to 21L,
            "Flag%20of%20Malaysia.svg" to 21L,
            "Flag of Maldives.svg" to 21L,
            "Flag of Malta.svg" to 21L,
            "Tino Rangatiratanga Maori sovereignty movement flag.svg" to 21L,
            "Flag of the Mapuches (1992).svg" to 21L,
            "Flag of Maharashtra.svg" to 21L,
            "Flag of Iran.svg" to 21L,
            "Flag of The Principality of Mingrelia (Portolan 1559).svg" to 21L,
            "Flag of the Isle of Mann.svg" to 21L,
            "Bandera otomí.png" to 21L,
            "Flag of Minang.svg" to 21L,
            "Pt-mdr1.png" to 23L,
            "Flag of Myanmar.svg" to 21L,
            "Flag of the Moksha people.svg" to 21L,
            "Flag of Mongolia.svg" to 21L,
            "Flag of Nauru.svg" to 21L,
            "Amended Navajo Nation Flag.jpg" to 21L,
            "Flag of Naples.svg" to 21L,
            "Flag of the Netherlands.svg" to 21L,
            "Flag of Normandie.svg" to 21L,
            "Flag of Norway.svg" to 21L,
            "Flag of Novial.svg" to 21L,
            "Bandera d'Orissa.svg" to 21L,
            "Flag of Occitania (with star).svg" to 21L,
            "Flag of Olonets.png" to 21L,
            "Flag of the Oromia Region.svg" to 21L,
            "Flag of North Ossetia.svg" to 21L,
            "Flag of Buddhism.svg" to 21L,
            "Flag-of-Khalistan.svg" to 21L,
            "Flag of Punjab.svg" to 21L,
            "Flag of Pangasinan.svg" to 21L,
            "Aruba-Curaçao-Caribbean Netherlands.png" to 21L,
            "Flag of Papua New Guinea.svg" to 21L,
            "Flag of Pennsylvania.svg" to 21L,
            "Flag of Komi-Permyak Okrug.svg" to 21L,
            "Flag of Afghanistan (2013–2021).svg" to 21L,
            "Palatinate Flag.png" to 21L,
            "Flag of Mari El.svg" to 21L,
            "Flag of Picardie.svg" to 21L,
            "Flag of the Pitcairn Islands.svg" to 21L,
            "Flag of Piedmont.svg" to 21L,
            "Flag of Portugal.svg" to 21L,
            "Flag of French Guiana.svg" to 21L,
            "Flag of France.svg" to 21L,
            "Flag of Afghanistan.svg" to 21L,
            "Proposed Flag of Romanchia.svg" to 21L,
            "Proposed flag of Romagna-(StGeorge Cross version).svg" to 21L,
            "Flag of Romania.svg" to 21L,
            "Rusyn flag.svg" to 21L,
            "Flag of Russia.svg" to 21L,
            "Flag of the Republic of China.svg" to 21L,
            "Sami flag.svg" to 21L,
            "Flag of Samoa.svg" to 21L,
            "Flag of the Central African Republic.svg" to 21L,
            "Red om symbol.png" to 23L,
            "Flag of Sardinia, Italy.svg" to 21L,
            "Bandera zapoteca.png" to 21L,
            "Cebuan Cross 2.jpg" to 21L,
            "Catedral Ortodoxa de San Jorge,Cuauhtémoc,Ciudad de México (10393670154).jpg" to 21L,
            "Raven Banner.svg" to 23L,
            "Flag of Serbia.svg" to 21L,
            "HR-BA-ME-RS flag.svg" to 21L,
            "Flag of Sicily.svg" to 21L,
            "Flag of Silesia.svg" to 21L,
            "Flag of Sindh.svg" to 21L,
            "Flag of Sri Lanka.svg" to 21L,
            "Flag of Slovakia.svg" to 21L,
            "Flag of Slovenia.svg" to 21L,
            "Flag of Somalia.svg" to 21L,
            "Upper Sorbian Flag.gif" to 21L,
            "Lower Sorbian Flag.gif" to 21L,
            "Flag of Lesotho.svg" to 21L,
            "Flag of Lebowa.svg" to 21L,
            "Flag of Suriname.svg" to 21L,
            "Flag of Swahili.gif" to 21L,
            "Flag of West Java (vectorised).svg" to 21L,
            "Flag of Finland.svg" to 21L,
            "Flag of Eswatini.svg" to 21L,
            "Flag of Northern Cheyenne.svg" to 21L,
            "Flag of Shan State.svg" to 21L,
            "Flag of Scotland.svg" to 21L,
            "Flag of Zimbabwe.svg" to 21L,
            "Flag of Sweden.svg" to 21L,
            "Flag of Tajikistan.svg" to 21L,
            "Flag of French Polynesia.svg" to 21L,
            "Flag of Thailand.svg" to 21L,
            "Tamil flag of World Tamil Confederation.svg" to 21L,
            "Flag of Telangana.svg" to 21L,
            "Flag of East Timor.svg" to 21L,
            "Flag of Tibet.svg" to 21L,
            "Flag of the Tigray Region.svg" to 21L,
            "Flag of Tonga.svg" to 21L,
            "Flag of Tatarstan.svg" to 21L,
            "Flag of Tsonga language.svg" to 21L,
            "Flag of Malawi.svg" to 21L,
            "Flag of Turkmenistan.svg" to 21L,
            "Flag of Turkey.svg" to 21L,
            "Flag of the Ottoman Empire (1844–1922).svg" to 21L,
            "Flag of Udmurtia.svg" to 21L,
            "Kokbayraq flag.svg" to 21L,
            "Flag of Ukraine.svg" to 21L,
            "Flag of Pakistan.svg" to 21L,
            "Flag of Uzbekistan.svg" to 21L,
            "Flag of Wallonia.svg" to 21L,
            "Flag of Wales (1959–present).svg" to 21L,
            "Flag of Venda (1973–1994).svg" to 21L,
            "Flag of Veneto.svg" to 21L,
            "Flag of Hungary.svg" to 21L,
            "Flag of Vepsia.svg" to 21L,
            "Flag of Mexico.svg" to 21L,
            "Flag of Vietnam.svg" to 21L,
            "Flag of Germany.svg" to 21L,
            "Noordlandflagg.svg" to 21L,
            "Intersaksische vlagge 3.svg" to 21L,
            "Flag of Volapük.svg" to 21L,
            "Flag of Senegal.svg" to 21L,
            "Flag of Zazaistan.svg" to 21L,
            "Flag of Zeeland.svg" to 21L,
            "Flag of the KwaZulu-Natal Province.png" to 21L,
        )
        assertEquals(280, assets.size)
        assertEquals(280, assets.map { it.first }.toSet().size)
        val media = assets.map { Media(it.first, "image", "") }
        val images = assets.mapIndexed { index, (file, width) ->
            Span("link", "", "File:$file", image = InlineImage(file, width),
                targetFragment = when (index % 3) { 0 -> null; 1 -> ""; else -> "Controlled#fragment" })
        }
        val blocks = images.mapIndexed { index, image ->
            Block("paragraph", 0, listOf(Span("text", "Controlled row ${index + 1}: "), image))
        }
        val note = listOf(Block("paragraph", 0, listOf(Span("text", "Controlled note: "), images.last())))
        val back = listOf(Span("link", "Controlled back", "Ispanija", targetFragment = "controlled-section"))
        val sections = listOf(Section(2, "Controlled catalog", blocks, "controlled-section"))
        val items = listOf(Item(1, blocks = note), Item(2, spans = back, kind = ReferenceKind.Fragment))
        val entry = decode(fixture('G', items, sections, media = media))
        assertEquals(media, entry.media)
        assertEquals(sections, entry.sections)
        assertEquals(listOf(Reference(1, 1, "notes", emptyList(), blocks = note),
            Reference(2, null, "notes", back, ReferenceKind.Fragment)), entry.references)
        assertEquals(images.map { it.image!! } + images.last().image!!, entry.inlineImages)
        assertEquals(assets.map { it.second }, entry.sections.single().blocks.map { it.spans.last().image!!.widthPx })
        assertEquals(images.map { it.entryLink() }, entry.sections.single().blocks.map { it.spans.last().entryLink() })
        assertEquals("Controlled row 280: ", entry.sections.single().blocks.last().spans.first().text)
        // An otherwise identical F document must retain its historical typed catalog bound.
        assertThrows(IllegalArgumentException::class.java) { decode(fixture('F', items, sections, media = media)) }
    }

    @Test fun controlledSourceFlagOrder193AndReferencesSurviveEWithoutNativeOutputClaim() {
        // Controlled wire fixture, NOT a native-produced DE document. Names/order are
        // authenticated against source-diagnosis01.json SHA25644e0df97165f226ef55e1f9d631f940cb99b97ce5971ccb2465e31ac1a67bb6c.
        // Full captured reference/body conservation remains a genuine Writer/Reader obligation.
        val files = listOf(
            "Flag of Afghanistan.svg",
            "Flag of Albania.svg",
            "Flag of Algeria.svg",
            "Flag of Andorra.svg",
            "Flag of Angola.svg",
            "Flag of Antigua and Barbuda.svg",
            "Flag of Saudi Arabia.svg",
            "Flag of Argentina.svg",
            "Flag of Armenia.svg",
            "Flag of Australia.svg",
            "Flag of Austria.svg",
            "Flag of Azerbaijan.svg",
            "Flag of the Bahamas.svg",
            "Flag of Bahrain.svg",
            "Flag of Bangladesh.svg",
            "Flag of Barbados.svg",
            "Flag of Belgium.svg",
            "Flag of Belize.svg",
            "Flag of Benin.svg",
            "Flag of Bhutan.svg",
            "Flag of Belarus.svg",
            "Flag of Myanmar.svg",
            "Flag of Bolivia.svg",
            "Flag of Bosnia and Herzegovina.svg",
            "Flag of Botswana.svg",
            "Flag of Brazil.svg",
            "Flag of Brunei.svg",
            "Flag of Bulgaria.svg",
            "Flag of Burkina Faso.svg",
            "Flag of Burundi.svg",
            "Flag of Chile.svg",
            "Flag of the People's Republic of China.svg",
            "Flag of Croatia.svg",
            "Flag of Cyprus.svg",
            "Flag of Chad.svg",
            "Flag of Montenegro.svg",
            "Flag of the Czech Republic.svg",
            "Flag of Denmark.svg",
            "Flag of the Democratic Republic of the Congo.svg",
            "Flag of Dominica.svg",
            "Flag of the Dominican Republic.svg",
            "Flag of Djibouti.svg",
            "Flag of Egypt.svg",
            "Flag of Ecuador.svg",
            "Flag of Eritrea.svg",
            "Flag of Estonia.svg",
            "Flag of Ethiopia.svg",
            "Flag of Fiji.svg",
            "Flag of Philippines.svg",
            "Flag of Finland.svg",
            "Flag of France.svg",
            "Flag of Gabon.svg",
            "Flag of The Gambia.svg",
            "Flag of Ghana.svg",
            "Flag of Greece.svg",
            "Flag of Grenada.svg",
            "Flag of Georgia.svg",
            "Flag of Guyana.svg",
            "Flag of Guatemala.svg",
            "Flag of Guinea.svg",
            "Flag of Guinea-Bissau.svg",
            "Flag of Equatorial Guinea.svg",
            "Flag of Haiti.svg",
            "Flag of Spain.svg",
            "Flag of the Netherlands.svg",
            "Flag of India.svg",
            "Flag of Indonesia.svg",
            "Flag of Iraq.svg",
            "Flag of Iran.svg",
            "Flag of Ireland.svg",
            "Flag of Iceland.svg",
            "Flag of Israel.svg",
            "Flag of Jamaica.svg",
            "Flag of Japan.svg",
            "Flag of Yemen.svg",
            "Flag of Jordan.svg",
            "Flag of Cambodia.svg",
            "Flag of Cameroon.svg",
            "Flag of Canada.svg",
            "Flag of Qatar.svg",
            "Flag of Kazakhstan.svg",
            "Flag of Kenya.svg",
            "Flag of Kyrgyzstan.svg",
            "Flag of Kiribati.svg",
            "Flag of Colombia.svg",
            "Flag of the Comoros.svg",
            "Flag of the Republic of the Congo.svg",
            "Flag of South Korea.svg",
            "Flag of North Korea.svg",
            "Flag of Costa Rica.svg",
            "Flag of Cuba.svg",
            "Flag of Kuwait.svg",
            "Flag of Laos.svg",
            "Flag of Lesotho.svg",
            "Flag of Lebanon.svg",
            "Flag of Liberia.svg",
            "Flag of Libya.svg",
            "Flag of Liechtenstein.svg",
            "Flag of Lithuania.svg",
            "Flag of Luxembourg.svg",
            "Flag of Latvia.svg",
            "Flag of North Macedonia.svg",
            "Flag of Madagascar.svg",
            "Flag of Malawi.svg",
            "Flag of Maldives.svg",
            "Flag of Malaysia.svg",
            "Flag of Mali.svg",
            "Flag of Malta.svg",
            "Flag of Morocco.svg",
            "Flag of Mauritania.svg",
            "Flag of Mauritius.svg",
            "Flag of Mexico.svg",
            "Flag of Federated States of Micronesia.svg",
            "Flag of Moldova.svg",
            "Flag of Monaco.svg",
            "Flag of Mongolia.svg",
            "Flag of Mozambique.svg",
            "Flag of Namibia.svg",
            "Flag of Nauru.svg",
            "Flag of Nepal.svg",
            "Flag of Germany.svg",
            "Flag of Niger.svg",
            "Flag of Nigeria.svg",
            "Flag of Nicaragua.svg",
            "Flag of Norway.svg",
            "Flag of New Zealand.svg",
            "Flag of Oman.svg",
            "Flag of Pakistan.svg",
            "Flag of Palau.svg",
            "Flag of Panama.svg",
            "Flag of Papua New Guinea.svg",
            "Flag of Paraguay.svg",
            "Flag of Peru.svg",
            "Flag of Poland.svg",
            "Flag of Portugal.svg",
            "Flag of South Africa.svg",
            "Flag of the Central African Republic.svg",
            "Flag of Cape Verde (10-17).svg",
            "Flag of Russia.svg",
            "Flag of Romania.svg",
            "Flag of Rwanda.svg",
            "Flag of Saint Kitts and Nevis.svg",
            "Flag of Saint Lucia.svg",
            "Flag of Saint Vincent and the Grenadines.svg",
            "Flag of El Salvador.svg",
            "Flag of Samoa.svg",
            "Flag of San Marino.svg",
            "Flag of Senegal.svg",
            "Flag of Serbia.svg",
            "Flag of the Seychelles.svg",
            "Flag of Sierra Leone.svg",
            "Flag of Singapore.svg",
            "Flag of Slovakia.svg",
            "Flag of Slovenia.svg",
            "Flag of Somalia.svg",
            "Flag of Sri Lanka.svg",
            "Flag of the United States.svg",
            "Flag of Swaziland.svg",
            "Flag of Sudan.svg",
            "Flag of Suriname.svg",
            "Flag of Syria.svg",
            "Flag of Switzerland.svg",
            "Flag of Sweden.svg",
            "Flag of Tajikistan.svg",
            "Flag of the Republic of China.svg",
            "Flag of Thailand.svg",
            "Flag of Tanzania.svg",
            "Flag of East Timor.svg",
            "Flag of Togo (3-2).svg",
            "Flag of Tonga.svg",
            "Flag of Trinidad and Tobago.svg",
            "Flag of Tunisia.svg",
            "Flag of Turkey.svg",
            "Flag of Turkmenistan.svg",
            "Flag of Tuvalu.svg",
            "Flag of Uganda.svg",
            "Flag of Ukraine.svg",
            "Flag of Uruguay.svg",
            "Flag of Uzbekistan.svg",
            "Flag of Vanuatu.svg",
            "Flag of the Vatican City.svg",
            "Flag of Venezuela.svg",
            "Flag of Hungary.svg",
            "Flag of the United Kingdom.svg",
            "Flag of Vietnam.svg",
            "Flag of Italy.svg",
            "Flag of Cote d'Ivoire.svg",
            "Flag of the Marshall Islands.svg",
            "Flag of the Solomon Islands.svg",
            "Flag of Sao Tome and Principe.svg",
            "Flag of Zambia.svg",
            "Flag of Zimbabwe.svg",
            "Flag of the United Arab Emirates.svg"
        )
        assertEquals(193, files.size)
        assertEquals(193, files.toSet().size)
        val flags = files.map { Span("link", "", "File:$it", image = InlineImage(it, 30)) }
        val rows = flags.mapIndexed { index, flag -> listOf(Cell(listOf(flag, Span("text", " row ${index + 1}")), false, 1, 1)) }
        val table = Block("table", 0, emptyList(), table = Table(emptyList(), rows))
        val sections = listOf(Section(2, "Controlled flags", listOf(table)))
        val reference = listOf(Span("external_link", "Retained reference", "https://example.org/reference", role = "reference"))
        val media = files.map { Media(it, "image", "") }
        val entry = decode(fixture('E', listOf(Item(1, spans = reference)), sections = sections, media = media))
        assertEquals(sections, entry.sections)
        assertEquals(media, entry.media)
        assertEquals(files, entry.inlineImages.map { it.file })
        assertTrue(entry.inlineImages.all { it.widthPx == 30L && it.heightPx == null })
        assertEquals(listOf(Reference(1, 1, "notes", reference, ReferenceKind.Note)), entry.references)
    }

}
