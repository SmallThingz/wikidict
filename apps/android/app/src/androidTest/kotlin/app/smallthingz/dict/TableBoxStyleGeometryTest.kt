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
import androidx.compose.ui.test.*
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.dp
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

class TableBoxStyleGeometryTest {
    @get:Rule val compose = createPhysicalComposeRule()
    private fun px(value: Float) = StyleLength(StyleLengthUnit.Px, value)

    @Test fun separateTablePaddingKeepsActualCellPaintPlacementAndActionsAlignedInRtl() {
        val direction = mutableStateOf(LayoutDirection.Ltr)
        val table = Table(emptyList(), listOf(listOf(
            Cell(listOf(Span("link", "A", target = "Target")), false, 1, 1, background = "#ff0000",
                style = CellStyle(StyleBorder.None, StyleEdges(px(1f), px(1f), px(1f), px(1f)))),
            Cell(listOf(Span("text", "B")), false, 1, 1, background = "#00ff00",
                style = CellStyle(StyleBorder.None, StyleEdges(px(1f), px(1f), px(1f), px(1f)))))),
            geometry = TableGeometry(cellSpacing = 3),
            style = TableStyle(background = "#123456", border = StyleBorder.Solid(px(2f), "#aaaaaa"),
                width = StyleWidth(StyleWidthUnit.Px, 100f), padding = StyleEdges(px(2f), px(4f), px(6f), px(8f))))
        val followed = mutableListOf<String>()
        try {
            compose.activityRule.scenario.onActivity { activity -> activity.setContent {
                CompositionLocalProvider(LocalDensity provides Density(1f, 1f), LocalLayoutDirection provides direction.value) {
                    DictTheme("light") { Box(Modifier.width(200.dp)) { CompiledTableView(table, null) { followed += it.target } } }
                }
            } }
            for (value in listOf(LayoutDirection.Ltr, LayoutDirection.Rtl)) {
                compose.runOnIdle { direction.value = value }
                compose.waitForIdle()
                val grid = compose.onNodeWithTag("compiled-table-grid", useUnmergedTree = true)
                val gridBounds = grid.fetchSemanticsNode().boundsInRoot
                val first = compose.onNodeWithTag("compiled-table-cell-root-0", useUnmergedTree = true).fetchSemanticsNode().boundsInRoot
                val second = compose.onNodeWithTag("compiled-table-cell-root-1", useUnmergedTree = true).fetchSemanticsNode().boundsInRoot
                assertEquals(100f, gridBounds.width, .01f)
                assertEquals(if (value == LayoutDirection.Ltr) 13f else 53f, first.left - gridBounds.left, .01f)
                assertEquals(7f, first.top - gridBounds.top, .01f)
                assertEquals(if (value == LayoutDirection.Ltr) 54f else 13f, second.left - gridBounds.left, .01f)
                val image = grid.captureToImage().asAndroidBitmap()
                try {
                    assertEquals(0xff123456.toInt(), image.getPixel(5, 10))
                    assertEquals(0xffff0000.toInt(), image.getPixel((first.left - gridBounds.left).toInt() + 1, 8))
                    assertEquals(0xff00ff00.toInt(), image.getPixel((second.left - gridBounds.left).toInt() + 1, 8))
                } finally { image.recycle() }
                compose.onNodeWithText("A").assertIsDisplayed().performTouchInput { click(center) }
            }
            compose.runOnIdle { assertEquals(listOf("Target", "Target"), followed) }
        } finally { compose.activityRule.scenario.onActivity { it.setContent {} } }
    }
}
