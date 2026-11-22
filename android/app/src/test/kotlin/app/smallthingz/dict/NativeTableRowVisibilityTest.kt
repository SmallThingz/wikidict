package app.smallthingz.dict

import org.junit.Assert.*
import org.junit.Test

class NativeTableRowVisibilityTest {
    private fun px(value: Float) = StyleLength(StyleLengthUnit.Px, value)

    @Test fun rootBoundaryKeepsOriginalCaptionRowsAndNestedOwnershipAcrossRecovery() {
        val caption = listOf(Span("link", "Caption", target = "Caption target"))
        val leaf = Cell(listOf(Span("link", "Nested body", target = "Nested target")), false, 1, 1)
        val nested = Table(caption, listOf(listOf(leaf)), rowsHiddenMaxWidthPx = 800)
        val cell = Cell(emptyList(), false, 1, 1, nestedTable = nested)
        val original = Table(caption, listOf(listOf(cell)), rowsHiddenMaxWidthPx = 639)
        assertTrue(nativeTableHasRowVisibility(original))
        assertTrue(nativeTableHasRowVisibility(original.copy(rowsHiddenMaxWidthPx = null)))
        assertFalse(nativeTableHasRowVisibility(nested.copy(rowsHiddenMaxWidthPx = null)))
        val hidden = nativeTableRowProjection(original, 639.0)
        assertSame(original, hidden.source)
        assertSame(caption, hidden.source.caption)
        assertSame(cell, hidden.source.rows.single().single())
        assertSame(nested, cell.nestedTable)
        assertTrue(hidden.rowsHidden)
        assertEquals(TableGrid(emptyList(), 0, 0), hidden.grid)
        val wide = nativeTableRowProjection(original, Math.nextUp(639.0))
        assertFalse(wide.rowsHidden)
        assertSame(cell, wide.grid.cells.single().cell)
        assertTrue(nativeTableRowProjection(nested, Math.nextUp(639.0)).rowsHidden)
        assertSame(caption, nativeTableRowProjection(nested, 800.0).source.caption)
        assertSame(leaf, nativeTableRowProjection(nested, Math.nextUp(800.0)).grid.cells.single().cell)
        // An unrelated 160px cell allocation never enters this root-viewport decision.
        for (containing in listOf(160, 240)) {
            assertEquals(639L, checkNotNull(original.rowsHiddenMaxWidthPx))
            assertTrue(containing < 639)
            assertEquals(wide.grid, nativeTableRowProjection(original, 640.0).grid)
        }
        assertThrows(IllegalArgumentException::class.java) { nativeTableRowProjection(original) }
        for (root in listOf(Double.NaN, Double.POSITIVE_INFINITY, -1.0))
            assertThrows(IllegalArgumentException::class.java) { nativeTableRowsHiddenAt(original, root) }
        assertFalse(nativeTableRowsHiddenAt(null as Long?, Double.NaN))
        assertTrue(nativeTableRowsHiddenAt(0xffffffffL, 0xffffffffL.toDouble()))
        assertThrows(IllegalArgumentException::class.java) { nativeTableRowsHiddenAt(0L, 639.0) }
        assertSame(cell, nativeTableRowProjection(original, 640.0).grid.cells.single().cell)
    }

    @Test fun hiddenBodyRetainsOnlyOwnEdgesCaptionMinimumAndAuthoredWidthWithoutFakeCells() {
        val child = Table(emptyList(), listOf(listOf(Cell(emptyList(), false, 1, 1))),
            geometry = TableGeometry(width = TableWidth(TableWidthUnit.Px, 10000)))
        val sourceCell = Cell(emptyList(), false, 1, 99, nestedTable = child,
            style = CellStyle(border = StyleBorder.Solid(px(80f), "#ff0000"),
                width = StyleWidth(StyleWidthUnit.Px, 9000f)))
        val table = Table(listOf(Span("text", "real caption")), listOf(listOf(sourceCell)),
            geometry = TableGeometry(cellSpacing = 4, cellPadding = 700),
            style = TableStyle(border = StyleBorder.Solid(px(2f), "#123456"),
                collapse = TableCollapse.Separate, padding = StyleEdges(px(3f), px(5f), px(7f), px(11f))),
            rowsHiddenMaxWidthPx = 639)
        fun natural(value: Table = table, root: Double = 639.0) = checkNotNull(tableRenderMetrics(
            value, 136, 10, 10, 1f, containerFontPixels = 20f, rootViewportCssWidth = root))
        val projection = nativeTableRowProjection(table, 639.0)
        val metrics = natural()
        assertEquals(24, metrics.width) // 4px border + 16px table padding + one 4px spacing.
        assertEquals(1.0, metrics.style!!.decorationScale, 0.0)
        assertTrue(metrics.style!!.cellInsets.isEmpty())
        val bare = checkNotNull(inlineTableMetrics(metrics, projection.grid, intArrayOf(), intArrayOf(), 8))
        assertEquals(24, bare.width)
        val caption = checkNotNull(inlineTableMetrics(metrics, projection.grid, intArrayOf(), intArrayOf(), 30,
            captionMinimumWidth = 47))
        assertEquals(47, caption.width)
        val specified = checkNotNull(inlineTableMetrics(metrics, projection.grid, intArrayOf(), intArrayOf(), 30,
            authoredWidth = 60, captionMinimumWidth = 47, minimumWidth = 52.25f))
        assertEquals(60, specified.width)
        assertEquals(53, inlineTableMetrics(metrics, projection.grid, intArrayOf(), intArrayOf(), 30,
            captionMinimumWidth = 47, minimumWidth = 52.25f)!!.width)
        fun pixels(m: TableRenderMetrics, grid: TableGrid = projection.grid) = checkNotNull(tablePixelLayout(grid,
            m.columnWidth, m.minRowHeight, intArrayOf(), m.cellSpacing, m.borderWidth, m.width, m.extraColumns,
            m.style!!.tablePadding, m.columnWidths, m.outerBorder))
        assertEquals(18, pixels(caption).height) // 4px border + 10px padding + 4px spacing, no 99-row or 10px row floor.
        assertArrayEquals(intArrayOf(0), pixels(caption).rowOffsets)
        val collapsed = natural(table.copy(style = table.style!!.copy(collapse = TableCollapse.Collapse)))
        assertEquals(4, collapsed.width)
        assertEquals(4, pixels(collapsed).height)
        val percentage = table.copy(style = table.style!!.copy(width = StyleWidth(StyleWidthUnit.Percent, 50f)))
        assertEquals(100, tableMetricsInWidth(percentage, natural(percentage), 0, 200)!!.width)
        assertSame(sourceCell, table.rows.single().single())
        assertTrue(natural(root = 640.0).width > metrics.width)
        assertEquals(metrics, natural())
        val noPolicy = table.copy(rows = emptyList(), rowsHiddenMaxWidthPx = null)
        val oldEmpty = natural(noPolicy)
        assertNull(inlineTableMetrics(oldEmpty, tableGrid(noPolicy), intArrayOf(), intArrayOf(), 100))
        // The shared policy permits empty individual rows; visible ones retain the old row minimum.
        val emptyRow = table.copy(rows = listOf(emptyList()))
        val visibleEmpty = natural(emptyRow, 640.0)
        val emptyGrid = nativeTableRowProjection(emptyRow, 640.0).grid
        assertEquals(1, emptyGrid.rows)
        assertNotNull(inlineTableMetrics(visibleEmpty, emptyGrid, intArrayOf(), intArrayOf(), 100))
        assertEquals(32, pixels(visibleEmpty, emptyGrid).height)
    }

    @Test fun hiddenRelativeTableKeepsOneOpaqueChildAndItsRealPositionedPaintPhase() {
        val table = Table(emptyList(), listOf(listOf(Cell(listOf(Span("link", "body", target = "Target")), false, 1, 1))),
            rowsHiddenMaxWidthPx = 639)
        val style = ContainerStyle(overflow = ContainerOverflow.Hidden, positioning = ContainerPositioning.RelativeAuto,
            width = ContainerWidth.FitContent, padding = StyleEdges(px(3f), px(5f), px(7f), px(11f)),
            border = ContainerBorder.Solid(px(2f), ContainerColor.Transparent))
        val source = Container(listOf(Block("table", 0, emptyList(), table = table)), style)
        val original = NativeFloatContextSpec.Child(17, { it }, 0f, widthFromContent = true)
        val children = listOf(original)
        val policy = NativeOrdinaryHiddenScrollportPolicy(source)
        fun prepare(selected: NativeOrdinaryHiddenScrollportPolicy?) = nativeContainerSpec(9, style.atViewport(640.0),
            children, 1f, 20f, false, false, false, ordinaryHidden = selected)
        val actual = prepare(policy)
        assertNull(actual.unavailableReason)
        assertTrue(actual.relativeAuto)
        assertTrue(actual.isolatesFloats)
        assertNull(actual.absoluteContainingBlock)
        val viewport = actual.preparedParts!!.single() as NativeFloatContextSpec.Child
        assertSame(children, viewport.scrollport!!.parts)
        assertSame(original, viewport.scrollport.parts.single())
        assertSame(source, viewport.scrollport.ordinaryHidden!!.source)
        assertSame(table, viewport.scrollport.ordinaryHidden.source.blocks.single().table)
        assertEquals(FloatMargins(3f, 5f, 7f, 11f), viewport.scrollport.padding)
        assertEquals(FloatMargins(2f, 2f, 2f, 2f), actual.padding(200))
        // The real opaque viewport belongs to its relative group and paints after later ordinary flow.
        val paint = nativeContextPaintSequence(listOf(NativePaintOrderNode(0),
            NativePaintOrderNode(1, actual.relativeAuto, listOf(NativePaintOrderNode(2))), NativePaintOrderNode(3)))
        assertEquals(listOf(0, 3, 1, 2), paint)
        assertTrue(paint.indexOf(2) > paint.indexOf(3))
        val refused = prepare(null)
        assertNotNull(refused.unavailableReason)
        assertSame(original, refused.preparedParts!!.single())
        assertNull(prepare(policy).unavailableReason)
    }
}
