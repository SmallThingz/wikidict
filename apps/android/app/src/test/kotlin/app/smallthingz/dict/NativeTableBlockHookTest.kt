package app.smallthingz.dict

import org.junit.Assert.*
import org.junit.Test

class NativeTableBlockHookTest {
    private val zero = ContainerMargin.Length(StyleLength(StyleLengthUnit.Px, 0f))
    private fun policy(direction: TableContainingDirection = TableContainingDirection.Ltr,
        gridDirection: TableContainingDirection = TableContainingDirection.Rtl,
        width: StyleWidth = StyleWidth(StyleWidthUnit.Percent, 70f)) = TableBlockViewport(639,
        TableStyle(width = width, marginValues = ContainerMargins(zero, ContainerMargin.Auto, zero, ContainerMargin.Auto),
            containingDirection = direction), ContainerBoxSizing.ContentBox,
        StyleWidth(StyleWidthUnit.Percent, 200f), TableStyle(collapse = TableCollapse.Collapse), gridDirection, language = "ru")
    private fun table(policy: TableBlockViewport) = Table(emptyList(),
        listOf(listOf(Cell(listOf(Span("text", "body")), false, 1, 1))), blockViewport = policy)

    @Test fun blockReportKeepsFractionalBorderSeparateFromSmallerAndWiderGrids() {
        val policy = policy()
        val source = table(policy)
        val input = NativeTableMarginMeasureInput(source)
        val owner = Any()
        input.bind(owner)
        val block = resolveTableBlockBox(policy, 201f, 1f, 16f)
        for (gridWidth in listOf(60, 300)) {
            input.beginBlock(201, block)
            input.publishBlock(owner, source, 21, gridWidth, 20, 20.25f)
            val actual = input.ready(141, 21)
            assertEquals(140.7f, actual.placementWidth, .0001f)
            assertEquals(20.25f, actual.placementHeight, 0f)
            assertEquals(140.7f, actual.blockBox!!.contentWidth, .0001f)
            assertEquals(gridWidth, actual.gridWidth)
            assertEquals(141, actual.viewportWidth)
            assertEquals(141, actual.minimumWidth)
            assertThrows(UnsupportedFloatLayout::class.java) { input.ready(gridWidth, 20) }
        }
    }

    @Test fun ownerPolicyAndEachNewRequestInvalidatePreviouslyPublishedBox() {
        val policy = policy()
        val source = table(policy)
        val input = NativeTableMarginMeasureInput(source)
        val owner = Any()
        input.bind(owner)
        val block = resolveTableBlockBox(policy, 200f, 1f, 16f)
        input.beginBlock(200, block)
        input.publishBlock(owner, source, 20, 300, 20)
        assertEquals(140f, input.ready(140, 20).placementWidth, 0f)
        input.beginBlock(200, block)
        assertThrows(UnsupportedFloatLayout::class.java) { input.ready(140, 20) }
        assertThrows(UnsupportedFloatLayout::class.java) {
            input.publishBlock(owner, source.copy(), 20, 300, 20)
        }
        input.publishBlock(owner, source, 20, 60, 20)
        val equalButDifferentPolicy = policy.copy()
        assertEquals(policy, equalButDifferentPolicy)
        assertThrows(UnsupportedFloatLayout::class.java) {
            input.beginBlock(200, resolveTableBlockBox(equalButDifferentPolicy, 200f, 1f, 16f))
        }
        assertThrows(UnsupportedFloatLayout::class.java) { input.ready(140, 20) }
    }

    @Test fun oldGridPublicationCannotMasqueradeAsSourceBlockPublication() {
        val policy = policy()
        val source = table(policy)
        val input = NativeTableMarginMeasureInput(source)
        val owner = Any()
        input.bind(owner)
        input.beginBlock(200, resolveTableBlockBox(policy, 200f, 1f, 16f))
        assertThrows(UnsupportedFloatLayout::class.java) { input.publish(owner, source, 300, 20, 140, true) }
        assertThrows(UnsupportedFloatLayout::class.java) { input.ready(140, 20) }
        input.begin(200, 140, 300)
        assertThrows(UnsupportedFloatLayout::class.java) { input.publishBlock(owner, source, 20, 300, 20) }
        assertThrows(IllegalArgumentException::class.java) { NativeTableMarginBox(140, 20, 140, 20, 300, true) }
        input.publish(owner, source, 300, 20, 140, true)
        assertEquals(300f, input.ready(140, 20).placementWidth, 0f)
    }

    @Test fun parentPlacementUsesSourceBlockAndContainingDirectionDespiteOppositeGrid() {
        for (direction in TableContainingDirection.entries) {
            val gridDirection = if (direction == TableContainingDirection.Ltr) TableContainingDirection.Rtl else TableContainingDirection.Ltr
            val policy = policy(direction, gridDirection, StyleWidth(StyleWidthUnit.Px, 140f))
            val source = table(policy)
            val input = NativeTableMarginMeasureInput(source)
            val owner = Any()
            input.bind(owner)
            val block = resolveTableBlockBox(policy, 100f, 1f, 16f)
            input.beginBlock(100, block)
            input.publishBlock(owner, source, 21, 300, 20, 20.25f)
            val actual = input.ready(140, 21)
            val placed = placeNativeAutoMarginTable(100f, 0f, emptyList(), requireNotNull(block.margins),
                direction, NativeBlockWidth.FixedPx(actual.placementWidth)) {
                NativeBlockMeasure(actual.placementWidth, actual.placementWidth, actual.placementHeight)
            }
            assertEquals(if (direction == TableContainingDirection.Ltr) 0f else -40f, placed.content.left, 0f)
            assertEquals(140f, placed.content.right - placed.content.left, 0f)
            assertEquals(20.25f, placed.nextY, 0f)
            assertEquals(300, actual.gridWidth)
        }
    }

    @Test fun responsiveTableOwnsNativeContextWithoutInventingAFloatOrChangingAbsentMode() {
        val source = table(policy())
        val block = Block("table", 0, emptyList(), table = source)
        assertTrue(block.needsNativeBlockContext())
        assertTrue(listOf(block).needsNativeBlockSequence(null))
        assertFalse(block.hasBodyFloat())
        assertFalse(block.copy(table = source.copy(blockViewport = null)).needsNativeBlockContext())
    }

    @Test fun middlePlacementRetainsSignedAndZeroBaselinesButNoEmptyBaseline() {
        val short = Cell(listOf(Span("text", "short")), false, 1, 1,
            style = CellStyle(verticalAlign = CellVerticalAlign.Middle))
        val tall = Cell(listOf(Span("text", "tall")), false, 1, 1)
        val grid = tableGrid(Table(emptyList(), listOf(listOf(short, tall))))
        val pixels = checkNotNull(tablePixelLayout(grid, 10, 0, intArrayOf(1, 4), 0, 0, anonymousGrid = true))
        val offset = tableCellContentOffset(pixels, grid.cells[0], 1, CellVerticalAlign.Middle)
        assertEquals(1.5f, offset, 0f)
        val signed = nativeTableTextBaselines(listOf(NativeTextBaselines.of(-1.5f, 0f), null),
            listOf(0, 0), listOf(offset, 0f))
        assertEquals(0f, signed!!.first!!, 0f)
        assertEquals(1.5f, signed.last!!, 0f)
        assertNull(nativeTableTextBaselines(listOf(null, null), listOf(0, 0), listOf(offset, 0f)))
    }
}
