package app.smallthingz.dict

import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.width
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Typography
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.layout.FirstBaseline
import androidx.compose.ui.layout.LastBaseline
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalLayoutDirection
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.test.*
import androidx.compose.ui.text.TextLayoutResult
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.intl.LocaleList
import androidx.compose.ui.text.style.ResolvedTextDirection
import androidx.compose.ui.text.style.TextDirection
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import kotlin.math.ceil
import kotlin.math.roundToInt

/** API03 device obligations. Source only: not compiled, installed, or executed. */
class TableBlockViewportDeviceTest {
    @get:Rule val compose = createPhysicalComposeRule()
    private fun px(value: Float) = StyleLength(StyleLengthUnit.Px, value)
    private fun edges(value: Float) = StyleEdges(px(value), px(value), px(value), px(value))
    private fun zeroMargin() = ContainerMargin.Length(px(0f))
    private fun policy(
        containingDirection: TableContainingDirection = TableContainingDirection.Ltr,
        gridDirection: TableContainingDirection = TableContainingDirection.Ltr,
    ) = TableBlockViewport(639,
        TableStyle(width = StyleWidth(StyleWidthUnit.Percent, 70f),
            marginValues = ContainerMargins(zeroMargin(), ContainerMargin.Auto, zeroMargin(), ContainerMargin.Auto),
            containingDirection = containingDirection),
        ContainerBoxSizing.ContentBox, StyleWidth(StyleWidthUnit.Percent, 100f),
        TableStyle(collapse = TableCollapse.Collapse), gridDirection, language = "ru")

    private fun cell(label: String, minimum: Float = 150f) = Cell(
        listOf(Span("link", label, "Viewport-$label")), false, 1, 1, background = "#0000ff",
        style = CellStyle(border = StyleBorder.None, padding = edges(0f),
            textAlign = CellTextAlign.Center, minWidth = px(minimum)))

    private fun table(value: TableBlockViewport = policy(), minimum: Float = 150f,
        caption: List<Span> = emptyList(), rows: List<List<Cell>> = listOf(listOf(cell("Start", minimum), cell("End", minimum)))) =
        Table(caption, rows, style = TableStyle(border = StyleBorder.None, padding = edges(0f),
            margins = edges(0f), collapse = TableCollapse.Collapse), blockViewport = value)

    @Composable
    private fun Scene(blocks: List<Block>, viewport: Double, width: Int = 200,
        fontScale: Float = 1f, ambientDirection: LayoutDirection = LayoutDirection.Ltr,
        onLink: (EntryLink) -> Unit = {}) {
        CompositionLocalProvider(LocalDensity provides Density(1f, fontScale),
            LocalLayoutDirection provides ambientDirection, LocalTableDocumentViewportCssWidth provides viewport) {
            DictTheme("light") {
                Box(Modifier.width(width.dp).testTag("table-containing-block")) {
                    NativeFloatBlockContext(blocks, onLink, "viewport-device", Modifier,
                        inCell = false, gridPath = "root", gapDp = 0f, trailingGap = false)
                }
            }
        }
    }

    private fun tableBlock(value: Table) = Block("table", 0, emptyList(), table = value)
    private fun withScene(content: @Composable () -> Unit, assertions: () -> Unit) {
        try {
            compose.activityRule.scenario.onActivity { activity -> activity.setContent(content = content) }
            compose.waitForIdle()
            assertions()
        } finally { compose.activityRule.scenario.onActivity { it.setContent {} } }
    }

    private fun bounds(node: SemanticsNodeInteraction): Rect = node.getUnclippedBoundsInRoot().let {
        Rect(it.left.value, it.top.value, it.right.value, it.bottom.value)
    }
    private fun parent() = compose.onNodeWithTag("table-containing-block", useUnmergedTree = true)
    private fun border() = compose.onNodeWithTag("compiled-table-block-viewport", useUnmergedTree = true)
    private fun content() = compose.onNodeWithTag("compiled-table-block-content", useUnmergedTree = true)
    private val gridMatcher = SemanticsMatcher("the actual anonymous or wide grid") {
        val tag = it.config.getOrNull(SemanticsProperties.TestTag)
        tag == "compiled-table-grid" || tag?.startsWith("compiled-table-grid-") == true
    }
    private fun grid() = compose.onNode(gridMatcher, useUnmergedTree = true)
    private val horizontalMatcher = SemanticsMatcher("a horizontal scroll owner") {
        it.config.getOrNull(SemanticsProperties.HorizontalScrollAxisRange) != null
    }
    private fun axis(node: SemanticsNodeInteraction = content()) =
        node.fetchSemanticsNode().config[SemanticsProperties.HorizontalScrollAxisRange]
    private fun scroll(node: SemanticsNodeInteraction = content(), pixels: Float) {
        node.performSemanticsAction(SemanticsActions.ScrollBy) { it(pixels, 0f) }
        compose.waitForIdle()
    }
    private fun assertNoRefusal() {
        compose.onAllNodesWithText("layout unavailable", substring = true, ignoreCase = true).assertCountEquals(0)
    }
    private fun tapGlyph(label: String) {
        val node = compose.onNodeWithText(label, useUnmergedTree = true).assertIsDisplayed()
        val layouts = mutableListOf<TextLayoutResult>()
        node.performSemanticsAction(SemanticsActions.GetTextLayoutResult) { it(layouts) }
        compose.runOnIdle { assertPhysicalActivity(compose.activity); check(compose.activity.hasWindowFocus()) }
        node.performTouchInput { click(layouts.single().getBoundingBox(0).center) }
    }

    private fun tapNativeLink(label: String) = compose.runOnIdle {
        assertPhysicalActivity(compose.activity)
        check(compose.activity.hasWindowFocus())
        val owners = mutableListOf<NativeFloatTextView>()
        fun visit(view: android.view.View) {
            if (view is NativeFloatTextView && view.isShown && view.logicalText.toString() == label) owners += view
            if (view is android.view.ViewGroup) repeat(view.childCount) { visit(view.getChildAt(it)) }
        }
        visit(compose.activity.window.decorView)
        val owner = owners.single()
        val infos = checkNotNull(owner.accessibilityNodeProvider.findAccessibilityNodeInfosByText(label, android.view.View.NO_ID))
        try {
            val node = infos.single { it.isClickable && it.isVisibleToUser }
            val screenBounds = android.graphics.Rect().also(node::getBoundsInScreen)
            assertFalse(screenBounds.isEmpty)
            val origin = IntArray(2).also(owner::getLocationOnScreen)
            val x = screenBounds.exactCenterX() - origin[0]
            val y = screenBounds.exactCenterY() - origin[1]
            val time = android.os.SystemClock.uptimeMillis()
            val down = android.view.MotionEvent.obtain(time, time, android.view.MotionEvent.ACTION_DOWN, x, y, 0)
            val up = android.view.MotionEvent.obtain(time, time + 1, android.view.MotionEvent.ACTION_UP, x, y, 0)
            try {
                assertTrue(owner.dispatchTouchEvent(down))
                assertTrue(owner.dispatchTouchEvent(up))
            } finally { down.recycle(); up.recycle() }
        } finally { infos.forEach { it.recycle() } }
    }

    @Test fun fractionalDocumentThresholdSelectsTheSameTableGraphBeforeRounding() {
        val viewport = mutableStateOf(638.75)
        val value = table()
        withScene({ Scene(listOf(tableBlock(value)), viewport.value) }) {
            for (cssWidth in listOf(638.75, 639.0, 639.25, 639.0)) {
                compose.runOnIdle { viewport.value = cssWidth }
                compose.waitForIdle()
                assertNoRefusal()
                compose.onAllNodesWithText("Start", useUnmergedTree = true).assertCountEquals(1)
                compose.onAllNodesWithText("End", useUnmergedTree = true).assertCountEquals(1)
                assertEquals(300f, bounds(grid()).width, .01f)
                if (cssWidth <= 639.0) {
                    assertEquals(140f, bounds(border()).width, .01f)
                    assertEquals(30f, bounds(border()).left - bounds(parent()).left, .01f)
                    assertEquals(140f, bounds(content()).width, .01f)
                    assertEquals(160f, axis().maxValue(), .01f)
                } else {
                    border().assertDoesNotExist()
                    content().assertDoesNotExist()
                }
            }
        }
    }

    @Test fun documentThresholdAndSourcePercentageUseIndependentCoordinatesAndFontScale() {
        val viewport = mutableStateOf(638.75)
        val width = mutableStateOf(200)
        val fontScale = mutableStateOf(1f)
        val value = table()
        withScene({ Scene(listOf(tableBlock(value)), viewport.value, width.value, fontScale.value) }) {
            assertEquals(140f, bounds(border()).width, .01f)
            compose.runOnIdle { width.value = 100; fontScale.value = 2f }
            compose.waitForIdle()
            assertNoRefusal()
            assertEquals(70f, bounds(border()).width, .01f)
            assertEquals(15f, bounds(border()).left - bounds(parent()).left, .01f)
            assertEquals(300f, bounds(grid()).width, .01f)
            assertEquals(230f, axis().maxValue(), .01f)
            // A narrow containing block cannot activate a policy whose document viewport is wide.
            compose.runOnIdle { viewport.value = 639.25 }
            compose.waitForIdle()
            border().assertDoesNotExist()
            content().assertDoesNotExist()
            assertEquals(300f, bounds(grid()).width, .01f)
        }
    }

    @Test fun oppositeContainingAndGridDirectionsKeepOuterResidualAndLocalScrollIndependent() {
        val containing = mutableStateOf(TableContainingDirection.Ltr)
        withScene({
            val rtlGrid = containing.value == TableContainingDirection.Ltr
            val base = policy(containing.value, if (rtlGrid) TableContainingDirection.Rtl else TableContainingDirection.Ltr)
            val value = base.copy(boxStyle = base.boxStyle.copy(width = StyleWidth(StyleWidthUnit.Px, 300f)),
                maxWidth = StyleWidth(StyleWidthUnit.Px, 300f))
            Scene(listOf(tableBlock(table(value, minimum = 200f))), 639.0,
                ambientDirection = if (rtlGrid) LayoutDirection.Ltr else LayoutDirection.Rtl)
        }) {
            for (sourceDirection in TableContainingDirection.entries) {
                compose.runOnIdle { containing.value = sourceDirection }
                compose.waitForIdle()
                assertNoRefusal()
                scroll(pixels = -10000f)
                val rtlGrid = sourceDirection == TableContainingDirection.Ltr
                val initialBorder = bounds(border())
                val initialGrid = bounds(grid())
                val clip = bounds(content())
                assertEquals(300f, initialBorder.width, .01f)
                assertEquals(if (sourceDirection == TableContainingDirection.Rtl) -100f else 0f,
                    initialBorder.left - bounds(parent()).left, .01f)
                assertEquals(400f, initialGrid.width, .01f)
                assertEquals(if (rtlGrid) -100f else 0f, initialGrid.left - clip.left, .01f)
                val first = bounds(compose.onNodeWithTag("compiled-table-cell-root/block-0-0", useUnmergedTree = true))
                assertEquals(if (rtlGrid) 200f else 0f, first.left - initialGrid.left, .01f)
                assertEquals(100f, axis().maxValue(), .01f)
                scroll(pixels = 10000f)
                assertEquals(100f, axis().value(), .01f)
                assertEquals(if (rtlGrid) 100f else -100f, bounds(grid()).left - initialGrid.left, .01f)
                assertEquals(initialBorder, bounds(border()))
            }
        }
    }

    @Test fun sourceBorderPaddingAndClipStayFixedWhileActualLinkScrollsAndTaps() {
        val opened = mutableListOf<String>()
        val source = policy()
        val value = table(source.copy(boxStyle = source.boxStyle.copy(background = "#00ff00",
            border = StyleBorder.Solid(px(2f), "#ff0000"), padding = edges(6f))))
        fun retainFrame(name: String, phase: String) {
            val viewport = parent()
            val semantics = viewport.printToString(maxDepth = 8).take(12000)
            val report = renderedLayoutFailureEvidence(
                "responsive-table-border-$phase", null, viewport.fetchSemanticsNode(), viewport, name,
            ) + "\nphase=$phase; opened=$opened; documentViewportCss=639.0\n$semantics"
            check(report.toByteArray(Charsets.UTF_8).size <= 128 * 1024)
            androidx.test.platform.app.InstrumentationRegistry.getInstrumentation().sendStatus(
                0, android.os.Bundle().apply {
                    putString(android.app.Instrumentation.REPORT_KEY_STREAMRESULT, "\n$report\n")
                },
            )
            check("OWNED_PNG_BEGIN $name " in report)
        }
        withScene({ Scene(listOf(tableBlock(value)), 639.0, onLink = { opened += it.target }) }) {
            var assertionFailure: Throwable? = null
            try {
                assertNoRefusal()
                val sourceBorder = bounds(border())
                val clip = bounds(content())
                assertEquals(156f, sourceBorder.width, .01f)
                assertEquals(22f, sourceBorder.left - bounds(parent()).left, .01f)
                assertEquals(140f, clip.width, .01f)
                assertEquals(8f, clip.left - sourceBorder.left, .01f)
                assertEquals(8f, clip.top - sourceBorder.top, .01f)
                assertEquals(300f, bounds(grid()).width, .01f)
                assertEquals(160f, axis().maxValue(), .01f)
                fun assertPaint() {
                    val bitmap = border().captureToImage().asAndroidBitmap()
                    try {
                        val y = bitmap.height / 2
                        assertEquals(0xffff0000.toInt(), bitmap.getPixel(0, y))
                        assertEquals(0xff00ff00.toInt(), bitmap.getPixel(4, y))
                        assertEquals(0xff00ff00.toInt(), bitmap.getPixel(bitmap.width - 5, y))
                        assertEquals(0xff0000ff.toInt(), bitmap.getPixel(10, bitmap.height - 9))
                    } finally { bitmap.recycle() }
                }
                assertPaint()
                compose.onNodeWithText("End", useUnmergedTree = true).assertIsNotDisplayed()
                scroll(pixels = 10000f)
                assertEquals(160f, axis().value(), .01f)
                assertEquals(sourceBorder, bounds(border()))
                assertEquals(clip, bounds(content()))
                assertPaint()
                tapGlyph("End")
                compose.runOnIdle { assertEquals(listOf("Viewport-End"), opened) }
                border().performTouchInput { click(Offset(4f, height / 2f)) }
                compose.runOnIdle { assertEquals("Padding must not hit a clipped cell link", listOf("Viewport-End"), opened) }
            } catch (failure: Throwable) {
                assertionFailure = failure
                throw failure
            } finally {
                // Observe only after the unchanged assertions; retain an original failure on export errors.
                try {
                    val failed = assertionFailure != null
                    retainFrame(if (failed) "responsive-table-border-failure.png" else "responsive-table-border-scrolled.png",
                        if (failed) "failure" else "scrolled")
                } catch (evidenceFailure: Throwable) {
                    val original = assertionFailure
                    if (original == null) throw evidenceFailure
                    original.addSuppressed(evidenceFailure)
                }
            }
        }
    }

    @Test fun authoredContainerScrollportKeepsTheTablesOwnLocalScrollAndHitOwner() {
        val opened = mutableListOf<String>()
        val outer = Block("container", 0, emptyList(), container = Container(listOf(tableBlock(table())),
            ContainerStyle(overflow = ContainerOverflow.Auto)))
        val outerMatcher = horizontalMatcher and !hasTestTag("compiled-table-block-content")
        withScene({ Scene(listOf(outer), 639.0, onLink = { opened += it.target }) }) {
            assertNoRefusal()
            compose.onAllNodes(horizontalMatcher, useUnmergedTree = true).assertCountEquals(2)
            val outerScroll = compose.onNode(outerMatcher, useUnmergedTree = true)
            assertEquals(140f, bounds(border()).width, .01f)
            assertEquals(300f, bounds(grid()).width, .01f)
            assertEquals(160f, axis().maxValue(), .01f)
            assertEquals(0f, axis(outerScroll).maxValue(), .01f)
            val sourceBorder = bounds(border())
            scroll(pixels = 10000f)
            assertEquals(160f, axis().value(), .01f)
            assertEquals(0f, axis(outerScroll).value(), .01f)
            assertEquals(sourceBorder, bounds(border()))
            tapNativeLink("End")
            compose.runOnIdle { assertEquals(listOf("Viewport-End"), opened) }
        }
    }

    @Test fun emptyAnonymousGridStillPaintsSourceBorderAndPaddingWithoutAnInventedRow() {
        val source = policy()
        val value = table(source.copy(boxStyle = source.boxStyle.copy(background = "#00ff00",
            border = StyleBorder.Solid(px(2f), "#ff0000"), padding = edges(4f))), rows = emptyList())
        withScene({ Scene(listOf(tableBlock(value)), 639.0) }) {
            assertNoRefusal()
            assertEquals(152f, bounds(border()).width, .01f)
            assertEquals(12f, bounds(border()).height, .01f)
            assertEquals(140f, bounds(content()).width, .01f)
            assertEquals(0f, bounds(content()).height, .01f)
            assertEquals(0f, bounds(grid()).width, .01f)
            assertEquals(0f, bounds(grid()).height, .01f)
            assertEquals(0f, axis().maxValue(), .01f)
            val bitmap = border().captureToImage().asAndroidBitmap()
            try {
                assertEquals(0xffff0000.toInt(), bitmap.getPixel(0, 5))
                assertEquals(0xff00ff00.toInt(), bitmap.getPixel(5, 5))
            } finally { bitmap.recycle() }
        }
    }

    @Test fun tableSourceDirectionControlsBothViewportStatesAndRefreshesActualCellParagraphs() {
        val direction = mutableStateOf(TableContainingDirection.Ltr)
        val viewport = mutableStateOf(639.0)
        // Each TH/TD pair contains both first-strong scripts; one opposes either selected source direction.
        val labels = listOf("\u05d0\u05d1 TH", "Latin TH", "\u05d0\u05d1 TD", "Latin TD")
        val cells = labels.mapIndexed { index, label ->
            Cell(listOf(Span("text", label)), index < 2, 1, 1,
                style = CellStyle(border = StyleBorder.None, padding = edges(0f), minWidth = px(100f)))
        }
        val ltr = table(policy(gridDirection = TableContainingDirection.Ltr), rows = cells.chunked(2))
        // The exact cell/span lists survive every direction and viewport change.
        val rtl = ltr.copy(blockViewport = ltr.blockViewport!!.copy(gridDirection = TableContainingDirection.Rtl))
        withScene({
            Scene(listOf(tableBlock(if (direction.value == TableContainingDirection.Ltr) ltr else rtl)),
                viewport.value, ambientDirection = if (direction.value == TableContainingDirection.Ltr)
                    LayoutDirection.Rtl else LayoutDirection.Ltr)
        }) {
            var previousDirection: TableContainingDirection? = null
            var previousLayouts: List<TextLayoutResult>? = null
            val states = listOf(TableContainingDirection.Ltr to 639.0, TableContainingDirection.Ltr to 640.0,
                TableContainingDirection.Rtl to 640.0, TableContainingDirection.Rtl to 639.0,
                TableContainingDirection.Ltr to 639.0, TableContainingDirection.Ltr to 640.0)
            for ((sourceDirection, cssViewport) in states) {
                compose.runOnIdle { direction.value = sourceDirection; viewport.value = cssViewport }
                compose.waitForIdle()
                assertNoRefusal()
                if (cssViewport == 639.0) border().assertExists() else border().assertDoesNotExist()
                val expectedBase = if (sourceDirection == TableContainingDirection.Rtl)
                    ResolvedTextDirection.Rtl else ResolvedTextDirection.Ltr
                val expectedStyle = if (sourceDirection == TableContainingDirection.Rtl) TextDirection.Rtl else TextDirection.Ltr
                val layouts = labels.mapIndexed { index, label ->
                    val results = mutableListOf<TextLayoutResult>()
                    compose.onNodeWithText(label, useUnmergedTree = true).assertExists()
                        .performSemanticsAction(SemanticsActions.GetTextLayoutResult) { it(results) }
                    results.single().also { result ->
                        assertEquals(label, result.layoutInput.text.text)
                        assertEquals(expectedBase, result.getParagraphDirection(0))
                        assertEquals(if (index % 2 == 0) ResolvedTextDirection.Rtl else ResolvedTextDirection.Ltr,
                            result.getBidiRunDirection(0))
                        assertTrue(result.layoutInput.text.paragraphStyles.any { range ->
                            range.start == 0 && range.end == label.length && range.item.textDirection == expectedStyle
                        })
                    }
                }
                previousLayouts?.zip(layouts)?.forEach { (before, after) ->
                    if (previousDirection == sourceDirection) assertEquals(before.layoutInput.text, after.layoutInput.text)
                    else assertNotEquals(before.layoutInput.text, after.layoutInput.text)
                }
                val first = bounds(compose.onNodeWithTag("compiled-table-cell-root/block-0-0", useUnmergedTree = true))
                val second = bounds(compose.onNodeWithTag("compiled-table-cell-root/block-0-1", useUnmergedTree = true))
                assertTrue(if (sourceDirection == TableContainingDirection.Ltr) first.left < second.left else first.left > second.left)
                previousDirection = sourceDirection
                previousLayouts = layouts
            }
        }
    }

    @Test fun explicitMiddleMovesActualContentWithinTheWholeRowspanWhileTopStaysAtItsStart() {
        fun aligned(label: String, alignment: CellVerticalAlign, rowspan: Int = 1, lines: Int = 1): Cell {
            val spans = buildList {
                repeat(lines) { index ->
                    if (index != 0) add(Span("line_break", ""))
                    add(Span("text", if (lines == 1) label else "$label$index"))
                }
            }
            return Cell(spans, false, 1, rowspan, style = CellStyle(border = StyleBorder.None,
                padding = edges(0f), minWidth = px(40f), verticalAlign = alignment))
        }
        val value = table(rows = listOf(
            listOf(aligned("T", CellVerticalAlign.Top, rowspan = 2),
                aligned("M", CellVerticalAlign.Middle, rowspan = 2),
                aligned("Tall", CellVerticalAlign.Top, lines = 3)),
            listOf(aligned("Row", CellVerticalAlign.Top, lines = 2))))
        withScene({ Scene(listOf(tableBlock(value)), 639.0) }) {
            assertNoRefusal()
            val allocatedSpan = bounds(grid())
            val topContent = bounds(compose.onNodeWithTag("compiled-table-cell-root/block-0-0", useUnmergedTree = true))
            val middleContent = bounds(compose.onNodeWithTag("compiled-table-cell-root/block-0-1", useUnmergedTree = true))
            val secondRow = bounds(compose.onNodeWithTag("compiled-table-cell-root/block-0-3", useUnmergedTree = true))
            assertTrue(allocatedSpan.height > middleContent.height * 2f)
            assertEquals(topContent.height, middleContent.height, .01f)
            assertEquals(allocatedSpan.top, topContent.top, .01f)
            assertEquals((allocatedSpan.height - middleContent.height) / 2f,
                middleContent.top - allocatedSpan.top, .01f)
            assertEquals(allocatedSpan.bottom, secondRow.bottom, .01f)
            assertEquals(topContent.top, bounds(compose.onNodeWithText("T", useUnmergedTree = true)).top, .01f)
            assertEquals(middleContent.top, bounds(compose.onNodeWithText("M", useUnmergedTree = true)).top, .01f)
        }
    }

    @Test fun sourceLanguageOwnsRealNativeStrutPaintBaselineAndActionAcrossBothStates() {
        val viewport = mutableStateOf(639.0)
        val actions = mutableListOf<EntryLink>()
        val spans = listOf(Span("link", "M", "native-first-target", language = "ja", foreground = "#d00000",
            fontScale = 2f, fontScaleBasis = FontScaleBasis.NormalBody),
            Span("text", " "), Span("link", "reset", "native-reset-target", foreground = "#d00000"))
        val nativeCell = Cell(spans, false, 1, 1, background = "#ffffff",
            style = CellStyle(border = StyleBorder.None, padding = edges(0f), minWidth = px(100f),
                verticalAlign = CellVerticalAlign.Top,
                lineHeight = CellLineHeight(CellLineHeightValue.Length(CellFixedLineHeight(.7f, FontScaleBasis.NormalBody)),
                    CellTextStrut(.7f, FontScaleBasis.NormalBody))))
        val value = table(policy(gridDirection = TableContainingDirection.Rtl), rows = listOf(listOf(nativeCell)))
        val outer = Block("container", 0, emptyList(), container = Container(listOf(tableBlock(value)), ContainerStyle()))
        val entry = Entry("Native source owner", emptyList(), "language", "Japanese", "ja",
            listOf(Section(2, "", listOf(outer))), emptyList(), edition = "ja")
        val cellMatcher = SemanticsMatcher("the real C8 cell") {
            it.config.getOrNull(SemanticsProperties.TestTag)?.startsWith("compiled-table-cell-") == true
        }
        data class Inspection(val owner: NativeFloatTextView, val leaf: NativeContextInputLeaf,
            val native: NativeFloatGeometry, val layout: android.text.StaticLayout)
        fun inspect(): Inspection {
            val owners = mutableListOf<NativeFloatTextView>()
            fun visit(view: android.view.View) {
                if (view is NativeFloatTextView && view.isShown &&
                    view.currentMeasuredGeometry?.nodes?.count { it.label?.toString() == "reset" } == 1) owners += view
                if (view is android.view.ViewGroup) repeat(view.childCount) { visit(view.getChildAt(it)) }
            }
            visit(compose.activity.window.decorView)
            val owner = owners.single()
            var geometry = checkNotNull(owner.currentMeasuredGeometry)
            while (geometry is NativeSurfaceGeometry) geometry = geometry.content
            if (geometry.javaClass.simpleName == "NoPaintGeometry") {
                geometry = geometry.javaClass.getDeclaredField("value").apply { isAccessible = true }.get(geometry) as FloatTextGeometry
            }
            val context = geometry as NativeFloatContextGeometry
            val leaf = context.inputLeaves().single { it.geometry.text.toString() == "M reset" }
            val native = leaf.geometry as NativeFloatGeometry
            val layout = NativeFloatGeometry::class.java.getDeclaredField("layout").apply { isAccessible = true }
                .get(native) as android.text.StaticLayout
            return Inspection(owner, leaf, native, layout)
        }
        fun expectedPaint(size: Float, language: String) = android.text.TextPaint(android.graphics.Paint.ANTI_ALIAS_FLAG).apply {
            textSize = size
            typeface = android.graphics.Typeface.create(android.graphics.Typeface.SERIF, 400, false)
            textLocales = android.os.LocaleList.forLanguageTags(language)
        }
        withScene({
            CompositionLocalProvider(LocalDensity provides Density(1f, 1f), LocalLayoutDirection provides LayoutDirection.Ltr,
                LocalTableDocumentViewportCssWidth provides viewport.value) {
                DictTheme("light") {
                    MaterialTheme(typography = Typography(bodyLarge = TextStyle(fontSize = 20.sp,
                        fontFamily = FontFamily.Serif, letterSpacing = 0.sp, localeList = LocaleList("de")))) {
                        Box(Modifier.width(224.dp).testTag("table-containing-block")) {
                            EntryView(entry, false, {}, onLink = { actions += it }, settings = AppSettings(
                                allowImages = false, allowAudio = false, collapseOtherSections = false, collapseDetails = false))
                        }
                    }
                }
            }
        }) {
            for ((iteration, cssViewport) in listOf(639.0, 640.0).withIndex()) {
                compose.runOnIdle { viewport.value = cssViewport }
                compose.waitForIdle()
                assertNoRefusal()
                if (cssViewport == 639.0) border().assertExists() else border().assertDoesNotExist()
                val (cellBaseline, screenPoint) = compose.runOnIdle {
                    assertPhysicalActivity(compose.activity)
                    check(compose.activity.hasWindowFocus())
                    val actual = inspect()
                    val source = actual.native.text as android.text.Spanned
                    assertEquals("M reset", source.toString())
                    assertEquals("ja", entry.languageCode)
                    assertEquals("ja", entry.edition)
                    assertEquals("ru", value.blockViewport!!.language)
                    assertEquals("ru", actual.layout.paint.textLocales.toLanguageTags())
                    assertEquals(14f, actual.layout.paint.textSize, .01f)
                    assertEquals(-1, actual.layout.getParagraphDirection(actual.layout.getLineForOffset(0)))
                    val strut = source.getSpans(0, source.length, NativeRunLineMetrics::class.java).single { it.strut }
                    val expectedBase = expectedPaint(14f, "ru")
                    assertEquals(14f, strut.primary.fontSize, .01f)
                    assertEquals(expectedBase.fontMetrics.ascent, strut.primary.ascent, .01f)
                    assertEquals(expectedBase.fontMetrics.descent, strut.primary.descent, .01f)
                    assertEquals(NativeLineHeightPolicy.Pixels(14f), strut.policy)
                    fun runPaint(offset: Int): android.text.TextPaint = android.text.TextPaint(actual.layout.paint).also { paint ->
                        source.getSpans(offset, offset + 1, android.text.style.MetricAffectingSpan::class.java)
                            .filter { source.getSpanStart(it) <= offset && source.getSpanEnd(it) > offset }
                            .forEach { it.updateMeasureState(paint) }
                    }
                    val first = runPaint(0)
                    assertEquals("ja", first.textLocales.toLanguageTags())
                    assertEquals(40f, first.textSize, .01f)
                    val reset = runPaint(2)
                    assertEquals("ru", reset.textLocales.toLanguageTags())
                    assertEquals(14f, reset.textSize, .01f)
                    val bands = listOf(expectedBase, expectedPaint(40f, "ja"), expectedPaint(14f, "ru")).map { paint ->
                        val metrics = paint.fontMetrics
                        val halfLeading = (14f - (metrics.descent - metrics.ascent)) / 2f
                        metrics.ascent - halfLeading to metrics.descent + halfLeading
                    }
                    val top = bands.minOf { it.first }; val bottom = bands.maxOf { it.second }
                    assertEquals(bottom - top, actual.native.textBottom, .01f)
                    val baseline = checkNotNull(checkNotNull(actual.native.textBaselines).first)
                    assertEquals(-top, baseline, .01f)
                    assertEquals(baseline, checkNotNull(checkNotNull(actual.native.textBaselines).last), .01f)
                    val measured = checkNotNull(actual.owner.currentMeasuredGeometry)
                    val action = measured.nodes.single { it.label?.toString() == "reset" }
                    actual.owner.setSelection(action.start, action.end)
                    assertEquals("reset", actual.owner.selectedTextForCopy())
                    actual.owner.dispatchKeyEvent(android.view.KeyEvent(android.view.KeyEvent.ACTION_DOWN, android.view.KeyEvent.KEYCODE_ESCAPE))
                    val info = checkNotNull(actual.owner.accessibilityNodeProvider.createAccessibilityNodeInfo(action.id))
                    val point = try {
                        assertTrue(info.isClickable); assertTrue(info.isVisibleToUser)
                        assertEquals("reset", info.text?.toString())
                        val rect = android.graphics.Rect().also(info::getBoundsInScreen)
                        assertFalse(rect.isEmpty)
                        Offset(rect.exactCenterX(), rect.exactCenterY())
                    } finally { info.recycle() }
                    (actual.leaf.y + baseline).roundToInt() to point
                }
                val cell = compose.onNode(cellMatcher, useUnmergedTree = true)
                val cellNode = cell.fetchSemanticsNode()
                assertEquals(cellBaseline, cellNode.getAlignmentLinePosition(FirstBaseline))
                assertEquals(cellBaseline, cellNode.getAlignmentLinePosition(LastBaseline))
                val gridNode = grid().fetchSemanticsNode()
                assertEquals(cellBaseline + (bounds(cell).top - bounds(grid()).top).roundToInt(),
                    gridNode.getAlignmentLinePosition(FirstBaseline))
                val bitmap = grid().captureToImage().asAndroidBitmap()
                try {
                    var redPixels = 0
                    for (y in 0 until bitmap.height) for (x in 0 until bitmap.width) {
                        val color = bitmap.getPixel(x, y)
                        val red = color ushr 16 and 255; val green = color ushr 8 and 255; val blue = color and 255
                        if (red > green + 40 && red > blue + 40) redPixels++
                    }
                    assertTrue("The actual renderer must retain authored red glyph paint", redPixels > 0)
                } finally { bitmap.recycle() }
                val rootOrigin = compose.onRoot().fetchSemanticsNode().positionOnScreen
                compose.onRoot().performTouchInput { click(screenPoint - rootOrigin) }
                compose.runOnIdle {
                    assertEquals(iteration + 1, actions.size)
                    assertEquals("native-reset-target", actions.last().target)
                }
            }
        }
    }

    @Test fun boundedCombinedHeightRetainsActualCaptionGridAndLinkAfterMeasurementRefusal() {
        val cap = mutableStateOf(400)
        val opened = mutableListOf<String>()
        val caption = "Retained caption"
        val labels = listOf("Keep") + (1..7).map { "Row$it" }
        val value = table(caption = listOf(Span("text", caption)),
            rows = labels.map { listOf(cell(it, minimum = 50f)) })
        withScene({
            CompositionLocalProvider(LocalDensity provides Density(1f, 1f),
                LocalLayoutDirection provides LayoutDirection.Ltr,
                LocalTableDocumentViewportCssWidth provides 639.0,
                LocalFloatMarginsConsumed provides true, LocalNativeTableMarginMeasureInput provides null) {
                DictTheme("light") {
                    Box(Modifier.width(200.dp).heightIn(max = cap.value.dp).testTag("table-containing-block")) {
                        CompiledTableView(value, null) { opened += it.target }
                    }
                }
            }
        }) {
            assertNoRefusal()
            border().assertDoesNotExist() // This real standalone owner receives the finite height constraint.
            val initialGrid = bounds(grid())
            val initialCaption = bounds(compose.onNodeWithText(caption, useUnmergedTree = true))
            assertEquals(initialCaption.bottom, initialGrid.top, .01f)
            val failingCap = ceil(initialCaption.height + initialGrid.height).toInt() - 1
            assertTrue(failingCap > maxOf(initialCaption.height, initialGrid.height))
            assertTrue(failingCap < 400)
            compose.runOnIdle { cap.value = failingCap }
            compose.waitForIdle()
            compose.onNodeWithText("Table block content exceeds native geometry", substring = true).assertIsDisplayed()
            compose.onAllNodesWithText(caption, useUnmergedTree = true).assertCountEquals(1)
            for (label in labels) compose.onAllNodesWithText(label, useUnmergedTree = true).assertCountEquals(1)
            val retainedGrid = bounds(grid())
            val retainedCaption = bounds(compose.onNodeWithText(caption, useUnmergedTree = true))
            assertEquals(initialGrid.width, retainedGrid.width, .01f)
            assertEquals(initialGrid.height, retainedGrid.height, .01f)
            assertEquals(initialCaption.width, retainedCaption.width, .01f)
            assertEquals(initialCaption.height, retainedCaption.height, .01f)
            assertEquals(retainedCaption.bottom, retainedGrid.top, .01f)
            tapGlyph("Keep")
            compose.runOnIdle { assertEquals(listOf("Viewport-Keep"), opened); cap.value = 400 }
            compose.waitForIdle()
            assertNoRefusal()
            assertEquals(initialGrid, bounds(grid()))
            assertEquals(initialCaption, bounds(compose.onNodeWithText(caption, useUnmergedTree = true)))
            tapGlyph("Keep")
            compose.runOnIdle { assertEquals(List(2) { "Viewport-Keep" }, opened) }
        }
    }

    @Test fun unsupportedNativeLanguageShowsRetainedActionsAndRecoversWithoutChangingTheModel() {
        val viewport = mutableStateOf(639.0)
        val language = mutableStateOf("ru")
        val sourceWarning = "Table language is unavailable for this layout."
        val opened = mutableListOf<String>()
        val expectedActions = mutableListOf<String>()
        val supported = table(policy(gridDirection = TableContainingDirection.Rtl),
            caption = listOf(Span("link", "Caption", "retained-caption-target")),
            rows = listOf(listOf(cell("Keep", minimum = 100f))))
        val languages = listOf("ru", "ru--RU", "zh-cmn", "i-klingon")
        val variants = languages.associateWith { source ->
            supported.copy(blockViewport = supported.blockViewport!!.copy(language = source))
        }
        val fallback = compose.onNodeWithTag("compiled-table-language-unavailable", useUnmergedTree = true)
        fun assertBodyAndActions() {
            compose.onAllNodesWithText("Caption", useUnmergedTree = true).assertCountEquals(1)
            compose.onAllNodesWithText("Keep", useUnmergedTree = true).assertCountEquals(1)
            tapGlyph("Caption")
            tapGlyph("Keep")
            expectedActions += listOf("retained-caption-target", "Viewport-Keep")
            compose.runOnIdle { assertEquals(expectedActions, opened) }
        }
        withScene({ Scene(listOf(tableBlock(variants.getValue(language.value))), viewport.value,
            onLink = { opened += it.target }) }) {
            for (cssViewport in listOf(639.0, 640.0)) {
                compose.runOnIdle { viewport.value = cssViewport; language.value = "ru" }
                compose.waitForIdle()
                fallback.assertDoesNotExist()
                compose.onNodeWithText(sourceWarning).assertDoesNotExist()
                compose.onNodeWithText("Unable to display this layout.").assertDoesNotExist()
                assertNoRefusal()
                val recoveredGrid = bounds(grid())
                if (cssViewport == 639.0) border().assertExists() else border().assertDoesNotExist()
                assertBodyAndActions()
                for (source in languages.drop(1)) {
                    compose.runOnIdle { language.value = source }
                    compose.waitForIdle()
                    val raw = variants.getValue(source)
                    assertEquals(source, raw.blockViewport!!.language)
                    assertSame(supported.rows, raw.rows)
                    assertSame(supported.caption, raw.caption)
                    fallback.assertIsDisplayed()
                    compose.onAllNodesWithText(sourceWarning, useUnmergedTree = true).assertCountEquals(1)
                    compose.onNode(hasText(sourceWarning) and
                        hasAnyAncestor(hasTestTag("compiled-table-language-unavailable")), useUnmergedTree = true).assertIsDisplayed()
                    compose.onNodeWithText("Unable to display this layout.", useUnmergedTree = true).assertDoesNotExist()
                    border().assertDoesNotExist()
                    content().assertDoesNotExist()
                    compose.onAllNodes(gridMatcher, useUnmergedTree = true).assertCountEquals(0)
                    assertBodyAndActions()
                    compose.runOnIdle { language.value = "ru" }
                    compose.waitForIdle()
                    fallback.assertDoesNotExist()
                    compose.onNodeWithText(sourceWarning).assertDoesNotExist()
                    compose.onNodeWithText("Unable to display this layout.").assertDoesNotExist()
                    assertNoRefusal()
                    assertEquals(recoveredGrid, bounds(grid()))
                    if (cssViewport == 639.0) border().assertExists() else border().assertDoesNotExist()
                    assertBodyAndActions()
                }
            }
        }
    }

    @Test fun captionMinimumEnlargesOnlyTheAnonymousGridAndKeepsOneCaptionBody() = captionMinimumCase(emptyGrid = false)

    @Test fun captionOnlyScrollsItsRealCaptionWithoutInventingGridDimensions() = captionMinimumCase(emptyGrid = true)

    private fun captionMinimumCase(emptyGrid: Boolean) {
        val caption = "WWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWW"
        val rows = if (emptyGrid) emptyList() else listOf(listOf(cell("Start", 20f), cell("End", 20f)))
        val value = table(caption = listOf(Span("text", caption)), rows = rows)
        withScene({ Scene(listOf(tableBlock(value)), 639.0) }) {
            assertNoRefusal()
            val sourceBorder = bounds(border())
            val clip = bounds(content())
            val captionNode = compose.onNodeWithText(caption, useUnmergedTree = true)
            compose.onAllNodesWithText(caption, useUnmergedTree = true).assertCountEquals(1)
            val actualCaption = bounds(captionNode)
            val actualGrid = bounds(grid())
            assertEquals(140f, sourceBorder.width, .01f)
            assertEquals(30f, sourceBorder.left - bounds(parent()).left, .01f)
            assertEquals(140f, clip.width, .01f)
            assertTrue("The real unbroken caption must overflow the source block", actualCaption.width > clip.width)
            if (emptyGrid) {
                assertEquals(0f, actualGrid.width, .01f)
                assertEquals(0f, actualGrid.height, .01f)
            } else {
                assertEquals(actualCaption.width, actualGrid.width, .01f)
                assertTrue(actualGrid.height > 0f)
            }
            assertEquals(actualCaption.width - clip.width, axis().maxValue(), 1f)
            assertEquals(actualCaption.bottom, actualGrid.top, .01f)
            assertEquals(actualCaption.height + actualGrid.height, sourceBorder.height, .01f)
        }
    }
}
