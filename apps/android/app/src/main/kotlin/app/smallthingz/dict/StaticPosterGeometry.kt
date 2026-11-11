package app.smallthingz.dict

internal fun Figure.staticPoster(): StaticPoster? = (content as? FigureContent.Image)?.span?.image?.staticPoster

internal fun staticPosterCaptionUnavailable(figure: Figure, viewportCssWidth: Double): String? =
    if (figure.staticPoster() != null && viewportCssWidth > 639.0 && figure.captionBlocks.orEmpty().any { it.table != null })
        "Poster caption table needs its original-width float placement" else null

/** Root presentation viewport chooses the screen rule; parent width only sizes the image. */
internal fun staticPosterScreenFigure(figure: Figure, viewportCssWidth: Double): Figure {
    if (figure.staticPoster() == null) return figure
    require(viewportCssWidth.isFinite() && viewportCssWidth >= 0)
    val zero = StyleLength(StyleLengthUnit.Px, 0f)
    val empty = figure.caption.isEmpty() && figure.captionBlocks.orEmpty().isEmpty()
    val captionPadding = if (empty) figure.captionPadding.copy(bottom = StyleLength(StyleLengthUnit.Px, 3f)) else figure.captionPadding
    return if (viewportCssWidth <= 639.0) figure.copy(placement = FigurePlacement.Center,
        margins = StyleEdges(zero, zero, zero, zero), captionPadding = captionPadding)
        else figure.copy(captionPadding = captionPadding)
}

internal fun staticPosterFitMetrics(natural: FigureBoxMetrics, availableFrameWidth: Float): FigureBoxMetrics {
    require(availableFrameWidth.isFinite() && availableFrameWidth >= 0f)
    val edges = natural.frameBorder * 2f + natural.imageInsets.left + natural.imageInsets.right + natural.imageBorder * 2f
    val available = (availableFrameWidth - edges).coerceAtLeast(0f)
    val width = minOf(natural.image.width, available)
    val ratio = width / natural.image.width
    return natural.copy(image = natural.image.copy(width = width, height = natural.image.height * ratio))
}

internal fun staticPosterCaptionExclusion(width: Int, density: Float): NativeFloatExclusion {
    require(width >= 0 && density.isFinite() && density > 0f)
    return NativeFloatExclusion(TableFloatSide.Right, NativeFloatBounds(width - 18f * density, 0f, width.toFloat(), 11f * density))
}

internal fun staticPosterPaintedLabel(label: String): String = label.replace(Regex("[ \\t\\r\\n\\u000c]+"), " ").trim(' ')
