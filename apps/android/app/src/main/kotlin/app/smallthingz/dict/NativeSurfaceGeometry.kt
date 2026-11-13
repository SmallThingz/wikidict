package app.smallthingz.dict

import android.graphics.Canvas
import android.graphics.RectF

/**
 * A physical View/Canvas covers signed overflow while its Compose parent still reports the
 * original used box. Text, actions, source offsets and the original painter keep one owner.
 */
internal class NativeSurfaceGeometry(val content: FloatTextGeometry,
    val surface: NativeSurfaceBox = NativeSurfaceBox.from(content.extents)) : FloatTextGeometry {
    private val dx = -surface.left.toFloat()
    private val dy = -surface.top.toFloat()
    override val text: CharSequence get() = content.text
    override val width: Int get() = surface.width
    override val height: Int get() = surface.height
    override val textBaselines: NativeTextBaselines? get() = content.textBaselines?.translated(dy)
    override val nodes: List<FloatInteractionNode> = content.nodes.map { it.translated(dx, dy) }
    override val positionedGroups get() = content.positionedGroups.map { it.translated(dx, dy) }
    override val extents: NativeGeometryExtents get() = NativeGeometryExtents(width, height.toFloat(),
        content.extents.ink?.translated(dx, dy), content.extents.interaction?.translated(dx, dy))
    override val ordinaryPaintBounds: List<NativeFloatBounds> get() =
        content.ordinaryPaintBounds.map { it.translated(dx, dy) }
    override val focusBounds: RectF get() = RectF(content.focusBounds).apply { offset(dx, dy) }
    override fun containsInteraction(x: Float, y: Float) = content.containsInteraction(x - dx, y - dy)
    override fun containsInput(x: Float, y: Float) = content.containsInput(x - dx, y - dy)
    override fun interactionNodeAt(x: Float, y: Float): FloatInteractionNode? =
        content.interactionNodeAt(x - dx, y - dy)?.translated(dx, dy)
    override fun paint(canvas: Canvas) {
        val saved = canvas.save()
        try { canvas.translate(dx, dy); content.paint(canvas) }
        finally { canvas.restoreToCount(saved) }
    }
    override fun paintOrdinary(canvas: Canvas) {
        val saved = canvas.save()
        try { canvas.translate(dx, dy); content.paintOrdinary(canvas) }
        finally { canvas.restoreToCount(saved) }
    }
    override fun offsetForPosition(x: Float, y: Float): Int = content.offsetForPosition(x - dx, y - dy)
    override fun rectsForRange(start: Int, end: Int): List<RectF> = content.rectsForRange(start, end)
        .map { RectF(it).apply { offset(dx, dy) } }
    override fun characterRects(start: Int, length: Int): List<RectF?> = content.characterRects(start, length)
        .map { it?.let { bounds -> RectF(bounds).apply { offset(dx, dy) } } }
    override fun revealOffset(offset: Int, onRevealed: () -> Unit) = content.revealOffset(offset, onRevealed)
    override fun clipForOffset(offset: Int): RectF? = content.clipForOffset(offset)
        ?.let { RectF(it).apply { offset(dx, dy) } }
    override fun horizontalScrollTargetAt(x: Float, y: Float): NativeHorizontalScrollTarget? =
        content.horizontalScrollTargetAt(x - dx, y - dy)
    override fun caretRect(offset: Int): RectF = RectF(content.caretRect(offset)).apply { offset(dx, dy) }
    override fun lineRange(offset: Int): Pair<Int, Int> = content.lineRange(offset)
    override fun visualOffset(offset: Int, direction: Int): Int = content.visualOffset(offset, direction)
}
