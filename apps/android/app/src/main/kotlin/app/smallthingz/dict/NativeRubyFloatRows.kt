package app.smallthingz.dict

import android.text.Layout
import android.text.Spanned
import android.text.TextPaint
import android.text.style.AlignmentSpan

/** Ruby's joint cuts are source-owned; their widths come from the complete native
 * MeasuredText, including Float replacement advances. Replay keeps that same context. */
internal fun nativeRubyFloatRows(source: Spanned, paint: TextPaint, runs: NativeFloatRowRuns,
    width: Float, left: IntArray, right: IntArray, wrap: NativeTextWrapPlan?,
    alignment: Layout.Alignment): List<NativeFloatPlannedRow> {
    val selected = source.getSpans(0, source.length, NativeRubyLinePlan::class.java).singleOrNull()
    val breaks = source.getSpans(0, source.length, NativeRubyBreaks::class.java).singleOrNull()?.boundaries.orEmpty()
    val forced = nativeInlineRanges(source, NativeRubyColumn::class.java).filter { it.value.continues }.map { it.end }.toSet()
    val emergency by lazy { nativeFloatRowEmergencyEnds(runs) }
    val result = mutableListOf<NativeFloatPlannedRow>()
    fun measure(paragraph: NativeFloatRunParagraph, start: Int, end: Int): Float {
        val last = minOf(end, paragraph.measuredEnd)
        return if (start >= last) 0f else checkNotNull(paragraph.measured).getWidth(start - paragraph.start, last - paragraph.start)
    }
    fun visible(start: Int, end: Int): Int {
        if (end == source.length && (end == start || source[end - 1] != '\n')) return end
        if (end > start && source[end - 1] == '\n') return end - 1
        var last = end
        while (last > start && nativeFloatRowLineEndSpace(source[last - 1])) last--
        return last
    }
    fun fitEnd(paragraph: NativeFloatRunParagraph, start: Int, end: Int): Int {
        var last = minOf(end, paragraph.measuredEnd)
        while (last > start && nativeFloatRowLineEndSpace(source[last - 1])) last--
        return last
    }
    for (paragraph in runs.paragraphs) {
        val paragraphAlignment = source.getSpans(paragraph.start, paragraph.end, AlignmentSpan::class.java)
            .filter { source.getSpanStart(it) <= paragraph.start && source.getSpanEnd(it) >= paragraph.end }
            .lastOrNull()?.alignment ?: alignment
        var start = paragraph.start
        do {
            val ordinal = result.size
            val limit = (width - left[minOf(ordinal, left.lastIndex)] - right[minOf(ordinal, right.lastIndex)]).coerceAtLeast(0f)
            val end = if (selected != null) {
                selected.ends.getOrNull(ordinal)
                    ?: throw UnsupportedFloatLayout("Exact ruby joint plan lost a native line")
            } else if (paragraph.isEmpty || wrap?.noWrap?.paragraphAt(start) != null) paragraph.end
            else {
                val stop = forced.filter { it > start && it < paragraph.end }.minOrNull() ?: paragraph.end
                val ordinary = (breaks.filter { it > start && it < stop } + stop).distinct().sorted()
                    .filter { cut -> cut == stop || wrap?.words.orEmpty().none { it.normal && cut > it.start && cut < it.visibleEnd } }
                val fit = ordinary.lastOrNull { measure(paragraph, start, fitEnd(paragraph, start, it)) <= limit }
                if (fit != null) fit else {
                    val first = ordinary.first()
                    val normal = wrap?.words?.any { it.normal && start >= it.start && start < it.visibleEnd } == true
                    if (normal) first else {
                        val cuts = emergency.filter { it > start && it <= first }.sorted()
                        cuts.lastOrNull { measure(paragraph, start, fitEnd(paragraph, start, it)) <= limit }
                            ?: cuts.firstOrNull() ?: first
                    }
                }
            }
            if (end < start || end > paragraph.end || end == start && !paragraph.isEmpty)
                throw UnsupportedFloatLayout("Exact ruby line lost its original paragraph range")
            val contentEnd = minOf(end, paragraph.measuredEnd)
            val visibleEnd = visible(start, end)
            val glyphs = if (paragraph.isEmpty) emptyList() else runs.visualRuns(paragraph, start, contentEnd, visibleEnd)
            val advance = nativeFloatRowSum(glyphs.map { it.advance })
            val measured = measure(paragraph, start, end)
            if (!nativeFloatRowSameAdvance(advance, measured, glyphs.size))
                throw UnsupportedFloatLayout("Exact ruby replay differs from native measurement")
            if (selected != null && !nativeFloatRowSameAdvance(advance, selected.advances[ordinal], glyphs.size))
                throw UnsupportedFloatLayout("Exact ruby joint cut changed its selected advance")
            val fm = paint.fontMetrics
            var natural = NativeUsedLineMetrics(fm.ascent, fm.descent)
            var padded = NativeUsedLineMetrics(fm.top, fm.bottom)
            glyphs.forEach { natural = natural.including(it.natural); padded = padded.including(it.paddedNatural) }
            val shown = nativeFloatRowSum(glyphs.filter { it.start < visibleEnd }.map { it.advance })
            result += NativeFloatPlannedRow(paragraph, paragraphAlignment, start, end, visibleEnd,
                glyphs, advance, shown, measure(paragraph, start, fitEnd(paragraph, start, end)), natural, padded)
            start = end
        } while (start < paragraph.end)
    }
    if (selected != null && result.map { it.end } != selected.ends)
        throw UnsupportedFloatLayout("Exact ruby joint plan changed native endpoints")
    return result
}
