package app.smallthingz.dict

import android.graphics.Canvas
import android.graphics.RectF

internal data class NativeTextBaselines(val first: Float?, val last: Float?) {
    init {
        require(first != null || last != null)
        require(first == null || first.isFinite())
        require(last == null || last.isFinite())
    }
    fun translated(y: Float) = NativeTextBaselines(first?.plus(y), last?.plus(y))
    companion object {
        fun of(first: Float?, last: Float?): NativeTextBaselines? =
            if (first == null && last == null) null else NativeTextBaselines(first, last)
    }
}

/** Table baseline rules are shared by Compose alignment and selected child geometry. */
internal fun nativeTableTextBaselines(cells: List<NativeTextBaselines?>, rows: List<Int>,
    tops: List<Float>): NativeTextBaselines? {
    require(cells.size == rows.size && cells.size == tops.size)
    val first = cells.indices.mapNotNull { i ->
        if (rows[i] == 0) cells[i]?.first?.plus(tops[i]) else null
    }.maxOrNull()
    val last = cells.indices.mapNotNull { i -> cells[i]?.last?.plus(tops[i]) }.maxOrNull()
    return NativeTextBaselines.of(first, last)
}

/** All offsets are UTF-16 indices in [text]; layout must never insert line breaks. */
internal interface FloatTextGeometry {
    val text: CharSequence
    val width: Int
    val height: Int
    val nodes: List<FloatInteractionNode>
    /** Actual line baselines; absent for a true empty box, even if it has borders or padding. */
    val textBaselines: NativeTextBaselines? get() = null
    /** Deferred paint groups retain this owner's text and node indices; no second child graph. */
    val positionedGroups: List<NativePositionedGroup> get() = emptyList()
    /** Fixed boxes default to their allocation; text/composite owners publish their signed overflow. */
    val extents: NativeGeometryExtents get() = NativeGeometryExtents(width, height.toFloat(),
        NativeFloatBounds(0f, 0f, width.toFloat(), height.toFloat()),
        nativeBoundsOf(rectsForRange(0, text.length) + nodes.flatMap { it.bounds }))
    /** Paint envelopes are never hit targets. Keep actual selectable advances and action bounds. */
    fun containsInteraction(x: Float, y: Float): Boolean = nodes.any { it.contains(x, y) } ||
        rectsForRange(0, text.length).any { it.contains(x, y) }
    fun containsInput(x: Float, y: Float): Boolean = (x >= 0f && y >= 0f && x < width && y < height) ||
        containsInteraction(x, y)
    val focusBounds: RectF get() = if (width > 0 && height > 0) RectF(0f, 0f, width.toFloat(), height.toFloat())
        else extents.interaction?.let { RectF(it.left, it.top, it.right, it.bottom) } ?: RectF()
    /** Point priority may differ from logical/keyboard/accessibility traversal order. */
    fun interactionNodeAt(x: Float, y: Float): FloatInteractionNode? = nodes.lastOrNull { it.contains(x, y) }
    fun paint(canvas: Canvas)
    /** A containing Entry paint context schedules [positionedGroups] separately. */
    fun paintOrdinary(canvas: Canvas) = paint(canvas)
    fun offsetForPosition(x: Float, y: Float): Int
    fun rectsForRange(start: Int, end: Int): List<RectF>
    /** Exactly [length] entries, including null for a character without visible bounds. */
    fun characterRects(start: Int, length: Int): List<RectF?>
    fun caretRect(offset: Int): RectF
    /** Logical bounds of the visual line containing offset; the end is exclusive. */
    fun lineRange(offset: Int): Pair<Int, Int>
    /** direction -1 means visual left; +1 means visual right. */
    fun visualOffset(offset: Int, direction: Int): Int
}

internal fun nativeBoundsOf(rectangles: List<RectF>): NativeFloatBounds? = rectangles
    .filter { !it.isEmpty }.map { NativeFloatBounds(it.left, it.top, it.right, it.bottom) }
    .reduceOrNull { a, b -> a.enclosing(b) }

internal enum class FloatInteractionKind { LINK, IMAGE, HEADING, CONTROL, MARKER }

/** IDs must remain stable across width reflow. Empty and single-space labels are authored data. */
internal data class FloatInteractionNode(
    val id: Int,
    val kind: FloatInteractionKind,
    val start: Int,
    val end: Int,
    val bounds: List<RectF>,
    val label: CharSequence?,
    val tooltip: CharSequence?,
    val onClick: (() -> Unit)?,
    val stateDescription: CharSequence? = null,
    val onLongClick: (() -> Unit)? = null,
    val hitTest: ((Float, Float) -> Boolean)? = null,
    val missingLinkPaint: NativeMissingLinkPaint? = null,
    val focusPaint: NativeNodeFocusPaint? = null,
) {
    fun contains(x: Float, y: Float): Boolean = bounds.any { it.contains(x, y) } && (hitTest?.invoke(x, y) ?: true)
    fun translated(x: Float, y: Float): FloatInteractionNode = copy(
        bounds = bounds.map { RectF(it).apply { offset(x, y) } },
        hitTest = hitTest?.let { test -> { px, py -> test(px - x, py - y) } },
        focusPaint = focusPaint?.translated(x, y),
    )
}

/** Null keeps the reader's ordinary focus treatment; None is an explicit authored absence. */
internal sealed interface NativeNodeFocusPaint {
    data object None : NativeNodeFocusPaint
    data class Outline(val bounds: RectF, val width: Float, val color: Int, val radius: Float,
        val offset: Float) : NativeNodeFocusPaint
    data class Fragments(val outlines: List<Outline>) : NativeNodeFocusPaint
    /** One inline owner may contain a font band and an atomic child's border box. */
    data class Connected(val outlines: List<Outline>) : NativeNodeFocusPaint
    fun translated(x: Float, y: Float): NativeNodeFocusPaint = when (this) {
        None -> None
        is Outline -> copy(bounds = RectF(bounds).apply { offset(x, y) })
        is Fragments -> copy(outlines = outlines.map { it.copy(bounds = RectF(it.bounds).apply { offset(x, y) }) })
        is Connected -> copy(outlines = outlines.map { it.copy(bounds = RectF(it.bounds).apply { offset(x, y) }) })
    }
}

internal fun NativeNodeFocusPaint.outlines(): List<NativeNodeFocusPaint.Outline> = when (this) {
    NativeNodeFocusPaint.None -> emptyList()
    is NativeNodeFocusPaint.Outline -> listOf(this)
    is NativeNodeFocusPaint.Fragments -> outlines
    is NativeNodeFocusPaint.Connected -> outlines
}

internal fun nativeFocusInk(nodes: List<FloatInteractionNode>): NativeFloatBounds? = nodes
    .flatMap { it.focusPaint?.outlines().orEmpty() }.mapNotNull { outline ->
        if (outline.color ushr 24 == 0) null else nativeOutlineGeometry(NativeFloatBounds(outline.bounds.left,
            outline.bounds.top, outline.bounds.right, outline.bounds.bottom), outline.width, outline.radius, outline.offset)?.ink
    }.reduceOrNull { a, b -> a.enclosing(b) }

/** Region-based hit rectangles omit zero advances. Focus retains the actual native
 * caret positions and line bands, without promoting the caret's one-pixel width to a hit. */
internal fun nativeLinkFocusFragments(geometry: FloatTextGeometry, start: Int, end: Int,
    hitFragments: List<RectF>): List<RectF> {
    if (hitFragments.isNotEmpty()) return hitFragments
    return (start until end).map { offset ->
        val first = geometry.caretRect(offset)
        val next = geometry.caretRect(offset + 1)
        val endX = if (first.top == next.top && first.bottom == next.bottom) next.left else first.left
        RectF(minOf(first.left, endX), first.top, maxOf(first.left, endX), first.bottom)
    }.distinct()
}

internal fun figureLinkFocusPaint(policy: FigureLinkPaint, fragments: List<RectF>, density: Float,
    bodyPixels: Float, connected: Boolean = false): NativeNodeFocusPaint {
    val outline = policy.focusOutline ?: return NativeNodeFocusPaint.None
    val width = figureLengthPixels(outline.width, density, bodyPixels)
    val radius = figureLengthPixels(outline.radius, density, bodyPixels)
    val offset = outline.offset.value.toDouble() * if (outline.offset.unit == StyleLengthUnit.Px) density else bodyPixels
    if (!offset.isFinite() || kotlin.math.abs(offset) > TablePixelLimit)
        throw UnsupportedFloatLayout("Link focus offset exceeds the native geometry range")
    val color = 0xff000000.toInt() or (outline.color as FigureColor.Rgb).value.substring(1).toInt(16)
    val parts = fragments.map {
        require(listOf(it.left, it.top, it.right, it.bottom).all(Float::isFinite) && it.width() >= 0f && it.height() >= 0f)
        NativeNodeFocusPaint.Outline(RectF(it), width, color, radius, offset.toFloat())
    }
    return if (connected) NativeNodeFocusPaint.Connected(parts) else NativeNodeFocusPaint.Fragments(parts)
}

internal data class NativePositionedGroup(val bounds: List<RectF>, val nodeIds: Set<Int>,
    val sourceOffset: Int, val paint: (Canvas) -> Unit) {
    fun contains(x: Float, y: Float): Boolean = bounds.any { it.contains(x, y) }
    fun translated(x: Float, y: Float, textOffset: Int = 0, nodeId: (Int) -> Int = { it }): NativePositionedGroup =
        copy(bounds = bounds.map { RectF(it).apply { offset(x, y) } }, nodeIds = nodeIds.map(nodeId).toSet(),
            sourceOffset = sourceOffset + textOffset, paint = { canvas ->
                val save = canvas.save()
                try { canvas.translate(x, y); paint(canvas) } finally { canvas.restoreToCount(save) }
            })
}

internal val LocalNativePositionedPaintParent = androidx.compose.runtime.staticCompositionLocalOf { false }
internal val LocalNativePositionedPaintUnavailable = androidx.compose.runtime.staticCompositionLocalOf<String?> { null }

/** Paint suppression changes no geometry, action, selection or accessibility owner. */
internal class NativeOrdinaryPaint(private val content: FloatTextGeometry) : FloatTextGeometry by content {
    override fun paint(canvas: Canvas) = content.paintOrdinary(canvas)
}

internal data class NativeOutlineGeometry(val ink: NativeFloatBounds, val stroke: NativeFloatBounds,
    val radiusX: Float, val radiusY: Float)

/** CSS outline-offset clamps the outside size to two stroke widths, independently per axis. */
internal fun nativeOutlineGeometry(anchor: NativeFloatBounds, width: Float, radius: Float,
    offset: Float): NativeOutlineGeometry? {
    require(width.isFinite() && width >= 0f && radius.isFinite() && radius >= 0f && offset.isFinite())
    if (width == 0f) return null
    val halfStroke = width.toDouble() / 2.0
    val outerWidth = maxOf(width.toDouble() * 2.0, anchor.width.toDouble() + 2.0 * (offset.toDouble() + width))
    val outerHeight = maxOf(width.toDouble() * 2.0, anchor.height.toDouble() + 2.0 * (offset.toDouble() + width))
    val x = (anchor.left.toDouble() + anchor.right) / 2.0
    val y = (anchor.top.toDouble() + anchor.bottom) / 2.0
    fun bounds(left: Double, top: Double, right: Double, bottom: Double): NativeFloatBounds {
        if (listOf(left, top, right, bottom).any { !it.isFinite() || kotlin.math.abs(it) > TablePixelLimit })
            throw UnsupportedFloatLayout("Focus outline exceeds the native geometry range")
        return NativeFloatBounds(left.toFloat(), top.toFloat(), right.toFloat(), bottom.toFloat())
    }
    val ink = bounds(x - outerWidth / 2.0, y - outerHeight / 2.0, x + outerWidth / 2.0, y + outerHeight / 2.0)
    val stroke = bounds(ink.left + halfStroke, ink.top + halfStroke, ink.right - halfStroke, ink.bottom - halfStroke)
    val radiusX = (radius + (outerWidth - anchor.width) / 2.0 - halfStroke).coerceIn(0.0, stroke.width / 2.0)
    val radiusY = (radius + (outerHeight - anchor.height) / 2.0 - halfStroke).coerceIn(0.0, stroke.height / 2.0)
    return NativeOutlineGeometry(ink, stroke, radiusX.toFloat(), radiusY.toFloat())
}

internal fun paintNativeFocusOutline(canvas: Canvas, value: NativeNodeFocusPaint.Outline) {
    if (value.color ushr 24 == 0) return
    val geometry = nativeOutlineGeometry(NativeFloatBounds(value.bounds.left, value.bounds.top,
        value.bounds.right, value.bounds.bottom), value.width, value.radius, value.offset) ?: return
    val bounds = geometry.stroke.let { RectF(it.left, it.top, it.right, it.bottom) }
    val paint = android.graphics.Paint(android.graphics.Paint.ANTI_ALIAS_FLAG).apply {
        color = value.color; style = android.graphics.Paint.Style.STROKE; strokeWidth = value.width
    }
    canvas.drawRoundRect(bounds, geometry.radiusX, geometry.radiusY, paint)
}

internal fun paintNativeFocus(canvas: Canvas, value: NativeNodeFocusPaint) {
    if (value !is NativeNodeFocusPaint.Connected) {
        value.outlines().forEach { paintNativeFocusOutline(canvas, it) }
        return
    }
    val first = value.outlines.firstOrNull() ?: return
    if (first.color ushr 24 == 0 || first.width == 0f) return
    require(value.outlines.all { it.width == first.width && it.color == first.color &&
        it.radius == first.radius && it.offset == first.offset })
    val parts = value.outlines.mapNotNull {
        nativeOutlineGeometry(NativeFloatBounds(it.bounds.left, it.bounds.top, it.bounds.right,
            it.bounds.bottom), it.width, it.radius, it.offset)
    }
    val path = android.graphics.Path()
    val rectangles = parts.map { RectF(it.stroke.left, it.stroke.top, it.stroke.right, it.stroke.bottom) }
    rectangles.forEachIndexed { index, rect ->
        val piece = android.graphics.Path().apply { addRect(rect, android.graphics.Path.Direction.CW) }
        if (index == 0) path.set(piece) else {
            // A strongly negative offset can separate the individually clamped parts. Keep this
            // one owner's contour connected with a minimum-width bridge, never a new hit area.
            if (rectangles.take(index).none { RectF.intersects(it, rect) }) {
                val prior = rectangles[index - 1]
                val line = android.graphics.Path().apply {
                    moveTo(prior.centerX(), prior.centerY()); lineTo(rect.centerX(), rect.centerY())
                }
                val bridge = android.graphics.Path()
                android.graphics.Paint().apply {
                    style = android.graphics.Paint.Style.STROKE; strokeWidth = first.width
                }.getFillPath(line, bridge)
                check(path.op(bridge, android.graphics.Path.Op.UNION))
            }
            check(path.op(piece, android.graphics.Path.Op.UNION))
        }
    }
    val paint = android.graphics.Paint(android.graphics.Paint.ANTI_ALIAS_FLAG).apply {
        color = first.color; style = android.graphics.Paint.Style.STROKE; strokeWidth = first.width
        // CSS leaves the connected outline contour to the UA. Round this rectangle union;
        // do not paint internal overlapping edges or expand the action's separate hit union.
        pathEffect = android.graphics.CornerPathEffect(parts.minOf { minOf(it.radiusX, it.radiusY) })
    }
    canvas.drawPath(path, paint)
}
