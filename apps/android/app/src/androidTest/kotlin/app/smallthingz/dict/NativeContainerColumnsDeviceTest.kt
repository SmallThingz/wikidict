package app.smallthingz.dict

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Rect
import android.graphics.RectF
import android.graphics.Typeface
import android.text.SpannableString
import android.text.Spanned
import android.text.TextPaint
import android.text.style.ForegroundColorSpan
import android.text.style.RelativeSizeSpan
import android.view.View
import android.view.accessibility.AccessibilityNodeInfo
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.width
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.layout.boundsInWindow
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalLayoutDirection
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.*
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

class NativeContainerColumnsDeviceTest {
    @get:Rule val compose = createPhysicalComposeRule()

    @Test fun nativeLineFragmentsRetainBidiSpansCaretsRangesAndOneMarkerOwner() {
        val text = "Wide words אבג\t12\nsecond paragraph text\nthird line words\nfourth line words"
        val source = SpannableString(text).apply {
            setSpan(RelativeSizeSpan(1.4f), 5, 10, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
            setSpan(ForegroundColorSpan(android.graphics.Color.BLUE), 0, length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        }
        val paint = TextPaint().apply { textSize = 20f; typeface = Typeface.MONOSPACE; isAntiAlias = true }
        var markerPaints = 0
        var clicked = 0
        val original = NativeFloatGeometry.build(source, paint, 150, emptyList(),
            nodeFactory = { geometry -> listOf(FloatInteractionNode(0, FloatInteractionKind.LINK, 0, text.length,
                geometry.rectsForRange(0, text.length), text, null, { clicked++ })) },
            decoration = { canvas, geometry ->
                markerPaints++
                val first = geometry.firstLineBand()
                canvas.drawRect(first.left - 4, first.top, first.left - 1, first.top + 4, paint)
            }, decorationBounds = { geometry -> geometry.firstLineBand().let {
                NativeFloatBounds(it.left - 4, it.top, it.left - 1, it.top + 4)
            } })
        assertTrue(original.shapedLineCount >= 4)
        val lines = List(original.shapedLineCount) { NativeColumnLine(0, it, original.usedLineHeight(it)) }
        val balanced = balanceNativeColumns(lines, 2)
        val shifted = original.inColumns(balanced.placements.map { (.375f + it.column * 180.5f) to it.top })
        assertEquals(original.text, shifted.text)
        assertEquals(1, shifted.nodes.size)
        assertEquals(text, shifted.nodes.single().label)
        for (offset in text.indices.filter { !text[it].isWhitespace() }) {
            val range = original.lineRange(offset)
            assertEquals(range, shifted.lineRange(offset))
            val line = lines.indices.first { original.lineRange(offset).first ==
                original.lineRange(lineStart(original, it)).first }
            val dx = .375f + balanced.placements[line].column * 180.5f
            val dy = shifted.baselineForOffset(offset) - original.baselineForOffset(offset)
            val expected = original.caretRect(offset).apply { offset(dx, dy) }
            val actual = shifted.caretRect(offset)
            assertEquals(expected.left, actual.left, .001f)
            assertEquals(expected.top, actual.top, .001f)
            val oldRects = original.rectsForRange(offset, offset + 1)
            val newRects = shifted.rectsForRange(offset, offset + 1)
            assertEquals(oldRects.size, newRects.size)
            oldRects.zip(newRects).forEach { (old, new) ->
                old.offset(dx, dy); assertEquals(old, new)
                val hit = shifted.offsetForPosition(new.centerX(), new.centerY())
                assertTrue(hit in range.first..range.second)
            }
            assertEquals(newRects.reduceOrNull { a, b -> a.apply { union(b) } }, shifted.characterRects(offset, 1).single())
        }
        val bitmap = Bitmap.createBitmap(420, 500, Bitmap.Config.ARGB_8888)
        shifted.paint(Canvas(bitmap).apply { translate(12f, 24f) })
        assertEquals("Marker belongs to the original paragraph, not each column", 1, markerPaints)
        for (column in 0..1) {
            var pixels = 0
            for (y in 0 until bitmap.height) for (x in (12 + column * 180) until (170 + column * 180))
                if (android.graphics.Color.alpha(bitmap.getPixel(x, y)) != 0) pixels++
            assertTrue("Real native glyph ink in column $column", pixels > 20)
        }
        shifted.nodes.single().onClick!!.invoke()
        assertEquals(1, clicked)
        val zero = NativeFloatGeometry.build(source, paint, 150, emptyList(),
            usedLineMetrics = { _, _ -> NativeUsedLineMetrics(0f, 0f) })
        val zeroMapped = zero.inColumns(List(zero.shapedLineCount) { (it % 2 * 180f) to 0f })
        assertEquals(0f, zeroMapped.textBottom, 0f)
        assertTrue(checkNotNull(zeroMapped.extents.ink).bottom > 0f)
    }

    private fun lineStart(geometry: NativeFloatGeometry, line: Int): Int {
        var offset = 0
        repeat(line) { offset = geometry.lineRange(offset).second }
        return offset
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

    @Test fun actualEntryAndTableCellKeepOneOrderedOwnerAcrossCountWidthAndDirectionChanges() {
        val mode = mutableStateOf(0)
        val opened = mutableListOf<String>()
        var rootWindow = androidx.compose.ui.geometry.Rect.Zero
        fun px(value: Float) = StyleLength(StyleLengthUnit.Px, value)
        fun block(): Block {
            val children = List(8) { index -> Block("list_item", 1, listOf(
                Span("link", "item-$index", target = "target-$index", foreground = "#000000"),
                Span("text", " אבג text", small = index % 2 == 0))) }
            return Block("container", 0, emptyList(), container = Container(children, ContainerStyle(
                columns = ContainerColumns(if (mode.value == 1) 3 else 2, px(12.5f)),
                lineHeight = ContainerLineHeight.Multiplier(1f))))
        }
        fun entry(): Entry {
            val body = if (mode.value < 2) block() else Block("table", 0, emptyList(), table = Table(emptyList(),
                listOf(listOf(Cell(emptyList(), false, 1, 1, blocks = listOf(block()),
                    style = CellStyle(minWidth = px(360f)))))))
            return Entry("Columns", emptyList(), "language", "English", "en",
                listOf(Section(2, "", listOf(body))), emptyList())
        }
        try {
            compose.activityRule.scenario.onActivity { activity -> activity.setContent {
                CompositionLocalProvider(LocalDensity provides Density(1f, 1f),
                    LocalLayoutDirection provides if (mode.value == 3) LayoutDirection.Rtl else LayoutDirection.Ltr) {
                    DictTheme("light") { MaterialTheme(typography = MaterialTheme.typography.copy(
                        bodyLarge = MaterialTheme.typography.bodyLarge.copy(fontSize = 20.sp, lineHeight = 20.sp))) {
                        Box(Modifier.width(if (mode.value == 1) 520.dp else 440.dp).height(600.dp).testTag("columns-root")
                            .onGloballyPositioned { rootWindow = it.boundsInWindow() }) {
                            EntryView(entry(), false, {}, onLink = { opened += it.target },
                                settings = AppSettings(allowImages = false, allowAudio = false,
                                    collapseOtherSections = false, collapseDetails = false))
                        }
                    } }
                }
            } }
            var ordinary: NativeFloatTextView? = null
            var cell: NativeFloatTextView? = null
            for (state in 0..3) {
                compose.runOnIdle { mode.value = state }; compose.waitForIdle()
                val owner = views().single { it.logicalText.toString().contains("item-7") }
                if (state == 0) ordinary = owner else if (state == 1) assertSame(ordinary, owner)
                if (state == 2) cell = owner else if (state == 3) assertSame(cell, owner)
                assertEquals((0..7).map { "item-$it" }, Regex("item-\\d").findAll(owner.logicalText).map { it.value }.toList())
                val nodes = mutableListOf<AccessibilityNodeInfo>()
                compose.runOnIdle {
                    for (i in 0..7) nodes += checkNotNull(owner.accessibilityNodeProvider
                        .findAccessibilityNodeInfosByText("item-$i", View.NO_ID)).single()
                }
                val boxes = nodes.map { Rect().also(it::getBoundsInScreen) }
                assertTrue("Source flow occupies distinct columns", boxes.map { it.left }.distinct().size >= 2)
                assertTrue("Later source column resets its block coordinate", boxes.zipWithNext().any { (a, b) -> b.top < a.top })
                val viewport = compose.onNodeWithTag("columns-root")
                val image = viewport.captureToImage()
                val report = renderedLayoutFailureEvidence("native-columns-$state.png", null, null, viewport,
                    "native columns", image.asAndroidBitmap()) + "\nstate=$state boxes=$boxes text=${owner.logicalText}"
                InstrumentationRegistry.getInstrumentation().sendStatus(0, android.os.Bundle().apply {
                    putString(android.app.Instrumentation.REPORT_KEY_STREAMRESULT, "\n$report\n")
                })
                check("OWNED_PNG_BEGIN native-columns-$state.png " in report)
                var target = Offset.Zero
                compose.runOnIdle {
                    assertTrue(nodes.last().isVisibleToUser)
                    val screen = IntArray(2); val window = IntArray(2)
                    owner.getLocationOnScreen(screen); owner.getLocationInWindow(window)
                    target = Offset(boxes.last().exactCenterX() - screen[0] + window[0] - rootWindow.left,
                        boxes.last().exactCenterY() - screen[1] + window[1] - rootWindow.top)
                    assertTrue(target.x in 0f..rootWindow.width && target.y in 0f..rootWindow.height)
                    val bitmap = image.asAndroidBitmap()
                    for (box in listOf(boxes.first(), boxes.last())) {
                        val left = (box.left - screen[0] + window[0] - rootWindow.left).toInt()
                        val top = (box.top - screen[1] + window[1] - rootWindow.top).toInt()
                        var ink = 0
                        for (y in maxOf(0, top) until minOf(bitmap.height, top + box.height()))
                            for (x in maxOf(0, left) until minOf(bitmap.width, left + box.width())) {
                                val pixel = bitmap.getPixel(x, y)
                                if (android.graphics.Color.alpha(pixel) > 128 && android.graphics.Color.red(pixel) < 100 &&
                                    android.graphics.Color.green(pixel) < 100 && android.graphics.Color.blue(pixel) < 100) ink++
                            }
                        assertTrue("Original first/last source links have native pixels", ink > 5)
                    }
                }
                viewport.performTouchInput { click(target) }
                compose.waitForIdle()
                assertEquals("target-7", opened.last())
                compose.onNodeWithText("Unable to display this layout.").assertDoesNotExist()
            }
            assertEquals(List(4) { "target-7" }, opened)
        } finally { compose.activityRule.scenario.onActivity { it.setContent {} }; compose.waitForIdle() }
    }
}
