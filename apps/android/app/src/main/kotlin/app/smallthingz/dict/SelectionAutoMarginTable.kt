package app.smallthingz.dict

import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.layout.IntrinsicMeasurable
import androidx.compose.ui.layout.IntrinsicMeasureScope
import androidx.compose.ui.layout.Layout
import androidx.compose.ui.layout.Measurable
import androidx.compose.ui.layout.MeasurePolicy
import androidx.compose.ui.layout.MeasureResult
import androidx.compose.ui.layout.MeasureScope
import androidx.compose.ui.layout.Placeable
import androidx.compose.ui.unit.Constraints
import kotlin.math.ceil

/** The actual grid owns its border width; this owner keeps the containing viewport separate.
 * Signed overflow is published through NativeSemanticGroup.extents, not added as padding. */
@Composable
internal fun SelectionAutoMarginTable(margins: NativeTableAutoMargins?,
    containingDirection: TableContainingDirection?, gridDirection: BidiResolvedDirection,
    inline: Boolean, captionGap: Int, sink: SelectionGeometrySink, preparationFailure: String? = null,
    caption: (@Composable (SelectionGeometrySink) -> Unit)?,
    grid: @Composable (NativeLayoutInput<Int>, NativeLayoutInput<Int>, SelectionGeometrySink) -> Unit) {
    val semantic = rememberNativeSemanticMeasurement()
    val containingWidth = remember { NativeLayoutInput(0) }
    val captionMinimum = remember { NativeLayoutInput(0) }
    val captionInput = LocalStaticCaptionInput.current
    val captionChildInput = remember { StaticCaptionInput() }
    val published = remember { arrayOfNulls<FloatTextGeometry>(2) }
    val message = remember { NativeLayoutInput<String?>(null) }
    val hasCaption = caption != null
    fun publish(index: Int, value: FloatTextGeometry?) {
        if (published[index] !== value) { published[index] = value; semantic.changed() }
    }
    CompositionLocalProvider(LocalNativeSemanticMeasurement provides semantic) {
        Layout(modifier = semantic.modifier.then(captionInput?.modifier ?: Modifier).fillMaxWidth(), content = {
            if (caption != null) CompositionLocalProvider(LocalStaticCaptionInput provides captionChildInput) {
                caption { publish(0, it) }
            }
            // Table cells form their own content owners. Outer caption floats are handled here.
            CompositionLocalProvider(LocalStaticCaptionInput provides null) {
                grid(containingWidth, captionMinimum) { publish(1, it) }
            }
            NativeLayoutMessage(message)
        }, measurePolicy = object : MeasurePolicy {
            private fun intrinsic(measurables: List<IntrinsicMeasurable>, maximum: Boolean): Int {
                val fixed = margins?.fixed ?: return Constraints.Infinity
                val minimumCaption = if (hasCaption) measurables.first().minIntrinsicWidth(Constraints.Infinity) else 0
                val child = measurables[if (hasCaption) 1 else 0]
                val table = if (maximum) child.maxIntrinsicWidth(Constraints.Infinity) else child.minIntrinsicWidth(Constraints.Infinity)
                val width = maxOf(minimumCaption, table).toDouble() + fixed.left + fixed.right
                return if (!width.isFinite() || width > TablePixelLimit) Constraints.Infinity else ceil(width).toInt()
            }
            override fun IntrinsicMeasureScope.minIntrinsicWidth(measurables: List<IntrinsicMeasurable>, height: Int) = intrinsic(measurables, false)
            override fun IntrinsicMeasureScope.maxIntrinsicWidth(measurables: List<IntrinsicMeasurable>, height: Int) = intrinsic(measurables, true)

            override fun MeasureScope.measure(measurables: List<Measurable>, constraints: Constraints): MeasureResult = semantic.measure {
                val width = constraints.maxWidth.takeIf { constraints.hasBoundedWidth }?.coerceAtMost(TablePixelLimit) ?: 0
                val gridIndex = if (hasCaption) 1 else 0
                var gridChild: Placeable? = null
                var captionChild: Placeable? = null
                var attemptedGrid = false
                var attemptedCaption = false
                var solved: NativeTableUsedMargins? = null
                var failure: String? = null
                var height = 0
                var gridTop = 0f
                var contentLeft = 0f
                try {
                    val resolved = margins ?: throw UnsupportedFloatLayout(preparationFailure
                        ?: "Table margins exceed native geometry")
                    if (!constraints.hasBoundedWidth || constraints.maxWidth > TablePixelLimit)
                        throw UnsupportedFloatLayout("Caption table needs a bounded native containing width")
                    if (captionGap < 0) throw UnsupportedFloatLayout("Caption table gap is invalid")
                    if (captionInput?.exclusions?.isNotEmpty() == true)
                        throw UnsupportedFloatLayout("Caption table needs a shared exclusion owner")
                    val minimumCaption = if (hasCaption) measurables.first().minIntrinsicWidth(Constraints.Infinity) else 0
                    if (minimumCaption !in 0..TablePixelLimit)
                        throw UnsupportedFloatLayout("Caption table minimum exceeds native geometry")
                    containingWidth.update(width)
                    captionMinimum.update(minimumCaption)
                    val available = (width.toDouble() - resolved.fixed.left - resolved.fixed.right).coerceAtLeast(0.0).toInt()
                    attemptedGrid = true
                    gridChild = measurables[gridIndex].measure(Constraints(maxWidth = available, maxHeight = constraints.maxHeight))
                    val table = published[1] ?: throw UnsupportedFloatLayout("Caption table selection geometry is unavailable")
                    if (table.width != gridChild.measuredWidth || table.height != gridChild.measuredHeight || table.width < minimumCaption)
                        throw UnsupportedFloatLayout("Caption table border geometry differs from its measured grid")
                    val direction = containingDirection
                        ?: throw UnsupportedFloatLayout("Table containing direction is not supplied by the compiled presentation")
                    solved = if (inline) NativeTableUsedMargins(resolved.fixed.top, resolved.fixed.right,
                        resolved.fixed.bottom, resolved.fixed.left) else solveTableAutoMargins(width.toFloat(), table.width.toFloat(),
                        resolved, NativeTableMarginFlow.Block, direction)
                    // Inline auto margins are zero; keep the existing caption grid's logical placement.
                    contentLeft = solved.left + if (inline && gridDirection == BidiResolvedDirection.Rtl)
                        width - resolved.fixed.left - resolved.fixed.right - table.width else 0f
                    if (hasCaption) {
                        captionChildInput.update(emptyList(), contentLeft, solved.top)
                        attemptedCaption = true
                        captionChild = measurables.first().measure(Constraints.fixedWidth(table.width))
                        val text = published[0] ?: throw UnsupportedFloatLayout("Table caption selection geometry is unavailable")
                        if (text.width != captionChild.measuredWidth || text.height != captionChild.measuredHeight || text.width != table.width)
                            throw UnsupportedFloatLayout("Table caption and grid border widths differ")
                    }
                    gridTop = solved.top + (captionChild?.measuredHeight ?: 0) + if (hasCaption) captionGap else 0
                    height = figureCoordinate(gridTop.toDouble() + table.height + solved.bottom)
                    if (height > constraints.maxHeight) throw UnsupportedFloatLayout("Caption table exceeds its available height")
                } catch (error: UnsupportedFloatLayout) {
                    failure = error.message ?: "Caption table layout is unavailable"
                }
                if (failure == null) {
                    val used = checkNotNull(solved)
                    val children = mutableListOf<PositionedSemanticChild>()
                    if (hasCaption) children += PositionedSemanticChild(NoPaintGeometry(checkNotNull(published[0])),
                        contentLeft, used.top, gridDirection)
                    children += PositionedSemanticChild(NoPaintGeometry(checkNotNull(published[1])),
                        contentLeft, gridTop, gridDirection, if (hasCaption && published[0]?.text?.isNotEmpty() == true) "\n" else "")
                    message.update(null)
                    measurables.last().measure(Constraints.fixed(0, 0))
                    sink(NativeSemanticGroup(width, height, children))
                    layout(width, height) {
                        captionChild?.let { child -> child.placeWithLayer(
                            -(child.width - child.measuredWidth) / 2, -(child.height - child.measuredHeight) / 2) {
                            translationX = contentLeft; translationY = used.top
                        } }
                        checkNotNull(gridChild).let { child -> child.placeWithLayer(
                            -(child.width - child.measuredWidth) / 2, -(child.height - child.measuredHeight) / 2) {
                            translationX = contentLeft; translationY = gridTop
                        } }
                    }
                } else {
                    // A visible warning distinguishes actual retained fallback geometry from authored layout.
                    if (gridChild == null && !attemptedGrid) {
                        containingWidth.update(width)
                        captionMinimum.update(0)
                        attemptedGrid = true
                        gridChild = try { measurables[gridIndex].measure(Constraints(maxWidth = width,
                            maxHeight = constraints.maxHeight)) }
                        catch (error: UnsupportedFloatLayout) { failure += "; " + error.message; null }
                    }
                    if (hasCaption && captionChild == null && !attemptedCaption) {
                        attemptedCaption = true
                        captionChild = try { measurables.first().measure(Constraints(maxWidth = width,
                            maxHeight = constraints.maxHeight)) }
                        catch (error: UnsupportedFloatLayout) { failure += "; " + error.message; null }
                    }
                    message.update("Table margin layout unavailable. " + failure)
                    val warning = measurables.last().measure(Constraints(maxWidth = width, maxHeight = constraints.maxHeight))
                    val captionTop = warning.measuredHeight
                    val fallbackGridTop = captionTop + (captionChild?.measuredHeight ?: 0) + if (hasCaption) captionGap.coerceAtLeast(0) else 0
                    val fallbackHeight = nativeFallbackHeight(Constraints(maxWidth = width, minHeight = constraints.minHeight,
                        maxHeight = constraints.maxHeight), fallbackGridTop.toLong() + (gridChild?.measuredHeight ?: 0))
                    val fallbackGeometry = mutableListOf<PositionedSemanticChild>()
                    val table = published[1]
                    val text = published[0]
                    val complete = gridChild != null && table != null && table.width == gridChild.measuredWidth &&
                        table.height == gridChild.measuredHeight && (!hasCaption || captionChild != null && text != null &&
                        text.width == captionChild.measuredWidth && text.height == captionChild.measuredHeight)
                    if (complete) {
                        if (hasCaption) fallbackGeometry += PositionedSemanticChild(NoPaintGeometry(checkNotNull(text)),
                            0f, captionTop.toFloat(), gridDirection)
                        fallbackGeometry += PositionedSemanticChild(NoPaintGeometry(checkNotNull(table)),
                            0f, fallbackGridTop.toFloat(), gridDirection, if (hasCaption && text?.text?.isNotEmpty() == true) "\n" else "")
                    }
                    // An unavailable child cannot acquire fabricated copy/action geometry.
                    sink(if (complete) NativeSemanticGroup(width, fallbackHeight, fallbackGeometry) else null)
                    layout(width, fallbackHeight) {
                        warning.place(0, 0)
                        captionChild?.let { child -> child.place(-(child.width - child.measuredWidth) / 2,
                            captionTop - (child.height - child.measuredHeight) / 2) }
                        gridChild?.let { child -> child.place(-(child.width - child.measuredWidth) / 2,
                            fallbackGridTop - (child.height - child.measuredHeight) / 2) }
                    }
                }
            }
        })
    }
}
