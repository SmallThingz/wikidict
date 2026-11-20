package app.smallthingz.dict

import org.junit.Assert.*
import org.junit.Test

class NativeFlexColumnTest {
    private fun px(value: Float) = StyleLength(StyleLengthUnit.Px, value)
    private fun length(value: Float) = ContainerWidth.Length(StyleWidth(StyleWidthUnit.Px, value))
    private fun edge(value: Float) = ContainerMargin.Length(SignedContainerMargin(StyleLengthUnit.Px, value))
    private fun edges(value: Float) = StyleEdges(px(value), px(value), px(value), px(value))
    private val rightBorder = ContainerBorder.Edges(ContainerBorderEdge.None,
        ContainerBorderEdge.Solid(px(2f), ContainerColor.Rgb("#9e9e9e")),
        ContainerBorderEdge.None, ContainerBorderEdge.None)
    private fun cross(style: ContainerStyle, width: Float, intrinsic: ContainerWidths,
        alignment: ContainerAlignItems, rtl: Boolean = false) =
        containerFlexColumnMeasure(style.atViewport(800f), width, intrinsic, 1f, 20f,
            NativeFlexColumnPolicy(alignment, rtl))

    @Test fun crossAxisUsesRealFractionalContainingWidthAndCentersTheOriginalEmptyBorderBox() {
        val connector = ContainerStyle(height = px(20f), border = rightBorder)
        val empty = ContainerWidths(0f, 0f)
        for (rtl in listOf(false, true)) {
            val centered = cross(connector, 100.5f, empty, ContainerAlignItems.Center, rtl)
            assertEquals(0f, centered.width, 0f)
            assertEquals(49.25f, centered.left + centered.crossOffset, 0f)
            assertEquals(20f, containerUsedHeight(connector, 0f, 1f, 20f)!!.content, 0f)
            assertEquals(98.5f, cross(connector, 100.5f, empty, ContainerAlignItems.Stretch, rtl).width, 0f)
            assertEquals(if (rtl) 98.5f else 0f,
                cross(connector, 100.5f, empty, ContainerAlignItems.Start, rtl).crossOffset, 0f)
            assertEquals(if (rtl) 0f else 98.5f,
                cross(connector, 100.5f, empty, ContainerAlignItems.End, rtl).crossOffset, 0f)
        }
        val percent = connector.copy(width = ContainerWidth.Length(StyleWidth(StyleWidthUnit.Percent, 50f)))
        for (alignment in ContainerAlignItems.entries)
            assertEquals(50.25f, cross(percent, 100.5f, empty, alignment).width, 0f)
        val sourceText = ContainerWidths(35f, 180f)
        assertEquals(98.5f, cross(connector, 100.5f, sourceText, ContainerAlignItems.Center).width, 0f)
        val overflowing = cross(connector, 22f, sourceText, ContainerAlignItems.Center)
        assertEquals(35f, overflowing.width, 0f)
        assertEquals(-7.5f, overflowing.crossOffset, 0f)
        assertEquals(0f, cross(connector, 0f, empty, ContainerAlignItems.Stretch).width, 0f)
        assertEquals(-1f, cross(connector, 0f, empty, ContainerAlignItems.Center).crossOffset, 0f)
    }

    @Test fun crossAutoMarginsPrecedeAlignmentWhileDefiniteAndBorderBoxCapsRemainIndependent() {
        val autoMargins = ContainerMargins(edge(0f), ContainerMargin.Auto, edge(0f), ContainerMargin.Auto)
        val source = ContainerStyle(width = length(40f), marginValues = autoMargins)
        for (alignment in ContainerAlignItems.entries) for (rtl in listOf(false, true)) {
            val placed = cross(source, 100.5f, ContainerWidths(10f, 200f), alignment, rtl)
            assertEquals(40f, placed.width, 0f)
            assertEquals(30.25f, placed.left, 0f); assertEquals(30.25f, placed.right, 0f)
            assertEquals(0f, placed.crossOffset, 0f)
        }
        val oneAuto = source.copy(marginValues = autoMargins.copy(right = edge(7f)))
        val placed = cross(oneAuto, 100.5f, ContainerWidths(10f, 200f), ContainerAlignItems.End)
        assertEquals(53.5f, placed.left, 0f); assertEquals(7f, placed.right, 0f)
        val oversized = source.copy(width = length(120f))
        for (rtl in listOf(false, true)) {
            val overflow = cross(oversized, 100f, ContainerWidths(0f, 0f), ContainerAlignItems.Center, rtl)
            assertEquals(120f, overflow.width, 0f)
            assertEquals(if (rtl) -20f else 0f, overflow.crossOffset, 0f)
            assertEquals(0f, overflow.left, 0f); assertEquals(0f, overflow.right, 0f)
        }
        val capped = ContainerStyle(padding = edges(2f), border = rightBorder,
            maxWidth = ContainerMaxWidth.Length(StyleWidth(StyleWidthUnit.Px, 31.5f)),
            boxSizing = ContainerBoxSizing.BorderBox)
        val cap = cross(capped, 100.5f, ContainerWidths(80f, 200f), ContainerAlignItems.Stretch)
        assertEquals(25.5f, cap.width, 0f) // 31.5 border box minus four padding and two border pixels.
        assertEquals(0f, cap.crossOffset, 0f)
        val definite = capped.copy(width = length(20f))
        assertEquals(14f, cross(definite, 100.5f, ContainerWidths(80f, 200f), ContainerAlignItems.Stretch).width, 0f)
        assertEquals(0f, cross(definite.copy(width = length(0f)), 100.5f,
            ContainerWidths(80f, 200f), ContainerAlignItems.Center).width, 0f)
        assertThrows(UnsupportedFloatLayout::class.java) {
            cross(ContainerStyle(width = length(TablePixelLimit + 1f)), 100f,
                ContainerWidths(0f, 0f), ContainerAlignItems.Center)
        }
    }

    @Test fun controlledFourOriginalItemsRetainActionsFontAndDeclaringPaddingWithoutInventingConnectorText() {
        val first = Span("link", "alpha", "A", targetFragment = "kept", bold = true)
        val french = Span("link", "beta", "B", language = "fr", italic = true)
        val plain = Span("text", " plain", language = "fr", italic = true)
        val tail = Span("link", "tail", "Tail")
        fun paragraph(spans: List<Span>) = Block("paragraph", 0, spans)
        val items = listOf(
            Container(listOf(paragraph(listOf(first)))),
            Container(emptyList(), ContainerStyle(height = px(20f), border = rightBorder)),
            Container(listOf(paragraph(listOf(french, plain))), ContainerStyle(ownerFontScale = 1.25f)),
            Container(listOf(paragraph(listOf(tail)))))
        val originalBlocks = items.map { Block("container", 0, emptyList(), container = it) }
        val em = StyleLength(StyleLengthUnit.Em, .5f)
        val ownerStyle = ContainerStyle(width = ContainerWidth.FitContent,
            padding = StyleEdges(em, em, em, em),
            marginValues = ContainerMargins(ContainerMargin.Auto, ContainerMargin.Auto, ContainerMargin.Auto, ContainerMargin.Auto),
            layout = ContainerLayout.FlexColumn, alignItems = ContainerAlignItems.Center)
        val owner = Container(originalBlocks, ownerStyle)
        assertTrue(nativeFlexColumnSourceSupported(owner))
        val projected = containerFlowItems(owner.blocks)
        assertEquals(listOf(0, 1, 2, 3), projected.map { (it as ContainerFlowItem.Block).index })
        originalBlocks.zip(owner.blocks).forEach { (original, retained) -> assertSame(original, retained) }
        items.zip(owner.blocks).forEach { (original, retained) -> assertSame(original, retained.container) }
        assertTrue(items[1].blocks.isEmpty())
        assertEquals(1.25f, items[2].style.ownerFontScale!!, 0f)
        val retained = owner.blocks.flatMap { it.container!!.blocks }.flatMap { it.spans }
        assertEquals(listOf(first, french, plain, tail), retained)
        listOf(first, french, plain, tail).zip(retained).forEach { (a, b) -> assertSame(a, b) }
        assertEquals(listOf("A", "B", "Tail"), retained.filter { it.hasInternalAction() }.map { it.target })
        assertEquals("kept", retained.first().targetFragment)
        assertEquals("alphabeta plaintail", rubyGraphicalText(retained))
        // Controlled intrinsic values stand for actual child measurements; the production
        // column query uses their maximum, whereas the existing row query uses their sum.
        val intrinsic = listOf(ContainerWidths(30f, 70f), ContainerWidths(0f, 0f),
            ContainerWidths(40f, 120f), ContainerWidths(20f, 60f))
        val minimum = items.indices.map { containerFlexIntrinsicContribution(items[it].style.atViewport(800f), intrinsic[it], 1f, 20f, false) }
        val maximum = items.indices.map { containerFlexIntrinsicContribution(items[it].style.atViewport(800f), intrinsic[it], 1f, 20f, true) }
        assertEquals(listOf(30f, 2f, 40f, 20f), minimum)
        assertEquals(listOf(70f, 2f, 120f, 60f), maximum)
        fun contribution(style: ContainerStyle, maximum: Boolean) = containerFlexIntrinsicContribution(
            style.atViewport(800f), ContainerWidths(40f, 100f), 1f, 20f, maximum)
        for (maximumQuery in listOf(false, true)) {
            assertEquals(20f, contribution(ContainerStyle(width = length(20f)), maximumQuery), 0f)
            assertEquals(160f, contribution(ContainerStyle(width = length(160f)), maximumQuery), 0f)
            assertEquals(60f, contribution(ContainerStyle(width = length(160f),
                maxWidth = ContainerMaxWidth.Length(StyleWidth(StyleWidthUnit.Px, 60f))), maximumQuery), 0f)
            assertEquals(if (maximumQuery) 100f else 40f, contribution(ContainerStyle(), maximumQuery), 0f)
            assertEquals(if (maximumQuery) 100f else 40f, contribution(ContainerStyle(
                width = ContainerWidth.Length(StyleWidth(StyleWidthUnit.Percent, 50f)),
                maxWidth = ContainerMaxWidth.Length(StyleWidth(StyleWidthUnit.Percent, 25f))), maximumQuery), 0f)
        }
        val box = containerBoxWidth(ownerStyle, 400f, ContainerWidths(minimum.max(), maximum.max()), 1f, 20f)
        assertEquals(120f, box.content, 0f); assertEquals(140f, box.borderBox, 0f)
        assertEquals(130f, box.marginLeft, 0f); assertEquals(130f, box.marginRight, 0f)
        val connector = cross(items[1].style, box.content, intrinsic[1], ContainerAlignItems.Center)
        assertEquals(59f, connector.crossOffset, 0f); assertEquals(0f, connector.width, 0f)
        assertEquals(20f, containerUsedHeight(items[1].style, 0f, 1f, 20f)!!.content, 0f)
        val relative = items[1].copy(style = items[1].style.copy(positioning = ContainerPositioning.RelativeAuto))
        val refused = owner.copy(blocks = originalBlocks.toMutableList().also { it[1] = it[1].copy(container = relative) })
        assertFalse(nativeFlexColumnSourceSupported(refused))
        assertSame(relative, refused.blocks[1].container)
        assertSame(first, refused.blocks[0].container!!.blocks[0].spans[0])
        assertTrue(nativeFlexColumnSourceSupported(owner))
        assertFalse(nativeFlexColumnSourceSupported(owner.copy(blocks = listOf(paragraph(listOf(first))))))
        val fragmented = items[0].copy(style = ContainerStyle(columns = ContainerColumns(2, px(10f))))
        assertFalse(nativeFlexColumnSourceSupported(owner.copy(blocks = originalBlocks.toMutableList().also {
            it[0] = it[0].copy(container = fragmented)
        })))
        val negative = edge(-1f)
        val clipped = Span("text", "", clippedAbsolute = ClippedAbsoluteInline(px(1f), px(1f),
            ContainerMargins(negative, negative, negative, negative), listOf(Span("text", "retained")),
            staticParentDirection = BidiResolvedDirection.Ltr))
        val clippedItem = items[0].copy(blocks = listOf(paragraph(listOf(clipped))))
        val unavailable = owner.copy(blocks = originalBlocks.toMutableList().also { it[0] = it[0].copy(container = clippedItem) })
        assertFalse(nativeFlexColumnSourceSupported(unavailable))
        assertSame(clipped, unavailable.blocks[0].container!!.blocks[0].spans[0])
    }

    @Test fun automaticMainAxisAddsActualHeightsWithoutOrdinaryMarginCollapseAndKeysItsPolicy() {
        val items = listOf(NativeFlexColumnItemHeight(20f, 3f, 7f),
            NativeFlexColumnItemHeight(12.25f, 11f, 5f), NativeFlexColumnItemHeight(0f, 0f, 0f))
        val stack = nativeFlexColumnStack(items)
        assertEquals(listOf(3f, 41f, 58.25f), stack.tops)
        assertEquals(58.25f, stack.height, 0f)
        val ordinary = NativeMarginCursor(NativeMarginCollapse(false, false))
        for (item in items.take(2)) {
            val margins = NativeAdjoiningMargins(item.before, item.after, false)
            val placement = ordinary.begin(margins)
            ordinary.end(placement, item.borderHeight, margins)
        }
        assertEquals(51.25f, ordinary.finish(), 0f)
        assertEquals(NativeFlexColumnStack(emptyList(), 0f), nativeFlexColumnStack(emptyList()))
        assertThrows(UnsupportedFloatLayout::class.java) {
            nativeFlexColumnStack(listOf(NativeFlexColumnItemHeight(TablePixelLimit.toFloat(), 0f, 1f)))
        }
        val normal = NativeFlowOwnerBoundary(1, 100, null, true)
        val center = normal.copy(column = NativeFlexColumnPolicy(ContainerAlignItems.Center))
        val stretch = normal.copy(column = NativeFlexColumnPolicy(ContainerAlignItems.Stretch))
        assertNotEquals(normal, center); assertNotEquals(center, stretch)
        assertEquals(center, center.copy())
        val row = normal.copy(row = NativeFlexRowPolicy(ContainerAlignItems.Center))
        assertNotEquals(row, center)
        val source = ContainerStyle(height = px(20f))
        for (metadata in listOf<ContainerFlexItem?>(null, ContainerFlexItem.None)) {
            val child = source.copy(flexItem = metadata)
            assertEquals(20f, containerUsedHeight(child, 0f, 1f, 20f)!!.content, 0f)
        }
        // The existing row still apportions widths and retains its independent cross-height calculation.
        val rowItems = listOf(ContainerFlexWidth(80f, 10f, 0f), ContainerFlexWidth(80f, 10f, 0f))
        assertEquals(listOf(50f, 50f), containerFlexWidths(100f, rowItems))
        assertEquals(NativeFlexCrossPlacement(5f, 20f), nativeFlexCrossPlacement(30f, 20f, 0f, 0f,
            NativeFlexCrossMargins(), ContainerAlignItems.Center))
    }
}
