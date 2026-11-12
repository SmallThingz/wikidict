package app.smallthingz.dict

import kotlin.math.max
import kotlin.math.min

internal data class ContainerWidths(val minimum: Float, val maximum: Float) {
    init { require(minimum.isFinite() && maximum.isFinite() && minimum >= 0f && maximum >= minimum) }
}
internal data class ContainerBoxWidth(val content: Float, val borderBox: Float, val marginBox: Float,
    val marginLeft: Float, val marginRight: Float)

private fun ContainerStyle.withoutViewportOverride(): ContainerViewportStyle {
    require(screenMaxWidth == null) { "Resolve conditional container style against the root viewport first" }
    return atViewport(0f)
}

internal fun containerBoxWidth(style: ContainerStyle, containingWidth: Float, intrinsic: ContainerWidths,
    density: Float, normalBodyFont: Float, flexItem: Boolean = false, rtl: Boolean = false): ContainerBoxWidth =
    containerBoxWidth(style.withoutViewportOverride(), containingWidth, intrinsic, density, normalBodyFont, flexItem, rtl)

/** Used box geometry in pixels. Flex Auto uses max-content; [containerFlexMeasure] retains the unclamped base. */
internal fun containerBoxWidth(resolved: ContainerViewportStyle, containingWidth: Float, intrinsic: ContainerWidths,
    density: Float, normalBodyFont: Float, flexItem: Boolean = false, rtl: Boolean = false): ContainerBoxWidth {
    require(listOf(containingWidth, density, normalBodyFont).all { it.isFinite() && it >= 0f })
    val style = resolved.box
    fun length(value: StyleLength): Float = value.value * if (value.unit == StyleLengthUnit.Px) density else normalBodyFont
    fun width(value: StyleWidth): Float = value.value * when (value.unit) {
        StyleWidthUnit.Px -> density
        StyleWidthUnit.Em -> normalBodyFont
        StyleWidthUnit.Percent -> containingWidth / 100f
    }
    val padding = style.padding?.let { length(it.left) + length(it.right) } ?: 0f
    val border = style.border.physicalEdges().let { sides ->
        (sides.left.usedWidth?.let(::length) ?: 0f) + (sides.right.usedWidth?.let(::length) ?: 0f)
    }
    val edges = padding + border
    fun margin(value: ContainerMargin?): Float = (value as? ContainerMargin.Length)?.let {
        it.value.value * if (it.value.unit == StyleLengthUnit.Px) density else normalBodyFont
    } ?: 0f
    var left = margin(resolved.margins?.left)
    var right = margin(resolved.margins?.right)
    fun contentBox(request: Float) = if (style.boxSizing == ContainerBoxSizing.BorderBox) max(0f, request - edges) else request
    val available = max(0f, containingWidth - left - right - edges)
    val used = when (val request = style.width) {
        is ContainerWidth.Length -> contentBox(width(request.value))
        ContainerWidth.FitContent -> min(max(intrinsic.minimum, available), intrinsic.maximum)
        ContainerWidth.Auto, null -> when {
            flexItem -> intrinsic.maximum
            style.floatSide != null -> min(max(intrinsic.minimum, available), intrinsic.maximum)
            else -> available
        }
    }
    val limited = when (val limit = style.maxWidth) {
        is ContainerMaxWidth.Length -> min(used, contentBox(width(limit.value)))
        ContainerMaxWidth.None, null -> used
    }
    val borderBox = limited + edges
    // Normal blocks solve margins after the used width/max-width. Floats keep auto
    // margins zero; flex items resolve their auto margins after the entire row flexes.
    if (!flexItem && style.floatSide == null) {
        val free = containingWidth - borderBox - left - right
        val leftAuto = resolved.margins?.left == ContainerMargin.Auto
        val rightAuto = resolved.margins?.right == ContainerMargin.Auto
        when {
            free >= 0f && leftAuto && rightAuto -> { left = free / 2f; right = free / 2f }
            free >= 0f && leftAuto -> left = free
            free >= 0f && rightAuto -> right = free
            rtl -> left += free
            else -> right += free
        }
    }
    val result = ContainerBoxWidth(limited, borderBox,
        if (!flexItem && style.floatSide == null) containingWidth else max(0f, borderBox + left + right), left, right)
    require(listOf(result.content, result.borderBox, result.marginBox).all { it.isFinite() && it >= 0f }) {
        "Container width exceeds the numeric range"
    }
    require(left.isFinite() && right.isFinite())
    return result
}

/** An inherited multiplier follows the descendant font; a computed length never does. */
internal fun containerLineHeightPixels(value: ContainerLineHeight?, density: Float,
    normalBodyFont: Float, descendantFont: Float): Float? {
    require(listOf(density, normalBodyFont, descendantFont).all { it.isFinite() && it >= 0f })
    val result = when (value) {
        null, ContainerLineHeight.Normal -> return null
        is ContainerLineHeight.Multiplier -> value.value * descendantFont
        is ContainerLineHeight.Length -> value.value.value *
            if (value.value.unit == StyleLengthUnit.Px) density else normalBodyFont
    }
    require(result.isFinite() && result >= 0f)
    return result
}

/** Flex bases and automatic minimums come from the same real child intrinsic measurements. */
internal data class ContainerFlexWidth(val basis: Float, val minimum: Float, val outerEdges: Float,
    val shrink: Boolean = true, val maximum: Float? = null, val marginLeft: Float = 0f,
    val marginRight: Float = 0f, val autoMarginLeft: Boolean = false, val autoMarginRight: Boolean = false) {
    init {
        require(basis.isFinite() && minimum.isFinite() && minimum >= 0f &&
            outerEdges.isFinite() && outerEdges >= 0f && basis.toDouble() + outerEdges >= 0.0)
        require(maximum == null || maximum.isFinite() && maximum >= minimum)
        require(listOf(marginLeft, marginRight).all { it.isFinite() && it >= 0f } &&
            marginLeft.toDouble() + marginRight <= outerEdges.toDouble())
        require(!autoMarginLeft || marginLeft == 0f)
        require(!autoMarginRight || marginRight == 0f)
    }
}

/** The specified-size suggestion caps the automatic minimum; fixed width is not a table-cell minimum. */
internal fun containerFlexMeasure(style: ContainerStyle, containingWidth: Float, intrinsic: ContainerWidths,
    density: Float, normalBodyFont: Float): ContainerFlexWidth =
    containerFlexMeasure(style.withoutViewportOverride(), containingWidth, intrinsic, density, normalBodyFont)

internal fun containerFlexMeasure(resolved: ContainerViewportStyle, containingWidth: Float, intrinsic: ContainerWidths,
    density: Float, normalBodyFont: Float): ContainerFlexWidth {
    val style = resolved.box
    val box = containerBoxWidth(resolved.copy(box = style.copy(maxWidth = ContainerMaxWidth.None)), containingWidth,
        intrinsic, density, normalBodyFont, flexItem = true)
    val edges = box.borderBox - box.content
    fun width(value: StyleWidth): Float = value.value * when (value.unit) {
        StyleWidthUnit.Px -> density
        StyleWidthUnit.Em -> normalBodyFont
        StyleWidthUnit.Percent -> containingWidth / 100f
    }
    fun content(value: StyleWidth): Float = width(value) -
        if (style.boxSizing == ContainerBoxSizing.BorderBox) edges else 0f
    val specified = (style.width as? ContainerWidth.Length)?.let { content(it.value) }
    val maximum = (style.maxWidth as? ContainerMaxWidth.Length)?.let { max(0f, content(it.value)) }
    var minimum = if (style.overflow == ContainerOverflow.Auto) 0f else
        min(intrinsic.minimum, specified?.coerceAtLeast(0f) ?: intrinsic.minimum)
    if (maximum != null) minimum = min(minimum, maximum)
    // Flex9.2 ignores min/max and the zero floor while establishing the inner base. A
    // border-box width0 with positive padding therefore has a negative inner base.
    return ContainerFlexWidth(specified ?: box.content, minimum, box.marginBox - box.content,
        shrink = style.flexItem != ContainerFlexItem.None, maximum = maximum,
        marginLeft = box.marginLeft, marginRight = box.marginRight,
        autoMarginLeft = resolved.margins?.left == ContainerMargin.Auto,
        autoMarginRight = resolved.margins?.right == ContainerMargin.Auto)
}

/** Main-axis auto margins consume positive space only after the complete row's flex sizing. */
internal fun containerFlexMargins(available: Float, items: List<ContainerFlexWidth>, widths: List<Float>): List<Pair<Float, Float>> {
    require(available.isFinite() && available >= 0f && items.size == widths.size)
    require(widths.all { it.isFinite() && it >= 0f })
    val count = items.sumOf { (if (it.autoMarginLeft) 1 else 0) + (if (it.autoMarginRight) 1 else 0) }
    val free = available.toDouble() - items.indices.sumOf { widths[it].toDouble() + items[it].outerEdges }
    val share = if (count > 0 && free > 0.0) (free / count).toFloat() else 0f
    return items.map { (it.marginLeft + if (it.autoMarginLeft) share else 0f) to
        (it.marginRight + if (it.autoMarginRight) share else 0f) }
}
internal fun containerFlexWidths(available: Float, items: List<ContainerFlexWidth>): List<Float> {
    require(available.isFinite() && available >= 0f)
    fun clamp(index: Int, value: Double): Double = maxOf(items[index].minimum.toDouble(),
        minOf(value, items[index].maximum?.toDouble() ?: Double.POSITIVE_INFINITY), 0.0)
    val hypothetical = items.indices.map { clamp(it, items[it].basis.toDouble()) }
    // The supported profile has flex-grow zero. Positive free space remains free after
    // hypothetical min/max constraints; it must not inflate a flex:auto basis.
    if (items.indices.sumOf { hypothetical[it] + items[it].outerEdges } < available)
        return hypothetical.map { it.toFloat() }
    val result = items.map { it.basis.toDouble() }.toMutableList()
    val frozen = BooleanArray(items.size) { !items[it].shrink || items[it].basis < hypothetical[it] }
    items.indices.filter { frozen[it] }.forEach { result[it] = hypothetical[it] }
    repeat(items.size + 1) {
        val active = items.indices.filter { !frozen[it] }
        if (active.isEmpty()) return result.map { it.toFloat() }
        val free = available.toDouble() - items.indices.sumOf { index ->
            items[index].outerEdges + if (frozen[index]) result[index] else items[index].basis.toDouble()
        }
        val weight = active.sumOf { items[it].basis.toDouble() }
        val violations = DoubleArray(items.size)
        active.forEach { index ->
            val target = items[index].basis.toDouble() - if (weight > 0.0)
                kotlin.math.abs(free) * items[index].basis / weight else 0.0
            result[index] = clamp(index, target)
            violations[index] = result[index] - target
        }
        val violation = active.sumOf { violations[it] }
        var newlyFrozen = 0
        active.forEach { index ->
            if (violation == 0.0 || violation > 0.0 && violations[index] > 0.0 ||
                violation < 0.0 && violations[index] < 0.0) {
                frozen[index] = true; newlyFrozen++
            }
        }
        check(newlyFrozen > 0) { "Flex min/max resolution made no progress" }
    }
    error("Flex shrink did not converge")
}
