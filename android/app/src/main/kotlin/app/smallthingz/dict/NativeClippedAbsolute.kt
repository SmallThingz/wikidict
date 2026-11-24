package app.smallthingz.dict

import android.text.SpannableString
import android.text.Spanned
import android.text.SpannedString
import android.text.style.ParagraphStyle
import kotlin.math.abs

/** One original declaring occurrence; equal source spans at different paths stay distinct. */
internal class NativeClippedAbsoluteOwner(val span: Span, val path: String)

internal data class NativeClippedAbsoluteMargins(val top: Float, val right: Float,
    val bottom: Float, val left: Float) {
    init { nativeClippedCoordinates(top, right, bottom, left) }
}

internal class NativeClippedAbsoluteFormat(val owner: NativeClippedAbsoluteOwner,
    val width: Float, val height: Float, val margins: NativeClippedAbsoluteMargins,
    val coordinateScope: NativeClippedAbsoluteCoordinateScope? = null) {
    init {
        nativeClippedCoordinates(width, height)
        if (width < 0f || height < 0f) throw UnsupportedFloatLayout("Clipped absolute dimensions are negative")
    }
}

internal data class NativeClippedAbsoluteOccurrence(val start: Int, val end: Int,
    val format: NativeClippedAbsoluteFormat, val declaring: NativeRubyGroupFormat,
    val parentScript: NativeRubyScriptState)

/** Source-bound direction of the original static-position paragraph container. */
internal data class NativeClippedParagraphDirection(val direction: BidiResolvedDirection)

internal fun nativeClippedParagraphDirectionAt(source: Spanned, offset: Int): BidiResolvedDirection? {
    val directions = source.getSpans(offset, offset, NativeClippedParagraphDirection::class.java).filter {
        val first = source.getSpanStart(it); val last = source.getSpanEnd(it)
        first <= offset && (offset < last || first == last && offset == first ||
            offset == source.length && last == offset && source.lastOrNull() != '\n')
    }.map { it.direction }.distinct()
    if (directions.size > 1) throw UnsupportedFloatLayout("Clipped static-parent directions conflict in one paragraph")
    return directions.singleOrNull()
}

internal fun nativeHasClippedParagraphDirection(source: Spanned): Boolean =
    source.getSpans(0, source.length, NativeClippedParagraphDirection::class.java).isNotEmpty()

internal data class NativeClippedSourceParagraph(val start: Int, val end: Int, val direction: BidiResolvedDirection)

/** Original visible point identity survives immutable metric-span occurrence copies. */
internal class NativeClippedVisibleMetricPoint
internal class NativeClippedVisibleMetricMarker(val key: NativeClippedVisibleMetricPoint)

/** Public source bytes never enter the private visual buffer for a clipped owner. */
internal class NativeClippedAbsoluteProjection private constructor(val source: Spanned,
    val occurrences: List<NativeClippedAbsoluteOccurrence>, private val prepared: List<Prepared>) {
    val map = NativeClippedSourceMap(source.toString(), occurrences.map { NativeClippedSourceRange(it.start, it.end) })
    private val sourceParagraphStarts = listOf(0) + map.source.indices.filter { map.source[it] == '\n' }.map { it + 1 }
    private fun paragraphStart(offset: Int): Int {
        val found = sourceParagraphStarts.binarySearch(offset)
        return sourceParagraphStarts[if (found >= 0) found else -found - 2]
    }
    private val paragraphOwners = occurrences.groupBy { paragraphStart(it.start) }
    val paragraphs: List<NativeClippedSourceParagraph> = paragraphOwners.map { (start, owners) ->
        val directions = owners.map { checkNotNull(it.format.owner.span.clippedAbsolute).staticParentDirection }.distinct()
        if (directions.size != 1) throw UnsupportedFloatLayout("Clipped static-parent directions conflict in one paragraph")
        val ordinal = sourceParagraphStarts.binarySearch(start)
        val end = sourceParagraphStarts.getOrNull(ordinal + 1) ?: source.length
        NativeClippedSourceParagraph(start, end, directions.single())
    }
    private val paragraphByOccurrence = java.util.IdentityHashMap<NativeClippedAbsoluteOccurrence, NativeClippedSourceParagraph>().apply {
        paragraphs.forEach { paragraph -> paragraphOwners.getValue(paragraph.start).forEach { put(it, paragraph) } }
    }
    private val points = nativeInlineRanges(source, NativeClippedVisibleMetricMarker::class.java)
    val visual: Spanned
    val hasFlow: Boolean get() = visual.isNotEmpty() || hasNativeAuthoredInlineMetrics(visual)

    private data class Prepared(val start: Int, val end: Int, val value: NativeRubyPreparedSource)

    private fun installVisibleGroups(target: SpannableString, start: Int, end: Int,
        original: NativeRubyPreparedSource, ranges: List<RubyTextRange>) {
        val actions = ranges.filter { it.role == RubyTextRole.ActionGroup }
        if (actions.isEmpty() && ranges.none { it.span?.let { span ->
                span.usesInlineDirectionIsolate() || span.citationMarker != null
            } == true }) return
        val local = SpannedString(target.subSequence(start, end))
        val groups = actions.associate { it.path to original.groups.getValue(it.path) }
        val marker = NativeRubyPreparedSource(RubyTextProjection(local.toString(), ranges), local,
            original.paint, original.direction, groups, original.parentScript)
        target.setSpan(marker, start, end, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
    }

    init {
        val result = SpannableString(map.visual)
        for (value in source.getSpans(0, source.length, Any::class.java)) {
            if (value is NativeRubyPreparedSource || value is NativeClippedVisibleMetricMarker || value is NativeClippedParagraphDirection) continue
            val first = source.getSpanStart(value); val last = source.getSpanEnd(value)
            if (first < 0 || last < first) continue
            val start = map.toVisual(first); val end = map.toVisual(last)
            // A complete parent strut supplies hypothetical static context when no
            // in-flow line remains. Clipped child metrics never become that strut.
            val hypothetical = map.visual.isEmpty() && first == 0 && last == source.length &&
                (value is NativeRunLineMetrics && value.strut || value is ParagraphStyle)
            val pointKey = when (value) {
                is NativeAuthoredInlineMetrics -> value.clippedVisiblePoint
                is NativeAuthoredBaselineShift -> value.clippedVisiblePoint
                else -> null
            }
            val point = pointKey != null && first == last && points.any {
                it.start == first && it.end == last && it.value.key === pointKey }
            if (start == end && !hypothetical && !point) continue
            if (value is NativeAuthoredTextWrap && map.visual.isEmpty()) continue
            val copy = if (value is NativeAuthoredTextWrap) value.copy(sourceLineStarts =
                value.sourceLineStarts?.map(map::toVisual)?.distinct()) else nativeInlineStyleSpanCopy(value)
            val flags = if (hypothetical) (source.getSpanFlags(value) and Spanned.SPAN_POINT_MARK_MASK.inv()) or
                Spanned.SPAN_MARK_MARK else source.getSpanFlags(value)
            result.setSpan(copy, start, end, flags)
        }
        // Ordinary directional spans still use the established Ruby source compiler's
        // private isolates. A plain visible projection needs no structural marker.
        for (item in prepared) {
            val original = item.value
            val leaves = original.projection.ranges.filter { it.role != RubyTextRole.ClippedAbsolute &&
                it.role != RubyTextRole.ClippedText }
            val start = map.toVisual(item.start); val end = map.toVisual(item.end)
            if (start == end) continue
            val ranges = leaves.map { it.copy(start = map.toVisual(item.start + it.start) - start,
                end = map.toVisual(item.start + it.end) - start) }
            installVisibleGroups(result, start, end, original, ranges)
        }
        points.filter { it.start == it.end }.forEach { point ->
            val at = map.toVisual(point.start)
            result.setSpan(NativeClippedVisibleMetricMarker(point.value.key), at, at, Spanned.SPAN_MARK_MARK)
        }
        paragraphs.forEach { paragraph ->
            val start = map.toVisual(paragraph.start); val end = map.toVisual(paragraph.end)
            result.setSpan(NativeClippedParagraphDirection(paragraph.direction), start, end,
                if (start == end) Spanned.SPAN_MARK_MARK else Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        }
        visual = SpannedString(result)
    }

    fun visibleParagraphDirection(start: Int, end: Int,
        fallback: android.text.TextDirectionHeuristic): BidiResolvedDirection {
        nativeClippedParagraphDirectionAt(visual, start)?.let { return it }
        // The existing compiler isolates these original leaves. Their first strong
        // characters must not become the enclosing paragraph's fallback direction.
        val context = StringBuilder(visual.subSequence(start, end))
        nativeInlineRanges(visual, NativeRubyPreparedSource::class.java).forEach { prepared ->
            prepared.value.projection.ranges.forEach rangeLoop@ { range ->
                val span = range.span ?: return@rangeLoop
                if (!span.usesInlineDirectionIsolate() && span.citationMarker?.isolation == null) return@rangeLoop
                val first = maxOf(start, prepared.start + range.start)
                val last = minOf(end, prepared.start + range.end)
                for (at in first until last) if (context[at - start] != '\n') context.setCharAt(at - start, '\ufffc')
            }
        }
        return if (fallback.isRtl(context, 0, context.length)) BidiResolvedDirection.Rtl else BidiResolvedDirection.Ltr
    }

    fun hypothetical(occurrence: NativeClippedAbsoluteOccurrence): NativeClippedHypotheticalSource {
        val paragraph = paragraphByOccurrence[occurrence]
            ?: throw UnsupportedFloatLayout("Clipped hypothetical occurrence is not owned by this source")
        val first = paragraph.start
        val last = paragraph.end - if (paragraph.end > first && source[paragraph.end - 1] == '\n') 1 else 0
        val removed = paragraphOwners.getValue(first).filter { it !== occurrence }
        val localMap = NativeClippedSourceMap(source.subSequence(first, last).toString(),
            removed.map { NativeClippedSourceRange(it.start - first, it.end - first) })
        val target = SpannableString(localMap.visual)
        for (value in source.getSpans(first, last, Any::class.java)) {
            if (value is NativeRubyPreparedSource || value is NativeClippedVisibleMetricMarker) continue
            val a = maxOf(first, source.getSpanStart(value)); val b = minOf(last, source.getSpanEnd(value))
            val pointKey = when (value) {
                is NativeAuthoredInlineMetrics -> value.clippedVisiblePoint
                is NativeAuthoredBaselineShift -> value.clippedVisiblePoint
                else -> null
            }
            val visiblePoint = pointKey != null && source.getSpanStart(value) == source.getSpanEnd(value) &&
                points.any { it.start == source.getSpanStart(value) && it.end == source.getSpanEnd(value) &&
                    it.value.key === pointKey }
            if (a > b || a == b && !visiblePoint && removed.any { a in it.start..it.end }) continue
            val start = localMap.toVisual(a - first); val end = localMap.toVisual(b - first)
            if (start == end && a != b) continue
            val copy = if (value is NativeAuthoredTextWrap) value.copy(sourceLineStarts =
                value.sourceLineStarts?.filter { it in first..last }?.map { localMap.toVisual(it - first) })
                else nativeInlineStyleSpanCopy(value)
            target.setSpan(copy, start, end, source.getSpanFlags(value))
        }
        points.filter { it.start == it.end && it.start in first..last }.forEach { point ->
            val at = localMap.toVisual(point.start - first)
            target.setSpan(NativeClippedVisibleMetricMarker(point.value.key), at, at, Spanned.SPAN_MARK_MARK)
        }
        val start = localMap.toVisual(occurrence.start - first)
        val end = localMap.toVisual(occurrence.end - first)
        val declaring = occurrence.declaring
        fun mode(span: Span): NativeRubyScriptMode = when {
            span.superscript -> NativeRubyScriptMode.Super
            span.subscript -> NativeRubyScriptMode.Sub
            else -> NativeRubyScriptMode.Normal
        }
        val placement = nativeRubyBaselinePlacement(mode(occurrence.format.owner.span), declaring.baselineShift,
            declaring.localBaselineShift, occurrence.parentScript)
        val primary = NativePrimaryFontMetrics.from(declaring.paint).copy(baselineShift = placement.local)
        val children = prepared.flatMap { item -> item.value.projection.ranges.filter {
            it.role == RubyTextRole.ClippedText && item.start + it.start >= occurrence.start &&
                item.start + it.end <= occurrence.end
        }.map { range -> (item.start + range.start - occurrence.start) to checkNotNull(range.span) } }
        fun visibleMetricPoint(value: Any): Boolean {
            val key = when (value) {
                is NativeAuthoredInlineMetrics -> value.clippedVisiblePoint
                is NativeAuthoredBaselineShift -> value.clippedVisiblePoint
                else -> null
            } ?: return false
            val at = target.getSpanStart(value)
            return target.getSpanEnd(value) == at && points.any { point ->
                point.start == point.end && point.start in first..last && point.value.key === key &&
                    localMap.toVisual(point.start - first) == at
            }
        }
        val ownerSource = SpannableString(target.subSequence(start, end))
        target.getSpans(start, end, Any::class.java).filter(::visibleMetricPoint).forEach(ownerSource::removeSpan)
        val local = nativeRubyLocalSource(SpannedString(ownerSource), declaring.paint,
            placement.state, declaring.lineHeight, placement.local) { offset ->
            children.lastOrNull { it.first <= offset }?.second?.let(::mode) ?: placement.state.mode
        }
        local.getSpans(0, local.length, NativeRunLineMetrics::class.java).forEach(local::removeSpan)
        val metricCuts = (listOf(0, local.length) +
            local.getSpans(0, local.length, android.text.style.MetricAffectingSpan::class.java)
                .flatMap { listOf(local.getSpanStart(it), local.getSpanEnd(it)) }).distinct().sorted()
        metricCuts.zipWithNext().forEach { (a, b) ->
            if (a < b && local.getSpans(a, b, NativeAuthoredInlineMetrics::class.java).none {
                    local.getSpanStart(it) <= a && local.getSpanEnd(it) >= b }) {
                val measured = android.text.TextPaint(declaring.paint)
                local.getSpans(a, b, android.text.style.MetricAffectingSpan::class.java)
                    .forEach { it.updateMeasureState(measured) }
                local.setSpan(NativeRunLineMetrics(NativePrimaryFontMetrics.from(measured), declaring.lineHeight),
                    a, b, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
            }
        }
        fun localEffect(value: Any): Boolean = value is android.text.style.CharacterStyle ||
            value is NativeAuthoredInlineMetrics || value is NativeAuthoredBaselineShift ||
            value is NativeAuthoredUnderline || value is NativeAuthoredCursor ||
            value is NativeRunLineMetrics && !value.strut
        target.getSpans(start, end, Any::class.java).filter { localEffect(it) && !visibleMetricPoint(it) }.forEach { value ->
            val a = target.getSpanStart(value); val b = target.getSpanEnd(value)
            val flags = target.getSpanFlags(value)
            target.removeSpan(value)
            if (a < start) target.setSpan(nativeRubySpanCopy(value), a, start, flags)
            if (b > end) target.setSpan(nativeRubySpanCopy(value), end, b, flags)
        }
        local.getSpans(0, local.length, Any::class.java).filter(::localEffect).forEach { value ->
            target.setSpan(nativeRubySpanCopy(value), start + local.getSpanStart(value),
                start + local.getSpanEnd(value), local.getSpanFlags(value))
        }
        target.setSpan(NativeRunLineMetrics(primary, declaring.lineHeight, strut = true,
            includePrimaryInNormal = true, independentNormalStrut = true), start, end, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        // Retain the existing ordinary compiler's private isolates/citation policy.
        // Only this occurrence's real children become ordinary measurement ranges.
        for (item in prepared) {
            val a = maxOf(first, item.start); val b = minOf(last, item.end)
            if (a >= b) continue
            val localStart = localMap.toVisual(a - first); val localEnd = localMap.toVisual(b - first)
            if (localStart == localEnd) continue
            val ranges = item.value.projection.ranges.mapNotNull { range ->
                if (range.role == RubyTextRole.ClippedAbsolute) return@mapNotNull null
                val originalStart = item.start + range.start; val originalEnd = item.start + range.end
                if (originalStart >= b || originalEnd <= a || removed.any {
                        originalStart >= it.start && originalEnd <= it.end }) return@mapNotNull null
                range.copy(start = localMap.toVisual(maxOf(a, originalStart) - first) - localStart,
                    end = localMap.toVisual(minOf(b, originalEnd) - first) - localStart,
                    role = if (range.role == RubyTextRole.ClippedText) RubyTextRole.Text else range.role)
            }
            installVisibleGroups(target, localStart, localEnd, item.value, ranges)
        }
        target.setSpan(NativeClippedParagraphDirection(checkNotNull(occurrence.format.owner.span.clippedAbsolute).staticParentDirection),
            0, target.length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        return NativeClippedHypotheticalSource(SpannedString(target), start, end, first, last, primary)
    }

    companion object {
        fun create(source: Spanned): NativeClippedAbsoluteProjection? {
            val markers = nativeInlineRanges(source, NativeRubyPreparedSource::class.java)
            if (markers.none { it.value.projection.ranges.any { range -> range.role == RubyTextRole.ClippedAbsolute } }) return null
            val occurrences = mutableListOf<NativeClippedAbsoluteOccurrence>()
            val prepared = mutableListOf<Prepared>()
            for (item in markers) {
                val value = item.value
                if (item.end - item.start != value.projection.text.length ||
                    source.subSequence(item.start, item.end).toString() != value.projection.text)
                    throw UnsupportedFloatLayout("Clipped absolute source projection lost its occurrence")
                if (value.projection.ranges.any { it.role !in setOf(RubyTextRole.Text, RubyTextRole.ActionGroup,
                        RubyTextRole.ClippedAbsolute, RubyTextRole.ClippedText) } ||
                    value.visualOmissions.isNotEmpty() || value.visualSpaces.isNotEmpty() || value.protectedSpaces.isNotEmpty())
                    throw UnsupportedFloatLayout("Clipped absolute mixed structural source is unavailable")
                val structural = value.projection.ranges.filter {
                    it.role == RubyTextRole.ActionGroup || it.role == RubyTextRole.ClippedAbsolute
                }.sortedBy { it.start }
                // A visible action must survive as one complete original owner in both projections.
                if (structural.zipWithNext().any { (a, b) -> a.end > b.start } || structural.any { range ->
                        range.role == RubyTextRole.ActionGroup && (range.start == range.end ||
                            (range.start until range.end).any { value.projection.text[it] == '\n' })
                    }) throw UnsupportedFloatLayout("Clipped absolute source requires independent paragraph-local action groups")
                prepared += Prepared(item.start, item.end, value)
                for (range in value.projection.ranges.filter { it.role == RubyTextRole.ClippedAbsolute }) {
                    val declaring = value.groups[range.path]
                    val format = declaring?.clippedAbsolute
                        ?: throw UnsupportedFloatLayout("Clipped absolute declaring geometry is unavailable")
                    if (format.owner.span !== range.span || format.owner.path != range.path || range.start == range.end)
                        throw UnsupportedFloatLayout("Clipped absolute declaring occurrence changed")
                    occurrences += NativeClippedAbsoluteOccurrence(item.start + range.start, item.start + range.end, format,
                        checkNotNull(declaring), value.parentScript)
                }
            }
            if (occurrences.any { source.subSequence(it.start, it.end).any { c -> c == '\n' } })
                throw UnsupportedFloatLayout("Clipped hypothetical nowrap source contains a hard paragraph break")
            val sorted = occurrences.sortedBy { it.start }
            if (sorted.zipWithNext().any { (a, b) -> a.end > b.start })
                throw UnsupportedFloatLayout("Clipped absolute source occurrences overlap")
            return try { NativeClippedAbsoluteProjection(SpannedString(source), sorted.toList(), prepared.toList()) }
            catch (failure: IllegalArgumentException) {
                throw UnsupportedFloatLayout("Clipped absolute source boundary is unavailable: ${failure.message}")
            }
        }
    }
}

internal fun nativeClippedCoordinates(vararg values: Float) {
    if (values.any { !it.isFinite() || abs(it) > TablePixelLimit })
        throw UnsupportedFloatLayout("Clipped absolute geometry exceeds native coordinates")
}

/** Private formatting input. Raw glyph advances remain those of MeasuredText;
 * only this unpublished probe adds the signed inline margin allocation. */
internal class NativeClippedProbeAllocation(val start: Int, val end: Int,
    val margins: NativeClippedAbsoluteMargins) {
    init { require(start >= 0 && end > start) }
    fun protects(offset: Int): Boolean = offset > start && offset < end
    fun owns(first: Int, last: Int): Boolean = first <= start && last >= end
    fun flow(raw: Float, first: Int, last: Int): Float {
        val value = raw.toDouble() + if (owns(first, last)) margins.left.toDouble() + margins.right else 0.0
        if (!value.isFinite() || value < 0.0 || value > TablePixelLimit)
            throw UnsupportedFloatLayout("Clipped hypothetical signed inline advance is unavailable")
        return value.toFloat()
    }
}

internal data class NativeClippedStaticEdges(val contentLeft: Float, val contentRight: Float,
    val contentTop: Float, val marginLeft: Float, val marginRight: Float, val marginTop: Float)

/** Checked work accounting only. No unqualified record/owner limit is inferred
 * from the separate presentation-item budget. */
internal class NativeClippedProbeWork {
    var used = 0L
        private set
    fun charge(utf16: Long) {
        if (utf16 < 0 || utf16 > Long.MAX_VALUE - used)
            throw UnsupportedFloatLayout("Clipped hypothetical native shaping work exceeds checked accounting")
        used += utf16
    }
}

internal data class NativeClippedHypotheticalSource(val source: Spanned, val start: Int, val end: Int,
    val originalParagraphStart: Int, val originalParagraphEnd: Int, val primary: NativePrimaryFontMetrics)

/** The same original paragraph is measured with one owner restored. Nothing from
 * the hypothetical paragraph is installed in public flow, selection or actions. */
internal fun nativeClippedStaticEdges(input: NativeClippedHypotheticalSource,
    occurrence: NativeClippedAbsoluteOccurrence, paint: android.text.TextPaint, width: Int,
    alignment: android.text.Layout.Alignment, direction: android.text.TextDirectionHeuristic,
    lineSpacingExtra: Float, lineSpacingMultiplier: Float, carried: List<NativeFloatExclusion>,
    insets: NativeTextInsets, includeFontPadding: Boolean, exactAvailableWidth: Float?,
    exactParagraphInsets: Boolean, paragraphTop: Float, work: NativeClippedProbeWork): NativeClippedStaticEdges {
    // This ordinary-only private projection inserts at most one isolate pair per
    // retained range. Charge both compiler input and native shaping before either.
    val rangeCount = input.source.getSpans(0, input.source.length, NativeRubyPreparedSource::class.java)
        .sumOf { it.projection.ranges.size.toLong() }
    val nativeBound = input.source.length.toLong() + 2L * rangeCount
    work.charge(input.source.length.toLong())
    work.charge(nativeBound)
    val compiled = nativeRubyLayout(input.source, paint, direction, exactAdvances = true)
    val first = compiled?.nativeOffset(input.start) ?: input.start
    val last = compiled?.nativeOffset(input.end, endAffinity = true) ?: input.end
    val native = SpannableString(compiled?.native ?: input.source)
    if (native.length.toLong() > nativeBound)
        throw UnsupportedFloatLayout("Clipped hypothetical compiler exceeded its accounted source expansion")
    val allocation = NativeClippedProbeAllocation(first, last, occurrence.format.margins)
    native.setSpan(allocation, first, last, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
    val localCarry = carried.map { it.copy(outer = it.outer.translated(0f, -paragraphTop)) }
    val plan = NativeFloatRowPlan.build(native, paint, width, emptyList(), alignment, direction,
        lineSpacingExtra, lineSpacingMultiplier, false, localCarry, insets, null,
        includeFontPadding, exactAvailableWidth, exactParagraphInsets)
    val line = plan.lineAt(first)
    val row = plan.rows[line]
    if (!allocation.owns(row.start, row.end))
        throw UnsupportedFloatLayout("Clipped hypothetical owner was fragmented by native fitting")
    val left = plan.paragraphLeft + plan.flow.left[line]
    val right = plan.paragraphRight - plan.flow.right[line]
    val physical = when (row.alignment) {
        android.text.Layout.Alignment.ALIGN_CENTER -> NativeFloatRowPhysicalAlignment.Center
        android.text.Layout.Alignment.ALIGN_NORMAL -> if (row.paragraph.rtl)
            NativeFloatRowPhysicalAlignment.Right else NativeFloatRowPhysicalAlignment.Left
        android.text.Layout.Alignment.ALIGN_OPPOSITE -> if (row.paragraph.rtl)
            NativeFloatRowPhysicalAlignment.Left else NativeFloatRowPhysicalAlignment.Right
        else -> throw UnsupportedFloatLayout("Clipped hypothetical paragraph alignment is unavailable")
    }
    val fullFlow = allocation.flow(row.advance, row.start, row.end)
    val origin = nativeFloatRowOrigin(left, maxOf(left, right), row.visibleAdvance, physical) -
        if (row.paragraph.rtl) fullFlow - row.visibleAdvance else 0f
    var prefix = 0.0
    val pieces = mutableListOf<Pair<Double, Double>>()
    for (run in row.glyphs) {
        val a = maxOf(first, run.start); val b = minOf(last, run.end)
        if (a < b) {
            if (run.image != null || run.column != null)
                throw UnsupportedFloatLayout("Clipped hypothetical content is not an ordinary inline fragment")
            fun boundary(offset: Int): Boolean = offset == run.start || offset == run.end ||
                run.cursor(run.cursor(offset, false), true) == offset
            if (!boundary(a) || !boundary(b))
                throw UnsupportedFloatLayout("Clipped hypothetical margin cuts a native cluster")
            val x = run.advanceTo(a); val y = run.advanceTo(b)
            val firstX = if (run.rtl) run.advance - y else x
            val lastX = if (run.rtl) run.advance - x else y
            pieces += prefix + firstX to prefix + lastX
        }
        prefix += run.advance.toDouble()
    }
    if (pieces.isEmpty()) throw UnsupportedFloatLayout("Clipped hypothetical first inline fragment is unavailable")
    val ordered = pieces.sortedBy { it.first }
    // A single nowrap inline owner may contain several native bidi/metric runs,
    // but this first-fragment proof cannot bridge intervening outside content.
    if (ordered.zipWithNext().any { (a, b) ->
            !nativeFloatRowSameAdvance(a.second.toFloat(), b.first.toFloat(), row.glyphs.size) })
        throw UnsupportedFloatLayout("Clipped hypothetical owner has disjoint visual fragments")
    val contentLeft = (origin.toDouble() + ordered.first().first + allocation.margins.left).toFloat()
    val contentRight = (origin.toDouble() + ordered.last().second + allocation.margins.left).toFloat()
    val contentTop = paragraphTop + plan.flow.baselines[line] + input.primary.ascent + input.primary.baselineShift
    val marginLeft = contentLeft - allocation.margins.left
    val marginRight = contentRight + allocation.margins.right
    val marginTop = contentTop - allocation.margins.top
    nativeClippedCoordinates(contentLeft, contentRight, contentTop, marginLeft, marginRight, marginTop)
    return NativeClippedStaticEdges(contentLeft, contentRight, contentTop, marginLeft, marginRight, marginTop)
}

/** Only the private clipped probe calls this fitter. Native glyphs and their full
 * metric/bidi contexts are unchanged; legal cuts omit the protected owner interior. */
internal fun nativeClippedProbeRows(source: Spanned, paint: android.text.TextPaint,
    runs: NativeFloatRowRuns, width: Float, left: IntArray, right: IntArray,
    wrap: NativeTextWrapPlan?, alignment: android.text.Layout.Alignment,
    allocation: NativeClippedProbeAllocation): List<NativeFloatPlannedRow> {
    if (runs.paragraphs.size != 1 || allocation.end > runs.paragraphs.single().measuredEnd)
        throw UnsupportedFloatLayout("Clipped hypothetical nowrap owner crosses a hard paragraph")
    val paragraph = runs.paragraphs.single()
    allocation.flow(checkNotNull(paragraph.measured).getWidth(allocation.start - paragraph.start,
        allocation.end - paragraph.start), allocation.start, allocation.end)
    val iterator = java.text.BreakIterator.getLineInstance(paint.textLocale).apply { setText(source.toString()) }
    val ordinary = source.getSpans(0, source.length, NativeRubyBreaks::class.java).singleOrNull()?.boundaries
        ?: buildList { var at = iterator.first(); while (at != java.text.BreakIterator.DONE) {
            add(at); at = iterator.next() } }
    val emergency by lazy { nativeFloatRowEmergencyEnds(runs) }
    val citationRanges = nativeInlineRanges(source, NativeCitationMarkerSpan::class.java)
        .filter { it.value.marker.nowrap }
    val paragraphAlignment = source.getSpans(0, source.length, android.text.style.AlignmentSpan::class.java)
        .filter { source.getSpanStart(it) <= paragraph.start && source.getSpanEnd(it) >= paragraph.end }
        .lastOrNull()?.alignment ?: alignment
    fun raw(first: Int, last: Int): Float = if (first >= last) 0f else
        checkNotNull(paragraph.measured).getWidth(first - paragraph.start, last - paragraph.start)
    fun fitEnd(first: Int, last: Int): Int {
        var end = last
        while (end > first && nativeFloatRowLineEndSpace(source[end - 1]) &&
            !(end > allocation.start && end <= allocation.end)) end--
        return end
    }
    fun legal(cut: Int): Boolean = !allocation.protects(cut) &&
        citationRanges.none { cut > it.start && cut < it.end } &&
        wrap?.words.orEmpty().none { it.normal && cut > it.start && cut < it.visibleEnd }
    fun flow(first: Int, last: Int): Float = allocation.flow(raw(first, last), first, last)
    val result = mutableListOf<NativeFloatPlannedRow>()
    var start = paragraph.start
    while (start < paragraph.end) {
        val ordinal = result.size
        val limit = maxOf(0f, width - left[minOf(ordinal, left.lastIndex)] - right[minOf(ordinal, right.lastIndex)])
        val cuts = (ordinary.filter { it > start && it < paragraph.end && legal(it) } + paragraph.end).distinct().sorted()
        val fitting = if (wrap?.noWrap?.paragraphAt(start) != null) paragraph.end else
            cuts.lastOrNull { flow(start, fitEnd(start, it)) <= limit }
        val end = fitting ?: run {
            val first = cuts.first()
            val normal = wrap?.words?.any { it.normal && start >= it.start && start < it.visibleEnd } == true
            val emergencyCuts = if (normal) emptyList() else emergency.filter { it > start && it <= first && legal(it) }.sorted()
            val fit = emergencyCuts.lastOrNull { flow(start, fitEnd(start, it)) <= limit }
            if (fit != null) fit else {
                val selected = emergencyCuts.firstOrNull() ?: first
                selected
            }
        }
        if (end <= start || end > paragraph.end)
            throw UnsupportedFloatLayout("Clipped hypothetical fitting lost its source endpoints")
        val visible = if (end == source.length) end else fitEnd(start, end)
        val glyphs = runs.visualRuns(paragraph, start, end, visible)
        val advance = nativeFloatRowSum(glyphs.map { it.advance })
        if (!nativeFloatRowSameAdvance(advance, raw(start, end), glyphs.size))
            throw UnsupportedFloatLayout("Clipped hypothetical glyph replay differs from native measurement")
        val fm = paint.fontMetrics
        var natural = NativeUsedLineMetrics(fm.ascent, fm.descent)
        var padded = NativeUsedLineMetrics(fm.top, fm.bottom)
        glyphs.forEach { natural = natural.including(it.natural); padded = padded.including(it.paddedNatural) }
        // The first indivisible unit is stable across exclusion passes. Do not
        // move a breakable prefix merely because its later owner needs more room.
        val firstUnit = emergency.filter { it > start && it <= end && legal(it) && raw(start, it) > 0f }
            .minOrNull() ?: end
        val required = if (allocation.owns(start, firstUnit) ||
            citationRanges.any { start <= it.start && firstUnit >= it.end }) flow(start, fitEnd(start, firstUnit)) else null
        result += NativeFloatPlannedRow(paragraph, paragraphAlignment, start, end, visible, glyphs,
            advance, flow(start, visible), flow(start, fitEnd(start, end)), natural, padded,
            requiredFlowWidth = required)
        start = end
    }
    return result
}
