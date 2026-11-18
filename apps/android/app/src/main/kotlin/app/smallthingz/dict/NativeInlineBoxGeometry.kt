package app.smallthingz.dict

import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Path
import android.graphics.RectF
import android.text.Layout

/** One selected full-source native layout, with source-boundary advances only.
 * Vertical edges are paint overflow: they never replace the native used line band. */
internal class NativeInlineBoxGeometry(
    private val raw: NativeFloatGeometry,
    spans: List<NativeInlineRange<NativeInlineBoxSpan>>,
    private val alignment: Layout.Alignment,
    private val left: Float,
    private val right: Float,
    allowedOverflowStarts: Set<Int>,
) : FloatTextGeometry {
    private val spans = spans.toList()
    override val text: CharSequence get() = raw.text
    override val width: Int get() = raw.width
    override val height: Int get() = raw.height
    override val textBaselines: NativeTextBaselines? get() = raw.textBaselines
    override val nodes: List<FloatInteractionNode> = emptyList()

    private data class VisualFragment(val first: Int, val last: Int, val left: Float, val right: Float,
        val leftPiece: NativeInlineRunPiece, val rightPiece: NativeInlineRunPiece)
    private data class Edge(val owner: NativeInlineRange<NativeInlineBoxSpan>, val leftSide: Boolean,
        val increment: NativeInlineBoundaryIncrement)
    private data class Line(val mapped: NativeInlineMappedLine, val advance: Float, val bounds: RectF)
    private data class Fragment(val owner: NativeInlineRange<NativeInlineBoxSpan>, val line: Int,
        val first: Int, val last: Int, val content: RectF, val padding: RectF, val border: RectF,
        val painter: NativeInlineBoxBorderPaint)
    private data class Owner(val range: NativeInlineRange<NativeInlineBoxSpan>, val fragments: List<Fragment>,
        val decoration: NativeInlineActionPaint, val overlays: List<NativeInlineBoxBorderPaint>,
        val overlayLine: Int)
    private val lines: List<Line>
    private val owners: List<Owner>
    private val fragments: List<Fragment>
    private val nestingParents: List<Int>
    private val spanIndices = this.spans.withIndex().associate { it.value to it.index }
    private val nestedChildren: Map<Int, Int>
    private val rounded: Map<Fragment, NativeInlineBoxCurvePaint>
    private val cursors = nativeInlineRanges(raw.nativeRubyShapingSource, NativeAuthoredCursor::class.java)

    private fun coordinate(value: Double) = nativeInlineBoxCoordinate(value)
    private fun rectangle(l: Float, t: Float, r: Float, b: Float): RectF {
        nativeInlineBoxCoordinates(l, t, r, b)
        if (r < l || b < t) throw UnsupportedFloatLayout("Inline box has reversed native geometry")
        return RectF(l, t, r, b)
    }
    private fun visual(pieces: List<NativeInlineRunPiece>): List<VisualFragment> {
        val unique = pieces.filter { it.right > it.left }.distinctBy {
            listOf(it.start, it.end, it.rtl, it.left, it.right)
        }.sortedWith(compareBy({ it.left }, { it.right }, { it.start }, { it.end }))
        val result = mutableListOf<VisualFragment>()
        for (piece in unique) {
            val previous = result.lastOrNull()
            if (previous != null && piece.left <= previous.right) {
                result[result.lastIndex] = previous.copy(first = minOf(previous.first, piece.start),
                    last = maxOf(previous.last, piece.end), right = maxOf(previous.right, piece.right),
                    rightPiece = if (piece.right > previous.right) piece else previous.rightPiece)
            } else result += VisualFragment(piece.start, piece.end, piece.left, piece.right, piece, piece)
        }
        return result
    }
    private fun edge(capture: NativeInlineLineCapture, fragment: VisualFragment, leftSide: Boolean): NativeInlineBoundary {
        val piece = if (leftSide) fragment.leftPiece else fragment.rightPiece
        val atStart = leftSide != piece.rtl
        return capture.boundary(if (atStart) piece.start else piece.end,
            if (atStart) NativeInlineBoundaryAffinity.Following else NativeInlineBoundaryAffinity.Preceding)
    }
    private fun ownerRtl(range: NativeInlineRange<NativeInlineBoxSpan>, line: Int): Boolean =
        range.value.parentRtl ?: (raw.nativeRubyLineDirection(line) < 0)
    private fun firstLine(range: NativeInlineRange<NativeInlineBoxSpan>): Int = raw.nativeLineAt(range.start)
    private fun lastLine(range: NativeInlineRange<NativeInlineBoxSpan>): Int = raw.nativeLineAt(range.end - 1)
    private fun selectedOwner(owner: NativeInlineBoxOwner, start: Int, end: Int): Owner? =
        owners.singleOrNull { it.range.value.box.owner === owner && it.range.start == start && it.range.end == end }

    init {
        nativeInlineBoxCoordinates(left, right)
        if (right < left || raw.nativeRubyRaw !== raw || raw.hasColumnFragments || raw.floats.isNotEmpty() || raw.exclusions.isNotEmpty())
            throw UnsupportedFloatLayout("Inline boxes require an ordinary unfragmented native paragraph")
        if (this.spans.isEmpty()) throw UnsupportedFloatLayout("Inline box source metadata is unavailable")
        this.spans.forEach { range ->
            if (range.start !in text.indices || range.end <= range.start || range.end > text.length)
                throw UnsupportedFloatLayout("Inline box requires a nonempty source interval")
            if ((range.start until range.end).any { at ->
                    val c = text[at]
                    c == '\n' || c == '\r' || c == '\t' || c == '\uFFFC' ||
                        android.icu.lang.UCharacter.hasBinaryProperty(c.code, android.icu.lang.UProperty.BIDI_CONTROL)
                }) throw UnsupportedFloatLayout("Inline box body contains unsupported native controls")
        }
        nestingParents = nativeInlineBoxNesting(this.spans) { range -> ownerRtl(range, firstLine(range)) }
        nestedChildren = nestingParents.withIndex().filter { it.value >= 0 }.associate { it.value to it.index }
        if (this.spans.map { it.value.box.owner }.distinct().size != this.spans.size)
            throw UnsupportedFloatLayout("Inline box owner lost its original occurrence")
        val source = raw.nativeRubyShapingSource
        val required = nativeInlineBoxRequiredBreaks(source) { at -> raw.nativeRubyLineDirection(raw.nativeLineAt(at)) < 0 }
        val builtFragments = mutableListOf<Fragment>()
        lines = (0 until raw.shapedLineCount).map { line ->
            val (start, end) = raw.nativeRangeOfLine(line)
            val active = this.spans.filter { it.start < end && it.end > start }
            if (active.any { raw.nativeRubyMeasuredAdvance(maxOf(start, it.start), minOf(end, it.end)) == 0f })
                throw UnsupportedFloatLayout("Inline box zero-advance fragment allocation is unavailable")
            val cuts = active.flatMap { listOf(maxOf(start, it.start), minOf(end, it.end)) }
            val capture = nativeInlineLineCapture(raw, line, cuts, required)
            val edges = mutableListOf<Edge>()
            for (owner in active) {
                val captured = capture.piecesForRange(maxOf(start, owner.start), minOf(end, owner.end))
                val ownerIndex = spanIndices.getValue(owner)
                if ((nestingParents[ownerIndex] >= 0 || nestedChildren.containsKey(ownerIndex)) && captured.any { it.rtl })
                    throw UnsupportedFloatLayout("Nested inline decoration requires actual LTR native runs")
                val parts = visual(captured)
                if (parts.isEmpty()) throw UnsupportedFloatLayout("Inline box zero-advance fragment allocation is unavailable")
                val rtl = ownerRtl(owner, line)
                fun addEdge(leftSide: Boolean, amount: Float, fragment: VisualFragment, sourceBoundary: Int) {
                    if (amount == 0f) return
                    val token = edge(capture, fragment, leftSide)
                    val bothEdges = owner.value.box.leftAdvance > 0f && owner.value.box.rightAdvance > 0f
                    val originalCut = if (bothEdges) token.offset == owner.start || token.offset == owner.end
                        else token.offset == sourceBoundary
                    if (!originalCut || token.offset !in required)
                        throw UnsupportedFloatLayout("Inline box edge shaping affinity is unavailable")
                    edges += Edge(owner, leftSide, NativeInlineBoundaryIncrement(token, amount))
                }
                if (line == firstLine(owner)) addEdge(!rtl,
                    if (rtl) owner.value.box.rightAdvance else owner.value.box.leftAdvance,
                    if (rtl) parts.last() else parts.first(), owner.start)
                if (line == lastLine(owner)) addEdge(rtl,
                    if (rtl) owner.value.box.leftAdvance else owner.value.box.rightAdvance,
                    if (rtl) parts.first() else parts.last(), owner.end)
            }
            // At a shared physical boundary, the preceding box's end precedes the
            // following box's start regardless of the source's bidi traversal order.
            val orderedEdges = edges.sortedWith(compareBy({ it.increment.boundary.x }, { if (it.leftSide) 1 else 0 }))
            val added = orderedEdges.fold(0.0) { sum, item -> sum + item.increment.pixels }
            val advance = coordinate(raw.nativeInlineVisibleAdvance(line).toDouble() + added)
            if (advance > right - left && start !in allowedOverflowStarts)
                throw UnsupportedFloatLayout("Inline box exceeds its selected native line")
            val originalLeft = raw.nativeInlineVisibleBounds(line)?.left
                ?: raw.nativeRubyLineCaret(line, start)?.left
                ?: throw UnsupportedFloatLayout("Inline box line has no native origin")
            val ltr = raw.nativeRubyLineDirection(line) > 0
            val alignedLeft = when (alignment) {
                Layout.Alignment.ALIGN_NORMAL -> if (ltr) left else coordinate(right.toDouble() - advance)
                Layout.Alignment.ALIGN_OPPOSITE -> if (ltr) coordinate(right.toDouble() - advance) else left
                Layout.Alignment.ALIGN_CENTER -> coordinate((left.toDouble() + right - advance) / 2.0)
                else -> throw UnsupportedFloatLayout("Inline box paragraph alignment is unavailable")
            }
            val mapped = capture.mapped(orderedEdges.map { it.increment }, coordinate(alignedLeft.toDouble() - originalLeft))
            val advanceBounds = mapped.advanceBounds()
            if (start !in allowedOverflowStarts && (advanceBounds.left < left || advanceBounds.right > right))
                throw UnsupportedFloatLayout("Inline box mapped advance exceeds its selected native line")
            for (owner in active) {
                val value = owner.value
                val box = value.box
                val primary = NativePrimaryFontMetrics.from(value.format.paint)
                val baseline = coordinate(mapped.baseline.toDouble() + value.shift)
                val top = coordinate(baseline.toDouble() + primary.ascent)
                val bottom = coordinate(baseline.toDouble() + primary.descent)
                val ownPieces = mapped.piecesForRange(maxOf(start, owner.start), minOf(end, owner.end))
                val ownerIndex = spanIndices.getValue(owner)
                val childIndex = nestedChildren[ownerIndex]
                // Child edges are real in-flow allocation, including at a wrapped row endpoint.
                // They extend only the ancestor decoration; source glyph/caret pieces stay exact.
                val childEdges = if (childIndex == null) emptyList() else orderedEdges.filter {
                    it.owner === this.spans[childIndex]
                }.map { edge ->
                    val placed = mapped.placedEdges.single { it.increment === edge.increment }
                    val at = edge.increment.boundary.offset
                    NativeInlineRunPiece(at, at, false, placed.left, placed.right, -1)
                }
                val parts = visual(ownPieces + childEdges)
                val rtl = ownerRtl(owner, line)
                parts.forEachIndexed { index, part ->
                    val hasLeft = (line == firstLine(owner) && !rtl && index == 0) ||
                        (line == lastLine(owner) && rtl && index == 0)
                    val hasRight = (line == firstLine(owner) && rtl && index == parts.lastIndex) ||
                        (line == lastLine(owner) && !rtl && index == parts.lastIndex)
                    val content = rectangle(part.left, top, part.right, bottom)
                    fun placed(leftSide: Boolean): NativeInlinePlacedEdge? = mapped.placedEdges.singleOrNull { candidate ->
                        orderedEdges.any { it.owner === owner && it.leftSide == leftSide && it.increment === candidate.increment }
                    }
                    val borderLeft = if (hasLeft && box.leftAdvance > 0f) placed(true)?.left
                        ?: throw UnsupportedFloatLayout("Inline box lost its left edge allocation") else part.left
                    val borderRight = if (hasRight && box.rightAdvance > 0f) placed(false)?.right
                        ?: throw UnsupportedFloatLayout("Inline box lost its right edge allocation") else part.right
                    val sideLeft = if (hasLeft) box.border.left else NativeInlineBoxBorder(0f, null)
                    val sideRight = if (hasRight) box.border.right else NativeInlineBoxBorder(0f, null)
                    val padding = rectangle(coordinate(borderLeft.toDouble() + sideLeft.width),
                        coordinate(top.toDouble() - box.padding.top),
                        coordinate(borderRight.toDouble() - sideRight.width), coordinate(bottom.toDouble() + box.padding.bottom))
                    val border = rectangle(borderLeft, coordinate(padding.top.toDouble() - box.border.top.width),
                        borderRight, coordinate(padding.bottom.toDouble() + box.border.bottom.width))
                    val sides = NativeInlineBoxBorders(box.border.top, sideRight, box.border.bottom, sideLeft)
                    builtFragments += Fragment(owner, line, part.first, part.last, content, padding, border,
                        NativeInlineBoxBorderPaint(border, sides))
                }
            }
            Line(mapped, coordinate(advanceBounds.right.toDouble() - advanceBounds.left), advanceBounds)
        }
        fragments = builtFragments.toList()
        val roundedFragments = mutableMapOf<Fragment, NativeInlineBoxCurvePaint>()
        owners = this.spans.map { range ->
            val own = fragments.filter { it.owner === range }
            range.value.box.radius?.takeIf { it > 0f || range.value.box.border.top.dotted }?.let { radius ->
                val rtl = ownerRtl(range, firstLine(range))
                val visualOrder = own.groupBy { it.line }.toSortedMap().values.flatMap {
                    if (rtl) it.asReversed() else it
                }
                val box = range.value.box
                if (!box.radiusPercentage && !box.border.top.dotted) {
                    val slices = nativeInlineBoxCornerSlices(visualOrder.map(::boxBounds), rtl, radius,
                        box.border.top.width)
                    visualOrder.zip(slices).forEach { (fragment, slice) ->
                        roundedFragments[fragment] = NativeInlineBoxRoundPaint(slice)
                    }
                } else {
                    val slices = nativeInlineBoxEllipseSlices(visualOrder.map(::boxBounds), rtl, radius,
                        box.radiusPercentage, box.border.top.width)
                    val decorations = mutableMapOf<NativeInlineBoxEllipseShape, NativeInlineBoxEllipseDecoration>()
                    visualOrder.zip(slices).forEach { (fragment, slice) ->
                        roundedFragments[fragment] = decorations.getOrPut(slice.shape) {
                            NativeInlineBoxEllipseDecoration(slice.shape, box.border.top.dotted)
                        }.slice(slice)
                    }
                }
            }
            val first = own.filter { it.line == firstLine(range) }.let { if (ownerRtl(range, firstLine(range))) it.last() else it.first() }
            val last = own.filter { it.line == lastLine(range) }.let { if (ownerRtl(range, lastLine(range))) it.first() else it.last() }
            val containing = rectangle(minOf(first.padding.left, last.padding.left), minOf(first.padding.top, last.padding.top),
                maxOf(first.padding.right, last.padding.right), maxOf(first.padding.bottom, last.padding.bottom))
            val overlays = range.value.box.overlays.map { overlay ->
                NativeInlineBoxBorderPaint(nativeInlineBoxOverlayRect(overlay, containing, ownerRtl(range, first.line)), overlay.border)
            }
            Owner(range, own, NativeInlineActionPaint(range.value.format, range.value.shift,
                lines.flatMap { it.mapped.fragmentsForRange(range.start, range.end) },
                currentColorPaint = range.value.box.currentColorPaint), overlays, last.line)
        }
        rounded = roundedFragments.toMap()
    }

    fun lineAdvance(line: Int): Float = lines[line].advance
    fun lineAdvanceBounds(line: Int): RectF = RectF(lines[line].bounds)
    fun boxRects(owner: NativeInlineBoxOwner, start: Int, end: Int, line: Int? = null): List<RectF>? {
        val known = selectedOwner(owner, start, end) ?: return null
        return known.fragments.filter { line == null || it.line == line }.map { RectF(it.border) }
    }
    fun boxHitTest(owner: NativeInlineBoxOwner, start: Int, end: Int): ((Float, Float) -> Boolean)? {
        val known = selectedOwner(owner, start, end) ?: return null
        return { x, y -> known.fragments.any { contains(it, x, y) } }
    }
    private fun contains(fragment: Fragment, x: Float, y: Float): Boolean =
        rounded[fragment]?.contains(x, y) ?: fragment.border.contains(x, y)

    /** Only caller-owned action boxes are clipped; native selection and caret paths are untouched. */
    fun childActionRects(owner: NativeInlineBoxOwner, start: Int, end: Int, childStart: Int, childEnd: Int,
        fragments: List<RectF>): List<RectF>? {
        val known = selectedOwner(owner, start, end) ?: return null
        if (childStart < start || childEnd < childStart || childEnd > end) return null
        val actual = lines.indices.associateWith { rectsOnLine(it, childStart, childEnd) }
        return fragments.flatMap { original ->
            val line = actual.filterValues { rectangles -> rectangles.any { it == original } }.keys.singleOrNull()
                ?: throw UnsupportedFloatLayout("Inline box child action lost its native line occurrence")
            known.fragments.filter { it.line == line && it.first < childEnd && it.last > childStart }.mapNotNull { allocation ->
                val l = maxOf(original.left, allocation.content.left)
                val r = minOf(original.right, allocation.content.right)
                if (r <= l) null else RectF(l, original.top, r, original.bottom)
            }
        }
    }
    private fun rectangleFragment(fragment: Fragment): NativeInlineActionFragment {
        val path = Path().apply { addRect(fragment.border.left, 0f, fragment.border.right, 1f, Path.Direction.CW) }
        return NativeInlineActionFragment(fragment.line, fragment.first, fragment.last, path, lines[fragment.line].mapped.baseline)
    }
    fun actionFragments(start: Int, end: Int, includeBoxes: Boolean = true): List<NativeInlineActionFragment> {
        require(start in 0..text.length && end in start..text.length)
        if (!includeBoxes) return lines.flatMap { it.mapped.fragmentsForRange(start, end) }
        val selected = owners.filter { it.range.start >= start && it.range.end <= end }
        val cuts = (listOf(start, end) + selected.flatMap { listOf(it.range.start, it.range.end) }).distinct().sorted()
        return cuts.zipWithNext().flatMap { (a, b) ->
            val own = selected.singleOrNull { it.range.start == a && it.range.end == b }
            if (own != null) own.fragments.map(::rectangleFragment)
            else lines.flatMap { it.mapped.fragmentsForRange(a, b) }
        }
    }
    fun rectsOnLine(line: Int, start: Int, end: Int): List<RectF> = lines[line].mapped.rectsForRange(start, end)
    fun caretOnLine(line: Int, offset: Int): RectF? = lines[line].mapped.caretRect(offset,
        if (offset == raw.nativeRangeOfLine(line).second) NativeInlineBoundaryAffinity.Preceding else NativeInlineBoundaryAffinity.Following)
    fun offsetOnLine(line: Int, x: Float, y: Float): Int = lines[line].mapped.offsetForPosition(x, y)
    private fun mappedCursor(line: Int, x: Float, y: Float): InlineCursor? {
        if (rounded.isEmpty()) return lines[line].mapped.cursorAt(x, y)
        val range = raw.nativeRangeOfLine(line)
        return cursors.lastOrNull { cursor ->
            val start = maxOf(range.first, cursor.start); val end = minOf(range.second, cursor.end)
            start < end && lines[line].mapped.rectsForRange(start, end).any { it.contains(x, y) } &&
                owners.filter { it.range.value.box.radius != null && cursor.start >= it.range.start &&
                    cursor.end <= it.range.end }.all { owner -> owner.fragments.any { contains(it, x, y) } }
        }?.value?.cursor
    }
    fun cursorOnLine(line: Int, x: Float, y: Float): InlineCursor? = mappedCursor(line, x, y)
        ?: fragments.lastOrNull { it.line == line && contains(it, x, y) }?.owner?.value?.format?.cursor
    private fun lineAt(x: Float, y: Float): Int = lines.indices.reversed().firstOrNull { line ->
        val range = raw.nativeRangeOfLine(line)
        rectsOnLine(line, range.first, range.second).any { it.contains(x, y) }
    } ?: fragments.lastOrNull { contains(it, x, y) }?.line
        ?: raw.nativeLineAt(raw.offsetForPosition(x, y))
    override fun offsetForPosition(x: Float, y: Float): Int = offsetOnLine(lineAt(x, y), x, y)
    override fun caretAt(x: Float, y: Float): NativeTextCaret {
        val line = lineAt(x, y)
        val offset = offsetOnLine(line, x, y)
        return NativeTextCaret(offset, if (offset == raw.nativeRangeOfLine(line).second)
            NativeTextAffinity.Upstream else NativeTextAffinity.Downstream)
    }
    val cursorBounds: List<RectF> get() = fragments.filter { it.owner.value.format.cursor != null }.map { RectF(it.border) }
    override fun cursorAt(x: Float, y: Float): InlineCursor? = mappedCursor(lineAt(x, y), x, y)
        ?: fragments.lastOrNull { it.owner.value.format.cursor != null && contains(it, x, y) }?.owner?.value?.format?.cursor
    override fun rectsForRange(start: Int, end: Int): List<RectF> = lines.flatMap { it.mapped.rectsForRange(start, end) }
    override fun characterRects(start: Int, length: Int): List<RectF?> {
        require(start in 0..text.length && length >= 0 && length <= text.length - start)
        return (start until start + length).map { offset ->
            val begin = if (offset > 0 && Character.isLowSurrogate(text[offset]) && Character.isHighSurrogate(text[offset - 1])) offset - 1 else offset
            val end = if (Character.isHighSurrogate(text[begin]) && begin + 1 < text.length && Character.isLowSurrogate(text[begin + 1])) begin + 2 else begin + 1
            rectsForRange(begin, end).reduceOrNull { a, b -> a.apply { union(b) } }
        }
    }
    override fun caretRect(offset: Int): RectF = caretOnLine(raw.nativeLineAt(offset), offset)
        ?: throw UnsupportedFloatLayout("Inline box caret lost its native source affinity")
    override fun caretRect(caret: NativeTextCaret): RectF {
        require(caret.offset in 0..text.length)
        val preceding = caret.affinity == NativeTextAffinity.Upstream && caret.offset > 0
        val line = raw.nativeLineAt(if (preceding) caret.offset - 1 else caret.offset)
        return lines[line].mapped.caretRect(caret.offset, if (preceding)
            NativeInlineBoundaryAffinity.Preceding else NativeInlineBoundaryAffinity.Following)
            ?: throw UnsupportedFloatLayout("Inline box caret lost its explicit source affinity")
    }
    override fun lineRange(offset: Int): Pair<Int, Int> = raw.lineRange(offset)
    override fun visualLineRanges(offset: Int): List<Pair<Int, Int>> = raw.visualLineRanges(offset)
    override fun isHardLineBreak(offset: Int): Boolean = raw.isHardLineBreak(offset)
    override fun visualOffset(offset: Int, direction: Int): Int = raw.visualOffset(offset, direction)
    override fun containsInteraction(x: Float, y: Float): Boolean = cursorBounds.any { it.contains(x, y) } ||
        rectsForRange(0, text.length).any { it.contains(x, y) }
    private fun boxBounds(fragment: Fragment) = NativeFloatBounds(fragment.border.left, fragment.border.top,
        fragment.border.right, fragment.border.bottom)
    fun linePaintBounds(line: Int): List<NativeFloatBounds> = buildList {
        addAll(lines[line].mapped.ordinaryPaintBounds)
        fragments.filter { it.line == line }.forEach { fragment -> add(boxBounds(fragment)); addAll(fragment.painter.bounds) }
        owners.forEach { owner ->
            addAll(owner.decoration.bounds(line))
            if (owner.overlayLine == line) owner.overlays.forEach { addAll(it.bounds) }
        }
    }
    override val ordinaryPaintBounds: List<NativeFloatBounds> get() = lines.indices.flatMap(::linePaintBounds)
    val scrollableBounds: NativeFloatBounds by lazy {
        var result = NativeFloatBounds(0f, 0f, width.toFloat(), raw.textBottom)
        lines.forEach { result = result.enclosing(NativeFloatBounds(it.bounds.left, it.bounds.top, it.bounds.right, it.bounds.bottom)) }
        fragments.forEach { result = result.enclosing(boxBounds(it)) }
        owners.forEach { owner -> owner.overlays.forEach { overlay -> overlay.bounds.forEach { result = result.enclosing(it) } } }
        result
    }
    override val extents: NativeGeometryExtents get() = NativeGeometryExtents(width, height.toFloat(),
        ordinaryPaintBounds.reduceOrNull { a, b -> a.enclosing(b) }, nativeBoundsOf(rectsForRange(0, text.length) + cursorBounds))
    private fun paintBackgrounds(canvas: Canvas, line: Int?) {
        fragments.filter { line == null || it.line == line }
            .sortedWith(compareBy({ it.line }, { if (nestingParents[spanIndices.getValue(it.owner)] < 0) 0 else 1 })).forEach { fragment ->
            val color = fragment.owner.value.format.paint.bgColor
            val curved = rounded[fragment]
            if (curved != null) curved.paint(canvas, color,
                fragment.owner.value.box.color(fragment.owner.value.box.border.top, fragment.owner.value.format))
            else {
                if (color ushr 24 != 0) canvas.drawRect(fragment.border, Paint(Paint.ANTI_ALIAS_FLAG).apply { this.color = color })
                fragment.painter.paint(canvas) { fragment.owner.value.box.color(it, fragment.owner.value.format) }
            }
        }
    }
    fun paintOverlays(canvas: Canvas, line: Int? = null) {
        owners.filter { line == null || it.overlayLine == line }.forEach { owner ->
            owner.overlays.forEach { overlay -> overlay.paint(canvas) {
                owner.range.value.box.color(it, owner.range.value.format)
            } }
        }
    }
    fun paintLine(canvas: Canvas, line: Int, includeOverlays: Boolean = true) {
        paintBackgrounds(canvas, line)
        lines[line].mapped.paint(canvas)
        owners.forEach { it.decoration.paintDecorations(canvas, line) }
        if (includeOverlays) paintOverlays(canvas, line)
    }
    override fun paint(canvas: Canvas) = paint(canvas, includeOverlays = true)
    fun paint(canvas: Canvas, includeOverlays: Boolean) {
        paintBackgrounds(canvas, null)
        lines.forEach { it.mapped.paint(canvas) }
        owners.forEach { it.decoration.paintDecorations(canvas) }
        if (includeOverlays) paintOverlays(canvas)
    }
}

/** Each physical side owns its outer-to-inner corner polygon. Shared edges have no
 * area; neither solid fills nor dotted clips acquire a second side's corner. */
internal class NativeInlineBoxBorderPaint(box: RectF, borders: NativeInlineBoxBorders) {
    private data class Side(val border: NativeInlineBoxBorder, val path: Path,
        val bounds: NativeFloatBounds, val dotted: TableBorderSegment?)
    private val sides: List<Side>
    private val fill = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.FILL }
    val bounds: List<NativeFloatBounds>

    init {
        nativeInlineBoxCoordinates(box.left, box.top, box.right, box.bottom)
        val width = box.right.toDouble() - box.left
        val height = box.bottom.toDouble() - box.top
        nativeInlineBoxCoordinate(width)
        nativeInlineBoxCoordinate(height)
        if (width < 0.0 || height < 0.0 ||
            borders.left.width.toDouble() + borders.right.width > width ||
            borders.top.width.toDouble() + borders.bottom.width > height)
            throw UnsupportedFloatLayout("Inline border exceeds its prepared box")
        val left = box.left
        val top = box.top
        val right = box.right
        val bottom = box.bottom
        val innerLeft = nativeInlineBoxCoordinate(left.toDouble() + borders.left.width)
        val innerTop = nativeInlineBoxCoordinate(top.toDouble() + borders.top.width)
        val innerRight = nativeInlineBoxCoordinate(right.toDouble() - borders.right.width)
        val innerBottom = nativeInlineBoxCoordinate(bottom.toDouble() - borders.bottom.width)
        if (innerLeft > innerRight || innerTop > innerBottom ||
            borders.left.width > 0f && innerLeft <= left ||
            borders.top.width > 0f && innerTop <= top ||
            borders.right.width > 0f && innerRight >= right ||
            borders.bottom.width > 0f && innerBottom >= bottom)
            throw UnsupportedFloatLayout("Inline border lacks representable native insets")

        fun center(first: Float, last: Float, border: NativeInlineBoxBorder): Float {
            val value = nativeInlineBoxCoordinate((first.toDouble() + last) / 2.0)
            if (border.width / 2f <= 0f || value <= minOf(first, last) || value >= maxOf(first, last))
                throw UnsupportedFloatLayout("Dotted inline border lacks its native center line")
            return value
        }
        val prepared = mutableListOf<Side>()
        fun side(border: NativeInlineBoxBorder, x0: Float, y0: Float, x1: Float, y1: Float,
            x2: Float, y2: Float, x3: Float, y3: Float, segment: () -> TableBorderSegment) {
            if (border.width == 0f || width == 0.0 || height == 0.0) return
            val path = Path().apply {
                moveTo(x0, y0); lineTo(x1, y1); lineTo(x2, y2); lineTo(x3, y3); close()
            }
            val envelope = NativeFloatBounds(minOf(x0, x1, x2, x3), minOf(y0, y1, y2, y3),
                maxOf(x0, x1, x2, x3), maxOf(y0, y1, y2, y3))
            prepared += Side(border, path, envelope, if (border.dotted) segment() else null)
        }
        side(borders.top, left, top, right, top, innerRight, innerTop, innerLeft, innerTop) {
            val y = center(top, innerTop, borders.top)
            TableBorderSegment(left, y, right, y, borders.top.width, null, TableStroke.Dotted)
        }
        side(borders.right, right, top, right, bottom, innerRight, innerBottom, innerRight, innerTop) {
            val x = center(innerRight, right, borders.right)
            TableBorderSegment(x, top, x, bottom, borders.right.width, null, TableStroke.Dotted)
        }
        side(borders.bottom, right, bottom, left, bottom, innerLeft, innerBottom, innerRight, innerBottom) {
            val y = center(innerBottom, bottom, borders.bottom)
            TableBorderSegment(left, y, right, y, borders.bottom.width, null, TableStroke.Dotted)
        }
        side(borders.left, left, bottom, left, top, innerLeft, innerTop, innerLeft, innerBottom) {
            val x = center(left, innerLeft, borders.left)
            TableBorderSegment(x, top, x, bottom, borders.left.width, null, TableStroke.Dotted)
        }
        sides = prepared.toList()
        // Color may become visible later through currentColor; geometry is reserved once.
        bounds = sides.map { it.bounds }
    }

    fun paint(canvas: Canvas, color: (NativeInlineBoxBorder) -> Int) {
        sides.forEach { side ->
            val value = color(side.border)
            if (value ushr 24 == 0) return@forEach
            val dotted = side.dotted
            if (dotted == null) {
                fill.color = value
                canvas.drawPath(side.path, fill)
            } else {
                val checkpoint = canvas.save()
                try {
                    canvas.clipPath(side.path)
                    paintNativeTableBorder(canvas, dotted, value)
                } finally { canvas.restoreToCount(checkpoint) }
            }
        }
    }
}

/** Paint a bounded window of the one composite decoration. Text replay never enters this clip. */
private class NativeInlineBoxRoundPaint(val slice: NativeInlineBoxCornerSlice) : NativeInlineBoxCurvePaint {
    override fun contains(x: Float, y: Float) = slice.contains(x, y)
    private fun path(box: NativeFloatBounds, radii: NativeCornerRadii) = Path().apply {
        val corners = radii.clockwise.flatMap { listOf(it.toFloat(), it.toFloat()) }.toFloatArray()
        addRoundRect(RectF(box.left, box.top, box.right, box.bottom), corners, Path.Direction.CW)
    }
    private val outer = path(slice.localShape.borderBox, slice.localShape.outerRadii)
    private val border = Path(outer).apply {
        fillType = Path.FillType.EVEN_ODD
        slice.localShape.paddingBox?.let { addPath(path(it, slice.localShape.innerRadii)) }
    }
    private val fill = Paint(Paint.ANTI_ALIAS_FLAG)
    override fun paint(canvas: Canvas, background: Int, borderColor: Int) {
        val box = slice.fragment
        val checkpoint = canvas.save()
        try {
            canvas.translate(box.left, box.top)
            canvas.clipRect(0f, 0f, box.right - box.left, box.bottom - box.top)
            if (background ushr 24 != 0) { fill.color = background; canvas.drawPath(outer, fill) }
            if (slice.localShape.borderWidth > 0f && borderColor ushr 24 != 0) {
                fill.color = borderColor; canvas.drawPath(border, fill)
            }
        } finally { canvas.restoreToCount(checkpoint) }
    }
}
