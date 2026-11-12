package app.smallthingz.dict

/** Only the outer lazy item allocates overflow; nested CSS used heights stay unchanged. */
internal fun Block.needsFigureDocumentExtent(): Boolean = when {
    container != null -> container.blocks.any(Block::needsFigureDocumentExtent)
    table != null -> table.needsFigureDocumentExtent()
    figure != null -> figure.needsFigureDocumentExtent()
    flow != null -> flow.needsFigureDocumentExtent()
    else -> false
}

private fun Figure.needsFigureDocumentExtent(): Boolean = tableCaptionLayout?.let { layout ->
    (listOf(layout.media) + layout.viewportStates.map { it.media }).any { it.after != null || it.focusOutline != null }
} == true || captionBlocks?.any(Block::needsFigureDocumentExtent) == true

private fun Table.needsFigureDocumentExtent(): Boolean =
    captionBlocks?.any(Block::needsFigureDocumentExtent) == true || rows.any { row -> row.any { cell ->
        cell.blocks?.any(Block::needsFigureDocumentExtent) == true || cell.nestedTable?.needsFigureDocumentExtent() == true
    } }

private fun List<FlowPart>.needsFigureDocumentExtent(): Boolean = any { part -> when (part) {
    is FlowPart.Inline -> false
    is FlowPart.ImageFigure -> part.figure.needsFigureDocumentExtent()
    is FlowPart.Scope -> part.scope.parts.needsFigureDocumentExtent()
} }

/** Complete states replace the wrapper; absent fields are initial values, not inheritance. */
internal fun figureTableViewport(figure: Figure, cssWidth: Double): Figure {
    val layout = figure.tableCaptionLayout ?: return figure
    val wrapper = layout.stateAtViewport(cssWidth)?.wrapper ?: layout.wrapper
    val placement = when (wrapper.floatSide) {
        TableFloatSide.Left -> FigurePlacement.FloatLeft
        TableFloatSide.Right -> FigurePlacement.FloatRight
        null -> FigurePlacement.None
    }
    return figure.copy(placement = placement, clear = wrapper.clear ?: FigureClear.None)
}

internal fun figureTableWrapper(figure: Figure, cssWidth: Double): ContainerStyle {
    val layout = checkNotNull(figure.tableCaptionLayout)
    return layout.stateAtViewport(cssWidth)?.wrapper ?: layout.wrapper
}

internal fun figureTableMargins(style: ContainerStyle, density: Float, normalBodyPixels: Float): FloatMargins {
    val margins = style.atViewport(0.0).margins
    fun value(margin: ContainerMargin?): Float = (margin as? ContainerMargin.Length)?.value?.let {
        figureLengthPixels(StyleLength(it.unit, it.value), density, normalBodyPixels)
    } ?: 0f
    return FloatMargins(value(margins?.top), value(margins?.right), value(margins?.bottom), value(margins?.left))
}

internal fun figureTableNormalLeft(style: ContainerStyle, containingWidth: Int, frameWidth: Int,
    density: Float, normalBodyPixels: Float, rtl: Boolean): Float? {
    if (style.floatSide != null) return null
    val fixed = style.copy(width = ContainerWidth.Length(StyleWidth(StyleWidthUnit.Px, frameWidth / density)))
    return containerBoxWidth(fixed, containingWidth.toFloat(), ContainerWidths(frameWidth.toFloat(), frameWidth.toFloat()),
        density, normalBodyPixels, rtl = rtl).marginLeft
}
