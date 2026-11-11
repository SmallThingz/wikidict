package app.smallthingz.dict

import android.graphics.Canvas
import android.graphics.Paint
import android.text.Layout
import android.text.SpannableString
import android.text.SpannableStringBuilder
import android.text.Spanned
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
internal fun nativeTextWidthRange(source: Spanned, paint: TextPaint, inset: Float = 0f): NativeWidthRange {
    require(inset.isFinite() && inset >= 0f)
    val replacements = source.getSpans(0, source.length, ReplacementSpan::class.java)
    val breaks = BreakIterator.getLineInstance(paint.textLocale).apply { setText(source.toString()) }
    var minimum = 0f
    var maximum = 0f
    var start = 0
    var end = breaks.next()
    while (end != BreakIterator.DONE) {
        if (replacements.none { source.getSpanStart(it) < end && source.getSpanEnd(it) > end }) {
            var visibleEnd = end
            while (visibleEnd > start && source[visibleEnd - 1].isWhitespace()) visibleEnd--
            minimum = maxOf(minimum, Layout.getDesiredWidth(source, start, visibleEnd, paint))
            start = end
        }
        end = breaks.next()
    }
    if (start < source.length) minimum = maxOf(minimum, Layout.getDesiredWidth(source, start, source.length, paint))
    start = 0
    while (start <= source.length) {
        val newline = source.toString().indexOf('\n', start).let { if (it < 0) source.length else it }
        maximum = maxOf(maximum, Layout.getDesiredWidth(source, start, newline, paint))
        if (newline == source.length) break
        start = newline + 1
    }
    fun pixels(value: Float): Int {
        val width = value.toDouble() + inset
        return if (!width.isFinite() || width > TablePixelLimit) Constraints.Infinity else ceil(width).toInt()
    }
    return NativeWidthRange(pixels(minimum), pixels(maxOf(minimum, maximum)))
}

/** Figure geometry already has an actual box width before its caption is measured. */
internal fun anonymousWidthRange(content: AnonymousFlowContent, paint: TextPaint,
    inline: (AnonymousFlowEvent.Inline) -> Spanned,
    figureWidth: (AnonymousFlowEvent.FigureObject) -> Float,
    inset: Float): NativeWidthRange {
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
    return nativeTextWidthRange(measured, paint, inset)
}
