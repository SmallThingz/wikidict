package app.smallthingz.dict

import android.graphics.text.LineBreaker
import android.text.Layout
import android.text.Spanned
import android.text.TextDirectionHeuristic
import android.text.TextPaint
import android.text.style.AlignmentSpan
import android.text.style.ReplacementSpan
import java.text.BreakIterator
import kotlin.math.abs
import kotlin.math.ceil
import kotlin.math.floor
import kotlin.math.max

private fun validateNativeFloatRowStructure(source: Spanned) {
    if (source.getSpans(0, source.length, NativeRubyPreparedSource::class.java).isNotEmpty() ||
        source.getSpans(0, source.length, NativeInlineBoxSpan::class.java).isNotEmpty())
        throw UnsupportedFloatLayout("Positioned inline images inside structural inline groups are unavailable")
    if (source.any { it == '\t' || it == '\r' || it == '\u000b' || it == '\u000c' ||
            it == '\u0085' || it == '\u2028' || it == '\u2029' })
        throw UnsupportedFloatLayout("Float image rows require explicit LF paragraph boundaries")
}

internal data class NativeFloatPlannedRow(
    val paragraph: NativeFloatRunParagraph,
    val alignment: Layout.Alignment,
    val start: Int,
    val end: Int,
    val visibleEnd: Int,
    val glyphs: List<NativeFloatGlyphRun>,
    val advance: Float,
    val visibleAdvance: Float,
    val nativeFitAdvance: Float,
    val natural: NativeUsedLineMetrics,
    val paddedNatural: NativeUsedLineMetrics,
    val requiredFlowWidth: Float? = null,
)

/** A selected LineBreaker result plus the unchanged float/clear placement algorithm.
 * Nothing here substitutes text with replacement runs or chooses a second set of line breaks. */
internal class NativeFloatRowPlan private constructor(
    val source: Spanned,
    val paint: TextPaint,
    val width: Int,
    val runs: NativeFloatRowRuns,
    val rows: List<NativeFloatPlannedRow>,
    val flow: NativeFloatFlow,
    val nativeLineMetrics: List<NativeUsedLineMetrics>,
    val alignment: Layout.Alignment,
    val availableWidth: Float = width.toFloat(),
    val paragraphLeft: Float = 0f,
    val paragraphRight: Float = availableWidth,
    val rebuild: (Spanned) -> NativeFloatRowPlan,
) {
    fun lineAt(offset: Int): Int {
        require(offset in 0..source.length)
        val found = rows.binarySearchBy(offset) { it.start }
        return (if (found >= 0) found else -found - 2).coerceIn(0, rows.lastIndex)
    }
    fun measuredAdvance(start: Int, end: Int): Float {
        require(start in 0..source.length && end in start..source.length)
        if (start == end) return 0f
        val paragraph = runs.paragraphs.firstOrNull { start >= it.start && end <= it.end }
            ?: throw UnsupportedFloatLayout("Float image measurement crosses a source paragraph")
        val last = minOf(end, paragraph.measuredEnd)
        return if (start >= last) 0f else checkNotNull(paragraph.measured).getWidth(start - paragraph.start, last - paragraph.start)
    }
    fun emergencyEnds(): Set<Int> = nativeFloatRowEmergencyEnds(runs)

    companion object {
        fun build(source: Spanned, paint: TextPaint, width: Int,
            occurrences: List<NativeFloatOccurrence>, alignment: Layout.Alignment,
            direction: TextDirectionHeuristic, lineSpacingExtra: Float, lineSpacingMultiplier: Float,
            requireDrainedAtBoundary: Boolean, carriedExclusions: List<NativeFloatExclusion>,
            insets: NativeTextInsets, usedLineMetrics: ((Int, Int) -> NativeUsedLineMetrics)?,
            includeFontPadding: Boolean, exactAvailableWidth: Float? = null,
            exactParagraphInsets: Boolean = false): NativeFloatRowPlan {
            require(width >= 0 && width <= Int.MAX_VALUE / 4)
            val availableWidth = exactAvailableWidth ?: width.toFloat()
            if (exactParagraphInsets && (exactAvailableWidth == null || occurrences.isNotEmpty() || carriedExclusions.isNotEmpty()))
                throw UnsupportedFloatLayout("Exact paragraph gutters require an exact width without floats")
            if (exactAvailableWidth != null && (!availableWidth.isFinite() || availableWidth < 0f ||
                    availableWidth > TablePixelLimit || floor(availableWidth).toInt() != width ||
                    occurrences.isNotEmpty() || !exactParagraphInsets && insets != NativeTextInsets()))
                throw UnsupportedFloatLayout("Exact Float text width requires a zero-inset paragraph without source floats")
            // Constant list gutters belong to the original paragraph, outside its native
            // fitting lane. Keep them in Float coordinates for both fitting and replay.
            fun gutter(first: Float, extra: Float): Float {
                val value = first.toDouble() + extra
                if (!value.isFinite() || value > TablePixelLimit)
                    throw UnsupportedFloatLayout("Exact paragraph gutter exceeds native geometry")
                return value.toFloat()
            }
            val paragraphLeft = if (exactParagraphInsets) gutter(insets.left, insets.extraLeft) else 0f
            val paragraphRightInset = if (exactParagraphInsets) gutter(insets.right, insets.extraRight) else 0f
            val fittingWidth = if (exactParagraphInsets)
                maxOf(0.0, availableWidth.toDouble() - paragraphLeft - paragraphRightInset).toFloat() else availableWidth
            val paragraphRight = if (exactParagraphInsets) paragraphLeft + fittingWidth else availableWidth
            val flowInsets = if (exactParagraphInsets) NativeTextInsets() else insets
            require(lineSpacingExtra.isFinite() && lineSpacingExtra >= 0f)
            require(lineSpacingMultiplier.isFinite() && lineSpacingMultiplier > 0f)
            require(occurrences.map { it.sourceId }.distinct().size == occurrences.size)
            require(occurrences.map { it.offset }.distinct().size == occurrences.size)
            validateNativeFloatRowStructure(source)
            if (occurrences.isNotEmpty())
                throw UnsupportedFloatLayout("Positioned inline images with source float anchors are unavailable")
            validateNativeInlineStyle(source, paint)
            val wrap = NativeTextWrapPlan.create(source, paint)
            wrap?.noWrap?.requireLinePresence()
            if (wrap?.noWrap != null && carriedExclusions.isNotEmpty() && exactAvailableWidth == null)
                throw UnsupportedFloatLayout("No-wrap source cannot inherit float exclusions")
            val runs = NativeFloatRowRuns(source, paint, direction)
            val clippedProbe = source.getSpans(0, source.length, NativeClippedProbeAllocation::class.java).singleOrNull()
            var left = intArrayOf(0)
            var right = intArrayOf(0)
            val seen = mutableSetOf<List<Int>>()
            repeat(64) {
                if (!seen.add(left.toList() + listOf(-1) + right.toList()))
                    throw UnsupportedFloatLayout("Float image row exclusions cycle")
                val rows = nativeFloatRows(source, paint, runs, fittingWidth, left, right, wrap, alignment)
                val natural = rows.mapIndexed { index, row ->
                    var metric = row.natural
                    if (includeFontPadding) metric = NativeUsedLineMetrics(
                        if (index == 0) minOf(metric.top, row.paddedNatural.top) else metric.top,
                        if (index == rows.lastIndex) maxOf(metric.bottom, row.paddedNatural.bottom) else metric.bottom)
                    if (index != rows.lastIndex) {
                        val extra = floor((metric.height.toDouble() * (lineSpacingMultiplier - 1.0) +
                            lineSpacingExtra) + 0.5).toFloat()
                        metric = NativeUsedLineMetrics(metric.top, maxOf(metric.top, metric.bottom + extra))
                    }
                    source.getSpans(row.start, row.end, NativeLineMinimum::class.java).filter {
                        source.getSpanStart(it) < row.end && source.getSpanEnd(it) > row.start
                    }.forEach { metric = metric.including(it.primary.authored(NativeLineHeightPolicy.Pixels(it.pixels))!!) }
                    source.getSpans(row.start, row.end, NativeLineGap::class.java).filter {
                        source.getSpanStart(it) < row.end && source.getSpanEnd(it) > row.start && source.getSpanEnd(it) <= row.end
                    }.forEach { metric = NativeUsedLineMetrics(metric.top, metric.bottom + it.pixels) }
                    metric
                }
                val flow = nativePositionFloatRows(source, width, rows.map { it.start }.toIntArray(),
                    rows.map { it.end }.toIntArray(), natural, occurrences, carriedExclusions, flowInsets,
                    usedLineMetrics, wrap?.noWrap?.let { plan -> { start -> plan.hasLineAt(start) } },
                    exactAvailableWidth = exactAvailableWidth,
                    requiredLineWidths = when {
                        exactAvailableWidth != null && wrap?.noWrap != null -> FloatArray(rows.size) { rows[it].visibleAdvance }
                        clippedProbe != null -> FloatArray(rows.size) { rows[it].requiredFlowWidth ?: 0f }
                        else -> null
                    })
                if (left.contentEquals(flow.left) && right.contentEquals(flow.right)) {
                    rows.forEachIndexed { index, row ->
                        if (flow.constrainedByFloat[index] && row.visibleAdvance > availableWidth - flow.left[index] - flow.right[index])
                            throw UnsupportedFloatLayout("Native Float image row exceeds the remaining float lane")
                    }
                    if (requireDrainedAtBoundary && flow.exclusions.any { it.outer.bottom > flow.bottom + 0.01f })
                        throw UnsupportedFloatLayout("Active float crosses an unsupported formatting boundary")
                    return NativeFloatRowPlan(source, TextPaint().apply { set(paint) }, width, runs, rows, flow, natural,
                        alignment, availableWidth, paragraphLeft, paragraphRight) { next ->
                        build(next, paint, width, occurrences, alignment, direction, lineSpacingExtra,
                            lineSpacingMultiplier, requireDrainedAtBoundary, carriedExclusions, insets,
                            usedLineMetrics, includeFontPadding, exactAvailableWidth, exactParagraphInsets)
                    }
                }
                left = flow.left; right = flow.right
            }
            throw UnsupportedFloatLayout("Float image rows did not converge after 64 native layouts")
        }
    }
}

private fun nativeFloatRows(source: Spanned, paint: TextPaint, runs: NativeFloatRowRuns,
    width: Float, left: IntArray, right: IntArray, wrap: NativeTextWrapPlan?,
    alignment: Layout.Alignment): List<NativeFloatPlannedRow> {
    source.getSpans(0, source.length, NativeClippedProbeAllocation::class.java).singleOrNull()?.let {
        return nativeClippedProbeRows(source, paint, runs, width, left, right, wrap, alignment, it)
    }
    if (source.getSpans(0, source.length, NativeRubyLinePlan::class.java).isNotEmpty() ||
        source.getSpans(0, source.length, NativeRubyBreaks::class.java).isNotEmpty())
        return nativeRubyFloatRows(source, paint, runs, width, left, right, wrap, alignment)
    val result = mutableListOf<NativeFloatPlannedRow>()
    val indents = IntArray(maxOf(left.size, right.size)) { index ->
        val l = left[minOf(index, left.lastIndex)]
        val r = right[minOf(index, right.lastIndex)]
        if (l.toLong() + r > Int.MAX_VALUE) throw UnsupportedFloatLayout("Float image lane exceeds native coordinates")
        l + r
    }
    val breaker = LineBreaker.Builder().setBreakStrategy(LineBreaker.BREAK_STRATEGY_SIMPLE)
        .setHyphenationFrequency(LineBreaker.HYPHENATION_FREQUENCY_NONE).setIndents(indents).build()
    for (paragraph in runs.paragraphs) {
        val paragraphAlignment = source.getSpans(paragraph.start, paragraph.end, AlignmentSpan::class.java)
            .filter { source.getSpanStart(it) <= paragraph.start && source.getSpanEnd(it) >= paragraph.end }
            .lastOrNull()?.alignment ?: alignment
        if (paragraph.isEmpty) {
            val fm = paint.fontMetricsInt
            result += NativeFloatPlannedRow(paragraph, paragraphAlignment, paragraph.start, paragraph.end, paragraph.measuredEnd,
                emptyList(), 0f, 0f, 0f, NativeUsedLineMetrics(fm.ascent.toFloat(), fm.descent.toFloat()),
                NativeUsedLineMetrics(fm.top.toFloat(), fm.bottom.toFloat()))
            continue
        }
        val noWrap = wrap?.noWrap?.paragraphAt(paragraph.start)
        val measured = checkNotNull(paragraph.measured)
        val initialIndent = indents[minOf(result.size, indents.lastIndex)]
        // NoWrap removes soft fitting pressure, rather than rounding a measured
        // prefix into a threshold. Actual published coordinates remain bounded.
        val paragraphWidth = if (noWrap == null) width else maxOf(width,
            TablePixelLimit * 2f + initialIndent)
        val constraints = LineBreaker.ParagraphConstraints().apply { setWidth(paragraphWidth) }
        val fitted = breaker.computeLineBreaks(measured, constraints, result.size)
        var start = paragraph.start
        for (index in 0 until fitted.lineCount) {
            val contentEnd = paragraph.start + fitted.getLineBreakOffset(index)
            val end = if (contentEnd == paragraph.measuredEnd) paragraph.end else contentEnd
            if (end <= start || end > paragraph.end || fitted.hasLineTab(index) ||
                fitted.getStartLineHyphenEdit(index) != 0 || fitted.getEndLineHyphenEdit(index) != 0)
                throw UnsupportedFloatLayout("Float image native row has an unsupported source break")
            val normal = wrap?.words?.firstOrNull { it.normal && end > it.start && end < it.visibleEnd }
            if (normal != null)
                throw UnsupportedFloatLayout("Authored normal Float image overflow needs an unavailable exact native correction")
            if (noWrap != null && (start != paragraph.start || end != paragraph.end))
                throw UnsupportedFloatLayout("Native Float image no-wrap changed a hard source paragraph")
            val visibleEnd = nativeFloatDisplayEnd(source, start, end)
            val glyphs = runs.visualRuns(paragraph, start, contentEnd, visibleEnd)
            val advance = nativeFloatRowSum(glyphs.map { it.advance })
            val visible = nativeFloatRowSum(glyphs.filter { it.start < visibleEnd }.map { it.advance })
            val fullMeasured = measured.getWidth(start - paragraph.start, contentEnd - paragraph.start)
            if (!nativeFloatRowSameAdvance(advance, fullMeasured, glyphs.size))
                throw UnsupportedFloatLayout("Float image row glyph advances differ from full native measurement")
            var fitEnd = contentEnd
            while (fitEnd > start && nativeFloatRowLineEndSpace(source[fitEnd - 1])) fitEnd--
            val fitMeasured = measured.getWidth(start - paragraph.start, fitEnd - paragraph.start)
            val fitAdvance = fitted.getLineWidth(index)
            if (!nativeFloatRowSameAdvance(fitMeasured, fitAdvance, end - start))
                throw UnsupportedFloatLayout("Float image native fit width has an unsupported trailing-source policy")
            var natural = NativeUsedLineMetrics(fitted.getLineAscent(index), fitted.getLineDescent(index))
            var padded = natural
            glyphs.forEach { natural = natural.including(it.natural); padded = padded.including(it.paddedNatural) }
            result += NativeFloatPlannedRow(paragraph, paragraphAlignment, start, end, visibleEnd, glyphs, advance, visible,
                fitAdvance, natural, padded)
            start = end
        }
        if (start != paragraph.end) throw UnsupportedFloatLayout("Float image native row lost its paragraph suffix")
    }
    if (result.isEmpty()) throw UnsupportedFloatLayout("Float image source has no native paragraph")
    return result
}

internal fun nativeFloatRowSum(values: List<Float>): Float = values.sumOf { it.toDouble() }.let {
    if (!it.isFinite() || it < 0.0 || it > TablePixelLimit) throw UnsupportedFloatLayout("Float row advance exceeds native coordinates")
    it.toFloat()
}

/** The bound accounts only for Float accumulation order; it is not a pixel fitting tolerance. */
internal fun nativeFloatRowSameAdvance(a: Float, b: Float, terms: Int): Boolean =
    a.isFinite() && b.isFinite() && abs(a.toDouble() - b) <=
        maxOf(Math.ulp(a).toDouble(), Math.ulp(b).toDouble()) * maxOf(2, terms)

private fun nativeFloatDisplayEnd(source: CharSequence, start: Int, end: Int): Int {
    if (end == source.length && (end == start || source[end - 1] != '\n')) return end
    if (end > start && source[end - 1] == '\n') return end - 1
    var at = end
    while (at > start && nativeFloatRowLineEndSpace(source[at - 1])) at--
    return at
}

internal fun nativeFloatRowEmergencyEnds(runs: NativeFloatRowRuns): Set<Int> = buildSet {
    val breaker = LineBreaker.Builder().setBreakStrategy(LineBreaker.BREAK_STRATEGY_SIMPLE)
        .setHyphenationFrequency(LineBreaker.HYPHENATION_FREQUENCY_NONE).build()
    val constraints = LineBreaker.ParagraphConstraints().apply { setWidth(0f) }
    for (paragraph in runs.paragraphs) if (!paragraph.isEmpty) {
        val fit = breaker.computeLineBreaks(checkNotNull(paragraph.measured), constraints, 0)
        for (line in 0 until fit.lineCount) {
            val end = paragraph.start + fit.getLineBreakOffset(line)
            add(if (end == paragraph.measuredEnd) paragraph.end else end)
        }
    }
}

internal data class NativeFloatRowIntrinsicWidths(val minimum: Float, val maximum: Float)

/** Preserve native advances until a caller actually publishes an integer measurement. */
internal fun nativeFloatRowIntrinsicWidths(source: Spanned, paint: TextPaint, direction: TextDirectionHeuristic,
    breakWordMinimum: Boolean, intrinsicWrap: InlineBoxIntrinsicWrap? = null): NativeFloatRowIntrinsicWidths {
    NativeClippedAbsoluteProjection.create(source)?.let { clipped ->
        if (!clipped.hasFlow) return NativeFloatRowIntrinsicWidths(0f, 0f)
        return nativeFloatRowIntrinsicWidths(clipped.visual, paint, direction, breakWordMinimum, intrinsicWrap)
    }
    nativeRubyLayout(source, paint, direction, exactAdvances = true,
        intrinsicWidth = NativeRubyIntrinsicWidth.Maximum)?.let { unbroken ->
        val maximum = nativeFloatRowIntrinsicWidths(unbroken.native, paint, direction, breakWordMinimum, intrinsicWrap).maximum
        val fragmented = checkNotNull(nativeRubyLayout(source, paint, direction,
            NativeRubyBands(0f, allowEmergency = false), exactAdvances = true, intrinsicWidth = NativeRubyIntrinsicWidth.Minimum))
        val minimum = nativeFloatRowIntrinsicWidths(fragmented.native, paint, direction, breakWordMinimum, intrinsicWrap).minimum
        if (minimum > maximum) throw UnsupportedFloatLayout("Exact ruby minimum exceeds its unbroken width")
        return NativeFloatRowIntrinsicWidths(minimum, maximum)
    }
    validateNativeFloatRowStructure(source)
    val runs = NativeFloatRowRuns(source, paint, direction)
    val wrap = NativeTextWrapPlan.create(source, paint)
    wrap?.noWrap?.requireLinePresence()
    if (intrinsicWrap == InlineBoxIntrinsicWrap.Anywhere && wrap?.noWrap != null)
        throw UnsupportedFloatLayout("Anywhere intrinsic wrapping conflicts with a no-wrap owner")
    val emergencyMinimumRequested = when (intrinsicWrap) {
        InlineBoxIntrinsicWrap.Anywhere -> true
        InlineBoxIntrinsicWrap.Normal -> false
        null -> breakWordMinimum
    }
    var maximum = 0f
    var minimum = 0f
    var authoredMinimum = 0f
    val breaks = BreakIterator.getLineInstance(paint.textLocale).apply { setText(source.toString()) }
    val boundaries = source.getSpans(0, source.length, NativeRubyBreaks::class.java).singleOrNull()?.boundaries
        ?: buildList { add(0); var at = breaks.next(); while (at != BreakIterator.DONE) { add(at); at = breaks.next() } }
    fun advance(start: Int, end: Int): Float {
        if (start == end) return 0f
        val paragraph = runs.paragraphs.firstOrNull { start >= it.start && end <= it.end }
            ?: throw UnsupportedFloatLayout("Float image intrinsic range crosses a hard paragraph")
        val last = minOf(end, paragraph.measuredEnd)
        return if (start >= last) 0f else checkNotNull(paragraph.measured).getWidth(start - paragraph.start, last - paragraph.start)
    }
    for (paragraph in runs.paragraphs) {
        maximum = maxOf(maximum, advance(paragraph.start, paragraph.measuredEnd))
        if (wrap?.noWrap != null) continue
        val cuts = (listOf(paragraph.start, paragraph.end) + boundaries.filter { it > paragraph.start && it < paragraph.end }).distinct().sorted()
        for ((first, last) in cuts.zipWithNext()) {
            var end = minOf(last, paragraph.measuredEnd)
            while (end > first && nativeFloatRowLineEndSpace(source[end - 1])) end--
            val value = advance(first, end)
            minimum = maxOf(minimum, value)
            if (intrinsicWrap != InlineBoxIntrinsicWrap.Anywhere &&
                wrap?.ordinaryMinimum(first, end, emergencyMinimumRequested) == true)
                authoredMinimum = maxOf(authoredMinimum, value)
        }
    }
    if (wrap?.noWrap != null) minimum = maximum
    else if (emergencyMinimumRequested) {
        var emergencyMinimum = 0f
        val emergencyEnds = nativeFloatRowEmergencyEnds(runs)
        for (paragraph in runs.paragraphs) {
            var first = paragraph.start
            for (end in emergencyEnds.filter { it > paragraph.start && it <= paragraph.end }.sorted()) {
                var visibleEnd = minOf(end, paragraph.measuredEnd)
                while (visibleEnd > first && nativeFloatRowLineEndSpace(source[visibleEnd - 1])) visibleEnd--
                emergencyMinimum = maxOf(emergencyMinimum, advance(first, visibleEnd)); first = end
            }
        }
        minimum = maxOf(authoredMinimum, emergencyMinimum)
    }
    return NativeFloatRowIntrinsicWidths(minimum, maxOf(minimum, maximum))
}

internal fun nativeFloatRowWidthRange(source: Spanned, paint: TextPaint, direction: TextDirectionHeuristic,
    inset: Float, breakWordMinimum: Boolean): NativeWidthRange {
    val widths = nativeFloatRowIntrinsicWidths(source, paint, direction, breakWordMinimum)
    fun pixels(value: Float): Int {
        val total = value.toDouble() + inset
        return if (!total.isFinite() || total > TablePixelLimit) androidx.compose.ui.unit.Constraints.Infinity else ceil(total).toInt()
    }
    return NativeWidthRange(pixels(widths.minimum), pixels(widths.maximum))
}
