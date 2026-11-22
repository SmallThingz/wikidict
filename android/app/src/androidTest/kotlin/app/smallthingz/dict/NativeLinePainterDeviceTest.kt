package app.smallthingz.dict

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.text.Layout
import android.text.SpannableString
import android.text.Spanned
import android.text.StaticLayout
import android.text.TextDirectionHeuristics
import android.text.TextPaint
import android.text.style.BackgroundColorSpan
import android.text.style.ForegroundColorSpan
import android.text.style.LeadingMarginSpan
import android.text.style.LineBackgroundSpan
import android.text.style.RelativeSizeSpan
import android.text.style.ReplacementSpan
import android.text.style.StyleSpan
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class NativeLinePainterDeviceTest {
    @Test fun delegatedLinesMatchNativePixelsWithBidiTabsMarginsStylesAndFloatIndents() {
        val text = SpannableString("abc \u05d0\u05d1\u05d2\t12 xyz more words\nsecond paragraph with two narrow lines")
        text.setSpan(ForegroundColorSpan(Color.RED), 0, 3, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        text.setSpan(BackgroundColorSpan(Color.YELLOW), 4, 7, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        text.setSpan(RelativeSizeSpan(.8f), 8, 14, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        text.setSpan(StyleSpan(android.graphics.Typeface.BOLD), 15, 24, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        var currentLayout: Layout? = null
        val marginCalls = mutableListOf<List<Int>>()
        text.setSpan(object : LeadingMarginSpan.LeadingMarginSpan2 {
            override fun getLeadingMargin(first: Boolean): Int = if (first) 17 else 5
            override fun getLeadingMarginLineCount(): Int = 2
            override fun drawLeadingMargin(c: Canvas, p: Paint, x: Int, dir: Int, top: Int,
                baseline: Int, bottom: Int, source: CharSequence, start: Int, end: Int,
                first: Boolean, layout: Layout) {
                assertSame(text, source)
                assertSame(currentLayout, layout)
                marginCalls += listOf(x, dir, top, baseline, bottom, start, end, if (first) 1 else 0)
                c.drawRect((x - 3).toFloat(), baseline - 7f, (x + 3).toFloat(), baseline - 1f,
                    Paint().apply { color = Color.MAGENTA })
            }
        }, 0, text.length, Spanned.SPAN_INCLUSIVE_EXCLUSIVE)
        text.setSpan(object : LineBackgroundSpan {
            override fun drawBackground(c: Canvas, p: Paint, left: Int, right: Int, top: Int,
                baseline: Int, bottom: Int, source: CharSequence, start: Int, end: Int, line: Int) {
                assertSame(text, source)
                c.drawRect(left.toFloat(), top.toFloat(), right.toFloat(), top + 2f,
                    Paint().apply { color = Color.CYAN })
            }
        }, 0, text.length, Spanned.SPAN_INCLUSIVE_EXCLUSIVE)
        val paint = TextPaint(Paint.ANTI_ALIAS_FLAG).apply { textSize = 22f; color = Color.BLACK }
        val leftIndents = intArrayOf(0, 25, 0)
        val rightIndents = intArrayOf(15, 0, 0)
        for (direction in listOf(TextDirectionHeuristics.LTR, TextDirectionHeuristics.RTL)) {
            for (alignment in listOf(Layout.Alignment.ALIGN_NORMAL, Layout.Alignment.ALIGN_OPPOSITE, Layout.Alignment.ALIGN_CENTER)) {
                val shaped = StaticLayout.Builder.obtain(text, 0, text.length, paint, 150)
                    .setAlignment(alignment).setTextDirection(direction).setIncludePad(true)
                    .setBreakStrategy(Layout.BREAK_STRATEGY_SIMPLE)
                    .setHyphenationFrequency(Layout.HYPHENATION_FREQUENCY_NONE)
                    .setIndents(leftIndents, rightIndents).build()
                currentLayout = shaped
                assertTrue(shaped.lineCount > 2)
                val expected = Bitmap.createBitmap(300, shaped.height + 80, Bitmap.Config.ARGB_8888)
                val actual = Bitmap.createBitmap(expected.width, expected.height, Bitmap.Config.ARGB_8888)
                try {
                    marginCalls.clear()
                    Canvas(expected).apply { translate(60f, 40f); shaped.draw(this) }
                    val expectedMarginCalls = marginCalls.toList()
                    marginCalls.clear()
                    val painter = NativeLinePainter(shaped)
                    Canvas(actual).apply {
                        translate(60f, 40f)
                        painter.paint(this, (0 until shaped.lineCount).map { line ->
                            NativeLinePaintPlacement(line, shaped.getLineBaseline(line).toFloat(),
                                leftIndents[minOf(line, leftIndents.lastIndex)],
                                rightIndents[minOf(line, rightIndents.lastIndex)])
                        })
                    }
                    assertEquals(expectedMarginCalls, marginCalls)
                    val expectedPixels = IntArray(expected.width * expected.height)
                    val actualPixels = IntArray(actual.width * actual.height)
                    expected.getPixels(expectedPixels, 0, expected.width, 0, 0, expected.width, expected.height)
                    actual.getPixels(actualPixels, 0, actual.width, 0, 0, actual.width, actual.height)
                    assertArrayEquals("The existing native drawing must retain every styled pixel", expectedPixels, actualPixels)
                    assertSame(text, shaped.text)
                } finally {
                    actual.recycle(); expected.recycle()
                }
            }
        }
    }

    @Test fun zeroContainingWidthAndCoincidentUsedBaselinesKeepBothOriginalSpanOwners() {
        val draws = IntArray(2)
        val text = SpannableString("A\nB")
        fun box(owner: Int, color: Int, left: Int) = object : ReplacementSpan() {
            override fun getSize(paint: Paint, text: CharSequence, start: Int, end: Int,
                fm: Paint.FontMetricsInt?): Int {
                fm?.apply { ascent = -14; top = -14; descent = 0; bottom = 0 }
                return 24
            }
            override fun draw(canvas: Canvas, text: CharSequence, start: Int, end: Int, x: Float,
                top: Int, y: Int, bottom: Int, paint: Paint) {
                draws[owner]++
                canvas.drawRect(x + left, y - 14f, x + left + 12, y.toFloat(),
                    Paint().apply { this.color = color })
            }
        }
        val first = box(0, Color.RED, 0)
        val second = box(1, Color.BLUE, 12)
        text.setSpan(first, 0, 1, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        text.setSpan(second, 2, 3, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        val shaped = StaticLayout.Builder.obtain(text, 0, text.length,
            TextPaint(Paint.ANTI_ALIAS_FLAG).apply { textSize = 22f }, 0)
            .setIncludePad(true).setBreakStrategy(Layout.BREAK_STRATEGY_SIMPLE)
            .setHyphenationFrequency(Layout.HYPHENATION_FREQUENCY_NONE).build()
        assertEquals(0, shaped.width)
        val bitmap = Bitmap.createBitmap(80, 100, Bitmap.Config.ARGB_8888)
        try {
            val canvas = Canvas(bitmap).apply { translate(20f, 0f) }
            val painter = NativeLinePainter(shaped)
            painter.paint(canvas, (0 until shaped.lineCount).map { NativeLinePaintPlacement(it, 40f) })
            assertArrayEquals(intArrayOf(1, 1), draws)
            assertEquals(Color.RED, bitmap.getPixel(25, 35))
            assertEquals(Color.BLUE, bitmap.getPixel(37, 35))
            assertEquals(Color.TRANSPARENT, bitmap.getPixel(25, 60))
            assertEquals(Color.TRANSPARENT, bitmap.getPixel(37, 60))
            assertSame(first, text.getSpans(0, 1, ReplacementSpan::class.java).single())
            assertSame(second, text.getSpans(2, 3, ReplacementSpan::class.java).single())
            assertEquals("A\nB", shaped.text.toString())
        } finally {
            bitmap.recycle()
        }
    }

    @Test fun coincidentBaselinesPaintAllLineBackgroundsBeforeEitherOriginalInkOwner() {
        val calls = mutableListOf<String>()
        val text = SpannableString("A\nB")
        fun box(owner: Int, color: Int, left: Int) = object : ReplacementSpan() {
            override fun getSize(paint: Paint, text: CharSequence, start: Int, end: Int,
                fm: Paint.FontMetricsInt?): Int {
                fm?.apply { ascent = -14; top = -14; descent = 0; bottom = 0 }
                return 24
            }
            override fun draw(canvas: Canvas, source: CharSequence, start: Int, end: Int, x: Float,
                top: Int, y: Int, bottom: Int, paint: Paint) {
                calls += "ink$owner"
                canvas.drawRect(x + left, y - 14f, x + left + 12, y.toFloat(),
                    Paint().apply { this.color = color })
            }
        }
        val first = box(0, Color.RED, 0)
        val second = box(1, Color.BLUE, 12)
        text.setSpan(first, 0, 1, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        text.setSpan(second, 2, 3, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        text.setSpan(object : LineBackgroundSpan {
            override fun drawBackground(canvas: Canvas, paint: Paint, left: Int, right: Int,
                top: Int, baseline: Int, bottom: Int, source: CharSequence, start: Int,
                end: Int, line: Int) {
                assertSame(text, source)
                calls += "background$line"
                canvas.drawRect(left.toFloat(), baseline - 20f, right.toFloat(), baseline + 5f,
                    Paint().apply { color = if (line == 0) Color.CYAN else Color.GREEN })
            }
        }, 0, text.length, Spanned.SPAN_INCLUSIVE_EXCLUSIVE)
        val shaped = StaticLayout.Builder.obtain(text, 0, text.length,
            TextPaint(Paint.ANTI_ALIAS_FLAG).apply { textSize = 22f }, 64)
            .setIncludePad(true).setBreakStrategy(Layout.BREAK_STRATEGY_SIMPLE)
            .setHyphenationFrequency(Layout.HYPHENATION_FREQUENCY_NONE).build()
        assertEquals(2, shaped.lineCount)
        val bitmap = Bitmap.createBitmap(80, 80, Bitmap.Config.ARGB_8888)
        try {
            NativeLinePainter(shaped).paint(Canvas(bitmap), listOf(
                NativeLinePaintPlacement(0, 40f), NativeLinePaintPlacement(1, 40f)))
            assertEquals(listOf("background0", "background1", "ink0", "ink1"), calls)
            assertEquals(Color.RED, bitmap.getPixel(5, 35))
            assertEquals(Color.BLUE, bitmap.getPixel(17, 35))
            assertEquals(Color.GREEN, bitmap.getPixel(40, 35))
            assertSame(first, text.getSpans(0, 1, ReplacementSpan::class.java).single())
            assertSame(second, text.getSpans(2, 3, ReplacementSpan::class.java).single())
            assertSame(text, shaped.text)
        } finally {
            bitmap.recycle()
        }
    }
}
