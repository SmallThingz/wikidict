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
import androidx.test.platform.app.InstrumentationRegistry
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class NativeEgyptianOverflowDeviceTest {
    @Test
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

    @Test
    fun rubyLocalGlyphCopyKeepsScaledEnvelopeAndAtomicReplay() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val text = "\ud80c\udc00\ud80c\udc01"
        val paint = TextPaint(Paint.ANTI_ALIAS_FLAG).apply { textSize = 48f; color = Color.BLUE; letterSpacing = .2f }
        val run = EgyptianTextRun(0, text.length, text, true)
        fun prepare(shift: Float, source: EgyptianTextRun = run, background: Int? = null) = runBlocking {
            prepareNativeEgyptianSpan(context, source, paint, shift, underline = false,
                strike = false, foreground = Color.BLUE, background = background)
        }
        val shifted = prepare(.2f)
        val neutral = prepare(0f)
        assertTrue(shifted.error?.toString(), shifted.available)
        assertTrue(neutral.error?.toString(), neutral.available)
        val policy = NativeMissingLinkPaint(MissingLinkPaint.VectorNewLinkV1, dark = false, visited = false)
        val bitmaps = mutableListOf<Bitmap>()
        var primary: Throwable? = null
        try {
            fun render(span: ReplacementSpan, parent: Float, atomic: Boolean = false): IntArray {
                val bitmap = Bitmap.createBitmap(256, 192, Bitmap.Config.ARGB_8888).also(bitmaps::add)
                val target = Canvas(bitmap)
                target.translate(0f, parent)
                var atoms = 0
                val canvas = if (!atomic) target else object : Canvas(), NativeRubyAtomicCanvas {
                    override fun paintRubyAtom(x: Float, y: Float, draw: (Canvas) -> Unit) {
                        atoms++
                        val save = target.save()
                        try { target.translate(x + 7.25f, y); draw(target) }
                        finally { target.restoreToCount(save) }
                    }
                }
                span.draw(canvas, text, 0, text.length, 24f, 0, 96, 192, paint)
                if (atomic) assertEquals(1, atoms)
                return IntArray(256 * 192).also { bitmap.getPixels(it, 0, 256, 0, 0, 256, 192) }
            }
            val original = shifted.spanForWidth(0f, policy)
            val originalBounds = checkNotNull((original as NativeReplacementPaintBounds).nativePaintBounds(0f, 0f))
            val captured = (original as NativeRubyGlyphReplacement).nativeRubyScriptShift
            val relative = original.withRubyLocalShift(captured - 3.25f)
            val relativeBounds = checkNotNull((relative as NativeReplacementPaintBounds).nativePaintBounds(0f, 0f))
            assertEquals(originalBounds.top - 3.25f, relativeBounds.top, .0001f)
            assertEquals(originalBounds.bottom - 3.25f, relativeBounds.bottom, .0001f)
            assertEquals(original.getSize(paint, text, 0, text.length, null),
                relative.getSize(paint, text, 0, text.length, null))
            val rawPixels = render(original, 0f)
            assertTrue(rawPixels.any { Color.alpha(it) != 0 })
            assertArrayEquals(rawPixels, render(relative, 3.25f))
            val repeated = (relative as NativeRubyGlyphReplacement).withRubyLocalShift(captured - 3.25f)
            assertArrayEquals(rawPixels, render(repeated, 3.25f)) // Always uses original captured origin.
            assertEquals(original.nativeRubyScriptShift, relative.nativeRubyScriptShift, 0f)
            assertFalse(original is NativeAtomicInlineMetrics)
            assertFalse(original is NativeRubyResolvedGlyphReplacement)
            assertTrue(relative is NativeRubyResolvedGlyphReplacement)
            val oldMetrics = Paint.FontMetricsInt()
            original.getSize(paint, text, 0, text.length, oldMetrics)
            val used = (relative as NativeAtomicInlineMetrics).nativeUsedMetrics
            assertEquals(oldMetrics.ascent - 3.25f, used.top, 0f)
            assertEquals(oldMetrics.descent - 3.25f, used.bottom, 0f)

            val backed = prepare(.2f, background = Color.GREEN)
            assertTrue(backed.error?.toString(), backed.available)
            val backedOriginal = backed.spanForWidth(13.25f, policy)
            val backedTarget = (backedOriginal as NativeRubyGlyphReplacement).nativeRubyScriptShift - 3.25f
            val backedRelative = backedOriginal.withRubyLocalShift(backedTarget)
            assertArrayEquals(render(backedOriginal, 0f), render(backedRelative, 3.25f))
            val backedBounds = checkNotNull((backedOriginal as NativeReplacementPaintBounds).nativePaintBounds(0f, 0f))
            val movedBounds = checkNotNull((backedRelative as NativeReplacementPaintBounds).nativePaintBounds(0f, 0f))
            assertEquals(backedBounds.top - 3.25f, movedBounds.top, .0001f)
            assertEquals(backedBounds.bottom - 3.25f, movedBounds.bottom, .0001f)

            val narrow = shifted.spanForWidth(13.25f, policy)
            val plainNarrow = neutral.spanForWidth(13.25f, policy)
            assertTrue(narrow.getSize(paint, text, 0, text.length, null) < original.getSize(paint, text, 0, text.length, null))
            val zero = (narrow as NativeRubyGlyphReplacement).withRubyLocalShift(0f)
            val local = narrow.withRubyLocalShift(.75f)
            assertEquals(narrow.nativeRubyScriptShift, (local as NativeRubyGlyphReplacement).nativeRubyScriptShift, 0f)
            assertEquals(plainNarrow.getSize(paint, text, 0, text.length, null), zero.getSize(paint, text, 0, text.length, null))
            assertArrayEquals(render(plainNarrow, 3.25f), render(zero, 3.25f))
            assertArrayEquals(render(plainNarrow, 4f), render(local, 3.25f))
            val localBounds = checkNotNull((local as NativeReplacementPaintBounds).nativePaintBounds(0f, 0f))
            val plainBounds = checkNotNull((plainNarrow as NativeReplacementPaintBounds).nativePaintBounds(0f, 0f))
            assertEquals(plainBounds.top + .75f, localBounds.top, .0001f)
            val exactSource = SpannableString(text).apply { setSpan(local, 0, length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE) }
            assertEquals(text, exactSource.toString())
            assertEquals(0, exactSource.getSpanStart(local)); assertEquals(text.length, exactSource.getSpanEnd(local))
            exactSource.setSpan(NativeRunLineMetrics(NativePrimaryFontMetrics(0f, 0f, 0f, 0f),
                NativeLineHeightPolicy.Pixels(0f), strut = true), 0, text.length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
            assertEquals((local as NativeAtomicInlineMetrics).nativeUsedMetrics.including(NativeUsedLineMetrics(0f, 0f)),
                nativeRunLineMetrics(exactSource, 0, text.length, NativeUsedLineMetrics(-200f, 200f)))

            val atomicPixels = render(local, 3.25f, atomic = true)
            val direct = Bitmap.createBitmap(256, 192, Bitmap.Config.ARGB_8888).also(bitmaps::add)
            Canvas(direct).apply {
                translate(7.25f, 3.25f)
                local.draw(this, text, 0, text.length, 24f, 0, 96, 192, paint)
            }
            val directPixels = IntArray(256 * 192).also { direct.getPixels(it, 0, 256, 0, 0, 256, 192) }
            assertArrayEquals(directPixels, atomicPixels)
            policy.hovered = true
            assertArrayEquals(render(plainNarrow, 4f), render(local, 3.25f)) // Same live paint owner after copying.

            val failed = prepare(0f, run.copy(fontFeatures = FontFeaturePolicy.Normal))
            assertFalse(failed.available)
            val marker = failed.spanForWidth(13.25f)
            assertTrue(marker.getSize(paint, text, 0, text.length, null) > 0)
            try {
                (marker as NativeRubyGlyphReplacement).withRubyLocalShift(0f)
                fail("Unavailable glyphs must retain the explicit Ruby fallback")
            } catch (failure: UnsupportedFloatLayout) {
                assertEquals("Egyptian glyph layout unavailable", failure.message)
            }
            assertArrayEquals(render(plainNarrow, 4f), render(local, 3.25f))
        } catch (failure: Throwable) {
            primary = failure
            throw failure
        } finally {
            var cleanup: Throwable? = null
            bitmaps.forEach { bitmap ->
                try { bitmap.recycle() } catch (failure: Throwable) {
                    if (cleanup == null) cleanup = failure
                    else if (failure !== cleanup) cleanup!!.addSuppressed(failure)
                }
            }
            cleanup?.let { failure ->
                if (primary == null) throw failure
                if (failure !== primary) primary?.addSuppressed(failure)
            }
        }
    }
}
