package app.smallthingz.dict

import android.graphics.Canvas
import android.graphics.Paint
import android.text.Layout
import android.text.PrecomputedText
import android.text.SpannableString
import android.text.Spanned
import android.text.StaticLayout
import android.text.TextDirectionHeuristics
import android.text.TextPaint
import android.text.style.MetricAffectingSpan
import kotlin.math.ceil

/**
 * Generated list markers and the explicit failure marker use the same native text/decorations
 * path as paragraphs. Their existing anchor and baseline stay independent of the flow box.
 */
internal class NativeMarkerText(text: String, originalPaint: TextPaint,
    appearance: NativeMissingLinkPaint? = null) {
    private val paint = TextPaint(originalPaint).apply {
        // These markers supply their actual baseline explicitly; Canvas.drawText previously
        // ignored TextPaint's paragraph-only fields too.
        baselineShift = 0; bgColor = 0; textAlign = Paint.Align.LEFT
    }
    private val layout: StaticLayout
    private val placement = listOf(NativeLinePaintPlacement(0, 0f))
    private val painter: NativeLinePainter
    val advance: Float
    private val shift: Float
    val ink: NativeFloatBounds?

    init {
        val measured = paint.measureText(text)
        if (!measured.isFinite() || measured < 0f || measured > Int.MAX_VALUE / 4f)
            throw UnsupportedFloatLayout("Native marker exceeds the coordinate range")
        val source = SpannableString(text)
        if (appearance != null && text.isNotEmpty()) source.setSpan(object : MetricAffectingSpan(), NativeMayUnderline {
            override val mayUnderline = true
            override fun updateMeasureState(paint: TextPaint) = Unit
            override fun updateDrawState(paint: TextPaint) {
                val current = appearance.appearance()
                paint.color = current.color; paint.isUnderlineText = current.underline
            }
        }, 0, text.length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        val direction = TextDirectionHeuristics.FIRSTSTRONG_LTR
        val params = PrecomputedText.Params.Builder(paint).setTextDirection(direction)
            .setBreakStrategy(android.graphics.text.LineBreaker.BREAK_STRATEGY_SIMPLE)
            .setHyphenationFrequency(Layout.HYPHENATION_FREQUENCY_NONE).build()
        val retained = PrecomputedText.create(source, params)
        layout = StaticLayout.Builder.obtain(retained, 0, retained.length, paint, ceil(measured.toDouble()).toInt())
            .setTextDirection(direction).setAlignment(Layout.Alignment.ALIGN_NORMAL)
            .setBreakStrategy(android.graphics.text.LineBreaker.BREAK_STRATEGY_SIMPLE)
            .setHyphenationFrequency(Layout.HYPHENATION_FREQUENCY_NONE).build()
        if (layout.lineCount != 1)
            throw UnsupportedFloatLayout("Generated native marker must remain one unbroken line")
        advance = layout.getLineWidth(0)
        if (!advance.isFinite() || advance < 0f || advance > Int.MAX_VALUE / 4f)
            throw UnsupportedFloatLayout("Native marker advance exceeds the coordinate range")
        // ALIGN_NORMAL starts an RTL TextLine at the integer layout width. Normalize its full
        // advance to a left anchor without rounding that advance or trimming trailing space.
        shift = if (layout.getParagraphDirection(0) == -1) advance - layout.width else 0f
        painter = NativeLinePainter(layout)
        ink = nativeTextInkBounds(layout, placement)?.translated(shift, 0f)
    }

    fun bounds(x: Float, baseline: Float, rightAligned: Boolean = false): NativeFloatBounds? =
        ink?.translated(x - if (rightAligned) advance else 0f, baseline)

    fun paint(canvas: Canvas, x: Float, baseline: Float, rightAligned: Boolean = false) {
        val saved = canvas.save()
        try {
            canvas.translate(x - (if (rightAligned) advance else 0f) + shift, baseline)
            painter.paint(canvas, placement)
        } finally { canvas.restoreToCount(saved) }
    }
}
