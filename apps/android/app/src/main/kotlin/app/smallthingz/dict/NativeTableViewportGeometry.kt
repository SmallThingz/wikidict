package app.smallthingz.dict

import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.RectF

/** One immutable scroll placement of the existing caption/grid body. Logical offsets and
 * action IDs survive clipping; scrolling never creates a second selection owner. */
internal class NativeTableViewportGeometry(
    private val content: FloatTextGeometry,
    private val placement: NativeTableBlockPlacement,
    private val afterContentPublication: ((FloatTextGeometry?, NativeTableBlockPlacement?) -> Unit) -> Unit = {
        it(content, placement)
    },
) : FloatTextGeometry {
    override val text: CharSequence get() = content.text
    override val width: Int get() = placement.ownerWidth
    override val height: Int get() = placement.ownerHeight
    private val x = placement.contentX + placement.physicalScrollX
    private val y = placement.contentY
    private val clip = RectF(placement.contentClip)
    private val precise = placement.cornerClip?.let { nativeTableContentClip(it, clip) }
    override val hasPreciseClips: Boolean get() = precise != null || content.hasPreciseClips
    private fun containsClip(x: Float, y: Float): Boolean = clip.contains(x, y) && (precise?.contains(x, y) ?: true)
    private fun paintClip(canvas: Canvas) { canvas.clipRect(clip); precise?.clip(canvas) }
    private fun translated(rect: RectF) = RectF(rect).apply { offset(x, y) }
    private fun clipped(rect: RectF): RectF? = translated(rect).takeIf { it.intersect(clip) && !it.isEmpty }
        ?.let { if (precise == null) it else precise.bounds(it) }
    private fun intersected(rect: RectF): RectF = RectF(rect).apply { if (!intersect(clip)) setEmpty() }
    private fun clippedBounds(value: NativeFloatBounds?): NativeFloatBounds? = value?.let {
        clipped(RectF(it.left, it.top, it.right, it.bottom))?.let { rect ->
            NativeFloatBounds(rect.left, rect.top, rect.right, rect.bottom)
        }
    }
    private fun emptyBand(rect: RectF): Boolean = rect.left == rect.right && rect.top <= rect.bottom &&
        listOf(rect.left, rect.top, rect.right, rect.bottom).all(Float::isFinite)
    private fun reveal(rect: RectF?, currentPlacement: NativeTableBlockPlacement?, complete: () -> Unit,
        allowEmptyBand: Boolean = false) {
        if (rect == null || rect.isEmpty && !(allowEmptyBand && emptyBand(rect)) || currentPlacement == null) complete()
        else currentPlacement.revealContentRect(RectF(rect), complete)
    }
    override val nodes: List<FloatInteractionNode> = content.nodes.map { node ->
        val shifted = node.translated(x, y)
        val ownClip = shifted.preciseClip?.intersected(clip)?.let { if (precise == null) it else it.intersected(precise) } ?: precise
        // Keep authenticated empty declaring bands/points raw for identity/reveal. Visibility is
        // still governed by the same clips; zero-width rectangles never gain pointer area.
        val emptyBands = if (node.kind == FloatInteractionKind.LINK && node.start == node.end)
            shifted.bounds.filter(::emptyBand).map(::RectF) else emptyList()
        shifted.copy(bounds = (if (ownClip == null) node.bounds.mapNotNull(::clipped)
            else shifted.bounds.mapNotNull(ownClip::bounds)) + emptyBands, preciseClip = ownClip,
            clipBounds = shifted.clipBounds?.let(::intersected) ?: RectF(clip),
            onReveal = { complete ->
                content.revealNode(node.id) {
                    afterContentPublication { current, currentPlacement ->
                        val fresh = current?.takeIf { it.text.toString() == text.toString() }?.nodes
                            ?.firstOrNull { it.id == node.id && it.kind == node.kind &&
                                it.start == node.start && it.end == node.end }
                        val emptyOwner = fresh?.let { it.kind == FloatInteractionKind.LINK && it.start == it.end } == true
                        reveal(fresh?.bounds?.firstOrNull { !it.isEmpty || emptyOwner && emptyBand(it) },
                            currentPlacement, complete, allowEmptyBand = emptyOwner)
                    }
                }
            })
    }
    override val textBaselines: NativeTextBaselines? get() = content.textBaselines?.translated(y)
    override val positionedGroups: List<NativePositionedGroup> = content.positionedGroups.map { group ->
        val ownClip = group.preciseClip?.translated(x, y)?.intersected(clip)
            ?.let { if (precise == null) it else it.intersected(precise) } ?: precise
        group.copy(bounds = if (ownClip == null) group.bounds.mapNotNull(::clipped)
            else group.bounds.mapNotNull { ownClip.bounds(translated(it)) }, preciseClip = ownClip, paint = { canvas ->
            val saved = canvas.save()
            try { paintClip(canvas); canvas.translate(x, y); group.paint(canvas) }
            finally { canvas.restoreToCount(saved) }
        })
    }
    override val ordinaryPaintBounds: List<NativeFloatBounds> = content.ordinaryPaintBounds.mapNotNull(::clippedBounds)
    override val extents: NativeGeometryExtents = NativeGeometryExtents(width, height.toFloat(),
        enclosingBounds(placement.borderBox.let { NativeFloatBounds(it.left, it.top, it.right, it.bottom) },
            clippedBounds(content.extents.ink)), clippedBounds(content.extents.interaction))
    override val focusBounds: RectF get() = RectF(placement.borderBox)
    override fun containsInteraction(x: Float, y: Float): Boolean = containsClip(x, y) &&
        content.containsInteraction(x - this.x, y - this.y)
    override fun containsInput(x: Float, y: Float): Boolean = containsClip(x, y)
    override fun interactionNodeAt(x: Float, y: Float): FloatInteractionNode? {
        if (!containsClip(x, y)) return null
        val child = content.interactionNodeAt(x - this.x, y - this.y) ?: return null
        return nodes.firstOrNull { it.id == child.id && it.contains(x, y) }
    }
    override fun cursorAt(x: Float, y: Float): InlineCursor? =
        if (containsClip(x, y)) content.cursorAt(x - this.x, y - this.y) else null
    override fun horizontalScrollTargetAt(x: Float, y: Float): NativeHorizontalScrollTarget? {
        if (!containsClip(x, y)) return null
        return content.horizontalScrollTargetAt(x - this.x, y - this.y) ?: placement.scrollTarget
    }
    override fun paint(canvas: Canvas) {
        paintOrdinary(canvas)
        positionedGroups.forEach { it.paint(canvas) }
    }
    override fun paintOrdinary(canvas: Canvas) {
        val saved = canvas.save()
        try { paintClip(canvas); canvas.translate(x, y); content.paintOrdinary(canvas) }
        finally { canvas.restoreToCount(saved) }
    }
    override fun paintSelection(canvas: Canvas, start: Int, end: Int, paint: Paint) {
        val saved = canvas.save()
        try { paintClip(canvas); canvas.translate(x, y); content.paintSelection(canvas, start, end, paint) }
        finally { canvas.restoreToCount(saved) }
    }
    override fun preciseClipForOffset(offset: Int): NativeTextClip? {
        val child = content.preciseClipForOffset(offset)?.translated(x, y)?.intersected(clip)
        return if (child == null) precise else if (precise == null) child else child.intersected(precise)
    }
    override fun offsetForPosition(x: Float, y: Float): Int = content.offsetForPosition(x - this.x, y - this.y)
    override fun rectsForRange(start: Int, end: Int): List<RectF> {
        require(start in 0..text.length && end in start..text.length)
        // A nested rounded owner has its own clip per source range. Keep that shape until
        // intersection, rather than clipping a previous bounding box into visible corners.
        return if (content.hasPreciseClips) characterRects(start, end - start).filterNotNull()
            else content.rectsForRange(start, end).mapNotNull(::clipped)
    }
    override fun characterRects(start: Int, length: Int): List<RectF?> = content.characterRects(start, length).mapIndexed { index, rect ->
        val bounds = rect?.let(::clipped) ?: return@mapIndexed null
        val exact = preciseClipForOffset(start + index)
        if (exact == null) bounds else exact.bounds(bounds)
    }
    // Carets retain logical position for arrow navigation; the View clips their paint separately.
    override fun caretRect(offset: Int): RectF = translated(content.caretRect(offset))
    override fun clipForOffset(offset: Int): RectF = content.clipForOffset(offset)?.let { intersected(translated(it)) }
        ?: RectF(clip)
    override fun revealOffset(offset: Int, onRevealed: () -> Unit) {
        content.revealOffset(offset) {
            afterContentPublication { current, currentPlacement ->
                reveal(current?.takeIf { it.text.toString() == text.toString() }?.caretRect(offset), currentPlacement, onRevealed)
            }
        }
    }
    override fun lineRange(offset: Int): Pair<Int, Int> = content.lineRange(offset)
    override fun visualLineRanges(offset: Int): List<Pair<Int, Int>> = content.visualLineRanges(offset)
    override fun isHardLineBreak(offset: Int): Boolean = content.isHardLineBreak(offset)
    override fun visualOffset(offset: Int, direction: Int): Int = content.visualOffset(offset, direction)
}

/** A reveal continuation observes the enclosing body's fresh publication, including a
 * nested scroll whose geometry arrived after the caller's immutable snapshot. */
internal class NativeTableViewportPublication {
    private var closed = false
    private val pending = mutableListOf<(FloatTextGeometry?, NativeTableBlockPlacement?) -> Unit>()
    var invalidate: (() -> Unit)? = null

    fun afterPublication(continuation: (FloatTextGeometry?, NativeTableBlockPlacement?) -> Unit) {
        if (closed || invalidate == null) { continuation(null, null); return }
        pending += continuation
        invalidate?.invoke()
    }

    fun publish(content: FloatTextGeometry?, placement: NativeTableBlockPlacement?) {
        val callbacks = pending.toList()
        pending.clear()
        callbacks.forEach { it(content, placement) }
    }

    fun close() {
        closed = true
        invalidate = null
        publish(null, null)
    }
}
