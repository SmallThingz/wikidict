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
    val policy: NativeLineHeightPolicy, val strut: Boolean = false,
    val includePrimaryInNormal: Boolean = false,
    val independentNormalStrut: Boolean = false) {
    init { require(!(includePrimaryInNormal || independentNormalStrut) || strut) }
}

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
    natural: NativeUsedLineMetrics, pointOnLine: ((Int) -> Boolean)? = null): NativeUsedLineMetrics? {
    require(start in 0..source.length && end in start..source.length)
    fun intersects(span: Any): Boolean {
        val first = source.getSpanStart(span)
        val last = source.getSpanEnd(span)
        return if (start == end) first <= start && last == source.length else first < end && last > start
    }
    val runs = source.getSpans(start, end, NativeRunLineMetrics::class.java).filter(::intersects)
    val authored = source.getSpans(start, end, NativeAuthoredInlineMetrics::class.java).filter { run ->
        val first = source.getSpanStart(run)
        val last = source.getSpanEnd(run)
        if (first == last) pointOnLine?.invoke(first) ?: nativeInlinePointInRange(source, first, start, end)
        else first < end && last > start
    }
    if (runs.isEmpty() && authored.isEmpty()) return null
    val explicitHeight = runs.any { it.policy != NativeLineHeightPolicy.Normal } ||
        authored.any { it.policy != NativeLineHeightPolicy.Normal }
    val independentPoints = if (!explicitHeight) emptyList() else authored.filter { run ->
        val offset = source.getSpanStart(run)
        run.policy == NativeLineHeightPolicy.Normal && offset == source.getSpanEnd(run) &&
            (run.emptyBoxStrut || source.getSpans(offset, offset, NativeInlineActionPoint::class.java).any { point ->
                point.metrics === run && source.getSpanStart(point) == offset && source.getSpanEnd(point) == offset
            })
    }
    fun independentPoint(run: NativeAuthoredInlineMetrics): Boolean = independentPoints.any { it === run }
    // A V strut has no painted fallback text. Its primary font is independent of
    // explicit descendants; a Normal text run still needs the native fallback envelope.
    // All-Normal lines retain their existing native-envelope path.
    val independentNormal = explicitHeight && (runs.any { it.independentNormalStrut } || independentPoints.isNotEmpty())
    val consumesNatural = runs.any { it.policy == NativeLineHeightPolicy.Normal &&
        !(independentNormal && it.independentNormalStrut) } || authored.any {
        it.policy == NativeLineHeightPolicy.Normal && !independentPoint(it)
    }
    if ((independentNormal || authored.any { it.policy != NativeLineHeightPolicy.Normal &&
            source.getSpanStart(it) < source.getSpanEnd(it) }) && consumesNatural)
        throw UnsupportedFloatLayout("Authored inline height with mixed native normal owners is unavailable")
    fun primaryBounds(primary: NativePrimaryFontMetrics) = NativeUsedLineMetrics(
        primary.ascent + primary.baselineShift, primary.descent + primary.baselineShift)
    var used: NativeUsedLineMetrics? = null
    for (run in runs) {
        val bounds = run.primary.authored(run.policy) ?: if (independentNormal && run.independentNormalStrut) {
            primaryBounds(run.primary)
        } else if (run.includePrimaryInNormal) {
            // A source Cell owner participates independently of the painted descendants.
            // Keep Android's real fallback envelope as well as that owner's primary font.
            natural.including(NativeUsedLineMetrics(run.primary.ascent + run.primary.baselineShift,
                run.primary.descent + run.primary.baselineShift))
        } else natural
        used = used?.including(bounds) ?: bounds
    }
    for (run in authored) {
        // Normal keeps the platform's fallback-aware envelope. A fractional explicit
        // shift with Normal is refused before shaping; no paragraph envelope is shifted.
        val own = run.primary.authored(run.policy) ?: if (independentPoint(run)) primaryBounds(run.primary) else natural
        used = used?.including(own) ?: own
        run.declaringPrimary?.let { declaring ->
            val owner = declaring.authored(run.policy) ?: NativeUsedLineMetrics(
                declaring.ascent + declaring.baselineShift, declaring.descent + declaring.baselineShift)
            used = used!!.including(owner)
        }
    }
    source.getSpans(start, end, NativeAtomicInlineMetrics::class.java).filter(::intersects).forEach {
        used = used!!.including(it.nativeUsedMetrics)
    }
    // These controls are already contained only when the native envelope was consumed.
    // An independent Normal strut supplies its own font, so the controls still apply once.
    if (!consumesNatural) {
        source.getSpans(start, end, NativeLineMinimum::class.java).filter(::intersects).forEach {
            used = used!!.including(it.primary.authored(NativeLineHeightPolicy.Pixels(it.pixels))!!)
        }
        source.getSpans(start, end, NativeLineGap::class.java).filter(::intersects).forEach {
            if (source.getSpanEnd(it) <= end) used = NativeUsedLineMetrics(used!!.top, used!!.bottom + it.pixels)
        }
    }
    return used
}
