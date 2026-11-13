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

/** The figure adapter owns image/caption layout and media state; this owner never remeasures a bitmap. */
internal data class MeasuredAnonymousFigure(
    val geometry: FloatTextGeometry,
    val margins: FloatMargins,
    val frameMinimumWidens: Boolean = false,
    val normalContentLeft: Float? = null,
) {
    init {
        require(geometry.width >= 0 && geometry.height >= 0)
        require(normalContentLeft == null || normalContentLeft.isFinite())
        require(geometry.width.toDouble() + margins.left + margins.right <= Int.MAX_VALUE / 4)
        require(geometry.height.toDouble() + margins.top + margins.bottom <= Int.MAX_VALUE / 4)
    }
    val outerWidth: Float get() = geometry.width + margins.left + margins.right
    val outerHeight: Float get() = geometry.height + margins.top + margins.bottom
}

internal data class PlacedAnonymousFigure(
    val anchor: AnonymousFigureAnchor, val measured: MeasuredAnonymousFigure, val bounds: RectF,
    val paintsOutsideLineClip: Boolean = false,
)

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
) : FloatTextGeometry {
    private val figureById = figures.associateBy { it.anchor.event.id }
    val selection = AnonymousFlowSelection.build(offsets) { figureById.getValue(it.event.id).measured.geometry.text }
    private val figureSegments = selection.segments.filterIsInstance<AnonymousSelectionSegment.Figure>().associateBy { it.anchor.event.id }
    override val text: CharSequence get() = selection.text
    override val width: Int get() = native.width
    override val height: Int get() = native.height
    override val textBaselines: NativeTextBaselines? get() = native.textBaselines
    val textBottom: Float get() = native.textBottom
    val scrollableBounds: NativeFloatBounds by lazy {
        figures.fold(native.scrollableBounds) { bounds, figure ->
            bounds.enclosing(NativeFloatBounds(figure.bounds.left, figure.bounds.top,
                figure.bounds.right, figure.bounds.bottom))
        }.let { bounds -> positionedGroups.flatMap { it.bounds }.fold(bounds) { area, box ->
            area.enclosing(NativeFloatBounds(box.left, box.top, box.right, box.bottom))
        } }
    }
    val ownExclusions: List<NativeFloatExclusion> get() = native.floats.map {
        NativeFloatExclusion(it.occurrence.side, NativeFloatBounds(it.outer.left, it.outer.top, it.outer.right, it.outer.bottom))
    }
    internal fun firstLineBand(): RectF = native.firstLineBand()
    private data class OwnedNode(val value: FloatInteractionNode, val figure: Int? = null, val localId: Int = value.id)
    private val ownedNodes = buildList {
        addAll(inlineNodes(this@NativeAnonymousFlowGeometry).map { OwnedNode(it) })
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
    override val positionedGroups: List<NativePositionedGroup> by lazy { figures.flatMap { placed ->
        val start = figureSegments.getValue(placed.anchor.event.id).start
        placed.measured.geometry.positionedGroups.map { group ->
            group.translated(placed.bounds.left, placed.bounds.top, start) { id ->
                figureNodeIds.getValue(placed.anchor.event.id to id)
            }
        }
    } }

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
        native.paint(canvas)
        // Native text paints through per-line clips. A minimum-driven overflowing block
        // paints once at its measured bounds after those clips, like an anchored float.
        figures.filter { it.paintsOutsideLineClip }.forEach { drawFigure(canvas, it.measured, it.bounds) }
    }
    internal fun nativeRectsForRange(start: Int, end: Int): List<RectF> = native.rectsForRange(start, end)
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

    override fun caretRect(offset: Int): RectF {
        require(offset in 0..text.length)
        val segment = selection.at(offset)
        if (segment is AnonymousSelectionSegment.Figure) {
            val placed = figureById.getValue(segment.anchor.event.id)
            return placed.measured.geometry.caretRect(offset - segment.start).apply { offset(placed.bounds.left, placed.bounds.top) }
        }
        if (text.isEmpty()) return RectF(0f, 0f, 1f, 0f)
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
            prepared.forEachIndexed { index, (_, styled) -> if (styled.isNotEmpty()) {
                val range = offsets.inlineSources[index]
                check(styled.toString() == offsets.nativeText.substring(range.start, range.end))
                styled.getSpans(0, styled.length, Any::class.java).forEach { span ->
                    // Alignment belongs to this full anonymous owner, not an independently shaped inline shard.
                    if (span is AlignmentSpan) return@forEach
                    source.setSpan(span, range.start + styled.getSpanStart(span),
                        range.start + styled.getSpanEnd(span), styled.getSpanFlags(span))
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
                    if (bandWidth > 0 && box.outerWidth > bandWidth && !box.frameMinimumWidens)
                        throw UnsupportedFloatLayout("In-flow figure cannot fit its exact containing width")
                    val usedLeft = box.normalContentLeft ?: ((if (model.placement == FigurePlacement.Center)
                        (bandWidth - box.outerWidth) / 2f else 0f) + box.margins.left)
                    val span = InFlowFigureSpan(box, bandWidth, model.placement == FigurePlacement.Center,
                        paintsOutsideLineClip = box.outerWidth > bandWidth || usedLeft < 0f || usedLeft + box.geometry.width > bandWidth)
                    source.setSpan(span, anchor.nativeOffset, anchor.nativeOffset + 1, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
                    inFlow[anchor] = span
                }
            }
            // A figure-only owner has no authored text line. Generated controls must not add a strut.
            if (offsets.logicalText.isEmpty() && source.isNotEmpty()) {
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
                    val left = boxes.minOfOrNull { it.left } ?: native.caretRect(anchor.nativeOffset).left
                    val top = native.baselineForOffset(anchor.nativeOffset) - box.outerHeight
                    RectF(left + span.contentLeft, top + box.margins.top,
                        left + span.contentLeft + box.geometry.width, top + box.margins.top + box.geometry.height)
                }
                PlacedAnonymousFigure(anchor, box, bounds, inFlow[anchor]?.paintsOutsideLineClip == true)
            }
            return NativeAnonymousFlowGeometry(offsets, native, placed, inlineNodes)
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
    val paintsOutsideLineClip: Boolean) : ReplacementSpan(), NativeAtomicInlineMetrics, NativeReplacementPaintBounds {
    override val nativeUsedMetrics: NativeUsedLineMetrics get() = NativeUsedLineMetrics(-box.outerHeight, 0f)
    val contentLeft = box.normalContentLeft ?: ((if (centered) (width - box.outerWidth) / 2f else 0f) + box.margins.left)
    override fun nativePaintBounds(lineTop: Float, lineBottom: Float): NativeFloatBounds? =
        if (paintsOutsideLineClip) null else box.geometry.extents.ink
            ?.translated(contentLeft, -box.outerHeight + box.margins.top)
    override fun getSize(paint: Paint, text: CharSequence, start: Int, end: Int, fm: Paint.FontMetricsInt?): Int {
        fm?.let { it.ascent = minOf(it.ascent, -ceil(box.outerHeight).toInt()); it.top = minOf(it.top, it.ascent) }
        return width
    }
    override fun draw(canvas: Canvas, text: CharSequence, start: Int, end: Int, x: Float,
        top: Int, y: Int, bottom: Int, paint: Paint) {
        if (paintsOutsideLineClip) return
        val left = x + contentLeft
        val childTop = y - box.outerHeight + box.margins.top
        drawFigure(canvas, box, RectF(left, childTop, left + box.geometry.width, childTop + box.geometry.height))
    }
}
