package app.smallthingz.dict

import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.RectF
import android.text.Layout
import android.text.Spanned
import android.text.TextDirectionHeuristic
import android.text.TextPaint

/** One semantic source with an independently shaped in-flow projection. */
internal class NativeClippedAbsoluteGeometry private constructor(
    private val projection: NativeClippedAbsoluteProjection,
    private val inner: NativeFloatGeometry,
    private val carried: List<NativeFloatExclusion>,
    private val makeNodes: (NativeFloatGeometry) -> List<FloatInteractionNode>,
    private val decoration: (Canvas, NativeFloatGeometry) -> Unit,
    private val decorationBounds: (NativeFloatGeometry) -> NativeFloatBounds?,
    private val located: List<Located>,
    internal val hypotheticalUtf16Work: Long,
) : NativeFloatGeometry() {
    private val map get() = projection.map
    private val hasFlow get() = projection.hasFlow
    override val text: CharSequence get() = projection.source
    override val width: Int get() = inner.width
    override val height: Int get() = if (hasFlow) inner.height else 0
    override val floats: List<PlacedNativeFloat> get() = inner.floats
    override val exclusions: List<NativeFloatExclusion> get() = if (hasFlow) inner.exclusions else carried
    override val textBottom: Float get() = if (hasFlow) inner.textBottom else 0f
    override val hasResidualFloats: Boolean get() = if (hasFlow) inner.hasResidualFloats else carried.any { it.outer.bottom > 0f }
    override val textBaselines: NativeTextBaselines? get() = if (hasFlow) inner.textBaselines else null
    override val hasPreciseClips: Boolean get() = inner.hasPreciseClips
    override val hasColumnFragments: Boolean get() = inner.hasColumnFragments
    override val shapedLineCount: Int get() = if (hasFlow) inner.shapedLineCount else 0

    private data class Located(val occurrence: NativeClippedAbsoluteOccurrence, val line: Int,
        val location: NativeClippedAbsoluteSemanticLocation)
    override val clippedAbsoluteSemanticLocations: List<NativeClippedAbsoluteSemanticLocation>
        get() = located.map { it.location }
    private fun owner(start: Int, end: Int): Located? = located.singleOrNull {
        start >= it.occurrence.start && end <= it.occurrence.end && start < end
    }
    override fun clippedAbsoluteSemanticLocation(start: Int, end: Int): NativeClippedAbsoluteSemanticLocation? =
        owner(start, end)?.location

    override val nodes: List<FloatInteractionNode> = makeNodes(this).map { node ->
        val location = owner(node.start, node.end)?.location
        if (location == null) node else node.copy(bounds = emptyList(), focusPaint = null,
            clippedAbsoluteLocation = location)
    }
    override val positionedGroups: List<NativePositionedGroup> by lazy {
        inner.positionedGroups.map { group ->
            val offset = map.toSource(group.sourceOffset, NativeClippedSourceAffinity.After)
            group.copy(sourceOffset = offset, nodeIds = nodes.filter {
                it.start <= offset && offset < it.end && it.clippedAbsoluteLocation == null
            }.map { it.id }.toSet())
        }
    }
    override val ordinaryPaintBounds: List<NativeFloatBounds> get() = if (!hasFlow) emptyList()
        else inner.ordinaryPaintBounds + listOfNotNull(decorationBounds(this))
    override val extents: NativeGeometryExtents by lazy {
        val ink = ordinaryPaintBounds.fold(nativeFocusInk(nodes), ::enclosingBounds)
        NativeGeometryExtents(width, height.toFloat(), ink,
            if (hasFlow) enclosingBounds(inner.extents.interaction, nativeBoundsOf(nodes.flatMap { it.bounds })) else null)
    }
    override val scrollableBounds: NativeFloatBounds by lazy {
        located.fold(if (hasFlow) inner.scrollableBounds else NativeFloatBounds(0f, 0f, width.toFloat(), 0f)) { bounds, item ->
            item.location.bounds.let { bounds.enclosing(NativeFloatBounds(it.left, it.top, it.right, it.bottom)) }
        }
    }
    override val focusBounds: RectF get() = if (hasFlow) inner.focusBounds else RectF(0f, 0f, width.toFloat(), 0f)
    override fun containsInput(x: Float, y: Float): Boolean = hasFlow && inner.containsInput(x, y)
    override fun containsInteraction(x: Float, y: Float): Boolean = hasFlow && inner.containsInteraction(x, y)
    override fun interactionNodeAt(x: Float, y: Float): FloatInteractionNode? {
        for (group in positionedGroups.asReversed()) if (group.contains(x, y))
            nodes.asReversed().firstOrNull { it.id in group.nodeIds && it.contains(x, y) }?.let { return it }
        return nodes.asReversed().firstOrNull { it.contains(x, y) }
    }
    override fun cursorAt(x: Float, y: Float): InlineCursor? = if (hasFlow) inner.cursorAt(x, y) else null
    override fun horizontalScrollTargetAt(x: Float, y: Float): NativeHorizontalScrollTarget? =
        if (hasFlow) inner.horizontalScrollTargetAt(x, y) else null
    override fun paint(canvas: Canvas) { paintOrdinary(canvas); positionedGroups.forEach { it.paint(canvas) } }
    override fun paintOrdinary(canvas: Canvas) {
        if (!hasFlow) return
        inner.paintOrdinary(canvas); decoration(canvas, this)
    }
    override fun paintSelection(canvas: Canvas, start: Int, end: Int, paint: Paint) {
        map.visibleIntersections(start, end).forEach { inner.paintSelection(canvas, it.visualStart, it.visualEnd, paint) }
    }
    override fun rectsForRange(start: Int, end: Int): List<RectF> = map.visibleIntersections(start, end)
        .flatMap { inner.rectsForRange(it.visualStart, it.visualEnd) }
    override fun characterRects(start: Int, length: Int): List<RectF?> {
        require(start >= 0 && length >= 0 && start.toLong() + length <= text.length)
        val result = MutableList<RectF?>(length) { null }
        map.visibleIntersections(start, start + length).forEach { range ->
            inner.characterRects(range.visualStart, range.visualEnd - range.visualStart).forEachIndexed { index, rect ->
                result[range.sourceStart - start + index] = rect
            }
        }
        return result
    }
    override fun caretRect(offset: Int): RectF = if (hasFlow) inner.caretRect(map.toVisual(offset))
        else { map.toVisual(offset); RectF(inner.caretRect(0).left, 0f, inner.caretRect(0).left, 0f) }
    override fun caretRect(caret: NativeTextCaret): RectF = if (hasFlow)
        inner.caretRect(caret.copy(offset = map.toVisual(caret.offset))) else caretRect(caret.offset)
    override fun caretAt(x: Float, y: Float): NativeTextCaret = if (!hasFlow) NativeTextCaret(0) else
        inner.caretAt(x, y).let { it.copy(offset = map.toSource(it.offset,
            if (it.affinity == NativeTextAffinity.Upstream) NativeClippedSourceAffinity.Before else NativeClippedSourceAffinity.After)) }
    override fun visualCaret(caret: NativeTextCaret, direction: Int): NativeTextCaret {
        if (!hasFlow) return caret
        return inner.visualCaret(caret.copy(offset = map.toVisual(caret.offset)), direction).let {
            it.copy(offset = map.toSource(it.offset,
                if (it.affinity == NativeTextAffinity.Upstream) NativeClippedSourceAffinity.Before else NativeClippedSourceAffinity.After))
        }
    }
    override fun clipForOffset(offset: Int): RectF? = if (map.clippedRangeIndexAt(offset) != null)
        caretRect(offset).let { RectF(it.left, it.top, it.left, it.top) } else inner.clipForOffset(map.toVisual(offset))
    override fun preciseClipForOffset(offset: Int): NativeTextClip? = inner.preciseClipForOffset(map.toVisual(offset))
    override fun offsetForPosition(x: Float, y: Float): Int = if (hasFlow)
        map.toSource(inner.offsetForPosition(x, y), NativeClippedSourceAffinity.After) else 0
    override fun visualOffset(offset: Int, direction: Int): Int {
        val before = map.toVisual(offset)
        if (!hasFlow) return offset
        val after = inner.visualOffset(before, direction)
        return map.toSource(after, if (after < before) NativeClippedSourceAffinity.Before else NativeClippedSourceAffinity.After)
    }
    override fun isHardLineBreak(offset: Int): Boolean = offset in text.indices && text[offset] == '\n'
    private fun sourceRanges(line: Int): List<Pair<Int, Int>> {
        if (!hasFlow) return listOf(0 to text.length)
        val (first, last) = inner.nativeRangeOfLine(line)
        val ranges = map.visibleIntersections(0, text.length).mapNotNull { range ->
            val start = maxOf(first, range.visualStart); val end = minOf(last, range.visualEnd)
            if (start < end) (range.sourceStart + start - range.visualStart) to (range.sourceStart + end - range.visualStart) else null
        } + located.filter { it.line == line }.map { it.occurrence.start to it.occurrence.end }
        return ranges.sortedBy { it.first }.fold(mutableListOf<Pair<Int, Int>>()) { result, range ->
            val previous = result.lastOrNull()
            if (previous != null && previous.second == range.first) result[result.lastIndex] = previous.first to range.second
            else result += range
            result
        }
    }
    override fun lineRange(offset: Int): Pair<Int, Int> = sourceRanges(nativeLineAt(offset)).let {
        if (it.isEmpty()) offset to offset else it.first().first to it.last().second
    }
    override fun visualLineRanges(offset: Int): List<Pair<Int, Int>> = sourceRanges(nativeLineAt(offset))
    override fun nativeLineAt(offset: Int): Int = inner.nativeLineAt(map.toVisual(offset))
    override fun nativeRangeOfLine(line: Int): Pair<Int, Int> = sourceRanges(line).let {
        if (it.isEmpty()) map.toSource(inner.nativeRangeOfLine(line).first, NativeClippedSourceAffinity.After).let { edge -> edge to edge }
        else it.first().first to it.last().second
    }
    override fun firstLineBand(): RectF = if (hasFlow) inner.firstLineBand() else RectF(0f, 0f, width.toFloat(), 0f)
    override fun headingOwnerContentTop(): Float? = if (hasFlow) inner.headingOwnerContentTop() else null
    override fun remainingExclusions(afterY: Float): List<NativeFloatExclusion> = if (hasFlow) inner.remainingExclusions(afterY)
        else carried.mapNotNull { it.outer.takeIf { bounds -> bounds.bottom > afterY }?.let { bounds ->
            it.copy(outer = bounds.translated(0f, -afterY)) } }
    override fun baselineForOffset(offset: Int): Float {
        val visual = map.toVisual(offset)
        if (!hasFlow) return 0f
        val source = projection.source
        val point = source.getSpans(offset, offset, NativeAuthoredBaselineShift::class.java).firstOrNull { value ->
            val key = value.clippedVisiblePoint
            key != null && source.getSpanStart(value) == offset && source.getSpanEnd(value) == offset &&
                source.getSpans(offset, offset, NativeClippedVisibleMetricMarker::class.java).any {
                    it.key === key && source.getSpanStart(it) == offset && source.getSpanEnd(it) == offset
                }
        }
        return if (point != null) inner.nativeRubyLineBaseline(inner.nativeLineAt(visual)) + point.shift
            else inner.baselineForOffset(visual)
    }
    override fun distanceForPosition(x: Float, y: Float): Double = if (hasFlow) inner.distanceForPosition(x, y) else Double.POSITIVE_INFINITY
    override fun usedLineHeight(line: Int): Float = if (hasFlow) inner.usedLineHeight(line) else 0f
    override fun inColumns(origins: List<Pair<Float, Float>>): NativeFloatGeometry =
        throw UnsupportedFloatLayout("Clipped hypothetical column fragmentainer placement is unavailable")
    override val nativeRubyShapingSource: Spanned get() = inner.nativeRubyShapingSource
    override val nativeRubyShapingPaint: TextPaint get() = inner.nativeRubyShapingPaint
    override val nativeRubyParagraphDirection: Int get() = inner.nativeRubyParagraphDirection
    override val nativeRubyExactAdvances: Boolean get() = inner.nativeRubyExactAdvances
    override fun nativeRubyLineSourceStart(line: Int): Int = nativeRangeOfLine(line).first
    override fun nativeRubyLineAdvanceBounds(line: Int): RectF? = if (hasFlow) inner.nativeRubyLineAdvanceBounds(line) else null
    override fun nativeRubyLineBaseline(line: Int): Float = if (hasFlow) inner.nativeRubyLineBaseline(line) else 0f
    override fun nativeRubyLineTop(line: Int): Float = if (hasFlow) inner.nativeRubyLineTop(line) else 0f
    override fun nativeRubyLineDirection(line: Int): Int = inner.nativeRubyLineDirection(line)
    override fun nativeRubyLinePaintBounds(line: Int): List<NativeFloatBounds> = if (hasFlow) inner.nativeRubyLinePaintBounds(line) else emptyList()
    override fun nativeRubyLineCaret(line: Int, publicOffset: Int): RectF? = if (hasFlow)
        inner.nativeRubyLineCaret(line, map.toVisual(publicOffset)) else caretRect(publicOffset)
    override fun nativeRubyLineOffsetForPosition(line: Int, x: Float, y: Float): Int =
        map.toSource(inner.nativeRubyLineOffsetForPosition(line, x, y), NativeClippedSourceAffinity.After)
    override fun nativeRubyLineCursorAt(line: Int, x: Float, y: Float): InlineCursor? =
        if (hasFlow) inner.nativeRubyLineCursorAt(line, x, y) else null
    override fun nativeRubyEmergencyLineEnds(): Set<Int> = inner.nativeRubyEmergencyLineEnds()
        .map { map.toSource(it, NativeClippedSourceAffinity.After) }.toSet()
    override fun nativeRubyMeasuredAdvance(start: Int, end: Int): Float = map.visibleIntersections(start, end)
        .sumOf { inner.nativeRubyMeasuredAdvance(it.visualStart, it.visualEnd).toDouble() }.toFloat()
    override fun nativeRubyAvailableAt(offset: Int, considerPreviousLine: Boolean): Float =
        inner.nativeRubyAvailableAt(map.toVisual(offset), considerPreviousLine)
    override fun nativeRubyLineRects(line: Int, start: Int, end: Int): List<RectF> = map.visibleIntersections(start, end)
        .flatMap { inner.nativeRubyLineRects(line, it.visualStart, it.visualEnd) }
    override fun nativeRubyLineBaseText(line: Int): String = inner.nativeRubyLineBaseText(line)
    override fun nativeRubyLineRanges(line: Int): List<Pair<Int, Int>> = sourceRanges(line)
    override fun paintRubyNativeLine(canvas: Canvas, line: Int) { if (hasFlow) inner.paintRubyNativeLine(canvas, line) }
    override val nativeRubyAdvanceBounds: RectF? get() = if (hasFlow) inner.nativeRubyAdvanceBounds else null
    override fun nativeInlineVisibleEnd(line: Int): Int = map.toSource(inner.nativeInlineVisibleEnd(line), NativeClippedSourceAffinity.After)
    override fun nativeInlineVisibleAdvance(line: Int): Float = if (hasFlow) inner.nativeInlineVisibleAdvance(line) else 0f
    override fun nativeInlineVisibleBounds(line: Int): RectF? = if (hasFlow) inner.nativeInlineVisibleBounds(line) else null
    override fun nativeLineAvailableWidth(line: Int): Float = inner.nativeLineAvailableWidth(line)
    override fun nativeSingleLineAdvance(): Float = if (hasFlow) inner.nativeSingleLineAdvance() else 0f
    override fun nativeLineAdvance(line: Int): Float = if (hasFlow) inner.nativeLineAdvance(line) else 0f
    override fun nativeUsedLineMetrics(line: Int): NativeUsedLineMetrics = if (hasFlow) inner.nativeUsedLineMetrics(line) else NativeUsedLineMetrics(0f, 0f)
    override fun nativeContentLineMetrics(line: Int): NativeUsedLineMetrics = if (hasFlow) inner.nativeContentLineMetrics(line) else NativeUsedLineMetrics(0f, 0f)
    override fun nativeReplacementOrigin(offset: Int): Pair<Float, Float> = inner.nativeReplacementOrigin(map.toVisual(offset))
    override fun nativeInlineActionFragments(start: Int, end: Int): List<NativeInlineActionFragment> =
        map.visibleIntersections(start, end).flatMap { inner.nativeInlineActionFragments(it.visualStart, it.visualEnd) }

    companion object {
        fun build(projection: NativeClippedAbsoluteProjection, paint: TextPaint, width: Int,
            occurrences: List<NativeFloatOccurrence>, alignment: Layout.Alignment,
            textDirection: TextDirectionHeuristic, lineSpacingExtra: Float, lineSpacingMultiplier: Float,
            requireDrainedAtBoundary: Boolean, carriedExclusions: List<NativeFloatExclusion>,
            nodeFactory: (NativeFloatGeometry) -> List<FloatInteractionNode>, insets: NativeTextInsets,
            usedLineMetrics: ((Int, Int) -> NativeUsedLineMetrics)?,
            decoration: (Canvas, NativeFloatGeometry) -> Unit,
            decorationBounds: (NativeFloatGeometry) -> NativeFloatBounds?, includeFontPadding: Boolean,
            exactAvailableWidth: Float? = null, exactParagraphInsets: Boolean = false,
        ): NativeFloatGeometry {
            if (occurrences.isNotEmpty() || usedLineMetrics != null)
                throw UnsupportedFloatLayout("Clipped absolute source-owned float or external metric callback is unavailable")
            val explicitParent = when (textDirection) {
                android.text.TextDirectionHeuristics.LTR -> BidiResolvedDirection.Ltr
                android.text.TextDirectionHeuristics.RTL -> BidiResolvedDirection.Rtl
                else -> null
            }
            if (explicitParent != null && projection.paragraphs.any { it.direction != explicitParent })
                throw UnsupportedFloatLayout("Clipped source static-parent direction conflicts with explicit represented parent")
            val paragraphStarts = listOf(0) + projection.visual.indices.filter {
                projection.visual[it] == '\n' && (it + 1 < projection.visual.length ||
                    nativeClippedParagraphDirectionAt(projection.visual, it + 1) != null)
            }.map { it + 1 }
            val visibleDirections = paragraphStarts.mapIndexed { index, start ->
                val end = paragraphStarts.getOrNull(index + 1) ?: projection.visual.length
                projection.visibleParagraphDirection(start, end, textDirection)
            }.distinct()
            val commonDirection = visibleDirections.singleOrNull()
                ?: throw UnsupportedFloatLayout("Clipped mixed paragraph directions require selection-equivalent paragraph splitting")
            // Preserve the current integral ordinary selection/line engine after
            // resolving the source proofs without changing public selection metrics.
            val innerSource = android.text.SpannableString(projection.visual).apply {
                getSpans(0, length, NativeClippedParagraphDirection::class.java).forEach(::removeSpan)
            }
            val innerDirection = when (commonDirection) {
                BidiResolvedDirection.Ltr -> android.text.TextDirectionHeuristics.LTR
                BidiResolvedDirection.Rtl -> android.text.TextDirectionHeuristics.RTL
            }
            val inner = NativeFloatGeometry.build(innerSource, paint, width, emptyList(), alignment,
                innerDirection, lineSpacingExtra, lineSpacingMultiplier, requireDrainedAtBoundary,
                carriedExclusions, insets = insets, includeFontPadding = includeFontPadding,
                exactAvailableWidth = exactAvailableWidth, exactParagraphInsets = exactParagraphInsets)
            val work = NativeClippedProbeWork()
            val located = projection.occurrences.map { occurrence ->
                val scope = occurrence.format.coordinateScope ?: throw UnsupportedFloatLayout(
                    "Clipped absolute containing-block coordinate owner is unavailable")
                val input = projection.hypothetical(occurrence)
                val visualStart = projection.map.toVisual(input.originalParagraphStart)
                val visualEnd = projection.map.toVisual(input.originalParagraphEnd)
                val visibleLine = inner.nativeLineAt(projection.map.toVisual(occurrence.start))
                val staticDirection = checkNotNull(occurrence.format.owner.span.clippedAbsolute).staticParentDirection
                val parentRtl = staticDirection == BidiResolvedDirection.Rtl
                if (visualStart < visualEnd && (inner.nativeRubyLineDirection(inner.nativeLineAt(visualStart)) < 0) != parentRtl)
                    throw UnsupportedFloatLayout("Clipped static-parent proof differs from actual visible paragraph")
                val parentDirection = if (parentRtl) android.text.TextDirectionHeuristics.RTL
                    else android.text.TextDirectionHeuristics.LTR
                // Earlier visible paragraphs are unchanged. Start before this paragraph's
                // float clearance; its restored inline metrics determine its own clearance.
                val paragraphTop = if (visualStart == 0) 0f else {
                    val previous = inner.nativeLineAt(visualStart - 1)
                    inner.nativeRubyLineTop(previous) + inner.usedLineHeight(previous)
                }
                val edges = nativeClippedStaticEdges(input, occurrence, paint, width, alignment, parentDirection,
                    lineSpacingExtra, lineSpacingMultiplier, carriedExclusions, insets,
                    includeFontPadding, exactAvailableWidth, exactParagraphInsets, paragraphTop, work)
                val format = occurrence.format
                val left = if (parentRtl) edges.marginRight.toDouble() - format.margins.right - format.width
                    else edges.marginLeft.toDouble() + format.margins.left
                val top = edges.marginTop.toDouble() + format.margins.top
                val right = left + format.width; val bottom = top + format.height
                if (listOf(left, top, right, bottom).any { !it.isFinite() || kotlin.math.abs(it) > TablePixelLimit })
                    throw UnsupportedFloatLayout("Clipped absolute static box exceeds native coordinates")
                Located(occurrence, visibleLine, NativeClippedAbsoluteSemanticLocation(
                    RectF(left.toFloat(), top.toFloat(), right.toFloat(), bottom.toFloat()), coordinateScope = scope))
            }
            return NativeClippedAbsoluteGeometry(projection, inner, carriedExclusions, nodeFactory, decoration,
                decorationBounds, located, work.used)
        }
    }
}
