package app.smallthingz.dict

import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.RectF

internal data class PositionedSemanticChild(val geometry: FloatTextGeometry, val x: Float, val y: Float,
    val direction: BidiResolvedDirection, val separatorBefore: String = "")

/** Ordered block/cell owners retain independent physical layouts and one source-order range map. */
internal class NativeSemanticGroup(
    override val width: Int,
    override val height: Int,
    children: List<PositionedSemanticChild>,
    private val decoration: (Canvas) -> Unit = {},
    private val extraNodes: List<FloatInteractionNode> = emptyList(),
    private val baselineProvider: (() -> NativeTextBaselines?)? = null,
) : FloatTextGeometry {
    private val children = children.toList()
    override val textBaselines: NativeTextBaselines? by lazy {
        if (baselineProvider != null) baselineProvider.invoke() else {
            val lines = this.children.mapNotNull { it.geometry.textBaselines?.translated(it.y) }
            NativeTextBaselines.of(lines.firstNotNullOfOrNull { it.first },
                lines.asReversed().firstNotNullOfOrNull { it.last })
        }
    }
    private data class Segment(val child: PositionedSemanticChild, val start: Int, val end: Int)
    private val segments: List<Segment>
    override val text: String
    init {
        require(width >= 0 && height >= 0)
        val source = StringBuilder()
        segments = children.map { child ->
            source.append(child.separatorBefore)
            val start = source.length
            source.append(child.geometry.text)
            Segment(child, start, source.length)
        }
        text = source.toString()
    }
    override val nodes = (extraNodes + segments.flatMap { segment -> segment.child.geometry.nodes.map { node ->
        node.translated(segment.child.x, segment.child.y).copy(
            start = segment.start + node.start, end = segment.start + node.end)
    } }).mapIndexed { index, node -> node.copy(id = index) }
    override val positionedGroups: List<NativePositionedGroup> by lazy {
        var base = extraNodes.size
        segments.flatMap { segment ->
            val first = base; val child = segment.child
            base += child.geometry.nodes.size
            child.geometry.positionedGroups.map { group -> group.translated(child.x, child.y, segment.start) { id ->
                first + child.geometry.nodes.indexOfFirst { it.id == id }.also { check(it >= 0) }
            } }
        }
    }
    override val ordinaryPaintBounds: List<NativeFloatBounds> by lazy {
        listOf(NativeFloatBounds(0f, 0f, width.toFloat(), height.toFloat())) + children.flatMap { child ->
            child.geometry.ordinaryPaintBounds.map { it.translated(child.x, child.y) }
        }
    }
    override val extents: NativeGeometryExtents by lazy {
        children.fold(NativeGeometryExtents(width, height.toFloat(),
            NativeFloatBounds(0f, 0f, width.toFloat(), height.toFloat()),
            nativeBoundsOf(extraNodes.flatMap { it.bounds }))) { outer, child ->
            outer.including(child.geometry.extents, child.x, child.y)
        }
    }
    override fun containsInteraction(x: Float, y: Float): Boolean = extraNodes.any { it.contains(x, y) } ||
        children.any { it.geometry.containsInteraction(x - it.x, y - it.y) }
    private fun at(offset: Int): Segment? {
        require(offset in 0..text.length)
        return segments.firstOrNull { offset in it.start until it.end }
            ?: segments.lastOrNull { it.end == offset && it.end > it.start }
    }
    override fun revealOffset(offset: Int, onRevealed: () -> Unit) {
        require(offset in 0..text.length)
        val segment = at(offset) ?: segments.firstOrNull { it.start >= offset }
        if (segment == null) onRevealed() else segment.child.geometry.revealOffset(
            (offset - segment.start).coerceIn(0, segment.end - segment.start), onRevealed)
    }
    override fun clipForOffset(offset: Int): RectF? {
        require(offset in 0..text.length)
        val segment = at(offset) ?: segments.firstOrNull { it.start >= offset } ?: return null
        return segment.child.geometry.clipForOffset((offset - segment.start).coerceIn(0, segment.end - segment.start))
            ?.let { RectF(it).apply { offset(segment.child.x, segment.child.y) } }
    }
    override val hasPreciseClips: Boolean get() = children.any { it.geometry.hasPreciseClips }
    override fun preciseClipForOffset(offset: Int): NativeTextClip? {
        val segment = at(offset) ?: segments.firstOrNull { it.start >= offset } ?: return null
        return segment.child.geometry.preciseClipForOffset((offset - segment.start).coerceIn(0, segment.end - segment.start))
            ?.translated(segment.child.x, segment.child.y)
    }
    override fun paintSelection(canvas: Canvas, start: Int, end: Int, paint: Paint) {
        require(start in 0..text.length && end in start..text.length)
        segments.forEach { segment ->
            val first = maxOf(start, segment.start); val last = minOf(end, segment.end)
            if (first < last) {
                val saved = canvas.save()
                try { canvas.translate(segment.child.x, segment.child.y)
                    segment.child.geometry.paintSelection(canvas, first - segment.start, last - segment.start, paint) }
                finally { canvas.restoreToCount(saved) }
            }
        }
    }
    override fun cursorAt(x: Float, y: Float): InlineCursor? {
        val positioned = children.asReversed().firstOrNull { child ->
            child.geometry.positionedGroups.any { it.contains(x - child.x, y - child.y) }
        }
        if (positioned != null) return positioned.geometry.cursorAt(x - positioned.x, y - positioned.y)
        val child = children.asReversed().firstOrNull {
            it.geometry.containsInteraction(x - it.x, y - it.y) || it.geometry.containsInput(x - it.x, y - it.y)
        } ?: return null
        return child.geometry.cursorAt(x - child.x, y - child.y)
    }
    override fun horizontalScrollTargetAt(x: Float, y: Float): NativeHorizontalScrollTarget? {
        // Deferred groups paint after every ordinary child, including later siblings.
        val child = children.asReversed().firstOrNull { child ->
            child.geometry.positionedGroups.any { it.contains(x - child.x, y - child.y) }
        } ?: children.asReversed().firstOrNull { it.geometry.containsInteraction(x - it.x, y - it.y) }
            ?: children.asReversed().firstOrNull { it.geometry.containsInput(x - it.x, y - it.y) }
            ?: return null
        return child.geometry.horizontalScrollTargetAt(x - child.x, y - child.y)
    }
    override fun paint(canvas: Canvas) {
        paintOrdinary(canvas)
        positionedGroups.forEach { it.paint(canvas) }
    }
    override fun paintOrdinary(canvas: Canvas) {
        decoration(canvas)
        children.forEach { child ->
            val saved = canvas.save(); canvas.translate(child.x, child.y)
            child.geometry.paintOrdinary(canvas); canvas.restoreToCount(saved)
        }
    }
    override fun offsetForPosition(x: Float, y: Float): Int {
        positionedGroups.lastOrNull { it.contains(x, y) }?.let { return it.sourceOffset }
        val segment = segments.lastOrNull { it.child.geometry.containsInteraction(x - it.child.x, y - it.child.y) }
            ?: segments.lastOrNull { x >= it.child.x && x < it.child.x + it.child.geometry.width &&
                y >= it.child.y && y < it.child.y + it.child.geometry.height }
            ?: segments.minByOrNull { kotlin.math.abs(y - it.child.y) } ?: return 0
        return segment.start + segment.child.geometry.offsetForPosition(x - segment.child.x, y - segment.child.y)
    }
    override fun interactionNodeAt(x: Float, y: Float): FloatInteractionNode? {
        positionedGroups.lastOrNull { it.contains(x, y) }?.let { group ->
            return nodes.lastOrNull { it.id in group.nodeIds && it.contains(x, y) }
        }
        return nodes.lastOrNull { it.contains(x, y) }
    }
    override fun caretRect(offset: Int): RectF {
        val segment = at(offset) ?: segments.firstOrNull { it.start >= offset }
            ?: return RectF(0f, height.toFloat(), 1f, height.toFloat())
        return segment.child.geometry.caretRect((offset - segment.start).coerceIn(0, segment.end - segment.start))
            .apply { offset(segment.child.x, segment.child.y) }
    }
    override fun lineRange(offset: Int): Pair<Int, Int> {
        val segment = at(offset) ?: return offset to offset
        val range = segment.child.geometry.lineRange(offset - segment.start)
        return segment.start + range.first to segment.start + range.second
    }
    override fun visualLineRanges(offset: Int): List<Pair<Int, Int>> {
        val segment = at(offset) ?: return listOf(offset to offset)
        return segment.child.geometry.visualLineRanges(offset - segment.start).map { range ->
            segment.start + range.first to segment.start + range.second
        }
    }
    override fun isHardLineBreak(offset: Int): Boolean {
        require(offset in 0 until text.length)
        val segment = segments.firstOrNull { offset >= it.start && offset < it.end }
        return segment?.let { it.child.geometry.isHardLineBreak(offset - it.start) }
            ?: (text[offset] == '\n') // Explicit separatorBefore, outside every child.
    }
    override fun visualOffset(offset: Int, direction: Int): Int {
        require(direction in listOf(-1, 1))
        val segment = at(offset)
        if (segment != null) {
            val local = offset - segment.start
            val moved = segment.child.geometry.visualOffset(local, direction)
            if (moved != local) return segment.start + moved
            val forward = (direction > 0) == (segment.child.direction == BidiResolvedDirection.Ltr)
            val neighbor = segments.getOrNull(segments.indexOf(segment) + if (forward) 1 else -1)
            if (neighbor != null) {
                val enterStart = (direction > 0) == (neighbor.child.direction == BidiResolvedDirection.Ltr)
                val edge = if (enterStart) 0 else neighbor.end - neighbor.start
                val boundary = neighbor.start + edge
                return if (boundary != offset) boundary
                    else neighbor.start + neighbor.child.geometry.visualOffset(edge, direction)
            }
        }
        return offset
    }
    override fun rectsForRange(start: Int, end: Int): List<RectF> {
        require(start in 0..text.length && end in start..text.length)
        return segments.flatMap { segment ->
            val first = maxOf(start, segment.start); val last = minOf(end, segment.end)
            if (first >= last) emptyList() else segment.child.geometry.rectsForRange(first - segment.start, last - segment.start)
                .map { RectF(it).apply { offset(segment.child.x, segment.child.y) } }
        }
    }
    override fun characterRects(start: Int, length: Int): List<RectF?> {
        require(start in 0..text.length && length >= 0 && length <= text.length - start)
        return (start until start + length).map { offset ->
            at(offset)?.takeIf { offset < it.end }?.let { segment ->
                segment.child.geometry.characterRects(offset - segment.start, 1).single()
                    ?.let { RectF(it).apply { offset(segment.child.x, segment.child.y) } }
            }
        }
    }
}
