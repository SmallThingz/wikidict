package app.smallthingz.dict

import android.graphics.Canvas
import android.graphics.Matrix
import android.graphics.Paint
import android.graphics.Path
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

/** One real local scroll owner; positive distance moves content physically left. */
internal interface NativeHorizontalScrollTarget {
    fun scrollBy(physicalDistance: Float): Float
    fun fling(physicalVelocity: Float)
    fun cancel()
}

/** Parameter intervals stay on the original segment through every clip and transform. */
private data class NativeClipInterval(val first: Double, val last: Double) {
    fun intersected(other: NativeClipInterval): NativeClipInterval? =
        nativeClipInterval(maxOf(first, other.first), minOf(last, other.last))
}
private fun nativeClipInterval(first: Double, last: Double): NativeClipInterval? =
    if (first < last) NativeClipInterval(first, last) else null

private data class NativeClipSegment(val x: Double, val y: Double, val dx: Double, val dy: Double) {
    init {
        if (!listOf(x, y, dx, dy).all(Double::isFinite) || dx == 0.0 && dy == 0.0)
            throw UnsupportedFloatLayout("Text clip segment is unavailable")
    }
    fun xAt(t: Double): Double = x + dx * t
    fun yAt(t: Double): Double = y + dy * t
    fun affine(values: FloatArray): NativeClipSegment {
        if (values[6] != 0f || values[7] != 0f || values[8] == 0f || !values.all(Float::isFinite))
            throw UnsupportedFloatLayout("Perspective text clip segments are unavailable")
        val w = values[8].toDouble()
        return NativeClipSegment((values[0] * x + values[1] * y + values[2]) / w,
            (values[3] * x + values[4] * y + values[5]) / w,
            (values[0] * dx + values[1] * dy) / w, (values[3] * dx + values[4] * dy) / w)
    }
}

private fun nativeRectangleClipInterval(rect: RectF, line: NativeClipSegment): NativeClipInterval? {
    if (!listOf(rect.left, rect.top, rect.right, rect.bottom).all(Float::isFinite))
        throw UnsupportedFloatLayout("Text clip rectangle is unavailable")
    if (rect.isEmpty) return null
    var result = NativeClipInterval(0.0, 1.0)
    fun axis(origin: Double, delta: Double, low: Float, high: Float): Boolean {
        // A whole segment on the excluded right/bottom edge has no visible interval.
        if (delta == 0.0) return origin >= low && origin < high
        val first = (low - origin) / delta
        val last = (high - origin) / delta
        result = result.intersected(NativeClipInterval(minOf(first, last), maxOf(first, last))) ?: return false
        return true
    }
    return if (axis(line.x, line.dx, rect.left, rect.right) &&
        axis(line.y, line.dy, rect.top, rect.bottom)) result else null
}

private fun nativeCircleClipInterval(line: NativeClipSegment, cx: Double, cy: Double,
    radius: Double): NativeClipInterval? {
    val ox = line.x - cx
    val oy = line.y - cy
    val scale = maxOf(kotlin.math.abs(ox), kotlin.math.abs(oy), kotlin.math.abs(line.dx),
        kotlin.math.abs(line.dy), radius)
    val x = ox / scale
    val y = oy / scale
    val dx = line.dx / scale
    val dy = line.dy / scale
    val r = radius / scale
    val a = dx * dx + dy * dy
    val b = x * dx + y * dy
    val c = x * x + y * y - r * r
    val discriminant = b * b - a * c
    if (!a.isFinite() || a == 0.0 || !discriminant.isFinite())
        throw UnsupportedFloatLayout("Text clip circle intersection is unavailable")
    if (discriminant < 0.0) return null
    if (discriminant == 0.0) {
        // Tangency can trim one excluded corner endpoint while the straight edge beyond
        // it survives. Only the final rounded-box interval must have positive length.
        val tangent = -b / a
        if (!tangent.isFinite())
            throw UnsupportedFloatLayout("Text clip circle intersection is unavailable")
        return NativeClipInterval(tangent, tangent)
    }
    val root = kotlin.math.sqrt(discriminant)
    val q = -b - if (b >= 0.0) root else -root
    val first = q / a
    val last = c / q
    if (!first.isFinite() || !last.isFinite())
        throw UnsupportedFloatLayout("Text clip circle intersection is unavailable")
    return nativeClipInterval(minOf(first, last), maxOf(first, last))
}

private fun nativeTableClipInterval(shape: NativeTableCornerShape,
    line: NativeClipSegment): NativeClipInterval? {
    val box = shape.paddingBox ?: return null
    var result = nativeRectangleClipInterval(RectF(box.left, box.top, box.right, box.bottom), line) ?: return null
    shape.innerRadii.clockwise.forEachIndexed { index, radius ->
        if (radius > 0.0) {
            val (cx, cy) = shape.center(index)
            fun outside(t: Double): Boolean {
                val x = line.xAt(t)
                val y = line.yAt(t)
                val outwardX = if (index == 0 || index == 3) x < cx else x > cx
                val outwardY = if (index < 2) y < cy else y > cy
                val dx = x - cx
                val dy = y - cy
                return outwardX && outwardY && dx * dx + dy * dy > radius * radius
            }
            // Each retained rounded box is convex. An excluded endpoint enters/leaves at
            // the analytic circle root; endpoints already inside need no corner cut.
            val cutFirst = outside(result.first)
            val cutLast = outside(result.last)
            if (cutFirst || cutLast) {
                val circle = nativeCircleClipInterval(line, cx, cy, radius) ?: return null
                result = nativeClipInterval(if (cutFirst) maxOf(result.first, circle.first) else result.first,
                    if (cutLast) minOf(result.last, circle.last) else result.last) ?: return null
            }
        }
    }
    return result
}

/** Immutable precise clipping accompanies the existing rectangular bounds. Only explicit
 * rounded Table overflow creates one; path bounds are for rectangular platform APIs. */
internal class NativeTextClip private constructor(private val path: Path, private val envelope: RectF,
    private val segmentInterval: (NativeClipSegment) -> NativeClipInterval?,
    private val point: (Float, Float) -> Boolean) {
    fun contains(x: Float, y: Float): Boolean = point(x, y)
    fun clip(canvas: Canvas) { canvas.clipPath(path) }
    /** A segment is not an area. Keep its positive-length survivor, including a zero-width
     * envelope; isolated tangency and segments on excluded right/bottom edges are absent. */
    fun segmentBounds(startX: Float, startY: Float, endX: Float, endY: Float): RectF? {
        if (!listOf(startX, startY, endX, endY).all(Float::isFinite))
            throw UnsupportedFloatLayout("Text clip segment is unavailable")
        if (startX == endX && startY == endY) return null
        val line = NativeClipSegment(startX.toDouble(), startY.toDouble(),
            endX.toDouble() - startX, endY.toDouble() - startY)
        val interval = segmentInterval(line) ?: return null
        val x0 = line.xAt(interval.first).toFloat()
        val y0 = line.yAt(interval.first).toFloat()
        val x1 = line.xAt(interval.last).toFloat()
        val y1 = line.yAt(interval.last).toFloat()
        if (!listOf(x0, y0, x1, y1).all(Float::isFinite) || x0 == x1 && y0 == y1)
            throw UnsupportedFloatLayout("Text clip segment cannot be represented in native coordinates")
        return RectF(minOf(x0, x1), minOf(y0, y1), maxOf(x0, x1), maxOf(y0, y1))
    }
    fun bounds(rectangle: RectF): RectF? {
        if (rectangle.isEmpty) return null
        val result = Path(path)
        if (!result.op(Path().apply { addRect(rectangle, Path.Direction.CW) }, Path.Op.INTERSECT))
            throw UnsupportedFloatLayout("Rounded text clip intersection is unavailable")
        if (result.isEmpty) return null
        // Public Path bounds enclose control points, not analytic arc extrema. Platform AX
        // receives a conservative visible envelope, bounded by every rectangular limit.
        return RectF().also { result.computeBounds(it, true) }.takeIf {
            it.intersect(rectangle) && it.intersect(envelope) && !it.isEmpty
        }
    }
    fun intersected(other: NativeTextClip): NativeTextClip {
        val result = Path(path)
        if (!result.op(other.path, Path.Op.INTERSECT))
            throw UnsupportedFloatLayout("Rounded text clip intersection is unavailable")
        val bounds = RectF(envelope).apply { if (!intersect(other.envelope)) setEmpty() }
        return NativeTextClip(result, bounds, { line ->
            segmentInterval(line)?.let { first -> other.segmentInterval(line)?.let(first::intersected) }
        }) { x, y -> contains(x, y) && other.contains(x, y) }
    }
    fun intersected(rectangle: RectF): NativeTextClip = intersected(NativeTextClip.rectangle(rectangle))
    fun translated(x: Float, y: Float): NativeTextClip = NativeTextClip(Path(path).apply { offset(x, y) },
        RectF(envelope).apply { offset(x, y) }, { line ->
            segmentInterval(line.copy(x = line.x - x, y = line.y - y))
        }) { px, py -> contains(px - x, py - y) }
    fun transformed(matrix: Matrix): NativeTextClip {
        val inverse = Matrix()
        if (!matrix.invert(inverse)) return rectangle(RectF())
        val values = FloatArray(9).also(inverse::getValues)
        return NativeTextClip(Path(path).apply { transform(matrix) }, RectF(envelope).apply { matrix.mapRect(this) },
            { line -> segmentInterval(line.affine(values)) }) { x, y ->
            val point = floatArrayOf(x, y); inverse.mapPoints(point)
            point.all(Float::isFinite) && contains(point[0], point[1])
        }
    }
    companion object {
        fun rectangle(value: RectF): NativeTextClip {
            val copy = RectF(value)
            return NativeTextClip(Path().apply { if (!copy.isEmpty) addRect(copy, Path.Direction.CW) }, copy,
                { line -> nativeRectangleClipInterval(copy, line) }) { x, y -> copy.contains(x, y) }
        }
        internal fun table(shape: NativeTableCornerShape, content: RectF): NativeTextClip =
            NativeTextClip(nativeTableCornerPath(shape, padding = true), shape.paddingBox?.let {
                RectF(it.left, it.top, it.right, it.bottom)
            } ?: RectF(), { line -> nativeTableClipInterval(shape, line) }) { x, y ->
                shape.contains(x, y, padding = true)
            }.intersected(content)
    }
}
internal fun nativeTableContentClip(shape: NativeTableCornerShape, contentRect: RectF): NativeTextClip =
    NativeTextClip.table(shape, contentRect)

/** All offsets are UTF-16 indices in [text]; layout must never insert line breaks. */
/** The real clipped owner's border box is semantic metadata only. Its own empty
 * paint/hit clip is deliberately absent here; these clips belong to outer owners. */
internal class NativeClippedAbsoluteSemanticLocation(
    bounds: RectF,
    clipBounds: RectF? = null,
    val preciseClip: NativeTextClip? = null,
    val coordinateScope: NativeClippedAbsoluteCoordinateScope? = null,
    val viewportSteps: List<NativeClippedAbsoluteViewportStep> = emptyList(),
) {
    private val location = RectF(bounds)
    private val outerClip = clipBounds?.let(::RectF)
    val bounds: RectF get() = RectF(location)
    val clipBounds: RectF? get() = outerClip?.let(::RectF)
    init {
        require(listOf(location.left, location.top, location.right, location.bottom).all(Float::isFinite) &&
            location.left <= location.right && location.top <= location.bottom)
        require(outerClip == null || listOf(outerClip.left, outerClip.top, outerClip.right, outerClip.bottom).all(Float::isFinite))
    }
    fun translated(x: Float, y: Float) = NativeClippedAbsoluteSemanticLocation(
        RectF(location).apply { offset(x, y) }, outerClip?.let { RectF(it).apply { offset(x, y) } },
        preciseClip?.translated(x, y), coordinateScope, viewportSteps)
    fun throughViewport(x: Float, y: Float, panX: Float, panY: Float, clipOwner: NativeScrollClip?,
        rect: RectF, precise: NativeTextClip?): NativeClippedAbsoluteSemanticLocation {
        if (coordinateScope == null) return translated(x, y).withOuterClip(rect, precise)
        val boundary = clipOwner ?: throw UnsupportedFloatLayout("Clipped absolute viewport provenance is unavailable")
        return NativeClippedAbsoluteSemanticLocation(RectF(location).apply { offset(x, y) },
            outerClip?.let { RectF(it).apply { offset(x, y) } }, preciseClip?.translated(x, y),
            coordinateScope, viewportSteps + NativeClippedAbsoluteViewportStep(boundary, panX, panY))
    }
    fun withOuterClip(rect: RectF, precise: NativeTextClip? = null): NativeClippedAbsoluteSemanticLocation {
        val clipped = outerClip?.let { RectF(it).apply { if (!intersect(rect)) setEmpty() } } ?: RectF(rect)
        val shape = preciseClip?.intersected(rect)?.let { if (precise == null) it else it.intersected(precise) } ?: precise
        return NativeClippedAbsoluteSemanticLocation(location, clipped, shape, coordinateScope, viewportSteps)
    }
}

internal interface FloatTextGeometry {
    val text: CharSequence
    val width: Int
    val height: Int
    val nodes: List<FloatInteractionNode>
    val citationMarkerRanges: List<NativeCitationMarkerRange> get() = nodes.mapNotNull { node ->
        node.citationMarker?.let { NativeCitationMarkerRange(it, node.start, node.end, node.id) }
    }
    fun citationMarkerRange(anchor: String): NativeCitationMarkerRange? =
        citationMarkerRanges.singleOrNull { it.marker.anchor == anchor }
    /** Completion follows the owner's actual scroll and fresh geometry publication. */
    fun revealOffset(offset: Int, onRevealed: () -> Unit) { onRevealed() }
    fun revealOffset(caret: NativeTextCaret, onRevealed: () -> Unit) = revealOffset(caret.offset, onRevealed)
    fun revealNode(id: Int, onRevealed: () -> Unit) {
        nodes.firstOrNull { it.id == id }?.onReveal?.invoke(onRevealed) ?: onRevealed()
    }
    /** Null is unbounded; an empty rectangle is completely clipped. Caret positions stay logical. */
    fun clipForOffset(offset: Int): RectF? = null
    fun preciseClipForOffset(offset: Int): NativeTextClip? = null
    fun clipForOffset(caret: NativeTextCaret): RectF? = clipForOffset(caret.ownerOffset)
    fun preciseClipForOffset(caret: NativeTextCaret): NativeTextClip? = preciseClipForOffset(caret.ownerOffset)
    val hasPreciseClips: Boolean get() = false
    fun paintSelection(canvas: Canvas, start: Int, end: Int, paint: Paint) {
        rectsForRange(start, end).forEach { canvas.drawRect(it, paint) }
    }
    fun horizontalScrollTargetAt(x: Float, y: Float): NativeHorizontalScrollTarget? = null
    /** The concrete text owner resolves source pointer policy through its actual hit layout. */
    fun cursorAt(x: Float, y: Float): InlineCursor? = null
    /** Actual line baselines; absent for a true empty box, even if it has borders or padding. */
    val textBaselines: NativeTextBaselines? get() = null
    /** Deferred paint groups retain this owner's text and node indices; no second child graph. */
    val positionedGroups: List<NativePositionedGroup> get() = emptyList()
    val clippedAbsoluteSemanticLocations: List<NativeClippedAbsoluteSemanticLocation> get() = emptyList()
    /** Only one wholly owned, nonempty source interval can authenticate this location. */
    fun clippedAbsoluteSemanticLocation(start: Int, end: Int): NativeClippedAbsoluteSemanticLocation? = null
    /** Fixed boxes default to their allocation; text/composite owners publish their signed overflow. */
    val extents: NativeGeometryExtents get() = NativeGeometryExtents(width, height.toFloat(),
        NativeFloatBounds(0f, 0f, width.toFloat(), height.toFloat()),
        nativeBoundsOf(rectsForRange(0, text.length) + nodes.flatMap { it.bounds }))
    /** Conservative ordinary-paint coverage, excluding separately scheduled media and
     * View selection/focus where the concrete painter can distinguish those phases. */
    val ordinaryPaintBounds: List<NativeFloatBounds> get() = listOfNotNull(extents.ink)
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
    /** Exact natural box of one original inline-padding owner; null grants no group authority. */
    fun inlinePaddingGroupRects(owner: Span, start: Int, end: Int): List<RectF>? = null
    /** A known original action owner may project a subset across several native fragments. */
    fun inlineActionGroupRects(owner: NativeInlineActionOwner, start: Int, end: Int): List<RectF>? = null
    /** In-flow fragments only; positioned border overlays never become action/selection geometry. */
    fun inlineBoxGroupRects(owner: NativeInlineBoxOwner, start: Int, end: Int): List<RectF>? = null
    fun inlineBoxGroupHitTest(owner: NativeInlineBoxOwner, start: Int, end: Int): ((Float, Float) -> Boolean)? = null
    fun inlineBoxChildActionRects(owner: NativeInlineBoxOwner, start: Int, end: Int,
        childStart: Int, childEnd: Int, fragments: List<RectF>): List<RectF>? = null
    /** Exactly [length] entries, including null for a character without visible bounds. */
    fun characterRects(start: Int, length: Int): List<RectF?>
    fun caretRect(offset: Int): RectF
    fun caretRect(caret: NativeTextCaret): RectF = caretRect(caret.offset)
    fun caretAt(x: Float, y: Float): NativeTextCaret = NativeTextCaret(offsetForPosition(x, y))
    fun visualCaret(caret: NativeTextCaret, direction: Int): NativeTextCaret =
        NativeTextCaret(visualOffset(caret.offset, direction))
    /** Logical bounds of the visual line containing offset; the end is exclusive. */
    fun lineRange(offset: Int): Pair<Int, Int>
    /** A source LF can be a retained Ruby gap rather than a native paragraph break. */
    fun isHardLineBreak(offset: Int): Boolean = text[offset] == '\n'
    /** Original UTF-16 fragments on the queried visual row, in logical order. Fragments
     * never include characters from another row; generated layout tokens have no range.
     * Legacy owners retain their single contiguous line, including its terminal LF. */
    fun visualLineRanges(offset: Int): List<Pair<Int, Int>> = listOf(lineRange(offset))
    /** The preceding source unit owns an upstream boundary, including a detached end. */
    fun visualLineRanges(caret: NativeTextCaret): List<Pair<Int, Int>> {
        require(caret.offset in 0..text.length)
        return visualLineRanges(if (caret.affinity == NativeTextAffinity.Upstream && caret.offset > 0)
            caret.offset - 1 else caret.offset)
    }
    /** direction -1 means visual left; +1 means visual right. */
    fun visualOffset(offset: Int, direction: Int): Int
}

/** Movement reports one real contiguous fragment, never the envelope of disjoint rows.
 * Shared boundaries belong to the following fragment; the final end belongs to the last. */
internal fun FloatTextGeometry.visualLineFragment(offset: Int): Pair<Int, Int>? {
    require(offset in 0..text.length)
    val ranges = visualLineRanges(offset)
    return ranges.firstOrNull { offset >= it.first && offset < it.second }
        ?: ranges.lastOrNull { offset == it.second }
}

internal fun FloatTextGeometry.visualLineEnd(offset: Int): Int {
    require(offset in 0..text.length)
    val end = visualLineRanges(offset).lastOrNull()?.second ?: offset
    return if (end > 0 && isHardLineBreak(end - 1)) end - 1 else end
}

internal fun FloatTextGeometry.visualLineEnd(caret: NativeTextCaret): Int {
    val end = visualLineRanges(caret).lastOrNull()?.second ?: caret.offset
    return if (end > 0 && isHardLineBreak(end - 1)) end - 1 else end
}

/** Accessibility paragraph movement uses authored hard breaks, not retained Ruby gap LFs. */
internal fun FloatTextGeometry.paragraphBoundary(offset: Int, forward: Boolean): Int {
    require(offset in 0..text.length)
    if (forward) {
        for (index in offset until text.length) if (isHardLineBreak(index)) return index + 1
        return text.length
    }
    for (index in offset - 2 downTo 0) if (isHardLineBreak(index)) return index + 1
    return 0
}

internal fun nativeBoundsOf(rectangles: List<RectF>): NativeFloatBounds? = rectangles
    .filter { !it.isEmpty }.map { NativeFloatBounds(it.left, it.top, it.right, it.bottom) }
    .reduceOrNull { a, b -> a.enclosing(b) }

internal enum class FloatInteractionKind { LINK, IMAGE, HEADING, CONTROL, MARKER, SEPARATOR, ADVISORY }

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
    val onReveal: ((() -> Unit) -> Unit)? = null,
    val clipBounds: RectF? = null,
    val customActions: List<NativeHeadingAction> = emptyList(),
    val preciseClip: NativeTextClip? = null,
    /** Image source policy uses input-focus modality without text-link key/state handling. */
    val sourceFocusVisible: Boolean = false,
    val citationMarker: CitationMarker? = null,
    val clippedAbsoluteLocation: NativeClippedAbsoluteSemanticLocation? = null,
    val advisoryIdentity: NativeTextAdvisoryIdentity? = null,
    val tooltipForPosition: ((Float, Float) -> CharSequence?)? = null,
) {
    fun contains(x: Float, y: Float): Boolean = (clipBounds?.contains(x, y) ?: true) &&
        (preciseClip?.contains(x, y) ?: true) &&
        bounds.any { it.contains(x, y) } && (hitTest?.invoke(x, y) ?: true)
    fun translated(x: Float, y: Float): FloatInteractionNode = copy(
        bounds = bounds.map { RectF(it).apply { offset(x, y) } },
        hitTest = hitTest?.let { test -> { px, py -> test(px - x, py - y) } },
        tooltipForPosition = tooltipForPosition?.let { query -> { px, py -> query(px - x, py - y) } },
        focusPaint = focusPaint?.translated(x, y),
        clipBounds = clipBounds?.let { RectF(it).apply { offset(x, y) } },
        preciseClip = preciseClip?.translated(x, y),
        clippedAbsoluteLocation = clippedAbsoluteLocation?.translated(x, y),
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

internal fun nativeFocusInk(nodes: List<FloatInteractionNode>): NativeFloatBounds? = nodes.mapNotNull { node ->
    val ink = node.focusPaint?.outlines().orEmpty().mapNotNull { outline ->
        if (outline.color ushr 24 == 0) null else nativeOutlineGeometry(NativeFloatBounds(outline.bounds.left,
            outline.bounds.top, outline.bounds.right, outline.bounds.bottom), outline.width, outline.radius, outline.offset)?.ink
    }.reduceOrNull { a, b -> a.enclosing(b) }
    // Enclose this owner's connected outline before clipping, so a bridge crossing the
    // viewport remains covered even when its endpoint outlines lie outside the clip.
    if (ink == null || node.clipBounds == null && node.preciseClip == null) ink else {
        var clipped = RectF(ink.left, ink.top, ink.right, ink.bottom)
        node.clipBounds?.let { if (!clipped.intersect(it)) clipped.setEmpty() }
        node.preciseClip?.let { clipped = it.bounds(clipped) ?: RectF() }
        if (clipped.isEmpty) null else NativeFloatBounds(clipped.left, clipped.top, clipped.right, clipped.bottom)
    }
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
    bodyPixels: Float, connected: Boolean = false): NativeNodeFocusPaint =
    nativeLinkFocusPaint(policy.focusOutline, fragments, density, bodyPixels, connected)

internal fun ordinaryLinkFocusPaint(policy: LinkPaint, fragments: List<RectF>, density: Float,
    bodyPixels: Float): NativeNodeFocusPaint =
    nativeLinkFocusPaint(policy.focusOutline, fragments, density, bodyPixels, false)

private fun nativeLinkFocusPaint(outline: FigureFocusOutline?, fragments: List<RectF>, density: Float,
    bodyPixels: Float, connected: Boolean): NativeNodeFocusPaint {
    if (outline == null) return NativeNodeFocusPaint.None
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
    val sourceOffset: Int, val paint: (Canvas) -> Unit, val preciseClip: NativeTextClip? = null) {
    fun contains(x: Float, y: Float): Boolean = (preciseClip?.contains(x, y) ?: true) && bounds.any { it.contains(x, y) }
    fun translated(x: Float, y: Float, textOffset: Int = 0, nodeId: (Int) -> Int = { it }): NativePositionedGroup =
        copy(bounds = bounds.map { RectF(it).apply { offset(x, y) } }, nodeIds = nodeIds.map(nodeId).toSet(),
            sourceOffset = sourceOffset + textOffset, preciseClip = preciseClip?.translated(x, y), paint = { canvas ->
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
