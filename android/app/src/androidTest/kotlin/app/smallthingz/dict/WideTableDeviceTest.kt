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
import java.util.concurrent.atomic.AtomicReference
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

class WideTableDeviceTest {
    @get:Rule val compose = createPhysicalContentRule()
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
    private val keyboardOwner = AtomicReference<androidx.compose.ui.input.InputModeManager>()

    private fun withReaderKeyboard(action: () -> Unit) {
        val input = checkNotNull(keyboardOwner.get())
        val initial = compose.runOnIdle { input.inputMode }
        var primary: Throwable? = null
        try {
            compose.runOnIdle {
                assertPhysicalActivity(compose.activity)
                assertTrue(compose.activity.hasWindowFocus())
                assertTrue(input.requestInputMode(androidx.compose.ui.input.InputMode.Keyboard))
            }
            compose.waitUntil(10_000) { input.inputMode == androidx.compose.ui.input.InputMode.Keyboard }
            action()
        } catch (failure: Throwable) {
            primary = failure
            throw failure
        } finally {
            try {
                if (initial == androidx.compose.ui.input.InputMode.Touch && input.inputMode != initial) {
                    // An owned physical touch returns Android to touch mode. Cancel before it can activate content.
                    val start = android.os.SystemClock.uptimeMillis()
                    var first: android.graphics.Point? = null
                    for (eventType in listOf(android.view.MotionEvent.ACTION_DOWN, android.view.MotionEvent.ACTION_CANCEL)) {
                        val point = compose.runOnIdle {
                            val activity = compose.activity
                            assertPhysicalActivity(activity)
                            val decor = activity.window.decorView
                            assertTrue(activity.hasWindowFocus() && decor.hasWindowFocus())
                            val content = checkNotNull(activity.findViewById<android.view.View>(android.R.id.content))
                            val origin = IntArray(2).also(content::getLocationOnScreen)
                            val frame = android.graphics.Rect().also(decor::getWindowVisibleDisplayFrame)
                            assertTrue(frame.intersect(origin[0], origin[1], origin[0] + content.width, origin[1] + content.height))
                            assertTrue(frame.width() > 2 && frame.height() > 2)
                            android.graphics.Point(frame.left + 1, frame.top + 1)
                        }
                        if (first == null) first = point else assertEquals(first, point)
                        val event = android.view.MotionEvent.obtain(start, android.os.SystemClock.uptimeMillis(), eventType,
                            point.x.toFloat(), point.y.toFloat(), 0).apply { source = android.view.InputDevice.SOURCE_TOUCHSCREEN }
                        try { InstrumentationRegistry.getInstrumentation().sendPointerSync(event) } finally { event.recycle() }
                    }
                }
                compose.waitUntil(10_000) { input.inputMode == initial }
            } catch (cleanup: Throwable) {
                if (primary != null) primary.addSuppressed(cleanup) else throw cleanup
            }
        }
    }

    @Composable
    private fun TableViewport(mode: String, fontScale: Float, fixedDensity: Float? = null,
                              content: @Composable () -> Unit) {
        val base = LocalDensity.current
        val local = Density(fixedDensity ?: base.density, fontScale = fontScale)
        val input = androidx.compose.ui.platform.LocalInputModeManager.current
        SideEffect { observedDensity.set(local); keyboardOwner.set(input) }
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

    @Test fun tableJustBeyondPackedHeightRetainsSparseRowsAndFollowingLink() {
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
            visibleText("Oversize forms", 1f)
            val grid = compose.onNodeWithTag("compiled-table-grid", useUnmergedTree = true)
            grid.performScrollToIndex(0)
            compose.onNodeWithTag("compiled-table-cell-root-0", useUnmergedTree = true).assertExists()
            grid.performScrollToIndex(rowCount - 1)
            compose.onNodeWithTag("compiled-table-cell-root-1", useUnmergedTree = true).performScrollTo().assertIsDisplayed()
            compose.onNodeWithText("Table layout is unavailable at this size.", useUnmergedTree = true).assertDoesNotExist()
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

    private fun frequencyLinkEntry(last: Int): Entry = tableEntry("oversized-table-owner", "Frequency",
        Table(emptyList(), List(last + 1) { row -> listOf(
            Cell(listOf(Span("text", row.toString())), row == 0, 1, 1),
            Cell(listOf(Span("link", "word $row", target = "word-$row")), false, 1, 1)) }))

    @Test fun keyboardTraversesUncomposedRowBandsInOrder() {
        val mode = LearningStore.get(InstrumentationRegistry.getInstrumentation().targetContext).data.settings.darkMode
        val entry = frequencyLinkEntry(6999)
        val opened = mutableListOf<EntryLink>()
        val finalRow = 24
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        fun key(code: Int) {
            val start = android.os.SystemClock.uptimeMillis()
            for (action in listOf(android.view.KeyEvent.ACTION_DOWN, android.view.KeyEvent.ACTION_UP)) {
                compose.runOnIdle {
                    assertPhysicalActivity(compose.activity)
                    assertTrue(compose.activity.hasWindowFocus())
                }
                instrumentation.sendKeySync(android.view.KeyEvent(start, android.os.SystemClock.uptimeMillis(), action,
                    code, 0, 0, android.view.KeyCharacterMap.VIRTUAL_KEYBOARD, 0, 0, android.view.InputDevice.SOURCE_DPAD))
            }
            compose.waitForIdle()
        }
        fun focusDescription(): String = compose.onAllNodes(isFocused(), useUnmergedTree = true)
            .fetchSemanticsNodes().joinToString { focused ->
                generateSequence(focused) { it.parent }.take(8).joinToString(" > ") { node ->
                    val tag = node.config.getOrNull(SemanticsProperties.TestTag)
                    val text = node.config.getOrNull(SemanticsProperties.Text)?.joinToString { it.text }
                    "${node.id}(${tag.orEmpty()},${text.orEmpty()},click=${SemanticsActions.OnClick in node.config},${node.boundsInRoot})"
                }
            }
        fun link(row: Int) = compose.onNode(hasAnyAncestor(hasTestTag("compiled-table-cell-root-${row * 2 + 1}")) and
            hasClickAction() and SemanticsMatcher.keyIsDefined(SemanticsActions.RequestFocus), useUnmergedTree = true)
        try {
            compose.activityRule.scenario.onActivity { activity -> activity.setContent {
                TableViewport(mode, 1f, fixedDensity = 1f) {
                    EntryView(entry, false, {}, onLink = { opened += it },
                        settings = AppSettings(collapseOtherSections = false, collapseDetails = false))
                }
            } }
            compose.onNodeWithTag("entry-scroll").performScrollToNode(hasTestTag("compiled-table-grid"))
            link(finalRow).assertDoesNotExist()
            var reached = -1
            try {
                withReaderKeyboard {
                    link(0).performSemanticsAction(SemanticsActions.RequestFocus) { assertTrue(it()) }
                    for (row in 0 until finalRow) {
                        link(row).assertIsFocused()
                        key(android.view.KeyEvent.KEYCODE_DPAD_DOWN)
                        val actual = focusDescription()
                        instrumentation.sendStatus(0, android.os.Bundle().apply {
                            putString("stream", "\nTALL_DIRECTION from=$row to=${row + 1} focused=$actual\n")
                        })
                        link(row + 1).assertIsFocused()
                        reached = row + 1
                    }
                    link(finalRow).assertIsFocused().assertIsDisplayed()
                    key(android.view.KeyEvent.KEYCODE_DPAD_UP)
                    link(finalRow - 1).assertIsFocused()
                    key(android.view.KeyEvent.KEYCODE_DPAD_DOWN)
                    link(finalRow).assertIsFocused()
                    key(android.view.KeyEvent.KEYCODE_ENTER)
                    compose.runOnIdle { assertEquals(listOf(EntryLink("word-$finalRow")), opened) }
                    val selection = compose.onNode(hasAnyAncestor(hasTestTag("compiled-table-cell-root-${finalRow * 2 + 1}")) and
                        SemanticsMatcher.keyIsDefined(SemanticsActions.RequestFocus) and !hasClickAction(),
                        useUnmergedTree = true)
                    selection.performSemanticsAction(SemanticsActions.RequestFocus) { assertTrue(it()) }.assertIsFocused()
                }
            } finally {
                val count = compose.runOnIdle { opened.size }
                InstrumentationRegistry.getInstrumentation().sendStatus(0, android.os.Bundle().apply {
                    putString("stream", "\nTALL_KEYBOARD reached=$reached target=$finalRow activations=$count\n")
                })
            }
        } finally {
            compose.runOnIdle { compose.activity.setContent {} }
            compose.waitForIdle()
        }
    }

    @Test fun oversizedTableScrollsToMiddleAndFinalLinksWithGlobalCellSemantics() {
        val mode = LearningStore.get(InstrumentationRegistry.getInstrumentation().targetContext).data.settings.darkMode
        val last = 6999
        val entry = frequencyLinkEntry(last)
        val opened = mutableListOf<String>()
        val visit = EntryReadingState()
        val selectedVisit = mutableStateOf(visit)
        val visible = mutableStateOf(true)
        try {
            compose.activityRule.scenario.onActivity { activity -> activity.setContent {
                TableViewport(mode, 1f, fixedDensity = 1f) {
                    if (visible.value) EntryView(entry, false, {}, readingState = selectedVisit.value, onLink = { opened += it.target },
                        settings = AppSettings(collapseOtherSections = false, collapseDetails = false))
                }
            } }
            val tag = "compiled-table-grid"
            compose.onNodeWithTag("entry-scroll").performScrollToNode(hasTestTag(tag))
            val viewport = compose.onNodeWithTag(tag, useUnmergedTree = true)
            assertTrue(rawBounds(viewport).height <= rawBounds(compose.onNodeWithTag("entry-scroll")).height + 1f)
            val collection = viewport.fetchSemanticsNode().config[SemanticsProperties.CollectionInfo]
            assertEquals(last + 1, collection.rowCount)
            assertEquals(2, collection.columnCount)
            compose.onNodeWithText("word $last", useUnmergedTree = true).assertDoesNotExist()
            for (row in listOf(0, 3500, last, 1)) {
                viewport.performScrollToIndex(row)
                val cellTag = "compiled-table-cell-root-${row * 2 + 1}"
                val cell = compose.onNodeWithTag(cellTag, useUnmergedTree = true)
                val item = cell.fetchSemanticsNode().config[SemanticsProperties.CollectionItemInfo]
                assertEquals(row, item.rowIndex)
                assertEquals(1, item.columnIndex)
                val (link, layout) = visibleText("word $row", 1f)
                val count = compose.runOnIdle { opened.size }
                if (row == last) {
                    val action = compose.onNode(hasAnyAncestor(hasTestTag(cellTag)) and hasClickAction() and
                        SemanticsMatcher.keyIsDefined(SemanticsActions.RequestFocus), useUnmergedTree = true)
                    withReaderKeyboard {
                        action.performSemanticsAction(SemanticsActions.RequestFocus) { assertTrue(it()) }
                        action.assertIsFocused().performKeyInput { pressKey(androidx.compose.ui.input.key.Key.Enter) }
                    }
                } else {
                    link.performTouchInput { click(layout.getBoundingBox(0).center) }
                }
                compose.runOnIdle {
                    assertEquals(count + 1, opened.size)
                    assertEquals("word-$row", opened.last())
                }
                if (row == 3500) {
                    compose.runOnIdle { visible.value = false }
                    compose.waitForIdle()
                    compose.runOnIdle { visible.value = true }
                    link.assertIsDisplayed()
                    compose.runOnIdle { selectedVisit.value = EntryReadingState() }
                    compose.onNodeWithTag("entry-scroll").performScrollToNode(hasTestTag(tag))
                    compose.onNodeWithText("word 0", useUnmergedTree = true).assertExists()
                    compose.runOnIdle { selectedVisit.value = visit }
                    link.assertIsDisplayed()
                }
            }
            tapVisibleLink("After table", 1f)
            compose.runOnIdle { assertEquals("after-table", opened.last()) }
        } finally {
            compose.runOnIdle { compose.activity.setContent {} }
            compose.waitForIdle()
        }
    }

    @Test fun rowHeightsBeyondTheMinimumSwitchToTheScrollableGrid() {
        val mode = LearningStore.get(InstrumentationRegistry.getInstrumentation().targetContext).data.settings.darkMode
        val multiline = Cell(List(99) { if (it % 2 == 0) Span("text", "line") else Span("line_break", "") }, false, 1, 1)
        val last = 319
        val table = Table(emptyList(), List(last + 1) { row -> listOf(multiline,
            Cell(listOf(Span("link", "Row $row", target = "row-$row")), false, 1, 1)) })
        val entry = tableEntry("wrapped-owner", "Wrapped rows", table)
        try {
            compose.activityRule.scenario.onActivity { activity -> activity.setContent {
                TableViewport(mode, 1f, fixedDensity = 1f) {
                    EntryView(entry, false, {}, settings = AppSettings(collapseOtherSections = false, collapseDetails = false))
                }
            } }
            val grid = hasTestTag("compiled-table-grid") and SemanticsMatcher.keyIsDefined(SemanticsActions.ScrollToIndex)
            compose.onNodeWithTag("entry-scroll").performScrollToNode(grid)
            compose.onNode(grid, useUnmergedTree = true).performScrollToIndex(last)
            compose.onNodeWithText("Row $last", useUnmergedTree = true).performScrollTo().assertIsDisplayed()
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
