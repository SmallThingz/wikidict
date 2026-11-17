package app.smallthingz.dict

import android.text.Layout
import android.text.PrecomputedText
import android.text.Spanned
import android.text.StaticLayout
import android.text.TextDirectionHeuristic
import android.text.TextPaint
import android.text.style.ReplacementSpan
import java.text.BreakIterator

/** Source endpoints are selected without inserting text. The actual full-context native
 * fitter must subsequently reproduce every endpoint; fractional edge sums are checked again
 * against the captured native line advances before paint or interaction is published. */
internal data class NativeInlineBoxFit(val ends: List<Int>, val advances: List<Float>,
    val overflowingStarts: Set<Int>)

internal class NativeInlineBoxWidths(source: Spanned, private val paint: TextPaint,
    private val direction: TextDirectionHeuristic) {
    private val source = source
    private val boxes = nativeInlineRanges(source, NativeInlineBoxSpan::class.java)
    private val markers = nativeInlineRanges(source, NativeCitationMarkerSpan::class.java)
        .filter { it.value.marker.nowrap }
    private val wrap = NativeTextWrapPlan.create(source, paint)
    private val measured = PrecomputedText.create(source, PrecomputedText.Params.Builder(TextPaint(paint))
        .setTextDirection(direction).setBreakStrategy(android.graphics.text.LineBreaker.BREAK_STRATEGY_SIMPLE)
        .setHyphenationFrequency(Layout.HYPHENATION_FREQUENCY_NONE).build())
    private val paragraphs = buildList<Pair<Int, Int>> {
        var first = 0
        source.indices.forEach { at -> if (source[at] == '\n') { add(first to at + 1); first = at + 1 } }
        if (first < source.length) add(first to source.length)
    }
    private val ordinary: List<Int>
    init {
        require(source.isNotEmpty() && (boxes.isNotEmpty() || markers.isNotEmpty()))
        if (markers.any { it.start < 0 || it.start >= it.end || it.end > source.length } ||
            markers.sortedBy { it.start }.zipWithNext().any { (a, b) -> a.end > b.start })
            throw UnsupportedFloatLayout("Citation no-wrap lost its disjoint nonempty source intervals")
        if (source.any { it == '\t' || it == '\r' || it == '\u000b' || it == '\u000c' ||
                it == '\u0085' || it == '\u2028' || it == '\u2029' })
            throw UnsupportedFloatLayout("Inline box paragraph has unsupported native control layout")
        if (source.getSpans(0, source.length, ReplacementSpan::class.java).isNotEmpty())
            throw UnsupportedFloatLayout("Inline box paragraph needs native replacement allocation")
        if (boxes.any { it.start >= it.end || it.start < 0 || it.end > source.length })
            throw UnsupportedFloatLayout("Inline box lost its nonempty source interval")
        if (boxes.sortedBy { it.start }.zipWithNext().any { (a, b) -> a.end > b.start })
            throw UnsupportedFloatLayout("Nested inline box allocation is unavailable")
        boxes.forEach { box ->
            val body = source.subSequence(box.start, box.end)
            if (body.any { it in "\t\r\n\u000c" })
                throw UnsupportedFloatLayout("Inline box forced text breaks are unavailable")
            if (body.first().isWhitespace() || body.last().isWhitespace())
                throw UnsupportedFloatLayout("Inline box edge whitespace needs native collapse ownership")
        }
        val retained = source.getSpans(0, source.length, NativeRubyBreaks::class.java).singleOrNull()?.boundaries
        ordinary = (retained ?: buildList {
            val breaks = BreakIterator.getLineInstance(paint.textLocale).apply { setText(source.toString()) }
            var at = breaks.first()
            while (at != BreakIterator.DONE) { add(at); at = breaks.next() }
        }).filter { it > 0 }.plus(paragraphs.map { it.second }).distinct().sorted()
            .filter(::allowedMarkerBoundary)
    }

    // A marker suppresses only its interior soft opportunities. Keep the original
    // paragraph ends, including a real hard LF inside a no-wrap source range.
    private fun allowedMarkerBoundary(end: Int): Boolean = markers.none { end > it.start && end < it.end } ||
        paragraphs.any { it.second == end }

    private fun paragraph(at: Int): Pair<Int, Int> = paragraphs.first { at >= it.first && at < it.second }
    private fun parentRtl(box: NativeInlineBoxSpan, at: Int): Boolean = box.parentRtl ?: paragraph(at).let {
        direction.isRtl(source, it.first, it.second - it.first)
    }
    fun edges(start: Int, end: Int): Float = nativeInlineBoxCoordinate(boxes.sumOf { range ->
        val box = range.value.box
        val rtl = parentRtl(range.value, range.start)
        (if (range.start >= start && range.start < end) (if (rtl) box.rightAdvance else box.leftAdvance).toDouble() else 0.0) +
            (if (range.end > start && range.end <= end) (if (rtl) box.leftAdvance else box.rightAdvance).toDouble() else 0.0)
    })
    private fun visibleEnd(start: Int, end: Int): Int {
        if (end == source.length && source.last() != '\n') return end
        var last = end
        // Match the native visible-end policy. A hard LF ends this scan; soft-line
        // spaces are excluded, while the historical final line keeps its spaces.
        if (last > start && source[last - 1] == '\n') return last - 1
        fun lineEndSpace(c: Char): Boolean = c == ' ' || c == '\t' || c == '\u1680' ||
            c in '\u2000'..'\u200a' && c != '\u2007' || c == '\u205f' || c == '\u3000'
        while (last > start && lineEndSpace(source[last - 1])) last--
        return last
    }
    fun advance(start: Int, end: Int, intrinsicMinimum: Boolean = false): Float {
        var last = visibleEnd(start, end)
        if (intrinsicMinimum) {
            if (markers.isEmpty()) while (last > start && source[last - 1].isWhitespace()) last--
            else while (last > start && nativeFloatRowLineEndSpace(source[last - 1]) &&
                markers.none { last - 1 >= it.start && last - 1 < it.end }) last--
        }
        val value = try { if (last == start) 0f else measured.getWidth(start, last) }
        catch (_: IllegalArgumentException) {
            throw UnsupportedFloatLayout("Inline box width crosses a native paragraph")
        }
        if (value < 0f) throw UnsupportedFloatLayout("Inline box native advance is negative")
        return nativeInlineBoxCoordinate(value.toDouble())
    }
    private fun allowedOrdinary(end: Int): Boolean = wrap?.words?.none {
        it.normal && end > it.start && end < it.visibleEnd
    } ?: true
    private val emergency by lazy {
        // Observe endpoints using the same original source and native engine, without
        // invoking unrelated authored-normal fit/refusal on a zero-width paragraph.
        val layout = StaticLayout.Builder.obtain(measured, 0, measured.length, TextPaint(paint), 0)
            .setTextDirection(direction).setIncludePad(false)
            .setBreakStrategy(android.graphics.text.LineBreaker.BREAK_STRATEGY_SIMPLE)
            .setHyphenationFrequency(Layout.HYPHENATION_FREQUENCY_NONE).build()
        (0 until layout.lineCount).map { layout.getLineEnd(it) }.distinct().filter {
            allowedMarkerBoundary(it) &&
                (wrap?.permitsEmergencyBreak(it) ?: (it > 0 && it < source.length))
        }
    }

    fun fit(available: Float): NativeInlineBoxFit {
        require(available.isFinite() && available >= 0f)
        val ends = mutableListOf<Int>()
        val advances = mutableListOf<Float>()
        val overflow = mutableSetOf<Int>()
        var start = 0
        while (start < source.length) {
            val paragraphEnd = paragraph(start).second
            val choices = if (wrap?.noWrap != null) listOf(paragraphEnd)
                else ordinary.filter { it > start && it <= paragraphEnd && allowedOrdinary(it) }
            if (choices.isEmpty()) throw UnsupportedFloatLayout("Inline box has no native ordinary continuation")
            fun total(end: Int): Double = advance(start, end).toDouble() + edges(start, end)
            var selected = choices.lastOrNull { total(it) <= available } ?: choices.first()
            if (total(selected) > available && wrap?.noWrap == null) {
                val alternatives = emergency.filter { it > start && it < selected }
                (alternatives.lastOrNull { total(it) <= available } ?: alternatives.firstOrNull())?.let { selected = it }
            }
            if (total(selected) > available) overflow += start
            ends += selected
            advances += advance(start, selected)
            start = selected
        }
        if (source.last() == '\n') { ends += source.length; advances += 0f }
        return NativeInlineBoxFit(ends, advances, overflow)
    }

    fun intrinsic(inset: Float, breakWordMinimum: Boolean): NativeWidthRange {
        require(inset.isFinite() && inset >= 0f)
        var minimum = 0.0
        var maximum = 0.0
        var authoredMinimum = 0.0
        for ((start, end) in paragraphs) {
            maximum = maxOf(maximum, advance(start, end).toDouble() + edges(start, end))
            if (wrap?.noWrap != null) continue
            var first = start
            ordinary.filter { it > start && it <= end && allowedOrdinary(it) }.forEach { last ->
                val used = advance(first, last, intrinsicMinimum = true).toDouble() + edges(first, last)
                minimum = maxOf(minimum, used)
                if (wrap?.ordinaryMinimum(first, visibleEnd(first, last), true) == true)
                    authoredMinimum = maxOf(authoredMinimum, used)
                first = last
            }
        }
        if (wrap?.noWrap != null) minimum = maximum
        else if (breakWordMinimum) {
            var first = 0
            var emergencyMinimum = 0.0
            (emergency + ordinary).distinct().sorted().forEach { last ->
                if (last > first) {
                    emergencyMinimum = maxOf(emergencyMinimum, advance(first, last, intrinsicMinimum = true).toDouble() + edges(first, last))
                    first = last
                }
            }
            minimum = maxOf(authoredMinimum, emergencyMinimum)
        }
        fun pixels(value: Double): Int {
            val used = value + inset
            if (!used.isFinite() || used > TablePixelLimit)
                throw UnsupportedFloatLayout("Inline box intrinsic exceeds native coordinates")
            return kotlin.math.ceil(used).toInt()
        }
        return NativeWidthRange(pixels(minimum), pixels(maxOf(minimum, maximum)))
    }
}
