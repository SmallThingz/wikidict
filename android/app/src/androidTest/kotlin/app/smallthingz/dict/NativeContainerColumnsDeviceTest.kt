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
import androidx.activity.ComponentActivity
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
    @get:Rule val compose = createPhysicalContentRule()

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

    @Test fun widthDrivenEntryColumnsPreserveOriginalListsAcrossAllocationZoomAndEmptyClearRecovery() {
        // Direct typed source-shaped fixture, not a retained me230 render: stored 9em is already
        // normalized to the original body. The independent declaring owner is 1.35 body sizes.
        data class Phase(val host: Float = 520f, val zoom: Float = 1f, val largeChild: Boolean = false,
            val rtl: Boolean = false, val cap: Int? = null, val fixed: Boolean = false,
            val clear: Boolean = true, val items: Int = 9, val omitColumns: Boolean = false,
            val columnDirection: BidiResolvedDirection? = null, val tableDirection: TableContainingDirection? = null,
            val uiRtl: Boolean? = null, val longItem: Boolean = false,
            val breakInside: ColumnBreakInside? = null, val neighborBreakInside: ColumnBreakInside? = ColumnBreakInside.Auto)
        val phases = listOf(
            Phase(host = 380f), Phase(), Phase(largeChild = true), Phase(zoom = 1.5f),
            Phase(cap = 1), Phase(rtl = true), Phase(rtl = true, clear = false), Phase(rtl = true),
            Phase(rtl = true, fixed = true), Phase(rtl = true, items = 8), Phase(rtl = true),
            Phase(items = 0), Phase(items = 0, clear = false, omitColumns = true), Phase(),
            // Separate direct-typed precedence contrasts; not claims about retained me230 metadata.
            Phase(columnDirection = BidiResolvedDirection.Rtl, uiRtl = false),
            Phase(rtl = true, tableDirection = TableContainingDirection.Ltr, uiRtl = true),
            Phase(rtl = true, tableDirection = TableContainingDirection.Ltr,
                columnDirection = BidiResolvedDirection.Rtl, uiRtl = true), Phase(),
            // Synthetic real wrapped owners distinguish per-owner avoidance from global list no-wrap.
            Phase(longItem = true), Phase(longItem = true, breakInside = ColumnBreakInside.Avoid),
            Phase(longItem = true, breakInside = ColumnBreakInside.Auto, neighborBreakInside = null),
            Phase(longItem = true, breakInside = ColumnBreakInside.Auto, neighborBreakInside = ColumnBreakInside.Avoid),
            Phase(longItem = true), Phase())
        val phase = mutableStateOf(0)
        val opened = mutableListOf<String>()
        val failures = mutableListOf<String>()
        var rootWindow = androidx.compose.ui.geometry.Rect.Zero
        var activity: ComponentActivity? = null
        fun px(value: Float) = StyleLength(StyleLengthUnit.Px, value)
        fun em(value: Float) = StyleLength(StyleLengthUnit.Em, value)
        fun text(value: String, scale: Float) = Span("text", value, code = true,
            foreground = "#000000", fontScale = scale, fontScaleBasis = FontScaleBasis.NormalBody)
        val introduction = Block("paragraph", 0, listOf(text("Column introduction", .6f)))
        val smallLinks = List(9) { i -> Span("link", "item-$i", target = "column-target-$i", code = true,
            foreground = "#000000", fontScale = .6f, fontScaleBasis = FontScaleBasis.NormalBody) }
        val largeLinks = smallLinks.map { it.copy(fontScale = 1.2f) }
        fun items(links: List<Span>) = links.map { link -> Block("list_item", 1,
            listOf(link, text(" אבג", checkNotNull(link.fontScale)))) }
        val smallItems = items(smallLinks)
        val largeItems = items(largeLinks)
        val longTail = " word".repeat(72)
        val wrappedItems = smallItems.toMutableList().apply {
            this[0] = Block("list_item", 1, listOf(smallLinks[0], text(longTail, .6f)))
        }.toList()
        val phaseItems = phases.map { value ->
            if (!value.longItem) if (value.largeChild) largeItems else smallItems
            else wrappedItems.mapIndexed { i, block -> when (i) {
                0 -> block.copy(columnBreakInside = value.breakInside)
                1 -> block.copy(columnBreakInside = value.neighborBreakInside)
                else -> block
            } }
        }
        val emptyClear = Block("container", 0, emptyList(), container = Container(emptyList(),
            ContainerStyle(clear = FigureClear.Both)))
        val following = Block("paragraph", 0, listOf(text("AFTER_COLUMNS", .6f)))
        val sourceBodies = phases.mapIndexed { index, value ->
            val body = if (value.items == 0) emptyList() else listOf(introduction) + phaseItems[index].take(value.items)
            val columns = Block("container", 0, emptyList(), container = Container(body, ContainerStyle(
                columns = ContainerColumns(count = if (value.fixed) 2 else value.cap, gap = px(12.5f),
                    width = if (value.fixed) null else em(9f), direction = value.columnDirection),
                ownerFont = InlineFontSnapshot(fontScale = 1.35f, fontScaleBasis = FontScaleBasis.NormalBody,
                    fontNormalized = true), lineHeight = ContainerLineHeight.Multiplier(1f))))
            // The real empty clear DIV is a following sibling, never moved into the column owner.
            buildList { if (!value.omitColumns) add(columns); if (value.clear) add(emptyClear); add(following) }
        }
        fun sourceBlock(index: Int, value: Phase): Block {
            val body = Block("container", 0, emptyList(), container = Container(sourceBodies[index]))
            val tableDirection = value.tableDirection ?: return body
            val zero = StyleEdges(px(0f), px(0f), px(0f), px(0f))
            val zeroMargin = ContainerMargin.Length(px(0f))
            // The existing typed Table owner supplies direction even in its ordinary wide route.
            // Threshold0 keeps this positive-width fixture wide; no invented direction local.
            val table = Table(emptyList(), listOf(listOf(Cell(emptyList(), false, 1, 1,
                blocks = listOf(body), style = CellStyle(border = StyleBorder.None, padding = zero)))),
                style = TableStyle(width = StyleWidth(StyleWidthUnit.Percent, 100f), border = StyleBorder.None,
                    padding = zero, margins = zero, collapse = TableCollapse.Collapse),
                blockViewport = TableBlockViewport(0L,
                    TableStyle(width = StyleWidth(StyleWidthUnit.Percent, 100f),
                        marginValues = ContainerMargins(zeroMargin, ContainerMargin.Auto, zeroMargin, ContainerMargin.Auto),
                        containingDirection = TableContainingDirection.Ltr),
                    ContainerBoxSizing.ContentBox, StyleWidth(StyleWidthUnit.Percent, 100f),
                    TableStyle(collapse = TableCollapse.Collapse), tableDirection, language = "en"))
            return Block("table", 0, emptyList(), table = table)
        }
        val entries = phases.mapIndexed { index, value -> Entry("Columns", emptyList(), "language", "English", "en",
            listOf(Section(2, "", listOf(sourceBlock(index, value)))), emptyList(),
            bodyTypography = BodyTypography(InlineFontSnapshot(fontScale = 1f,
                fontScaleBasis = FontScaleBasis.NormalBody, fontNormalized = true),
                direction = if (value.rtl) BidiResolvedDirection.Rtl else BidiResolvedDirection.Ltr)) }
        fun expectedText(value: Phase): String = (if (value.items == 0) emptyList() else
            listOf("Column introduction") + List(value.items) {
                "item-$it" + if (value.longItem && it == 0) longTail else " אבג"
            }).plus("AFTER_COLUMNS").joinToString("\n")
        fun activeViews(): List<NativeFloatTextView> {
            val result = mutableListOf<NativeFloatTextView>()
            fun visit(view: View) {
                if (view is NativeFloatTextView && view.isShown) result += view
                if (view is android.view.ViewGroup) for (i in 0 until view.childCount) visit(view.getChildAt(i))
            }
            visit(checkNotNull(activity).window.decorView)
            return result
        }
        data class Snapshot(val text: String, val width: Int, val usedHeight: Float,
            val carets: List<RectF>, val characters: List<RectF?>, val ranges: List<List<Pair<Int, Int>>>,
            val actions: List<Pair<Int, Int>>, val markers: List<RectF>)
        val snapshots = mutableMapOf<Int, Snapshot>()
        val counts = mutableMapOf<Int, Int>()
        val longRows = mutableMapOf<Int, List<Pair<Int, Int>>>()
        val longLanes = mutableMapOf<Int, Int>()
        var primary: Throwable? = null
        try {
            compose.activityRule.scenario.onActivity { host ->
                activity = host
                host.setContent {
                    val value = phases[phase.value]
                    CompositionLocalProvider(LocalDensity provides Density(1f, value.zoom),
                        // Typed column/Table/BODY authority must win over the independent outer UI.
                        LocalLayoutDirection provides if (value.uiRtl ?: !value.rtl) LayoutDirection.Rtl else LayoutDirection.Ltr,
                        LocalNativeFloatContextFailureObserver provides { reason -> failures += reason }) {
                        DictTheme("light") { MaterialTheme(typography = MaterialTheme.typography.copy(
                            bodyLarge = MaterialTheme.typography.bodyLarge.copy(fontSize = 20.sp, lineHeight = 20.sp, letterSpacing = 0.sp))) {
                            Box(Modifier.width(value.host.dp).height(720.dp).testTag("width-columns-root")
                                .onGloballyPositioned { rootWindow = it.boundsInWindow() }) {
                                EntryView(entries[phase.value], false, {}, onLink = { opened += it.target },
                                    settings = AppSettings(allowImages = false, allowAudio = false,
                                        collapseOtherSections = false, collapseDetails = false))
                            }
                        } }
                    }
                }
            }
            for ((index, value) in phases.withIndex()) {
                compose.runOnIdle { phase.value = index }
                compose.waitForIdle()
                compose.waitUntil(5_000) { compose.runOnIdle {
                    activeViews().count { it.logicalText.toString() == expectedText(value) &&
                        it.currentMeasuredGeometry?.nodes?.count { node -> node.kind == FloatInteractionKind.LINK } == value.items } == 1
                } }
                var touch = Offset.Zero
                compose.runOnIdle {
                    assertTrue("phase=$index failures=$failures", failures.isEmpty())
                    val view = activeViews().single { it.logicalText.toString() == expectedText(value) }
                    val visible = checkNotNull(view.currentMeasuredGeometry)
                    val geometry = (visible as? NativeSurfaceGeometry)?.content ?: visible
                    val text = expectedText(value)
                    assertEquals(text, geometry.text.toString())
                    assertTrue(rootWindow.width <= value.host + .01f)
                    assertTrue(geometry.width > 0 && geometry.width <= rootWindow.width)
                    // A declaring column direction is inherited by real paragraphs as well as markers.
                    // These leaves have no independent direction override; raw Hebrew stays original text.
                    val paragraphRtl = value.columnDirection?.let { it == BidiResolvedDirection.Rtl }
                        ?: value.tableDirection?.let { it == TableContainingDirection.Rtl } ?: value.rtl
                    val columnRtl = paragraphRtl
                    val links = geometry.nodes.filter { it.kind == FloatInteractionKind.LINK }
                    val markers = geometry.nodes.filter { it.kind == FloatInteractionKind.MARKER }
                    assertEquals(value.items, links.size)
                    assertEquals(value.items, markers.size)
                    assertEquals(List(value.items) { "item-$it" }, links.map { it.label.toString() })
                    assertEquals(links.map { it.start }.sorted(), links.map { it.start })
                    assertEquals(links.map { it.start }, markers.map { it.start })
                    assertTrue(markers.all { it.start == it.end && it.onClick == null && it.bounds.size == 1 })
                    if (value.items > 0) {
                        val columnOwner = checkNotNull(sourceBodies[index].first().container)
                        val expectedItems = phaseItems[index]
                        assertSame(introduction, columnOwner.blocks.first())
                        columnOwner.blocks.drop(1).forEachIndexed { i, block -> assertSame(expectedItems[i], block) }
                        if (value.longItem) {
                            assertEquals(value.breakInside, expectedItems[0].columnBreakInside)
                            assertEquals(value.neighborBreakInside, expectedItems[1].columnBreakInside)
                            expectedItems.forEachIndexed { i, block -> assertSame(smallLinks[i], block.spans.first()) }
                        }
                        if (value.clear) assertSame(emptyClear, sourceBodies[index][1])
                        assertTrue(checkNotNull(emptyClear.container).blocks.isEmpty())
                        assertEquals(ContainerStyle(clear = FigureClear.Both), emptyClear.container!!.style)
                        val containing = geometry.width.toFloat() // zero-edge actual native root and column owner
                        val preferred = 9f * 20f * value.zoom
                        val possible = maxOf(1, kotlin.math.floor(((containing + 12.5f) /
                            (maxOf(1f, preferred) + 12.5f)).toDouble()).toInt())
                        val expectedCount = if (value.fixed) 2 else minOf(value.cap ?: possible, possible)
                        counts[index] = expectedCount
                        val columnWidth = (containing - (expectedCount - 1) * 12.5f) / expectedCount
                        val lanes = markers.map { it.bounds.single().left }.sorted().fold(mutableListOf<Float>()) { result, x ->
                            if (result.isEmpty() || kotlin.math.abs(result.last() - x) > .01f) result += x
                            result
                        }
                        assertEquals("actual source marker lanes, phase=$index C=$containing", expectedCount, lanes.size)
                        lanes.zipWithNext().forEach { (left, right) -> assertEquals(columnWidth + 12.5f, right - left, .01f) }
                        assertEquals(if (columnRtl) lanes.last() else lanes.first(), markers.first().bounds.single().left, .01f)
                        val childPaint = TextPaint().apply {
                            textSize = 20f * value.zoom * if (value.largeChild) 1.2f else .6f
                            typeface = Typeface.MONOSPACE
                        }
                        links.zip(markers).forEachIndexed { i, (link, marker) ->
                            assertEquals(text.indexOf("item-$i"), link.start)
                            assertEquals(link.start + "item-$i".length, link.end)
                            if (!(value.longItem && i == 0)) {
                                val latin = checkNotNull(geometry.characterRects(link.start, 1).single())
                                val hebrew = checkNotNull(geometry.characterRects(link.end + 1, 1).single())
                                assertEquals('א', text[link.end + 1])
                                if (paragraphRtl) assertTrue("Real RTL paragraph places Hebrew before the Latin run",
                                    hebrew.centerX() < latin.centerX())
                                else assertTrue("Real LTR paragraph places the Latin run before Hebrew",
                                    latin.centerX() < hebrew.centerX())
                            }
                            if (!paragraphRtl) assertEquals(childPaint.measureText("item-$i"),
                                kotlin.math.abs(geometry.caretRect(link.end).left - geometry.caretRect(link.start).left), .02f)
                            val firstLine = geometry.visualLineRanges(link.start)
                            val glyphRects = firstLine.flatMap { (start, end) -> geometry.characterRects(start, end - start) }
                                .filterNotNull().filter { !it.isEmpty }
                            assertTrue(glyphRects.isNotEmpty())
                            val markerBox = marker.bounds.single()
                            if (columnRtl) assertTrue("source RTL marker is on the physical right",
                                markerBox.left + 1.01f >= glyphRects.maxOf { it.right })
                            else assertTrue("source LTR marker is on the physical left",
                                markerBox.right - 1.01f <= glyphRects.minOf { it.left })
                            val nativeNode = visible.nodes.single { it.kind == FloatInteractionKind.LINK && it.start == link.start }
                            val hit = nativeNode.bounds.first { !it.isEmpty }
                            assertEquals(nativeNode.id, visible.interactionNodeAt(hit.centerX(), hit.centerY())?.id)
                            val info = checkNotNull(view.accessibilityNodeProvider.createAccessibilityNodeInfo(nativeNode.id))
                            try {
                                assertEquals("item-$i", info.text.toString())
                                assertTrue(info.isClickable)
                                val actual = Rect(); info.getBoundsInParent(actual)
                                val expected = RectF(nativeNode.bounds.first())
                                nativeNode.bounds.drop(1).forEach(expected::union)
                                val parent = Rect(); expected.roundOut(parent); parent.offset(view.paddingLeft, view.paddingTop)
                                assertEquals(parent, actual)
                            } finally { info.recycle() }
                        }
                        if (value.longItem) {
                            val start = text.indexOf("item-0")
                            val end = text.indexOf('\n', start)
                            val rows = (start until end).flatMap(geometry::visualLineRanges).distinct().sortedBy { it.first }
                            val columnEnd = text.indexOf("\nAFTER_COLUMNS")
                            val allRows = (0 until columnEnd).filter { text[it] != '\n' }
                                .flatMap(geometry::visualLineRanges).distinct()
                            assertTrue("The real long owner dominates half the column line count", rows.size >= 6 && rows.size * 2 > allRows.size)
                            val xs = rows.map { (first, last) ->
                                val inkOffset = (first until last).first { !text[it].isWhitespace() }
                                geometry.caretRect(inkOffset).left
                            }.sorted().fold(mutableListOf<Float>()) { result, x ->
                                if (result.isEmpty() || kotlin.math.abs(result.last() - x) > .01f) result += x
                                result
                            }
                            longRows[index] = rows
                            longLanes[index] = xs.size
                            assertEquals(if (value.breakInside == ColumnBreakInside.Avoid) 1 else 2, xs.size)
                        }
                        val first = visible.nodes.first { it.kind == FloatInteractionKind.LINK }
                        assertTrue(view.accessibilityNodeProvider.performAction(first.id, AccessibilityNodeInfo.ACTION_CLICK, null))
                        assertEquals("column-target-0", opened.last())
                        // Actual hit/touch uses the same first original action; no global focus/input-mode changes.
                        val bounds = first.bounds.first { !it.isEmpty }
                        val window = IntArray(2); view.getLocationInWindow(window)
                        touch = Offset(window[0] + view.paddingLeft + bounds.centerX() - rootWindow.left,
                            window[1] + view.paddingTop + bounds.centerY() - rootWindow.top)
                        assertTrue(touch.x in 0f..rootWindow.width && touch.y in 0f..rootWindow.height)
                    }
                    view.setSelection(0, text.length)
                    assertEquals(text, view.selectedTextForCopy())
                    assertTrue(view.accessibilityNodeProvider.performAction(View.NO_ID, AccessibilityNodeInfo.ACTION_SET_SELECTION, null))
                    val characters = geometry.characterRects(0, text.length)
                    text.indices.filter { text[it] != '\n' }.forEach { assertNotNull(characters[it]) }
                    snapshots[index] = Snapshot(text, geometry.width, geometry.extents.usedHeight,
                        (0..text.length).map { RectF(geometry.caretRect(it)) }, characters.map { it?.let(::RectF) },
                        text.indices.map(geometry::visualLineRanges), links.map { it.start to it.end },
                        markers.map { RectF(it.bounds.single()) })
                }
                if (value.items > 0) {
                    val before = opened.size
                    compose.onNodeWithTag("width-columns-root").performTouchInput { click(touch) }
                    compose.waitForIdle()
                    assertEquals(before + 1, opened.size)
                    assertEquals("column-target-0", opened.last())
                }
                compose.onNodeWithText("Unable to display this layout.").assertDoesNotExist()
            }
            assertEquals(1, counts[0]); assertEquals(2, counts[1])
            assertEquals(counts[1], counts[2]) // different actual child advances, identical allocation policy
            assertEquals(1, counts[3]); assertEquals(1, counts[4]); assertEquals(2, counts[5])
            assertEquals(snapshots[5], snapshots[6]) // omitting only the real empty clear sibling
            assertEquals(snapshots[5], snapshots[7])
            assertEquals(snapshots[5], snapshots[8]) // width-null fixed count shares the exact Float pipeline
            assertEquals(snapshots[5], snapshots[10]) // eight-list source restored to original nine owners
            assertEquals(snapshots[11], snapshots[12]) // empty width wrapper + clear adds no line/token/height
            assertEquals(snapshots[1], snapshots[13])
            assertEquals(2, counts[14])
            assertEquals(2, counts[15]); assertEquals(counts[15], counts[16])
            assertEquals(snapshots[15]!!.width, snapshots[16]!!.width)
            assertEquals(snapshots[15]!!.text, snapshots[16]!!.text)
            assertEquals(snapshots[15]!!.actions, snapshots[16]!!.actions)
            assertEquals(snapshots[1], snapshots[17])
            assertEquals(2, longLanes[18]); assertEquals(1, longLanes[19])
            for (index in 19..22) {
                assertEquals(longRows[18], longRows[index]) // Avoid changes column cuts, never native line fitting.
                assertEquals(snapshots[18]!!.text, snapshots[index]!!.text)
                assertEquals(snapshots[18]!!.actions, snapshots[index]!!.actions)
            }
            assertTrue(snapshots[19]!!.usedHeight > snapshots[18]!!.usedHeight)
            assertEquals(snapshots[18], snapshots[20]) // explicit Auto equals null
            assertEquals(snapshots[18], snapshots[21]) // a different short Avoid owner cannot protect item0
            assertEquals(snapshots[18], snapshots[22])
            assertEquals(snapshots[1], snapshots[23])
            assertEquals(List(phases.count { it.items > 0 } * 2) { "column-target-0" }, opened)
        } catch (failure: Throwable) {
            primary = failure
            throw failure
        } finally {
            try {
                compose.activityRule.scenario.onActivity { it.setContent {} }
                compose.waitForIdle()
            } catch (cleanup: Throwable) {
                val original = primary
                if (original == null) throw cleanup
                if (cleanup !== original) original.addSuppressed(cleanup)
            }
        }
    }

    @Test fun exactFloatParagraphGuttersFitAndMapOnceAcrossColumns() {
        // The two legitimate translation orders differ by Float rounding; retain the
        // suite's 0.001px coordinate convention, with native source endpoints exact.
        fun assertRect(expected: RectF, actual: RectF) {
            assertEquals(expected.left, actual.left, .001f)
            assertEquals(expected.top, actual.top, .001f)
            assertEquals(expected.right, actual.right, .001f)
            assertEquals(expected.bottom, actual.bottom, .001f)
        }
        for (rtl in listOf(false, true)) {
            val text = List(20) { if (rtl) "אב" else "ab" }.joinToString(" ")
            val paint = TextPaint(android.graphics.Paint.ANTI_ALIAS_FLAG or android.graphics.Paint.SUBPIXEL_TEXT_FLAG).apply {
                textSize = 18f; typeface = Typeface.MONOSPACE; color = android.graphics.Color.BLUE
            }
            val primary = NativePrimaryFontMetrics.from(paint)
            val source = SpannableString(text).apply {
                setSpan(NativeRunLineMetrics(primary, NativeLineHeightPolicy.Pixels(24f), strut = true),
                    0, length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
                setSpan(NativeAuthoredCursor(InlineCursor.Help), 0, length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
            }
            val measured = android.graphics.text.MeasuredText.Builder(text.toCharArray())
                .appendStyleRun(paint, text.length, rtl).build()
            val prefixWidth = 24.25f
            val insets = if (rtl) NativeTextInsets(left = .0625f, right = 4.125f,
                extraLeft = .0625f, extraRight = prefixWidth)
                else NativeTextInsets(left = 4.125f, right = .0625f, extraLeft = prefixWidth, extraRight = .0625f)
            val left = insets.left + insets.extraLeft
            val right = insets.right + insets.extraRight
            // Two intact words fit at the native measured boundary. Rounding each gutter
            // upward must lose that boundary, independently of the installed font's advances.
            val outerWidth = measured.getWidth(0, 5) + left + right + .125f
            val innerWidth = (outerWidth.toDouble() - left - right).toFloat()
            val breaker = android.graphics.text.LineBreaker.Builder()
                .setBreakStrategy(android.graphics.text.LineBreaker.BREAK_STRATEGY_SIMPLE)
                .setHyphenationFrequency(android.graphics.text.LineBreaker.HYPHENATION_FREQUENCY_NONE).build()
            fun ends(width: Float): List<Int> {
                val result = breaker.computeLineBreaks(measured,
                    android.graphics.text.LineBreaker.ParagraphConstraints().apply { setWidth(width) }, 0)
                return List(result.lineCount) { result.getLineBreakOffset(it) }
            }
            val expectedEnds = ends(innerWidth)
            val roundedEnds = ends((kotlin.math.floor(outerWidth) - kotlin.math.ceil(left) - kotlin.math.ceil(right)).coerceAtLeast(0f))
            assertTrue(expectedEnds.size >= 4)
            assertTrue(expectedEnds.first() >= 5)
            assertTrue("Ceiling the permanent gutters changes the actual native fit", roundedEnds.first() < expectedEnds.first())
            val direction = if (rtl) android.text.TextDirectionHeuristics.RTL else android.text.TextDirectionHeuristics.LTR
            for (alignment in listOf(android.text.Layout.Alignment.ALIGN_NORMAL,
                android.text.Layout.Alignment.ALIGN_CENTER, android.text.Layout.Alignment.ALIGN_OPPOSITE)) {
                var markerPaints = 0
                var clicked = 0
                val prefixPaint = TextPaint().apply { set(paint); color = android.graphics.Color.RED }
                val marker = NativeMarkerText("1.", prefixPaint)
                fun markerBounds(geometry: NativeFloatGeometry): NativeFloatBounds? {
                    val band = geometry.firstLineBand()
                    val x = if (rtl) band.right + prefixWidth else band.left - prefixWidth
                    return marker.bounds(x, band.top - prefixPaint.ascent(), rightAligned = rtl)
                }
                val ordinary = NativeFloatGeometry.build(source, paint, kotlin.math.floor(innerWidth).toInt(), emptyList(),
                    textDirection = direction, alignment = alignment, exactAvailableWidth = innerWidth)
                val original = NativeFloatGeometry.build(source, paint, kotlin.math.floor(outerWidth).toInt(), emptyList(),
                    textDirection = direction, alignment = alignment, insets = insets,
                    exactAvailableWidth = outerWidth, exactParagraphInsets = true,
                    nodeFactory = { geometry -> listOf(FloatInteractionNode(0, FloatInteractionKind.LINK, 0, text.length,
                        geometry.rectsForRange(0, text.length), text, null, { clicked++ })) },
                    decoration = { canvas, geometry ->
                        markerPaints++
                        val band = geometry.firstLineBand()
                        val x = if (rtl) band.right + prefixWidth else band.left - prefixWidth
                        marker.paint(canvas, x, band.top - prefixPaint.ascent(), rightAligned = rtl)
                    }, decorationBounds = ::markerBounds)
                assertEquals(text, original.text.toString())
                assertEquals(expectedEnds.size, original.shapedLineCount)
                assertEquals(left, original.firstLineBand().left, 0f)
                assertEquals(left + innerWidth, original.firstLineBand().right, 0f)
                var first = 0
                for ((line, end) in expectedEnds.withIndex()) {
                    assertEquals(first to end, original.lineRange(first))
                    assertEquals(24f, original.usedLineHeight(line), 0f)
                    assertEquals(ordinary.baselineForOffset(first), original.baselineForOffset(first), 0f)
                    for (offset in first until end) {
                        val old = ordinary.caretRect(offset).apply { offset(left, 0f) }
                        assertRect(old, original.caretRect(offset))
                        val before = ordinary.rectsForRange(offset, offset + 1).map { RectF(it).apply { offset(left, 0f) } }
                        val actual = original.rectsForRange(offset, offset + 1)
                        assertEquals(before.size, actual.size)
                        before.zip(actual).forEach { (expected, placed) -> assertRect(expected, placed) }
                    }
                    first = end
                }
                val lines = List(original.shapedLineCount) { NativeColumnLine(0, it, original.usedLineHeight(it)) }
                val balanced = balanceNativeColumns(lines, 2)
                val gap = 12.5f
                val totalWidth = 2f * outerWidth + gap
                val origins = balanced.placements.map { placement ->
                    val x = if (rtl) totalWidth - outerWidth - placement.column * (outerWidth + gap)
                        else placement.column * (outerWidth + gap)
                    (x + .375f) to placement.top
                }
                val columns = original.inColumns(origins)
                assertEquals(text, columns.text.toString())
                assertEquals(1, columns.nodes.size)
                assertEquals(text, columns.nodes.single().label)
                assertEquals(0, columns.nodes.single().start)
                assertEquals(text.length, columns.nodes.single().end)
                assertRect(original.firstLineBand().apply { offset(origins.first().first, origins.first().second) }, columns.firstLineBand())
                first = 0
                for ((line, end) in expectedEnds.withIndex()) {
                    val dx = origins[line].first
                    val dy = origins[line].second - original.nativeRubyLineTop(line)
                    assertEquals(first to end, columns.lineRange(first))
                    assertEquals(original.baselineForOffset(first) + dy, columns.baselineForOffset(first), .001f)
                    for (offset in first until end) {
                        assertRect(original.caretRect(offset).apply { offset(dx, dy) }, columns.caretRect(offset))
                        val before = original.rectsForRange(offset, offset + 1)
                        val after = columns.rectsForRange(offset, offset + 1)
                        assertEquals(before.size, after.size)
                        before.zip(after).forEach { (expected, placed) ->
                            assertRect(RectF(expected).apply { offset(dx, dy) }, placed)
                        }
                        if (text[offset] != ' ') for (box in after) {
                            // Stay away from a cursor midpoint tie during inverse translation.
                            val x = box.left + box.width() * .25f
                            val y = box.centerY()
                            assertEquals(original.offsetForPosition(x - dx, y - dy), columns.offsetForPosition(x, y))
                            assertEquals(InlineCursor.Help, columns.cursorAt(x, y))
                            assertEquals(columns.nodes.single(), columns.interactionNodeAt(x, y))
                        }
                    }
                    first = end
                }
                columns.nodes.single().onClick!!.invoke()
                assertEquals(1, clicked)
                val bitmap = Bitmap.createBitmap(kotlin.math.ceil(totalWidth + 64f).toInt(),
                    kotlin.math.ceil(balanced.height + 64f).toInt(), Bitmap.Config.ARGB_8888)
                try {
                    columns.paint(Canvas(bitmap).apply { translate(24f, 24f) })
                    assertEquals("Original paragraph prefix paints once across all fragments", 1, markerPaints)
                    var red = 0
                    var blue = 0
                    for (y in 0 until bitmap.height) for (x in 0 until bitmap.width) {
                        val pixel = bitmap.getPixel(x, y)
                        if (android.graphics.Color.alpha(pixel) == 0) continue
                        if (android.graphics.Color.red(pixel) > 0 && android.graphics.Color.green(pixel) == 0 && android.graphics.Color.blue(pixel) == 0) red++
                        if (android.graphics.Color.blue(pixel) > 0 && android.graphics.Color.green(pixel) == 0 && android.graphics.Color.red(pixel) == 0) blue++
                    }
                    assertTrue(red > 0)
                    assertTrue(blue > 0)
                } finally { bitmap.recycle() }
            }
            val overconstrained = NativeFloatGeometry.build(source, paint, 4, emptyList(), textDirection = direction,
                insets = insets, exactAvailableWidth = 4f, exactParagraphInsets = true)
            assertEquals(text, overconstrained.text.toString())
            assertEquals(left, overconstrained.firstLineBand().left, 0f)
            assertEquals(left, overconstrained.firstLineBand().right, 0f)
            assertEquals(measured.getWidth(0, text.length),
                nativeFloatRowIntrinsicWidths(source, paint, direction, false).maximum, 0f)
            assertThrows(UnsupportedFloatLayout::class.java) {
                NativeFloatGeometry.build(source, paint, kotlin.math.floor(outerWidth).toInt(), emptyList(),
                    insets = insets, exactAvailableWidth = outerWidth)
            }
            assertThrows(UnsupportedFloatLayout::class.java) {
                NativeFloatGeometry.build(source, paint, 100, emptyList(), exactParagraphInsets = true)
            }
            assertThrows(UnsupportedFloatLayout::class.java) {
                NativeFloatGeometry.build(source, paint, 100, emptyList(), exactAvailableWidth = 100f,
                    exactParagraphInsets = true, carriedExclusions = listOf(NativeFloatExclusion(TableFloatSide.Left,
                        NativeFloatBounds(0f, 0f, 10f, 10f))))
            }
            val leading = SpannableString(source).apply { setSpan(android.text.style.LeadingMarginSpan.Standard(1, 2),
                0, length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE) }
            assertThrows(UnsupportedFloatLayout::class.java) {
                NativeFloatGeometry.build(leading, paint, 100, emptyList(), exactAvailableWidth = 100f, exactParagraphInsets = true)
            }
            assertEquals(text, NativeFloatGeometry.build(source, paint, 100, emptyList(), insets = insets,
                textDirection = direction).text.toString())
        }
    }

    @Test fun emptyClearColumnEventsRetainIdentityWithoutTextHeightOrPaint() {
        val paint = TextPaint().apply { textSize = 16f; typeface = Typeface.MONOSPACE; isAntiAlias = true }
        var builds = 0
        var clearBuilds = 0
        var clicks = 0
        val click: () -> Unit = { clicks++ }
        fun text(value: String, gap: Float): NativeFloatContextPart.Text {
            val source = SpannableString(value)
            fun shape(width: Float): NativeFloatGeometry {
                builds++
                return NativeFloatGeometry.build(source, paint, kotlin.math.floor(width).toInt(), emptyList(),
                    textDirection = android.text.TextDirectionHeuristics.LTR,
                    exactAvailableWidth = width, exactParagraphInsets = true,
                    usedLineMetrics = { _, _ -> NativeUsedLineMetrics(-8f, 2f) },
                    nodeFactory = { geometry -> listOf(FloatInteractionNode(0, FloatInteractionKind.LINK,
                        0, value.length, geometry.rectsForRange(0, value.length), value, null, click)) })
            }
            return NativeFloatContextPart.Text(source, { width, carried ->
                check(carried.isEmpty()); shape(width.toFloat())
            }, gapAfter = gap, buildInColumns = ::shape)
        }
        fun clear(id: Int) = NativeFloatContextPart.Container(id, 0, { _, _ ->
            clearBuilds++; error("A retained empty clear event must not construct a text subtree")
        }, clear = FigureClear.Both, empty = true, preparedParts = emptyList(), columnClearEvent = true)
        fun build(parts: List<NativeFloatContextPart>) = NativeFloatContextGeometry.buildPreparedColumns(
            202, 202.5f, parts, NativeColumnPolicy(2, 3.25f, false), NativeOrdinaryPreparation(parts))
        val first = text("a\nb\nc\nd", 7.25f)
        val last = text("e\nf", 0f)
        val ordinary = build(listOf(first, last))
        assertEquals(2, builds)
        val before = clear(101)
        val between = clear(102)
        val after = clear(103)
        val withEvents = build(listOf(before, first, between, last, after))
        assertEquals(4, builds)
        assertEquals(0, clearBuilds)
        assertEquals(ordinary.text.toString(), withEvents.text.toString())
        assertEquals("a\nb\nc\nd\ne\nf", withEvents.text.toString())
        assertEquals(ordinary.height, withEvents.height)
        assertEquals(ordinary.usedHeight, withEvents.usedHeight, 0f)
        assertEquals(ordinary.textBottom, withEvents.textBottom, 0f)
        assertEquals(listOf(0, 0, first.text.length, first.text.length + 1, withEvents.text.length), withEvents.partOffsets)
        assertEquals(setOf(101, 102, 103), withEvents.ordinaryBounds.keys)
        for (id in listOf(101, 102, 103)) {
            assertEquals(0f, checkNotNull(withEvents.ordinaryBounds[id]).height(), 0f)
            assertEquals(0f, checkNotNull(withEvents.clearanceById[id]), 0f)
        }
        assertTrue(withEvents.children.isEmpty())
        assertTrue(withEvents.flowChildren.isEmpty())
        assertEquals(2, withEvents.nodes.size)
        assertEquals(ordinary.nodes.map { it.start to it.end }, withEvents.nodes.map { it.start to it.end })
        assertEquals(ordinary.nodes.map { it.label }, withEvents.nodes.map { it.label })
        withEvents.nodes.forEach { assertSame(click, it.onClick); it.onClick!!.invoke() }
        assertEquals(2, clicks)
        for (offset in 0..ordinary.text.length) {
            assertEquals(ordinary.caretRect(offset), withEvents.caretRect(offset))
            assertEquals(ordinary.lineRange(offset), withEvents.lineRange(offset))
        }
        val plainPixels = Bitmap.createBitmap(220, 100, Bitmap.Config.ARGB_8888)
        val eventPixels = Bitmap.createBitmap(220, 100, Bitmap.Config.ARGB_8888)
        ordinary.paint(Canvas(plainPixels)); withEvents.paint(Canvas(eventPixels))
        val expected = IntArray(220 * 100); val actual = IntArray(220 * 100)
        plainPixels.getPixels(expected, 0, 220, 0, 0, 220, 100)
        eventPixels.getPixels(actual, 0, 220, 0, 0, 220, 100)
        assertArrayEquals(expected, actual)
        assertTrue(actual.any { android.graphics.Color.alpha(it) != 0 })
        val empty = build(listOf(before, between, after))
        assertEquals("", empty.text.toString())
        assertEquals(0, empty.height)
        assertEquals(0f, empty.usedHeight, 0f)
        assertNull(empty.textBaselines)
        assertTrue(empty.nodes.isEmpty())
        assertEquals(listOf(0, 0, 0), empty.partOffsets)
        assertEquals(4, builds)
        assertEquals(0, clearBuilds)
        assertThrows(UnsupportedFloatLayout::class.java) {
            build(listOf(before.copy(padding = FloatMargins(0f, 0f, 0f, .25f)), first, last))
        }
        assertEquals(ordinary.usedHeight, build(listOf(first, between, last)).usedHeight, 0f)
        // Only the actual zero-edge source shape earns this event classification.
        val sourceClear = ContainerStyle(clear = FigureClear.Both)
        fun admitted(style: ContainerStyle) = nativeContainerSpec(500, style.atViewport(202.5f), emptyList(),
            1f, 20f, rtl = false, dark = false, flexItem = false)
        assertTrue(admitted(sourceClear).columnClearEvent)
        assertFalse(admitted(sourceClear.copy(height = StyleLength(StyleLengthUnit.Px, 1f))).columnClearEvent)
        assertFalse(admitted(sourceClear.copy(padding = StyleEdges(StyleLength(StyleLengthUnit.Px, 1f),
            StyleLength(StyleLengthUnit.Px, 0f), StyleLength(StyleLengthUnit.Px, 0f), StyleLength(StyleLengthUnit.Px, 0f)))).columnClearEvent)
    }
}
