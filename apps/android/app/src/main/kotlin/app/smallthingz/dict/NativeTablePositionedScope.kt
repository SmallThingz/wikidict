package app.smallthingz.dict

/** Original source custody for the first clipped positioned-table family. This is
 * enrollment only: the real Views and complete Entry scene still have to pass the
 * separate measured proof below. Ordinary map fallback spans remain original leaves. */
internal class NativeTablePositionedScopeSource private constructor(
    val table: Table, val cells: List<Cell>, val blocks: List<List<Block>>,
    val scopeIndex: Int, val scope: Container,
) {
    fun rank(index: Int): Int = if (index == scopeIndex) cells.size else index
    fun owns(index: Int, source: List<Block>): Boolean = index in blocks.indices &&
        source.size == blocks[index].size && source.indices.all { source[it] === blocks[index][it] }
    fun ownsScope(index: Int, value: Container): Boolean = index == scopeIndex && value === scope

    companion object {
        fun from(table: Table): NativeTablePositionedScopeSource? {
            if (table.caption.isNotEmpty() || table.captionBlocks != null || table.geometry != null ||
                table.style != null || table.blockViewport != null || table.floatViewport != null ||
                table.rowsHiddenMaxWidthPx != null || table.rows.isEmpty() || table.rows.any { it.isEmpty() }) return null
            val cells = table.rows.flatten()
            if (cells.any { it.rowspan != 1 || it.colspan != 1 || it.nestedTable != null || it.style != null }) return null
            var scopeIndex = -1
            var scope: Container? = null
            val blocks = ArrayList<List<Block>>(cells.size)
            for ((index, cell) in cells.withIndex()) {
                val source = cell.blocks
                if (source == null) {
                    if (cell.spans.any { !nativeScopeTableSpan(it, image = false) }) return null
                    // Terminal presentation of this original Cell, not an added source Span.
                    blocks += listOf(Block("paragraph", 0, cell.spans))
                    continue
                }
                val block = source.singleOrNull() ?: return null
                val owner = block.container ?: return null
                if (scope != null || cell.spans.isNotEmpty() || block.kind != "container" || block.style != null ||
                    !nativeScopeTableContainer(owner)) return null
                scopeIndex = index; scope = owner; blocks += source
            }
            return scope?.let { NativeTablePositionedScopeSource(table, cells, blocks, scopeIndex, it) }
        }
    }
}

private fun nativeScopeTableSpan(span: Span, image: Boolean): Boolean =
    span.kind in setOf("text", "link", "external_link", "line_break") &&
        (image || span.image == null) && span.ruby == null && span.inlineBoxGroup == null &&
        span.inlinePaddingGroup == null && span.inlineActionGroup == null && span.clippedAbsolute == null &&
        span.audioControl == null && span.citationMarker == null

private fun nativeScopeTableContainer(value: Container): Boolean {
    val style = value.style
    val scope = style.positionedScope ?: return false
    if (value.disclosure != null || scope.textWrap != TextWrap.NoWrap || scope.overflowX != PositionedOverflowX.Hidden ||
        scope.overflowY != PositionedOverflowY.Auto || scope.viewportStates.isNotEmpty() ||
        style.positioning != ContainerPositioning.RelativeAuto) return false
    val padding = style.padding ?: return false
    if (listOf(padding.top, padding.right, padding.left).any { it.value != 0f }) return false
    val values = style.margins?.let { listOf(it.top, it.right, it.bottom, it.left) }
        ?: style.marginValues?.let { margins ->
            listOf(margins.top, margins.right, margins.bottom, margins.left).map {
                (it as? ContainerMargin.Length)?.value ?: return false
            }
        } ?: return false
    if (listOf(values[0], values[1], values[3]).any { it.value != 0f }) return false
    val bottom = values[2]
    if (bottom.unit != padding.bottom.unit || bottom.value != -padding.bottom.value) return false
    if (style.copy(positioning = null, positionedScope = null, padding = null, margins = null, marginValues = null) != ContainerStyle()) return false
    if (value.blocks.size != 1 || value.blocks.any { block ->
            block.kind != "paragraph" || block.depth != 0 || block.style != null || block.table != null ||
                block.container != null || block.figure != null || block.flow != null || block.feature != null ||
                block.spans.any { !nativeScopeTableSpan(it, image = true) }
        }) return false
    return value.blocks.sumOf { block -> block.spans.count { it.image != null } } == 1
}

internal fun nativeHasTablePositionedScope(table: Table): Boolean =
    table.rows.any { row -> row.any { cell -> cell.blocks?.any { it.container?.style?.positionedScope != null } == true } }

/** This capability authenticates the entire actual visible Entry projection. A catalog
 * media record is allowed only when the existing Entry renderer consumes it inline. */
internal class NativeTableScopeEntrySource private constructor(
    val entry: Entry, private val blocks: List<Block>, private val paths: List<String>,
    val revision: Any,
) {
    fun owns(source: List<Block>, sourcePaths: List<String>?): Boolean = sourcePaths == paths &&
        source.size == blocks.size && source.indices.all { source[it] === blocks[it] }
    fun contains(table: Table): Boolean = blocks.any { it.table === table }

    companion object {
        fun from(entry: Entry, rows: List<ReadingRow>, folded: Map<String, Boolean>, run: IntRange,
            blocks: List<Block>, paths: List<String>, remainingMedia: List<Media>): NativeTableScopeEntrySource? {
            if (entry.displayTitle.isNotEmpty() || entry.preamble.isNotEmpty() || entry.references.isNotEmpty() ||
                remainingMedia.isNotEmpty() || entry.media.any { media ->
                    entry.inlineImages.none { it.file == media.file } || media.file in entry.separateImageCaptionFiles
                } || rows.isEmpty() || run.first != 0 || run.last != rows.lastIndex ||
                rows.any { it.reference != null || it.referenceBatch != null }) return null
            val actual = visibleEntryReadingRows(entry, folded.filterValues { it }.keys)
            if (actual.size != rows.size || actual.indices.any { actual[it] !== rows[it] }) return null
            val visible = actual.filter { it.block != null || it.heading?.let { heading -> sectionHeadingVisible(heading, entry.language) } == true }
            if (paths != visible.map { it.key } || blocks.size != visible.size) return null
            for (index in visible.indices) {
                val row = visible[index]
                val original = row.block ?: row.headingBlock
                if (original != null) { if (blocks[index] !== original) return null }
                else if (blocks[index] != Block("heading", 0,
                        listOf(Span("text", sectionHeadingLabel(checkNotNull(row.heading), entry.language, null))),
                        level = checkNotNull(row.heading).level)) return null
            }
            if (blocks.count { it.table?.let(::nativeHasTablePositionedScope) == true } != 1) return null
            return NativeTableScopeEntrySource(entry, blocks.toList(), paths.toList(), listOf(
                NativeCellOpacitySourceIdentity(entry), rows.map(::NativeCellOpacitySourceIdentity),
                folded.toMap(), paths.toList()))
        }
    }
}

/** Published only by the new-family grid's actual clipToBounds coordinator. */
internal data class NativeTableScopeMeasuredClip(val bounds: NativeFloatBounds,
    val minimumTouchWidth: Float, val minimumTouchHeight: Float)

/** Distinct from the overflow-visible Figure/absolute proof. Actual z placement of the
 * original cell Views resolves internal overlap. External overlap never borrows that
 * local ordering. The full viewport/input/state band participates, including blank padding. */
internal fun nativeTableScopePaintDecision(
    surroundings: NativeDelegatedSurroundings, cells: List<NativeDelegatedMeasuredCell>,
    expectedOwners: List<Any>, source: NativeTablePositionedScopeSource,
    measuredRanks: List<Int>, viewportCurrent: Boolean, rootAllocation: NativeFloatBounds,
    gridClip: NativeTableScopeMeasuredClip?,
): NativeDelegatedPaintDecision {
    fun refuse(reason: String) = NativeDelegatedPaintDecision.Unavailable(reason)
    if (!viewportCurrent) return refuse("The original clipped scope publication is not current")
    val clip = gridClip ?: return refuse("The positioned table clipping coordinator is absent")
    if (clip.bounds != surroundings.allocation || !clip.minimumTouchWidth.isFinite() ||
        !clip.minimumTouchHeight.isFinite() || clip.minimumTouchWidth < 0f || clip.minimumTouchHeight < 0f ||
        clip.bounds.width < clip.minimumTouchWidth || clip.bounds.height < clip.minimumTouchHeight)
        return refuse("The positioned table clip does not bound minimum touch candidates")
    if (cells.size != source.cells.size || cells.size != expectedOwners.size ||
        cells.indices.any { cells[it].owner !== expectedOwners[it] } ||
        measuredRanks != cells.indices.map(source::rank)) return refuse("The original positioned table cell order is incomplete")
    if (cells.indices.any { i -> cells.take(i).any { it.owner === cells[i].owner } }) return refuse("Duplicated positioned table View")
    val root = surroundings.rootOwner ?: return refuse("Positioned table Entry root is absent")
    val state = surroundings.rootState ?: return refuse("Positioned table Entry state is absent")
    val otherInk = surroundings.otherInk ?: return refuse("Positioned table surrounding paint is unknown")
    val otherInput = surroundings.otherInput ?: return refuse("Positioned table surrounding input is unknown")
    if (cells.any { it.rootOwner !== root || it.generation !== surroundings.generation || it.owner === state.view })
        return refuse("Positioned table owner generation changed")
    fun valid(b: NativeFloatBounds) = listOf(b.left,b.top,b.right,b.bottom).all(Float::isFinite) && b.left <= b.right && b.top <= b.bottom
    fun contains(a: NativeFloatBounds, b: NativeFloatBounds) = a.left <= b.left && a.top <= b.top && a.right >= b.right && a.bottom >= b.bottom
    fun overlaps(a: NativeFloatBounds, b: NativeFloatBounds) = a.left < b.right && b.left < a.right && a.top < b.bottom && b.top < a.bottom
    val all = listOf(rootAllocation, clip.bounds, surroundings.allocation, state.surface, state.clip) + state.input + state.fallbackInput + otherInk + otherInput +
        cells.flatMap { listOfNotNull(it.cell,it.physicalSurface,it.innerClip) + it.ink + it.deferredInk + it.input + it.ordinaryStateInk + it.ordinaryInk + it.realInputAncestors.map { a -> a.bounds } }
    if (all.any { !valid(it) }) return refuse("Invalid positioned table envelope")
    // Title and plain text-details precede this entire native body LazyColumn item.
    // Only the actual item allocation, never expanded ink, proves their separation.
    if (!contains(rootAllocation, surroundings.allocation))
        return refuse("Positioned table escapes its actual body item allocation")
    if ((state.input + state.fallbackInput).any { !contains(state.surface,it) }) return refuse("Root state exceeds its original View")
    for ((index, cell) in cells.withIndex()) {
        if (!contains(surroundings.allocation,cell.cell) || !contains(surroundings.allocation,cell.physicalSurface))
            return refuse("Positioned table source surface escapes the measured table")
        if (cell.innerClip != cell.physicalSurface || cell.realInputAncestors.isEmpty())
            return refuse("Positioned table original View ancestry changed")
        if (!cell.minimumTouchWidth.isFinite() || !cell.minimumTouchHeight.isFinite() || cell.minimumTouchWidth < 0f || cell.minimumTouchHeight < 0f ||
            index == source.scopeIndex &&
                (listOf(cell.physicalSurface) + cell.realInputAncestors.filterNot { it.clips }.map { it.bounds }).any {
                    it.width < cell.minimumTouchWidth || it.height < cell.minimumTouchHeight })
            return refuse("Positioned table minimum touch expansion is unproved")
        // UI 1.11.2 keeps sharing hits in z order, dispatches DOWN on Initial, and
        // consumes only after the original AndroidView accepts it. Ordinary small
        // neighbors may add near candidates but reject unowned DOWN. The actual
        // large grid clip above prevents those candidates escaping this Table.
        val paint = cell.ink + cell.deferredInk + cell.ordinaryStateInk + cell.ordinaryInk
        if ((paint + cell.input).any { !contains(cell.physicalSurface,it) }) return refuse("Positioned table surface misses original paint or input")
        if (cells.take(index).any { overlaps(it.cell,cell.cell) }) return refuse("Original table cells overlap")
        // Reject even clipped-away external conflicts: a later reveal may expose them.
        if (paint.any { a -> otherInk.any { overlaps(a,it) } } ||
            cell.input.any { a -> (otherInput + state.fallbackInput).any { overlaps(a,it) } })
            return refuse("Positioned table overlaps another Entry owner")
    }
    return NativeDelegatedPaintDecision.Permitted(surroundings.generation, expectedOwners)
}
