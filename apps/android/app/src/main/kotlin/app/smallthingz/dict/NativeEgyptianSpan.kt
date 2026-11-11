package app.smallthingz.dict

import android.content.Context
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.RectF
import android.os.Build
import android.text.TextPaint
import android.text.style.ReplacementSpan
import androidx.annotation.RequiresApi
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlin.math.ceil
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min

/** Shape once per immutable logical run; resizing changes only the span's drawing scale. */
internal class NativeEgyptianSpanPreparation internal constructor(
    val available: Boolean,
    val error: Throwable?,
    private val createSpan: (Float, NativeMissingLinkPaint?) -> ReplacementSpan,
) {
    fun spanForWidth(width: Float, missingLinkPaint: NativeMissingLinkPaint? = null): ReplacementSpan {
        require(width.isFinite() && width > 0f)
        return createSpan(width, missingLinkPaint)
    }
}

/** Parent installs the span on run.start..run.end of the unchanged original text.
 * Paint is resolved at that range (size, resource typeface, fake bold and skew).
 * This span owns baseline shifting and decorations; do not apply those twice.
 */
internal suspend fun prepareNativeEgyptianSpan(
    context: Context,
    run: EgyptianTextRun,
    paint: TextPaint,
    baselineShiftMultiplier: Float,
    underline: Boolean,
    strike: Boolean,
    foreground: Int,
    background: Int?,
): NativeEgyptianSpanPreparation {
    val capturedPaint = TextPaint(paint).apply {
        color = foreground
        isUnderlineText = false
        isStrikeThruText = false
        baselineShift = 0
    }
    return try {
        if (Build.VERSION.SDK_INT < 31) throw UnsupportedOperationException("Egyptian glyph layout requires Android 12")
        val ink = prepareInk(context, run, capturedPaint, baselineShiftMultiplier, underline, strike)
        NativeEgyptianSpanPreparation(true, null) { width, linkPaint -> GlyphSpan(ink, capturedPaint, background, width, linkPaint) }
    } catch (cancelled: CancellationException) { throw cancelled }
    catch (failure: LinkageError) {
        NativeEgyptianSpanPreparation(false, failure) { width, linkPaint -> UnavailableEgyptianSpan(capturedPaint, background, width, linkPaint) }
    } catch (failure: Exception) {
        NativeEgyptianSpanPreparation(false, failure) { width, linkPaint -> UnavailableEgyptianSpan(capturedPaint, background, width, linkPaint) }
    }
}

private data class NativeEgyptianDecoration(val position: Float, val thickness: Float)

@RequiresApi(31)
private data class NativeEgyptianInk(
    val glyphs: EgyptianGlyphRun,
    val bounds: RectF,
    val naturalWidth: Float,
    val left: Float,
    val shift: Int,
    val metrics: Paint.FontMetricsInt,
    val decorations: List<NativeEgyptianDecoration>,
)

@RequiresApi(31)
private suspend fun prepareInk(context: Context, run: EgyptianTextRun, paint: TextPaint,
    baselineShiftMultiplier: Float, underline: Boolean, strike: Boolean): NativeEgyptianInk {
    val glyphs = EgyptianShaper.shape(context.applicationContext, run.text, paint.textSize)
        .withTracking(run.text, paint.letterSpacing * paint.textSize)
    return withContext(Dispatchers.IO) {
        val decorations = buildList {
            if (underline) add(NativeEgyptianDecoration(paint.underlinePosition, max(1f, paint.underlineThickness)))
            if (strike) add(NativeEgyptianDecoration(paint.strikeThruPosition, max(1f, paint.strikeThruThickness)))
        }
        var ink: RectF? = null
        for (index in 0 until glyphs.glyphCount()) {
            val bounds = RectF()
            glyphs.getFont(index).getGlyphBounds(glyphs.getGlyphId(index), paint, bounds)
            if (!bounds.isEmpty) {
                bounds.offset(glyphs.getGlyphX(index), glyphs.getGlyphY(index))
                if (ink == null) ink = bounds else ink!!.union(bounds)
            }
        }
        val bounds = checkNotNull(ink) { "Egyptian run has no drawing glyphs" }
        decorations.forEach { bounds.union(0f, it.position - it.thickness / 2, glyphs.advance, it.position + it.thickness / 2) }
        val left = min(0f, bounds.left)
        val width = max(glyphs.advance, bounds.right) - left
        check(width.isFinite() && bounds.height().isFinite() && width > 0f && bounds.height() > 0f)
        NativeEgyptianInk(glyphs, RectF(bounds), width, left,
            ceil(paint.ascent() * baselineShiftMultiplier).toInt(), paint.fontMetricsInt, decorations)
    }
}

@RequiresApi(31)
private class GlyphSpan(
    private val ink: NativeEgyptianInk,
    private val inkPaint: TextPaint,
    private val background: Int?,
    availableWidth: Float,
    private val missingLinkPaint: NativeMissingLinkPaint?,
) : ReplacementSpan() {
    private val scale = min(1f, availableWidth / ink.naturalWidth)
    private val width = ceil(ink.naturalWidth * scale).toInt().coerceAtLeast(1)
    private val ascent = min(ink.metrics.ascent, floor((ink.bounds.top + ink.shift) * scale).toInt())
    private val descent = max(ink.metrics.descent, ceil((ink.bounds.bottom + ink.shift) * scale).toInt())

    override fun getSize(paint: Paint, text: CharSequence, start: Int, end: Int, fm: Paint.FontMetricsInt?): Int {
        fm?.let {
            it.ascent = ascent
            it.descent = descent
            it.top = min(ink.metrics.top, ascent)
            it.bottom = max(ink.metrics.bottom, descent)
            it.leading = ink.metrics.leading
        }
        return width
    }

    override fun draw(canvas: Canvas, text: CharSequence, start: Int, end: Int, x: Float, top: Int, y: Int, bottom: Int, paint: Paint) {
        val appearance = missingLinkPaint?.appearance()
        val drawingPaint = TextPaint(inkPaint).apply { appearance?.let { color = it.color } }
        if (background != null) {
            drawingPaint.color = background
            canvas.drawRect(x, (y + ascent).toFloat(), x + width, (y + descent).toFloat(), drawingPaint)
            drawingPaint.color = appearance?.color ?: inkPaint.color
        }
        val saved = canvas.save()
        try {
            canvas.translate(x, y.toFloat())
            canvas.scale(scale, scale)
            canvas.translate(-ink.left, ink.shift.toFloat())
            ink.glyphs.draw(canvas, drawingPaint)
            for (line in ink.decorations) {
                drawingPaint.strokeWidth = line.thickness
                canvas.drawLine(0f, line.position, ink.glyphs.advance, line.position, drawingPaint)
            }
            if (appearance?.underline == true && ink.decorations.none { it.position == inkPaint.underlinePosition }) {
                drawingPaint.strokeWidth = max(1f, inkPaint.underlineThickness)
                canvas.drawLine(0f, inkPaint.underlinePosition, ink.glyphs.advance, inkPaint.underlinePosition, drawingPaint)
            }
        } finally { canvas.restoreToCount(saved) }
    }
}

/** Explicit failure marker, while the original Egyptian scalars remain selectable and spoken. */
private class UnavailableEgyptianSpan(
    private val markerPaint: TextPaint,
    private val background: Int?,
    availableWidth: Float,
    private val missingLinkPaint: NativeMissingLinkPaint?,
) : ReplacementSpan() {
    private val size = max(1f, markerPaint.textSize)
    private val width = ceil(min(availableWidth, size)).toInt().coerceAtLeast(1)
    override fun getSize(paint: Paint, text: CharSequence, start: Int, end: Int, fm: Paint.FontMetricsInt?): Int {
        fm?.let {
            val original = markerPaint.fontMetricsInt
            it.ascent = min(original.ascent, -ceil(size).toInt())
            it.descent = original.descent
            it.top = min(original.top, it.ascent)
            it.bottom = original.bottom
            it.leading = original.leading
        }
        return width
    }
    override fun draw(canvas: Canvas, text: CharSequence, start: Int, end: Int, x: Float, top: Int, y: Int, bottom: Int, paint: Paint) {
        val appearance = missingLinkPaint?.appearance()
        val marker = TextPaint(markerPaint).apply {
            textSize = min(size, width.toFloat())
            appearance?.let { color = it.color; isUnderlineText = it.underline }
        }
        if (background != null) {
            marker.color = background
            canvas.drawRect(x, top.toFloat(), x + width, bottom.toFloat(), marker)
            marker.color = appearance?.color ?: markerPaint.color
        }
        // Default Latin typeface makes the failure marker independent of the Egyptian font.
        marker.typeface = android.graphics.Typeface.DEFAULT
        canvas.drawText("!", x, y.toFloat(), marker)
    }
}
