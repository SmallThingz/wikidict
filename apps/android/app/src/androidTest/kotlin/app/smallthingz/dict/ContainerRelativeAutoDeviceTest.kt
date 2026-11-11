package app.smallthingz.dict

import android.graphics.Rect
import android.view.MotionEvent
import android.view.View
import android.view.accessibility.AccessibilityNodeInfo
import androidx.activity.compose.setContent
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.width
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.layout.boundsInWindow
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.*
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

class ContainerRelativeAutoDeviceTest {
    @get:Rule val compose = createPhysicalComposeRule()
    private fun px(value: Float) = StyleLength(StyleLengthUnit.Px, value)
    private fun group(children: List<Block>, style: ContainerStyle) =
        Block("container", 0, emptyList(), container = Container(children, style))
    private fun body(positioned: Boolean, tableFirst: Boolean): List<Block> {
        val head = group(listOf(Block("paragraph", 0,
            listOf(Span("link", "HEAD", target = "head-target", foreground = "#ff0000")))),
            ContainerStyle(height = px(32f), ownerFontScale = 2f,
                background = ContainerColor.Rgb("#ffff00"),
                positioning = if (positioned) ContainerPositioning.RelativeAuto else null))
        // The ordinary outer owner has zero used height. Its real child keeps positive ink.
        val headOwner = group(listOf(head), ContainerStyle(height = px(0f)))
        val cell = group(listOf(Block("paragraph", 0,
            listOf(Span("link", "TABLE_TARGET_EXPOSED", target = "table-target", foreground = "#ffffff")))),
            ContainerStyle(ownerFontScale = 1f))
        val table = Block("table", 0, emptyList(), table = Table(emptyList(),
            listOf(listOf(Cell(emptyList(), false, 1, 1, blocks = listOf(cell), background = "#0000ff"))),
            style = TableStyle(background = "#0000ff", width = StyleWidth(StyleWidthUnit.Px, 300f))))
        val tableOwner = group(listOf(table), ContainerStyle(height = px(0f)))
        return if (tableFirst) listOf(tableOwner, headOwner) else listOf(headOwner, tableOwner)
    }
    private fun views(): List<NativeFloatTextView> {
        val result = mutableListOf<NativeFloatTextView>()
        compose.activityRule.scenario.onActivity { activity ->
            fun visit(view: View) {
                if (view is NativeFloatTextView) result += view
                if (view is android.view.ViewGroup) for (i in 0 until view.childCount) visit(view.getChildAt(i))
            }
            visit(activity.window.decorView)
        }
        return result
    }
    private fun node(owner: NativeFloatTextView, label: String): AccessibilityNodeInfo {
        var result: AccessibilityNodeInfo? = null
        compose.runOnIdle { result = checkNotNull(owner.accessibilityNodeProvider
            .findAccessibilityNodeInfosByText(label, View.NO_ID)).single() }
        return checkNotNull(result)
    }
    private fun point(owner: NativeFloatTextView, x: Float, y: Float,
        root: androidx.compose.ui.geometry.Rect): Offset {
        val screen = IntArray(2); val window = IntArray(2)
        compose.runOnIdle { owner.getLocationOnScreen(screen); owner.getLocationInWindow(window) }
        return Offset(x - screen[0] + window[0] - root.left, y - screen[1] + window[1] - root.top)
    }
    private fun evidence(tag: String, label: String): android.graphics.Bitmap {
        val root = compose.onNodeWithTag(tag)
        val image = root.captureToImage()
        val report = renderedLayoutFailureEvidence(label, null, null, root,
            "relative-auto native paint and input order", image.asAndroidBitmap())
        InstrumentationRegistry.getInstrumentation().sendStatus(0, android.os.Bundle().apply {
            putString(android.app.Instrumentation.REPORT_KEY_STREAMRESULT, "\n$report\n")
        })
        check("OWNED_PNG_BEGIN $label " in report)
        return image.asAndroidBitmap()
    }

    @Test fun actualEntryRelativeHeaderRanksAboveRealTableWithStableTextAndChildOwners() {
        val mode = mutableStateOf(0)
        val opened = mutableListOf<String>()
        var rootWindow = androidx.compose.ui.geometry.Rect.Zero
        try {
            compose.activityRule.scenario.onActivity { activity -> activity.setContent {
                CompositionLocalProvider(LocalDensity provides Density(1f, if (mode.value == 2) 1.25f else 1f)) {
                    DictTheme("light") { MaterialTheme(typography = MaterialTheme.typography.copy(
                        bodyLarge = MaterialTheme.typography.bodyLarge.copy(fontSize = 20.sp, lineHeight = 20.sp))) {
                        Box(Modifier.width(if (mode.value == 2) 420.dp else 380.dp).height(550.dp).testTag("relative-entry")
                            .onGloballyPositioned { rootWindow = it.boundsInWindow() }) {
                            EntryView(Entry("Relative", emptyList(), "language", "English", "en",
                                listOf(Section(2, "", body(mode.value != 0, mode.value == 3))), emptyList()),
                                false, {}, onLink = { opened += it.target },
                                settings = AppSettings(allowImages = false, allowAudio = false,
                                    collapseOtherSections = false, collapseDetails = false))
                        }
                    } }
                }
            } }
            var firstText: NativeFloatTextView? = null
            var firstTable: NativeFloatTextView? = null
            var originalText = ""
            var originalHeadBox: Rect? = null
            for (state in 0..3) {
                compose.runOnIdle { mode.value = state }; compose.waitForIdle()
                val text = views().single { it.logicalText.contains("HEAD") }
                val table = views().single { it.logicalText.contains("TABLE_TARGET_EXPOSED") }
                assertNotSame(text, table)
                if (state == 0) { firstText = text; firstTable = table; originalText = text.logicalText.toString() }
                if (state in 1..2) { assertSame(firstText, text); assertSame(firstTable, table) }
                if (state in 1..2) assertEquals(originalText, text.logicalText.toString())
                val headNode = node(text, "HEAD")
                val tableNode = node(table, "TABLE_TARGET_EXPOSED")
                assertTrue(headNode.isClickable && tableNode.isClickable)
                assertTrue(headNode.isVisibleToUser && tableNode.isVisibleToUser)
                val headBox = Rect().also(headNode::getBoundsInScreen)
                val tableBox = Rect().also(tableNode::getBoundsInScreen)
                if (state == 0) originalHeadBox = Rect(headBox)
                if (state == 1) assertEquals(originalHeadBox, headBox)
                val overlap = Rect(headBox)
                assertTrue("The original header and real table link must overlap", overlap.intersect(tableBox))
                assertTrue("The real table retains an exposed action interval", tableBox.right > headBox.right + 8)
                val bitmap = evidence("relative-entry", "native-relative-entry-$state.png")
                val first = point(text, overlap.left.toFloat(), overlap.top.toFloat(), rootWindow)
                var red = 0
                var yellow = 0
                for (y in maxOf(0, first.y.toInt()) until minOf(bitmap.height, first.y.toInt() + overlap.height()))
                    for (x in maxOf(0, first.x.toInt()) until minOf(bitmap.width, first.x.toInt() + overlap.width())) {
                        val p = bitmap.getPixel(x, y)
                        if (android.graphics.Color.red(p) > 170 && android.graphics.Color.green(p) < 100 &&
                            android.graphics.Color.blue(p) < 100) red++
                        if (android.graphics.Color.red(p) > 220 && android.graphics.Color.green(p) > 220 &&
                            android.graphics.Color.blue(p) < 50) yellow++
                    }
                if (state == 0) { assertEquals(0, red); assertEquals(0, yellow) }
                else { assertTrue("Positioned glyph ink survives later opaque table", red > 5)
                    assertTrue("The complete positioned background survives too", yellow > 10) }
                val hit = point(text, overlap.exactCenterX(), overlap.exactCenterY(), rootWindow)
                compose.onNodeWithTag("relative-entry").performTouchInput { click(hit) }
                compose.waitForIdle()
                assertEquals(if (state == 0) "table-target" else "head-target", opened.last())
                val exposed = point(table, tableBox.right - 2f, tableBox.exactCenterY(), rootWindow)
                compose.onNodeWithTag("relative-entry").performTouchInput { click(exposed) }
                compose.waitForIdle()
                assertEquals("table-target", opened.last())
                compose.onNodeWithText("Unable to display this layout.").assertDoesNotExist()
                if (state == 3) assertTrue(text.logicalText.indexOf('\ufffc') < text.logicalText.indexOf("HEAD"))
            }
            assertEquals(listOf("table-target", "table-target", "head-target", "table-target",
                "head-target", "table-target", "head-target", "table-target"), opened)
        } finally { compose.activityRule.scenario.onActivity { it.setContent {} }; compose.waitForIdle() }
    }

    @Test fun positionedGroupRetainsAncestorClipAndDoesNotTransferAGestureToTheTable() {
        val clipped = mutableStateOf(false)
        val positioned = mutableStateOf(true)
        val opened = mutableListOf<String>()
        var rootWindow = androidx.compose.ui.geometry.Rect.Zero
        try {
            compose.activityRule.scenario.onActivity { activity -> activity.setContent {
                CompositionLocalProvider(LocalDensity provides Density(1f, 1f)) {
                    DictTheme("light") { MaterialTheme(typography = MaterialTheme.typography.copy(
                        bodyLarge = MaterialTheme.typography.bodyLarge.copy(fontSize = 20.sp, lineHeight = 20.sp))) {
                        Box(Modifier.width(380.dp).height(120.dp).background(Color.White).testTag("relative-clip")
                            .onGloballyPositioned { rootWindow = it.boundsInWindow() }) {
                            Box(Modifier.width(360.dp).height(if (clipped.value) 6.dp else 100.dp).clipToBounds()) {
                                NativeFloatBlockContext(body(positioned.value, false), { opened += it.target },
                                    "relative-control", Modifier, inCell = false, gridPath = "relative-control",
                                    gapDp = 6f, trailingGap = true, documentSurface = true, positionedPaintRoot = true)
                            }
                        }
                    } }
                }
            } }
            compose.waitForIdle()
            val text = views().single { it.logicalText.contains("HEAD") }
            val table = views().single { it.logicalText.contains("TABLE_TARGET_EXPOSED") }
            val headBox = Rect().also(node(text, "HEAD")::getBoundsInScreen)
            val tableBox = Rect().also(node(table, "TABLE_TARGET_EXPOSED")::getBoundsInScreen)
            val overlap = Rect(headBox); assertTrue(overlap.intersect(tableBox))
            val hit = point(text, overlap.exactCenterX(), overlap.exactCenterY(), rootWindow)
            val textEvents = mutableListOf<Int>()
            val tableEvents = mutableListOf<Int>()
            compose.runOnIdle {
                text.setOnTouchListener { _, event -> textEvents += event.actionMasked; false }
                table.setOnTouchListener { _, event -> tableEvents += event.actionMasked; false }
            }
            // A DOWN accepted by the positioned text cannot transfer to the table when the
            // style changes while that same gesture is held.
            compose.onNodeWithTag("relative-clip").performTouchInput { down(hit) }
            compose.runOnIdle { positioned.value = false }; compose.waitForIdle()
            compose.onNodeWithTag("relative-clip").performTouchInput { up() }
            compose.waitForIdle()
            assertTrue(textEvents.contains(MotionEvent.ACTION_DOWN) && textEvents.contains(MotionEvent.ACTION_UP))
            assertFalse(tableEvents.contains(MotionEvent.ACTION_DOWN))
            // The dispatch owner stays latched. Activation is resolved against the current
            // text geometry and may cancel; it must never transfer to the newly higher table.
            assertFalse(opened.contains("table-target"))
            assertSame(text, views().single { it.logicalText.contains("HEAD") })
            assertSame(table, views().single { it.logicalText.contains("TABLE_TARGET_EXPOSED") })
            compose.runOnIdle { opened.clear(); positioned.value = true; clipped.value = true }; compose.waitForIdle()
            val image = evidence("relative-clip", "native-relative-ancestor-clip.png")
            for (y in 8 until image.height) for (x in 0 until image.width)
                assertEquals("No deferred paint may escape the existing ancestor clip", android.graphics.Color.WHITE, image.getPixel(x, y))
            compose.onNodeWithTag("relative-clip").performTouchInput { click(Offset(30f, 30f)) }
            compose.waitForIdle()
            assertTrue("Clipped deferred text and table may not receive an outside touch", opened.isEmpty())
        } finally { compose.activityRule.scenario.onActivity { it.setContent {} }; compose.waitForIdle() }
    }

    @Test fun unjoinedFigureAndTableCaptionOwnersKeepOriginalBodyAndActionsVisible() {
        val mode = mutableStateOf(0)
        val opened = mutableListOf<String>()
        fun edges() = StyleEdges(px(0f), px(0f), px(0f), px(0f))
        fun tree(): Block {
            val style = if (mode.value == 1) ContainerStyle(columns = ContainerColumns(2, px(8f)))
                else ContainerStyle(positioning = ContainerPositioning.RelativeAuto)
            val caption = group(listOf(Block("paragraph", 0,
                listOf(Span("link", "caption-body", target = "caption-target")))), style)
            if (mode.value == 2) return Block("table", 0, emptyList(), table = Table(emptyList(),
                listOf(listOf(Cell(emptyList(), false, 1, 1))), captionBlocks = listOf(caption)))
            return Block("paragraph", 0, emptyList(), figure = Figure(
                FigureContent.Missing(Span("link", "figure-body", target = "figure-target"), px(100f), px(20f)),
                FigureFormat.Thumbnail, FigurePlacement.None, FigureClear.None, edges(), edges(), edges(),
                1f, px(20f), FigureColor.Transparent, FigureBorder.None, FigureColor.Transparent, FigureBorder.None,
                FigureColor.Rgb("#000000"), FigureColor.Transparent, captionBlocks = listOf(caption)))
        }
        try {
            compose.activityRule.scenario.onActivity { activity -> activity.setContent { DictTheme("light") {
                Box(Modifier.width(380.dp).height(500.dp).testTag("relative-refusal")) {
                    EntryView(Entry("Refusal", emptyList(), "language", "English", "en",
                        listOf(Section(2, "", listOf(tree()))), emptyList()), false, {},
                        onLink = { opened += it.target }, settings = AppSettings(allowImages = false, allowAudio = false,
                            collapseOtherSections = false, collapseDetails = false))
                }
            } } }
            for (state in 0..2) {
                compose.runOnIdle { mode.value = state }; compose.waitForIdle()
                evidence("relative-refusal", "native-relative-owner-refusal-$state.png")
                compose.onAllNodesWithText("Unable to display this layout.").onFirst().assertIsDisplayed()
                val label = compose.onNodeWithText("caption-body", useUnmergedTree = true).assertIsDisplayed()
                val layouts = mutableListOf<androidx.compose.ui.text.TextLayoutResult>()
                label.performSemanticsAction(SemanticsActions.GetTextLayoutResult) { it(layouts) }
                label.performTouchInput { click(layouts.single().getBoundingBox(2).center) }
                compose.waitForIdle()
                assertEquals("caption-target", opened.last())
                if (state != 2) compose.onNodeWithText("figure-body", useUnmergedTree = true).assertIsDisplayed()
            }
            assertEquals(List(3) { "caption-target" }, opened)
        } finally { compose.activityRule.scenario.onActivity { it.setContent {} }; compose.waitForIdle() }
    }
}
