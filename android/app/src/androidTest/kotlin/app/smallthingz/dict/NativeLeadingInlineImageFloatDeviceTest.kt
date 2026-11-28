package app.smallthingz.dict

import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.RectF
import android.text.SpannableString
import android.text.Spanned
import android.text.TextPaint
import android.text.style.LeadingMarginSpan
import android.text.style.ReplacementSpan
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class NativeLeadingInlineImageFloatDeviceTest {
    private val exclusion = NativeFloatExclusion(TableFloatSide.Right, NativeFloatBounds(96f, -20f, 240f, 84f))

    @Test fun imageWiderThanLaneMovesBelowFloatAndRebreaksInFullWidth() {
        val geometry = build(110)

        assertEquals(84f, geometry.firstLineBand().top, .001f)
        assertEquals(216f, geometry.nativeLineAvailableWidth(0), .001f)
        assertEquals(0 to geometry.text.length, geometry.nativeRangeOfLine(0))
        assertEquals(24f, geometry.nativeReplacementOrigin(0).first, .001f)
    }

    @Test fun imageThatFitsKeepsItsLineBesideFloat() {
        val geometry = build(50)

        assertEquals(0f, geometry.firstLineBand().top, .001f)
        assertEquals(72f, geometry.nativeLineAvailableWidth(0), .001f)
        assertEquals(24f, geometry.nativeReplacementOrigin(0).first, .001f)
    }

    @Test fun rebreaksTallAndShortImagesBeforeMovingTheLeadingImageDown() {
        val source = SpannableString("\uFFFC \uFFFC").apply {
            setSpan(InlineImage(50, 10, 0), 0, 1, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
            setSpan(InlineImage(36, 60, 2), 2, 3, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        }
        val stacked = listOf(
            NativeFloatExclusion(TableFloatSide.Right, NativeFloatBounds(80f, 0f, 100f, 30f)),
            NativeFloatExclusion(TableFloatSide.Right, NativeFloatBounds(40f, 30f, 100f, 100f)),
        )
        val geometry = NativeFloatGeometry.build(source, TextPaint().apply { textSize = 12f }, 100, emptyList(),
            carriedExclusions = stacked, includeFontPadding = false)

        assertEquals(2, geometry.shapedLineCount)
        assertEquals(0 to 2, geometry.nativeRangeOfLine(0))
        assertEquals(2 to 3, geometry.nativeRangeOfLine(1))
        assertEquals(0f, geometry.firstLineBand().top, .001f)
        assertEquals(80f, geometry.nativeLineAvailableWidth(0), .001f)
        assertEquals(40f, geometry.nativeLineAvailableWidth(1), .001f)
        val tallImageTop = geometry.nativeReplacementOrigin(2).second - 60f
        assertEquals(geometry.nativeRubyLineTop(1), tallImageTop, .001f)
        assertTrue(tallImageTop in 0f..<30f)
    }

    @Test fun countsTheNativeParagraphLeadingMarginInTheImageLane() {
        val source = SpannableString("\uFFFC").apply {
            setSpan(InlineImage(60), 0, 1, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
            setSpan(LeadingMarginSpan.Standard(20, 0), 0, length, Spanned.SPAN_PARAGRAPH)
        }
        val nearby = NativeFloatExclusion(TableFloatSide.Right, NativeFloatBounds(70f, -20f, 100f, 84f))
        val geometry = NativeFloatGeometry.build(source, TextPaint().apply { textSize = 16f }, 100, emptyList(),
            carriedExclusions = listOf(nearby))

        assertEquals(84f, geometry.firstLineBand().top, .001f)
        assertEquals(100f, geometry.nativeLineAvailableWidth(0), .001f)
        assertEquals(20f, geometry.nativeReplacementOrigin(0).first, .001f)
    }

    @Test fun crossesLongAlternatingFloatBandsBeforeSettlingOnAFreeLine() {
        val source = SpannableString("\uFFFC").apply {
            setSpan(InlineImage(60, 10), 0, 1, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        }
        val bands = List(32) { index ->
            val top = index * 20f
            val bottom = top + 20f
            if (index % 2 == 0) {
                NativeFloatExclusion(TableFloatSide.Right, NativeFloatBounds(40f, top, 100f, bottom))
            } else {
                NativeFloatExclusion(TableFloatSide.Left, NativeFloatBounds(0f, top, 60f, bottom))
            }
        }
        val geometry = NativeFloatGeometry.build(source, TextPaint().apply { textSize = 8f }, 100, emptyList(),
            carriedExclusions = bands, includeFontPadding = false)

        assertEquals(1, geometry.shapedLineCount)
        assertEquals(0 to 1, geometry.nativeRangeOfLine(0))
        assertEquals(640f, geometry.firstLineBand().top, .001f)
        assertEquals(100f, geometry.nativeLineAvailableWidth(0), .001f)
        assertEquals(0f, geometry.nativeReplacementOrigin(0).first, .001f)
    }

    private fun build(imageWidth: Int): NativeFloatGeometry {
        val source = SpannableString("\uFFFC label").apply {
            setSpan(InlineImage(imageWidth), 0, 1, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        }
        return NativeFloatGeometry.build(source, TextPaint().apply { textSize = 16f }, 240, emptyList(),
            carriedExclusions = listOf(exclusion), insets = NativeTextInsets(extraLeft = 24f))
    }

    private class InlineImage(private val width: Int, private val height: Int = 16,
        override val nativeImageSourceOffset: Int = 0) : ReplacementSpan(), NativeFloatInlineImage {
        override val nativeImageId = nativeImageSourceOffset
        override val nativeImageWidth = width.toFloat()
        override val nativeImageHeight = height.toFloat()
        override val nativeImageInkBounds = NativeFloatBounds(0f, 0f, nativeImageWidth, nativeImageHeight)
        override val nativeImageOccurrence: NativeImageOccurrencePlacement? = null
        override val nativeUsedMetrics = NativeUsedLineMetrics(-nativeImageHeight, 0f)

        override fun getSize(paint: Paint, text: CharSequence, start: Int, end: Int, fm: Paint.FontMetricsInt?): Int {
            fm?.let {
                it.ascent = minOf(it.ascent, -height)
                it.top = minOf(it.top, it.ascent)
            }
            return width
        }

        override fun nativePaintBounds(lineTop: Float, lineBottom: Float) =
            nativeImageInkBounds.translated(0f, nativeUsedMetrics.top)

        override fun drawNativeImage(canvas: Canvas, outer: RectF) = Unit

        override fun draw(canvas: Canvas, text: CharSequence, start: Int, end: Int, x: Float,
            top: Int, y: Int, bottom: Int, paint: Paint) = Unit
    }
}
