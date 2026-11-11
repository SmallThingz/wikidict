package app.smallthingz.dict

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Path
import android.graphics.RectF
import android.graphics.Typeface
import android.text.Layout
import android.text.SpannableString
import android.text.Spanned
import android.text.StaticLayout
import android.text.TextDirectionHeuristics
import android.text.TextPaint
import android.text.style.BackgroundColorSpan
import android.text.style.ForegroundColorSpan
import android.text.style.LeadingMarginSpan
import android.text.style.ReplacementSpan
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

/** Native flow primitives only; the complete container Compose surface is qualified separately. */
@RunWith(AndroidJUnit4::class)
class NativeFlowOverflowDeviceTest {
    private class OwnedImage(private val color: Int, private val advance: Int = 18) : ReplacementSpan() {
        var draws = 0
        override fun getSize(paint: Paint, text: CharSequence, start: Int, end: Int,
            fm: Paint.FontMetricsInt?): Int {
            fm?.let { it.ascent = -12; it.descent = 4; it.top = -12; it.bottom = 4 }
            return advance
        }
        override fun draw(canvas: Canvas, text: CharSequence, start: Int, end: Int,
            x: Float, top: Int, y: Int, bottom: Int, paint: Paint) {
            draws++
            val old = paint.color
            try {
                paint.color = color
                canvas.drawRect(x, y - 12f, x + advance, y + 4f, paint)
            } finally { paint.color = old }
        }
    }

    @Test fun zeroContainingWidthKeepsOriginalInlineOwnersPixelsAndActionBounds() {
        val first = OwnedImage(Color.RED)
        val second = OwnedImage(Color.BLUE)
        val source = SpannableString("\ufffc\n\ufffc").apply {
            setSpan(first, 0, 1, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
            setSpan(second, 2, 3, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        }
        var activated = 0
        val geometry = NativeFloatGeometry.build(source, TextPaint().apply { textSize = 18f }, 0,
            emptyList(), nodeFactory = { g -> listOf(FloatInteractionNode(0, FloatInteractionKind.LINK,
                2, 3, g.rectsForRange(2, 3), "Second image", null, { activated++ })) })
        assertEquals(0, geometry.width)
        assertEquals(source.toString(), geometry.text.toString())
        assertTrue(geometry.height > 0)
        val image = Bitmap.createBitmap(64, geometry.height + 32, Bitmap.Config.ARGB_8888)
        try {
            val canvas = Canvas(image)
            canvas.translate(8f, 8f)
            geometry.paint(canvas)
            assertEquals(1, first.draws)
            assertEquals(1, second.draws)
            val pixels = IntArray(image.width * image.height)
            image.getPixels(pixels, 0, image.width, 0, 0, image.width, image.height)
            assertTrue(pixels.count { it == Color.RED } > 100)
            assertTrue(pixels.count { it == Color.BLUE } > 100)
            val firstBounds = geometry.characterRects(0, 1).single()!!
            val secondBounds = geometry.characterRects(2, 1).single()!!
            assertTrue(firstBounds.width() >= 18f && secondBounds.width() >= 18f)
            assertTrue(secondBounds.top >= firstBounds.bottom)
            val node = geometry.nodes.single()
            assertEquals(listOf(secondBounds), node.bounds)
            node.onClick!!()
            assertEquals(1, activated)
            assertEquals(2, geometry.offsetForPosition(secondBounds.left + 1f, secondBounds.centerY()))
            assertSame(first, source.getSpans(0, 1, ReplacementSpan::class.java).single())
            assertSame(second, source.getSpans(2, 3, ReplacementSpan::class.java).single())
        } finally { image.recycle() }
    }

    @Test fun zeroWidthWithAuthoredGuttersKeepsNativeOverflowPaintAndSelection() {
        for (direction in listOf(TextDirectionHeuristics.LTR, TextDirectionHeuristics.RTL)) {
            for (alignment in listOf(Layout.Alignment.ALIGN_NORMAL, Layout.Alignment.ALIGN_CENTER,
                Layout.Alignment.ALIGN_OPPOSITE)) {
                val owner = OwnedImage(Color.RED, 24)
                val source = SpannableString("\ufffc").apply {
                    setSpan(owner, 0, 1, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
                }
                val paint = TextPaint().apply { textSize = 18f }
                val zero = nativeInlineLineMetrics(-12f, 4f, 0f)
                val insets = NativeTextInsets(left = 10f, right = 5f, extraLeft = 2f, extraRight = 2f)
                var activated = 0
                val geometry = NativeFloatGeometry.build(source, paint, 0, emptyList(),
                    alignment = alignment, textDirection = direction, insets = insets,
                    usedLineMetrics = { _, _ -> zero }, nodeFactory = { g -> listOf(
                        FloatInteractionNode(0, FloatInteractionKind.LINK, 0, 1, g.rectsForRange(0, 1),
                            "Overflowing image", null, { activated++ })) })
                val native = StaticLayout.Builder.obtain(source, 0, source.length, TextPaint(paint), 0)
                    .setAlignment(alignment).setTextDirection(direction).setIncludePad(true)
                    .setLineSpacing(0f, 1f)
                    .setBreakStrategy(android.graphics.text.LineBreaker.BREAK_STRATEGY_SIMPLE)
                    .setHyphenationFrequency(Layout.HYPHENATION_FREQUENCY_NONE)
                    .setIndents(intArrayOf(12, 0), intArrayOf(7, 0)).build()
                assertEquals(1, native.lineCount)
                assertEquals(0, geometry.width); assertEquals(0, geometry.height)
                assertEquals(12f, geometry.firstLineBand().left, 0f)
                assertEquals(-7f, geometry.firstLineBand().right, 0f)
                assertEquals(-zero.top, geometry.baselineForOffset(0), 0f)
                val path = Path()
                native.getSelectionPath(0, 1, path)
                val expectedBounds = RectF()
                path.computeBounds(expectedBounds, true)
                expectedBounds.offset(0f, -zero.top - native.getLineBaseline(0))
                val bounds = geometry.characterRects(0, 1).single()!!
                assertEquals(expectedBounds, bounds)
                assertTrue(bounds.width() >= 24f && bounds.top < 0f && bounds.bottom > 0f)
                assertEquals(listOf(bounds), geometry.nodes.single().bounds)
                assertTrue(geometry.nodes.single().contains(bounds.centerX(), bounds.centerY()))
                geometry.nodes.single().onClick!!()
                assertEquals(1, activated)
                assertEquals(native.getOffsetForHorizontal(0, bounds.centerX()),
                    geometry.offsetForPosition(bounds.centerX(), bounds.centerY()))
                val expected = Bitmap.createBitmap(160, 160, Bitmap.Config.ARGB_8888)
                val actual = Bitmap.createBitmap(160, 160, Bitmap.Config.ARGB_8888)
                try {
                    Canvas(expected).apply {
                        translate(80f, 80f - zero.top - native.getLineBaseline(0)); native.draw(this)
                    }
                    assertEquals(1, owner.draws)
                    owner.draws = 0
                    Canvas(actual).apply { translate(80f, 80f); geometry.paint(this) }
                    assertEquals(1, owner.draws)
                    val expectedPixels = IntArray(160 * 160)
                    val actualPixels = IntArray(expectedPixels.size)
                    expected.getPixels(expectedPixels, 0, 160, 0, 0, 160, 160)
                    actual.getPixels(actualPixels, 0, 160, 0, 0, 160, 160)
                    assertTrue(expectedPixels.count { it == Color.RED } > 100)
                    assertArrayEquals("Native zero-lane paint $direction/$alignment", expectedPixels, actualPixels)
                    assertSame(owner, source.getSpans(0, 1, ReplacementSpan::class.java).single())
                } finally { expected.recycle(); actual.recycle() }
            }
        }
    }

    @Test fun zeroWidthGuttersClearTemporaryFloatWithoutLosingEitherOwner() {
        val inline = OwnedImage(Color.BLUE, 24)
        val source = SpannableString("\ufffc\ufffc").apply {
            setSpan(inline, 1, 2, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        }
        var floatDraws = 0
        val occurrence = NativeFloatOccurrence(0, 0, 10f, 30f, TableFloatSide.Left,
            NativeFloatClear.None, FloatMargins(0f, 0f, 0f, 0f)) { canvas, bounds ->
            floatDraws++
            canvas.drawRect(bounds, Paint().apply { color = Color.RED })
        }
        val zero = nativeInlineLineMetrics(-12f, 4f, 0f)
        val geometry = NativeFloatGeometry.build(source, TextPaint().apply { textSize = 18f }, 0,
            listOf(occurrence), insets = NativeTextInsets(left = 12f, right = 7f),
            usedLineMetrics = { _, _ -> zero })
        assertEquals(0, geometry.width)
        assertEquals(30, geometry.height)
        assertEquals(30f, geometry.textBottom, 0f)
        assertEquals(30f - zero.top, geometry.baselineForOffset(1), 0f)
        assertSame(occurrence, geometry.floats.single().occurrence)
        assertEquals(RectF(0f, 0f, 10f, 30f), geometry.floats.single().content)
        val image = Bitmap.createBitmap(96, 96, Bitmap.Config.ARGB_8888)
        try {
            Canvas(image).apply { translate(24f, 24f); geometry.paint(this) }
            assertEquals(1, floatDraws); assertEquals(1, inline.draws)
            val pixels = IntArray(96 * 96)
            image.getPixels(pixels, 0, 96, 0, 0, 96, 96)
            assertEquals(300, pixels.count { it == Color.RED })
            assertEquals(24 * 16, pixels.count { it == Color.BLUE })
            assertSame(inline, source.getSpans(1, 2, ReplacementSpan::class.java).single())
        } finally { image.recycle() }
    }

    @Test fun batchedFlowPaintMatchesNativeLayoutForOrdinaryStyledParagraphs() {
        val source = SpannableString("First styled line\nSecond line with a margin").apply {
            setSpan(BackgroundColorSpan(Color.YELLOW), 0, 12, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
            setSpan(LeadingMarginSpan.Standard(12, 6), 0, length, Spanned.SPAN_INCLUSIVE_EXCLUSIVE)
        }
        val paint = TextPaint(Paint.ANTI_ALIAS_FLAG).apply { textSize = 21f; color = Color.BLACK }
        for (alignment in listOf(Layout.Alignment.ALIGN_NORMAL, Layout.Alignment.ALIGN_CENTER,
            Layout.Alignment.ALIGN_OPPOSITE)) {
            val native = StaticLayout.Builder.obtain(source, 0, source.length, TextPaint(paint), 120)
                .setAlignment(alignment).setTextDirection(TextDirectionHeuristics.FIRSTSTRONG_LTR)
                .setIncludePad(true).setLineSpacing(0f, 1f)
                .setBreakStrategy(android.graphics.text.LineBreaker.BREAK_STRATEGY_SIMPLE)
                .setHyphenationFrequency(Layout.HYPHENATION_FREQUENCY_NONE).build()
            val geometry = NativeFloatGeometry.build(source, paint, 120, emptyList(), alignment = alignment)
            assertEquals(native.height, geometry.height)
            val expected = Bitmap.createBitmap(160, native.height + 40, Bitmap.Config.ARGB_8888)
            val actual = Bitmap.createBitmap(expected.width, expected.height, Bitmap.Config.ARGB_8888)
            try {
                Canvas(expected).apply { translate(20f, 20f); native.draw(this) }
                Canvas(actual).apply { translate(20f, 20f); geometry.paint(this) }
                val left = IntArray(expected.width * expected.height)
                val right = IntArray(left.size)
                expected.getPixels(left, 0, expected.width, 0, 0, expected.width, expected.height)
                actual.getPixels(right, 0, actual.width, 0, 0, actual.width, actual.height)
                assertArrayEquals("Native paint parity for $alignment", left, right)
            } finally { expected.recycle(); actual.recycle() }
        }
    }
    @Test fun zeroUsedLinesKeepCoincidentBaselinesAndSignedInkSelectionExtents() {
        val source = SpannableString("W\nI").apply {
            setSpan(ForegroundColorSpan(Color.RED), 0, 1, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
            setSpan(ForegroundColorSpan(Color.BLUE), 2, 3, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        }
        val paint = TextPaint(Paint.ANTI_ALIAS_FLAG).apply { textSize = 24f; typeface = Typeface.MONOSPACE }
        val metrics = paint.fontMetrics
        val zero = nativeInlineLineMetrics(metrics.ascent, metrics.descent, 0f)
        var activated = 0
        val geometry = NativeFloatGeometry.build(source, paint, 0, emptyList(),
            usedLineMetrics = { _, _ -> zero }, nodeFactory = { g -> listOf(
                FloatInteractionNode(0, FloatInteractionKind.LINK, 2, 3, g.rectsForRange(2, 3),
                    "Second visible glyph", null, { activated++ })) })
        assertEquals(0, geometry.width)
        assertEquals(0, geometry.height)
        assertEquals(0f, geometry.textBottom, 0f)
        assertEquals(-zero.top, geometry.baselineForOffset(0), 0f)
        assertEquals(geometry.baselineForOffset(0), geometry.baselineForOffset(2), 0f)
        val image = Bitmap.createBitmap(96, 96, Bitmap.Config.ARGB_8888)
        try {
            Canvas(image).apply { translate(32f, 32f); geometry.paint(this) }
            val pixels = IntArray(image.width * image.height)
            image.getPixels(pixels, 0, image.width, 0, 0, image.width, image.height)
            assertTrue("Earlier native glyph ink survives outside the used box", pixels.count { it == Color.RED } > 10)
            assertTrue("Later coincident glyph still paints", pixels.count { it == Color.BLUE } > 10)
            val bounds = geometry.characterRects(2, 1).single()!!
            assertTrue(bounds.width() > 0f && bounds.top < 0f && bounds.bottom > 0f)
            assertTrue(geometry.caretRect(2).height() > 0f)
            val node = geometry.nodes.single()
            assertEquals(listOf(bounds), node.bounds)
            assertTrue(node.contains(bounds.centerX(), bounds.centerY()))
            node.onClick!!()
            assertEquals(1, activated)
            assertEquals(2, geometry.lineRange(geometry.offsetForPosition(bounds.left + 1f, bounds.centerY())).first)
        } finally { image.recycle() }
    }

    @Test fun overlappingZeroUsedLinesKeepExposedWiderSelectionAndLaterSharedAdvance() {
        for (literal in listOf("\ufffc\n\ufffc", "\ufffc\ufffc")) {
            val secondOffset = literal.lastIndex
            val wide = OwnedImage(Color.RED, 48)
            val narrow = OwnedImage(Color.BLUE, 12)
            val source = SpannableString(literal).apply {
                setSpan(wide, 0, 1, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
                setSpan(narrow, secondOffset, secondOffset + 1, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
            }
            val paint = TextPaint().apply { textSize = 18f }
            val zero = nativeInlineLineMetrics(-12f, 4f, 0f)
            val actions = mutableListOf<Int>()
            val geometry = NativeFloatGeometry.build(source, paint, 0, emptyList(),
                usedLineMetrics = { _, _ -> zero }, nodeFactory = { g -> listOf(
                    FloatInteractionNode(0, FloatInteractionKind.LINK, 0, 1, g.rectsForRange(0, 1),
                        "Wide earlier image", null, { actions += 0 }),
                    FloatInteractionNode(1, FloatInteractionKind.LINK, secondOffset, secondOffset + 1,
                        g.rectsForRange(secondOffset, secondOffset + 1), "Narrow later image", null, { actions += 1 })) })
            assertEquals(0, geometry.width)
            assertEquals(0, geometry.height)
            assertEquals(geometry.baselineForOffset(0), geometry.baselineForOffset(secondOffset), 0f)
            val y = geometry.baselineForOffset(0) - 4f
            val sharedX = 3f
            val exposedX = 18f // Past the later 12px advance, before the earlier 48px midpoint.
            assertEquals("Later selectable content owns the shared interval", secondOffset,
                geometry.offsetForPosition(sharedX, y))
            assertEquals("The narrower later line cannot occlude the earlier selectable wing", 0,
                geometry.offsetForPosition(exposedX, y))
            // The real input surface also resolves its published node bounds in reverse order.
            val shared = geometry.nodes.last { it.contains(sharedX, y) }
            val exposed = geometry.nodes.last { it.contains(exposedX, y) }
            assertEquals(1, shared.id)
            assertEquals(0, exposed.id)
            shared.onClick!!(); exposed.onClick!!()
            assertEquals(listOf(1, 0), actions)
            val image = Bitmap.createBitmap(80, 48, Bitmap.Config.ARGB_8888)
            try {
                Canvas(image).apply { translate(8f, 24f); geometry.paint(this) }
                assertEquals(Color.BLUE, image.getPixel((8f + sharedX).toInt(), (24f + y).toInt()))
                assertEquals(Color.RED, image.getPixel((8f + exposedX).toInt(), (24f + y).toInt()))
                assertEquals(1, wide.draws); assertEquals(1, narrow.draws)
                assertSame(wide, source.getSpans(0, 1, ReplacementSpan::class.java).single())
                assertSame(narrow, source.getSpans(secondOffset, secondOffset + 1, ReplacementSpan::class.java).single())
            } finally { image.recycle() }
        }
    }

    @Test fun selectableLineIntervalsMatchNativeBidiMarginsAndExactIndents() {
        val source = SpannableString("abc \u05d0\u05d1\u05d2\nsecond\tX").apply {
            setSpan(LeadingMarginSpan.Standard(12, 6), 0, length, Spanned.SPAN_INCLUSIVE_EXCLUSIVE)
        }
        val paint = TextPaint().apply { textSize = 18f }
        val left = intArrayOf(7, 19, 0)
        val right = intArrayOf(3, 11, 0)
        for (alignment in listOf(Layout.Alignment.ALIGN_NORMAL, Layout.Alignment.ALIGN_CENTER,
            Layout.Alignment.ALIGN_OPPOSITE)) {
            val shaped = StaticLayout.Builder.obtain(source, 0, source.length, paint, 400)
                .setAlignment(alignment).setIncludePad(true).setIndents(left, right).build()
            assertEquals(2, shaped.lineCount)
            val painter = NativeLinePainter(shaped)
            for (line in 0 until shaped.lineCount) {
                var end = shaped.getLineEnd(line)
                if (end > shaped.getLineStart(line) && source[end - 1] == '\n') end--
                val path = Path()
                shaped.getSelectionPath(shaped.getLineStart(line), end, path)
                val expected = RectF().also { path.computeBounds(it, true) }
                val actual = checkNotNull(painter.selectableBounds(NativeLinePaintPlacement(line,
                    shaped.getLineBaseline(line).toFloat(), left[line], right[line])))
                assertEquals("$alignment line $line left", expected.left, actual.left, 0.01f)
                assertEquals("$alignment line $line right", expected.right, actual.right, 0.01f)
                assertEquals(expected.top, actual.top, 0.01f)
                assertEquals(expected.bottom, actual.bottom, 0.01f)
            }
        }
    }
}
