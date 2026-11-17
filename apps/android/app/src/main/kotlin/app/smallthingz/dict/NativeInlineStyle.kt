package app.smallthingz.dict

import android.graphics.Canvas
import android.graphics.DashPathEffect
import android.graphics.Paint
import android.graphics.Rect
import android.graphics.RectF
import android.text.Spannable
import android.text.Spanned
import android.text.TextPaint
import android.text.style.CharacterStyle
import android.text.style.ReplacementSpan

/** The reader's complete paint snapshots do not install hidden custom underline fields. */
internal interface NativeInlineSafePaintSpan

/** A declaring snapshot is resolved independently from the covered run before installation. */
internal data class NativeAuthoredInlineMetrics(
    val primary: NativePrimaryFontMetrics,
    val policy: NativeLineHeightPolicy,
    val declaringPrimary: NativePrimaryFontMetrics? = null,
    val clippedVisiblePoint: NativeClippedVisibleMetricPoint? = null,
)

/** Physical downward displacement; the source's positive raise is negated by lowering. */
internal data class NativeAuthoredBaselineShift(val shift: Float,
    val clippedVisiblePoint: NativeClippedVisibleMetricPoint? = null) {
    init {
        require(shift.isFinite() && kotlin.math.abs(shift) <= TablePixelLimit)
    }
    val nativeShift: Int get() = shift.toInt()
    val remainder: Float get() = shift - nativeShift
}

/** An additional source underline never changes the anchor's native state underline. */
internal data class NativeAuthoredUnderline(val style: InlineUnderlineStyle, val color: Int?, val thickness: Float?) {
    init {
        require(thickness == null || thickness.isFinite() && thickness >= 0f && thickness <= TablePixelLimit)
    }
}

internal data class NativeAuthoredCursor(val cursor: InlineCursor)

/** Reusing a styled fragment must not merge distinct source occurrences at one offset. */
internal fun nativeInlineStyleSpanCopy(span: Any): Any = when (span) {
    is NativeAuthoredInlineMetrics -> span.copy()
    is NativeAuthoredBaselineShift -> span.copy()
    is NativeAuthoredUnderline -> span.copy()
    is NativeAuthoredCursor -> span.copy()
    is NativeCitationMarkerSpan -> span.copy()
    is NativeAuthoredTextWrap -> span.copy()
    is NativeClippedVisibleMetricMarker -> NativeClippedVisibleMetricMarker(span.key)
    is NativeRubyPreparedSource -> NativeRubyPreparedSource(span.projection, span.source, span.paint,
        span.direction, span.groups, span.parentScript, span.visualOmissions, span.visualSpaces,
        span.visualSpaceNeighbors, span.protectedSpaces)
    else -> span
}

internal fun hasNativeAuthoredInlineMetrics(source: CharSequence): Boolean = source is Spanned &&
    source.getSpans(0, source.length, NativeAuthoredInlineMetrics::class.java).isNotEmpty()

/** Empty semantic owners can still supply a real line/box. This is admission only;
 * their native metric owners continue to determine the actual used geometry. */
internal fun hasNativeInlineLayoutOwner(source: CharSequence): Boolean = source is Spanned &&
    (hasNativeAuthoredInlineMetrics(source) ||
        source.getSpans(0, source.length, NativeRubyPreparedSource::class.java).isNotEmpty())

/** Native layout callers supply getLineForOffset affinity, including soft wraps and trailing LF. */
internal fun nativeInlinePointInRange(source: CharSequence, offset: Int, start: Int, end: Int): Boolean =
    if (start == end) offset == start
    else offset >= start && offset < end || offset == end && end == source.length &&
        (source.isEmpty() || source.last() != '\n')

internal data class NativeInlineRange<T>(val start: Int, val end: Int, val value: T)

internal fun <T> nativeInlineRanges(source: Spanned, type: Class<T>): List<NativeInlineRange<T>> =
    source.getSpans(0, source.length, type).map { NativeInlineRange(source.getSpanStart(it), source.getSpanEnd(it), it) }

/** Unsupported ownership fails before shaping, so existing callers retain source text/actions. */
internal fun validateNativeInlineStyle(source: Spanned, basePaint: TextPaint) {
    val metrics = nativeInlineRanges(source, NativeAuthoredInlineMetrics::class.java)
    val shifts = nativeInlineRanges(source, NativeAuthoredBaselineShift::class.java)
    val underlines = nativeInlineRanges(source, NativeAuthoredUnderline::class.java)
    fun checkRange(first: Int, last: Int) {
        if (first < 0 || last < first || last > source.length)
            throw UnsupportedFloatLayout("Authored inline range is outside its source")
    }
    (metrics + shifts + underlines).forEach { checkRange(it.start, it.end) }
    fun <T> noOverlap(ranges: List<NativeInlineRange<T>>, name: String) {
        val visible = ranges.filter { it.start < it.end }.sortedBy { it.start }
        if (visible.zipWithNext().any { (a, b) -> a.end > b.start })
            throw UnsupportedFloatLayout("Overlapping authored $name owners are unavailable")
    }
    noOverlap(shifts, "baseline")
    noOverlap(underlines, "underline")
    if (underlines.any { it.start < it.end } || shifts.any { it.start < it.end && it.value.remainder != 0f }) {
        if (source.getSpans(0, source.length, CharacterStyle::class.java).any {
            it !is NativeInlineSafePaintSpan && it !is ReplacementSpan
        }) throw UnsupportedFloatLayout("Authored inline paint requires complete reader-owned paint spans")
    }
    for (range in shifts) {
        val owners = metrics.filter { it.start <= range.start && it.end >= range.end }
        if (owners.none { it.value.primary.baselineShift == range.value.shift })
            throw UnsupportedFloatLayout("Authored baseline requires its exact run metrics")
        if (range.value.remainder != 0f && metrics.any { metric ->
            metric.start <= range.start && metric.end >= range.end && metric.value.policy == NativeLineHeightPolicy.Normal
        }) throw UnsupportedFloatLayout("Fractional authored baseline with native normal line height is unavailable")
        if (range.value.shift != 0f) {
            var first = range.start
            while (first < range.end) {
                val last = source.nextSpanTransition(first, range.end, CharacterStyle::class.java)
                val paint = TextPaint(basePaint)
                source.getSpans(first, last, CharacterStyle::class.java).forEach { it.updateDrawState(paint) }
                // TextLine moves glyphs and strokes but leaves its character background
                // on the original baseline. Do not publish that partial source displacement.
                if (paint.bgColor != 0)
                    throw UnsupportedFloatLayout("Authored baseline with a character background is unavailable")
                first = last
            }
        }
    }
    (shifts + underlines).filter { it.start < it.end }.forEach { range ->
        if (source.getSpans(range.start, range.end, ReplacementSpan::class.java).any {
            source.getSpanStart(it) < range.end && source.getSpanEnd(it) > range.start
        }) throw UnsupportedFloatLayout("Authored baseline or underline on replacement-backed text is unavailable")
    }
}

internal sealed interface NativeInlinePaintPass {
    data class Base(val shifted: List<NativeInlineRange<NativeAuthoredBaselineShift>>) : NativeInlinePaintPass
    data class Shifted(val range: NativeInlineRange<NativeAuthoredBaselineShift>) : NativeInlinePaintPass
    data class Underline(val range: NativeInlineRange<NativeAuthoredUnderline>) : NativeInlinePaintPass
}

/** Draw-only masks leave TextLine's original metric context, bidi, tabs and advances intact. */
internal fun installNativeInlineMask(text: Spannable, pass: NativeInlinePaintPass) {
    val ranges = when (pass) {
        is NativeInlinePaintPass.Base -> pass.shifted.map { it.start to it.end }
        is NativeInlinePaintPass.Shifted -> listOf(pass.range.start to pass.range.end)
        is NativeInlinePaintPass.Underline -> listOf(pass.range.start to pass.range.end)
    }
    val cuts = (listOf(0, text.length) + ranges.flatMap { listOf(it.first, it.second) }).distinct().sorted()
    for ((start, end) in cuts.zipWithNext()) {
        if (start == end) continue
        val selected = ranges.any { it.first <= start && it.second >= end }
        if (pass is NativeInlinePaintPass.Base && !selected) continue
        val mask = object : CharacterStyle() {
            override fun updateDrawState(paint: TextPaint) {
                val hidden = if (pass is NativeInlinePaintPass.Base) selected else !selected
                if (pass !is NativeInlinePaintPass.Base) paint.bgColor = 0
                if (hidden) {
                    // The admitted paint owners never install hidden custom underline colors.
                    paint.isUnderlineText = false
                    paint.isStrikeThruText = false
                    paint.alpha = 0
                } else if (pass is NativeInlinePaintPass.Underline) {
                    paint.isStrikeThruText = false
                    paint.isUnderlineText = paint.textSize > 0f
                    pass.range.value.color?.let { paint.color = it }
                }
            }
        }
        text.setSpan(mask, start, end, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        if (text.getSpans(start, end, CharacterStyle::class.java).lastOrNull() !== mask)
            throw UnsupportedFloatLayout("Authored inline draw mask is not the final paint owner")
    }
}

internal data class NativeInlineDecorationFragment(val bounds: NativeFloatBounds, val color: Int,
    val style: InlineUnderlineStyle) {
    fun paint(canvas: Canvas) {
        val thickness = bounds.bottom - bounds.top
        if (thickness <= 0f || bounds.right <= bounds.left || color ushr 24 == 0) return
        val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply { this.color = this@NativeInlineDecorationFragment.color }
        if (style == InlineUnderlineStyle.Solid) {
            canvas.drawRect(bounds.left, bounds.top, bounds.right, bounds.bottom, paint)
        } else {
            val period = thickness * 2f
            if (!period.isFinite() || period <= 0f)
                throw UnsupportedFloatLayout("Authored dotted underline exceeds native geometry")
            paint.style = Paint.Style.STROKE
            paint.strokeWidth = thickness
            paint.strokeCap = Paint.Cap.ROUND
            paint.pathEffect = DashPathEffect(floatArrayOf(0f, period), 0f)
            val saved = canvas.save()
            try {
                canvas.clipRect(bounds.left, bounds.top, bounds.right, bounds.bottom)
                val y = bounds.top + thickness / 2f
                canvas.drawLine(bounds.left, y, bounds.right, y, paint)
            } finally { canvas.restoreToCount(saved) }
        }
    }
}

/** Public TextLine dispatch supplies exact visual fragments and platform auto underline metrics. */
internal class NativeInlineUnderlineCanvas(private val owner: NativeAuthoredUnderline) : Canvas() {
    private data class Translation(val x: Float, val y: Float)
    private val saved = mutableListOf(Translation(0f, 0f))
    val fragments = mutableListOf<NativeInlineDecorationFragment>()
    override fun save(): Int = saved.size.also { saved += saved.last() }
    override fun getSaveCount() = saved.size
    override fun restore() { check(saved.size > 1); saved.removeAt(saved.lastIndex) }
    override fun restoreToCount(saveCount: Int) {
        check(saveCount in 1..saved.size)
        while (saved.size > saveCount) restore()
    }
    override fun translate(dx: Float, dy: Float) {
        val previous = saved.last()
        saved[saved.lastIndex] = Translation(previous.x + dx, previous.y + dy)
    }
    override fun getClipBounds(bounds: Rect): Boolean {
        bounds.set(-TablePixelLimit, -TablePixelLimit, TablePixelLimit, TablePixelLimit)
        return true
    }
    override fun drawRect(left: Float, top: Float, right: Float, bottom: Float, paint: Paint) {
        val thickness = owner.thickness ?: (bottom - top)
        if (paint.alpha == 0 || paint.textSize == 0f || right <= left || thickness == 0f) return
        if (paint.style != Paint.Style.FILL || thickness < 0f)
            throw UnsupportedFloatLayout("Authored underline probe received an unowned decoration")
        val translated = saved.last()
        val values = listOf(left.toDouble() + translated.x, top.toDouble() + translated.y,
            right.toDouble() + translated.x, top.toDouble() + translated.y + thickness)
        if (values.any { !it.isFinite() || kotlin.math.abs(it) > TablePixelLimit })
            throw UnsupportedFloatLayout("Authored underline exceeds native geometry")
        fragments += NativeInlineDecorationFragment(NativeFloatBounds(values[0].toFloat(), values[1].toFloat(),
            values[2].toFloat(), values[3].toFloat()), owner.color ?: paint.color, owner.style)
    }
    override fun drawRect(rect: RectF, paint: Paint) = drawRect(rect.left, rect.top, rect.right, rect.bottom, paint)
    override fun drawRect(rect: Rect, paint: Paint) = drawRect(rect.left.toFloat(), rect.top.toFloat(), rect.right.toFloat(), rect.bottom.toFloat(), paint)
    override fun drawTextRun(text: CharArray, index: Int, count: Int, contextIndex: Int, contextCount: Int,
        x: Float, y: Float, isRtl: Boolean, paint: Paint) = Unit
    override fun drawTextRun(text: CharSequence, start: Int, end: Int, contextStart: Int, contextEnd: Int,
        x: Float, y: Float, isRtl: Boolean, paint: Paint) = Unit
    private fun unexpectedText(): Nothing = throw UnsupportedFloatLayout("Authored underline needs native run dispatch")
    override fun drawText(text: CharArray, index: Int, count: Int, x: Float, y: Float, paint: Paint) = unexpectedText()
    override fun drawText(text: String, x: Float, y: Float, paint: Paint) = unexpectedText()
    override fun drawText(text: String, start: Int, end: Int, x: Float, y: Float, paint: Paint) = unexpectedText()
    override fun drawText(text: CharSequence, start: Int, end: Int, x: Float, y: Float, paint: Paint) = unexpectedText()
}
