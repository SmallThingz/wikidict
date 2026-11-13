package app.smallthingz.dict

import androidx.compose.ui.unit.Constraints
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class TableBlockViewportLayoutTest {
    private fun px(value: Float) = StyleLength(StyleLengthUnit.Px, value)
    private fun margins(left: ContainerMargin = ContainerMargin.Auto,
        right: ContainerMargin = ContainerMargin.Auto) = ContainerMargins(
        ContainerMargin.Length(px(.2f)), right, ContainerMargin.Length(px(.2f)), left)
    private fun policy(width: StyleWidth = StyleWidth(StyleWidthUnit.Percent, 70f),
        cap: StyleWidth = StyleWidth(StyleWidthUnit.Percent, 100f),
        sizing: ContainerBoxSizing = ContainerBoxSizing.ContentBox,
        containing: TableContainingDirection = TableContainingDirection.Ltr,
        grid: TableContainingDirection = TableContainingDirection.Ltr,
        edges: Boolean = false, values: ContainerMargins = margins()) = TableBlockViewport(639,
        TableStyle(width = width, marginValues = values, containingDirection = containing,
            padding = if (edges) StyleEdges(px(3f), px(3f), px(3f), px(3f)) else null,
            border = if (edges) StyleBorder.Solid(px(2f), "#123456") else null), sizing, cap,
        TableStyle(collapse = TableCollapse.Collapse), grid, language = "ru")

    @Test fun sourceBlockWidthIsIndependentFromGridIntrinsicOverflow() {
        val box = resolveTableBlockBox(policy(), 200f, 1f, 16f)
        assertEquals(140f, box.contentWidth, 0f)
        assertEquals(140f, box.borderWidth, 0f)
        assertEquals(30f, box.usedMargins.left, 0f)
        assertEquals(30f, box.usedMargins.right, 0f)
        val overflow = tableBlockScrollGeometry(box.contentWidth, 300, 0, false)
        assertEquals(160f, overflow.overflow, 0f)
        assertEquals(140, overflow.viewportPixels)
        assertEquals(300, overflow.surfaceWidth)
        assertEquals(0f, overflow.physicalTranslation, 0f)
    }

    @Test fun sourceEdgesAndBoxSizingBelongToViewportOnce() {
        val content = resolveTableBlockBox(policy(edges = true), 200f, 1f, 16f)
        assertEquals(140f, content.contentWidth, 0f)
        assertEquals(150f, content.borderWidth, 0f)
        assertEquals(25f, content.usedMargins.left, 0f)
        assertEquals(5f, content.insets.left, 0f)
        val border = resolveTableBlockBox(policy(edges = true, sizing = ContainerBoxSizing.BorderBox), 200f, 1f, 16f)
        assertEquals(130f, border.contentWidth, 0f)
        assertEquals(140f, border.borderWidth, 0f)
        assertEquals(30f, border.usedMargins.left, 0f)
        assertEquals(listOf(2f, 2f, 2f, 2f), content.decoration.edges!!.map { it.width })
        val capped = resolveTableBlockBox(policy(width = StyleWidth(StyleWidthUnit.Percent, 200f),
            edges = true, sizing = ContainerBoxSizing.BorderBox), 200f, 1f, 16f)
        assertEquals(200f, capped.borderWidth, 0f)
        assertEquals(190f, capped.contentWidth, 0f)
    }

    @Test fun sourceEdgesPreserveUnboundedSentinelAndFiniteHeightConstraints() {
        val source = policy()
        val decorated = source.copy(boxStyle = source.boxStyle.copy(
            border = StyleBorder.Solid(px(2f), "#ff0000"),
            padding = StyleEdges(px(6f), px(6f), px(6f), px(6f))))
        val box = resolveTableBlockBox(decorated, 200f, 1f, 16f)
        assertEquals(156f, box.borderWidth, 0f)
        assertEquals(140f, box.contentWidth, 0f)
        assertEquals(8f, box.insets.top, 0f)
        assertEquals(8f, box.insets.bottom, 0f)
        val available = box.contentMaxHeight(Constraints(minWidth = 156, maxWidth = 156))
        assertEquals(Constraints.Infinity, available)
        val viewport = Constraints(minWidth = 140, maxWidth = 140, maxHeight = available)
        assertEquals(140, viewport.minWidth)
        assertEquals(140, viewport.maxWidth)
        assertEquals(0, viewport.minHeight)
        assertTrue(!viewport.hasBoundedHeight)
        assertEquals(Constraints.Infinity, viewport.maxHeight)
        listOf(8 to 0, 16 to 0, 40 to 24, 200000 to 199984).forEach { (outer, expected) ->
            val available = box.contentMaxHeight(Constraints(minWidth = 156, maxWidth = 156, maxHeight = outer))
            val viewport = Constraints(minWidth = 140, maxWidth = 140, maxHeight = available)
            assertTrue(viewport.hasBoundedHeight)
            assertEquals(expected, viewport.maxHeight)
            assertEquals(0, viewport.minHeight)
        }
        val fractional = resolveTableBlockBox(decorated, 200f, 1.1f, 16f)
        assertEquals(1, fractional.contentMaxHeight(Constraints(maxWidth = 158, maxHeight = 19)))
    }

    @Test fun containingDirectionSolvesSignedMarginsIndependentlyFromGridDirection() {
        val ltr = resolveTableBlockBox(policy(width = StyleWidth(StyleWidthUnit.Px, 140f),
            cap = StyleWidth(StyleWidthUnit.Px, 200f), grid = TableContainingDirection.Rtl), 100f, 1f, 16f)
        val rtl = resolveTableBlockBox(policy(width = StyleWidth(StyleWidthUnit.Px, 140f),
            cap = StyleWidth(StyleWidthUnit.Px, 200f), containing = TableContainingDirection.Rtl), 100f, 1f, 16f)
        assertEquals(0f, ltr.usedMargins.left, 0f)
        assertEquals(-40f, ltr.usedMargins.right, 0f)
        assertEquals(-40f, rtl.usedMargins.left, 0f)
        assertEquals(0f, rtl.usedMargins.right, 0f)
        assertEquals(-40f, tableBlockScrollGeometry(100f, 140, 0, true).physicalTranslation, 0f)
        assertEquals(0f, tableBlockScrollGeometry(100f, 140, 0, false).physicalTranslation, 0f)
    }

    @Test fun oneAutoMarginRetainsOtherFixedEdgeAndEmUsesIndependentBodyScale() {
        val values = margins(left = ContainerMargin.Length(StyleLength(StyleLengthUnit.Em, .25f)))
        val box = resolveTableBlockBox(policy(values = values), 200f, 1.5f, 20f)
        assertEquals(5f, box.usedMargins.left, 0f)
        assertEquals(55f, box.usedMargins.right, 0f)
        assertEquals(.3f, box.usedMargins.top, .0001f)
    }

    @Test fun cyclicPercentagesUseInitialValuesOnlyForIntrinsicContribution() {
        val source = policy(cap = StyleWidth(StyleWidthUnit.Percent, 10f), edges = true)
        assertEquals(310, tableBlockIntrinsicWidth(source, 300, 1f, 16f))
        assertEquals(90, tableBlockIntrinsicWidth(source, 80, 1f, 16f))
        val definite = resolveTableBlockBox(source, 200f, 1f, 16f)
        assertEquals(20f, definite.contentWidth, 0f)
        assertEquals(30f, definite.borderWidth, 0f)
        assertEquals(310, tableBlockIntrinsicWidth(source, 300, 1f, 16f))
        val absolute = policy(width = StyleWidth(StyleWidthUnit.Px, 120f), cap = StyleWidth(StyleWidthUnit.Px, 100f), edges = true)
        assertEquals(110, tableBlockIntrinsicWidth(absolute, 300, 1f, 16f))
        assertEquals(110, tableBlockIntrinsicWidth(absolute, 0, 1f, 16f))
        assertEquals(Constraints.Infinity, tableBlockIntrinsicWidth(source, Constraints.Infinity, 1f, 16f))
    }

    @Test fun fractionalScrollEndpointsMatchBothPaintAndExportedGeometry() {
        val width = resolveTableBlockBox(policy(), 201f, 1f, 16f).contentWidth
        assertEquals(140.7f, width, .0001f)
        val leftStart = tableBlockScrollGeometry(width, 300, 0, false)
        val leftEnd = tableBlockScrollGeometry(width, 300, 160, false)
        val rightStart = tableBlockScrollGeometry(width, 300, 0, true)
        val rightEnd = tableBlockScrollGeometry(width, 300, 160, true)
        assertEquals(141, leftStart.viewportPixels)
        assertEquals(301, leftStart.surfaceWidth)
        assertEquals(-159.3f, leftEnd.physicalTranslation, .0001f)
        assertEquals(.7f, leftEnd.childTranslation, .0001f)
        assertEquals(-159.3f, rightStart.physicalTranslation, .0001f)
        assertEquals(.7f, rightStart.childTranslation, .0001f)
        assertEquals(0f, rightEnd.physicalTranslation, 0f)
        assertEquals(0f, rightEnd.childTranslation, .0001f)
        // Compose contributes its integral offset; the child correction makes the same physical origin.
        assertEquals(leftEnd.physicalTranslation, -160f + leftEnd.childTranslation, .0001f)
        assertEquals(rightStart.physicalTranslation, -160f + rightStart.childTranslation, .0001f)
    }

    @Test fun smallerGridAndZeroWidthViewportKeepDistinctExtents() {
        val right = tableBlockScrollGeometry(140.7f, 60, 0, true)
        assertEquals(0f, right.overflow, 0f)
        assertEquals(80.7f, right.alignment, .0001f)
        assertEquals(80.7f, right.childTranslation, .0001f)
        assertEquals(0f, tableBlockScrollGeometry(140.7f, 60, 0, false).alignment, 0f)
        val zero = tableBlockScrollGeometry(0f, 60, 60, false)
        assertEquals(0, zero.viewportPixels)
        assertEquals(60, zero.surfaceWidth)
        assertEquals(-60f, zero.physicalTranslation, 0f)
        assertEquals(0, tableBlockScrollGeometry(0f, 0, 0, true).surfaceWidth)
    }

    @Test fun revealUsesExactVisibleRangeAndIndependentScrollDirection() {
        assertEquals(160, tableBlockRevealValue(140.7f, 300, 0, false, 290f, 300f))
        assertEquals(0, tableBlockRevealValue(140.7f, 300, 160, false, 0f, 10f))
        assertEquals(160, tableBlockRevealValue(140.7f, 300, 0, true, 0f, 10f))
        assertEquals(0, tableBlockRevealValue(140.7f, 300, 160, true, 290f, 300f))
        assertEquals(0, tableBlockRevealValue(140.7f, 60, 0, true, 0f, 60f))
        assertTrue(runCatching { tableBlockScrollGeometry(Float.NaN, 10, 0, false) }.isFailure)
        assertTrue(runCatching { tableBlockRevealValue(100f, 300, 0, false, 10f, 0f) }.isFailure)
    }

    @Test fun standaloneBlockReusesActualParentExclusionsAndClear() {
        val exclusion = NativeFloatExclusion(TableFloatSide.Left, NativeFloatBounds(0f, 0f, 80f, 50f))
        val narrow = resolveTableBlockBox(policy(width = StyleWidth(StyleWidthUnit.Px, 100f)), 200f, 1f, 16f)
        val alongside = placeStandaloneTableBlock(narrow, 200f, 20.25f, listOf(exclusion))
        assertEquals(90f, alongside.content.left, 0f)
        assertEquals(.2f, alongside.content.top, .0001f)
        assertEquals(20.45f, alongside.content.bottom, .0001f)
        assertEquals(1, alongside.measurementCount)
        val wide = resolveTableBlockBox(policy(), 200f, 1f, 16f)
        val below = placeStandaloneTableBlock(wide, 200f, 20.25f, listOf(exclusion))
        assertEquals(50f, below.content.top, 0f)
        assertEquals(30f, below.content.left, 0f)
        val clearedPolicy = narrow.policy.copy(boxStyle = narrow.policy.boxStyle.copy(clear = FigureClear.Left))
        val cleared = placeStandaloneTableBlock(resolveTableBlockBox(clearedPolicy, 200f, 1f, 16f),
            200f, 20.25f, listOf(exclusion))
        assertEquals(50f, cleared.content.top, 0f)
        assertEquals(50f, cleared.content.left, 0f)
    }
}
