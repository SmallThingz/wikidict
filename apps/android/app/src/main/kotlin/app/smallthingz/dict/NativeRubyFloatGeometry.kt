package app.smallthingz.dict

import android.graphics.Canvas
import android.graphics.RectF
import android.text.Layout
import android.text.SpannableString
import android.text.Spanned
import android.text.TextDirectionHeuristic
import android.text.TextPaint

/** The existing ruby source projection over exact native glyph/replacement rows. */
internal class NativeRubyFloatGeometry(
    private val compiled: NativeRubyLayout,
    private val raw: NativeFloatGeometry,
    private val nodeFactory: (NativeFloatGeometry) -> List<FloatInteractionNode>,
    private val decoration: (Canvas, NativeFloatGeometry) -> Unit,
    private val decorationBounds: (NativeFloatGeometry) -> NativeFloatBounds?,
) : NativeFloatGeometry() {
    private val projection = compiled.placed(raw)
    override val text: CharSequence get() = compiled.source
    override val width: Int get() = raw.width
    override val height: Int get() = raw.height
    override val floats get() = projection.floats
    override val exclusions get() = raw.exclusions
    override val textBottom get() = raw.textBottom
    override val hasResidualFloats get() = raw.hasResidualFloats
    override val textBaselines get() = raw.textBaselines
    override val nodes = nodeFactory(this)
    override val scrollableBounds get() = projection.scrollableBounds
    override val ordinaryPaintBounds get() = projection.ordinaryPaintBounds + listOfNotNull(decorationBounds(this))
    override val extents: NativeGeometryExtents get() = NativeGeometryExtents(width, height.toFloat(),
        ordinaryPaintBounds.fold(nativeFocusInk(nodes), ::enclosingBounds),
        nativeBoundsOf(rectsForRange(0, text.length) + nodes.flatMap { it.bounds } + listOf(caretRect(0), caretRect(text.length))))
    override fun firstLineBand() = raw.firstLineBand()
    override fun headingOwnerContentTop(): Float? {
        if (text.isEmpty() || nodes.count { it.kind == FloatInteractionKind.HEADING &&
                it.start == 0 && it.end == text.length } != 1) return null
        val owner = compiled.source.getSpans(0, text.length, NativeRunLineMetrics::class.java).singleOrNull {
            it.strut && compiled.source.getSpanStart(it) == 0 && compiled.source.getSpanEnd(it) > 0
        } ?: return null
        return (raw.nativeRubyLineBaseline(0).toDouble() + owner.primary.ascent + owner.primary.baselineShift)
            .toFloat().takeIf { it.isFinite() }
    }
    override fun remainingExclusions(afterY: Float) = raw.remainingExclusions(afterY)
    override fun paint(canvas: Canvas) {
        projection.paintGapBackgrounds(canvas)
        raw.paint(canvas)
        projection.paintGapDecorations(canvas)
        decoration(canvas, this)
    }
    override fun offsetForPosition(x: Float, y: Float) = projection.offset(x, y)
    override fun rectsForRange(start: Int, end: Int) = projection.rects(start, end)
    override fun caretRect(offset: Int) = projection.caret(offset)
    override fun cursorAt(x: Float, y: Float) = projection.cursor(x, y)
    override fun visualOffset(offset: Int, direction: Int) = projection.visualOffset(offset, direction)
    override fun visualLineRanges(offset: Int) = projection.visualLineRanges(offset)
    override fun isHardLineBreak(offset: Int) = projection.isHardLineBreak(offset)
    override fun lineRange(offset: Int): Pair<Int, Int> {
        val fragments = projection.visualLineRanges(offset)
        return fragments.firstOrNull { offset >= it.first && offset < it.second }
            ?: fragments.lastOrNull { offset == it.second } ?: (offset to offset)
    }
    override fun characterRects(start: Int, length: Int): List<RectF?> {
        require(start in 0..text.length && length >= 0 && length <= text.length - start)
        return (start until start + length).map { at ->
            val first = if (at > 0 && Character.isLowSurrogate(text[at]) && Character.isHighSurrogate(text[at - 1])) at - 1 else at
            val end = if (Character.isHighSurrogate(text[first]) && first + 1 < text.length && Character.isLowSurrogate(text[first + 1])) first + 2 else first + 1
            rectsForRange(first, end).reduceOrNull { a, b -> a.apply { union(b) } }
        }
    }
    override fun inlinePaddingGroupRects(owner: Span, start: Int, end: Int) = projection.paddingRects(owner, start, end)
    override fun inlineActionGroupRects(owner: NativeInlineActionOwner, start: Int, end: Int) = projection.actionRects(owner, start, end)
    override fun inlineBoxGroupRects(owner: NativeInlineBoxOwner, start: Int, end: Int) = projection.boxRects(owner, start, end)
    override fun inlineBoxGroupHitTest(owner: NativeInlineBoxOwner, start: Int, end: Int) = projection.boxHitTest(owner, start, end)
    override fun inlineBoxChildActionRects(owner: NativeInlineBoxOwner, start: Int, end: Int,
        childStart: Int, childEnd: Int, fragments: List<RectF>) = projection.boxChildActionRects(owner, start, end, childStart, childEnd, fragments)
    internal override fun nativeInlineActionRectsOnLine(owner: NativeInlineActionOwner, line: Int, start: Int, end: Int) =
        projection.actionRects(owner, start, end, line)
    internal override fun baselineForOffset(offset: Int) = projection.baseline(offset)
    internal override fun distanceForPosition(x: Float, y: Float) = projection.distance(x, y)
    internal override val shapedLineCount get() = raw.shapedLineCount
    internal override fun usedLineHeight(line: Int) = raw.usedLineHeight(line)
    internal override val hasColumnFragments get() = raw.hasColumnFragments
    internal override fun inColumns(origins: List<Pair<Float, Float>>) =
        raw.inColumns(origins).withRubyProjection(compiled, nodeFactory, decoration, decorationBounds)
    internal override val nativeRubyExactAdvances get() = true
    internal override val nativeRubyRaw get() = raw
    internal override val nativeRubyColumns get() = compiled.pieces.filterIsInstance<NativeRubyPiece.Column>()
    internal override val nativeRubyCollapsedText get() = compiled.pieces.filterIsInstance<NativeRubyPiece.Text>().filter { it.collapsed }
    internal override fun nativeRubyRawOffset(publicOffset: Int) = compiled.nativeOffset(publicOffset)
    internal override val nativeRubyShapingSource get() = raw.nativeRubyShapingSource
    internal override val nativeRubyShapingPaint get() = raw.nativeRubyShapingPaint
    internal override val nativeRubyParagraphDirection get() = raw.nativeRubyParagraphDirection
    internal override fun nativeRubyLineSourceStart(line: Int) = raw.nativeRubyLineSourceStart(line)
    internal override fun nativeRubyLineAdvanceBounds(line: Int) = raw.nativeRubyLineAdvanceBounds(line)
    internal override fun nativeRubyLineBaseline(line: Int) = raw.nativeRubyLineBaseline(line)
    internal override fun nativeRubyLineTop(line: Int) = raw.nativeRubyLineTop(line)
    internal override fun nativeRubyLineDirection(line: Int) = raw.nativeRubyLineDirection(line)
    internal override fun nativeRubyLinePaintBounds(line: Int) = raw.nativeRubyLinePaintBounds(line) + projection.gapPaintBounds(line)
    internal override fun nativeRubyLineCaret(line: Int, publicOffset: Int) = projection.caretOnLine(line, publicOffset)
    internal override fun nativeRubyLineOffsetForPosition(line: Int, x: Float, y: Float) = projection.offsetOnLine(line, x, y)
    internal override fun nativeRubyLineCursorAt(line: Int, x: Float, y: Float) = projection.cursorOnLine(line, x, y)
    internal override fun nativeRubyEmergencyLineEnds() = raw.nativeRubyEmergencyLineEnds()
    internal override fun nativeRubyMeasuredAdvance(start: Int, end: Int) = raw.nativeRubyMeasuredAdvance(start, end)
    internal override fun nativeRubyAvailableAt(offset: Int, considerPreviousLine: Boolean) = raw.nativeRubyAvailableAt(offset, considerPreviousLine)
    internal override fun nativeRubyLineRects(line: Int, start: Int, end: Int) = projection.rectsOnLine(line, start, end)
    internal override fun nativeRubyLineBaseText(line: Int) = projection.baseTextOnLine(line)
    internal override fun nativeRubyLineRanges(line: Int) = projection.lineRanges(line)
    internal override fun paintRubyNativeLine(canvas: Canvas, line: Int) {
        projection.paintGapBackgrounds(canvas, line)
        raw.paintRubyNativeLine(canvas, line)
        projection.paintGapDecorations(canvas, line)
    }
    internal override val nativeRubyAdvanceBounds get() = raw.nativeRubyAdvanceBounds
    internal override fun nativeLineAt(offset: Int) = raw.nativeLineAt(offset)
    internal override fun nativeRangeOfLine(line: Int) = raw.nativeRangeOfLine(line)
    internal override fun nativeInlineVisibleEnd(line: Int) = raw.nativeInlineVisibleEnd(line)
    internal override fun nativeInlineVisibleAdvance(line: Int) = raw.nativeInlineVisibleAdvance(line)
    internal override fun nativeInlineVisibleBounds(line: Int) = raw.nativeInlineVisibleBounds(line)
    internal override fun nativeLineAvailableWidth(line: Int) = raw.nativeLineAvailableWidth(line)
    internal override fun nativeSingleLineAdvance() = raw.nativeSingleLineAdvance()
    internal override fun nativeLineAdvance(line: Int) = raw.nativeLineAdvance(line)
    internal override fun nativeUsedLineMetrics(line: Int) = raw.nativeUsedLineMetrics(line)
    internal override fun nativeContentLineMetrics(line: Int) = raw.nativeContentLineMetrics(line)
    internal override fun nativeReplacementOrigin(offset: Int) = raw.nativeReplacementOrigin(offset)
    internal override fun nativeInlineActionFragments(start: Int, end: Int) = raw.nativeInlineActionFragments(start, end)
    internal override fun nativeRubyColumnView(nativeStart: Int, column: NativeRubyColumn): FloatTextGeometry {
        if (nativeRubyColumns.none { it.nativeStart == nativeStart })
            throw UnsupportedFloatLayout("Exact ruby column lost its source occurrence")
        return NativeRubyColumnView(compiled.source, nativeStart, column, raw, compiled.actionScopes)
    }
    private fun reproject(next: NativeRubyLayout, shape: NativeFloatGeometry): NativeFloatGeometry {
        val trimmed = next.trimLineEdges(shape)
        val actual = if (trimmed == null) shape else (shape as NativeFloatRowGeometry).rebuilding(trimmed.native)
        return actual.withRubyProjection(trimmed ?: next, nodeFactory, decoration, decorationBounds)
    }
    internal override fun nativeRubyReflow(ends: List<Int>, advances: List<Float>) =
        reproject(compiled, raw.nativeRubyReflow(ends, advances))
    internal override fun nativeRubyReflowColumns(replacements: Map<Int, List<NativeRubyColumn>>,
        ends: List<Int>, advances: List<Float>): NativeFloatGeometry {
        if (replacements.isEmpty()) return if (ends.size == 1) this else nativeRubyReflow(ends, advances)
        val next = compiled.replacingColumns(replacements)
        val source = SpannableString(next.native)
        source.getSpans(0, source.length, NativeRubyLinePlan::class.java).forEach(source::removeSpan)
        source.setSpan(NativeRubyLinePlan(ends, advances), 0, source.length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        return reproject(next, (raw as NativeFloatRowGeometry).rebuilding(source))
    }
    internal override fun nativeRubyTrimSourceSpaces(offsets: Set<Int>): NativeFloatGeometry {
        val trimmed = compiled.trimLineEdges(raw, offsets) ?: return this
        return (raw as NativeFloatRowGeometry).rebuilding(trimmed.native)
            .withRubyProjection(trimmed, nodeFactory, decoration, decorationBounds)
    }
}

internal fun nativeRubyFloatGeometry(source: Spanned, paint: TextPaint, width: Int,
    exactWidth: Float, alignment: Layout.Alignment, direction: TextDirectionHeuristic,
    lineSpacingExtra: Float, lineSpacingMultiplier: Float, insets: NativeTextInsets,
    includeFontPadding: Boolean, exactParagraphInsets: Boolean,
    nodeFactory: (NativeFloatGeometry) -> List<FloatInteractionNode>,
    decoration: (Canvas, NativeFloatGeometry) -> Unit,
    decorationBounds: (NativeFloatGeometry) -> NativeFloatBounds?): NativeFloatGeometry {
    val left = if (exactParagraphInsets) insets.left + insets.extraLeft else kotlin.math.ceil(insets.left + insets.extraLeft)
    val right = if (exactParagraphInsets) insets.right + insets.extraRight else kotlin.math.ceil(insets.right + insets.extraRight)
    val available = (exactWidth - left - right).coerceAtLeast(0f)
    var bands = NativeRubyBands(available)
    val seen = mutableSetOf<Map<NativeRubyFragmentKey, Float>>()
    fun shape(value: Spanned) = NativeFloatRowGeometry.build(value, paint, width, emptyList(), alignment,
        direction, lineSpacingExtra, lineSpacingMultiplier, false, emptyList(), { emptyList() },
        insets, null, { _, _ -> }, { null }, includeFontPadding, exactWidth, exactParagraphInsets)
    repeat(64) {
        if (!seen.add(bands.observed)) throw UnsupportedFloatLayout("Exact ruby fragment bands cycle")
        var compiled = checkNotNull(nativeRubyLayout(source, paint, direction, bands, exactAdvances = true))
        var raw = shape(compiled.native)
        compiled.trimLineEdges(raw)?.let { trimmed -> compiled = trimmed; raw = shape(trimmed.native) }
        val observed = compiled.observedBands(raw)
        if (observed.all { (key, value) -> bands.widthAt(key) == value })
            return raw.withRubyProjection(compiled, nodeFactory, decoration, decorationBounds)
        bands = NativeRubyBands(available, bands.observed + observed)
    }
    throw UnsupportedFloatLayout("Exact ruby fragments did not converge")
}
