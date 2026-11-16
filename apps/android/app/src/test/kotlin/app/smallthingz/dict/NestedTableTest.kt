package app.smallthingz.dict

import org.junit.Assert.*
import org.junit.Test
import java.io.ByteArrayOutputStream

class NestedTableTest {
    private fun cell(text: String = "", header: Boolean = false, colspan: Int = 1,
                     background: String? = null, child: Table? = null) =
        Cell(if (text.isEmpty()) emptyList() else listOf(Span("text", text)), header, colspan, 1, background, child)

    private fun fourGrids(): Table = Table(emptyList(), listOf(List(4) { index ->
        cell(child = Table(listOf(Span("text", "Group $index")), listOf(
            listOf(cell("Title $index", header = true, colspan = 5)),
            listOf(cell(header = true, background = "#800080"), cell("a"), cell("b"), cell("c")),
        ) + List(5) { row -> List(4) { column -> cell("$index:$row:$column") } },
            TableGeometry(border = 1, cellPadding = 2, width = TableWidth(TableWidthUnit.Percent, 100))))
    }), TableGeometry(border = 0, cellSpacing = 15))

    /** An independent little-endian wire writer, including all DPR6 fields before DPR7 additions. */
    private fun wire(table: Table, version: Int = 7, flagsOverride: Int? = null,
                     widthUnitOverride: Int? = null, widthValueOverride: Long? = null,
                     mixedChildSpans: Boolean = false, rowCountOverride: Int? = null): ByteArray {
        val out = ByteArrayOutputStream()
        fun byte(value: Int) { out.write(value) }
        fun u16(value: Int) { repeat(2) { byte(value ushr (8 * it)) } }
        fun u32(value: Long) { repeat(4) { byte((value ushr (8 * it)).toInt()) } }
        fun string(value: String) { val bytes = value.toByteArray(Charsets.UTF_8); u32(bytes.size.toLong()); out.write(bytes) }
        fun spans(values: List<Span>) {
            u32(values.size.toLong())
            values.forEach { span ->
                byte(listOf("text", "link", "external_link", "line_break").indexOf(span.kind)); byte(0); byte(0)
                listOf(span.text, span.target, span.trail, span.language, span.classes, span.direction).forEach(::string)
                if (version >= 3) string(span.explanation)
                if (version >= 4) { byte(if (span.foreground == null) 0 else 1); span.foreground?.let(::string) }
                if (version >= 6) { byte(if (span.background == null) 0 else 1); span.background?.let(::string) }
            }
        }
        fun writeTable(value: Table?, depth: Int) {
            byte(if (value == null) 0 else 1)
            if (value == null) return
            if (version >= 7) {
                val geometry = value.geometry
                val flags = if (depth == 1 && flagsOverride != null) flagsOverride else
                    (if (geometry?.border != null) 1 else 0) or
                    (if (geometry?.cellSpacing != null) 2 else 0) or
                    (if (geometry?.cellPadding != null) 4 else 0) or
                    (if (geometry?.width != null) 8 else 0)
                byte(flags)
                if (flags and 1 != 0) u16(geometry?.border ?: 0)
                if (flags and 2 != 0) u16(geometry?.cellSpacing ?: 0)
                if (flags and 4 != 0) u16(geometry?.cellPadding ?: 0)
                if (flags and 8 != 0) {
                    byte(if (depth == 1 && widthUnitOverride != null) widthUnitOverride else
                        if (geometry?.width?.unit == TableWidthUnit.Percent) 1 else 0)
                    u32(if (depth == 1 && widthValueOverride != null) widthValueOverride else geometry?.width?.value ?: 0)
                }
            }
            spans(value.caption)
            if (depth == 1 && rowCountOverride != null) {
                u32(rowCountOverride.toLong()); out.write(ByteArray(rowCountOverride * 4)); return
            }
            u32(value.rows.size.toLong())
            value.rows.forEach { row ->
                u32(row.size.toLong())
                row.forEach { item ->
                    byte(if (item.header) 1 else 0); u16(item.colspan); u16(item.rowspan)
                    if (version >= 4) { byte(if (item.background == null) 0 else 1); item.background?.let(::string) }
                    spans(if (mixedChildSpans && item.nestedTable != null) listOf(Span("text", "not empty")) else item.spans)
                    if (version >= 7) writeTable(item.nestedTable, depth + 1)
                }
            }
        }
        out.write("DPR$version".toByteArray(Charsets.US_ASCII))
        spans(listOf(Span("text", "fixture")))
        u32(1); byte(1); string("Tables")
        if (version >= 5) { string(""); string("") }
        u32(1); byte(12); byte(0); byte(0); spans(emptyList()); byte(0); string(""); string("")
        writeTable(table, 1)
        if (version >= 5) { string(""); string("") }
        spans(emptyList()); repeat(4) { u32(0) }
        return out.toByteArray()
    }
    private fun decode(bytes: ByteArray) = BlobDecoder.decode(bytes, "fixture", "language", "English", "en")
    private fun decodedTable(bytes: ByteArray) = decode(bytes).sections.single().blocks.single().table!!

    @Test fun legacyAndAbsentExtensionKeepTheSameModelAndNativeDefaults() {
        val table = Table(emptyList(), listOf(listOf(cell("one"), cell("two"))))
        for (version in 2..7) {
            val decoded = decodedTable(wire(table, version))
            assertEquals(table, decoded)
            val metrics = checkNotNull(tableRenderMetrics(decoded, 136, 10, 40, 1f))
            assertEquals(TableRenderMetrics(136, 10, 0, 0, 40, 272), metrics)
        }
        val zero = table.copy(geometry = TableGeometry(border = 0, cellSpacing = 0, cellPadding = 0,
            width = TableWidth(TableWidthUnit.Px, 0)))
        assertEquals(zero, decodedTable(wire(zero)))
        assertEquals(0, checkNotNull(tableRenderMetrics(zero, 136, 10, 40, 1f)).cellPadding)
        assertEquals(10, checkNotNull(tableRenderMetrics(table.copy(geometry = TableGeometry(width =
            TableWidth(TableWidthUnit.Px, 0))), 136, 10, 40, 1f)).cellPadding)
    }

    @Test fun exactFourNestedGridsKeepEmptyPaintedHeadersAndImplicitFifthColumn() {
        val expected = fourGrids()
        val decoded = decodedTable(wire(expected))
        assertEquals(expected, decoded)
        assertEquals(4, tableGrid(decoded).columns)
        decoded.rows.single().forEach { outerCell ->
            assertTrue(outerCell.spans.isEmpty())
            val child = outerCell.nestedTable!!
            val grid = tableGrid(child)
            assertEquals(7, grid.rows); assertEquals(5, grid.columns)
            assertEquals(5, grid.cells.first().colspan)
            assertEquals(4, child.rows[1].size)
            assertTrue(child.rows[1][0].spans.isEmpty())
            assertEquals("#800080", child.rows[1][0].background)
            assertTrue(child.rows[1][0].header)
            assertEquals(TableWidth(TableWidthUnit.Percent, 100), child.geometry!!.width)
        }
    }

    @Test fun rejectsUnknownGeometryInvalidPercentAndMixedChildContent() {
        val root = fourGrids()
        assertThrows(Exception::class.java) { decodedTable(wire(root, flagsOverride = 16)) }
        assertThrows(Exception::class.java) { decodedTable(wire(root, flagsOverride = 8, widthUnitOverride = 2)) }
        assertThrows(Exception::class.java) { decodedTable(wire(root, flagsOverride = 8, widthUnitOverride = 1, widthValueOverride = 101)) }
        assertThrows(Exception::class.java) { decodedTable(wire(root, mixedChildSpans = true)) }
        assertThrows(Exception::class.java) { Cell(listOf(Span("text", "mixed")), false, 1, 1, nestedTable = root) }
    }

    @Test fun depthIsSixteenTablesInclusiveAndCollectionBudgetIsShared() {
        fun chain(depth: Int): Table = if (depth == 1) Table(emptyList(), listOf(listOf(cell("leaf")))) else
            Table(emptyList(), listOf(listOf(cell(child = chain(depth - 1)))))
        assertEquals(chain(16), decodedTable(wire(chain(16))))
        assertThrows(Exception::class.java) { decodedTable(wire(chain(17))) }
        // Display title, section and block have already consumed three collection elements.
        assertThrows(Exception::class.java) {
            decodedTable(wire(Table(emptyList(), emptyList()), rowCountOverride = (1 shl 20) - 2))
        }
        val bytes = wire(fourGrids())
        for (length in listOf(4, bytes.size / 2, bytes.size - 1)) {
            assertThrows(Exception::class.java) { decodedTable(bytes.copyOf(length)) }
        }
    }

    @Test fun authoredGapsAndBordersHaveRealGeometryWithoutSyntheticSpans() {
        val table = fourGrids()
        val root = checkNotNull(tableRenderMetrics(table, 30, 10, 40, 1f))
        val child = table.rows.single().first().nestedTable!!
        val childNatural = checkNotNull(tableRenderMetrics(child, 30, 10, 40, 1f))
        assertTrue(root.columnWidth >= childNatural.width + 20)
        assertEquals(15, root.cellSpacing); assertEquals(0, root.borderWidth)
        val allocated = root.columnWidth - 20
        val metrics = checkNotNull(tableMetricsInWidth(child, childNatural, 5, allocated))
        assertEquals(allocated, metrics.width)
        val grid = tableGrid(child)
        val pixels = checkNotNull(tablePixelLayout(grid, metrics.columnWidth, metrics.minRowHeight,
            IntArray(grid.cells.size) { 8 }, metrics.cellSpacing, metrics.borderWidth, metrics.width, metrics.extraColumns))
        val empty = grid.cells.first { it.cell.background == "#800080" }
        assertTrue(empty.cell.spans.isEmpty())
        assertTrue(pixels.cellWidth(empty.colspan, empty.column) > 0)
        assertTrue(pixels.cellBottom(empty.row, empty.cell.rowspan) > pixels.cellTop(empty.row))
        assertEquals(metrics.width - 1, pixels.cellLeft(4) + pixels.cellWidth(1, 4))
    }

    @Test fun percentWidthsResolveExactlyWithoutExceedingContainingContentBox() {
        val table = Table(emptyList(), listOf(List(5) { cell() }), TableGeometry(border = 1,
            cellSpacing = 2, width = TableWidth(TableWidthUnit.Percent, 100)))
        val natural = checkNotNull(tableRenderMetrics(table, 1, 0, 1, 1f))
        for (available in 37..42) {
            val metrics = checkNotNull(tableMetricsInWidth(table, natural, 5, available))
            val grid = tableGrid(table)
            val pixels = checkNotNull(tablePixelLayout(grid, metrics.columnWidth, 1, IntArray(5) { 1 },
                metrics.cellSpacing, metrics.borderWidth, metrics.width, metrics.extraColumns))
            assertEquals(available, pixels.width)
            assertEquals(available - 3, pixels.cellLeft(4) + pixels.cellWidth(1, 4))
        }
        assertEquals(natural, tableMetricsInWidth(table, natural, 5, 1))
        assertNull(tableRenderMetrics(table.copy(geometry = TableGeometry(cellSpacing = 65535)), 136, 10, 40, 4f))
    }

    @Test fun explicitPixelWidthOverridesPreferredColumnsWhileRetainingPaddingAndChildMinimums() {
        val table = Table(emptyList(), listOf(List(3) { cell("wrap this ordinary text") }),
            TableGeometry(border = 1, cellPadding = 2, width = TableWidth(TableWidthUnit.Px, 101)))
        val metrics = checkNotNull(tableRenderMetrics(table, 136, 10, 40, 1f))
        assertEquals(101, metrics.width)
        assertEquals(33, metrics.columnWidth)
        assertEquals(0, metrics.extraColumns)
        val fractional = checkNotNull(tableRenderMetrics(table.copy(geometry = table.geometry!!.copy(
            width = TableWidth(TableWidthUnit.Px, 102))), 136, 10, 40, 1f))
        assertEquals(102, fractional.width); assertEquals(1, fractional.extraColumns)
        val withChild = table.copy(rows = listOf(listOf(cell(child = fourGrids()))))
        assertTrue(checkNotNull(tableRenderMetrics(withChild, 136, 10, 40, 1f)).width > 101)
    }

    @Test fun recursiveCompactionAndAnnotationTraversalPreserveChildOwnership() {
        val marker = Span("link", "abbr.", target = "Appendix:abbreviation", explanation = "Expanded meaning", trail = " ")
        val media = Span("text", "File:nested.png", classes = "wikidict-media", trail = " ")
        val blank = Span("text", " ")
        val child = Table(listOf(blank, marker, blank), listOf(listOf(Cell(listOf(blank, marker, media, blank), false, 1, 1))))
        val root = Table(emptyList(), listOf(listOf(cell(child = child))))
        val entry = decode(wire(root))
        assertEquals(2, entry.abbreviations.size)
        assertTrue(entry.abbreviations.all { it.explanation == "Expanded meaning" && it.context.contains("Table 1, 1") })
        val compact = entry.readingRows.first { it.block != null }.block!!.table!!.rows.single().single().nestedTable!!
        assertEquals(listOf(marker), compact.caption)
        val order = mutableListOf<String>()
        compact.visitSpans { spans -> if (spans.isNotEmpty()) order.add(textOf(spans)) }
        assertEquals(listOf("abbr.", "abbr. File:nested.png"), order)
        assertEquals("Appendix:abbreviation", compact.rows.single().single().spans.first().target)
    }

    @Test fun deepNativeMetricsKeepEveryPaddingInsetAndTheIndependentPixelLimit() {
        val leaf = Table(emptyList(), listOf(listOf(cell("Deep leaf"))),
            TableGeometry(border = 0, cellSpacing = 0, cellPadding = 0,
                width = TableWidth(TableWidthUnit.Px, 100)))
        fun chain(depth: Int): Table {
            var table = leaf
            repeat(depth - 1) { table = Table(emptyList(), listOf(listOf(cell(child = table))),
                TableGeometry(border = 0, cellSpacing = 0, cellPadding = 1)) }
            return table
        }
        for (depth in listOf(20, 32)) {
            val source = chain(depth)
            val metrics = checkNotNull(tableRenderMetrics(source, 1, 0, 1, 1f))
            // Each real one-cell parent adds two authored pixels around the fixed 100px leaf.
            assertEquals(100 + 2 * (depth - 1), metrics.width)
            var current = source
            repeat(depth - 1) { level ->
                val grid = tableGrid(current)
                assertEquals(1, grid.rows); assertEquals(1, grid.columns)
                assertSame(current.rows.single().single(), grid.cells.single().cell)
                val remaining = checkNotNull(tableRenderMetrics(current, 1, 0, 1, 1f))
                assertEquals(100 + 2 * (depth - level - 1), remaining.width)
                current = checkNotNull(current.rows.single().single().nestedTable)
            }
            assertSame(leaf, current)
            assertEquals("Deep leaf", textOf(current.rows.single().single().spans))
        }
        assertNull(tableRenderMetrics(chain(33), 1, 0, 1, 1f))
        val oversized = chain(20).copy(geometry = TableGeometry(border = 0, cellSpacing = 0,
            cellPadding = 1, width = TableWidth(TableWidthUnit.Px, TablePixelLimit.toLong() + 1)))
        assertNull(tableRenderMetrics(oversized, 1, 0, 1, 1f))
    }
}
