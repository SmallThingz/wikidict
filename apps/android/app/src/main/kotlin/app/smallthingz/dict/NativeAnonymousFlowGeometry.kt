package app.smallthingz.dict

import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.RectF
import android.text.Layout
import android.text.SpannableString
import android.text.Spanned
import android.text.TextDirectionHeuristics
import android.text.TextPaint
import android.text.style.LineHeightSpan
import android.text.style.AlignmentSpan
import android.text.style.ReplacementSpan
import kotlin.math.ceil

/** Exact new block-media flow dimensions; integer child dimensions only allocate the native surface. */
internal data class NativeFigureUsedBox(val width: Float, val height: Float,
    val margins: SignedNativeContainerMargins) {
    init {
        figureCoordinate(width); figureCoordinate(height)
        if (margins.top != 0f || margins.bottom != 0f)
            throw UnsupportedFloatLayout("Figure block vertical margins need a joined margin owner")
    }
}

/** The figure adapter owns image/caption layout and media state; this owner never remeasures a bitmap. */
internal data class MeasuredAnonymousFigure(
    val geometry: FloatTextGeometry,
    val margins: FloatMargins,
    val frameMinimumWidens: Boolean = false,
    val normalContentLeft: Float? = null,
    val usedBox: NativeFigureUsedBox? = null,
) {
    init {
        require(geometry.width >= 0 && geometry.height >= 0)
        require(normalContentLeft == null || normalContentLeft.isFinite())
        require(geometry.width.toDouble() + margins.left + margins.right <= Int.MAX_VALUE / 4)
        require(geometry.height.toDouble() + margins.top + margins.bottom <= Int.MAX_VALUE / 4)
        usedBox?.let {
            if (figureCoordinate(it.width) != geometry.width || figureCoordinate(it.height) != geometry.height)
                throw UnsupportedFloatLayout("Figure block used box differs from its native allocation")
            figureCoordinate(it.width.toDouble() + it.margins.left + it.margins.right)
            figureCoordinate(it.height.toDouble() + it.margins.top + it.margins.bottom)
        }
    }
    val marginTop: Float get() = usedBox?.margins?.top ?: margins.top
    val outerWidth: Float get() = usedBox?.let { it.width + it.margins.left + it.margins.right }
        ?: (geometry.width + margins.left + margins.right)
    val outerHeight: Float get() = usedBox?.let { it.height + it.margins.top + it.margins.bottom }
        ?: (geometry.height + margins.top + margins.bottom)
}

internal data class PlacedAnonymousFigure(
    val anchor: AnonymousFigureAnchor, val measured: MeasuredAnonymousFigure, val bounds: RectF,
    val paintsOutsideLineClip: Boolean = false,
)

/** Original native interval before image alt text changes the public source length. */
internal data class NativeAnonymousInlineNode(val node: FloatInteractionNode,
    val nativeStart: Int, val nativeEnd: Int)

/**
 * A single native paragraph owns text, scopes and measured figure objects. NativeFloatGeometry
 * resolves each line again after float exclusions change; no pre-reordered strings or text shards
 * are passed to the native layout. Captions retain their own layout, offset space and language.
 */
internal class NativeAnonymousFlowGeometry private constructor(
    val offsets: AnonymousFlowOffsets,
    private val native: NativeFloatGeometry,
    val figures: List<PlacedAnonymousFigure>,
    inlineNodes: (NativeAnonymousFlowGeometry) -> List<FloatInteractionNode>,
    inlineNodeSources: ((NativeAnonymousFlowGeometry) -> List<NativeAnonymousInlineNode>)?,
) : FloatTextGeometry {
    private val figureById = figures.associateBy { it.anchor.event.id }
    val selection = AnonymousFlowSelection.build(offsets) { figureById.getValue(it.event.id).measured.geometry.text }
    private val figureSegments = selection.segments.filterIsInstance<AnonymousSelectionSegment.Figure>().associateBy { it.anchor.event.id }
    override val text: CharSequence get() = selection.text
    override val width: Int get() = native.width
    override val height: Int get() = native.height
    override val textBaselines: NativeTextBaselines? get() = native.textBaselines
    override val clippedAbsoluteSemanticLocations get() = native.clippedAbsoluteSemanticLocations + figures.flatMap { placed ->
        placed.measured.geometry.clippedAbsoluteSemanticLocations.map { it.translated(placed.bounds.left, placed.bounds.top) }
    }
    val textBottom: Float get() = native.textBottom
    val scrollableBounds: NativeFloatBounds by lazy {
        figures.fold(native.scrollableBounds) { bounds, figure ->
            val used = figure.measured.usedBox
            val frame = bounds.enclosing(NativeFloatBounds(figure.bounds.left, figure.bounds.top,
                if (used == null) figure.bounds.right else figure.bounds.left + used.width,
                if (used == null) figure.bounds.bottom else figure.bounds.top + used.height))
            if (figure.measured.usedBox == null) frame else {
                val extent = figure.measured.geometry.extents
                listOfNotNull(extent.ink, extent.interaction).fold(frame) { area, ink ->
                    area.enclosing(ink.translated(figure.bounds.left, figure.bounds.top))
                }
            }
        }.let { bounds -> positionedGroups.flatMap { it.bounds }.fold(bounds) { area, box ->
            area.enclosing(NativeFloatBounds(box.left, box.top, box.right, box.bottom))
        } }
    }
    val ownExclusions: List<NativeFloatExclusion> get() = native.floats.map {
        NativeFloatExclusion(it.occurrence.side, NativeFloatBounds(it.outer.left, it.outer.top, it.outer.right, it.outer.bottom))
    }
    internal fun firstLineBand(): RectF = native.firstLineBand()
    private data class OwnedNode(val value: FloatInteractionNode, val figure: Int? = null,
        val localId: Int = value.id, val nativeStart: Int? = null, val nativeEnd: Int? = null)
    private val ownedNodes = buildList {
        val sourced = inlineNodeSources?.invoke(this@NativeAnonymousFlowGeometry)
        if (sourced == null) addAll(inlineNodes(this@NativeAnonymousFlowGeometry).map { OwnedNode(it) })
        else addAll(sourced.map { owner ->
            require(owner.nativeStart in 0..native.text.length && owner.nativeEnd in owner.nativeStart..native.text.length)
            OwnedNode(owner.node, nativeStart = owner.nativeStart, nativeEnd = owner.nativeEnd)
        })
        figures.forEach { placed ->
            val start = figureSegments.getValue(placed.anchor.event.id).start
            placed.measured.geometry.nodes.forEach { node -> add(OwnedNode(node.translated(placed.bounds.left, placed.bounds.top).copy(
                start = start + node.start, end = start + node.end,
                label = node.label ?: placed.measured.geometry.text.subSequence(node.start, node.end),
            ), placed.anchor.event.id, node.id)) }
        }
    }.sortedBy { it.value.start }
    override val nodes = ownedNodes.mapIndexed { index, node -> node.value.copy(id = index) }
    private val figureNodeIds = ownedNodes.withIndex().filter { it.value.figure != null }
        .associate { (it.value.figure to it.value.localId) to it.index }
    private data class OwnedPositionedGroup(val group: NativePositionedGroup,
        val nativeOffset: Int, val childOffset: Int = 0, val figure: Int? = null)
    init {
        if (native.positionedGroups.isNotEmpty() && ownedNodes.any {
                it.figure == null && it.nativeStart == null && it.value.kind != FloatInteractionKind.MARKER
            }) throw UnsupportedFloatLayout("Positioned anonymous inline actions need original native ranges")
    }
    private val ownedPositionedGroups: List<OwnedPositionedGroup> by lazy {
        val inline = native.positionedGroups.map { group ->
            val ids = ownedNodes.withIndex().filter { (_, owner) ->
                owner.figure == null && owner.nativeStart != null && owner.nativeEnd != null &&
                    owner.nativeStart <= group.sourceOffset && owner.nativeEnd > group.sourceOffset
            }.map { it.index }.toSet()
            OwnedPositionedGroup(group.copy(nodeIds = ids,
                sourceOffset = selection.semanticOffset(group.sourceOffset)), group.sourceOffset)
        }
        val children = figures.flatMap { placed ->
            val start = figureSegments.getValue(placed.anchor.event.id).start
            placed.measured.geometry.positionedGroups.map { group ->
                OwnedPositionedGroup(group.translated(placed.bounds.left, placed.bounds.top, start) { id ->
                    figureNodeIds.getValue(placed.anchor.event.id to id)
                }, placed.anchor.nativeOffset, group.sourceOffset, placed.anchor.event.id)
            }
        }
        // Expanded or empty alt/caption strings can share public offsets. The original
        // event position, followed by its child's source order, owns deferred paint order.
        (inline + children).sortedWith(compareBy({ it.nativeOffset }, { it.childOffset }))
    }
    override val positionedGroups: List<NativePositionedGroup> by lazy { ownedPositionedGroups.map { it.group } }

    override val ordinaryPaintBounds: List<NativeFloatBounds> by lazy {
        native.ordinaryPaintBounds + figures.flatMap { placed ->
            placed.measured.geometry.ordinaryPaintBounds.map { it.translated(placed.bounds.left, placed.bounds.top) }
        }
    }
    override val extents: NativeGeometryExtents by lazy {
        figures.fold(native.extents.copy(usedWidth = width, usedHeight = height.toFloat(),
            interaction = enclosingBounds(native.extents.interaction, nativeBoundsOf(nodes.flatMap { it.bounds })))) { area, placed ->
            area.including(placed.measured.geometry.extents, placed.bounds.left, placed.bounds.top)
        }
    }

    override fun containsInteraction(x: Float, y: Float): Boolean = native.containsInteraction(x, y) ||
        figures.any { it.measured.geometry.containsInteraction(x - it.bounds.left, y - it.bounds.top) }

    override fun paint(canvas: Canvas) {
        paintOrdinary(canvas)
        positionedGroups.forEach { it.paint(canvas) }
    }
    override fun paintOrdinary(canvas: Canvas) {
        native.paintOrdinary(canvas)
        // Native text paints through per-line clips. A minimum-driven overflowing block
        // paints once at its measured bounds after those clips, like an anchored float.
        figures.filter { it.paintsOutsideLineClip }.forEach { drawFigure(canvas, it.measured, it.bounds) }
    }
    internal fun nativeRectsForRange(start: Int, end: Int): List<RectF> = native.rectsForRange(start, end)
    internal fun nativeClippedAbsoluteSemanticLocation(start: Int, end: Int): NativeClippedAbsoluteSemanticLocation? =
        native.clippedAbsoluteSemanticLocation(start, end)
    internal fun nativeInlinePaddingGroupRects(owner: Span, start: Int, end: Int): List<RectF>? =
        native.inlinePaddingGroupRects(owner, start, end)
    internal fun nativeInlineActionGroupRects(owner: NativeInlineActionOwner, start: Int, end: Int): List<RectF>? =
        native.inlineActionGroupRects(owner, start, end)
    internal fun nativeInlineBoxGroupRects(owner: NativeInlineBoxOwner, start: Int, end: Int): List<RectF>? =
        native.inlineBoxGroupRects(owner, start, end)
    internal fun nativeInlineBoxGroupHitTest(owner: NativeInlineBoxOwner, start: Int, end: Int): ((Float, Float) -> Boolean)? =
        native.inlineBoxGroupHitTest(owner, start, end)
    internal fun nativeInlineBoxChildActionRects(owner: NativeInlineBoxOwner, start: Int, end: Int,
        childStart: Int, childEnd: Int, fragments: List<RectF>): List<RectF>? =
        native.inlineBoxChildActionRects(owner, start, end, childStart, childEnd, fragments)
    override fun interactionNodeAt(x: Float, y: Float): FloatInteractionNode? {
        positionedGroups.lastOrNull { it.contains(x, y) }?.let { group ->
            return nodes.lastOrNull { it.id in group.nodeIds && it.contains(x, y) }
        }
        return nodes.lastOrNull { it.contains(x, y) }
    }
    override fun offsetForPosition(x: Float, y: Float): Int {
        positionedGroups.lastOrNull { it.contains(x, y) }?.let { return it.sourceOffset }
        figures.lastOrNull { it.measured.geometry.containsInteraction(x - it.bounds.left, y - it.bounds.top) }
            ?.let { placed ->
            return figureSegments.getValue(placed.anchor.event.id).start + placed.measured.geometry
                .offsetForPosition(x - placed.bounds.left, y - placed.bounds.top)
        }
        return selection.semanticOffset(native.offsetForPosition(x, y))
    }

    override fun revealOffset(caret: NativeTextCaret, onRevealed: () -> Unit) {
        require(caret.offset in 0..text.length)
        val segment = caretSegment(caret)
        if (segment is AnonymousSelectionSegment.Figure)
            figureById.getValue(segment.anchor.event.id).measured.geometry.revealOffset(caret.translated(-segment.start), onRevealed)
        else native.revealOffset(nativeCaret(caret, segment), onRevealed)
    }
    override fun revealOffset(offset: Int, onRevealed: () -> Unit) {
        require(offset in 0..text.length)
        val segment = selection.at(offset)
        if (segment is AnonymousSelectionSegment.Figure)
            figureById.getValue(segment.anchor.event.id).measured.geometry.revealOffset(offset - segment.start, onRevealed)
        else native.revealOffset(selection.nativeOffset(offset), onRevealed)
    }
    override fun clipForOffset(offset: Int): RectF? {
        require(offset in 0..text.length)
        val segment = selection.at(offset)
        if (segment is AnonymousSelectionSegment.Figure) {
            val placed = figureById.getValue(segment.anchor.event.id)
            return placed.measured.geometry.clipForOffset(offset - segment.start)
                ?.let { RectF(it).apply { offset(placed.bounds.left, placed.bounds.top) } }
        }
        return native.clipForOffset(selection.nativeOffset(offset))
    }
    override val hasPreciseClips: Boolean get() = native.hasPreciseClips || figures.any { it.measured.geometry.hasPreciseClips }
    override fun preciseClipForOffset(offset: Int): NativeTextClip? {
        require(offset in 0..text.length)
        val segment = selection.at(offset)
        if (segment is AnonymousSelectionSegment.Figure) {
            val placed = figureById.getValue(segment.anchor.event.id)
            return placed.measured.geometry.preciseClipForOffset(offset - segment.start)?.translated(placed.bounds.left, placed.bounds.top)
        }
        return native.preciseClipForOffset(selection.nativeOffset(offset))
    }
    override fun paintSelection(canvas: Canvas, start: Int, end: Int, paint: Paint) {
        require(start in 0..text.length && end in start..text.length)
        selection.segments.forEach { segment ->
            val first = maxOf(start, segment.start); val last = minOf(end, segment.end)
            if (first < last) when (segment) {
                is AnonymousSelectionSegment.Inline -> native.paintSelection(canvas,
                    if (segment.authored.replacement) segment.nativeStart else segment.nativeStart + first - segment.start,
                    if (segment.authored.replacement) segment.nativeEnd else segment.nativeStart + last - segment.start, paint)
                is AnonymousSelectionSegment.Figure -> {
                    val placed = figureById.getValue(segment.anchor.event.id)
                    val saved = canvas.save()
                    try { canvas.translate(placed.bounds.left, placed.bounds.top)
                        placed.measured.geometry.paintSelection(canvas, first - segment.start, last - segment.start, paint) }
                    finally { canvas.restoreToCount(saved) }
                }
            }
        }
    }
    override fun cursorAt(x: Float, y: Float): InlineCursor? {
        ownedPositionedGroups.lastOrNull { it.group.contains(x, y) }?.let { owner ->
            val placed = owner.figure?.let(figureById::getValue)
            return if (placed == null) native.cursorAt(x, y)
                else placed.measured.geometry.cursorAt(x - placed.bounds.left, y - placed.bounds.top)
        }
        val figure = figures.asReversed().firstOrNull {
            it.measured.geometry.containsInteraction(x - it.bounds.left, y - it.bounds.top) ||
                it.measured.geometry.containsInput(x - it.bounds.left, y - it.bounds.top)
        }
        // A hit figure owns even a null cursor; a lower text run cannot shine through it.
        return if (figure != null) figure.measured.geometry.cursorAt(x - figure.bounds.left, y - figure.bounds.top)
            else native.cursorAt(x, y)
    }

    override fun horizontalScrollTargetAt(x: Float, y: Float): NativeHorizontalScrollTarget? {
        ownedPositionedGroups.lastOrNull { it.group.contains(x, y) }?.let { owner ->
            val placed = owner.figure?.let(figureById::getValue)
            return if (placed == null) native.horizontalScrollTargetAt(x, y)
                else placed.measured.geometry.horizontalScrollTargetAt(x - placed.bounds.left, y - placed.bounds.top)
        }
        val figure = figures.asReversed().firstOrNull {
            it.measured.geometry.containsInteraction(x - it.bounds.left, y - it.bounds.top)
        } ?: figures.asReversed().firstOrNull {
            it.measured.geometry.containsInput(x - it.bounds.left, y - it.bounds.top)
        } ?: return native.horizontalScrollTargetAt(x, y)
        return figure.measured.geometry.horizontalScrollTargetAt(x - figure.bounds.left, y - figure.bounds.top)
    }

    private fun caretSegment(caret: NativeTextCaret): AnonymousSelectionSegment? =
        if (caret.affinity == NativeTextAffinity.Upstream && caret.offset > 0)
            selection.segments.lastOrNull { it.end > it.start && it.end == caret.offset } ?: selection.at(caret.offset)
        else selection.at(caret.offset)
    private fun nativeCaret(caret: NativeTextCaret, segment: AnonymousSelectionSegment?): NativeTextCaret =
        caret.copy(offset = if (segment is AnonymousSelectionSegment.Inline)
            segment.authored.nativeOffset(segment.authored.logicalStart + caret.offset - segment.start)
        else selection.nativeOffset(caret.offset))
    override fun caretRect(caret: NativeTextCaret): RectF {
        val segment = caretSegment(caret)
        if (segment is AnonymousSelectionSegment.Figure) {
            val placed = figureById.getValue(segment.anchor.event.id)
            return placed.measured.geometry.caretRect(caret.translated(-segment.start))
                .apply { offset(placed.bounds.left, placed.bounds.top) }
        }
        if (text.isEmpty()) return caretRect(caret.offset)
        return native.caretRect(nativeCaret(caret, segment))
    }
    override fun caretAt(x: Float, y: Float): NativeTextCaret {
        positionedGroups.lastOrNull { it.contains(x, y) }?.let { return NativeTextCaret(it.sourceOffset) }
        figures.lastOrNull { it.measured.geometry.containsInteraction(x - it.bounds.left, y - it.bounds.top) }
            ?.let { placed ->
                val segment = figureSegments.getValue(placed.anchor.event.id)
                return placed.measured.geometry.caretAt(x - placed.bounds.left, y - placed.bounds.top).translated(segment.start)
            }
        return native.caretAt(x, y).let { it.copy(offset = selection.semanticOffset(it.offset)) }
    }
    override fun visualCaret(caret: NativeTextCaret, direction: Int): NativeTextCaret {
        require(caret.offset in 0..text.length && (direction == -1 || direction == 1))
        val segment = caretSegment(caret)
        if (segment is AnonymousSelectionSegment.Figure) {
            val local = caret.translated(-segment.start)
            val moved = figureById.getValue(segment.anchor.event.id).measured.geometry.visualCaret(local, direction)
            val translated = moved.translated(segment.start)
            if (moved.offset != local.offset) return translated.copy(affinity = when (translated.offset) {
                segment.start -> NativeTextAffinity.Downstream
                segment.end -> NativeTextAffinity.Upstream
                else -> translated.affinity
            })
            if (moved != local && caretSegment(translated) === segment) return translated
        }
        fun mapped(value: NativeTextCaret, owner: AnonymousSelectionSegment.Inline): NativeTextCaret =
            NativeTextCaret(owner.start + owner.authored.logicalOffset(value.offset) - owner.authored.logicalStart,
                when (value.offset) {
                    owner.nativeStart -> NativeTextAffinity.Downstream
                    owner.nativeEnd -> NativeTextAffinity.Upstream
                    else -> value.affinity
                })
        var at = nativeCaret(caret, segment)
        if (segment is AnonymousSelectionSegment.Figure) {
            val forward = (direction > 0) == (segment.anchor.event.captionContext.direction == BidiResolvedDirection.Ltr)
            at = NativeTextCaret(if (forward) segment.nativeEnd else segment.nativeStart,
                if (forward) NativeTextAffinity.Downstream else NativeTextAffinity.Upstream)
        }
        val inline = selection.segments.filterIsInstance<AnonymousSelectionSegment.Inline>()
            .filter { it.end > it.start }
        val visited = mutableSetOf<NativeTextCaret>()
        while (visited.add(at)) {
            val moved = native.visualCaret(at, direction)
            if (segment is AnonymousSelectionSegment.Inline && moved.offset in segment.nativeStart..segment.nativeEnd) {
                val logical = mapped(moved, segment)
                if (logical != caret) return logical
            } else {
                // A caption exit follows the outer native bidi walk. Keep the entered
                // inline edge before consuming the character used to establish that route.
                if (segment is AnonymousSelectionSegment.Figure && moved.offset != at.offset) {
                    inline.firstOrNull { at.offset in it.nativeStart..it.nativeEnd &&
                        moved.offset in it.nativeStart..it.nativeEnd }?.let { entered ->
                        val edge = mapped(at, entered)
                        if (edge != caret) return edge
                    }
                }
                val entered = figureSegments.values.firstOrNull { it !== segment && it.end > it.start &&
                    (moved.offset == it.nativeStart || moved.offset == it.nativeEnd ||
                        at.offset == it.nativeStart && moved.offset == it.nativeEnd ||
                        at.offset == it.nativeEnd && moved.offset == it.nativeStart) }
                if (entered != null) {
                    val start = (direction > 0) == (entered.anchor.event.captionContext.direction == BidiResolvedDirection.Ltr)
                    return NativeTextCaret(if (start) entered.start else entered.end,
                        if (start) NativeTextAffinity.Downstream else NativeTextAffinity.Upstream)
                }
                val owner = (if (moved.affinity == NativeTextAffinity.Upstream)
                    inline.lastOrNull { it.nativeEnd == moved.offset } else null)
                    ?: inline.firstOrNull { moved.offset >= it.nativeStart && moved.offset < it.nativeEnd }
                    ?: inline.lastOrNull { moved.offset == it.nativeEnd }
                owner?.let {
                    val logical = mapped(moved, it)
                    if (logical != caret) return logical
                }
            }
            if (moved == at) return caret
            at = moved
        }
        return caret
    }

    override fun caretRect(offset: Int): RectF {
        require(offset in 0..text.length)
        val segment = selection.at(offset)
        if (segment is AnonymousSelectionSegment.Figure) {
            val placed = figureById.getValue(segment.anchor.event.id)
            return placed.measured.geometry.caretRect(offset - segment.start).apply { offset(placed.bounds.left, placed.bounds.top) }
        }
        if (text.isEmpty()) {
            if (!hasNativeAuthoredInlineMetrics(native.text)) return RectF(0f, 0f, 1f, 0f)
            val caret = native.caretRect(selection.nativeOffset(offset))
            val line = native.firstLineBand()
            return RectF(caret.left, line.top, caret.right, line.bottom)
        }
        return native.caretRect(selection.nativeOffset(offset))
    }

    override fun lineRange(offset: Int): Pair<Int, Int> {
        val segment = selection.at(offset)
        if (segment is AnonymousSelectionSegment.Figure) {
            val range = figureById.getValue(segment.anchor.event.id).measured.geometry.lineRange(offset - segment.start)
            return (segment.start + range.first) to (segment.start + range.second)
        }
        val range = native.lineRange(selection.nativeOffset(offset))
        return selection.semanticOffset(range.first) to selection.semanticOffset(range.second)
    }

    override fun visualLineRanges(offset: Int): List<Pair<Int, Int>> {
        val segment = selection.at(offset)
        if (segment is AnonymousSelectionSegment.Figure) {
            val child = figureById.getValue(segment.anchor.event.id).measured.geometry
            return child.visualLineRanges(offset - segment.start).map { range ->
                (segment.start + range.first) to (segment.start + range.second)
            }
        }
        // NativeFloatGeometry exports its original input offsets, even when it privately
        // shapes Ruby column tokens. Map each fragment separately through this owner.
        return native.visualLineRanges(selection.nativeOffset(offset)).map { range ->
            selection.semanticOffset(range.first) to selection.semanticOffset(range.second)
        }
    }

    override fun isHardLineBreak(offset: Int): Boolean {
        require(offset in 0 until text.length)
        val segment = selection.at(offset)
        if (segment is AnonymousSelectionSegment.Figure)
            return figureById.getValue(segment.anchor.event.id).measured.geometry.isHardLineBreak(offset - segment.start)
        val original = selection.nativeOffset(offset)
        // Keep the existing semantic image-alt behavior. Ruby's exact public source
        // retains its gap LF, so only its native owner can classify that character.
        return if (original < native.text.length && native.text[original] == '\n')
            native.isHardLineBreak(original) else text[offset] == '\n'
    }

    override fun visualOffset(offset: Int, direction: Int): Int {
        require(offset in 0..text.length && direction in listOf(-1, 1))
        val segment = selection.at(offset)
        if (segment is AnonymousSelectionSegment.Figure) {
            val local = offset - segment.start
            val moved = figureById.getValue(segment.anchor.event.id).measured.geometry.visualOffset(local, direction)
            if (moved != local) return segment.start + moved
        }
        var at = selection.nativeOffset(offset)
        if (segment is AnonymousSelectionSegment.Figure) {
            val ltr = segment.anchor.event.captionContext.direction == BidiResolvedDirection.Ltr
            at = if ((direction > 0) == ltr) segment.nativeEnd else segment.nativeStart
        }
        val visited = mutableSetOf<Int>()
        while (visited.add(at)) {
            val moved = native.visualOffset(at, direction)
            val entered = figureSegments.values.firstOrNull { it.nativeStart == moved }
            val logical = if (entered != null && entered !== segment) {
                val ltr = entered.anchor.event.captionContext.direction == BidiResolvedDirection.Ltr
                val edge = if ((direction > 0) == ltr) entered.start else entered.end
                // Different owners can share a semantic index. Enter the actual child before
                // skipping generated native positions, even when its edge equals the old offset.
                val child = figureById.getValue(entered.anchor.event.id).measured.geometry
                entered.start + child.visualOffset(edge - entered.start, direction)
            } else selection.semanticOffset(moved)
            if (logical != offset) return logical
            if (moved == at) return offset
            at = moved
        }
        return offset
    }

    override fun clippedAbsoluteSemanticLocation(start: Int, end: Int): NativeClippedAbsoluteSemanticLocation? {
        if (start < 0 || end <= start || end > text.length) return null
        val covered = selection.segments.filter { start < it.end && end > it.start }
        val first = covered.firstOrNull() ?: return null
        if (start < first.start || end > covered.last().end) return null
        if (first is AnonymousSelectionSegment.Figure) {
            if (covered.size != 1) return null
            val placed = figureById.getValue(first.anchor.event.id)
            return placed.measured.geometry.clippedAbsoluteSemanticLocation(start - first.start, end - first.start)
                ?.translated(placed.bounds.left, placed.bounds.top)
        }
        if (covered.any { it !is AnonymousSelectionSegment.Inline }) return null
        val inline = covered.filterIsInstance<AnonymousSelectionSegment.Inline>()
        if (inline.any { it.authored.replacement } || inline.zipWithNext().any { (a, b) ->
                a.end != b.start || a.nativeEnd != b.nativeStart
            }) return null
        val begin = inline.first()
        val last = inline.last()
        return native.clippedAbsoluteSemanticLocation(
            begin.authored.nativeOffset(begin.authored.logicalStart + start - begin.start),
            last.authored.nativeOffset(last.authored.logicalStart + end - last.start))
    }

    override fun inlinePaddingGroupRects(owner: Span, start: Int, end: Int): List<RectF>? {
        require(start in 0..text.length && end in start..text.length)
        if (start == end) return null
        val covered = selection.segments.filter { start < it.end && end > it.start }
        val first = covered.firstOrNull() ?: return null
        if (first is AnonymousSelectionSegment.Figure) {
            if (covered.size != 1) return null
            val placed = figureById.getValue(first.anchor.event.id)
            return placed.measured.geometry.inlinePaddingGroupRects(owner, start - first.start, end - first.start)
                ?.map { RectF(it).apply { offset(placed.bounds.left, placed.bounds.top) } }
        }
        if (covered.any { it !is AnonymousSelectionSegment.Inline }) return null
        val inline = covered.filterIsInstance<AnonymousSelectionSegment.Inline>()
        if (inline.any { it.authored.replacement } || inline.zipWithNext().any { (a, b) ->
                a.end != b.start || a.nativeEnd != b.nativeStart
            }) return null
        val begin = inline.first()
        val last = inline.last()
        return native.inlinePaddingGroupRects(owner,
            begin.authored.nativeOffset(begin.authored.logicalStart + start - begin.start),
            last.authored.nativeOffset(last.authored.logicalStart + end - last.start))
    }

    override fun inlineBoxGroupRects(owner: NativeInlineBoxOwner, start: Int, end: Int): List<RectF>? {
        require(start in 0..text.length && end in start..text.length)
        if (start == end) return null
        val covered = selection.segments.filter { start < it.end && end > it.start }
        val first = covered.firstOrNull() ?: return null
        if (first is AnonymousSelectionSegment.Figure) {
            if (covered.size != 1) return null
            val placed = figureById.getValue(first.anchor.event.id)
            return placed.measured.geometry.inlineBoxGroupRects(owner, start - first.start, end - first.start)
                ?.map { RectF(it).apply { offset(placed.bounds.left, placed.bounds.top) } }
        }
        if (covered.any { it !is AnonymousSelectionSegment.Inline }) return null
        val inline = covered.filterIsInstance<AnonymousSelectionSegment.Inline>()
        if (inline.any { it.authored.replacement } || inline.zipWithNext().any { (a, b) ->
                a.end != b.start || a.nativeEnd != b.nativeStart
            }) return null
        val begin = inline.first()
        val last = inline.last()
        return native.inlineBoxGroupRects(owner,
            begin.authored.nativeOffset(begin.authored.logicalStart + start - begin.start),
            last.authored.nativeOffset(last.authored.logicalStart + end - last.start))
    }

    override fun inlineBoxGroupHitTest(owner: NativeInlineBoxOwner, start: Int, end: Int): ((Float, Float) -> Boolean)? {
        require(start in 0..text.length && end in start..text.length)
        if (start == end) return null
        val covered = selection.segments.filter { start < it.end && end > it.start }
        val first = covered.firstOrNull() ?: return null
        if (first is AnonymousSelectionSegment.Figure) {
            if (covered.size != 1) return null
            val placed = figureById.getValue(first.anchor.event.id)
            return placed.measured.geometry.inlineBoxGroupHitTest(owner, start - first.start, end - first.start)
                ?.let { test -> { x, y -> test(x - placed.bounds.left, y - placed.bounds.top) } }
        }
        if (covered.any { it !is AnonymousSelectionSegment.Inline }) return null
        val inline = covered.filterIsInstance<AnonymousSelectionSegment.Inline>()
        if (inline.any { it.authored.replacement } || inline.zipWithNext().any { (a, b) ->
                a.end != b.start || a.nativeEnd != b.nativeStart
            }) return null
        val begin = inline.first()
        val last = inline.last()
        return native.inlineBoxGroupHitTest(owner,
            begin.authored.nativeOffset(begin.authored.logicalStart + start - begin.start),
            last.authored.nativeOffset(last.authored.logicalStart + end - last.start))
    }

    override fun inlineBoxChildActionRects(owner: NativeInlineBoxOwner, start: Int, end: Int,
        childStart: Int, childEnd: Int, fragments: List<RectF>): List<RectF>? {
        require(start in 0..text.length && end in start..text.length && childStart in start..end && childEnd in childStart..end)
        if (start == end) return null
        val covered = selection.segments.filter { start < it.end && end > it.start }
        val first = covered.firstOrNull() ?: return null
        if (first is AnonymousSelectionSegment.Figure) {
            if (covered.size != 1) return null
            val placed = figureById.getValue(first.anchor.event.id)
            val dx = placed.bounds.left; val dy = placed.bounds.top
            return placed.measured.geometry.inlineBoxChildActionRects(owner, start - first.start, end - first.start,
                childStart - first.start, childEnd - first.start,
                fragments.map { RectF(it).apply { offset(-dx, -dy) } })
                ?.map { RectF(it).apply { offset(dx, dy) } }
        }
        if (covered.any { it !is AnonymousSelectionSegment.Inline }) return null
        val inline = covered.filterIsInstance<AnonymousSelectionSegment.Inline>()
        if (inline.any { it.authored.replacement } || inline.zipWithNext().any { (a, b) ->
                a.end != b.start || a.nativeEnd != b.nativeStart
            }) return null
        fun mapped(offset: Int, endAffinity: Boolean): Int {
            val segment = (if (endAffinity) inline.lastOrNull { offset > it.start && offset <= it.end }
                else inline.firstOrNull { offset >= it.start && offset < it.end })
                ?: if (offset == end) inline.last() else inline.first()
            return segment.authored.nativeOffset(segment.authored.logicalStart + offset - segment.start)
        }
        return native.inlineBoxChildActionRects(owner, mapped(start, false), mapped(end, true),
            mapped(childStart, false), mapped(childEnd, true), fragments)
    }

    override fun inlineActionGroupRects(owner: NativeInlineActionOwner, start: Int, end: Int): List<RectF>? {
        require(start in 0..text.length && end in start..text.length)
        if (start == end) {
            var recognized = false
            val result = mutableListOf<RectF>()
            val nativeQueries = mutableSetOf<Int>()
            selection.segments.filter { start in it.start..it.end }.forEach { segment ->
                val boxes = when (segment) {
                    is AnonymousSelectionSegment.Inline -> if (segment.authored.replacement) null else {
                        val at = segment.authored.nativeOffset(segment.authored.logicalStart + start - segment.start)
                        if (nativeQueries.add(at)) native.inlineActionGroupRects(owner, at, at) else null
                    }
                    is AnonymousSelectionSegment.Figure -> {
                        val placed = figureById.getValue(segment.anchor.event.id)
                        placed.measured.geometry.inlineActionGroupRects(owner, start - segment.start, start - segment.start)
                            ?.map { RectF(it).apply { offset(placed.bounds.left, placed.bounds.top) } }
                    }
                }
                if (boxes != null) { recognized = true; result.addAll(boxes) }
            }
            return result.takeIf { recognized }
        }
        // Validate the complete requested interval before any projection. An overlap
        // with an owner is not authority for source outside that owner.
        val covered = selection.segments.filter { start < it.end && end > it.start }
        val first = covered.firstOrNull() ?: return null
        if (first is AnonymousSelectionSegment.Figure) {
            if (covered.size != 1) return null
            val placed = figureById.getValue(first.anchor.event.id)
            return placed.measured.geometry.inlineActionGroupRects(owner, start - first.start, end - first.start)
                ?.map { RectF(it).apply { offset(placed.bounds.left, placed.bounds.top) } }
        }
        if (covered.any { it !is AnonymousSelectionSegment.Inline }) return null
        val inline = covered.filterIsInstance<AnonymousSelectionSegment.Inline>()
        if (inline.any { it.authored.replacement } || inline.zipWithNext().any { (a, b) ->
                a.end != b.start || a.nativeEnd != b.nativeStart
            }) return null
        val begin = inline.first(); val last = inline.last()
        return native.inlineActionGroupRects(owner,
            begin.authored.nativeOffset(begin.authored.logicalStart + start - begin.start),
            last.authored.nativeOffset(last.authored.logicalStart + end - last.start))
    }

    override fun rectsForRange(start: Int, end: Int): List<RectF> {
        require(start in 0..text.length && end in start..text.length)
        return buildList {
            selection.segments.forEach { segment ->
                val first = maxOf(start, segment.start)
                val last = minOf(end, segment.end)
                if (first < last) when (segment) {
                    is AnonymousSelectionSegment.Inline -> addAll(native.rectsForRange(
                        if (segment.authored.replacement) segment.nativeStart else segment.nativeStart + first - segment.start,
                        if (segment.authored.replacement) segment.nativeEnd else segment.nativeStart + last - segment.start))
                    is AnonymousSelectionSegment.Figure -> {
                        val placed = figureById.getValue(segment.anchor.event.id)
                        addAll(placed.measured.geometry.rectsForRange(first - segment.start, last - segment.start)
                            .map { RectF(it).apply { offset(placed.bounds.left, placed.bounds.top) } })
                    }
                }
            }
        }
    }

    override fun characterRects(start: Int, length: Int): List<RectF?> {
        require(start in 0..text.length && length >= 0 && length <= text.length - start)
        return (start until start + length).map { offset ->
            when (val segment = checkNotNull(selection.at(offset))) {
                is AnonymousSelectionSegment.Inline -> native.characterRects(
                    if (segment.authored.replacement) segment.nativeStart else segment.nativeStart + offset - segment.start, 1).single()
                is AnonymousSelectionSegment.Figure -> {
                    val placed = figureById.getValue(segment.anchor.event.id)
                    placed.measured.geometry.characterRects(offset - segment.start, 1).single()
                        ?.let { RectF(it).apply { offset(placed.bounds.left, placed.bounds.top) } }
                }
            }
        }
    }

    companion object {
        fun build(
            content: AnonymousFlowContent,
            paint: TextPaint,
            width: Int,
            inline: (AnonymousFlowEvent.Inline) -> Spanned,
            figure: (AnonymousFlowEvent.FigureObject, Int) -> MeasuredAnonymousFigure,
            insets: NativeTextInsets = NativeTextInsets(),
            carriedExclusions: List<NativeFloatExclusion> = emptyList(),
            inlineNodes: (NativeAnonymousFlowGeometry) -> List<FloatInteractionNode> = { emptyList() },
            inlineSemantic: (AnonymousFlowEvent.Inline, String) -> List<AnonymousInlineTextPart> = { _, text ->
                listOf(AnonymousInlineTextPart(0, text.length, text))
            },
            decoration: (Canvas, NativeFloatGeometry) -> Unit = { _, _ -> },
            outsideMarkerHeight: Float = 0f,
            decorationBounds: (NativeFloatGeometry) -> NativeFloatBounds? = { null },
            inlineNodeSources: ((NativeAnonymousFlowGeometry) -> List<NativeAnonymousInlineNode>)? = null,
        ): NativeAnonymousFlowGeometry {
            require(width >= 0 && width <= Int.MAX_VALUE / 4)
            val prepared = content.events.filterIsInstance<AnonymousFlowEvent.Inline>().map { it to inline(it) }
            var nextInline = 0
            val offsets = AnonymousFlowOffsets.build(content, inlineSemantic) { event ->
                val row = prepared[nextInline++]
                check(row.first === event)
                row.second.toString()
            }
            val source = SpannableString(offsets.nativeText)
            prepared.forEachIndexed { index, (event, styled) -> if (styled.isNotEmpty() || hasNativeInlineLayoutOwner(styled)) {
                val range = offsets.inlineSources[index]
                check(styled.toString() == offsets.nativeText.substring(range.start, range.end))
                styled.getSpans(0, styled.length, Any::class.java).forEach { span ->
                    // Alignment belongs to this full anonymous owner, not an independently shaped inline shard.
                    if (span is AlignmentSpan) return@forEach
                    // Each source occurrence retains its own point/range owner, even when an empty fragment is reused.
                    val copied = nativeInlineStyleSpanCopy(span)
                    source.setSpan(copied, range.start + styled.getSpanStart(span),
                        range.start + styled.getSpanEnd(span), styled.getSpanFlags(span))
                    if (copied is NativeRubyPreparedSource) nativeRubyBindAnonymousScope(source, copied, event)
                }
            } }
            val measured = offsets.figures.associateWith { figure(it.event, width) }
            val floats = mutableListOf<NativeFloatOccurrence>()
            val inFlow = linkedMapOf<AnonymousFigureAnchor, InFlowFigureSpan>()
            measured.forEach { (anchor, box) ->
                val model = anchor.event.figure
                val side = when (model.placement) {
                    FigurePlacement.FloatLeft -> TableFloatSide.Left
                    FigurePlacement.FloatRight -> TableFloatSide.Right
                    else -> null
                }
                if (side != null) {
                    floats += NativeFloatOccurrence(anchor.event.id, anchor.nativeOffset,
                        box.geometry.width.toFloat(), box.geometry.height.toFloat(), side,
                        when (model.clear) {
                            FigureClear.None -> NativeFloatClear.None
                            FigureClear.Left -> NativeFloatClear.Left
                            FigureClear.Right -> NativeFloatClear.Right
                            FigureClear.Both -> NativeFloatClear.Both
                        }, box.margins, { canvas, bounds -> drawFigure(canvas, box, bounds) })
                } else {
                    if (model.clear != FigureClear.None)
                        throw UnsupportedFloatLayout("In-flow figure clear needs a line-position constraint")
                    val bandWidth = kotlin.math.floor(width - insets.left - insets.right - insets.extraLeft - insets.extraRight).toInt().coerceAtLeast(0)
                    // An authored content minimum may overflow its containing block. The
                    // measured child keeps that width; the replacement still owns one block line.
                    val blockMedia = model.blockMediaLayout != null
                    if (blockMedia && bandWidth == 0 && (measured.size != 1 || offsets.logicalText.isNotEmpty()))
                        throw UnsupportedFloatLayout("Zero-width Figure block siblings need an explicit block line owner")
                    if (blockMedia != (box.usedBox != null))
                        throw UnsupportedFloatLayout("Figure block flow dimensions are unavailable")
                    if (bandWidth > 0 && box.outerWidth > bandWidth && !box.frameMinimumWidens && !blockMedia)
                        throw UnsupportedFloatLayout("In-flow figure cannot fit its exact containing width")
                    val usedLeft = box.normalContentLeft ?: ((if (model.placement == FigurePlacement.Center)
                        (bandWidth - box.outerWidth) / 2f else 0f) + box.margins.left)
                    val exactLeft = if (blockMedia) insets.left + insets.extraLeft + usedLeft else null
                    val ink = if (blockMedia) box.geometry.extents.ink else null
                    val outside = box.outerWidth > bandWidth || usedLeft < 0f || usedLeft + box.geometry.width > bandWidth ||
                        (ink != null && (ink.left < 0f || ink.top < 0f || ink.right > box.geometry.width || ink.bottom > box.geometry.height))
                    val span = InFlowFigureSpan(box, bandWidth, model.placement == FigurePlacement.Center,
                        paintsOutsideLineClip = blockMedia || outside, exactContentLeft = exactLeft,
                        minimumHeight = if (blockMedia) outsideMarkerHeight else 0f)
                    source.setSpan(span, anchor.nativeOffset, anchor.nativeOffset + 1, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
                    if (blockMedia) {
                        // The real child already owns its complete source strut. This generated
                        // replacement contributes only its exact atomic line, including height zero.
                        source.setSpan(NativeRunLineMetrics(NativePrimaryFontMetrics(0f, 0f, 0f, 0f),
                            NativeLineHeightPolicy.Pixels(0f), strut = true), anchor.nativeOffset,
                            anchor.nativeOffset + 1, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
                    }
                    inFlow[anchor] = span
                }
            }
            // A figure-only owner has no authored text line. Generated controls must not add a strut.
            if (offsets.logicalText.isEmpty() && source.isNotEmpty() &&
                offsets.inlineSources.none { it.start < it.end }) {
                source.setSpan(object : LineHeightSpan {
                    override fun chooseHeight(text: CharSequence, start: Int, end: Int, spanstartv: Int,
                        v: Int, fm: Paint.FontMetricsInt) {
                        val height = ceil(maxOf(outsideMarkerHeight, inFlow.filterKeys { it.nativeOffset in start until end }
                            .values.maxOfOrNull { it.box.outerHeight } ?: 0f)).toInt()
                        fm.ascent = -height; fm.top = -height; fm.descent = 0; fm.bottom = 0; fm.leading = 0
                    }
                }, 0, source.length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
            }
            val alignment = when (content.context.textAlign) {
                CellTextAlign.Center -> Layout.Alignment.ALIGN_CENTER
                CellTextAlign.Left -> if (content.context.direction == BidiResolvedDirection.Ltr)
                    Layout.Alignment.ALIGN_NORMAL else Layout.Alignment.ALIGN_OPPOSITE
                CellTextAlign.Right -> if (content.context.direction == BidiResolvedDirection.Rtl)
                    Layout.Alignment.ALIGN_NORMAL else Layout.Alignment.ALIGN_OPPOSITE
                null -> Layout.Alignment.ALIGN_NORMAL
            }
            val native = NativeFloatGeometry.build(source, paint, width, floats,
                alignment = alignment,
                textDirection = if (content.context.direction == BidiResolvedDirection.Ltr)
                    TextDirectionHeuristics.LTR else TextDirectionHeuristics.RTL,
                carriedExclusions = carriedExclusions, insets = insets, decoration = decoration,
                decorationBounds = decorationBounds)
            val placed = measured.map { (anchor, box) ->
                val float = native.floats.singleOrNull { it.occurrence.sourceId == anchor.event.id }
                val bounds = if (float != null) RectF(float.content) else {
                    val span = inFlow.getValue(anchor)
                    val boxes = native.rectsForRange(anchor.nativeOffset, anchor.nativeOffset + 1)
                    // A source block's child and deferred paint share one exact containing origin.
                    // Its CSS position is never reconstructed from quantized selection rectangles.
                    val left = span.exactContentLeft ?: ((boxes.minOfOrNull { it.left }
                        ?: native.caretRect(anchor.nativeOffset).left) + span.contentLeft)
                    val top = native.baselineForOffset(anchor.nativeOffset) - box.outerHeight
                    if (box.usedBox != null) {
                        val own = box.geometry.extents
                        val ink = enclosingBounds(own.ink, own.interaction)
                        val childLeft = left
                        val first = childLeft + minOf(0f, ink?.left ?: 0f)
                        val last = childLeft + maxOf(box.usedBox.width, ink?.right ?: 0f)
                        val bottom = top + box.marginTop + maxOf(box.usedBox.height, ink?.bottom ?: 0f)
                        // A float may already have moved the native line before this publication.
                        // Until the child receives that exclusion, conservatively retain refusal
                        // for earlier intersecting source footprints too, including signed overflow.
                        if (native.exclusions.any { exclusion ->
                            exclusion.outer.bottom > 0f && exclusion.outer.top <= bottom &&
                                exclusion.outer.left <= last && exclusion.outer.right >= first
                        }) throw UnsupportedFloatLayout("Figure block inherited float placement is unavailable")
                    }
                    RectF(left, top + box.marginTop,
                        left + box.geometry.width, top + box.marginTop + box.geometry.height)
                }
                PlacedAnonymousFigure(anchor, box, bounds, inFlow[anchor]?.paintsOutsideLineClip == true)
            }
            return NativeAnonymousFlowGeometry(offsets, native, placed, inlineNodes, inlineNodeSources)
        }
    }
}

private fun drawFigure(canvas: Canvas, box: MeasuredAnonymousFigure, bounds: RectF) {
    val saved = canvas.save()
    canvas.translate(bounds.left, bounds.top)
    box.geometry.paint(canvas)
    canvas.restoreToCount(saved)
}

/** Full-width object forces a visual block line without inserting a paragraph separator. */
private class InFlowFigureSpan(val box: MeasuredAnonymousFigure, val width: Int, centered: Boolean,
    val paintsOutsideLineClip: Boolean, val exactContentLeft: Float? = null, private val minimumHeight: Float = 0f) :
    ReplacementSpan(), NativeAtomicInlineMetrics, NativeReplacementPaintBounds {
    override val nativeUsedMetrics: NativeUsedLineMetrics get() =
        NativeUsedLineMetrics(-maxOf(box.outerHeight, minimumHeight), 0f)
    val contentLeft = box.normalContentLeft ?: ((if (centered) (width - box.outerWidth) / 2f else 0f) + box.margins.left)
    override fun nativePaintBounds(lineTop: Float, lineBottom: Float): NativeFloatBounds? =
        if (paintsOutsideLineClip) null else box.geometry.extents.ink
            ?.translated(contentLeft, -box.outerHeight + box.marginTop)
    override fun getSize(paint: Paint, text: CharSequence, start: Int, end: Int, fm: Paint.FontMetricsInt?): Int {
        fm?.let { it.ascent = minOf(it.ascent, -ceil(box.outerHeight).toInt()); it.top = minOf(it.top, it.ascent) }
        return width
    }
    override fun draw(canvas: Canvas, text: CharSequence, start: Int, end: Int, x: Float,
        top: Int, y: Int, bottom: Int, paint: Paint) {
        if (paintsOutsideLineClip) return
        val left = x + contentLeft
        val childTop = y - box.outerHeight + box.marginTop
        drawFigure(canvas, box, RectF(left, childTop, left + box.geometry.width, childTop + box.geometry.height))
    }
}
