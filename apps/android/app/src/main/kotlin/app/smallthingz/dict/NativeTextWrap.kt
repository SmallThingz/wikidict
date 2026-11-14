package app.smallthingz.dict

import android.text.Layout
import android.text.PrecomputedText
import android.text.Spanned
import android.text.StaticLayout
import android.text.TextPaint
import android.text.style.CharacterStyle
import android.text.style.ReplacementSpan
import java.text.BreakIterator
import kotlin.math.ceil

/** Non-painting source policy. A heading owner is inherited; an authored run overrides it. */
internal data class NativeAuthoredTextWrap(val wrap: TextWrap, val inheritedOwner: Boolean = false,
    val sourceLineStarts: List<Int>? = null) {
    init { require(sourceLineStarts == null || wrap == TextWrap.NoWrap && inheritedOwner) {
        "Source line presence requires the complete no-wrap owner"
    } }
}

internal enum class NativeWrapAlignment { Normal, Opposite, Center }

/** Only the existing ordinary native inline-image span opts into this atomic owner. */
internal interface NativeNoWrapInlineImage : NativeAtomicInlineMetrics, NativeReplacementPaintBounds

/** Admitted images retain their existing object character and never replace surrounding text. */
internal fun validateNativeNoWrapImageRanges(source: CharSequence, ranges: List<Pair<Int, Int>>) {
    var previousEnd = -1
    for ((start, end) in ranges.sortedBy { it.first }) {
        if (start < 0 || start >= source.length || end != start + 1 || source[start] != '\ufffc' || start < previousEnd)
            throw UnsupportedFloatLayout("No-wrap image lost its exact source object range")
        previousEnd = end
    }
}

/** One explicit hard-LF line. Its measured text excludes LF but retains trailing spaces. */
internal data class NativeNoWrapParagraph(val start: Int, val measuredEnd: Int, val end: Int)

/** Whole-owner nowrap has no ordinary or emergency opportunities. This source map adds
 * no characters and keeps empty/consecutive/trailing hard lines as actual native lines. */
internal class NativeNoWrapPlan private constructor(val paragraphs: List<NativeNoWrapParagraph>,
    private val sourceLineStarts: Set<Int>?) {
    fun requireLinePresence() {
        if (sourceLineStarts == null) throw UnsupportedFloatLayout("No-wrap source line presence is unavailable")
    }

    fun hasLineAt(sourceStart: Int): Boolean {
        requireLinePresence()
        return paragraphAt(sourceStart).start in checkNotNull(sourceLineStarts)
    }

    fun paragraphAt(sourceStart: Int): NativeNoWrapParagraph {
        val exact = paragraphs.binarySearchBy(sourceStart) { it.start }
        val index = if (exact >= 0) exact else -exact - 2
        val paragraph = paragraphs.getOrNull(index)
        if (paragraph == null || sourceStart > paragraph.measuredEnd)
            throw UnsupportedFloatLayout("No-wrap line lost its source paragraph")
        return paragraph
    }

    fun advance(paragraph: NativeNoWrapParagraph, measure: (Int, Int) -> Float): Float {
        if (paragraph.start == paragraph.measuredEnd) return 0f
        val value = try { measure(paragraph.start, paragraph.measuredEnd) }
            catch (_: IllegalArgumentException) {
                throw UnsupportedFloatLayout("No-wrap source crosses a native measured paragraph")
            }
        if (!value.isFinite() || value < 0f || value > TablePixelLimit)
            throw UnsupportedFloatLayout("No-wrap source exceeds native coordinates")
        return value
    }

    fun maximumAdvance(measure: (Int, Int) -> Float): Float = paragraphs
        .filter { sourceLineStarts == null || it.start in sourceLineStarts }
        .maxOfOrNull { advance(it, measure) } ?: 0f

    fun validateLines(starts: IntArray, ends: IntArray) {
        if (starts.size != paragraphs.size || ends.size != paragraphs.size ||
            paragraphs.indices.any { starts[it] != paragraphs[it].start || ends[it] != paragraphs[it].end })
            throw UnsupportedFloatLayout("Native no-wrap layout changed an explicit hard-line boundary")
    }

    companion object {
        fun create(source: CharSequence, ranges: List<NativeInlineRange<NativeAuthoredTextWrap>>): NativeNoWrapPlan? {
            if (ranges.none { it.value.wrap == TextWrap.NoWrap }) return null
            val owner = ranges.singleOrNull()
            if (owner == null || owner.value.wrap != TextWrap.NoWrap || !owner.value.inheritedOwner ||
                owner.start != 0 || owner.end != source.length)
                throw UnsupportedFloatLayout("No-wrap requires one complete owner without descendant wrap overrides")
            if (source.any { it == '\t' || it == '\r' || it == '\u000b' || it == '\u000c' ||
                    it == '\u0085' || it == '\u2028' || it == '\u2029' })
                throw UnsupportedFloatLayout("No-wrap tab or non-LF hard-break mapping is unavailable")
            val paragraphs = mutableListOf<NativeNoWrapParagraph>()
            var start = 0
            source.indices.forEach { index ->
                if (source[index] == '\n') {
                    paragraphs += NativeNoWrapParagraph(start, index, index + 1)
                    start = index + 1
                }
            }
            paragraphs += NativeNoWrapParagraph(start, source.length, source.length)
            val declared = owner.value.sourceLineStarts
            if (declared != null && (declared.zipWithNext().any { (a, b) -> a >= b } ||
                    declared.any { at -> paragraphs.none { it.start == at && it.start < it.end } } ||
                    paragraphs.any { it.end > it.measuredEnd && it.start !in declared }))
                throw UnsupportedFloatLayout("No-wrap source line presence disagrees with its hard-line map")
            return NativeNoWrapPlan(paragraphs, declared?.toSet())
        }
    }
}

internal data class NativeWrapWord(val start: Int, val visibleEnd: Int, val end: Int,
    val normal: Boolean, val authored: Boolean, val fullyAuthored: Boolean)

/** Keep the normal break opportunities used by the existing intrinsic-width owner. The
 * native paragraph still shapes and breaks the complete source; this plan only detects
 * emergency breaks forbidden by an explicit normal range. Inline boundaries add no break. */
internal class NativeTextWrapPlan private constructor(
    val words: List<NativeWrapWord>,
    private val source: Spanned,
    private val authoredRanges: List<NativeInlineRange<NativeAuthoredTextWrap>>,
    private val graphemeBoundaries: Set<Int>,
    val noWrap: NativeNoWrapPlan? = null,
) {
    private val requiredWords = mutableMapOf<Int, NativeWrapWord>()

    fun ordinaryMinimum(sourceStart: Int, sourceEnd: Int, legacyEmergency: Boolean): Boolean {
        if (!legacyEmergency) return true
        val owned = words.filter { it.start < sourceEnd && it.visibleEnd > sourceStart && it.authored }
        if (owned.isEmpty()) return false
        // A run boundary inside an unbreakable word has no independent CSS soft opportunity.
        // Do not silently make a neighbouring legacy-anywhere run part of this source policy.
        if (owned.any { it.start < sourceStart || it.visibleEnd > sourceEnd || !it.fullyAuthored })
            throw UnsupportedFloatLayout("Authored wrap crosses an intrinsic word boundary")
        return true
    }

    fun fit(layout: StaticLayout, measured: PrecomputedText, physicalLeft: IntArray,
        physicalRight: IntArray, constrainedByFloat: BooleanArray): Pair<IntArray, IntArray> {
        noWrap?.let { return fitNoWrap(it, layout, measured, physicalLeft, physicalRight, constrainedByFloat) }
        val left = physicalLeft.copyOf()
        val right = physicalRight.copyOf()
        for (line in 0 until layout.lineCount) {
            val start = layout.getLineStart(line)
            val end = layout.getLineEnd(line)
            val forbidden = words.firstOrNull { it.normal && end > it.start && end < it.visibleEnd }
            if (forbidden != null) {
                if (start != forbidden.start) {
                    // This layout still contains continuation lines from before the first
                    // line's fit extension. The next full native pass removes those lines;
                    // never transfer their obsolete line indices to another source word.
                    if (start > forbidden.start && requiredWords[forbidden.start] == forbidden &&
                        layout.getLineStart(layout.getLineForOffset(forbidden.start)) == forbidden.start) continue
                    throw UnsupportedFloatLayout("Authored normal fitting needs its native word-start line")
                }
                if ((forbidden.start until forbidden.visibleEnd).any { source[it] in "/\\.:@?#=&" })
                    throw UnsupportedFloatLayout("Native URL-tailored normal break ownership is unavailable")
                requiredWords[start] = forbidden
            }
            val requiredWord = requiredWords[start] ?: continue
            val requiredEnd = requiredWord.visibleEnd
            if (requiredEnd <= start || requiredEnd > source.length)
                throw UnsupportedFloatLayout("Authored wrap fitting lost its source word")
            val advance = try { measured.getWidth(start, requiredEnd) }
                catch (_: IllegalArgumentException) {
                    throw UnsupportedFloatLayout("Authored normal word crosses a native measured paragraph")
                }
            if (!advance.isFinite() || advance < 0f || advance > TablePixelLimit)
                throw UnsupportedFloatLayout("Authored normal word exceeds native coordinates")
            val available = layout.width.toLong() - physicalLeft[line] - physicalRight[line]
            val extra = (ceil(advance.toDouble()).toLong() - available).coerceAtLeast(0L)
            if (extra == 0L) {
                requiredWords.remove(start)
                continue
            }
            if (extra > 0L && constrainedByFloat[line])
                throw UnsupportedFloatLayout("Authored normal overflow in an active float lane is unavailable")
            val fitted = nativeWrapFitIndents(physicalLeft[line], physicalRight[line], extra,
                layout.getParagraphDirection(line) == 1, when (layout.getParagraphAlignment(line)) {
                    Layout.Alignment.ALIGN_NORMAL -> NativeWrapAlignment.Normal
                    Layout.Alignment.ALIGN_OPPOSITE -> NativeWrapAlignment.Opposite
                    Layout.Alignment.ALIGN_CENTER -> NativeWrapAlignment.Center
                    else -> throw UnsupportedFloatLayout("Unsupported authored wrap alignment")
                })
            left[line] = fitted.first
            right[line] = fitted.second
        }
        return left to right
    }

    private fun fitNoWrap(plan: NativeNoWrapPlan, layout: StaticLayout, measured: PrecomputedText,
        physicalLeft: IntArray, physicalRight: IntArray, constrainedByFloat: BooleanArray): Pair<IntArray, IntArray> {
        val left = physicalLeft.copyOf()
        val right = physicalRight.copyOf()
        for (line in 0 until layout.lineCount) {
            val paragraph = plan.paragraphAt(layout.getLineStart(line))
            if (layout.getLineStart(layout.getLineForOffset(paragraph.start)) != paragraph.start)
                throw UnsupportedFloatLayout("No-wrap fitting lost its native paragraph-start line")
            // The first pass can contain several soft/emergency continuation lines. Only
            // the source-start line owns this paragraph's extension; the next full native
            // pass removes stale continuations, without transferring their line indexes.
            if (layout.getLineStart(line) != paragraph.start) continue
            if (constrainedByFloat[line])
                throw UnsupportedFloatLayout("No-wrap float exclusions are unavailable")
            val advance = if (plan.hasLineAt(paragraph.start))
                plan.advance(paragraph) { start, end -> measured.getWidth(start, end) } else 0f
            val available = layout.width.toLong() - physicalLeft[line] - physicalRight[line]
            val extra = (ceil(advance.toDouble()).toLong() - available).coerceAtLeast(0L)
            val fitted = nativeWrapFitIndents(physicalLeft[line], physicalRight[line], extra,
                layout.getParagraphDirection(line) == 1, when (layout.getParagraphAlignment(line)) {
                    Layout.Alignment.ALIGN_NORMAL -> NativeWrapAlignment.Normal
                    Layout.Alignment.ALIGN_OPPOSITE -> NativeWrapAlignment.Opposite
                    Layout.Alignment.ALIGN_CENTER -> NativeWrapAlignment.Center
                    else -> throw UnsupportedFloatLayout("Unsupported no-wrap alignment")
                })
            left[line] = fitted.first
            right[line] = fitted.second
        }
        return left to right
    }

    fun validateResult(layout: StaticLayout) {
        noWrap?.let {
            it.validateLines(IntArray(layout.lineCount) { line -> layout.getLineStart(line) },
                IntArray(layout.lineCount) { line -> layout.getLineEnd(line) })
            return
        }
        for (line in 0 until layout.lineCount) {
            val start = layout.getLineStart(line)
            val end = layout.getLineEnd(line)
            if (authoredRanges.any { end > it.start && end < it.end } && end !in graphemeBoundaries)
                throw UnsupportedFloatLayout("Native emergency break splits an authored grapheme")
            if (words.any { it.normal && end > it.start && end < it.visibleEnd })
                throw UnsupportedFloatLayout("Native layout still splits an authored normal word")
            if (requiredWords[start]?.let { it.end != end } == true)
                throw UnsupportedFloatLayout("Native integer fitting cannot isolate the authored word boundary")
        }
    }

    companion object {
        fun create(source: Spanned, paint: TextPaint): NativeTextWrapPlan? {
            val ranges = nativeInlineRanges(source, NativeAuthoredTextWrap::class.java)
            if (ranges.isEmpty()) return null
            NativeNoWrapPlan.create(source, ranges)?.let { plan ->
                val replacements = source.getSpans(0, source.length, ReplacementSpan::class.java)
                if (replacements.any { it !is NativeNoWrapInlineImage })
                    throw UnsupportedFloatLayout("No-wrap replacement-backed text is unavailable")
                validateNativeNoWrapImageRanges(source, replacements.map { source.getSpanStart(it) to source.getSpanEnd(it) })
                return NativeTextWrapPlan(emptyList(), source, ranges, emptySet(), plan)
            }
            val graphemes = android.icu.text.BreakIterator.getCharacterInstance(paint.textLocale).apply {
                setText(source.toString())
            }
            val graphemeBoundaries = mutableSetOf<Int>()
            var boundary = graphemes.first()
            while (boundary != android.icu.text.BreakIterator.DONE) {
                graphemeBoundaries += boundary
                boundary = graphemes.next()
            }
            ranges.forEach { range ->
                if (range.start < 0 || range.end <= range.start || range.end > source.length ||
                    !graphemes.isBoundary(range.start) || !graphemes.isBoundary(range.end))
                    throw UnsupportedFloatLayout("Authored wrap must own complete nonempty grapheme ranges")
                if (source.getSpans(range.start, range.end, ReplacementSpan::class.java).any {
                    source.getSpanStart(it) < range.end && source.getSpanEnd(it) > range.start
                }) throw UnsupportedFloatLayout("Authored wrap on replacement-backed text is unavailable")
            }
            for (owner in listOf(false, true)) {
                val peers = ranges.filter { it.value.inheritedOwner == owner }.sortedBy { it.start }
                if (peers.zipWithNext().any { (a, b) -> a.end > b.start })
                    throw UnsupportedFloatLayout("Overlapping authored wrap peers are unavailable")
            }
            fun policyAt(offset: Int): TextWrap? = ranges.filter { it.start <= offset && it.end > offset }
                .minByOrNull { if (it.value.inheritedOwner) 1 else 0 }?.value?.wrap
            val breaks = BreakIterator.getLineInstance(paint.textLocale).apply { setText(source.toString()) }
            val words = mutableListOf<NativeWrapWord>()
            var start = 0
            var end = breaks.next()
            while (end != BreakIterator.DONE) {
                var visibleEnd = end
                while (visibleEnd > start && source[visibleEnd - 1].isWhitespace()) visibleEnd--
                if (visibleEnd > start) {
                    val cuts = (listOf(start, visibleEnd) + ranges.flatMap { listOf(it.start, it.end) }
                        .filter { it > start && it < visibleEnd }).distinct().sorted()
                    val policies = cuts.zipWithNext().map { (a, _) -> policyAt(a) }.distinct()
                    if (TextWrap.Normal in policies && policies.size != 1)
                        throw UnsupportedFloatLayout("Mixed normal wrap inside one unbreakable word is unavailable")
                    val normal = policies.singleOrNull() == TextWrap.Normal
                    if (normal) {
                        if ((start until visibleEnd).any { source[it] == '\t' })
                            throw UnsupportedFloatLayout("Authored normal tab fitting is unavailable")
                        var position = start
                        while (position < visibleEnd) {
                            val next = source.nextSpanTransition(position, visibleEnd, CharacterStyle::class.java)
                            val resolved = TextPaint(paint)
                            source.getSpans(position, next, CharacterStyle::class.java).forEach { it.updateDrawState(resolved) }
                            if (resolved.textLocales != paint.textLocales)
                                throw UnsupportedFloatLayout("Authored normal fitting needs one known break locale")
                            position = next
                        }
                    }
                    words += NativeWrapWord(start, visibleEnd, end, normal, policies.any { it != null }, policies.none { it == null })
                }
                start = end
                end = breaks.next()
            }
            return NativeTextWrapPlan(words, source, ranges, graphemeBoundaries)
        }
    }
}

/** Extend only the fitting side that leaves native paragraph alignment unchanged. The
 * physical Flow indents still own paint, hit, selection and float exclusions. For CENTER
 * an even extension keeps StaticLayout's integer half-indent identical to the old owner. */
internal fun nativeWrapFitIndents(left: Int, right: Int, extra: Long, ltr: Boolean,
    alignment: NativeWrapAlignment): Pair<Int, Int> {
    require(left >= 0 && right >= 0 && extra >= 0)
    if (extra > 3L * TablePixelLimit)
        throw UnsupportedFloatLayout("Authored wrap fitting exceeds native coordinates")
    val (l, r) = when (alignment) {
        NativeWrapAlignment.Normal -> if (ltr) left.toLong() to right.toLong() - extra
            else left.toLong() - extra to right.toLong()
        NativeWrapAlignment.Opposite -> if (ltr) left.toLong() - extra to right.toLong()
            else left.toLong() to right.toLong() - extra
        NativeWrapAlignment.Center -> (left.toLong() - (extra + 1L) / 2L) to
            (right.toLong() - (extra + 1L) / 2L)
    }
    if (kotlin.math.abs(l) > TablePixelLimit || kotlin.math.abs(r) > TablePixelLimit)
        throw UnsupportedFloatLayout("Authored wrap fitting exceeds native coordinates")
    return l.toInt() to r.toInt()
}
