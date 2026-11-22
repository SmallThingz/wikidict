package app.smallthingz.dict

import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.requiredWidth
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
import androidx.compose.ui.unit.dp
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import kotlin.math.roundToInt

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
                        CompiledTableView(table, null) { followed = it.target }
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
                    val signs = SemanticsMatcher.expectValue(EgyptianShapedRunCount, 1) and hasAnyAncestor(hasTestTag(gridTag))
                    compose.waitUntil(10000) {
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
                            EntryView(entry, false, {}, onLink = { followed = it.target }, settings = AppSettings(collapseDetails = true),
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
                val signs = SemanticsMatcher.expectValue(EgyptianShapedRunCount, 1) and hasAnyAncestor(hasTestTag("compiled-table-grid-root/2/block-0"))
                compose.waitUntil(10000) {
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
    @Test fun explicitParagraphCenterOverridesInheritedRightCellAcrossRtlAndResize() {
        val blocks = listOf(Block("paragraph", 0, listOf(Span("text", "first"))),
            Block("paragraph", 0, listOf(Span("text", "middle", fontScale = 2f)), textAlign = CellTextAlign.Center),
            Block("paragraph", 0, listOf(Span("link", "last", "last-target"))),
            Block("preformatted", 0, listOf(Span("text", "R")), textAlign = CellTextAlign.Right),
            Block("preformatted", 0, listOf(Span("text", "C")), textAlign = CellTextAlign.Center))
        val table = Table(emptyList(), listOf(listOf(Cell(emptyList(), false, 2, 1, background = "#b4cdcd", blocks = blocks,
            style = CellStyle(textAlign = CellTextAlign.Right)))),
            TableGeometry(border = 2, cellSpacing = 0, cellPadding = 4, width = TableWidth(TableWidthUnit.Px, 250)))
        val direction = mutableStateOf(LayoutDirection.Ltr)
        val width = mutableStateOf(280)
        var followed: String? = null
        try {
            compose.activityRule.scenario.onActivity { activity -> activity.setContent {
                CompositionLocalProvider(LocalLayoutDirection provides direction.value) {
                    DictTheme("light") { androidx.compose.foundation.layout.Box(
                        Modifier.requiredWidth(width.value.dp)) { CompiledTableView(table, null) { followed = it.target } } }
                }
            } }
            for (widthDp in listOf(260, 280, 320)) for (rtl in listOf(LayoutDirection.Ltr, LayoutDirection.Rtl)) {
                compose.runOnIdle { width.value = widthDp; direction.value = rtl; followed = null }
                compose.waitForIdle()
                for ((label, expected) in listOf("first" to androidx.compose.ui.text.style.TextAlign.Right,
                        "middle" to androidx.compose.ui.text.style.TextAlign.Center, "last" to androidx.compose.ui.text.style.TextAlign.Right,
                        "R" to androidx.compose.ui.text.style.TextAlign.Right, "C" to androidx.compose.ui.text.style.TextAlign.Center)) {
                    val node = compose.onNodeWithText(label, useUnmergedTree = true)
                    node.assertIsDisplayed()
                    val layouts = mutableListOf<androidx.compose.ui.text.TextLayoutResult>()
                    node.performSemanticsAction(SemanticsActions.GetTextLayoutResult) { it(layouts) }
                    val layout = layouts.single()
                    assertEquals(expected, layout.layoutInput.style.textAlign)
                    if (label == "R" || label == "C") {
                        val cell = compose.onNodeWithTag("compiled-table-cell-root-0", useUnmergedTree = true).fetchSemanticsNode().boundsInRoot
                        assertTrue("Short preformatted text must receive viewport width, not only its intrinsic glyph width",
                            node.fetchSemanticsNode().boundsInRoot.width > cell.width / 2f)
                    }
                    if (expected == androidx.compose.ui.text.style.TextAlign.Center)
                        assertEquals(layout.size.width / 2f, (layout.getLineLeft(0) + layout.getLineRight(0)) / 2f, 1f)
                    else assertEquals(layout.size.width.toFloat(), layout.getLineRight(0), 1f)
                    if (label == "last") {
                        val link = layout.layoutInput.text.getLinkAnnotations(0, layout.layoutInput.text.length).single()
                        node.performTouchInput { click(layout.getBoundingBox(link.start).center) }
                        compose.runOnIdle { assertEquals("last-target", followed) }
                    }
                }
            }
        } finally { compose.activityRule.scenario.onActivity { it.setContent {} } }
    }

    @Test fun sectionHeadingCompanionKeepsExplicitPhysicalAlignmentAndItsLink() {
        val align = mutableStateOf(CellTextAlign.Center)
        val direction = mutableStateOf(LayoutDirection.Ltr)
        var followed: String? = null
        try {
            compose.activityRule.scenario.onActivity { activity -> activity.setContent {
                val rich = Block("heading", 0, listOf(Span("link", "Pronunciation", "pronunciation-target")),
                    level = 3, textAlign = align.value)
                val entry = Entry("Aligned heading", emptyList(), "language", "English", "en",
                    listOf(Section(3, "Pronunciation", listOf(rich, Block("paragraph", 0, listOf(Span("text", "Body")))))), emptyList())
                CompositionLocalProvider(LocalLayoutDirection provides direction.value) {
                    DictTheme("light") { EntryView(entry, false, {}, onLink = { followed = it.target }) }
                }
            } }
            for (side in listOf(CellTextAlign.Center, CellTextAlign.Right)) for (rtl in listOf(LayoutDirection.Ltr, LayoutDirection.Rtl)) {
                compose.runOnIdle { align.value = side; direction.value = rtl; followed = null }
                compose.waitForIdle()
                val node = compose.onNodeWithText("Pronunciation", useUnmergedTree = true)
                val layouts = mutableListOf<androidx.compose.ui.text.TextLayoutResult>()
                node.performSemanticsAction(SemanticsActions.GetTextLayoutResult) { it(layouts) }
                val layout = layouts.single()
                assertEquals(if (side == CellTextAlign.Center) androidx.compose.ui.text.style.TextAlign.Center else androidx.compose.ui.text.style.TextAlign.Right,
                    layout.layoutInput.style.textAlign)
                if (side == CellTextAlign.Center) assertEquals(layout.size.width / 2f, (layout.getLineLeft(0) + layout.getLineRight(0)) / 2f, 1f)
                else assertEquals(layout.size.width.toFloat(), layout.getLineRight(0), 1f)
                val link = layout.layoutInput.text.getLinkAnnotations(0, layout.layoutInput.text.length).single()
                node.performTouchInput { click(layout.getBoundingBox(link.start).center) }
                compose.runOnIdle { assertEquals("pronunciation-target", followed) }
            }
        } finally { compose.activityRule.scenario.onActivity { it.setContent {} } }
    }

    @Test fun tableOnlySectionKeepsFollowingNativeHeadingFoldAndListActions() {
        val px0 = StyleLength(StyleLengthUnit.Px, 0f)
        val table = Table(emptyList(), List(4) { listOf(Cell(listOf(Span("text", "number")), false, 1, 1)) },
            TableGeometry(width = TableWidth(TableWidthUnit.Px, 100)),
            TableStyle(margins = StyleEdges(px0, px0, px0, StyleLength(StyleLengthUnit.Px, 20f)), floatSide = TableFloatSide.Right))
        val entry = Entry("dwa control", emptyList(), "language", "poloniera", "pl", listOf(
            Section(2, "Poloniera", listOf(Block("table", 0, emptyList(), table = table))),
            Section(3, "Ahoskera", listOf(
                Block("list_item", 2, listOf(Span("link", "IPA", "IPA"), Span("text", ": /dva/")), listPath = ":*"),
                Block("list_item", 2, listOf(Span("text", "second pronunciation")), listPath = ":*"))),
            Section(3, "Adjektiboa", listOf(Block("indent", 1, listOf(Span("text", "number meaning")), listPath = ":")))), emptyList())
        var followed: String? = null
        var activityRoot: android.view.View? = null
        fun nativeView(): NativeFloatTextView {
            fun collect(view: android.view.View): List<NativeFloatTextView> = when (view) {
                is NativeFloatTextView -> listOf(view)
                is android.view.ViewGroup -> (0 until view.childCount).flatMap { collect(view.getChildAt(it)) }
                else -> emptyList()
            }
            return collect(checkNotNull(activityRoot)).single()
        }
        fun action(label: String) {
            compose.runOnIdle {
                val view = nativeView()
                val provider = view.accessibilityNodeProvider
                val id = (0 until 32).single { candidate ->
                    val info = provider.createAccessibilityNodeInfo(candidate)
                    info != null && info.text?.toString() == label && info.isClickable
                }
                assertTrue(provider.performAction(id, android.view.accessibility.AccessibilityNodeInfo.ACTION_CLICK, null))
            }
            compose.waitForIdle()
        }
        try {
            compose.activityRule.scenario.onActivity { activity -> activityRoot = activity.window.decorView; activity.setContent {
                DictTheme("light") { EntryView(entry, false, {}, onLink = { followed = it.target }, settings = AppSettings(collapseDetails = false)) }
            } }
            compose.waitForIdle()
            compose.runOnIdle {
                val text = nativeView().logicalText.toString()
                assertTrue(text.contains("Ahoskera") && text.contains("second pronunciation") && text.contains("number meaning"))
                assertFalse(text.contains(":*")) // Source list path is a marker gutter, never invented body text.
            }
            action("IPA")
            compose.runOnIdle { assertEquals("IPA", followed) }
            action("Collapse Ahoskera")
            compose.runOnIdle { assertFalse(nativeView().logicalText.contains("second pronunciation")) }
            action("Expand Ahoskera")
            compose.runOnIdle { assertTrue(nativeView().logicalText.contains("second pronunciation")) }
        } finally { compose.activityRule.scenario.onActivity { it.setContent {} } }
    }

    @Test fun deepTwentyAndThirtyTwoTablesKeepOriginalNativeLinkThroughResizeAndOneScrollOwner() {
        val label = "Deep link"
        val original = Span("link", label, target = "deep-original-target", foreground = "#0000ff",
            fontScale = 16f, fontScaleBasis = FontScaleBasis.CssPx,
            fontFamily = ContainerFontFamily.SansSerif,
            inlineStyle = InlineTextStyle(wrap = TextWrap.Normal))
        fun chain(depth: Int): Table {
            var result = Table(emptyList(), listOf(listOf(Cell(listOf(original), false, 1, 1,
                background = "#ffffff"))), TableGeometry(border = 0, cellSpacing = 0, cellPadding = 1,
                width = TableWidth(TableWidthUnit.Px, 240)))
            repeat(depth - 1) {
                result = Table(emptyList(), listOf(listOf(Cell(emptyList(), false, 1, 1,
                    nestedTable = result))), TableGeometry(border = 0, cellSpacing = 0, cellPadding = 1))
            }
            return result
        }
        val sources = listOf(20, 32).associateWith(::chain)
        val depth = mutableStateOf(20)
        val width = mutableStateOf(180)
        val calls = mutableListOf<EntryLink>()
        var activityRoot: android.view.View? = null
        fun nativeOwner(): NativeFloatTextView {
            val views = mutableListOf<NativeFloatTextView>()
            fun visit(view: android.view.View) {
                if (view is NativeFloatTextView && view.isShown &&
                    view.currentMeasuredGeometry?.text?.toString() == label) views += view
                if (view is android.view.ViewGroup) repeat(view.childCount) { visit(view.getChildAt(it)) }
            }
            visit(checkNotNull(activityRoot))
            return views.single()
        }
        val horizontal = SemanticsMatcher("one deep-table scroll owner") {
            it.config.getOrNull(SemanticsProperties.HorizontalScrollAxisRange) != null
        }
        var failure: Throwable? = null
        try {
            compose.activityRule.scenario.onActivity { activity ->
                activityRoot = activity.window.decorView
                activity.setContent {
                    CompositionLocalProvider(LocalLayoutDirection provides LayoutDirection.Ltr,
                        androidx.compose.ui.platform.LocalDensity provides androidx.compose.ui.unit.Density(1f, 1f)) {
                        DictTheme("light") {
                            androidx.compose.foundation.layout.Box(Modifier.fillMaxSize(),
                                contentAlignment = androidx.compose.ui.Alignment.Center) {
                                androidx.compose.foundation.layout.Box(Modifier.requiredWidth(width.value.dp)) {
                                    CompiledTableView(sources.getValue(depth.value), null) { calls += it }
                                }
                            }
                        }
                    }
                }
            }
            for (levels in listOf(20, 32)) {
                val source = sources.getValue(levels)
                // The leaf grid is 240px wide and at least 40px tall. Every enclosing
                // one-cell grid adds precisely its authored 1px padding on both sides.
                val expectedWidth = 240 + 2 * (levels - 1)
                val expectedHeight = 40 + 2 * (levels - 1)
                assertEquals(expectedWidth, checkNotNull(tableRenderMetrics(source, 136, 10, 40, 1f)).width)
                var leaf = source
                repeat(levels - 1) { leaf = checkNotNull(leaf.rows.single().single().nestedTable) }
                assertSame(original, leaf.rows.single().single().spans.single())
                for (viewport in listOf(180, 360, 180)) {
                    compose.runOnIdle { depth.value = levels; width.value = viewport }
                    compose.waitForIdle()
                    compose.onAllNodesWithText("unavailable", substring = true, ignoreCase = true).assertCountEquals(0)
                    compose.onAllNodesWithText("Table is too large to display.").assertCountEquals(0)
                    compose.onAllNodes(horizontal, useUnmergedTree = true).assertCountEquals(1)
                    val scroll = compose.onNode(horizontal, useUnmergedTree = true)
                    fun scrollValue() = scroll.fetchSemanticsNode().config[SemanticsProperties.HorizontalScrollAxisRange].value()
                    val overflow = (expectedWidth - viewport).coerceAtLeast(0).toFloat()
                    assertEquals(overflow, scroll.fetchSemanticsNode().config[SemanticsProperties.HorizontalScrollAxisRange].maxValue(), 0f)
                    val carried = scrollValue()
                    if (carried != 0f) {
                        scroll.performSemanticsAction(SemanticsActions.ScrollBy) { assertTrue(it(-carried, 0f)) }
                        compose.waitForIdle()
                    }
                    assertEquals(0f, scrollValue(), 0f)
                    if (overflow > 0f) {
                        scroll.performSemanticsAction(SemanticsActions.ScrollBy) { assertTrue(it(overflow, 0f)) }
                        compose.waitForIdle()
                        assertEquals(overflow, scrollValue(), 0f)
                        scroll.performSemanticsAction(SemanticsActions.ScrollBy) { assertTrue(it(-overflow, 0f)) }
                        compose.waitForIdle()
                        assertEquals(0f, scrollValue(), 0f)
                    }
                    var path = "root"
                    var previous: androidx.compose.ui.unit.DpRect? = null
                    repeat(levels) { level ->
                        val grid = compose.onNodeWithTag(if (level == 0) "compiled-table-grid" else "compiled-table-grid-$path",
                            useUnmergedTree = true).assertExists()
                        val info = grid.fetchSemanticsNode().config[SemanticsProperties.CollectionInfo]
                        assertEquals(1, info.rowCount); assertEquals(1, info.columnCount)
                        val bounds = grid.getUnclippedBoundsInRoot()
                        assertEquals((expectedWidth - 2 * level).toFloat(), (bounds.right - bounds.left).value, 0f)
                        assertEquals((expectedHeight - 2 * level).toFloat(), (bounds.bottom - bounds.top).value, 0f)
                        previous?.let { parent ->
                            assertEquals(parent.left.value + 1f, bounds.left.value, 0f)
                            assertEquals(parent.top.value + 1f, bounds.top.value, 0f)
                        }
                        val cell = compose.onNodeWithTag("compiled-table-cell-$path-0", useUnmergedTree = true)
                            .fetchSemanticsNode().config[SemanticsProperties.CollectionItemInfo]
                        assertEquals(0, cell.rowIndex); assertEquals(0, cell.columnIndex)
                        assertEquals(1, cell.rowSpan); assertEquals(1, cell.columnSpan)
                        previous = bounds
                        if (level + 1 < levels) path += "/0"
                    }
                    val painted = compose.onNodeWithTag("compiled-table-cell-$path-0", useUnmergedTree = true)
                        .assertIsDisplayed().captureToImage().asAndroidBitmap()
                    try {
                        var blueInk = false
                        var whiteBackground = false
                        for (y in 0 until painted.height) for (x in 0 until painted.width) {
                            val pixel = painted.getPixel(x, y)
                            val red = android.graphics.Color.red(pixel)
                            val green = android.graphics.Color.green(pixel)
                            val blue = android.graphics.Color.blue(pixel)
                            if (android.graphics.Color.alpha(pixel) > 0 && blue > red && red == green) blueInk = true
                            if (pixel == android.graphics.Color.WHITE) whiteBackground = true
                        }
                        assertTrue("The deepest original blue link must actually paint on its white cell", blueInk && whiteBackground)
                    } finally { painted.recycle() }
                    compose.runOnIdle {
                        val view = nativeOwner()
                        val geometry = checkNotNull(view.currentMeasuredGeometry)
                        assertEquals(label, view.logicalText.toString())
                        // The chosen 16px one-line source fits the leaf's independent 40px
                        // minimum after its two 1px insets; larger content must not be hidden.
                        assertTrue(view.measuredHeight + 2 <= 40)
                        val node = geometry.nodes.single()
                        assertEquals(FloatInteractionKind.LINK, node.kind)
                        assertEquals(0, node.start); assertEquals(label.length, node.end)
                        assertEquals(label, node.label.toString())
                        assertEquals(geometry.rectsForRange(0, label.length), node.bounds)
                        val hit = node.bounds.first { !it.isEmpty }
                        assertEquals(node.id, geometry.interactionNodeAt(hit.centerX(), hit.centerY())?.id)
                        val location = IntArray(2); view.getLocationOnScreen(location)
                        val expectedScreen = android.graphics.RectF().apply {
                            node.bounds.forEach(::union)
                            offset(location[0].toFloat() + view.paddingLeft, location[1].toFloat() + view.paddingTop)
                        }.let { android.graphics.Rect().also(it::roundOut) }
                        val visible = android.graphics.Rect()
                        assertTrue(view.getGlobalVisibleRect(visible))
                        assertTrue("The complete action must remain in the owned viewport", visible.contains(expectedScreen))
                        val provider = view.accessibilityNodeProvider
                        val ax = checkNotNull(provider.createAccessibilityNodeInfo(node.id))
                        try {
                            assertTrue(ax.isClickable && ax.isVisibleToUser)
                            assertEquals(label, ax.text.toString())
                            val actualScreen = android.graphics.Rect(); ax.getBoundsInScreen(actualScreen)
                            assertEquals(expectedScreen, actualScreen)
                            assertTrue(ax.actionList.any { it.id == android.view.accessibility.AccessibilityNodeInfo.ACTION_CLICK })
                        } finally { ax.recycle() }
                        val before = calls.size
                        view.setSelection(0, label.length)
                        assertEquals(label, view.selectedTextForCopy())
                        assertTrue(view.performAccessibilityAction(android.view.accessibility.AccessibilityNodeInfo.ACTION_SET_SELECTION, null))
                        assertNull(view.selectedTextForCopy())
                        assertEquals(before, calls.size)
                        assertTrue(provider.performAction(node.id, android.view.accessibility.AccessibilityNodeInfo.ACTION_CLICK, null))
                        assertEquals(before + 1, calls.size)
                        assertEquals(EntryLink("deep-original-target"), calls.last())
                    }
                }
            }
            compose.runOnIdle { assertEquals(6, calls.size) }
        } catch (error: Throwable) {
            failure = error
            throw error
        } finally {
            try { compose.activityRule.scenario.onActivity { it.setContent {} } }
            catch (cleanup: Throwable) {
                val primary = failure
                if (primary == null) throw cleanup
                if (cleanup !== primary) primary.addSuppressed(cleanup)
            }
        }
    }

    @Test fun inheritedCellInkTracksActualEnclosingPaintWithoutChangingNestedAutoOrLinks() {
        // Controlled typography/backdrops. This checks the symbolic cell policy, not
        // a captured page palette. Every phase renders the same original leaf objects.
        fun text(value: String, foreground: String? = null) = Span("text", value,
            foreground = foreground, bold = true, fontScale = 18f,
            fontScaleBasis = FontScaleBasis.CssPx, fontFamily = ContainerFontFamily.SansSerif)
        val ordinary = text("MARK ")
        val explicit = text("RGB ", "#ff0000")
        val ownBackground = text("OWN ").copy(background = "#ffffff")
        val link = text("LINK").copy(kind = "link", target = "original-cell-link", targetFragment = "source-fragment")
        val boxText = text("BOX ")
        val boxLink = text("HELP").copy(kind = "link", target = "original-box-link")
        val zero = StyleLength(StyleLengthUnit.Px, 0f)
        val none = InlineBoxBorderEdges(InlineBoxBorderEdge.None, InlineBoxBorderEdge.None,
            InlineBoxBorderEdge.None, InlineBoxBorderEdge.None)
        val box = text("").copy(inlineBoxGroup = InlineBoxGroup(StyleEdges(zero, zero, zero, zero),
            none, spans = listOf(boxText, boxLink)))
        val rubyText = text("BASE")
        val rubyOwner = RubyOwner(InlineFontSnapshot(fontScale = 18f,
            fontScaleBasis = FontScaleBasis.CssPx, bold = true,
            fontFamily = ContainerFontFamily.SansSerif), background = "#ffffff")
        val ruby = Span("text", "", ruby = Ruby(listOf(RubySegment(emptyList(),
            listOf(RubyBase(rubyOwner, emptyList(), listOf(rubyText))), emptyList()))))
        val outerText = text("OUTER")
        val innerText = text("INHERIT")
        val autoText = text("AUTO")
        val rootCaption = text("ROOT CAPTION")
        val nestedCaption = text("NESTED CAPTION")
        val inherit = CellStyle(foreground = CellForeground.Inherit)
        val inner = Table(listOf(nestedCaption), listOf(listOf(
            Cell(listOf(innerText), false, 1, 1, background = "#a0a0a0", style = inherit),
            Cell(listOf(autoText), false, 1, 1, background = "#a0a0a0"))),
            TableGeometry(border = 0, cellSpacing = 2, cellPadding = 4,
                width = TableWidth(TableWidthUnit.Percent, 100)),
            style = TableStyle(background = "#ffffff"))
        fun source(background: String, marked: Boolean) = Table(listOf(rootCaption), listOf(
            listOf(Cell(listOf(ordinary, explicit, ownBackground, link), false, 1, 1, background = "#000000", style = inherit)),
            listOf(Cell(listOf(box, text(" "), ruby), false, 1, 1, background = "#000000", style = inherit)),
            listOf(Cell(emptyList(), false, 1, 1, background = background,
                blocks = listOf(Block("paragraph", 0, listOf(outerText)),
                    Block("table", 0, emptyList(), table = inner)),
                style = if (marked) inherit else null))),
            TableGeometry(border = 0, cellSpacing = 2, cellPadding = 4,
                width = TableWidth(TableWidthUnit.Percent, 100)),
            style = TableStyle(background = "#c0c0c0"))
        val sources = listOf(source("#000000", false), source("#ffffff", false), source("#000000", true))
        data class Phase(val source: Int, val ink: Int, val width: Int, val outerInk: Int)
        val green = android.graphics.Color.rgb(0, 192, 64)
        val purple = android.graphics.Color.rgb(160, 0, 192)
        val phases = listOf(
            Phase(0, green, 340, android.graphics.Color.WHITE),
            Phase(0, purple, 340, android.graphics.Color.WHITE), // Same source, live enclosing ink only.
            Phase(1, purple, 280, android.graphics.Color.BLACK),
            Phase(2, purple, 280, purple), // Marked outer cell changes the actual inherited nested ink.
            Phase(2, green, 340, green),
            Phase(0, green, 340, android.graphics.Color.WHITE))
        val phase = mutableStateOf(phases.first())
        val calls = mutableListOf<EntryLink>()
        var activityRoot: android.view.View? = null
        fun owner(value: String): NativeFloatTextView {
            val found = mutableListOf<NativeFloatTextView>()
            fun visit(view: android.view.View) {
                if (view is NativeFloatTextView && view.isShown &&
                    view.currentMeasuredGeometry?.text?.toString() == value) found += view
                if (view is android.view.ViewGroup) repeat(view.childCount) { visit(view.getChildAt(it)) }
            }
            visit(checkNotNull(activityRoot))
            return found.single()
        }
        data class Raster(val bitmap: android.graphics.Bitmap, val left: Int, val top: Int)
        fun capture(): Raster {
            val interaction = compose.onRoot(useUnmergedTree = true)
            val node = interaction.fetchSemanticsNode()
            val bounds = node.boundsInRoot
            val root = (checkNotNull(node.root) as androidx.compose.ui.platform.ViewRootForTest).view
            val bitmap = interaction.captureToImage().asAndroidBitmap()
            try {
                val location = IntArray(2)
                compose.runOnIdle { root.getLocationOnScreen(location) }
                assertEquals(bounds.right.roundToInt() - bounds.left.roundToInt(), bitmap.width)
                assertEquals(bounds.bottom.roundToInt() - bounds.top.roundToInt(), bitmap.height)
                return Raster(bitmap, location[0] + bounds.left.roundToInt(), location[1] + bounds.top.roundToInt())
            } catch (error: Throwable) { bitmap.recycle(); throw error }
        }
        fun assertInk(raster: Raster, value: String, start: Int, length: Int, expected: Int) {
            val bounds = mutableListOf<android.graphics.RectF>()
            compose.runOnIdle {
                val view = owner(value)
                val geometry = checkNotNull(view.currentMeasuredGeometry)
                val location = IntArray(2); view.getLocationOnScreen(location)
                bounds += geometry.characterRects(start, length).map { rect ->
                    android.graphics.RectF(checkNotNull(rect)).apply {
                        offset((location[0] + view.paddingLeft - raster.left).toFloat(),
                            (location[1] + view.paddingTop - raster.top).toFloat())
                    }
                }
                assertEquals(value, view.logicalText.toString())
                assertFalse(bounds.isEmpty())
            }
            var exactInk = 0
            for (rect in bounds) {
                val left = kotlin.math.floor(rect.left.toDouble()).toInt()
                val top = kotlin.math.floor(rect.top.toDouble()).toInt()
                val right = kotlin.math.ceil(rect.right.toDouble()).toInt()
                val bottom = kotlin.math.ceil(rect.bottom.toDouble()).toInt()
                assertTrue("Original glyph range must be inside the captured root", left >= 0 && top >= 0 &&
                    right <= raster.bitmap.width && bottom <= raster.bitmap.height)
                for (y in top until bottom) for (x in left until right)
                    if (raster.bitmap.getPixel(x, y) == expected) exactInk++
            }
            assertTrue("$value[$start,${start + length}) must actually paint its expected foreground", exactInk >= 4)
        }
        var failure: Throwable? = null
        try {
            compose.activityRule.scenario.onActivity { activity ->
                activityRoot = activity.window.decorView
                activity.setContent {
                    CompositionLocalProvider(LocalLayoutDirection provides LayoutDirection.Ltr,
                        androidx.compose.ui.platform.LocalDensity provides androidx.compose.ui.unit.Density(1f, 1f)) {
                        DictTheme("light") {
                            val ink = androidx.compose.ui.graphics.Color(phase.value.ink)
                            androidx.compose.material3.Surface(Modifier.fillMaxSize(),
                                color = androidx.compose.ui.graphics.Color(0xffe0e0e0), contentColor = ink) {
                                androidx.compose.material3.ProvideTextStyle(
                                    androidx.compose.material3.MaterialTheme.typography.bodyLarge.copy(color = ink)) {
                                    androidx.compose.foundation.layout.Box(Modifier.requiredWidth(phase.value.width.dp)) {
                                        CompiledTableView(sources[phase.value.source], null) { calls += it }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            for (current in phases) {
                compose.runOnIdle { phase.value = current }
                compose.waitForIdle()
                compose.onAllNodesWithText("unavailable", substring = true, ignoreCase = true).assertCountEquals(0)
                compose.onAllNodesWithText("Table is too large to display.").assertCountEquals(0)
                compose.onNodeWithTag("compiled-table-grid", useUnmergedTree = true).assertIsDisplayed()
                val raster = capture()
                try {
                    assertInk(raster, rootCaption.text, 0, rootCaption.text.length, current.ink)
                    assertInk(raster, "MARK RGB OWN LINK", 0, 4, current.ink)
                    assertInk(raster, "MARK RGB OWN LINK", 5, 3, android.graphics.Color.RED)
                    assertInk(raster, "MARK RGB OWN LINK", 9, 3, android.graphics.Color.BLACK)
                    assertInk(raster, "MARK RGB OWN LINK", 13, 4, android.graphics.Color.WHITE)
                    assertInk(raster, "BOX HELP BASE", 0, 3, current.ink)
                    assertInk(raster, "BOX HELP BASE", 4, 4, android.graphics.Color.WHITE)
                    // A real RubyOwner background owns its own contrast, independently
                    // of the marked cell's plain ink and of direct Span.background.
                    assertInk(raster, "BOX HELP BASE", 9, 4, android.graphics.Color.BLACK)
                    assertInk(raster, outerText.text, 0, outerText.text.length, current.outerInk)
                    assertInk(raster, nestedCaption.text, 0, nestedCaption.text.length, current.outerInk)
                    assertInk(raster, innerText.text, 0, innerText.text.length, current.outerInk)
                    assertInk(raster, autoText.text, 0, autoText.text.length, android.graphics.Color.BLACK)
                } finally { raster.bitmap.recycle() }
                compose.runOnIdle {
                    val source = sources[current.source]
                    assertSame(rootCaption, source.caption.single())
                    assertSame(ordinary, source.rows[0].single().spans[0])
                    assertSame(ownBackground, source.rows[0].single().spans[2])
                    assertSame(link, source.rows[0].single().spans[3])
                    assertSame(box, source.rows[1].single().spans[0])
                    assertSame(ruby, source.rows[1].single().spans[2])
                    val base = ruby.ruby!!.segments.single().bases.single()
                    assertSame(rubyOwner, base.owner)
                    assertSame(rubyText, base.spans.single())
                    assertSame(inner, source.rows[2].single().blocks!![1].table)
                    assertSame(innerText, inner.rows.single()[0].spans.single())
                    assertNull(inner.rows.single()[1].style) // No inherited policy marker on the auto child.
                    for ((value, original) in listOf("MARK RGB OWN LINK" to link, "BOX HELP BASE" to boxLink)) {
                        val view = owner(value)
                        val geometry = checkNotNull(view.currentMeasuredGeometry)
                        val action = geometry.nodes.single { it.kind == FloatInteractionKind.LINK }
                        assertEquals(original.text, action.label.toString())
                        assertEquals(original.text, value.substring(action.start, action.end))
                        val provider = view.accessibilityNodeProvider
                        val ax = checkNotNull(provider.createAccessibilityNodeInfo(action.id))
                        try {
                            assertEquals(original.text, ax.text.toString())
                            assertTrue(ax.isClickable && ax.isVisibleToUser)
                        } finally { ax.recycle() }
                        view.setSelection(0, value.length)
                        assertEquals(value, view.selectedTextForCopy())
                        assertTrue(view.performAccessibilityAction(
                            android.view.accessibility.AccessibilityNodeInfo.ACTION_SET_SELECTION, null))
                        val before = calls.size
                        assertTrue(provider.performAction(action.id,
                            android.view.accessibility.AccessibilityNodeInfo.ACTION_CLICK, null))
                        assertEquals(before + 1, calls.size)
                        assertEquals(original.entryLink(), calls.last())
                    }
                }
            }
            compose.runOnIdle { assertEquals(phases.size * 2, calls.size) }
        } catch (error: Throwable) { failure = error; throw error }
        finally {
            try { compose.activityRule.scenario.onActivity { it.setContent {} } }
            catch (cleanup: Throwable) {
                val primary = failure
                if (primary == null) throw cleanup
                if (cleanup !== primary) primary.addSuppressed(cleanup)
            }
        }
    }

}
