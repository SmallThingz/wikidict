package app.smallthingz.dict

/** Value contract from A2 model 71e09682; public wire admission remains the decoder's job. */
data class ContainerDisclosureNamedFont(val name: String) {
    init {
        val aliases = setOf("serif", "sans-serif", "sans serif", "sans", "monospace", "cursive",
            "fantasy", "system", "system-ui", "ui-serif", "ui-sans-serif", "ui-monospace",
            "ui-rounded", "emoji", "math", "fangsong")
        require(name.length in 1..128 && name == name.trim() &&
            name.all { it.code in 0x20..0x7e && it != '[' && it != ']' } &&
            name.lowercase(java.util.Locale.ROOT).replace(Regex(" +"), " ") !in aliases) {
            "Unsupported disclosure named font"
        }
    }
}
// BlobDecoder reads these in wire order. Both use the explicit four-state box painter.
enum class ContainerDisclosureButtonAppearance { NativeButton, None }

internal fun ResolvedStyleBorderEdge.disclosureLine(): Pair<StyleLength, StyleBorderPaint>? = when (this) {
    ResolvedStyleBorderEdge.None, ResolvedStyleBorderEdge.Hidden -> null
    is ResolvedStyleBorderEdge.Solid -> width to paint
    is ResolvedStyleBorderEdge.Dotted -> width to paint
    is ResolvedStyleBorderEdge.Inset -> width to paint
    is ResolvedStyleBorderEdge.Outset -> width to paint
}
internal fun StyleBorder.ResolvedEdges.disclosureEdges() = listOf(top, right, bottom, left)

data class ContainerDisclosureButtonState(val background: FigureColor, val border: StyleBorder.ResolvedEdges) {
    init {
        require(background == FigureColor.Transparent || background is FigureColor.Rgb)
        require(border.disclosureEdges().all { edge -> edge.disclosureLine()?.let {
            it.first.unit == StyleLengthUnit.Px && it.second is StyleBorderPaint.Rgb
        } ?: true }) { "Disclosure button edges require pixel widths and RGB paint" }
    }
}
data class ContainerDisclosureButtonFocus(val mode: ContainerDisclosureFocusMode, val outline: FigureFocusOutline) {
    init {
        require(mode == ContainerDisclosureFocusMode.UaAuto && outline.color is FigureColor.Rgb &&
            outline.width.unit == StyleLengthUnit.Px && outline.width.value > 0f &&
            outline.radius.unit == StyleLengthUnit.Px && outline.radius.value == 0f &&
            outline.offset.unit == StyleLengthUnit.Px && outline.offset.value.isFinite())
    }
}
data class ContainerDisclosureButtonOutlineColors(val unfocused: FigureColor, val focused: FigureColor) {
    init { require(unfocused is FigureColor.Rgb && focused is FigureColor.Rgb) }
}
data class ContainerDisclosureButton(val appearance: ContainerDisclosureButtonAppearance,
    val fontFamily: ContainerDisclosureNamedFont, val fontSize: StyleLength, val fontWeight: Int,
    val fontItalic: Boolean, val lineHeight: ContainerLineHeight, val padding: StyleEdges,
    val normal: ContainerDisclosureButtonState, val hover: ContainerDisclosureButtonState,
    val active: ContainerDisclosureButtonState, val hoverActive: ContainerDisclosureButtonState,
    val focusVisible: ContainerDisclosureButtonFocus? = null,
    val outlineColors: ContainerDisclosureButtonOutlineColors? = null) {
    init {
        require(appearance == ContainerDisclosureButtonAppearance.NativeButton ||
            appearance == ContainerDisclosureButtonAppearance.None)
        require(fontSize.unit == StyleLengthUnit.Px && fontSize.value > 0f && fontWeight == 400 && !fontItalic)
        require(lineHeight == ContainerLineHeight.Normal || lineHeight is ContainerLineHeight.Length &&
            lineHeight.value.unit == StyleLengthUnit.Px && lineHeight.value.value > 0f)
        require(listOf(padding.top, padding.right, padding.bottom, padding.left).all { it.unit == StyleLengthUnit.Px })
    }
    internal fun state(hovered: Boolean, pressed: Boolean): ContainerDisclosureButtonState = when {
        hovered && pressed -> hoverActive
        pressed -> active
        hovered -> hover
        else -> normal
    }
    /** Colors alone never synthesize an outline; invisible focus still retains its computed color. */
    internal fun outlineColor(focused: Boolean, focusVisible: Boolean): FigureColor? {
        require(!focusVisible || focused)
        if (focusVisible) this.focusVisible?.let { return it.outline.color }
        return outlineColors?.let { if (focused) it.focused else it.unfocused }
    }
}
