package app.smallthingz.dict

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Matrix
import android.graphics.Paint
import android.graphics.Rect
import android.graphics.RectF
import android.text.Layout
import android.text.PrecomputedText
import android.text.SpannableString
import android.text.Spanned
import android.text.StaticLayout
import android.text.TextDirectionHeuristics
import android.text.TextPaint
import android.text.style.LeadingMarginSpan
import android.text.style.LineBackgroundSpan
import android.text.style.MetricAffectingSpan
import android.text.style.ReplacementSpan
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class NativeDecorationBoundsDeviceTest {
    @Test fun publicNativeRectDispatchMatchesObservedDecorationsWithoutReenteringMediaOrParagraphPainters() {
        for (direction in listOf(TextDirectionHeuristics.LTR, TextDirectionHeuristics.RTL)) {
            var sizes = 0
            var draws = 0
            var margins = 0
            var backgrounds = 0
            val paint = TextPaint(Paint.ANTI_ALIAS_FLAG).apply {
                textSize = 31f; color = Color.RED; isUnderlineText = true; isStrikeThruText = true
            }
            val replacement = object : ReplacementSpan() {
                override fun getSize(paint: Paint, text: CharSequence, start: Int, end: Int,
                    fm: Paint.FontMetricsInt?): Int { sizes++; return 27 }
                override fun draw(canvas: Canvas, text: CharSequence, start: Int, end: Int,
                    x: Float, top: Int, y: Int, bottom: Int, paint: Paint) {
                    draws++
                    canvas.drawRect(x, y - 12f, x + 27f, y + 2f, Paint().apply { color = Color.BLUE })
                }
            }
            val margin = object : LeadingMarginSpan.LeadingMarginSpan2 {
                override fun getLeadingMargin(first: Boolean) = if (first) 13 else 5
                override fun getLeadingMarginLineCount() = 2
                override fun drawLeadingMargin(c: Canvas, p: Paint, x: Int, dir: Int, top: Int,
                    baseline: Int, bottom: Int, text: CharSequence, start: Int, end: Int,
                    first: Boolean, layout: Layout) { margins++ }
            }
            val background = LineBackgroundSpan { _, _, _, _, _, _, _, _, _, _, _ -> backgrounds++ }
            val source = SpannableString("a\t\u05d0\u05d1\ufffc\nW\u0301").apply {
                setSpan(replacement, 4, 5, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
                setSpan(margin, 0, length, Spanned.SPAN_INCLUSIVE_INCLUSIVE)
                setSpan(background, 0, length, Spanned.SPAN_INCLUSIVE_INCLUSIVE)
                // Noncommutative equal-priority metrics catch remove-and-append span reordering.
                setSpan(object : MetricAffectingSpan(), NativeMayUnderline {
                    override val mayUnderline = true
                    override fun updateMeasureState(p: TextPaint) { p.textSize = 19f }
                    override fun updateDrawState(p: TextPaint) { updateMeasureState(p); p.isUnderlineText = true }
                }, 0, length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
                setSpan(object : MetricAffectingSpan() {
                    override fun updateMeasureState(p: TextPaint) { p.textSize *= 1.5f; p.baselineShift = -4 }
                    override fun updateDrawState(p: TextPaint) { updateMeasureState(p); p.bgColor = Color.GREEN }
                }, 0, length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
            }
            val params = PrecomputedText.Params.Builder(paint).setTextDirection(direction)
                .setBreakStrategy(Layout.BREAK_STRATEGY_SIMPLE)
                .setHyphenationFrequency(Layout.HYPHENATION_FREQUENCY_NONE).build()
            val retained = PrecomputedText.create(source, params)
            val layout = StaticLayout.Builder.obtain(retained, 0, retained.length, paint, 160)
                .setTextDirection(direction).setBreakStrategy(Layout.BREAK_STRATEGY_SIMPLE)
                .setHyphenationFrequency(Layout.HYPHENATION_FREQUENCY_NONE)
                .setIndents(intArrayOf(11, 23), intArrayOf(7, 9)).build()
            val positions = (0 until layout.lineCount).map { NativeLinePaintPlacement(it, -6f,
                if (it == 0) 11 else 23, if (it == 0) 7 else 9) }
            val beforeSizes = sizes
            val painter = NativeLinePainter(layout)
            val observed = checkNotNull(painter.decorationBounds(positions))
            assertEquals(beforeSizes, sizes)
            assertEquals(0, draws); assertEquals(0, margins); assertEquals(0, backgrounds)
            assertSame(replacement, retained.getSpans(4, 5, ReplacementSpan::class.java).single())
            assertSame(margin, retained.getSpans(0, retained.length, LeadingMarginSpan::class.java).single())
            val bitmap = Bitmap.createBitmap(512, 192, Bitmap.Config.ARGB_8888)
            try {
                val canvas = RecordingCanvas(bitmap)
                canvas.translate(256f, 96f)
                painter.paint(canvas, positions)
                assertEquals(observed.translated(256f, 96f), canvas.decorations)
                assertTrue(canvas.rectangles > 0)
                assertEquals(1, draws)
                assertTrue(margins > 0); assertTrue(backgrounds > 0)
                val pixels = IntArray(bitmap.width * bitmap.height)
                bitmap.getPixels(pixels, 0, bitmap.width, 0, 0, bitmap.width, bitmap.height)
                assertTrue(pixels.any { it == Color.RED })
                assertTrue(pixels.any { it == Color.GREEN })
                assertTrue(pixels.any { it == Color.BLUE })
            } finally { bitmap.recycle() }
            val afterPaintSizes = sizes
            assertEquals(observed, painter.decorationBounds(positions))
            assertEquals(afterPaintSizes, sizes)
            assertEquals(1, draws)
        }
    }

    @Test fun observerRetainsAllPublicRectOverloadsAcrossSaveAndNegativeTranslation() {
        val canvas = NativeDecorationBoundsCanvas()
        val paint = Paint().apply { style = Paint.Style.FILL }
        val saved = canvas.save()
        canvas.translate(-8f, -13f)
        canvas.drawRect(0f, 0f, 3f, 2f, paint)
        canvas.drawRect(RectF(1f, -4f, 6f, 3f), paint)
        canvas.drawRect(Rect(-2, 2, 4, 6), paint)
        assertEquals(NativeFloatBounds(-10f, -17f, -2f, -7f), canvas.bounds)
        canvas.restoreToCount(saved)
        assertEquals(1, canvas.saveCount)
        val clip = Rect()
        assertTrue(canvas.getClipBounds(clip)); assertTrue(clip.contains(-10, -17))
        canvas.drawRect(1f, 1f, 2f, 2f, paint)
        assertEquals(NativeFloatBounds(-10f, -17f, 2f, 2f), canvas.bounds)
    }

    @Test fun actualNativeRunContextsKeepWrappedInkWithoutWholePrefixExpansion() {
        val texts = listOf("\u00c5ffiaffiaffiaffi cafe\u0301 retained caption",
            "caption \u0633\u0644\u0627\u0645\u0644\u0627\u0633\u0644\u0627\u0645\tlink retained",
            "\u0915\u094d\u0937\u093f\u0924\u093f\u091c\u0915\u094d\u0937\u093f\u0924\u093f\u091c caption retained")
        for ((sample, value) in texts.withIndex()) for (alignment in listOf(Layout.Alignment.ALIGN_NORMAL,
            Layout.Alignment.ALIGN_CENTER, Layout.Alignment.ALIGN_OPPOSITE)) for (width in listOf(541, 181)) {
            val paint = TextPaint(Paint.ANTI_ALIAS_FLAG).apply {
                textSize = 31f; color = Color.BLACK; textSkewX = -.18f
                letterSpacing = listOf(.035f, -.02f, 0f)[sample]
            }
            val source = SpannableString(value).apply {
                setSpan(object : MetricAffectingSpan() {
                    override fun updateDrawState(p: TextPaint) = updateMeasureState(p)
                    override fun updateMeasureState(p: TextPaint) { p.textSize = 24f; p.baselineShift = -7 }
                }, 5, 10, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
            }
            val params = PrecomputedText.Params.Builder(paint).setTextDirection(TextDirectionHeuristics.LTR)
                .setBreakStrategy(Layout.BREAK_STRATEGY_SIMPLE)
                .setHyphenationFrequency(Layout.HYPHENATION_FREQUENCY_NONE).build()
            val text = PrecomputedText.create(source, params)
            val layout = StaticLayout.Builder.obtain(text, 0, text.length, paint, width)
                .setTextDirection(TextDirectionHeuristics.LTR).setAlignment(alignment)
                .setBreakStrategy(Layout.BREAK_STRATEGY_SIMPLE)
                .setHyphenationFrequency(Layout.HYPHENATION_FREQUENCY_NONE)
                .setIndents(intArrayOf(11, 23), intArrayOf(7, 9)).build()
            val positions = (0 until layout.lineCount).map { line -> NativeLinePaintPlacement(line,
                layout.getLineBaseline(line) - 16f, if (line == 0) 11 else 23,
                if (line == 0) 7 else 9, -13.5f) }
            val painter = NativeLinePainter(layout)
            assertTrue(painter.observedPaintBounds(positions).textComplete)
            if (width == 181) assertTrue("The wrap oracle must actually wrap", layout.lineCount > 1)
            val ink = checkNotNull(nativeTextInkBounds(layout, positions))
            // The old whole-prefix envelope was about three advances wide. Actual native
            // run context keeps wrapped ligatures/joining, skew, tabs and combining marks.
            assertTrue("Native ink must not grow by its entire prefix on both sides",
                ink.width < width + 48f)
            val bitmap = Bitmap.createBitmap(1024, 512, Bitmap.Config.ARGB_8888)
            try {
                val canvas = Canvas(bitmap)
                canvas.translate(128f, 80f)
                painter.paint(canvas, positions)
                val pixels = IntArray(bitmap.width * bitmap.height)
                bitmap.getPixels(pixels, 0, bitmap.width, 0, 0, bitmap.width, bitmap.height)
                var painted = 0
                pixels.forEachIndexed { index, pixel -> if (Color.alpha(pixel) != 0) {
                    painted++
                    val x = index % bitmap.width + .5f - 128f
                    val y = index / bitmap.width + .5f - 80f
                    assertTrue("Native glyph pixel outside retained ink: $x,$y in $ink",
                        x >= ink.left - 1f && x <= ink.right + 1f && y >= ink.top - 1f && y <= ink.bottom + 1f)
                } }
                assertTrue(painted > 0)
            } finally { bitmap.recycle() }
        }
        val observer = NativeDecorationBoundsCanvas(true)
        val paint = Paint().apply { textSize = 30f }
        observer.drawText("unowned fast path", 0f, 0f, paint)
        assertFalse("An unexpected dispatch retains conservative bounds", observer.textBoundsComplete)
    }

    @Test fun exactRunBoundsSkipCursorScanWhileReplacementAndUnsupportedRunsRetainIt() {
        for (mode in 0..2) {
            var replacementSizes = 0
            var replacementDraws = 0
            val paint = TextPaint(Paint.ANTI_ALIAS_FLAG).apply {
                textSize = 24f
                if (mode == 2) style = Paint.Style.STROKE
            }
            val source = SpannableString("office retained caption ".repeat(40))
            if (mode == 1) source.setSpan(object : ReplacementSpan(), NativeReplacementPaintBounds {
                override fun getSize(paint: Paint, text: CharSequence, start: Int, end: Int,
                    fm: Paint.FontMetricsInt?): Int { replacementSizes++; return 24 }
                override fun draw(canvas: Canvas, text: CharSequence, start: Int, end: Int,
                    x: Float, top: Int, y: Int, bottom: Int, paint: Paint) { replacementDraws++ }
                override fun nativePaintBounds(lineTop: Float, lineBottom: Float) =
                    NativeFloatBounds(-3f, -20f, 27f, 4f)
            }, 0, 1, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
            val params = PrecomputedText.Params.Builder(paint).setTextDirection(TextDirectionHeuristics.LTR)
                .setBreakStrategy(Layout.BREAK_STRATEGY_SIMPLE)
                .setHyphenationFrequency(Layout.HYPHENATION_FREQUENCY_NONE).build()
            val text = PrecomputedText.create(source, params)
            val shaped = StaticLayout.Builder.obtain(text, 0, text.length, paint, 280)
                .setTextDirection(TextDirectionHeuristics.LTR)
                .setBreakStrategy(Layout.BREAK_STRATEGY_SIMPLE)
                .setHyphenationFrequency(Layout.HYPHENATION_FREQUENCY_NONE).build()
            val layout = CursorCountingLayout(shaped)
            val positions = (0 until layout.lineCount).map {
                NativeLinePaintPlacement(it, layout.getLineBaseline(it).toFloat())
            }
            assertTrue(layout.lineCount > 1)
            assertEquals(mode != 2, NativeLinePainter(layout).observedPaintBounds(positions).textComplete)
            val sizesBefore = replacementSizes
            layout.cursorCalls = 0
            val ink = checkNotNull(nativeTextInkBounds(layout, positions))
            assertEquals(sizesBefore, replacementSizes)
            assertEquals(0, replacementDraws)
            if (mode == 0) {
                assertEquals("Exact text must not query every UTF-16 cursor", 0, layout.cursorCalls)
            } else {
                assertTrue("Retained replacement/fallback origins still need native cursors", layout.cursorCalls > 0)
                if (mode == 1) {
                    assertTrue(ink.left <= -3f)
                    assertTrue(ink.bottom >= layout.getLineBaseline(0) + 4f)
                }
            }
        }
    }

    private class CursorCountingLayout(private val shaped: Layout) : Layout(shaped.text,
        TextPaint(shaped.paint), shaped.width, shaped.alignment, shaped.spacingMultiplier, shaped.spacingAdd) {
        var cursorCalls = 0
        override fun getPrimaryHorizontal(offset: Int): Float {
            cursorCalls++
            return shaped.getPrimaryHorizontal(offset)
        }
        override fun getSecondaryHorizontal(offset: Int): Float {
            cursorCalls++
            return shaped.getSecondaryHorizontal(offset)
        }
        override fun getLineCount() = shaped.lineCount
        override fun getLineTop(line: Int) = shaped.getLineTop(line)
        override fun getLineDescent(line: Int) = shaped.getLineDescent(line)
        override fun getLineStart(line: Int) = shaped.getLineStart(line)
        override fun getParagraphDirection(line: Int) = shaped.getParagraphDirection(line)
        override fun getLineContainsTab(line: Int) = shaped.getLineContainsTab(line)
        override fun getLineDirections(line: Int): Layout.Directions = shaped.getLineDirections(line)
        override fun getTopPadding() = shaped.topPadding
        override fun getBottomPadding() = shaped.bottomPadding
        override fun getEllipsisStart(line: Int) = shaped.getEllipsisStart(line)
        override fun getEllipsisCount(line: Int) = shaped.getEllipsisCount(line)
    }

    private class RecordingCanvas(bitmap: Bitmap) : Canvas(bitmap) {
        var decorations: NativeFloatBounds? = null
        var rectangles = 0
        @Suppress("DEPRECATION")
        override fun drawRect(left: Float, top: Float, right: Float, bottom: Float, paint: Paint) {
            if (paint.color != Color.BLUE && right > left && bottom > top) {
                val rect = RectF(left, top, right, bottom)
                val matrix = Matrix()
                getMatrix(matrix); matrix.mapRect(rect)
                decorations = enclosingBounds(decorations, NativeFloatBounds(rect.left, rect.top, rect.right, rect.bottom))
                rectangles++
            }
            super.drawRect(left, top, right, bottom, paint)
        }
    }
}
