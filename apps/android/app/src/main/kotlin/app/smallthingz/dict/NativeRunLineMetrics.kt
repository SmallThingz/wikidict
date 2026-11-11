package app.smallthingz.dict

import android.text.Spanned
import android.text.TextPaint

/** Computed inheritance: a length is resolved once, while a number follows each descendant font. */
internal sealed interface NativeLineHeightPolicy {
    data object Normal : NativeLineHeightPolicy
    data class Pixels(val value: Float) : NativeLineHeightPolicy {
        init { require(value.isFinite() && value >= 0f) }
    }
    data class Multiplier(val value: Float) : NativeLineHeightPolicy {
        init { require(value.isFinite() && value >= 0f) }
    }
}

/**
 * Immutable base-font metrics from the exact resolved native Paint. Android's text-independent
 * getFontMetrics uses Typeface's baseFontFaked; it does not aggregate text-specific fallback runs.
 * Elegant-text metrics, if selected on that Paint, remain the platform's effective metrics.
 */
internal data class NativePrimaryFontMetrics(val ascent: Float, val descent: Float,
    val fontSize: Float, val baselineShift: Float) {
    init {
        require(listOf(ascent, descent, fontSize, baselineShift).all { it.isFinite() })
        require(descent >= ascent && fontSize >= 0f)
    }
    fun authored(policy: NativeLineHeightPolicy): NativeUsedLineMetrics? {
        val height = when (policy) {
            NativeLineHeightPolicy.Normal -> return null
            is NativeLineHeightPolicy.Pixels -> policy.value
            is NativeLineHeightPolicy.Multiplier -> (fontSize.toDouble() * policy.value).toFloat()
        }
        if (!height.isFinite()) throw UnsupportedFloatLayout("Computed native line height exceeds geometry")
        return nativeInlineLineMetrics(ascent, descent, height, baselineShift)
    }
    companion object {
        fun from(paint: TextPaint): NativePrimaryFontMetrics {
            val metrics = paint.fontMetrics
            return NativePrimaryFontMetrics(metrics.ascent, metrics.descent, paint.textSize,
                paint.baselineShift.toFloat())
        }
    }
}

/** A paragraph strut or styled text run; these spans never mutate native font/paint metrics. */
internal class NativeRunLineMetrics(val primary: NativePrimaryFontMetrics,
    val policy: NativeLineHeightPolicy, val strut: Boolean = false)

/** Real replaced boxes keep their own aligned margin box independently of text line-height. */
internal interface NativeAtomicInlineMetrics {
    val nativeUsedMetrics: NativeUsedLineMetrics
}

/** Additional block/control requirements remain explicit instead of inflating font metrics. */
internal class NativeLineMinimum(val primary: NativePrimaryFontMetrics, val pixels: Float) {
    init { require(pixels.isFinite() && pixels >= 0f) }
}
internal class NativeLineGap(val pixels: Float) {
    init { require(pixels.isFinite() && pixels >= 0f) }
}

/**
 * Normal lines retain the real fallback-aware native line envelope. Authored heights use the
 * root strut plus every style's primary-font half-leading and each real replaced margin box.
 * Original StaticLayout glyph metrics and owners remain untouched for paint, caret and selection.
 */
internal fun nativeRunLineMetrics(source: Spanned, start: Int, end: Int,
    natural: NativeUsedLineMetrics): NativeUsedLineMetrics? {
    require(start in 0..source.length && end in start..source.length)
    fun intersects(span: Any): Boolean {
        val first = source.getSpanStart(span)
        val last = source.getSpanEnd(span)
        return if (start == end) first <= start && last == source.length else first < end && last > start
    }
    val runs = source.getSpans(start, end, NativeRunLineMetrics::class.java).filter(::intersects)
    if (runs.isEmpty()) return null
    var used: NativeUsedLineMetrics? = null
    for (run in runs) {
        val bounds = run.primary.authored(run.policy) ?: natural
        used = used?.including(bounds) ?: bounds
    }
    source.getSpans(start, end, NativeAtomicInlineMetrics::class.java).filter(::intersects).forEach {
        used = used!!.including(it.nativeUsedMetrics)
    }
    // Native normal metrics already contain these legacy control and paragraph-gap spans.
    if (runs.none { it.policy == NativeLineHeightPolicy.Normal }) {
        source.getSpans(start, end, NativeLineMinimum::class.java).filter(::intersects).forEach {
            used = used!!.including(it.primary.authored(NativeLineHeightPolicy.Pixels(it.pixels))!!)
        }
        source.getSpans(start, end, NativeLineGap::class.java).filter(::intersects).forEach {
            if (source.getSpanEnd(it) <= end) used = NativeUsedLineMetrics(used!!.top, used!!.bottom + it.pixels)
        }
    }
    return used
}
