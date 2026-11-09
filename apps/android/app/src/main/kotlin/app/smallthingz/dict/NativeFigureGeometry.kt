package app.smallthingz.dict

import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.RectF

/** Resolved figure paints are total: legacy image border/background are never painted here. */
internal data class FigurePaints(val frameBackground: Int, val frameBorder: Int,
    val imageBackground: Int, val imageBorder: Int, val captionBackground: Int)

internal class NativeFigureGeometry(
    val metrics: FigureBoxMetrics,
    private val caption: FloatTextGeometry,
    private val paints: FigurePaints,
    private val drawImage: (Canvas, RectF) -> Unit,
    imageNodes: (RectF) -> List<FloatInteractionNode>,
) : FloatTextGeometry {
    init {
        require(caption.width == metrics.captionWidth)
    }
    override val width = metrics.width
    override val height = metrics.height(caption.height)
    override val text: CharSequence get() = caption.text
    private val captionX = metrics.captionLeft
    private val captionY = metrics.captionTop + metrics.captionPadding.top
    val imageBounds = RectF(metrics.imageLeft, metrics.imageTop,
        metrics.imageLeft + metrics.image.width, metrics.imageTop + metrics.image.height)
    override val nodes = (imageNodes(imageBounds).map { it.copy(start = 0, end = 0) } +
        caption.nodes.map { node -> node.translated(captionX, captionY) })
        .mapIndexed { index, node -> node.copy(id = index) }

    override fun paint(canvas: Canvas) {
        val brush = Paint(Paint.ANTI_ALIAS_FLAG)
        fun fill(bounds: RectF, color: Int) {
            if (color ushr 24 == 0 || bounds.isEmpty) return
            brush.color = color; brush.style = Paint.Style.FILL
            canvas.drawRect(bounds, brush)
        }
        fun border(bounds: RectF, width: Float, color: Int) {
            // Canvas treats a zero-width Stroke as a hairline. Authored zero means no ink/extent.
            if (width <= 0 || color ushr 24 == 0 || bounds.isEmpty) return
            brush.color = color; brush.style = Paint.Style.STROKE; brush.strokeWidth = width
            val half = width / 2
            canvas.drawRect(bounds.left + half, bounds.top + half, bounds.right - half, bounds.bottom - half, brush)
        }
        val frame = RectF(0f, 0f, width.toFloat(), height.toFloat())
        fill(frame, paints.frameBackground)
        fill(imageBounds, paints.imageBackground)
        drawImage(canvas, imageBounds)
        val imageBorder = RectF(imageBounds).apply { inset(-metrics.imageBorder, -metrics.imageBorder) }
        border(imageBorder, metrics.imageBorder, paints.imageBorder)
        fill(RectF(metrics.frameBorder, metrics.captionTop, width - metrics.frameBorder,
            height - metrics.frameBorder), paints.captionBackground)
        val saved = canvas.save()
        canvas.translate(captionX, captionY); caption.paint(canvas); canvas.restoreToCount(saved)
        border(frame, metrics.frameBorder, paints.frameBorder)
    }
    override fun offsetForPosition(x: Float, y: Float): Int = caption.offsetForPosition(x - captionX, y - captionY)
    override fun caretRect(offset: Int): RectF = caption.caretRect(offset).apply { offset(captionX, captionY) }
    override fun lineRange(offset: Int): Pair<Int, Int> = caption.lineRange(offset)
    override fun visualOffset(offset: Int, direction: Int): Int = caption.visualOffset(offset, direction)
    override fun rectsForRange(start: Int, end: Int): List<RectF> = caption.rectsForRange(start, end)
        .map { RectF(it).apply { offset(captionX, captionY) } }
    override fun characterRects(start: Int, length: Int): List<RectF?> = caption.characterRects(start, length)
        .map { it?.let { bounds -> RectF(bounds).apply { offset(captionX, captionY) } } }
}

/** No Text/StaticLayout is constructed for an authoritative empty caption. */
internal class EmptyCaptionGeometry(override val width: Int, override val text: String = "") : FloatTextGeometry {
    init { require(width >= 0) }
    override val height = 0
    override val nodes = emptyList<FloatInteractionNode>()
    override fun paint(canvas: Canvas) = Unit
    override fun offsetForPosition(x: Float, y: Float) = 0
    override fun caretRect(offset: Int): RectF { require(offset in 0..text.length); return RectF(0f, 0f, 1f, 0f) }
    override fun lineRange(offset: Int): Pair<Int, Int> { require(offset in 0..text.length); return 0 to text.length }
    override fun visualOffset(offset: Int, direction: Int): Int {
        require(offset in 0..text.length && direction in listOf(-1, 1))
        return if (offset == 0 && direction < 0 || offset == text.length && direction > 0) offset
            else Character.offsetByCodePoints(text, offset, direction)
    }
    override fun rectsForRange(start: Int, end: Int): List<RectF> { require(start in 0..text.length && end in start..text.length); return emptyList() }
    override fun characterRects(start: Int, length: Int): List<RectF?> {
        require(start in 0..text.length && length >= 0 && length <= text.length - start); return List(length) { null }
    }
}
