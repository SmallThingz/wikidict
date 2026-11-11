package app.smallthingz.dict

import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.RectF
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.TextUnit
import kotlin.math.ceil
import kotlin.math.floor

/** Paint belongs to the solved border box, not to its margin allocation or descendant ink. */
internal data class NativeContainerDecoration(val background: Int?, val borderColor: Int?, val borderWidth: Float) {
    fun paint(canvas: Canvas, box: RectF) {
        if (box.isEmpty) return
        val paint = Paint()
        background?.let { paint.color = it; canvas.drawRect(box, paint) }
        borderColor?.takeIf { borderWidth > 0f }?.let { color ->
            paint.color = color
            val x = minOf(borderWidth, box.width() / 2f)
            val y = minOf(borderWidth, box.height() / 2f)
            canvas.drawRect(box.left, box.top, box.right, box.top + y, paint)
            canvas.drawRect(box.left, box.bottom - y, box.right, box.bottom, paint)
            canvas.drawRect(box.left, box.top + y, box.left + x, box.bottom - y, paint)
            canvas.drawRect(box.right - x, box.top + y, box.right, box.bottom - y, paint)
        }
    }
}

/** This is the adapter for the existing prepared owner, not another measurement subtree. */
internal fun nativeContainerSpec(id: Int, resolved: ContainerViewportStyle,
    children: List<NativeFloatContextSpec>, density: Float, normalBodyFont: Float,
    rtl: Boolean, dark: Boolean, flexItem: Boolean): NativeFloatContextSpec.Container = try {
    supportedNativeContainerSpec(id, resolved, children, density, normalBodyFont, rtl, dark, flexItem)
} catch (error: UnsupportedFloatLayout) {
    // Keep the real leaves available to the existing visible fallback. Geometry
    // limits must not discard the body by throwing out of composition.
    NativeFloatContextSpec.Container(id, contentWidth = { width, _ -> width }, intrinsicWidth = { width, _ -> width },
        preparedParts = children, unavailableReason = error.message ?: "Container geometry is unavailable", content = {})
}

private fun supportedNativeContainerSpec(id: Int, resolved: ContainerViewportStyle,
    children: List<NativeFloatContextSpec>, density: Float, normalBodyFont: Float,
    rtl: Boolean, dark: Boolean, flexItem: Boolean): NativeFloatContextSpec.Container {
    val style = resolved.box
    fun length(value: StyleLength): Float {
        val result = value.value.toDouble() * if (value.unit == StyleLengthUnit.Px) density else normalBodyFont
        if (!result.isFinite() || result !in 0.0..TablePixelLimit.toDouble())
            throw UnsupportedFloatLayout("Container edge exceeds native geometry")
        return result.toFloat()
    }
    fun margin(value: ContainerMargin?): Float = (value as? ContainerMargin.Length)?.let { length(it.value) } ?: 0f
    val margins = resolved.margins?.let { FloatMargins(margin(it.top), margin(it.right), margin(it.bottom), margin(it.left)) }
        ?: FloatMargins(0f, 0f, 0f, 0f)
    val border = (style.border as? ContainerBorder.Solid)?.let { length(it.width) } ?: 0f
    val padding = style.padding?.let { FloatMargins(length(it.top) + border, length(it.right) + border,
        length(it.bottom) + border, length(it.left) + border) } ?: FloatMargins(border, border, border, border)
    fun color(value: ContainerColor?): Int? = when (value) {
        null, ContainerColor.Transparent -> null
        is ContainerColor.Rgb -> android.graphics.Color.parseColor(value.value)
        is ContainerColor.LightDark -> android.graphics.Color.parseColor(if (dark) value.dark else value.light)
    }
    val decoration = NativeContainerDecoration(color(style.background),
        color((style.border as? ContainerBorder.Solid)?.color), border)
        .takeIf { it.background != null || it.borderColor != null && it.borderWidth > 0f }
    val relativeAuto = style.positioning == ContainerPositioning.RelativeAuto
    if (relativeAuto && (flexItem || style.layout == ContainerLayout.FlexRow || style.floatSide != null ||
            style.columns != null || children.any { it !is NativeFloatContextSpec.Text }))
        throw UnsupportedFloatLayout("Positioned groups require one ordinary plaintext owner")
    val columns = style.columns?.let { NativeColumnPolicy(it.count, length(it.gap), rtl) }
    if (columns != null && (style.height != null || style.layout == ContainerLayout.FlexRow ||
            style.overflow == ContainerOverflow.Auto))
        throw UnsupportedFloatLayout("Columns require an auto-height ordinary formatting context")
    if (columns != null && children.any { it !is NativeFloatContextSpec.Text })
        throw UnsupportedFloatLayout("Column fragmentation for this child layout is unavailable")
    fun columnIntrinsic(intrinsic: ContainerWidths) = if (columns == null) intrinsic else
        ContainerWidths(columns.intrinsic(intrinsic.minimum), columns.intrinsic(intrinsic.maximum))
    fun solved(width: Float, intrinsic: ContainerWidths) =
        containerBoxWidth(resolved, width, columnIntrinsic(intrinsic), density, normalBodyFont, flexItem, rtl)
    fun pixels(value: Float): Int {
        if (!value.isFinite() || value !in 0f..TablePixelLimit.toFloat())
            throw UnsupportedFloatLayout("Container width exceeds native geometry")
        return floor(value).toInt()
    }
    val flex = if (!flexItem) null else NativeFlexItemSpec(
        measure = { width, intrinsic -> containerFlexMeasure(resolved, width, columnIntrinsic(intrinsic), density, normalBodyFont) },
        intrinsic = { intrinsic, maximum -> containerFlexIntrinsicContribution(resolved, columnIntrinsic(intrinsic), density, normalBodyFont, maximum) },
        crossMargins = NativeFlexCrossMargins(resolved.margins?.top == ContainerMargin.Auto,
            resolved.margins?.bottom == ContainerMargin.Auto))
    return NativeFloatContextSpec.Container(id,
        contentWidth = { width, intrinsic -> pixels(solved(width.toFloat(), intrinsic).content) },
        intrinsicWidth = { content, maximum ->
            // Percentages are indefinite during an intrinsic query, exactly as in row contributions.
            val value = containerFlexIntrinsicContribution(resolved, columnIntrinsic(ContainerWidths(content.toFloat(), content.toFloat())),
                density, normalBodyFont, maximum)
            if (value > TablePixelLimit) androidx.compose.ui.unit.Constraints.Infinity else ceil(value).toInt()
        }, margins = { margins }, padding = { padding },
        floatSide = if (flexItem) null else style.floatSide, clear = if (flexItem) null else style.clear,
        empty = children.isEmpty(), isolatesFloats = resolved.ownsFormattingContext || flexItem,
        preparedParts = children,
        horizontal = { width, intrinsic -> NativeContainerHorizontal.from(solved(width.toFloat(), intrinsic),
            padding.left, margins.left, margins.right) },
        row = if (style.layout == ContainerLayout.FlexRow) NativeFlexRowPolicy(style.alignItems ?: ContainerAlignItems.Stretch, rtl) else null,
        flex = flex, decoration = decoration, columns = columns, relativeAuto = relativeAuto,
        fixedContentHeight = containerUsedHeight(style, padding.top + padding.bottom,
            density, normalBodyFont)?.content,
        unavailableReason = if (style.overflow == ContainerOverflow.Auto)
            "Container scrolling needs a shared paint, input and accessibility viewport" else null,
        content = {})
}

internal data class NativeContainerLeaf(val block: Block, val previous: Block?, val id: Int,
    val path: String, val gridPath: String, val gap: Float, val rootIndex: Int?,
    val format: NativeContainerTextFormat?, val context: ContainerTextContext?,
    val align: CellTextAlign?, val inContainer: Boolean)

/** Project only real source owners. A logical UL/OL remains one flex item, and each
 * actual paragraph/figure/table leaf is prepared once at its original source address. */
@Composable
internal fun prepareNativeContainerTree(blocks: List<Block>, path: String, gridPath: String,
    rootPaths: List<String>?, rootGaps: List<Float>, inherited: ContainerTextContext,
    inheritedStyle: TextStyle, inheritedAlign: CellTextAlign?, normalBodySize: TextUnit,
    density: Density, rootViewport: Double, rtl: Boolean, dark: Boolean, fixedHeightReachable: Boolean,
    id: (String) -> Int, positionedPaintReachable: Boolean = false,
    leaf: @Composable (NativeContainerLeaf) -> List<NativeFloatContextSpec>
): List<NativeFloatContextSpec> {
    val bodyPixels = normalBodySize.value * density.density * density.fontScale
    fun groupIndices(item: ContainerFlowItem): List<Int> = when (item) {
        is ContainerFlowItem.Block -> listOf(item.index)
        is ContainerFlowItem.ListGroup -> item.items.flatMap { listOf(it.index) + it.children.flatMap(::groupIndices) }
    }
    @Composable fun visit(values: List<Block>, paths: List<String>, grids: List<String>,
        gaps: List<Float>, context: ContainerTextContext, align: CellTextAlign?, inside: Boolean,
        row: Boolean, roots: List<Int?>): List<NativeFloatContextSpec> {
        val result = mutableListOf<NativeFloatContextSpec>()
        val groups = if (row) containerFlowItems(values) else values.indices.map { ContainerFlowItem.Block(it) }
        for (group in groups) {
            val indices = groupIndices(group)
            val first = indices.first()
            val block = values[first]
            val container = block.container.takeIf { group is ContainerFlowItem.Block }
            if (container != null) {
                val resolved = container.style.atViewport(rootViewport)
                val requestedContext = resolved.box.textContext(context)
                var textFailure: String? = null
                val next = try {
                    nativeContainerTextFormat(requestedContext, normalBodySize, inheritedStyle, density)
                    requestedContext
                } catch (error: UnsupportedFloatLayout) {
                    textFailure = error.message ?: "Container text geometry is unavailable"
                    context
                }
                val nextAlign = resolved.box.textAlign ?: align
                val background = when (val value = resolved.box.background) {
                    is ContainerColor.Rgb -> value.value
                    is ContainerColor.LightDark -> if (dark) value.dark else value.light
                    null, ContainerColor.Transparent -> LocalAuthoredBackground.current
                }
                val children = mutableListOf<NativeFloatContextSpec>()
                CompositionLocalProvider(LocalAuthoredBackground provides background) {
                    children += visit(container.blocks,
                        container.blocks.indices.map { "${paths[first]}/container/block-$it" },
                        container.blocks.indices.map { "${grids[first]}/container/block-$it" },
                        List(container.blocks.size) { 0f }, next, nextAlign, true,
                        resolved.box.layout == ContainerLayout.FlexRow, List(container.blocks.size) { null })
                }
                val prepared = nativeContainerSpec(id(paths[first]), resolved, children,
                    density.density, bodyPixels, rtl, dark, row)
                val failure = textFailure ?: when {
                    resolved.box.height != null && !fixedHeightReachable ->
                        "Fixed-height overflow needs this owner's document extent export"
                    resolved.box.positioning != null && !positionedPaintReachable ->
                        "Positioned painting needs this owner's Entry stacking context"
                    else -> null
                }
                result += if (failure == null) prepared else prepared.copy(unavailableReason = failure)
            } else {
                val children = mutableListOf<NativeFloatContextSpec>()
                for (index in indices) {
                    val original = values[index]
                    // The generated flex item owns a direct block's edges; list groups
                    // retain every LI/detail's own block edges and marker geometry.
                    val consumed = row && group is ContainerFlowItem.Block
                    val rendered = if (consumed) original.copy(style = null) else original
                    val format = if (inside) nativeContainerTextFormat(context, normalBodySize, inheritedStyle, density) else null
                    children += leaf(NativeContainerLeaf(rendered, if (inside) null else values.getOrNull(index - 1),
                        id(paths[index] + "/leaf"), paths[index], grids[index], if (inside) 0f else gaps[index],
                        roots[index], format, context.takeIf { inside }, align, inside))
                }
                if (!row) result += children else {
                    val own = if (group is ContainerFlowItem.Block) ContainerStyle(margins = block.style?.margins,
                        padding = block.style?.padding) else ContainerStyle()
                    result += nativeContainerSpec(id(paths[first] + "/logical-item"), own.atViewport(rootViewport), children,
                        density.density, bodyPixels, rtl, dark, true)
                }
            }
        }
        return result
    }
    return visit(blocks, rootPaths ?: blocks.indices.map { "$path/block-$it" },
        blocks.indices.map { "$gridPath/block-$it" }, rootGaps, inherited, inheritedAlign,
        false, false, blocks.indices.map { it })
}
