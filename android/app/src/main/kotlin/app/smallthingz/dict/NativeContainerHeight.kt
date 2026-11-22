package app.smallthingz.dict

/** Definite flow geometry. Natural child lines, ink and interactions are measured separately. */
internal data class NativeContainerHeight(val content: Float, val border: Float)
internal data class NativeContainerMinimum(val content: Float, val computedPositive: Boolean) {
    init { require(content.isFinite() && content >= 0f) }
}

private fun ContainerMargins?.hasNegativeLength(): Boolean = this?.let { margins ->
    listOf(margins.top, margins.right, margins.bottom, margins.left).any {
        it is ContainerMargin.Length && it.value.value < 0f
    }
} == true

internal fun ContainerViewportStyle.needsDocumentExtent(): Boolean =
    box.height != null || margins.hasNegativeLength()

private fun ContainerStyle.needsDocumentExtent(): Boolean {
    if (height != null || marginValues.hasNegativeLength() || margins?.let { listOf(it.top, it.right, it.bottom, it.left).any { edge -> edge.value < 0f } } == true)
        return true
    return screenMaxWidth?.let { rule -> (listOf(rule) + rule.followingRules).any { it.margins.hasNegativeLength() } } == true
}

internal fun Block.needsContainerDocumentExtent(): Boolean = when {
    container != null -> container.style.needsDocumentExtent() || container.blocks.any(Block::needsContainerDocumentExtent)
    table != null -> table.needsContainerDocumentExtent()
    figure != null -> figure.captionBlocks?.any(Block::needsContainerDocumentExtent) == true
    flow != null -> flow.needsContainerDocumentExtent()
    else -> false
}

private fun Table.needsContainerDocumentExtent(): Boolean =
    captionBlocks?.any(Block::needsContainerDocumentExtent) == true || rows.any { row -> row.any { cell ->
        cell.blocks?.any(Block::needsContainerDocumentExtent) == true || cell.nestedTable?.needsContainerDocumentExtent() == true
    } }

private fun List<FlowPart>.needsContainerDocumentExtent(): Boolean = any { part -> when (part) {
    is FlowPart.Inline -> false
    is FlowPart.ImageFigure -> part.figure.captionBlocks?.any(Block::needsContainerDocumentExtent) == true
    is FlowPart.Scope -> part.scope.parts.needsContainerDocumentExtent()
} }

internal fun containerUsedHeight(style: ContainerStyle, verticalEdges: Float,
    density: Float, normalBodyFont: Float): NativeContainerHeight? {
    require(verticalEdges.isFinite() && verticalEdges >= 0f)
    require(density.isFinite() && density > 0f && normalBodyFont.isFinite() && normalBodyFont >= 0f)
    val authored = style.height ?: return null
    val requested = authored.value.toDouble() * if (authored.unit == StyleLengthUnit.Px) density else normalBodyFont
    val content = if (style.boxSizing == ContainerBoxSizing.BorderBox)
        maxOf(0.0, requested - verticalEdges) else requested
    val border = content + verticalEdges
    if (!requested.isFinite() || !border.isFinite() || requested < 0.0 || border > TablePixelLimit)
        throw UnsupportedFloatLayout("Container height exceeds native geometry")
    return NativeContainerHeight(content.toFloat(), border.toFloat())
}

internal fun containerMinimumHeight(style: ContainerStyle, verticalEdges: Float,
    density: Float, normalBodyFont: Float): NativeContainerMinimum {
    val authored = style.minHeight ?: return NativeContainerMinimum(0f, false)
    val resolved = checkNotNull(containerUsedHeight(style.copy(height = authored), verticalEdges, density, normalBodyFont))
    // The CSS adjacency rule uses computed min-height, before border-box subtraction.
    val computed = authored.value.toDouble() * if (authored.unit == StyleLengthUnit.Px) density else normalBodyFont
    return NativeContainerMinimum(resolved.content, computed > 0.0)
}

/** Only the document's outer lazy item consumes this allocation, never a CSS sibling cursor. */
internal data class NativeDocumentVerticalExtent(val origin: Int, val height: Int)

internal fun nativeDocumentVerticalExtent(usedHeight: Int, surfaceTop: Int,
    surfaceBottom: Int): NativeDocumentVerticalExtent {
    require(usedHeight >= 0 && surfaceBottom >= surfaceTop)
    val top = minOf(0L, surfaceTop.toLong())
    val bottom = maxOf(usedHeight.toLong(), surfaceBottom.toLong())
    val height = bottom - top
    if (height > TablePixelLimit || -top > TablePixelLimit)
        throw UnsupportedFloatLayout("Document overflow exceeds native geometry")
    return NativeDocumentVerticalExtent((-top).toInt(), height.toInt())
}

/** Scroll allocation keeps the original containing width. Ink and the opposite
 * origin-exterior side never enlarge the reachable document range. */
internal data class NativeDocumentHorizontalExtent(val viewportWidth: Int, val overflow: Float, val range: Int)

internal fun nativeDocumentHorizontalExtent(viewportWidth: Int, scrollable: NativeFloatBounds?,
    rtl: Boolean): NativeDocumentHorizontalExtent {
    if (viewportWidth !in 0..TablePixelLimit)
        throw UnsupportedFloatLayout("Document horizontal viewport exceeds native geometry")
    val overflow = if (scrollable == null) 0.0 else if (rtl)
        maxOf(0.0, -scrollable.left.toDouble()) else
        maxOf(0.0, scrollable.right.toDouble() - viewportWidth.toDouble())
    val range = kotlin.math.ceil(overflow)
    if (!overflow.isFinite() || range > TablePixelLimit.toDouble() - viewportWidth.toDouble())
        throw UnsupportedFloatLayout("Document horizontal overflow exceeds native geometry")
    return NativeDocumentHorizontalExtent(viewportWidth, overflow.toFloat(), range.toInt())
}

/** The selected document scroll owner starts at CSS y=0. Late descendant layout
 * extends its bottom; physical surface top/ink do not move the normal origin. */
internal fun nativeDocumentScrollableVerticalExtent(usedHeight: Int,
    scrollable: NativeFloatBounds): NativeDocumentVerticalExtent {
    val bottom = kotlin.math.ceil(maxOf(0.0, scrollable.bottom.toDouble()))
    if (bottom > TablePixelLimit)
        throw UnsupportedFloatLayout("Document overflow exceeds native geometry")
    return nativeDocumentVerticalExtent(usedHeight, 0, bottom.toInt())
}
