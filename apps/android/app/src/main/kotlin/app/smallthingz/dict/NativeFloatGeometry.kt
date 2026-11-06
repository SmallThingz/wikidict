package app.smallthingz.dict

import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Path
import android.graphics.Rect
import android.graphics.RectF
import android.graphics.Region
import android.graphics.RegionIterator
import android.text.Layout
import android.text.SpannableString
import android.text.Spanned
import android.text.SpannedString
import android.text.StaticLayout
import android.text.TextDirectionHeuristic
import android.text.TextDirectionHeuristics
import android.text.TextPaint
import android.text.style.ReplacementSpan
import kotlin.math.ceil
import kotlin.math.max

/** Source-only candidate. All dimensions here are physical device pixels. */
internal data class FloatMargins(val top: Float, val right: Float, val bottom: Float, val left: Float) {
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
        require(width.isFinite() && height.isFinite() && width > 0f && height > 0f)
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
    nodeFactory: (NativeFloatGeometry) -> List<FloatInteractionNode>,
    private val decoration: (Canvas, NativeFloatGeometry) -> Unit,
) : FloatTextGeometry {
    val floats: List<PlacedNativeFloat> get() = flow.floats
    /** Includes inherited margin boxes; only [floats] belong to this segment's paint/nodes. */
    val exclusions: List<NativeFloatExclusion> get() = flow.exclusions
    val textBottom: Float get() = flow.bottom
    val hasResidualFloats: Boolean get() = exclusions.any { it.outer.bottom > textBottom + 0.01f }
    override val height: Int = ceil(max(flow.bottom, exclusions.maxOfOrNull { it.outer.bottom } ?: 0f)).toInt()
    override val nodes: List<FloatInteractionNode> = nodeFactory(this)
    fun firstLineBand(): RectF = RectF(flow.left[0].toFloat(), flow.tops[0], (width - flow.right[0]).toFloat(), flow.bottoms[0])

    fun remainingExclusions(afterY: Float = textBottom): List<NativeFloatExclusion> {
        require(afterY.isFinite() && afterY >= 0f)
        return exclusions.filter { it.outer.bottom > afterY }.map { it.copy(outer = it.outer.translated(0f, -afterY)) }
    }

    override fun paint(canvas: Canvas) {
        for (line in 0 until layout.lineCount) {
            val saved = canvas.save()
            canvas.clipRect(0f, flow.tops[line], width.toFloat(), flow.bottoms[line])
            canvas.translate(0f, flow.tops[line] - layout.getLineTop(line))
            layout.draw(canvas)
            canvas.restoreToCount(saved)
        }
        floats.forEach { it.occurrence.draw(canvas, RectF(it.content)) }
        decoration(canvas, this)
    }

    override fun offsetForPosition(x: Float, y: Float): Int {
        floats.lastOrNull { it.content.contains(x, y) }?.let { return it.occurrence.offset }
        return layout.getOffsetForHorizontal(lineForY(y), x).coerceIn(0, text.length)
    }

    override fun caretRect(offset: Int): RectF {
        require(offset in 0..text.length)
        val line = layout.getLineForOffset(offset)
        val x = layout.getPrimaryHorizontal(offset)
        return RectF(x, flow.tops[line], x + 1f, flow.bottoms[line])
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
        val rect = Rect()
        for (line in layout.getLineForOffset(start)..layout.getLineForOffset(end - 1)) {
            val top = layout.getLineTop(line)
            val region = Region()
            region.setPath(path, Region(flow.left[line], top, width - flow.right[line], layout.getLineBottom(line)))
            val iterator = RegionIterator(region)
            while (iterator.next(rect)) result += RectF(rect).apply { offset(0f, flow.tops[line] - top) }
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

    private fun lineForY(y: Float): Int {
        var low = 0
        var high = layout.lineCount - 1
        while (low < high) {
            val mid = (low + high) / 2
            if (y < flow.bottoms[mid]) high = mid else low = mid + 1
        }
        return low
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
            decoration: (Canvas, NativeFloatGeometry) -> Unit = { _, _ -> },
        ): NativeFloatGeometry {
            require(width > 0 && width <= Int.MAX_VALUE / 4)
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
            val native = SpannableString(original)
            val ordered = occurrences.sortedBy { it.offset }
            ordered.forEach {
                require(it.offset < source.length && source[it.offset] == '\ufffc') { "Float must refer to its original object character" }
                require(source.getSpans(it.offset, it.offset + 1, ReplacementSpan::class.java).isEmpty()) { "Float marker already has an inline replacement" }
                native.setSpan(FloatMarker(), it.offset, it.offset + 1, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
            }
            var left = intArrayOf(0)
            var right = intArrayOf(0)
            val seen = mutableSetOf<List<Int>>()
            repeat(64) {
                val signature = left.toList() + listOf(-1) + right.toList()
                if (!seen.add(signature)) throw UnsupportedFloatLayout("Float line exclusions cycle")
                val nativeLayout = StaticLayout.Builder.obtain(native, 0, native.length, TextPaint(paint), width)
                    .setAlignment(alignment).setTextDirection(textDirection).setIncludePad(true)
                    .setLineSpacing(lineSpacingExtra, lineSpacingMultiplier)
                    .setBreakStrategy(Layout.BREAK_STRATEGY_SIMPLE)
                    .setHyphenationFrequency(Layout.HYPHENATION_FREQUENCY_NONE)
                    .setIndents(left, right).build()
                val flow = position(nativeLayout, width, ordered, carriedExclusions, insets)
                if (left.contentEquals(flow.left) && right.contentEquals(flow.right)) {
                    for (line in 0 until nativeLayout.lineCount) {
                        if (left[line] + right[line] > 0 &&
                            nativeLayout.getLineMax(line) > width - left[line] - right[line] + 1f) {
                            throw UnsupportedFloatLayout("Native text exceeds the remaining float lane")
                        }
                    }
                    if (requireDrainedAtBoundary && flow.exclusions.any { it.outer.bottom > flow.bottom + 0.01f }) {
                        throw UnsupportedFloatLayout("Active float crosses an unsupported formatting boundary")
                    }
                    return NativeFloatGeometry(original, width, nativeLayout, flow, nodeFactory, decoration)
                }
                left = flow.left
                right = flow.right
            }
            throw UnsupportedFloatLayout("Float exclusions did not converge after 64 native layouts")
        }
    }
}

private class FloatMarker : ReplacementSpan() {
    override fun getSize(paint: Paint, text: CharSequence, start: Int, end: Int, fm: Paint.FontMetricsInt?): Int = 0
    override fun draw(canvas: Canvas, text: CharSequence, start: Int, end: Int, x: Float, top: Int, y: Int, bottom: Int, paint: Paint) = Unit
}

private data class Flow(
    val tops: FloatArray, val bottoms: FloatArray, val left: IntArray, val right: IntArray,
    val floats: List<PlacedNativeFloat>, val exclusions: List<NativeFloatExclusion>, val bottom: Float,
)

private fun position(layout: StaticLayout, width: Int, occurrences: List<NativeFloatOccurrence>,
    carriedExclusions: List<NativeFloatExclusion>, insets: NativeTextInsets): Flow {
    val tops = FloatArray(layout.lineCount)
    val bottoms = FloatArray(layout.lineCount)
    // StaticLayout repeats its last indent; always terminate exclusions with zero.
    val left = IntArray(layout.lineCount + 1)
    val right = IntArray(layout.lineCount + 1)
    val placed = mutableListOf<PlacedNativeFloat>()
    val exclusions = carriedExclusions.toMutableList()
    val anchors = occurrences.groupBy { layout.getLineForOffset(it.offset) }
    var y = 0f
    for (line in 0 until layout.lineCount) {
        val lineHeight = (layout.getLineBottom(line) - layout.getLineTop(line)).toFloat()
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
            val overlap = exclusions.filter { it.outer.top < y + lineHeight && it.outer.bottom > y }
            val l = ceil(max(insets.left, overlap.filter { it.side == TableFloatSide.Left }.maxOfOrNull { it.outer.right } ?: 0f) + insets.extraLeft).toInt().coerceIn(0, width)
            val r = ceil(max(insets.right, width - (overlap.filter { it.side == TableFloatSide.Right }.minOfOrNull { it.outer.left } ?: width.toFloat())) + insets.extraRight).toInt().coerceIn(0, width)
            if (l + r >= width && overlap.isEmpty()) throw UnsupportedFloatLayout("Text gutters consume the native line width")
            if (l + r < width) {
                left[line] = l
                right[line] = r
                break
            }
            y = overlap.minOf { it.outer.bottom }
        }
        tops[line] = y
        y += lineHeight
        if (!y.isFinite() || y > Int.MAX_VALUE / 4) throw UnsupportedFloatLayout("Float context exceeds native geometry")
        bottoms[line] = y
    }
    return Flow(tops, bottoms, left, right, placed, exclusions, y)
}
