package app.smallthingz.dict

/** The source block and its single inline image have separate used widths. */
internal data class FigureBlockMediaAllocation(
    val metrics: FigureBoxMetrics,
    val box: ContainerBoxWidth,
    val lineHeight: Float,
    val margins: SignedNativeContainerMargins,
)

/** The native adapter supplies the real source-font normal strut, including its baseline offset.
 * Authored lengths have already been normalized to the independent body font by the producer. */
internal class FigureBlockMediaMetrics(
    val wrapper: ContainerStyle,
    val media: FigureMediaLayout,
    private val preferredWidthPx: Long,
    private val naturalWidth: Long,
    private val naturalHeight: Long,
    private val density: Float,
    private val normalBodyPixels: Float,
    private val mediaFont: FigureMediaFont,
    private val normalStrut: NativeUsedLineMetrics,
    private val containingDirection: BidiResolvedDirection,
) {
    init {
        require(preferredWidthPx in 1L..0xffff_ffffL && naturalWidth in 1L..0xffff_ffffL &&
            naturalHeight in 1L..0xffff_ffffL)
        require(density.isFinite() && density > 0f && normalBodyPixels.isFinite() && normalBodyPixels >= 0f)
        require(wrapper.width == ContainerWidth.Auto && wrapper.lineHeight != null && wrapper.textAlign != null)
        require(media.verticalAlign == InlineBoxVerticalAlign.Middle)
        require(media.maxWidth == null || media.maxWidth.percent == 100f && media.maxWidth.subtract.value == 0f)
    }

    private val resolved = wrapper.atViewport(0.0)
    private fun margin(value: ContainerMargin?): Float = (value as? ContainerMargin.Length)?.value?.let {
        val pixels = it.value.toDouble() * if (it.unit == StyleLengthUnit.Px) density else normalBodyPixels
        if (!pixels.isFinite() || kotlin.math.abs(pixels) > TablePixelLimit)
            throw UnsupportedFloatLayout("Figure block margin exceeds native geometry")
        pixels.toFloat()
    } ?: 0f

    /** Auto margins are zero during intrinsic contribution; used horizontal values belong to box. */
    val margins = SignedNativeContainerMargins(margin(resolved.margins?.top), margin(resolved.margins?.right),
        margin(resolved.margins?.bottom), margin(resolved.margins?.left))

    private fun imagePixels(available: Float?): FigurePixels {
        val preferred = preferredWidthPx.toDouble() * density
        val width = if (available != null && media.maxWidth != null) minOf(preferred, available.toDouble()) else preferred
        val height = width * naturalHeight.toDouble() / naturalWidth.toDouble()
        // One projection retains the authenticated rendition ratio at the existing image safety cap.
        val projection = if (width == 0.0 && height == 0.0) 1.0
            else minOf(1.0, MaxComputedFontPixels.toDouble() / maxOf(width, height))
        return FigurePixels((width * projection).toFloat(), (height * projection).toFloat())
    }

    /** A cyclic percentage cap is zero for the replaced image's MIN contribution, absent for MAX. */
    fun intrinsic(): NativeWidthRange {
        val maximum = figureCoordinate(imagePixels(null).width)
        return NativeWidthRange(if (media.maxWidth == null) maximum else 0, maximum)
    }

    fun resolve(containingWidth: Float): FigureBlockMediaAllocation {
        figureCoordinate(containingWidth)
        val box = containerBoxWidth(resolved, containingWidth, ContainerWidths(0f, 0f), density,
            normalBodyPixels, rtl = containingDirection == BidiResolvedDirection.Rtl)
        figureCoordinate(box.borderBox)
        if (listOf(box.marginLeft, box.marginRight).any { !it.isFinite() || kotlin.math.abs(it) > TablePixelLimit })
            throw UnsupportedFloatLayout("Figure block origin exceeds native geometry")
        val image = imagePixels(box.content)
        val lineStrut = when (val policy = checkNotNull(wrapper.lineHeight)) {
            ContainerLineHeight.Normal -> normalStrut
            is ContainerLineHeight.Multiplier -> checkNotNull(mediaFont.primary.authored(NativeLineHeightPolicy.Multiplier(policy.value)))
            is ContainerLineHeight.Length -> {
                val pixels = policy.value.value.toDouble() *
                    if (policy.value.unit == StyleLengthUnit.Px) density else normalBodyPixels
                figureCoordinate(pixels)
                checkNotNull(mediaFont.primary.authored(NativeLineHeightPolicy.Pixels(pixels.toFloat())))
            }
        }
        val line = figureMediaLine(mediaFont, media.verticalAlign, image.height, lineStrut = lineStrut)
        figureCoordinate(line.height)
        val left = when (checkNotNull(wrapper.textAlign)) {
            CellTextAlign.Left -> 0f
            CellTextAlign.Center -> (box.content - image.width) / 2f
            CellTextAlign.Right -> box.content - image.width
        }
        val zero = FigurePixelEdges(0f, 0f, 0f, 0f)
        val metrics = FigureBoxMetrics(image, FigurePixelEdges(margins.top, box.marginRight, margins.bottom, box.marginLeft),
            FigurePixelEdges(line.contentTop, box.content - (left + image.width),
                line.height - (line.contentTop + image.height), left), zero, 0f, 0f)
        // Derived signed insets reuse the Figure owner, but may not change its integer allocation.
        if (metrics.width != figureCoordinate(box.borderBox) || metrics.height(0) != figureCoordinate(line.height))
            throw UnsupportedFloatLayout("Figure block dimensions lose precision in the native box")
        return FigureBlockMediaAllocation(metrics, box, line.height, margins)
    }
}
