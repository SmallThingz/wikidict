package app.smallthingz.dict

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.RectF
import android.text.SpannableString
import android.text.TextPaint
import android.view.View
import android.view.accessibility.AccessibilityNodeInfo
import android.view.accessibility.AccessibilityNodeProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class FigureAdapterGeometryTest {
    private val paint = TextPaint().apply { textSize = 20f }
    private fun figure(side: FigurePlacement): Figure {
        val zero = StyleLength(StyleLengthUnit.Px, 0f)
        val edges = StyleEdges(zero, zero, zero, zero)
        return Figure(FigureContent.Image(Span("link", "", "Image", image = InlineImage("Image.png", widthPx = 80)), FigureSizingPolicy.RequestedFit),
            FigureFormat.Thumbnail, side, FigureClear.None, edges, edges, edges,
            .884f, StyleLength(StyleLengthUnit.Em, 1.2376f), FigureColor.NativeTheme, FigureBorder.None,
            FigureColor.Transparent, FigureBorder.None, FigureColor.NativeTheme, FigureColor.Transparent,
            caption = listOf(Span("text", "caption")))
    }

    @Test fun outerFloatOwnerKeepsCaptionSelectionActionsAndFollowingParagraphExclusion() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        instrumentation.runOnMainSync {
            for (side in listOf(FigurePlacement.FloatLeft, FigurePlacement.FloatRight)) {
                var clicks = 0
                val caption = NativeFloatGeometry.build(SpannableString("caption"), paint, 80, emptyList(),
                    nodeFactory = { g -> listOf(FloatInteractionNode(0, FloatInteractionKind.LINK, 0, 7,
                        g.rectsForRange(0, 7), "caption", null, { clicks++ })) })
                val child = NativeSemanticGroup(80, 160,
                    listOf(PositionedSemanticChild(caption, 0f, 100f, BidiResolvedDirection.Ltr)))
                val content = anonymousFlowContent(Block("paragraph", 0, emptyList(), flow = listOf(
                    FlowPart.Inline(listOf(Span("text", "before "))), FlowPart.ImageFigure(figure(side)),
                    FlowPart.Inline(listOf(Span("text", " after"))))),
                    AnonymousFlowContext(BidiResolvedDirection.Ltr, "en", null))
                var actual: NativeAnonymousFlowGeometry? = null
                val flow = NativeFloatContextPart.Flow(1, { width, carried ->
                    NativeAnonymousFlowGeometry.build(content, paint, width, { SpannableString(textOf(it.spans)) },
                        { _, _ -> MeasuredAnonymousFigure(child, FloatMargins(0f, 0f, 0f, 0f)) },
                        carriedExclusions = carried).also { actual = it }
                })
                val following = "following body remains outside the figure"
                val ordinary = NativeFloatContextPart.Text(following, { width, carried ->
                    NativeFloatGeometry.build(SpannableString(following), paint, width, emptyList(), carriedExclusions = carried)
                })
                val owner = NativeFloatContextGeometry.build(260, listOf(flow, ordinary))
                val expected = "before caption after\n$following"
                assertEquals(expected, owner.text.toString())
                assertFalse(owner.text.contains('\ufffc'))
                assertEquals(1, owner.flowChildren.size)
                val figureBounds = checkNotNull(actual).figures.single().bounds
                val next = expected.indexOf(following)
                owner.characterRects(next, following.length).filterNotNull().forEach { rect ->
                    assertFalse("Following text must respect the actual carried figure", RectF.intersects(rect, figureBounds))
                }
                assertEquals(checkNotNull(actual).rectsForRange(8, 13), owner.rectsForRange(8, 13))
                val view = NativeFloatTextView(instrumentation.targetContext)
                view.bind({ owner }, 0x6633b5e5, 0xff1686c7.toInt())
                view.measure(View.MeasureSpec.makeMeasureSpec(260, View.MeasureSpec.EXACTLY),
                    View.MeasureSpec.makeMeasureSpec(1000, View.MeasureSpec.AT_MOST))
                view.layout(0, 0, view.measuredWidth, view.measuredHeight)
                view.setSelection(2, expected.length - 3)
                assertEquals(expected.substring(2, expected.length - 3), view.selectedTextForCopy())
                val host = view.accessibilityNodeProvider.createAccessibilityNodeInfo(AccessibilityNodeProvider.HOST_VIEW_ID)!!
                try { assertEquals(expected, host.text.toString()); assertEquals(1, host.childCount) }
                finally { host.recycle() }
                assertTrue(view.accessibilityNodeProvider.performAction(owner.nodes.single().id, AccessibilityNodeInfo.ACTION_CLICK, null))
                assertEquals(1, clicks)
            }
        }
    }

    @Test fun zeroAndTransparentFigureBordersHaveDistinctPaintWithoutInventedCaptionLine() {
        val px = { value: Float -> StyleLength(StyleLengthUnit.Px, value) }
        val base = figure(FigurePlacement.Center).copy(caption = emptyList(),
            captionPadding = StyleEdges(px(2f), px(0f), px(3f), px(0f)))
        for (border in listOf(FigureBorder.None, FigureBorder.Solid(px(0f), FigureColor.Rgb("#ff0000")),
            FigureBorder.Solid(px(2f), FigureColor.Transparent))) {
            val metrics = figureBoxMetrics(base.copy(imageBorder = border), FigurePixels(20f, 10f), 1f, 20f)
            val geometry = NativeFigureGeometry(metrics, EmptyCaptionGeometry(metrics.captionWidth),
                FigurePaints(Color.TRANSPARENT, Color.TRANSPARENT, Color.TRANSPARENT,
                    if (border is FigureBorder.Solid && border.color == FigureColor.Transparent) Color.TRANSPARENT else Color.RED,
                    Color.TRANSPARENT),
                { canvas, bounds -> canvas.drawRect(bounds, android.graphics.Paint().apply { color = Color.BLUE }) }, { emptyList() })
            assertEquals(if (border is FigureBorder.Solid && border.width.value > 0) 19 else 15, geometry.height)
            assertEquals("", geometry.text.toString()); assertTrue(geometry.nodes.isEmpty())
            val bitmap = Bitmap.createBitmap(geometry.width, geometry.height, Bitmap.Config.ARGB_8888)
            try {
                geometry.paint(Canvas(bitmap))
                val pixels = IntArray(bitmap.width * bitmap.height)
                bitmap.getPixels(pixels, 0, bitmap.width, 0, 0, bitmap.width, bitmap.height)
                assertEquals(200, pixels.count { it == Color.BLUE })
                assertFalse("A zero solid border must not paint a hairline", pixels.any { it == Color.RED })
            } finally { bitmap.recycle() }
        }
    }

    @Test fun richCaptionKeyboardVisitsSeparatedBoundariesAndSharedCellOwnersWithoutSkippingText() {
        fun text(value: String) = NativeFloatGeometry.build(SpannableString(value), paint, 80, emptyList())
        val first = text("a")
        val second = text("b")
        val separated = NativeSemanticGroup(80, first.height + second.height, listOf(
            PositionedSemanticChild(first, 0f, 0f, BidiResolvedDirection.Ltr),
            PositionedSemanticChild(second, 0f, first.height.toFloat(), BidiResolvedDirection.Ltr, "\n")))
        assertEquals("a\nb", separated.text)
        assertEquals(2, separated.visualOffset(1, 1))
        assertEquals(3, separated.visualOffset(2, 1))
        assertEquals(1, separated.visualOffset(2, -1))
        assertEquals(0, separated.visualOffset(1, -1))
        val adjacent = NativeSemanticGroup(160, maxOf(first.height, second.height), listOf(
            PositionedSemanticChild(first, 0f, 0f, BidiResolvedDirection.Ltr),
            PositionedSemanticChild(second, 80f, 0f, BidiResolvedDirection.Ltr)))
        assertEquals("ab", adjacent.text)
        assertEquals(0, adjacent.visualOffset(1, -1))
        assertEquals(2, adjacent.visualOffset(1, 1))
        assertEquals(first.characterRects(0, 1) + listOf(null) + second.characterRects(0, 1).map {
            it?.let { rect -> RectF(rect).apply { offset(0f, first.height.toFloat()) } }
        }, separated.characterRects(0, 3))
    }

    @Test fun compiledSizingControlsPaintedImageBoundsAndZeroHeightKeepsOnlyCaptionPadding() {
        val zero = StyleLength(StyleLengthUnit.Px, 0f)
        val base = figure(FigurePlacement.Center).copy(caption = emptyList(),
            captionPadding = StyleEdges(StyleLength(StyleLengthUnit.Px, 2f), zero,
                StyleLength(StyleLengthUnit.Px, 3f), zero))
        val variants = listOf(
            Triple(base.copy(content = (base.content as FigureContent.Image).copy(span = base.content.span.copy(image = InlineImage("Image.png", widthPx = 10)))),
                5L to 4L, 10 to 8),
            Triple(base.copy(content = (base.content as FigureContent.Image).copy(span = base.content.span.copy(image = InlineImage("Image.png", widthPx = 10)), sizing = FigureSizingPolicy.RequestedFitCapOriginalWidth)), 5L to 4L, 5 to 4),
            Triple(base.copy(content = (base.content as FigureContent.Image).copy(span = base.content.span.copy(image = InlineImage("Image.png", widthPx = 1)))),
                3L to 1L, 1 to 0))
        for ((value, original, expected) in variants) {
            val pixels = figureImagePixels(value, original.first, original.second, 1f)
            val metrics = figureBoxMetrics(value, pixels, 1f, 20f)
            var paintedBounds: RectF? = null
            val geometry = NativeFigureGeometry(metrics, EmptyCaptionGeometry(metrics.captionWidth),
                FigurePaints(Color.TRANSPARENT, Color.TRANSPARENT, Color.TRANSPARENT, Color.TRANSPARENT, Color.TRANSPARENT),
                { canvas, bounds ->
                    paintedBounds = RectF(bounds)
                    canvas.drawRect(bounds, android.graphics.Paint().apply { color = Color.BLUE })
                }, { emptyList() })
            assertEquals(expected.first, geometry.width)
            assertEquals(expected.second + 5, geometry.height)
            assertEquals("", geometry.text.toString())
            assertTrue(geometry.nodes.isEmpty())
            assertTrue(geometry.rectsForRange(0, 0).isEmpty())
            val bitmap = Bitmap.createBitmap(geometry.width, geometry.height, Bitmap.Config.ARGB_8888)
            try {
                geometry.paint(Canvas(bitmap))
                assertEquals(RectF(0f, 0f, expected.first.toFloat(), expected.second.toFloat()), paintedBounds)
                val raster = IntArray(bitmap.width * bitmap.height)
                bitmap.getPixels(raster, 0, bitmap.width, 0, 0, bitmap.width, bitmap.height)
                assertEquals(expected.first * expected.second, raster.count { it == Color.BLUE })
                assertEquals(expected.second == 0, geometry.imageBounds.isEmpty)
            } finally { bitmap.recycle() }
        }
    }

    @Test fun contentMinimumOverflowsNarrowParentWithFullCaptionPaintAndSemanticRanges() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        instrumentation.runOnMainSync {
            val px = { value: Float -> StyleLength(StyleLengthUnit.Px, value) }
            val captionText = "Complete caption remains visible in source order across several wrapped lines."
            for (placement in listOf(FigurePlacement.None, FigurePlacement.Center)) {
                val value = figure(placement).copy(content = (figure(placement).content as FigureContent.Image).copy(span = figure(placement).content.span.copy(image = InlineImage("Image.png", widthPx = 20))),
                    frameMinWidth = px(100f), frameBorder = FigureBorder.Solid(px(1f), FigureColor.Rgb("#ff0000")),
                    caption = listOf(Span("text", captionText)))
                val metrics = figureBoxMetrics(value, figureImagePixels(value, 20, 10, 1f), 1f, 20f)
                assertEquals(100, metrics.captionWidth); assertEquals(102, metrics.width)
                val caption = NativeFloatGeometry.build(SpannableString(captionText), paint, metrics.captionWidth, emptyList())
                var paintedImage: RectF? = null
                val child = NativeFigureGeometry(metrics, caption,
                    FigurePaints(Color.WHITE, Color.RED, Color.TRANSPARENT, Color.TRANSPARENT, Color.TRANSPARENT),
                    { canvas, bounds -> paintedImage = RectF(bounds)
                        canvas.drawRect(bounds, android.graphics.Paint().apply { color = Color.BLUE }) }, { emptyList() })
                assertEquals(captionText, child.text.toString())
                assertEquals(RectF(1f, 1f, 21f, 11f), child.imageBounds)
                val content = anonymousFlowContent(Block("paragraph", 0, emptyList(), flow = listOf(
                    FlowPart.Inline(listOf(Span("text", "before "))), FlowPart.ImageFigure(value),
                    FlowPart.Inline(listOf(Span("text", " after"))))),
                    AnonymousFlowContext(BidiResolvedDirection.Ltr, "en", null))
                val flow = NativeAnonymousFlowGeometry.build(content, paint, 60,
                    { SpannableString(textOf(it.spans)) },
                    { _, _ -> MeasuredAnonymousFigure(child, FloatMargins(0f, 0f, 0f, 0f), metrics.frameMinimumWidens) })
                val bounds = flow.figures.single().bounds
                assertEquals(102f, bounds.width(), 0f)
                assertEquals(if (placement == FigurePlacement.Center) -21f else 0f, bounds.left, 0.01f)
                assertTrue(bounds.right > flow.width)
                val expected = "before $captionText after"
                assertEquals(expected, flow.text.toString()); assertFalse(flow.text.contains('\ufffc'))
                val first = "before ".length
                val range = child.rectsForRange(0, captionText.length).map { RectF(it).apply { offset(bounds.left, bounds.top) } }
                assertEquals(range, flow.rectsForRange(first, first + captionText.length))
                assertTrue("The complete caption wraps, without truncation", range.map { it.top }.distinct().size > 1)
                val character = flow.characterRects(first, 1).single()!!
                assertEquals(first, flow.offsetForPosition(character.left + character.width() * .2f, character.centerY()))
                assertEquals(child.caretRect(captionText.length - 1).apply { offset(bounds.left, bounds.top) },
                    flow.caretRect(first + captionText.length - 1))
                val view = NativeFloatTextView(instrumentation.targetContext)
                view.bind({ flow }, 0x6633b5e5, 0xff1686c7.toInt())
                view.measure(View.MeasureSpec.makeMeasureSpec(60, View.MeasureSpec.EXACTLY),
                    View.MeasureSpec.makeMeasureSpec(flow.height, View.MeasureSpec.EXACTLY))
                view.layout(0, 0, view.measuredWidth, view.measuredHeight)
                view.setSelection(0, expected.length)
                assertEquals(expected, view.selectedTextForCopy())
                // A wider canvas observes native overflow paint; View/Compose viewport input is separate.
                val bitmap = Bitmap.createBitmap(180, flow.height + 4, Bitmap.Config.ARGB_8888)
                try {
                    val canvas = Canvas(bitmap); canvas.translate(32f, 0f); flow.paint(canvas)
                    assertEquals(child.imageBounds, paintedImage)
                    val raster = IntArray(bitmap.width * bitmap.height)
                    bitmap.getPixels(raster, 0, bitmap.width, 0, 0, bitmap.width, bitmap.height)
                    assertEquals(200, raster.count { it == Color.BLUE })
                    assertEquals(Color.RED, bitmap.getPixel((32 + bounds.right - 1).toInt(), (bounds.top + 2).toInt()))
                } finally { bitmap.recycle() }
                assertThrows(UnsupportedFloatLayout::class.java) {
                    NativeAnonymousFlowGeometry.build(content, paint, 60, { SpannableString(textOf(it.spans)) },
                        { _, _ -> MeasuredAnonymousFigure(child, FloatMargins(0f, 0f, 0f, 0f)) })
                }
            }
        }
    }
}
