package app.smallthingz.dict

import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.RectF

/** Resolved figure paints are total: legacy image border/background are never painted here. */
internal data class FigurePaints(val frameBackground: Int, val frameBorder: Int,
    val imageBackground: Int, val imageBorder: Int, val captionBackground: Int, val tableBorderTheme: Int = 0)

internal class NativeFigureGeometry(
    val metrics: FigureBoxMetrics,
    private val caption: FloatTextGeometry,
    private val paints: FigurePaints,
    private val drawImage: (Canvas, RectF) -> Unit,
    private val overlay: (Canvas) -> Unit,
    imageNodes: (RectF) -> List<FloatInteractionNode>,
) : FloatTextGeometry {
    constructor(metrics: FigureBoxMetrics, caption: FloatTextGeometry, paints: FigurePaints,
        drawImage: (Canvas, RectF) -> Unit, imageNodes: (RectF) -> List<FloatInteractionNode>) :
        this(metrics, caption, paints, drawImage, {}, imageNodes)
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
    private val resolvedImageNodes = imageNodes(imageBounds).map { it.copy(start = 0, end = 0) }
    override val nodes = (resolvedImageNodes +
        caption.nodes.map { node -> node.translated(captionX, captionY) })
        .mapIndexed { index, node -> node.copy(id = index) }
    override val extents: NativeGeometryExtents by lazy {
        val ink = NativeFloatBounds(minOf(0f, imageBounds.left - metrics.imageBorder),
            minOf(0f, imageBounds.top - metrics.imageBorder),
            maxOf(width.toFloat(), imageBounds.right + metrics.imageBorder),
            maxOf(height.toFloat(), imageBounds.bottom + metrics.imageBorder))
        val afterInk = metrics.tableCaption?.let { box -> box.after?.takeIf { box.prepared.layout.media.after?.paint != null } }
        val focusInk = nativeFocusInk(nodes)
        NativeGeometryExtents(width, height.toFloat(), enclosingBounds(enclosingBounds(ink, afterInk), focusInk),
            nativeBoundsOf(nodes.flatMap { it.bounds })).including(caption.extents, captionX, captionY)
    }
    override fun containsInteraction(x: Float, y: Float): Boolean =
        nodes.any { node -> node.bounds.any { it.contains(x, y) } } ||
            caption.containsInteraction(x - captionX, y - captionY)

    private val deferredMedia = metrics.tableCaption?.prepared?.layout?.media?.positioning == ContainerPositioning.RelativeAuto
    private fun mediaBounds(): List<RectF> = metrics.tableCaption?.let { box ->
        listOfNotNull(box.anchor.let { RectF(it.left,it.top,it.right,it.bottom) },
            box.after?.let { RectF(it.left,it.top,it.right,it.bottom) })
    } ?: listOf(imageBounds)
    override val positionedGroups: List<NativePositionedGroup> by lazy {
        val own = if (deferredMedia) listOf(NativePositionedGroup(mediaBounds(), resolvedImageNodes.indices.toSet(), 0, ::paintMedia))
            else emptyList()
        own + caption.positionedGroups.map { group -> group.translated(captionX, captionY) { id ->
            resolvedImageNodes.size + caption.nodes.indexOfFirst { it.id == id }.also { check(it >= 0) }
        } }
    }
    private fun fill(canvas: Canvas, bounds: RectF, color: Int) {
        if (color ushr 24 == 0 || bounds.isEmpty) return
        canvas.drawRect(bounds, Paint(Paint.ANTI_ALIAS_FLAG).apply { this.color = color; style = Paint.Style.FILL })
    }
    private fun border(canvas: Canvas, bounds: RectF, width: Float, color: Int) {
        // Authored zero never becomes a Canvas hairline.
        if (width <= 0 || color ushr 24 == 0 || bounds.isEmpty) return
        val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply { this.color = color; style = Paint.Style.STROKE; strokeWidth = width }
        val half = width / 2
        canvas.drawRect(bounds.left + half, bounds.top + half, bounds.right - half, bounds.bottom - half, paint)
    }
    private fun paintMedia(canvas: Canvas) {
        fill(canvas, imageBounds, paints.imageBackground)
        drawImage(canvas, imageBounds)
        border(canvas, RectF(imageBounds).apply { inset(-metrics.imageBorder, -metrics.imageBorder) }, metrics.imageBorder, paints.imageBorder)
        overlay(canvas)
        metrics.tableCaption?.let { box ->
            val after = box.after
            val graphic = box.prepared.layout.media.after?.paint
            if (after != null && graphic != null) paintFigureMagnifyGraphic(canvas, after.left, after.top,
                (after.right - after.left) / 15f, graphic)
        }
    }
    override fun paint(canvas: Canvas) {
        paintOrdinary(canvas)
        positionedGroups.forEach { it.paint(canvas) }
    }
    override fun paintOrdinary(canvas: Canvas) {
        val frame = RectF(0f, 0f, width.toFloat(), height.toFloat())
        fill(canvas, frame, paints.frameBackground)
        if (!deferredMedia) paintMedia(canvas)
        fill(canvas, RectF(metrics.frameBorder, metrics.tableCaption?.pixels?.height?.toFloat() ?: metrics.captionTop, width - metrics.frameBorder,
            height - metrics.frameBorder), paints.captionBackground)
        val saved = canvas.save()
        canvas.translate(captionX, captionY); caption.paintOrdinary(canvas); canvas.restoreToCount(saved)
        border(canvas, frame, metrics.frameBorder, paints.frameBorder)
        metrics.tableCaption?.borders(caption.height)?.forEach { edge ->
            val color = when (edge.color) {
                null -> paints.tableBorderTheme
                "" -> 0
                else -> checkNotNull(canonicalColorArgb(edge.color)).toInt()
            }
            paintNativeTableBorder(canvas, edge, color)
        }
    }
    override fun interactionNodeAt(x: Float, y: Float): FloatInteractionNode? {
        positionedGroups.lastOrNull { it.contains(x, y) }?.let { group ->
            return nodes.lastOrNull { it.id in group.nodeIds && it.contains(x, y) }
        }
        return nodes.lastOrNull { it.contains(x, y) }
    }
    override fun offsetForPosition(x: Float, y: Float): Int =
        positionedGroups.lastOrNull { it.contains(x, y) }?.sourceOffset ?: caption.offsetForPosition(x - captionX, y - captionY)
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
