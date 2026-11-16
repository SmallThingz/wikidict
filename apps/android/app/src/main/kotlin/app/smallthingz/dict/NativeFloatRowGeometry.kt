package app.smallthingz.dict

import android.graphics.Canvas
import android.graphics.Path
import android.graphics.RectF
import android.text.Layout
import android.text.Spanned
import android.text.SpannedString
import android.text.TextDirectionHeuristic
import android.text.TextPaint
import kotlin.math.ceil

/** Native Float advances and replay share one selected row map; no StaticLayout scaffold exists. */
internal class NativeFloatRowGeometry private constructor(
    private val plan: NativeFloatRowPlan,
    private val nodeFactory: (NativeFloatGeometry) -> List<FloatInteractionNode>,
    private val decoration: (Canvas, NativeFloatGeometry) -> Unit,
    private val decorationBounds: (NativeFloatGeometry) -> NativeFloatBounds?,
    private val origins: List<Pair<Float, Float>>? = null,
) : NativeFloatGeometry() {
    override val text: CharSequence get() = plan.source
    override val width: Int get() = plan.width
    override val floats: List<PlacedNativeFloat> get() = plan.flow.floats
    override val exclusions: List<NativeFloatExclusion> get() = plan.flow.exclusions
    override val textBottom: Float get() = bottoms.maxOrNull() ?: 0f
    override val hasResidualFloats: Boolean get() = exclusions.any { it.outer.bottom > textBottom + 0.01f }
    override val height: Int get() = ceil(maxOf(textBottom, exclusions.maxOfOrNull { it.outer.bottom } ?: 0f)).toInt()
    private val tops = plan.rows.indices.map { origins?.get(it)?.second ?: plan.flow.tops[it] }
    private val bottoms = plan.rows.indices.map { tops[it] + plan.flow.bottoms[it] - plan.flow.tops[it] }
    private val baselines = plan.rows.indices.map { tops[it] + plan.flow.baselines[it] - plan.flow.tops[it] }
    private fun present(line: Int): Boolean = plan.flow.sourceLinePresent?.get(line) ?: true
    private val mappedRows = plan.rows.mapIndexed { line, row ->
        val left = plan.flow.left[line].toFloat() + (origins?.get(line)?.first ?: 0f)
        val right = width - plan.flow.right[line].toFloat() + (origins?.get(line)?.first ?: 0f)
        val physical = when (row.alignment) {
            Layout.Alignment.ALIGN_CENTER -> NativeFloatRowPhysicalAlignment.Center
            Layout.Alignment.ALIGN_NORMAL -> if (row.paragraph.rtl) NativeFloatRowPhysicalAlignment.Right else NativeFloatRowPhysicalAlignment.Left
            Layout.Alignment.ALIGN_OPPOSITE -> if (row.paragraph.rtl) NativeFloatRowPhysicalAlignment.Left else NativeFloatRowPhysicalAlignment.Right
            else -> throw UnsupportedFloatLayout("Float image row alignment is unavailable")
        }
        nativeFloatRowBounds(left.toDouble(), right.toDouble(), baselines[line].toDouble())
        val origin = nativeFloatRowOrigin(left, maxOf(left, right), row.visibleAdvance, physical) -
            if (row.paragraph.rtl) row.advance - row.visibleAdvance else 0f
        nativeFloatRowBounds(left.toDouble(), right.toDouble(), origin.toDouble(), baselines[line].toDouble())
        val pieces = row.glyphs.map { run ->
            run.image?.let { image ->
                val occurrence = image.nativeImageOccurrence
                NativeFloatRowPiece.Image(run.start, run.rtl, NativeFloatRowImage(
                    image.nativeImageWidth, image.nativeImageHeight, image.nativeUsedMetrics.top,
                    occurrence?.paddingLeft ?: 0f, occurrence?.paddingRight ?: 0f,
                    occurrence?.translationX ?: 0f, occurrence?.translationY ?: 0f, occurrence != null))
            } ?: NativeFloatRowPiece.Text(run.start, run.end, run.rtl, run.advance)
        }
        var prefix = 0.0
        for (piece in pieces) {
            val first = origin.toDouble() + prefix
            prefix += piece.advance.toDouble()
            nativeFloatRowBounds(first, origin.toDouble() + prefix)
            if (piece is NativeFloatRowPiece.Image) {
                val image = piece.image
                val x = first + image.paddingLeft + image.translationX
                val y = baselines[line].toDouble() + image.baselineTop + image.translationY
                nativeFloatRowBounds(x, x + image.outerWidth, y, y + image.outerHeight)
            }
        }
        nativeFloatRowPieces(text, row.start, minOf(row.end, row.paragraph.measuredEnd), pieces, origin, baselines[line])
    }
    private val authoredBaselines = nativeInlineRanges(plan.source, NativeAuthoredBaselineShift::class.java)
    private val authoredMetrics = nativeInlineRanges(plan.source, NativeAuthoredInlineMetrics::class.java)
    private val cursors = nativeInlineRanges(plan.source, NativeAuthoredCursor::class.java)
    override val nodes: List<FloatInteractionNode> = nodeFactory(this)

    override val textBaselines: NativeTextBaselines? get() {
        val lines = plan.rows.indices.filter(::present)
        return NativeTextBaselines.of(lines.firstOrNull()?.let { baselines[it] }, lines.lastOrNull()?.let { baselines[it] })
    }
    override fun firstLineBand(): RectF {
        val line = plan.rows.indices.firstOrNull(::present) ?: return RectF()
        val x = origins?.get(line)?.first ?: 0f
        return RectF(plan.flow.left[line] + x, tops[line], width - plan.flow.right[line] + x, bottoms[line])
    }
    override fun headingOwnerContentTop(): Float? {
        if (text.isEmpty() || nodes.count { it.kind == FloatInteractionKind.HEADING && it.start == 0 && it.end == text.length } != 1) return null
        val owner = plan.source.getSpans(0, text.length, NativeRunLineMetrics::class.java).singleOrNull {
            it.strut && plan.source.getSpanStart(it) == 0 && plan.source.getSpanEnd(it) > 0
        } ?: return null
        return baselines.first() + owner.primary.ascent + owner.primary.baselineShift
    }
    override fun remainingExclusions(afterY: Float): List<NativeFloatExclusion> {
        require(afterY.isFinite() && afterY >= 0f)
        return exclusions.filter { it.outer.bottom > afterY }.map { it.copy(outer = it.outer.translated(0f, -afterY)) }
    }
    private data class ImagePiece(val line: Int, val run: NativeFloatGlyphRun,
        val placed: NativeFloatRowPiecePlacement, val image: NativeFloatInlineImage)
    private val images: List<ImagePiece> by lazy {
        plan.rows.flatMapIndexed { line, row -> row.glyphs.mapIndexedNotNull { index, run ->
            run.image?.let { ImagePiece(line, run, mappedRows[line].placements[index], it) }
        } }
    }
    private val positionedImages: List<ImagePiece> by lazy {
        images.filter { it.image.nativeImageOccurrence != null }.sortedBy { it.run.start }
    }
    private fun imageRect(image: ImagePiece): RectF = checkNotNull(image.placed.imageBounds).let {
        RectF(it.left, it.top, it.right, it.bottom)
    }
    private fun imageInk(image: ImagePiece): NativeFloatBounds {
        val outer = checkNotNull(image.placed.imageBounds)
        return image.image.nativeImageInkBounds.translated(outer.left, outer.top)
    }
    override val positionedGroups: List<NativePositionedGroup> by lazy {
        positionedImages.filter { present(it.line) }.map { occurrence ->
            NativePositionedGroup(listOf(imageRect(occurrence)), nodes.filter {
                it.start <= occurrence.run.start && it.end >= occurrence.run.end
            }.map { it.id }.toSet(), occurrence.run.start,
                paint = { canvas -> occurrence.image.drawNativeImage(canvas, imageRect(occurrence)) })
        }
    }
    override fun paint(canvas: Canvas) {
        paintOrdinary(canvas)
        positionedGroups.forEach { it.paint(canvas) }
    }
    override fun paintOrdinary(canvas: Canvas) {
        plan.rows.indices.filter(::present).forEach { paintLine(canvas, it, includePositioned = false) }
        decoration(canvas, this)
    }
    private fun paintLine(canvas: Canvas, line: Int, includePositioned: Boolean) {
        if (!present(line)) return
        val row = plan.rows[line]
        val map = mappedRows[line]
        row.glyphs.forEachIndexed { index, run -> if (run.start < row.visibleEnd && run.image == null) {
            run.paintBackground(canvas, map.placements[index].left, baselines[line], plan.nativeLineMetrics[line].top, plan.nativeLineMetrics[line].bottom)
        } }
        row.glyphs.forEachIndexed { index, run ->
            val placed = map.placements[index]
            if (run.image != null) {
                if (includePositioned || run.image!!.nativeImageOccurrence == null) {
                    val box = checkNotNull(placed.imageBounds)
                    run.image!!.drawNativeImage(canvas, RectF(box.left, box.top, box.right, box.bottom))
                }
            } else if (run.start < row.visibleEnd) run.paintGlyphs(canvas, placed.left, baselines[line])
        }
        row.glyphs.forEachIndexed { index, run -> if (run.start < row.visibleEnd && run.image == null) {
            run.paintDecorations(canvas, map.placements[index].left, baselines[line])
        } }
    }
    override val ordinaryPaintBounds: List<NativeFloatBounds> by lazy {
        plan.rows.flatMapIndexed { line, row -> if (!present(line)) emptyList() else row.glyphs.mapIndexedNotNull { index, run ->
            if (run.image != null) {
                if (run.image!!.nativeImageOccurrence == null) images.first { it.line == line && it.run === run }.let(::imageInk) else null
            } else if (run.start < row.visibleEnd) run.paintBounds(mappedRows[line].placements[index].left,
                baselines[line], plan.nativeLineMetrics[line].top, plan.nativeLineMetrics[line].bottom) else null
        } } + listOfNotNull(decorationBounds(this))
    }
    override val scrollableBounds: NativeFloatBounds by lazy {
        var bounds = NativeFloatBounds(0f, 0f, width.toFloat(), textBottom)
        plan.rows.indices.filter(::present).forEach { line ->
            nativeRubyLineAdvanceBounds(line)?.let { bounds = bounds.enclosing(NativeFloatBounds(it.left, tops[line], it.right, bottoms[line])) }
        }
        images.forEach { bounds = bounds.enclosing(checkNotNull(it.placed.imageBounds)) }
        bounds
    }
    override val extents: NativeGeometryExtents by lazy {
        val ink = (ordinaryPaintBounds + images.filter { it.image.nativeImageOccurrence != null }.map(::imageInk))
            .fold(nativeFocusInk(nodes), ::enclosingBounds)
        val interaction = nativeBoundsOf(rectsForRange(0, text.length) + nodes.flatMap { it.bounds } +
            listOf(caretRect(0), caretRect(text.length)))
        NativeGeometryExtents(width, height.toFloat(), ink, interaction)
    }
    override fun containsInteraction(x: Float, y: Float): Boolean =
        nodes.any { it.contains(x, y) } || rectsForRange(0, text.length).any { it.contains(x, y) }
    override fun interactionNodeAt(x: Float, y: Float): FloatInteractionNode? {
        positionedGroups.asReversed().forEach { group -> if (group.contains(x, y)) {
            nodes.lastOrNull { it.id in group.nodeIds && it.contains(x, y) }?.let { return it }
        } }
        return nodes.lastOrNull { it.contains(x, y) }
    }
    private fun selectionMetrics(line: Int, offset: Int): NativeUsedLineMetrics {
        val shift = authoredBaselines.firstOrNull { offset >= it.start && offset < it.end }
        val own = shift?.let { scope -> authoredMetrics.firstOrNull {
            it.start <= scope.start && it.end >= scope.end && it.value.primary.baselineShift == scope.value.shift
        }?.value }
        if (own != null && own.policy != NativeLineHeightPolicy.Normal)
            return NativeUsedLineMetrics(own.primary.ascent + shift.value.shift, own.primary.descent + shift.value.shift)
        return plan.nativeLineMetrics[line]
    }
    private fun textX(run: NativeFloatGlyphRun, placed: NativeFloatRowPiecePlacement, offset: Int): Float {
        val advance = run.advanceTo(offset.coerceIn(run.start, run.end))
        return if (run.rtl) placed.right - advance else placed.left + advance
    }
    override fun rectsForRange(start: Int, end: Int): List<RectF> {
        require(start in 0..text.length && end in start..text.length)
        if (start == end) return emptyList()
        return plan.rows.indices.flatMap { nativeRubyLineRects(it, start, end) }
    }
    override fun characterRects(start: Int, length: Int): List<RectF?> {
        require(start in 0..text.length && length >= 0 && length <= text.length - start)
        return (start until start + length).map { offset ->
            val rects = rectsForRange(offset, offset + 1)
            if (rects.isEmpty()) null else RectF(rects.first()).also { union -> rects.drop(1).forEach(union::union) }
        }
    }
    override fun caretRect(offset: Int): RectF {
        require(offset in 0..text.length)
        return checkNotNull(nativeRubyLineCaret(nativeLineAt(offset), offset))
    }
    private fun offsetOnLine(line: Int, x: Float, y: Float): Int {
        val row = plan.rows[line]
        val placements = mappedRows[line].placements
        var selected: Int? = null
        var distance = Double.POSITIVE_INFINITY
        row.glyphs.forEachIndexed { index, run ->
            val placed = placements[index]
            val candidate: Int
            val edge: Float
            if (run.image != null) {
                val bounds = checkNotNull(placed.imageBounds)
                val after = x >= (bounds.left + bounds.right) / 2f
                candidate = if (after != run.rtl) run.end else run.start
                edge = if (after) bounds.right else bounds.left
            } else {
                val logical = if (run.rtl) placed.right - x else x - placed.left
                candidate = run.offsetForAdvance(logical.coerceIn(0f, run.advance))
                edge = textX(run, placed, candidate)
            }
            val delta = absSquared(x - edge)
            if (delta < distance) { distance = delta; selected = candidate }
        }
        return selected ?: row.start
    }
    override fun offsetForPosition(x: Float, y: Float): Int {
        val imageOrder = images.filter { it.image.nativeImageOccurrence == null } +
            positionedImages
        imageOrder.asReversed().firstOrNull { imageRect(it).contains(x, y) }?.let {
            val rect = imageRect(it)
            return if ((x >= (rect.left + rect.right) / 2f) != it.run.rtl) it.run.end else it.run.start
        }
        val line = plan.rows.indices.filter(::present).minByOrNull {
            val vertical = maxOf(tops[it] - y, 0f, y - bottoms[it])
            absSquared(vertical)
        } ?: 0
        return offsetOnLine(line, x, y)
    }
    override fun cursorAt(x: Float, y: Float): InlineCursor? = cursors.lastOrNull {
        rectsForRange(it.start, it.end).any { rect -> rect.contains(x, y) }
    }?.value?.cursor
    override fun lineRange(offset: Int): Pair<Int, Int> = nativeRangeOfLine(nativeLineAt(offset))
    override fun visualOffset(offset: Int, direction: Int): Int {
        require(offset in 0..text.length && direction in listOf(-1, 1))
        val line = nativeLineAt(offset)
        val stops = visualStops(line)
        val owned = plan.rows[line].glyphs.indexOfFirst { offset >= it.start && offset < it.end }
        val candidates = stops.indices.filter { stops[it].first == offset }
        val current = candidates.firstOrNull { stops[it].second == owned } ?: candidates.firstOrNull()
            ?: return offset
        var next = current + direction
        while (next in stops.indices && stops[next].first == offset) next += direction
        if (next in stops.indices) return stops[next].first
        val adjacent = line + if ((direction > 0) != plan.rows[line].paragraph.rtl) 1 else -1
        if (adjacent !in plan.rows.indices) return offset
        val other = visualStops(adjacent)
        return if (direction > 0) other.firstOrNull()?.first ?: plan.rows[adjacent].start
            else other.lastOrNull()?.first ?: plan.rows[adjacent].start
    }
    private fun visualStops(line: Int): List<Pair<Int, Int>> = buildList {
        plan.rows[line].glyphs.forEachIndexed { index, run ->
            val own = mutableListOf(run.start)
            var at = run.start
            while (at < run.end) {
                val next = if (run.image != null) run.end else run.cursor(at, after = true)
                if (next <= at || next > run.end) throw UnsupportedFloatLayout("Native Float row cursor failed to advance")
                own += next; at = next
            }
            (if (run.rtl) own.asReversed() else own).forEach { add(it to index) }
        }
        if (isEmpty()) add(plan.rows[line].start to -1)
    }
    internal override fun baselineForOffset(offset: Int): Float = baselines[nativeLineAt(offset)] +
        (authoredBaselines.firstOrNull { offset >= it.start && offset < it.end }?.value?.shift ?: 0f)
    internal override fun distanceForPosition(x: Float, y: Float): Double =
        plan.rows.indices.filter(::present).minOfOrNull { line ->
            val box = nativeRubyLineAdvanceBounds(line) ?: firstLineBand()
            absSquared(maxOf(box.left - x, 0f, x - box.right)) + absSquared(maxOf(tops[line] - y, 0f, y - bottoms[line]))
        } ?: Double.POSITIVE_INFINITY
    internal override val shapedLineCount: Int get() = plan.rows.size
    internal override fun usedLineHeight(line: Int): Float = bottoms[line] - tops[line]
    internal override val hasColumnFragments: Boolean get() = origins != null
    internal override fun inColumns(origins: List<Pair<Float, Float>>): NativeFloatGeometry {
        require(origins.size == shapedLineCount && origins.all { (x, y) -> x.isFinite() && y.isFinite() &&
            kotlin.math.abs(x) <= TablePixelLimit && kotlin.math.abs(y) <= TablePixelLimit })
        if (exclusions.isNotEmpty() || this.origins != null)
            throw UnsupportedFloatLayout("Float image columns require an unfragmented owner without exclusions")
        return NativeFloatRowGeometry(plan, nodeFactory, decoration, decorationBounds, origins)
    }
    internal override val nativeRubyShapingSource: Spanned get() = plan.source
    internal override val nativeRubyShapingPaint: TextPaint get() = TextPaint().apply { set(plan.paint) }
    internal override val nativeRubyParagraphDirection: Int get() = if (plan.rows.first().paragraph.rtl) -1 else 1
    internal override fun nativeRubyLineSourceStart(line: Int): Int = plan.rows[line].start
    internal override fun nativeRubyLineAdvanceBounds(line: Int): RectF? {
        if (!present(line)) return null
        val pieces = mappedRows[line]
        return RectF(pieces.originX, tops[line], pieces.originX + pieces.advance, bottoms[line])
    }
    internal override fun nativeRubyLineBaseline(line: Int): Float = baselines[line]
    internal override fun nativeRubyLineTop(line: Int): Float = tops[line]
    internal override fun nativeRubyLineDirection(line: Int): Int = if (plan.rows[line].paragraph.rtl) -1 else 1
    internal override fun nativeRubyLinePaintBounds(line: Int): List<NativeFloatBounds> {
        val row = plan.rows[line]
        return row.glyphs.mapIndexedNotNull { index, run ->
            if (run.image != null) images.first { it.line == line && it.run === run }.let(::imageInk)
            else if (run.start < row.visibleEnd) run.paintBounds(mappedRows[line].placements[index].left,
                baselines[line], plan.nativeLineMetrics[line].top, plan.nativeLineMetrics[line].bottom) else null
        }
    }
    internal override fun nativeRubyLineCaret(line: Int, publicOffset: Int): RectF? {
        val row = plan.rows[line]
        if (publicOffset !in row.start..row.end) return null
        val owned = row.glyphs.indexOfFirst { publicOffset >= it.start && publicOffset < it.end }.let {
            if (it >= 0) it else row.glyphs.indices.filter { index -> row.glyphs[index].end <= publicOffset }
                .maxByOrNull { index -> row.glyphs[index].end } ?: -1
        }
        if (owned < 0) return RectF(mappedRows[line].originX, tops[line], mappedRows[line].originX +
            if (present(line)) 1f else 0f, bottoms[line])
        val run = row.glyphs[owned]
        val placed = mappedRows[line].placements[owned]
        if (run.image != null) {
            val box = checkNotNull(placed.imageBounds)
            val atStart = publicOffset <= run.start
            val x = if (atStart != run.rtl) box.left else box.right
            return RectF(x, box.top, x + 1f, box.bottom)
        }
        val x = textX(run, placed, publicOffset)
        val metrics = selectionMetrics(line, publicOffset.coerceIn(run.start, run.end - 1))
        return RectF(x, baselines[line] + metrics.top, x + 1f, baselines[line] + metrics.bottom)
    }
    internal override fun nativeRubyLineOffsetForPosition(line: Int, x: Float, y: Float): Int = offsetOnLine(line, x, y)
    internal override fun nativeRubyLineCursorAt(line: Int, x: Float, y: Float): InlineCursor? = cursors.lastOrNull {
        nativeRubyLineRects(line, it.start, it.end).any { rect -> rect.contains(x, y) }
    }?.value?.cursor
    internal override fun nativeRubyEmergencyLineEnds(): Set<Int> = plan.emergencyEnds()
    internal override fun nativeRubyMeasuredAdvance(start: Int, end: Int): Float = plan.measuredAdvance(start, end)
    internal override fun nativeRubyAvailableAt(offset: Int, considerPreviousLine: Boolean): Float {
        val line = nativeLineAt(offset)
        val before = plan.measuredAdvance(plan.rows[line].start, offset)
        if (considerPreviousLine && line > 0 && before == 0f && plan.rows[line].start > 0 && text[plan.rows[line].start - 1] != '\n') {
            val remaining = nativeLineAvailableWidth(line - 1) - nativeLineAdvance(line - 1)
            if (remaining > 0f) return remaining
        }
        return (nativeLineAvailableWidth(line) - before).coerceAtLeast(0f)
    }
    internal override fun nativeRubyLineRects(line: Int, start: Int, end: Int): List<RectF> {
        require(start in 0..text.length && end in start..text.length)
        if (!present(line) || start == end) return emptyList()
        return plan.rows[line].glyphs.mapIndexedNotNull { index, run ->
            val first = maxOf(start, run.start); val last = minOf(end, run.end)
            if (first >= last) null else if (run.image != null) {
                val box = checkNotNull(mappedRows[line].placements[index].imageBounds)
                RectF(box.left, box.top, box.right, box.bottom)
            } else {
                val placed = mappedRows[line].placements[index]
                val firstX = textX(run, placed, first); val lastX = textX(run, placed, last)
                val metrics = selectionMetrics(line, first)
                if (firstX == lastX) null else RectF(minOf(firstX, lastX), baselines[line] + metrics.top,
                    maxOf(firstX, lastX), baselines[line] + metrics.bottom)
            }
        }
    }
    internal override fun nativeRubyLineBaseText(line: Int): String =
        text.subSequence(plan.rows[line].start, plan.rows[line].end).toString()
    internal override fun nativeRubyLineRanges(line: Int): List<Pair<Int, Int>> = listOf(nativeRangeOfLine(line))
    internal override fun paintRubyNativeLine(canvas: Canvas, line: Int) = paintLine(canvas, line, includePositioned = true)
    internal override val nativeRubyAdvanceBounds: RectF? get() = nativeRubyLineAdvanceBounds(0)
    internal override fun nativeLineAt(offset: Int): Int = plan.lineAt(offset)
    internal override fun nativeRangeOfLine(line: Int): Pair<Int, Int> = plan.rows[line].let { it.start to it.end }
    internal override fun nativeInlineVisibleEnd(line: Int): Int = plan.rows[line].visibleEnd
    internal override fun nativeInlineVisibleAdvance(line: Int): Float = plan.rows[line].visibleAdvance
    internal override fun nativeInlineVisibleBounds(line: Int): RectF? =
        if (!present(line) || plan.rows[line].visibleAdvance == 0f) null else {
            val row = plan.rows[line]
            val start = mappedRows[line].originX + if (row.paragraph.rtl) row.advance - row.visibleAdvance else 0f
            RectF(start, tops[line], start + row.visibleAdvance, bottoms[line])
        }
    internal override fun nativeLineAvailableWidth(line: Int): Float = width - plan.flow.left[line].toFloat() - plan.flow.right[line]
    internal override fun nativeSingleLineAdvance(): Float { check(shapedLineCount == 1); return nativeLineAdvance(0) }
    internal override fun nativeLineAdvance(line: Int): Float = plan.rows[line].advance
    internal override fun nativeUsedLineMetrics(line: Int): NativeUsedLineMetrics = NativeUsedLineMetrics(tops[line] - baselines[line], bottoms[line] - baselines[line])
    internal override fun nativeContentLineMetrics(line: Int): NativeUsedLineMetrics = plan.nativeLineMetrics[line]
    internal override fun nativeReplacementOrigin(offset: Int): Pair<Float, Float> {
        val line = nativeLineAt(offset)
        val placed = mappedRows[line].placements.singleOrNull { it.piece.start == offset && it.piece is NativeFloatRowPiece.Image }
            ?: throw UnsupportedFloatLayout("Float image origin lost its original object range")
        val box = checkNotNull(placed.imageBounds)
        return box.left to baselines[line]
    }
    internal override fun nativeInlineActionFragments(start: Int, end: Int): List<NativeInlineActionFragment> =
        plan.rows.indices.flatMap { line -> nativeRubyLineRects(line, start, end).map { rect ->
            val path = Path().apply { addRect(rect.left, 0f, rect.right, 1f, Path.Direction.CW) }
            NativeInlineActionFragment(line, maxOf(start, plan.rows[line].start), minOf(end, plan.rows[line].end), path, baselines[line])
        } }

    companion object {
        fun build(source: Spanned, paint: TextPaint, width: Int, occurrences: List<NativeFloatOccurrence>,
            alignment: Layout.Alignment, direction: TextDirectionHeuristic, lineSpacingExtra: Float,
            lineSpacingMultiplier: Float, requireDrainedAtBoundary: Boolean,
            carriedExclusions: List<NativeFloatExclusion>, nodeFactory: (NativeFloatGeometry) -> List<FloatInteractionNode>,
            insets: NativeTextInsets, usedLineMetrics: ((Int, Int) -> NativeUsedLineMetrics)?,
            decoration: (Canvas, NativeFloatGeometry) -> Unit,
            decorationBounds: (NativeFloatGeometry) -> NativeFloatBounds?, includeFontPadding: Boolean): NativeFloatRowGeometry {
            val plan = NativeFloatRowPlan.build(SpannedString(source), TextPaint().apply { set(paint) }, width, occurrences,
                alignment, direction, lineSpacingExtra, lineSpacingMultiplier, requireDrainedAtBoundary,
                carriedExclusions, insets, usedLineMetrics, includeFontPadding)
            return NativeFloatRowGeometry(plan, nodeFactory, decoration, decorationBounds)
        }
    }
}

private fun absSquared(value: Float): Double = value.toDouble() * value

private fun nativeFloatRowBounds(vararg values: Double) {
    if (values.any { !it.isFinite() || kotlin.math.abs(it) > TablePixelLimit })
        throw UnsupportedFloatLayout("Float image placement exceeds native coordinates")
}
