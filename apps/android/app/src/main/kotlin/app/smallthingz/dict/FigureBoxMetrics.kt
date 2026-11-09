package app.smallthingz.dict

import kotlin.math.ceil
import kotlin.math.floor

internal data class FigurePixels(val width: Float, val height: Float,
    val sourceWidth: Double? = null, val sourceHeight: Double? = null)
internal data class FigurePixelEdges(val top: Float, val right: Float, val bottom: Float, val left: Float)
internal data class FigureBoxMetrics(
    val image: FigurePixels,
    val margins: FigurePixelEdges,
    val imageInsets: FigurePixelEdges,
    val captionPadding: FigurePixelEdges,
    val frameBorder: Float,
    val imageBorder: Float,
    val frameMinWidth: Float? = null,
) {
    private val naturalInnerWidth: Float get() = imageInsets.left + imageBorder * 2 + image.width + imageInsets.right
    val frameMinimumWidens: Boolean get() = frameMinWidth != null && frameMinWidth > naturalInnerWidth
    // The authored floor owns the content box; outer frame borders are added once below.
    val innerWidth: Float get() = maxOf(naturalInnerWidth, frameMinWidth ?: 0f)
    val width: Int get() = figureCoordinate(innerWidth + frameBorder * 2)
    val captionWidth: Int get() {
        val available = innerWidth - captionPadding.left - captionPadding.right
        if (available < 0) throw UnsupportedFloatLayout("Figure caption edges exceed its content width")
        return floor(available).toInt()
    }
    val imageLeft: Float get() = frameBorder + imageInsets.left + imageBorder
    val imageTop: Float get() = frameBorder + imageInsets.top + imageBorder
    val captionTop: Float get() = frameBorder + imageInsets.top + imageBorder * 2 + image.height + imageInsets.bottom
    val captionLeft: Float get() = frameBorder + captionPadding.left
    fun height(captionHeight: Int): Int {
        require(captionHeight >= 0)
        // Required padding owns an empty caption box too. Empty content supplies zero line height.
        return figureCoordinate(captionTop + captionPadding.top + captionHeight + captionPadding.bottom + frameBorder)
    }
}

internal fun figureCoordinate(value: Double): Int {
    if (!value.isFinite() || value < 0 || value > Int.MAX_VALUE / 4)
        throw UnsupportedFloatLayout("Figure exceeds the platform coordinate range")
    return ceil(value).toInt()
}
internal fun figureCoordinate(value: Float): Int = figureCoordinate(value.toDouble())

/** No font-size ceiling or implicit default image width is applied to authored figure geometry. */
internal fun figureLengthPixels(length: StyleLength, density: Float, normalBodyPixels: Float): Float {
    require(density.isFinite() && density > 0 && normalBodyPixels.isFinite() && normalBodyPixels > 0)
    val pixels = length.value.toDouble() * if (length.unit == StyleLengthUnit.Px) density else normalBodyPixels
    figureCoordinate(pixels)
    return pixels.toFloat()
}

internal data class FigureSourceSize(val width: ULong, val height: ULong)

/** A media-state box reserves requested width, not an invented image aspect or map coordinate space. */
internal fun figurePlaceholderWidth(figure: Figure, density: Float, naturalTextWidth: Float): Int {
    require(density.isFinite() && density > 0 && naturalTextWidth.isFinite() && naturalTextWidth >= 0)
    val requested = when (figure.sizing) {
        FigureSizingPolicy.RequestedFit, FigureSizingPolicy.RequestedFitCapOriginalWidth -> figure.imageSpan.image!!.widthPx
        FigureSizingPolicy.Intrinsic, FigureSizingPolicy.OriginalWidthWithHeightBound -> null
    }
    return figureCoordinate(maxOf(1.0, requested?.toDouble()?.times(density) ?: naturalTextWidth.toDouble()))
}

internal fun figurePlaceholderPixels(width: Int, measuredTextHeight: Int): FigurePixels {
    require(width > 0 && measuredTextHeight > 0)
    figureCoordinate(width.toDouble()); figureCoordinate(measuredTextHeight.toDouble())
    return FigurePixels(width.toFloat(), measuredTextHeight.toFloat())
}

/** All multiplicands are positive u32 values, so their products fit an unsigned 64-bit integer. */
internal fun figureSourceSize(figure: Figure, originalWidth: Long, originalHeight: Long): FigureSourceSize {
    if (originalWidth !in 1L..0xffff_ffffL || originalHeight !in 1L..0xffff_ffffL)
        throw UnsupportedFloatLayout("Verified original image dimensions are unavailable")
    val originalW = originalWidth.toULong(); val originalH = originalHeight.toULong()
    val image = requireNotNull(figure.imageSpan.image)
    if (figure.sizing == FigureSizingPolicy.Intrinsic) return FigureSourceSize(originalW, originalH)
    var width = when (figure.sizing) {
        FigureSizingPolicy.OriginalWidthWithHeightBound -> originalW
        FigureSizingPolicy.RequestedFit -> requireNotNull(image.widthPx).toULong()
        FigureSizingPolicy.RequestedFitCapOriginalWidth -> minOf(requireNotNull(image.widthPx).toULong(), originalW)
        FigureSizingPolicy.Intrinsic -> error("Intrinsic size returned above")
    }
    fun rounded(numerator: ULong, denominator: ULong): ULong {
        val whole = numerator / denominator
        // Avoid adding half to the product, which could overflow near the u64 boundary.
        return whole + if (numerator % denominator >= (denominator + 1uL) / 2uL) 1uL else 0uL
    }
    val bound = image.heightPx?.toULong()
    val height = if (bound != null && width * originalH > bound * originalW) {
        val product = originalW * bound
        val down = product / originalH
        val up = down + if (product % originalH == 0uL) 0uL else 1uL
        width = if (rounded(up * originalH, originalW) > bound) down else up
        if (width == 0uL) width = 1uL
        // Source logical height survives the fitted-width minimum; backing pixels are independent.
        bound
    } else rounded(originalH * width, originalW)
    return FigureSourceSize(width, height)
}

internal fun figureImagePixels(figure: Figure, originalWidth: Long, originalHeight: Long,
    density: Float): FigurePixels {
    require(density.isFinite() && density > 0)
    val exact = figureSourceSize(figure, originalWidth, originalHeight)
    fun logical(axis: ULong): Double {
        if (axis > 9_007_199_254_740_992uL)
            throw UnsupportedFloatLayout("Figure logical axis exceeds exact numeric conversion")
        return axis.toDouble()
    }
    val source = logical(exact.width) to logical(exact.height)
    fun pixels(axis: Double): Float {
        val physical = axis * density
        figureCoordinate(physical)
        // Source HTML axes were rounded above, before density. Keep them for map normalization.
        return floor(physical + 0.5).toFloat()
    }
    return FigurePixels(pixels(source.first), pixels(source.second), source.first, source.second)
}

internal fun figureBoxMetrics(figure: Figure, image: FigurePixels, density: Float,
    normalBodyPixels: Float): FigureBoxMetrics {
    fun edges(value: StyleEdges) = FigurePixelEdges(
        figureLengthPixels(value.top, density, normalBodyPixels),
        figureLengthPixels(value.right, density, normalBodyPixels),
        figureLengthPixels(value.bottom, density, normalBodyPixels),
        figureLengthPixels(value.left, density, normalBodyPixels))
    fun border(value: FigureBorder) = when (value) {
        FigureBorder.None -> 0f
        is FigureBorder.Solid -> figureLengthPixels(value.width, density, normalBodyPixels)
    }
    return FigureBoxMetrics(image, edges(figure.margins), edges(figure.imageInsets),
        edges(figure.captionPadding), border(figure.frameBorder), border(figure.imageBorder),
        figure.frameMinWidth?.let { figureLengthPixels(it, density, normalBodyPixels) }).also {
        it.width; it.captionWidth; it.height(0)
    }
}
