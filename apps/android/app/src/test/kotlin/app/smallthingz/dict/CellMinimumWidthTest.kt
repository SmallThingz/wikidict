package app.smallthingz.dict

import java.io.ByteArrayOutputStream
import org.junit.Assert.*
import org.junit.Test

class CellMinimumWidthTest {
    private class Wire {
        val output = ByteArrayOutputStream()
        fun byte(value: Int) { output.write(value) }
        fun short(value: Int) { byte(value); byte(value ushr 8) }
        fun int(value: Int) { repeat(4) { byte(value ushr (8 * it)) } }
        fun float(value: Float) = int(value.toRawBits())
        fun text(value: String) { val bytes = value.encodeToByteArray(); int(bytes.size); output.write(bytes) }
        fun length(unit: Int, value: Float) { byte(unit); float(value) }
    }
    private fun fixture(version: Char = 'M', style: Wire.() -> Unit): ByteArray = Wire().apply {
        byte('D'.code); byte('P'.code); byte('R'.code); byte(version.code)
        int(0)
        int(1); byte(2); text("Controlled"); text(""); text("")
        int(1); byte(12); byte(0); byte(0); int(0); byte(0); text(""); text("")
        byte(1); byte(0); int(0); int(1); int(1)
        byte(0); short(1); short(1); byte(0); int(0); byte(0); byte(0)
        byte(1); style()
        byte(0); byte(0)
        text(""); text(""); byte(0); byte(0); byte(0); byte(0)
        repeat(5) { int(0) }
    }.output.toByteArray()
    private fun read(bytes: ByteArray): CellStyle = BlobDecoder.decode(bytes, "word", "language", "English", "en")
        .sections.single().blocks.single().table!!.rows.single().single().style!!
    private fun em(value: Float) = StyleLength(StyleLengthUnit.Em, value)
    private fun px(value: Float) = StyleLength(StyleLengthUnit.Px, value)
    private fun cell(columns: Int = 1, minimum: StyleLength? = null, text: String = "kept") =
        Cell(listOf(Span("link", text, target = text)), false, columns, 1,
            style = minimum?.let { CellStyle(minWidth = it) })

    @Test fun mMinimumFollowsExistingCellTailAndOldHeadersKeepTheirClosedGrammar() {
        val bytes = fixture {
            byte(71); byte(0)
            repeat(4) { length(0, 3f) }; byte(0)
            length(1, 27f)
        }
        val style = read(bytes)
        assertEquals(StyleBorder.None, style.border)
        assertEquals(CellTextAlign.Left, style.textAlign)
        assertNull(style.borderEdges)
        assertNull(style.letterSpacing)
        assertNull(style.width)
        assertEquals(em(27f), style.minWidth)
        assertEquals(px(0f), read(fixture { byte(64); length(0, 0f) }).minWidth)
        for (version in listOf('J', 'K', 'L')) {
            assertThrows(Exception::class.java) { read(bytes.copyOf().also { it[3] = version.code.toByte() }) }
            val absent = read(fixture(version) { byte(1); byte(0) })
            assertNull(absent.minWidth)
            assertEquals(absent, read(fixture('M') { byte(1); byte(0) }))
        }
        val invalid: List<Wire.() -> Unit> = listOf(
            { byte(128) }, { byte(0) }, { byte(64); length(2, 1f) },
            { byte(64); length(0, -1f) }, { byte(64); length(1, Float.NaN) },
            { byte(64); length(1, Float.POSITIVE_INFINITY) },
        )
        invalid.forEach { payload -> assertThrows(Exception::class.java) { read(fixture(style = payload)) } }
        for (length in bytes.indices) assertThrows(Exception::class.java) { read(bytes.copyOf(length)) }
        assertThrows(Exception::class.java) { read(bytes + byteArrayOf(0)) }
    }

    @Test fun reservedCellTailBitsAreRejectedByEverySharedHeader() {
        // Complete former private payloads: rejection must occur at the flag, not truncation.
        val privateTails: List<Wire.() -> Unit> = listOf(
            { byte(8); byte(1); byte(0) },
            { byte(16); length(1, .3f) },
            { byte(32); byte(2); float(48f) },
        )
        for (version in listOf('J', 'K', 'L', 'M')) {
            privateTails.forEach { payload ->
                assertThrows(Exception::class.java) { read(fixture(version, payload)) }
            }
            val legacy = read(fixture(version) {
                byte(7); byte(1); length(0, 2f); text("#123456")
                repeat(4) { length(0, 3f) }; byte(2)
            })
            assertEquals(StyleBorder.Solid(px(2f), "#123456"), legacy.border)
            assertEquals(StyleEdges(px(3f), px(3f), px(3f), px(3f)), legacy.padding)
            assertEquals(CellTextAlign.Right, legacy.textAlign)
            assertNull(legacy.minWidth)
            assertNull(legacy.borderEdges); assertNull(legacy.letterSpacing); assertNull(legacy.width)
            if (version != 'M') assertThrows(Exception::class.java) {
                read(fixture(version) { byte(64); length(0, 0f) })
            }
        }
        assertEquals(em(27f), read(fixture('M') { byte(64); length(1, 27f) }).minWidth)
        assertThrows(Exception::class.java) {
            read(fixture('M') { byte(64 or 8); byte(1); byte(0); length(1, 27f) })
        }
    }

    @Test fun colspanFloorUsesEveryRowAndRetainsOverflowBeyondTheContainingWidth() {
        val table = Table(emptyList(), listOf(
            listOf(cell(3, em(30f), "header")),
            listOf(cell(text = "left"), cell(text = "middle"), cell(text = "right")),
        ))
        val grid = tableGrid(table)
        val preferences = tableCellWidthPreferences(grid, List(4) { TablePixelInsets(0, 0, 0, 0) }, 0, 1f, 20f)
        val columns = inlineTableColumnWidths(grid, intArrayOf(10, 10, 10, 10), intArrayOf(40, 20, 20, 20),
            0, 0, 200, cellPreferences = preferences)!!
        assertEquals(600, columns.sum())
        assertEquals(listOf(200, 200, 200), columns)
        val later = table.copy(rows = table.rows + listOf(listOf(cell(3, em(36f), "later"))))
        val laterGrid = tableGrid(later)
        val laterPreferences = tableCellWidthPreferences(laterGrid, null, 0, 1f, 20f)
        val expanded = inlineTableColumnWidths(laterGrid, IntArray(5) { 10 }, IntArray(5) { 40 },
            0, 0, 200, cellPreferences = laterPreferences)!!
        assertEquals(720, expanded.sum())
        assertEquals(listOf("header", "left", "middle", "right", "later"),
            laterGrid.cells.map { it.cell.spans.single().target })
    }

    @Test fun computedCellEmIsAppliedOnceAndOffsetsAreOutsideItsContentFloor() {
        val header = cell(3, em(27f)).copy(spans = listOf(
            Span("text", "small", small = true, fontScale = .5f, fontScaleBasis = FontScaleBasis.NormalBody),
            Span("link", "large", target = "large", fontScale = 2f, fontScaleBasis = FontScaleBasis.NormalBody)))
        val table = Table(emptyList(), listOf(listOf(header), listOf(cell(), cell(), cell())))
        val grid = tableGrid(table)
        val insets = listOf(TablePixelInsets(2, 7, 3, 7)) + List(3) { TablePixelInsets(0, 0, 0, 0) }
        val preferences = tableCellWidthPreferences(grid, insets, 0, 1f, 20f)
        assertEquals(540, preferences.first().minimumPixels)
        assertNull(preferences.first().pixels)
        assertNull(preferences.first().percent)
        val columns = inlineTableColumnWidths(grid, intArrayOf(24, 0, 0, 0), intArrayOf(60, 0, 0, 0), 4, 12, 200,
            cellPreferences = preferences)!!
        assertEquals(540, columns.sum() + 8 - 14)
        assertTrue(columns.sum() + 12 > 200)
        val pixelMinimum = table.copy(rows = listOf(listOf(header.copy(style = CellStyle(minWidth = px(27f))))))
        assertEquals(54, tableCellWidthPreferences(tableGrid(pixelMinimum), insets, 0, 2f, 80f).single().minimumPixels)
    }

    @Test fun zeroMinimumDoesNotEraseIntrinsicContentAndNestedFloorsStayLocal() {
        val table = Table(emptyList(), listOf(listOf(cell(3, px(0f)))))
        val grid = tableGrid(table)
        val columns = inlineTableColumnWidths(grid, intArrayOf(900), intArrayOf(1000), 0, 0, 200,
            cellPreferences = tableCellWidthPreferences(grid, null, 0, 1f, 20f))!!
        assertEquals(900, columns.sum())
        val nested = Table(emptyList(), listOf(listOf(cell(minimum = px(120f)))))
        val nestedGrid = tableGrid(nested)
        val childColumns = inlineTableColumnWidths(nestedGrid, intArrayOf(20), intArrayOf(40), 0, 0, 60,
            cellPreferences = tableCellWidthPreferences(nestedGrid, null, 0, 1f, 20f))!!
        assertEquals(120, childColumns.sum())
        val outer = Table(emptyList(), listOf(listOf(
            Cell(emptyList(), false, 1, 1, nestedTable = nested), cell(minimum = px(30f)))))
        val outerGrid = tableGrid(outer)
        val outerPreferences = tableCellWidthPreferences(outerGrid, null, 0, 1f, 20f)
        assertEquals(listOf(0, 30), outerPreferences.map { it.minimumPixels })
        assertEquals(listOf(120, 30), inlineTableColumnWidths(outerGrid, intArrayOf(120, 10), intArrayOf(120, 20),
            0, 0, 100, cellPreferences = outerPreferences))
    }

    @Test fun separateMinimumAndPreferredPercentageNeverShrinkTheIntrinsicFloor() {
        val grid = tableGrid(Table(emptyList(), listOf(listOf(cell(), cell()))))
        val preferences = listOf(TableCellWidthPreference(percent = 10.0, minimumPixels = 300),
            TableCellWidthPreference(pixels = 20, minimumPixels = 40))
        assertEquals(listOf(300, 40), inlineTableColumnWidths(grid, intArrayOf(10, 10), intArrayOf(20, 20),
            0, 0, 100, authoredWidth = 50, cellPreferences = preferences))
        val huge = Table(emptyList(), listOf(listOf(cell(minimum = px(Float.MAX_VALUE), text = "retained action"))))
        assertNull(tableRenderMetrics(huge, 1, 0, 20, 1f, containerFontPixels = 20f))
        assertEquals("retained action", huge.rows.single().single().spans.single().target)
    }
}
