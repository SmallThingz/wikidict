package app.smallthingz.dict

import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.width
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.graphics.toPixelMap
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.*
import androidx.compose.ui.text.TextLayoutResult
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

class CellMinimumWidthDeviceTest {
    @get:Rule val compose = createPhysicalComposeRule()

    private fun rawBounds(node: SemanticsNodeInteraction): Rect {
        val actual = node.fetchSemanticsNode()
        return Rect(actual.positionInRoot, Size(actual.size.width.toFloat(), actual.size.height.toFloat()))
    }

    private fun retain(name: String, detail: String): ImageBitmap {
        val viewport = compose.onNodeWithTag("cell-minimum-root")
        val image = viewport.captureToImage()
        val report = renderedLayoutFailureEvidence(name, null, null, viewport, name, image.asAndroidBitmap()) + "\n$detail"
        check(report.toByteArray(Charsets.UTF_8).size <= 128 * 1024)
        InstrumentationRegistry.getInstrumentation().sendStatus(0, android.os.Bundle().apply {
            putString(android.app.Instrumentation.REPORT_KEY_STREAMRESULT, "\n$report\n")
        })
        check("OWNED_PNG_BEGIN $name " in report)
        return image
    }

    @Test fun nestedTableBlocksKeepIntrinsicWidthsSpacingOwnersAndActionsAcrossViewportChanges() {
        val viewportWidth = mutableStateOf(900)
        val opened = mutableListOf<String>()
        val zero = StyleLength(StyleLengthUnit.Px, 0f)
        val zeroEdges = StyleEdges(zero, zero, zero, zero)
        val cellStyle = CellStyle(border = StyleBorder.None, padding = zeroEdges,
            textAlign = CellTextAlign.Center)
        val tableStyle = TableStyle(collapse = TableCollapse.Separate,
            padding = zeroEdges, border = StyleBorder.None)
        val nested = (0..4).map { index ->
            val rows = (0..1).map { row -> (0..2).map { column ->
                val label = "$index-$row-$column"
                Cell(listOf(Span("link", label, target = "nested-$label")), false, 1, 1,
                    background = "#ffffff", style = cellStyle)
            } }
            Block("table", 0, emptyList(), table = Table(emptyList(), rows, style = tableStyle))
        }
        val table = Table(emptyList(), listOf(
            listOf(Cell(listOf(Span("text", "Possession")), true, 3, 1,
                background = "#ffffff", style = cellStyle.copy(textAlign = CellTextAlign.Left,
                    minWidth = StyleLength(StyleLengthUnit.Em, 30f)))),
            listOf(Cell(emptyList(), false, 3, 1, blocks = nested,
                background = "#ffffff", style = cellStyle))), style = tableStyle)
        try {
            compose.activityRule.scenario.onActivity { activity -> activity.setContent {
                CompositionLocalProvider(LocalDensity provides Density(1f, 1f)) {
                    DictTheme("light") {
                        MaterialTheme(typography = MaterialTheme.typography.copy(
                            bodyLarge = MaterialTheme.typography.bodyLarge.copy(fontSize = 20.sp, lineHeight = 24.sp))) {
                            Surface(Modifier.fillMaxSize()) {
                                Box(Modifier.fillMaxSize(), contentAlignment = Alignment.TopStart) {
                                    Box(Modifier.width(viewportWidth.value.dp).height(700.dp).testTag("cell-minimum-root")) {
                                        CompiledTableView(table, null) { opened += it.target }
                                    }
                                }
                            }
                        }
                    }
                }
            } }
            var owners: List<Int>? = null
            for ((iteration, width) in listOf(900, 240, 900).withIndex()) {
                compose.runOnIdle { viewportWidth.value = width }
                compose.waitForIdle()
                val grid = compose.onNodeWithTag("compiled-table-grid", useUnmergedTree = true)
                val header = compose.onNodeWithTag("compiled-table-cell-root-0", useUnmergedTree = true)
                val body = compose.onNodeWithTag("compiled-table-cell-root-1", useUnmergedTree = true)
                val children = (0..4).map { index ->
                    compose.onNodeWithTag("compiled-table-grid-root/1/block-$index", useUnmergedTree = true)
                }
                val currentOwners = listOf(grid.fetchSemanticsNode().id) + children.map { it.fetchSemanticsNode().id }
                if (owners == null) owners = currentOwners else assertEquals("One nested source graph across resize", owners, currentOwners)
                assertEquals("The spanning 30em content floor survives nested width queries", 600f, rawBounds(grid).width, 1f)
                assertEquals(600f, rawBounds(header).width, 1f)
                assertEquals(600f, rawBounds(body).width, 1f)
                val childBounds = children.map(::rawBounds)
                assertEquals(rawBounds(body).top, childBounds.first().top, 1f)
                childBounds.zipWithNext().forEach { (previous, next) ->
                    assertEquals("Existing block spacing is applied once", 4f, next.top - previous.bottom, 1f)
                }
                assertEquals("No manufactured trailing block gap", rawBounds(body).bottom, childBounds.last().bottom, 1f)
                (0..4).forEach { index ->
                    compose.onNodeWithText("$index-0-0", useUnmergedTree = true).assertExists()
                    compose.onNodeWithText("$index-1-2", useUnmergedTree = true).assertExists()
                }
                compose.onNodeWithText("Table is too large to display.").assertDoesNotExist()
                compose.onNodeWithText("Table layout is unavailable at this size.").assertDoesNotExist()
                val horizontal = compose.onAllNodes(SemanticsMatcher.keyIsDefined(SemanticsProperties.HorizontalScrollAxisRange))
                    .assertCountEquals(1)[0]
                val range = horizontal.fetchSemanticsNode().config[SemanticsProperties.HorizontalScrollAxisRange]
                if (width == 240) assertTrue("Only the outer table scrolls", range.maxValue() > 300f)
                else assertEquals(0f, range.maxValue(), 1f)
                retain("nested-cell-blocks-$iteration.png", "viewport=$width outer=${rawBounds(grid)} children=$childBounds owners=$currentOwners")
            }
            val target = compose.onNodeWithText("4-1-2", useUnmergedTree = true).assertIsDisplayed()
            val layouts = mutableListOf<TextLayoutResult>()
            target.performSemanticsAction(SemanticsActions.GetTextLayoutResult) { it(layouts) }
            target.performTouchInput { click(layouts.single().getBoundingBox(0).center) }
            compose.waitForIdle()
            compose.runOnIdle { assertEquals(listOf("nested-4-1-2"), opened) }
        } finally {
            compose.activityRule.scenario.onActivity { it.setContent {} }
            compose.waitForIdle()
        }
    }

    @Test fun spanningMinimumUsesAllRowsAndBodyEmOnceWhileRealOverflowRemainsScrollableAndClickable() {
        val state = mutableStateOf(0)
        val opened = mutableListOf<String>()
        fun px(value: Float) = StyleLength(StyleLengthUnit.Px, value)
        fun em(value: Float) = StyleLength(StyleLengthUnit.Em, value)
        val zero = px(0f)
        val zeroEdges = StyleEdges(zero, zero, zero, zero)
        fun entry(mode: Int): Entry {
            val decorated = mode >= 2
            val padding = if (decorated) px(7f) else zero
            val border = if (decorated) StyleBorder.Solid(px(2f), "#0000ff") else StyleBorder.None
            fun style(minimum: StyleLength? = null) = CellStyle(border = border,
                padding = StyleEdges(padding, padding, padding, padding),
                textAlign = CellTextAlign.Left, minWidth = minimum)
            val header = Cell(listOf(Span("text", "H", fontScale = if (mode >= 3) 2f else .5f,
                fontScaleBasis = FontScaleBasis.NormalBody)), true, 3, 1,
                background = "#ffffff", style = style(em(if (decorated) 27f else 30f)))
            val row = listOf("L", "M", "R").map { label -> Cell(listOf(Span("link", label, target = "target-$label")),
                false, 1, 1, background = "#ffffff", style = style()) }
            val later = Cell(listOf(Span("text", "Z")), false, 3, 1,
                background = "#ffffff", style = style(if (mode == 1) em(36f) else px(0f)))
            val table = Table(emptyList(), listOf(listOf(header), row, listOf(later)), style = TableStyle(
                collapse = TableCollapse.Separate, padding = zeroEdges, border = StyleBorder.None))
            return Entry("Cell minimum", emptyList(), "language", "English", "en",
                listOf(Section(2, "", listOf(Block("table", 0, emptyList(), table = table)))), emptyList())
        }
        try {
            compose.activityRule.scenario.onActivity { activity -> activity.setContent {
                CompositionLocalProvider(LocalDensity provides Density(1f, 1f)) {
                    DictTheme("light") {
                        MaterialTheme(typography = MaterialTheme.typography.copy(
                            bodyLarge = MaterialTheme.typography.bodyLarge.copy(fontSize = 20.sp, lineHeight = 24.sp))) {
                            Surface(Modifier.fillMaxSize()) {
                                Box(Modifier.fillMaxSize(), contentAlignment = Alignment.TopStart) {
                                    Box(Modifier.width(if (state.value == 4) 240.dp else 900.dp).height(700.dp)
                                        .testTag("cell-minimum-root")) {
                                        EntryView(entry(state.value), false, {}, onLink = { opened += it.target },
                                            settings = AppSettings(allowImages = false, allowAudio = false,
                                                collapseOtherSections = false, collapseDetails = false))
                                    }
                                }
                            }
                        }
                    }
                }
            } }
            var owner: Int? = null
            for (mode in 0..4) {
                compose.runOnIdle { state.value = mode }
                compose.waitForIdle()
                val grid = compose.onNodeWithTag("compiled-table-grid", useUnmergedTree = true)
                val gridNode = grid.fetchSemanticsNode()
                val header = compose.onNodeWithTag("compiled-table-cell-root-0", useUnmergedTree = true)
                val later = compose.onNodeWithTag("compiled-table-cell-root-4", useUnmergedTree = true)
                val expected = if (mode == 0) 600f else if (mode == 1) 720f else 558f
                val picture = retain("cell-minimum-$mode.png", "mode=$mode grid=${rawBounds(grid)} header=${rawBounds(header)} later=${rawBounds(later)}")
                if (owner == null) owner = gridNode.id else assertEquals("Same grid owner across style/viewport changes", owner, gridNode.id)
                assertEquals("Actual grid keeps the content floor plus real cell edges", expected, rawBounds(grid).width, 1f)
                assertEquals(expected, rawBounds(header).width, 1f)
                assertEquals(expected, rawBounds(later).width, 1f)
                val expectedFloor = if (mode == 0) 600f else if (mode == 1) 720f else 540f
                assertEquals(expectedFloor, rawBounds(header).width - (if (mode >= 2) 18f else 0f), 1f)
                compose.onNodeWithText("Table is too large to display.").assertDoesNotExist()
                compose.onNodeWithText("Table layout is unavailable at this size.").assertDoesNotExist()
                val layouts = mutableListOf<TextLayoutResult>()
                compose.onNodeWithText("H", useUnmergedTree = true)
                    .performSemanticsAction(SemanticsActions.GetTextLayoutResult) { it(layouts) }
                assertTrue("Child font override remains independent of normalized cell em",
                    layouts.single().layoutInput.text.spanStyles.any {
                        kotlin.math.abs(it.item.fontSize.value - (if (mode >= 3) 40f else 10f)) < .01f
                    })
                val pixels = picture.toPixelMap()
                val root = rawBounds(compose.onNodeWithTag("cell-minimum-root"))
                val ink = rawBounds(compose.onNodeWithText("H", useUnmergedTree = true))
                var count = 0
                for (y in (ink.top - root.top).toInt().coerceAtLeast(0) until
                    (ink.bottom - root.top).toInt().coerceAtMost(picture.height))
                    for (x in (ink.left - root.left).toInt().coerceAtLeast(0) until
                        (ink.right - root.left).toInt().coerceAtMost(picture.width)) {
                        val color = pixels[x, y]
                        if (color.alpha > .5f && color.red < .3f && color.green < .3f && color.blue < .3f) count++
                    }
                assertTrue("The same native child must draw real glyph pixels", count > 0)
                if (mode == 4) {
                    val horizontal = compose.onNode(SemanticsMatcher.keyIsDefined(SemanticsProperties.HorizontalScrollAxisRange))
                    val range = horizontal.fetchSemanticsNode().config[SemanticsProperties.HorizontalScrollAxisRange]
                    assertTrue("The authored minimum overflows the narrow viewport", range.maxValue() > 250f)
                    horizontal.performSemanticsAction(SemanticsActions.ScrollBy) { assertTrue(it(2000f, 0f)) }
                    compose.waitForIdle()
                    assertTrue(horizontal.fetchSemanticsNode().config[SemanticsProperties.HorizontalScrollAxisRange].value() > 250f)
                    val target = compose.onNodeWithText("R", useUnmergedTree = true).assertIsDisplayed()
                    val text = mutableListOf<TextLayoutResult>()
                    target.performSemanticsAction(SemanticsActions.GetTextLayoutResult) { it(text) }
                    target.performTouchInput { click(text.single().getBoundingBox(0).center) }
                    compose.waitForIdle()
                    compose.runOnIdle { assertEquals(listOf("target-R"), opened) }
                    retain("cell-minimum-scrolled.png", "actual scroll=${horizontal.fetchSemanticsNode().config[SemanticsProperties.HorizontalScrollAxisRange].value()} actions=$opened")
                }
            }
        } finally {
            compose.activityRule.scenario.onActivity { it.setContent {} }
            compose.waitForIdle()
        }
    }
}
