package app.smallthingz.dict

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.text.Layout
import android.text.SpannableString
import android.text.Spanned
import android.text.StaticLayout
import android.text.TextPaint
import android.text.style.ReplacementSpan
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.filters.SdkSuppress
import androidx.test.platform.app.InstrumentationRegistry
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class NativeEgyptianOverflowDeviceTest {
    @Test @SdkSuppress(minSdkVersion = 31)
    fun zeroContainingWidthRetainsOriginalShapedEgyptianInkTrackingAndBaseline() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val text = "\ud80c\udc00\ud80c\udc01"
        val paint = TextPaint(Paint.ANTI_ALIAS_FLAG).apply {
            textSize = 48f; color = Color.BLUE; letterSpacing = .3f
        }
        val preparation = runBlocking {
            prepareNativeEgyptianSpan(context, EgyptianTextRun(0, text.length, text, true), paint,
                .2f, underline = true, strike = false, foreground = Color.BLUE, background = null)
        }
        assertTrue(preparation.error?.toString(), preparation.available)
        val zeroSpan = preparation.spanForWidth(0f)
        val naturalSpan = preparation.spanForWidth(1024f)
        val zeroWidth = zeroSpan.getSize(paint, text, 0, text.length, null)
        assertEquals(naturalSpan.getSize(paint, text, 0, text.length, null), zeroWidth)
        assertTrue(zeroWidth > 1)
        for (bad in listOf(-1f, Float.NaN, Float.POSITIVE_INFINITY)) {
            try { preparation.spanForWidth(bad); fail("Invalid width accepted: $bad") }
            catch (_: IllegalArgumentException) { }
        }
        fun source(span: ReplacementSpan) = SpannableString(text).apply {
            setSpan(span, 0, length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
            setSpan(NativeRunLineMetrics(NativePrimaryFontMetrics.from(paint), NativeLineHeightPolicy.Pixels(0f), strut = true),
                0, length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        }
        val original = source(zeroSpan)
        val geometry = NativeFloatGeometry.build(original, paint, 0, emptyList())
        assertEquals(0, geometry.width); assertEquals(0, geometry.height)
        assertEquals(text, geometry.text.toString())
        assertSame(zeroSpan, original.getSpans(0, text.length, ReplacementSpan::class.java).single())
        val natural = source(naturalSpan)
        val native = StaticLayout.Builder.obtain(natural, 0, natural.length, TextPaint(paint), 1024)
            .setIncludePad(true).setUseLineSpacingFromFallbacks(true)
            .setBreakStrategy(android.graphics.text.LineBreaker.BREAK_STRATEGY_SIMPLE)
            .setHyphenationFrequency(Layout.HYPHENATION_FREQUENCY_NONE).build()
        assertEquals(1, native.lineCount)
        val actual = Bitmap.createBitmap(1200, 256, Bitmap.Config.ARGB_8888)
        val expected = Bitmap.createBitmap(1200, 256, Bitmap.Config.ARGB_8888)
        try {
            Canvas(actual).apply { translate(40f, 120f); geometry.paint(this) }
            Canvas(expected).apply {
                translate(40f, 120f + geometry.baselineForOffset(0) - native.getLineBaseline(0)); native.draw(this)
            }
            val found = IntArray(1200 * 256)
            val wanted = IntArray(found.size)
            actual.getPixels(found, 0, 1200, 0, 0, 1200, 256)
            expected.getPixels(wanted, 0, 1200, 0, 0, 1200, 256)
            assertTrue("Real shaped Egyptian ink survives", wanted.count { Color.alpha(it) != 0 } > 50)
            assertArrayEquals(wanted, found)
            val reference = NativeFloatGeometry.build(natural, paint, 1024, emptyList())
            assertEquals(reference.characterRects(0, text.length), geometry.characterRects(0, text.length))
            val bounds = geometry.rectsForRange(0, text.length)
            assertTrue(bounds.any { it.width() >= zeroWidth && (it.top < 0f || it.bottom > 0f) })
        } finally { actual.recycle(); expected.recycle() }
    }
}
