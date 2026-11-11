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
