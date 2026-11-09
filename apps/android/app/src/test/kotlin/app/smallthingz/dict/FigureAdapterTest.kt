package app.smallthingz.dict

import org.junit.Assert.*
import org.junit.Test

/** Source controls for the private adapter; these do not establish native or Compose behavior. */
class FigureAdapterTest {
    private fun px(value: Float) = StyleLength(StyleLengthUnit.Px, value)
    private val zero = StyleEdges(px(0f), px(0f), px(0f), px(0f))
    private fun figure() = Figure(Span("text", "", image = InlineImage("Image.png", widthPx = 3)),
        FigureFormat.Thumbnail, FigurePlacement.None, FigureClear.None, zero, zero, zero,
        .884f, StyleLength(StyleLengthUnit.Em, 1.2376f), FigureColor.NativeTheme, FigureBorder.None,
        FigureColor.Transparent, FigureBorder.None, FigureColor.NativeTheme, FigureColor.Transparent,
        sizing = FigureSizingPolicy.RequestedFit)

    @Test fun inlineAltAndAuthoredControlsKeepSemanticOffsetsWithoutGeneratedCharacters() {
        val authored = "A\u2067he\u2069\ud83d\ude80"
        for (alt in listOf(null, "", "long image alt")) {
            val spans = listOf(Span("text", authored, direction = "rtl"),
                Span("text", "", direction = "ltr", image = InlineImage("Image.png", alt = alt)),
                Span("text", "!"), Span("line_break", ""), Span("text", "tail"))
            val native = "\u2067$authored\u2069\u2066\ufffc\u2069!\ntail"
            val content = anonymousFlowContent(Block("paragraph", 0, spans),
                AnonymousFlowContext(BidiResolvedDirection.Ltr, "en", null))
            val offsets = AnonymousFlowOffsets.build(content,
                { event, text -> anonymousInlineSemantic(event.spans, text) }) { native }
            val expected = authored + alt.orEmpty() + "!\ntail"
            assertEquals(expected, offsets.logicalText)
            assertFalse(offsets.logicalText.contains('\ufffc'))
            assertEquals(1, offsets.logicalText.count { it == '\u2067' })
            val selection = AnonymousFlowSelection.build(offsets) { error("No figure in this control") }
            assertEquals(expected, selection.text)
            if (!alt.isNullOrEmpty()) {
                val replacement = offsets.authored.single { it.replacement }
                assertEquals("\ufffc", offsets.nativeText.substring(replacement.nativeStart, replacement.nativeEnd))
                val start = expected.indexOf(alt)
                for (offset in start until start + alt.length)
                    assertEquals(replacement.nativeStart, selection.nativeOffset(offset))
                assertEquals(start + alt.length, selection.semanticOffset(replacement.nativeEnd))
            } else assertFalse(offsets.authored.any { it.replacement })
            assertThrows(IllegalStateException::class.java) { anonymousInlineSemantic(spans, native + "drift") }
        }
    }

    @Test fun emptyCaptionPaddingAndZeroBordersOwnOnlyTheirExplicitGeometry() {
        val padding = StyleEdges(px(2f), px(3f), px(5f), px(7f))
        val authored = figure().copy(captionPadding = padding, captionBlocks = emptyList())
        val image = FigurePixels(40f, 20f, 40.0, 20.0)
        val empty = figureBoxMetrics(authored, image, 1f, 16f)
        assertEquals(40, empty.width)
        assertEquals(30, empty.captionWidth)
        assertEquals(27, empty.height(0))
        assertEquals(47, empty.height(20))
        val zeroSolid = authored.copy(imageBorder = FigureBorder.Solid(px(0f), FigureColor.NativeTheme),
            frameBorder = FigureBorder.Solid(px(0f), FigureColor.Rgb("#ff0000")))
        assertEquals(empty, figureBoxMetrics(zeroSolid, image, 1f, 16f))
        val transparent = authored.copy(imageBorder = FigureBorder.Solid(px(2f), FigureColor.Transparent))
        val reserved = figureBoxMetrics(transparent, image, 1f, 16f)
        assertEquals(44, reserved.width); assertEquals(31, reserved.height(0))
        assertEquals(50000f, figureLengthPixels(px(50000f), 1f, 16f), 0f)
        assertThrows(UnsupportedFloatLayout::class.java) {
            figureBoxMetrics(authored.copy(captionPadding = padding.copy(left = px(100f))), image, 1f, 16f)
        }
    }

    @Test fun bodyFloatDiscoveryDoesNotPromoteCaptionOrCellContainersIntoOuterFlow() {
        for (direction in androidx.compose.ui.unit.LayoutDirection.entries) {
            val ltr = direction == androidx.compose.ui.unit.LayoutDirection.Ltr
            assertEquals(if (ltr) CellTextAlign.Left else CellTextAlign.Right,
                figureInheritedAlign(androidx.compose.ui.text.style.TextAlign.Start, direction))
            assertEquals(if (ltr) CellTextAlign.Right else CellTextAlign.Left,
                figureInheritedAlign(androidx.compose.ui.text.style.TextAlign.End, direction))
            assertEquals(CellTextAlign.Left, figureInheritedAlign(androidx.compose.ui.text.style.TextAlign.Left, direction))
            assertEquals(CellTextAlign.Right, figureInheritedAlign(androidx.compose.ui.text.style.TextAlign.Right, direction))
            assertEquals(CellTextAlign.Center, figureInheritedAlign(androidx.compose.ui.text.style.TextAlign.Center, direction))
            assertNull(figureInheritedAlign(null, direction))
            assertNull(figureInheritedAlign(androidx.compose.ui.text.style.TextAlign.Unspecified, direction))
            assertThrows(UnsupportedFloatLayout::class.java) {
                figureInheritedAlign(androidx.compose.ui.text.style.TextAlign.Justify, direction)
            }
        }
        val floating = figure().copy(placement = FigurePlacement.FloatRight)
        val nested = FlowPart.Scope(BidiScope(BidiMode.Isolate, BidiDirectionInput.Auto,
            BidiResolvedDirection.Ltr, "", listOf(FlowPart.ImageFigure(floating))))
        assertTrue(Block("paragraph", 0, emptyList(), flow = listOf(nested)).hasBodyFloat())
        assertTrue(Block("list_item", 1, emptyList(), listPath = "*", figure = floating).hasBodyFloat())
        val captionOnly = figure().copy(captionBlocks = listOf(Block("paragraph", 0, emptyList(), figure = floating)))
        assertFalse(Block("paragraph", 0, emptyList(), figure = captionOnly).hasBodyFloat())
        val cell = Cell(emptyList(), false, 1, 1, blocks = listOf(Block("paragraph", 0, emptyList(), figure = floating)))
        assertFalse(Block("table", 0, emptyList(), table = Table(emptyList(), listOf(listOf(cell)))).hasBodyFloat())
    }

    @Test fun sourceAxesRoundBeforeDensityAndHeightBoundsUseSourceFitBoxWidth() {
        val widthOnly = figureImagePixels(figure(), 5, 3, 1.5f)
        assertEquals(3.0, widthOnly.sourceWidth!!, 0.0)
        assertEquals(2.0, widthOnly.sourceHeight!!, 0.0)
        assertEquals(5f, widthOnly.width, 0f); assertEquals(3f, widthOnly.height, 0f)
        val bounded = figure().copy(imageSpan = figure().imageSpan.copy(image = InlineImage("Image.png", widthPx = 400, heightPx = 200)))
        val fit = figureImagePixels(bounded, 400, 300, 1.5f)
        assertEquals(267.0, fit.sourceWidth!!, 0.0); assertEquals(200.0, fit.sourceHeight!!, 0.0)
        assertEquals(401f, fit.width, 0f); assertEquals(300f, fit.height, 0f)
        assertNotEquals(fit.width.toDouble() / 1.5, fit.sourceWidth)
        val floorBound = bounded.copy(imageSpan = bounded.imageSpan.copy(image = InlineImage("Image.png", widthPx = 5, heightPx = 3)))
        val floorFit = figureImagePixels(floorBound, 5, 9, 1f)
        assertEquals(1.0, floorFit.sourceWidth!!, 0.0); assertEquals(3.0, floorFit.sourceHeight!!, 0.0)
        val framed = figureImagePixels(bounded.copy(format = FigureFormat.Framed,
            sizing = FigureSizingPolicy.Intrinsic), 5, 3, 1.5f)
        assertEquals(FigurePixels(8f, 5f, 5.0, 3.0), framed)
        val upscale = figure().copy(imageSpan = figure().imageSpan.copy(image = InlineImage("Image.png", widthPx = 6)))
        assertEquals(FigurePixels(6f, 4f, 6.0, 4.0), figureImagePixels(upscale, 5, 3, 1f))
        assertEquals(FigurePixels(5f, 3f, 5.0, 3.0), figureImagePixels(
            upscale.copy(sizing = FigureSizingPolicy.RequestedFitCapOriginalWidth), 5, 3, 1f))
        val tiny = figure().copy(imageSpan = figure().imageSpan.copy(image = InlineImage("Image.png", widthPx = 1)))
        assertEquals(FigurePixels(1f, 0f, 1.0, 0.0), figureImagePixels(tiny, 4000, 1, 1f))
    }

    @Test fun frameMinimumOwnsContentWidthWithoutResizingImageOrAddingBordersTwice() {
        val base = figure().copy(imageSpan = figure().imageSpan.copy(image = InlineImage("Image.png", widthPx = 20)),
            frameBorder = FigureBorder.Solid(px(1f), FigureColor.NativeTheme),
            imageBorder = FigureBorder.Solid(px(2f), FigureColor.NativeTheme),
            imageInsets = StyleEdges(px(3f), px(5f), px(7f), px(11f)),
            captionPadding = StyleEdges(px(0f), px(13f), px(0f), px(17f)),
            margins = StyleEdges(px(19f), px(23f), px(29f), px(31f)),
            caption = listOf(Span("text", "The entire caption remains independently laid out.")))
        val image = figureImagePixels(base, 20, 10, 1f)
        val natural = figureBoxMetrics(base, image, 1f, 16f)
        val explicitZero = figureBoxMetrics(base.copy(frameMinWidth = px(0f)), image, 1f, 16f)
        assertEquals(natural, explicitZero.copy(frameMinWidth = null))
        assertFalse(explicitZero.frameMinimumWidens)
        val widenedFigure = base.copy(frameMinWidth = px(100f))
        val widened = figureBoxMetrics(widenedFigure, figureImagePixels(widenedFigure, 20, 10, 1f), 1f, 16f)
        assertEquals(40f, natural.innerWidth, 0f)
        assertEquals(100f, widened.innerWidth, 0f); assertEquals(102, widened.width)
        assertEquals(70, widened.captionWidth); assertTrue(widened.frameMinimumWidens)
        assertEquals(natural.image, widened.image); assertEquals(natural.margins, widened.margins)
        assertEquals(natural.imageLeft, widened.imageLeft, 0f)
        assertEquals(natural.imageTop, widened.imageTop, 0f)
        assertEquals(natural.captionTop, widened.captionTop, 0f)
        assertEquals(natural.height(37), widened.height(37))
        assertEquals(base.caption, widenedFigure.caption)
        val scaled = figureBoxMetrics(widenedFigure, figureImagePixels(widenedFigure, 20, 10, 1.5f), 1.5f, 24f)
        assertEquals(150f, scaled.innerWidth, 0f); assertEquals(153, scaled.width)
        assertEquals(FigurePixels(30f, 15f, 20.0, 10.0), scaled.image)
        val larger = figureBoxMetrics(widenedFigure, FigurePixels(180f, 90f, 180.0, 90.0), 1f, 16f)
        assertEquals(202, larger.width); assertFalse(larger.frameMinimumWidens)
        assertThrows(IllegalArgumentException::class.java) {
            base.copy(frameMinWidth = StyleLength(StyleLengthUnit.Em, 1f))
        }
        assertThrows(UnsupportedFloatLayout::class.java) {
            figureBoxMetrics(base.copy(frameMinWidth = px(Float.MAX_VALUE)), image, 1f, 16f)
        }
    }
}
