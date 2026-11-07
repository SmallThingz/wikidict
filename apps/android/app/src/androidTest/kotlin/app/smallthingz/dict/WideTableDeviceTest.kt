package app.smallthingz.dict

import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.width
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalLayoutDirection
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.dp
import androidx.test.platform.app.InstrumentationRegistry
import androidx.compose.material3.MaterialTheme
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.test.*
import androidx.compose.ui.text.TextLayoutResult
import androidx.test.filters.SdkSuppress
import java.util.concurrent.atomic.AtomicReference
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

class WideTableDeviceTest {
    @get:Rule val compose = createPhysicalComposeRule()
    private val witness = "𓂜𓐰𓏏𓐱𓏭𓅪𓆑"
    private fun fixture(): ByteArray {
        fun u32(n: Int) = ByteArray(4) { (n ushr (it * 8)).toByte() }
        fun u16(n: Int) = byteArrayOf(n.toByte(), (n ushr 8).toByte())
        fun string(s: String) = s.toByteArray(Charsets.UTF_8).let { u32(it.size) + it }
        fun span(kind: Int, text: String, target: String = "", trail: String = "", classes: String = "", direction: String = "") =
            byteArrayOf(kind.toByte(), 0, 0) + listOf(text, target, trail, "", classes, direction)
                .fold(byteArrayOf()) { bytes, value -> bytes + string(value) }
        val cells = (0 until 6).fold(byteArrayOf()) { bytes, index ->
            val letter = ('A'.code + index).toChar()
            val ordinary = span(1, "Cell $letter", "target$letter", if (index == 0) " " else "")
            val spans = if (index == 0) u32(2) + ordinary + span(0, witness, classes = "Egyp", direction = "ltr")
                else u32(1) + ordinary
            bytes + byteArrayOf(0) + u16(100) + u16(1) + spans
        }
        val table = byteArrayOf(1) + u32(1) + span(0, "Wide forms") + u32(1) + u32(6) + cells
        val block = byteArrayOf(12, 0, 0) + u32(0) + byteArrayOf(0) + string("") + string("") + table
        return "DPR2".toByteArray() + u32(0) + u32(1) + byteArrayOf(3) + string("Noun") + u32(1) + block + ByteArray(20)
    }
    @Test
    @SdkSuppress(minSdkVersion = 31)
    fun sixInflatedCellsDecodeAndDisplayEveryLinkIncludingNativeEgyptianText() {
        val entry = BlobDecoder.decode(fixture(), "Wide table", "language", "English", "en")
        val table = checkNotNull(entry.sections.single().blocks.single().table)
        assertEquals(List(6) { 100 }, table.rows.single().map { it.colspan })
        assertEquals(6, tableGrid(table).columns)
        val clicked = AtomicReference<String?>()
        compose.runOnUiThread {
            compose.activity.setContent {
                MaterialTheme { EntryView(entry, false, {}, onLink = { clicked.set(it.target) }, settings = AppSettings(collapseOtherSections = false, collapseDetails = false)) }
            }
        }
        val first = "Cell A \u2066$witness\u2069"
        compose.waitUntil(10000) {
            compose.onAllNodesWithText(first, useUnmergedTree = true)
                .fetchSemanticsNodes(atLeastOneRootRequired = false)
                .singleOrNull()?.config?.getOrNull(EgyptianShapedRunCount) == 1
        }
        compose.onNodeWithText("Wide forms", useUnmergedTree = true).assertIsDisplayed()
        for (index in 0 until 6) {
            val letter = ('A'.code + index).toChar()
            val text = if (index == 0) first else "Cell $letter"
            val node = compose.onNodeWithText(text, useUnmergedTree = true)
            node.performScrollTo().assertIsDisplayed()
            val layouts = mutableListOf<TextLayoutResult>()
            node.performSemanticsAction(SemanticsActions.GetTextLayoutResult) { it(layouts) }
            val layout = layouts.single()
            assertFalse("Every cell must retain all visible text", layout.hasVisualOverflow)
            if (index == 0) assertNotNull("Native cell must really render its placeholder", layout.placeholderRects.single())
            node.performTouchInput { click(layout.getBoundingBox(1).center) }
            compose.waitUntil(10000) { clicked.get() == "target$letter" }
        }
        compose.onNodeWithText("Table is too large to display.", useUnmergedTree = true).assertDoesNotExist()
    }

    private val observedDensity = AtomicReference<Density?>()

    @Composable
    private fun TableViewport(mode: String, fontScale: Float, fixedDensity: Float? = null,
                              content: @Composable () -> Unit) {
        val base = LocalDensity.current
        val local = Density(fixedDensity ?: base.density, fontScale = fontScale)
        SideEffect { observedDensity.set(local) }
        CompositionLocalProvider(LocalDensity provides local, LocalLayoutDirection provides LayoutDirection.Ltr) {
            DictTheme(mode) {
                androidx.compose.material3.Surface(Modifier.width(320.dp).height(480.dp).clipToBounds().testTag("table-viewport")) {
                    content()
                }
            }
        }
    }

    private fun rawBounds(node: SemanticsNodeInteraction): Rect {
        val actual = node.fetchSemanticsNode()
        return Rect(actual.positionInRoot, Size(actual.size.width.toFloat(), actual.size.height.toFloat()))
    }

    private fun visibleText(label: String, fontScale: Float): Pair<SemanticsNodeInteraction, TextLayoutResult> {
        val node = compose.onNodeWithText(label, useUnmergedTree = true)
        return withRenderedLayoutFailureEvidence(label, node, compose.onNodeWithTag("table-viewport"), if (label == "Table is too large to display.") "unavailable-table" else null, {
            var state = ""
            compose.runOnIdle { state = ownedLayoutState(compose.activity.window.decorView) }
            state
        }) {
        compose.onNodeWithTag("entry-scroll").performScrollToNode(hasText(label))
        node.performScrollTo()
        // The nearest scroll parent is the table's horizontal container. Explicitly move
        // the outer vertical list when the measured cell still crosses the viewport.
        val outer = compose.onNodeWithTag("entry-scroll")
        val viewportNode = compose.onNodeWithTag("table-viewport").assertIsDisplayed()
        for (attempt in 0 until 4) {
            val frame = rawBounds(viewportNode)
            val before = rawBounds(node)
            val dy = when {
                before.top < frame.top - 1f -> before.top - frame.top
                before.bottom > frame.bottom + 1f -> before.bottom - frame.bottom
                else -> break
            }
            outer.performSemanticsAction(SemanticsActions.ScrollBy) { action ->
                assertTrue("Outer entry must consume vertical positioning: " + label, action(0f, dy))
            }
            compose.waitForIdle()
            val after = rawBounds(node)
            assertTrue("Vertical positioning must make progress: " + label,
                kotlin.math.abs(after.top - before.top) > 0f)
        }
        node.assertIsDisplayed()
        val viewport = rawBounds(viewportNode)
        val density = checkNotNull(observedDensity.get())
        assertEquals(fontScale, density.fontScale, 0f)
        assertTrue(viewport.width > 0f && viewport.width <= with(density) { 320.dp.toPx() } + 1f)
        assertTrue(viewport.height > 0f && viewport.height <= with(density) { 480.dp.toPx() } + 1f)
        val bounds = rawBounds(node)
        assertTrue("Visible text must have area", bounds.width > 0f && bounds.height > 0f)
        assertTrue("Full text must be reachable horizontally: " + label,
            bounds.left >= viewport.left - 1f && bounds.right <= viewport.right + 1f)
        assertTrue("Full text must be reachable vertically: " + label,
            bounds.top >= viewport.top - 1f && bounds.bottom <= viewport.bottom + 1f)
        val layouts = mutableListOf<TextLayoutResult>()
        node.performSemanticsAction(SemanticsActions.GetTextLayoutResult) { it(layouts) }
        val layout = layouts.single()
        assertEquals(fontScale, layout.layoutInput.density.fontScale, 0f)
        if (label == "Table is too large to display.") {
            assertCompletePlainTextLayout(layout, label)
        } else {
            assertFalse("Rendered text must not overflow: " + label, layout.hasVisualOverflow)
        }
        assertTrue(layout.size.width <= bounds.width + 1f && layout.size.height <= bounds.height + 1f)
        node to layout
        }
    }

    private fun tapVisibleLink(label: String, fontScale: Float) {
        val (node, layout) = visibleText(label, fontScale)
        node.performTouchInput { click(layout.getBoundingBox(0).center) }
        compose.waitForIdle()
    }

    private fun tableEntry(owner: String, title: String, table: Table): Entry =
        Entry(title, emptyList(), "language", "English", "en",
            listOf(Section(3, "Noun", listOf(
                Block("table", 0, emptyList(), table = table),
                Block("paragraph", 0, listOf(Span("link", "After table", target = "after-table"))),
            ))), emptyList(), edition = "enwiktionary-20261001",
            origin = WordHit(owner, title, "English", "language", 0, 4, owner + "-record"))

    @Test fun unavailableTableShowsReadableFeedbackAndKeepsFollowingLinkReachable() {
        val mode = LearningStore.get(InstrumentationRegistry.getInstrumentation().targetContext).data.settings.darkMode
        // Empty source rows preserve minimum-row spacing without composing thousands
        // of text cells. Derive a genuinely overflowing height from the installed API.
        val capacity = Constraints.fitPrioritizingWidth(136, 136, 0, Int.MAX_VALUE - 1).maxHeight
        val rowCount = capacity / 40 + 1
        val table = Table(listOf(Span("text", "Oversize forms")), List(rowCount) { row ->
            if (row == 0 || row == rowCount - 1)
                listOf(Cell(listOf(Span("text", "Partial cell")), false, 1, 1))
            else emptyList()
        })
        val entry = tableEntry("oversize-owner", "Oversize", table)
        val opened = mutableListOf<Pair<String, String>>()
        try {
            compose.activityRule.scenario.onActivity { activity ->
                activity.setContent {
                    TableViewport(mode, 1f, fixedDensity = 1f) {
                        EntryView(entry, false, {}, onLink = { opened += entry.key to it.target },
                            settings = AppSettings(collapseOtherSections = false, collapseDetails = false))
                    }
                }
            }
            assertTrue("Fixture exceeds the renderer's supported minimum-row height",
                rowCount.toLong() * 40L > capacity)
            compose.onNodeWithTag("entry-scroll").performScrollToNode(hasText("Oversize forms"))
            compose.waitUntil(10000) {
                compose.onAllNodesWithText("Table is too large to display.", useUnmergedTree = true)
                    .fetchSemanticsNodes(atLeastOneRootRequired = false).isNotEmpty()
            }
            visibleText("Oversize forms", 1f)
            visibleText("Table is too large to display.", 1f)
            compose.onAllNodesWithText("Partial cell", useUnmergedTree = true).assertCountEquals(0)
            tapVisibleLink("After table", 1f)
            compose.runOnIdle { assertEquals(listOf(entry.key to "after-table"), opened) }
        } finally {
            compose.runOnIdle { compose.activity.setContent {} }
            compose.waitForIdle()
        }
    }

    @Test fun formerlyUnavailableTallSparseTableKeepsEveryLinkAndFollowingContentReachable() {
        val mode = LearningStore.get(InstrumentationRegistry.getInstrumentation().targetContext).data.settings.darkMode
        val capacity = Constraints.fitPrioritizingWidth(136, 136, 0, Int.MAX_VALUE - 1).maxHeight
        val labels = listOf("Tall first α", "Tall middle ⲁ", "Tall last 日")
        val indexes = listOf(0, 499, 999)
        val table = Table(listOf(Span("text", "Tall forms")), List(1000) { row ->
            val index = indexes.indexOf(row)
            if (index < 0) emptyList() else listOf(Cell(
                listOf(Span("link", labels[index], target = "tall-" + index)), false, 1, 1))
        })
        val entry = tableEntry("tall-owner", "Tall", table)
        val opened = mutableListOf<Pair<String, String>>()
        try {
            compose.activityRule.scenario.onActivity { activity ->
                activity.setContent {
                    TableViewport(mode, 1f, fixedDensity = 1f) {
                        EntryView(entry, false, {}, onLink = { opened += entry.key to it.target },
                            settings = AppSettings(collapseOtherSections = false, collapseDetails = false))
                    }
                }
            }
            assertTrue("Fixture was above the former conservative height", 1000L * 40L > TablePixelLimit)
            assertTrue("Fixture fits the installed width-dependent finite budget", 1000L * 40L <= capacity)
            visibleText("Tall forms", 1f)
            labels.forEach { tapVisibleLink(it, 1f) }
            tapVisibleLink("After table", 1f)
            compose.onNodeWithText("Table is too large to display.", useUnmergedTree = true).assertDoesNotExist()
            compose.runOnIdle {
                assertEquals(labels.indices.map { entry.key to ("tall-" + it) } + (entry.key to "after-table"), opened)
            }
        } finally {
            compose.runOnIdle { compose.activity.setContent {} }
            compose.waitForIdle()
        }
    }

    @Test fun largeTextMultirowTableScrollsAndForwardsLinksForCurrentEntryOwner() {
        val mode = LearningStore.get(InstrumentationRegistry.getInstrumentation().targetContext).data.settings.darkMode
        val labels = listOf("A α", "B β", "C ⲁ", "D 日", "E ε", "F ⲃ", "G 本",
            "H η", "I θ", "J ⲅ", "K 語", "L λ", "M μ", "N ⲇ", "O 文",
            "P π", "Q ρ", "R ⲉ", "S 字", "T τ", "U υ", "V ⲍ", "W 形")
        fun cell(index: Int, rowspan: Int = 1) = Cell(
            listOf(Span("link", labels[index], target = "cell-" + index)), index < 4, 1, rowspan)
        val table = Table(listOf(Span("text", "Mixed forms")), listOf(
            listOf(cell(0, rowspan = 2), cell(1), cell(2), cell(3)),
            listOf(cell(4), cell(5), cell(6)),
            (7..10).map { cell(it) }, (11..14).map { cell(it) },
            (15..18).map { cell(it) }, (19..22).map { cell(it) },
        ))
        val first = tableEntry("first-table-owner", "First", table)
        val second = tableEntry("second-table-owner", "Second", table)
        val displayed = mutableStateOf(first)
        val opened = mutableListOf<Pair<String, String>>()
        try {
            compose.activityRule.scenario.onActivity { activity ->
                activity.setContent {
                    TableViewport(mode, 2f) {
                        val current = displayed.value
                        EntryView(current, false, {}, onLink = { opened += current.key to it.target },
                            settings = AppSettings(collapseOtherSections = false, collapseDetails = false))
                    }
                }
            }
            visibleText(labels[0], 2f)
            // Observe actual placement: row two skips the two-row cell, then row three
            // resumes its column. No tableGrid/tablePixelLayout oracle is reused here.
            val a = rawBounds(compose.onNodeWithText(labels[0], useUnmergedTree = true))
            val b = rawBounds(compose.onNodeWithText(labels[1], useUnmergedTree = true))
            val e = rawBounds(compose.onNodeWithText(labels[4], useUnmergedTree = true))
            val h = rawBounds(compose.onNodeWithText(labels[7], useUnmergedTree = true))
            assertEquals(a.top, b.top, 1f)
            assertEquals(b.left, e.left, 1f)
            assertEquals(a.left, h.left, 1f)
            assertTrue(e.top > b.top && h.top > e.top)

            val horizontal = compose.onNode(SemanticsMatcher.keyIsDefined(SemanticsProperties.HorizontalScrollAxisRange))
            val horizontalBefore = horizontal.fetchSemanticsNode().config[SemanticsProperties.HorizontalScrollAxisRange].value()
            val viewport = rawBounds(compose.onNodeWithTag("table-viewport"))
            val rowY = a.center.y - viewport.top
            compose.onNodeWithTag("table-viewport").performTouchInput {
                swipe(Offset(width * 0.85f, rowY), Offset(width * 0.15f, rowY))
            }
            val horizontalAfter = horizontal.fetchSemanticsNode().config[SemanticsProperties.HorizontalScrollAxisRange]
            compose.runOnIdle {
                assertTrue("Real horizontal drag must move the table", horizontalAfter.value() > horizontalBefore)
            }
            val reader = compose.onNodeWithTag("entry-scroll")
            val verticalBefore = reader.fetchSemanticsNode().config[SemanticsProperties.VerticalScrollAxisRange].value()
            compose.onNodeWithTag("table-viewport").performTouchInput { swipeUp() }
            val verticalAfter = reader.fetchSemanticsNode().config[SemanticsProperties.VerticalScrollAxisRange]
            compose.runOnIdle {
                assertTrue("Vertical drag over the table must reach the reader scroll", verticalAfter.value() > verticalBefore)
            }
            labels.forEach { tapVisibleLink(it, 2f) }
            tapVisibleLink("After table", 2f)
            compose.onNodeWithText("Table is too large to display.", useUnmergedTree = true).assertDoesNotExist()
            compose.runOnIdle {
                assertEquals(labels.indices.map { first.key to ("cell-" + it) } + (first.key to "after-table"), opened)
                displayed.value = second
            }
            compose.onNodeWithTag("entry-title").assertTextEquals("Second")
            // Locate and measure the replacement nodes afresh; never carry coordinates
            // or semantics references from the previous owner's table.
            tapVisibleLink(labels.first(), 2f)
            tapVisibleLink(labels.last(), 2f)
            compose.runOnIdle {
                assertEquals(listOf(second.key to "cell-0", second.key to "cell-22"), opened.takeLast(2))
                assertEquals(labels.size + 3, opened.size)
            }
        } finally {
            compose.runOnIdle { compose.activity.setContent {} }
            compose.waitForIdle()
        }
    }
}
