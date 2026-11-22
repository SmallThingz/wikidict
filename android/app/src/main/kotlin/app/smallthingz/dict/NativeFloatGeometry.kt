package app.smallthingz.dict

import android.graphics.Canvas
import android.graphics.Matrix
import android.graphics.Paint
import android.graphics.Path
import android.graphics.Rect
import android.graphics.RectF
import android.graphics.Region
import android.graphics.RegionIterator
import android.text.Layout
import android.text.PrecomputedText
import android.text.SpannableString
import android.text.Spanned
import android.text.SpannedString
import android.text.StaticLayout
import android.text.TextDirectionHeuristic
import android.text.TextDirectionHeuristics
import android.text.TextPaint
import android.text.style.ReplacementSpan
import kotlin.math.ceil
import kotlin.math.floor
import kotlin.math.max

/** Source-only candidate. All dimensions here are physical device pixels. */
internal data class FloatMargins(override val top: Float, override val right: Float,
    override val bottom: Float, override val left: Float) : NativeContainerMargins {
    init { require(listOf(top, right, bottom, left).all { it.isFinite() && it >= 0f }) }
}

internal data class NativeTextInsets(val left: Float = 0f, val right: Float = 0f,
    val extraLeft: Float = 0f, val extraRight: Float = 0f) {
    init { require(listOf(left, right, extraLeft, extraRight).all { it.isFinite() && it >= 0f }) }
}

internal enum class NativeFloatClear { None, Left, Right, Both }

internal data class NativeFloatOccurrence(
    val sourceId: Int, val offset: Int, val width: Float, val height: Float,
    val side: TableFloatSide, val clear: NativeFloatClear, val margins: FloatMargins,
    val draw: (Canvas, RectF) -> Unit,
) {
    init {
        require(sourceId >= 0 && offset >= 0)
        require(width.isFinite() && height.isFinite() && width >= 0f && height >= 0f)
        if (width.toDouble() + margins.left + margins.right > Int.MAX_VALUE / 4 ||
            height.toDouble() + margins.top + margins.bottom > Int.MAX_VALUE / 4)
            throw UnsupportedFloatLayout("Float margin box exceeds native geometry")
    }
}

internal data class PlacedNativeFloat(val occurrence: NativeFloatOccurrence, val outer: RectF, val content: RectF)
internal class UnsupportedFloatLayout(message: String) : IllegalArgumentException(message)

/** Only explicitly aligned ordinary images replace the legacy line-band selection. */
internal interface NativeAlignedImageSelection {
    /** Outer image box relative to its native replacement X and the used line baseline. */
    val nativeImageSelectionBounds: NativeFloatBounds?
}

/**
 * Owns a single full-context Layout: paragraph bidi, shaping and UTF-16 offsets
 * remain native. Only a float's existing object character gets a zero-width span.
 * Line translations provide blocked-line vertical space without adding text.
 * Clear changes only a float's top, including floats anchored inside a text line.
 * A caller must join an entire formatting context before invoking this builder.
 */
/** One native geometry API, with the original StaticLayout path retained for null-only images. */
internal abstract class NativeFloatGeometry : FloatTextGeometry {
    abstract val floats: List<PlacedNativeFloat>
    abstract val exclusions: List<NativeFloatExclusion>
    abstract val textBottom: Float
    abstract val hasResidualFloats: Boolean
    abstract val scrollableBounds: NativeFloatBounds
    abstract fun firstLineBand(): RectF
    abstract fun headingOwnerContentTop(): Float?
    abstract fun remainingExclusions(afterY: Float = textBottom): List<NativeFloatExclusion>
    internal abstract fun baselineForOffset(offset: Int): Float
    internal abstract fun distanceForPosition(x: Float, y: Float): Double
    internal abstract val shapedLineCount: Int
    internal abstract fun usedLineHeight(line: Int): Float
    internal abstract fun inColumns(origins: List<Pair<Float, Float>>): NativeFloatGeometry
    internal abstract val hasColumnFragments: Boolean
    internal abstract val nativeRubyShapingSource: Spanned
    internal abstract val nativeRubyShapingPaint: TextPaint
    internal abstract val nativeRubyParagraphDirection: Int
    internal abstract fun nativeRubyLineSourceStart(line: Int): Int
    internal abstract fun nativeRubyLineAdvanceBounds(line: Int): RectF?
    internal abstract fun nativeRubyLineBaseline(line: Int): Float
    internal abstract fun nativeRubyLineTop(line: Int): Float
    internal abstract fun nativeRubyLineDirection(line: Int): Int
    internal abstract fun nativeRubyLinePaintBounds(line: Int): List<NativeFloatBounds>
    internal abstract fun nativeRubyLineCaret(line: Int, publicOffset: Int): RectF?
    internal abstract fun nativeRubyLineOffsetForPosition(line: Int, x: Float, y: Float): Int
    internal abstract fun nativeRubyLineCursorAt(line: Int, x: Float, y: Float): InlineCursor?
    internal abstract fun nativeRubyEmergencyLineEnds(): Set<Int>
    internal abstract fun nativeRubyMeasuredAdvance(start: Int, end: Int): Float
    internal abstract fun nativeRubyAvailableAt(offset: Int, considerPreviousLine: Boolean): Float
    internal abstract fun nativeRubyLineRects(line: Int, start: Int, end: Int): List<RectF>
    internal abstract fun nativeRubyLineBaseText(line: Int): String
    internal abstract fun nativeRubyLineRanges(line: Int): List<Pair<Int, Int>>
    internal abstract fun paintRubyNativeLine(canvas: Canvas, line: Int)
    internal abstract val nativeRubyAdvanceBounds: RectF?
    internal abstract fun nativeLineAt(offset: Int): Int
    internal abstract fun nativeRangeOfLine(line: Int): Pair<Int, Int>
    internal abstract fun nativeInlineVisibleEnd(line: Int): Int
    internal abstract fun nativeInlineVisibleAdvance(line: Int): Float
    internal abstract fun nativeInlineVisibleBounds(line: Int): RectF?
    internal abstract fun nativeLineAvailableWidth(line: Int): Float
    internal abstract fun nativeSingleLineAdvance(): Float
    internal abstract fun nativeLineAdvance(line: Int): Float
    internal abstract fun nativeUsedLineMetrics(line: Int): NativeUsedLineMetrics
    internal abstract fun nativeContentLineMetrics(line: Int): NativeUsedLineMetrics
    internal abstract fun nativeReplacementOrigin(offset: Int): Pair<Float, Float>
    internal open fun nativeReplacementPaintOrder(offset: Int): Long = offset.toLong()
    internal open fun nativeOrdinaryCaretAbove(x: Float, y: Float, after: Long): NativeTextCaret? = null
    internal abstract fun nativeInlineActionFragments(start: Int, end: Int): List<NativeInlineActionFragment>

    internal open val nativeRubyExactAdvances: Boolean get() = false
    internal open val nativeRubyRaw: NativeFloatGeometry get() = this
    internal open val nativeRubyColumns: List<NativeRubyPiece.Column> get() = emptyList()
    internal open val nativeRubyCollapsedText: List<NativeRubyPiece.Text> get() = emptyList()
    internal open fun nativeRubyRawOffset(publicOffset: Int): Int = publicOffset
    internal open fun nativeInlineBoxOverlay(owner: NativeInlineBoxOwner, index: Int): NativeInlineBoxOverlayGeometry? = null
    internal open val nativeInlineBoxCursorBounds: List<RectF> get() = emptyList()
    internal open fun nativeInlineBoxCursorAt(x: Float, y: Float, line: Int? = null): InlineCursor? = null
    internal open fun nativeInlineBoxRects(owner: NativeInlineBoxOwner, start: Int, end: Int,
        line: Int? = null): List<RectF>? = null
    internal open fun nativeInlineBoxHitTest(owner: NativeInlineBoxOwner, start: Int, end: Int): ((Float, Float) -> Boolean)? = null
    internal open fun nativeInlineBoxChildActionRects(owner: NativeInlineBoxOwner, start: Int, end: Int,
        childStart: Int, childEnd: Int, fragments: List<RectF>): List<RectF>? = null
    internal open fun nativeInlineActionRectsOnLine(owner: NativeInlineActionOwner, line: Int,
        start: Int, end: Int): List<RectF>? = null
    internal open fun paintInlineBoxContent(canvas: Canvas) = paint(canvas)
    internal open fun paintInlineBoxOverlays(canvas: Canvas, line: Int? = null) = Unit
    internal open fun paintInlineBoxLineContent(canvas: Canvas, line: Int) = paintRubyNativeLine(canvas, line)
    internal open fun nativeRubyGapAllocations(start: Int, end: Int): List<NativeRubyGapAllocation> =
        throw UnsupportedFloatLayout("Float image rows do not contain Ruby gap allocations")
    internal open fun validateRubyFloatBands() = Unit
    internal open fun nativeRubyColumnView(nativeStart: Int, column: NativeRubyColumn): FloatTextGeometry =
        throw UnsupportedFloatLayout("Float image rows do not contain Ruby columns")
    internal open fun nativeRubyReflowColumns(replacements: Map<Int, List<NativeRubyColumn>>,
        ends: List<Int>, advances: List<Float>): NativeFloatGeometry =
        throw UnsupportedFloatLayout("Float image rows cannot consume a Ruby column plan")
    internal open fun nativeRubyReflow(ends: List<Int>, advances: List<Float>): NativeFloatGeometry =
        throw UnsupportedFloatLayout("Float image rows retain their native LineBreaker plan")
    internal open fun nativeRubyTrimSourceSpaces(offsets: Set<Int>): NativeFloatGeometry =
        throw UnsupportedFloatLayout("Float image rows do not rewrite Ruby source spaces")
    internal open fun withRubyProjection(compiled: NativeRubyLayout,
        nodes: (NativeFloatGeometry) -> List<FloatInteractionNode> = { emptyList() },
        paintDecoration: (Canvas, NativeFloatGeometry) -> Unit = { _, _ -> },
        paintBounds: (NativeFloatGeometry) -> NativeFloatBounds? = { null }): NativeFloatGeometry =
        throw UnsupportedFloatLayout("Positioned inline images inside Ruby groups are unavailable")

    companion object {
        fun build(source: Spanned, paint: TextPaint, width: Int,
            occurrences: List<NativeFloatOccurrence>,
            alignment: Layout.Alignment = Layout.Alignment.ALIGN_NORMAL,
            textDirection: TextDirectionHeuristic = TextDirectionHeuristics.FIRSTSTRONG_LTR,
            lineSpacingExtra: Float = 0f, lineSpacingMultiplier: Float = 1f,
            requireDrainedAtBoundary: Boolean = false,
            carriedExclusions: List<NativeFloatExclusion> = emptyList(),
            nodeFactory: (NativeFloatGeometry) -> List<FloatInteractionNode> = { emptyList() },
            insets: NativeTextInsets = NativeTextInsets(),
            usedLineMetrics: ((start: Int, end: Int) -> NativeUsedLineMetrics)? = null,
            decoration: (Canvas, NativeFloatGeometry) -> Unit = { _, _ -> },
            decorationBounds: (NativeFloatGeometry) -> NativeFloatBounds? = { null },
            includeFontPadding: Boolean = true,
            rubyProbe: Boolean = false,
            inlineBoxProbe: Boolean = false,
            exactAvailableWidth: Float? = null,
            exactParagraphInsets: Boolean = false,
        ): NativeFloatGeometry {
            NativeClippedAbsoluteProjection.create(source)?.let { clipped ->
                return NativeClippedAbsoluteGeometry.build(clipped, paint, width, occurrences, alignment,
                    textDirection, lineSpacingExtra, lineSpacingMultiplier, requireDrainedAtBoundary,
                    carriedExclusions, nodeFactory, insets, usedLineMetrics, decoration, decorationBounds,
                    includeFontPadding, exactAvailableWidth, exactParagraphInsets)
            }
            return if (exactParagraphInsets && exactAvailableWidth == null) {
            throw UnsupportedFloatLayout("Exact paragraph gutters require an exact width without floats")
        } else if (exactParagraphInsets && source.isEmpty() &&
            source.getSpans(0, 0, NativeRubyPreparedSource::class.java).isNotEmpty()) {
            // A real source-empty rich owner has no fitting decisions. Keep its original
            // compiler/metrics and move its native zero-advance row to the exact lane.
            val exact = checkNotNull(exactAvailableWidth)
            if (!exact.isFinite() || exact < 0f || exact > TablePixelLimit || floor(exact).toInt() != width ||
                occurrences.isNotEmpty() || carriedExclusions.isNotEmpty())
                throw UnsupportedFloatLayout("Exact empty column lane requires an exact width without floats")
            fun gutter(first: Float, extra: Float): Float {
                val value = first.toDouble() + extra
                if (!value.isFinite() || value > TablePixelLimit)
                    throw UnsupportedFloatLayout("Exact paragraph gutter exceeds native geometry")
                return value.toFloat()
            }
            val left = gutter(insets.left, insets.extraLeft)
            val right = left + maxOf(0.0, exact.toDouble() - left - gutter(insets.right, insets.extraRight)).toFloat()
            val shaped = NativeStaticFloatGeometry.build(source, paint, width, emptyList(), alignment, textDirection,
                lineSpacingExtra, lineSpacingMultiplier, requireDrainedAtBoundary,
                usedLineMetrics = usedLineMetrics, includeFontPadding = includeFontPadding,
                rubyProbe = rubyProbe, inlineBoxProbe = inlineBoxProbe)
            shaped.withEmptyColumnLane(left, right, nodeFactory, decoration, decorationBounds)
        } else if ((exactAvailableWidth != null || nativeHasClippedParagraphDirection(source) || nativeHasAtomicInlineBoxes(source)) &&
            source.getSpans(0, source.length, NativeRubyPreparedSource::class.java).isNotEmpty()) {
            if (occurrences.isNotEmpty() || carriedExclusions.isNotEmpty() && !nativeHasAtomicInlineBoxes(source) || usedLineMetrics != null ||
                nativeHasPositionedInlineImages(source))
                throw UnsupportedFloatLayout("Exact rich rows require source-owned metrics without floats or positioned images")
            nativeRubyFloatGeometry(source, paint, width, exactAvailableWidth ?: width.toFloat(), alignment, textDirection,
                lineSpacingExtra, lineSpacingMultiplier, insets, includeFontPadding,
                exactParagraphInsets || (nativeHasClippedParagraphDirection(source) || nativeHasAtomicInlineBoxes(source)) && insets != NativeTextInsets(),
                nodeFactory, decoration, decorationBounds, carriedExclusions, requireDrainedAtBoundary)
        } else if (exactAvailableWidth != null || nativeHasPositionedInlineImages(source) || nativeHasClippedParagraphDirection(source) || nativeHasAtomicInlineBoxes(source)) {
            NativeFloatRowGeometry.build(source, paint, width, occurrences, alignment, textDirection,
                lineSpacingExtra, lineSpacingMultiplier, requireDrainedAtBoundary, carriedExclusions,
                nodeFactory, insets, usedLineMetrics, decoration, decorationBounds, includeFontPadding,
                exactAvailableWidth, exactParagraphInsets)
        } else NativeStaticFloatGeometry.build(source, paint, width, occurrences, alignment, textDirection,
            lineSpacingExtra, lineSpacingMultiplier, requireDrainedAtBoundary, carriedExclusions,
            nodeFactory, insets, usedLineMetrics, decoration, decorationBounds, includeFontPadding,
            rubyProbe, inlineBoxProbe)
        }
    }
}

private data class NativeEmptyColumnLane(val left: Float, val right: Float, val anchor: Float, val shift: Float)

private class NativeStaticFloatGeometry private constructor(
    override val text: CharSequence,
    override val width: Int,
    private val layout: StaticLayout,
    private val flow: Flow,
    private val nodeFactory: (NativeFloatGeometry) -> List<FloatInteractionNode>,
    private val decoration: (Canvas, NativeFloatGeometry) -> Unit,
    private val decorationBounds: (NativeFloatGeometry) -> NativeFloatBounds?,
    private val lineOrigins: FloatArray? = null,
    private val ruby: NativeRubyPlacedProjection? = null,
    private val inlineBox: NativeInlineBoxGeometry? = null,
    private val emptyColumnLane: NativeEmptyColumnLane? = null,
) : NativeFloatGeometry() {
    override val floats: List<PlacedNativeFloat> get() = ruby?.floats ?: flow.floats
    /** Includes inherited margin boxes; only [floats] belong to this segment's paint/nodes. */
    override val exclusions: List<NativeFloatExclusion> get() = flow.exclusions
    override val textBottom: Float get() = flow.bottom
    override val hasResidualFloats: Boolean get() = exclusions.any { it.outer.bottom > textBottom + 0.01f }
    override val height: Int = ceil(max(flow.bottom, exclusions.maxOfOrNull { it.outer.bottom } ?: 0f)).toInt()
    private val authoredBaselines = nativeInlineRanges(text as Spanned, NativeAuthoredBaselineShift::class.java)
        .filter { it.start < it.end }
    private val authoredMetrics = nativeInlineRanges(text as Spanned, NativeAuthoredInlineMetrics::class.java)
    private val authoredCursors = nativeInlineRanges(text as Spanned, NativeAuthoredCursor::class.java)
    private val alignedImages = nativeInlineRanges(text as Spanned, NativeAlignedImageSelection::class.java)
        .filter { it.start < it.end && it.value.nativeImageSelectionBounds != null }
    private val linePainter = NativeLinePainter(layout)
    private val citationFit = nativeHasCitationNoWrap(text as Spanned) &&
        text.getSpans(0, text.length, NativeRubyLinePlan::class.java).isNotEmpty()
    private fun horizontalOffset(line: Int, x: Float): Int = if (!citationFit)
        layout.getOffsetForHorizontal(line, x - originX(line)) else linePainter.getOffsetForHorizontal(line,
            x - linePainter.horizontalShift(NativeLinePaintPlacement(line, flow.baselines[line],
                flow.left[line], flow.right[line], originX(line))))
    override val nodes: List<FloatInteractionNode> = nodeFactory(this)
    private fun linePresent(line: Int): Boolean = flow.sourceLinePresent?.get(line) ?: true
    override val textBaselines: NativeTextBaselines? get() {
        if (flow.sourceLinePresent == null) return NativeTextBaselines(flow.baselines.first(), flow.baselines.last())
        val lines = flow.baselines.indices.filter(::linePresent)
        return NativeTextBaselines.of(lines.firstOrNull()?.let { flow.baselines[it] }, lines.lastOrNull()?.let { flow.baselines[it] })
    }
    override fun firstLineBand(): RectF {
        val line = flow.baselines.indices.firstOrNull(::linePresent) ?: return RectF()
        emptyColumnLane?.let { lane ->
            val column = lineOrigins?.get(line) ?: 0f
            return RectF(lane.left + column, flow.tops[line], lane.right + column, flow.bottoms[line])
        }
        return RectF(flow.left[line] + originX(line), flow.tops[line], width - flow.right[line] + originX(line), flow.bottoms[line])
    }

    /** The H owner's font content edge, before line-height half-leading or descendant ink. */
    override fun headingOwnerContentTop(): Float? {
        if (text.isEmpty() || nodes.count { it.kind == FloatInteractionKind.HEADING && it.start == 0 && it.end == text.length } != 1)
            return null
        val source = text as Spanned
        val owner = source.getSpans(0, text.length, NativeRunLineMetrics::class.java).singleOrNull {
            it.strut && source.getSpanStart(it) == 0 && source.getSpanEnd(it) > 0
        } ?: return null
        return (flow.baselines.first().toDouble() + owner.primary.ascent + owner.primary.baselineShift)
            .toFloat().takeIf { it.isFinite() }
    }

    override fun remainingExclusions(afterY: Float): List<NativeFloatExclusion> {
        require(afterY.isFinite() && afterY >= 0f)
        return exclusions.filter { it.outer.bottom > afterY }.map { it.copy(outer = it.outer.translated(0f, -afterY)) }
    }

    private val linePaintPositions = (0 until layout.lineCount).map { line ->
        NativeLinePaintPlacement(line, flow.baselines[line],
            flow.left[line], flow.right[line], originX(line))
    }
    private val paintedLinePositions get() = if (flow.sourceLinePresent == null) linePaintPositions
        else linePaintPositions.filter { linePresent(it.line) }
    private val selectableLineBounds by lazy { linePaintPositions.map {
        if (linePresent(it.line)) linePainter.selectableBounds(it) else null
    } }
    private fun hasAlignedImage(line: Int): Boolean = alignedImages.any {
        it.start < layout.getLineEnd(line) && it.end > layout.getLineStart(line)
    }
    private val selectableFragments by lazy {
        if (ruby != null) ruby.rects(0, text.length)
        else if (inlineBox != null) inlineBox.rectsForRange(0, text.length)
        else if (authoredBaselines.isNotEmpty()) rectsForRange(0, text.length)
        else selectableLineBounds.flatMapIndexed { line, bounds ->
            if (hasAlignedImage(line)) authoredRangeRects(layout.getLineStart(line), layout.getLineEnd(line))
            else listOfNotNull(bounds)
        }
    }

    /** Native glyph advances use each exact authored line box, not its ceil View allocation
     * or the taller font/selection ink. Floated replacements contribute their real margin boxes. */
    override val scrollableBounds: NativeFloatBounds by lazy {
        ruby?.let { return@lazy it.scrollableBounds }
        inlineBox?.let { return@lazy it.scrollableBounds }
        if (flow.sourceLinePresent?.none { it } == true) return@lazy NativeFloatBounds(0f, 0f, 0f, 0f)
        var bounds = NativeFloatBounds(0f, 0f, width.toFloat(), textBottom)
        selectableLineBounds.forEachIndexed { line, rect ->
            if (rect != null) bounds = bounds.enclosing(NativeFloatBounds(rect.left, flow.tops[line],
                rect.right, flow.bottoms[line]))
        }
        floats.forEach { placed -> bounds = bounds.enclosing(NativeFloatBounds(placed.outer.left,
            placed.outer.top, placed.outer.right, placed.outer.bottom)) }
        bounds
    }

    override val ordinaryPaintBounds: List<NativeFloatBounds> by lazy {
        ruby?.let { return@lazy it.ordinaryPaintBounds + listOfNotNull(decorationBounds(this)) }
        inlineBox?.let { return@lazy it.ordinaryPaintBounds + listOfNotNull(decorationBounds(this)) }
        listOfNotNull(nativeTextInkBounds(layout, paintedLinePositions),
            nativeBoundsOf(floats.map { it.content }), if (paintedLinePositions.isNotEmpty()) decorationBounds(this) else null)
    }
    override val extents: NativeGeometryExtents by lazy {
        val ink = ordinaryPaintBounds.fold(nativeFocusInk(nodes), ::enclosingBounds)
        val interaction = nativeBoundsOf(selectableFragments +
            nodes.flatMap { it.bounds } + nativeInlineBoxCursorBounds + ruby?.detachedCaretBounds().orEmpty() +
            listOf(caretRect(0), caretRect(text.length)))
        NativeGeometryExtents(width, height.toFloat(), ink, interaction)
    }

    override fun containsInteraction(x: Float, y: Float): Boolean =
        selectableFragments.any { it.contains(x, y) } || nativeInlineBoxCursorBounds.any { it.contains(x, y) } ||
            ruby?.detachedCaretBounds()?.any { it.contains(x, y) } == true ||
            nodes.any { node -> node.bounds.any { it.contains(x, y) } }

    override fun paint(canvas: Canvas) {
        ruby?.let {
            it.paintGapBackgrounds(canvas)
            it.raw.paintInlineBoxContent(canvas)
            it.paintGapDecorations(canvas)
            it.raw.paintInlineBoxOverlays(canvas)
            decoration(canvas, this)
            return
        }
        inlineBox?.let { it.paint(canvas); decoration(canvas, this); return }
        // Paint the complete shaped flow in one batch. A zero containing width or a short
        // line box must not clip its glyphs, and all native backgrounds precede the text.
        if (paintedLinePositions.isEmpty()) return
        linePainter.paint(canvas, paintedLinePositions)
        floats.forEach { it.occurrence.draw(canvas, RectF(it.content)) }
        decoration(canvas, this)
    }

    internal override fun paintInlineBoxContent(canvas: Canvas) {
        val box = inlineBox
        if (box == null) paint(canvas) else box.paint(canvas, includeOverlays = false)
    }
    internal override fun paintInlineBoxOverlays(canvas: Canvas, line: Int?) {
        inlineBox?.paintOverlays(canvas, line)
    }
    internal override fun paintInlineBoxLineContent(canvas: Canvas, line: Int) {
        val box = inlineBox
        if (box == null) paintRubyNativeLine(canvas, line) else box.paintLine(canvas, line, includeOverlays = false)
    }

    override fun offsetForPosition(x: Float, y: Float): Int {
        ruby?.let { return it.offset(x, y) }
        inlineBox?.let { return it.offsetForPosition(x, y) }
        floats.lastOrNull { it.content.contains(x, y) }?.let { return it.occurrence.offset }
        val line = lineForPosition(x, y)
        return horizontalOffset(line, x).coerceIn(0, text.length)
    }

    internal override fun baselineForOffset(offset: Int): Float {
        ruby?.let { return it.baseline(offset) }
        inlineBox?.let { return it.baselineForOffset(offset) }
        require(offset in 0..text.length)
        val line = layout.getLineForOffset(offset)
        return flow.baselines[line] + (authoredBaselineAt(offset)?.value?.shift ?: 0f)
    }

    override fun caretRect(offset: Int): RectF {
        ruby?.let { return it.caret(offset) }
        inlineBox?.let { return it.caretRect(offset) }
        require(offset in 0..text.length)
        val line = layout.getLineForOffset(offset)
        val x = if (!citationFit && emptyColumnLane == null) layout.getPrimaryHorizontal(offset) + originX(line) else
            linePainter.caretHorizontalOnLine(line, offset, NativeLinePaintPlacement(line,
                flow.baselines[line], flow.left[line], flow.right[line], originX(line)))
        if (!linePresent(line)) return RectF(x, flow.tops[line], x, flow.tops[line])
        if (text.isEmpty() && hasNativeAuthoredInlineMetrics(text))
            return RectF(x, flow.tops[line], x + 1f, flow.bottoms[line])
        alignedImages.firstOrNull { offset >= it.start && offset < it.end }
            ?.value?.nativeImageSelectionBounds?.let { own ->
                return RectF(x, flow.baselines[line] + own.top, x + 1f, flow.baselines[line] + own.bottom)
            }
        authoredSelectionMetrics(offset)?.let { own ->
            return RectF(x, flow.baselines[line] + own.top, x + 1f, flow.baselines[line] + own.bottom)
        }
        val shift = flow.baselines[line] - layout.getLineBaseline(line)
        return RectF(x, layout.getLineTop(line) + shift, x + 1f, layout.getLineBottom(line) + shift)
    }

    override fun caretRect(caret: NativeTextCaret): RectF {
        require(caret.offset in 0..text.length)
        ruby?.let { return it.caret(caret) }
        inlineBox?.let { return it.caretRect(caret) }
        return if (caret.affinity == NativeTextAffinity.Upstream && caret.offset > 0)
            checkNotNull(nativeRubyLineCaret(layout.getLineForOffset(caret.offset - 1), caret.offset))
        else caretRect(caret.offset)
    }
    override fun caretAt(x: Float, y: Float): NativeTextCaret {
        ruby?.let { return it.caretAt(x, y) }
        inlineBox?.let { return it.caretAt(x, y) }
        floats.lastOrNull { it.content.contains(x, y) }?.let { return NativeTextCaret(it.occurrence.offset) }
        val line = lineForPosition(x, y)
        val offset = horizontalOffset(line, x).coerceIn(0, text.length)
        return NativeTextCaret(offset, if (offset == layout.getLineEnd(line))
            NativeTextAffinity.Upstream else NativeTextAffinity.Downstream)
    }
    override fun visualCaret(caret: NativeTextCaret, direction: Int): NativeTextCaret =
        ruby?.visualCaret(caret, direction) ?: NativeTextCaret(visualOffset(caret.offset, direction))

    override fun visualOffset(offset: Int, direction: Int): Int {
        ruby?.let { return it.visualOffset(offset, direction) }
        require(offset in 0..text.length && direction in listOf(-1, 1))
        return if (direction < 0) layout.getOffsetToLeftOf(offset) else layout.getOffsetToRightOf(offset)
    }

    override fun visualLineRanges(offset: Int): List<Pair<Int, Int>> =
        ruby?.visualLineRanges(offset) ?: listOf(lineRange(offset))

    override fun lineRange(offset: Int): Pair<Int, Int> {
        ruby?.let { projection ->
            val fragments = projection.visualLineRanges(offset)
            return fragments.firstOrNull { offset >= it.first && offset < it.second }
                ?: fragments.lastOrNull { offset == it.second } ?: (offset to offset)
        }
        require(offset in 0..text.length)
        val line = layout.getLineForOffset(offset)
        return layout.getLineStart(line) to layout.getLineEnd(line)
    }

    override fun inlinePaddingGroupRects(owner: Span, start: Int, end: Int): List<RectF>? {
        require(start in 0..text.length && end in start..text.length)
        return ruby?.paddingRects(owner, start, end)
    }

    internal override fun nativeInlineBoxOverlay(owner: NativeInlineBoxOwner, index: Int): NativeInlineBoxOverlayGeometry? =
        inlineBox?.overlay(owner, index)

    override fun inlineBoxGroupRects(owner: NativeInlineBoxOwner, start: Int, end: Int): List<RectF>? {
        require(start in 0..text.length && end in start..text.length)
        return ruby?.boxRects(owner, start, end) ?: inlineBox?.boxRects(owner, start, end)
    }
    override fun inlineBoxGroupHitTest(owner: NativeInlineBoxOwner, start: Int, end: Int): ((Float, Float) -> Boolean)? {
        require(start in 0..text.length && end in start..text.length)
        return ruby?.boxHitTest(owner, start, end) ?: inlineBox?.boxHitTest(owner, start, end)
    }
    internal override fun nativeInlineBoxHitTest(owner: NativeInlineBoxOwner, start: Int, end: Int): ((Float, Float) -> Boolean)? =
        inlineBox?.boxHitTest(owner, start, end)
    override fun inlineBoxChildActionRects(owner: NativeInlineBoxOwner, start: Int, end: Int,
        childStart: Int, childEnd: Int, fragments: List<RectF>): List<RectF>? {
        require(start in 0..text.length && end in start..text.length && childStart in start..end && childEnd in childStart..end)
        return ruby?.boxChildActionRects(owner, start, end, childStart, childEnd, fragments)
            ?: inlineBox?.childActionRects(owner, start, end, childStart, childEnd, fragments)
    }
    internal override fun nativeInlineBoxRects(owner: NativeInlineBoxOwner, start: Int, end: Int,
        line: Int?): List<RectF>? = inlineBox?.boxRects(owner, start, end, line)
    internal override fun nativeInlineBoxChildActionRects(owner: NativeInlineBoxOwner, start: Int, end: Int,
        childStart: Int, childEnd: Int, fragments: List<RectF>): List<RectF>? =
        inlineBox?.childActionRects(owner, start, end, childStart, childEnd, fragments)
    internal override val nativeInlineBoxCursorBounds: List<RectF> get() = ruby?.raw?.nativeInlineBoxCursorBounds
        ?: inlineBox?.cursorBounds.orEmpty()
    internal override fun nativeInlineBoxCursorAt(x: Float, y: Float, line: Int?): InlineCursor? =
        inlineBox?.let { if (line == null) it.cursorAt(x, y) else it.cursorOnLine(line, x, y) }

    override fun inlineActionGroupRects(owner: NativeInlineActionOwner, start: Int, end: Int): List<RectF>? {
        require(start in 0..text.length && end in start..text.length)
        return ruby?.actionRects(owner, start, end)
    }
    internal override fun nativeInlineActionRectsOnLine(owner: NativeInlineActionOwner, line: Int,
        start: Int, end: Int): List<RectF>? {
        require(start in 0..text.length && end in start..text.length && line in 0 until layout.lineCount)
        return ruby?.actionRects(owner, start, end, line)
    }
    /** Exact native float contours, before selection regions are rasterized to integer rectangles. */
    internal override fun nativeInlineActionFragments(start: Int, end: Int): List<NativeInlineActionFragment> {
        require(ruby == null && start in 0..text.length && end in start..text.length)
        inlineBox?.let { return it.actionFragments(start, end, includeBoxes = true) }
        if (start == end) return emptyList()
        return buildList {
            for (line in layout.getLineForOffset(start)..layout.getLineForOffset(end - 1)) {
                if (!linePresent(line)) continue
                val first = maxOf(start, layout.getLineStart(line))
                val last = minOf(end, layout.getLineEnd(line))
                if (first >= last) continue
                val path = linePainter.selectionPathForRange(line, first, last)
                val bounds = RectF().also { path.computeBounds(it, true) }
                if (bounds.width() <= 0f) continue
                if (!bounds.height().isFinite() || bounds.height() <= 0f)
                    throw UnsupportedFloatLayout("Inline action selection has positive width without a native height")
                // A node factory can query during construction, before linePaintPositions exists.
                val position = NativeLinePaintPlacement(line, flow.baselines[line], flow.left[line], flow.right[line], originX(line))
                val shift = linePainter.horizontalShift(position)
                val scale = 1f / bounds.height()
                path.transform(Matrix().apply { setValues(floatArrayOf(
                    1f, 0f, shift, 0f, scale, -bounds.top * scale, 0f, 0f, 1f)) })
                add(NativeInlineActionFragment(line, first, last, path, flow.baselines[line]))
            }
        }
    }

    override fun rectsForRange(start: Int, end: Int): List<RectF> {
        ruby?.let { return it.rects(start, end) }
        inlineBox?.let { return it.rectsForRange(start, end) }
        require(start in 0..text.length && end in start..text.length)
        if (start == end) return emptyList()
        if (authoredBaselines.any { it.start < end && it.end > start } ||
            alignedImages.any { it.start < end && it.end > start }) return authoredRangeRects(start, end)
        return legacyRangeRects(start, end)
    }

    private fun legacyRangeRects(start: Int, end: Int, includeFloats: Boolean = true): List<RectF> {
        val path = Path()
        layout.getSelectionPath(start, end, path)
        val result = mutableListOf<RectF>()
        val selectionBounds = RectF()
        path.computeBounds(selectionBounds, true)
        val rect = Rect()
        for (line in layout.getLineForOffset(start)..layout.getLineForOffset(end - 1)) {
            if (!linePresent(line)) continue
            val top = layout.getLineTop(line)
            val region = Region()
            // Native selection paths already describe bidi runs and overflowing glyph advances.
            // The containing width is a line-breaking constraint, not an interaction clip.
            region.setPath(path, Region(floor(selectionBounds.left).toInt(), top,
                ceil(selectionBounds.right).toInt(), layout.getLineBottom(line)))
            val iterator = RegionIterator(region)
            while (iterator.next(rect)) result += RectF(rect).apply { offset(originX(line), flow.baselines[line] - layout.getLineBaseline(line)) }
        }
        if (includeFloats) floats.filter { it.occurrence.offset in start until end }.forEach { result += RectF(it.content) }
        return result
    }

    private fun authoredBaselineAt(offset: Int): NativeInlineRange<NativeAuthoredBaselineShift>? =
        authoredBaselines.firstOrNull { offset >= it.start && offset < it.end }
            ?: authoredBaselines.lastOrNull { offset == text.length && it.end == offset }

    private fun authoredSelectionMetrics(offset: Int): NativeUsedLineMetrics? {
        val shift = authoredBaselineAt(offset) ?: return null
        val owner = authoredMetrics.firstOrNull { it.start <= shift.start && it.end >= shift.end &&
            it.value.primary.baselineShift == shift.value.shift }?.value ?: return null
        // Integer Normal displacement keeps the platform's fallback-aware selection box.
        if (owner.policy == NativeLineHeightPolicy.Normal) return null
        return NativeUsedLineMetrics(owner.primary.ascent + shift.value.shift,
            owner.primary.descent + shift.value.shift)
    }

    private fun authoredRangeRects(start: Int, end: Int): List<RectF> = buildList {
        if (start == end) return@buildList
        for (line in layout.getLineForOffset(start)..layout.getLineForOffset(end - 1)) {
            if (!linePresent(line)) continue
            val first = maxOf(start, layout.getLineStart(line))
            val last = minOf(end, layout.getLineEnd(line))
            val cuts = (listOf(first, last) + authoredBaselines.flatMap {
                listOf(it.start.coerceIn(first, last), it.end.coerceIn(first, last))
            } + alignedImages.flatMap {
                listOf(it.start.coerceIn(first, last), it.end.coerceIn(first, last))
            }).distinct().sorted()
            for ((a, b) in cuts.zipWithNext()) {
                if (a == b) continue
                val image = alignedImages.firstOrNull { it.start == a && it.end == b }
                    ?.value?.nativeImageSelectionBounds
                if (image == null && alignedImages.isNotEmpty() &&
                    (authoredBaselines.isEmpty() || hasAlignedImage(line)) &&
                    authoredBaselines.none { it.start < b && it.end > a }) {
                    // Newly partitioned ordinary text keeps the original StaticLayout's
                    // indented fragments. The enclosing range appends each float once.
                    addAll(legacyRangeRects(a, b, includeFloats = false))
                    continue
                }
                val path = linePainter.selectionPathForRange(line, a, b)
                val bounds = RectF().also { path.computeBounds(it, true) }
                if (image != null) {
                    // A one-character replacement's native selection supplies its bidi X.
                    // Its occurrence metrics already include the image's baseline shift;
                    // authored text baseline effects cannot overlap a replacement span.
                    val x = bounds.left + linePainter.horizontalShift(NativeLinePaintPlacement(
                        line, flow.baselines[line], flow.left[line], flow.right[line], originX(line)))
                    if (!path.isEmpty) add(RectF(x + image.left, flow.baselines[line] + image.top,
                        x + image.right, flow.baselines[line] + image.bottom))
                    continue
                }
                val region = Region()
                region.setPath(path, Region(floor(bounds.left).toInt(), layout.getLineTop(line),
                    ceil(bounds.right).toInt(), layout.getLineBottom(line)))
                val iterator = RegionIterator(region)
                val rect = Rect()
                val own = authoredSelectionMetrics(a)
                while (iterator.next(rect)) {
                    add(RectF(rect).apply {
                        offset(originX(line), flow.baselines[line] - layout.getLineBaseline(line))
                        if (own != null) {
                            top = flow.baselines[line] + own.top
                            bottom = flow.baselines[line] + own.bottom
                        }
                    })
                }
            }
        }
        floats.filter { it.occurrence.offset in start until end }.forEach { add(RectF(it.content)) }
    }

    override fun characterRects(start: Int, length: Int): List<RectF?> {
        require(start in 0..text.length && length >= 0 && length <= text.length - start)
        return (start until start + length).map { offset ->
            // Accessibility indexes UTF-16; surrogate halves share a native box.
            val begin = if (offset > 0 && Character.isLowSurrogate(text[offset]) && Character.isHighSurrogate(text[offset - 1])) offset - 1 else offset
            val end = if (Character.isHighSurrogate(text[begin]) && begin + 1 < text.length && Character.isLowSurrogate(text[begin + 1])) begin + 2 else begin + 1
            rectsForRange(begin, end).reduceOrNull { a, b -> a.apply { union(b) } }
        }
    }

    override fun cursorAt(x: Float, y: Float): InlineCursor? {
        ruby?.let { return it.cursor(x, y) }
        inlineBox?.let { return it.cursorAt(x, y) }
        if (authoredCursors.isEmpty() || floats.any { it.content.contains(x, y) }) return null
        val line = exactSelectableLineAt(x, y) ?: return null
        val start = layout.getLineStart(line)
        val end = layout.getLineEnd(line)
        return authoredCursors.lastOrNull { owner ->
            val first = maxOf(start, owner.start)
            val last = minOf(end, owner.end)
            first < last && authoredRangeRects(first, last).any { it.contains(x, y) }
        }?.value?.cursor
    }

    private fun exactSelectableLineAt(x: Float, y: Float): Int? {
        // Later lines own only their native selectable advance. A narrower overlapping
        // line cannot hide an earlier line's exposed range; glyph ink holes do not matter.
        for (line in layout.lineCount - 1 downTo 0) {
            val hit = if (authoredBaselines.isEmpty() && !hasAlignedImage(line)) selectableLineBounds[line]?.contains(x, y) == true
                else authoredRangeRects(layout.getLineStart(line), layout.getLineEnd(line)).any { it.contains(x, y) }
            if (hit) return line
        }
        return null
    }

    private fun lineForPosition(x: Float, y: Float): Int {
        exactSelectableLineAt(x, y)?.let { return it }
        if (lineOrigins != null) return (0 until layout.lineCount).minBy { line ->
            val box = selectableLineBounds[line] ?: RectF(originX(line), flow.tops[line],
                originX(line) + width, flow.bottoms[line])
            val dx = maxOf(box.left - x, 0f, x - box.right).toDouble()
            val dy = maxOf(box.top - y, 0f, y - box.bottom).toDouble()
            dx * dx + dy * dy
        }
        // Outside every selectable range, retain normal vertical caret placement.
        var low = 0
        var high = layout.lineCount - 1
        while (low < high) {
            val mid = (low + high) / 2
            if (y < flow.bottoms[mid]) high = mid else low = mid + 1
        }
        return low
    }

    private fun originX(line: Int): Float = (lineOrigins?.get(line) ?: 0f) + (emptyColumnLane?.shift ?: 0f)
    internal override val hasColumnFragments: Boolean get() = lineOrigins != null
    internal override fun distanceForPosition(x: Float, y: Float): Double = ruby?.distance(x, y) ?: (0 until layout.lineCount).filter(::linePresent).minOfOrNull { line ->
        val box = selectableLineBounds[line] ?: RectF(originX(line), flow.tops[line],
            originX(line) + width, flow.bottoms[line])
        val dx = maxOf(box.left - x, 0f, x - box.right).toDouble()
        val dy = maxOf(box.top - y, 0f, y - box.bottom).toDouble()
        dx * dx + dy * dy
    } ?: Double.POSITIVE_INFINITY
    internal override val shapedLineCount: Int get() = layout.lineCount
    internal override fun usedLineHeight(line: Int): Float = flow.bottoms[line] - flow.tops[line]

    /** Reuse the original full-context native shaping and source offsets. Every geometry
     * consumer, including the node factory and marker painter, observes this same map. */
    internal override fun inColumns(origins: List<Pair<Float, Float>>): NativeFloatGeometry {
        ruby?.let { return it.raw.inColumns(origins).withRubyProjection(it.compiled, nodeFactory, decoration, decorationBounds) }
        if (inlineBox != null) throw UnsupportedFloatLayout("Inline box column redistribution is unavailable")
        require(origins.size == layout.lineCount)
        if (floats.isNotEmpty() || exclusions.isNotEmpty() || lineOrigins != null)
            throw UnsupportedFloatLayout("Column fragments require an unfragmented text owner without floats")
        val xs = FloatArray(origins.size)
        val tops = FloatArray(origins.size)
        val bottoms = FloatArray(origins.size)
        val baselines = FloatArray(origins.size)
        origins.forEachIndexed { line, (x, y) ->
            if (!x.isFinite() || !y.isFinite() || kotlin.math.abs(x) > TablePixelLimit ||
                kotlin.math.abs(y) > TablePixelLimit)
                throw UnsupportedFloatLayout("Column fragment exceeds native geometry")
            xs[line] = x
            tops[line] = y
            bottoms[line] = y + usedLineHeight(line)
            baselines[line] = y + flow.baselines[line] - flow.tops[line]
        }
        return NativeStaticFloatGeometry(text, width, layout,
            flow.copy(tops = tops, bottoms = bottoms, baselines = baselines,
                bottom = bottoms.maxOrNull() ?: 0f), nodeFactory, decoration, decorationBounds, xs,
            emptyColumnLane = emptyColumnLane)
    }

    /** Ruby keeps this native view private; all public owner queries use original UTF-16. */
    internal override val nativeRubyRaw: NativeFloatGeometry get() = ruby?.raw ?: this
    internal override val nativeRubyColumns: List<NativeRubyPiece.Column> get() =
        ruby?.compiled?.pieces?.filterIsInstance<NativeRubyPiece.Column>().orEmpty()
    internal override val nativeRubyCollapsedText: List<NativeRubyPiece.Text> get() =
        ruby?.compiled?.pieces?.filterIsInstance<NativeRubyPiece.Text>()?.filter { it.collapsed }.orEmpty()
    internal override val nativeRubyShapingSource: Spanned get() = layout.text as Spanned
    internal override val nativeRubyShapingPaint: TextPaint get() = TextPaint(layout.paint)
    internal override val nativeRubyParagraphDirection: Int get() = layout.getParagraphDirection(0)
    internal override fun nativeRubyRawOffset(publicOffset: Int): Int = ruby?.compiled?.nativeOffset(publicOffset) ?: publicOffset
    internal override fun nativeRubyLineSourceStart(line: Int): Int = layout.getLineStart(line)
    internal override fun nativeRubyLineAdvanceBounds(line: Int): RectF? = ruby?.raw?.nativeRubyLineAdvanceBounds(line)
        ?: inlineBox?.lineAdvanceBounds(line) ?: selectableLineBounds[line]?.let(::RectF)
    internal override fun nativeRubyLineBaseline(line: Int): Float = flow.baselines[line]
    internal override fun nativeRubyLineTop(line: Int): Float = flow.tops[line]
    internal override fun nativeRubyLineDirection(line: Int): Int = layout.getParagraphDirection(line)
    internal override fun nativeRubyLinePaintBounds(line: Int): List<NativeFloatBounds> {
        ruby?.let { return it.raw.nativeRubyLinePaintBounds(line) + it.gapPaintBounds(line) }
        inlineBox?.let { return it.linePaintBounds(line) }
        return if (linePresent(line)) listOfNotNull(nativeTextInkBounds(layout, listOf(linePaintPositions[line]))) else emptyList()
    }
    /** Horizontal allocation comes from this actual shaped line, before integer region rounding. */
    internal override fun nativeRubyGapAllocations(start: Int, end: Int): List<NativeRubyGapAllocation> {
        require(ruby == null && start in 0..text.length && end in start..text.length)
        if (start == end) return emptyList()
        return (layout.getLineForOffset(start)..layout.getLineForOffset(end - 1)).mapNotNull { line ->
            if (!linePresent(line)) return@mapNotNull null
            val first = maxOf(start, layout.getLineStart(line))
            val last = minOf(end, layout.getLineVisibleEnd(line))
            if (first >= last) return@mapNotNull null
            val path = linePainter.selectionPathForRange(line, first, last)
            val bounds = RectF().also { path.computeBounds(it, true) }
            val shift = linePainter.horizontalShift(linePaintPositions[line])
            if (bounds.width() <= 0f) null else NativeRubyGapAllocation(line,
                bounds.left + shift, bounds.right + shift, flow.baselines[line])
        }
    }
    internal override fun nativeRubyLineCaret(line: Int, publicOffset: Int): RectF? {
        ruby?.let { return it.caretOnLine(line, publicOffset) }
        inlineBox?.let { return it.caretOnLine(line, publicOffset) }
        if (publicOffset !in layout.getLineStart(line)..layout.getLineEnd(line)) return null
        val x = linePainter.caretHorizontalOnLine(line, publicOffset, linePaintPositions[line])
        if (!linePresent(line)) return RectF(x, flow.tops[line], x, flow.tops[line])
        val affinity = if (publicOffset == layout.getLineEnd(line) && publicOffset > layout.getLineStart(line))
            publicOffset - 1 else publicOffset
        val original = caretRect(affinity)
        return RectF(x, original.top, x + 1f, original.bottom)
    }
    override fun isHardLineBreak(offset: Int): Boolean = ruby?.isHardLineBreak(offset)
        ?: (text[offset] == '\n')
    internal override fun nativeRubyLineOffsetForPosition(line: Int, x: Float, y: Float): Int {
        ruby?.let { return it.offsetOnLine(line, x, y) }
        inlineBox?.let { return it.offsetOnLine(line, x, y) }
        return horizontalOffset(line, x).coerceIn(0, text.length)
    }
    internal override fun nativeRubyLineCursorAt(line: Int, x: Float, y: Float): InlineCursor? {
        ruby?.let { return it.cursorOnLine(line, x, y) }
        inlineBox?.let { return it.cursorOnLine(line, x, y) }
        return authoredCursors.lastOrNull { owner ->
            nativeRubyLineRects(line, owner.start, owner.end).any { it.contains(x, y) }
        }?.value?.cursor
    }
    /** Probe only the already-lowered private shaping buffer. The row planner
     * separately checks source policy; these are actual native fitted endpoints. */
    internal override fun nativeRubyEmergencyLineEnds(): Set<Int> {
        val source = SpannableString(layout.text)
        check(source.getSpans(0, source.length, NativeRubyPreparedSource::class.java).isEmpty())
        source.getSpans(0, source.length, NativeRubyLinePlan::class.java).forEach(source::removeSpan)
        if (source.getSpans(0, source.length, NativeAuthoredTextWrap::class.java).any { it.wrap == TextWrap.NoWrap })
            return emptySet()
        // Endpoint discovery must not run authored Normal's width-zero fitting
        // policy before the caller has selected its ordinary outcome. This is
        // the same initial full-source native fitter, without policy correction.
        val measured = PrecomputedText.create(source, (layout.text as PrecomputedText).params)
        val params = measured.params
        val hasRunMetrics = source.getSpans(0, source.length, NativeRunLineMetrics::class.java).isNotEmpty() ||
            hasNativeAuthoredInlineMetrics(source)
        val fitted = StaticLayout.Builder.obtain(measured, 0, measured.length, TextPaint(layout.paint), 0)
            .setAlignment(layout.alignment).setTextDirection(params.textDirection).setIncludePad(false)
            .setLineSpacing(layout.spacingAdd, layout.spacingMultiplier)
            .setUseLineSpacingFromFallbacks(hasRunMetrics)
            .setBreakStrategy(params.breakStrategy).setHyphenationFrequency(params.hyphenationFrequency)
            .build()
        return (0 until fitted.lineCount).map { fitted.getLineEnd(it) }
            .filter { it > 0 && it < source.length }.toSet()
    }
    internal override fun nativeRubyMeasuredAdvance(start: Int, end: Int): Float =
        (layout.text as PrecomputedText).getWidth(start, end).also {
            if (!it.isFinite() || it < 0f) throw UnsupportedFloatLayout("Ruby native advance is unavailable")
        }
    internal override fun nativeRubyAvailableAt(offset: Int, considerPreviousLine: Boolean): Float {
        val line = layout.getLineForOffset(offset)
        val start = layout.getLineStart(line)
        val before = nativeRubyMeasuredAdvance(start, offset)
        val available = (nativeLineAvailableWidth(line) - before).coerceAtLeast(0f)
        if (considerPreviousLine && line > 0 && before == 0f && start > 0 && layout.text[start - 1] != '\n') {
            val previousStart = layout.getLineStart(line - 1)
            val forced = (layout.text as Spanned).getSpans(previousStart, start, NativeRubyColumn::class.java)
                .any { it.continues }
            val remaining = nativeLineAvailableWidth(line - 1) - layout.getLineWidth(line - 1)
            if (!forced && remaining > 0f) return remaining
        }
        return available
    }
    internal override fun validateRubyFloatBands() {
        for (line in 0 until layout.lineCount) if (flow.constrainedByFloat[line] &&
            layout.getLineMax(line) > nativeLineAvailableWidth(line) + 1f)
            throw UnsupportedFloatLayout("Native ruby text exceeds the remaining float lane")
    }
    internal override fun nativeRubyColumnView(nativeStart: Int, column: NativeRubyColumn): FloatTextGeometry {
        val projection = ruby ?: throw UnsupportedFloatLayout("Ruby column lost its source projection")
        if (projection.compiled.pieces.filterIsInstance<NativeRubyPiece.Column>().none { it.nativeStart == nativeStart })
            throw UnsupportedFloatLayout("Ruby column lost its native occurrence")
        return NativeRubyColumnView(projection.compiled.source, nativeStart, column, projection.raw,
            projection.compiled.actionScopes)
    }
    internal override fun nativeRubyReflowColumns(replacements: Map<Int, List<NativeRubyColumn>>,
        ends: List<Int>, advances: List<Float>): NativeFloatGeometry {
        require(ends.isNotEmpty() && ends.size == advances.size)
        if (replacements.isEmpty()) return if (ends.size == 1) this else nativeRubyReflow(ends, advances)
        val projection = ruby ?: throw UnsupportedFloatLayout("Ruby fragments lost their original source map")
        val compiled = projection.compiled.replacingColumns(replacements)
        require(ends.last() == compiled.native.length)
        val source = SpannableString(compiled.native)
        source.setSpan(NativeRubyLinePlan(ends, advances), 0, source.length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        val shaped = build(source, layout.paint, width, emptyList(),
            textDirection = if (layout.getParagraphDirection(0) < 0) TextDirectionHeuristics.RTL else TextDirectionHeuristics.LTR,
            includeFontPadding = false)
        return reprojectRubyReflow(compiled, shaped)
    }
    internal override fun nativeRubyReflow(ends: List<Int>, advances: List<Float>): NativeFloatGeometry {
        require(ends.size == advances.size && ends.isNotEmpty() && ends.last() == layout.text.length)
        val source = SpannableString(layout.text)
        source.getSpans(0, source.length, NativeRubyLinePlan::class.java).forEach(source::removeSpan)
        source.setSpan(NativeRubyLinePlan(ends, advances), 0, source.length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        val shaped = build(source, layout.paint, width, emptyList(),
            textDirection = if (layout.getParagraphDirection(0) < 0) TextDirectionHeuristics.RTL else TextDirectionHeuristics.LTR,
            includeFontPadding = false)
        return ruby?.let { reprojectRubyReflow(it.compiled, shaped) } ?: shaped
    }
    internal override fun nativeRubyTrimSourceSpaces(offsets: Set<Int>): NativeFloatGeometry {
        val projection = ruby ?: return this
        val trimmed = projection.compiled.trimLineEdges(projection.raw, offsets) ?: return this
        val shaped = build(trimmed.native, layout.paint, width, emptyList(),
            textDirection = if (layout.getParagraphDirection(0) < 0) TextDirectionHeuristics.RTL else TextDirectionHeuristics.LTR,
            includeFontPadding = false)
        return shaped.withRubyProjection(trimmed)
    }
    private fun reprojectRubyReflow(compiled: NativeRubyLayout, shaped: NativeFloatGeometry): NativeFloatGeometry {
        val trimmed = compiled.trimLineEdges(shaped) ?: return shaped.withRubyProjection(compiled)
        val actual = build(trimmed.native, layout.paint, width, emptyList(),
            textDirection = if (layout.getParagraphDirection(0) < 0) TextDirectionHeuristics.RTL else TextDirectionHeuristics.LTR,
            includeFontPadding = false)
        return actual.withRubyProjection(trimmed)
    }
    internal override fun nativeRubyLineRects(line: Int, start: Int, end: Int): List<RectF> {
        ruby?.let { return it.rectsOnLine(line, start, end) }
        inlineBox?.let { return it.rectsOnLine(line, start, end) }
        require(start in 0..text.length && end in start..text.length)
        if (!linePresent(line)) return emptyList()
        val first = maxOf(start, layout.getLineStart(line))
        val last = minOf(end, layout.getLineEnd(line))
        if (first >= last) return emptyList()
        val cuts = (listOf(first, last) + authoredBaselines.flatMap {
            listOf(it.start.coerceIn(first, last), it.end.coerceIn(first, last))
        }).distinct().sorted()
        val position = linePaintPositions[line]
        return buildList {
            for ((a, b) in cuts.zipWithNext()) {
                val path = linePainter.selectionPathForRange(line, a, b)
                val bounds = RectF().also { path.computeBounds(it, true) }
                val region = Region().apply { setPath(path, Region(floor(bounds.left).toInt(),
                    layout.getLineTop(line), ceil(bounds.right).toInt(), layout.getLineBottom(line))) }
                val iterator = RegionIterator(region)
                val rect = Rect()
                val own = authoredSelectionMetrics(a)
                while (iterator.next(rect)) add(RectF(rect).apply {
                    offset(linePainter.horizontalShift(position), flow.baselines[line] - layout.getLineBaseline(line))
                    if (own != null) {
                        top = flow.baselines[line] + own.top
                        bottom = flow.baselines[line] + own.bottom
                    }
                })
            }
        }
    }
    internal override fun nativeRubyLineBaseText(line: Int): String = ruby?.baseTextOnLine(line)
        ?: layout.text.subSequence(layout.getLineStart(line), layout.getLineEnd(line)).toString()

    internal override fun nativeRubyLineRanges(line: Int): List<Pair<Int, Int>> = ruby?.lineRanges(line)
        ?: listOf(layout.getLineStart(line) to layout.getLineEnd(line))
    internal override fun paintRubyNativeLine(canvas: Canvas, line: Int) {
        ruby?.let {
            it.paintGapBackgrounds(canvas, line)
            it.raw.paintInlineBoxLineContent(canvas, line)
            it.paintGapDecorations(canvas, line)
            it.raw.paintInlineBoxOverlays(canvas, line)
            return
        }
        inlineBox?.let { it.paintLine(canvas, line); return }
        require(floats.isEmpty() && exclusions.isEmpty())
        if (linePresent(line)) linePainter.paint(canvas, listOf(linePaintPositions[line]))
    }
    internal override val nativeRubyAdvanceBounds: RectF? get() = ruby?.raw?.nativeRubyAdvanceBounds
        ?: inlineBox?.lineAdvanceBounds(0) ?: selectableLineBounds.firstOrNull()?.let(::RectF)
    internal override fun nativeLineAt(offset: Int): Int = layout.getLineForOffset(offset)
    internal override fun nativeRangeOfLine(line: Int): Pair<Int, Int> = layout.getLineStart(line) to layout.getLineEnd(line)
    internal override fun nativeInlineVisibleEnd(line: Int): Int = layout.getLineVisibleEnd(line)
    internal override fun nativeInlineVisibleAdvance(line: Int): Float = layout.getLineMax(line)
    internal override fun nativeInlineVisibleBounds(line: Int): RectF? {
        val first = layout.getLineStart(line); val last = layout.getLineVisibleEnd(line)
        if (first >= last) return null
        val path = linePainter.selectionPathForRange(line, first, last)
        if (path.isEmpty) return null
        return RectF().also { bounds ->
            path.computeBounds(bounds, true)
            bounds.offset(linePainter.horizontalShift(linePaintPositions[line]),
                flow.baselines[line] - layout.getLineBaseline(line))
        }
    }
    internal override fun nativeLineAvailableWidth(line: Int): Float = emptyColumnLane?.let { it.right - it.left }
        ?: (width - flow.left[line].toFloat() - flow.right[line])
    internal override fun nativeSingleLineAdvance(): Float {
        check(layout.lineCount == 1)
        return nativeLineAdvance(0)
    }
    internal override fun nativeLineAdvance(line: Int): Float = ruby?.raw?.nativeLineAdvance(line)
        ?: inlineBox?.lineAdvance(line) ?: layout.getLineWidth(line)
    internal override fun nativeUsedLineMetrics(line: Int): NativeUsedLineMetrics =
        NativeUsedLineMetrics(flow.tops[line] - flow.baselines[line], flow.bottoms[line] - flow.baselines[line])
    internal override fun nativeContentLineMetrics(line: Int): NativeUsedLineMetrics {
        val baseline = layout.getLineBaseline(line)
        var result = NativeUsedLineMetrics((layout.getLineTop(line) - baseline).toFloat(),
            (layout.getLineBottom(line) - baseline).toFloat())
        (layout.text as Spanned).getSpans(layout.getLineStart(line), layout.getLineEnd(line), NativeRubyColumn::class.java)
            .forEach { result = result.including(it.container) }
        return result
    }
    internal override fun nativeReplacementOrigin(offset: Int): Pair<Float, Float> {
        val line = layout.getLineForOffset(offset)
        emptyColumnLane?.let { return (it.anchor + (lineOrigins?.get(line) ?: 0f)) to flow.baselines[line] }
        val path = linePainter.selectionPathForRange(line, offset, offset + 1)
        val bounds = RectF().also { path.computeBounds(it, true) }
        return (bounds.left + linePainter.horizontalShift(NativeLinePaintPlacement(line,
            flow.baselines[line], flow.left[line], flow.right[line], originX(line)))) to flow.baselines[line]
    }
    internal override fun withRubyProjection(compiled: NativeRubyLayout,
        nodes: (NativeFloatGeometry) -> List<FloatInteractionNode>,
        paintDecoration: (Canvas, NativeFloatGeometry) -> Unit,
        paintBounds: (NativeFloatGeometry) -> NativeFloatBounds?): NativeFloatGeometry {
        check(ruby == null && text.toString() == compiled.native.toString())
        return NativeStaticFloatGeometry(compiled.source, width, layout, flow, nodes, paintDecoration,
            paintBounds, lineOrigins, compiled.placed(this), emptyColumnLane = emptyColumnLane)
    }

    /** Only a genuine public-empty owner may adjust a zero-advance native row.
     * The original compiled source, declaring metrics and native Y remain intact. */
    internal fun withEmptyColumnLane(left: Float, right: Float,
        nodes: (NativeFloatGeometry) -> List<FloatInteractionNode>,
        paintDecoration: (Canvas, NativeFloatGeometry) -> Unit,
        paintBounds: (NativeFloatGeometry) -> NativeFloatBounds?): NativeStaticFloatGeometry {
        val projected = ruby
        val owners = (text as Spanned).getSpans(0, text.length, NativeRubyPreparedSource::class.java)
        val actualOwner = owners.any { owner -> owner.projection.ranges.any {
            it.start == 0 && it.end == 0 && it.role in setOf(RubyTextRole.Owner, RubyTextRole.ActionGroup)
        } }
        val raw = projected?.raw as? NativeStaticFloatGeometry
        if (text.isNotEmpty() || !actualOwner || raw == null || layout.lineCount != 1 || !linePresent(0) ||
            floats.isNotEmpty() || exclusions.isNotEmpty() || lineOrigins != null || emptyColumnLane != null ||
            inlineBox != null || raw.inlineBox != null || layout.getLineWidth(0) != 0f || layout.getLineMax(0) != 0f ||
            nativeRubyColumns.any { it.column.advance != 0f } ||
            !left.isFinite() || !right.isFinite() || left < 0f || right < left || right > TablePixelLimit)
            throw UnsupportedFloatLayout("Exact empty column lane requires a source-empty zero-advance owner")
        val ltr = layout.getParagraphDirection(0) == 1
        val anchor = when (layout.getParagraphAlignment(0)) {
            Layout.Alignment.ALIGN_NORMAL -> if (ltr) left else right
            Layout.Alignment.ALIGN_OPPOSITE -> if (ltr) right else left
            Layout.Alignment.ALIGN_CENTER -> left + (right - left) / 2f
            else -> throw UnsupportedFloatLayout("Exact empty column alignment is unavailable")
        }
        val oldAnchor = raw.linePainter.caretHorizontalOnLine(0, layout.getLineStart(0), raw.linePaintPositions[0])
        val lane = NativeEmptyColumnLane(left, right, anchor, anchor - oldAnchor)
        val placedRaw = NativeStaticFloatGeometry(raw.text, raw.width, raw.layout, raw.flow,
            { emptyList() }, { _, _ -> }, { null }, emptyColumnLane = lane)
        return placedRaw.withRubyProjection(checkNotNull(projected).compiled, nodes, paintDecoration, paintBounds) as NativeStaticFloatGeometry
    }

    companion object {
        fun build(
            source: Spanned, paint: TextPaint, width: Int,
            occurrences: List<NativeFloatOccurrence>,
            alignment: Layout.Alignment = Layout.Alignment.ALIGN_NORMAL,
            textDirection: TextDirectionHeuristic = TextDirectionHeuristics.FIRSTSTRONG_LTR,
            lineSpacingExtra: Float = 0f, lineSpacingMultiplier: Float = 1f,
            requireDrainedAtBoundary: Boolean = false,
            carriedExclusions: List<NativeFloatExclusion> = emptyList(),
            nodeFactory: (NativeFloatGeometry) -> List<FloatInteractionNode> = { emptyList() },
            insets: NativeTextInsets = NativeTextInsets(),
            usedLineMetrics: ((start: Int, end: Int) -> NativeUsedLineMetrics)? = null,
            decoration: (Canvas, NativeFloatGeometry) -> Unit = { _, _ -> },
            decorationBounds: (NativeFloatGeometry) -> NativeFloatBounds? = { null },
            includeFontPadding: Boolean = true,
            rubyProbe: Boolean = false,
            inlineBoxProbe: Boolean = false,
        ): NativeStaticFloatGeometry {
            require(width >= 0 && width <= Int.MAX_VALUE / 4)
            require(lineSpacingExtra.isFinite() && lineSpacingExtra >= 0f)
            require(lineSpacingMultiplier.isFinite() && lineSpacingMultiplier > 0f)
            require(occurrences.map { it.sourceId }.distinct().size == occurrences.size)
            require(occurrences.map { it.offset }.distinct().size == occurrences.size)
            carriedExclusions.forEach { exclusion ->
                val box = exclusion.outer
                if (listOf(box.left, box.top, box.right, box.bottom).any { kotlin.math.abs(it) > Int.MAX_VALUE / 4 }) {
                    throw UnsupportedFloatLayout("Carried float exceeds native geometry")
                }
            }
            if (source.getSpans(0, source.length, NativeRubyPreparedSource::class.java).isNotEmpty()) {
                if (usedLineMetrics != null)
                    throw UnsupportedFloatLayout("Ruby needs source-owned metrics rather than an external single-range callback")
                val available = (width - ceil((insets.left + insets.extraLeft).toDouble()).toFloat() -
                    ceil((insets.right + insets.extraRight).toDouble()).toFloat()).coerceAtLeast(0f)
                var bands = NativeRubyBands(available)
                val seenBands = mutableSetOf<Map<NativeRubyFragmentKey, Float>>()
                repeat(64) {
                    if (!seenBands.add(bands.observed))
                        throw UnsupportedFloatLayout("Ruby fragment and native float bands cycle")
                    var compiled = checkNotNull(nativeRubyLayout(source, paint, textDirection, bands))
                    val nativeOccurrences = occurrences.map { it.copy(offset = compiled.nativeOffset(it.offset)) }
                    var raw = build(compiled.native, paint, width, nativeOccurrences, alignment, textDirection,
                        lineSpacingExtra, lineSpacingMultiplier, requireDrainedAtBoundary, carriedExclusions,
                        insets = insets, includeFontPadding = includeFontPadding, rubyProbe = true)
                    compiled.trimLineEdges(raw)?.let { trimmed ->
                        compiled = trimmed
                        raw = build(trimmed.native, paint, width, nativeOccurrences, alignment, textDirection,
                            lineSpacingExtra, lineSpacingMultiplier, requireDrainedAtBoundary, carriedExclusions,
                            insets = insets, includeFontPadding = includeFontPadding, rubyProbe = true)
                    }
                    val observed = compiled.observedBands(raw)
                    if (observed.all { (key, value) -> bands.widthAt(key) == value }) {
                        raw.validateRubyFloatBands()
                        return raw.withRubyProjection(compiled, nodeFactory, decoration, decorationBounds) as NativeStaticFloatGeometry
                    }
                    bands = NativeRubyBands(available, bands.observed + observed)
                }
                throw UnsupportedFloatLayout("Ruby fragments did not converge with native float bands")
            }
            if (!inlineBoxProbe && (source.getSpans(0, source.length, NativeInlineBoxSpan::class.java).isNotEmpty() ||
                    nativeHasCitationNoWrap(source))) {
                if (occurrences.isNotEmpty() || carriedExclusions.isNotEmpty())
                    throw UnsupportedFloatLayout("Inline box float exclusions are unavailable")
                if (usedLineMetrics != null)
                    throw UnsupportedFloatLayout("Inline box needs its declared source metrics")
                val bounded = nativeInlineBoxBoundedSource(source) { at ->
                    nativeInlineBoxParagraphRtl(source, textDirection, at)
                }
                val widths = NativeInlineBoxWidths(bounded, paint, textDirection)
                val left = ceil((insets.left + insets.extraLeft).toDouble()).toFloat()
                val right = width - ceil((insets.right + insets.extraRight).toDouble()).toFloat()
                val spans = nativeInlineRanges(bounded, NativeInlineBoxSpan::class.java)
                val allocated = spans.any { it.value.box.leftAdvance > 0f || it.value.box.rightAdvance > 0f }
                val fit = if (allocated || nativeHasCitationNoWrap(bounded))
                    widths.fit((right - left).coerceAtLeast(0f)) else null
                val fitting = SpannableString(bounded)
                if (fit != null) {
                    fitting.getSpans(0, fitting.length, NativeRubyLinePlan::class.java).forEach(fitting::removeSpan)
                    fitting.setSpan(NativeRubyLinePlan(fit.ends, fit.advances, allowEmptyTerminal = source.last() == '\n'),
                        0, fitting.length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
                }
                var raw = build(fitting, paint, width, emptyList(), alignment, textDirection,
                    lineSpacingExtra, lineSpacingMultiplier, requireDrainedAtBoundary, emptyList(),
                    insets = insets, includeFontPadding = includeFontPadding, rubyProbe = rubyProbe, inlineBoxProbe = true)
                NativeTextWrapPlan.create(bounded, paint)?.validateResult(raw.layout)
                if (spans.isEmpty()) return NativeStaticFloatGeometry(raw.text, width, raw.layout, raw.flow,
                    nodeFactory, decoration, decorationBounds)
                val overflow = fit?.overflowingStarts ?: (0 until raw.shapedLineCount).filter {
                    raw.nativeInlineVisibleAdvance(it) > (right - left).coerceAtLeast(0f)
                }.map { raw.nativeRangeOfLine(it).first }.toSet()
                val firstPadding = if (includeFontPadding) maxOf(0f, -raw.layout.topPadding.toFloat()) else 0f
                val lastPadding = if (includeFontPadding) maxOf(0f, raw.layout.bottomPadding.toFloat()) else 0f
                val bottom = nativeInlineBottomLines(raw, spans, paint, firstPadding, lastPadding)
                if (bottom != null) {
                    if (lineSpacingExtra != 0f || lineSpacingMultiplier != 1f)
                        throw UnsupportedFloatLayout("Bottom inline owners require ordinary paragraph line spacing")
                    // Native font padding surrounds the logical row bands. It does
                    // not become an alignment target for a bottom participant.
                    var y = firstPadding
                    val tops = FloatArray(bottom.size)
                    val bottoms = FloatArray(bottom.size)
                    val baselines = FloatArray(bottom.size)
                    bottom.forEachIndexed { line, placed ->
                        tops[line] = y
                        baselines[line] = nativeInlineBoxCoordinate(y.toDouble() - placed.metrics.top)
                        y = nativeInlineBoxCoordinate(y.toDouble() + placed.metrics.height)
                        bottoms[line] = y
                    }
                    raw = NativeStaticFloatGeometry(raw.text, width, raw.layout,
                        raw.flow.copy(tops = tops, bottoms = bottoms, baselines = baselines,
                            bottom = nativeInlineBoxCoordinate(y.toDouble() + lastPadding)),
                        raw.nodeFactory, raw.decoration, raw.decorationBounds)
                }
                val box = NativeInlineBoxGeometry(raw, spans, alignment, left, right, overflow, bottom)
                return NativeStaticFloatGeometry(raw.text, width, raw.layout, raw.flow, nodeFactory, decoration,
                    decorationBounds, inlineBox = box)
            }
            validateNativeInlineStyle(source, paint)
            val original = SpannedString(source)
            val wrapPlan = NativeTextWrapPlan.create(original, paint)
            wrapPlan?.noWrap?.requireLinePresence()
            if (wrapPlan?.noWrap != null && (occurrences.isNotEmpty() || carriedExclusions.isNotEmpty()))
                throw UnsupportedFloatLayout("No-wrap source cannot inherit or establish float exclusions")
            val hasRunMetrics = original.getSpans(0, original.length, NativeRunLineMetrics::class.java).isNotEmpty() ||
                hasNativeAuthoredInlineMetrics(original)
            val native = SpannableString(original)
            val ordered = occurrences.sortedBy { it.offset }
            ordered.forEach {
                require(it.offset < source.length && source[it.offset] == '\ufffc') { "Float must refer to its original object character" }
                require(source.getSpans(it.offset, it.offset + 1, ReplacementSpan::class.java).isEmpty()) { "Float marker already has an inline replacement" }
                native.setSpan(FloatMarker(), it.offset, it.offset + 1, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
            }
            val measured = PrecomputedText.create(native, PrecomputedText.Params.Builder(TextPaint(paint))
                .setTextDirection(textDirection).setBreakStrategy(android.graphics.text.LineBreaker.BREAK_STRATEGY_SIMPLE)
                .setHyphenationFrequency(Layout.HYPHENATION_FREQUENCY_NONE).build())
            val rubyLinePlan = original.getSpans(0, original.length, NativeRubyLinePlan::class.java).singleOrNull()
            val rubyFragments = NativeRubyFragmentLines(original)
            val rubyIndents = rubyLinePlan?.indents(width, textDirection.isRtl(measured, 0, measured.length))
            var left = rubyIndents?.first ?: intArrayOf(0)
            var right = rubyIndents?.second ?: intArrayOf(0)
            val seen = mutableSetOf<List<Int>>()
            repeat(64) {
                val signature = left.toList() + listOf(-1) + right.toList()
                if (!seen.add(signature)) throw UnsupportedFloatLayout("Float line exclusions cycle")
                val nativeLayout = StaticLayout.Builder.obtain(measured, 0, measured.length, TextPaint(paint), width)
                    .setAlignment(alignment).setTextDirection(textDirection).setIncludePad(includeFontPadding)
                    .setLineSpacing(lineSpacingExtra, lineSpacingMultiplier)
                    .setUseLineSpacingFromFallbacks(hasRunMetrics)
                    .setBreakStrategy(android.graphics.text.LineBreaker.BREAK_STRATEGY_SIMPLE)
                    .setHyphenationFrequency(Layout.HYPHENATION_FREQUENCY_NONE)
                    .setIndents(left, right).build()
                val flow = position(nativeLayout, width, ordered, carriedExclusions, insets, usedLineMetrics,
                    wrapPlan?.noWrap?.let { plan -> { start -> plan.hasLineAt(start) } })
                val fit = if (rubyLinePlan == null) rubyFragments.fit(nativeLayout, measured, flow.left, flow.right,
                    wrapPlan?.fit(nativeLayout, measured, flow.left, flow.right,
                        if (rubyProbe) BooleanArray(flow.constrainedByFloat.size) else flow.constrainedByFloat)) else rubyIndents
                val nextLeft = fit?.first ?: flow.left
                val nextRight = fit?.second ?: flow.right
                if (left.contentEquals(nextLeft) && right.contentEquals(nextRight)) {
                    if (rubyLinePlan != null) rubyLinePlan.validate(nativeLayout)
                    else wrapPlan?.validateResult(nativeLayout)
                    rubyFragments.validate(nativeLayout)
                    for (line in 0 until nativeLayout.lineCount) {
                        if (!rubyProbe && flow.constrainedByFloat[line] &&
                            nativeLayout.getLineMax(line) > width - flow.left[line] - flow.right[line] + 1f) {
                            throw UnsupportedFloatLayout("Native text exceeds the remaining float lane")
                        }
                    }
                    if (requireDrainedAtBoundary && flow.exclusions.any { it.outer.bottom > flow.bottom + 0.01f }) {
                        throw UnsupportedFloatLayout("Active float crosses an unsupported formatting boundary")
                    }
                    return NativeStaticFloatGeometry(original, width, nativeLayout, flow, nodeFactory, decoration, decorationBounds)
                }
                left = nextLeft
                right = nextRight
            }
            throw UnsupportedFloatLayout("Float exclusions did not converge after 64 native layouts")
        }
    }
}

private class FloatMarker : ReplacementSpan(), NativeReplacementPaintBounds {
    override fun nativePaintBounds(lineTop: Float, lineBottom: Float): NativeFloatBounds? = null
    override fun getSize(paint: Paint, text: CharSequence, start: Int, end: Int, fm: Paint.FontMetricsInt?): Int = 0
    override fun draw(canvas: Canvas, text: CharSequence, start: Int, end: Int, x: Float, top: Int, y: Int, bottom: Int, paint: Paint) = Unit
}

internal data class NativeFloatFlow(
    val tops: FloatArray, val bottoms: FloatArray, val baselines: FloatArray,
    val left: IntArray, val right: IntArray,
    val floats: List<PlacedNativeFloat>, val exclusions: List<NativeFloatExclusion>, val bottom: Float,
    val constrainedByFloat: BooleanArray,
    val sourceLinePresent: BooleanArray? = null,
)

private typealias Flow = NativeFloatFlow

private fun position(layout: StaticLayout, width: Int, occurrences: List<NativeFloatOccurrence>,
    carriedExclusions: List<NativeFloatExclusion>, insets: NativeTextInsets,
    usedLineMetrics: ((Int, Int) -> NativeUsedLineMetrics)?, sourceLinePresent: ((Int) -> Boolean)? = null): Flow = nativePositionFloatRows(layout.text as Spanned, width,
    IntArray(layout.lineCount) { layout.getLineStart(it) },
    IntArray(layout.lineCount) { layout.getLineEnd(it) },
    List(layout.lineCount) { line ->
        val baseline = layout.getLineBaseline(line)
        NativeUsedLineMetrics((layout.getLineTop(line) - baseline).toFloat(),
            (layout.getLineBottom(line) - baseline).toFloat())
    }, occurrences, carriedExclusions, insets, usedLineMetrics, sourceLinePresent)

internal fun nativePositionFloatRows(source: Spanned, width: Int, starts: IntArray, ends: IntArray,
    naturalMetrics: List<NativeUsedLineMetrics>, occurrences: List<NativeFloatOccurrence>,
    carriedExclusions: List<NativeFloatExclusion>, insets: NativeTextInsets,
    usedLineMetrics: ((Int, Int) -> NativeUsedLineMetrics)?, sourceLinePresent: ((Int) -> Boolean)? = null,
    exactAvailableWidth: Float? = null, requiredLineWidths: FloatArray? = null): NativeFloatFlow {
    require(starts.size == ends.size && naturalMetrics.size == starts.size)
    val availableWidth = exactAvailableWidth ?: width.toFloat()
    if (exactAvailableWidth != null && (!availableWidth.isFinite() || availableWidth < 0f ||
            availableWidth > TablePixelLimit || kotlin.math.floor(availableWidth).toInt() != width))
        throw UnsupportedFloatLayout("Exact Float row width exceeds native geometry")
    if (requiredLineWidths != null && (requiredLineWidths.size != starts.size ||
            requiredLineWidths.any { !it.isFinite() || it < 0f || it > TablePixelLimit }))
        throw UnsupportedFloatLayout("Required native row widths exceed native geometry")
    fun lineAt(offset: Int): Int {
        val found = starts.binarySearch(offset)
        return (if (found >= 0) found else -found - 2).coerceIn(0, starts.lastIndex)
    }
    val tops = FloatArray(starts.size)
    val bottoms = FloatArray(starts.size)
    val baselines = FloatArray(starts.size)
    // StaticLayout repeats its last indent; always terminate exclusions with zero.
    val left = IntArray(starts.size + 1)
    val right = IntArray(starts.size + 1)
    val constrainedByFloat = BooleanArray(starts.size)
    val present = sourceLinePresent?.let { owns -> BooleanArray(starts.size) { owns(starts[it]) } }
    val placed = mutableListOf<PlacedNativeFloat>()
    val exclusions = carriedExclusions.toMutableList()
    val anchors = occurrences.groupBy { lineAt(it.offset) }
    var y = 0f
    for (line in 0 until starts.size) {
        if (present?.get(line) == false) {
            tops[line] = y
            bottoms[line] = y
            baselines[line] = y
            continue
        }
        val natural = naturalMetrics[line]
        val ordinaryMetrics = usedLineMetrics?.invoke(starts[line], ends[line])
            ?: nativeRunLineMetrics(source, starts[line], ends[line], natural,
                pointOnLine = { offset -> lineAt(offset) == line })
            ?: natural
        val metrics = nativeRubyLineMetrics(source, starts[line],
            ends[line], ordinaryMetrics)
        val lineHeight = metrics.height
        for (occurrence in anchors[line].orEmpty()) {
            val clearBottom = exclusions.filter { previous ->
                when (occurrence.clear) {
                    NativeFloatClear.None -> false
                    NativeFloatClear.Left -> previous.side == TableFloatSide.Left
                    NativeFloatClear.Right -> previous.side == TableFloatSide.Right
                    NativeFloatClear.Both -> true
                }
            }.maxOfOrNull { it.outer.bottom } ?: y
            // CSS 2.2 9.5.2 constraint 10 applies to the float's outer top;
            // moving y here would incorrectly clear earlier and following text.
            var floatY = max(max(y, clearBottom), exclusions.maxOfOrNull { it.outer.top } ?: 0f)
            val outerWidth = occurrence.width + occurrence.margins.left + occurrence.margins.right
            val outerHeight = occurrence.height + occurrence.margins.top + occurrence.margins.bottom
            var x: Float
            while (true) {
                val overlap = exclusions.filter { it.outer.top < floatY + outerHeight && it.outer.bottom > floatY }
                val occupiedLeft = overlap.filter { it.side == TableFloatSide.Left }.maxOfOrNull { it.outer.right } ?: 0f
                val occupiedRight = overlap.filter { it.side == TableFloatSide.Right }.minOfOrNull { it.outer.left } ?: availableWidth
                if (outerWidth <= occupiedRight - occupiedLeft || overlap.isEmpty()) {
                    x = if (occurrence.side == TableFloatSide.Left) occupiedLeft else occupiedRight - outerWidth
                    break
                }
                floatY = overlap.minOf { it.outer.bottom }
            }
            if (!(floatY + outerHeight).isFinite() || floatY + outerHeight > Int.MAX_VALUE / 4) {
                throw UnsupportedFloatLayout("Float context exceeds native geometry")
            }
            val outer = RectF(x, floatY, x + outerWidth, floatY + outerHeight)
            val content = RectF(x + occurrence.margins.left, floatY + occurrence.margins.top,
                x + occurrence.margins.left + occurrence.width, floatY + occurrence.margins.top + occurrence.height)
            placed += PlacedNativeFloat(occurrence, outer, content)
            exclusions += NativeFloatExclusion(occurrence.side, NativeFloatBounds(outer.left, outer.top, outer.right, outer.bottom))
        }
        while (true) {
            val overlap = exclusions.filter {
                (if (lineHeight == 0f) it.outer.top <= y else it.outer.top < y + lineHeight) && it.outer.bottom > y
            }
            val l = nativeLineIndent(max(insets.left, overlap.filter { it.side == TableFloatSide.Left }.maxOfOrNull { it.outer.right } ?: 0f) + insets.extraLeft)
            val r = nativeLineIndent(max(insets.right, availableWidth - (overlap.filter { it.side == TableFloatSide.Right }.minOfOrNull { it.outer.left } ?: availableWidth)) + insets.extraRight)
            // Native line breaking clamps the signed remaining width to zero, while drawing keeps
            // the real indents. Permanent authored gutters can overflow; temporary floats still
            // move a line below their margin boxes when they leave no available line width.
            val hasWidth = if (exactAvailableWidth == null) l + r < width
                else l.toDouble() + r < availableWidth.toDouble()
            // Only an authenticated indivisible row supplies this requirement. Ordinary
            // wrapping rows must rebreak against the new lane instead of moving wholesale.
            val fitsRequired = requiredLineWidths?.get(line)?.let {
                it.toDouble() <= availableWidth.toDouble() - l - r
            } ?: true
            if (overlap.isEmpty() || (hasWidth && fitsRequired)) {
                left[line] = l
                right[line] = r
                constrainedByFloat[line] = overlap.isNotEmpty()
                break
            }
            y = overlap.minOf { it.outer.bottom }
        }
        tops[line] = y
        baselines[line] = y - metrics.top
        if (!baselines[line].isFinite() || kotlin.math.abs(baselines[line]) > Int.MAX_VALUE / 4)
            throw UnsupportedFloatLayout("Native baseline exceeds the geometry range")
        y += lineHeight
        if (!y.isFinite() || y > Int.MAX_VALUE / 4) throw UnsupportedFloatLayout("Float context exceeds native geometry")
        bottoms[line] = y
    }
    return Flow(tops, bottoms, baselines, left, right, placed, exclusions, y, constrainedByFloat, present)
}

private fun nativeLineIndent(value: Float): Int {
    if (!value.isFinite() || value < 0f || value > Int.MAX_VALUE / 4f)
        throw UnsupportedFloatLayout("Native text gutter exceeds the coordinate range")
    return ceil(value).toInt()
}
