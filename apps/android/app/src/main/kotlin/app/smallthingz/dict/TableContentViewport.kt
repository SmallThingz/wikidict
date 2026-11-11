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
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.constrainWidth
import androidx.compose.ui.unit.constrainHeight

/** This unweighted stack's width depends only on its real caption/grid widths.
 * Column's generic width query first probes child heights, which would run the
 * grid's default intrinsic measure against its layout-only warning surface. */
@Composable
internal fun TableContentColumn(modifier: Modifier, spacing: Dp, content: @Composable () -> Unit) {
    Layout(content = content, modifier = modifier, measurePolicy = object : MeasurePolicy {
        override fun IntrinsicMeasureScope.minIntrinsicWidth(measurables: List<IntrinsicMeasurable>, height: Int) =
            measurables.maxOfOrNull { it.minIntrinsicWidth(height) } ?: 0
        override fun IntrinsicMeasureScope.maxIntrinsicWidth(measurables: List<IntrinsicMeasurable>, height: Int) =
            measurables.maxOfOrNull { it.maxIntrinsicWidth(height) } ?: 0

        override fun MeasureScope.measure(measurables: List<Measurable>, constraints: Constraints): MeasureResult {
            val gap = spacing.roundToPx().coerceAtLeast(0)
            var top = 0L
            val positions = ArrayList<Int>(measurables.size)
            val children = measurables.mapIndexed { index, measurable ->
                positions += top.toInt()
                val remaining = (constraints.maxHeight.toLong() - top).coerceAtLeast(0L).toInt()
                val child = measurable.measure(Constraints(maxWidth = constraints.maxWidth, maxHeight = remaining))
                top += child.height
                if (index != measurables.lastIndex) top += minOf(gap.toLong(), (constraints.maxHeight.toLong() - top).coerceAtLeast(0L))
                child
            }
            val width = constraints.constrainWidth(children.maxOfOrNull { it.width } ?: 0)
            val height = constraints.constrainHeight(top.toInt())
            return layout(width, height) {
                children.forEachIndexed { index, child -> child.placeRelative(0, positions[index]) }
            }
        }
    })
}

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
