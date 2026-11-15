package app.smallthingz.dict

import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.RectF

internal data class NativeAbsoluteTextPlacement(val left: Float, val top: Float)

/** Semantic paragraphs stay intact. Child blocks retain their existing native/Compose renderer. */
internal sealed interface NativeFloatContextPart {
    data class Text(
        val text: CharSequence,
        val build: (Int, List<NativeFloatExclusion>) -> NativeFloatGeometry,
        val gapAfter: Float = 0f,
        val box: ParagraphBox? = null,
        val emptyInlineOwner: Boolean = false,
    ) : NativeFloatContextPart
    data class Rule(val id: Int, val metrics: NativeRuleMetrics,
        val containingWidth: Float? = null) : NativeFloatContextPart
    data class Flow(val id: Int, val build: (Int, List<NativeFloatExclusion>) -> NativeAnonymousFlowGeometry,
        val gapAfter: Float = 0f, val box: ParagraphBox? = null, val empty: Boolean = false) : NativeFloatContextPart
    /** Normal flow shares exclusions. Float and flex formatting contexts isolate descendants. */
    data class Container(val id: Int, val contentWidth: Int,
        val build: (Int, List<NativeFloatExclusion>) -> NativeFloatContextGeometry,
        val margins: NativeContainerMargins = FloatMargins(0f, 0f, 0f, 0f),
        val padding: FloatMargins = FloatMargins(0f, 0f, 0f, 0f),
        val floatSide: TableFloatSide? = null, val clear: FigureClear? = null,
        val empty: Boolean = false, val isolatesFloats: Boolean = false,
        val innerMargins: NativeAdjoiningMargins? = null,
        val buildAdjoining: ((Int, List<NativeFloatExclusion>, NativeMarginCollapse) -> NativeFloatContextGeometry)? = null,
        val preparedParts: List<NativeFloatContextPart>? = null,
        val horizontal: NativeContainerHorizontal? = null,
        val row: NativeFlexRowPolicy? = null,
        val flexCrossMargins: NativeFlexCrossMargins = NativeFlexCrossMargins(),
        val fixedContentHeight: Float? = null,
        val columns: NativeColumnPolicy? = null,
        val minimum: NativeContainerMinimum = NativeContainerMinimum(0f, false),
        val headingAllocation: NativeSectionHeadingAllocation? = null,
        val absolute: NativeAbsoluteTextPlacement? = null,
        val positionedScope: Boolean = false,
    ) : NativeFloatContextPart {
        init { require(fixedContentHeight == null || fixedContentHeight.isFinite() && fixedContentHeight >= 0f) }
        fun contentHeight(natural: Float): Float = maxOf(0f, fixedContentHeight ?: natural, minimum.content)
        fun childCollapse(inner: NativeAdjoiningMargins): NativeMarginCollapse {
            val before = floatSide == null && !isolatesFloats && padding.top == 0f
            // A positive computed minimum blocks bottom escape only for the set
            // which also adjoins this parent's top; ordinary last-child bottoms escape.
            val after = floatSide == null && !isolatesFloats && padding.bottom == 0f && fixedContentHeight == null &&
                !(minimum.computedPositive && before && inner.through)
            return NativeMarginCollapse(before, after)
        }
    }
    data class Child(
        val id: Int,
        val widthRule: NativeBlockWidth,
        val measure: (NativeBlockMeasureRequest) -> NativeBlockMeasure,
        val gapAfter: Float = 0f,
        val floatSide: TableFloatSide? = null,
        val margins: FloatMargins = FloatMargins(0f, 0f, 0f, 0f),
        val requiresUnobstructedText: Boolean = false,
        val gapBefore: Float = 0f,
        val clear: FigureClear? = null,
        val logicalObject: Boolean = true,
        val autoMarginBox: NativeTableMarginBox? = null,
        val autoMargins: NativeTableAutoMargins? = null,
        val containingDirection: TableContainingDirection? = null,
        val fixedMarginBox: NativeTableMarginBox? = null,
        val fixedMarginDirection: TableContainingDirection? = null,
        val pairedViewportDirection: TableContainingDirection? = null,
    ) : NativeFloatContextPart
}

internal data class PlacedFloatContextChild(val id: Int, val offset: Int, val bounds: RectF,
    val logicalObject: Boolean = true)

internal data class PlacedNativeContextText(val geometry: FloatTextGeometry, val x: Float, val y: Float)
internal data class NativeContextInputLeaf(val sourceIndex: Int, val offset: Int,
    val x: Float, val y: Float, val geometry: FloatTextGeometry, val nodeBase: Int)

/**
 * One selection/accessibility owner across native paragraphs. A delegated table is one object in
 * the parent's logical stream and keeps its original independent cell selection/semantics tree.
 * Child positions come from whole-height float exclusion, never an implicit clear at a boundary.
 */
internal class NativeFloatContextGeometry private constructor(
    override val width: Int,
    override val text: CharSequence,
    override val height: Int,
    val usedHeight: Float,
    private val paragraphs: List<Paragraph>,
    val children: List<PlacedFloatContextChild>,
    val partOffsets: List<Int>,
    val flowChildren: List<PlacedFloatContextChild>,
    val textBottom: Float,
    val ownExclusions: List<NativeFloatExclusion>,
    val adjoiningMargins: NativeAdjoiningMargins? = null,
    val marginPlacements: Map<Int, NativeMarginPlacement> = emptyMap(),
    val ordinaryBounds: Map<Int, RectF> = emptyMap(),
    val clearanceById: Map<Int, Float> = emptyMap(),
    val structuralMargins: NativeAdjoiningMargins? = null,
    private val hardSeparators: Set<Int> = emptySet(),
) : FloatTextGeometry {
    private data class Paragraph(val partIndex: Int, val offset: Int, val x: Float, val y: Float, val geometry: FloatTextGeometry,
        val textBottom: Float, val paintHere: Boolean = true, val ordinary: Boolean = false,
        val outOfFlow: Boolean = false)
    override val textBaselines: NativeTextBaselines? by lazy {
        val lines = paragraphs.filterNot { it.outOfFlow }.mapNotNull { it.geometry.textBaselines?.translated(it.y) }
        NativeTextBaselines.of(lines.firstNotNullOfOrNull { it.first },
            lines.asReversed().firstNotNullOfOrNull { it.last })
    }
    private val textParagraphs: List<Paragraph> by lazy { paragraphs.filterNot { paragraph ->
        paragraph.geometry is NativeRuleGeometry || paragraph.ordinary &&
            (paragraph.geometry as NativeFloatContextGeometry).onlyRuleContent
    } }
    private val onlyRuleContent: Boolean get() = paragraphs.isNotEmpty() && textParagraphs.isEmpty() &&
        children.none { it.logicalObject }
    fun textPaintPart(index: Int): PlacedNativeContextText? = paragraphs.firstOrNull {
        it.partIndex == index && it.paintHere
    }?.let { PlacedNativeContextText(it.geometry, it.x, it.y) } ?: paragraphs.firstNotNullOfOrNull { p ->
        if (!p.ordinary) null else (p.geometry as NativeFloatContextGeometry).textPaintPart(index)?.let {
            it.copy(x = it.x + p.x, y = it.y + p.y)
        }
    }
    fun inputLeaves(): List<NativeContextInputLeaf> {
        val result = mutableListOf<NativeContextInputLeaf>()
        var nodeBase = 0
        fun collect(context: NativeFloatContextGeometry, x: Float, y: Float, offset: Int) {
            context.paragraphs.forEach { p ->
                if (p.ordinary) collect(p.geometry as NativeFloatContextGeometry, x + p.x, y + p.y, offset + p.offset)
                else {
                    result += NativeContextInputLeaf(p.partIndex, offset + p.offset, x + p.x, y + p.y, p.geometry, nodeBase)
                    nodeBase += p.geometry.nodes.size
                }
            }
        }
        collect(this, 0f, 0f, 0)
        check(nodeBase == nodes.size)
        return result
    }
    override val nodes: List<FloatInteractionNode> = paragraphs.flatMap { paragraph ->
        paragraph.geometry.nodes.map { node -> node.translated(paragraph.x, paragraph.y).copy(
            // Source offsets are stable and unique across semantic parts, unlike per-part IDs.
            id = node.id,
            start = paragraph.offset + node.start, end = paragraph.offset + node.end,
        ) }
    }.mapIndexed { index, node -> node.copy(id = index) }
    fun positionedGroupsAtSource(source: Int): List<NativePositionedGroup> = inputLeaves()
        .filter { it.sourceIndex == source }.flatMap { leaf -> leaf.geometry.positionedGroups.map { group ->
            group.translated(leaf.x, leaf.y, leaf.offset) { id ->
                leaf.nodeBase + leaf.geometry.nodes.indexOfFirst { it.id == id }.also { check(it >= 0) }
            }
        } }
    override val positionedGroups: List<NativePositionedGroup> by lazy {
        inputLeaves().map { it.sourceIndex }.distinct().flatMap(::positionedGroupsAtSource)
    }
    override val ordinaryPaintBounds: List<NativeFloatBounds> by lazy {
        listOfNotNull(nativeBoundsOf(children.map { it.bounds } + ordinaryBounds.values)) +
            paragraphs.flatMap { paragraph -> paragraph.geometry.ordinaryPaintBounds.map {
                it.translated(paragraph.x, paragraph.y)
            } }
    }
    override val extents: NativeGeometryExtents by lazy {
        paragraphs.fold(NativeGeometryExtents(width, usedHeight,
            nativeBoundsOf(children.map { it.bounds } + ordinaryBounds.values), nativeBoundsOf(children.map { it.bounds }))) { area, paragraph ->
            area.including(paragraph.geometry.extents, paragraph.x, paragraph.y)
        }
    }
    /** Layout boxes and selectable advances define scrollable overflow. Glyph ink is separate. */
    val scrollableBounds: NativeFloatBounds by lazy {
        var bounds = NativeFloatBounds(0f, 0f, width.toFloat(), usedHeight)
        for (rect in children.map { it.bounds } + ordinaryBounds.values) {
            bounds = bounds.enclosing(NativeFloatBounds(rect.left, rect.top, rect.right, rect.bottom))
        }
        ownExclusions.forEach { bounds = bounds.enclosing(it.outer) }
        paragraphs.forEach { p ->
            val child = when (val geometry = p.geometry) {
                is NativeFloatContextGeometry -> geometry.scrollableBounds
                is NativeFloatGeometry -> geometry.scrollableBounds
                is NativeAnonymousFlowGeometry -> geometry.scrollableBounds
                is NativeRuleGeometry -> NativeFloatBounds(0f, 0f, geometry.contentWidth, geometry.extents.usedHeight)
                is NativeTableViewportGeometry -> geometry.focusBounds.let { NativeFloatBounds(it.left, it.top, it.right, it.bottom) }
                else -> throw UnsupportedFloatLayout("Child scrollable layout bounds are unavailable")
            }
            if (p.outOfFlow && (child.right <= child.left || child.bottom <= child.top)) return@forEach
            bounds = bounds.enclosing(NativeFloatBounds(child.left + p.x, child.top + p.y,
                child.right + p.x, child.bottom + p.y))
        }
        bounds
    }
    override fun containsInteraction(x: Float, y: Float): Boolean =
        children.any { it.bounds.contains(x, y) } ||
            paragraphs.any { it.geometry.containsInteraction(x - it.x, y - it.y) }
    override fun paint(canvas: Canvas) {
        paintOrdinary(canvas)
        positionedGroups.forEach { it.paint(canvas) }
    }
    override fun paintOrdinary(canvas: Canvas) {
        paragraphs.filter { it.paintHere }.forEach { paragraph -> val saved = canvas.save()
            canvas.translate(paragraph.x, paragraph.y); paragraph.geometry.paintOrdinary(canvas); canvas.restoreToCount(saved) }
    }
    override fun offsetForPosition(x: Float, y: Float): Int {
        children.lastOrNull { it.bounds.contains(x, y) }?.let { return it.offset }
        paragraphs.lastOrNull { it.geometry.containsInteraction(x - it.x, y - it.y) }?.let {
            return it.offset + it.geometry.offsetForPosition(x - it.x, y - it.y)
        }
        val paragraph = if (hasColumnFragments) textParagraphs.minByOrNull { p ->
            distanceForParagraph(p, x - p.x, y - p.y)
        } else textParagraphs.minByOrNull { p -> when {
            y < p.y -> p.y - y
            y > p.y + p.textBottom -> y - p.y - p.textBottom
            else -> 0f
        } }
        paragraph ?: return 0
        return paragraph.offset + paragraph.geometry.offsetForPosition(x - paragraph.x, y - paragraph.y)
    }
    private val hasColumnFragments: Boolean get() = paragraphs.any { p -> when (val g = p.geometry) {
        is NativeFloatGeometry -> g.hasColumnFragments
        is NativeFloatContextGeometry -> g.hasColumnFragments
        else -> false
    } }
    private fun distanceForParagraph(paragraph: Paragraph, x: Float, y: Float): Double = when (val g = paragraph.geometry) {
        is NativeFloatGeometry -> g.distanceForPosition(x, y)
        is NativeFloatContextGeometry -> g.textParagraphs.minOfOrNull { p ->
            g.distanceForParagraph(p, x - p.x, y - p.y)
        } ?: Double.POSITIVE_INFINITY
        else -> {
            val dx = maxOf(-x, 0f, x - g.width).toDouble()
            val dy = maxOf(-y, 0f, y - paragraph.textBottom).toDouble()
            dx * dx + dy * dy
        }
    }
    private fun paragraphAt(offset: Int): Paragraph? = textParagraphs.lastOrNull { offset >= it.offset }
        ?.takeIf { offset <= it.offset + it.geometry.text.length }
    override fun revealOffset(offset: Int, onRevealed: () -> Unit) {
        require(offset in 0..text.length)
        paragraphAt(offset)?.let { it.geometry.revealOffset(offset - it.offset, onRevealed); return }
        if (children.any { it.logicalObject && it.offset == offset }) { onRevealed(); return }
        val next = textParagraphs.firstOrNull { it.offset > offset }
        if (next == null) onRevealed() else next.geometry.revealOffset(0, onRevealed)
    }
    override fun clipForOffset(offset: Int): RectF? {
        require(offset in 0..text.length)
        val paragraph = paragraphAt(offset)
        if (paragraph != null) return paragraph.geometry.clipForOffset(offset - paragraph.offset)
            ?.let { RectF(it).apply { offset(paragraph.x, paragraph.y) } }
        if (children.any { it.logicalObject && it.offset == offset }) return null
        val next = textParagraphs.firstOrNull { it.offset > offset } ?: return null
        return next.geometry.clipForOffset(0)?.let { RectF(it).apply { offset(next.x, next.y) } }
    }
    override val hasPreciseClips: Boolean get() = paragraphs.any { it.geometry.hasPreciseClips }
    override fun preciseClipForOffset(offset: Int): NativeTextClip? {
        require(offset in 0..text.length)
        val paragraph = paragraphAt(offset)
        if (paragraph != null) return paragraph.geometry.preciseClipForOffset(offset - paragraph.offset)?.translated(paragraph.x, paragraph.y)
        if (children.any { it.logicalObject && it.offset == offset }) return null
        val next = textParagraphs.firstOrNull { it.offset > offset } ?: return null
        return next.geometry.preciseClipForOffset(0)?.translated(next.x, next.y)
    }
    override fun paintSelection(canvas: Canvas, start: Int, end: Int, paint: Paint) {
        require(start in 0..text.length && end in start..text.length)
        paragraphs.forEach { paragraph ->
            val first = maxOf(0, start - paragraph.offset)
            val last = minOf(paragraph.geometry.text.length, end - paragraph.offset)
            if (first < last) {
                val saved = canvas.save()
                try { canvas.translate(paragraph.x, paragraph.y); paragraph.geometry.paintSelection(canvas, first, last, paint) }
                finally { canvas.restoreToCount(saved) }
            }
        }
        children.filter { it.logicalObject && it.offset in start until end }.forEach { canvas.drawRect(it.bounds, paint) }
    }
    override fun cursorAt(x: Float, y: Float): InlineCursor? {
        val positioned = paragraphs.asReversed().firstOrNull { paragraph ->
            paragraph.geometry.positionedGroups.any { it.contains(x - paragraph.x, y - paragraph.y) }
        }
        if (positioned != null) return positioned.geometry.cursorAt(x - positioned.x, y - positioned.y)
        if (children.any { it.bounds.contains(x, y) }) return null
        val paragraph = paragraphs.asReversed().firstOrNull {
            it.geometry.containsInteraction(x - it.x, y - it.y) || it.geometry.containsInput(x - it.x, y - it.y)
        } ?: return null
        return paragraph.geometry.cursorAt(x - paragraph.x, y - paragraph.y)
    }
    override fun horizontalScrollTargetAt(x: Float, y: Float): NativeHorizontalScrollTarget? {
        val positioned = paragraphs.asReversed().firstOrNull { paragraph ->
            paragraph.geometry.positionedGroups.any { it.contains(x - paragraph.x, y - paragraph.y) }
        }
        if (positioned != null) return positioned.geometry.horizontalScrollTargetAt(x - positioned.x, y - positioned.y)
        if (children.any { it.bounds.contains(x, y) }) return null
        val paragraph = paragraphs.asReversed().firstOrNull { it.geometry.containsInteraction(x - it.x, y - it.y) }
            ?: paragraphs.asReversed().firstOrNull { it.geometry.containsInput(x - it.x, y - it.y) }
            ?: return null
        return paragraph.geometry.horizontalScrollTargetAt(x - paragraph.x, y - paragraph.y)
    }
    override fun caretRect(offset: Int): RectF {
        require(offset in 0..text.length)
        paragraphAt(offset)?.let { return it.geometry.caretRect(offset - it.offset).apply { offset(it.x, it.y) } }
        children.firstOrNull { it.logicalObject && it.offset == offset }?.let { return RectF(it.bounds.left, it.bounds.top, it.bounds.left + 1, it.bounds.bottom) }
        val next = textParagraphs.firstOrNull { it.offset > offset }
        return next?.geometry?.caretRect(0)?.apply { offset(next.x, next.y) } ?: RectF(0f, height.toFloat(), 1f, height.toFloat())
    }
    override fun rectsForRange(start: Int, end: Int): List<RectF> {
        require(start in 0..text.length && end in start..text.length)
        return buildList {
            paragraphs.forEach { paragraph ->
                val first = maxOf(0, start - paragraph.offset)
                val last = minOf(paragraph.geometry.text.length, end - paragraph.offset)
                if (first < last) addAll(paragraph.geometry.rectsForRange(first, last).map { RectF(it).apply { offset(paragraph.x, paragraph.y) } })
            }
            children.filter { it.logicalObject && it.offset in start until end }.forEach { add(RectF(it.bounds)) }
        }
    }
    override fun characterRects(start: Int, length: Int): List<RectF?> {
        require(start in 0..text.length && length >= 0 && length <= text.length - start)
        return (start until start + length).map { offset ->
            val paragraph = paragraphAt(offset)?.takeIf { offset < it.offset + it.geometry.text.length }
            if (paragraph != null) paragraph.geometry.characterRects(offset - paragraph.offset, 1).single()
                ?.let { RectF(it).apply { offset(paragraph.x, paragraph.y) } }
            else children.firstOrNull { it.logicalObject && it.offset == offset }?.let { RectF(it.bounds) }
        }
    }
    override fun lineRange(offset: Int): Pair<Int, Int> {
        require(offset in 0..text.length)
        paragraphAt(offset)?.let { paragraph ->
            val local = paragraph.geometry.lineRange(offset - paragraph.offset)
            val end = paragraph.offset + local.second
            // The separator belongs to the preceding native line, exactly like Layout.getLineEnd.
            val withSeparator = if (local.second == paragraph.geometry.text.length && end in hardSeparators) end + 1 else end
            return (paragraph.offset + local.first) to withSeparator
        }
        children.firstOrNull { it.logicalObject && (offset == it.offset || (offset == it.offset + 1 && offset in hardSeparators)) }?.let {
            val end = it.offset + 1
            return it.offset to if (end in hardSeparators) end + 1 else end
        }
        return offset to minOf(text.length, offset + 1)
    }
    override fun visualLineRanges(offset: Int): List<Pair<Int, Int>> {
        require(offset in 0..text.length)
        paragraphAt(offset)?.let { paragraph ->
            return paragraph.geometry.visualLineRanges(offset - paragraph.offset).map { range ->
                val end = paragraph.offset + range.second
                // Preserve the existing paragraph separator only on its ending fragment.
                val withSeparator = if (range.second == paragraph.geometry.text.length &&
                    end in hardSeparators) end + 1 else end
                (paragraph.offset + range.first) to withSeparator
            }
        }
        return listOf(lineRange(offset))
    }
    override fun isHardLineBreak(offset: Int): Boolean {
        require(offset in 0 until text.length)
        val paragraph = paragraphs.firstOrNull { offset >= it.offset && offset < it.offset + it.geometry.text.length }
        return paragraph?.let { it.geometry.isHardLineBreak(offset - it.offset) } ?: (offset in hardSeparators)
    }
    override fun visualOffset(offset: Int, direction: Int): Int {
        require(offset in 0..text.length && direction in listOf(-1, 1))
        paragraphAt(offset)?.let { p ->
            val moved = p.geometry.visualOffset(offset - p.offset, direction) + p.offset
            if (moved != offset) return moved
        }
        return if ((direction < 0 && offset == 0) || (direction > 0 && offset == text.length)) offset
            else Character.offsetByCodePoints(text, offset, direction)
    }

    companion object {
        /** Shape each semantic paragraph once at the column width, then balance its real
         * native line boxes. The original paragraph owner and global source index survive. */
        internal fun buildPreparedColumns(width: Int, available: Float,
            parts: List<NativeFloatContextPart>, policy: NativeColumnPolicy,
            preparation: NativeOrdinaryPreparation): NativeFloatContextGeometry {
            val columnWidth = policy.width(available)
            val nativeWidth = kotlin.math.floor(columnWidth).toInt()
            val shaped = parts.map { part ->
                val item = part as? NativeFloatContextPart.Text
                    ?: throw UnsupportedFloatLayout("Column fragmentation for this child layout is unavailable")
                val box = item.box
                if (box != null && (box.padding.top != 0f || box.padding.bottom != 0f ||
                        box.before != 0f || box.margins.top != 0f || box.margins.bottom != 0f))
                    throw UnsupportedFloatLayout("Fragmented paragraph vertical edges are unavailable")
                if (box != null && item.text.isEmpty() && !hasNativeInlineLayoutOwner(item.text)) return@map null
                val contentWidth = kotlin.math.floor(maxOf(0f, nativeWidth -
                    (box?.contentLeft ?: 0f) - (box?.contentRight ?: 0f))).toInt()
                item.build(contentWidth, emptyList()).also {
                    check(it.text.toString() == item.text.toString()) { "Column shaping changed its logical source" }
                }
            }
            val lines = buildList {
                shaped.forEachIndexed { index, geometry ->
                    if (geometry == null) return@forEachIndexed
                    for (line in 0 until geometry.shapedLineCount) add(NativeColumnLine(index, line,
                        geometry.usedLineHeight(line), if (line == 0 && index > 0)
                            (parts[index - 1] as NativeFloatContextPart.Text).let { it.box?.after ?: it.gapAfter } else 0f))
                }
            }
            val balance = balanceNativeColumns(lines, policy.count)
            val paragraphs = mutableListOf<Paragraph>()
            val offsets = mutableListOf<Int>()
            val text = StringBuilder()
            val hardSeparators = mutableSetOf<Int>()
            var cursor = 0
            var seenLogical = false
            shaped.forEachIndexed { index, geometry ->
                val part = parts[index] as NativeFloatContextPart.Text
                val sourceIndex = preparation.sourceIndex(part)
                if (geometry != null && seenLogical) { hardSeparators += text.length; text.append('\n') }
                if (geometry != null) seenLogical = true
                offsets += text.length
                if (geometry == null) return@forEachIndexed
                val localLeft = part.box?.contentLeft ?: 0f
                val origins = List(geometry.shapedLineCount) {
                    val position = balance.placements[cursor++]
                    (policy.left(position.column, available) + localLeft) to position.top
                }
                val fragmented = geometry.inColumns(origins)
                paragraphs += Paragraph(sourceIndex, text.length, 0f, 0f, fragmented, balance.height)
                text.append(fragmented.text)
            }
            return NativeFloatContextGeometry(width, text.toString(), kotlin.math.ceil(balance.height).toInt(),
                balance.height, paragraphs, emptyList(), offsets, emptyList(), balance.height, emptyList(),
                NativeAdjoiningMargins(0f, 0f, false), emptyMap(), emptyMap(), emptyMap(), NativeAdjoiningMargins(0f, 0f, false),
                hardSeparators = hardSeparators.toSet())
        }

        /** Flex items own their contents' formatting contexts; the same global leaf slots
         * supply their native geometry. Source order remains the logical/paint order in RTL. */
        internal fun buildPreparedRow(width: Int, available: Float, parts: List<NativeFloatContextPart>,
            policy: NativeFlexRowPolicy, preparation: NativeOrdinaryPreparation,
            fixedContentHeight: Float? = null): NativeFloatContextGeometry {
            require(width >= 0 && available.isFinite() && available >= 0f && available <= TablePixelLimit)
            val items = parts.map { it as? NativeFloatContextPart.Container
                ?: throw UnsupportedFloatLayout("A prepared row requires complete logical item owners") }
            val geometries = items.map { item ->
                check(item.floatSide == null && item.clear == null && item.isolatesFloats && item.preparedParts != null)
                preparation.measurePreparedContainer(item, emptyList(), NativeMarginCollapse(false, false))
            }
            val heights = items.indices.map { index ->
                items[index].padding.top + items[index].contentHeight(geometries[index].usedHeight) + items[index].padding.bottom
            }
            val lineHeight = fixedContentHeight ?: items.indices.maxOfOrNull { index ->
                heights[index] + items[index].margins.top + items[index].margins.bottom
            } ?: 0f
            if (!lineHeight.isFinite() || lineHeight > TablePixelLimit)
                throw UnsupportedFloatLayout("Flex row height exceeds native geometry")
            val text = StringBuilder()
            val hardSeparators = mutableSetOf<Int>()
            val paragraphs = mutableListOf<Paragraph>()
            val children = mutableListOf<PlacedFloatContextChild>()
            val flows = mutableListOf<PlacedFloatContextChild>()
            val offsets = mutableListOf<Int>()
            val bounds = mutableMapOf<Int, RectF>()
            val clearances = mutableMapOf<Int, Float>()
            var advance = 0f
            var seenLogical = false
            for (index in items.indices) {
                val item = items[index]
                val geometry = geometries[index]
                val padding = item.padding
                val margins = item.margins
                val horizontal = checkNotNull(item.horizontal)
                val cross = nativeFlexCrossPlacement(lineHeight, heights[index], margins.top, margins.bottom,
                    item.flexCrossMargins, policy.alignment, item.fixedContentHeight != null,
                    padding.top + padding.bottom)
                val borderLeft = if (policy.rtl) available - advance - margins.right - horizontal.borderWidth
                    else advance + margins.left
                val x = borderLeft + padding.left
                val top = cross.top + padding.top
                advance += margins.left + horizontal.borderWidth + margins.right
                if (!advance.isFinite() || advance > TablePixelLimit || !borderLeft.isFinite() || kotlin.math.abs(borderLeft) > TablePixelLimit)
                    throw UnsupportedFloatLayout("Flex row width exceeds native geometry")
                if (geometry.text.isNotEmpty()) {
                    if (seenLogical) { hardSeparators += text.length; text.append('\n') }
                    seenLogical = true
                }
                offsets += geometry.partOffsets.map { it + text.length }
                paragraphs += Paragraph(-1, text.length, x, top, geometry, geometry.textBottom, ordinary = true)
                children += geometry.children.map { it.copy(offset = it.offset + text.length,
                    bounds = RectF(it.bounds).apply { offset(x, top) }, logicalObject = false) }
                flows += geometry.flowChildren.map { it.copy(offset = it.offset + text.length,
                    bounds = RectF(it.bounds).apply { offset(x, top) }) }
                bounds.putAll(geometry.ordinaryBounds.mapValues { (_, box) -> RectF(box).apply { offset(x, top) } })
                bounds[item.id] = RectF(borderLeft, cross.top, borderLeft + horizontal.borderWidth, cross.top + cross.borderHeight)
                clearances.putAll(geometry.clearanceById)
                text.append(geometry.text)
            }
            val structural = NativeAdjoiningMargins(0f, 0f, items.isEmpty())
            return NativeFloatContextGeometry(width, text.toString(), kotlin.math.ceil(lineHeight).toInt(),
                lineHeight, paragraphs, children, offsets, flows, lineHeight, emptyList(), structural,
                ordinaryBounds = bounds, clearanceById = clearances, structuralMargins = structural,
                hardSeparators = hardSeparators.toSet())
        }

        /** Export one already measured local viewport through the existing Container owner. */
        fun viewport(body: NativeTableViewportGeometry, usedHeight: Float): NativeFloatContextGeometry {
            require(usedHeight.isFinite() && usedHeight >= 0f && kotlin.math.ceil(usedHeight).toInt() <= body.height)
            val margins = NativeAdjoiningMargins(0f, 0f, false)
            return NativeFloatContextGeometry(body.width, body.text, body.height, usedHeight,
                listOf(Paragraph(0, 0, 0f, 0f, body, usedHeight)), emptyList(), listOf(0), emptyList(),
                usedHeight, emptyList(), margins, structuralMargins = margins)
        }

        fun adjoiningMarginsFor(parts: List<NativeFloatContextPart>): NativeAdjoiningMargins =
            NativeAdjoiningMargins.sequence(parts.mapNotNull { adjoiningProfile(it) })

        internal fun adjoiningProfile(part: NativeFloatContextPart, preparation: NativeOrdinaryPreparation? = null): NativeAdjoiningMargins? = when (part) {
            is NativeFloatContextPart.Text -> paragraphMargins(part.box, part.emptyInlineOwner ||
                part.box != null && part.text.isEmpty() && !hasNativeInlineLayoutOwner(part.text), part.gapAfter)
            is NativeFloatContextPart.Flow -> paragraphMargins(part.box, part.empty, part.gapAfter)
            is NativeFloatContextPart.Rule -> part.metrics.adjoining
            is NativeFloatContextPart.Child -> {
                if (part.gapBefore != 0f || part.gapAfter != 0f)
                    throw UnsupportedFloatLayout("Legacy component gaps are not authored adjoining margins")
                if (part.floatSide != null) null else NativeAdjoiningMargins(part.margins.top, part.margins.bottom, false)
            }
            is NativeFloatContextPart.Container -> if (part.absolute != null) null else {
                val inner = part.preparedParts?.let { children -> NativeAdjoiningMargins.sequence(
                    children.mapNotNull { adjoiningProfile(it, preparation) }) }
                    ?: preparation?.innerMargins(part) ?: part.innerMargins
                    ?: throw UnsupportedFloatLayout("Container structural margins are not prepared")
                if (part.floatSide != null) null else {
                    val collapse = part.childCollapse(inner)
                    val before = NativeMarginStrut.of(part.margins.top).let { if (collapse.before) it.join(inner.beforeSet) else it }
                    val after = NativeMarginStrut.of(part.margins.bottom).let { if (collapse.after) it.join(inner.afterSet) else it }
                    val through = inner.through && collapse.before && part.padding.bottom == 0f &&
                        !part.minimum.computedPositive && (part.fixedContentHeight == null || part.fixedContentHeight == 0f)
                    NativeAdjoiningMargins(before, after, through)
                }
            }
        }?.let { profile -> if (preparation?.hasClearance(part) == true)
            profile.copy(beforeAdjoins = false, afterAdjoins = !profile.through) else profile }

        private fun paragraphMargins(box: ParagraphBox?, empty: Boolean, gap: Float): NativeAdjoiningMargins {
            if (box == null && gap != 0f) throw UnsupportedFloatLayout("Implicit paragraph gaps have no container margin authority")
            return NativeAdjoiningMargins(box?.margins?.top ?: 0f, box?.margins?.bottom ?: 0f,
                empty && (box?.padding?.top ?: 0f) == 0f && (box?.padding?.bottom ?: 0f) == 0f)
        }

        private fun onlyRules(part: NativeFloatContextPart): Boolean = part is NativeFloatContextPart.Rule ||
            part is NativeFloatContextPart.Container && !part.preparedParts.isNullOrEmpty() && part.preparedParts.all(::onlyRules)

        fun build(width: Int, parts: List<NativeFloatContextPart>, containAtEnd: Boolean = true,
            carriedExclusions: List<NativeFloatExclusion> = emptyList(), allowProtrudingFloats: Boolean = false,
            adjoining: Boolean = false, marginCollapse: NativeMarginCollapse = NativeMarginCollapse(false, false),
            preparation: NativeOrdinaryPreparation? = null, bodyAdjoining: Boolean = false,
            absoluteScope: Boolean = false): NativeFloatContextGeometry {
            require(width >= 0)
            if (bodyAdjoining && (!adjoining || marginCollapse != NativeMarginCollapse(true, true) ||
                    !containAtEnd || carriedExclusions.isNotEmpty()))
                throw UnsupportedFloatLayout("Ordinary body requires its complete root margin boundary")
            val text = StringBuilder()
            val hardSeparators = mutableSetOf<Int>()
            val paragraphs = mutableListOf<Paragraph>()
            val children = mutableListOf<PlacedFloatContextChild>()
            val flowChildren = mutableListOf<PlacedFloatContextChild>()
            val exclusions = carriedExclusions.toMutableList()
            val partOffsets = mutableListOf<Int>()
            val prepared = if (adjoining) preparation ?: NativeOrdinaryPreparation(parts) else null
            if (bodyAdjoining) checkNotNull(prepared).resolveBodyLeading(parts, width)
            val ordinaryBounds = mutableMapOf<Int, RectF>()
            val clearanceById = mutableMapOf<Int, Float>()
            val cursor = if (adjoining) NativeMarginCursor(marginCollapse) else null
            val marginPlacements = mutableMapOf<Int, NativeMarginPlacement>()
            var y = 0f
            var logicalPartSeen = false
            parts.forEachIndexed { partIndex, part ->
                val emptyBox = part is NativeFloatContextPart.Text && (part.emptyInlineOwner ||
                    part.box != null && part.text.isEmpty() && !hasNativeInlineLayoutOwner(part.text)) ||
                    part is NativeFloatContextPart.Flow && part.empty || part is NativeFloatContextPart.Container && part.empty
                val logicalPart = !emptyBox && !onlyRules(part) &&
                    (part !is NativeFloatContextPart.Child || part.logicalObject)
                if (logicalPart && logicalPartSeen) { // A semantic block boundary, never a visual wrap.
                    hardSeparators += text.length; text.append('\n')
                }
                if (logicalPart) logicalPartSeen = true
                if (part !is NativeFloatContextPart.Container || part.preparedParts == null) partOffsets += text.length
                if (part is NativeFloatContextPart.Container && part.absolute != null) {
                    val at = part.absolute
                    if (!absoluteScope || !adjoining || part.preparedParts == null || part.contentWidth != width ||
                        part.floatSide != null || part.clear != null || part.row != null || part.columns != null ||
                        part.fixedContentHeight != 0f || part.minimum.content != 0f || part.minimum.computedPositive ||
                        part.padding != FloatMargins(0f, 0f, 0f, 0f) ||
                        listOf(part.margins.top, part.margins.right, part.margins.bottom, part.margins.left).any { it != 0f } ||
                        part.preparedParts.any { it !is NativeFloatContextPart.Text } ||
                        listOf(at.left, at.top).any { !it.isFinite() || kotlin.math.abs(it) > TablePixelLimit })
                        throw UnsupportedFloatLayout("Absolute text requires its direct zero-edge positioned scope")
                    val geometry = checkNotNull(prepared).measurePreparedContainer(part, emptyList(), NativeMarginCollapse(false, false))
                    if (geometry.ownExclusions.isNotEmpty() || geometry.children.isNotEmpty() || geometry.flowChildren.isNotEmpty())
                        throw UnsupportedFloatLayout("Absolute text cannot introduce replaced or floating content")
                    partOffsets += geometry.partOffsets.map { it + text.length }
                    paragraphs += Paragraph(-1, text.length, at.left, at.top, geometry, geometry.textBottom,
                        ordinary = true, outOfFlow = true)
                    // A zero-area border adds no scroll area; its actual descendant line boxes
                    // and ink remain exported independently of the normal-flow cursor.
                    text.append(geometry.text)
                    return@forEachIndexed
                }
                if (part is NativeFloatContextPart.Container && part.preparedParts != null &&
                    part.floatSide == null && !part.isolatesFloats) {
                    if (cursor == null) throw UnsupportedFloatLayout("Prepared ordinary groups require adjoining layout")
                    prepared!!.resolve(part, exclusions) { profile -> cursor.preview(profile,
                        nativeClearBottom(part.clear, exclusions), prepared.hasClearance(part)).borderTop }
                }
                var profile = if (adjoining) adjoiningProfile(part, prepared) else null
                var marginPlacement = if (cursor != null && profile != null) {
                    val bottom = nativeClearBottom(nativeClearForPart(part), exclusions)
                    cursor.begin(profile, bottom, prepared?.hasClearance(part) == true).also { marginPlacements[partIndex] = it; y = it.borderTop }
                } else null
                if (marginPlacement?.clearance != null) {
                    prepared!!.markClearance(part)
                    profile = adjoiningProfile(part, prepared)
                }
                if (cursor != null && profile == null) y = cursor.floatTop
                var borderTop = y
                when (part) {
                    is NativeFloatContextPart.Text -> {
                        require(part.gapAfter.isFinite() && part.gapAfter >= 0)
                        val box = part.box
                        y += (if (adjoining) 0f else box?.before ?: 0f) + (box?.padding?.top ?: 0f)
                        val x = box?.contentLeft ?: 0f
                        val available = kotlin.math.floor(width - x - (box?.contentRight ?: 0f)).toInt().coerceAtLeast(0)
                        if (emptyBox) {
                            y += (box?.padding?.bottom ?: 0f) + if (adjoining) 0f else part.gapAfter
                            if (marginPlacement != null) cursor!!.end(marginPlacement, y - borderTop, profile!!)
                            return@forEachIndexed
                        }
                        val carried = exclusions.filter { it.outer.bottom > y }.map { it.copy(outer = it.outer.translated(-x, -y)) }
                        val geometry = part.build(available, carried)
                        check(geometry.text.toString() == part.text.toString()) { "Native paragraph changed its logical source" }
                        paragraphs += Paragraph(prepared?.sourceIndex(part) ?: partIndex, text.length, x, y, geometry, geometry.textBottom)
                        text.append(part.text)
                        geometry.floats.forEach { placed -> exclusions += NativeFloatExclusion(placed.occurrence.side,
                            NativeFloatBounds(placed.outer.left + x, placed.outer.top + y, placed.outer.right + x, placed.outer.bottom + y)) }
                        y += geometry.textBottom + (box?.padding?.bottom ?: 0f) + if (adjoining) 0f else part.gapAfter
                    }
                    is NativeFloatContextPart.Rule -> {
                        if (!adjoining) throw UnsupportedFloatLayout("Authored rule requires adjoining margin ownership")
                        val available = part.containingWidth ?: width.toFloat()
                        if (!available.isFinite() || available < 0f || kotlin.math.floor(available).toInt() != width)
                            throw UnsupportedFloatLayout("Authored rule containing width differs from its native allocation")
                        val metrics = part.metrics
                        val contentWidth = metrics.contentWidth(available)
                        // The shared owner has not proved separator/float paint and hit order.
                        // Preserve its actual width and refuse only intersecting separator geometry.
                        if (metrics.positive && contentWidth > 0f && exclusions.any {
                                maxOf(metrics.margins.left, it.outer.left) < minOf(metrics.margins.left + contentWidth, it.outer.right) &&
                                    maxOf(y, it.outer.top) < minOf(y + metrics.height, it.outer.bottom)
                            }) throw UnsupportedFloatLayout("Authored rule overlaps a float without shared paint and hit order")
                        val geometry = NativeRuleGeometry(contentWidth, metrics, metrics.allocatedWidth(available))
                        paragraphs += Paragraph(prepared?.sourceIndex(part) ?: partIndex, text.length, metrics.margins.left, y,
                            geometry, metrics.height)
                        y += metrics.height
                    }
                    is NativeFloatContextPart.Flow -> {
                        require(part.gapAfter.isFinite() && part.gapAfter >= 0)
                        val box = part.box
                        y += (if (adjoining) 0f else box?.before ?: 0f) + (box?.padding?.top ?: 0f)
                        val x = box?.contentLeft ?: 0f
                        val available = kotlin.math.floor(width - x - (box?.contentRight ?: 0f)).toInt().coerceAtLeast(0)
                        if (part.empty) {
                            y += (box?.padding?.bottom ?: 0f) + if (adjoining) 0f else part.gapAfter
                            if (marginPlacement != null) cursor!!.end(marginPlacement, y - borderTop, profile!!)
                            return@forEachIndexed
                        }
                        val carried = exclusions.filter { it.outer.bottom > y }.map { it.copy(outer = it.outer.translated(-x, -y)) }
                        val geometry = part.build(available, carried)
                        prepared?.checkBodyLeadingFlow(part, (box?.padding?.top ?: 0f) +
                            geometry.textBottom + (box?.padding?.bottom ?: 0f), geometry.ownExclusions.isNotEmpty())
                        paragraphs += Paragraph(prepared?.sourceIndex(part) ?: partIndex, text.length, x, y, geometry, geometry.textBottom, paintHere = false)
                        flowChildren += PlacedFloatContextChild(part.id, text.length,
                            RectF(x, y, x + geometry.width, y + geometry.height))
                        text.append(geometry.text)
                        geometry.ownExclusions.forEach { exclusion -> exclusions += exclusion.copy(
                            outer = exclusion.outer.translated(x, y)) }
                        y += geometry.textBottom + (box?.padding?.bottom ?: 0f) + if (adjoining) 0f else part.gapAfter
                    }
                    is NativeFloatContextPart.Container -> {
                        require(part.contentWidth >= 0)
                        check(part.row == null || part.isolatesFloats) { "A flex row must isolate its contents" }
                        val margin = part.margins
                        val padding = part.padding
                        if (part.headingAllocation != null && (!part.isolatesFloats || part.floatSide != null ||
                                part.preparedParts?.singleOrNull() !is NativeFloatContextPart.Text || part.row != null ||
                                part.columns != null || part.fixedContentHeight != null || part.minimum.content != 0f ||
                                part.minimum.computedPositive))
                            throw UnsupportedFloatLayout("Section heading allocation requires its single prepared title owner")
                        require(listOf(margin.top, margin.right, margin.bottom, margin.left).all { it.isFinite() })
                        require(listOf(padding.top, padding.right, padding.bottom, padding.left).all { it.isFinite() && it >= 0f })
                        if ((part.floatSide != null || part.isolatesFloats) &&
                            listOf(margin.top, margin.right, margin.bottom, margin.left).any { it < 0f } &&
                            !(part.positionedScope && part.floatSide == null && margin.left >= 0f && margin.right >= 0f))
                            throw UnsupportedFloatLayout("Signed external float or BFC margins are not supported")
                        val horizontal = part.horizontal
                        if (horizontal != null && (!adjoining ||
                                part.contentWidth != kotlin.math.floor(horizontal.content).toInt()))
                            throw UnsupportedFloatLayout("Container used width does not match its prepared native allocation")
                        var paddedWidth = horizontal?.borderWidth ?: (part.contentWidth.toFloat() + padding.left + padding.right)
                        if (!paddedWidth.isFinite() || paddedWidth > TablePixelLimit)
                            throw UnsupportedFloatLayout("Container edges exceed the native width range")
                        if (part.preparedParts != null) {
                            if (!adjoining) throw UnsupportedFloatLayout("Prepared groups require adjoining layout")
                            val isolated = part.floatSide != null || part.isolatesFloats
                            val inner = NativeAdjoiningMargins.sequence(part.preparedParts.mapNotNull { adjoiningProfile(it, prepared) })
                            val collapse = part.childCollapse(inner)
                            var x: Float
                            var top: Float
                            var placedBorderLeft: Float
                            var placedBorderTop: Float
                            val geometry: NativeFloatContextGeometry
                            if (part.floatSide != null) {
                                var built: NativeFloatContextGeometry? = null
                                val placed = placeNativeFloatingTable(width.toFloat(), tableClearanceY(y, part.clear, exclusions),
                                    exclusions, part.floatSide, margin.nonnegativeFloatMargins(), NativeBlockWidth.FixedPx(paddedWidth), pixelAligned = false) {
                                    prepared!!.measurePreparedContainer(part, emptyList(), collapse).also { built = it }.let {
                                        NativeBlockMeasure(paddedWidth, paddedWidth, padding.top + part.contentHeight(it.usedHeight) + padding.bottom)
                                    }
                                }
                                geometry = checkNotNull(built)
                                placedBorderLeft = placed.content.left
                                placedBorderTop = placed.content.top
                                x = placedBorderLeft + padding.left
                                top = placedBorderTop + padding.top
                                exclusions += NativeFloatExclusion(part.floatSide, placed.outer)
                            } else if (part.isolatesFloats && part.headingAllocation != null) {
                                val allocation = part.headingAllocation
                                var measured: NativeFloatContextGeometry? = null
                                var solved: NativeContainerHorizontal? = null
                                val placed = placeNativeFloatBlock(width.toFloat(), y, exclusions,
                                    NativeBlockWidth.Auto, pixelAligned = false, strictWidth = true) { request ->
                                    val next = allocation.horizontal(request.availableWidth)
                                    // Only StaticLayout reflows. The same prepared Text object retains
                                    // its source index, callbacks, styles and semantic owner at every width.
                                    val owner = part.copy(contentWidth = kotlin.math.floor(next.content).toInt(), horizontal = next)
                                    val child = prepared!!.measurePreparedContainer(owner, emptyList(), collapse)
                                    measured = child
                                    solved = next
                                    NativeBlockMeasure(next.allocation, allocation.minimumWidth,
                                        padding.top + owner.contentHeight(child.usedHeight) + padding.bottom)
                                }
                                geometry = checkNotNull(measured)
                                val actual = checkNotNull(solved)
                                paddedWidth = actual.borderWidth
                                placedBorderLeft = placed.availableLeft + actual.borderLeft
                                placedBorderTop = placed.bounds.top
                                x = placed.availableLeft + actual.contentLeft
                                top = placedBorderTop + padding.top
                                y = placedBorderTop + padding.top + part.contentHeight(geometry.usedHeight) + padding.bottom
                                borderTop = placedBorderTop
                                marginPlacement = checkNotNull(marginPlacement).copy(borderTop = borderTop)
                                marginPlacements[partIndex] = checkNotNull(marginPlacement)
                            } else if (part.isolatesFloats) {
                                geometry = prepared!!.measurePreparedContainer(part, emptyList(), collapse)
                                val height = padding.top + part.contentHeight(geometry.usedHeight) + padding.bottom
                                if (horizontal != null) {
                                    placedBorderLeft = horizontal.borderLeft
                                    placedBorderTop = nativeContainerBfcTop(y, height, horizontal, exclusions)
                                    x = horizontal.contentLeft
                                } else {
                                    val outerWidth = paddedWidth + margin.left + margin.right
                                    val placed = placeNativeFloatBlock(width.toFloat(), y, exclusions,
                                        NativeBlockWidth.FixedPx(outerWidth), pixelAligned = false) {
                                        NativeBlockMeasure(outerWidth, outerWidth, height)
                                    }
                                    placedBorderLeft = placed.bounds.left + margin.left
                                    placedBorderTop = placed.bounds.top
                                    x = placedBorderLeft + padding.left
                                }
                                top = placedBorderTop + padding.top
                                y = placedBorderTop + height
                                borderTop = placedBorderTop
                                marginPlacement = checkNotNull(marginPlacement).copy(borderTop = borderTop)
                                marginPlacements[partIndex] = checkNotNull(marginPlacement)
                            } else {
                                placedBorderLeft = horizontal?.borderLeft ?: margin.left
                                placedBorderTop = y
                                x = horizontal?.contentLeft ?: (margin.left + padding.left)
                                top = placedBorderTop + padding.top
                                val carried = exclusions.filter { it.outer.bottom > top }.map {
                                    it.copy(outer = it.outer.translated(-x, -top))
                                }
                                geometry = prepared!!.measurePreparedContainer(part, carried, collapse)
                                geometry.ownExclusions.forEach { exclusions += it.copy(outer = it.outer.translated(x, top)) }
                                y = top + part.contentHeight(geometry.textBottom) + padding.bottom
                            }
                            partOffsets += geometry.partOffsets.map { it + text.length }
                            paragraphs += Paragraph(-1, text.length, x, top, geometry, geometry.textBottom, ordinary = true)
                            children += geometry.children.map { it.copy(offset = it.offset + text.length,
                                bounds = RectF(it.bounds).apply { offset(x, top) }, logicalObject = false) }
                            flowChildren += geometry.flowChildren.map { it.copy(offset = it.offset + text.length,
                                bounds = RectF(it.bounds).apply { offset(x, top) }) }
                            ordinaryBounds.putAll(geometry.ordinaryBounds.mapValues { (_, bounds) -> RectF(bounds).apply { offset(x, top) } })
                            clearanceById.putAll(geometry.clearanceById)
                            ordinaryBounds[part.id] = RectF(placedBorderLeft, placedBorderTop,
                                placedBorderLeft + paddedWidth, top + part.contentHeight(if (isolated) geometry.usedHeight else geometry.textBottom) + padding.bottom)
                            text.append(geometry.text)
                        } else if (adjoining) {
                            val inner = checkNotNull(part.innerMargins)
                            val collapsed = part.childCollapse(inner)
                            val build = part.buildAdjoining ?: throw UnsupportedFloatLayout("Container adjoining measurement is not prepared")
                            var child: NativeFloatContextGeometry? = null
                            fun measured(carried: List<NativeFloatExclusion>): NativeFloatContextGeometry {
                                check(child == null) { "An adjoining container was measured twice" }
                                return (prepared?.measureContainer(part, collapsed) { build(part.contentWidth, carried, collapsed) }
                                    ?: build(part.contentWidth, carried, collapsed)).also {
                                    child = it
                                    if (it.width != part.contentWidth || it.structuralMargins != inner)
                                        throw UnsupportedFloatLayout("Container structural margins changed during measurement")
                                }
                            }
                            var x: Float
                            var top: Float
                            val geometry: NativeFloatContextGeometry
                            if (part.floatSide != null) {
                                val placed = placeNativeFloatingTable(width.toFloat(), tableClearanceY(y, part.clear, exclusions),
                                    exclusions, part.floatSide, margin.nonnegativeFloatMargins(), NativeBlockWidth.FixedPx(paddedWidth), pixelAligned = false) {
                                    val built = measured(emptyList())
                                    NativeBlockMeasure(paddedWidth, paddedWidth,
                                        padding.top + part.contentHeight(built.usedHeight) + padding.bottom)
                                }
                                geometry = checkNotNull(child)
                                x = placed.content.left + padding.left
                                top = placed.content.top + padding.top
                                exclusions += NativeFloatExclusion(part.floatSide, placed.outer)
                            } else if (part.isolatesFloats && horizontal != null) {
                                geometry = measured(emptyList())
                                val height = padding.top + part.contentHeight(geometry.usedHeight) + padding.bottom
                                borderTop = nativeContainerBfcTop(y, height, horizontal, exclusions)
                                x = horizontal.contentLeft
                                top = borderTop + padding.top
                                y = borderTop + height
                                marginPlacement = checkNotNull(marginPlacement).copy(borderTop = borderTop)
                                marginPlacements[partIndex] = checkNotNull(marginPlacement)
                            } else if (part.isolatesFloats) {
                                val outerWidth = paddedWidth + margin.left + margin.right
                                val placed = placeNativeFloatBlock(width.toFloat(), y, exclusions,
                                    NativeBlockWidth.FixedPx(outerWidth), measure = {
                                        val built = measured(emptyList())
                                        NativeBlockMeasure(outerWidth, outerWidth,
                                            padding.top + part.contentHeight(built.usedHeight) + padding.bottom)
                                    })
                                geometry = checkNotNull(child)
                                x = placed.bounds.left + margin.left + padding.left
                                top = placed.bounds.top + padding.top
                                y = placed.nextY
                                borderTop = placed.bounds.top
                                marginPlacement = checkNotNull(marginPlacement).copy(borderTop = borderTop)
                                marginPlacements[partIndex] = checkNotNull(marginPlacement)
                            } else {
                                x = horizontal?.contentLeft ?: (margin.left + padding.left)
                                top = y + padding.top
                                val carried = exclusions.filter { it.outer.bottom > top }.map {
                                    it.copy(outer = it.outer.translated(-x, -top))
                                }
                                geometry = measured(carried)
                                geometry.ownExclusions.forEach { exclusion -> exclusions += exclusion.copy(outer = exclusion.outer.translated(x, top)) }
                                y = top + part.contentHeight(geometry.textBottom) + padding.bottom
                            }
                            paragraphs += Paragraph(prepared?.sourceIndex(part) ?: partIndex, text.length, x, top, geometry, geometry.textBottom, paintHere = false)
                            flowChildren += PlacedFloatContextChild(part.id, text.length,
                                RectF(x, top, x + geometry.width, top + geometry.height))
                            text.append(geometry.text)
                        } else if (part.floatSide == null && part.isolatesFloats) {
                            if (margin.top != 0f || margin.bottom != 0f)
                                throw UnsupportedFloatLayout("Adjoining container margins need collapse semantics")
                            var child: NativeFloatContextGeometry? = null
                            val outerWidth = paddedWidth + margin.left + margin.right
                            val placed = placeNativeFloatBlock(width.toFloat(), tableClearanceY(y, part.clear, exclusions),
                                exclusions, NativeBlockWidth.FixedPx(outerWidth), measure = {
                                    check(child == null) { "A flex formatting context was measured twice" }
                                    val geometry = part.build(part.contentWidth, emptyList())
                                    if (geometry.width != part.contentWidth)
                                        throw UnsupportedFloatLayout("Flex container content width changed")
                                    child = geometry
                                    NativeBlockMeasure(outerWidth, outerWidth, padding.top + part.contentHeight(geometry.usedHeight) + padding.bottom)
                                })
                            val geometry = checkNotNull(child)
                            val x = placed.bounds.left + margin.left + padding.left
                            val top = placed.bounds.top + padding.top
                            paragraphs += Paragraph(prepared?.sourceIndex(part) ?: partIndex, text.length, x, top, geometry, geometry.textBottom, paintHere = false)
                            flowChildren += PlacedFloatContextChild(part.id, text.length,
                                RectF(x, top, x + geometry.width, top + geometry.height))
                            text.append(geometry.text)
                            y = placed.nextY
                            // Internal float boxes are contained by this formatting context.
                        } else if (part.floatSide == null) {
                            // The shared initial domain excludes adjoining vertical margins.
                            // Padding separates this box from its descendants but does not make a BFC.
                            if (margin.top != 0f || margin.bottom != 0f)
                                throw UnsupportedFloatLayout("Adjoining container margins need collapse semantics")
                            y = tableClearanceY(y, part.clear, exclusions)
                            val x = margin.left + padding.left
                            val top = y + padding.top
                            val carried = exclusions.filter { it.outer.bottom > top }.map {
                                it.copy(outer = it.outer.translated(-x, -top))
                            }
                            val geometry = part.build(part.contentWidth, carried)
                            if (geometry.width != part.contentWidth) throw UnsupportedFloatLayout("Container content width changed during measurement")
                            paragraphs += Paragraph(prepared?.sourceIndex(part) ?: partIndex, text.length, x, top, geometry, geometry.textBottom, paintHere = false)
                            flowChildren += PlacedFloatContextChild(part.id, text.length,
                                RectF(x, top, x + geometry.width, top + geometry.height))
                            text.append(geometry.text)
                            geometry.ownExclusions.forEach { exclusion -> exclusions += exclusion.copy(outer = exclusion.outer.translated(x, top)) }
                            y = top + part.contentHeight(geometry.textBottom) + padding.bottom
                        } else {
                            var child: NativeFloatContextGeometry? = null
                            val placed = placeNativeFloatingTable(width.toFloat(), tableClearanceY(y, part.clear, exclusions),
                                exclusions, part.floatSide, margin.nonnegativeFloatMargins(), NativeBlockWidth.FixedPx(paddedWidth)) {
                                check(child == null) { "A floated container was measured twice" }
                                val geometry = part.build(part.contentWidth, emptyList())
                                if (geometry.width != part.contentWidth) throw UnsupportedFloatLayout("Floated container content width changed")
                                child = geometry
                                NativeBlockMeasure(paddedWidth, paddedWidth, padding.top + part.contentHeight(geometry.usedHeight) + padding.bottom)
                            }
                            val geometry = checkNotNull(child)
                            val x = placed.content.left + padding.left
                            val top = placed.content.top + padding.top
                            paragraphs += Paragraph(prepared?.sourceIndex(part) ?: partIndex, text.length, x, top, geometry, geometry.textBottom, paintHere = false)
                            flowChildren += PlacedFloatContextChild(part.id, text.length,
                                RectF(x, top, x + geometry.width, top + geometry.height))
                            text.append(geometry.text)
                            // Descendant floats remain inside this BFC. Only its outer margin box escapes.
                            exclusions += NativeFloatExclusion(part.floatSide, placed.outer)
                        }
                    }
                    is NativeFloatContextPart.Child -> {
                        require(part.gapAfter.isFinite() && part.gapAfter >= 0)
                        require(part.gapBefore.isFinite() && part.gapBefore >= 0)
                        y += part.gapBefore
                        if (part.requiresUnobstructedText && exclusions.any { it.outer.bottom > y })
                            throw UnsupportedFloatLayout("This text block needs native exclusion-band shaping")
                        val side = part.floatSide
                        val clearedY = tableClearanceY(y, part.clear, exclusions)
                        if (part.pairedViewportDirection != null) {
                            if (side != null || part.widthRule != NativeBlockWidth.Auto || part.autoMarginBox != null ||
                                    part.autoMargins != null || part.containingDirection != null || part.fixedMarginBox != null ||
                                    part.fixedMarginDirection != null)
                                throw UnsupportedFloatLayout("Paired table placement owner is inconsistent")
                            val fixed = if (adjoining) part.margins.copy(top = 0f, bottom = 0f) else part.margins
                            val placed = placeNativeFixedMarginTable(width.toFloat(), y, exclusions, fixed,
                                part.pairedViewportDirection, NativeBlockWidth.Auto,
                                if (adjoining) FigureClear.None else part.clear, part.measure)
                            children += PlacedFloatContextChild(part.id, text.length,
                                RectF(placed.content.left, placed.content.top, placed.content.right, placed.content.bottom), part.logicalObject)
                            y = placed.outer.bottom + if (adjoining) 0f else part.gapAfter
                            if (adjoining) {
                                borderTop = placed.content.top
                                marginPlacement = checkNotNull(marginPlacement).copy(borderTop = borderTop)
                                marginPlacements[partIndex] = checkNotNull(marginPlacement)
                            }
                        } else if (part.fixedMarginBox != null || part.fixedMarginDirection != null) {
                            val box = part.fixedMarginBox
                                ?: throw UnsupportedFloatLayout("Fixed table border measurement is unavailable")
                            val direction = part.fixedMarginDirection
                                ?: throw UnsupportedFloatLayout("Fixed table containing direction is unavailable")
                            if (part.autoMarginBox != null || part.autoMargins != null || part.containingDirection != null ||
                                box.scrolling || box.blockBox != null || side != null && side != TableFloatSide.Right ||
                                part.widthRule != NativeBlockWidth.FixedPx(box.placementWidth))
                                throw UnsupportedFloatLayout("Fixed table placement owner is inconsistent")
                            if (side == TableFloatSide.Right) {
                                val placed = placeNativeFloatingTable(width.toFloat(), clearedY, exclusions, side,
                                    part.margins, part.widthRule, pixelAligned = false, measure = part.measure)
                                children += PlacedFloatContextChild(part.id, text.length,
                                    RectF(placed.content.left, placed.content.top, placed.content.right, placed.content.bottom), part.logicalObject)
                                exclusions += NativeFloatExclusion(side, placed.outer)
                            } else {
                                val fixed = if (adjoining) part.margins.copy(top = 0f, bottom = 0f) else part.margins
                                val placed = placeNativeFixedMarginTable(width.toFloat(), y, exclusions, fixed, direction,
                                    part.widthRule, if (adjoining) FigureClear.None else part.clear, part.measure)
                                children += PlacedFloatContextChild(part.id, text.length,
                                    RectF(placed.content.left, placed.content.top, placed.content.right, placed.content.bottom), part.logicalObject)
                                y = placed.outer.bottom + if (adjoining) 0f else part.gapAfter
                                if (adjoining) {
                                    borderTop = placed.content.top
                                    marginPlacement = checkNotNull(marginPlacement).copy(borderTop = borderTop)
                                    marginPlacements[partIndex] = checkNotNull(marginPlacement)
                                }
                            }
                        } else if (part.autoMarginBox != null || part.autoMargins != null || part.containingDirection != null) {
                            val box = part.autoMarginBox
                                ?: throw UnsupportedFloatLayout("Table automatic margin measurement is unavailable")
                            val margins = part.autoMargins
                                ?: throw UnsupportedFloatLayout("Table automatic margins are unavailable")
                            val direction = part.containingDirection
                                ?: throw UnsupportedFloatLayout("Table containing direction is unavailable")
                            if (side != null || part.margins != margins.fixed)
                                throw UnsupportedFloatLayout("Table automatic margin flow owner is inconsistent")
                            val actualMargins = if (adjoining)
                                margins.copy(fixed = margins.fixed.copy(top = 0f, bottom = 0f)) else margins
                            val placed = placeNativeAutoMarginTable(width.toFloat(), y, exclusions, actualMargins,
                                direction, NativeBlockWidth.FixedPx(box.placementWidth),
                                if (adjoining) FigureClear.None else part.clear, measure = part.measure)
                            // A local scroll surface clips the real table border box. Its initial
                            // physical viewport follows the independently authored containing direction.
                            val left = placed.content.left + if (box.blockBox == null && box.scrolling && direction == TableContainingDirection.Rtl)
                                box.borderWidth - box.viewportWidth else 0
                            children += PlacedFloatContextChild(part.id, text.length,
                                RectF(left, placed.content.top, left + if (box.blockBox == null) box.viewportWidth.toFloat() else box.placementWidth,
                                    placed.content.top + if (box.blockBox == null) box.viewportHeight.toFloat() else box.placementHeight), part.logicalObject)
                            y = placed.nextY + if (adjoining) 0f else part.gapAfter
                            if (adjoining) {
                                borderTop = placed.content.top
                                marginPlacement = checkNotNull(marginPlacement).copy(borderTop = borderTop)
                                marginPlacements[partIndex] = checkNotNull(marginPlacement)
                            }
                        } else if (adjoining && side == null) {
                            val placed = placeNativeClearedTable(width.toFloat(), y, exclusions, FigureClear.None,
                                part.margins.copy(top = 0f, bottom = 0f), part.widthRule,
                                pixelAligned = false, measure = part.measure)
                            children += PlacedFloatContextChild(part.id, text.length,
                                RectF(placed.content.left, placed.content.top, placed.content.right, placed.content.bottom), part.logicalObject)
                            y = placed.outer.bottom
                            borderTop = placed.content.top
                            marginPlacement = checkNotNull(marginPlacement).copy(borderTop = borderTop)
                            marginPlacements[partIndex] = checkNotNull(marginPlacement)
                        } else if (side == null && part.clear != null && part.clear != FigureClear.None) {
                            val placed = placeNativeClearedTable(width.toFloat(), y, exclusions, part.clear,
                                part.margins, part.widthRule, measure = part.measure)
                            children += PlacedFloatContextChild(part.id, text.length,
                                RectF(placed.content.left, placed.content.top, placed.content.right, placed.content.bottom), part.logicalObject)
                            y = placed.outer.bottom + part.gapAfter
                        } else if (side == null) {
                            val placed = placeNativeFloatBlock(width.toFloat(), clearedY, exclusions, part.widthRule,
                                pixelAligned = true, measure = part.measure)
                            children += PlacedFloatContextChild(part.id, text.length,
                                RectF(placed.bounds.left, placed.bounds.top, placed.bounds.right, placed.bounds.bottom), part.logicalObject)
                            y = placed.nextY + part.gapAfter
                        } else {
                            val placed = placeNativeFloatingTable(width.toFloat(), clearedY, exclusions, side,
                                part.margins, part.widthRule, pixelAligned = !adjoining, measure = { request ->
                                    prepared?.measureChild(part, request) ?: part.measure(request)
                                })
                            children += PlacedFloatContextChild(part.id, text.length,
                                RectF(placed.content.left, placed.content.top, placed.content.right, placed.content.bottom), part.logicalObject)
                            exclusions += NativeFloatExclusion(side, placed.outer)
                            // A floated table leaves the following body at its normal flow Y.
                            // Its stored margins, rather than a fabricated empty paragraph, exclude later lines.
                        }
                        // App-owned media controls have their own input/AX tree, not authored copy text.
                        if (part.logicalObject) text.append('\ufffc')
                    }
                }
                if (marginPlacement != null) {
                    cursor!!.end(marginPlacement, y - borderTop, checkNotNull(adjoiningProfile(part, prepared)))
                    marginPlacement.clearance?.let { amount ->
                        val id = when (part) {
                            is NativeFloatContextPart.Child -> part.id
                            is NativeFloatContextPart.Container -> part.id
                            else -> null
                        }
                        if (id != null) clearanceById[id] = amount
                    }
                }
            }
            if (cursor != null) y = cursor.finish()
            val ownExclusions = exclusions.drop(carriedExclusions.size)
            val floatBottom = ownExclusions.maxOfOrNull { it.outer.bottom } ?: 0f
            if (!containAtEnd && !allowProtrudingFloats && floatBottom > y + .01f) throw UnsupportedFloatLayout("Float crosses a delegated section boundary")
            val bottom = maxOf(y, floatBottom)
            if (!bottom.isFinite() || bottom > Int.MAX_VALUE / 4) throw UnsupportedFloatLayout("Native context height exceeds geometry limit")
            val usedBottom = maxOf(0f, if (containAtEnd) bottom else y)
            val adjoiningMargins = if (adjoining) NativeAdjoiningMargins.sequence(
                parts.mapNotNull { adjoiningProfile(it, prepared) }) else null
            return NativeFloatContextGeometry(width, text.toString(), kotlin.math.ceil(usedBottom).toInt(), usedBottom, paragraphs, children,
                partOffsets, flowChildren, maxOf(0f, y), ownExclusions, adjoiningMargins, marginPlacements, ordinaryBounds, clearanceById,
                if (adjoining) adjoiningMarginsFor(parts) else null, hardSeparators = hardSeparators.toSet())
        }
    }
}
