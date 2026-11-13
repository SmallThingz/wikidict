package app.smallthingz.dict

sealed interface FigureBorderEdge {
    data object None : FigureBorderEdge
    data object Hidden : FigureBorderEdge
    data class Solid(val width: StyleLength, val color: FigureColor) : FigureBorderEdge
    data class Dotted(val width: StyleLength, val color: FigureColor) : FigureBorderEdge
}
data class FigureBorderEdges(val top: FigureBorderEdge, val right: FigureBorderEdge,
    val bottom: FigureBorderEdge, val left: FigureBorderEdge)
data class AvailableWidthLimit(val percent: Float, val subtract: StyleLength) {
    init { require(percent == 100f) { "Unsupported Figure media width expression" } }
}
data class FigureMediaStrut(val fontScale: Float, val bold: Boolean = false, val italic: Boolean = false,
    val code: Boolean = false, val language: String = "", val direction: BidiResolvedDirection,
    val fontFeatures: FontFeaturePolicy? = null) {
    init {
        require(fontScale.isFinite() && fontScale >= 0f) { "Invalid Figure media font scale" }
        require(validPresentationString(language)) { "Invalid Figure media language" }
    }
}
enum class FigureMediaGraphic { MagnifyClipLtrV1, MagnifyClipRtlV1 }
data class FigureGraphicPaint(val graphic: FigureMediaGraphic, val invert: Boolean = false)
data class FigureMediaAfter(val width: StyleLength, val height: StyleLength, val side: TableFloatSide,
    val inset: StyleLength, val bottom: ContainerMarginLength, val paint: FigureGraphicPaint? = null) {
    init {
        require(width == StyleLength(StyleLengthUnit.Px, 15f) && height == StyleLength(StyleLengthUnit.Px, 11f) &&
            inset == StyleLength(StyleLengthUnit.Px, 6f) && bottom.unit == StyleLengthUnit.Px && bottom.value == -11f) {
            "Unsupported Figure after box"
        }
    }
}
data class FigureFocusOutline(val width: StyleLength, val color: FigureColor, val radius: StyleLength,
    val offset: ContainerMarginLength)
data class FigureLinkState(val foreground: String, val underline: Boolean) {
    init { require(Regex("#[0-9a-f]{6}").matches(foreground)) { "Invalid Figure link foreground" } }
}
data class FigureLinkPaint(val normal: FigureLinkState, val hover: FigureLinkState,
    val active: FigureLinkState, val visited: FigureLinkState, val visitedHover: FigureLinkState,
    val visitedActive: FigureLinkState, val underlineOnFocus: Boolean,
    val focusOutline: FigureFocusOutline? = null) {
    init { require(focusOutline == null || focusOutline.color is FigureColor.Rgb) {
        "Figure link focus requires its source RGB color"
    } }
    internal fun state(visited: Boolean, hovered: Boolean, active: Boolean): FigureLinkState = when {
        visited && active -> visitedActive
        visited && hovered -> visitedHover
        visited -> this.visited
        active -> this.active
        hovered -> hover
        else -> normal
    }
}
data class FigureMediaLayout(val strut: FigureMediaStrut, val verticalAlign: InlineBoxVerticalAlign,
    val maxWidth: AvailableWidthLimit? = null, val positioning: ContainerPositioning? = null,
    val after: FigureMediaAfter? = null, val focusOutline: FigureFocusOutline? = null) {
    init {
        require(verticalAlign in listOf(InlineBoxVerticalAlign.Baseline, InlineBoxVerticalAlign.Middle)) {
            "Unsupported Figure media alignment"
        }
        require(after == null || positioning == ContainerPositioning.RelativeAuto) {
            "Figure after box requires its positioned anchor"
        }
    }
    internal fun validFor(content: FigureContent): Boolean = when (content) {
        is FigureContent.Missing -> verticalAlign == InlineBoxVerticalAlign.Baseline && maxWidth == null &&
            positioning == null && after == null && focusOutline == null
        is FigureContent.Image -> verticalAlign == InlineBoxVerticalAlign.Middle &&
            (after == null && focusOutline == null || content.span.kind in listOf("link", "external_link") &&
                content.span.target.isNotEmpty())
    }
}
data class FigureViewportState(val maxWidthPx: Long, val wrapper: ContainerStyle,
    val media: FigureMediaLayout, val captionBefore: ContainerStyle? = null) {
    init {
        require(maxWidthPx in 0L..0xffff_ffffL) { "Invalid Figure viewport threshold" }
        require(validFigureViewportWrapper(wrapper)) { "Unsupported Figure viewport wrapper" }
        require(captionBefore == null || validFigureCaptionBefore(captionBefore)) { "Unsupported Figure caption float" }
    }
}
data class TableCaptionLayout(val collapse: TableCollapse, val wrapper: ContainerStyle, val tableBorder: FigureBorderEdges,
    val captionBorder: FigureBorderEdges, val media: FigureMediaLayout,
    val captionBefore: ContainerStyle? = null, val viewportStates: List<FigureViewportState> = emptyList(),
    val missingLinkPaint: FigureLinkPaint? = null, val captionLinkPaint: FigureLinkPaint? = null) {
    init {
        require(collapse == TableCollapse.Collapse) { "Unsupported Figure table spacing" }
        require(validFigureViewportWrapper(wrapper)) { "Unsupported Figure base wrapper" }
        require(captionBefore == null || validFigureCaptionBefore(captionBefore)) { "Unsupported Figure caption float" }
        require(viewportStates.size <= 16) { "Too many Figure viewport states" }
        require(viewportStates.zipWithNext().all { (a, b) -> a.maxWidthPx > b.maxWidthPx }) {
            "Figure viewport states must be strictly descending"
        }
    }
    internal fun stateAtViewport(cssWidth: Double): FigureViewportState? {
        require(cssWidth.isFinite() && cssWidth >= 0)
        return viewportStates.lastOrNull { cssWidth <= it.maxWidthPx.toDouble() }
    }
}

private fun ContainerMarginEdges.nonnegative(): Boolean = listOf(top, right, bottom, left).all { it.value >= 0f }
private fun ContainerMargin.nonnegativeLength(): Boolean = this is ContainerMargin.Length && value.value >= 0f
internal fun validFigureViewportWrapper(style: ContainerStyle): Boolean =
    style == ContainerStyle(margins = style.margins, floatSide = style.floatSide, clear = style.clear,
        marginValues = style.marginValues) && style.margins?.nonnegative() != false &&
        style.marginValues?.let {
            it.top.nonnegativeLength() && it.bottom.nonnegativeLength() &&
                (it.left == ContainerMargin.Auto || it.left.nonnegativeLength()) &&
                (it.right == ContainerMargin.Auto || it.right.nonnegativeLength())
        } != false

internal fun validFigureCaptionBefore(style: ContainerStyle): Boolean =
    style == ContainerStyle(margins = style.margins, width = style.width, floatSide = style.floatSide,
        boxSizing = style.boxSizing, layout = style.layout, background = style.background,
        border = style.border, height = style.height) && style.margins?.nonnegative() != false &&
        (style.width as? ContainerWidth.Length)?.value?.unit in listOf(StyleWidthUnit.Px, StyleWidthUnit.Em) &&
        style.height != null && style.floatSide != null &&
        style.boxSizing in listOf(null, ContainerBoxSizing.ContentBox) &&
        style.layout in listOf(null, ContainerLayout.Flow) &&
        style.background in listOf(null, ContainerColor.Transparent) &&
        style.border in listOf(null, ContainerBorder.None)
