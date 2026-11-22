package app.smallthingz.dict

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
import androidx.compose.ui.unit.constrainWidth

/** A row-visibility table keeps its real caption and grid. The caption's minimum,
 * not its preferred width, constrains the same grid that owns border/background. */
@Composable
internal fun NativeTableVisibilityColumn(table: Table, rowsHidden: Boolean,
    captionMinimum: NativeLayoutInput<Int>, spacing: Int, direction: BidiResolvedDirection,
    modifier: Modifier = Modifier, sink: SelectionGeometrySink? = null,
    caption: (@Composable (SelectionGeometrySink) -> Unit)?,
    grid: @Composable (SelectionGeometrySink) -> Unit) {
    val semantic = rememberNativeSemanticMeasurement()
    // An unchanged caption may reuse its measurement when CAPMIN dominates in both
    // bands. Keep that same source owner's geometry, but never carry an old row grid.
    val captionGeometry = remember(NativeDelegatedTableIdentity(table)) { arrayOfNulls<FloatTextGeometry>(1) }
    val published = remember(NativeDelegatedTableIdentity(table), rowsHidden) {
        arrayOf<FloatTextGeometry?>(captionGeometry[0], null)
    }
    val message = remember { NativeLayoutInput<String?>(null) }
    val captionInput = LocalStaticCaptionInput.current
    val captionChildInput = remember { StaticCaptionInput() }
    fun publish(index: Int, geometry: FloatTextGeometry?) {
        if (index == 0) captionGeometry[0] = geometry
        if (published[index] !== geometry) { published[index] = geometry; semantic.changed() }
    }
    CompositionLocalProvider(LocalNativeSemanticMeasurement provides semantic) {
        Layout(modifier = modifier.then(semantic.modifier).then(captionInput?.modifier ?: Modifier), content = {
            if (caption != null) CompositionLocalProvider(LocalStaticCaptionInput provides captionChildInput) {
                caption { publish(0, it) }
            }
            CompositionLocalProvider(LocalStaticCaptionInput provides null) { grid { publish(1, it) } }
            NativeLayoutMessage(message)
        }, measurePolicy = object : MeasurePolicy {
            private fun intrinsic(measurables: List<IntrinsicMeasurable>, maximum: Boolean): Int {
                val captionWidth = if (caption == null) 0 else measurables.first().minIntrinsicWidth(Constraints.Infinity)
                val body = measurables[if (caption == null) 0 else 1]
                val gridWidth = if (maximum) body.maxIntrinsicWidth(Constraints.Infinity) else body.minIntrinsicWidth(Constraints.Infinity)
                return maxOf(captionWidth, gridWidth)
            }
            override fun IntrinsicMeasureScope.minIntrinsicWidth(measurables: List<IntrinsicMeasurable>, height: Int) = intrinsic(measurables, false)
            override fun IntrinsicMeasureScope.maxIntrinsicWidth(measurables: List<IntrinsicMeasurable>, height: Int) = intrinsic(measurables, true)
            override fun MeasureScope.measure(measurables: List<Measurable>, constraints: Constraints): MeasureResult = semantic.measure {
                val captionSource = measurables.firstOrNull().takeIf { caption != null }
                val gridSource = measurables[if (caption == null) 0 else 1]
                var gridChild: Placeable? = null
                var captionChild: Placeable? = null
                var gridAttempted = false
                var captionAttempted = false
                var failure: String? = null
                try {
                    if (!constraints.hasBoundedWidth || constraints.maxWidth > TablePixelLimit || spacing < 0)
                        throw UnsupportedFloatLayout("Table row visibility needs a finite containing width")
                    if (captionInput?.exclusions?.isNotEmpty() == true)
                        throw UnsupportedFloatLayout("Row-visibility table caption with carried floats is unavailable")
                    val minimum = captionSource?.minIntrinsicWidth(Constraints.Infinity) ?: 0
                    if (minimum !in 0..TablePixelLimit)
                        throw UnsupportedFloatLayout("Table caption minimum exceeds native geometry")
                    captionMinimum.update(minimum)
                    gridAttempted = true
                    gridChild = gridSource.measure(constraints.copy(minWidth = 0, minHeight = 0))
                    val width = gridChild.measuredWidth
                    if (width !in minimum..TablePixelLimit)
                        throw UnsupportedFloatLayout("Table grid did not retain its caption minimum")
                    if (captionSource != null) {
                        captionChildInput.update(emptyList(), 0f, 0f)
                        captionAttempted = true
                        captionChild = captionSource.measure(Constraints(minWidth = width, maxWidth = width, maxHeight = constraints.maxHeight))
                    }
                } catch (error: UnsupportedFloatLayout) {
                    failure = error.message ?: "Table row visibility layout is unavailable"
                }
                // The existing grid fallback already contains only projected cells. Keep
                // those real owners visible on failure; never reconstruct hidden rows here.
                if (!gridAttempted) gridChild = gridSource.measure(constraints.copy(minWidth = 0, minHeight = 0))
                if (captionSource != null && !captionAttempted)
                    captionChild = captionSource.measure(constraints.copy(minWidth = 0, minHeight = 0))
                val body = gridChild
                val heading = captionChild
                val gap = if (heading == null) 0 else spacing
                val gridTop = (heading?.measuredHeight ?: 0).toLong() + gap
                val bodyHeight = gridTop + (body?.measuredHeight ?: 0)
                if (bodyHeight > TablePixelLimit || bodyHeight > constraints.maxHeight)
                    failure = failure ?: "Table caption and grid exceed native geometry"
                message.update(failure)
                val warning = measurables.last().measure(if (failure == null) Constraints.fixed(0, 0)
                    else constraints.copy(minWidth = 0, minHeight = 0))
                val height = nativeFallbackHeight(constraints, warning.measuredHeight.toLong() + bodyHeight)
                val borderWidth = maxOf(body?.measuredWidth ?: 0, heading?.measuredWidth ?: 0)
                val measuredWidth = maxOf(borderWidth, warning.measuredWidth)
                val width = if (sink == null) measuredWidth else constraints.constrainWidth(measuredWidth)
                val contentLeft = if (sink != null && direction == BidiResolvedDirection.Rtl) width - borderWidth else 0
                if (sink != null) {
                    val tableGeometry = published[1]?.takeIf { body != null && it.width == body.measuredWidth && it.height == body.measuredHeight }
                    val captionGeometry = published[0]?.takeIf { heading != null && it.width == heading.measuredWidth && it.height == heading.measuredHeight }
                    if (failure != null || tableGeometry == null || caption != null && captionGeometry == null) sink(null)
                    else {
                        val children = mutableListOf<PositionedSemanticChild>()
                        if (captionGeometry != null) children += PositionedSemanticChild(NoPaintGeometry(captionGeometry), contentLeft.toFloat(), 0f, direction)
                        children += PositionedSemanticChild(NoPaintGeometry(tableGeometry), contentLeft.toFloat(), gridTop.toFloat(), direction,
                            if (tableGeometry.text.isNotEmpty() && captionGeometry?.text?.isNotEmpty() == true) "\n" else "")
                        sink(NativeSemanticGroup(width, height, children))
                    }
                }
                layout(width, height) {
                    fun Placeable.at(left: Int, top: Int) = place(left - (this.width - this.measuredWidth) / 2, top - (this.height - measuredHeight) / 2)
                    warning.at(0, 0)
                    heading?.at(contentLeft, warning.measuredHeight)
                    body?.at(contentLeft, (warning.measuredHeight.toLong() + gridTop).coerceAtMost(Int.MAX_VALUE.toLong()).toInt())
                }
            }
        })
    }
}
