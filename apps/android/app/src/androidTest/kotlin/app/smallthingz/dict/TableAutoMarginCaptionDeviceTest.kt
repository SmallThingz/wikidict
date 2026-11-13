package app.smallthingz.dict

import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.width
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.*
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

/** Source-only integration controls through actual caption block/column/table owners. */
class TableAutoMarginCaptionDeviceTest {
    @get:Rule val compose = createPhysicalComposeRule()
    private fun px(value: Float) = StyleLength(StyleLengthUnit.Px, value)
    private val zero = StyleEdges(px(0f), px(0f), px(0f), px(0f))
    private val auto = ContainerMargins(ContainerMargin.Length(px(0f)), ContainerMargin.Auto,
        ContainerMargin.Length(px(0f)), ContainerMargin.Auto)
    private val style = TextStyle(fontSize = 16.sp, lineHeight = 20.sp, fontFamily = FontFamily.Monospace)

    @Test fun overwideCaptionTableKeepsContainingDirectionSeparateFromGridAndSignedSelection() {
        val containing = mutableStateOf(TableContainingDirection.Ltr)
        val gridDirection = mutableStateOf(BidiResolvedDirection.Rtl)
        val viewport = mutableStateOf(100)
        var observed: FloatTextGeometry? = null
        val clicked = mutableListOf<EntryLink>()
        val reader = FigureReaderContext(emptyList(), AppSettings(allowImages = false, allowAudio = false),
            "", { clicked += it }, Any())
        try {
            compose.activityRule.scenario.onActivity { activity -> activity.setContent {
                val table = Table(emptyList(), listOf(listOf(
                    Cell(listOf(Span("link", "A", "caption-auto-target")), false, 1, 1,
                        background = "#e40000", style = CellStyle(border = StyleBorder.None, padding = zero)),
                    Cell(listOf(Span("text", "B")), false, 1, 1,
                        background = "#e40000", style = CellStyle(border = StyleBorder.None, padding = zero)))),
                    style = TableStyle(border = StyleBorder.None, width = StyleWidth(StyleWidthUnit.Px, 140f),
                        marginValues = auto, containingDirection = containing.value))
                MaterialTheme { CompositionLocalProvider(LocalDensity provides Density(1f, 1f)) {
                    Box(Modifier.width(viewport.value.dp).testTag("caption-auto-owner")) {
                        FigureCaptionBlocks(listOf(Block("table", 0, emptyList(), table = table)),
                            AnonymousFlowContext(gridDirection.value, null, null), style, reader, { observed = it }, gapDp = 0f)
                    }
                } }
            } }
            for (direction in listOf(TableContainingDirection.Ltr, TableContainingDirection.Rtl)) {
                compose.runOnIdle {
                    containing.value = direction
                    gridDirection.value = if (direction == TableContainingDirection.Ltr) BidiResolvedDirection.Rtl else BidiResolvedDirection.Ltr
                }
                compose.waitForIdle()
                compose.onAllNodesWithText("Table margin layout unavailable.", substring = true).assertCountEquals(0)
                compose.runOnIdle {
                    val geometry = checkNotNull(observed)
                    val left = if (direction == TableContainingDirection.Ltr) 0f else -40f
                    assertEquals(100, geometry.width)
                    assertEquals(left, geometry.extents.ink!!.left, .01f)
                    assertEquals(left + 140f, geometry.extents.ink!!.right, .01f)
                    assertEquals("A\nB", geometry.text.toString())
                    val link = geometry.nodes.single { it.onClick != null }
                    val bounds = link.bounds.first()
                    val firstCellLeft = left + if (gridDirection.value == BidiResolvedDirection.Rtl) 70f else 0f
                    assertTrue(bounds.left >= firstCellLeft - .5f)
                    assertTrue(bounds.right <= firstCellLeft + 70f + .5f)
                    assertEquals(link.id, geometry.interactionNodeAt(bounds.centerX(), bounds.centerY())?.id)
                    assertTrue(geometry.characterRects(0, 1).single() != null)
                    assertTrue(geometry.rectsForRange(0, 1).isNotEmpty())
                    link.onClick!!.invoke()
                }
                val image = compose.onNodeWithTag("caption-auto-owner").captureToImage().asAndroidBitmap()
                try { assertEquals(0xffe40000.toInt(), image.getPixel(50, image.height - 2)) }
                finally { image.recycle() }
            }
            compose.runOnIdle {
                assertEquals(List(2) { EntryLink("caption-auto-target") }, clicked)
                viewport.value = 201
                containing.value = TableContainingDirection.Ltr
            }
            compose.waitForIdle()
            compose.runOnIdle {
                val geometry = checkNotNull(observed)
                val link = geometry.nodes.single { it.onClick != null }
                assertTrue(link.bounds.first().left >= 30.5f)
                assertEquals(201, geometry.width)
            }
        } finally { compose.activityRule.scenario.onActivity { it.setContent {} } }
    }

    @Test fun captionFloorEnlargesRealGridWhilePreservingCaptionAndCellActionsAcrossNesting() {
        val caption = "CAPTIONMINIMUM"
        var observed: FloatTextGeometry? = null
        val reader = FigureReaderContext(emptyList(), AppSettings(allowImages = false, allowAudio = false), "", {}, Any())
        val inner = Table(listOf(Span("link", caption, "caption-target")), listOf(listOf(
            Cell(listOf(Span("link", "Body", "body-target")), false, 1, 1,
                style = CellStyle(border = StyleBorder.None, padding = zero)))),
            style = TableStyle(border = StyleBorder.None, width = StyleWidth(StyleWidthUnit.Percent, 10f),
                marginValues = auto, containingDirection = TableContainingDirection.Ltr))
        val outer = Table(emptyList(), listOf(listOf(Cell(emptyList(), false, 1, 1, nestedTable = inner,
            style = CellStyle(border = StyleBorder.None, padding = zero)))), style = TableStyle(width = StyleWidth(StyleWidthUnit.Px, 300f)))
        try {
            compose.activityRule.scenario.onActivity { activity -> activity.setContent {
                MaterialTheme { CompositionLocalProvider(LocalDensity provides Density(1f, 1f)) {
                    Box(Modifier.width(300.dp)) {
                        FigureCaptionBlocks(listOf(Block("table", 0, emptyList(), table = outer)),
                            AnonymousFlowContext(BidiResolvedDirection.Ltr, null, null), style, reader, { observed = it }, gapDp = 0f)
                    }
                } }
            } }
            compose.waitForIdle()
            compose.onAllNodesWithText("Table margin layout unavailable.", substring = true).assertCountEquals(0)
            compose.runOnIdle {
                val geometry = checkNotNull(observed)
                assertEquals(1, geometry.text.toString().split(caption).size - 1)
                assertEquals(1, geometry.text.toString().split("Body").size - 1)
                assertEquals(2, geometry.nodes.count { it.onClick != null })
                val captionRange = geometry.rectsForRange(0, caption.length).single()
                val bodyRange = geometry.rectsForRange(geometry.text.toString().indexOf("Body"), geometry.text.length).single()
                assertTrue(captionRange.width() > 30f)
                assertTrue(bodyRange.top > captionRange.top)
                assertTrue(captionRange.left > 0f)
            }
        } finally { compose.activityRule.scenario.onActivity { it.setContent {} } }
    }

    @Test fun unsupportedCaptionExclusionsKeepRealBodyAndActionsBehindVisibleWarning() {
        var observed: FloatTextGeometry? = null
        val clicked = mutableListOf<EntryLink>()
        val reader = FigureReaderContext(emptyList(), AppSettings(allowImages = false, allowAudio = false),
            "", { clicked += it }, Any())
        val table = Table(listOf(Span("link", "Caption", "caption-target")), listOf(listOf(
            Cell(listOf(Span("link", "Body", "body-target")), false, 1, 1,
                style = CellStyle(border = StyleBorder.None, padding = zero)))),
            style = TableStyle(width = StyleWidth(StyleWidthUnit.Px, 100f), marginValues = auto,
                containingDirection = TableContainingDirection.Rtl))
        try {
            compose.activityRule.scenario.onActivity { activity -> activity.setContent {
                val exclusions = remember { StaticCaptionInput().apply {
                    update(listOf(NativeFloatExclusion(TableFloatSide.Left, NativeFloatBounds(0f, 0f, 10f, 20f))))
                } }
                MaterialTheme { CompositionLocalProvider(LocalDensity provides Density(1f, 1f),
                    LocalStaticCaptionInput provides exclusions) {
                    Box(Modifier.width(300.dp)) {
                        FigureCaptionBlocks(listOf(Block("table", 0, emptyList(), table = table)),
                            AnonymousFlowContext(BidiResolvedDirection.Ltr, null, null), style, reader, { observed = it }, gapDp = 0f)
                    }
                } }
            } }
            compose.waitForIdle()
            compose.onNodeWithText("Table margin layout unavailable.", substring = true).assertIsDisplayed()
            compose.onNodeWithTag("compiled-table-grid-figure-caption", useUnmergedTree = true).assertIsDisplayed()
            compose.runOnIdle {
                val geometry = checkNotNull(observed)
                assertEquals("Caption\nBody", geometry.text.toString())
                val nodes = geometry.nodes.filter { it.onClick != null }
                assertEquals(2, nodes.size)
                nodes.forEach { node ->
                    val bounds = node.bounds.first()
                    assertEquals(node.id, geometry.interactionNodeAt(bounds.centerX(), bounds.centerY())?.id)
                    node.onClick!!.invoke()
                }
                assertEquals(listOf(EntryLink("caption-target"), EntryLink("body-target")), clicked)
            }
        } finally { compose.activityRule.scenario.onActivity { it.setContent {} } }
    }

    @Test fun inlineCaptionTableKeepsExistingLogicalPlacementWithZeroAutoMargins() {
        val direction = mutableStateOf(BidiResolvedDirection.Ltr)
        val reader = FigureReaderContext(emptyList(), AppSettings(allowImages = false, allowAudio = false), "", {}, Any())
        try {
            compose.activityRule.scenario.onActivity { activity -> activity.setContent {
                val table = Table(emptyList(), listOf(listOf(Cell(listOf(Span("text", "A")), false, 1, 1,
                    style = CellStyle(border = StyleBorder.None, padding = zero)))),
                    style = TableStyle(width = StyleWidth(StyleWidthUnit.Px, 100f), display = TableDisplay.InlineTable,
                        marginValues = auto, containingDirection = if (direction.value == BidiResolvedDirection.Ltr)
                            TableContainingDirection.Rtl else TableContainingDirection.Ltr))
                MaterialTheme { CompositionLocalProvider(LocalDensity provides Density(1f, 1f)) {
                    Box(Modifier.width(200.dp).testTag("inline-caption-auto-owner")) {
                        FigureCaptionTable(table, AnonymousFlowContext(direction.value, null, null), style, reader, {})
                    }
                } }
            } }
            for (value in listOf(BidiResolvedDirection.Ltr, BidiResolvedDirection.Rtl)) {
                compose.runOnIdle { direction.value = value }; compose.waitForIdle()
                compose.onAllNodesWithText("Table margin layout unavailable.", substring = true).assertCountEquals(0)
                val parent = compose.onNodeWithTag("inline-caption-auto-owner").fetchSemanticsNode().boundsInRoot
                val grid = compose.onNodeWithTag("compiled-table-grid-figure-caption", useUnmergedTree = true)
                    .fetchSemanticsNode().boundsInRoot
                assertEquals(100f, grid.width, .01f)
                assertEquals(if (value == BidiResolvedDirection.Ltr) 0f else 100f, grid.left - parent.left, .01f)
            }
        } finally { compose.activityRule.scenario.onActivity { it.setContent {} } }
    }
}
