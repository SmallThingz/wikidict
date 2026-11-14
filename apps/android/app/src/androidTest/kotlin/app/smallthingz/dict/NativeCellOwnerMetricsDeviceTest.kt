package app.smallthingz.dict

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Typeface
import android.text.Layout
import android.text.SpannableString
import android.text.Spanned
import android.text.StaticLayout
import android.text.TextDirectionHeuristics
import android.text.TextPaint
import android.text.style.MetricAffectingSpan
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import kotlin.math.ceil
import kotlin.math.max
import kotlin.math.min

/** Synthetic metric-owner controls. Actual Cell lowering/interaction has a separate Entry fixture. */
@RunWith(AndroidJUnit4::class)
class NativeCellOwnerMetricsDeviceTest {
    private class ExactPaint(val value: TextPaint) : MetricAffectingSpan() {
        override fun updateMeasureState(paint: TextPaint) { paint.set(value) }
        override fun updateDrawState(paint: TextPaint) { paint.set(value) }
    }

    private fun paint(size: Float, face: Typeface = Typeface.SANS_SERIF) =
        TextPaint(Paint.ANTI_ALIAS_FLAG).apply { textSize = size; typeface = face; color = Color.BLUE }

    private fun layout(source: Spanned, owner: TextPaint, width: Int): StaticLayout =
        StaticLayout.Builder.obtain(source, 0, source.length, TextPaint(owner), width)
            .setTextDirection(TextDirectionHeuristics.FIRSTSTRONG_LTR).setIncludePad(true)
            .setUseLineSpacingFromFallbacks(true).setLineSpacing(0f, 1f)
            .setBreakStrategy(android.graphics.text.LineBreaker.BREAK_STRATEGY_SIMPLE)
            .setHyphenationFrequency(Layout.HYPHENATION_FREQUENCY_NONE).build()

    private fun source(text: String, owner: TextPaint, child: ExactPaint,
        policy: NativeLineHeightPolicy, cell: Boolean = true): SpannableString = SpannableString(text).apply {
        setSpan(NativeRunLineMetrics(NativePrimaryFontMetrics.from(owner), policy,
            strut = true, includePrimaryInNormal = cell), 0, length,
            if (isEmpty()) Spanned.SPAN_MARK_MARK else Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        if (isNotEmpty()) {
            setSpan(child, 0, length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
            setSpan(NativeRunLineMetrics(NativePrimaryFontMetrics.from(child.value), policy),
                0, length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        }
    }

    @Test fun normalCellOwnerKeepsIndependentPrimaryAndFallbackEnvelopeAcrossRealWraps() {
        // This direct envelope contrast is deterministic even on fonts whose fallback happens
        // to share the primary font's ascender. The opt-in must not alter old Normal owners.
        val primary = NativePrimaryFontMetrics(-31.5f, 8.25f, 40f, -2f)
        val natural = NativeUsedLineMetrics(-18f, 12f)
        val point = SpannableString("x")
        val marker = NativeRunLineMetrics(primary, NativeLineHeightPolicy.Normal,
            strut = true, includePrimaryInNormal = true)
        point.setSpan(marker, 0, 1, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        val union = checkNotNull(nativeRunLineMetrics(point, 0, 1, natural))
        assertEquals(-33.5f, union.top, 0f)
        assertEquals(12f, union.bottom, 0f)
        point.removeSpan(marker)
        point.setSpan(NativeRunLineMetrics(primary, NativeLineHeightPolicy.Normal, strut = true),
            0, 1, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        assertEquals(natural, nativeRunLineMetrics(point, 0, 1, natural))

        val text = "owner \u0e01\u0e49 \u05d0\u05d1 \ud83d\udc69\u200d\ud83d\ude80 child owner child"
        for (ownerSize in listOf(8f, 48f)) {
            val owner = paint(ownerSize)
            val child = ExactPaint(paint(14f, Typeface.MONOSPACE))
            val data = source(text, owner, child, NativeLineHeightPolicy.Normal)
            val native = layout(data, owner, 92)
            assertTrue(native.lineCount > 1)
            val geometry = NativeFloatGeometry.build(data, owner, 92, emptyList())
            val fm = owner.fontMetrics
            var top = 0f
            for (line in 0 until native.lineCount) {
                val baseline = native.getLineBaseline(line)
                val wantedTop = min((native.getLineTop(line) - baseline).toFloat(), fm.ascent)
                val wantedBottom = max((native.getLineBottom(line) - baseline).toFloat(), fm.descent)
                val start = native.getLineStart(line)
                assertEquals(top - wantedTop, geometry.baselineForOffset(start), 0.001f)
                assertEquals(native.getPrimaryHorizontal(start), geometry.caretRect(start).left, 0.001f)
                top += wantedBottom - wantedTop
            }
            assertEquals(top, geometry.textBottom, 0.001f)
            assertEquals(ceil(top).toInt(), geometry.height)
            assertEquals(text, geometry.text.toString())
            assertSame(child, (geometry.text as Spanned).getSpans(0, text.length, ExactPaint::class.java).single())
            val childProbe = TextPaint(owner).also(child::updateMeasureState)
            assertEquals(14f, childProbe.textSize, 0f)
            assertSame(child.value.typeface, childProbe.typeface)
            assertEquals(Color.BLUE, childProbe.color)
        }
    }

    @Test fun computedAndNumberPoliciesKeepOwnerSizeIndependentFromChildPaintAndFractionalBaseline() {
        val owner = paint(9.5f)
        val child = ExactPaint(paint(13f, Typeface.MONOSPACE).apply { baselineShift = -2 })
        for (policy in listOf(NativeLineHeightPolicy.Pixels(17.25f), NativeLineHeightPolicy.Multiplier(1.1f))) {
            val data = source("Source", owner, child, policy)
            val native = layout(data, owner, 220)
            assertEquals(1, native.lineCount)
            val geometry = NativeFloatGeometry.build(data, owner, 220, emptyList())
            val expected = listOf(owner, child.value).map { value ->
                val fm = value.fontMetrics
                val height = when (policy) {
                    is NativeLineHeightPolicy.Pixels -> policy.value
                    is NativeLineHeightPolicy.Multiplier -> policy.value * value.textSize
                    else -> error("Authored policy")
                }
                val leading = (height - (fm.descent - fm.ascent)) / 2f
                (fm.ascent - leading + value.baselineShift) to (fm.descent + leading + value.baselineShift)
            }
            val first = expected.minOf { it.first }
            val last = expected.maxOf { it.second }
            assertEquals(last - first, geometry.textBottom, 0.001f)
            assertEquals(-first, geometry.baselineForOffset(0), 0.001f)
            // The source owner's metrics move the line; they never recolor or replace its glyphs.
            val expectedBitmap = Bitmap.createBitmap(260, 100, Bitmap.Config.ARGB_8888)
            val actualBitmap = Bitmap.createBitmap(260, 100, Bitmap.Config.ARGB_8888)
            try {
                Canvas(expectedBitmap).apply {
                    translate(10f, 30f - first - native.getLineBaseline(0)); native.draw(this)
                }
                Canvas(actualBitmap).apply { translate(10f, 30f); geometry.paint(this) }
                val expectedPixels = IntArray(260 * 100)
                val actualPixels = IntArray(expectedPixels.size)
                expectedBitmap.getPixels(expectedPixels, 0, 260, 0, 0, 260, 100)
                actualBitmap.getPixels(actualPixels, 0, 260, 0, 0, 260, 100)
                assertTrue(expectedPixels.any { Color.alpha(it) != 0 })
                assertArrayEquals(expectedPixels, actualPixels)
            } finally { expectedBitmap.recycle(); actualBitmap.recycle() }
            assertEquals("Source", geometry.text.toString())
            assertSame(child, (geometry.text as Spanned).getSpans(0, 6, ExactPaint::class.java).single())
        }
    }

    @Test fun realEmptyLineKeepsCellPointMetricsWhileAbsentSourceAndZeroFontStayDistinct() {
        val smallOwner = paint(8f)
        val oldLargeDefault = paint(80f, Typeface.SERIF)
        val empty = source("", smallOwner, ExactPaint(smallOwner), NativeLineHeightPolicy.Pixels(24.25f))
        val actual = NativeFloatGeometry.build(empty, smallOwner, 100, emptyList())
        val fm = smallOwner.fontMetrics
        val leading = (24.25f - (fm.descent - fm.ascent)) / 2f
        assertEquals("", actual.text.toString())
        assertEquals(24.25f, actual.textBottom, 0.001f)
        assertEquals(-fm.ascent + leading, actual.baselineForOffset(0), 0.001f)
        assertTrue(actual.nodes.isEmpty())
        val retained = (actual.text as Spanned).getSpans(0, 0, NativeRunLineMetrics::class.java).single()
        assertTrue(retained.strut && retained.includePrimaryInNormal)
        assertEquals(Spanned.SPAN_MARK_MARK, (actual.text as Spanned).getSpanFlags(retained))

        // Empty Normal's actual layout paint is the small owner, never an unrelated large
        // inherited header default. This also covers the default-paint envelope without glyphs.
        val normal = source("", smallOwner, ExactPaint(smallOwner), NativeLineHeightPolicy.Normal)
        val small = NativeFloatGeometry.build(normal, smallOwner, 100, emptyList())
        val natural = layout(normal, smallOwner, 100)
        assertEquals(natural.height.toFloat(), small.textBottom, 0f)
        val legacy = NativeFloatGeometry.build(SpannableString(""), oldLargeDefault, 100, emptyList())
        assertEquals(layout(SpannableString(""), oldLargeDefault, 100).height, legacy.height)
        assertTrue(legacy.height > small.height)

        // An independently admitted no-line owner remains absent. A Cell snapshot cannot
        // manufacture source lines; the Compose lowering does not attach its point marker here.
        val absent = SpannableString("").apply {
            setSpan(NativeAuthoredTextWrap(TextWrap.NoWrap, inheritedOwner = true,
                sourceLineStarts = emptyList()), 0, 0, Spanned.SPAN_MARK_MARK)
        }
        val noLine = NativeFloatGeometry.build(absent, paint(0f), 0, emptyList())
        assertEquals(0f, noLine.textBottom, 0f)
        assertEquals(0, noLine.height)
        assertTrue(noLine.nodes.isEmpty())
        assertEquals("", noLine.text.toString())
        val zero = paint(0f)
        val zeroText = source("x", zero, ExactPaint(zero), NativeLineHeightPolicy.Normal)
        val zeroGeometry = NativeFloatGeometry.build(zeroText, zero, 100, emptyList())
        assertEquals("x", zeroGeometry.text.toString())
        assertEquals(0f, zeroGeometry.textBottom, 0f)
        assertEquals(0, zeroGeometry.height)
    }
}
