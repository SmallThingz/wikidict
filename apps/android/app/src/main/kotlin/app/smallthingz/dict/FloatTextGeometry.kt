package app.smallthingz.dict

import android.graphics.Canvas
import android.graphics.RectF

/** All offsets are UTF-16 indices in [text]; layout must never insert line breaks. */
internal interface FloatTextGeometry {
    val text: CharSequence
    val width: Int
    val height: Int
    val nodes: List<FloatInteractionNode>
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
) {
    fun contains(x: Float, y: Float): Boolean = bounds.any { it.contains(x, y) } && (hitTest?.invoke(x, y) ?: true)
    fun translated(x: Float, y: Float): FloatInteractionNode = copy(
        bounds = bounds.map { RectF(it).apply { offset(x, y) } },
        hitTest = hitTest?.let { test -> { px, py -> test(px - x, py - y) } },
    )
}
