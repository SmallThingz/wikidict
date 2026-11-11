package app.smallthingz.dict

/** The admitted row is single-line, grow zero and horizontal writing. */
internal data class NativeFlexRowPolicy(val alignment: ContainerAlignItems = ContainerAlignItems.Stretch,
    val rtl: Boolean = false)
internal data class NativeFlexCrossMargins(val autoTop: Boolean = false, val autoBottom: Boolean = false)
internal class NativeFlexItemSpec(val measure: (Float, ContainerWidths) -> ContainerFlexWidth,
    val intrinsic: (ContainerWidths, Boolean) -> Float,
    val crossMargins: NativeFlexCrossMargins = NativeFlexCrossMargins())
internal data class NativeFlexItemAllocation(val width: Float, val left: Float, val right: Float)

/** Blink's row intrinsic contribution policy, restricted to this model's grow-zero auto/none
 * profile. A definite width supplies the clamped hypothetical contribution; content-derived
 * bases contribute native min/max sizes. Cyclic percentages are indefinite here and resolve
 * only when the actual row containing width is known. This is not the spec's ideal algorithm. */
internal fun containerFlexIntrinsicContribution(resolved: ContainerViewportStyle, intrinsic: ContainerWidths,
    density: Float, normalBodyFont: Float, maximum: Boolean): Float {
    val style = resolved.box
    val definite = (style.width as? ContainerWidth.Length)?.takeIf { it.value.unit != StyleWidthUnit.Percent }
    val maxWidth = (style.maxWidth as? ContainerMaxWidth.Length)?.takeIf { it.value.unit != StyleWidthUnit.Percent }
    val available = if (maximum) intrinsic.maximum else intrinsic.minimum
    val selected = resolved.copy(box = style.copy(width = definite ?: ContainerWidth.Auto,
        maxWidth = maxWidth ?: ContainerMaxWidth.None, floatSide = null))
    val own = if (definite == null) ContainerWidths(available, available) else intrinsic
    return containerBoxWidth(selected, 0f, own, density, normalBodyFont, flexItem = true).marginBox
}

internal data class NativeFlexCrossPlacement(val top: Float, val borderHeight: Float)

/** Stretch applies only to an auto-height item. Definite cross sizes and signed alignment
 * offsets never rescale or remeasure the original text/media contents. */
internal fun nativeFlexCrossPlacement(lineHeight: Float, borderHeight: Float, top: Float, bottom: Float,
    margins: NativeFlexCrossMargins, alignment: ContainerAlignItems,
    definiteHeight: Boolean = false, minimumBorderHeight: Float = 0f): NativeFlexCrossPlacement {
    require(listOf(lineHeight, borderHeight, top, bottom).all { it.isFinite() && it >= 0f })
    require(minimumBorderHeight.isFinite() && minimumBorderHeight in 0f..borderHeight)
    require(!margins.autoTop || top == 0f)
    require(!margins.autoBottom || bottom == 0f)
    val free = lineHeight - borderHeight - top - bottom
    val remaining = maxOf(0f, free)
    if (margins.autoTop || margins.autoBottom) {
        val share = remaining / ((if (margins.autoTop) 1 else 0) + (if (margins.autoBottom) 1 else 0))
        return NativeFlexCrossPlacement(top + if (margins.autoTop) share else 0f, borderHeight)
    }
    return when (alignment) {
        ContainerAlignItems.Stretch -> NativeFlexCrossPlacement(top,
            if (definiteHeight) borderHeight else maxOf(minimumBorderHeight, lineHeight - top - bottom))
        ContainerAlignItems.Start -> NativeFlexCrossPlacement(top, borderHeight)
        ContainerAlignItems.Center -> NativeFlexCrossPlacement(top + free / 2f, borderHeight)
        ContainerAlignItems.End -> NativeFlexCrossPlacement(top + free, borderHeight)
    }
}
