package app.smallthingz.dict

/** CSS box lengths use density; the independent text size also honors Android text zoom. */
internal data class NativeDisclosureButtonInsets(val top: Float, val right: Float,
    val bottom: Float, val left: Float) {
    val horizontal: Float get() = left + right
    val vertical: Float get() = top + bottom
    init {
        require(listOf(top, right, bottom, left, horizontal, vertical).all {
            it.isFinite() && it >= 0f && it < Int.MAX_VALUE / 4f
        }) { "Disclosure button box exceeds native geometry" }
    }
}
internal fun nativeDisclosureButtonInsets(button: ContainerDisclosureButton,
    state: ContainerDisclosureButtonState, density: Float): NativeDisclosureButtonInsets {
    require(density.isFinite() && density > 0f)
    fun side(padding: StyleLength, border: ResolvedStyleBorderEdge) =
        (padding.value + (border.disclosureLine()?.first?.value ?: 0f)) * density
    return NativeDisclosureButtonInsets(side(button.padding.top, state.border.top),
        side(button.padding.right, state.border.right), side(button.padding.bottom, state.border.bottom),
        side(button.padding.left, state.border.left))
}
internal fun nativeDisclosureButtonFocusOverflow(button: ContainerDisclosureButton, density: Float): Float {
    require(density.isFinite() && density > 0f)
    val result = button.focusVisible?.outline?.let { maxOf(0f, it.offset.value + it.width.value) * density } ?: 0f
    if (!result.isFinite() || result >= Int.MAX_VALUE / 4f)
        throw UnsupportedFloatLayout("Disclosure focus exceeds native geometry")
    return result
}

internal fun nativeDisclosureButtonExtents(width: Float, textBottom: Float, text: NativeGeometryExtents,
    insets: NativeDisclosureButtonInsets, focusOverflow: Float): NativeGeometryExtents {
    val height = textBottom + insets.vertical
    if (!width.isFinite() || !height.isFinite() || width < insets.horizontal || textBottom < 0f ||
        !focusOverflow.isFinite() || focusOverflow < 0f)
        throw UnsupportedFloatLayout("Disclosure button has invalid used geometry")
    val box = NativeFloatBounds(-focusOverflow, -focusOverflow, width + focusOverflow, height + focusOverflow)
    return NativeGeometryExtents(kotlin.math.ceil(width).toInt(), height, box,
        NativeFloatBounds(0f, 0f, width, height)).including(text, insets.left, insets.top)
}
