package app.smallthingz.dict

import org.junit.Assert.*
import org.junit.Test

class FigureTableCaptionTest {
    private fun px(value: Float) = StyleLength(StyleLengthUnit.Px, value)
    private val zero = FigurePixelEdges(0f, 0f, 0f, 0f)
    private val none = FigureBorderEdges(FigureBorderEdge.None, FigureBorderEdge.None, FigureBorderEdge.None, FigureBorderEdge.None)
    private val font = FigureMediaFont(NativePrimaryFontMetrics(-16f, 4f, 20f, 0f), 10f)
    private fun media(cap: Float? = null) = FigureMediaLayout(FigureMediaStrut(1f, direction = BidiResolvedDirection.Ltr),
        InlineBoxVerticalAlign.Middle, cap?.let { AvailableWidthLimit(100f, px(it)) })
    private fun layout(cap: Float? = null, table: FigureBorderEdges = none, caption: FigureBorderEdges = none) =
        TableCaptionLayout(TableCollapse.Collapse, ContainerStyle(), table, caption, media(cap))
    private fun natural(width: Float = 100f, height: Float = 50f, padding: FigurePixelEdges = zero,
        insets: FigurePixelEdges = zero, border: Float = 0f, minimum: Float? = null) =
        FigureBoxMetrics(FigurePixels(width, height, width.toDouble(), height.toDouble()), zero, insets, padding, 0f, border, minimum)
    private fun prepared(style: TableCaptionLayout = layout(), box: FigureBoxMetrics = natural(), rtl: Boolean = false) =
        FigureTableCaptionMetrics(style, box, 1f, 20f, rtl, font)

    @Test fun captionMinimumEnlargesMediaGridAndCentersWithoutUsingCaptionMaximum() {
        val content = prepared()
        assertEquals(NativeWidthRange(160, 160), content.intrinsic(160))
        val wide = content.resolve(900, 160)
        assertEquals(160, wide.width)
        assertEquals(30f, wide.imageLeft, 0f)
        assertEquals(160, wide.captionWidth)
        assertEquals(50f, wide.captionTop, 0f)
        assertEquals(90, wide.height(40))
        assertEquals(160, content.resolve(40, 160).width)
        // With a short unbreakable minimum, arbitrarily long wrapping prose is not a width input.
        assertEquals(100, content.resolve(900, 12).width)
        assertEquals(0f, content.resolve(900, 12).imageLeft, 0f)
    }

    @Test fun cyclicCapUsesAllocatedCellContentAndPreservesPreferredSourceAxes() {
        val box = natural(200f, 100f, insets = FigurePixelEdges(1f, 2f, 3f, 2f), border = 1f)
        val content = prepared(layout(cap = 10f), box)
        assertEquals(NativeWidthRange(40, 206), content.intrinsic(40))
        val small = content.resolve(80, 40)
        assertEquals(80, small.width)
        assertEquals(70f, small.image.width, 0f)
        assertEquals(35f, small.image.height, 0f)
        assertEquals(5f, small.imageLeft, 0f)
        assertEquals(200.0, small.image.sourceWidth!!, 0.0)
        assertEquals(100.0, small.image.sourceHeight!!, 0.0)
        val roomy = content.resolve(900, 40)
        assertEquals(206, roomy.width)
        assertEquals(196f, roomy.image.width, 0f) // 206 cell width minus10, not900 minus10.
        assertEquals(0f, prepared(layout(cap = 100f)).resolve(20, 0).image.width, 0f)
        assertEquals(800f, prepared(layout(cap = 0f), natural(100000f, 50000f)).resolve(800, 1).image.width, 0f)
    }

    @Test fun cappedStatusContentKeepsItsRemeasuredHeightInsteadOfImageRatio() {
        val requested = mutableListOf<Float>()
        val status = FigureBoxMetrics(FigurePixels(200f, 24f), zero, zero, zero, 0f, 0f)
        val content = FigureTableCaptionMetrics(layout(cap = 10f), status, 1f, 20f, false, font) { width ->
            requested += width
            if (width < 100f) 96f else 24f
        }
        val narrow = content.resolve(80, 0)
        assertEquals(listOf(70f), requested)
        assertEquals(70f, narrow.image.width, 0f)
        assertEquals(96f, narrow.image.height, 0f)
        assertEquals(96f, narrow.captionTop, 0f)
        assertNull(narrow.image.sourceWidth); assertNull(narrow.image.sourceHeight)
        val wide = content.resolve(900, 0)
        assertEquals(190f, wide.image.width, 0f)
        assertEquals(24f, wide.image.height, 0f)
        val invalid = FigureTableCaptionMetrics(layout(cap = 10f), status, 1f, 20f, false, font) { Float.NaN }
        assertThrows(UnsupportedFloatLayout::class.java) { invalid.resolve(80, 0) }
    }

    @Test fun collapsedMediaEdgesAndExternalCaptionEdgesKeepTheirIndependentBoxes() {
        val solid = FigureBorderEdge.Solid(px(3f), FigureColor.Rgb("#112233"))
        val dotted = FigureBorderEdge.Dotted(px(5f), FigureColor.NativeTheme)
        val content = prepared(layout(table = FigureBorderEdges(solid, solid, solid, solid),
            caption = FigureBorderEdges(dotted, solid, FigureBorderEdge.Hidden, FigureBorderEdge.None)),
            natural(padding = FigurePixelEdges(2f, 4f, 6f, 8f)))
        assertEquals(TablePixelInsets(2, 2, 2, 2), content.mediaInsets)
        val box = content.resolve(900, 150)
        assertEquals(165, box.width) // 150 content +12 padding +3 external right border.
        assertEquals(150, box.captionWidth)
        assertEquals(54, box.tableCaption!!.pixels.height)
        assertEquals(59f, box.captionTop, 0f) // Caption top border is outside the media grid.
        assertEquals(87, box.height(20))
        val edges = box.tableCaption!!.borders(20)
        assertEquals(5, edges.count { it.stroke == TableStroke.Solid }) // Four grid sides plus the separate caption right edge.
        assertEquals(1, edges.count { it.stroke == TableStroke.Dotted })
        assertFalse(edges.any { it.stroke == TableStroke.Hidden && it.width > 0f })
    }

    @Test fun captionFloatZeroAndExactPhysicalSideDoNotManufactureTextOrAWholeLineInset() {
        fun before(width: Float, height: Float, side: TableFloatSide) = ContainerStyle(
            width = ContainerWidth.Length(StyleWidth(StyleWidthUnit.Px, width)), height = px(height), floatSide = side,
            margins = SignedContainerEdges(SignedContainerMargin(StyleLengthUnit.Px, 0f),
                SignedContainerMargin(StyleLengthUnit.Px, 0f), SignedContainerMargin(StyleLengthUnit.Px, 0f),
                SignedContainerMargin(StyleLengthUnit.Px, 3f)))
        val float = captionBeforeFloat(before(15f, 11f, TableFloatSide.Right), 1f, 20f)
        assertEquals(18f, float.minimumWidth, 0f)
        val placed = float.place(100)
        assertEquals(82f, placed.outer.left, 0f)
        assertEquals(100f, placed.outer.right, 0f)
        assertEquals(11f, placed.outer.bottom, 0f)
        val empty = captionBeforeFloat(before(0f, 0f, TableFloatSide.Left).copy(margins = null), 1f, 20f)
        assertEquals(0f, empty.place(100).outer.bottom, 0f)
        assertEquals(0f, empty.minimumWidth, 0f)
        assertFalse(validFigureCaptionBefore(before(15f, 11f, TableFloatSide.Left).copy(padding = StyleEdges(px(1f),px(0f),px(0f),px(0f)))))
    }

    @Test fun completeResponsiveStateResetsFloatAndBeforeAndSolvesBothAutoMargins() {
        val auto = ContainerMargin.Auto
        val zeroMargin = ContainerMargin.Length(SignedContainerMargin(StyleLengthUnit.Px, 0f))
        val wrapper = ContainerStyle(marginValues = ContainerMargins(zeroMargin, auto, zeroMargin, auto))
        val value = layout().copy(viewportStates = listOf(FigureViewportState(639, wrapper, media()), FigureViewportState(399, ContainerStyle(), media())))
        assertNull(value.stateAtViewport(640.0))
        assertEquals(wrapper, value.stateAtViewport(639.0)!!.wrapper)
        assertNull(value.stateAtViewport(639.0)!!.captionBefore)
        assertEquals(ContainerStyle(), value.stateAtViewport(399.0)!!.wrapper)
        assertEquals(350f, figureTableNormalLeft(wrapper, 900, 200, 1f, 20f, false)!!, 0f)
        assertEquals(-50f, figureTableNormalLeft(wrapper, 150, 200, 1f, 20f, true)!!, 0f)
        assertEquals(0f, figureTableNormalLeft(wrapper, 150, 200, 1f, 20f, false)!!, 0f)
        assertThrows(IllegalArgumentException::class.java) { value.stateAtViewport(Double.NaN) }
        assertThrows(IllegalArgumentException::class.java) { value.copy(viewportStates = value.viewportStates.reversed()) }
        assertThrows(IllegalArgumentException::class.java) { FigureViewportState(100, wrapper.copy(height = px(3f)), media()) }
    }

    @Test fun normalBodyEmBasisIsAppliedOnceAndAuthoritativeEmptyCaptionKeepsOnlyEdges() {
        val width = FigureBorderEdge.Solid(StyleLength(StyleLengthUnit.Em, .1f), FigureColor.Transparent)
        val style = layout(caption = FigureBorderEdges(width, width, width, width))
        val content = FigureTableCaptionMetrics(style, natural(0f, 0f), 2f, 20f, false,
            FigureMediaFont(NativePrimaryFontMetrics(0f, 0f, 0f, 0f), 0f))
        val box = content.resolve(300, 0)
        assertEquals(4, box.width)
        assertEquals(0, box.captionWidth)
        assertEquals(4, box.height(0))
        assertEquals(2f, content.captionEdges.top.width, 0f)
        assertEquals("", content.captionEdges.top.color)
        assertEquals(0, box.tableCaption!!.pixels.height)
    }

    @Test fun completeBaseWrapperUsesActualFlowDirectionAndNeverReconstructsLegacyCenter() {
        val zeroMargin = ContainerMargin.Length(SignedContainerMargin(StyleLengthUnit.Px, 0f))
        val auto = ContainerStyle(marginValues = ContainerMargins(zeroMargin, ContainerMargin.Auto,
            zeroMargin, ContainerMargin.Auto))
        val lengths = StyleEdges(px(0f), px(0f), px(0f), px(0f))
        val content = FigureContent.Image(Span("link", "", "File:owner.png",
            image = InlineImage("owner.png", widthPx = 140)), FigureSizingPolicy.RequestedFit)
        val source = Figure(content, FigureFormat.Thumbnail, FigurePlacement.FloatRight, FigureClear.Both,
            lengths, lengths, lengths, 1f, px(20f), FigureColor.Transparent, FigureBorder.None,
            FigureColor.Transparent, FigureBorder.None, FigureColor.NativeTheme, FigureColor.Transparent,
            caption = listOf(Span("link", "source caption", "caption-target")),
            tableCaptionLayout = layout().copy(wrapper = auto,
                viewportStates = listOf(FigureViewportState(80, ContainerStyle(), media()))))
        val selected = figureTableViewport(source, 100.0)
        assertEquals(FigurePlacement.None, selected.placement)
        assertEquals(FigureClear.None, selected.clear)
        assertSame(content, selected.content); assertSame(source.caption, selected.caption)
        assertEquals(auto, figureTableWrapper(selected, 100.0))
        assertEquals(0f, figureTableNormalLeft(auto, 100, 140, 1f, 20f, false)!!, 0f)
        assertEquals(-40f, figureTableNormalLeft(auto, 100, 140, 1f, 20f, true)!!, 0f)
        assertEquals(30f, figureTableNormalLeft(auto, 200, 140, 1f, 20f, false)!!, 0f)
        val fixed = ContainerStyle(margins = SignedContainerEdges(SignedContainerMargin(StyleLengthUnit.Px, 0f),
            SignedContainerMargin(StyleLengthUnit.Px, 7f), SignedContainerMargin(StyleLengthUnit.Px, 0f),
            SignedContainerMargin(StyleLengthUnit.Px, 11f)))
        assertEquals(11f, figureTableNormalLeft(fixed, 200, 140, 1f, 20f, false)!!, 0f)
        assertEquals(53f, figureTableNormalLeft(fixed, 200, 140, 1f, 20f, true)!!, 0f)
        assertNull(figureTableNormalLeft(fixed.copy(floatSide = TableFloatSide.Right), 200, 140, 1f, 20f, false))
        assertEquals(ContainerStyle(), figureTableWrapper(source, 80.0))
        assertEquals(auto, figureTableWrapper(source, 200.0))
        assertThrows(IllegalArgumentException::class.java) { layout().copy(wrapper = auto.copy(height = px(1f))) }
        assertThrows(IllegalArgumentException::class.java) { layout().copy(wrapper = fixed.copy(
            margins = checkNotNull(fixed.margins).let { SignedContainerEdges(it.top, it.right, it.bottom,
                SignedContainerMargin(StyleLengthUnit.Px, -1f)) })) }
        val legacy = source.copy(tableCaptionLayout = null)
        assertSame(legacy, figureTableViewport(legacy, 100.0))
    }

    @Test fun zeroLineHeightKeepsRealFontStrutAndMissingLabelLastBaseline() {
        val normal = figureMediaLine(font, InlineBoxVerticalAlign.Middle, 190f)
        assertEquals(190f, normal.height, 0f)
        assertEquals(0f, normal.contentTop, 0f)
        val large = FigureMediaFont(NativePrimaryFontMetrics(-80f, 20f, 100f, 0f), 50f)
        val tinyImage = figureMediaLine(large, InlineBoxVerticalAlign.Middle, 2f)
        assertEquals(6f, tinyImage.height, 0f) // Strut point -30; image margin box -26..-24.
        assertEquals(4f, tinyImage.contentTop, 0f)
        val missing = figureMediaLine(font, InlineBoxVerticalAlign.Baseline, 30f, 24f)
        assertEquals(30f, missing.height, 0f)
        assertEquals(0f, missing.contentTop, 0f)
        val zero = figureMediaLine(FigureMediaFont(NativePrimaryFontMetrics(0f,0f,0f,0f),0f),
            InlineBoxVerticalAlign.Middle, 0f)
        assertEquals(FigureMediaLine(0f, 0f), zero)
        assertThrows(IllegalArgumentException::class.java) {
            figureMediaLine(font, InlineBoxVerticalAlign.Baseline, 30f)
        }
    }

    @Test fun afterBoxUsesFullAnchorEndAndCompleteStateMayRemoveOnlyItsPaint() {
        val after = FigureMediaAfter(px(15f), px(11f), TableFloatSide.Right, px(6f),
            SignedContainerMargin(StyleLengthUnit.Px, -11f),
            FigureGraphicPaint(FigureMediaGraphic.MagnifyClipLtrV1))
        val value = layout().copy(media = media().copy(positioning = ContainerPositioning.RelativeAuto, after = after))
        val actual = prepared(value).resolve(900, 200).tableCaption!!
        assertEquals(NativeFloatBounds(0f, 0f, 200f, 50f), actual.anchor)
        assertEquals(NativeFloatBounds(179f, 50f, 194f, 61f), actual.after)
        assertEquals(50f, actual.imageLeft, 0f) // Actual media center is independent of the anchor's right edge.
        val narrowState = FigureViewportState(639, ContainerStyle(), value.media.copy(after = after.copy(paint = null)))
        val responsive = value.copy(viewportStates = listOf(narrowState))
        val selected = responsive.stateAtViewport(639.0)!!
        assertNotNull(selected.media.after)
        assertNull(selected.media.after!!.paint)
        assertEquals(actual.after, prepared(responsive.copy(media = selected.media)).resolve(900, 200).tableCaption!!.after)
        val left = prepared(value.copy(media = value.media.copy(after = after.copy(side = TableFloatSide.Left))))
            .resolve(900, 200).tableCaption!!
        assertEquals(NativeFloatBounds(6f, 50f, 21f, 61f), left.after)
    }

    @Test fun mediaPhaseUsesTheExistingEntryOrderAndRejectsUnjoinedNestedPositionedOwners() {
        val tree = listOf(NativePaintOrderNode(0, children = listOf(NativePaintOrderNode(1))),
            NativePaintOrderNode(2), NativePaintOrderNode(3, positioned = true), NativePaintOrderNode(4))
        assertEquals(listOf(0, 1, 2, 4, 11, 3, 14),
            nativeContextMediaPaintSequence(tree, mapOf(1 to 11, 4 to 14)))
        assertEquals(nativeContextPaintSequence(tree), nativeContextMediaPaintSequence(tree, emptyMap()))
        assertThrows(IllegalArgumentException::class.java) {
            nativeContextMediaPaintSequence(tree, mapOf(8 to 18))
        }
        assertThrows(IllegalArgumentException::class.java) {
            nativeContextMediaPaintSequence(tree, mapOf(3 to 13))
        }
        assertThrows(IllegalStateException::class.java) {
            nativeContextMediaPaintSequence(tree, mapOf(1 to 2))
        }
    }

    @Test fun afterOrFocusInAnyCompleteStateRequestsOnlyOuterDocumentOverflow() {
        val after = FigureMediaAfter(px(15f), px(11f), TableFloatSide.Right, px(6f),
            SignedContainerMargin(StyleLengthUnit.Px, -11f))
        val zeroLengths = StyleEdges(px(0f), px(0f), px(0f), px(0f))
        fun figure(style: TableCaptionLayout?) = Figure(FigureContent.Image(
            Span("link", "", "File:control.png", image = InlineImage("control.png", widthPx = 100)), FigureSizingPolicy.RequestedFit),
            FigureFormat.Thumbnail, FigurePlacement.None, FigureClear.None, zeroLengths, zeroLengths, zeroLengths,
            1f, px(20f), FigureColor.Transparent, FigureBorder.None, FigureColor.Transparent, FigureBorder.None,
            FigureColor.NativeTheme, FigureColor.Transparent, tableCaptionLayout = style)
        fun block(style: TableCaptionLayout?) = Block("paragraph", 0, emptyList(), figure = figure(style))
        assertFalse(block(null).needsFigureDocumentExtent())
        assertFalse(block(layout()).needsFigureDocumentExtent())
        val phase = media().copy(positioning = ContainerPositioning.RelativeAuto, after = after)
        val selected = layout().copy(viewportStates = listOf(FigureViewportState(639, ContainerStyle(), phase)))
        val leaf = block(selected)
        assertTrue(leaf.needsFigureDocumentExtent())
        assertFalse(leaf.needsContainerDocumentExtent())
        val table = Table(emptyList(), listOf(listOf(Cell(emptyList(), false, 1, 1, blocks = listOf(leaf)))))
        val nested = Block("container", 0, emptyList(), container = Container(listOf(Block("table", 0, emptyList(), table = table))))
        assertTrue(nested.needsFigureDocumentExtent())
        assertTrue(Block("paragraph", 0, emptyList(), flow = listOf(FlowPart.ImageFigure(figure(selected)))).needsFigureDocumentExtent())
        val focus = media().copy(focusOutline = FigureFocusOutline(px(2f), FigureColor.NativeTheme, px(2f),
            SignedContainerMargin(StyleLengthUnit.Px, 0f)))
        assertTrue(block(layout().copy(media = focus)).needsFigureDocumentExtent())
        assertEquals(NativeDocumentVerticalExtent(2, 53), nativeDocumentVerticalExtent(40, -2, 51))
    }

    @Test fun sourceMagnifyPathsRetainFractionalCoordinatesDirectionAndPaintOrder() {
        val ltr = figureMagnifyRectangles(FigureMediaGraphic.MagnifyClipLtrV1)
        assertEquals(listOf(FigureMagnifyRectangle(1.509f, 1.865f, 12.499f, 9.784f),
            FigureMagnifyRectangle(-1.499f, 6.868f, 4.444f, 11.772f)), ltr)
        val rtl = figureMagnifyRectangles(FigureMediaGraphic.MagnifyClipRtlV1)
        assertEquals(2, rtl.size)
        for (i in ltr.indices) {
            assertEquals(11f - ltr[i].startX, rtl[i].startX, .000002f)
            assertEquals(11f - ltr[i].endX, rtl[i].endX, .000002f)
            assertEquals(ltr[i].top, rtl[i].top, 0f)
            assertEquals(ltr[i].bottom, rtl[i].bottom, 0f)
        }
        assertTrue(ltr[0].endX > 11f && ltr[1].startX < 0f)
    }

    @Test fun negativeOutlineOffsetsClampEachOutsideAxisAndShareExactStrokeExtents() {
        val anchor = NativeFloatBounds(0f, 0f, 10f, 2f)
        val expected = listOf(-100f to NativeFloatBounds(3f, -1f, 7f, 3f),
            -2f to NativeFloatBounds(0f, -1f, 10f, 3f),
            0f to NativeFloatBounds(-2f, -2f, 12f, 4f),
            4f to NativeFloatBounds(-6f, -6f, 16f, 8f))
        for ((offset, ink) in expected) {
            val geometry = checkNotNull(nativeOutlineGeometry(anchor, 2f, 2f, offset))
            assertEquals(ink, geometry.ink)
            assertEquals(NativeFloatBounds(ink.left + 1f, ink.top + 1f, ink.right - 1f, ink.bottom - 1f), geometry.stroke)
            assertTrue(geometry.ink.width >= 4f && geometry.ink.height >= 4f)
            assertTrue(geometry.radiusX in 0f..geometry.stroke.width / 2f)
            assertTrue(geometry.radiusY in 0f..geometry.stroke.height / 2f)
        }
        assertEquals(NativeFloatBounds(8f, 0f, 92f, 4f),
            checkNotNull(nativeOutlineGeometry(NativeFloatBounds(0f, 0f, 100f, 4f), 2f, 2f, -10f)).ink)
        assertEquals(NativeFloatBounds(3f, 5f, 7f, 9f),
            checkNotNull(nativeOutlineGeometry(NativeFloatBounds(5f, 7f, 5f, 7f), 2f, 2f, -100f)).ink)
        assertNull(nativeOutlineGeometry(anchor, 0f, 2f, -100f))
        assertThrows(IllegalArgumentException::class.java) { nativeOutlineGeometry(anchor, 2f, 2f, Float.NaN) }
        assertThrows(UnsupportedFloatLayout::class.java) { nativeOutlineGeometry(anchor, 2f, 2f, Float.MAX_VALUE) }
    }
}
