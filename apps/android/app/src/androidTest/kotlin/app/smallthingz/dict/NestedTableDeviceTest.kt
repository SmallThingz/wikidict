package app.smallthingz.dict

import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.graphics.toArgb
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

    @Test fun orderedCellBlocksRevealRealHeadingsAndRetainPaintActionsAndEmptyCells() {
        val headingLabel = "Cell heading العربية Ω"
        val inner = Table(listOf(Span("text", "Inner caption")), listOf(listOf(
            Cell(listOf(Span("text", "\uD80C\uDC00", classes = "Egyp", direction = "ltr")), false, 1, 1))),
            TableGeometry(border = 1, width = TableWidth(TableWidthUnit.Percent, 100)))
        val table = Table(emptyList(), listOf(listOf(
            Cell(emptyList(), true, 1, 1, "#800080", blocks = emptyList()),
            Cell(emptyList(), false, 1, 1, blocks = listOf(Block("paragraph", 0, listOf(Span("text", "before 1"))))),
            Cell(emptyList(), false, 1, 1, blocks = listOf(Block("table", 1, emptyList(), table = inner))),
            Cell(emptyList(), true, 1, 1, "#000000", blocks = listOf(
                Block("paragraph", 0, listOf(Span("text", "before target"))),
                Block("heading", 1, listOf(Span("text", headingLabel)), level = 4, anchor = "reference-1", anchorFallback = "Cell_ID"),
                Block("list_item", 1, listOf(Span("link", "Follow ordered", target = "ordered-target")), listPath = "ul"),
                Block("rule", 0, emptyList()),
                Block("paragraph", 0, listOf(Span("text", "after target", background = "#ffff00"))))))),
            TableGeometry(border = 1, cellPadding = 2))
        val entry = Entry("ordered", listOf(Span("link", "Jump to cell", target = "#reference-1")), "language", "English", "en",
            listOf(Section(1, "Meaning", listOf(Block("definition", 1, listOf(Span("text", "definition"))),
                Block("table", 0, emptyList(), table = table)), "Meaning")),
            listOf(Reference(1, 1, "", listOf(Span("text", "Reference fallback")))))
        val direction = mutableStateOf(LayoutDirection.Ltr)
        val mode = mutableStateOf("light")
        val request = mutableStateOf<EntryAnchorRequest?>(null)
        var consumed = 0
        var followed: String? = null
        fun tapLink(node: SemanticsNodeInteraction, target: String) {
            val layouts = mutableListOf<androidx.compose.ui.text.TextLayoutResult>()
            node.performSemanticsAction(SemanticsActions.GetTextLayoutResult) { it(layouts) }
            val layout = layouts.single()
            val annotation = layout.layoutInput.text.getLinkAnnotations(0, layout.layoutInput.text.length).single()
            assertEquals(target, (annotation.item as androidx.compose.ui.text.LinkAnnotation.Clickable).tag)
            node.performTouchInput { click(layout.getBoundingBox(annotation.start).center) }
        }
        try {
            compose.activityRule.scenario.onActivity { activity -> activity.setContent {
                androidx.compose.runtime.key(mode.value, direction.value) {
                    CompositionLocalProvider(LocalLayoutDirection provides direction.value) {
                        DictTheme(mode.value) { androidx.compose.material3.Surface(Modifier.fillMaxSize()) {
                            EntryView(entry, false, {}, onLink = { followed = it }, settings = AppSettings(collapseDetails = true),
                                anchorRequest = request.value, onAnchorConsumed = { consumed++; request.value = null })
                        } }
                    }
                }
            } }
            for (theme in listOf("light", "dark")) for (layoutDirection in listOf(LayoutDirection.Ltr, LayoutDirection.Rtl)) {
                compose.runOnIdle { mode.value = theme; direction.value = layoutDirection; request.value = null; followed = null }
                compose.waitForIdle()
                compose.onNodeWithText(headingLabel, useUnmergedTree = true).assertDoesNotExist()
                tapLink(compose.onNodeWithText("Jump to cell", useUnmergedTree = true), "#reference-1")
                val heading = compose.onNodeWithText(headingLabel, useUnmergedTree = true)
                heading.assertIsDisplayed().assert(SemanticsMatcher.keyIsDefined(SemanticsProperties.Heading))
                compose.onNodeWithText("Table is too large to display.").assertDoesNotExist()
                val horizontal = SemanticsMatcher("one parent grid scroll") { it.config.getOrNull(SemanticsProperties.HorizontalScrollAxisRange) != null }
                compose.onAllNodes(horizontal, useUnmergedTree = true).assertCountEquals(1)
                val headingText = heading.fetchSemanticsNode().config[SemanticsProperties.Text].single()
                assertTrue(headingText.spanStyles.any { it.item.color == androidx.compose.ui.graphics.Color.White })
                assertTrue(headingText.spanStyles.any { it.item.fontWeight == androidx.compose.ui.text.font.FontWeight.SemiBold })
                val before = compose.onNodeWithText("before target", useUnmergedTree = true).fetchSemanticsNode().boundsInRoot
                val afterNode = compose.onNodeWithText("after target", useUnmergedTree = true)
                val after = afterNode.fetchSemanticsNode().boundsInRoot
                assertTrue(before.top < heading.fetchSemanticsNode().boundsInRoot.top)
                assertTrue(heading.fetchSemanticsNode().boundsInRoot.bottom <= after.top)
                val afterText = afterNode.fetchSemanticsNode().config[SemanticsProperties.Text].single()
                assertTrue(afterText.spanStyles.any { it.item.background == androidx.compose.ui.graphics.Color.Yellow })
                assertTrue(afterText.spanStyles.any { it.item.color == androidx.compose.ui.graphics.Color.Black })
                val action = compose.onNodeWithText("Follow ordered", useUnmergedTree = true)
                action.performScrollTo().assertIsDisplayed()
                tapLink(action, "ordered-target")
                compose.runOnIdle { assertEquals("ordered-target", followed) }
                val empty = compose.onNodeWithTag("compiled-table-cell-root-0", useUnmergedTree = true)
                empty.performScrollTo().assertIsDisplayed().assertHasNoClickAction()
                assertNull(empty.fetchSemanticsNode().config.getOrNull(SemanticsProperties.Text))
                val paint = empty.captureToImage().asAndroidBitmap()
                try { assertEquals(0xff800080.toInt(), paint.getPixel(paint.width / 2, paint.height / 2)) }
                finally { paint.recycle() }
                val prior = consumed
                compose.runOnIdle { request.value = EntryAnchorRequest("other-owner", "#Cell_ID") }
                compose.waitForIdle()
                compose.runOnIdle { assertEquals(prior, consumed); request.value = EntryAnchorRequest(entry.key, "#Cell_ID") }
                heading.assertIsDisplayed()
                compose.runOnIdle { assertEquals(prior + 1, consumed) }
                empty.performScrollTo().assertIsDisplayed()
                compose.runOnIdle { request.value = EntryAnchorRequest(entry.key, "#Cell_ID") }
                heading.assertIsDisplayed()
                compose.runOnIdle { assertEquals(prior + 2, consumed) }
                val signs = if (android.os.Build.VERSION.SDK_INT >= 31)
                    SemanticsMatcher.expectValue(EgyptianShapedRunCount, 1) and hasAnyAncestor(hasTestTag("compiled-table-grid-root/2/block-0"))
                else hasText("\u2066\uD80C\uDC00\u2069")
                if (android.os.Build.VERSION.SDK_INT >= 31) compose.waitUntil(10000) {
                    compose.onAllNodes(signs, useUnmergedTree = true).fetchSemanticsNodes().size == 1
                }
                compose.onNode(signs, useUnmergedTree = true).performScrollTo().assertIsDisplayed()
            }
        } finally { compose.activityRule.scenario.onActivity { it.setContent {} } }
    }

    @Test fun nestedHeightFailureLabelRemainsReadableOnAuthoredParentPaint() {
        // Empty authored rows exceed the paired height capacity without composing thousands of cells.
        val child = Table(emptyList(), List(2000) { emptyList<Cell>() },
            TableGeometry(width = TableWidth(TableWidthUnit.Px, 10000)))
        val childMetrics = checkNotNull(tableRenderMetrics(child, 136, 10, 40, 1f))
        assertTrue(childMetrics.width in 1..TablePixelLimit)
        assertTrue(child.rows.size.toLong() * childMetrics.minRowHeight > checkNotNull(tableHeightLimit(childMetrics.width)))
        val mode = mutableStateOf("light")
        val background = mutableStateOf<String?>("#000000")
        var themeForeground = androidx.compose.ui.graphics.Color.Unspecified
        try {
            compose.activityRule.scenario.onActivity { activity -> activity.setContent {
                CompositionLocalProvider(androidx.compose.ui.platform.LocalDensity provides androidx.compose.ui.unit.Density(1f, 1f)) {
                    DictTheme(mode.value) { androidx.compose.material3.Surface(Modifier.fillMaxSize()) {
                        themeForeground = androidx.compose.material3.MaterialTheme.colorScheme.onSurface
                        val parent = Table(emptyList(), listOf(listOf(
                            Cell(emptyList(), false, 1, 1, background = background.value, nestedTable = child))))
                        CompiledTableView(parent, null) {}
                    } }
                }
            } }
            for (theme in listOf("light", "dark")) for (paint in listOf("#000000", "#ffffff", null)) {
                compose.runOnIdle { mode.value = theme; background.value = paint }
                compose.waitForIdle()
                compose.onNodeWithTag("compiled-table-grid", useUnmergedTree = true).assertExists()
                compose.onNodeWithTag("compiled-table-grid-root/0", useUnmergedTree = true).assertDoesNotExist()
                val error = compose.onNodeWithText("Table is too large to display.", useUnmergedTree = true)
                error.assertIsDisplayed().assertHasNoClickAction()
                    .assert(hasAnyAncestor(hasTestTag("compiled-table-cell-root-0")))
                val layouts = mutableListOf<androidx.compose.ui.text.TextLayoutResult>()
                error.performSemanticsAction(SemanticsActions.GetTextLayoutResult) { it(layouts) }
                val expected = when (paint) {
                    "#000000" -> androidx.compose.ui.graphics.Color.White
                    "#ffffff" -> androidx.compose.ui.graphics.Color.Black
                    else -> themeForeground
                }
                assertEquals(expected, layouts.single().layoutInput.style.color)
                if (paint != null) {
                    val image = error.captureToImage().asAndroidBitmap()
                    try {
                        val expectedPaint = if (paint == "#000000") android.graphics.Color.BLACK else android.graphics.Color.WHITE
                        var parentPaintVisible = false
                        for (y in 0 until image.height) for (x in 0 until image.width) {
                            if (image.getPixel(x, y) == expectedPaint) parentPaintVisible = true
                        }
                        assertTrue("Unavailable child must remain inside the authored parent paint", parentPaintVisible)
                    } finally { image.recycle() }
                }
            }
        } finally { compose.activityRule.scenario.onActivity { it.setContent {} } }
    }

    @Test fun orderedCellRulesKeepContrastAndPreserveThemeAndDeeperPaint() {
        val mode = mutableStateOf("light")
        val scenario = mutableStateOf("authored")
        val blocks = listOf(
            Block("paragraph", 0, listOf(Span("text", "Before rule"))),
            Block("rule", 0, emptyList()),
            Block("paragraph", 0, listOf(Span("text", "After rule"))))
        var expectedRule = androidx.compose.ui.graphics.Color.Unspecified
        var expectedBackground = androidx.compose.ui.graphics.Color.Unspecified
        try {
            compose.activityRule.scenario.onActivity { activity -> activity.setContent {
                CompositionLocalProvider(androidx.compose.ui.platform.LocalDensity provides androidx.compose.ui.unit.Density(1f, 1f)) {
                    DictTheme(mode.value) { androidx.compose.material3.Surface(Modifier.fillMaxSize()) {
                        val colors = androidx.compose.material3.MaterialTheme.colorScheme
                        val authored = if (mode.value == "light") "#cbcdbf" else "#465348"
                        val deeperPaint = if (mode.value == "light") "#000000" else "#ffffff"
                        val background = when (scenario.value) { "theme" -> null; "override" -> deeperPaint; else -> authored }
                        expectedBackground = background?.let { androidx.compose.ui.graphics.Color(checkNotNull(canonicalColorArgb(it))) } ?: colors.surface
                        expectedRule = when {
                            scenario.value == "theme" -> colors.outlineVariant
                            scenario.value == "override" -> if (mode.value == "light") androidx.compose.ui.graphics.Color.White else androidx.compose.ui.graphics.Color.Black
                            else -> if (mode.value == "light") androidx.compose.ui.graphics.Color.Black else androidx.compose.ui.graphics.Color.White
                        }
                        val content = Cell(emptyList(), false, 1, 1, background = background, blocks = blocks)
                        val cell = if (scenario.value == "override") Cell(emptyList(), false, 1, 1, background = authored,
                            nestedTable = Table(emptyList(), listOf(listOf(content)))) else content
                        CompiledTableView(Table(emptyList(), listOf(listOf(cell))), null) {}
                    } }
                }
            } }
            for (theme in listOf("light", "dark")) for (case in listOf("authored", "theme", "override")) {
                compose.runOnIdle { mode.value = theme; scenario.value = case }
                compose.waitForIdle()
                compose.onNodeWithText("Table is too large to display.").assertDoesNotExist()
                val tag = if (case == "override") "compiled-table-cell-root/0-0" else "compiled-table-cell-root-0"
                val cell = compose.onNodeWithTag(tag, useUnmergedTree = true).assertIsDisplayed()
                val bounds = cell.fetchSemanticsNode().boundsInRoot
                val before = compose.onNodeWithText("Before rule", useUnmergedTree = true).assertIsDisplayed().fetchSemanticsNode().boundsInRoot
                val after = compose.onNodeWithText("After rule", useUnmergedTree = true).assertIsDisplayed().fetchSemanticsNode().boundsInRoot
                val image = cell.captureToImage().asAndroidBitmap()
                try {
                    val top = kotlin.math.ceil(before.bottom - bounds.top).toInt().coerceIn(0, image.height)
                    val bottom = kotlin.math.floor(after.top - bounds.top).toInt().coerceIn(0, image.height)
                    assertTrue("Rule must remain between its ordered neighboring blocks", bottom > top)
                    val pixels = (top until bottom).map { image.getPixel(image.width / 2, it) }
                    assertTrue("Rule must remain visible on its effective cell paint", expectedRule.toArgb() in pixels)
                    assertTrue("Neighboring gap must retain the effective cell paint", expectedBackground.toArgb() in pixels)
                } finally { image.recycle() }
            }
        } finally { compose.activityRule.scenario.onActivity { it.setContent {} } }
    }
}
