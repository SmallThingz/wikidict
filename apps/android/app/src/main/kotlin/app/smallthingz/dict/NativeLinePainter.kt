package app.smallthingz.dict

import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Path
import android.graphics.RectF
import android.text.Layout
import android.text.PrecomputedText
import android.text.SpannableString
import android.text.Spanned
import android.text.TextPaint
import android.text.style.LeadingMarginSpan
import android.text.style.LineBackgroundSpan
import android.text.style.MetricAffectingSpan
import android.text.style.ReplacementSpan

internal data class NativeLinePaintPlacement(
    val line: Int,
    val baseline: Float,
    val leftIndent: Int = 0,
    val rightIndent: Int = 0,
    val originX: Float = 0f,
)

/** Keeps native background-before-text ordering while placing the original shaped lines. */
internal class NativeLinePainter private constructor(
    private val shaped: Layout,
    private val source: NativeLinePaintSource,
) : Layout(source.text, TextPaint(shaped.paint), shaped.width, shaped.alignment,
    shaped.spacingMultiplier, shaped.spacingAdd) {
    constructor(shaped: Layout) : this(shaped, NativeLinePaintSource(shaped))

    private var selectedLine = 0
    private var selectionEndLine: Int? = null

    /** Public native TextLine dispatch exposes exact decoration rectangles even on API28. */
    fun decorationBounds(positions: List<NativeLinePaintPlacement>): NativeFloatBounds? {
        val observer = NativeDecorationBoundsCanvas()
        NativeLinePainter(shaped, NativeLinePaintSource(shaped, decorationProbe = true)).paint(observer, positions)
        return observer.bounds
    }

    /** The complete native selectable advance, without cross-line selection filler. */
    fun selectableBounds(position: NativeLinePaintPlacement): RectF? {
        val line = position.line
        require(line in 0 until shaped.lineCount && position.baseline.isFinite())
        check(selectionEndLine == null)
        val path = Path()
        selectionEndLine = line
        try {
            // A soft-wrap end offset normally maps to the next line. Keep just this
            // native line's bidi runs, instead of adding a highlight to the viewport edge.
            getSelectionPath(shaped.getLineStart(line), shaped.getLineEnd(line), path)
        } finally { selectionEndLine = null }
        if (path.isEmpty) return null
        return RectF().also {
            path.computeBounds(it, true)
            it.offset(horizontalShift(position), position.baseline - shaped.getLineBaseline(line))
        }.takeUnless { it.isEmpty }
    }

    /** Indents are the exact values supplied to the original StaticLayout builder. */
    fun paint(canvas: Canvas, positions: List<NativeLinePaintPlacement>) {
        require(positions.all { it.line in 0 until shaped.lineCount && it.baseline.isFinite() &&
            it.leftIndent >= 0 && it.rightIndent >= 0 && it.originX.isFinite() })
        require(positions.zipWithNext().all { (left, right) -> left.line < right.line })
        source.paintBackgrounds(canvas, getPaint(), positions)
        for (position in positions) paintTextLine(canvas, position)
    }

    private fun paintTextLine(canvas: Canvas, position: NativeLinePaintPlacement) {
        val (line, baseline) = position
        selectedLine = line
        source.horizontalShift = horizontalShift(position)
        source.fragmentOrigin = position.originX
        val saved = canvas.save()
        try {
            canvas.translate(source.horizontalShift, baseline - shaped.getLineBaseline(line))
            super.draw(canvas)
        } finally {
            canvas.restoreToCount(saved)
        }
    }

    private fun horizontalShift(position: NativeLinePaintPlacement): Float {
        val (line, _, leftIndent, rightIndent) = position
        val ltr = shaped.getParagraphDirection(line) == 1
        return when (shaped.getParagraphAlignment(line)) {
            Layout.Alignment.ALIGN_NORMAL -> if (ltr) leftIndent else -rightIndent
            Layout.Alignment.ALIGN_OPPOSITE -> if (ltr) -rightIndent else leftIndent
            Layout.Alignment.ALIGN_CENTER -> (leftIndent - rightIndent) shr 1
            else -> error("Unsupported native paragraph alignment")
        }.toFloat() + position.originX
    }

    // Native Layout still draws the original bidi runs, tabs, character styles and replacement
    // spans. Only its visible line range and the used baseline are different.
    override fun getLineForVertical(vertical: Int): Int = selectedLine
    override fun getLineForOffset(offset: Int): Int = selectionEndLine?.takeIf {
        offset == shaped.getLineEnd(it)
    } ?: shaped.getLineForOffset(offset)
    override fun getLineCount(): Int = shaped.lineCount
    override fun getLineTop(line: Int): Int = shaped.getLineTop(line)
    override fun getLineDescent(line: Int): Int = shaped.getLineDescent(line)
    override fun getLineStart(line: Int): Int = shaped.getLineStart(line)
    override fun getParagraphDirection(line: Int): Int = shaped.getParagraphDirection(line)
    override fun getLineContainsTab(line: Int): Boolean = shaped.getLineContainsTab(line)
    override fun getLineDirections(line: Int): Layout.Directions = shaped.getLineDirections(line)
    override fun getTopPadding(): Int = shaped.topPadding
    override fun getBottomPadding(): Int = shaped.bottomPadding
    override fun getEllipsisStart(line: Int): Int = shaped.getEllipsisStart(line)
    override fun getEllipsisCount(line: Int): Int = shaped.getEllipsisCount(line)
}

/** Paragraph decorations precede StaticLayout's text indent and must keep their original origin. */
private class NativeLinePaintSource(private val shaped: Layout, private val decorationProbe: Boolean = false) {
    var horizontalShift = 0f
    var fragmentOrigin = 0f
    private data class Background(val span: LineBackgroundSpan, val start: Int, val end: Int)
    private val backgrounds = if (decorationProbe) emptyList() else (shaped.text as? Spanned)?.let { original ->
        original.getSpans(0, original.length, LineBackgroundSpan::class.java).mapNotNull { span ->
            val start = original.getSpanStart(span)
            val end = original.getSpanEnd(span)
            if (start < end) Background(span, start, end) else null
        }
    }.orEmpty()
    val text: CharSequence = (shaped.text as? Spanned)?.let { original ->
        // Preserve priority and relative insertion order, including overlapping metric spans.
        // Removing/reinserting just one metric span would move it after equal-priority peers.
        SpannableString(original.toString()).apply {
            for (span in original.getSpans(0, original.length, Any::class.java)) {
                val wrapped = when {
                    span is LineBackgroundSpan -> null
                    span is LeadingMarginSpan.LeadingMarginSpan2 -> Margin2(span)
                    span is LeadingMarginSpan -> Margin(span)
                    decorationProbe && span is ReplacementSpan -> replacementProbe(original, span)
                    decorationProbe && span is NativeMayUnderline && span.mayUnderline -> underlineProbe(span)
                    else -> span
                }
                if (wrapped != null) setSpan(wrapped, original.getSpanStart(span),
                    original.getSpanEnd(span), original.getSpanFlags(span))
            }
        }
    } ?: if (decorationProbe) SpannableString(shaped.text) else shaped.text

    private fun replacementProbe(original: Spanned, span: ReplacementSpan): ReplacementSpan {
        // The existing PrecomputedText has already measured this exact owner. Do not invoke
        // either its getSize or draw while observing native decorations.
        val measured = shaped.text as? PrecomputedText
            ?: throw UnsupportedFloatLayout("Replacement decoration measurement needs retained native advances")
        val advance = measured.getWidth(original.getSpanStart(span), original.getSpanEnd(span))
        if (!advance.isFinite() || advance < 0f || advance > Int.MAX_VALUE / 4f || advance != advance.toInt().toFloat())
            throw UnsupportedFloatLayout("Replacement advance is not its retained native size")
        return object : ReplacementSpan() {
            override fun getSize(paint: Paint, text: CharSequence, start: Int, end: Int,
                fm: Paint.FontMetricsInt?): Int = advance.toInt()
            override fun draw(canvas: Canvas, text: CharSequence, start: Int, end: Int,
                x: Float, top: Int, y: Int, bottom: Int, paint: Paint) = Unit
        }
    }

    private fun underlineProbe(span: NativeMayUnderline): MetricAffectingSpan {
        if (span !is MetricAffectingSpan)
            throw UnsupportedFloatLayout("Dynamic native underline must retain its metric owner")
        return object : MetricAffectingSpan() {
            override fun updateMeasureState(paint: TextPaint) = span.updateMeasureState(paint)
            override fun updateDrawState(paint: TextPaint) {
                span.updateDrawState(paint); paint.isUnderlineText = true
            }
        }
    }

    // Layout's background/text split is hidden on API28. Invoke the public span contract in
    // its original order, then let Layout paint all text and margin decorations normally.
    fun paintBackgrounds(canvas: Canvas, paint: TextPaint, positions: List<NativeLinePaintPlacement>) {
        if (backgrounds.isEmpty()) return
        for (position in positions) {
            val line = position.line
            val start = shaped.getLineStart(line)
            val end = shaped.getLineStart(line + 1)
            if (start == end && start != 0) continue
            val saved = canvas.save()
            try {
                canvas.translate(position.originX, position.baseline - shaped.getLineBaseline(line))
                for (background in backgrounds) {
                    if (background.start >= end || background.end <= start) continue
                    background.span.drawBackground(canvas, paint, 0, shaped.width,
                        shaped.getLineTop(line), shaped.getLineBaseline(line),
                        shaped.getLineTop(line + 1), shaped.text, start, end, line)
                }
            } finally {
                canvas.restoreToCount(saved)
            }
        }
    }

    private inline fun atDecorationOrigin(canvas: Canvas, draw: () -> Unit) {
        val saved = canvas.save()
        try {
            canvas.translate(fragmentOrigin - horizontalShift, 0f)
            draw()
        } finally {
            canvas.restoreToCount(saved)
        }
    }

    private open inner class Margin(private val original: LeadingMarginSpan) : LeadingMarginSpan {
        override fun getLeadingMargin(first: Boolean): Int = original.getLeadingMargin(first)
        override fun drawLeadingMargin(c: Canvas, p: Paint, x: Int, dir: Int, top: Int,
            baseline: Int, bottom: Int, text: CharSequence, start: Int, end: Int,
            first: Boolean, layout: Layout) {
            if (!decorationProbe) atDecorationOrigin(c) {
                original.drawLeadingMargin(c, p, x, dir, top, baseline, bottom, shaped.text,
                    start, end, first, shaped)
            }
        }
    }

    private inner class Margin2(private val original: LeadingMarginSpan.LeadingMarginSpan2) :
        Margin(original), LeadingMarginSpan.LeadingMarginSpan2 {
        override fun getLeadingMarginLineCount(): Int = original.leadingMarginLineCount
    }

}
