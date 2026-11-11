package app.smallthingz.dict

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Path
import android.graphics.RectF
import android.text.Layout
import android.text.SpannableString
import android.text.Spanned
import android.text.StaticLayout
import android.text.TextDirectionHeuristics
import android.text.TextPaint
import android.text.style.MetricAffectingSpan
import android.text.style.ReplacementSpan
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import kotlin.math.ceil

@RunWith(AndroidJUnit4::class)
class NativeRunLineMetricsDeviceTest {
    private class ExactPaint(val original: TextPaint) : MetricAffectingSpan() {
        override fun updateMeasureState(paint: TextPaint) { paint.set(original) }
        override fun updateDrawState(paint: TextPaint) { paint.set(original) }
    }

    @Test fun authoredRunHeightsUsePrimaryFontWhileOriginalMixedScriptInkAndBidiSurvive() {
        val face = InstrumentationRegistry.getInstrumentation().targetContext.resources.getFont(R.font.newsreader)
        val root = TextPaint(Paint.ANTI_ALIAS_FLAG).apply { typeface = face; textSize = 20f; color = Color.RED }
        val large = TextPaint(root).apply { textSize = 36f; baselineShift = -4; color = Color.BLUE }
        val small = TextPaint(root).apply { textSize = 13f; textScaleX = 1.15f; textSkewX = -0.15f; color = Color.GREEN }
        val text = "A\u0e01\u0e49 \u05d0\u05d1 \ud83d\udc69\u200d\ud83d\ude80B"
        for (policy in listOf(NativeLineHeightPolicy.Multiplier(0f), NativeLineHeightPolicy.Multiplier(1.5f),
            NativeLineHeightPolicy.Pixels(18f), NativeLineHeightPolicy.Normal)) {
            val source = SpannableString(text)
            val owners = listOf(ExactPaint(root), ExactPaint(large), ExactPaint(small))
            val ranges = listOf(0 to 1, 1 to 7, 7 to text.length)
            source.setSpan(NativeRunLineMetrics(NativePrimaryFontMetrics.from(root), policy, strut = true),
                0, source.length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
            owners.zip(ranges).forEach { (owner, range) ->
                source.setSpan(owner, range.first, range.second, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
                source.setSpan(NativeRunLineMetrics(NativePrimaryFontMetrics.from(owner.original), policy),
                    range.first, range.second, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
            }
            val native = StaticLayout.Builder.obtain(source, 0, source.length, TextPaint(root), 400)
                .setTextDirection(TextDirectionHeuristics.FIRSTSTRONG_LTR).setIncludePad(true)
                .setUseLineSpacingFromFallbacks(true).setLineSpacing(0f, 1f)
                .setBreakStrategy(android.graphics.text.LineBreaker.BREAK_STRATEGY_SIMPLE)
                .setHyphenationFrequency(Layout.HYPHENATION_FREQUENCY_NONE).build()
            assertEquals(1, native.lineCount)
            val geometry = NativeFloatGeometry.build(source, root, 400, emptyList())
            val expectedBaseline: Float
            if (policy == NativeLineHeightPolicy.Normal) {
                assertEquals(native.height, geometry.height)
                expectedBaseline = native.getLineBaseline(0).toFloat()
            } else {
                // Independent first-font oracle: the parent's strut participates alongside every
                // descendant style. Lengths stay fixed; only a number follows the child's font size.
                val bounds = (listOf(root) + owners.map { it.original }).map { paint ->
                    val fm = paint.fontMetrics
                    val height = when (policy) {
                        is NativeLineHeightPolicy.Pixels -> policy.value
                        is NativeLineHeightPolicy.Multiplier -> paint.textSize * policy.value
                        else -> error("Authored branch")
                    }
                    val leading = (height - (fm.descent - fm.ascent)) / 2f
                    (fm.ascent - leading + paint.baselineShift) to (fm.descent + leading + paint.baselineShift)
                }
                val top = bounds.minOf { it.first }
                val bottom = bounds.maxOf { it.second }
                assertEquals(bottom - top, geometry.textBottom, 0.001f)
                assertEquals(ceil(bottom - top).toInt(), geometry.height)
                expectedBaseline = -top
                assertEquals(expectedBaseline, geometry.baselineForOffset(0), 0.001f)
            }
            val expected = Bitmap.createBitmap(480, 200, Bitmap.Config.ARGB_8888)
            val actual = Bitmap.createBitmap(480, 200, Bitmap.Config.ARGB_8888)
            try {
                val shift = expectedBaseline - native.getLineBaseline(0)
                Canvas(expected).apply { translate(40f, 80f + shift); native.draw(this) }
                Canvas(actual).apply { translate(40f, 80f); geometry.paint(this) }
                val wanted = IntArray(480 * 200)
                val found = IntArray(wanted.size)
                expected.getPixels(wanted, 0, 480, 0, 0, 480, 200)
                actual.getPixels(found, 0, 480, 0, 0, 480, 200)
                assertTrue(wanted.count { Color.alpha(it) != 0 } > 50)
                assertArrayEquals("Original native mixed-script painting for $policy", wanted, found)
                val path = Path()
                native.getSelectionPath(4, 6, path)
                val nativeBounds = RectF()
                path.computeBounds(nativeBounds, true)
                nativeBounds.offset(0f, shift)
                val bounds = geometry.rectsForRange(4, 6).reduce { a, b -> a.apply { union(b) } }
                assertEquals(nativeBounds.left, bounds.left, 1f)
                assertEquals(nativeBounds.right, bounds.right, 1f)
                assertEquals(nativeBounds.top, bounds.top, 1f)
                assertEquals(nativeBounds.bottom, bounds.bottom, 1f)
                for (offset in 0..text.length) assertEquals(native.getPrimaryHorizontal(offset), geometry.caretRect(offset).left, 0f)
                assertEquals(owners, source.getSpans(0, source.length, ExactPaint::class.java).toList())
            } finally { expected.recycle(); actual.recycle() }
        }
    }

    @Test fun zeroTextHeightKeepsAnActualReplacedBoxAndItsOriginalPainter() {
        var draws = 0
        val image = object : ReplacementSpan(), NativeAtomicInlineMetrics {
            override val nativeUsedMetrics = NativeUsedLineMetrics(-40f, 8f)
            override fun getSize(paint: Paint, text: CharSequence, start: Int, end: Int, fm: Paint.FontMetricsInt?): Int {
                fm?.let { it.ascent = -40; it.top = -40; it.descent = 8; it.bottom = 8 }
                return 32
            }
            override fun draw(canvas: Canvas, text: CharSequence, start: Int, end: Int, x: Float,
                top: Int, y: Int, bottom: Int, paint: Paint) {
                draws++
                canvas.drawRect(x, y - 40f, x + 32f, y + 8f, Paint().apply { color = Color.BLUE })
            }
        }
        val paint = TextPaint().apply { textSize = 20f }
        val source = SpannableString("\ufffc").apply {
            setSpan(NativeRunLineMetrics(NativePrimaryFontMetrics.from(paint), NativeLineHeightPolicy.Pixels(0f), strut = true),
                0, 1, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
            setSpan(image, 0, 1, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        }
        val geometry = NativeFloatGeometry.build(source, paint, 100, emptyList())
        assertEquals(48f, geometry.textBottom, 0f)
        assertEquals(40f, geometry.baselineForOffset(0), 0f)
        val bitmap = Bitmap.createBitmap(100, 80, Bitmap.Config.ARGB_8888)
        try {
            geometry.paint(Canvas(bitmap))
            assertEquals(1, draws)
            assertEquals(Color.BLUE, bitmap.getPixel(2, 2))
            assertEquals(Color.BLUE, bitmap.getPixel(2, 47))
            assertEquals(0, bitmap.getPixel(2, 48))
            assertSame(image, source.getSpans(0, 1, ReplacementSpan::class.java).single())
        } finally { bitmap.recycle() }
    }
}
