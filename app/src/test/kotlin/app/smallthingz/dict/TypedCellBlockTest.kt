package app.smallthingz.dict

import org.junit.Assert.*
import org.junit.Test
import java.io.ByteArrayOutputStream

/** Independent wire fixtures; these are not producer interoperability results. */
class TypedCellBlockTest {
    private fun text(value: String) = listOf(Span("text", value))
    private fun grid(blocks: List<Block>?, background: String? = null) =
        Table(emptyList(), listOf(listOf(Cell(emptyList(), true, 1, 1, background, blocks = blocks))))
    private fun entry(table: Table) = Entry("fixture", text("fixture"), "language", "English", "en",
        listOf(Section(1, "Meaning", listOf(Block("table", 0, emptyList(), table = table)), "Meaning")),
        listOf(Reference(1, 1, "", text("reference"))))

    /** DPR8 append location is encoded independently of BlobDecoder. */
    private class Wire(val version: Int = 8, val mixed: Boolean = false, val invalidPresence: Int? = null,
                       val oversizedBlockCount: Boolean = false) {
        val out = ByteArrayOutputStream()
        fun byte(value: Int) { out.write(value) }
        fun u16(value: Int) { repeat(2) { byte(value ushr (8 * it)) } }
        fun u32(value: Long) { repeat(4) { byte((value ushr (8 * it)).toInt()) } }
        fun string(value: String) { val bytes = value.toByteArray(); u32(bytes.size.toLong()); out.write(bytes) }
        fun spans(values: List<Span>) {
            u32(values.size.toLong())
            values.forEach { span ->
                byte(listOf("text", "link", "external_link", "line_break").indexOf(span.kind))
                byte(listOf("normal", "label", "pronunciation", "headword", "example", "quotation", "citation", "reference").indexOf(span.role))
                byte((if (span.bold) 1 else 0) or (if (span.italic) 2 else 0) or (if (span.code) 4 else 0) or
                    (if (span.small) 8 else 0) or (if (span.superscript) 16 else 0) or (if (span.subscript) 32 else 0) or
                    (if (span.strike) 64 else 0) or (if (span.underline) 128 else 0))
                listOf(span.text, span.target, span.trail, span.language, span.classes, span.direction).forEach(::string)
                if (version >= 3) string(span.explanation)
                if (version >= 4) { byte(if (span.foreground == null) 0 else 1); span.foreground?.let(::string) }
                if (version >= 6) { byte(if (span.background == null) 0 else 1); span.background?.let(::string) }
            }
        }
        fun table(value: Table?) {
            byte(if (value == null) 0 else 1)
            if (value == null) return
            if (version >= 7) {
                val g = value.geometry
                byte((if (g?.border != null) 1 else 0) or (if (g?.cellSpacing != null) 2 else 0) or
                    (if (g?.cellPadding != null) 4 else 0) or (if (g?.width != null) 8 else 0))
                g?.border?.let(::u16); g?.cellSpacing?.let(::u16); g?.cellPadding?.let(::u16)
                g?.width?.let { byte(if (it.unit == TableWidthUnit.Percent) 1 else 0); u32(it.value) }
            }
            spans(value.caption); u32(value.rows.size.toLong())
            value.rows.forEach { row -> u32(row.size.toLong()); row.forEach { cell ->
                byte(if (cell.header) 1 else 0); u16(cell.colspan); u16(cell.rowspan)
                if (version >= 4) { byte(if (cell.background == null) 0 else 1); cell.background?.let(::string) }
                spans(if (mixed && cell.blocks != null) listOf(Span("text", "mixed")) else cell.spans)
                if (version >= 7) table(cell.nestedTable)
                if (version >= 8) {
                    byte(invalidPresence ?: if (cell.blocks == null) 0 else 1)
                    cell.blocks?.let { blocks ->
                        if (oversizedBlockCount) {
                            u32((1 shl 20).toLong()); out.write(ByteArray(25 * (1 shl 20)))
                        } else { u32(blocks.size.toLong()); blocks.forEach(::block) }
                    }
                }
            } }
        }
        fun block(value: Block) {
            byte(listOf("paragraph", "blank", "definition", "example", "quotation", "list_item", "list_detail", "indent", "term", "heading", "preformatted", "rule", "table").indexOf(value.kind))
            byte(value.depth); byte(value.level); spans(value.spans)
            byte(if (value.feature == null) 0 else 1)
            value.feature?.let { listOf(it.kind, it.language, it.data, it.tailKind, it.tail).forEach(::string) }
            string(value.listPath); string(value.number); table(value.table)
            if (version >= 5) { string(value.anchor); string(value.anchorFallback) }
        }
        fun entry(value: Table): ByteArray {
            out.write("DPR$version".toByteArray()); spans(emptyList()); u32(1); byte(1); string("Meaning")
            if (version >= 5) { string("Meaning"); string("") }
            u32(1); block(Block("table", 0, emptyList(), table = value))
            spans(emptyList()); repeat(4) { u32(0) }
            return out.toByteArray()
        }
    }
    private fun decode(bytes: ByteArray) = BlobDecoder.decode(bytes, "fixture", "language", "English", "en")
    private fun decodedTable(bytes: ByteArray) = decode(bytes).sections.single().blocks.single().table!!

    @Test fun orderedBlocksRetainFullMetadataAndNullDiffersFromPresentEmpty() {
        val styled = Span("link", "abbr.", target = "target", trail = " ", language = "ar", classes = "fixture",
            direction = "rtl", bold = true, italic = true, underline = true, role = "label", explanation = "Expanded",
            foreground = "#ffffff", background = "#000000")
        val child = Table(text("child"), listOf(listOf(Cell(text("leaf"), false, 1, 1))),
            TableGeometry(border = 1, width = TableWidth(TableWidthUnit.Percent, 100)))
        val blocks = listOf(Block("paragraph", 0, text("before")),
            Block("heading", 2, listOf(styled), level = 4, anchor = "Cell_ID", anchorFallback = "Cell_ID_2"),
            Block("list_item", 2, text("item"), listPath = "ul/ol", number = "3"),
            Block("rule", 0, emptyList()), Block("table", 1, emptyList(), table = child,
                feature = Feature("fixture", "en", "data", "text", "tail")), Block("paragraph", 0, text("after")))
        val expected = grid(blocks, "#000000")
        assertEquals(expected, decodedTable(Wire().entry(expected)))
        val payload = Wire().entry(expected)
        val alias = ByteArrayOutputStream()
        fun byte(value: Int) { alias.write(value) }
        fun u32(value: Int) { repeat(4) { byte(value ushr (8 * it)) } }
        fun field(bytes: ByteArray) {
            var size = bytes.size
            do { byte((size and 127) or if (size > 127) 128 else 0); size = size ushr 7 } while (size != 0)
            alias.write(bytes)
        }
        alias.write("DAL1".toByteArray()); u32(0); byte(1); byte(1); u32(0); byte(1)
        listOf("fixture", "fixture", "target", "target", "target", "Cell_ID").forEach { field(it.toByteArray()) }
        field(payload)
        assertEquals(expected, AliasDecoder.decode(alias.toByteArray(), "1\tfixture").entry().sections.single().blocks.single().table)
        val empty = decodedTable(Wire().entry(grid(emptyList()))).rows.single().single()
        assertEquals(emptyList<Block>(), empty.blocks); assertTrue(empty.spans.isEmpty()); assertNull(empty.nestedTable)
        for (version in 2..8) assertNull(decodedTable(Wire(version).entry(grid(null))).rows.single().single().blocks)
    }

    @Test fun malformedOrderedCellContentAndTruncatedPresenceAreRejected() {
        val table = grid(listOf(Block("paragraph", 0, text("body"))))
        assertThrows(Exception::class.java) { decodedTable(Wire(mixed = true).entry(table)) }
        assertThrows(Exception::class.java) { decodedTable(Wire(invalidPresence = 2).entry(table)) }
        assertThrows(Exception::class.java) { Cell(text("mixed"), false, 1, 1, blocks = emptyList()) }
        assertThrows(Exception::class.java) { Cell(emptyList(), false, 1, 1, nestedTable = grid(null), blocks = emptyList()) }
        val bytes = Wire().entry(table)
        for (length in listOf(4, bytes.size / 2, bytes.size - 1)) assertThrows(Exception::class.java) { decodedTable(bytes.copyOf(length)) }
        assertThrows(Exception::class.java) { decodedTable(Wire(oversizedBlockCount = true).entry(grid(emptyList()))) }
    }

    @Test fun mixedLegacyAndBlockTableDepthUsesOneSharedLimit() {
        fun chain(depth: Int): Table {
            if (depth == 1) return grid(listOf(Block("paragraph", 0, text("leaf"))))
            val child = chain(depth - 1)
            return if (depth % 2 == 0) grid(listOf(Block("table", 0, emptyList(), table = child)))
                else Table(emptyList(), listOf(listOf(Cell(emptyList(), false, 1, 1, nestedTable = child))))
        }
        assertEquals(chain(16), decodedTable(Wire().entry(chain(16))))
        assertThrows(Exception::class.java) { decodedTable(Wire().entry(chain(17))) }
        assertNotNull(tableRenderMetrics(chain(16), 1, 0, 1, 1f))
        assertNull(tableRenderMetrics(chain(17), 1, 0, 1, 1f))
    }

    @Test fun headingNavigationKeepsAuthoredPathsAmbiguityAndCompiledReferencePrecedence() {
        val heading = Block("heading", 1, text("Cell heading"), level = 3, anchor = "reference-1", anchorFallback = "Cell_heading")
        val nested = grid(listOf(Block("paragraph", 0, text("before")), heading, Block("paragraph", 0, text("after"))))
        val value = entry(nested)
        val destination = checkNotNull(headingDestination(value, "#reference-1"))
        assertEquals("block-0-0", destination.rowKey)
        assertEquals("block-0-0/table/cell-0/block-1", destination.path)
        assertTrue(destination.compiledId)
        assertEquals(destination, headingDestination(value, "#Cell heading"))
        assertEquals(destination.rowKey, headingScrollKey(value, "#Cell_heading"))
        assertNull(headingDestination(entry(grid(listOf(heading, heading))), "#reference-1"))
        val empty = heading.copy(spans = emptyList(), anchor = "empty", anchorFallback = "")
        assertNotNull(headingDestination(entry(grid(listOf(empty))), "#empty"))
        val legacy = heading.copy(anchor = "", anchorFallback = "")
        assertFalse(checkNotNull(headingDestination(entry(grid(listOf(legacy))), "#Cell_heading")).compiledId)
        assertEquals("block-0-0/table/cell-0/block-0/table/cell-0/block-1",
            headingDestination(entry(grid(listOf(Block("table", 0, emptyList(), table = nested)))), "#reference-1")!!.path)
    }

    @Test fun traversalCompactionAndWidthsRetainAuthoritativeOrderAndLiteralWhitespace() {
        val marked = Span("link", "abbr.", target = "target", explanation = "Expanded")
        val literal = listOf(Span("text", "  literal  "), Span("line_break", ""), Span("line_break", ""))
        val child = Table(text("caption"), listOf(listOf(Cell(text("leaf"), false, 1, 1))),
            TableGeometry(width = TableWidth(TableWidthUnit.Px, 220)))
        val blocks = listOf(Block("paragraph", 0, listOf(Span("text", " "), marked, Span("text", " "))),
            Block("preformatted", 0, literal), Block("table", 2, emptyList(), table = child),
            Block("paragraph", 0, text("after")))
        val value = entry(grid(blocks))
        val compact = value.readingRows.first { it.block != null }.block!!.table!!
        val runs = mutableListOf<Pair<List<Span>, Boolean>>()
        compact.visitSpanRuns { spans, preserve -> if (spans.isNotEmpty()) runs.add(spans to preserve) }
        assertEquals(listOf("abbr.", "literal", "caption", "leaf", "after"), runs.map { textOf(it.first) })
        assertEquals(literal, runs[1].first); assertTrue(runs[1].second)
        assertEquals(1, value.abbreviations.size)
        assertTrue(value.abbreviations.single().context.contains("Table 1, 1 · Block 1"))
        val metrics = checkNotNull(tableRenderMetrics(compact, 1, 2, 1, 1f))
        assertTrue(metrics.width >= 220 + blockIndentDp(blocks[2]) + 4)
        assertEquals(emptyList<Block>(), entry(grid(emptyList())).readingRows.first { it.block != null }
            .block!!.table!!.rows.single().single().blocks)
    }
}
