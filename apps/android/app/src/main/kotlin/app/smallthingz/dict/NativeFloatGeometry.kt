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
) : FloatTextGeometry {
    val floats: List<PlacedNativeFloat> get() = flow.floats
    /** Includes inherited margin boxes; only [floats] belong to this segment's paint/nodes. */
    val exclusions: List<NativeFloatExclusion> get() = flow.exclusions
    val textBottom: Float get() = flow.bottom
    val hasResidualFloats: Boolean get() = exclusions.any { it.outer.bottom > textBottom + 0.01f }
    override val height: Int = ceil(max(flow.bottom, exclusions.maxOfOrNull { it.outer.bottom } ?: 0f)).toInt()
    override val nodes: List<FloatInteractionNode> = nodeFactory(this)
    fun firstLineBand(): RectF = RectF(flow.left[0] + originX(0), flow.tops[0], width - flow.right[0] + originX(0), flow.bottoms[0])

    fun remainingExclusions(afterY: Float = textBottom): List<NativeFloatExclusion> {
        require(afterY.isFinite() && afterY >= 0f)
        return exclusions.filter { it.outer.bottom > afterY }.map { it.copy(outer = it.outer.translated(0f, -afterY)) }
    }

    private val linePainter = NativeLinePainter(layout)
    private val linePaintPositions = (0 until layout.lineCount).map { line ->
        NativeLinePaintPlacement(line, flow.baselines[line],
            flow.left[line], flow.right[line], originX(line))
    }
    private val selectableLineBounds by lazy { linePaintPositions.map(linePainter::selectableBounds) }

    /** Native glyph advances use each exact authored line box, not its ceil View allocation
     * or the taller font/selection ink. Floated replacements contribute their real margin boxes. */
    val scrollableBounds: NativeFloatBounds by lazy {
        var bounds = NativeFloatBounds(0f, 0f, width.toFloat(), textBottom)
        selectableLineBounds.forEachIndexed { line, rect ->
            if (rect != null) bounds = bounds.enclosing(NativeFloatBounds(rect.left, flow.tops[line],
                rect.right, flow.bottoms[line]))
        }
        floats.forEach { placed -> bounds = bounds.enclosing(NativeFloatBounds(placed.outer.left,
            placed.outer.top, placed.outer.right, placed.outer.bottom)) }
        bounds
    }

    override val extents: NativeGeometryExtents by lazy {
        val ink = enclosingBounds(enclosingBounds(nativeTextInkBounds(layout, linePaintPositions),
            enclosingBounds(nativeBoundsOf(floats.map { it.content }), decorationBounds(this))), nativeFocusInk(nodes))
        val interaction = nativeBoundsOf(selectableLineBounds.filterNotNull() +
            nodes.flatMap { it.bounds } + listOf(caretRect(0), caretRect(text.length)))
        NativeGeometryExtents(width, height.toFloat(), ink, interaction)
    }

    override fun containsInteraction(x: Float, y: Float): Boolean =
        selectableLineBounds.any { it?.contains(x, y) == true } ||
            nodes.any { node -> node.bounds.any { it.contains(x, y) } }

    override fun paint(canvas: Canvas) {
        // Paint the complete shaped flow in one batch. A zero containing width or a short
        // line box must not clip its glyphs, and all native backgrounds precede the text.
        linePainter.paint(canvas, linePaintPositions)
        floats.forEach { it.occurrence.draw(canvas, RectF(it.content)) }
        decoration(canvas, this)
    }

    override fun offsetForPosition(x: Float, y: Float): Int {
        floats.lastOrNull { it.content.contains(x, y) }?.let { return it.occurrence.offset }
        val line = lineForPosition(x, y)
        return layout.getOffsetForHorizontal(line, x - originX(line)).coerceIn(0, text.length)
    }

    internal fun baselineForOffset(offset: Int): Float {
        require(offset in 0..text.length)
        val line = layout.getLineForOffset(offset)
        return flow.baselines[line]
    }

    override fun caretRect(offset: Int): RectF {
        require(offset in 0..text.length)
        val line = layout.getLineForOffset(offset)
        val x = layout.getPrimaryHorizontal(offset) + originX(line)
        val shift = flow.baselines[line] - layout.getLineBaseline(line)
        return RectF(x, layout.getLineTop(line) + shift, x + 1f, layout.getLineBottom(line) + shift)
    }

    override fun visualOffset(offset: Int, direction: Int): Int {
        require(offset in 0..text.length && direction in listOf(-1, 1))
        return if (direction < 0) layout.getOffsetToLeftOf(offset) else layout.getOffsetToRightOf(offset)
    }

    override fun lineRange(offset: Int): Pair<Int, Int> {
        require(offset in 0..text.length)
        val line = layout.getLineForOffset(offset)
        return layout.getLineStart(line) to layout.getLineEnd(line)
    }

    override fun rectsForRange(start: Int, end: Int): List<RectF> {
        require(start in 0..text.length && end in start..text.length)
        if (start == end) return emptyList()
        val path = Path()
        layout.getSelectionPath(start, end, path)
        val result = mutableListOf<RectF>()
        val selectionBounds = RectF()
        path.computeBounds(selectionBounds, true)
        val rect = Rect()
        for (line in layout.getLineForOffset(start)..layout.getLineForOffset(end - 1)) {
            val top = layout.getLineTop(line)
            val region = Region()
            // Native selection paths already describe bidi runs and overflowing glyph advances.
            // The containing width is a line-breaking constraint, not an interaction clip.
            region.setPath(path, Region(floor(selectionBounds.left).toInt(), top,
                ceil(selectionBounds.right).toInt(), layout.getLineBottom(line)))
            val iterator = RegionIterator(region)
            while (iterator.next(rect)) result += RectF(rect).apply { offset(originX(line), flow.baselines[line] - layout.getLineBaseline(line)) }
        }
        floats.filter { it.occurrence.offset in start until end }.forEach { result += RectF(it.content) }
        return result
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

    private fun lineForPosition(x: Float, y: Float): Int {
        // Later lines own only their native selectable advance. A narrower overlapping
        // line cannot hide an earlier line's exposed range; glyph ink holes do not matter.
        for (line in layout.lineCount - 1 downTo 0) {
            if (selectableLineBounds[line]?.contains(x, y) == true) return line
        }
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
    internal fun distanceForPosition(x: Float, y: Float): Double = (0 until layout.lineCount).minOf { line ->
        val box = selectableLineBounds[line] ?: RectF(originX(line), flow.tops[line],
            originX(line) + width, flow.bottoms[line])
        val dx = maxOf(box.left - x, 0f, x - box.right).toDouble()
        val dy = maxOf(box.top - y, 0f, y - box.bottom).toDouble()
        dx * dx + dy * dy
    }
    internal val shapedLineCount: Int get() = layout.lineCount
    internal fun usedLineHeight(line: Int): Float = flow.bottoms[line] - flow.tops[line]

    /** Reuse the original full-context native shaping and source offsets. Every geometry
     * consumer, including the node factory and marker painter, observes this same map. */
    internal fun inColumns(origins: List<Pair<Float, Float>>): NativeFloatGeometry {
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
            val original = SpannedString(source)
            val hasRunMetrics = original.getSpans(0, original.length, NativeRunLineMetrics::class.java).isNotEmpty()
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
            var left = intArrayOf(0)
            var right = intArrayOf(0)
            val seen = mutableSetOf<List<Int>>()
            repeat(64) {
                val signature = left.toList() + listOf(-1) + right.toList()
                if (!seen.add(signature)) throw UnsupportedFloatLayout("Float line exclusions cycle")
                val nativeLayout = StaticLayout.Builder.obtain(measured, 0, measured.length, TextPaint(paint), width)
                    .setAlignment(alignment).setTextDirection(textDirection).setIncludePad(true)
                    .setLineSpacing(lineSpacingExtra, lineSpacingMultiplier)
                    .setUseLineSpacingFromFallbacks(hasRunMetrics)
                    .setBreakStrategy(android.graphics.text.LineBreaker.BREAK_STRATEGY_SIMPLE)
                    .setHyphenationFrequency(Layout.HYPHENATION_FREQUENCY_NONE)
                    .setIndents(left, right).build()
                val flow = position(nativeLayout, width, ordered, carriedExclusions, insets, usedLineMetrics)
                if (left.contentEquals(flow.left) && right.contentEquals(flow.right)) {
                    for (line in 0 until nativeLayout.lineCount) {
                        if (flow.constrainedByFloat[line] &&
                            nativeLayout.getLineMax(line) > width - left[line] - right[line] + 1f) {
                            throw UnsupportedFloatLayout("Native text exceeds the remaining float lane")
                        }
                    }
                    if (requireDrainedAtBoundary && flow.exclusions.any { it.outer.bottom > flow.bottom + 0.01f }) {
                        throw UnsupportedFloatLayout("Active float crosses an unsupported formatting boundary")
                    }
                    return NativeFloatGeometry(original, width, nativeLayout, flow, nodeFactory, decoration, decorationBounds)
                }
                left = flow.left
                right = flow.right
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
)

private fun position(layout: StaticLayout, width: Int, occurrences: List<NativeFloatOccurrence>,
    carriedExclusions: List<NativeFloatExclusion>, insets: NativeTextInsets,
    usedLineMetrics: ((Int, Int) -> NativeUsedLineMetrics)?): Flow {
    val tops = FloatArray(layout.lineCount)
    val bottoms = FloatArray(layout.lineCount)
    val baselines = FloatArray(layout.lineCount)
    // StaticLayout repeats its last indent; always terminate exclusions with zero.
    val left = IntArray(layout.lineCount + 1)
    val right = IntArray(layout.lineCount + 1)
    val constrainedByFloat = BooleanArray(layout.lineCount)
    val placed = mutableListOf<PlacedNativeFloat>()
    val exclusions = carriedExclusions.toMutableList()
    val anchors = occurrences.groupBy { layout.getLineForOffset(it.offset) }
    var y = 0f
    for (line in 0 until layout.lineCount) {
        val nativeBaseline = layout.getLineBaseline(line)
        val natural = NativeUsedLineMetrics((layout.getLineTop(line) - nativeBaseline).toFloat(),
            (layout.getLineBottom(line) - nativeBaseline).toFloat())
        val metrics = usedLineMetrics?.invoke(layout.getLineStart(line), layout.getLineEnd(line))
            ?: nativeRunLineMetrics(layout.text as Spanned, layout.getLineStart(line), layout.getLineEnd(line), natural)
            ?: natural
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
    return Flow(tops, bottoms, baselines, left, right, placed, exclusions, y, constrainedByFloat)
}

private fun nativeLineIndent(value: Float): Int {
    if (!value.isFinite() || value < 0f || value > Int.MAX_VALUE / 4f)
        throw UnsupportedFloatLayout("Native text gutter exceeds the coordinate range")
    return ceil(value).toInt()
}
