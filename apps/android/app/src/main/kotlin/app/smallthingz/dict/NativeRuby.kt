package app.smallthingz.dict

import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.RectF
import android.text.Layout
import android.text.PrecomputedText
import android.text.SpannableString
import android.text.SpannableStringBuilder
import android.text.Spanned
import android.text.SpannedString
import android.text.StaticLayout
import android.text.TextDirectionHeuristic
import android.text.TextDirectionHeuristics
import android.text.TextPaint
import android.text.style.CharacterStyle
import android.text.style.MetricAffectingSpan
import android.text.style.LineBackgroundSpan
import android.text.style.ParagraphStyle
import android.text.style.ReplacementSpan
import java.text.BreakIterator
import kotlin.math.ceil

/** Resolved from the actual declaring source owner, independently of every child run.
 * baselineShift is this font's native SCRIPT default in the original inline basis.
 * A numeric policy is owner-local, overrides that owner's script delta, and never
 * cancels placement inherited from an ancestor. */
internal class NativeRubyGroupFormat(
    paint: TextPaint,
    val direction: TextDirectionHeuristic,
    val lineHeight: NativeLineHeightPolicy,
    val baselineShift: Float = 0f,
    val wrap: TextWrap? = null,
    val underline: NativeAuthoredUnderline? = null,
    val cursor: InlineCursor? = null,
    val sourceDirection: String = "",
    val localBaselineShift: Float? = null,
    val padding: NativeInlinePaddingEdges? = null,
    val actionPaint: NativeMissingLinkPaint? = null,
    val actionOwner: NativeInlineActionOwner? = null,
    val box: NativeInlineBoxFormat? = null,
    val clippedAbsolute: NativeClippedAbsoluteFormat? = null,
) {
    val paint = TextPaint(paint)
    init {
        require(baselineShift.isFinite() && kotlin.math.abs(baselineShift) <= TablePixelLimit)
        require(this.paint.baselineShift == 0) { "Ruby compound displacement must be applied once" }
        require(sourceDirection in setOf("", "ltr", "rtl", "auto"))
        require(localBaselineShift == null || localBaselineShift.isFinite() && kotlin.math.abs(localBaselineShift) <= TablePixelLimit)
    }
}

/** Physical edges keep the declaring font's fractional em resolution. A zero-size
 * font may resolve a positive authored em edge to zero without losing the owner. */
internal data class NativeInlinePaddingEdges(val left: Float, val right: Float) {
    init {
        require(left.isFinite() && right.isFinite() && left >= 0f && right >= 0f)
        if (left.toDouble() + right > TablePixelLimit)
            throw UnsupportedFloatLayout("Inline padding exceeds native coordinates")
    }
}

internal enum class NativeRubyScriptMode { Normal, Super, Sub }
internal data class NativeRubyScriptState(val mode: NativeRubyScriptMode = NativeRubyScriptMode.Normal,
    val applied: Float = 0f)
internal data class NativeRubyBaselinePlacement(val local: Float, val state: NativeRubyScriptState)

/** Effective script mode is inherited independently from its native font-dependent
 * default. A numeric owner suppresses that node's default, not an ancestor's placement. */
internal fun nativeRubyBaselinePlacement(mode: NativeRubyScriptMode, defaultShift: Float,
    numeric: Float?, parent: NativeRubyScriptState): NativeRubyBaselinePlacement {
    require(defaultShift.isFinite() && parent.applied.isFinite() && (numeric == null || numeric.isFinite()))
    val local = numeric ?: if (mode == parent.mode) 0f else defaultShift - parent.applied
    if (kotlin.math.abs(local) > TablePixelLimit)
        throw UnsupportedFloatLayout("Ruby local baseline exceeds native coordinates")
    return NativeRubyBaselinePlacement(local, NativeRubyScriptState(mode,
        if (numeric != null || mode == parent.mode) parent.applied else defaultShift))
}

private fun nativeRubyScriptMode(superscript: Boolean, subscript: Boolean): NativeRubyScriptMode = when {
    superscript -> NativeRubyScriptMode.Super
    subscript -> NativeRubyScriptMode.Sub
    else -> NativeRubyScriptMode.Normal
}

private fun nativeRubyScriptMode(range: RubyTextRange): NativeRubyScriptMode = when (range.role) {
    RubyTextRole.Base -> checkNotNull(range.base).owner.font.let { nativeRubyScriptMode(it.superscript, it.subscript) }
    RubyTextRole.Annotation -> checkNotNull(range.annotation).owner.font.let { nativeRubyScriptMode(it.superscript, it.subscript) }
    else -> checkNotNull(range.span).let { nativeRubyScriptMode(it.superscript, it.subscript) }
}

/** A data-only span over exactly [projection.text]. The source has no layout-only tokens.
 * Anonymous-flow concatenation retains this original index space; native shaping owns its
 * private visual projection. No independent action owner or cache is introduced here. */
internal class NativeRubyPreparedSource(
    val projection: RubyTextProjection,
    source: Spanned,
    paint: TextPaint,
    val direction: TextDirectionHeuristic,
    groups: Map<String, NativeRubyGroupFormat>,
    val parentScript: NativeRubyScriptState = NativeRubyScriptState(),
    visualOmissions: List<Pair<Int, Int>> = emptyList(),
    visualSpaces: Set<Int> = emptySet(),
    visualSpaceNeighbors: Map<Int, Pair<Int?, Int?>> = emptyMap(),
    protectedSpaces: Set<Int> = emptySet(),
) {
    val source: Spanned = SpannedString(source)
    val paint = TextPaint(paint)
    val groups = groups.toMap()
    val visualOmissions = visualOmissions.toList()
    val visualSpaces = visualSpaces.toSet()
    val visualSpaceNeighbors = visualSpaceNeighbors.toMap()
    val protectedSpaces = protectedSpaces.toSet()
    // Definite child layout is independent of outer fitting bands. Cache only within
    // this original immutable source/font preparation; copying it starts a new epoch.
    private val atomicChildren = mutableMapOf<Pair<String, Boolean>, NativeFloatGeometry>()
    internal fun atomicChild(path: String, rtl: Boolean, create: () -> NativeFloatGeometry): NativeFloatGeometry =
        atomicChildren.getOrPut(path to rtl, create)
    init {
        require(this.source.toString() == projection.text) { "Ruby source must keep its graphical UTF-16 text" }
        require(parentScript.applied.isFinite() && kotlin.math.abs(parentScript.applied) <= TablePixelLimit)
        require(visualOmissions.all { (first, last) -> first >= 0 && last > first && last <= source.length &&
            source.subSequence(first, last).all { it in " \t\r\n" } } &&
            visualOmissions.zipWithNext().all { (a, b) -> a.second < b.first })
        require(visualSpaces.all { it in source.indices && source[it] in " \t\r\n" &&
            !nativeRubyOmitted(it, visualOmissions) })
        require(visualSpaceNeighbors.keys.all { it in visualSpaces } && protectedSpaces.all { it in visualSpaces })
        require(projection.ranges.all { it.start >= 0 && it.end >= it.start && it.end <= source.length })
        require(projection.ranges.map { it.path }.distinct().size == projection.ranges.size)
        require(projection.ranges.filter { it.role in setOf(RubyTextRole.Owner, RubyTextRole.Base,
            RubyTextRole.Annotation, RubyTextRole.PaddingGroup, RubyTextRole.ActionGroup, RubyTextRole.BoxGroup) }.all { it.path in groups }) { "Ruby declaring group context is missing" }
        require(this.source.getSpans(0, this.source.length, NativeRubyPreparedSource::class.java).isEmpty()) {
            "A Ruby preparation cannot contain itself"
        }
    }
}

private fun nativeRubyOmitted(offset: Int, omissions: List<Pair<Int, Int>>): Boolean {
    var first = 0; var last = omissions.size
    while (first < last) {
        val middle = (first + last) ushr 1
        val range = omissions[middle]
        if (offset < range.first) last = middle else if (offset >= range.second) first = middle + 1 else return true
    }
    return false
}

private fun nativeRubyBidiControl(char: Char): Boolean = android.icu.lang.UCharacter.hasBinaryProperty(
    char.code, android.icu.lang.UProperty.BIDI_CONTROL)

/** Collapse only a real same-level whitespace chain. Annotation source order never
 * supplies base-side context; hidden readings and segment boundaries split levels. */
private data class NativeRubyGapProjection(val omissions: List<Pair<Int, Int>>, val spaces: Set<Int>,
    val neighbors: Map<Int, Pair<Int?, Int?>>)

private fun nativeRubyGapOmissions(prepared: NativeRubyPreparedSource, owner: RubyTextRange): NativeRubyGapProjection {
    val projection = prepared.projection
    val source = projection.text
    val removed = prepared.visualOmissions.flatMap { (first, last) -> (first until last).toList() }.toMutableSet()
    val spaces = prepared.visualSpaces.toMutableSet()
    val neighbors = prepared.visualSpaceNeighbors.toMutableMap()
    val gapOffsets = mutableSetOf<Int>()
    fun gap(path: String): List<Int> = projection.ranges.filter {
        it.path.startsWith(path + "/gapBefore/") && it.span != null
    }.flatMap { range ->
        nativeRubyGapCollapse(source.substring(range.start, range.end), false, false, false, false)
        (range.start until range.end).toList().also { gapOffsets.addAll(it) }
    }
    fun body(range: RubyTextRange): List<Int> = projection.ranges.filter { leaf ->
        leaf.span != null && leaf.role !in setOf(RubyTextRole.Owner, RubyTextRole.PaddingGroup,
            RubyTextRole.ActionGroup, RubyTextRole.BoxGroup) && leaf.path.startsWith(range.path + "/") &&
            !leaf.path.removePrefix(range.path).contains("/annotations/")
    }.flatMap { (it.start until it.end).toList() }
    fun collapse(sequence: List<Int>) {
        val visible = sequence.filter { it !in removed && !nativeRubyBidiControl(source[it]) }
        var index = 0
        while (index < visible.size) {
            if (source[visible[index]] !in " \t\r\n") { index++; continue }
            val first = index
            while (index < visible.size && source[visible[index]] in " \t\r\n") index++
            val chain = visible.subList(first, index)
            if (chain.none { it in gapOffsets }) continue
            val raw = buildString { chain.forEach { append(source[it]) } }
            val kept = nativeRubyGapCollapse(raw, false, false, false, false).sourceOffset?.let { chain[it] }
            if (kept != null) {
                spaces += kept
                neighbors[kept] = visible.getOrNull(first - 1) to visible.getOrNull(index)
            }
            chain.filter { it != kept }.forEach(removed::add)
        }
    }
    val segments = projection.ranges.filter { it.role == RubyTextRole.Segment &&
        it.path.substringBeforeLast("/segments/", "") == owner.path + "/ruby" }
    val bases = mutableListOf<Int>()
    segments.forEach { segmentRange ->
        bases += gap(segmentRange.path)
        val segment = checkNotNull(segmentRange.segment)
        segment.bases.indices.forEach { index ->
            val range = projection.ranges.single { it.role == RubyTextRole.Base &&
                it.path == segmentRange.path + "/bases/$index" }
            bases += gap(range.path)
            bases += body(range)
        }
        segment.annotations.withIndex().groupBy { it.value.level }.values.forEach { level ->
            var sequence = mutableListOf<Int>()
            var hasPrevious = false
            level.forEach { indexed ->
                val range = projection.ranges.singleOrNull { it.role == RubyTextRole.Annotation &&
                    it.path == segmentRange.path + "/annotations/${indexed.index}" }
                if (range == null) {
                    collapse(sequence); sequence = mutableListOf(); hasPrevious = false
                } else {
                    val preceding = gap(range.path)
                    if (!hasPrevious) removed.addAll(preceding) else sequence.addAll(preceding)
                    sequence.addAll(body(range))
                    hasPrevious = true
                }
            }
            collapse(sequence)
        }
    }
    collapse(bases)
    val omissions = buildList<Pair<Int, Int>> {
        removed.sorted().forEach { offset ->
            val previous = lastOrNull()
            if (previous != null && previous.second == offset) {
                removeAt(lastIndex); add(previous.first to offset + 1)
            } else add(offset to offset + 1)
        }
    }
    return NativeRubyGapProjection(omissions, spaces.filterNot { it in removed }.toSet(),
        neighbors.filterKeys { it !in removed })
}

internal data class NativeRubyWidthConstraint(val first: Int, val count: Int, val advance: Float)

/** Resolve shorter spanning constraints first. The first covered base's preceding gap is
 * outside that annotation; retained gaps between covered bases participate in its allocation. */
internal fun nativeRubyColumnWidths(base: List<Float>, gaps: List<Float>,
    annotations: List<NativeRubyWidthConstraint>): List<Float> {
    require(base.size == gaps.size && base.isNotEmpty())
    require((base + gaps).all { it.isFinite() && it >= 0f && it <= TablePixelLimit })
    annotations.forEach { require(it.first >= 0 && it.count > 0 &&
        it.first <= base.size - it.count && it.advance.isFinite() && it.advance >= 0f &&
        it.advance <= TablePixelLimit) }
    val widths = base.map(Float::toDouble).toMutableList()
    annotations.withIndex().sortedWith(compareBy({ it.value.count }, { it.index })).forEach { indexed ->
        val constraint = indexed.value
        val last = constraint.first + constraint.count
        val current = (constraint.first until last).sumOf { widths[it] } +
            (constraint.first + 1 until last).sumOf { gaps[it].toDouble() }
        val extra = (constraint.advance - current).coerceAtLeast(0.0) / constraint.count
        for (index in constraint.first until last) widths[index] += extra
    }
    return widths.map { value ->
        if (!value.isFinite() || value > TablePixelLimit)
            throw UnsupportedFloatLayout("Ruby column allocation exceeds native geometry")
        value.toFloat()
    }
}

internal data class NativeRubyAroundSpacing(val edge: Float, val interior: Float)

/** Only native-shape-verified typographic opportunities are counted. With none, the intact
 * shaped row is centered; no Latin/Bopomofo or ligature boundary is manufactured. */
internal fun nativeRubyAroundSpacing(advance: Float, allocation: Float,
    opportunities: Int): NativeRubyAroundSpacing {
    require(advance.isFinite() && allocation.isFinite() && advance >= 0f && allocation >= advance)
    require(opportunities >= 0)
    val unit = (allocation.toDouble() - advance) / (opportunities.toDouble() + 1.0)
    return NativeRubyAroundSpacing((unit / 2.0).toFloat(), unit.toFloat())
}

/** Base alignment stays unchanged. Extra leading supplies only the separation missing from
 * the complete container extent across three identical lines; glyph ink is a separate extent. */
internal fun nativeRubyAdditionalLeading(base: NativeUsedLineMetrics,
    container: NativeUsedLineMetrics, above: Boolean, below: Boolean): NativeUsedLineMetrics {
    if (!above && !below) return base
    val extra = (container.height.toDouble() - base.height).coerceAtLeast(0.0)
    if (extra == 0.0) return base
    val before = if (above) (base.top.toDouble() - container.top).coerceAtLeast(0.0) else 0.0
    val after = if (below) (container.bottom.toDouble() - base.bottom).coerceAtLeast(0.0) else 0.0
    val upper = when {
        !above -> 0.0
        !below -> extra
        before + after > 0.0 -> extra * before / (before + after)
        else -> extra / 2.0
    }
    val top = base.top.toDouble() - upper
    val bottom = base.bottom.toDouble() + extra - upper
    if (!top.isFinite() || !bottom.isFinite() || kotlin.math.abs(top) > TablePixelLimit ||
        kotlin.math.abs(bottom) > TablePixelLimit)
        throw UnsupportedFloatLayout("Ruby additional leading exceeds native geometry")
    return NativeUsedLineMetrics(top.toFloat(), bottom.toFloat())
}

/** Base-only break opportunities, expressed in the private native buffer. Reading order
 * never enters the paragraph's ordinary word-break decision. */
internal class NativeRubyBreaks(val boundaries: List<Int>)

internal data class NativeRubyFragmentKey(val path: String, val base: Int, val offset: Int)
internal enum class NativeRubyBreakStage { Ordinary, Emergency }
internal class NativeRubyBands(val width: Float, val observed: Map<NativeRubyFragmentKey, Float> = emptyMap(),
    val allowEmergency: Boolean = true) {
    init { require(width.isFinite() && width >= 0f) }
    fun widthAt(key: NativeRubyFragmentKey): Float = observed[key] ?: width
}

/** A private child retains its complete native paragraph and styles. Only the line
 * fitting indents vary; native endpoints must agree with the jointly selected cuts. */
internal class NativeRubyLinePlan(ends: List<Int>, advances: List<Float>, allowEmptyTerminal: Boolean = false) {
    internal val ends = ends.toList()
    internal val advances = advances.toList()
    init {
        require(ends.isNotEmpty() && ends.size == advances.size && ends.first() > 0 &&
            ends.zipWithNext().withIndex().all { (index, pair) -> pair.first < pair.second ||
                allowEmptyTerminal && index == ends.size - 2 && pair.first == pair.second })
        require(advances.all { it.isFinite() && it >= 0f && it <= TablePixelLimit })
    }
    fun indents(width: Int, rtl: Boolean): Pair<IntArray, IntArray> {
        val fit = IntArray(advances.size + 1) { index ->
            if (index == advances.size) 0 else width - ceil(advances[index].toDouble()).toInt()
        }
        return if (rtl) fit to IntArray(fit.size) else IntArray(fit.size) to fit
    }
    fun validate(layout: android.text.StaticLayout) {
        if (layout.lineCount != ends.size || ends.indices.any { layout.getLineEnd(it) != ends[it] })
            throw UnsupportedFloatLayout("Ruby joint cuts cannot be represented by the native full-context line fitter")
    }
}

/** Keep an already chosen joint fragment boundary on a real native line. A fitting
 * indent changes neither the physical float lane nor the paragraph's shaping context. */
internal class NativeRubyFragmentLines(source: Spanned) {
    private val ends = nativeInlineRanges(source, NativeRubyColumn::class.java)
        .filter { it.value.continues }.map { it.end }.toSet()

    fun fit(layout: StaticLayout, measured: PrecomputedText, physicalLeft: IntArray,
        physicalRight: IntArray, ordinary: Pair<IntArray, IntArray>?): Pair<IntArray, IntArray>? {
        if (ends.isEmpty()) return ordinary
        val left = (ordinary?.first ?: physicalLeft).copyOf()
        val right = (ordinary?.second ?: physicalRight).copyOf()
        for (line in 0 until layout.lineCount) {
            val start = layout.getLineStart(line); val end = layout.getLineEnd(line)
            val selected = ends.filter { it > start && it <= end }.minOrNull() ?: continue
            val advance = measured.getWidth(start, selected)
            if (!advance.isFinite() || advance < 0f || advance > TablePixelLimit)
                throw UnsupportedFloatLayout("Ruby joint line width exceeds native coordinates")
            val remaining = layout.width.toLong() - physicalLeft[line] - physicalRight[line]
            val extra = ceil(advance.toDouble()).toLong() - remaining
            val ltr = layout.getParagraphDirection(line) > 0
            val align = layout.getParagraphAlignment(line)
            val pair = when (align) {
                Layout.Alignment.ALIGN_NORMAL -> if (ltr) physicalLeft[line].toLong() to physicalRight[line].toLong() - extra
                    else physicalLeft[line].toLong() - extra to physicalRight[line].toLong()
                Layout.Alignment.ALIGN_OPPOSITE -> if (ltr) physicalLeft[line].toLong() - extra to physicalRight[line].toLong()
                    else physicalLeft[line].toLong() to physicalRight[line].toLong() - extra
                Layout.Alignment.ALIGN_CENTER -> {
                    val half = if (extra >= 0) (extra + 1) / 2 else extra / 2
                    physicalLeft[line].toLong() - half to physicalRight[line].toLong() - half
                }
                else -> throw UnsupportedFloatLayout("Ruby joint line alignment is unavailable")
            }
            if (kotlin.math.abs(pair.first) > TablePixelLimit || kotlin.math.abs(pair.second) > TablePixelLimit)
                throw UnsupportedFloatLayout("Ruby joint fit exceeds native coordinates")
            left[line] = pair.first.toInt(); right[line] = pair.second.toInt()
        }
        return left to right
    }

    fun validate(layout: StaticLayout) {
        val actual = (0 until layout.lineCount).map { layout.getLineEnd(it) }.toSet()
        if (!actual.containsAll(ends))
            throw UnsupportedFloatLayout("Ruby joint fragment did not end at a real native line")
    }
}

internal data class NativeRubyChild(
    val start: Int, val end: Int, val geometry: FloatTextGeometry,
    val x: Float, val y: Float,
    val ranges: List<Pair<Int, Int>> = listOf(start to end),
)

internal data class NativeRubyCursorRegion(val bounds: NativeFloatBounds, val cursor: InlineCursor)
internal data class NativeRubyGapPaint(val format: NativeRubyGroupFormat,
    val baselineShift: Float, val content: NativeUsedLineMetrics)
internal data class NativeRubyGapAllocation(val line: Int, val left: Float, val right: Float, val baseline: Float)

/** Keep a native SPACE as a shaping separator at a chosen soft line end, while
 * removing its advance and run box. Public source bytes and break affinity stay exact. */
private class NativeRubyTrimmedGap : MetricAffectingSpan(), NativeInlineSafePaintSpan {
    override fun updateMeasureState(paint: TextPaint) {
        paint.textSize = 0f
        paint.textScaleX = 0f
        paint.baselineShift = 0
    }
    override fun updateDrawState(paint: TextPaint) {
        updateMeasureState(paint)
        paint.color = 0
        paint.bgColor = 0
        paint.isUnderlineText = false
        paint.isStrikeThruText = false
    }
}

private class NativeRubyGapInk : MetricAffectingSpan(), NativeInlineSafePaintSpan {
    override fun updateMeasureState(paint: TextPaint) = Unit
    override fun updateDrawState(paint: TextPaint) {
        paint.bgColor = 0
        paint.isUnderlineText = false
        paint.isStrikeThruText = false
    }
}

private fun nativeRubyGapLeaf(source: Spanned, base: TextPaint): NativeRubyGapPaint {
    require(source.isNotEmpty())
    if (source.getSpans(0, source.length, LineBackgroundSpan::class.java).isNotEmpty())
        throw UnsupportedFloatLayout("Ruby gap line-background owner is unavailable")
    val paint = TextPaint(base)
    source.getSpans(0, 1, CharacterStyle::class.java).forEach { it.updateDrawState(paint) }
    val shift = source.getSpans(0, 1, NativeAuthoredBaselineShift::class.java).lastOrNull()?.shift
        ?: paint.baselineShift.toFloat()
    paint.baselineShift = 0
    val primary = NativePrimaryFontMetrics.from(paint)
    val underline = source.getSpans(0, 1, NativeAuthoredUnderline::class.java).lastOrNull()
    val cursor = source.getSpans(0, 1, NativeAuthoredCursor::class.java).lastOrNull()?.cursor
    return NativeRubyGapPaint(NativeRubyGroupFormat(paint, TextDirectionHeuristics.LTR,
        NativeLineHeightPolicy.Pixels(primary.descent - primary.ascent), underline = underline, cursor = cursor),
        shift, NativeUsedLineMetrics(primary.ascent, primary.descent))
}

/** Rebuild from the original row allocations. Annotation-induced slack is retained;
 * only the new width is apportioned across the complete proved base hierarchy. */
internal class NativeRubyColumnHierarchy(
    private val widths: List<Float>, private val gaps: List<Float>,
    private val retainedGaps: List<Boolean>,
    private val physicalOrder: List<Int>,
    private val profiles: () -> List<NativeRubySpacingProfile>,
    private val rebuild: (List<Float>, List<NativeRubySpacingIncrement>) -> NativeRubyColumn,
) {
    init {
        require(widths.isNotEmpty() && widths.size == gaps.size && gaps.first() == 0f &&
            retainedGaps.size == widths.size && !retainedGaps.first())
        require(physicalOrder.sorted() == widths.indices.toList())
    }
    private val originalProfiles by lazy(profiles)
    private data class Item(val base: Int?, val profile: NativeRubySpacingProfile, val width: Float)
    private val items by lazy {
        buildList {
            widths.indices.forEach { index ->
                if (retainedGaps[index]) add(Item(null, NativeRubySpacingProfile.retainedGap(), gaps[index]))
                add(Item(index, originalProfiles[index], widths[index]))
            }
        }
    }
    private val orderedItems by lazy {
        // Source boxes follow the owning base level's physical direction; each
        // original row profile separately retains its measured inner edge order.
        if (physicalOrder == widths.indices.toList()) items else {
            require(physicalOrder == widths.indices.reversed().toList())
            items.asReversed()
        }
    }
    val profile: NativeRubySpacingProfile by lazy {
        NativeRubySpacingProfile.compose(items.map { it.profile },
            orderedItems.map { item -> items.indexOfFirst { it === item } }, complete = true)
    }
    fun reallocated(increment: NativeRubySpacingIncrement): NativeRubyColumn {
        val plan = nativeRubyHierarchyPlan(orderedItems.map { item ->
            NativeRubyHierarchyItem(item, item.profile, item.width, nested = item.base != null, reversedEdges = false)
        }, extra = 0f, parentIncrement = increment)
        val growth = MutableList(widths.size) { NativeRubySpacingIncrement(0f, 0f, 0f) }
        plan.placements.forEach { placed ->
            val item = placed.occurrence as Item
            item.base?.let { growth[it] = placed.increment }
        }
        return rebuild(widths.mapIndexed { index, width -> width + growth[index].width(originalProfiles[index]) }, growth)
    }
}

/** Replacement measurement supplies only base alignment metrics. The separate complete
 * container is consulted by the line-leading pass, never disguised as an image strut. */
internal class NativeRubyColumn(
    val advance: Float,
    val base: NativeUsedLineMetrics,
    val container: NativeUsedLineMetrics,
    val above: Boolean,
    val below: Boolean,
    val children: List<NativeRubyChild>,
    val decorations: List<NativeInlineDecorationFragment>,
    val backgrounds: List<Pair<NativeFloatBounds, Int>>,
    val cursor: InlineCursor?,
    val cursorRegions: List<NativeRubyCursorRegion>,
    val fragmentKey: NativeRubyFragmentKey? = null,
    val continues: Boolean = false,
    private val hierarchy: NativeRubyColumnHierarchy? = null,
    val ownerContent: NativeUsedLineMetrics = base,
    val association: NativeRubyAssociation? = null,
    val baseText: String = "",
    val annotationOwners: Set<String> = emptySet(),
    val annotationGapPredecessors: Map<Int, String> = emptyMap(),
    private val trimAnnotationGaps: ((Set<Int>) -> NativeRubyColumn)? = null,
    val baseRanges: List<Pair<Int, Int>> = emptyList(),
    val baseSpaceNeighbors: Map<Int, Pair<Int?, Int?>> = emptyMap(),
    private val trimBaseSpaces: ((Set<Int>) -> NativeRubyColumn)? = null,
) : ReplacementSpan(), NativeReplacementPaintBounds {
    fun spacingProfile(): NativeRubySpacingProfile = hierarchy?.profile
        ?: throw UnsupportedFloatLayout("Ruby column lacks its complete native base hierarchy")
    fun reallocated(increment: NativeRubySpacingIncrement): NativeRubyColumn = hierarchy?.reallocated(increment)
        ?: throw UnsupportedFloatLayout("Ruby column lacks its original allocation owner")
    fun withoutAnnotationGaps(indices: Set<Int>): NativeRubyColumn =
        checkNotNull(trimAnnotationGaps)(indices)
    fun withoutBaseSpaces(offsets: Set<Int>): NativeRubyColumn =
        checkNotNull(trimBaseSpaces)(offsets)
    val reserved = ceil(advance.toDouble()).toInt()
    init {
        if (!advance.isFinite() || advance < 0f || advance > TablePixelLimit ||
            listOf(base.top, base.bottom, container.top, container.bottom).any {
                !it.isFinite() || kotlin.math.abs(it) > TablePixelLimit
            }) throw UnsupportedFloatLayout("Ruby column exceeds native coordinates")
    }
    override fun getSize(paint: Paint, text: CharSequence, start: Int, end: Int,
        fm: Paint.FontMetricsInt?): Int {
        fm?.let {
            it.ascent = kotlin.math.floor(base.top).toInt()
            it.descent = ceil(base.bottom.toDouble()).toInt()
            it.top = it.ascent; it.bottom = it.descent; it.leading = 0
        }
        return reserved
    }
    override fun nativePaintBounds(lineTop: Float, lineBottom: Float): NativeFloatBounds? =
        children.fold<NativeRubyChild, NativeFloatBounds?>(null) { result, child ->
            enclosingBounds(result, child.geometry.extents.ink?.translated(child.x, child.y))
        }.let { content ->
            (decorations.map { it.bounds } + backgrounds.filter { it.second ushr 24 != 0 }.map { it.first })
                .fold(content, ::enclosingBounds)
        }
    override fun draw(canvas: Canvas, text: CharSequence, start: Int, end: Int,
        x: Float, top: Int, y: Int, bottom: Int, paint: Paint) {
        if (canvas is NativeRubyAtomicCanvas) {
            canvas.paintRubyAtom(this, x, y.toFloat(), ::paintContents)
            return
        }
        val saved = canvas.save()
        try {
            canvas.translate(x, y.toFloat())
            paintContents(canvas)
        } finally { canvas.restoreToCount(saved) }
    }

    internal fun paintContents(canvas: Canvas) {
        backgrounds.forEach { (box, color) ->
            if (color ushr 24 != 0) canvas.drawRect(box.left, box.top, box.right, box.bottom,
                Paint().apply { this.color = color })
        }
        children.forEach { child ->
            val saved = canvas.save()
            try { canvas.translate(child.x, child.y); child.geometry.paint(canvas) }
            finally { canvas.restoreToCount(saved) }
        }
        decorations.forEach { it.paint(canvas) }
    }
}

internal sealed interface NativeRubyPiece {
    val nativeStart: Int
    val nativeEnd: Int
    data class Text(val start: Int, val end: Int, override val nativeStart: Int,
        override val nativeEnd: Int, val collapsed: Boolean = false,
        val styled: Spanned? = null, val groupPaint: NativeRubyGapPaint? = null,
        val trimmed: Boolean = false, val leafPaint: NativeRubyGapPaint? = null,
        val protectedEdge: Boolean = false) : NativeRubyPiece
    data class AtomicBox(override val nativeStart: Int, val atom: NativeInlineAtomicBox) : NativeRubyPiece {
        override val nativeEnd: Int get() = nativeStart + 1
    }
    data class Column(override val nativeStart: Int, val column: NativeRubyColumn) : NativeRubyPiece {
        override val nativeEnd: Int get() = nativeStart + 1
    }
}

/** Original action occurrence and its private native interval. These are geometry
 * coordinates, not new logical text or an independently allocated action owner. */
internal data class NativeRubyActionPadding(val owner: Span, val start: Int, val end: Int)
internal data class NativeRubyActionScope(
    val owner: NativeInlineActionOwner, val start: Int, val end: Int,
    val nativeStart: Int, val nativeEnd: Int, val point: Int,
    val format: NativeRubyGroupFormat, val shift: Float,
    val paddings: List<NativeRubyActionPadding>,
    val boxes: List<NativeRubyActionBox> = emptyList(),
    val ownBox: NativeInlineBoxOwner? = null,
)
internal data class NativeRubyActionBox(val owner: NativeInlineBoxOwner, val start: Int, val end: Int)
internal data class NativeRubyBoxScope(val start: Int, val end: Int, val nativeStart: Int,
    val nativeEnd: Int, val format: NativeRubyGroupFormat, val shift: Float, val parentRtl: Boolean?)

/** The actual declaring metric point is the authority for an empty no-wrap line. */
internal class NativeInlineActionPoint(val owner: NativeInlineActionOwner,
    val metrics: NativeAuthoredInlineMetrics)

internal fun nativeInlineActionEmptyLine(source: CharSequence): Boolean {
    if (source.isNotEmpty() || source !is Spanned) return false
    return source.getSpans(0, 0, NativeInlineActionPoint::class.java).any { point ->
        source.getSpanStart(point) == 0 && source.getSpanEnd(point) == 0 &&
            source.getSpanStart(point.metrics) == 0 && source.getSpanEnd(point.metrics) == 0
    }
}

/** Immutable original-source / visual-buffer relation. Public callers never see tokens,
 * generated isolates, or an envelope spanning unrelated logical ranges on another row. */
internal class NativeRubyLayout(val source: Spanned, val native: Spanned,
    val pieces: List<NativeRubyPiece>, val actionScopes: List<NativeRubyActionScope> = emptyList(),
    val boxScopes: List<NativeRubyBoxScope> = emptyList()) {
    fun nativeOffset(offset: Int, endAffinity: Boolean = false): Int {
        require(offset in 0..source.length)
        val atoms = pieces.filterIsInstance<NativeRubyPiece.AtomicBox>()
        if (endAffinity) atoms.lastOrNull { it.atom.child.end == offset }?.let { return it.nativeEnd }
        val texts = pieces.filterIsInstance<NativeRubyPiece.Text>()
        texts.firstOrNull { offset >= it.start && offset < it.end }?.let {
            return if (it.collapsed) it.nativeStart else it.nativeStart + offset - it.start
        }
        atoms.firstOrNull { offset >= it.atom.child.start && offset < it.atom.child.end }?.let { return it.nativeStart }
        pieces.filterIsInstance<NativeRubyPiece.Column>().firstOrNull { piece ->
            piece.column.children.any { child -> child.ranges.any { offset >= it.first && offset < it.second } }
        }?.let { return it.nativeStart }
        val boundary = if (endAffinity) texts.lastOrNull { it.end == offset } else texts.firstOrNull { it.start == offset }
        if (boundary != null) return if (endAffinity) boundary.nativeEnd else boundary.nativeStart
        return if (offset == source.length) native.length else pieces.firstOrNull()?.nativeStart ?: 0
    }

    fun placed(raw: NativeFloatGeometry): NativeRubyPlacedProjection = NativeRubyPlacedProjection(this, raw)

    fun trimLineEdges(raw: NativeFloatGeometry, forcedSpaces: Set<Int> = emptySet()): NativeRubyLayout? {
        val columns = pieces.filterIsInstance<NativeRubyPiece.Column>()
        val ownersByLine = columns.groupBy { raw.nativeLineAt(it.nativeStart) }.mapValues { (_, values) ->
            values.flatMap { it.column.annotationOwners }.toSet()
        }
        val baseRangesByLine = mutableMapOf<Int, MutableList<Pair<Int, Int>>>()
        pieces.forEach { piece -> when (piece) {
            is NativeRubyPiece.AtomicBox -> baseRangesByLine.getOrPut(raw.nativeLineAt(piece.nativeStart)) { mutableListOf() }
                .addAll(piece.atom.child.ranges)
            is NativeRubyPiece.Column -> baseRangesByLine.getOrPut(raw.nativeLineAt(piece.nativeStart)) { mutableListOf() }
                .addAll(piece.column.baseRanges)
            is NativeRubyPiece.Text -> if (piece.nativeStart < piece.nativeEnd) {
                for (line in raw.nativeLineAt(piece.nativeStart)..raw.nativeLineAt(piece.nativeEnd - 1)) {
                    val (start, end) = raw.nativeRangeOfLine(line)
                    val first = maxOf(start, piece.nativeStart); val last = minOf(end, piece.nativeEnd)
                    if (first < last) baseRangesByLine.getOrPut(line) { mutableListOf() }.add(
                        if (piece.collapsed) piece.start to piece.end else
                            (piece.start + first - piece.nativeStart) to (piece.start + last - piece.nativeStart))
                }
            }
        }
        }
        val trimmedColumns = columns.mapNotNull { piece ->
            val owners = ownersByLine[raw.nativeLineAt(piece.nativeStart)].orEmpty()
            val discarded = piece.column.annotationGapPredecessors.filterValues { it !in owners }.keys
            val ranges = baseRangesByLine[raw.nativeLineAt(piece.nativeStart)].orEmpty()
            fun present(at: Int?) = at != null && ranges.any { at >= it.first && at < it.second }
            val spaces = piece.column.baseSpaceNeighbors.filter { (_, pair) ->
                // Out-of-slice neighbors belong to an enclosing Ruby row, which
                // retains this occurrence until its actual native line is known.
                pair.first?.let { it in source.indices } != false && pair.second?.let { it in source.indices } != false &&
                    (!present(pair.first) || !present(pair.second))
            }.keys + forcedSpaces.filter { at -> piece.column.baseRanges.any { at >= it.first && at < it.second } }
            var column = piece.column
            if (discarded.isNotEmpty()) column = column.withoutAnnotationGaps(discarded)
            if (spaces.isNotEmpty()) column = column.withoutBaseSpaces(spaces)
            if (column === piece.column) null else piece.nativeStart to column
        }.toMap()
        val intervals = pieces.flatMap { piece -> when (piece) {
            is NativeRubyPiece.AtomicBox -> listOf(piece.nativeStart to piece.nativeEnd)
            is NativeRubyPiece.Column -> if (piece.column.baseText.any { it !in " \t\r\n" && !nativeRubyBidiControl(it) })
                listOf(piece.nativeStart to piece.nativeEnd) else emptyList()
            is NativeRubyPiece.Text -> if (piece.collapsed) emptyList() else (piece.start until piece.end).mapNotNull { at ->
                val char = source[at]
                if (char in " \t\r\n" || nativeRubyBidiControl(char)) null
                else (piece.nativeStart + at - piece.start) to (piece.nativeStart + at - piece.start + 1)
            }
        } }
        val trim = pieces.filterIsInstance<NativeRubyPiece.Text>().filter { piece ->
            if (!piece.collapsed || piece.trimmed || piece.nativeStart == piece.nativeEnd) false
            else if ((piece.start until piece.end).any { it in forcedSpaces }) true
            else if (piece.protectedEdge) false else {
                val (first, last) = raw.nativeRangeOfLine(raw.nativeLineAt(piece.nativeStart))
                val before = intervals.any { it.first < piece.nativeStart && it.second > first }
                val after = intervals.any { it.first >= piece.nativeEnd && it.first < last }
                !before || !after
            }
        }
        if (trim.isEmpty() && trimmedColumns.isEmpty()) return null
        val target = SpannableString(native)
        target.getSpans(0, target.length, NativeRubyLinePlan::class.java).forEach(target::removeSpan)
        columns.forEach { piece -> trimmedColumns[piece.nativeStart]?.let { column ->
            target.removeSpan(piece.column)
            target.setSpan(column, piece.nativeStart, piece.nativeEnd, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        } }
        trim.forEach { piece ->
            // These are run owners, not the declaring paragraph strut. Splitting their
            // private spans keeps all untrimmed text's metrics and authored ink intact.
            target.getSpans(piece.nativeStart, piece.nativeEnd, Any::class.java).filter { span ->
                span is NativeRunLineMetrics && !span.strut || span is NativeAuthoredInlineMetrics ||
                    span is NativeAuthoredBaselineShift || span is NativeAuthoredUnderline
            }.forEach { span ->
                val first = target.getSpanStart(span); val last = target.getSpanEnd(span)
                val flags = target.getSpanFlags(span)
                target.removeSpan(span)
                if (first < piece.nativeStart) target.setSpan(nativeRubySpanCopy(span), first, piece.nativeStart, flags)
                if (last > piece.nativeEnd) target.setSpan(nativeRubySpanCopy(span), piece.nativeEnd, last, flags)
            }
            target.setSpan(NativeRubyTrimmedGap(), piece.nativeStart, piece.nativeEnd, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        }
        val ends = (0 until raw.shapedLineCount).map { raw.nativeRangeOfLine(it).second }
        val advances = (0 until raw.shapedLineCount).map { line ->
            val removed = trim.filter { raw.nativeLineAt(it.nativeStart) == line }
                .sumOf { raw.nativeRubyMeasuredAdvance(it.nativeStart, it.nativeEnd).toDouble() } +
                columns.filter { raw.nativeLineAt(it.nativeStart) == line }.sumOf { piece ->
                    trimmedColumns[piece.nativeStart]?.let { if (raw.nativeRubyExactAdvances) piece.column.advance.toDouble() - it.advance
                        else piece.column.reserved.toDouble() - it.reserved } ?: 0.0
                }
            (raw.nativeLineAdvance(line).toDouble() - removed).coerceAtLeast(0.0).toFloat()
        }
        target.setSpan(NativeRubyLinePlan(ends, advances, allowEmptyTerminal = native.lastOrNull() == '\n'),
            0, target.length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        return NativeRubyLayout(source, SpannedString(target), pieces.map { piece ->
            when {
                piece is NativeRubyPiece.Text && piece in trim -> piece.copy(trimmed = true)
                piece is NativeRubyPiece.Column && piece.nativeStart in trimmedColumns ->
                    piece.copy(column = checkNotNull(trimmedColumns[piece.nativeStart]))
                else -> piece
            }
        }, actionScopes, boxScopes)
    }

    fun replacingColumns(replacements: Map<Int, List<NativeRubyColumn>>): NativeRubyLayout {
        if (replacements.isEmpty()) return this
        val columns = pieces.filterIsInstance<NativeRubyPiece.Column>().associateBy { it.nativeStart }
        require(replacements.all { (at, values) -> at in columns && values.isNotEmpty() })
        fun mapped(offset: Int): Int = offset + replacements.entries.filter { it.key < offset }.sumOf { it.value.size - 1 }
        val target = SpannableStringBuilder(native)
        val oldBreaks = target.getSpans(0, target.length, NativeRubyBreaks::class.java).singleOrNull()?.boundaries.orEmpty()
        target.getSpans(0, target.length, NativeRubyBreaks::class.java).forEach(target::removeSpan)
        target.getSpans(0, target.length, NativeRubyLinePlan::class.java).forEach(target::removeSpan)
        replacements.entries.sortedByDescending { it.key }.forEach { (at, values) ->
            target.removeSpan(checkNotNull(columns[at]).column)
            target.replace(at, at + 1, "\ufffc".repeat(values.size))
            values.forEachIndexed { index, column ->
                target.setSpan(column, at + index, at + index + 1, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
            }
        }
        val projected = pieces.flatMap { piece -> when (piece) {
            is NativeRubyPiece.AtomicBox -> listOf(piece.copy(nativeStart = mapped(piece.nativeStart)))
            is NativeRubyPiece.Text -> listOf(piece.copy(nativeStart = mapped(piece.nativeStart), nativeEnd = mapped(piece.nativeEnd)))
            is NativeRubyPiece.Column -> (replacements[piece.nativeStart] ?: listOf(piece.column)).mapIndexed { index, column ->
                NativeRubyPiece.Column(mapped(piece.nativeStart) + index, column)
            }
        } }
        val breaks = oldBreaks.map(::mapped) + projected.filterIsInstance<NativeRubyPiece.Column>()
            .filter { it.column.continues }.map { it.nativeEnd }
        target.setSpan(NativeRubyBreaks(breaks.distinct().sorted()), 0, target.length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        return NativeRubyLayout(source, SpannedString(target), projected, actionScopes.map {
            it.copy(nativeStart = mapped(it.nativeStart), nativeEnd = mapped(it.nativeEnd), point = mapped(it.point))
        }, boxScopes.map { it.copy(nativeStart = mapped(it.nativeStart), nativeEnd = mapped(it.nativeEnd)) })
    }

    fun observedBands(raw: NativeFloatGeometry): Map<NativeRubyFragmentKey, Float> {
        val columns = pieces.filterIsInstance<NativeRubyPiece.Column>()
        return columns.mapIndexedNotNull { index, piece -> piece.column.fragmentKey?.let { key ->
            key to raw.nativeRubyAvailableAt(piece.nativeStart, columns.getOrNull(index - 1)?.column?.continues != true)
        } }.toMap()
    }
}

internal class NativeRubyPlacedProjection(val compiled: NativeRubyLayout,
    val raw: NativeFloatGeometry, private val isolatedColumn: Boolean = false) {
    private data class Child(val start: Int, val end: Int, val geometry: FloatTextGeometry,
        val x: Float, val y: Float, val line: Int, val cursor: InlineCursor?,
        val ranges: List<Pair<Int, Int>>, val atomic: Boolean = false, val paintOrder: Long = 0) {
        fun owns(offset: Int): Boolean = ranges.any { offset >= it.first && offset < it.second }
        fun endsAt(offset: Int): Boolean = ranges.any { it.first < it.second && offset == it.second }
    }
    private val atoms = compiled.pieces.filterIsInstance<NativeRubyPiece.AtomicBox>()
    private val children = compiled.pieces.flatMap { piece -> when (piece) {
        is NativeRubyPiece.Column -> {
            val (x, baseline) = raw.nativeReplacementOrigin(piece.nativeStart)
            val line = raw.nativeLineAt(piece.nativeStart)
            piece.column.children.map { child -> Child(child.start, child.end, child.geometry,
                x + child.x, baseline + child.y, line, piece.column.cursor, child.ranges,
                paintOrder = if (atoms.isEmpty()) 0 else raw.nativeReplacementPaintOrder(piece.nativeStart)) }
        }
        is NativeRubyPiece.AtomicBox -> {
            val (x, baseline) = raw.nativeReplacementOrigin(piece.nativeStart)
            val child = piece.atom.child
            listOf(Child(child.start, child.end, child.geometry, x + child.x, baseline + child.y,
                raw.nativeLineAt(piece.nativeStart), null, child.ranges, atomic = true,
                paintOrder = raw.nativeReplacementPaintOrder(piece.nativeStart)))
        }
        is NativeRubyPiece.Text -> emptyList()
    } }.let { if (atoms.isEmpty()) it else it.sortedBy { child -> child.paintOrder } }
    private val texts = compiled.pieces.filterIsInstance<NativeRubyPiece.Text>()
    private val sourceCursors = nativeInlineRanges(compiled.source, NativeAuthoredCursor::class.java)
    private fun textOwner(offset: Int): NativeRubyPiece.Text? = texts.firstOrNull { offset >= it.start && offset < it.end }
    private fun inText(piece: NativeRubyPiece.Text, offset: Int): Int =
        if (piece.collapsed) piece.nativeStart else piece.nativeStart + offset - piece.start
    private val cursors = compiled.pieces.filterIsInstance<NativeRubyPiece.Column>().flatMap { piece ->
        val (x, baseline) = raw.nativeReplacementOrigin(piece.nativeStart)
        piece.column.cursorRegions.map { it.copy(bounds = it.bounds.translated(x, baseline)) }
    }
    private data class Gap(val line: Int, val box: NativeFloatBounds, val cursor: InlineCursor?,
        val backgrounds: List<Pair<NativeFloatBounds, Int>>, val decorations: List<NativeInlineDecorationFragment>)
    private val gaps = texts.flatMap { piece ->
        if (piece.trimmed || piece.nativeStart == piece.nativeEnd) return@flatMap emptyList()
        val owners = listOfNotNull(piece.groupPaint, piece.leafPaint)
        if (owners.isEmpty()) return@flatMap emptyList()
        raw.nativeRubyGapAllocations(piece.nativeStart, piece.nativeEnd).map { allocation ->
            val backgrounds = mutableListOf<Pair<NativeFloatBounds, Int>>()
            val decorations = mutableListOf<NativeInlineDecorationFragment>()
            var box: NativeFloatBounds? = null
            owners.forEach { owner ->
                val baseline = allocation.baseline + owner.baselineShift
                nativeRubyGroupPaint(owner.format, allocation.left, allocation.right - allocation.left,
                    baseline, owner.content, backgrounds, decorations)
                box = enclosingBounds(box, NativeFloatBounds(allocation.left, baseline + owner.content.top,
                    allocation.right, baseline + owner.content.bottom))
            }
            Gap(allocation.line, checkNotNull(box), piece.groupPaint?.format?.cursor, backgrounds, decorations)
        }
    }
    private val actionPaints = if (isolatedColumn) emptyList() else compiled.actionScopes.filter { it.ownBox == null }.map { scope ->
        NativeInlineActionPaint(scope.format, scope.shift,
            raw.nativeInlineActionFragments(scope.nativeStart, scope.nativeEnd))
    }
    private val length get() = compiled.source.length

    fun isHardLineBreak(offset: Int): Boolean {
        require(offset in 0 until length)
        return textOwner(offset)?.let { !it.collapsed && compiled.source[offset] == '\n' } == true
    }

    val floats: List<PlacedNativeFloat> get() = raw.floats.map { placed ->
        placed.copy(occurrence = placed.occurrence.copy(offset = sourceOffset(placed.occurrence.offset)))
    }
    val ordinaryPaintBounds: List<NativeFloatBounds> get() = raw.ordinaryPaintBounds + gapPaintBounds()
    fun gapPaintBounds(line: Int? = null): List<NativeFloatBounds> = actionPaints.flatMap { it.bounds(line) } + gaps.filter { line == null || it.line == line }.flatMap { gap ->
        gap.backgrounds.filter { it.second ushr 24 != 0 }.map { it.first } + gap.decorations.map { it.bounds }
    }
    fun paintGapBackgrounds(canvas: Canvas, line: Int? = null) {
        actionPaints.forEach { it.paintBackgrounds(canvas, line) }
        gaps.filter { line == null || it.line == line }.forEach { gap -> gap.backgrounds.forEach { (box, color) ->
            if (color ushr 24 != 0) canvas.drawRect(box.left, box.top, box.right, box.bottom, Paint().apply { this.color = color })
        } }
    }
    fun paintGapDecorations(canvas: Canvas, line: Int? = null) {
        gaps.filter { line == null || it.line == line }.forEach { gap -> gap.decorations.forEach { it.paint(canvas) } }
        actionPaints.forEach { it.paintDecorations(canvas, line) }
    }
    val scrollableBounds: NativeFloatBounds get() {
        val childrenBounds = children.fold(raw.scrollableBounds) { bounds, child ->
            val own = if (child.geometry is NativeFloatGeometry) child.geometry.scrollableBounds
                else NativeFloatBounds(0f, 0f, child.geometry.width.toFloat(), child.geometry.height.toFloat())
            bounds.enclosing(own.translated(child.x, child.y))
        }
        val columns = compiled.pieces.filterIsInstance<NativeRubyPiece.Column>().fold(childrenBounds) { bounds, piece ->
            val (x, baseline) = raw.nativeReplacementOrigin(piece.nativeStart)
            bounds.enclosing(NativeFloatBounds(x, baseline + piece.column.container.top,
                x + piece.column.advance, baseline + piece.column.container.bottom))
        }
        val atomicBounds = atoms.fold(columns) { bounds, piece ->
            val (x, baseline) = raw.nativeReplacementOrigin(piece.nativeStart)
            bounds.enclosing(NativeFloatBounds(x, baseline + piece.atom.metrics.top,
                x + piece.atom.advance, baseline + piece.atom.metrics.bottom))
        }
        return gapPaintBounds().fold(gaps.fold(atomicBounds) { bounds, gap -> bounds.enclosing(gap.box) }) {
            bounds, own -> bounds.enclosing(own)
        }
    }

    fun rects(start: Int, end: Int): List<RectF> {
        require(start in 0..length && end in start..length)
        if (start == end) return emptyList()
        return buildList {
            texts.forEach { piece ->
                if (piece.trimmed || piece.nativeStart == piece.nativeEnd) return@forEach
                val a = maxOf(start, piece.start); val b = minOf(end, piece.end)
                if (a < b) addAll(raw.rectsForRange(
                    if (piece.collapsed) piece.nativeStart else piece.nativeStart + a - piece.start,
                    if (piece.collapsed) piece.nativeEnd else piece.nativeStart + b - piece.start))
            }
            children.forEach { child ->
                val a = maxOf(start, child.start); val b = minOf(end, child.end)
                if (a < b) addAll(child.geometry.rectsForRange(a - child.start, b - child.start).map {
                    RectF(it).apply { offset(child.x, child.y) }
                })
            }
        }
    }

    fun paddingRects(owner: Span, start: Int, end: Int, line: Int? = null): List<RectF>? {
        require(start in 0..length && end in start..length)
        val found = children.mapNotNull { child ->
            if (line != null && child.line != line) return@mapNotNull null
            if (start < child.start || end > child.end) return@mapNotNull null
            child.geometry.inlinePaddingGroupRects(owner, start - child.start, end - child.start)?.map {
                RectF(it).apply { offset(child.x, child.y) }
            }
        }
        if (found.isEmpty()) return null
        if (found.size != 1) throw UnsupportedFloatLayout("Inline padding group lost its unique native occurrence")
        return found.single()
    }

    fun boxRects(owner: NativeInlineBoxOwner, start: Int, end: Int, line: Int? = null): List<RectF>? {
        require(start in 0..length && end in start..length)
        atoms.singleOrNull { it.atom.format.box?.owner === owner &&
            it.atom.child.start == start && it.atom.child.end == end }?.let { piece ->
            if (line != null && raw.nativeLineAt(piece.nativeStart) != line) return emptyList()
            val (x, baseline) = raw.nativeReplacementOrigin(piece.nativeStart)
            val box = piece.atom.borderBounds
            return listOf(RectF(x + box.left, baseline + box.top, x + box.right, baseline + box.bottom))
        }
        val scope = compiled.boxScopes.singleOrNull {
            it.format.box?.owner === owner && it.start == start && it.end == end
        } ?: return null
        return raw.nativeInlineBoxRects(owner, scope.nativeStart, scope.nativeEnd, line)
    }

    fun boxHitTest(owner: NativeInlineBoxOwner, start: Int, end: Int): ((Float, Float) -> Boolean)? {
        require(start in 0..length && end in start..length)
        val scope = compiled.boxScopes.singleOrNull {
            it.format.box?.owner === owner && it.start == start && it.end == end
        } ?: return null
        return raw.nativeInlineBoxHitTest(owner, scope.nativeStart, scope.nativeEnd)
    }

    fun boxChildActionRects(owner: NativeInlineBoxOwner, start: Int, end: Int,
        childStart: Int, childEnd: Int, fragments: List<RectF>): List<RectF>? {
        require(start in 0..length && end in start..length && childStart in start..end && childEnd in childStart..end)
        val scope = compiled.boxScopes.singleOrNull {
            it.format.box?.owner === owner && it.start == start && it.end == end
        } ?: return null
        fun mapped(offset: Int, endAffinity: Boolean): Int {
            if (offset == scope.start) return scope.nativeStart
            if (offset == scope.end) return scope.nativeEnd
            if (endAffinity) compiled.pieces.filterIsInstance<NativeRubyPiece.Text>()
                .lastOrNull { it.end == offset && it.start >= scope.start }?.let { return it.nativeEnd }
            return compiled.nativeOffset(offset)
        }
        return raw.nativeInlineBoxChildActionRects(owner, scope.nativeStart, scope.nativeEnd,
            mapped(childStart, false), mapped(childEnd, true), fragments)
    }

    fun actionRects(owner: NativeInlineActionOwner, start: Int, end: Int,
        line: Int? = null): List<RectF>? {
        require(start in 0..length && end in start..length)
        val scope = compiled.actionScopes.singleOrNull { it.owner === owner }
        if (scope == null) {
            val found = children.mapNotNull { child ->
                if (line != null && child.line != line) return@mapNotNull null
                if (start < child.start || end > child.end) return@mapNotNull null
                child.geometry.inlineActionGroupRects(owner, start - child.start, end - child.start)?.map {
                    RectF(it).apply { offset(child.x, child.y) }
                }
            }
            return if (found.isEmpty()) null else found.flatten()
        }
        if (start < scope.start || end > scope.end) return null
        scope.ownBox?.let { owner ->
            return if (start == scope.start && end == scope.end) boxRects(owner, start, end, line)
                else if (line == null) rects(start, end) else rectsOnLine(line, start, end)
        }
        if (scope.start == scope.end) {
            if (start != scope.start || end != scope.end) return null
            val ownLine = raw.nativeLineAt(scope.point)
            if (line != null && line != ownLine) return emptyList()
            val primary = NativePrimaryFontMetrics.from(scope.format.paint).copy(baselineShift = scope.shift)
            val band = primary.authored(scope.format.lineHeight) ?: NativeUsedLineMetrics(
                primary.ascent + scope.shift, primary.descent + scope.shift)
            val caret = raw.caretRect(scope.point)
            val baseline = raw.nativeRubyLineBaseline(ownLine)
            return listOf(RectF(caret.left, baseline + band.top, caret.left, baseline + band.bottom))
        }
        if (start == end) return emptyList()
        val padding = scope.paddings.filter { it.start >= start && it.end <= end }
        val boxes = scope.boxes.filter { it.start >= start && it.end <= end }
        val groups = (padding.map { Triple(it.start, it.end, it as Any) } +
            boxes.map { Triple(it.start, it.end, it as Any) }).sortedBy { it.first }
        return buildList {
            fun text(first: Int, last: Int) {
                if (first < last) addAll(if (line == null) rects(first, last) else rectsOnLine(line, first, last))
            }
            var cursor = start
            groups.forEach { (first, last, group) ->
                text(cursor, first)
                val rectangles = when (group) {
                    is NativeRubyActionPadding -> paddingRects(group.owner, first, last, line)
                    is NativeRubyActionBox -> boxRects(group.owner, first, last, line)
                    else -> error("Unknown source inline group")
                }
                if (rectangles != null) addAll(rectangles)
                else if (line == null && !isolatedColumn)
                    throw UnsupportedFloatLayout("Inline action lost its contained inline geometry")
                cursor = last
            }
            text(cursor, end)
        }
    }

    fun rectsOnLine(line: Int, start: Int, end: Int): List<RectF> = buildList {
        require(start in 0..length && end in start..length)
        texts.forEach { piece ->
            if (piece.trimmed || piece.nativeStart == piece.nativeEnd) return@forEach
            val a = maxOf(start, piece.start); val b = minOf(end, piece.end)
            if (a < b) addAll(raw.nativeRubyLineRects(line,
                if (piece.collapsed) piece.nativeStart else piece.nativeStart + a - piece.start,
                if (piece.collapsed) piece.nativeEnd else piece.nativeStart + b - piece.start))
        }
        children.filter { it.line == line }.forEach { child ->
            child.ranges.forEach { range ->
                val a = maxOf(start, range.first); val b = minOf(end, range.second)
                if (a < b) addAll(child.geometry.rectsForRange(a - child.start, b - child.start).map {
                    RectF(it).apply { offset(child.x, child.y) }
                })
            }
        }
    }

    private fun childAt(value: NativeTextCaret): Child? =
        if (value.affinity == NativeTextAffinity.Upstream) children.lastOrNull {
            value.offset > it.start && value.offset <= it.end
        } else children.firstOrNull { it.owns(value.offset) }
    private fun childHit(x: Float, y: Float): Child? = children.lastOrNull { child ->
        child.geometry.containsInteraction(x - child.x, y - child.y) ||
            listOf(child.geometry.caretRect(NativeTextCaret(0)), child.geometry.caretRect(
                NativeTextCaret(child.end - child.start, NativeTextAffinity.Upstream))).any { box ->
                x >= child.x + box.left && x <= child.x + box.right && y >= child.y + box.top && y <= child.y + box.bottom
            }
    } ?: atoms.lastOrNull { piece ->
        val (left, baseline) = raw.nativeReplacementOrigin(piece.nativeStart)
        x >= left && x < left + piece.atom.advance &&
            y >= baseline + piece.atom.metrics.top && y < baseline + piece.atom.metrics.bottom
    }?.let { piece -> children.single { it.atomic && it.start == piece.atom.child.start && it.end == piece.atom.child.end } }

    fun caret(value: NativeTextCaret): RectF {
        require(value.offset in 0..length)
        childAt(value)?.let { child ->
            return RectF(child.geometry.caretRect(NativeTextCaret(value.offset - child.start, value.affinity)))
                .apply { offset(child.x, child.y) }
        }
        if (value.affinity == NativeTextAffinity.Upstream) texts.lastOrNull {
            value.offset > it.start && value.offset <= it.end
        }?.let { piece ->
            val at = if (value.offset == piece.end) piece.nativeEnd else inText(piece, value.offset)
            return raw.caretRect(NativeTextCaret(at, value.affinity))
        }
        return caret(value.offset)
    }

    private fun atomAtNative(value: NativeTextCaret): NativeRubyPiece.AtomicBox? =
        if (value.affinity == NativeTextAffinity.Upstream) atoms.lastOrNull {
            value.offset > it.nativeStart && value.offset <= it.nativeEnd
        } else atoms.firstOrNull { value.offset >= it.nativeStart && value.offset < it.nativeEnd }

    private fun sourceCaret(value: NativeTextCaret, movement: Int? = null): NativeTextCaret {
        val piece = if (value.affinity == NativeTextAffinity.Upstream) texts.lastOrNull {
            value.offset > it.nativeStart && value.offset <= it.nativeEnd
        } else texts.firstOrNull { value.offset >= it.nativeStart && value.offset < it.nativeEnd }
        if (piece != null) return NativeTextCaret(if (piece.collapsed) {
            if (value.offset == piece.nativeEnd) piece.end else piece.start
        } else piece.start + value.offset - piece.nativeStart, value.affinity)
        atomAtNative(value)?.let { atom ->
            val child = atom.atom.child
            // Keyboard entry follows this child's resolved paragraph progression;
            // coincident X values on different inner lines cannot select an owner.
            if (movement != null) {
                val rtl = (child.geometry as NativeFloatGeometry).nativeRubyParagraphDirection < 0
                return if ((movement > 0) == rtl) NativeTextCaret(child.end, NativeTextAffinity.Upstream)
                    else NativeTextCaret(child.start)
            }
            return if (value.affinity == NativeTextAffinity.Upstream) NativeTextCaret(child.end, value.affinity)
                else NativeTextCaret(child.start)
        }
        return NativeTextCaret(sourceOffset(value.offset), value.affinity)
    }

    fun caretAt(x: Float, y: Float): NativeTextCaret {
        val hit = childHit(x, y)
        if (atoms.isNotEmpty()) raw.nativeOrdinaryCaretAbove(x, y, hit?.paintOrder ?: -1L)?.let {
            return sourceCaret(it)
        }
        fun fromChild(child: Child): NativeTextCaret {
            val local = child.geometry.caretAt(x - child.x, y - child.y)
            return NativeTextCaret(child.start + local.offset,
                if (local.offset == child.end - child.start) NativeTextAffinity.Upstream else local.affinity)
        }
        hit?.let { return fromChild(it) }
        val rawCaret = raw.caretAt(x, y)
        atomAtNative(rawCaret)?.let { atom ->
            return fromChild(children.single { it.atomic && it.start == atom.atom.child.start && it.end == atom.atom.child.end })
        }
        return sourceCaret(rawCaret)
    }

    fun visualCaret(value: NativeTextCaret, direction: Int): NativeTextCaret {
        require(value.offset in 0..length && direction in listOf(-1, 1))
        val child = childAt(value)
        if (child != null) {
            if (!child.atomic) return NativeTextCaret(legacyVisualOffset(value.offset, direction))
            val local = NativeTextCaret(value.offset - child.start, value.affinity)
            val next = child.geometry.visualCaret(local, direction)
            val translated = NativeTextCaret(child.start + next.offset,
                if (next.offset == child.end - child.start) NativeTextAffinity.Upstream else next.affinity)
            if (translated != value) return translated
            val atom = atoms.single { it.atom.child.start == child.start && it.atom.child.end == child.end }
            val edges = listOf(NativeTextCaret(atom.nativeStart), NativeTextCaret(atom.nativeEnd, NativeTextAffinity.Upstream))
            val edge = if (direction < 0) edges.minBy { raw.caretRect(it).left } else edges.maxBy { raw.caretRect(it).left }
            val moved = raw.visualCaret(edge, direction)
            return if (moved == edge) value else sourceCaret(moved, direction)
        }
        val ordinary = if (value.affinity == NativeTextAffinity.Upstream) texts.lastOrNull {
            value.offset > it.start && value.offset <= it.end
        } else textOwner(value.offset)
        val at = ordinary?.let { if (value.offset == it.end) it.nativeEnd else inText(it, value.offset) }
            ?: compiled.nativeOffset(value.offset, value.affinity == NativeTextAffinity.Upstream)
        val next = raw.visualCaret(NativeTextCaret(at, value.affinity), direction)
        return sourceCaret(next, direction)
    }

    fun visualLineRanges(value: NativeTextCaret): List<Pair<Int, Int>> {
        require(value.offset in 0..length)
        childAt(value)?.takeIf { it.atomic }?.let { child ->
            return child.geometry.visualLineRanges(NativeTextCaret(value.offset - child.start, value.affinity))
                .map { (a, b) -> a + child.start to b + child.start }
        }
        return if (value.affinity == NativeTextAffinity.Upstream && value.offset > 0)
            lineRanges(lineAt(value.offset - 1)) else visualLineRanges(value.offset)
    }

    fun caret(offset: Int): RectF {
        require(offset in 0..length)
        val owned = children.firstOrNull { it.owns(offset) }
        if (owned == null) textOwner(offset)?.let { piece ->
            val result = raw.caretRect(inText(piece, offset))
            if (piece.trimmed || piece.nativeStart == piece.nativeEnd) {
                val baseline = raw.baselineForOffset(inText(piece, offset))
                return RectF(result.left, baseline, result.left, baseline)
            }
            return result
        }
        val child = owned ?: children.lastOrNull { it.endsAt(offset) }
        if (child != null) return RectF(child.geometry.caretRect(offset - child.start)).apply { offset(child.x, child.y) }
        return raw.caretRect(compiled.nativeOffset(offset, endAffinity = offset == length))
    }

    fun caretOnLine(line: Int, offset: Int): RectF? {
        require(offset in 0..length)
        val owned = children.firstOrNull { it.line == line && it.owns(offset) }
        if (owned != null) return RectF(owned.geometry.caretRect(offset - owned.start)).apply { offset(owned.x, owned.y) }
        textOwner(offset)?.let { piece ->
            val native = inText(piece, offset)
            if (raw.nativeLineAt(native) == line) return raw.nativeRubyLineCaret(line, native)?.let { rect ->
                if (piece.trimmed || piece.nativeStart == piece.nativeEnd) {
                    val baseline = raw.nativeRubyLineBaseline(line)
                    RectF(rect.left, baseline, rect.left, baseline)
                } else rect
            }
        }
        val child = children.lastOrNull { it.line == line && it.endsAt(offset) }
        if (child != null) return RectF(child.geometry.caretRect(offset - child.start)).apply { offset(child.x, child.y) }
        val piece = texts.firstOrNull { offset >= it.start && offset < it.end &&
            raw.nativeLineAt(it.nativeStart + if (it.collapsed) 0 else offset - it.start) == line }
            ?: texts.lastOrNull { offset == it.end && raw.nativeLineAt(maxOf(it.nativeStart, it.nativeEnd - 1)) == line }
            ?: return null
        val native = if (piece.collapsed) (if (offset == piece.end) piece.nativeEnd else piece.nativeStart)
            else piece.nativeStart + offset - piece.start
        return raw.nativeRubyLineCaret(line, native)
    }

    fun baseline(offset: Int): Float {
        require(offset in 0..length)
        val owned = children.firstOrNull { it.owns(offset) }
        if (owned == null) textOwner(offset)?.let { return raw.baselineForOffset(inText(it, offset)) }
        val child = owned ?: children.lastOrNull { it.endsAt(offset) }
        return if (child != null) child.y + (if (child.geometry is NativeFloatGeometry)
            child.geometry.baselineForOffset(offset - child.start) else child.geometry.textBaselines?.first ?: 0f)
        else raw.baselineForOffset(compiled.nativeOffset(offset, offset == length))
    }

    fun distance(x: Float, y: Float): Double = rects(0, length).minOfOrNull { rect ->
        val dx = maxOf(rect.left - x, 0f, x - rect.right).toDouble()
        val dy = maxOf(rect.top - y, 0f, y - rect.bottom).toDouble()
        dx * dx + dy * dy
    } ?: Double.POSITIVE_INFINITY

    fun offset(x: Float, y: Float): Int {
        if (atoms.isNotEmpty()) return caretAt(x, y).offset
        children.lastOrNull { it.geometry.containsInteraction(x - it.x, y - it.y) }?.let {
            return it.start + it.geometry.offsetForPosition(x - it.x, y - it.y)
        }
        if (isolatedColumn) {
            val nearest = children.filter { it.ranges.any { range -> range.first < range.second } }.minByOrNull { child ->
                child.geometry.rectsForRange(0, child.end - child.start).minOfOrNull { box ->
                    val dx = maxOf(box.left + child.x - x, 0f, x - box.right - child.x).toDouble()
                    val dy = maxOf(box.top + child.y - y, 0f, y - box.bottom - child.y).toDouble()
                    dx * dx + dy * dy
                } ?: Double.POSITIVE_INFINITY
            }
            return nearest?.let { it.start + it.geometry.offsetForPosition(x - it.x, y - it.y) }
                ?: children.firstOrNull()?.start ?: 0
        }
        val native = raw.offsetForPosition(x, y)
        val columns = compiled.pieces.filterIsInstance<NativeRubyPiece.Column>()
        val column = columns.firstOrNull { native >= it.nativeStart && native < it.nativeEnd }
            ?: columns.lastOrNull { native == it.nativeEnd }.takeIf {
                texts.none { native >= it.nativeStart && native < it.nativeEnd }
            }
        if (column != null) {
            val candidates = children.filter { it.line == raw.nativeLineAt(column.nativeStart) && it.start < it.end }
            val nearest = candidates.minByOrNull { child ->
                child.geometry.rectsForRange(0, child.end - child.start).minOfOrNull { box ->
                    val dx = maxOf(box.left + child.x - x, 0f, x - box.right - child.x).toDouble()
                    val dy = maxOf(box.top + child.y - y, 0f, y - box.bottom - child.y).toDouble()
                    dx * dx + dy * dy
                } ?: Double.POSITIVE_INFINITY
            }
            if (nearest != null) return nearest.start + nearest.geometry.offsetForPosition(x - nearest.x, y - nearest.y)
        }
        return sourceOffset(native)
    }

    fun offsetOnLine(line: Int, x: Float, y: Float): Int {
        children.lastOrNull { it.line == line && it.geometry.containsInteraction(x - it.x, y - it.y) }?.let {
            return it.start + it.geometry.offsetForPosition(x - it.x, y - it.y)
        }
        return sourceOffset(raw.nativeRubyLineOffsetForPosition(line, x, y))
    }

    private fun boxAllowsCursor(start: Int, end: Int, x: Float, y: Float): Boolean =
        compiled.boxScopes.filter { it.format.box?.radius != null && start >= it.start && end <= it.end }
            .all { scope -> boxHitTest(checkNotNull(scope.format.box).owner, scope.start, scope.end)?.invoke(x, y) == true }

    fun cursorOnLine(line: Int, x: Float, y: Float): InlineCursor? {
        children.lastOrNull { it.line == line && it.geometry.containsInteraction(x - it.x, y - it.y) }?.let {
            it.geometry.cursorAt(x - it.x, y - it.y)?.let { cursor -> return cursor }
        }
        compiled.pieces.filterIsInstance<NativeRubyPiece.Column>().asReversed().filter {
            raw.nativeLineAt(it.nativeStart) == line
        }.forEach { piece ->
            val (left, baseline) = raw.nativeReplacementOrigin(piece.nativeStart)
            piece.column.cursorRegions.asReversed().firstOrNull { region ->
                val box = region.bounds
                x >= left + box.left && x < left + box.right &&
                    y >= baseline + box.top && y < baseline + box.bottom
            }?.let { return it.cursor }
        }
        sourceCursors.lastOrNull { owner ->
            rectsOnLine(line, owner.start, owner.end).any { it.contains(x, y) } &&
                boxAllowsCursor(owner.start, owner.end, x, y)
        }?.let { return it.value.cursor }
        gaps.lastOrNull { it.line == line && x >= it.box.left && x < it.box.right &&
            y >= it.box.top && y < it.box.bottom }?.cursor?.let { return it }
        return raw.nativeInlineBoxCursorAt(x, y, line) ?: actionCursor(x, y, line)
    }

    private fun sourceOffset(native: Int): Int {
        atoms.firstOrNull { native >= it.nativeStart && native < it.nativeEnd }?.let { return it.atom.child.start }
        texts.firstOrNull { native >= it.nativeStart && native < it.nativeEnd }?.let {
            return if (it.collapsed) it.start else it.start + native - it.nativeStart
        }
        val columns = compiled.pieces.filterIsInstance<NativeRubyPiece.Column>()
        columns.firstOrNull { native >= it.nativeStart && native < it.nativeEnd }?.let { column ->
            column.column.children.flatMap { it.ranges }.filter { it.first < it.second }.minOfOrNull { it.first }?.let { return it }
        }
        texts.lastOrNull { native == it.nativeEnd }?.let { return it.end }
        atoms.lastOrNull { native == it.nativeEnd }?.let { return it.atom.child.end }
        columns.lastOrNull { native == it.nativeEnd }?.let { column ->
            column.column.children.flatMap { it.ranges }.filter { it.first < it.second }.maxOfOrNull { it.second }?.let { return it }
        }
        // Native arrows skip or stop beside layout-only isolate controls. Select the
        // following real source owner, without inventing a public control offset.
        compiled.pieces.firstOrNull { it.nativeStart > native }?.let { next ->
            when (next) {
                is NativeRubyPiece.AtomicBox -> return next.atom.child.start
                is NativeRubyPiece.Text -> return next.start
                is NativeRubyPiece.Column -> next.column.children.flatMap { it.ranges }.filter { it.first < it.second }
                    .minOfOrNull { it.first }?.let { return it }
            }
        }
        return if (native >= compiled.native.length) length else 0
    }

    fun visualOffset(offset: Int, direction: Int): Int =
        if (atoms.isNotEmpty()) visualCaret(NativeTextCaret(offset), direction).offset else legacyVisualOffset(offset, direction)

    private fun legacyVisualOffset(offset: Int, direction: Int): Int {
        require(offset in 0..length && direction in listOf(-1, 1))
        val owned = children.firstOrNull { it.owns(offset) }
        val ordinary = if (owned == null) textOwner(offset) else null
        val rawNext = raw.visualOffset(ordinary?.let { inText(it, offset) } ?: compiled.nativeOffset(offset), direction)
        if (ordinary != null && texts.any { rawNext >= it.nativeStart && rawNext < it.nativeEnd })
            return sourceOffset(rawNext)
        val child = owned ?: if (ordinary == null) children.lastOrNull { it.endsAt(offset) } else null
        if (child != null) {
            val next = child.geometry.visualOffset(offset - child.start, direction) + child.start
            if (next != offset && (child.owns(next) ||
                    children.none { it.owns(next) } && textOwner(next) == null)) return next
        }
        val line = lineAt(offset)
        data class Boundary(val offset: Int, val caret: RectF, val child: Child?)
        val current = caret(offset)
        fun inDirection(rect: RectF): Boolean = if (direction < 0) rect.left < current.left else rect.left > current.left
        val edges = children.filter { it.line == line }.flatMap { candidate ->
            candidate.ranges.filter { it.first < it.second }.flatMap { listOf(it.first, it.second) }.distinct().map { at ->
                Boundary(at, RectF(candidate.geometry.caretRect(at - candidate.start)).apply {
                    offset(candidate.x, candidate.y)
                }, candidate)
            }
        } + texts.flatMap { piece -> listOf(piece.start, piece.end).filter { it != offset }.mapNotNull { at ->
            val native = if (at == piece.end) piece.nativeEnd else piece.nativeStart
            raw.nativeRubyLineCaret(line, native)?.let { Boundary(at, it, null) }
        } }
        // Enter a neighboring owner's actual endpoint affinity before asking its
        // native cursor for an interior stop. Logical range edges alone can skip
        // a whole reading when its end is also the following ordinary text's start.
        for (edge in edges.filter { inDirection(it.caret) || it.child != null && it.caret.left == current.left }
            .sortedWith(compareBy<Boundary>({ kotlin.math.abs(it.caret.left - current.left) },
                { kotlin.math.abs(it.caret.top - current.top) }))) {
            val target = edge.child
            if (target != null && target !== owned && (!target.owns(edge.offset) || edge.offset == offset)) {
                val next = target.geometry.visualOffset(edge.offset - target.start, direction) + target.start
                if (next != edge.offset && target.owns(next) && inDirection(caret(next))) return next
                if (!target.owns(edge.offset)) continue
            }
            if (edge.offset != offset && inDirection(caret(edge.offset))) return edge.offset
        }
        return if (raw.nativeLineAt(rawNext) != line || texts.any { rawNext in it.nativeStart until it.nativeEnd })
            sourceOffset(rawNext) else offset
    }

    private fun lineAt(offset: Int): Int = children.firstOrNull { it.owns(offset) }?.line
        ?: textOwner(offset)?.let { raw.nativeLineAt(inText(it, offset)) }
        ?: children.lastOrNull { it.endsAt(offset) }?.line
        ?: raw.nativeLineAt(compiled.nativeOffset(offset, offset == length))

    fun visualLineRanges(offset: Int): List<Pair<Int, Int>> {
        require(offset in 0..length)
        children.firstOrNull { it.atomic && it.owns(offset) }?.let { child ->
            return child.geometry.visualLineRanges(offset - child.start).map { (a, b) -> a + child.start to b + child.start }
        }
        val line = lineAt(offset)
        return lineRanges(line)
    }

    fun baseTextOnLine(line: Int): String = buildString {
        val native = raw.nativeRangeOfLine(line)
        compiled.pieces.forEach { piece -> when (piece) {
            is NativeRubyPiece.AtomicBox -> if (piece.nativeStart >= native.first && piece.nativeStart < native.second)
                append(compiled.source, piece.atom.child.start, piece.atom.child.end)
            is NativeRubyPiece.Column -> if (piece.nativeStart >= native.first && piece.nativeStart < native.second)
                append(piece.column.baseText)
            is NativeRubyPiece.Text -> {
                val first = maxOf(native.first, piece.nativeStart); val last = minOf(native.second, piece.nativeEnd)
                if (first < last && !piece.trimmed) {
                    if (piece.collapsed) append(' ') else append(compiled.source,
                        piece.start + first - piece.nativeStart, piece.start + last - piece.nativeStart)
                }
            }
        } }
    }

    fun lineRanges(line: Int): List<Pair<Int, Int>> {
        val native = raw.nativeRangeOfLine(line)
        val ranges = buildList {
            texts.forEach { piece ->
                val a = maxOf(native.first, piece.nativeStart); val b = minOf(native.second, piece.nativeEnd)
                if (a < b) add(if (piece.collapsed) piece.start to piece.end
                    else (piece.start + a - piece.nativeStart) to (piece.start + b - piece.nativeStart))
                else if (piece.collapsed && piece.nativeStart == piece.nativeEnd &&
                    raw.nativeLineAt(piece.nativeStart) == line) add(piece.start to piece.end)
            }
            children.filter { it.line == line }.forEach { addAll(it.ranges.filter { range -> range.first < range.second }) }
        }.sortedBy { it.first }
        if (ranges.isEmpty()) {
            val offset = sourceOffset(native.first)
            return listOf(offset to offset)
        }
        val merged = mutableListOf<Pair<Int, Int>>()
        ranges.forEach { range ->
            val previous = merged.lastOrNull()
            if (previous != null && previous.second == range.first) merged[merged.lastIndex] = previous.first to range.second
            else merged += range
        }
        return merged
    }

    fun cursor(x: Float, y: Float): InlineCursor? {
        children.lastOrNull { it.geometry.containsInteraction(x - it.x, y - it.y) }?.let {
            it.geometry.cursorAt(x - it.x, y - it.y)?.let { cursor -> return cursor }
        }
        cursors.lastOrNull { x >= it.bounds.left && x < it.bounds.right &&
            y >= it.bounds.top && y < it.bounds.bottom }?.let { return it.cursor }
        if (isolatedColumn) return actionCursor(x, y)
        sourceCursors.lastOrNull { owner -> rects(owner.start, owner.end).any { it.contains(x, y) } &&
            boxAllowsCursor(owner.start, owner.end, x, y) }
            ?.let { return it.value.cursor }
        gaps.lastOrNull { x >= it.box.left && x < it.box.right &&
            y >= it.box.top && y < it.box.bottom }?.cursor?.let { return it }
        return raw.nativeInlineBoxCursorAt(x, y) ?: actionCursor(x, y)
    }

    private fun actionCursor(x: Float, y: Float, line: Int? = null): InlineCursor? =
        compiled.actionScopes.asReversed().firstOrNull { scope -> scope.format.cursor != null &&
            actionRects(scope.owner, scope.start, scope.end, line)?.any { it.contains(x, y) } == true &&
                (scope.ownBox?.let { boxHitTest(it, scope.start, scope.end)?.invoke(x, y) } ?: true)
        }?.format?.cursor
}

/** A read-only view of one retained occurrence, using the same child/source mapper.
 * Coordinates are column-local with baseline zero; unrelated old-position siblings
 * cannot win a query while a parent distributes additional hierarchical width. */
internal class NativeRubyColumnView(source: Spanned, nativeStart: Int,
    private val column: NativeRubyColumn, raw: NativeFloatGeometry,
    actionScopes: List<NativeRubyActionScope> = emptyList()) : FloatTextGeometry {
    private val projection = NativeRubyPlacedProjection(NativeRubyLayout(source, raw.nativeRubyShapingSource,
        listOf(NativeRubyPiece.Column(nativeStart, column)), actionScopes), raw, isolatedColumn = true)
    private val origin = raw.nativeReplacementOrigin(nativeStart)
    private val line = raw.nativeLineAt(nativeStart)
    private val ranges = column.children.flatMap { it.ranges }.filter { it.first < it.second }.sortedBy { it.first }
    private fun owns(offset: Int) = ranges.any { offset >= it.first && offset < it.second }
    private fun affinity(offset: Int) = owns(offset) || ranges.any { offset == it.second }
    private fun local(rect: RectF) = RectF(rect).apply { offset(-origin.first, -origin.second) }
    override val text: CharSequence = source
    override val width: Int get() = column.reserved
    override val height = ceil(column.container.height.toDouble()).toInt()
    override val nodes = emptyList<FloatInteractionNode>()
    override val textBaselines = NativeTextBaselines.of(if (ranges.isEmpty()) null else 0f, if (ranges.isEmpty()) null else 0f)
    override val ordinaryPaintBounds get() = listOfNotNull(column.nativePaintBounds(column.container.top, column.container.bottom))
    override val extents get() = NativeGeometryExtents(width, height.toFloat(), ordinaryPaintBounds.singleOrNull(),
        nativeBoundsOf(rectsForRange(0, text.length)))
    override fun paint(canvas: Canvas) = column.paintContents(canvas)
    override fun rectsForRange(start: Int, end: Int) = projection.rectsOnLine(line, start, end).map(::local)
    override fun inlinePaddingGroupRects(owner: Span, start: Int, end: Int): List<RectF>? =
        projection.paddingRects(owner, start, end)?.map(::local)
    override fun inlineActionGroupRects(owner: NativeInlineActionOwner, start: Int, end: Int): List<RectF>? =
        projection.actionRects(owner, start, end, line)?.map(::local)
    override fun characterRects(start: Int, length: Int): List<RectF?> {
        require(start in 0..text.length && length >= 0 && length <= text.length - start)
        return (start until start + length).map { offset ->
            if (!owns(offset)) null else {
                val first = if (offset > 0 && Character.isLowSurrogate(text[offset]) && Character.isHighSurrogate(text[offset - 1])) offset - 1 else offset
                val last = if (Character.isHighSurrogate(text[first]) && first + 1 < text.length && Character.isLowSurrogate(text[first + 1])) first + 2 else first + 1
                rectsForRange(first, last).reduceOrNull { a, b -> a.apply { union(b) } }
            }
        }
    }
    override fun caretRect(offset: Int): RectF {
        require(offset in 0..text.length)
        return if (affinity(offset)) projection.caretOnLine(line, offset)?.let(::local) ?: RectF() else RectF()
    }
    override fun offsetForPosition(x: Float, y: Float): Int = projection.offset(x + origin.first, y + origin.second)
    override fun lineRange(offset: Int): Pair<Int, Int> = visualLineRanges(offset).let {
        (it.firstOrNull()?.first ?: offset) to (it.lastOrNull()?.second ?: offset)
    }
    override fun visualLineRanges(offset: Int): List<Pair<Int, Int>> {
        require(offset in 0..text.length)
        return if (affinity(offset)) projection.lineRanges(line) else emptyList()
    }
    override fun isHardLineBreak(offset: Int): Boolean = projection.isHardLineBreak(offset)
    override fun visualOffset(offset: Int, direction: Int): Int {
        require(offset in 0..text.length && direction in listOf(-1, 1))
        if (!affinity(offset)) return offset
        return projection.visualOffset(offset, direction).takeIf(::affinity) ?: offset
    }
    override fun cursorAt(x: Float, y: Float): InlineCursor? = projection.cursor(x + origin.first, y + origin.second)
}

private class NativeRubyEmptyGeometry(override val text: CharSequence = "") : FloatTextGeometry {
    override val width = 0
    override val height = 0
    override val nodes = emptyList<FloatInteractionNode>()
    override val extents = NativeGeometryExtents(0, 0f, null, null)
    override val ordinaryPaintBounds = emptyList<NativeFloatBounds>()
    override fun paint(canvas: Canvas) = Unit
    override fun offsetForPosition(x: Float, y: Float) = 0
    override fun rectsForRange(start: Int, end: Int): List<RectF> {
        require(start in 0..text.length && end in start..text.length); return emptyList()
    }
    override fun characterRects(start: Int, length: Int): List<RectF?> {
        require(start in 0..text.length && length in 0..text.length - start); return List(length) { null }
    }
    override fun caretRect(offset: Int): RectF { require(offset in 0..text.length); return RectF() }
    override fun lineRange(offset: Int): Pair<Int, Int> { require(offset in 0..text.length); return 0 to text.length }
    override fun isHardLineBreak(offset: Int): Boolean { require(offset in text.indices); return false }
    override fun visualOffset(offset: Int, direction: Int): Int {
        require(offset in 0..text.length && direction in listOf(-1, 1)); return if (direction < 0) 0 else text.length
    }
}

internal data class NativeRubyRowPadding(val owner: Span, val format: NativeRubyGroupFormat,
    val content: NativeUsedLineMetrics, val localShift: Float, val innerAdvance: Float)

internal data class NativeRubyRow(val start: Int, val end: Int, val geometry: FloatTextGeometry,
    val advance: Float, val baseline: Float, val used: NativeUsedLineMetrics,
    val content: NativeUsedLineMetrics, val format: NativeRubyGroupFormat,
    val script: NativeRubyScriptState, val localShift: Float,
    val line: Int = 0, val ranges: List<Pair<Int, Int>> = listOf(start to end),
    val padding: NativeRubyRowPadding? = null) {
    fun withoutSpaces(offsets: Set<Int>): NativeRubyRow {
        val selected = offsets.filter { at -> ranges.any { at >= it.first && at < it.second } }.map { it - start }.toSet()
        val native = geometry as? NativeFloatGeometry ?: return this
        if (selected.isEmpty()) return this
        if (padding != null) throw UnsupportedFloatLayout("Inline padding group requires native whitespace fragmentation")
        val shaped = native.nativeRubyTrimSourceSpaces(selected)
        if (shaped === native) return this
        val primary = NativePrimaryFontMetrics.from(format.paint)
        return copy(geometry = shaped, advance = shaped.nativeLineAdvance(line), baseline = shaped.nativeRubyLineBaseline(line),
            used = shaped.nativeUsedLineMetrics(line),
            content = NativeUsedLineMetrics(primary.ascent, primary.descent).including(shaped.nativeContentLineMetrics(line)))
    }
    fun child(allocation: Float, x: Float, baseline: Float,
        parentIncrement: NativeRubySpacingIncrement? = null): NativeRubyChild {
        val spaced = if (padding != null) {
            if (parentIncrement != null && !parentIncrement.isZero)
                throw UnsupportedFloatLayout("Inline padding group requires native spacing distribution")
            val edges = checkNotNull(padding.format.padding)
            val inner = nativeRubyDistribute(geometry as NativeFloatGeometry,
                padding.innerAdvance, padding.innerAdvance, line)
            NativeInlinePaddingGeometry(inner, padding.owner, padding.innerAdvance,
                edges.left, edges.right, allocation, padding.format, padding.content, padding.localShift)
        } else if (geometry is NativeFloatGeometry)
            nativeRubyDistribute(geometry, advance, allocation, line, parentIncrement) else geometry
        val center = if (geometry !is NativeFloatGeometry) (allocation - advance) / 2f +
            (parentIncrement?.left ?: 0f) else 0f
        return NativeRubyChild(start, end, spaced, x + center,
            baseline - (spaced.textBaselines?.first ?: this.baseline), ranges)
    }

    val nativeLength: Int get() = (geometry as? NativeFloatGeometry)?.nativeRubyShapingSource?.length ?: 0
    fun baseText(): String = (geometry as? NativeFloatGeometry)?.nativeRubyLineBaseText(line).orEmpty()

    fun advance(from: Int, to: Int): Float {
        if (from == to) return 0f
        val edges = padding?.format?.padding
        return (geometry as NativeFloatGeometry).nativeRubyMeasuredAdvance(from, to) +
            (if (from == 0) edges?.left ?: 0f else 0f) +
            (if (to == nativeLength) edges?.right ?: 0f else 0f)
    }

    fun opportunities(): List<NativeRubyReadingCut> {
        val native = (geometry as? NativeFloatGeometry)?.nativeRubyShapingSource
            ?: return listOf(NativeRubyReadingCut(0, 0f))
        if (native.getSpans(0, native.length, NativeAuthoredTextWrap::class.java).any { it.wrap == TextWrap.NoWrap })
            return listOf(NativeRubyReadingCut(0, 0f), NativeRubyReadingCut(native.length, advance))
        val breaks = native.getSpans(0, native.length, NativeRubyBreaks::class.java).singleOrNull()?.boundaries
        val lines = BreakIterator.getLineInstance(format.paint.textLocale).apply { setText(native.toString()) }
        val clusters = android.icu.text.BreakIterator.getCharacterInstance(format.paint.textLocale).apply { setText(native.toString()) }
        val replacements = nativeInlineRanges(native, ReplacementSpan::class.java)
        return (listOf(0) + (1 until native.length).filter { offset ->
            (breaks?.contains(offset) ?: lines.isBoundary(offset)) && clusters.isBoundary(offset) &&
                replacements.none { offset > it.start && offset < it.end }
        } + native.length).map { NativeRubyReadingCut(it, advance(0, it)) }
    }

    fun emergencyOpportunities(): List<NativeRubyReadingCut> {
        val geometry = geometry as? NativeFloatGeometry ?: return emptyList()
        val source = geometry.nativeRubyShapingSource
        val ranges = nativeInlineRanges(source, NativeAuthoredTextWrap::class.java)
        if (ranges.none { it.value.wrap == TextWrap.BreakWord } || ranges.any { it.value.wrap == TextWrap.NoWrap })
            return emptyList()
        val policy = NativeTextWrapPlan.create(source, geometry.nativeRubyShapingPaint) ?: return emptyList()
        // Absent Ruby policy is ordinary-only. An unrelated authored word must
        // not grant its emergency permission to an unowned neighboring word.
        return geometry.nativeRubyEmergencyLineEnds().filter { offset ->
            policy.permitsEmergencyBreak(offset) && policy.words.any { word ->
                offset > word.start && offset < word.visibleEnd && ranges.any { range ->
                    range.value.wrap == TextWrap.BreakWord && range.start < word.visibleEnd && range.end > word.start
                }
            }
        }.map { NativeRubyReadingCut(it, advance(0, it)) }
    }

    /** A boundary between declared base boxes uses each box's own shaped edge.
     * No synthetic concatenation may create a cluster or borrow the peer's policy. */
    fun permitsEmergencyEdge(after: Boolean): Boolean {
        val geometry = geometry as? NativeFloatGeometry ?: return false
        if (baseText().none { it !in " \t\r\n" && !nativeRubyBidiControl(it) }) return false
        val source = geometry.nativeRubyShapingSource
        val ranges = nativeInlineRanges(source, NativeAuthoredTextWrap::class.java)
        if (ranges.any { it.value.wrap == TextWrap.NoWrap }) return false
        val indices = if (after) source.indices.reversed() else source.indices.toList()
        val edge = indices.firstOrNull { source[it] !in " \t\r\n" && !nativeRubyBidiControl(source[it]) } ?: return false
        val policy = ranges.filter { edge >= it.start && edge < it.end }
            .minByOrNull { if (it.value.inheritedOwner) 1 else 0 }?.value?.wrap
        if (policy != TextWrap.BreakWord) return false
        val plan = NativeTextWrapPlan.create(source, geometry.nativeRubyShapingPaint) ?: return false
        return plan.noWrap == null && plan.words.any { edge >= it.start && edge < it.visibleEnd && !it.normal }
    }

}

internal data class NativeRubyUnit(val first: Int, val end: Int,
    val bases: Map<Int, NativeRubyRow>, val readings: Map<Int, NativeRubyRow>,
    val readingStarts: Set<Int>, val widths: List<Float>, val gaps: List<Float>,
    val key: NativeRubyFragmentKey?, val continues: Boolean,
    val association: NativeRubyAssociation? = null)

internal data class NativeRubyRowCut(val native: Int, val nested: NativeRubyBaseCut? = null)
internal data class NativeRubyRowProgress(val offset: Int, val nested: NativeRubyAssociationProgress? = null)
internal data class NativeRubyAssociationProgress(val cursor: NativeRubyBreakCursor,
    val bases: Map<Int, NativeRubyRowProgress>, val readings: Map<Int, NativeRubyRowProgress>)
internal class NativeRubyRowSlice(val plan: NativeRubyRowPlan, val from: Int, val to: Int,
    val columns: Map<Int, NativeRubyColumnSelection>, val advance: Float, val next: NativeRubyRowProgress)
internal class NativeRubyColumnSelection(val owner: NativeRubyAssociation,
    val from: NativeRubyBaseCut, val to: NativeRubyBaseCut,
    val bases: Map<Int, NativeRubyRowSlice>, val readings: Map<Int, NativeRubyRowSlice>,
    val widths: List<Float>, val gaps: List<Float>, val next: NativeRubyAssociationProgress) {
    val advance: Float get() = widths.sum() + gaps.sum()
}

/** Endpoint ranks belong only to this plan. An interior nested endpoint carries its
 * original association cut; it is never passed to an Android UTF-16 API. */
internal class NativeRubyRowPlan(val row: NativeRubyRow) {
    private val geometry = row.geometry as? NativeFloatGeometry
    private val columns = geometry?.nativeRubyColumns.orEmpty().associateBy { it.nativeStart }
    private val noWrap = geometry?.nativeRubyShapingSource?.let { source ->
        source.getSpans(0, source.length, NativeAuthoredTextWrap::class.java).any { it.wrap == TextWrap.NoWrap }
    } == true
    private val ordinaryOffsets = row.opportunities().map { it.offset }.toSet()
    val cuts: List<NativeRubyRowCut> = buildList {
        (ordinaryOffsets + row.emergencyOpportunities().map { it.offset }).forEach { add(NativeRubyRowCut(it)) }
        columns.values.forEach { piece -> piece.column.association?.let { association ->
            if (!noWrap && !association.noWrap) association.cuts.drop(1).dropLast(1).forEach {
                add(NativeRubyRowCut(piece.nativeStart, it))
            }
        } }
    }.distinct().sortedWith(compareBy<NativeRubyRowCut>({ it.native },
        { if (it.nested == null) -1 else it.nested.baseIndex }, { it.nested?.offset ?: -1 }))
    val length: Int get() = cuts.lastIndex
    val opportunities: List<NativeRubyReadingCut> = cuts.mapIndexed { index, cut ->
        val prefix = row.advance(0, cut.native)
        val part = cut.nested?.let { nested ->
            val column = checkNotNull(columns[cut.native]).column
            val owner = checkNotNull(column.association)
            val total = owner.cuts.last().advance
            if (total > 0f) column.advance * nested.advance / total else 0f
        } ?: 0f
        NativeRubyReadingCut(index, prefix + part)
    }

    fun permits(offset: Int, stage: NativeRubyBreakStage): Boolean {
        val cut = cuts[offset]
        return if (cut.nested == null) cut.native in ordinaryOffsets || stage == NativeRubyBreakStage.Emergency
        else checkNotNull(columns[cut.native]?.column?.association).permits(cut.nested, stage)
    }

    fun opportunities(stage: NativeRubyBreakStage, current: Int): List<NativeRubyReadingCut> = opportunities.filter {
        it.offset == current || it.offset == 0 || it.offset == length || permits(it.offset, stage)
    }

    fun <T> select(from: NativeRubyRowProgress, to: Int, available: Float,
        stage: NativeRubyBreakStage,
        consume: (NativeRubyRowSlice) -> NativeRubyBreakCandidate<T>?): NativeRubyBreakCandidate<T>? {
        require(from.offset in 0..length && to in from.offset..length)
        val begin = cuts[from.offset]; val end = cuts[to]
        val nativeEnd = end.native + if (end.nested != null) 1 else 0
        val included = columns.values.filter { it.nativeStart >= begin.native && it.nativeEnd <= nativeEnd }
            .sortedBy { it.nativeStart }
        val selected = linkedMapOf<Int, NativeRubyColumnSelection>()
        val originalAdvance = row.advance(begin.native, nativeEnd)
        fun choose(index: Int): NativeRubyBreakCandidate<T>? {
            if (index == included.size) {
                val replaced = selected.keys.sumOf { at ->
                    checkNotNull(geometry).nativeRubyMeasuredAdvance(at, at + 1).toDouble()
                }
                val advance = (originalAdvance.toDouble() - replaced +
                    selected.values.sumOf { if (geometry?.nativeRubyExactAdvances == true) it.advance.toDouble() else ceil(it.advance.toDouble()) }).toFloat()
                if (!advance.isFinite() || advance < 0f || advance > TablePixelLimit)
                    throw UnsupportedFloatLayout("Ruby recursive fragment exceeds native coordinates")
                val progress = NativeRubyRowProgress(to,
                    if (end.nested != null) checkNotNull(selected[end.native]).next else null)
                return consume(NativeRubyRowSlice(this, from.offset, to, selected.toMap(), advance, progress))
            }
            val piece = included[index]
            val association = piece.column.association
            if (association == null) {
                // This is an intact already-resolved native column. It contributes its
                // original width and cannot expose an invented interior endpoint.
                return choose(index + 1)
            }
            val initial = if (begin.nested != null && piece.nativeStart == begin.native)
                checkNotNull(from.nested) else association.initial
            val target = if (end.nested != null && piece.nativeStart == end.native) end.nested else association.cuts.last()
            return association.select(initial, target, available, stage) { column ->
                selected[piece.nativeStart] = column
                try { choose(index + 1) } finally { selected.remove(piece.nativeStart) }
            }
        }
        return choose(0)
    }
}

/** A continuation is immutable original-row progress, including every nested reading.
 * Candidate evaluation may reject a tuple without consuming any part of that source. */
internal class NativeRubyAssociation(val path: String, val first: Int, val end: Int,
    val baseRows: List<NativeRubyRow>, val readingRows: List<NativeRubyRow>,
    val ranges: List<RubyTextRange>, val sourceGaps: List<Float>, val readingGaps: List<Float>,
    private val boundaries: Set<Int>, private val emergencyBoundaries: Set<Int>,
    val noWrap: Boolean, val render: (NativeRubyUnit) -> NativeRubyColumn) {
    val bases = (first until end).associateWith { NativeRubyRowPlan(baseRows[it]) }
    val indices = ranges.indices.filter { index -> checkNotNull(ranges[index].annotation).let {
        it.baseStart >= first && it.baseStart + it.baseCount <= end
    } }
    val readings = indices.associateWith { NativeRubyRowPlan(readingRows[it]) }
    val cuts: List<NativeRubyBaseCut> = buildList {
        add(NativeRubyBaseCut(0, 0, 0f))
        var advance = 0f
        for (index in first until end) {
            if (index > first) advance += sourceGaps[index]
            val row = checkNotNull(bases[index])
            row.opportunities.filter { it.offset > 0 && it.offset < row.length }.forEach {
                add(NativeRubyBaseCut(index - first, it.offset, advance + it.advance))
            }
            advance += baseRows[index].advance
            if (index + 1 == end || index + 1 in boundaries || index + 1 in emergencyBoundaries)
                add(NativeRubyBaseCut(index + 1 - first, 0, advance))
        }
    }
    val tracks: List<NativeRubyReadingBreak> = indices.map { index ->
        val annotation = checkNotNull(ranges[index].annotation)
        val row = checkNotNull(readings[index])
        NativeRubyReadingBreak(index, annotation.baseStart.toInt() - first, annotation.baseCount.toInt(),
            row.length, row.opportunities)
    }
    fun permits(cut: NativeRubyBaseCut, stage: NativeRubyBreakStage): Boolean = if (cut.offset == 0)
        cut.baseIndex == 0 || cut.baseIndex == end - first || first + cut.baseIndex in boundaries ||
            stage == NativeRubyBreakStage.Emergency && first + cut.baseIndex in emergencyBoundaries
        else checkNotNull(bases[first + cut.baseIndex]).permits(cut.offset, stage)
    val initial: NativeRubyAssociationProgress get() = NativeRubyAssociationProgress(
        NativeRubyBreakCursor(cuts.first(), indices.associateWith { 0 }),
        bases.keys.associateWith { NativeRubyRowProgress(0) }, readings.keys.associateWith { NativeRubyRowProgress(0) })

    private fun baseSlices(from: NativeRubyBaseCut, to: NativeRubyBaseCut): Map<Int, NativeRubySourceSlice> =
        (first + from.baseIndex until first + to.baseIndex + (if (to.offset > 0) 1 else 0)).associateWith { index ->
            NativeRubySourceSlice(if (index == first + from.baseIndex) from.offset else 0,
                if (index == first + to.baseIndex) to.offset else checkNotNull(bases[index]).length)
        }

    fun <T> select(progress: NativeRubyAssociationProgress, exactEnd: NativeRubyBaseCut?, available: Float,
        stage: NativeRubyBreakStage,
        consume: (NativeRubyColumnSelection) -> NativeRubyBreakCandidate<T>?): NativeRubyBreakCandidate<T>? {
        // Both stages use the same immutable endpoint ranks and continuation.
        // A prior emergency cursor remains a valid origin in the ordinary view.
        val selectedCuts = cuts.filter { it == progress.cursor.baseFrom || permits(it, stage) }
        val selectedTracks = tracks.map { track -> track.copy(opportunities = checkNotNull(readings[track.id])
            .opportunities(stage, checkNotNull(progress.cursor.readingOffsets[track.id]))) }
        val step = nativeRubyNextBreak(end - first, selectedCuts, selectedTracks, progress.cursor, available) { from, to, slices ->
            if (exactEnd != null && to != exactEnd) return@nativeRubyNextBreak null
            val selectedBases = baseSlices(from, to)
            val selected = selectedBases.map { (index, slice) -> Triple(false, index, slice) } +
                slices.map { (index, slice) -> Triple(true, index, slice) }
            val baseParts = linkedMapOf<Int, NativeRubyRowSlice>()
            val readingParts = linkedMapOf<Int, NativeRubyRowSlice>()
            fun choose(index: Int): NativeRubyBreakCandidate<T>? {
                if (index == selected.size) {
                    val a = selectedBases.keys.first(); val b = selectedBases.keys.last() + 1
                    val gaps = (a until b).map { if (it == a) 0f else sourceGaps[it] }
                    val constraints = readingParts.map { (id, part) ->
                        val annotation = checkNotNull(ranges[id].annotation)
                        val left = maxOf(a, annotation.baseStart.toInt())
                        val right = minOf(b, annotation.baseStart.toInt() + annotation.baseCount.toInt())
                        NativeRubyWidthConstraint(left - a, right - left,
                            part.advance + if (part.from == 0) readingGaps[id] else 0f)
                    }
                    val widths = nativeRubyColumnWidths((a until b).map { checkNotNull(baseParts[it]).advance }, gaps, constraints)
                    val next = NativeRubyAssociationProgress(NativeRubyBreakCursor(to,
                        progress.cursor.readingOffsets + slices.mapValues { it.value.to }),
                        progress.bases + baseParts.mapValues { it.value.next },
                        progress.readings + readingParts.mapValues { it.value.next })
                    return consume(NativeRubyColumnSelection(this, from, to, baseParts.toMap(),
                        readingParts.toMap(), widths, gaps, next))
                }
                val (reading, id, slice) = selected[index]
                val plan = checkNotNull(if (reading) readings[id] else bases[id])
                val before = checkNotNull(if (reading) progress.readings[id] else progress.bases[id])
                require(before.offset == slice.from)
                return plan.select(before, slice.to, available, stage) { part ->
                    val parts = if (reading) readingParts else baseParts
                    parts[id] = part
                    try { choose(index + 1) } finally { parts.remove(id) }
                }
            }
            choose(0)
        } ?: return null
        return NativeRubyBreakCandidate(step.fragment.width, step.certificate)
    }
}

/** Only the chosen certificates reach this pass. Each original native row is rebuilt
 * once with all its selected cuts, retaining its complete shaping context and source. */
private class NativeRubyMaterializer(selections: List<NativeRubyColumnSelection>) {
    private val byPlan = java.util.IdentityHashMap<NativeRubyRowPlan, MutableList<NativeRubyRowSlice>>()
    private val rows = java.util.IdentityHashMap<NativeRubyRowSlice, NativeRubyRow>()
    private val columns = java.util.IdentityHashMap<NativeRubyColumnSelection, NativeRubyColumn>()
    init {
        fun collect(selection: NativeRubyColumnSelection) {
            (selection.bases.values + selection.readings.values).forEach { slice ->
                byPlan.getOrPut(slice.plan) { mutableListOf() }.add(slice)
                slice.columns.values.forEach(::collect)
            }
        }
        selections.forEach(::collect)
    }

    fun column(selection: NativeRubyColumnSelection): NativeRubyColumn = columns.getOrPut(selection) {
        selection.owner.render(unit(selection))
    }

    fun unit(selection: NativeRubyColumnSelection): NativeRubyUnit {
        val owner = selection.owner
        val first = selection.bases.keys.first(); val end = selection.bases.keys.last() + 1
        return NativeRubyUnit(first, end, selection.bases.mapValues { row(it.value) },
            selection.readings.mapValues { row(it.value) }, selection.readings.filterValues { it.from == 0 }.keys,
            selection.widths, selection.gaps, NativeRubyFragmentKey(owner.path, first, selection.from.offset),
            selection.to != owner.cuts.last(),
            if (selection.from == owner.cuts.first() && selection.to == owner.cuts.last()) owner else null)
    }

    private fun row(slice: NativeRubyRowSlice): NativeRubyRow {
        rows[slice]?.let { return it }
        val plan = slice.plan
        val parts = checkNotNull(byPlan[plan]).sortedBy { it.from }
        require(parts.first().from == 0 && parts.last().to == plan.length &&
            parts.zipWithNext().all { (a, b) -> a.to == b.from })
        if (plan.row.padding != null) {
            if (parts.size != 1 || parts.single().from != 0 || parts.single().to != plan.length)
                throw UnsupportedFloatLayout("Inline padding group requires native fragmentation")
            rows[parts.single()] = plan.row
            return checkNotNull(rows[slice])
        }
        if (plan.length == 0) {
            require(parts.size == 1)
            rows[parts.single()] = plan.row
            return checkNotNull(rows[slice])
        }
        val geometry = plan.row.geometry as NativeFloatGeometry
        val chosen = linkedMapOf<Int, MutableList<NativeRubyColumnSelection>>()
        parts.forEach { part -> part.columns.forEach { (at, value) -> chosen.getOrPut(at) { mutableListOf() }.add(value) } }
        val replacements = chosen.mapValues { (_, values) -> values.map(::column) }
        fun mapped(offset: Int): Int = offset + replacements.entries.filter { it.key < offset }.sumOf { it.value.size - 1 }
        val ends = parts.map { part ->
            val end = plan.cuts[part.to]
            if (end.nested == null) mapped(end.native) else {
                val selected = checkNotNull(part.columns[end.native])
                val ordinal = checkNotNull(chosen[end.native]).indexOfFirst { it === selected }
                check(ordinal >= 0)
                mapped(end.native) + ordinal + 1
            }
        }
        val shaped = geometry.nativeRubyReflowColumns(replacements, ends, parts.map { it.advance })
        val primary = NativePrimaryFontMetrics.from(plan.row.format.paint)
        val natural = NativeUsedLineMetrics(primary.ascent, primary.descent)
        parts.forEachIndexed { line, part ->
            rows[part] = plan.row.copy(geometry = shaped, line = line,
                advance = shaped.nativeLineAdvance(line), baseline = shaped.nativeRubyLineBaseline(line),
                used = shaped.nativeUsedLineMetrics(line), content = natural.including(shaped.nativeContentLineMetrics(line)),
                ranges = shaped.nativeRubyLineRanges(line).map { (first, last) -> plan.row.start + first to plan.row.start + last })
        }
        return checkNotNull(rows[slice])
    }
}

/** The metadata compiler is local to this one immutable shape. It creates no Compose,
 * image, focus, action, or lifecycle owner and never changes the public source buffer. */
internal fun nativeRubyLayout(source: Spanned, paint: TextPaint,
    direction: TextDirectionHeuristic, bands: NativeRubyBands? = null, exactAdvances: Boolean = false): NativeRubyLayout? {
    val markers = nativeInlineRanges(source, NativeRubyPreparedSource::class.java).sortedBy { it.start }
    if (markers.isEmpty()) return null
    if (markers.any { it.start < 0 || it.end < it.start || it.end > source.length ||
            source.subSequence(it.start, it.end).toString() != it.value.projection.text } ||
        markers.zipWithNext().any { (a, b) -> a.end > b.start })
        throw UnsupportedFloatLayout("Ruby preparation lost its exact aggregate source range")
    val compiler = NativeRubyCompiler(source, paint, direction, bands, exactAdvances)
    var cursor = 0
    markers.forEach { marker ->
        compiler.text(cursor, marker.start)
        compiler.prepared(marker.value, marker.start)
        cursor = marker.end
    }
    compiler.text(cursor, source.length)
    return compiler.finish()
}

private class NativeRubyCompiler(private val original: Spanned, private val paint: TextPaint,
    private val direction: TextDirectionHeuristic, private val bands: NativeRubyBands?,
    private val exactAdvances: Boolean) {
    private val native = SpannableStringBuilder()
    private val pieces = mutableListOf<NativeRubyPiece>()
    private val breakText = StringBuilder()
    private val breakEdges = mutableMapOf(0 to 0)
    private val omitted = mutableSetOf<Int>()
    private val collapsedSpaces = mutableSetOf<Int>()
    private val protectedSpaces = mutableSetOf<Int>()
    private val ownerWraps = mutableListOf<NativeInlineRange<NativeAuthoredTextWrap>>()
    private val actionScopes = mutableListOf<NativeRubyActionScope>()
    private val boxScopes = mutableListOf<NativeRubyBoxScope>()
    private data class ActionContext(val range: RubyTextRange, val format: NativeRubyGroupFormat,
        val script: NativeRubyScriptState, val shift: Float, val rtl: Boolean, val styled: Spanned)

    fun text(start: Int, end: Int, collapsed: Boolean = false, styled: Spanned? = null,
        collapsedText: String = " ",
        groupPaint: NativeRubyGapPaint? = null, preservePoint: Boolean = false) {
        require(start in 0..original.length && end in start..original.length)
        if (start == end && !preservePoint) return
        if (!collapsed && (start until end).any { it in omitted || it in collapsedSpaces }) {
            var first = start
            while (first < end) {
                val discarded = first in omitted
                val space = first in collapsedSpaces
                var last = first + 1
                while (last < end && (last in omitted) == discarded && (last in collapsedSpaces) == space) last++
                text(first, last, collapsed = discarded || space, collapsedText = if (discarded) "" else " ",
                    styled = styled?.subSequence(first - start, last - start) as? Spanned, groupPaint = groupPaint)
                first = last
            }
            return
        }
        if (collapsed) validateCollapsedGap(original, start, end, paint)
        val first = native.length
        require(collapsedText.isEmpty() || collapsedText == " ")
        val value = if (collapsed) {
            if ((start until end).all { it in omitted }) "" else collapsedText
        } else original.subSequence(start, end).toString()
        native.append(value)
        require(styled == null || styled.toString() == original.subSequence(start, end).toString())
        val leaf = if (collapsed && value.isNotEmpty()) nativeRubyGapLeaf(styled ?: SpannedString(original.subSequence(start, end)), paint) else null
        pieces += NativeRubyPiece.Text(start, end, first, native.length, collapsed, styled?.let(::SpannedString), groupPaint,
            leafPaint = leaf, protectedEdge = start in protectedSpaces)
        val baseStart = breakText.length
        breakText.append(value)
        if (collapsed) {
            breakEdges[baseStart] = first; breakEdges[breakText.length] = native.length
        } else for (offset in 0..value.length) breakEdges[baseStart + offset] = first + offset
    }

    private fun isolate(rtl: Boolean, body: () -> Unit) {
        native.append(if (rtl) '\u2067' else '\u2066')
        body()
        native.append('\u2069')
        breakEdges[breakText.length] = native.length
    }

    fun prepared(prepared: NativeRubyPreparedSource, sourceStart: Int) {
        prepared.visualOmissions.forEach { (first, last) -> for (offset in first until last) omitted += sourceStart + offset }
        prepared.visualSpaces.forEach { collapsedSpaces += sourceStart + it }
        prepared.protectedSpaces.forEach { protectedSpaces += sourceStart + it }
        emitPrepared(prepared, sourceStart, null)
    }

    private fun emitPrepared(prepared: NativeRubyPreparedSource, sourceStart: Int, context: ActionContext?) {
        val ranges = prepared.projection.ranges.filter { context == null || it.path.startsWith(context.range.path + "/") }
        val structural = ranges.filter { it.role in setOf(RubyTextRole.Owner, RubyTextRole.ActionGroup, RubyTextRole.BoxGroup) }
        val owners = structural.filter { candidate -> structural.none { candidate.path.startsWith(it.path + "/") } }
        if (ranges.any { it.role == RubyTextRole.PaddingGroup &&
                owners.none { owner -> it.path.startsWith(owner.path + "/") } })
            throw UnsupportedFloatLayout("Inline padding group requires a complete ruby annotation")
        val leaves = ranges.filter { it.span != null && it.role !in setOf(RubyTextRole.Owner,
            RubyTextRole.PaddingGroup, RubyTextRole.ActionGroup, RubyTextRole.BoxGroup) &&
            owners.none { owner -> it.path.startsWith(owner.path + "/") } }
        val events = (owners + leaves).sortedWith(compareBy({ it.start }, {
            if (it.role in setOf(RubyTextRole.Owner, RubyTextRole.ActionGroup, RubyTextRole.BoxGroup)) 0 else 1 }))
        val rootText = buildString {
            events.forEach { range ->
                if (range.role == RubyTextRole.Owner || prepared.groups[range.path]?.box?.atomicLayout != null ||
                    range.span?.usesInlineDirectionIsolate() == true ||
                    range.span?.citationMarker?.isolation != null) append('\ufffc')
                else if (range.role in setOf(RubyTextRole.ActionGroup, RubyTextRole.BoxGroup)) append(directText(prepared, range))
                else append(prepared.projection.text, range.start, range.end)
            }
        }
        val fallbackRtl = context?.rtl ?: direction.isRtl(rootText, 0, rootText.length)
        events.forEach { range -> when (range.role) {
            RubyTextRole.Owner -> owner(prepared, range, sourceStart, fallbackRtl,
                context?.script, context?.shift ?: 0f)
            RubyTextRole.ActionGroup, RubyTextRole.BoxGroup -> action(prepared, range, sourceStart, context, fallbackRtl)
            else -> {
                val span = checkNotNull(range.span)
                fun emitPart(first: Int, last: Int) = text(sourceStart + first, sourceStart + last,
                    styled = context?.styled?.subSequence(first - context.range.start,
                        last - context.range.start) as? Spanned, preservePoint = context != null)
                val emit = { emitPart(range.start, range.end) }
                val marker = span.citationMarker
                val firstPiece = pieces.size
                if (marker?.isolation != null) {
                    // A real LF ends a native bidi paragraph. Reopen the stored isolate
                    // on its next actual text without adding any public source character.
                    val rtl = marker.isolation == BidiResolvedDirection.Rtl
                    var first = range.start
                    while (first < range.end) {
                        val lf = prepared.projection.text.indexOf('\n', first)
                            .let { if (it < 0 || it >= range.end) range.end else it }
                        if (first < lf) isolate(rtl) { emitPart(first, lf) }
                        if (lf < range.end) emitPart(lf, lf + 1)
                        first = lf + 1
                    }
                } else if (span.usesInlineDirectionIsolate()) isolate(resolveDirection(span.direction,
                    prepared.projection.text.substring(range.start, range.end),
                    nativeClippedParagraphDirectionAt(original, sourceStart + range.start)?.let { it == BidiResolvedDirection.Rtl }
                        ?: fallbackRtl), emit)
                else emit()
                if (marker != null) {
                    val body = pieces.drop(firstPiece).filterIsInstance<NativeRubyPiece.Text>()
                    val first = body.firstOrNull()?.nativeStart
                    val last = body.lastOrNull()?.nativeEnd
                    if (first != null && last != null && first < last)
                        native.setSpan(NativeCitationMarkerSpan(marker), first, last, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
                }
            }
        } }
    }

    private fun action(prepared: NativeRubyPreparedSource, range: RubyTextRange, sourceStart: Int,
        parent: ActionContext?, enclosingRtl: Boolean) {
        val format = checkNotNull(prepared.groups[range.path])
        val box = format.box
        if (box?.atomicLayout != null) {
            if (parent != null || range.role != RubyTextRole.BoxGroup)
                throw UnsupportedFloatLayout("Atomic inline box requires its original independent group")
            atomicBox(prepared, range, sourceStart, atomicParentRtl(prepared, sourceStart + range.start))
            return
        }
        val key = format.actionOwner
        if (range.role == RubyTextRole.ActionGroup) require(key != null && box == null)
        else {
            require(range.role == RubyTextRole.BoxGroup && box != null &&
                box.owner.span === range.span && box.owner.path == range.path)
            val descendants = prepared.projection.ranges.filter { it.path.startsWith(range.path + "/") }
            val nested = descendants.filter { it.role == RubyTextRole.BoxGroup }
            val paired = nested.isNotEmpty() || parent?.format?.box != null
            if (paired && (nested.isNotEmpty() && parent != null && parent.format.box == null ||
                    prepared.projection.ranges.any { ancestor -> range.path.startsWith(ancestor.path + "/") &&
                        ancestor.role in setOf(RubyTextRole.Owner, RubyTextRole.PaddingGroup, RubyTextRole.ActionGroup) }))
                throw UnsupportedFloatLayout("Nested inline decoration cannot inherit a structural action or ruby owner")
            if (descendants.any { it.role in setOf(RubyTextRole.Owner, RubyTextRole.PaddingGroup, RubyTextRole.ActionGroup) } ||
                nested.size > 1 || nested.any { it.start <= range.start || it.end >= range.end } ||
                nested.isNotEmpty() && descendants.any { child -> child.span?.let {
                    it.kind != "text" || it.usesInlineDirectionIsolate() || it.image != null || it.citationMarker != null
                } == true })
                throw UnsupportedFloatLayout("Inline box needs ordinary children or one strict interior static decoration")
        }
        require(key == null || key.span === range.span && key.path == range.path)
        val placement = nativeRubyBaselinePlacement(nativeRubyScriptMode(range), format.baselineShift,
            format.localBaselineShift, parent?.script ?: prepared.parentScript)
        val shift = (parent?.shift ?: 0f) + placement.local
        if (!shift.isFinite() || kotlin.math.abs(shift) > TablePixelLimit)
            throw UnsupportedFloatLayout("Inline action baseline exceeds native coordinates")
        val rtl = resolveDirection(format.sourceDirection, directText(prepared, range), enclosingRtl)
        if (box != null && parent?.format?.box != null &&
            (parent.rtl || rtl || !nativeInlineBoxNestedPair(
                NativeInlineBoxSpan(parent.format, parent.shift, null), NativeInlineBoxSpan(format, shift, null))))
            throw UnsupportedFloatLayout("Nested inline decoration lost its static equal-metric LTR context")
        val nestedDecoration = box != null && (parent?.format?.box != null ||
            prepared.projection.ranges.any { it.role == RubyTextRole.BoxGroup && it.path.startsWith(range.path + "/") })
        val absolute = SpannedString(prepared.source.subSequence(range.start, range.end))
        val styled = nativeRubyLocalSource(absolute, format.paint, placement.state, format.lineHeight, shift) { offset ->
            prepared.projection.ranges.lastOrNull { it.span != null &&
                it.role !in setOf(RubyTextRole.Owner, RubyTextRole.PaddingGroup, RubyTextRole.ActionGroup, RubyTextRole.BoxGroup) &&
                (range.start + offset >= it.start && range.start + offset < it.end ||
                    it.start == it.end && range.start + offset == it.start) }?.let(::nativeRubyScriptMode)
                ?: placement.state.mode
        }
        // Every ordinary descendant keeps its original complete paint, while its
        // inherited run policy is measured in this declaring group's placement.
        styled.getSpans(0, styled.length, NativeRunLineMetrics::class.java).forEach(styled::removeSpan)
        val cuts = (listOf(0, styled.length) + styled.getSpans(0, styled.length, MetricAffectingSpan::class.java)
            .flatMap { listOf(styled.getSpanStart(it), styled.getSpanEnd(it)) }).distinct().sorted()
        cuts.zipWithNext().forEach { (first, last) ->
            if (first < last && styled.getSpans(first, last, NativeAuthoredInlineMetrics::class.java).none {
                    styled.getSpanStart(it) <= first && styled.getSpanEnd(it) >= last
                }) {
                val measured = TextPaint(format.paint)
                styled.getSpans(first, last, MetricAffectingSpan::class.java).forEach { it.updateMeasureState(measured) }
                styled.setSpan(NativeRunLineMetrics(NativePrimaryFontMetrics.from(measured), format.lineHeight),
                    first, last, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
            }
        }
        if (nestedDecoration) {
            val primary = NativePrimaryFontMetrics.from(format.paint)
            if (rtl || shift != 0f || styled.getSpans(0, styled.length, NativeAuthoredBaselineShift::class.java).any { it.shift != 0f } ||
                styled.getSpans(0, styled.length, NativeAuthoredUnderline::class.java).isNotEmpty() ||
                styled.getSpans(0, styled.length, NativeAuthoredTextWrap::class.java).isNotEmpty() ||
                styled.getSpans(0, styled.length, NativeAuthoredInlineMetrics::class.java).any {
                    it.primary != primary || it.policy != format.lineHeight ||
                        it.declaringPrimary != null && it.declaringPrimary != primary
                } || styled.getSpans(0, styled.length, NativeRunLineMetrics::class.java).any {
                    it.primary != primary || it.policy != format.lineHeight
                }) throw UnsupportedFloatLayout("Nested inline decoration has unequal realized line metrics")
            cuts.zipWithNext().forEach { (start, end) ->
                if (start < end) {
                    val measured = TextPaint(format.paint)
                    styled.getSpans(start, end, MetricAffectingSpan::class.java).forEach { it.updateMeasureState(measured) }
                    if (!measured.equalsForTextMeasurement(format.paint) || measured.bgColor != 0 ||
                        measured.isUnderlineText || measured.isStrikeThruText)
                        throw UnsupportedFloatLayout("Nested inline decoration has unequal realized text metrics")
                }
            }
        }
        val first = native.length
        var point = first
        var bodyEnd = first
        val emit = {
            point = native.length
            emitPrepared(prepared, sourceStart, ActionContext(range, format, placement.state, shift, rtl, styled))
            bodyEnd = native.length
        }
        if (checkNotNull(range.span).usesInlineDirectionIsolate()) isolate(rtl, emit) else emit()
        val padding = prepared.projection.ranges.filter { it.role == RubyTextRole.PaddingGroup &&
            it.path.startsWith(range.path + "/") }.map {
            NativeRubyActionPadding(checkNotNull(it.span), sourceStart + it.start, sourceStart + it.end)
        }
        if (box != null) {
            val firstSource = sourceStart + range.start
            val lastSource = sourceStart + range.end
            val graphemes = android.icu.text.BreakIterator.getCharacterInstance(format.paint.textLocale)
                .apply { setText(original.toString()) }
            if ((box.leftAdvance > 0f || box.rightAdvance > 0f) &&
                (!graphemes.isBoundary(firstSource) || !graphemes.isBoundary(lastSource)))
                throw UnsupportedFloatLayout("Inline box edge is inside a source grapheme")
            boxScopes += NativeRubyBoxScope(firstSource, lastSource, point, bodyEnd, format, shift, parent?.rtl)
        }
        if (key != null) {
            val boxes = prepared.projection.ranges.filter { it.role == RubyTextRole.BoxGroup &&
                it.path.startsWith(range.path + "/") }.map { child ->
                NativeRubyActionBox(checkNotNull(prepared.groups[child.path]?.box).owner,
                    sourceStart + child.start, sourceStart + child.end)
            }
            actionScopes += NativeRubyActionScope(key, sourceStart + range.start, sourceStart + range.end,
                first, native.length, point, format, shift, padding, boxes, box?.owner)
        }
        format.wrap?.let { wrap ->
            // Empty inline boxes have no wrapping text. Only an entirely empty
            // no-wrap paragraph needs the separately authenticated source line.
            if (range.start < range.end || original.isEmpty() && wrap == TextWrap.NoWrap)
                ownerWraps += NativeInlineRange(first, native.length, NativeAuthoredTextWrap(wrap,
                    inheritedOwner = true, sourceLineStarts = if (wrap == TextWrap.NoWrap) listOf(first) else null))
        }
    }

    private val atomicParentText by lazy {
        val result = original.toString().toCharArray()
        val intervals = nativeInlineRanges(original, NativeRubyPreparedSource::class.java).flatMap { marker ->
            marker.value.projection.ranges.filter { range ->
                range.role == RubyTextRole.Owner || marker.value.groups[range.path]?.box?.atomicLayout != null ||
                    range.span?.usesInlineDirectionIsolate() == true || range.span?.citationMarker?.isolation != null
            }.map { marker.start + it.start to marker.start + it.end }
        }.sortedBy { it.first }
        var consumed = 0
        intervals.forEach { (first, last) ->
            for (at in maxOf(first, consumed) until last) if (result[at] != '\n') result[at] = '\ufffc'
            consumed = maxOf(consumed, last)
        }
        String(result)
    }
    private val atomicParentParagraphs by lazy {
        buildList {
            var first = 0
            atomicParentText.forEachIndexed { at, char -> if (char == '\n') { add(first to at); first = at + 1 } }
            add(first to atomicParentText.length)
        }
    }
    private val atomicParentDirections = mutableMapOf<Pair<Int, TextDirectionHeuristic>, Boolean>()
    private fun atomicParentRtl(prepared: NativeRubyPreparedSource, offset: Int): Boolean {
        val found = atomicParentParagraphs.binarySearchBy(offset) { it.first }
        val paragraph = atomicParentParagraphs[if (found >= 0) found else -found - 2]
        return atomicParentDirections.getOrPut(paragraph.first to prepared.direction) {
            prepared.direction.isRtl(atomicParentText, paragraph.first, paragraph.second - paragraph.first)
        }
    }

    private fun atomicBox(prepared: NativeRubyPreparedSource, range: RubyTextRange,
        sourceStart: Int, enclosingRtl: Boolean) {
        if (!exactAdvances) throw UnsupportedFloatLayout("Atomic inline box requires exact native rows")
        val format = checkNotNull(prepared.groups[range.path])
        val atomic = checkNotNull(format.box?.atomicLayout)
        if (format.actionOwner != null || format.sourceDirection !in setOf("", "ltr", "rtl") ||
            prepared.projection.ranges.any { it.path.startsWith(range.path + "/") &&
                it.role in setOf(RubyTextRole.Owner, RubyTextRole.PaddingGroup, RubyTextRole.ActionGroup, RubyTextRole.BoxGroup) })
            throw UnsupportedFloatLayout("Atomic inline box requires the admitted plain source owner")
        val rtl = when (format.sourceDirection) { "ltr" -> false; "rtl" -> true; else -> enclosingRtl }
        val geometry = prepared.atomicChild(range.path, rtl) {
            // A new inner formatting context has its own ASCII-space collapse,
            // strut, line height and wrapping. Outer collapsed maps never enter it.
            val styled = SpannableString(prepared.source.subSequence(range.start, range.end))
            styled.getSpans(0, styled.length, Any::class.java).filter { it !is CharacterStyle }.forEach(styled::removeSpan)
            if (styled.isEmpty() || styled.all { it == ' ' })
                throw UnsupportedFloatLayout("Atomic inline box requires a real inner text line")
            if (styled.any { it.code < 0x20 || it == '\u007f' || it == '\u2028' || it == '\u2029' })
                throw UnsupportedFloatLayout("Atomic inline box contains an unsupported paragraph boundary")
            val childPaint = TextPaint(format.paint).apply { bgColor = 0; baselineShift = 0 }
            styled.setSpan(NativeRunLineMetrics(NativePrimaryFontMetrics.from(childPaint), atomic.lineHeight,
                strut = true, independentNormalStrut = true), 0, styled.length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
            styled.setSpan(NativeAuthoredTextWrap(atomic.wrap, inheritedOwner = true),
                0, styled.length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
            val childDirection = if (rtl) TextDirectionHeuristics.RTL else TextDirectionHeuristics.LTR
            val compiler = NativeRubyCompiler(SpannedString(styled), childPaint, childDirection, null, true)
            var at = 0
            while (at < styled.length) {
                val space = styled[at] == ' '
                var end = at + 1
                while (end < styled.length && (styled[end] == ' ') == space) end++
                if (space) compiler.text(at, end, collapsed = true,
                    collapsedText = if (at == 0 || end == styled.length) "" else " ")
                else compiler.text(at, end)
                at = end
            }
            val compiled = compiler.finish()
            val alignment = when (atomic.textAlign) {
                InlineBoxOverlayTextAlign.Start -> Layout.Alignment.ALIGN_NORMAL
                InlineBoxOverlayTextAlign.Left -> if (rtl) Layout.Alignment.ALIGN_OPPOSITE else Layout.Alignment.ALIGN_NORMAL
                InlineBoxOverlayTextAlign.Right -> if (rtl) Layout.Alignment.ALIGN_NORMAL else Layout.Alignment.ALIGN_OPPOSITE
                InlineBoxOverlayTextAlign.Center -> Layout.Alignment.ALIGN_CENTER
            }
            val contentWidth = atomic.allocation.contentWidth
            val raw = NativeFloatGeometry.build(compiled.native, childPaint, kotlin.math.floor(contentWidth).toInt(),
                emptyList(), alignment = alignment, textDirection = childDirection,
                includeFontPadding = false, exactAvailableWidth = contentWidth)
            raw.withRubyProjection(compiled)
        }
        fun emit() {
            val at = native.length
            val atom = NativeInlineAtomicBox(format, sourceStart + range.start, sourceStart + range.end, geometry)
            native.append('\ufffc')
            pieces += NativeRubyPiece.AtomicBox(at, atom)
            val first = breakText.length
            breakText.append('\ufffc')
            breakEdges[first] = at
            breakEdges[breakText.length] = native.length
        }
        if (checkNotNull(range.span).usesInlineDirectionIsolate()) isolate(rtl, ::emit) else emit()
    }

    private fun resolveDirection(source: String, directText: String, enclosingRtl: Boolean): Boolean = when (source) {
        "ltr" -> false
        "rtl" -> true
        "auto" -> (if (enclosingRtl) TextDirectionHeuristics.FIRSTSTRONG_RTL else TextDirectionHeuristics.FIRSTSTRONG_LTR)
            .isRtl(directText, 0, directText.length)
        else -> enclosingRtl
    }

    private fun directText(prepared: NativeRubyPreparedSource, range: RubyTextRange): String = buildString {
        val candidates = prepared.projection.ranges.filter { candidate ->
            candidate.path.startsWith(range.path + "/") &&
                (candidate.role == RubyTextRole.Owner || candidate.span?.usesInlineDirectionIsolate() == true ||
                    range.role == RubyTextRole.Owner && candidate.role in setOf(RubyTextRole.Base, RubyTextRole.Annotation))
        }
        val nested = candidates.filter { child -> candidates.none { parent -> child.path.startsWith(parent.path + "/") } }
        var cursor = range.start
        nested.sortedBy { it.start }.forEach { child ->
            append(prepared.projection.text, cursor, child.start); append('\ufffc'); cursor = child.end
        }
        append(prepared.projection.text, cursor, range.end)
    }

    private fun row(prepared: NativeRubyPreparedSource, range: RubyTextRange,
        sourceStart: Int, enclosingRtl: Boolean, annotation: Boolean, parentScript: NativeRubyScriptState,
        inheritedWrap: TextWrap? = null): NativeRubyRow {
        if (prepared.projection.ranges.any { it.role == RubyTextRole.ActionGroup && it.path.startsWith(range.path + "/") })
            throw UnsupportedFloatLayout("Inline action inside a ruby child needs native fragment paint")
        if (prepared.projection.ranges.any { it.role == RubyTextRole.BoxGroup && it.path.startsWith(range.path + "/") })
            throw UnsupportedFloatLayout("Inline box inside a ruby child needs native fragment allocation")
        if (prepared.projection.ranges.any { it.span?.citationMarker != null && it.path.startsWith(range.path + "/") })
            throw UnsupportedFloatLayout("Citation marker inside a ruby child needs mapped fragment isolation")
        val format = checkNotNull(prepared.groups[range.path])
        val placement = nativeRubyBaselinePlacement(nativeRubyScriptMode(range), format.baselineShift,
            format.localBaselineShift, parentScript)
        val rtl = resolveDirection(format.sourceDirection, directText(prepared, range), enclosingRtl)
        val primary = NativePrimaryFontMetrics.from(format.paint)
        val natural = NativeUsedLineMetrics(primary.ascent, primary.descent)
        val declaring = if (annotation) natural else primary.authored(format.lineHeight) ?: natural
        val nestedOwners = prepared.projection.ranges.filter { it.role == RubyTextRole.Owner &&
            it.path.startsWith(range.path + "/") }
        val paddingGroups = prepared.projection.ranges.filter { candidate -> candidate.role == RubyTextRole.PaddingGroup &&
            candidate.path.startsWith(range.path + "/") &&
            nestedOwners.none { candidate.path.startsWith(it.path + "/") } }
        if (paddingGroups.isNotEmpty()) {
            val group = paddingGroups.singleOrNull()
                ?: throw UnsupportedFloatLayout("Inline padding group requires a complete ruby annotation")
            if (!annotation || group.start != range.start || group.end != range.end ||
                range.annotation?.spans?.singleOrNull() !== group.span)
                throw UnsupportedFloatLayout("Inline padding group requires a complete ruby annotation")
            val owner = checkNotNull(group.span)
            val groupFormat = checkNotNull(prepared.groups[group.path])
            if (rtl || resolveDirection(groupFormat.sourceDirection, directText(prepared, group), rtl))
                throw UnsupportedFloatLayout("Inline padding group requires a left-to-right annotation")
            val text = prepared.projection.text.substring(group.start, group.end)
            if (text.isEmpty() || text.first().isWhitespace() || text.last().isWhitespace() ||
                prepared.projection.ranges.any { it.path.startsWith(group.path + "/") &&
                    it.role in setOf(RubyTextRole.Owner, RubyTextRole.PaddingGroup) })
                throw UnsupportedFloatLayout("Inline padding group requires a nonempty plain annotation")
            val child = row(prepared, group, sourceStart, rtl, false, placement.state, format.wrap)
            val nativeChild = child.geometry as? NativeFloatGeometry
                ?: throw UnsupportedFloatLayout("Inline padding group lacks native text geometry")
            if (!nativeRubySpacingProfile(nativeChild, child.line).zeroOpportunities)
                throw UnsupportedFloatLayout("Inline padding group requires native spacing distribution")
            val edges = checkNotNull(groupFormat.padding)
            val paddedAdvance = child.advance.toDouble() + edges.left + edges.right
            if (!paddedAdvance.isFinite() || paddedAdvance > TablePixelLimit)
                throw UnsupportedFloatLayout("Inline padding exceeds native coordinates")
            val used = nativeRubyIncludeShifted(natural, child.used, child.localShift)
            val content = nativeRubyIncludeShifted(natural, child.content, child.localShift)
            return NativeRubyRow(sourceStart + range.start, sourceStart + range.end, nativeChild,
                paddedAdvance.toFloat(), child.baseline, used, content, format, placement.state, placement.local,
                padding = NativeRubyRowPadding(owner, groupFormat, child.content, child.localShift, child.advance))
        }
        if (range.start == range.end) return NativeRubyRow(sourceStart + range.start, sourceStart + range.end,
            NativeRubyEmptyGeometry(), 0f, 0f, declaring, natural, format, placement.state, placement.local)
        val absolute = SpannableString(prepared.source.subSequence(range.start, range.end))
        absolute.getSpans(0, absolute.length, NativeRubyPreparedSource::class.java).forEach(absolute::removeSpan)
        val slice = nativeRubyLocalSource(absolute, format.paint, placement.state, format.lineHeight) { offset ->
            prepared.projection.ranges.lastOrNull { it.span != null && it.role !in setOf(RubyTextRole.Owner, RubyTextRole.PaddingGroup, RubyTextRole.ActionGroup, RubyTextRole.BoxGroup) &&
                (range.start + offset >= it.start && range.start + offset < it.end ||
                    it.start == it.end && range.start + offset == it.start) }?.let(::nativeRubyScriptMode)
                ?: placement.state.mode
        }
        slice.getSpans(0, slice.length, NativeRunLineMetrics::class.java).forEach(slice::removeSpan)
        slice.getSpans(0, slice.length, ParagraphStyle::class.java).forEach(slice::removeSpan)
        slice.getSpans(0, slice.length, NativeRubyPreparedSource::class.java).forEach(slice::removeSpan)
        val wraps = slice.getSpans(0, slice.length, NativeAuthoredTextWrap::class.java)
        if (wraps.any { it.wrap == TextWrap.NoWrap }) {
            if (wraps.size != 1 || !wraps.single().inheritedOwner ||
                slice.getSpanStart(wraps.single()) != 0 || slice.getSpanEnd(wraps.single()) != slice.length)
                throw UnsupportedFloatLayout("Ruby no-wrap child has an independent descendant wrap policy")
            wraps.forEach(slice::removeSpan)
            slice.setSpan(NativeAuthoredTextWrap(TextWrap.NoWrap, inheritedOwner = true, sourceLineStarts = listOf(0)),
                0, slice.length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        } else if (format.wrap != null || inheritedWrap != null) {
            wraps.filter { it.inheritedOwner }.forEach(slice::removeSpan)
            slice.setSpan(NativeAuthoredTextWrap(checkNotNull(format.wrap ?: inheritedWrap), inheritedOwner = true,
                sourceLineStarts = if ((format.wrap ?: inheritedWrap) == TextWrap.NoWrap) listOf(0) else null), 0, slice.length,
                Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        }
        // Annotation line-height is not a strut. This derived height represents
        // the actual declaring primary-font box with exactly zero half-leading;
        // content below still includes Android's real fallback-aware envelope.
        val ownPolicy = if (annotation) NativeLineHeightPolicy.Pixels(natural.height) else format.lineHeight
        slice.setSpan(NativeRunLineMetrics(primary, ownPolicy, strut = true, includePrimaryInNormal = true),
            0, slice.length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        val cuts = (listOf(0, slice.length) + slice.getSpans(0, slice.length, MetricAffectingSpan::class.java).flatMap {
            listOf(slice.getSpanStart(it), slice.getSpanEnd(it))
        } + slice.getSpans(0, slice.length, NativeAuthoredInlineMetrics::class.java).flatMap {
            listOf(slice.getSpanStart(it), slice.getSpanEnd(it))
        }).distinct().sorted()
        for ((start, end) in cuts.zipWithNext()) {
            if (start == end || slice.getSpans(start, end, NativeAuthoredInlineMetrics::class.java).any {
                    slice.getSpanStart(it) <= start && slice.getSpanEnd(it) >= end
                }) continue
            val resolved = TextPaint(format.paint)
            slice.getSpans(start, end, MetricAffectingSpan::class.java).forEach { it.updateMeasureState(resolved) }
            slice.setSpan(NativeRunLineMetrics(NativePrimaryFontMetrics.from(resolved), format.lineHeight),
                start, end, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        }
        val descendants = prepared.projection.ranges.filter { it.path.startsWith(range.path + "/") }
        val omissions = prepared.visualOmissions.mapNotNull { (first, last) ->
            val a = maxOf(first, range.start); val b = minOf(last, range.end)
            if (a < b) (a - range.start) to (b - range.start) else null
        }
        // Even a non-nested group needs its original leaf isolate boundaries and
        // source omissions. The private compiler terminates at those actual leaves.
        run {
            val projection = RubyTextProjection(slice.toString(), descendants.map { it.copy(
                start = it.start - range.start, end = it.end - range.start) })
            val metadata = NativeRubyPreparedSource(projection, absolute, format.paint,
                if (rtl) TextDirectionHeuristics.RTL else TextDirectionHeuristics.LTR, prepared.groups,
                parentScript = placement.state, visualOmissions = omissions,
                visualSpaces = prepared.visualSpaces.filter { it in range.start until range.end }.map { it - range.start }.toSet(),
                visualSpaceNeighbors = prepared.visualSpaceNeighbors.filterKeys { it in range.start until range.end }
                    .mapKeys { it.key - range.start }.mapValues { (_, pair) ->
                        pair.first?.minus(range.start) to pair.second?.minus(range.start)
                    },
                protectedSpaces = prepared.visualSpaces.filter { it in range.start until range.end }.map { it - range.start }.toSet())
            slice.setSpan(metadata, 0, slice.length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        }
        val childDirection = if (rtl) TextDirectionHeuristics.RTL else TextDirectionHeuristics.LTR
        val widths = nativeTextWidthRange(slice, format.paint, textDirection = childDirection)
        if (widths.maximum > TablePixelLimit)
            throw UnsupportedFloatLayout("Ruby child exceeds native shaping width")
        val geometry = NativeFloatGeometry.build(slice, format.paint, widths.maximum, emptyList(),
            textDirection = childDirection, includeFontPadding = false,
            exactAvailableWidth = if (exactAdvances) widths.maximum.toFloat() else null)
        if (geometry.nativeRubyShapingSource.isEmpty()) return NativeRubyRow(sourceStart + range.start, sourceStart + range.end,
            NativeRubyEmptyGeometry(slice.toString()), 0f, 0f, declaring, natural, format, placement.state, placement.local)
        if (geometry.shapedLineCount != 1)
            throw UnsupportedFloatLayout("Ruby child requires an unrepresented forced line")
        val baseline = checkNotNull(geometry.textBaselines?.first)
        val advance = geometry.nativeSingleLineAdvance()
        val used = geometry.nativeUsedLineMetrics(0)
        val content = natural.including(geometry.nativeContentLineMetrics(0))
        return NativeRubyRow(sourceStart + range.start, sourceStart + range.end, geometry,
            advance, baseline, used, content, format, placement.state, placement.local)
    }

    private fun gap(prepared: NativeRubyPreparedSource, path: String): Pair<Int, Int>? {
        val rows = prepared.projection.ranges.filter { it.path.startsWith(path + "/gapBefore/") && it.span != null }
        val contexts = rows.map { checkNotNull(it.span).copy(text = " ", trail = "") }
        if (contexts.distinct().size > 1)
            throw UnsupportedFloatLayout("Collapsed ruby gap has distinct source inline owners")
        if (rows.isEmpty()) return null
        val range = rows.minOf { it.start } to rows.maxOf { it.end }
        nativeRubyGapCollapse(prepared.projection.text.substring(range.first, range.second),
            structurallyDiscarded = false, previousCollapsibleSpace = false,
            followingCollapsibleSpace = false, trimAtLineEdge = false)
        return range
    }

    private fun gapRetained(prepared: NativeRubyPreparedSource, range: Pair<Int, Int>?, retained: Boolean = true): Boolean =
        range != null && range.first < range.second && retained &&
            (range.first until range.second).any { !nativeRubyOmitted(it, prepared.visualOmissions) }

    private fun gapAdvance(prepared: NativeRubyPreparedSource, range: Pair<Int, Int>?, retained: Boolean = true): Float {
        if (!gapRetained(prepared, range, retained)) return 0f
        checkNotNull(range)
        val resolved = TextPaint(prepared.paint)
        prepared.source.getSpans(range.first, minOf(range.first + 1, range.second), MetricAffectingSpan::class.java)
            .forEach { it.updateMeasureState(resolved) }
        return resolved.measureText(" ").also { if (!it.isFinite() || it < 0f || it > TablePixelLimit)
            throw UnsupportedFloatLayout("Ruby gap exceeds native coordinates") }
    }

    private fun externalGap(prepared: NativeRubyPreparedSource, range: Pair<Int, Int>?, sourceStart: Int,
        format: NativeRubyGroupFormat, owner: NativeRubyBaselinePlacement, content: NativeUsedLineMetrics) {
        if (range == null || range.first == range.second) return
        val source = SpannedString(prepared.source.subSequence(range.first, range.second))
        val local = nativeRubyLocalSource(source, format.paint, owner.state, format.lineHeight,
            placement = owner.local) { offset ->
            prepared.projection.ranges.lastOrNull { it.span != null && it.role !in setOf(RubyTextRole.Owner, RubyTextRole.PaddingGroup, RubyTextRole.ActionGroup, RubyTextRole.BoxGroup) &&
                range.first + offset >= it.start && range.first + offset < it.end }?.let(::nativeRubyScriptMode)
                ?: owner.state.mode
        }
        local.getSpans(0, local.length, NativeRunLineMetrics::class.java).forEach(local::removeSpan)
        val resolved = TextPaint(format.paint)
        local.getSpans(0, 1, MetricAffectingSpan::class.java).forEach { it.updateMeasureState(resolved) }
        local.setSpan(NativeRunLineMetrics(NativePrimaryFontMetrics.from(resolved), format.lineHeight),
            0, local.length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        text(sourceStart + range.first, sourceStart + range.second, collapsed = true, styled = local,
            groupPaint = NativeRubyGapPaint(format, owner.local, content))
    }

    private fun gapRow(prepared: NativeRubyPreparedSource, range: Pair<Int, Int>?, sourceStart: Int,
        format: NativeRubyGroupFormat, rtl: Boolean, parentScript: NativeRubyScriptState,
        annotation: Boolean = false, retained: Boolean = true): NativeRubyRow? {
        if (range == null || range.first == range.second) return null
        validateCollapsedGap(prepared.source, range.first, range.second, format.paint)
        val source = SpannedString(prepared.source.subSequence(range.first, range.second))
        if (!retained || (range.first until range.second).all { nativeRubyOmitted(it, prepared.visualOmissions) })
            return NativeRubyRow(sourceStart + range.first, sourceStart + range.second,
            NativeRubyEmptyGeometry(source.toString()), 0f, 0f, NativeUsedLineMetrics(0f, 0f),
            NativeUsedLineMetrics(0f, 0f), format, parentScript, 0f)
        val actualPaint = TextPaint(format.paint)
        source.getSpans(0, 1, MetricAffectingSpan::class.java).forEach { it.updateMeasureState(actualPaint) }
        val actualPrimary = NativePrimaryFontMetrics.from(actualPaint)
        val policy = if (annotation) NativeLineHeightPolicy.Pixels(actualPrimary.descent - actualPrimary.ascent)
            else format.lineHeight
        val local = nativeRubyLocalSource(source, format.paint, parentScript, policy) { offset ->
            prepared.projection.ranges.lastOrNull { it.span != null && it.role !in setOf(RubyTextRole.Owner, RubyTextRole.PaddingGroup, RubyTextRole.ActionGroup, RubyTextRole.BoxGroup) &&
                (range.first + offset >= it.start && range.first + offset < it.end ||
                    it.start == it.end && range.first + offset == it.start) }?.let(::nativeRubyScriptMode)
                ?: parentScript.mode
        }
        val shaped = SpannableString(" ")
        val leafPaint = nativeRubyGapLeaf(local, format.paint)
        local.getSpans(0, 1, CharacterStyle::class.java).forEach {
            shaped.setSpan(nativeRubySpanCopy(it), 0, 1, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        }
        local.getSpans(0, 1, NativeAuthoredBaselineShift::class.java).forEach {
            shaped.setSpan(it.copy(), 0, 1, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        }
        local.getSpans(0, 1, NativeAuthoredInlineMetrics::class.java).forEach {
            shaped.setSpan(it.copy(), 0, 1, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        }
        shaped.setSpan(NativeRubyGapInk(), 0, 1, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        val normalizedPaint = TextPaint(format.paint)
        shaped.getSpans(0, 1, MetricAffectingSpan::class.java).forEach { it.updateMeasureState(normalizedPaint) }
        val primary = NativePrimaryFontMetrics.from(normalizedPaint)
        shaped.setSpan(NativeRunLineMetrics(primary, policy), 0, 1, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        val advance = gapAdvance(prepared, range)
        val raw = NativeFloatGeometry.build(shaped, format.paint,
            if (exactAdvances) kotlin.math.floor(advance).toInt() else ceil(advance.toDouble()).toInt(), emptyList(),
            textDirection = if (rtl) TextDirectionHeuristics.RTL else TextDirectionHeuristics.LTR,
            includeFontPadding = false, exactAvailableWidth = if (exactAdvances) advance else null)
        val compiled = NativeRubyLayout(source, shaped,
            listOf(NativeRubyPiece.Text(0, source.length, 0, 1, collapsed = true, leafPaint = leafPaint)))
        val geometry = raw.withRubyProjection(compiled)
        val shift = shaped.getSpans(0, 1, NativeAuthoredBaselineShift::class.java).singleOrNull()?.shift ?: primary.baselineShift
        val content = raw.nativeContentLineMetrics(0).including(
            NativeUsedLineMetrics(primary.ascent + shift, primary.descent + shift))
        return NativeRubyRow(sourceStart + range.first, sourceStart + range.second, geometry, advance,
            checkNotNull(raw.textBaselines?.first), raw.nativeUsedLineMetrics(0), content,
            format, parentScript, 0f)
    }

    private fun units(path: String, first: Int, end: Int, bases: List<NativeRubyRow>,
        readings: List<NativeRubyRow>, ranges: List<RubyTextRange>, gaps: List<Float>,
        readingGaps: List<Float>, boundaries: Set<Int>, emergencyBoundaries: Set<Int>, noWrap: Boolean,
        render: (NativeRubyUnit) -> NativeRubyColumn): List<NativeRubyUnit> {
        val association = NativeRubyAssociation(path, first, end, bases, readings, ranges,
            gaps, readingGaps, boundaries, emergencyBoundaries, noWrap, render)
        var progress = association.initial
        val selected = mutableListOf<NativeRubyColumnSelection>()
        while (progress.cursor.baseFrom != association.cuts.last()) {
            val from = progress.cursor.baseFrom
            val key = NativeRubyFragmentKey(path, first + from.baseIndex, from.offset)
            val width = bands?.widthAt(key) ?: TablePixelLimit.toFloat()
            val exactEnd = if (bands == null || noWrap) association.cuts.last() else null
            val ordinary = association.select(progress, exactEnd, width, NativeRubyBreakStage.Ordinary) {
                NativeRubyBreakCandidate(it.advance, it)
            } ?: throw UnsupportedFloatLayout("Ruby has no jointly admitted recursive fragment")
            val selectedStage = if (ordinary.width > width && bands?.allowEmergency == true && !noWrap)
                association.select(progress, exactEnd, width, NativeRubyBreakStage.Emergency) {
                    NativeRubyBreakCandidate(it.advance, it)
                } ?: ordinary else ordinary
            val next = selectedStage.certificate
            check(next.to != from)
            selected += next
            progress = next.next
        }
        val materializer = NativeRubyMaterializer(selected)
        return selected.map(materializer::unit)
    }

    private fun owner(originalPrepared: NativeRubyPreparedSource, owner: RubyTextRange,
        sourceStart: Int, enclosingRtl: Boolean, parentScript: NativeRubyScriptState? = null,
        ancestorShift: Float = 0f) {
        val projection = nativeRubyGapOmissions(originalPrepared, owner)
        val omissions = projection.omissions
        val prepared = if (omissions == originalPrepared.visualOmissions && projection.spaces == originalPrepared.visualSpaces &&
            projection.neighbors == originalPrepared.visualSpaceNeighbors)
            originalPrepared else NativeRubyPreparedSource(
            originalPrepared.projection, originalPrepared.source, originalPrepared.paint, originalPrepared.direction,
            originalPrepared.groups, originalPrepared.parentScript, omissions, projection.spaces, projection.neighbors,
            originalPrepared.protectedSpaces.intersect(projection.spaces))
        omissions.forEach { (first, last) -> for (offset in first until last) omitted += sourceStart + offset }
        projection.spaces.forEach { collapsedSpaces += sourceStart + it }
        val format = checkNotNull(prepared.groups[owner.path])
        val ownerPlacement = nativeRubyBaselinePlacement(nativeRubyScriptMode(owner), format.baselineShift,
            format.localBaselineShift, parentScript ?: prepared.parentScript)
        val externalPlacement = ownerPlacement.copy(local = ownerPlacement.local + ancestorShift)
        val ownerRtl = resolveDirection(format.sourceDirection, directText(prepared, owner), enclosingRtl)
        val noWrap = format.wrap == TextWrap.NoWrap || prepared.source.getSpans(owner.start, owner.end,
            NativeAuthoredTextWrap::class.java).any { it.wrap == TextWrap.NoWrap &&
                prepared.source.getSpanStart(it) <= owner.start && prepared.source.getSpanEnd(it) >= owner.end }
        val segments = prepared.projection.ranges.filter { it.role == RubyTextRole.Segment &&
            it.path.substringBeforeLast("/segments/", "") == owner.path + "/ruby" }
        val nativeOwnerStart = native.length
        isolate(ownerRtl) {
            segments.forEach { segmentRange ->
                val segment = checkNotNull(segmentRange.segment)
                val segmentGap = gap(prepared, segmentRange.path)
                val baseRanges = segment.bases.indices.map { index ->
                    prepared.projection.ranges.single { it.role == RubyTextRole.Base &&
                        it.path == segmentRange.path + "/bases/$index" }
                }
                val completeBases = baseRanges.map { row(prepared, it, sourceStart, ownerRtl,
                    annotation = false, parentScript = ownerPlacement.state) }
                val baseGaps = baseRanges.map { gap(prepared, it.path) }
                val completeGapPresence = baseGaps.map { gapRetained(prepared, it) }
                val completeGapWidths = baseGaps.map { gapAdvance(prepared, it) }
                val annotationRanges = prepared.projection.ranges.filter { it.role == RubyTextRole.Annotation &&
                    it.path.substringBeforeLast("/annotations/", "") == segmentRange.path }
                val completeAnnotations = annotationRanges.map { row(prepared, it, sourceStart, ownerRtl,
                    annotation = true, parentScript = ownerPlacement.state) }
                val annotationGaps = annotationRanges.map { gap(prepared, it.path) }
                val retainedAnnotationGaps = annotationRanges.map { range ->
                    val annotation = checkNotNull(range.annotation)
                    val originalIndex = segment.annotations.indexOfFirst { it === annotation }
                    check(originalIndex >= 0)
                    val previous = segment.annotations.take(originalIndex).lastOrNull { it.level == annotation.level }
                    val retained = previous != null && annotationRanges.any { it.annotation === previous }
                    gap(prepared, range.path)?.let { raw ->
                        nativeRubyGapCollapse(prepared.projection.text.substring(raw.first, raw.second),
                            structurallyDiscarded = !retained, previousCollapsibleSpace = false,
                            followingCollapsibleSpace = false, trimAtLineEdge = false).text.isNotEmpty()
                    } == true
                }
                val annotationGapWidths = annotationGaps.mapIndexed { index, range ->
                    gapAdvance(prepared, range, retainedAnnotationGaps[index])
                }
                val annotationGapPresence = annotationGaps.mapIndexed { index, range ->
                    gapRetained(prepared, range, retainedAnnotationGaps[index])
                }
                val constraints = annotationRanges.mapIndexed { index, range ->
                    val annotation = checkNotNull(range.annotation)
                    NativeRubyWidthConstraint(annotation.baseStart.toInt(), annotation.baseCount.toInt(),
                        completeAnnotations[index].advance + annotationGapWidths[index])
                }
                val baseText = StringBuilder()
                val ends = mutableListOf<Int>()
                completeBases.forEachIndexed { index, base ->
                    if (completeGapPresence[index]) baseText.append(' ')
                    baseText.append(base.baseText()); ends += baseText.length
                }
                val ordinary = BreakIterator.getLineInstance(format.paint.textLocale).apply { setText(baseText.toString()) }
                val cuts = mutableListOf(0)
                val boundaries = mutableSetOf<Int>()
                val emergencyBoundaries = mutableSetOf<Int>()
                for (index in 1 until completeBases.size) {
                    val covered = constraints.any { it.first < index && it.first + it.count > index }
                    if (ordinary.isBoundary(ends[index - 1])) {
                        boundaries += index
                        if (!covered && !noWrap) cuts += index
                    } else if (!noWrap && completeBases[index - 1].permitsEmergencyEdge(after = true) &&
                        completeBases[index].permitsEmergencyEdge(after = false)) {
                        emergencyBoundaries += index
                    }
                }
                cuts += completeBases.size
                fun makeColumn(fragment: NativeRubyUnit, trimmedAnnotationGaps: Set<Int> = emptySet(),
                    trimmedBaseSpaces: Set<Int> = emptySet()): NativeRubyColumn {
                    val first = fragment.first; val end = fragment.end
                    val bases = completeBases.mapIndexed { index, row ->
                        (fragment.bases[index] ?: row).withoutSpaces(trimmedBaseSpaces)
                    }
                    val annotations = completeAnnotations.mapIndexed { index, row -> fragment.readings[index] ?: row }
                    val intrinsicWidths = if (trimmedAnnotationGaps.isEmpty() && trimmedBaseSpaces.isEmpty()) fragment.widths else
                        nativeRubyColumnWidths((first until end).map { bases[it].advance }, fragment.gaps,
                            fragment.readings.map { (index, row) ->
                                val annotation = checkNotNull(annotationRanges[index].annotation)
                                val a = maxOf(first, annotation.baseStart.toInt())
                                val b = minOf(end, annotation.baseStart.toInt() + annotation.baseCount.toInt())
                                NativeRubyWidthConstraint(a - first, b - a, row.advance +
                                    if (index in fragment.readingStarts && index !in trimmedAnnotationGaps) annotationGapWidths[index] else 0f)
                            })
                    val widths = completeBases.indices.map { index -> if (index in first until end) intrinsicWidths[index - first] else 0f }
                    val gapWidths = completeBases.indices.map { index -> if (index in first until end) fragment.gaps[index - first] else 0f }
                    lateinit var hierarchy: NativeRubyColumnHierarchy
                    fun place(widths: List<Float>, gapWidths: List<Float>,
                        increments: List<NativeRubySpacingIncrement>? = null): NativeRubyColumn {
                    val width = (first until end).sumOf { widths[it].toDouble() } +
                        (first + 1 until end).sumOf { gapWidths[it].toDouble() }
                    if (!width.isFinite() || width > TablePixelLimit)
                        throw UnsupportedFloatLayout("Ruby compound width exceeds native coordinates")
                    val xs = FloatArray(end - first)
                    var current = 0f
                    for (index in first until end) {
                        if (index > first) current += gapWidths[index]
                        xs[index - first] = if (ownerRtl) width.toFloat() - current - widths[index] else current
                        current += widths[index]
                    }
                    val children = mutableListOf<NativeRubyChild>()
                    val decorations = mutableListOf<NativeInlineDecorationFragment>()
                    val backgrounds = mutableListOf<Pair<NativeFloatBounds, Int>>()
                    val cursors = mutableListOf<NativeRubyCursorRegion>()
                    var used: NativeUsedLineMetrics? = null
                    var content: NativeUsedLineMetrics? = null
                    for (index in first until end) {
                        val base = bases[index]
                        val shift = base.localShift
                        val x = xs[index - first]
                        val placedBase = base.child(intrinsicWidths[index - first], x, shift,
                            increments?.get(index - first))
                        children += placedBase
                        used = nativeRubyIncludeShifted(used, base.used, shift)
                        content = nativeRubyIncludeShifted(content, base.content, shift)
                        nativeRubyGroupPaint(base.format, x, widths[index], shift, base.content,
                            backgrounds, decorations, placedBase.geometry.rectsForRange(0, placedBase.end - placedBase.start)
                                .map { (it.left + placedBase.x) to (it.right + placedBase.x) })
                        (base.format.cursor ?: format.cursor)?.let { cursor -> cursors += NativeRubyCursorRegion(
                            NativeFloatBounds(x, shift + base.content.top, x + widths[index], shift + base.content.bottom), cursor) }
                        if (index > first) gapRow(prepared, baseGaps[index], sourceStart, format, ownerRtl,
                            ownerPlacement.state)?.let { gap ->
                            val gapX = if (ownerRtl) x + widths[index] else x - gap.advance
                            children += gap.child(gap.advance, gapX, 0f)
                            used = nativeRubyIncludeShifted(used, gap.used, 0f)
                            content = nativeRubyIncludeShifted(content, gap.content, 0f)
                        }
                    }
                    val ownerPrimary = NativePrimaryFontMetrics.from(format.paint)
                    val ownerStrut = ownerPrimary.authored(format.lineHeight)
                        ?: NativeUsedLineMetrics(ownerPrimary.ascent, ownerPrimary.descent)
                    val baseUsed = checkNotNull(used).including(ownerStrut)
                    val baseContent = checkNotNull(content)
                    var upper = baseContent.top
                    var lower = baseContent.bottom
                    var above = false
                    var below = false
                    val relevant = fragment.readings.keys.toList()
                    relevant.groupBy { checkNotNull(annotationRanges[it].annotation).level }.toSortedMap().forEach { (level, indices) ->
                        val gaps = indices.associateWith { index -> if (index in fragment.readingStarts)
                            gapRow(prepared, annotationGaps[index], sourceStart, format, ownerRtl,
                                ownerPlacement.state, annotation = true,
                                retained = retainedAnnotationGaps[index] && index !in trimmedAnnotationGaps) else null }
                        val levelMetrics = (indices.map { annotations[it].content } + gaps.values.mapNotNull {
                            it?.takeIf { it.geometry !is NativeRubyEmptyGeometry }?.content
                        })
                            .reduce(NativeUsedLineMetrics::including)
                        val over = level % 2L == 0L
                        val baseline = if (over) upper - levelMetrics.bottom else lower - levelMetrics.top
                        // First stack the unshifted annotation level flush to the current
                        // container. A local displacement moves its child once; using it
                        // to choose this baseline would algebraically cancel the policy.
                        val placedMetrics = (indices.map { index ->
                            val annotation = annotations[index]
                            val ownBaseline = baseline + annotation.localShift
                            NativeUsedLineMetrics(ownBaseline + annotation.content.top, ownBaseline + annotation.content.bottom)
                        } + gaps.values.mapNotNull { gap -> gap?.takeIf { it.geometry !is NativeRubyEmptyGeometry }?.content?.let {
                            NativeUsedLineMetrics(baseline + it.top, baseline + it.bottom)
                        } }).reduce(NativeUsedLineMetrics::including)
                        upper = minOf(upper, placedMetrics.top)
                        lower = maxOf(lower, placedMetrics.bottom)
                        if (over) above = true else below = true
                        indices.forEach { index ->
                            val annotation = checkNotNull(annotationRanges[index].annotation)
                            val a = maxOf(first, annotation.baseStart.toInt())
                            val b = minOf(end, annotation.baseStart.toInt() + annotation.baseCount.toInt())
                            val left = (a until b).minOf { xs[it - first] }
                            val right = (a until b).maxOf { xs[it - first] + widths[it] }
                            val own = annotations[index]
                            val gap = gaps[index]
                            val gapWidth = gap?.advance ?: 0f
                            val allocation = (right - left - gapWidth).coerceAtLeast(own.advance)
                            val ownX = if (ownerRtl) left else left + gapWidth
                            val ownBaseline = baseline + own.localShift
                            val placedAnnotation = own.child(allocation, ownX, ownBaseline)
                            children += placedAnnotation
                            nativeRubyGroupPaint(own.format, ownX, allocation, ownBaseline, own.content,
                                backgrounds, decorations,
                                placedAnnotation.geometry.rectsForRange(0, placedAnnotation.end - placedAnnotation.start)
                                    .map { (it.left + placedAnnotation.x) to (it.right + placedAnnotation.x) })
                            (own.format.cursor ?: format.cursor)?.let { cursor -> cursors += NativeRubyCursorRegion(
                                NativeFloatBounds(ownX, ownBaseline + own.content.top,
                                    ownX + allocation, ownBaseline + own.content.bottom), cursor) }
                            if (gap != null) children += gap.child(gapWidth,
                                if (ownerRtl) right - gapWidth else left, baseline)
                        }
                    }
                    val ownerShift = externalPlacement.local
                    val shiftedChildren = children.map { it.copy(y = it.y + ownerShift) }
                    val shiftedDecorations = decorations.map { it.copy(bounds = it.bounds.translated(0f, ownerShift)) }.toMutableList()
                    val shiftedBackgrounds = backgrounds.map { it.first.translated(0f, ownerShift) to it.second }.toMutableList()
                    nativeRubyGroupPaint(format, 0f, width.toFloat(), ownerShift, baseContent,
                        shiftedBackgrounds, shiftedDecorations)
                    val shiftedCursors = buildList {
                        format.cursor?.let { add(NativeRubyCursorRegion(NativeFloatBounds(0f,
                            baseContent.top + ownerShift, width.toFloat(), baseContent.bottom + ownerShift), it)) }
                        addAll(cursors.map { it.copy(bounds = it.bounds.translated(0f, ownerShift)) })
                    }
                    return NativeRubyColumn(width.toFloat(),
                        NativeUsedLineMetrics(baseUsed.top + ownerShift, baseUsed.bottom + ownerShift),
                        NativeUsedLineMetrics(upper + ownerShift, lower + ownerShift), above, below,
                        shiftedChildren, shiftedDecorations, shiftedBackgrounds, format.cursor, shiftedCursors,
                        fragment.key, fragment.continues, hierarchy, baseContent, fragment.association,
                        buildString { for (index in first until end) {
                            if (index > first && completeGapPresence[index]) append(' ')
                            append(bases[index].baseText())
                        } },
                        annotationOwners = fragment.readings.keys.map { "$sourceStart:${annotationRanges[it].path}" }.toSet(),
                        annotationGapPredecessors = fragment.readingStarts.filter {
                            it !in trimmedAnnotationGaps && annotationGapPresence[it]
                        }.associateWith { index ->
                            val annotation = checkNotNull(annotationRanges[index].annotation)
                            val originalIndex = segment.annotations.indexOfFirst { it === annotation }
                            val previous = segment.annotations.take(originalIndex).indexOfLast { it.level == annotation.level }
                            check(previous >= 0)
                            "$sourceStart:${segmentRange.path}/annotations/$previous"
                        },
                        trimAnnotationGaps = { discarded -> makeColumn(fragment, trimmedAnnotationGaps + discarded, trimmedBaseSpaces) },
                        baseRanges = (first until end).flatMap { bases[it].ranges },
                        baseSpaceNeighbors = prepared.visualSpaceNeighbors.filter { (at, _) ->
                            sourceStart + at !in trimmedBaseSpaces && (first until end).any { index ->
                                bases[index].ranges.any { sourceStart + at >= it.first && sourceStart + at < it.second }
                            }
                        }.mapKeys { sourceStart + it.key }.mapValues { (_, pair) ->
                            pair.first?.plus(sourceStart) to pair.second?.plus(sourceStart)
                        },
                        trimBaseSpaces = { discarded -> makeColumn(fragment, trimmedAnnotationGaps, trimmedBaseSpaces + discarded) })
                    }
                    // This is the same box order used by place() to compute xs;
                    // each row supplies its independently proved physical edges.
                    hierarchy = NativeRubyColumnHierarchy(intrinsicWidths, fragment.gaps,
                        (first until end).map { it > first && completeGapPresence[it] },
                        if (ownerRtl) fragment.widths.indices.reversed().toList() else fragment.widths.indices.toList(), profiles = {
                        (first until end).map { index ->
                            val row = bases[index]
                            val geometry = row.geometry
                            when {
                                geometry is NativeFloatGeometry -> nativeRubySpacingProfile(geometry, row.line)
                                geometry is NativeRubyEmptyGeometry && row.start == row.end && geometry.text.isEmpty() ->
                                    NativeRubySpacingProfile.sourceEmpty()
                                else -> throw UnsupportedFloatLayout("Ruby hierarchy lacks a source base profile")
                            }
                        }
                    }, rebuild = { grown, increments ->
                        place(completeBases.indices.map { if (it in first until end) grown[it - first] else 0f },
                            gapWidths, increments)
                    })
                    return place(widths, gapWidths)
                }
                val fragments = cuts.zipWithNext().flatMap { (first, end) ->
                    units("$sourceStart:${segmentRange.path}", first, end, completeBases, completeAnnotations, annotationRanges,
                        completeGapWidths, annotationGapWidths, boundaries, emergencyBoundaries, noWrap, { makeColumn(it) })
                }
                for ((fragmentIndex, fragment) in fragments.withIndex()) {
                    val first = fragment.first
                    val column = makeColumn(fragment)
                    if (fragmentIndex == 0) externalGap(prepared, segmentGap, sourceStart, format,
                        externalPlacement, column.ownerContent)
                    if (fragment.key?.offset == 0) externalGap(prepared, baseGaps[first], sourceStart, format,
                        externalPlacement, column.ownerContent)
                    val nativeStart = native.length
                    native.append('\ufffc')
                    pieces += NativeRubyPiece.Column(nativeStart, column)
                    breakEdges[breakText.length] = nativeStart
                    breakText.append(column.baseText)
                    breakEdges[breakText.length] = native.length
                }
            }
        }
        format.wrap?.let { wrap ->
            ownerWraps += NativeInlineRange(nativeOwnerStart, native.length, NativeAuthoredTextWrap(wrap,
                inheritedOwner = true,
                sourceLineStarts = if (wrap == TextWrap.NoWrap) listOf(nativeOwnerStart) else null))
        }
    }

    fun finish(): NativeRubyLayout {
        val result = NativeRubyLayout(SpannedString(original), SpannableString(native), pieces.toList(), actionScopes.toList(), boxScopes.toList())
        val target = SpannableString(native)
        val inheritedWraps = mutableListOf<NativeInlineRange<NativeAuthoredTextWrap>>()
        fun ranges(piece: NativeRubyPiece): List<Pair<Int, Int>> = when (piece) {
            is NativeRubyPiece.Text -> listOf(piece.start to piece.end)
            is NativeRubyPiece.Column -> piece.column.children.flatMap { it.ranges }
            is NativeRubyPiece.AtomicBox -> piece.atom.child.ranges
        }
        val clippedPoints = nativeInlineRanges(original, NativeClippedVisibleMetricMarker::class.java)
        original.getSpans(0, original.length, Any::class.java).forEach { span ->
            if (span is NativeRubyPreparedSource) return@forEach
            val start = original.getSpanStart(span); val end = original.getSpanEnd(span)
            val clippedPointKey = when (span) {
                is NativeAuthoredInlineMetrics -> span.clippedVisiblePoint
                is NativeAuthoredBaselineShift -> span.clippedVisiblePoint
                else -> null
            }
            if (start == end && clippedPointKey != null && clippedPoints.any {
                    it.start == start && it.end == end && it.value.key === clippedPointKey }) {
                val at = result.nativeOffset(start)
                target.setSpan(nativeRubySpanCopy(span), at, at, original.getSpanFlags(span))
                return@forEach
            }
            // An entirely empty source still has one enclosing paragraph strut.
            // Its point belongs to the generated empty owners, not an adjacent source range.
            val emptyRootStrut = original.isEmpty() && start == 0 && end == 0 &&
                (span is NativeRunLineMetrics && span.strut || actionScopes.isNotEmpty() &&
                    span is NativeAuthoredTextWrap && span.inheritedOwner)
            val covered = pieces.filter { piece -> ranges(piece).any { (a, b) ->
                a < end && b > start || emptyRootStrut && a == 0 && b == 0
            } }
            if (span is NativeRunLineMetrics && span.strut || span is ParagraphStyle || span is NativeClippedParagraphDirection ||
                span is NativeAuthoredTextWrap && span.inheritedOwner) {
                if (covered.isNotEmpty()) {
                    val first = covered.minOf { it.nativeStart }; val last = covered.maxOf { it.nativeEnd }
                    val copy = if (span is NativeAuthoredTextWrap && span.sourceLineStarts != null)
                        span.copy(sourceLineStarts = span.sourceLineStarts.map { start ->
                            val mapped = result.nativeOffset(start)
                            native.toString().lastIndexOf('\n', mapped - 1) + 1
                        }.distinct()) else if (span is NativeRunLineMetrics && span.strut &&
                            span.policy == NativeLineHeightPolicy.Normal && (actionScopes.any { scope ->
                                if (scope.start == scope.end) nativeInlinePointInRange(original, scope.start, start, end)
                                else scope.start < end && scope.end > start
                            } || boxScopes.any { scope -> scope.start < end && scope.end > start })) NativeRunLineMetrics(span.primary, span.policy, strut = true,
                                includePrimaryInNormal = span.includePrimaryInNormal, independentNormalStrut = true)
                        else nativeRubySpanCopy(span)
                    val a = if (copy is NativeClippedParagraphDirection)
                        target.toString().lastIndexOf('\n', first - 1) + 1
                        else if (start == 0) 0 else first
                    val b = if (copy is NativeClippedParagraphDirection)
                        target.toString().indexOf('\n', a).let { if (it < 0) target.length else it + 1 }
                        else if (end == original.length) target.length else last
                    if (copy is NativeAuthoredTextWrap) inheritedWraps += NativeInlineRange(a, b, copy)
                    else target.setSpan(copy, a, b, original.getSpanFlags(span))
                }
            } else covered.filterIsInstance<NativeRubyPiece.Text>().forEach { piece ->
                if (piece.nativeStart == piece.nativeEnd) return@forEach
                if (piece.collapsed && span is NativeAuthoredUnderline) return@forEach
                if (piece.styled != null && nativeRubyLocalEffect(span)) return@forEach
                if (piece.collapsed && !(start <= piece.start && end > piece.start)) return@forEach
                val first = if (piece.collapsed) piece.nativeStart else piece.nativeStart + maxOf(start, piece.start) - piece.start
                val last = if (piece.collapsed) piece.nativeEnd else piece.nativeStart + minOf(end, piece.end) - piece.start
                target.setSpan(nativeRubySpanCopy(span), first, last, original.getSpanFlags(span))
            }
        }
        pieces.filterIsInstance<NativeRubyPiece.Text>().forEach { piece ->
            val styled = piece.styled ?: return@forEach
            if (piece.collapsed && piece.nativeStart == piece.nativeEnd) return@forEach
            styled.getSpans(0, styled.length, Any::class.java).filter(::nativeRubyLocalEffect).forEach { span ->
                val first = styled.getSpanStart(span); val last = styled.getSpanEnd(span)
                if (piece.collapsed) {
                    if (span !is NativeAuthoredUnderline && first <= 0 && last > 0)
                        target.setSpan(nativeRubySpanCopy(span), piece.nativeStart, piece.nativeEnd, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
                } else target.setSpan(nativeRubySpanCopy(span), piece.nativeStart + first, piece.nativeStart + last,
                    if (first == last) Spanned.SPAN_MARK_MARK else styled.getSpanFlags(span))
            }
        }
        actionScopes.forEach { scope ->
            val primary = NativePrimaryFontMetrics.from(scope.format.paint).copy(baselineShift = scope.shift)
            val flags = if (scope.nativeStart == scope.nativeEnd) Spanned.SPAN_MARK_MARK else Spanned.SPAN_EXCLUSIVE_EXCLUSIVE
            target.setSpan(NativeRunLineMetrics(primary, scope.format.lineHeight, strut = true,
                includePrimaryInNormal = true, independentNormalStrut = true), scope.nativeStart, scope.nativeEnd, flags)
            if (scope.start == scope.end) {
                val metrics = NativeAuthoredInlineMetrics(primary, scope.format.lineHeight, primary)
                target.setSpan(metrics, scope.point, scope.point, Spanned.SPAN_MARK_MARK)
                target.setSpan(NativeInlineActionPoint(scope.owner, metrics), scope.point, scope.point, Spanned.SPAN_MARK_MARK)
            }
        }
        boxScopes.forEach { scope ->
            val primary = NativePrimaryFontMetrics.from(scope.format.paint).copy(baselineShift = scope.shift)
            if (scope.format.actionOwner == null) target.setSpan(NativeRunLineMetrics(primary, scope.format.lineHeight,
                strut = true, includePrimaryInNormal = true, independentNormalStrut = true),
                scope.nativeStart, scope.nativeEnd, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
            target.setSpan(NativeInlineBoxSpan(scope.format, scope.shift, scope.parentRtl),
                scope.nativeStart, scope.nativeEnd, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        }
        pieces.filterIsInstance<NativeRubyPiece.Text>().filter { it.collapsed && it.nativeStart < it.nativeEnd }.forEach { piece ->
            target.setSpan(NativeRubyGapInk(), piece.nativeStart, piece.nativeEnd, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        }
        pieces.filterIsInstance<NativeRubyPiece.Column>().forEach {
            target.setSpan(it.column, it.nativeStart, it.nativeEnd, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        }
        pieces.filterIsInstance<NativeRubyPiece.AtomicBox>().forEach {
            target.setSpan(it.atom, it.nativeStart, it.nativeEnd, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        }
        // Leaf wrap belongs to its actual child row. Only the declaring Ruby
        // owner contributes compound policy to this private parent buffer.
        inheritedWraps.forEach { inherited ->
            if (target.isEmpty() && nativeInlineActionEmptyLine(target) && inherited.value.wrap != TextWrap.NoWrap)
                return@forEach
            if (inherited.value.wrap == TextWrap.NoWrap && ownerWraps.any {
                    it.start < inherited.end && it.end > inherited.start && it.value.wrap != TextWrap.NoWrap
                }) throw UnsupportedFloatLayout("Ruby wrap cannot override inherited no-wrap")
            var fragments = listOf(inherited.start to inherited.end)
            ownerWraps.forEach { owner ->
                fragments = fragments.flatMap { (first, last) ->
                    if (owner.end <= first || owner.start >= last) listOf(first to last) else buildList {
                        if (first < owner.start) add(first to owner.start)
                        if (last > owner.end) add(owner.end to last)
                    }
                }
            }
            fragments.forEach { (first, last) ->
                target.setSpan(inherited.value.copy(), first, last,
                    if (target.isEmpty() && nativeInlineActionEmptyLine(target)) Spanned.SPAN_MARK_MARK else Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
            }
        }
        ownerWraps.forEach { owner ->
            if (target.isEmpty() && nativeInlineActionEmptyLine(target)) {
                val inherited = target.getSpans(0, 0, NativeAuthoredTextWrap::class.java)
                if (inherited.any { it.wrap == TextWrap.NoWrap && owner.value.wrap != TextWrap.NoWrap })
                    throw UnsupportedFloatLayout("Ruby wrap cannot override inherited no-wrap")
                inherited.forEach(target::removeSpan)
            }
            target.setSpan(owner.value, owner.start, owner.end,
                if (target.isEmpty() && nativeInlineActionEmptyLine(target)) Spanned.SPAN_MARK_MARK else Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        }
        val breaks = BreakIterator.getLineInstance(paint.textLocale).apply { setText(breakText.toString()) }
        val boundaries = mutableListOf(0)
        var boundary = breaks.next()
        while (boundary != BreakIterator.DONE) {
            breakEdges[boundary]?.let { boundaries += it }
            boundary = breaks.next()
        }
        boundaries += target.length
        boundaries += pieces.filterIsInstance<NativeRubyPiece.Column>().filter { it.column.continues }.map { it.nativeEnd }
        target.setSpan(NativeRubyBreaks(boundaries.distinct().sorted()), 0, target.length,
            if (target.isEmpty()) Spanned.SPAN_MARK_MARK else Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        return NativeRubyLayout(result.source, SpannedString(target), pieces.toList(), actionScopes.toList(), boxScopes.toList())
    }
}

private fun validateCollapsedGap(source: Spanned, start: Int, end: Int, base: TextPaint) {
    val styles = source.getSpans(start, end, CharacterStyle::class.java)
    fun drawing(at: Int): TextPaint {
        val paint = TextPaint(base)
        styles.filter { source.getSpanStart(it) <= at && source.getSpanEnd(it) > at }.forEach { it.updateDrawState(paint) }
        return paint
    }
    val effects = source.getSpans(start, end, Any::class.java).filter {
        (it is NativeAuthoredInlineMetrics || it is NativeAuthoredBaselineShift || it is NativeAuthoredUnderline ||
            it is NativeAuthoredCursor || it is NativeAuthoredTextWrap || it is NativeRunLineMetrics) &&
            source.getSpanStart(it) < end && (source.getSpanEnd(it) > start || source.getSpanStart(it) == source.getSpanEnd(it))
    }
    fun effectAt(at: Int): List<Any> = effects.filter {
        source.getSpanStart(it) <= at && source.getSpanEnd(it) > at
    }.map {
        if (it is NativeRunLineMetrics) listOf(it.primary, it.policy, it.strut, it.includePrimaryInNormal) else it
    }
    val first = drawing(start)
    val firstEffects = effectAt(start)
    val cuts = (styles.toList() + effects).flatMap { listOf(source.getSpanStart(it), source.getSpanEnd(it)) }
        .filter { it > start && it < end }.distinct()
    val nonuniform = cuts.any { at ->
        val current = drawing(at)
        !first.equalsForTextMeasurement(current) || first.color != current.color || first.bgColor != current.bgColor ||
            first.isUnderlineText != current.isUnderlineText || first.isStrikeThruText != current.isStrikeThruText ||
            first.baselineShift != current.baselineShift || firstEffects != effectAt(at)
    }
    if (nonuniform || effects.any { source.getSpanStart(it) == source.getSpanEnd(it) })
        throw UnsupportedFloatLayout("Collapsed ruby gap has distinct unrepresented inline effects")
}

internal fun nativeRubySpanCopy(span: Any): Any = when (span) {
    is NativeRunLineMetrics -> NativeRunLineMetrics(span.primary, span.policy, span.strut,
        span.includePrimaryInNormal, span.independentNormalStrut)
    is ReplacementSpan -> span
    is MetricAffectingSpan -> if (span is NativeInlineSafePaintSpan) NativeRubyMetricCopy(span)
        else CharacterStyle.wrap(span)
    is CharacterStyle -> CharacterStyle.wrap(span)
    else -> nativeInlineStyleSpanCopy(span)
}

private class NativeRubyMetricCopy(private val original: MetricAffectingSpan) : MetricAffectingSpan(),
    NativeInlineSafePaintSpan, NativeMayUnderline {
    override val mayUnderline: Boolean get() = (original as? NativeMayUnderline)?.mayUnderline ?: false
    override fun updateMeasureState(paint: TextPaint) = original.updateMeasureState(paint)
    override fun updateDrawState(paint: TextPaint) = original.updateDrawState(paint)
}

internal fun nativeRubyLineMetrics(source: Spanned, start: Int, end: Int,
    ordinary: NativeUsedLineMetrics): NativeUsedLineMetrics {
    val columns = source.getSpans(start, end, NativeRubyColumn::class.java).filter {
        source.getSpanStart(it) < end && source.getSpanEnd(it) > start
    }
    if (columns.isEmpty()) return ordinary
    val base = columns.fold(ordinary) { metrics, column -> metrics.including(column.base) }
    val container = columns.map { it.container }.reduce(NativeUsedLineMetrics::including)
    return nativeRubyAdditionalLeading(base, container, columns.any { it.above }, columns.any { it.below })
}

private fun nativeRubyIncludeShifted(previous: NativeUsedLineMetrics?, next: NativeUsedLineMetrics,
    shift: Float): NativeUsedLineMetrics {
    val shifted = NativeUsedLineMetrics(next.top + shift, next.bottom + shift)
    return previous?.including(shifted) ?: shifted
}

private fun nativeRubyGroupPaint(format: NativeRubyGroupFormat, left: Float, width: Float,
    baseline: Float, content: NativeUsedLineMetrics,
    backgrounds: MutableList<Pair<NativeFloatBounds, Int>>,
    decorations: MutableList<NativeInlineDecorationFragment>,
    decorationRanges: List<Pair<Float, Float>> = listOf(left to left + width)) {
    if (width == 0f) return
    if (format.paint.bgColor ushr 24 != 0) backgrounds +=
        NativeFloatBounds(left, baseline + content.top, left + width, baseline + content.bottom) to format.paint.bgColor
    if (!format.paint.isUnderlineText && !format.paint.isStrikeThruText && format.underline == null) return
    fun decoration(position: Float, thickness: Float, color: Int, style: InlineUnderlineStyle) {
        if (thickness > 0f) decorationRanges.forEach { (first, last) ->
            if (last > first) decorations += NativeInlineDecorationFragment(
                NativeFloatBounds(first, baseline + position, last, baseline + position + thickness), color, style)
        }
    }
    if (format.paint.isStrikeThruText) decoration(format.paint.strikeThruPosition,
        format.paint.strikeThruThickness, format.paint.color, InlineUnderlineStyle.Solid)
    if (format.underline != null) decoration(format.paint.underlinePosition,
        format.underline.thickness ?: format.paint.underlineThickness,
        format.underline.color ?: format.paint.color, format.underline.style)
    else if (format.paint.isUnderlineText) decoration(format.paint.underlinePosition,
        format.paint.underlineThickness, format.paint.color, InlineUnderlineStyle.Solid)
}

/** Complete source paint snapshots remain absolute until this one slice boundary. Both
 * native measure and dynamic draw dispatch preserve original span order; displacement
 * is replaced only after the complete effective paint has been resolved. */
internal fun nativeRubyLocalSource(source: Spanned, base: TextPaint, parent: NativeRubyScriptState,
    inheritedPolicy: NativeLineHeightPolicy, placement: Float = 0f,
    modeAt: (Int) -> NativeRubyScriptMode): SpannableString {
    val result = SpannableString(source)
    val paints = source.getSpans(0, source.length, CharacterStyle::class.java)
    paints.forEach(result::removeSpan)
    val metrics = nativeInlineRanges(source, NativeAuthoredInlineMetrics::class.java)
    val shifts = nativeInlineRanges(source, NativeAuthoredBaselineShift::class.java)
    metrics.forEach { result.removeSpan(it.value) }
    shifts.forEach { result.removeSpan(it.value) }
    val replacements = nativeInlineRanges(source, ReplacementSpan::class.java)
    if (replacements.any { it.value !is NativeRubyGlyphReplacement } ||
        replacements.sortedBy { it.start }.zipWithNext().any { (a, b) -> a.end > b.start })
        throw UnsupportedFloatLayout("Ruby body cannot acquire an unowned replacement")
    val cuts = (listOf(0, source.length) + paints.flatMap { listOf(source.getSpanStart(it), source.getSpanEnd(it)) } +
        metrics.flatMap { listOf(it.start, it.end) } + shifts.flatMap { listOf(it.start, it.end) } +
        (1 until source.length).filter { modeAt(it) != modeAt(it - 1) }).distinct().sorted()
    fun localShiftAt(first: Int, last: Int, defaultShift: Float): Float {
        val numeric = shifts.singleOrNull { it.start <= first && it.end >= last }?.value?.shift
        val shifted = nativeRubyBaselinePlacement(modeAt(first), defaultShift, numeric, parent).local + placement
        if (!shifted.isFinite() || kotlin.math.abs(shifted) > TablePixelLimit)
            throw UnsupportedFloatLayout("Ruby local baseline exceeds native coordinates")
        return shifted
    }
    replacements.forEach { range ->
        val known = range.value as NativeRubyGlyphReplacement
        val targets = (listOf(range.start) + cuts.filter { it > range.start && it < range.end } + range.end)
            .zipWithNext().map { (first, last) -> localShiftAt(first, last, known.nativeRubyScriptShift) }.distinct()
        if (targets.size != 1) throw UnsupportedFloatLayout("Ruby glyph replacement has distinct local baseline owners")
        result.setSpan(known.withRubyLocalShift(targets.single()), range.start, range.end, source.getSpanFlags(range.value))
    }
    metrics.forEach { range ->
        val value = range.value
        val boundaries = (listOf(range.start) + cuts.filter { it > range.start && it < range.end } + range.end)
        val parts = if (range.start == range.end) listOf(range.start to range.end) else boundaries.zipWithNext()
        parts.forEach { (first, last) ->
            val replacement = replacements.singleOrNull { it.start <= first && it.end >= last }
                ?.value as? NativeRubyGlyphReplacement
            val defaultShift = replacement?.nativeRubyScriptShift ?: value.primary.baselineShift
            result.setSpan(value.copy(primary = value.primary.copy(baselineShift = localShiftAt(first, last, defaultShift)),
                declaringPrimary = value.declaringPrimary?.let { it.copy(baselineShift =
                    localShiftAt(first, last, replacement?.nativeRubyScriptShift ?: it.baselineShift)) }),
                first, last, if (first == last) source.getSpanFlags(value) else Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        }
    }
    for ((first, last) in cuts.zipWithNext()) {
        if (first == last) continue
        val active = paints.filter { it !is ReplacementSpan && source.getSpanStart(it) < last && source.getSpanEnd(it) > first }
        val replacement = replacements.singleOrNull { it.start <= first && it.end >= last }
        val measured = TextPaint(base)
        active.filterIsInstance<MetricAffectingSpan>().forEach { it.updateMeasureState(measured) }
        // A known glyph wrapper already moves its complete captured envelope. Native
        // TextLine must not also displace its replacement paint or replay a shift pass.
        val local = if (replacement != null) 0f else localShiftAt(first, last, measured.baselineShift.toFloat())
        val span = object : MetricAffectingSpan(), NativeInlineSafePaintSpan, NativeMayUnderline {
            override val mayUnderline: Boolean get() = active.any { (it as? NativeMayUnderline)?.mayUnderline == true }
            override fun updateMeasureState(paint: TextPaint) {
                paint.set(base)
                active.filterIsInstance<MetricAffectingSpan>().forEach { it.updateMeasureState(paint) }
                paint.baselineShift = local.toInt()
            }
            override fun updateDrawState(paint: TextPaint) {
                paint.set(base)
                active.forEach { it.updateDrawState(paint) }
                paint.baselineShift = local.toInt()
            }
        }
        result.setSpan(span, first, last, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        if (local != 0f) {
            result.setSpan(NativeAuthoredBaselineShift(local), first, last, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
            if (metrics.none { it.start <= first && it.end >= last }) {
                result.setSpan(NativeAuthoredInlineMetrics(NativePrimaryFontMetrics.from(measured).copy(baselineShift = local),
                    inheritedPolicy), first, last, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
            }
        }
    }
    shifts.filter { it.start == it.end }.forEach { range ->
        result.setSpan(NativeAuthoredBaselineShift(range.value.shift + placement), range.start, range.end,
            source.getSpanFlags(range.value))
    }
    return result
}

private fun nativeRubyLocalEffect(span: Any): Boolean = span is CharacterStyle ||
    span is NativeAuthoredInlineMetrics || span is NativeAuthoredBaselineShift ||
    span is NativeAuthoredUnderline || span is NativeAuthoredCursor || span is NativeRunLineMetrics && !span.strut
