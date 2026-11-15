package app.smallthingz.dict

import android.graphics.Rect
import android.text.Layout
import android.text.PrecomputedText
import android.text.Spanned
import android.text.TextPaint
import android.text.style.CharacterStyle
import android.text.style.LeadingMarginSpan
import android.text.style.LineBackgroundSpan
import android.text.style.ReplacementSpan
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min

/** Bounds relative to the replacement's actual x and baseline, from its existing painter. */
internal interface NativeReplacementPaintBounds {
    fun nativePaintBounds(lineTop: Float, lineBottom: Float): NativeFloatBounds?
}

/** Interactive paint may add an underline without changing the immutable text metrics. */
internal interface NativeMayUnderline { val mayUnderline: Boolean }

/** Custom paragraph painters publish their own bounds; their callbacks remain the paint owner. */
internal interface NativeParagraphPaintBounds {
    fun nativePaintBounds(layout: Layout, line: Int): NativeFloatBounds?
}

/**
 * A conservative allocation envelope, never an advance, intrinsic width or hit-test rectangle.
 * The native painter supplies the actual run context and draw origin for bounds.
 * Unsupported paint paths retain conservative paragraph-range bounds.
 * Bound all piece prefixes by retained advances and all visual origins by native cursor positions.
 * Native shaping/bidi/tabs remain in the same compatible PrecomputedText/StaticLayout pair.
 */
internal fun nativeTextInkBounds(layout: Layout, placements: List<NativeLinePaintPlacement>): NativeFloatBounds? {
    val source = layout.text as PrecomputedText
    var result: NativeFloatBounds? = null
    fun include(value: NativeFloatBounds?) { result = enclosingBounds(result, value) }
    val bounds = Rect()
    val observed = NativeLinePainter(layout).observedPaintBounds(placements)
    if (observed.textComplete) include(observed.text)
    for (position in placements) {
        val line = position.line
        val start = layout.getLineStart(line)
        val end = layout.getLineEnd(line)
        val baseline = position.baseline
        val top = layout.getLineTop(line) - layout.getLineBaseline(line).toFloat()
        val bottom = layout.getLineBottom(line) - layout.getLineBaseline(line).toFloat()
        val replacements = source.getSpans(start, end, ReplacementSpan::class.java).filter {
            source.getSpanStart(it) < end && source.getSpanEnd(it) > start
        }
        var prefixBound = 0.0
        var left = Double.POSITIVE_INFINITY
        var right = Double.NEGATIVE_INFINITY
        if (!observed.textComplete || replacements.isNotEmpty()) {
            // Only conservative text/replacement origins need this scan. Exact native run
            // bounds already include their real origin, even across tabs and bidi boundaries.
            for (offset in start..end) {
                val primary = layout.getPrimaryHorizontal(offset).toDouble() + position.originX
                val secondary = layout.getSecondaryHorizontal(offset).toDouble() + position.originX
                left = min(left, min(primary, secondary))
                right = max(right, max(primary, secondary))
                if (!observed.textComplete && offset < end) prefixBound += abs(source.getWidth(offset, offset + 1).toDouble())
            }
            checkCoordinate(left); checkCoordinate(right); checkCoordinate(prefixBound)
        }
        if (start < end && !observed.textComplete) {
            val paints = drawPaints(source, start, end, layout.paint)
            val shifts = paints.map { it.baselineShift.toFloat() } +
                source.getSpans(start, end, NativeAuthoredBaselineShift::class.java).filter {
                    source.getSpanStart(it) < end && source.getSpanEnd(it) > start
                }.map { it.shift }
            val minShift = shifts.minOrNull() ?: 0f
            val maxShift = shifts.maxOrNull() ?: 0f
            source.getBounds(start, end, bounds)
            if (!bounds.isEmpty) include(checkedBounds(left + bounds.left - prefixBound,
                baseline + bounds.top.toDouble() + minShift,
                right + bounds.right + prefixBound, baseline + bounds.bottom.toDouble() + maxShift))
        }
        for (span in replacements) {
            val owned = span as? NativeReplacementPaintBounds
                ?: throw UnsupportedFloatLayout("Native replacement requires its own paint bounds")
            owned.nativePaintBounds(top, bottom)?.let {
                // Its visual origin is one of the native run origins bounded above. This
                // deliberate overestimate also covers an RTL replacement's left origin.
                include(checkedBounds(left + it.left, baseline + it.top.toDouble(),
                    right + it.right, baseline + it.bottom.toDouble()))
            }
        }
        for (span in source.getSpans(start, end, Any::class.java)) {
            if (source.getSpanStart(span) >= end || source.getSpanEnd(span) <= start) continue
            when {
                span is NativeParagraphPaintBounds -> include(span.nativePaintBounds(layout, line)
                    ?.translated(position.originX, baseline - layout.getLineBaseline(line)))
                span is LeadingMarginSpan.Standard -> Unit // Its native draw callback is empty.
                span is LineBackgroundSpan.Standard -> include(checkedBounds(position.originX.toDouble(),
                    baseline + top.toDouble(), layout.width.toDouble() + position.originX, baseline + bottom.toDouble()))
                span is LeadingMarginSpan || span is LineBackgroundSpan ->
                    throw UnsupportedFloatLayout("Native paragraph decoration requires its own paint bounds")
            }
        }
    }
    // The owned native paints are FILL/no-shadow. Observe the exact platform decorations,
    // including dynamic Missing underline, through public platform paint callbacks.
    return enclosingBounds(result, observed.decorations)
}

private fun drawPaints(source: Spanned, start: Int, end: Int, base: TextPaint): List<TextPaint> {
    if (start == end) return listOf(TextPaint(base))
    val result = mutableListOf<TextPaint>()
    var cursor = start
    while (cursor < end) {
        val next = source.nextSpanTransition(cursor, end, CharacterStyle::class.java)
        val spans = source.getSpans(cursor, next, CharacterStyle::class.java)
        val paint = TextPaint(base)
        spans.forEach { it.updateDrawState(paint) }
        if (spans.any { it is NativeMayUnderline && it.mayUnderline }) paint.isUnderlineText = true
        result += paint
        cursor = next
    }
    return result
}

private fun checkCoordinate(value: Double) {
    if (!value.isFinite() || abs(value) > Int.MAX_VALUE / 4.0)
        throw UnsupportedFloatLayout("Native paint envelope exceeds the coordinate range")
}

private fun checkedBounds(left: Double, top: Double, right: Double, bottom: Double): NativeFloatBounds {
    listOf(left, top, right, bottom).forEach(::checkCoordinate)
    return NativeFloatBounds(left.toFloat(), top.toFloat(), right.toFloat(), bottom.toFloat())
}
