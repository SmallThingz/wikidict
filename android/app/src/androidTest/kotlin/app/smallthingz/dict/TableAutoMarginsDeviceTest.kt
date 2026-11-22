package app.smallthingz.dict

import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.width
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalLayoutDirection
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.*
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.dp
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

/** Integration obligations, unrun. Current production UI has no auto-margin owner yet. */
class TableAutoMarginsDeviceTest {
    @get:Rule val compose = createPhysicalComposeRule()
    private fun px(value: Float) = StyleLength(StyleLengthUnit.Px, value)
    private fun length(value: Float) = ContainerMargin.Length(px(value))
    private fun table(style: TableStyle, caption: List<Span> = emptyList()) = Table(caption,
        listOf(listOf(Cell(listOf(Span("link", "A", target = "Target")), false, 1, 1,
            background = "#e40000", style = CellStyle(padding = StyleEdges(px(1f), px(1f), px(1f), px(1f)))))),
        geometry = TableGeometry(cellPadding = 1), style = style)

    @Test fun positiveAutoMarginsMovePaintCellSemanticsAndActualLinkTogether() {
        val direction = mutableStateOf(LayoutDirection.Ltr)
        val side = mutableStateOf(0)
        val followed = mutableListOf<String>()
        try {
            compose.activityRule.scenario.onActivity { activity -> activity.setContent {
                val margins = when (side.value) {
                    0 -> ContainerMargins(length(3f), ContainerMargin.Auto, length(5f), ContainerMargin.Auto)
                    1 -> ContainerMargins(length(3f), length(10f), length(5f), ContainerMargin.Auto)
                    else -> ContainerMargins(length(3f), ContainerMargin.Auto, length(5f), length(10f))
                }
                CompositionLocalProvider(LocalDensity provides Density(1f, 1f), LocalLayoutDirection provides direction.value) {
                    DictTheme("light") {
                        Box(Modifier.width(200.dp).testTag("table-containing-block")) {
                            CompiledTableView(table(TableStyle(width = StyleWidth(StyleWidthUnit.Px, 100f),
                                marginValues = margins, containingDirection = TableContainingDirection.Rtl)), null) { followed += it.target }
                        }
                    }
                }
            } }
            for (flowDirection in listOf(LayoutDirection.Ltr, LayoutDirection.Rtl)) for (autoSide in 0..2) {
                compose.runOnIdle { direction.value = flowDirection; side.value = autoSide }
                compose.waitForIdle()
                val parent = compose.onNodeWithTag("table-containing-block", useUnmergedTree = true).fetchSemanticsNode().boundsInRoot
                val grid = compose.onNodeWithTag("compiled-table-grid-root/block-0", useUnmergedTree = true)
                val bounds = grid.fetchSemanticsNode().boundsInRoot
                val cell = compose.onNodeWithTag("compiled-table-cell-root/block-0-0", useUnmergedTree = true).fetchSemanticsNode().boundsInRoot
                assertEquals(100f, bounds.width, .01f)
                assertEquals(when (autoSide) { 0 -> 50f; 1 -> 90f; else -> 10f }, bounds.left - parent.left, .01f)
                assertEquals(3f, bounds.top - parent.top, .01f)
                assertEquals(bounds.left, cell.left, .01f)
                val image = grid.captureToImage().asAndroidBitmap()
                try { assertEquals(0xffe40000.toInt(), image.getPixel(image.width - 2, image.height - 2)) }
                finally { image.recycle() }
                compose.onNodeWithText("A").assertIsDisplayed().performTouchInput { click(center) }
            }
            compose.runOnIdle { assertEquals(List(6) { "Target" }, followed) }
        } finally { compose.activityRule.scenario.onActivity { it.setContent {} } }
    }

    @Test fun captionMinimumEnlargesGridBeforeMarginsResolve() {
        val caption = "CaptionMinimumWidensTable"
        try {
            compose.activityRule.scenario.onActivity { activity -> activity.setContent {
                CompositionLocalProvider(LocalDensity provides Density(1f, 1f), LocalLayoutDirection provides LayoutDirection.Ltr) {
                    DictTheme("light") {
                        Box(Modifier.width(320.dp).testTag("table-containing-block")) {
                            CompiledTableView(table(TableStyle(width = StyleWidth(StyleWidthUnit.Percent, 10f),
                                marginValues = ContainerMargins(length(0f), ContainerMargin.Auto, length(0f), ContainerMargin.Auto),
                                containingDirection = TableContainingDirection.Rtl),
                                listOf(Span("text", caption))), null) { }
                        }
                    }
                }
            } }
            compose.waitForIdle()
            val parent = compose.onNodeWithTag("table-containing-block", useUnmergedTree = true).fetchSemanticsNode().boundsInRoot
            val grid = compose.onNodeWithTag("compiled-table-grid-root/block-0", useUnmergedTree = true).fetchSemanticsNode().boundsInRoot
            val text = compose.onNodeWithText(caption).fetchSemanticsNode().boundsInRoot
            assertTrue(grid.width > 32f)
            assertTrue(grid.width + .5f >= text.width)
            assertEquals((parent.width - grid.width) / 2f, grid.left - parent.left, .5f)
            assertEquals(grid.left, text.left, .5f)
        } finally { compose.activityRule.scenario.onActivity { it.setContent {} } }
    }

    @Test fun actualBorderAndScrollViewportUseIndependentContainingAndGridDirections() {
        val sourceDirection = mutableStateOf(TableContainingDirection.Ltr)
        val gridDirection = mutableStateOf(LayoutDirection.Rtl)
        val nestedOwner = mutableStateOf(false)
        val opened = mutableListOf<String>()
        try {
            compose.activityRule.scenario.onActivity { activity -> activity.setContent {
                val value = Table(emptyList(), listOf(listOf(
                    Cell(listOf(Span("link", "Left", "left-target")), false, 1, 1),
                    Cell(listOf(Span("link", "Right", "right-target")), false, 1, 1))),
                    geometry = TableGeometry(cellPadding = 1), style = TableStyle(
                        width = StyleWidth(StyleWidthUnit.Px, 140f),
                        marginValues = ContainerMargins(length(0f), ContainerMargin.Auto, length(0f), ContainerMargin.Auto),
                        containingDirection = sourceDirection.value))
                CompositionLocalProvider(LocalDensity provides Density(1f, 1f),
                    LocalLayoutDirection provides gridDirection.value) {
                    DictTheme("light") {
                        Box(Modifier.width(100.dp).testTag("table-containing-block")) {
                            NativeFloatBlockContext(listOf(Block("table", 0, emptyList(), table = value)),
                                { opened += it.target }, "auto-overflow", Modifier,
                                inCell = nestedOwner.value, gridPath = "root", gapDp = 0f, trailingGap = false)
                        }
                    }
                }
            } }
            for (nested in listOf(false, true)) for (source in TableContainingDirection.entries) {
                compose.runOnIdle {
                    nestedOwner.value = nested
                    sourceDirection.value = source
                    gridDirection.value = if (source == TableContainingDirection.Ltr) LayoutDirection.Rtl else LayoutDirection.Ltr
                }
                compose.waitForIdle()
                compose.onAllNodesWithText("Table margin layout unavailable", substring = true).assertCountEquals(0)
                val parent = compose.onNodeWithTag("table-containing-block", useUnmergedTree = true).getUnclippedBoundsInRoot()
                val grid = compose.onNodeWithTag("compiled-table-grid-root/block-0", useUnmergedTree = true).getUnclippedBoundsInRoot()
                assertEquals(140f, grid.right.value - grid.left.value, .01f)
                assertEquals(if (source == TableContainingDirection.Rtl) -40f else 0f,
                    grid.left.value - parent.left.value, .01f)
                compose.onNodeWithText("Right").assertIsDisplayed().performTouchInput { click(center) }
            }
            compose.runOnIdle { assertEquals(List(4) { "right-target" }, opened) }
        } finally { compose.activityRule.scenario.onActivity { it.setContent {} } }
    }

    @Test fun halfPixelPlacementMovesRealPaintHitAndCellSemanticsTogether() {
        val opened = mutableListOf<String>()
        try {
            compose.activityRule.scenario.onActivity { activity -> activity.setContent {
                CompositionLocalProvider(LocalDensity provides Density(1f, 1f), LocalLayoutDirection provides LayoutDirection.Rtl) {
                    DictTheme("light") {
                        Box(Modifier.width(101.dp).testTag("table-containing-block")) {
                            CompiledTableView(table(TableStyle(width = StyleWidth(StyleWidthUnit.Px, 70f),
                                marginValues = ContainerMargins(length(0f), ContainerMargin.Auto, length(0f), ContainerMargin.Auto),
                                containingDirection = TableContainingDirection.Ltr)), null) { opened += it.target }
                        }
                    }
                }
            } }
            compose.waitForIdle()
            val parent = compose.onNodeWithTag("table-containing-block", useUnmergedTree = true).getUnclippedBoundsInRoot()
            val grid = compose.onNodeWithTag("compiled-table-grid-root/block-0", useUnmergedTree = true).getUnclippedBoundsInRoot()
            val cell = compose.onNodeWithTag("compiled-table-cell-root/block-0-0", useUnmergedTree = true).getUnclippedBoundsInRoot()
            assertEquals(15.5f, grid.left.value - parent.left.value, .01f)
            assertEquals(grid.left.value, cell.left.value, .01f)
            compose.onNodeWithText("A").assertIsDisplayed().performTouchInput { click(center) }
            compose.runOnIdle { assertEquals(listOf("Target"), opened) }
        } finally { compose.activityRule.scenario.onActivity { it.setContent {} } }
    }
}
