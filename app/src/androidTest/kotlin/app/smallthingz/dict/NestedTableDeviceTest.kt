package app.smallthingz.dict

import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.platform.LocalLayoutDirection
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.test.*
import androidx.compose.ui.unit.LayoutDirection
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

/** Compiled semantic objects only. No source parsing, network, persistent fixture or clipboard. */
class NestedTableDeviceTest {
    @get:Rule val compose = createPhysicalComposeRule()

    private fun fixture(): Table = Table(emptyList(), listOf(List(4) { index ->
        val title = Cell(listOf(Span("text", "Grid $index")), true, 5, 1)
        val empty = Cell(emptyList(), true, 1, 1, "#800080")
        val link = Cell(listOf(Span("link", "Follow $index", target = "target-$index", explanation = "Compiled explanation $index")), false, 1, 1)
        val egyptian = Cell(listOf(Span("text", "\uD80C\uDC00", classes = "Egyp", direction = "ltr")), false, 1, 1)
        val value = Cell(listOf(Span("text", "value $index", background = if (index == 0) "#ffff00" else null)),
            false, 1, 1, background = if (index == 0) "#ffffff" else null)
        val child = Table(listOf(Span("text", "Caption $index")), listOf(listOf(title), listOf(empty, link, egyptian, value)) +
            List(5) { row -> List(4) { column -> Cell(listOf(Span("text", "$index:$row:$column")), false, 1, 1) } },
            TableGeometry(border = 1, cellPadding = 2, width = TableWidth(TableWidthUnit.Percent, 100)))
        Cell(emptyList(), false, 1, 1, background = if (index == 0) "#000000" else null, nestedTable = child)
    }), TableGeometry(border = 0, cellSpacing = 15))

    @Test fun nestedGridsKeepOneScrollRealEmptyPaintAndAccessibleLinksInBothDirections() {
        val table = fixture()
        val direction = mutableStateOf(LayoutDirection.Ltr)
        val mode = mutableStateOf("light")
        var followed: String? = null
        try {
            compose.activityRule.scenario.onActivity { activity -> activity.setContent {
                CompositionLocalProvider(LocalLayoutDirection provides direction.value) {
                    DictTheme(mode.value) { androidx.compose.material3.Surface(Modifier.fillMaxSize()) {
                        CompiledTableView(table, null) { followed = it }
                    } }
                }
            } }
            for (theme in listOf("light", "dark")) for (layoutDirection in listOf(LayoutDirection.Ltr, LayoutDirection.Rtl)) {
                compose.runOnIdle { mode.value = theme; direction.value = layoutDirection; followed = null }
                compose.waitForIdle()
                compose.onNodeWithText("Table is too large to display.").assertDoesNotExist()
                val horizontalScroll = SemanticsMatcher("horizontal scroll surface") {
                    it.config.getOrNull(SemanticsProperties.HorizontalScrollAxisRange) != null
                }
                compose.onAllNodes(horizontalScroll, useUnmergedTree = true).assertCountEquals(1)
                val root = compose.onNodeWithTag("compiled-table-grid", useUnmergedTree = true).fetchSemanticsNode()
                val rootCollection = root.config[SemanticsProperties.CollectionInfo]
                assertEquals(1, rootCollection.rowCount); assertEquals(4, rootCollection.columnCount)
                for (index in 0..3) {
                    val gridTag = "compiled-table-grid-root/$index"
                    val emptyTag = "compiled-table-cell-root/$index-1"
                    val empty = compose.onNodeWithTag(emptyTag, useUnmergedTree = true)
                    empty.performScrollTo().assertIsDisplayed().assertHasNoClickAction()
                    val node = empty.fetchSemanticsNode()
                    assertTrue(node.boundsInRoot.width > 0f && node.boundsInRoot.height > 0f)
                    assertTrue(node.config.contains(SemanticsProperties.Heading))
                    val item = node.config[SemanticsProperties.CollectionItemInfo]
                    assertEquals(1, item.rowIndex); assertEquals(0, item.columnIndex)
                    assertEquals(1, item.rowSpan); assertEquals(1, item.columnSpan)
                    assertNull(node.config.getOrNull(SemanticsProperties.Text))
                    val child = compose.onNodeWithTag(gridTag, useUnmergedTree = true).fetchSemanticsNode()
                    val childCollection = child.config[SemanticsProperties.CollectionInfo]
                    assertEquals(7, childCollection.rowCount); assertEquals(5, childCollection.columnCount)
                    val bitmap = empty.captureToImage().asAndroidBitmap()
                    try { assertEquals(0xff800080.toInt(), bitmap.getPixel(bitmap.width / 2, bitmap.height / 2)) }
                    finally { bitmap.recycle() }
                    val outerCell = compose.onNodeWithTag("compiled-table-cell-root-$index", useUnmergedTree = true).fetchSemanticsNode()
                    assertTrue(child.boundsInRoot.left >= outerCell.boundsInRoot.left - 1f)
                    assertTrue(child.boundsInRoot.right <= outerCell.boundsInRoot.right + 1f)
                    val link = compose.onNodeWithText("Follow $index", useUnmergedTree = true)
                    link.performScrollTo().assertIsDisplayed()
                    val layouts = mutableListOf<androidx.compose.ui.text.TextLayoutResult>()
                    link.performSemanticsAction(SemanticsActions.GetTextLayoutResult) { it(layouts) }
                    val layout = layouts.single()
                    if (index == 0) {
                        assertTrue(layout.layoutInput.text.spanStyles.any { it.item.color == androidx.compose.ui.graphics.Color.White })
                        val inheritedPaint = link.captureToImage().asAndroidBitmap()
                        try {
                            var black = false
                            var white = false
                            for (y in 0 until inheritedPaint.height) for (x in 0 until inheritedPaint.width) {
                                val pixel = inheritedPaint.getPixel(x, y)
                                if (pixel == android.graphics.Color.BLACK) black = true
                                if (pixel == android.graphics.Color.WHITE) white = true
                            }
                            assertTrue("Transparent child must retain parent paint and readable text", black && white)
                        } finally { inheritedPaint.recycle() }
                        val caption = compose.onNodeWithText("Caption 0", useUnmergedTree = true).fetchSemanticsNode()
                            .config[SemanticsProperties.Text].single()
                        assertTrue(caption.spanStyles.any { it.item.color == androidx.compose.ui.graphics.Color.White })
                        val valueText = compose.onNodeWithText("value 0", useUnmergedTree = true).fetchSemanticsNode()
                            .config[SemanticsProperties.Text].single()
                        assertTrue(valueText.spanStyles.any { it.item.background == androidx.compose.ui.graphics.Color.Yellow })
                        assertTrue(valueText.spanStyles.any { it.item.color == androidx.compose.ui.graphics.Color.Black })
                    }
                    val annotation = layout.layoutInput.text.getLinkAnnotations(0, layout.layoutInput.text.length).single()
                    assertEquals("target-$index", (annotation.item as androidx.compose.ui.text.LinkAnnotation.Clickable).tag)
                    link.performTouchInput { click(layout.getBoundingBox(annotation.start).center) }
                    compose.runOnIdle { assertEquals("target-$index", followed) }
                    // A native shaping descendant is actually measured by the same custom Layout.
                    val signs = if (android.os.Build.VERSION.SDK_INT >= 31)
                        SemanticsMatcher.expectValue(EgyptianShapedRunCount, 1) and hasAnyAncestor(hasTestTag(gridTag))
                    else hasText("\u2066\uD80C\uDC00\u2069") and hasAnyAncestor(hasTestTag(gridTag))
                    if (android.os.Build.VERSION.SDK_INT >= 31) compose.waitUntil(10000) {
                        compose.onAllNodes(signs, useUnmergedTree = true).fetchSemanticsNodes().size == 1
                    }
                    compose.onNode(signs, useUnmergedTree = true).performScrollTo().assertIsDisplayed()
                }
            }
        } finally { compose.activityRule.scenario.onActivity { it.setContent {} } }
    }
}
