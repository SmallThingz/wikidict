package app.smallthingz.dict

import org.junit.Assert.*
import org.junit.Test

class TableStyleTest {
    private fun px(value: Float) = StyleLength(StyleLengthUnit.Px, value)
    private fun em(value: Float) = StyleLength(StyleLengthUnit.Em, value)
    private fun all(value: StyleLength) = StyleEdges(value, value, value, value)

    @Test fun authoredHrCellEmUsesContainerFontWhilePxMarginsAndHeaderPaintStayDistinct() {
        val border = StyleBorder.Solid(px(1f), "#aaaaaa")
        val cellStyle = CellStyle(border, all(em(0.2f)), CellTextAlign.Center)
        val table = Table(emptyList(), listOf(listOf(
            Cell(listOf(Span("text", "Large first run", fontScale = 500f)), true, 1, 1,
                background = "#f2f2f2", style = cellStyle),
            Cell(listOf(Span("text", "Ordinary")), false, 1, 1, style = cellStyle.copy(textAlign = CellTextAlign.Left)))),
            style = TableStyle("#f9f9f9", border, TableCollapse.Collapse, all(px(10f))))
        val grid = tableGrid(table)
        val resolved = resolveTableStyle(table, grid, 2f, 20f, 10, 0)
        assertEquals(TablePixelInsets(20, 20, 20, 20), resolved.margins)
        assertEquals(listOf(TablePixelInsets(5, 5, 5, 5), TablePixelInsets(5, 5, 5, 5)), resolved.cellInsets)
        assertEquals("#f9f9f9", resolved.background)
        assertEquals("#f2f2f2", table.rows[0][0].background)
        assertEquals(CellTextAlign.Center, table.rows[0][0].style!!.textAlign)
        assertEquals(CellTextAlign.Left, table.rows[0][1].style!!.textAlign)
        val largerFont = resolveTableStyle(table, grid, 2f, 40f, 10, 0)
        assertEquals(TablePixelInsets(9, 9, 9, 9), largerFont.cellInsets.first())
        assertEquals(resolved.margins, largerFont.margins)
        val metrics = tableRenderMetrics(table, 10, 10, 10, 2f, containerFontPixels = 20f)!!
        assertEquals(0, metrics.borderWidth); assertEquals(0, metrics.cellSpacing)
        assertEquals(resolved, metrics.style)
        assertEquals(metrics, tableRenderMetrics(table, 10, 10, 10, 2f, containerFontPixels = 20f,
            decorationViewportWidth = 360, decorationViewportHeight = 640))
        assertEquals(500f, table.rows[0][0].spans.single().fontScale)
        // Narrow tall grids have more paired height capacity than widest grids;
        // ordinary decoration must remain exact while the body scrolls vertically.
        val tall = table.copy(rows = List(1500) { listOf(table.rows[0][0].copy(spans = listOf(Span("text", "Ordinary")))) })
        val tallMetrics = tableRenderMetrics(tall, 136, 10, 40, 1f, containerFontPixels = 20f,
            decorationViewportWidth = 360, decorationViewportHeight = 640)!!
        assertEquals(1.0, tallMetrics.style!!.decorationScale, 0.0)
        assertEquals(TablePixelInsets(10, 10, 10, 10), tallMetrics.style!!.margins)
        assertTrue(tallMetrics.style!!.cellInsets.all { it == TablePixelInsets(5, 5, 5, 5) })
        val tallGrid = tableGrid(tall)
        val tallPixels = tablePixelLayout(tallGrid, tallMetrics.columnWidth, 40, IntArray(1500) { 34 })!!
        assertEquals(60000, tallPixels.height)
        assertEquals(1500, tallGrid.cells.size)
    }

    @Test fun collapsedSolidBordersResolveOneWidestSharedEdgeAndNoneDoesNotInventAStroke() {
        val red = StyleBorder.Solid(px(1f), "#ff0000")
        val green = StyleBorder.Solid(px(3f), "#00ff00")
        val table = Table(emptyList(), listOf(listOf(
            Cell(emptyList(), false, 1, 1, style = CellStyle(red, all(px(0f)))),
            Cell(emptyList(), false, 1, 1, style = CellStyle(green, all(px(0f)))))),
            style = TableStyle(border = red, collapse = TableCollapse.Collapse))
        val grid = tableGrid(table)
        val metrics = tableRenderMetrics(table, 10, 0, 10, 1f, containerFontPixels = 20f)!!
        assertEquals(2, metrics.style!!.cellInsets[0].right)
        assertEquals(2, metrics.style!!.cellInsets[1].left)
        val pixels = tablePixelLayout(grid, metrics.columnWidth, 10, intArrayOf(10, 10))!!
        val edges = collapsedTableBorders(grid, pixels, metrics.style!!)
        val shared = edges.filter { it.x1 == pixels.cellLeft(1).toFloat() && it.x2 == it.x1 }
        assertEquals(1, shared.size)
        assertEquals(3f, shared.single().width, 0f); assertEquals("#00ff00", shared.single().color)
        assertTrue(edges.all { listOf(it.x1, it.x2, it.y1, it.y2, it.width).all { value -> value.isFinite() } })
        val noBorder = table.copy(style = TableStyle(border = StyleBorder.None, collapse = TableCollapse.Collapse),
            rows = table.rows.map { row -> row.map { it.copy(style = CellStyle(StyleBorder.None, all(px(0f)))) } })
        val none = resolveTableStyle(noBorder, tableGrid(noBorder), 1f, 20f, 10, 0)
        assertTrue(none.cellInsets.all { it == TablePixelInsets(0, 0, 0, 0) })
        assertTrue(collapsedTableBorders(tableGrid(noBorder), pixels, none).isEmpty())
        val empty = table.copy(rows = emptyList())
        val emptyGrid = tableGrid(empty)
        val emptyMetrics = tableRenderMetrics(empty, 10, 0, 10, 1f, containerFontPixels = 20f)!!
        val emptyPixels = tablePixelLayout(emptyGrid, emptyMetrics.columnWidth, 10, intArrayOf(), borderWidth = emptyMetrics.borderWidth)!!
        assertEquals(2, emptyPixels.height)
        assertEquals(4, collapsedTableBorders(emptyGrid, emptyPixels, emptyMetrics.style!!).size)
    }

    @Test fun finiteHugeLengthsSaturateOnlyComputedPixelsWhileZeroAndLegacyMetricsRemainExact() {
        val huge = px(Float.MAX_VALUE)
        assertEquals(MaxComputedFontPixels, tableStyleLengthPixels(huge, Float.MAX_VALUE, 20f), 0f)
        assertEquals(MaxComputedFontPixels, tableStyleLengthPixels(em(Float.MAX_VALUE), 1f, Float.MAX_VALUE), 0f)
        assertEquals(0f, tableStyleLengthPixels(px(0f), 3f, 30f), 0f)
        assertEquals(0f, tableStyleLengthPixels(em(Float.MAX_VALUE), 1f, 0f), 0f)
        assertEquals(Float.MAX_VALUE, huge.value, 0f)
        val plain = Table(emptyList(), listOf(listOf(Cell(emptyList(), false, 1, 1))))
        val legacy = tableRenderMetrics(plain, 20, 4, 10, 1f)!!
        assertNull(legacy.style); assertEquals(20, legacy.columnWidth); assertEquals(4, legacy.cellPadding)
        assertEquals(legacy, tableRenderMetrics(plain, 20, 4, 10, 1f, containerFontPixels = 37f))
        val body = Span("link", "Visible body", "Target")
        val extreme = plain.copy(style = TableStyle(border = StyleBorder.Solid(huge, "#aaaaaa"), margins = all(huge)),
            rows = plain.rows.map { row -> row.map { it.copy(spans = listOf(body), style = CellStyle(padding = all(huge))) } })
        val bounded = tableRenderMetrics(extreme, 136, 4, 40, 1f, containerFontPixels = 20f,
            decorationViewportWidth = 360, decorationViewportHeight = 640)!!
        val style = bounded.style!!
        assertTrue(style.decorationScale in 0.0..1.0 && style.decorationScale < 1.0)
        val grid = tableGrid(extreme)
        val inset = style.cellInsets.single()
        val pixels = tablePixelLayout(grid, bounded.columnWidth, bounded.minRowHeight,
            intArrayOf(24 + inset.vertical), bounded.cellSpacing, bounded.borderWidth, bounded.width, bounded.extraColumns)!!
        assertTrue(pixels.width + style.margins.horizontal <= 360)
        assertTrue(pixels.height + style.margins.vertical <= 640)
        assertTrue(pixels.cellWidth(1) - inset.horizontal >= 136)
        assertTrue(pixels.cellBottom(0, 1) - pixels.cellTop(0) - inset.vertical >= 24)
        assertEquals(1, grid.rows); assertEquals(1, grid.cells.size)
        assertEquals(listOf(body), grid.cells.single().cell.spans)
        val dense = extreme.copy(rows = listOf(List(512) { extreme.rows.single().single() }))
        val denseMetrics = tableRenderMetrics(dense, 136, 4, 40, 1f, containerFontPixels = 20f,
            decorationViewportWidth = 360, decorationViewportHeight = 640)!!
        val denseGrid = tableGrid(dense)
        assertEquals(512, denseGrid.cells.size)
        assertTrue(denseGrid.cells.all { it.cell.spans == listOf(body) })
        assertNotNull(tablePixelLayout(denseGrid, denseMetrics.columnWidth, 40, IntArray(512) { 24 },
            denseMetrics.cellSpacing, denseMetrics.borderWidth, denseMetrics.width, denseMetrics.extraColumns))
        assertEquals("Target", grid.cells.single().cell.spans.single().target)
        assertEquals(Float.MAX_VALUE, (extreme.style!!.border as StyleBorder.Solid).width.value, 0f)
        assertEquals(Float.MAX_VALUE, extreme.style!!.margins!!.left.value, 0f)
        val tiny = tableRenderMetrics(extreme, 136, 4, 40, 1f, containerFontPixels = 20f,
            decorationViewportWidth = 1, decorationViewportHeight = 1)!!
        assertEquals(0.0, tiny.style!!.decorationScale, 0.0)
        assertEquals(TablePixelInsets(0, 0, 0, 0), tiny.style!!.margins)
        assertEquals(listOf(body), extreme.rows.single().single().spans)
        val zeroWindow = tableRenderMetrics(extreme, 136, 4, 40, 1f, containerFontPixels = 20f,
            decorationViewportWidth = 0, decorationViewportHeight = 0)!!
        assertEquals(0.0, zeroWindow.style!!.decorationScale, 0.0)
        assertEquals(listOf(body), grid.cells.single().cell.spans)
    }

    @Test fun opacityOnlyCellStylePreservesNullGeometryAndDecorationProjectionAtEveryEndpoint() {
        val text = listOf(Span("text", "Original cell body"))
        val original = Table(emptyList(), listOf(listOf(Cell(text, false, 1, 1))))
        fun metrics(table: Table, viewport: Int) = tableRenderMetrics(table, 136, 10, 40, 1f,
            containerFontPixels = 20f, decorationViewportWidth = viewport, decorationViewportHeight = viewport)
        fun geometry(value: TableRenderMetrics?): List<Any?>? = value?.let { listOf(it.width, it.columnWidth,
            it.cellPadding, it.minRowHeight, it.cellSpacing, it.borderWidth, it.extraColumns,
            it.columnWidths?.toList(), it.outerBorder, it.style) }
        for (viewport in listOf(0, 1, 80, 400)) {
            val ordinary = metrics(original, viewport)
            for (opacity in listOf(0f, .2f, .201f, 1f)) {
                val cell = original.rows.single().single().copy(style = CellStyle(opacity = opacity))
                val table = original.copy(rows = listOf(listOf(cell)))
                assertFalse(tableHasOwnStyle(table))
                assertFalse(tableHasComputedCellStyle(table))
                assertEquals(tableUsesContentWidths(original), tableUsesContentWidths(table))
                assertEquals(geometry(ordinary), geometry(metrics(table, viewport)))
                assertSame(text, cell.spans)
                assertEquals(opacity, cell.style!!.opacity!!, 0f)
                assertEquals(opacity < 1f, table.hasNativeCellOpacity())
            }
        }
        // The existing geometric style and viewport-driven decoration projection
        // still own their exact arithmetic when opacity is added alongside them.
        val oldStyle = CellStyle(padding = all(px(1000f)), border = StyleBorder.Solid(px(30f), "#123456"))
        val styled = original.copy(rows = listOf(listOf(original.rows[0][0].copy(style = oldStyle))))
        assertTrue(tableHasOwnStyle(styled))
        for (viewport in listOf(1, 80, 400)) for (opacity in listOf(0f, .2f, 1f)) {
            val table = styled.copy(rows = listOf(listOf(styled.rows[0][0].copy(style = oldStyle.copy(opacity = opacity)))))
            assertEquals(geometry(metrics(styled, viewport)), geometry(metrics(table, viewport)))
            assertEquals(tableHasComputedCellStyle(styled), tableHasComputedCellStyle(table))
        }
    }

    @Test fun opacityGroupAdmissionKeepsRealBoxTextAndRefusesUnsupportedOwnersWithoutChangingSource() {
        val zero = all(px(0f))
        val border = InlineBoxBorderEdges(InlineBoxBorderEdge.None, InlineBoxBorderEdge.None,
            InlineBoxBorderEdge.None, InlineBoxBorderEdge.None)
        val children = listOf(Span("text", "\u00a0\u00a0\u00a0\u00a0"))
        val box = Span("text", "", background = "#153b64", tooltip = "Original advice",
            inlineBoxGroup = InlineBoxGroup(zero, border, spans = children))
        val body = listOf(box, Span("text", " "), box.copy(background = "#962e22"),
            Span("text", " "), box.copy(background = "#2f683a"))
        val cell = Cell(body, false, 1, 1, style = CellStyle(opacity = .2f))
        val table = Table(emptyList(), listOf(listOf(cell)), style = TableStyle(width = StyleWidth(StyleWidthUnit.Percent, 100f)))
        assertTrue(nativeCellOpacityTableShape(table))
        assertSame(body, table.rows[0][0].spans)
        assertSame(children, table.rows[0][0].spans[0].inlineBoxGroup!!.spans)
        assertEquals("\u00a0\u00a0\u00a0\u00a0 \u00a0\u00a0\u00a0\u00a0 \u00a0\u00a0\u00a0\u00a0", rubyGraphicalText(body))
        val linked = cell.copy(spans = listOf(Span("link", "Retained action", "Target")))
        assertFalse(nativeCellOpacityTableShape(table.copy(rows = listOf(listOf(linked)))))
        assertEquals("Target", linked.spans.single().target)
        val caption = listOf(Span("link", "Original caption", "Caption target"))
        val captioned = table.copy(caption = caption)
        assertFalse(nativeCellOpacityTableShape(captioned))
        assertSame(caption, captioned.caption)
        assertFalse(nativeCellOpacityTableShape(table.copy(style = table.style!!.copy(collapse = TableCollapse.Collapse))))
        val nested = cell.copy(spans = emptyList(), nestedTable = Table(emptyList(), listOf(listOf(Cell(children, false, 1, 1)))))
        assertFalse(nativeCellOpacityTableShape(table.copy(rows = listOf(listOf(nested)))))
        assertSame(children, nested.nestedTable!!.rows[0][0].spans)
        for (opacity in listOf(0f, 1f)) {
            val source = cell.copy(style = cell.style!!.copy(opacity = opacity))
            assertSame(body, source.spans)
            assertEquals(opacity < 1f, source.hasNativeCellOpacity())
        }
    }

    @Test fun opacityBodyEnrollmentPreservesOriginalRowsAndRequiresTheCompleteReferentialEntryEpoch() {
        val before = Block("paragraph", 0, listOf(Span("link", "Before", "Before target")))
        val cell = Cell(listOf(Span("text", "body")), false, 1, 1, style = CellStyle(opacity = .2f))
        val table = Table(emptyList(), listOf(listOf(cell)), style = TableStyle(width = StyleWidth(StyleWidthUnit.Percent, 100f)))
        val middle = Block("table", 0, emptyList(), table = table)
        val after = Block("paragraph", 0, listOf(Span("text", "After")))
        val entry = Entry("word", emptyList(), "language", "Malagasy", "mg",
            listOf(Section(2, "Malagasy", listOf(before, middle, after))), emptyList())
        val rows = entry.readingRows
        val originalKeys = rows.map { it.key }
        assertEquals(listOf(rows.indices), floatBodyRuns(rows, language = entry.language))
        assertEquals(originalKeys, entry.readingRows.map { it.key })
        assertSame(before, rows.single { it.block === before }.block)
        val tableProjection = rows.single { it.key == "block-0-1" }.block!!
        assertEquals(middle, tableProjection)
        assertSame(cell.spans, tableProjection.table!!.rows.single().single().spans)
        assertSame(table, entry.sections.single().blocks[1].table)
        assertSame(after, rows.single { it.block === after }.block)
        val source = nativeCellOpacityEntrySource(entry, rows, rows.indices)!!
        assertSame(entry, source.entry)
        assertNull(nativeCellOpacityEntrySource(entry, rows, 1..rows.lastIndex))
        val equalReplacement = entry.copy()
        assertEquals(entry, equalReplacement)
        assertNotEquals(NativeCellOpacitySourceIdentity(entry), NativeCellOpacitySourceIdentity(equalReplacement))
        assertEquals(NativeCellOpacitySourceIdentity(entry), NativeCellOpacitySourceIdentity(entry))
        assertNull(nativeCellOpacityEntrySource(entry.copy(preamble = listOf(Span("text", "Separate source"))), rows, rows.indices))
        assertNull(nativeCellOpacityEntrySource(entry.copy(references = listOf(Reference(1, 1, "", listOf(Span("text", "Reference"))))), rows, rows.indices))
        assertNull(nativeCellOpacityEntrySource(entry.copy(displayTitle = listOf(Span("text", "Separate rich title"))), rows, rows.indices))
        assertNull(nativeCellOpacityEntrySource(entry.copy(media = listOf(Media("Outside.png", "image", "Separate media"))), rows, rows.indices))
        for (opacity in listOf<Float?>(null, 1f)) {
            val original = table.copy(rows = listOf(listOf(cell.copy(style = opacity?.let { CellStyle(opacity = it) }))))
            val legacy = entry.copy(sections = listOf(entry.sections.single().copy(blocks = listOf(before, middle.copy(table = original), after))))
            assertTrue(floatBodyRuns(legacy.readingRows, language = legacy.language).isEmpty())
            assertEquals("Before target", legacy.sections.single().blocks.first().spans.single().target)
        }
    }
}
