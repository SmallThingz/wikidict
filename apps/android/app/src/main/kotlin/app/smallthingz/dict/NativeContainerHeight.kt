package app.smallthingz.dict

/** Definite flow geometry. Natural child lines, ink and interactions are measured separately. */
internal data class NativeContainerHeight(val content: Float, val border: Float)

internal fun Block.hasFixedContainerHeight(): Boolean = when {
    container != null -> container.style.height != null || container.blocks.any(Block::hasFixedContainerHeight)
    table != null -> table.hasFixedContainerHeight()
    figure != null -> figure.captionBlocks?.any(Block::hasFixedContainerHeight) == true
    flow != null -> flow.hasFixedContainerHeight()
    else -> false
}

private fun Table.hasFixedContainerHeight(): Boolean =
    captionBlocks?.any(Block::hasFixedContainerHeight) == true || rows.any { row -> row.any { cell ->
        cell.blocks?.any(Block::hasFixedContainerHeight) == true || cell.nestedTable?.hasFixedContainerHeight() == true
    } }

private fun List<FlowPart>.hasFixedContainerHeight(): Boolean = any { part -> when (part) {
    is FlowPart.Inline -> false
    is FlowPart.ImageFigure -> part.figure.captionBlocks?.any(Block::hasFixedContainerHeight) == true
    is FlowPart.Scope -> part.scope.parts.hasFixedContainerHeight()
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
