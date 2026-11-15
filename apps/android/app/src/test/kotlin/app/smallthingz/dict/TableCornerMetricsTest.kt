package app.smallthingz.dict

import org.junit.Assert.*
import org.junit.Test

class TableCornerMetricsTest {
    private fun px(value: Float) = StyleLength(StyleLengthUnit.Px, value)
    private fun all(value: StyleLength) = StyleEdges(value, value, value, value)
    private fun corners() = TableCornerRadii(px(8f), px(8f), px(8f), px(0f))
    private fun table(style: TableStyle) = Table(emptyList(), listOf(listOf(
        Cell(listOf(Span("link", "Actual cell", "Target")), true, 1, 1, background = "#ff0000"))), style = style)
    private fun metrics(table: Table) = tableRenderMetrics(table, 136, 0, 40, 1.25f,
        containerFontPixels = 20f, decorationViewportWidth = 360, decorationViewportHeight = 640)

    @Test fun cornersPreserveNullMetricsAndDoNotSelectAnotherWidthAlgorithm() {
        val style = TableStyle(background = "#f5f4aa", border = StyleBorder.Solid(px(1f), "#bca674"),
            collapse = TableCollapse.Separate, padding = all(StyleLength(StyleLengthUnit.Em, .1f)))
        val plain = table(style)
        val rounded = plain.copy(style = style.copy(cornerRadii = corners()))
        assertFalse(tableUsesContentWidths(plain))
        assertFalse(tableUsesContentWidths(rounded))
        val old = checkNotNull(metrics(plain))
        val actual = checkNotNull(metrics(rounded))
        assertEquals(old, actual.copy(style = actual.style!!.copy(cornerRadii = null)))
        assertEquals(10.0, actual.style!!.cornerRadii!!.topLeft, 0.0)
        assertEquals(0.0, actual.style!!.cornerRadii!!.bottomLeft, 0.0)
        assertEquals(TablePixelInsets(2, 2, 2, 2), actual.style!!.tablePadding)
        assertSame(plain.rows, rounded.rows)
        assertEquals("#ff0000", rounded.rows.single().single().background)
        assertEquals("Target", rounded.rows.single().single().spans.single().target)
    }

    @Test fun cornerBorderKeepsExactSourceWidthWithoutFontCapOrDecorationProjection() {
        val width = MaxComputedFontPixels + 1f
        val style = TableStyle(border = StyleBorder.Solid(px(width), "#bca674"),
            collapse = TableCollapse.Separate)
        val plain = table(style)
        val rounded = plain.copy(style = style.copy(cornerRadii = corners()))
        val old = checkNotNull(tableRenderMetrics(plain, 136, 0, 40, 1f, containerFontPixels = 20f,
            decorationViewportWidth = 360, decorationViewportHeight = 640))
        val actual = checkNotNull(tableRenderMetrics(rounded, 136, 0, 40, 1f, containerFontPixels = 20f,
            decorationViewportWidth = 360, decorationViewportHeight = 640))
        assertTrue(old.style!!.decorationScale < 1.0)
        assertEquals(1.0, actual.style!!.decorationScale, 0.0)
        assertEquals(width, actual.style!!.border.width, 0f)
        assertEquals(width.toInt(), actual.outerBorder.left)
        assertSame(plain.rows, rounded.rows)
    }

    @Test fun unavailableCornerGeometryRefusesProjectionAndWrongOwnerContextWithoutChangingSource() {
        val source = table(TableStyle(border = StyleBorder.Solid(px(TablePixelLimit + 1f), "#bca674"),
            collapse = TableCollapse.Separate, cornerRadii = corners()))
        assertNull(tableRenderMetrics(source, 136, 0, 40, 1f, containerFontPixels = 20f))
        assertEquals(TablePixelLimit + 1f, (source.style!!.border as StyleBorder.Solid).width.value, 0f)
        assertEquals("Target", source.rows.single().single().spans.single().target)
        val ordinary = source.copy(style = source.style!!.copy(border = StyleBorder.None))
        assertThrows(IllegalArgumentException::class.java) {
            resolveTableStyle(ordinary, tableGrid(ordinary), 1f, 20f, 0, 0, decorationScale = .5)
        }
        val blockBoxStyle = ordinary.style!!.copy(collapse = null)
        assertThrows(IllegalArgumentException::class.java) {
            resolveTableStyle(ordinary, tableGrid(ordinary), 1f, 20f, 0, 0, tableStyle = blockBoxStyle)
        }
        assertNotNull(tableRenderMetrics(ordinary, 136, 0, 40, 1f, containerFontPixels = 20f))
    }

    private fun separatePolicy(direction: TableContainingDirection = TableContainingDirection.Ltr,
        sizing: ContainerBoxSizing = ContainerBoxSizing.ContentBox) = TableBlockViewport(639,
        TableStyle(background = "#f5f4aa", border = StyleBorder.Solid(px(1f), "#bca674"),
            padding = all(StyleLength(StyleLengthUnit.Em, .1f)), width = StyleWidth(StyleWidthUnit.Percent, 100f),
            margins = StyleEdges(px(4f), px(0f), StyleLength(StyleLengthUnit.Em, .5f), px(0f)),
            containingDirection = direction, cornerRadii = corners()), sizing,
        StyleWidth(StyleWidthUnit.Percent, 100f), TableStyle(collapse = TableCollapse.Separate),
        TableContainingDirection.Rtl, "mg", TableScrollFocusPaint(TableScrollFocusMode.AuthoredNone))

    private fun separateTable(policy: TableBlockViewport) = Table(emptyList(), listOf(listOf(
        Cell(listOf(Span("link", "First", "A")), false, 1, 1),
        Cell(listOf(Span("link", "Second", "B")), false, 1, 1))),
        geometry = TableGeometry(cellSpacing = 2, cellPadding = 1),
        style = policy.boxStyle.copy(collapse = TableCollapse.Separate,
            containingDirection = if (policy.boxStyle.containingDirection == TableContainingDirection.Ltr)
                TableContainingDirection.Rtl else TableContainingDirection.Ltr), blockViewport = policy)

    @Test fun numericMarginsKeepPhysicalResidualDirectionAndExistingAutoCases() {
        val fixed = NativeTableAutoMargins(FloatMargins(0f, 20f, 0f, 10f), false, false)
        fun used(width: Float, direction: TableContainingDirection) =
            solveTableAutoMargins(100f, width, fixed, NativeTableMarginFlow.Block, direction)
        assertEquals(NativeTableUsedMargins(0f, 30f, 0f, 10f), used(60f, TableContainingDirection.Ltr))
        assertEquals(NativeTableUsedMargins(0f, 20f, 0f, 20f), used(60f, TableContainingDirection.Rtl))
        assertEquals(NativeTableUsedMargins(0f, -50f, 0f, 10f), used(140f, TableContainingDirection.Ltr))
        assertEquals(NativeTableUsedMargins(0f, 20f, 0f, -60f), used(140f, TableContainingDirection.Rtl))
        val both = NativeTableAutoMargins(FloatMargins(0f, 0f, 0f, 0f), true, true)
        val one = NativeTableAutoMargins(FloatMargins(0f, 10f, 0f, 0f), true, false)
        assertEquals(NativeTableUsedMargins(0f, 20f, 0f, 20f), solveTableAutoMargins(100f, 60f, both,
            NativeTableMarginFlow.Block, TableContainingDirection.Rtl))
        assertEquals(NativeTableUsedMargins(0f, 10f, 0f, 30f), solveTableAutoMargins(100f, 60f, one,
            NativeTableMarginFlow.Block, TableContainingDirection.Ltr))
    }

    @Test fun percentCornerBoxUsesSourceDirectionWithFixedMarginsAndKeepsOverflowEdges() {
        for (direction in TableContainingDirection.entries) {
            val policy = separatePolicy(direction)
            val box = resolveTableBlockBox(policy, 200f, 1f, 20f)
            assertEquals(200f, box.contentWidth, 0f)
            assertEquals(206f, box.borderWidth, 0f)
            assertEquals(FloatMargins(4f, 0f, 10f, 0f), box.fixedMargins)
            assertFalse(box.margins!!.leftAuto); assertFalse(box.margins!!.rightAuto)
            val placed = placeStandaloneTableBlock(box, 200f, 32f, emptyList())
            assertEquals(if (direction == TableContainingDirection.Rtl) -6f else 0f, placed.content.left, 0f)
            assertEquals(4f, placed.content.top, 0f)
            assertEquals(46f, placed.nextY, 0f)
            val borderBox = resolveTableBlockBox(policy.copy(boxSizing = ContainerBoxSizing.BorderBox), 200f, 1f, 20f)
            assertEquals(200f, borderBox.borderWidth, 0f)
            assertEquals(194f, borderBox.contentWidth, 0f)
        }
    }

    @Test fun separateGridPreservesResolvedSpacingPaddingAndRealEmptyRowSlotsInBothStates() {
        val policy = separatePolicy()
        val source = separateTable(policy)
        val wide = checkNotNull(tableRenderMetrics(source, 136, 99, 40, 1.5f, containerFontPixels = 20f))
        val narrow = checkNotNull(anonymousTableRenderMetrics(source, policy.gridStyle, 1.5f, 20f, true))
        assertEquals(3, wide.cellSpacing); assertEquals(wide.cellSpacing, narrow.cellSpacing)
        assertEquals(2, wide.cellPadding); assertEquals(wide.cellPadding, narrow.cellPadding)
        assertEquals(listOf(TablePixelInsets(2, 2, 2, 2), TablePixelInsets(2, 2, 2, 2)), narrow.style!!.cellInsets)
        assertEquals(wide.style!!.cellInsets, narrow.style!!.cellInsets)
        assertEquals(0, wide.minRowHeight); assertEquals(0, narrow.minRowHeight)
        assertFalse(narrow.style!!.collapse)
        assertNull(narrow.style!!.background); assertNull(narrow.style!!.cornerRadii)
        assertEquals(TablePixelInsets(0, 0, 0, 0), narrow.outerBorder)
        assertEquals(TablePixelInsets(0, 0, 0, 0), narrow.style!!.tablePadding)
        assertEquals(listOf("A", "B"), tableGrid(source).cells.map { it.cell.spans.single().target })
        for (rows in listOf(emptyList<List<Cell>>(), listOf(emptyList<Cell>()))) {
            val empty = source.copy(rows = rows)
            val metrics = checkNotNull(anonymousTableRenderMetrics(empty, policy.gridStyle, 1.5f, 20f, true))
            val grid = tableGrid(empty)
            val pixels = checkNotNull(tablePixelLayout(grid, metrics.columnWidth, metrics.minRowHeight,
                intArrayOf(), metrics.cellSpacing, metrics.borderWidth, metrics.width, metrics.extraColumns,
                metrics.style!!.tablePadding, metrics.columnWidths, metrics.outerBorder, anonymousGrid = true))
            assertEquals(2, metrics.cellPadding)
            assertEquals(3, pixels.width)
            assertEquals((rows.size + 1) * 3, pixels.height)
            assertTrue(grid.cells.isEmpty())
        }
    }
    @Test fun numericCornerFocusKeepsPolicyAndZeroRangeEligibilityAcrossStatesAndRefusal() {
        val paints = listOf(TableScrollFocusPaint(TableScrollFocusMode.AuthoredNone),
            TableScrollFocusPaint(TableScrollFocusMode.UaAuto),
            TableScrollFocusPaint(TableScrollFocusMode.UaAuto, FigureColor.Rgb("#335577")))
        for (paint in paints) {
            val policy = separatePolicy().copy(focusPaint = paint)
            val source = separateTable(policy)
            assertNull(source.floatViewport)
            assertEquals(TableContainingDirection.Rtl, source.style!!.containingDirection)
            assertEquals(TableContainingDirection.Ltr, policy.boxStyle.containingDirection)
            assertSame(paint, source.blockViewport!!.focusPaint)
            val owner = NativeTableScrollFocusOwner(checkNotNull(source.blockViewport!!.focusPaint))
            owner.update(true, 200f, 0f, 0f, null, null)
            assertTrue(owner.canAcquireFocus)
            assertFalse(owner.canScroll)
            assertFalse(owner.scrollBy(1f))
            assertEquals(paint.mode == TableScrollFocusMode.UaAuto, owner.paintsFocus)
            owner.update(false, 200f, 0f, 0f, null, null)
            assertFalse(owner.canAcquireFocus); assertFalse(owner.paintsFocus)
            owner.update(true, 200f, 0f, 0f, null, null)
            assertTrue(owner.canAcquireFocus)
            owner.unavailable()
            assertFalse(owner.canAcquireFocus); assertFalse(owner.paintsFocus)
            owner.update(true, 200f, 0f, 0f, null, null)
            assertTrue(owner.canAcquireFocus)
            assertSame(paint, owner.policy)
            assertEquals(listOf("A", "B"), source.rows.single().map { it.spans.single().target })
            owner.close()
        }
    }

    @Test fun numericCornerOverflowKeepsPaddingStripWithoutMovingContentOrPan() {
        val original = separatePolicy(TableContainingDirection.Rtl)
        val policy = original.copy(boxStyle = original.boxStyle.copy(
            border = StyleBorder.Solid(px(1.25f), "#bca674"),
            padding = StyleEdges(px(3.5f), px(7.25f), px(5.75f), px(11.5f)),
            cornerRadii = TableCornerRadii(px(7.75f), px(6.5f), px(5.25f), px(0f))))
        val box = resolveTableBlockBox(policy, 160f, 1f, 20f)
        val left = box.usedMargins.left
        val top = box.fixedMargins.top
        val border = NativeFloatBounds(left, top, left + box.borderWidth,
            top + box.insets.top + 28f + box.insets.bottom)
        val content = NativeFloatBounds(left + box.insets.left, top + box.insets.top,
            left + box.insets.left + box.contentWidth, top + box.insets.top + 28f)
        val shape = NativeTableCornerShape(border, nativeTableCornerRadii(policy.boxStyle.cornerRadii!!, 1f), 1.25f)
        val overflow = tableBlockOverflowBounds(policy, content, shape)
        assertEquals(NativeFloatBounds(-20f, 5.25f, 158.75f, 42.5f), overflow)
        assertEquals(NativeFloatBounds(-8.5f, 8.75f, 151.5f, 36.75f), content)
        assertTrue(overflow.left < content.left && overflow.top < content.top)
        assertTrue(overflow.right > content.right && overflow.bottom > content.bottom)
        assertTrue(shape.contains(50f, 6f, padding = true))
        assertFalse(shape.contains(50f, 5f, padding = true))
        assertFalse(shape.contains(overflow.left, overflow.top, padding = true))
        for (rtl in listOf(false, true)) {
            val scrolling = tableBlockScrollGeometry(box.contentWidth, 220, 17, rtl)
            assertEquals(60f, scrolling.overflow, 0f)
            assertEquals(if (rtl) -43f else -17f, scrolling.physicalTranslation, 0f)
            assertEquals(overflow, tableBlockOverflowBounds(policy, content, shape))
        }
        val shifted = tableBlockOverflowBounds(policy, content, shape.translated(3.375f, -1.125f))
        assertEquals(NativeFloatBounds(-16.625f, 4.125f, 162.125f, 41.375f), shifted)
        assertEquals(160f, box.contentWidth, 0f)
    }

    @Test fun legacyAndPairedClipsKeepContentEdgeWhileEmptyQPaddingStaysEmpty() {
        val zero = ContainerMargin.Length(px(0f))
        val legacy = TableBlockViewport(639, TableStyle(width = StyleWidth(StyleWidthUnit.Percent, 70f),
            marginValues = ContainerMargins(zero, ContainerMargin.Auto, zero, ContainerMargin.Auto),
            containingDirection = TableContainingDirection.Ltr), ContainerBoxSizing.ContentBox,
            StyleWidth(StyleWidthUnit.Percent, 100f), TableStyle(collapse = TableCollapse.Collapse),
            TableContainingDirection.Rtl, "ru")
        val paired = TableBlockViewport(639, TableStyle(margins = all(px(0f))), ContainerBoxSizing.BorderBox,
            StyleWidth(StyleWidthUnit.Percent, 100f), TableStyle(collapse = TableCollapse.Collapse),
            TableContainingDirection.Rtl, "de", TableScrollFocusPaint(TableScrollFocusMode.AuthoredNone))
        val content = NativeFloatBounds(12f, 8f, 90f, 28f)
        val shape = NativeTableCornerShape(NativeFloatBounds(0f, 0f, 100f, 40f),
            NativeCornerRadii(8f, 8f, 8f, 0f), 1f)
        for (policy in listOf(legacy, paired)) {
            assertSame(content, tableBlockOverflowBounds(policy, content, shape))
            assertSame(content, tableBlockOverflowBounds(policy, content, null))
        }
        val empty = NativeTableCornerShape(NativeFloatBounds(0f, 0f, 10f, 4f),
            NativeCornerRadii(8f, 8f, 8f, 0f), 3f)
        val clipped = tableBlockOverflowBounds(separatePolicy(), content, empty)
        assertEquals(clipped.left, clipped.right, 0f)
        assertEquals(clipped.top, clipped.bottom, 0f)
        assertThrows(UnsupportedFloatLayout::class.java) {
            tableBlockOverflowBounds(separatePolicy(), content, null)
        }
    }
}
