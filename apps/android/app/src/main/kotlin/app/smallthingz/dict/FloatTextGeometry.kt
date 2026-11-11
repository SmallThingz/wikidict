package app.smallthingz.dict

import android.graphics.Canvas
import android.graphics.RectF

/** All offsets are UTF-16 indices in [text]; layout must never insert line breaks. */
internal interface FloatTextGeometry {
    val text: CharSequence
    val width: Int
    val height: Int
    val nodes: List<FloatInteractionNode>
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
) {
    fun contains(x: Float, y: Float): Boolean = bounds.any { it.contains(x, y) } && (hitTest?.invoke(x, y) ?: true)
    fun translated(x: Float, y: Float): FloatInteractionNode = copy(
        bounds = bounds.map { RectF(it).apply { offset(x, y) } },
        hitTest = hitTest?.let { test -> { px, py -> test(px - x, py - y) } },
    )
}
