package app.smallthingz.dict

import android.graphics.Bitmap
import android.graphics.RectF
import android.os.SystemClock
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.View
import android.view.accessibility.AccessibilityNodeInfo
import androidx.activity.compose.setContent
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.text.contextmenu.data.TextContextMenuItem
import androidx.compose.foundation.text.contextmenu.data.TextContextMenuKeys
import androidx.compose.foundation.text.contextmenu.data.TextContextMenuSession
import androidx.compose.foundation.text.contextmenu.provider.LocalTextContextMenuToolbarProvider
import androidx.compose.foundation.text.contextmenu.provider.TextContextMenuDataProvider
import androidx.compose.foundation.text.contextmenu.provider.TextContextMenuProvider
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.toPixelMap
import androidx.compose.ui.layout.Layout
import androidx.compose.ui.layout.LayoutCoordinates
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.platform.ClipEntry
import androidx.compose.ui.platform.Clipboard
import androidx.compose.ui.platform.LocalClipboard
import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.hasAnyAncestor
import androidx.compose.ui.test.hasClickAction
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.longClick
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performSemanticsAction
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.platform.UriHandler
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.captureToImage
import androidx.compose.ui.test.click
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performTouchInput
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.unit.Density
import androidx.test.ext.junit.runners.AndroidJUnit4
import kotlinx.coroutines.CompletableDeferred
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference

@RunWith(AndroidJUnit4::class)
class FigureMediaPaintDeviceTest {
    @get:Rule val compose = createPhysicalComposeRule()
    private fun px(value: Float) = StyleLength(StyleLengthUnit.Px, value)
    private val edges = FigureBorderEdges(FigureBorderEdge.None, FigureBorderEdge.None, FigureBorderEdge.None, FigureBorderEdge.None)
    private val image = InlineImage("Figure-control.png", widthPx = 100L, heightPx = 40L, alt = "")
    private val media = listOf(Media(image.file, "image", ""))
    private val strut = FigureMediaStrut(1f, direction = BidiResolvedDirection.Ltr)
    private fun policy(graphic: Boolean = true, cap: Boolean = false) = FigureMediaLayout(strut,
        InlineBoxVerticalAlign.Middle, maxWidth = if (cap) AvailableWidthLimit(100f, px(4f)) else null,
        positioning = ContainerPositioning.RelativeAuto,
        after = FigureMediaAfter(px(15f), px(11f), TableFloatSide.Right, px(6f),
            SignedContainerMargin(StyleLengthUnit.Px, -11f),
            if (graphic) FigureGraphicPaint(FigureMediaGraphic.MagnifyClipLtrV1) else null),
        focusOutline = FigureFocusOutline(px(2f), FigureColor.Rgb("#ff0000"), px(2f),
            SignedContainerMargin(StyleLengthUnit.Px, 0f)))
    private fun figure(caption: List<Span>, graphic: Boolean = true, cap: Boolean = false): Figure {
        val zero = StyleEdges(px(0f), px(0f), px(0f), px(0f))
        return Figure(FigureContent.Image(Span("link", "", "File:Figure-control.png", image = image), FigureSizingPolicy.RequestedFit),
            FigureFormat.Thumbnail, FigurePlacement.None, FigureClear.None, zero, zero, zero,
            1f, px(24f), FigureColor.Transparent, FigureBorder.None, FigureColor.Transparent, FigureBorder.None,
            FigureColor.NativeTheme, FigureColor.Rgb("#00ff00"), caption = caption,
            tableCaptionLayout = TableCaptionLayout(TableCollapse.Collapse, ContainerStyle(), edges, edges, policy(graphic, cap)))
    }
    private fun nativeView(): NativeFloatTextView {
        var result: NativeFloatTextView? = null
        compose.activityRule.scenario.onActivity { activity ->
            fun visit(view: View) {
                if (view is NativeFloatTextView) { check(result == null); result = view }
                if (view is android.view.ViewGroup) for (i in 0 until view.childCount) visit(view.getChildAt(i))
            }
            visit(activity.window.decorView)
        }
        return checkNotNull(result)
    }

    @Test fun sourceMagnifyMeetTransformPaintsLetterboxAndClipsOnlyItsViewport() {
        val bitmap = Bitmap.createBitmap(70, 55, Bitmap.Config.ARGB_8888)
        try {
            fun render(graphic: FigureMediaGraphic, invert: Boolean = false) {
                bitmap.eraseColor(android.graphics.Color.GREEN)
                paintFigureMagnifyGraphic(android.graphics.Canvas(bitmap), 10f, 10f, 3f,
                    FigureGraphicPaint(graphic, invert))
            }
            render(FigureMediaGraphic.MagnifyClipLtrV1)
            // x=19 is inside the actual SVG viewport but left of the transformed viewBox.
            assertEquals(android.graphics.Color.WHITE, bitmap.getPixel(19, 30))
            assertEquals(android.graphics.Color.GREEN, bitmap.getPixel(9, 30))
            assertEquals(android.graphics.Color.GREEN, bitmap.getPixel(55, 30))
            assertEquals(android.graphics.Color.GREEN, bitmap.getPixel(30, 43))
            val first = IntArray(70 * 55); bitmap.getPixels(first, 0, 70, 0, 0, 70, 55)
            render(FigureMediaGraphic.MagnifyClipRtlV1)
            assertEquals(android.graphics.Color.WHITE, bitmap.getPixel(45, 30))
            for (y in 10 until 43) for (x in 10 until 55) {
                val a = first[y * 70 + x]
                val b = bitmap.getPixel(64 - x, y)
                for (shift in listOf(0, 8, 16, 24))
                    assertTrue(kotlin.math.abs((a ushr shift and 255) - (b ushr shift and 255)) <= 2)
            }
            render(FigureMediaGraphic.MagnifyClipLtrV1, invert = true)
            assertEquals(android.graphics.Color.BLACK, bitmap.getPixel(19, 30))
            assertEquals(android.graphics.Color.GREEN, bitmap.getPixel(9, 30))
        } finally { bitmap.recycle() }
    }

    @Test fun negativeOutlineOffsetsStayPaintedWithinTheirClampedOutsideBounds() {
        val bitmap = Bitmap.createBitmap(70, 55, Bitmap.Config.ARGB_8888)
        try {
            val cases = listOf(-100f to android.graphics.Rect(23, 19, 27, 23),
                -2f to android.graphics.Rect(20, 19, 30, 23),
                0f to android.graphics.Rect(18, 18, 32, 24),
                4f to android.graphics.Rect(14, 14, 36, 28))
            for ((offset, outside) in cases) {
                bitmap.eraseColor(android.graphics.Color.GREEN)
                paintNativeFocusOutline(android.graphics.Canvas(bitmap), NativeNodeFocusPaint.Outline(
                    RectF(20f, 20f, 30f, 22f), 2f, android.graphics.Color.BLUE, 0f, offset))
                assertEquals(android.graphics.Color.BLUE, bitmap.getPixel(outside.centerX(), outside.top))
                assertEquals(android.graphics.Color.GREEN, bitmap.getPixel(outside.left - 1, outside.centerY()))
                assertEquals(android.graphics.Color.GREEN, bitmap.getPixel(outside.right, outside.centerY()))
                assertEquals(android.graphics.Color.GREEN, bitmap.getPixel(outside.centerX(), outside.top - 1))
                assertEquals(android.graphics.Color.GREEN, bitmap.getPixel(outside.centerX(), outside.bottom))
            }
            bitmap.eraseColor(android.graphics.Color.GREEN)
            paintNativeFocusOutline(android.graphics.Canvas(bitmap), NativeNodeFocusPaint.Outline(
                RectF(20f, 20f, 30f, 22f), 0f, android.graphics.Color.BLUE, 0f, -100f))
            assertEquals(android.graphics.Color.GREEN, bitmap.getPixel(25, 20))
        } finally { bitmap.recycle() }
    }

    @Test fun wholeAnchorPaintAndTransparentAfterHitShareOneOwnerAcrossResizeAndCaptionChanges() {
        val width = mutableStateOf(900)
        val caption = mutableStateOf(true)
        val graphic = mutableStateOf(true)
        val bitmap = Bitmap.createBitmap(10, 4, Bitmap.Config.ARGB_8888).apply { eraseColor(android.graphics.Color.BLUE) }
        val settings = AppSettings(allowImages = false, allowAudio = false)
        val actions = mutableListOf<String>()
        val sourceUris = mutableListOf<String>()
        val actionEdition = mutableStateOf("")
        val sourceHandler = object : UriHandler { override fun openUri(uri: String) { sourceUris += uri } }
        var owner: InlineImageViewOwner? = null
        var created = 0
        var disposed = 0
        var geometry: NativeAnonymousFlowGeometry? = null
        try {
            compose.activityRule.scenario.onActivity { activity -> activity.setContent {
                MaterialTheme { CompositionLocalProvider(LocalDensity provides Density(1f, 1f),
                    LocalUriHandler provides sourceHandler) {
                    val activeOwner = rememberInlineImageViewOwner(listOf(image), media, settings, "enwiktionary-20261001")
                    androidx.compose.runtime.remember(activeOwner) {
                        activeOwner.states[image.file] = InlineImageAssetState.Ready(DecodedMediaBitmap(bitmap, 10, 4),
                            100, 40, "image/png", "controlled pixels", "")
                        true
                    }
                    DisposableEffect(activeOwner) { created++; onDispose { disposed++ } }
                    SideEffect { owner = activeOwner }
                    val spans = if (caption.value) listOf(Span("link", "caption link", "caption")) else emptyList()
                    val block = Block("paragraph", 0, emptyList(), figure = figure(spans, graphic.value))
                    val currentWidth = width.value
                    CompositionLocalProvider(LocalInlineImageOwner provides activeOwner) {
                        Layout(modifier = Modifier.testTag("figure-phase").background(Color.White), content = {
                            val flow = NativeFloatContextSpec.Flow(10, 0f, null, null, false) { carried, sink ->
                                AnonymousBlockView(block, Modifier, { actions += it.target }, media, settings, actionEdition.value,
                                    interactionOwner = false, carriedExclusions = carried,
                                    onFlowGeometry = { geometry = it; sink(it) })
                            }
                            val following = NativeFloatContextSpec.Child(20, { it }, 0f, logicalObject = false)
                            NativeFloatContextLayout(listOf(flow, following), Modifier, Color.Magenta) { _, _ ->
                                Layout(modifier = Modifier.background(Color.Green).clickable { actions += "following" }, content = {}) { _, c ->
                                    layout(c.maxWidth, 24) { }
                                }
                            }
                        }) { children, _ ->
                            val child = children.single().measure(Constraints.fixedWidth(currentWidth - 40))
                            layout(currentWidth, child.height + 40) { child.place(20, 20) }
                        }
                    }
                } }
            } }
            compose.waitForIdle()
            val originalOwner = owner
            fun verifyGraphic(expected: Boolean) {
                val captured = compose.onNodeWithTag("figure-phase").captureToImage().toPixelMap()
                val box = compose.runOnIdle { RectF(checkNotNull(geometry).nodes.single { it.kind == FloatInteractionKind.IMAGE }.bounds.last()) }
                var white = 0
                var black = 0
                for (y in kotlin.math.ceil(box.top).toInt() until kotlin.math.floor(box.bottom).toInt())
                    for (x in kotlin.math.ceil(box.left).toInt() until kotlin.math.floor(box.right).toInt()) {
                        val color = captured[x + 20, y + 20]
                        if (color.red > .98f && color.green > .98f && color.blue > .98f) white++
                        if (color.red < .4f && color.green < .4f && color.blue < .4f) black++
                    }
                if (expected) { assertTrue(white > 0); assertTrue(black > 0) }
                else assertEquals(Color.Green, captured[box.centerX().toInt() + 20, box.bottom.toInt() - 1 + 20])
            }
            verifyGraphic(true)
            compose.runOnIdle {
                assertEquals("caption link", checkNotNull(geometry).text.toString())
                val imageNode = checkNotNull(geometry).nodes.single { it.kind == FloatInteractionKind.IMAGE }
                assertEquals(2, imageNode.bounds.size)
                assertEquals(100f, imageNode.bounds.first().width(), .01f)
                assertEquals(40f, imageNode.bounds.first().height(), .01f)
                assertEquals(1, created); assertEquals(0, disposed)
                caption.value = false
                graphic.value = false
                width.value = 240
            }
            compose.waitForIdle()
            verifyGraphic(false)
            var point: Offset? = null
            compose.runOnIdle {
                val g = checkNotNull(geometry)
                assertSame(originalOwner, owner)
                assertEquals(1, created); assertEquals(0, disposed)
                assertEquals("", g.text.toString())
                val after = g.nodes.single { it.kind == FloatInteractionKind.IMAGE }.bounds.last()
                assertTrue(after.top >= g.figures.single().bounds.bottom - .01f)
                assertTrue(after.bottom > g.textBottom)
                assertTrue(g.scrollableBounds.bottom >= after.bottom)
                point = Offset(after.centerX() + 20, after.bottom - 1f + 20)
                val unresolved = g.nodes.single { it.kind == FloatInteractionKind.IMAGE }
                assertNull(unresolved.onClick)
                assertTrue(unresolved.stateDescription!!.contains("Image link source unavailable"))
            }
            val view = nativeView()
            compose.onNodeWithTag("figure-phase").performTouchInput { click(checkNotNull(point)) }
            compose.runOnIdle {
                assertTrue(actions.isEmpty()); assertTrue(sourceUris.isEmpty())
                actionEdition.value = "enwiktionary-20261001"
            }
            compose.waitForIdle()
            verifyGraphic(false)
            assertSame(view, nativeView())
            compose.runOnIdle {
                val node = checkNotNull(geometry).nodes.single { it.kind == FloatInteractionKind.IMAGE }
                assertNotNull(node.onClick)
                assertFalse(node.stateDescription!!.contains("Image link source unavailable"))
                val after = node.bounds.last()
                point = Offset(after.centerX() + 20, after.bottom - 1f + 20)
                assertSame(originalOwner, owner); assertEquals(1, created); assertEquals(0, disposed)
            }
            compose.onNodeWithTag("figure-phase").performTouchInput { click(checkNotNull(point)) }
            compose.runOnIdle {
                assertEquals(listOf("https://en.wiktionary.org/wiki/File%3AFigure-control.png"), sourceUris)
                assertTrue(actions.isEmpty())
            }
            fun outline(expected: Boolean) {
                compose.waitForIdle()
                val color = compose.onNodeWithTag("figure-phase").captureToImage().toPixelMap()[40, 19]
                if (expected) assertEquals(Color.Red, color) else assertNotEquals(Color.Red, color)
            }
            outline(false)
            compose.runOnIdle {
                val node = checkNotNull(geometry).nodes.single { it.kind == FloatInteractionKind.IMAGE }
                val provider = view.accessibilityNodeProvider
                val info = checkNotNull(provider.createAccessibilityNodeInfo(node.id))
                assertTrue(info.isVisibleToUser)
                assertFalse(info.isFocused)
                assertTrue(view.requestFocus())
                assertTrue(provider.performAction(node.id, AccessibilityNodeInfo.ACTION_ACCESSIBILITY_FOCUS, null))
                assertFalse(checkNotNull(provider.createAccessibilityNodeInfo(node.id)).isFocused)
            }
            outline(false)
            compose.runOnIdle {
                val node = checkNotNull(geometry).nodes.single { it.kind == FloatInteractionKind.IMAGE }
                val provider = view.accessibilityNodeProvider
                assertTrue(provider.performAction(node.id, AccessibilityNodeInfo.ACTION_CLEAR_ACCESSIBILITY_FOCUS, null))
                assertTrue(view.dispatchKeyEvent(KeyEvent(KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_TAB)))
                view.dispatchKeyEvent(KeyEvent(KeyEvent.ACTION_UP, KeyEvent.KEYCODE_TAB))
                assertTrue(checkNotNull(provider.createAccessibilityNodeInfo(node.id)).isFocused)
            }
            outline(true)
            compose.runOnIdle {
                val node = checkNotNull(geometry).nodes.single { it.kind == FloatInteractionKind.IMAGE }
                assertTrue(view.accessibilityNodeProvider.performAction(node.id, AccessibilityNodeInfo.ACTION_CLEAR_FOCUS, null))
            }
            outline(false)
            compose.runOnIdle {
                val node = checkNotNull(geometry).nodes.single { it.kind == FloatInteractionKind.IMAGE }
                val provider = view.accessibilityNodeProvider
                assertTrue(provider.performAction(node.id, AccessibilityNodeInfo.ACTION_FOCUS, null))
                assertEquals(1, checkNotNull(provider.findAccessibilityNodeInfosByText(image.file, View.NO_ID)).size)
            }
            outline(true)
            compose.runOnIdle { width.value = 900; graphic.value = true; caption.value = true }
            compose.waitForIdle()
            verifyGraphic(true)
            compose.runOnIdle { assertSame(originalOwner, owner); assertEquals(1, created); assertEquals(0, disposed) }
        } finally {
            compose.activityRule.scenario.onActivity { it.setContent {} }
            compose.waitForIdle()
            bitmap.recycle()
        }
        assertEquals(1, disposed)
    }

    @Test fun actualStatusTextAndRetryUseTheSameCaptionGraphAndCappedReadyRatio() {
        val directory = File(compose.activity.cacheDir, "figure-table-caption-" + UUID.randomUUID()).apply { mkdirs() }
        val bitmap = Bitmap.createBitmap(10, 4, Bitmap.Config.ARGB_8888).apply { eraseColor(android.graphics.Color.BLUE) }
        val png = ByteArrayOutputStream().use { out -> bitmap.compress(Bitmap.CompressFormat.PNG, 100, out); out.toByteArray() }
        bitmap.recycle()
        val gate = AtomicReference(CountDownLatch(1))
        val calls = AtomicInteger()
        val downloads = AtomicInteger()
        val cache = MediaCache(compose.activity, directory = directory, metadata = {
            val number = calls.incrementAndGet()
            check(gate.get().await(5, TimeUnit.SECONDS)) { "Controlled media release missing" }
            if (number == 1) throw java.io.IOException("Controlled unavailable image")
            """{"query":{"pages":[{"imageinfo":[{"url":"https://fixture.invalid/figure.png","width":100,"height":40,"mime":"image/png"}]}]}}""".toByteArray()
        }, openMedia = { downloads.incrementAndGet(); ByteArrayInputStream(png) })
        val settings = AppSettings(allowImages = true, allowAudio = false, mediaCacheMb = 1)
        val block = Block("paragraph", 0, emptyList(), figure = figure(listOf(Span("link", "caption", "caption")), cap = true))
        val width = mutableStateOf(240)
        var owner: InlineImageViewOwner? = null
        var geometry: NativeAnonymousFlowGeometry? = null
        var created = 0
        var disposed = 0
        try {
            compose.activityRule.scenario.onActivity { activity -> activity.setContent {
                MaterialTheme { CompositionLocalProvider(LocalDensity provides Density(1f, 1f), LocalInlineImageCache provides cache) {
                    val activeOwner = rememberInlineImageViewOwner(listOf(image), media, settings, "")
                    androidx.compose.runtime.remember(activeOwner) { activeOwner.states[image.file] = InlineImageAssetState.Disabled; true }
                    DisposableEffect(activeOwner) { created++; onDispose { disposed++ } }
                    SideEffect { owner = activeOwner }
                    val currentWidth = width.value
                    CompositionLocalProvider(LocalInlineImageOwner provides activeOwner) {
                        Layout(modifier = Modifier.testTag("figure-status"), content = {
                            NativeFloatContextLayout(listOf(NativeFloatContextSpec.Flow(1, 0f, null, null, false) { carried, sink ->
                                AnonymousBlockView(block, Modifier, {}, media, settings, "", interactionOwner = false,
                                    carriedExclusions = carried, onFlowGeometry = { geometry = it; sink(it) })
                            }), Modifier, Color.Magenta, documentSurface = true) { _, _ -> error("No delegated child") }
                        }) { children, _ ->
                            val child = children.single().measure(Constraints.fixedWidth(currentWidth))
                            layout(currentWidth, child.height) { child.place(0, 0) }
                        }
                    }
                } }
            } }
            compose.waitForIdle()
            val originalOwner = checkNotNull(owner)
            val originalText = checkNotNull(geometry).text.toString()
            val originalIds = checkNotNull(geometry).nodes.map { it.id }
            fun state(expected: String) {
                compose.waitForIdle()
                compose.runOnIdle {
                    val g = checkNotNull(geometry)
                    val node = g.nodes.single { it.kind == FloatInteractionKind.IMAGE }
                    assertTrue(node.stateDescription.toString().contains(expected))
                    assertEquals(originalText, g.text.toString())
                    assertEquals(originalIds, g.nodes.map { it.id })
                    assertSame(originalOwner, owner); assertEquals(1, created); assertEquals(0, disposed)
                    assertTrue(node.bounds.first().height() > 0f)
                    assertTrue(g.extents.ink!!.bottom >= node.bounds.last().bottom)
                }
            }
            state("Images disabled")
            assertEquals(0, calls.get())
            compose.runOnIdle { originalOwner.retry(image) }
            state("Loading image")
            gate.get().countDown()
            compose.waitUntil(5000) { originalOwner.states[image.file] == InlineImageAssetState.Failed }
            state("Image unavailable")
            gate.set(CountDownLatch(1))
            compose.runOnIdle { originalOwner.retry(image) }
            state("Loading image")
            gate.get().countDown()
            compose.waitUntil(5000) { originalOwner.states[image.file] is InlineImageAssetState.Ready }
            compose.waitForIdle()
            compose.runOnIdle {
                val anchor = checkNotNull(geometry).nodes.single { it.kind == FloatInteractionKind.IMAGE }.bounds.first()
                assertEquals(38.4f, anchor.height(), .02f)
                assertEquals(originalText, checkNotNull(geometry).text.toString())
                assertSame(originalOwner, owner); assertEquals(1, created); assertEquals(0, disposed)
                width.value = 80
            }
            compose.waitForIdle()
            compose.runOnIdle {
                assertSame(originalOwner, owner); assertEquals(1, created)
                val anchor = checkNotNull(geometry).nodes.single { it.kind == FloatInteractionKind.IMAGE }.bounds.first()
                assertTrue(anchor.height() < 38.4f)
                width.value = 240
            }
            compose.waitForIdle()
            compose.runOnIdle {
                assertEquals(originalIds, checkNotNull(geometry).nodes.map { it.id })
                assertEquals(38.4f, checkNotNull(geometry).nodes.single { it.kind == FloatInteractionKind.IMAGE }.bounds.first().height(), .02f)
            }
            assertEquals(2, calls.get()); assertEquals(1, downloads.get())
        } finally {
            gate.get().countDown()
            compose.activityRule.scenario.onActivity { it.setContent {} }
            compose.waitForIdle()
            directory.deleteRecursively()
        }
        assertEquals(1, disposed)
    }

    @Test fun delegatedTableAndScrollportRefuseUnjoinedPositionedMediaButKeepCaptionAndAction() {
        val scrollport = mutableStateOf(false)
        val actions = mutableListOf<String>()
        val caption = "retained caption link"
        val tail = " and retained body"
        val fullText = caption + tail
        val body = Block("paragraph", 0, emptyList(), figure = figure(listOf(
            Span("link", caption, "caption-target"), Span("text", tail))))
        val table = Block("table", 0, emptyList(), table = Table(emptyList(), listOf(
            listOf(Cell(emptyList(), false, 1, 1, blocks = listOf(body))))))
        val container = Block("container", 0, emptyList(), container = Container(listOf(body),
            ContainerStyle(overflow = ContainerOverflow.Auto)))
        val settings = AppSettings(allowImages = false, allowAudio = false)
        val copied = AtomicReference<String?>(null)
        val clipboard = object : Clipboard {
            override val nativeClipboard: android.content.ClipboardManager
                get() = error("This local selection control must not access the system clipboard")
            override suspend fun getClipEntry(): ClipEntry? = null
            override suspend fun setClipEntry(clipEntry: ClipEntry?) {
                val clip = checkNotNull(clipEntry).clipData
                assertEquals(1, clip.itemCount)
                copied.set(checkNotNull(clip.getItemAt(0).text).toString())
            }
        }
        var menuCoordinates: LayoutCoordinates? = null
        var shownMenu: Pair<TextContextMenuDataProvider, TextContextMenuSession>? = null
        var menuShows = 0
        val toolbar = object : TextContextMenuProvider {
            override suspend fun showTextContextMenu(dataProvider: TextContextMenuDataProvider) {
                val closed = CompletableDeferred<Unit>()
                val session = object : TextContextMenuSession {
                    override fun close() { closed.complete(Unit) }
                }
                val shown = dataProvider to session
                shownMenu = shown
                menuShows++
                try { closed.await() } finally {
                    if (shownMenu === shown) shownMenu = null
                }
            }
        }
        fun menuItem(key: Any): TextContextMenuItem? = shownMenu?.first?.data()?.components
            ?.filterIsInstance<TextContextMenuItem>()?.singleOrNull { it.key == key }
        fun invokeMenuItem(key: Any) {
            val shown = checkNotNull(shownMenu)
            val coordinates = checkNotNull(menuCoordinates)
            assertTrue(coordinates.isAttached)
            assertFalse(shown.first.contentBounds(coordinates).isEmpty)
            checkNotNull(menuItem(key)).onClick.invoke(shown.second)
        }
        try {
            compose.activityRule.scenario.onActivity { activity -> activity.setContent {
                MaterialTheme { CompositionLocalProvider(LocalDensity provides Density(1f, 1f),
                    LocalClipboard provides clipboard, LocalTextContextMenuToolbarProvider provides toolbar) {
                    val owner = rememberInlineImageViewOwner(listOf(image), media, settings, "")
                    CompositionLocalProvider(LocalInlineImageOwner provides owner) {
                        Layout(modifier = Modifier.onGloballyPositioned { menuCoordinates = it }, content = {
                            NativeFloatBlockContext(listOf(if (scrollport.value) container else table),
                                { actions += it.target }, "delegated-figure", Modifier, false, "delegated-grid",
                                0f, false, documentSurface = true, positionedPaintRoot = true)
                        }) { children, _ ->
                            val child = children.single().measure(Constraints.fixedWidth(320))
                            layout(320, child.height) { child.place(0, 0) }
                        }
                    }
                } }
            } }
            for (isScrollport in listOf(false, true)) {
                compose.runOnIdle { scrollport.value = isScrollport; copied.set(null) }
                compose.waitForIdle()
                assertTrue(compose.onAllNodesWithText("Unable to display this layout.").fetchSemanticsNodes().isNotEmpty())
                // These root fallback closures have no inherited Container text context. Their
                // retained spans use the existing Compose SelectionContainer/Text owner.
                compose.activityRule.scenario.onActivity { activity ->
                    var nativeCaptionOwners = 0
                    fun visit(view: View) {
                        if (view is NativeFloatTextView) {
                            val nodes = view.accessibilityNodeProvider.findAccessibilityNodeInfosByText(caption, View.NO_ID)
                            nodes.orEmpty().forEach {
                                if (it.text.toString() == caption) nativeCaptionOwners++
                                it.recycle()
                            }
                        }
                        if (view is android.view.ViewGroup) for (index in 0 until view.childCount) visit(view.getChildAt(index))
                    }
                    visit(activity.window.decorView)
                    assertEquals(0, nativeCaptionOwners)
                }
                compose.onAllNodesWithText(fullText, useUnmergedTree = true).assertCountEquals(1)
                val text = compose.onNodeWithText(fullText, useUnmergedTree = true).assertIsDisplayed()
                val layouts = mutableListOf<androidx.compose.ui.text.TextLayoutResult>()
                text.performSemanticsAction(androidx.compose.ui.semantics.SemanticsActions.GetTextLayoutResult) { it(layouts) }
                val layout = layouts.single()
                assertEquals(fullText, layout.layoutInput.text.text)
                val link = layout.layoutInput.text.getLinkAnnotations(0, fullText.length).single()
                assertEquals(0, link.start)
                assertEquals(caption.length, link.end)
                assertEquals("caption-target", (link.item as androidx.compose.ui.text.LinkAnnotation.Clickable).tag)
                val clickable = compose.onAllNodes(hasClickAction() and hasAnyAncestor(hasText(fullText)),
                    useUnmergedTree = true)
                clickable.assertCountEquals(1)
                clickable[0].assertIsDisplayed()
                val textBounds = text.fetchSemanticsNode().boundsInRoot
                val linkBounds = clickable[0].fetchSemanticsNode().boundsInRoot
                assertFalse(textBounds.isEmpty)
                assertFalse(linkBounds.isEmpty)
                val glyph = layout.getBoundingBox(link.start + 1).center
                assertTrue(linkBounds.contains(textBounds.topLeft + glyph))
                text.performTouchInput { click(glyph) }
                compose.runOnIdle { assertEquals(if (isScrollport) 2 else 1, actions.size) }
                val previousMenuShows = compose.runOnIdle { assertNull(shownMenu); menuShows }
                text.performTouchInput { longClick(layout.getBoundingBox(caption.length + 5).center) }
                // Observe the default ToolbarRequester route, then invoke its current menu items.
                compose.waitUntil(5000) { compose.runOnIdle {
                    menuShows > previousMenuShows && menuItem(TextContextMenuKeys.SelectAllKey) != null &&
                        menuItem(TextContextMenuKeys.CopyKey) != null
                } }
                compose.runOnIdle { invokeMenuItem(TextContextMenuKeys.SelectAllKey) }
                compose.waitForIdle()
                compose.waitUntil(5000) { compose.runOnIdle { menuItem(TextContextMenuKeys.CopyKey) != null } }
                compose.runOnIdle { invokeMenuItem(TextContextMenuKeys.CopyKey) }
                compose.waitUntil(5000) { copied.get() != null }
                assertEquals(fullText, copied.get())
                compose.waitUntil(5000) { compose.runOnIdle { shownMenu == null } }
                compose.runOnIdle { assertEquals(if (isScrollport) 2 else 1, actions.size) }
            }
            compose.runOnIdle { assertEquals(listOf("caption-target", "caption-target"), actions) }
        } finally {
            compose.activityRule.scenario.onActivity { it.setContent {} }
            compose.waitForIdle()
            compose.runOnIdle { assertNull(shownMenu) }
        }
    }
}
