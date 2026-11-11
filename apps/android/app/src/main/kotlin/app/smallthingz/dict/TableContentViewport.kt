package app.smallthingz.dict

import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.rememberScrollState
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.layout.IntrinsicMeasurable
import androidx.compose.ui.layout.IntrinsicMeasureScope
import androidx.compose.ui.layout.Layout
import androidx.compose.ui.layout.Measurable
import androidx.compose.ui.layout.MeasurePolicy
import androidx.compose.ui.layout.MeasureResult
import androidx.compose.ui.layout.MeasureScope
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.unit.constrainWidth
import androidx.compose.ui.unit.constrainHeight

/** The same grid receives the real viewport and exposes its unconstrained paint width to scrolling. */
@Composable
internal fun TableContentViewport(scrolling: Boolean, content: @Composable () -> Unit) {
    val modifier = if (scrolling) Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()) else Modifier
    Layout(content = content, modifier = modifier, measurePolicy = object : MeasurePolicy {
        override fun MeasureScope.measure(measurables: List<Measurable>, constraints: Constraints): MeasureResult {
            // horizontalScroll preserves the filled viewport minimum while removing its maximum.
            val viewport = if (scrolling) constraints.minWidth else
                constraints.maxWidth.takeIf { constraints.hasBoundedWidth } ?: TablePixelLimit
            val grid = measurables.single().measure(Constraints(maxWidth = viewport,
                maxHeight = constraints.maxHeight))
            val width = constraints.constrainWidth(grid.measuredWidth)
            val height = constraints.constrainHeight(grid.measuredHeight)
            return layout(width, height) {
                // Compose centers an overwide layout in its coerced Placeable. The table's own
                // physical origin stays at the scroll origin; its real width is the scroll extent.
                grid.place(-(grid.width - grid.measuredWidth) / 2, -(grid.height - grid.measuredHeight) / 2)
            }
        }

        override fun IntrinsicMeasureScope.minIntrinsicWidth(measurables: List<IntrinsicMeasurable>, height: Int) =
            measurables.single().minIntrinsicWidth(height)
        override fun IntrinsicMeasureScope.maxIntrinsicWidth(measurables: List<IntrinsicMeasurable>, height: Int) =
            measurables.single().maxIntrinsicWidth(height)
    })
}
