package app.smallthingz.dict

/** Single-line horizontal-writing flex column with an indefinite (automatic) main size. */
internal data class NativeFlexColumnPolicy(val alignment: ContainerAlignItems = ContainerAlignItems.Stretch,
    val rtl: Boolean = false)

/** Cross-axis width is resolved before the original child's one content measurement. */
internal fun containerFlexColumnMeasure(resolved: ContainerViewportStyle, containingWidth: Float,
    intrinsic: ContainerWidths, density: Float, normalBodyFont: Float,
    policy: NativeFlexColumnPolicy): NativeFlexItemAllocation {
    require(containingWidth.isFinite() && containingWidth >= 0f)
    val style = resolved.box
    val autoWidth = style.width == null || style.width == ContainerWidth.Auto
    val leftAuto = resolved.margins?.left == ContainerMargin.Auto
    val rightAuto = resolved.margins?.right == ContainerMargin.Auto
    val raw = containerBoxWidth(resolved, containingWidth, intrinsic, density, normalBodyFont, flexItem = true)
    val edges = raw.borderBox - raw.content
    val available = (containingWidth - raw.marginLeft - raw.marginRight - edges).coerceAtLeast(0f)
    val stretch = autoWidth && policy.alignment == ContainerAlignItems.Stretch && !leftAuto && !rightAuto
    val box = when {
        stretch -> containerBoxWidth(resolved, containingWidth, ContainerWidths(0f, available),
            density, normalBodyFont, flexItem = true)
        autoWidth -> containerBoxWidth(resolved.copy(box = style.copy(width = ContainerWidth.FitContent)),
            containingWidth, intrinsic, density, normalBodyFont, flexItem = true)
        else -> raw
    }
    var left = box.marginLeft
    var right = box.marginRight
    val free = containingWidth - box.borderBox - left - right
    val offset = if (leftAuto || rightAuto) {
        if (free > 0f) {
            val share = free / ((if (leftAuto) 1 else 0) + (if (rightAuto) 1 else 0))
            if (leftAuto) left += share
            if (rightAuto) right += share
            0f
        } else {
            // With overflow, auto margins stay zero at cross-start. The computed
            // cross-end deficit changes placement only, never authored margins.
            if (policy.rtl) free else 0f
        }
    } else when (policy.alignment) {
        ContainerAlignItems.Center -> free / 2f
        ContainerAlignItems.End -> if (policy.rtl) 0f else free
        ContainerAlignItems.Start, ContainerAlignItems.Stretch -> if (policy.rtl) free else 0f
    }
    if (listOf(box.content, box.borderBox, left, right, offset).any {
            !it.isFinite() || kotlin.math.abs(it) > TablePixelLimit })
        throw UnsupportedFloatLayout("Flex column cross size exceeds native geometry")
    return NativeFlexItemAllocation(box.content, left, right, offset)
}

internal data class NativeFlexColumnItemHeight(val borderHeight: Float, val before: Float, val after: Float) {
    init { require(listOf(borderHeight, before, after).all { it.isFinite() && it >= 0f }) }
}
internal data class NativeFlexColumnStack(val tops: List<Float>, val height: Float)

/** Main size is auto: grow-zero auto/none items keep their own used heights, without shrink or margin collapse. */
internal fun nativeFlexColumnStack(items: List<NativeFlexColumnItemHeight>): NativeFlexColumnStack {
    var cursor = 0.0
    val tops = items.map { item ->
        cursor += item.before.toDouble()
        if (cursor > TablePixelLimit) throw UnsupportedFloatLayout("Flex column height exceeds native geometry")
        val top = cursor.toFloat()
        cursor += item.borderHeight.toDouble() + item.after.toDouble()
        if (cursor > TablePixelLimit) throw UnsupportedFloatLayout("Flex column height exceeds native geometry")
        top
    }
    return NativeFlexColumnStack(tops, cursor.toFloat())
}

/** Admission only: preserve the complete original tree for the existing unavailable-body renderer. */
internal fun nativeFlexColumnSourceSupported(container: Container): Boolean {
    if (container.disclosure != null || container.blocks.any { it.kind != "container" || it.container == null }) return false
    fun ordinary(owner: Container): Boolean = owner.style.let { style ->
        style.positioning == null && style.absolutePosition == null && style.absoluteStatic == null &&
            style.positionedScope == null && style.columns == null &&
            (style.overflow == null || style.overflow == ContainerOverflow.Visible) && owner.disclosure == null
    }
    var supported = ordinary(container)
    PresentationSpanVisitor { _, _ -> }.apply {
        onSpan = { span -> if (span.clippedAbsolute != null || span.inlineBoxGroup?.overlays?.isNotEmpty() == true)
            supported = false }
        onContainer = { if (!ordinary(it)) supported = false }
    }.blocks(container.blocks)
    return supported
}
