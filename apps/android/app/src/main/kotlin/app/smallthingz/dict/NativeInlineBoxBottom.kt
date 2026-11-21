package app.smallthingz.dict

import android.text.TextPaint

/** Bottom participants constrain height without contributing to the baseline envelope. */
internal fun nativeInlineBottomLineMetrics(baseline: NativeUsedLineMetrics,
    aligned: List<NativeUsedLineMetrics>): NativeUsedLineMetrics = NativeUsedLineMetrics(
    baseline.top, maxOf(baseline.bottom, baseline.top + (aligned.maxOfOrNull { it.height } ?: 0f)))

internal data class NativeInlineBottomFragment(val start: Int, val end: Int,
    val metrics: NativeUsedLineMetrics, val shift: Float)

internal data class NativeInlineBottomLine(val metrics: NativeUsedLineMetrics,
    val fragments: List<NativeInlineBottomFragment>) {
    fun at(offset: Int, upstream: Boolean = false): NativeInlineBottomFragment? = fragments.firstOrNull {
        if (upstream) offset > it.start && offset <= it.end else offset >= it.start && offset < it.end
    }
}

/** The native dispatcher also emits paint-only rectangles. Accept one translation
 * only when its complete physical interval belongs to equal-placement pieces. */
internal class NativeInlineBottomReplay(private val line: NativeInlineBottomLine,
    private val pieces: List<NativeInlineRunPiece>) {
    fun source(start: Int, end: Int): Float {
        val owners = line.fragments.filter { it.start < end && it.end > start }
        if (owners.isEmpty()) return 0f
        val owner = owners.singleOrNull()
        if (owner == null || start < owner.start || end > owner.end)
            throw UnsupportedFloatLayout("Bottom replay crosses original owner placement")
        return owner.shift
    }
    fun physical(left: Float, right: Float): Float {
        val selected = pieces.filter { if (left == right) left >= it.left && left < it.right
            else left < it.right && right > it.left }
        val shifts = selected.map { source(it.start, it.end) }.distinct()
        if (shifts.size > 1)
            throw UnsupportedFloatLayout("Bottom paint primitive crosses unequal vertical placements")
        return shifts.firstOrNull() ?: 0f
    }
}

/** Uses the already selected native lines and their actual fallback-font draw runs.
 * It does not shape another paragraph or alter any horizontal fitting decision. */
internal fun nativeInlineBottomLines(raw: NativeFloatGeometry,
    boxes: List<NativeInlineRange<NativeInlineBoxSpan>>, paint: TextPaint,
    firstPadding: Float = 0f, lastPadding: Float = 0f): List<NativeInlineBottomLine>? {
    val bottom = boxes.filter { it.value.box.verticalAlign == InlineBoxGroupVerticalAlign.Bottom }
    if (bottom.isEmpty()) return null
    val source = raw.nativeRubyShapingSource
    if (boxes.sortedBy { it.start }.zipWithNext().any { (a, b) -> a.end > b.start } ||
        source.getSpans(0, source.length, NativeLineMinimum::class.java).isNotEmpty() ||
        source.getSpans(0, source.length, NativeLineGap::class.java).isNotEmpty() ||
        source.getSpans(0, source.length, NativeAuthoredInlineMetrics::class.java).isNotEmpty() ||
        source.getSpans(0, source.length, NativeRunLineMetrics::class.java).any {
            it.policy != NativeLineHeightPolicy.Normal
        }) throw UnsupportedFloatLayout("Bottom inline owners require independent ordinary normal-height text")
    for (owner in bottom) {
        val value = owner.value
        if (value.shift != 0f || value.format.lineHeight != NativeLineHeightPolicy.Normal ||
            value.format.paint.baselineShift != 0)
            throw UnsupportedFloatLayout("Bottom inline owner requires an unshifted normal-height font")
    }
    val root = NativePrimaryFontMetrics.from(paint)
    fun primary(value: NativePrimaryFontMetrics) = NativeUsedLineMetrics(
        value.ascent + value.baselineShift, value.descent + value.baselineShift)
    val required = nativeInlineBoxRequiredBreaks(source) { at -> raw.nativeRubyLineDirection(raw.nativeLineAt(at)) < 0 }
    return (0 until raw.shapedLineCount).map { line ->
        val (start, end) = raw.nativeRangeOfLine(line)
        val active = bottom.filter { it.start < end && it.end > start }
        if (active.isEmpty()) {
            val metrics = raw.nativeUsedLineMetrics(line)
            return@map NativeInlineBottomLine(NativeUsedLineMetrics(
                metrics.top + if (line == 0) firstPadding else 0f,
                metrics.bottom - if (line == raw.shapedLineCount - 1) lastPadding else 0f), emptyList())
        }
        val cuts = active.flatMap { listOf(maxOf(start, it.start), minOf(end, it.end)) }.distinct()
        val capture = nativeInlineLineCapture(raw, line, cuts, required)
        var baseline = primary(root)
        val own = active.associateWith { primary(NativePrimaryFontMetrics.from(it.value.format.paint)) }.toMutableMap()
        for (run in capture.measuredRuns()) {
            val owners = active.filter { it.start < run.end && it.end > run.start }
            if (owners.isEmpty()) baseline = baseline.including(run.metrics)
            else {
                val owner = owners.singleOrNull()
                    ?: throw UnsupportedFloatLayout("Bottom run overlaps original inline owners")
                if (run.start < owner.start || run.end > owner.end)
                    throw UnsupportedFloatLayout("Bottom owner lacks its native metric boundary")
                own[owner] = own.getValue(owner).including(run.metrics)
            }
        }
        for (run in nativeInlineRanges(source, NativeRunLineMetrics::class.java)) {
            if (run.start >= end || run.end <= start) continue
            val included = primary(run.value.primary)
            if (run.value.strut) baseline = baseline.including(included)
            else {
                val first = maxOf(start, run.start)
                val last = minOf(end, run.end)
                val owner = active.singleOrNull { first >= it.start && last <= it.end }
                if (owner != null) own[owner] = own.getValue(owner).including(included)
                else baseline = baseline.including(included)
            }
        }
        val metrics = nativeInlineBottomLineMetrics(baseline, own.values.toList())
        NativeInlineBottomLine(metrics, active.map { owner ->
            val child = own.getValue(owner)
            NativeInlineBottomFragment(maxOf(start, owner.start), minOf(end, owner.end), child,
                nativeInlineBoxCoordinate(metrics.bottom.toDouble() - child.bottom))
        })
    }
}
