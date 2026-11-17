package app.smallthingz.dict

import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Path
import android.graphics.RectF
import android.text.Layout
import android.text.PrecomputedText
import android.text.TextDirectionHeuristic
import android.text.SpannableString
import android.text.SpannableStringBuilder
import android.text.Spanned
import android.text.StaticLayout
import android.text.TextPaint
import android.text.style.ReplacementSpan
import androidx.compose.ui.Modifier
import androidx.compose.ui.layout.IntrinsicMeasurable
import androidx.compose.ui.layout.IntrinsicMeasureScope
import androidx.compose.ui.layout.LayoutModifier
import androidx.compose.ui.layout.Measurable
import androidx.compose.ui.layout.MeasureResult
import androidx.compose.ui.layout.MeasureScope
import androidx.compose.ui.unit.Constraints
import java.text.BreakIterator
import kotlin.math.ceil

internal data class NativeWidthRange(val minimum: Int, val maximum: Int) {
    init { require(minimum >= 0 && maximum >= minimum) }
}

/** Only the source-verified new table-caption formatting context has this intrinsic policy. */
internal val LocalCaptionBreakWord = androidx.compose.runtime.staticCompositionLocalOf { false }

/** Supply widths from the native paragraph's prepared source, without composing a second owner. */
internal fun Modifier.nativeWidthIntrinsics(widths: () -> NativeWidthRange): Modifier = then(object : LayoutModifier {
    override fun MeasureScope.measure(measurable: Measurable, constraints: Constraints): MeasureResult {
        val child = measurable.measure(constraints)
        return layout(child.width, child.height) { child.place(0, 0) }
    }
    override fun IntrinsicMeasureScope.minIntrinsicWidth(measurable: IntrinsicMeasurable, height: Int) = widths().minimum
    override fun IntrinsicMeasureScope.maxIntrinsicWidth(measurable: IntrinsicMeasurable, height: Int) = widths().maximum
})

/** Preserved preformatted lines have no soft wrapping opportunities. */
internal fun Modifier.preformattedWidthIntrinsics(): Modifier = then(object : LayoutModifier {
    override fun MeasureScope.measure(measurable: Measurable, constraints: Constraints): MeasureResult {
        val child = measurable.measure(constraints)
        return layout(child.width, child.height) { child.place(0, 0) }
    }
    override fun IntrinsicMeasureScope.minIntrinsicWidth(measurable: IntrinsicMeasurable, height: Int) = measurable.maxIntrinsicWidth(height)
    override fun IntrinsicMeasureScope.maxIntrinsicWidth(measurable: IntrinsicMeasurable, height: Int) = measurable.maxIntrinsicWidth(height)
})

/** Real metric spans, including native glyph clusters and image boxes, participate in both widths. */
internal fun nativeTextWidthRange(source: Spanned, paint: TextPaint, inset: Float = 0f,
    breakWordMinimum: Boolean = false, textDirection: TextDirectionHeuristic? = null): NativeWidthRange {
    require(inset.isFinite() && inset >= 0f)
    val rubyDirection = textDirection ?: android.text.TextDirectionHeuristics.FIRSTSTRONG_LTR
    NativeClippedAbsoluteProjection.create(source)?.let { clipped ->
        if (!clipped.hasFlow) return NativeWidthRange(0, 0)
        return nativeTextWidthRange(clipped.visual, paint, inset, breakWordMinimum, textDirection)
    }
    if (nativeHasPositionedInlineImages(source)) {
        if (textDirection == null && source.getSpans(0, source.length, NativeAuthoredTextWrap::class.java)
                .any { it.wrap == TextWrap.NoWrap })
            throw UnsupportedFloatLayout("No-wrap intrinsic direction is unavailable")
        return nativeFloatRowWidthRange(source, paint, rubyDirection, inset, breakWordMinimum)
    }
    nativeRubyLayout(source, paint, rubyDirection)?.let { unbroken ->
        val maximum = nativeTextWidthRange(unbroken.native, paint, inset, breakWordMinimum, textDirection).maximum
        val fragmented = checkNotNull(nativeRubyLayout(source, paint, rubyDirection, NativeRubyBands(0f, allowEmergency = false)))
        val minimum = nativeTextWidthRange(fragmented.native, paint, inset, breakWordMinimum, textDirection).minimum
        if (minimum > maximum) throw UnsupportedFloatLayout("Ruby minimum exceeds its unbroken native width")
        return NativeWidthRange(minimum, maximum)
    }
    if (source.getSpans(0, source.length, NativeInlineBoxSpan::class.java).isNotEmpty() ||
            nativeHasCitationNoWrap(source)) {
        val bounded = nativeInlineBoxBoundedSource(source) { at ->
            nativeInlineBoxParagraphRtl(source, rubyDirection, at)
        }
        return NativeInlineBoxWidths(bounded, paint, rubyDirection).intrinsic(inset, breakWordMinimum)
    }
    val replacements = source.getSpans(0, source.length, ReplacementSpan::class.java)
    val wrapPlan = NativeTextWrapPlan.create(source, paint)
    wrapPlan?.noWrap?.let { plan ->
        plan.requireLinePresence()
        val direction = textDirection ?: throw UnsupportedFloatLayout("No-wrap intrinsic direction is unavailable")
        val measured = PrecomputedText.create(source, PrecomputedText.Params.Builder(TextPaint(paint))
            .setTextDirection(direction).setBreakStrategy(android.graphics.text.LineBreaker.BREAK_STRATEGY_SIMPLE)
            .setHyphenationFrequency(Layout.HYPHENATION_FREQUENCY_NONE).build())
        val advance = plan.maximumAdvance { start, end -> measured.getWidth(start, end) }
        val width = advance.toDouble() + inset
        val pixels = if (!width.isFinite() || width > TablePixelLimit) Constraints.Infinity else ceil(width).toInt()
        return NativeWidthRange(pixels, pixels)
    }
    var authoredMinimum = 0f
    val breaks = BreakIterator.getLineInstance(paint.textLocale).apply { setText(source.toString()) }
    val rubyBreaks = source.getSpans(0, source.length, NativeRubyBreaks::class.java).singleOrNull()?.boundaries?.drop(1)?.iterator()
    fun nextBreak(): Int = if (rubyBreaks == null) breaks.next()
        else if (rubyBreaks.hasNext()) rubyBreaks.next() else BreakIterator.DONE
    var minimum = 0f
    var maximum = 0f
    var start = 0
    var end = nextBreak()
    while (end != BreakIterator.DONE) {
        if (replacements.none { source.getSpanStart(it) < end && source.getSpanEnd(it) > end }) {
            var visibleEnd = end
            while (visibleEnd > start && source[visibleEnd - 1].isWhitespace()) visibleEnd--
            val wordWidth = Layout.getDesiredWidth(source, start, visibleEnd, paint)
            minimum = maxOf(minimum, wordWidth)
            if (wrapPlan?.ordinaryMinimum(start, visibleEnd, breakWordMinimum) == true)
                authoredMinimum = maxOf(authoredMinimum, wordWidth)
            start = end
        }
        end = nextBreak()
    }
    if (start < source.length) minimum = maxOf(minimum, Layout.getDesiredWidth(source, start, source.length, paint))
    start = 0
    while (start <= source.length) {
        val newline = source.toString().indexOf('\n', start).let { if (it < 0) source.length else it }
        maximum = maxOf(maximum, Layout.getDesiredWidth(source, start, newline, paint))
        if (newline == source.length) break
        start = newline + 1
    }
    if (breakWordMinimum) minimum = maxOf(authoredMinimum, nativeGraphemeMinimum(source, paint, replacements, maximum))
    fun pixels(value: Float): Int {
        val width = value.toDouble() + inset
        return if (!width.isFinite() || width > TablePixelLimit) Constraints.Infinity else ceil(width).toInt()
    }
    return NativeWidthRange(pixels(minimum), pixels(maxOf(minimum, maximum)))
}

/** Shape the complete styled paragraph so emergency opportunities retain contextual glyph
 * advances. This is a width query on the existing source, never a second composed child. */
private fun nativeGraphemeMinimum(source: Spanned, paint: TextPaint, replacements: Array<ReplacementSpan>,
    maximum: Float): Float {
    if (source.isEmpty()) return 0f
    if (!maximum.isFinite()) return Float.POSITIVE_INFINITY
    val wide = ceil(maximum.toDouble()).coerceIn(1.0, TablePixelLimit.toDouble()).toInt()
    val layout = StaticLayout.Builder.obtain(source, 0, source.length, paint, wide)
        .setIncludePad(false).setBreakStrategy(android.graphics.text.LineBreaker.BREAK_STRATEGY_SIMPLE)
        .setHyphenationFrequency(Layout.HYPHENATION_FREQUENCY_NONE).build()
    val breaks = android.icu.text.BreakIterator.getCharacterInstance(paint.textLocale).apply { setText(source.toString()) }
    val path = Path()
    val bounds = RectF()
    var result = 0f
    var start = 0
    var end = breaks.next()
    while (end != android.icu.text.BreakIterator.DONE) {
        if (replacements.none { source.getSpanStart(it) < end && source.getSpanEnd(it) > end }) {
            var visibleEnd = end
            while (visibleEnd > start && source[visibleEnd - 1].isWhitespace() &&
                replacements.none { source.getSpanStart(it) < visibleEnd && source.getSpanEnd(it) >= visibleEnd }) visibleEnd--
            if (visibleEnd > start) {
                path.reset()
                layout.getSelectionPath(start, visibleEnd, path)
                path.computeBounds(bounds, true)
                result = maxOf(result, bounds.width())
            }
            start = end
        }
        end = breaks.next()
    }
    return result
}

/** Figure geometry already has an actual box width before its caption is measured. */
internal fun anonymousWidthRange(content: AnonymousFlowContent, paint: TextPaint,
    inline: (AnonymousFlowEvent.Inline) -> Spanned,
    figureWidth: (AnonymousFlowEvent.FigureObject) -> Float,
    inset: Float, breakWordMinimum: Boolean = false): NativeWidthRange {
    val prepared = content.events.filterIsInstance<AnonymousFlowEvent.Inline>().map { it to inline(it) }
    var next = 0
    val offsets = AnonymousFlowOffsets.build(content) { event ->
        val row = prepared[next++]
        check(row.first === event)
        row.second.toString()
    }
    val text = SpannableString(offsets.nativeText)
    prepared.forEachIndexed { index, (_, source) ->
        val range = offsets.inlineSources[index]
        source.getSpans(0, source.length, Any::class.java).forEach { span ->
            text.setSpan(span, range.start + source.getSpanStart(span), range.start + source.getSpanEnd(span), source.getSpanFlags(span))
        }
    }
    offsets.figures.forEach { anchor ->
        val width = figureWidth(anchor.event)
        require(width.isFinite() && width >= 0f)
        text.setSpan(object : ReplacementSpan() {
            override fun getSize(paint: Paint, text: CharSequence, start: Int, end: Int, fm: Paint.FontMetricsInt?) = ceil(width).toInt()
            override fun draw(canvas: Canvas, text: CharSequence, start: Int, end: Int, x: Float, top: Int, y: Int, bottom: Int, paint: Paint) = Unit
        }, anchor.nativeOffset, anchor.nativeOffset + 1, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
    }
    val measured = SpannableStringBuilder(text)
    offsets.figures.asReversed().forEach { anchor ->
        if (anchor.event.figure.placement !in setOf(FigurePlacement.FloatLeft, FigurePlacement.FloatRight)) {
            // The existing anonymous renderer places a non-float figure on its own block line.
            measured.insert(anchor.nativeOffset + 1, "\n")
            measured.insert(anchor.nativeOffset, "\n")
        }
    }
    return nativeTextWidthRange(measured, paint, inset, breakWordMinimum)
}
