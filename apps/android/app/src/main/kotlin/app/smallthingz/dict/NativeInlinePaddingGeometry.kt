package app.smallthingz.dict

import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.RectF
import kotlin.math.abs
import kotlin.math.ceil

/** A complete inline owner's fixed edges surround its original normalized text geometry.
 * The outer Ruby allocation may contain free space; it is not part of this owner's box. */
internal class NativeInlinePaddingGeometry(
    private val inner: FloatTextGeometry,
    private val owner: Span,
    innerAdvance: Float,
    left: Float,
    right: Float,
    allocation: Float,
    private val format: NativeRubyGroupFormat,
    content: NativeUsedLineMetrics,
    private val localShift: Float,
) : FloatTextGeometry {
    init {
        if (listOf(innerAdvance, left, right, allocation).any { !it.isFinite() || it < 0f || it > TablePixelLimit } ||
            innerAdvance.toDouble() + left + right > TablePixelLimit ||
            !localShift.isFinite() || abs(localShift) > TablePixelLimit)
            throw UnsupportedFloatLayout("Inline padding exceeds native coordinates")
    }
    private val naturalWidth = innerAdvance + left + right
    private val boxLeft = (allocation - naturalWidth) / 2f
    private val dx = boxLeft + left
    private val dy = localShift - (inner.textBaselines?.first
        ?: throw UnsupportedFloatLayout("Inline padding lacks its original text baseline"))
    private val box = NativeFloatBounds(boxLeft, content.top + localShift,
        boxLeft + naturalWidth, content.bottom + localShift)
    init {
        if (listOf(dx, dy, box.left, box.top, box.right, box.bottom).any {
                !it.isFinite() || abs(it) > TablePixelLimit
            }) throw UnsupportedFloatLayout("Inline padding placement exceeds native coordinates")
    }
    override val text: CharSequence get() = inner.text
    override val width = ceil(allocation.toDouble()).toInt()
    override val height = ceil(content.height.toDouble()).toInt()
    override val textBaselines = NativeTextBaselines(0f, 0f)
    override val nodes = inner.nodes.map { it.translated(dx, dy) }
    override val positionedGroups get() = inner.positionedGroups.map { it.translated(dx, dy) }
    override val hasPreciseClips get() = inner.hasPreciseClips
    private fun translated(rect: RectF) = RectF(rect).apply { offset(dx, dy) }
    private fun boxRect() = RectF(box.left, box.top, box.right, box.bottom)

    private fun decorations(reserve: Boolean): List<NativeInlineDecorationFragment> {
        val appearance = if (reserve) null else format.actionPaint?.appearance()
        val color = appearance?.color ?: format.paint.color
        return buildList {
            fun decoration(position: Float, thickness: Float, color: Int, style: InlineUnderlineStyle) {
                if (thickness <= 0f || naturalWidth == 0f) return
                val top = localShift + position
                val bottom = top + thickness
                if (!top.isFinite() || !bottom.isFinite() || abs(top) > TablePixelLimit || abs(bottom) > TablePixelLimit)
                    throw UnsupportedFloatLayout("Inline padding decoration exceeds native coordinates")
                add(NativeInlineDecorationFragment(NativeFloatBounds(box.left, top, box.right, bottom), color, style))
            }
            if (format.paint.isStrikeThruText) decoration(format.paint.strikeThruPosition,
                format.paint.strikeThruThickness, color, InlineUnderlineStyle.Solid)
            val authored = format.underline
            if (authored != null) decoration(format.paint.underlinePosition,
                authored.thickness ?: format.paint.underlineThickness, authored.color ?: color, authored.style)
            else if (reserve && format.actionPaint != null || (appearance?.underline ?: format.paint.isUnderlineText))
                decoration(format.paint.underlinePosition, format.paint.underlineThickness, color, InlineUnderlineStyle.Solid)
        }
    }
    private val reservedDecorations = decorations(reserve = true).map { it.bounds }
    override val ordinaryPaintBounds: List<NativeFloatBounds> get() =
        inner.ordinaryPaintBounds.map { it.translated(dx, dy) } + reservedDecorations +
            if (format.paint.bgColor ushr 24 != 0) listOf(box) else emptyList()
    override val extents get() = NativeGeometryExtents(width, height.toFloat(),
        ordinaryPaintBounds.reduceOrNull { a, b -> a.enclosing(b) },
        enclosingBounds(inner.extents.interaction?.translated(dx, dy), box))
    override val focusBounds: RectF get() = boxRect()
    override fun containsInteraction(x: Float, y: Float): Boolean = boxRect().contains(x, y) ||
        inner.containsInteraction(x - dx, y - dy)
    override fun containsInput(x: Float, y: Float): Boolean = boxRect().contains(x, y) ||
        inner.containsInput(x - dx, y - dy)
    override fun interactionNodeAt(x: Float, y: Float): FloatInteractionNode? =
        inner.interactionNodeAt(x - dx, y - dy)?.translated(dx, dy)
    override fun inlinePaddingGroupRects(owner: Span, start: Int, end: Int): List<RectF>? {
        require(start in 0..text.length && end in start..text.length)
        if (owner === this.owner && start == 0 && end == text.length) return listOf(boxRect())
        return inner.inlinePaddingGroupRects(owner, start, end)?.map(::translated)
    }
    override fun rectsForRange(start: Int, end: Int): List<RectF> = inner.rectsForRange(start, end).map(::translated)
    override fun characterRects(start: Int, length: Int): List<RectF?> =
        inner.characterRects(start, length).map { it?.let(::translated) }
    override fun caretRect(offset: Int): RectF = translated(inner.caretRect(offset))
    override fun offsetForPosition(x: Float, y: Float): Int = inner.offsetForPosition(x - dx, y - dy)
    override fun lineRange(offset: Int): Pair<Int, Int> = inner.lineRange(offset)
    override fun visualLineRanges(offset: Int): List<Pair<Int, Int>> = inner.visualLineRanges(offset)
    override fun isHardLineBreak(offset: Int): Boolean = inner.isHardLineBreak(offset)
    override fun visualOffset(offset: Int, direction: Int): Int = inner.visualOffset(offset, direction)
    override fun revealOffset(offset: Int, onRevealed: () -> Unit) = inner.revealOffset(offset, onRevealed)
    override fun revealNode(id: Int, onRevealed: () -> Unit) = inner.revealNode(id, onRevealed)
    override fun clipForOffset(offset: Int): RectF? = inner.clipForOffset(offset)?.let(::translated)
    override fun preciseClipForOffset(offset: Int): NativeTextClip? = inner.preciseClipForOffset(offset)?.translated(dx, dy)
    override fun horizontalScrollTargetAt(x: Float, y: Float): NativeHorizontalScrollTarget? =
        inner.horizontalScrollTargetAt(x - dx, y - dy)
    override fun cursorAt(x: Float, y: Float): InlineCursor? = inner.cursorAt(x - dx, y - dy)
        ?: format.cursor?.takeIf { boxRect().contains(x, y) }
    override fun paintSelection(canvas: Canvas, start: Int, end: Int, paint: Paint) {
        val saved = canvas.save()
        try { canvas.translate(dx, dy); inner.paintSelection(canvas, start, end, paint) }
        finally { canvas.restoreToCount(saved) }
    }
    private fun paint(canvas: Canvas, ordinary: Boolean) {
        if (format.paint.bgColor ushr 24 != 0)
            canvas.drawRect(box.left, box.top, box.right, box.bottom, Paint().apply { color = format.paint.bgColor })
        val saved = canvas.save()
        try {
            canvas.translate(dx, dy)
            if (ordinary) inner.paintOrdinary(canvas) else inner.paint(canvas)
        } finally { canvas.restoreToCount(saved) }
        decorations(reserve = false).forEach { it.paint(canvas) }
    }
    override fun paint(canvas: Canvas) = paint(canvas, ordinary = false)
    override fun paintOrdinary(canvas: Canvas) = paint(canvas, ordinary = true)
}

/** Native selection regions may round past a fractional text advance. Only child
 * action bounds are restricted to the exact content sides of their original owner. */
internal fun nativeInlinePaddingChildActionRects(geometry: FloatTextGeometry, owner: Span,
    start: Int, end: Int, edges: NativeInlinePaddingEdges, fragments: List<RectF>): List<RectF> {
    val boxes = geometry.inlinePaddingGroupRects(owner, start, end)
        ?: throw UnsupportedFloatLayout("Inline padding action geometry is unavailable")
    if (boxes.isEmpty()) return emptyList()
    if (boxes.size != 1) throw UnsupportedFloatLayout("Inline padding action requires one native fragment")
    val box = boxes.single()
    val left = box.left + edges.left
    val right = box.right - edges.right
    if (!left.isFinite() || !right.isFinite())
        throw UnsupportedFloatLayout("Inline padding action exceeds native coordinates")
    if (right <= left) return emptyList()
    return fragments.mapNotNull { source ->
        RectF(source).apply {
            this.left = maxOf(this.left, left)
            this.right = minOf(this.right, right)
        }.takeUnless { it.isEmpty }
    }
}
