package app.smallthingz.dict

import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Path
import android.graphics.Rect
import android.graphics.RectF
import android.graphics.Region
import android.graphics.RegionIterator
import android.text.Layout
import android.text.PrecomputedText
import android.text.SpannableString
import android.text.Spanned
import android.text.SpannedString
import android.text.StaticLayout
import android.text.TextDirectionHeuristic
import android.text.TextDirectionHeuristics
import android.text.TextPaint
import android.text.style.ReplacementSpan
import kotlin.math.ceil
import kotlin.math.floor
import kotlin.math.max

/** Source-only candidate. All dimensions here are physical device pixels. */
internal data class FloatMargins(override val top: Float, override val right: Float,
    override val bottom: Float, override val left: Float) : NativeContainerMargins {
    init { require(listOf(top, right, bottom, left).all { it.isFinite() && it >= 0f }) }
}

internal data class NativeTextInsets(val left: Float = 0f, val right: Float = 0f,
    val extraLeft: Float = 0f, val extraRight: Float = 0f) {
    init { require(listOf(left, right, extraLeft, extraRight).all { it.isFinite() && it >= 0f }) }
}

internal enum class NativeFloatClear { None, Left, Right, Both }

internal data class NativeFloatOccurrence(
    val sourceId: Int, val offset: Int, val width: Float, val height: Float,
    val side: TableFloatSide, val clear: NativeFloatClear, val margins: FloatMargins,
    val draw: (Canvas, RectF) -> Unit,
) {
    init {
        require(sourceId >= 0 && offset >= 0)
        require(width.isFinite() && height.isFinite() && width >= 0f && height >= 0f)
        if (width.toDouble() + margins.left + margins.right > Int.MAX_VALUE / 4 ||
            height.toDouble() + margins.top + margins.bottom > Int.MAX_VALUE / 4)
            throw UnsupportedFloatLayout("Float margin box exceeds native geometry")
    }
}

internal data class PlacedNativeFloat(val occurrence: NativeFloatOccurrence, val outer: RectF, val content: RectF)
internal class UnsupportedFloatLayout(message: String) : IllegalArgumentException(message)

/** Only explicitly aligned ordinary images replace the legacy line-band selection. */
internal interface NativeAlignedImageSelection {
    /** Outer image box relative to its native replacement X and the used line baseline. */
    val nativeImageSelectionBounds: NativeFloatBounds?
}

/**
 * Owns a single full-context Layout: paragraph bidi, shaping and UTF-16 offsets
 * remain native. Only a float's existing object character gets a zero-width span.
 * Line translations provide blocked-line vertical space without adding text.
 * Clear changes only a float's top, including floats anchored inside a text line.
 * A caller must join an entire formatting context before invoking this builder.
 */
internal class NativeFloatGeometry private constructor(
    override val text: CharSequence,
    override val width: Int,
    private val layout: StaticLayout,
    private val flow: Flow,
    private val nodeFactory: (NativeFloatGeometry) -> List<FloatInteractionNode>,
    private val decoration: (Canvas, NativeFloatGeometry) -> Unit,
    private val decorationBounds: (NativeFloatGeometry) -> NativeFloatBounds?,
    private val lineOrigins: FloatArray? = null,
    private val ruby: NativeRubyPlacedProjection? = null,
) : FloatTextGeometry {
    val floats: List<PlacedNativeFloat> get() = ruby?.floats ?: flow.floats
    /** Includes inherited margin boxes; only [floats] belong to this segment's paint/nodes. */
    val exclusions: List<NativeFloatExclusion> get() = flow.exclusions
    val textBottom: Float get() = flow.bottom
    val hasResidualFloats: Boolean get() = exclusions.any { it.outer.bottom > textBottom + 0.01f }
    override val height: Int = ceil(max(flow.bottom, exclusions.maxOfOrNull { it.outer.bottom } ?: 0f)).toInt()
    private val authoredBaselines = nativeInlineRanges(text as Spanned, NativeAuthoredBaselineShift::class.java)
        .filter { it.start < it.end }
    private val authoredMetrics = nativeInlineRanges(text as Spanned, NativeAuthoredInlineMetrics::class.java)
    private val authoredCursors = nativeInlineRanges(text as Spanned, NativeAuthoredCursor::class.java)
    private val alignedImages = nativeInlineRanges(text as Spanned, NativeAlignedImageSelection::class.java)
        .filter { it.start < it.end && it.value.nativeImageSelectionBounds != null }
    private val linePainter = NativeLinePainter(layout)
    override val nodes: List<FloatInteractionNode> = nodeFactory(this)
    private fun linePresent(line: Int): Boolean = flow.sourceLinePresent?.get(line) ?: true
    override val textBaselines: NativeTextBaselines? get() {
        if (flow.sourceLinePresent == null) return NativeTextBaselines(flow.baselines.first(), flow.baselines.last())
        val lines = flow.baselines.indices.filter(::linePresent)
        return NativeTextBaselines.of(lines.firstOrNull()?.let { flow.baselines[it] }, lines.lastOrNull()?.let { flow.baselines[it] })
    }
    fun firstLineBand(): RectF {
        val line = flow.baselines.indices.firstOrNull(::linePresent) ?: return RectF()
        return RectF(flow.left[line] + originX(line), flow.tops[line], width - flow.right[line] + originX(line), flow.bottoms[line])
    }

    /** The H owner's font content edge, before line-height half-leading or descendant ink. */
    fun headingOwnerContentTop(): Float? {
        if (text.isEmpty() || nodes.count { it.kind == FloatInteractionKind.HEADING && it.start == 0 && it.end == text.length } != 1)
            return null
        val source = text as Spanned
        val owner = source.getSpans(0, text.length, NativeRunLineMetrics::class.java).singleOrNull {
            it.strut && source.getSpanStart(it) == 0 && source.getSpanEnd(it) > 0
        } ?: return null
        return (flow.baselines.first().toDouble() + owner.primary.ascent + owner.primary.baselineShift)
            .toFloat().takeIf { it.isFinite() }
    }

    fun remainingExclusions(afterY: Float = textBottom): List<NativeFloatExclusion> {
        require(afterY.isFinite() && afterY >= 0f)
        return exclusions.filter { it.outer.bottom > afterY }.map { it.copy(outer = it.outer.translated(0f, -afterY)) }
    }

    private val linePaintPositions = (0 until layout.lineCount).map { line ->
        NativeLinePaintPlacement(line, flow.baselines[line],
            flow.left[line], flow.right[line], originX(line))
    }
    private val paintedLinePositions get() = if (flow.sourceLinePresent == null) linePaintPositions
        else linePaintPositions.filter { linePresent(it.line) }
    private val selectableLineBounds by lazy { linePaintPositions.map {
        if (linePresent(it.line)) linePainter.selectableBounds(it) else null
    } }
    private fun hasAlignedImage(line: Int): Boolean = alignedImages.any {
        it.start < layout.getLineEnd(line) && it.end > layout.getLineStart(line)
    }
    private val selectableFragments by lazy {
        if (ruby != null) ruby.rects(0, text.length)
        else if (authoredBaselines.isNotEmpty()) rectsForRange(0, text.length)
        else selectableLineBounds.flatMapIndexed { line, bounds ->
            if (hasAlignedImage(line)) authoredRangeRects(layout.getLineStart(line), layout.getLineEnd(line))
            else listOfNotNull(bounds)
        }
    }

    /** Native glyph advances use each exact authored line box, not its ceil View allocation
     * or the taller font/selection ink. Floated replacements contribute their real margin boxes. */
    val scrollableBounds: NativeFloatBounds by lazy {
        ruby?.let { return@lazy it.scrollableBounds }
        if (flow.sourceLinePresent?.none { it } == true) return@lazy NativeFloatBounds(0f, 0f, 0f, 0f)
        var bounds = NativeFloatBounds(0f, 0f, width.toFloat(), textBottom)
        selectableLineBounds.forEachIndexed { line, rect ->
            if (rect != null) bounds = bounds.enclosing(NativeFloatBounds(rect.left, flow.tops[line],
                rect.right, flow.bottoms[line]))
        }
        floats.forEach { placed -> bounds = bounds.enclosing(NativeFloatBounds(placed.outer.left,
            placed.outer.top, placed.outer.right, placed.outer.bottom)) }
        bounds
    }

    override val ordinaryPaintBounds: List<NativeFloatBounds> by lazy {
        ruby?.let { return@lazy it.ordinaryPaintBounds + listOfNotNull(decorationBounds(this)) }
        listOfNotNull(nativeTextInkBounds(layout, paintedLinePositions),
            nativeBoundsOf(floats.map { it.content }), if (paintedLinePositions.isNotEmpty()) decorationBounds(this) else null)
    }
    override val extents: NativeGeometryExtents by lazy {
        val ink = ordinaryPaintBounds.fold(nativeFocusInk(nodes), ::enclosingBounds)
        val interaction = nativeBoundsOf(selectableFragments +
            nodes.flatMap { it.bounds } + listOf(caretRect(0), caretRect(text.length)))
        NativeGeometryExtents(width, height.toFloat(), ink, interaction)
    }

    override fun containsInteraction(x: Float, y: Float): Boolean =
        selectableFragments.any { it.contains(x, y) } ||
            nodes.any { node -> node.bounds.any { it.contains(x, y) } }

    override fun paint(canvas: Canvas) {
        ruby?.let {
            it.paintGapBackgrounds(canvas)
            it.raw.paint(canvas)
            it.paintGapDecorations(canvas)
            decoration(canvas, this)
            return
        }
        // Paint the complete shaped flow in one batch. A zero containing width or a short
        // line box must not clip its glyphs, and all native backgrounds precede the text.
        if (paintedLinePositions.isEmpty()) return
        linePainter.paint(canvas, paintedLinePositions)
        floats.forEach { it.occurrence.draw(canvas, RectF(it.content)) }
        decoration(canvas, this)
    }

    override fun offsetForPosition(x: Float, y: Float): Int {
        ruby?.let { return it.offset(x, y) }
        floats.lastOrNull { it.content.contains(x, y) }?.let { return it.occurrence.offset }
        val line = lineForPosition(x, y)
        return layout.getOffsetForHorizontal(line, x - originX(line)).coerceIn(0, text.length)
    }

    internal fun baselineForOffset(offset: Int): Float {
        ruby?.let { return it.baseline(offset) }
        require(offset in 0..text.length)
        val line = layout.getLineForOffset(offset)
        return flow.baselines[line] + (authoredBaselineAt(offset)?.value?.shift ?: 0f)
    }

    override fun caretRect(offset: Int): RectF {
        ruby?.let { return it.caret(offset) }
        require(offset in 0..text.length)
        val line = layout.getLineForOffset(offset)
        val x = layout.getPrimaryHorizontal(offset) + originX(line)
        if (!linePresent(line)) return RectF(x, flow.tops[line], x, flow.tops[line])
        if (text.isEmpty() && hasNativeAuthoredInlineMetrics(text))
            return RectF(x, flow.tops[line], x + 1f, flow.bottoms[line])
        alignedImages.firstOrNull { offset >= it.start && offset < it.end }
            ?.value?.nativeImageSelectionBounds?.let { own ->
                return RectF(x, flow.baselines[line] + own.top, x + 1f, flow.baselines[line] + own.bottom)
            }
        authoredSelectionMetrics(offset)?.let { own ->
            return RectF(x, flow.baselines[line] + own.top, x + 1f, flow.baselines[line] + own.bottom)
        }
        val shift = flow.baselines[line] - layout.getLineBaseline(line)
        return RectF(x, layout.getLineTop(line) + shift, x + 1f, layout.getLineBottom(line) + shift)
    }

    override fun visualOffset(offset: Int, direction: Int): Int {
        ruby?.let { return it.visualOffset(offset, direction) }
        require(offset in 0..text.length && direction in listOf(-1, 1))
        return if (direction < 0) layout.getOffsetToLeftOf(offset) else layout.getOffsetToRightOf(offset)
    }

    override fun visualLineRanges(offset: Int): List<Pair<Int, Int>> =
        ruby?.visualLineRanges(offset) ?: listOf(lineRange(offset))

    override fun lineRange(offset: Int): Pair<Int, Int> {
        ruby?.let { projection ->
            val fragments = projection.visualLineRanges(offset)
            return fragments.firstOrNull { offset >= it.first && offset < it.second }
                ?: fragments.lastOrNull { offset == it.second } ?: (offset to offset)
        }
        require(offset in 0..text.length)
        val line = layout.getLineForOffset(offset)
        return layout.getLineStart(line) to layout.getLineEnd(line)
    }

    override fun inlinePaddingGroupRects(owner: Span, start: Int, end: Int): List<RectF>? {
        require(start in 0..text.length && end in start..text.length)
        return ruby?.paddingRects(owner, start, end)
    }

    override fun rectsForRange(start: Int, end: Int): List<RectF> {
        ruby?.let { return it.rects(start, end) }
        require(start in 0..text.length && end in start..text.length)
        if (start == end) return emptyList()
        if (authoredBaselines.any { it.start < end && it.end > start } ||
            alignedImages.any { it.start < end && it.end > start }) return authoredRangeRects(start, end)
        return legacyRangeRects(start, end)
    }

    private fun legacyRangeRects(start: Int, end: Int, includeFloats: Boolean = true): List<RectF> {
        val path = Path()
        layout.getSelectionPath(start, end, path)
        val result = mutableListOf<RectF>()
        val selectionBounds = RectF()
        path.computeBounds(selectionBounds, true)
        val rect = Rect()
        for (line in layout.getLineForOffset(start)..layout.getLineForOffset(end - 1)) {
            if (!linePresent(line)) continue
            val top = layout.getLineTop(line)
            val region = Region()
            // Native selection paths already describe bidi runs and overflowing glyph advances.
            // The containing width is a line-breaking constraint, not an interaction clip.
            region.setPath(path, Region(floor(selectionBounds.left).toInt(), top,
                ceil(selectionBounds.right).toInt(), layout.getLineBottom(line)))
            val iterator = RegionIterator(region)
            while (iterator.next(rect)) result += RectF(rect).apply { offset(originX(line), flow.baselines[line] - layout.getLineBaseline(line)) }
        }
        if (includeFloats) floats.filter { it.occurrence.offset in start until end }.forEach { result += RectF(it.content) }
        return result
    }

    private fun authoredBaselineAt(offset: Int): NativeInlineRange<NativeAuthoredBaselineShift>? =
        authoredBaselines.firstOrNull { offset >= it.start && offset < it.end }
            ?: authoredBaselines.lastOrNull { offset == text.length && it.end == offset }

    private fun authoredSelectionMetrics(offset: Int): NativeUsedLineMetrics? {
        val shift = authoredBaselineAt(offset) ?: return null
        val owner = authoredMetrics.firstOrNull { it.start <= shift.start && it.end >= shift.end &&
            it.value.primary.baselineShift == shift.value.shift }?.value ?: return null
        // Integer Normal displacement keeps the platform's fallback-aware selection box.
        if (owner.policy == NativeLineHeightPolicy.Normal) return null
        return NativeUsedLineMetrics(owner.primary.ascent + shift.value.shift,
            owner.primary.descent + shift.value.shift)
    }

    private fun authoredRangeRects(start: Int, end: Int): List<RectF> = buildList {
        if (start == end) return@buildList
        for (line in layout.getLineForOffset(start)..layout.getLineForOffset(end - 1)) {
            if (!linePresent(line)) continue
            val first = maxOf(start, layout.getLineStart(line))
            val last = minOf(end, layout.getLineEnd(line))
            val cuts = (listOf(first, last) + authoredBaselines.flatMap {
                listOf(it.start.coerceIn(first, last), it.end.coerceIn(first, last))
            } + alignedImages.flatMap {
                listOf(it.start.coerceIn(first, last), it.end.coerceIn(first, last))
            }).distinct().sorted()
            for ((a, b) in cuts.zipWithNext()) {
                if (a == b) continue
                val image = alignedImages.firstOrNull { it.start == a && it.end == b }
                    ?.value?.nativeImageSelectionBounds
                if (image == null && alignedImages.isNotEmpty() &&
                    (authoredBaselines.isEmpty() || hasAlignedImage(line)) &&
                    authoredBaselines.none { it.start < b && it.end > a }) {
                    // Newly partitioned ordinary text keeps the original StaticLayout's
                    // indented fragments. The enclosing range appends each float once.
                    addAll(legacyRangeRects(a, b, includeFloats = false))
                    continue
                }
                val path = linePainter.selectionPathForRange(line, a, b)
                val bounds = RectF().also { path.computeBounds(it, true) }
                if (image != null) {
                    // A one-character replacement's native selection supplies its bidi X.
                    // Its occurrence metrics already include the image's baseline shift;
                    // authored text baseline effects cannot overlap a replacement span.
                    val x = bounds.left + linePainter.horizontalShift(NativeLinePaintPlacement(
                        line, flow.baselines[line], flow.left[line], flow.right[line], originX(line)))
                    if (!path.isEmpty) add(RectF(x + image.left, flow.baselines[line] + image.top,
                        x + image.right, flow.baselines[line] + image.bottom))
                    continue
                }
                val region = Region()
                region.setPath(path, Region(floor(bounds.left).toInt(), layout.getLineTop(line),
                    ceil(bounds.right).toInt(), layout.getLineBottom(line)))
                val iterator = RegionIterator(region)
                val rect = Rect()
                val own = authoredSelectionMetrics(a)
                while (iterator.next(rect)) {
                    add(RectF(rect).apply {
                        offset(originX(line), flow.baselines[line] - layout.getLineBaseline(line))
                        if (own != null) {
                            top = flow.baselines[line] + own.top
                            bottom = flow.baselines[line] + own.bottom
                        }
                    })
                }
            }
        }
        floats.filter { it.occurrence.offset in start until end }.forEach { add(RectF(it.content)) }
    }

    override fun characterRects(start: Int, length: Int): List<RectF?> {
        require(start in 0..text.length && length >= 0 && length <= text.length - start)
        return (start until start + length).map { offset ->
            // Accessibility indexes UTF-16; surrogate halves share a native box.
            val begin = if (offset > 0 && Character.isLowSurrogate(text[offset]) && Character.isHighSurrogate(text[offset - 1])) offset - 1 else offset
            val end = if (Character.isHighSurrogate(text[begin]) && begin + 1 < text.length && Character.isLowSurrogate(text[begin + 1])) begin + 2 else begin + 1
            rectsForRange(begin, end).reduceOrNull { a, b -> a.apply { union(b) } }
        }
    }

    override fun cursorAt(x: Float, y: Float): InlineCursor? {
        ruby?.let { return it.cursor(x, y) }
        if (authoredCursors.isEmpty() || floats.any { it.content.contains(x, y) }) return null
        val line = exactSelectableLineAt(x, y) ?: return null
        val start = layout.getLineStart(line)
        val end = layout.getLineEnd(line)
        return authoredCursors.lastOrNull { owner ->
            val first = maxOf(start, owner.start)
            val last = minOf(end, owner.end)
            first < last && authoredRangeRects(first, last).any { it.contains(x, y) }
        }?.value?.cursor
    }

    private fun exactSelectableLineAt(x: Float, y: Float): Int? {
        // Later lines own only their native selectable advance. A narrower overlapping
        // line cannot hide an earlier line's exposed range; glyph ink holes do not matter.
        for (line in layout.lineCount - 1 downTo 0) {
            val hit = if (authoredBaselines.isEmpty() && !hasAlignedImage(line)) selectableLineBounds[line]?.contains(x, y) == true
                else authoredRangeRects(layout.getLineStart(line), layout.getLineEnd(line)).any { it.contains(x, y) }
            if (hit) return line
        }
        return null
    }

    private fun lineForPosition(x: Float, y: Float): Int {
        exactSelectableLineAt(x, y)?.let { return it }
        if (lineOrigins != null) return (0 until layout.lineCount).minBy { line ->
            val box = selectableLineBounds[line] ?: RectF(originX(line), flow.tops[line],
                originX(line) + width, flow.bottoms[line])
            val dx = maxOf(box.left - x, 0f, x - box.right).toDouble()
            val dy = maxOf(box.top - y, 0f, y - box.bottom).toDouble()
            dx * dx + dy * dy
        }
        // Outside every selectable range, retain normal vertical caret placement.
        var low = 0
        var high = layout.lineCount - 1
        while (low < high) {
            val mid = (low + high) / 2
            if (y < flow.bottoms[mid]) high = mid else low = mid + 1
        }
        return low
    }

    private fun originX(line: Int): Float = lineOrigins?.get(line) ?: 0f
    internal val hasColumnFragments: Boolean get() = lineOrigins != null
    internal fun distanceForPosition(x: Float, y: Float): Double = ruby?.distance(x, y) ?: (0 until layout.lineCount).filter(::linePresent).minOfOrNull { line ->
        val box = selectableLineBounds[line] ?: RectF(originX(line), flow.tops[line],
            originX(line) + width, flow.bottoms[line])
        val dx = maxOf(box.left - x, 0f, x - box.right).toDouble()
        val dy = maxOf(box.top - y, 0f, y - box.bottom).toDouble()
        dx * dx + dy * dy
    } ?: Double.POSITIVE_INFINITY
    internal val shapedLineCount: Int get() = layout.lineCount
    internal fun usedLineHeight(line: Int): Float = flow.bottoms[line] - flow.tops[line]

    /** Reuse the original full-context native shaping and source offsets. Every geometry
     * consumer, including the node factory and marker painter, observes this same map. */
    internal fun inColumns(origins: List<Pair<Float, Float>>): NativeFloatGeometry {
        ruby?.let { return it.raw.inColumns(origins).withRubyProjection(it.compiled, nodeFactory, decoration, decorationBounds) }
        require(origins.size == layout.lineCount)
        if (floats.isNotEmpty() || exclusions.isNotEmpty() || lineOrigins != null)
            throw UnsupportedFloatLayout("Column fragments require an unfragmented text owner without floats")
        val xs = FloatArray(origins.size)
        val tops = FloatArray(origins.size)
        val bottoms = FloatArray(origins.size)
        val baselines = FloatArray(origins.size)
        origins.forEachIndexed { line, (x, y) ->
            if (!x.isFinite() || !y.isFinite() || kotlin.math.abs(x) > TablePixelLimit ||
                kotlin.math.abs(y) > TablePixelLimit)
                throw UnsupportedFloatLayout("Column fragment exceeds native geometry")
            xs[line] = x
            tops[line] = y
            bottoms[line] = y + usedLineHeight(line)
            baselines[line] = y + flow.baselines[line] - flow.tops[line]
        }
        return NativeFloatGeometry(text, width, layout,
            flow.copy(tops = tops, bottoms = bottoms, baselines = baselines,
                bottom = bottoms.maxOrNull() ?: 0f), nodeFactory, decoration, decorationBounds, xs)
    }

    /** Ruby keeps this native view private; all public owner queries use original UTF-16. */
    internal val nativeRubyRaw: NativeFloatGeometry get() = ruby?.raw ?: this
    internal val nativeRubyColumns: List<NativeRubyPiece.Column> get() =
        ruby?.compiled?.pieces?.filterIsInstance<NativeRubyPiece.Column>().orEmpty()
    internal val nativeRubyCollapsedText: List<NativeRubyPiece.Text> get() =
        ruby?.compiled?.pieces?.filterIsInstance<NativeRubyPiece.Text>()?.filter { it.collapsed }.orEmpty()
    internal val nativeRubyShapingSource: Spanned get() = layout.text as Spanned
    internal val nativeRubyShapingPaint: TextPaint get() = TextPaint(layout.paint)
    internal val nativeRubyParagraphDirection: Int get() = layout.getParagraphDirection(0)
    internal fun nativeRubyRawOffset(publicOffset: Int): Int = ruby?.compiled?.nativeOffset(publicOffset) ?: publicOffset
    internal fun nativeRubyLineSourceStart(line: Int): Int = layout.getLineStart(line)
    internal fun nativeRubyLineAdvanceBounds(line: Int): RectF? = selectableLineBounds[line]?.let(::RectF)
    internal fun nativeRubyLineBaseline(line: Int): Float = flow.baselines[line]
    internal fun nativeRubyLineTop(line: Int): Float = flow.tops[line]
    internal fun nativeRubyLineDirection(line: Int): Int = layout.getParagraphDirection(line)
    internal fun nativeRubyLinePaintBounds(line: Int): List<NativeFloatBounds> {
        ruby?.let { return it.raw.nativeRubyLinePaintBounds(line) + it.gapPaintBounds(line) }
        return if (linePresent(line)) listOfNotNull(nativeTextInkBounds(layout, listOf(linePaintPositions[line]))) else emptyList()
    }
    /** Horizontal allocation comes from this actual shaped line, before integer region rounding. */
    internal fun nativeRubyGapAllocations(start: Int, end: Int): List<NativeRubyGapAllocation> {
        require(ruby == null && start in 0..text.length && end in start..text.length)
        if (start == end) return emptyList()
        return (layout.getLineForOffset(start)..layout.getLineForOffset(end - 1)).mapNotNull { line ->
            if (!linePresent(line)) return@mapNotNull null
            val first = maxOf(start, layout.getLineStart(line))
            val last = minOf(end, layout.getLineVisibleEnd(line))
            if (first >= last) return@mapNotNull null
            val path = linePainter.selectionPathForRange(line, first, last)
            val bounds = RectF().also { path.computeBounds(it, true) }
            val shift = linePainter.horizontalShift(linePaintPositions[line])
            if (bounds.width() <= 0f) null else NativeRubyGapAllocation(line,
                bounds.left + shift, bounds.right + shift, flow.baselines[line])
        }
    }
    internal fun nativeRubyLineCaret(line: Int, publicOffset: Int): RectF? {
        ruby?.let { return it.caretOnLine(line, publicOffset) }
        if (publicOffset !in layout.getLineStart(line)..layout.getLineEnd(line)) return null
        val x = linePainter.caretHorizontalOnLine(line, publicOffset, linePaintPositions[line])
        if (!linePresent(line)) return RectF(x, flow.tops[line], x, flow.tops[line])
        val affinity = if (publicOffset == layout.getLineEnd(line) && publicOffset > layout.getLineStart(line))
            publicOffset - 1 else publicOffset
        val original = caretRect(affinity)
        return RectF(x, original.top, x + 1f, original.bottom)
    }
    override fun isHardLineBreak(offset: Int): Boolean = ruby?.isHardLineBreak(offset)
        ?: (text[offset] == '\n')
    internal fun nativeRubyLineOffsetForPosition(line: Int, x: Float, y: Float): Int {
        ruby?.let { return it.offsetOnLine(line, x, y) }
        return layout.getOffsetForHorizontal(line, x - originX(line)).coerceIn(0, text.length)
    }
    internal fun nativeRubyLineCursorAt(line: Int, x: Float, y: Float): InlineCursor? {
        ruby?.let { return it.cursorOnLine(line, x, y) }
        return authoredCursors.lastOrNull { owner ->
            nativeRubyLineRects(line, owner.start, owner.end).any { it.contains(x, y) }
        }?.value?.cursor
    }
    /** Probe only the already-lowered private shaping buffer. The row planner
     * separately checks source policy; these are actual native fitted endpoints. */
    internal fun nativeRubyEmergencyLineEnds(): Set<Int> {
        val source = SpannableString(layout.text)
        check(source.getSpans(0, source.length, NativeRubyPreparedSource::class.java).isEmpty())
        source.getSpans(0, source.length, NativeRubyLinePlan::class.java).forEach(source::removeSpan)
        if (source.getSpans(0, source.length, NativeAuthoredTextWrap::class.java).any { it.wrap == TextWrap.NoWrap })
            return emptySet()
        // Endpoint discovery must not run authored Normal's width-zero fitting
        // policy before the caller has selected its ordinary outcome. This is
        // the same initial full-source native fitter, without policy correction.
        val measured = PrecomputedText.create(source, (layout.text as PrecomputedText).params)
        val params = measured.params
        val hasRunMetrics = source.getSpans(0, source.length, NativeRunLineMetrics::class.java).isNotEmpty() ||
            hasNativeAuthoredInlineMetrics(source)
        val fitted = StaticLayout.Builder.obtain(measured, 0, measured.length, TextPaint(layout.paint), 0)
            .setAlignment(layout.alignment).setTextDirection(params.textDirection).setIncludePad(false)
            .setLineSpacing(layout.spacingAdd, layout.spacingMultiplier)
            .setUseLineSpacingFromFallbacks(hasRunMetrics)
            .setBreakStrategy(params.breakStrategy).setHyphenationFrequency(params.hyphenationFrequency)
            .build()
        return (0 until fitted.lineCount).map { fitted.getLineEnd(it) }
            .filter { it > 0 && it < source.length }.toSet()
    }
    internal fun nativeRubyMeasuredAdvance(start: Int, end: Int): Float =
        (layout.text as PrecomputedText).getWidth(start, end).also {
            if (!it.isFinite() || it < 0f) throw UnsupportedFloatLayout("Ruby native advance is unavailable")
        }
    internal fun nativeRubyAvailableAt(offset: Int, considerPreviousLine: Boolean): Float {
        val line = layout.getLineForOffset(offset)
        val start = layout.getLineStart(line)
        val before = nativeRubyMeasuredAdvance(start, offset)
        val available = (nativeLineAvailableWidth(line) - before).coerceAtLeast(0f)
        if (considerPreviousLine && line > 0 && before == 0f && start > 0 && layout.text[start - 1] != '\n') {
            val previousStart = layout.getLineStart(line - 1)
            val forced = (layout.text as Spanned).getSpans(previousStart, start, NativeRubyColumn::class.java)
                .any { it.continues }
            val remaining = nativeLineAvailableWidth(line - 1) - layout.getLineWidth(line - 1)
            if (!forced && remaining > 0f) return remaining
        }
        return available
    }
    internal fun validateRubyFloatBands() {
        for (line in 0 until layout.lineCount) if (flow.constrainedByFloat[line] &&
            layout.getLineMax(line) > nativeLineAvailableWidth(line) + 1f)
            throw UnsupportedFloatLayout("Native ruby text exceeds the remaining float lane")
    }
    internal fun nativeRubyColumnView(nativeStart: Int, column: NativeRubyColumn): FloatTextGeometry {
        val projection = ruby ?: throw UnsupportedFloatLayout("Ruby column lost its source projection")
        if (projection.compiled.pieces.filterIsInstance<NativeRubyPiece.Column>().none { it.nativeStart == nativeStart })
            throw UnsupportedFloatLayout("Ruby column lost its native occurrence")
        return NativeRubyColumnView(projection.compiled.source, nativeStart, column, projection.raw)
    }
    internal fun nativeRubyReflowColumns(replacements: Map<Int, List<NativeRubyColumn>>,
        ends: List<Int>, advances: List<Float>): NativeFloatGeometry {
        require(ends.isNotEmpty() && ends.size == advances.size)
        if (replacements.isEmpty()) return if (ends.size == 1) this else nativeRubyReflow(ends, advances)
        val projection = ruby ?: throw UnsupportedFloatLayout("Ruby fragments lost their original source map")
        val compiled = projection.compiled.replacingColumns(replacements)
        require(ends.last() == compiled.native.length)
        val source = SpannableString(compiled.native)
        source.setSpan(NativeRubyLinePlan(ends, advances), 0, source.length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        val shaped = build(source, layout.paint, width, emptyList(),
            textDirection = if (layout.getParagraphDirection(0) < 0) TextDirectionHeuristics.RTL else TextDirectionHeuristics.LTR,
            includeFontPadding = false)
        return reprojectRubyReflow(compiled, shaped)
    }
    internal fun nativeRubyReflow(ends: List<Int>, advances: List<Float>): NativeFloatGeometry {
        require(ends.size == advances.size && ends.isNotEmpty() && ends.last() == layout.text.length)
        val source = SpannableString(layout.text)
        source.getSpans(0, source.length, NativeRubyLinePlan::class.java).forEach(source::removeSpan)
        source.setSpan(NativeRubyLinePlan(ends, advances), 0, source.length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        val shaped = build(source, layout.paint, width, emptyList(),
            textDirection = if (layout.getParagraphDirection(0) < 0) TextDirectionHeuristics.RTL else TextDirectionHeuristics.LTR,
            includeFontPadding = false)
        return ruby?.let { reprojectRubyReflow(it.compiled, shaped) } ?: shaped
    }
    internal fun nativeRubyTrimSourceSpaces(offsets: Set<Int>): NativeFloatGeometry {
        val projection = ruby ?: return this
        val trimmed = projection.compiled.trimLineEdges(projection.raw, offsets) ?: return this
        val shaped = build(trimmed.native, layout.paint, width, emptyList(),
            textDirection = if (layout.getParagraphDirection(0) < 0) TextDirectionHeuristics.RTL else TextDirectionHeuristics.LTR,
            includeFontPadding = false)
        return shaped.withRubyProjection(trimmed)
    }
    private fun reprojectRubyReflow(compiled: NativeRubyLayout, shaped: NativeFloatGeometry): NativeFloatGeometry {
        val trimmed = compiled.trimLineEdges(shaped) ?: return shaped.withRubyProjection(compiled)
        val actual = build(trimmed.native, layout.paint, width, emptyList(),
            textDirection = if (layout.getParagraphDirection(0) < 0) TextDirectionHeuristics.RTL else TextDirectionHeuristics.LTR,
            includeFontPadding = false)
        return actual.withRubyProjection(trimmed)
    }
    internal fun nativeRubyLineRects(line: Int, start: Int, end: Int): List<RectF> {
        ruby?.let { return it.rectsOnLine(line, start, end) }
        require(start in 0..text.length && end in start..text.length)
        if (!linePresent(line)) return emptyList()
        val first = maxOf(start, layout.getLineStart(line))
        val last = minOf(end, layout.getLineEnd(line))
        if (first >= last) return emptyList()
        val cuts = (listOf(first, last) + authoredBaselines.flatMap {
            listOf(it.start.coerceIn(first, last), it.end.coerceIn(first, last))
        }).distinct().sorted()
        val position = linePaintPositions[line]
        return buildList {
            for ((a, b) in cuts.zipWithNext()) {
                val path = linePainter.selectionPathForRange(line, a, b)
                val bounds = RectF().also { path.computeBounds(it, true) }
                val region = Region().apply { setPath(path, Region(floor(bounds.left).toInt(),
                    layout.getLineTop(line), ceil(bounds.right).toInt(), layout.getLineBottom(line))) }
                val iterator = RegionIterator(region)
                val rect = Rect()
                val own = authoredSelectionMetrics(a)
                while (iterator.next(rect)) add(RectF(rect).apply {
                    offset(linePainter.horizontalShift(position), flow.baselines[line] - layout.getLineBaseline(line))
                    if (own != null) {
                        top = flow.baselines[line] + own.top
                        bottom = flow.baselines[line] + own.bottom
                    }
                })
            }
        }
    }
    internal fun nativeRubyLineBaseText(line: Int): String = ruby?.baseTextOnLine(line)
        ?: layout.text.subSequence(layout.getLineStart(line), layout.getLineEnd(line)).toString()

    internal fun nativeRubyLineRanges(line: Int): List<Pair<Int, Int>> = ruby?.lineRanges(line)
        ?: listOf(layout.getLineStart(line) to layout.getLineEnd(line))
    internal fun paintRubyNativeLine(canvas: Canvas, line: Int) {
        ruby?.let {
            it.paintGapBackgrounds(canvas, line)
            it.raw.paintRubyNativeLine(canvas, line)
            it.paintGapDecorations(canvas, line)
            return
        }
        require(floats.isEmpty() && exclusions.isEmpty())
        if (linePresent(line)) linePainter.paint(canvas, listOf(linePaintPositions[line]))
    }
    internal val nativeRubyAdvanceBounds: RectF? get() = selectableLineBounds.firstOrNull()?.let(::RectF)
    internal fun nativeLineAt(offset: Int): Int = layout.getLineForOffset(offset)
    internal fun nativeRangeOfLine(line: Int): Pair<Int, Int> = layout.getLineStart(line) to layout.getLineEnd(line)
    internal fun nativeLineAvailableWidth(line: Int): Float = width - flow.left[line].toFloat() - flow.right[line]
    internal fun nativeSingleLineAdvance(): Float {
        check(layout.lineCount == 1)
        return nativeLineAdvance(0)
    }
    internal fun nativeLineAdvance(line: Int): Float = layout.getLineWidth(line)
    internal fun nativeUsedLineMetrics(line: Int): NativeUsedLineMetrics =
        NativeUsedLineMetrics(flow.tops[line] - flow.baselines[line], flow.bottoms[line] - flow.baselines[line])
    internal fun nativeContentLineMetrics(line: Int): NativeUsedLineMetrics {
        val baseline = layout.getLineBaseline(line)
        var result = NativeUsedLineMetrics((layout.getLineTop(line) - baseline).toFloat(),
            (layout.getLineBottom(line) - baseline).toFloat())
        (layout.text as Spanned).getSpans(layout.getLineStart(line), layout.getLineEnd(line), NativeRubyColumn::class.java)
            .forEach { result = result.including(it.container) }
        return result
    }
    internal fun nativeReplacementOrigin(offset: Int): Pair<Float, Float> {
        val line = layout.getLineForOffset(offset)
        val path = linePainter.selectionPathForRange(line, offset, offset + 1)
        val bounds = RectF().also { path.computeBounds(it, true) }
        return (bounds.left + linePainter.horizontalShift(NativeLinePaintPlacement(line,
            flow.baselines[line], flow.left[line], flow.right[line], originX(line)))) to flow.baselines[line]
    }
    internal fun withRubyProjection(compiled: NativeRubyLayout,
        nodes: (NativeFloatGeometry) -> List<FloatInteractionNode> = { emptyList() },
        paintDecoration: (Canvas, NativeFloatGeometry) -> Unit = { _, _ -> },
        paintBounds: (NativeFloatGeometry) -> NativeFloatBounds? = { null }): NativeFloatGeometry {
        check(ruby == null && text.toString() == compiled.native.toString())
        return NativeFloatGeometry(compiled.source, width, layout, flow, nodes, paintDecoration,
            paintBounds, lineOrigins, compiled.placed(this))
    }

    companion object {
        fun build(
            source: Spanned, paint: TextPaint, width: Int,
            occurrences: List<NativeFloatOccurrence>,
            alignment: Layout.Alignment = Layout.Alignment.ALIGN_NORMAL,
            textDirection: TextDirectionHeuristic = TextDirectionHeuristics.FIRSTSTRONG_LTR,
            lineSpacingExtra: Float = 0f, lineSpacingMultiplier: Float = 1f,
            requireDrainedAtBoundary: Boolean = false,
            carriedExclusions: List<NativeFloatExclusion> = emptyList(),
            nodeFactory: (NativeFloatGeometry) -> List<FloatInteractionNode> = { emptyList() },
            insets: NativeTextInsets = NativeTextInsets(),
            usedLineMetrics: ((start: Int, end: Int) -> NativeUsedLineMetrics)? = null,
            decoration: (Canvas, NativeFloatGeometry) -> Unit = { _, _ -> },
            decorationBounds: (NativeFloatGeometry) -> NativeFloatBounds? = { null },
            includeFontPadding: Boolean = true,
            rubyProbe: Boolean = false,
        ): NativeFloatGeometry {
            require(width >= 0 && width <= Int.MAX_VALUE / 4)
            require(lineSpacingExtra.isFinite() && lineSpacingExtra >= 0f)
            require(lineSpacingMultiplier.isFinite() && lineSpacingMultiplier > 0f)
            require(occurrences.map { it.sourceId }.distinct().size == occurrences.size)
            require(occurrences.map { it.offset }.distinct().size == occurrences.size)
            carriedExclusions.forEach { exclusion ->
                val box = exclusion.outer
                if (listOf(box.left, box.top, box.right, box.bottom).any { kotlin.math.abs(it) > Int.MAX_VALUE / 4 }) {
                    throw UnsupportedFloatLayout("Carried float exceeds native geometry")
                }
            }
            if (source.getSpans(0, source.length, NativeRubyPreparedSource::class.java).isNotEmpty()) {
                if (usedLineMetrics != null)
                    throw UnsupportedFloatLayout("Ruby needs source-owned metrics rather than an external single-range callback")
                val available = (width - ceil((insets.left + insets.extraLeft).toDouble()).toFloat() -
                    ceil((insets.right + insets.extraRight).toDouble()).toFloat()).coerceAtLeast(0f)
                var bands = NativeRubyBands(available)
                val seenBands = mutableSetOf<Map<NativeRubyFragmentKey, Float>>()
                repeat(64) {
                    if (!seenBands.add(bands.observed))
                        throw UnsupportedFloatLayout("Ruby fragment and native float bands cycle")
                    var compiled = checkNotNull(nativeRubyLayout(source, paint, textDirection, bands))
                    val nativeOccurrences = occurrences.map { it.copy(offset = compiled.nativeOffset(it.offset)) }
                    var raw = build(compiled.native, paint, width, nativeOccurrences, alignment, textDirection,
                        lineSpacingExtra, lineSpacingMultiplier, requireDrainedAtBoundary, carriedExclusions,
                        insets = insets, includeFontPadding = includeFontPadding, rubyProbe = true)
                    compiled.trimLineEdges(raw)?.let { trimmed ->
                        compiled = trimmed
                        raw = build(trimmed.native, paint, width, nativeOccurrences, alignment, textDirection,
                            lineSpacingExtra, lineSpacingMultiplier, requireDrainedAtBoundary, carriedExclusions,
                            insets = insets, includeFontPadding = includeFontPadding, rubyProbe = true)
                    }
                    val observed = compiled.observedBands(raw)
                    if (observed.all { (key, value) -> bands.widthAt(key) == value }) {
                        raw.validateRubyFloatBands()
                        return raw.withRubyProjection(compiled, nodeFactory, decoration, decorationBounds)
                    }
                    bands = NativeRubyBands(available, bands.observed + observed)
                }
                throw UnsupportedFloatLayout("Ruby fragments did not converge with native float bands")
            }
            validateNativeInlineStyle(source, paint)
            val original = SpannedString(source)
            val wrapPlan = NativeTextWrapPlan.create(original, paint)
            wrapPlan?.noWrap?.requireLinePresence()
            if (wrapPlan?.noWrap != null && (occurrences.isNotEmpty() || carriedExclusions.isNotEmpty()))
                throw UnsupportedFloatLayout("No-wrap source cannot inherit or establish float exclusions")
            val hasRunMetrics = original.getSpans(0, original.length, NativeRunLineMetrics::class.java).isNotEmpty() ||
                hasNativeAuthoredInlineMetrics(original)
            val native = SpannableString(original)
            val ordered = occurrences.sortedBy { it.offset }
            ordered.forEach {
                require(it.offset < source.length && source[it.offset] == '\ufffc') { "Float must refer to its original object character" }
                require(source.getSpans(it.offset, it.offset + 1, ReplacementSpan::class.java).isEmpty()) { "Float marker already has an inline replacement" }
                native.setSpan(FloatMarker(), it.offset, it.offset + 1, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
            }
            val measured = PrecomputedText.create(native, PrecomputedText.Params.Builder(TextPaint(paint))
                .setTextDirection(textDirection).setBreakStrategy(android.graphics.text.LineBreaker.BREAK_STRATEGY_SIMPLE)
                .setHyphenationFrequency(Layout.HYPHENATION_FREQUENCY_NONE).build())
            val rubyLinePlan = original.getSpans(0, original.length, NativeRubyLinePlan::class.java).singleOrNull()
            val rubyFragments = NativeRubyFragmentLines(original)
            val rubyIndents = rubyLinePlan?.indents(width, textDirection.isRtl(measured, 0, measured.length))
            var left = rubyIndents?.first ?: intArrayOf(0)
            var right = rubyIndents?.second ?: intArrayOf(0)
            val seen = mutableSetOf<List<Int>>()
            repeat(64) {
                val signature = left.toList() + listOf(-1) + right.toList()
                if (!seen.add(signature)) throw UnsupportedFloatLayout("Float line exclusions cycle")
                val nativeLayout = StaticLayout.Builder.obtain(measured, 0, measured.length, TextPaint(paint), width)
                    .setAlignment(alignment).setTextDirection(textDirection).setIncludePad(includeFontPadding)
                    .setLineSpacing(lineSpacingExtra, lineSpacingMultiplier)
                    .setUseLineSpacingFromFallbacks(hasRunMetrics)
                    .setBreakStrategy(android.graphics.text.LineBreaker.BREAK_STRATEGY_SIMPLE)
                    .setHyphenationFrequency(Layout.HYPHENATION_FREQUENCY_NONE)
                    .setIndents(left, right).build()
                val flow = position(nativeLayout, width, ordered, carriedExclusions, insets, usedLineMetrics,
                    wrapPlan?.noWrap?.let { plan -> { start -> plan.hasLineAt(start) } })
                val fit = if (rubyLinePlan == null) rubyFragments.fit(nativeLayout, measured, flow.left, flow.right,
                    wrapPlan?.fit(nativeLayout, measured, flow.left, flow.right,
                        if (rubyProbe) BooleanArray(flow.constrainedByFloat.size) else flow.constrainedByFloat)) else rubyIndents
                val nextLeft = fit?.first ?: flow.left
                val nextRight = fit?.second ?: flow.right
                if (left.contentEquals(nextLeft) && right.contentEquals(nextRight)) {
                    if (rubyLinePlan != null) rubyLinePlan.validate(nativeLayout)
                    else wrapPlan?.validateResult(nativeLayout)
                    rubyFragments.validate(nativeLayout)
                    for (line in 0 until nativeLayout.lineCount) {
                        if (!rubyProbe && flow.constrainedByFloat[line] &&
                            nativeLayout.getLineMax(line) > width - flow.left[line] - flow.right[line] + 1f) {
                            throw UnsupportedFloatLayout("Native text exceeds the remaining float lane")
                        }
                    }
                    if (requireDrainedAtBoundary && flow.exclusions.any { it.outer.bottom > flow.bottom + 0.01f }) {
                        throw UnsupportedFloatLayout("Active float crosses an unsupported formatting boundary")
                    }
                    return NativeFloatGeometry(original, width, nativeLayout, flow, nodeFactory, decoration, decorationBounds)
                }
                left = nextLeft
                right = nextRight
            }
            throw UnsupportedFloatLayout("Float exclusions did not converge after 64 native layouts")
        }
    }
}

private class FloatMarker : ReplacementSpan(), NativeReplacementPaintBounds {
    override fun nativePaintBounds(lineTop: Float, lineBottom: Float): NativeFloatBounds? = null
    override fun getSize(paint: Paint, text: CharSequence, start: Int, end: Int, fm: Paint.FontMetricsInt?): Int = 0
    override fun draw(canvas: Canvas, text: CharSequence, start: Int, end: Int, x: Float, top: Int, y: Int, bottom: Int, paint: Paint) = Unit
}

private data class Flow(
    val tops: FloatArray, val bottoms: FloatArray, val baselines: FloatArray,
    val left: IntArray, val right: IntArray,
    val floats: List<PlacedNativeFloat>, val exclusions: List<NativeFloatExclusion>, val bottom: Float,
    val constrainedByFloat: BooleanArray,
    val sourceLinePresent: BooleanArray? = null,
)

private fun position(layout: StaticLayout, width: Int, occurrences: List<NativeFloatOccurrence>,
    carriedExclusions: List<NativeFloatExclusion>, insets: NativeTextInsets,
    usedLineMetrics: ((Int, Int) -> NativeUsedLineMetrics)?, sourceLinePresent: ((Int) -> Boolean)? = null): Flow {
    val tops = FloatArray(layout.lineCount)
    val bottoms = FloatArray(layout.lineCount)
    val baselines = FloatArray(layout.lineCount)
    // StaticLayout repeats its last indent; always terminate exclusions with zero.
    val left = IntArray(layout.lineCount + 1)
    val right = IntArray(layout.lineCount + 1)
    val constrainedByFloat = BooleanArray(layout.lineCount)
    val present = sourceLinePresent?.let { owns -> BooleanArray(layout.lineCount) { owns(layout.getLineStart(it)) } }
    val placed = mutableListOf<PlacedNativeFloat>()
    val exclusions = carriedExclusions.toMutableList()
    val anchors = occurrences.groupBy { layout.getLineForOffset(it.offset) }
    var y = 0f
    for (line in 0 until layout.lineCount) {
        if (present?.get(line) == false) {
            tops[line] = y
            bottoms[line] = y
            baselines[line] = y
            continue
        }
        val nativeBaseline = layout.getLineBaseline(line)
        val natural = NativeUsedLineMetrics((layout.getLineTop(line) - nativeBaseline).toFloat(),
            (layout.getLineBottom(line) - nativeBaseline).toFloat())
        val ordinaryMetrics = usedLineMetrics?.invoke(layout.getLineStart(line), layout.getLineEnd(line))
            ?: nativeRunLineMetrics(layout.text as Spanned, layout.getLineStart(line), layout.getLineEnd(line), natural,
                pointOnLine = { offset -> layout.getLineForOffset(offset) == line })
            ?: natural
        val metrics = nativeRubyLineMetrics(layout.text as Spanned, layout.getLineStart(line),
            layout.getLineEnd(line), ordinaryMetrics)
        val lineHeight = metrics.height
        for (occurrence in anchors[line].orEmpty()) {
            val clearBottom = exclusions.filter { previous ->
                when (occurrence.clear) {
                    NativeFloatClear.None -> false
                    NativeFloatClear.Left -> previous.side == TableFloatSide.Left
                    NativeFloatClear.Right -> previous.side == TableFloatSide.Right
                    NativeFloatClear.Both -> true
                }
            }.maxOfOrNull { it.outer.bottom } ?: y
            // CSS 2.2 9.5.2 constraint 10 applies to the float's outer top;
            // moving y here would incorrectly clear earlier and following text.
            var floatY = max(max(y, clearBottom), exclusions.maxOfOrNull { it.outer.top } ?: 0f)
            val outerWidth = occurrence.width + occurrence.margins.left + occurrence.margins.right
            val outerHeight = occurrence.height + occurrence.margins.top + occurrence.margins.bottom
            var x: Float
            while (true) {
                val overlap = exclusions.filter { it.outer.top < floatY + outerHeight && it.outer.bottom > floatY }
                val occupiedLeft = overlap.filter { it.side == TableFloatSide.Left }.maxOfOrNull { it.outer.right } ?: 0f
                val occupiedRight = overlap.filter { it.side == TableFloatSide.Right }.minOfOrNull { it.outer.left } ?: width.toFloat()
                if (outerWidth <= occupiedRight - occupiedLeft || overlap.isEmpty()) {
                    x = if (occurrence.side == TableFloatSide.Left) occupiedLeft else occupiedRight - outerWidth
                    break
                }
                floatY = overlap.minOf { it.outer.bottom }
            }
            if (!(floatY + outerHeight).isFinite() || floatY + outerHeight > Int.MAX_VALUE / 4) {
                throw UnsupportedFloatLayout("Float context exceeds native geometry")
            }
            val outer = RectF(x, floatY, x + outerWidth, floatY + outerHeight)
            val content = RectF(x + occurrence.margins.left, floatY + occurrence.margins.top,
                x + occurrence.margins.left + occurrence.width, floatY + occurrence.margins.top + occurrence.height)
            placed += PlacedNativeFloat(occurrence, outer, content)
            exclusions += NativeFloatExclusion(occurrence.side, NativeFloatBounds(outer.left, outer.top, outer.right, outer.bottom))
        }
        while (true) {
            val overlap = exclusions.filter {
                (if (lineHeight == 0f) it.outer.top <= y else it.outer.top < y + lineHeight) && it.outer.bottom > y
            }
            val l = nativeLineIndent(max(insets.left, overlap.filter { it.side == TableFloatSide.Left }.maxOfOrNull { it.outer.right } ?: 0f) + insets.extraLeft)
            val r = nativeLineIndent(max(insets.right, width - (overlap.filter { it.side == TableFloatSide.Right }.minOfOrNull { it.outer.left } ?: width.toFloat())) + insets.extraRight)
            // Native line breaking clamps the signed remaining width to zero, while drawing keeps
            // the real indents. Permanent authored gutters can overflow; temporary floats still
            // move a line below their margin boxes when they leave no available line width.
            if (overlap.isEmpty() || l + r < width) {
                left[line] = l
                right[line] = r
                constrainedByFloat[line] = overlap.isNotEmpty()
                break
            }
            y = overlap.minOf { it.outer.bottom }
        }
        tops[line] = y
        baselines[line] = y - metrics.top
        if (!baselines[line].isFinite() || kotlin.math.abs(baselines[line]) > Int.MAX_VALUE / 4)
            throw UnsupportedFloatLayout("Native baseline exceeds the geometry range")
        y += lineHeight
        if (!y.isFinite() || y > Int.MAX_VALUE / 4) throw UnsupportedFloatLayout("Float context exceeds native geometry")
        bottoms[line] = y
    }
    return Flow(tops, bottoms, baselines, left, right, placed, exclusions, y, constrainedByFloat, present)
}

private fun nativeLineIndent(value: Float): Int {
    if (!value.isFinite() || value < 0f || value > Int.MAX_VALUE / 4f)
        throw UnsupportedFloatLayout("Native text gutter exceeds the coordinate range")
    return ceil(value).toInt()
}
