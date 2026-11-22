package app.smallthingz.dict

import android.graphics.Bitmap
import android.graphics.Paint
import android.graphics.Typeface
import android.text.TextPaint
import android.graphics.RectF
import android.os.SystemClock
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.View
import android.view.accessibility.AccessibilityNodeInfo
import androidx.activity.compose.setContent
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.focusable
import androidx.compose.foundation.text.contextmenu.data.TextContextMenuItem
import androidx.compose.foundation.text.contextmenu.data.TextContextMenuKeys
import androidx.compose.foundation.text.contextmenu.data.TextContextMenuSession
import androidx.compose.foundation.text.contextmenu.provider.LocalTextContextMenuToolbarProvider
import androidx.compose.foundation.text.contextmenu.provider.TextContextMenuDataProvider
import androidx.compose.foundation.text.contextmenu.provider.TextContextMenuProvider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.LocalTextStyle
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.focus.focusRequester
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
import androidx.compose.ui.test.assertIsFocused
import androidx.compose.ui.test.hasAnyAncestor
import androidx.compose.ui.test.hasClickAction
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.longClick
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performSemanticsAction
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalFontFamilyResolver
import androidx.compose.ui.platform.LocalLayoutDirection
import androidx.compose.ui.platform.LocalWindowInfo
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
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.sp
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontSynthesis
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.intl.Locale
import androidx.compose.ui.text.intl.LocaleList
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
import kotlin.math.ceil

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

    @Test fun imagePolicyOwnsOnlyRenderedImageAndAfterFocusAcrossBaseAndResponsiveFigureMedia() {
        data class Case(val imagePolicy: Boolean, val outline: Boolean, val after: Boolean, val mediaOutline: Boolean = false)
        data class Scene(val case: Case, val responsive: Boolean, val width: Int = 300,
            val tableCaption: Boolean = true)
        val cases = listOf(Case(true, false, true), Case(true, true, false), Case(true, true, true),
            Case(false, false, true), Case(false, false, true, true))
        val scene = mutableStateOf(Scene(cases.first(), false))
        val rasterFocus = androidx.compose.ui.focus.FocusRequester()
        val bitmap = Bitmap.createBitmap(10, 4, Bitmap.Config.ARGB_8888).apply { eraseColor(android.graphics.Color.BLUE) }
        val settings = AppSettings(allowImages = false, allowAudio = false)
        val edition = "mgwiktionary-20261001"
        val actionEdition = mutableStateOf(edition)
        val sourceUris = mutableListOf<String>()
        val sourceHandler = object : UriHandler { override fun openUri(uri: String) { sourceUris += uri } }
        val dictionaryAction: (EntryLink) -> Unit = { error("A Figure File action must keep its source URL: $it") }
        val sourceOutline = FigureFocusOutline(px(2f), FigureColor.Rgb("#ff0000"), px(0f),
            SignedContainerMargin(StyleLengthUnit.Px, 0f))
        fun imagePaint(outline: Boolean) = LinkPaint(
            normal = FigureLinkState("#102030", true), hover = FigureLinkState("#203040", false),
            active = FigureLinkState("#304050", true), hoverActive = FigureLinkState("#405060", false),
            visited = FigureLinkState("#506070", false), visitedHover = FigureLinkState("#607080", true),
            visitedActive = FigureLinkState("#708090", false), visitedHoverActive = FigureLinkState("#8090a0", true),
            underlineOnFocus = true, focusOutline = sourceOutline.takeIf { outline })
        fun source(current: Scene): Figure {
            val paint = imagePaint(current.case.outline).takeIf { current.case.imagePolicy }
            val span = Span("link", "", "File:Figure-control.png", image = image,
                linkPaint = paint, foreground = paint?.normal?.foreground, underline = paint?.normal?.underline ?: false)
            fun mediaStyle(scale: Float) = policy(graphic = false).copy(
                strut = strut.copy(fontScale = scale),
                after = policy(graphic = false).after.takeIf { current.case.after },
                focusOutline = sourceOutline.takeIf { current.case.mediaOutline })
            val value = figure(emptyList(), graphic = false)
            return value.copy(content = FigureContent.Image(span, FigureSizingPolicy.RequestedFit),
                imageBorder = FigureBorder.Solid(px(3f), FigureColor.Rgb("#000000")),
                tableCaptionLayout = value.tableCaptionLayout!!.copy(media = mediaStyle(64f),
                    viewportStates = if (current.responsive) listOf(
                        FigureViewportState(0xffff_ffffL, ContainerStyle(), mediaStyle(32f))) else emptyList()))
                .let { if (current.tableCaption) it else it.copy(tableCaptionLayout = null) }
        }
        data class ExpectedFrame(val scene: Scene, val source: Figure, val bodyStyle: TextStyle,
            val typeface: Typeface?, val fontPixels: Float?, val mediaFont: FigureMediaFont?,
            val metrics: FigureBoxMetrics)
        var geometry: NativeAnonymousFlowGeometry? = null
        var renderedSource: Figure? = null
        var expectedFrame: ExpectedFrame? = null
        var phase = "setup"
        val focusHistory = mutableListOf<String>()
        fun retainEvidence(value: String) {
            focusHistory += value.take(512)
            if (focusHistory.size > 12) focusHistory.removeAt(0)
        }
        fun recordFocus(point: String, view: NativeFloatTextView) {
            val provider = view.accessibilityNodeProvider
            fun snapshot(kind: Int): String {
                val info = provider.findFocus(kind)
                return try { if (info == null) "none" else
                    "focused=${info.isFocused},ax=${info.isAccessibilityFocused},visible=${info.isVisibleToUser}"
                } finally { info?.recycle() }
            }
            retainEvidence("phase=$phase point=$point case=${scene.value} host=${view.hasFocus()} self=${view.isFocused} " +
                "window=${view.hasWindowFocus()} density=${view.resources.displayMetrics.density} " +
                "size=${view.measuredWidth}x${view.measuredHeight} " +
                "imageIds=${view.currentMeasuredGeometry?.nodes.orEmpty().filter { it.kind == FloatInteractionKind.IMAGE }.take(4).map { it.id }} " +
                "input=${snapshot(AccessibilityNodeInfo.FOCUS_INPUT)} ax=${snapshot(AccessibilityNodeInfo.FOCUS_ACCESSIBILITY)}")
        }
        var primary: Throwable? = null
        try {
            compose.activityRule.scenario.onActivity { activity -> activity.setContent {
                MaterialTheme { CompositionLocalProvider(LocalDensity provides Density(1f, 1f),
                    LocalUriHandler provides sourceHandler) {
                    val activeOwner = rememberInlineImageViewOwner(listOf(image), media, settings, edition)
                    androidx.compose.runtime.remember(activeOwner) {
                        activeOwner.states[inlineImageAssetKey(image)] = InlineImageAssetState.Ready(
                            DecodedMediaBitmap(bitmap, 10, 4), 100, 40, "image/png", "controlled Figure focus", "")
                        true
                    }
                    val current = scene.value
                    val authored = source(current)
                    val fixtureDensity = LocalDensity.current
                    val bodyStyle = inheritedCellTextStyle(MaterialTheme.typography.bodyLarge)
                    val bodyPixels = with(fixtureDensity) { bodyStyle.fontSize.toPx() }
                    val viewportCss = LocalWindowInfo.current.containerSize.width.toDouble() / fixtureDensity.density
                    val selectedSource = figureTableViewport(authored, viewportCss)
                    val layout = selectedSource.tableCaptionLayout
                    val selectedMedia = layout?.let { it.stateAtViewport(viewportCss)?.media ?: it.media }
                    val resolver = LocalFontFamilyResolver.current
                    var resolvedTypeface: Typeface? = null
                    var fontPixels: Float? = null
                    val mediaFont = selectedMedia?.strut?.let { owner ->
                        val mediaStyle = inheritedCellTextStyle(bodyStyle.copy(
                            fontSize = (bodyStyle.fontSize.value * owner.fontScale).sp,
                            fontFamily = if (owner.code) FontFamily.Monospace else bodyStyle.fontFamily,
                            fontWeight = if (owner.bold) FontWeight.Bold else FontWeight.Normal,
                            fontStyle = if (owner.italic) FontStyle.Italic else FontStyle.Normal,
                            fontFeatureSettings = owner.fontFeatures?.nativeSettings ?: bodyStyle.fontFeatureSettings,
                        )).copy(localeList = if (owner.language.isEmpty()) LocaleList.current else LocaleList(Locale(owner.language)))
                        val effective = LocalTextStyle.current.merge(mediaStyle).toSpanStyle()
                        val face = resolver.resolve(effective.fontFamily ?: FontFamily.Default,
                            effective.fontWeight ?: FontWeight.Normal, effective.fontStyle ?: FontStyle.Normal,
                            effective.fontSynthesis ?: FontSynthesis.All).value as Typeface
                        val pixels = with(fixtureDensity) { effective.fontSize.toPx() }
                        val paint = TextPaint(Paint.ANTI_ALIAS_FLAG).apply {
                            typeface = face
                            textSize = pixels
                            baselineShift = ceil(ascent() * (effective.baselineShift?.multiplier ?: 0f)).toInt()
                            letterSpacing = when {
                                effective.letterSpacing.isEm -> effective.letterSpacing.value
                                effective.letterSpacing.isSp && pixels > 0f -> with(fixtureDensity) { effective.letterSpacing.toPx() } / pixels
                                else -> 0f
                            }
                            fontFeatureSettings = effective.fontFeatureSettings
                            effective.textGeometricTransform?.let { textScaleX = it.scaleX; textSkewX = it.skewX }
                            effective.localeList?.let { locales -> textLocales = android.os.LocaleList.forLanguageTags(
                                locales.joinToString(",") { it.toLanguageTag() }) }
                        }
                        resolvedTypeface = face
                        fontPixels = pixels
                        val x = android.graphics.Rect().also { paint.getTextBounds("x", 0, 1, it) }
                        FigureMediaFont(NativePrimaryFontMetrics.from(paint), x.height().toFloat())
                    }
                    val natural = figureBoxMetrics(selectedSource,
                        figureImagePixels(selectedSource, 100L, 40L, fixtureDensity.density), fixtureDensity.density, bodyPixels)
                    val expected = if (layout == null) natural else FigureTableCaptionMetrics(
                        layout.copy(media = checkNotNull(selectedMedia)), natural, fixtureDensity.density, bodyPixels,
                        LocalLayoutDirection.current == LayoutDirection.Rtl, checkNotNull(mediaFont))
                        .resolve(current.width - 40, captionMinimum = 0)
                    val observed = ExpectedFrame(current, selectedSource, bodyStyle, resolvedTypeface, fontPixels, mediaFont, expected)
                    val block = Block("paragraph", 0, emptyList(), figure = authored)
                    SideEffect { renderedSource = checkNotNull(block.figure); expectedFrame = observed }
                    CompositionLocalProvider(LocalInlineImageOwner provides activeOwner) {
                        Layout(modifier = Modifier.testTag("figure-image-policy").background(Color.White)
                            .focusRequester(rasterFocus).focusable(), content = {
                            val flow = NativeFloatContextSpec.Flow(41, 0f, null, null, false) { carried, sink ->
                                AnonymousBlockView(block, Modifier, dictionaryAction, media, settings, actionEdition.value,
                                    interactionOwner = false, carriedExclusions = carried,
                                    onFlowGeometry = { geometry = it; sink(it) })
                            }
                            NativeFloatContextLayout(listOf(flow), Modifier, Color.Magenta,
                                documentSurface = true) { _, _ -> error("No delegated child") }
                        }) { children, _ ->
                            val child = children.single().measure(Constraints.fixedWidth(current.width - 40))
                            layout(current.width, child.height + 40) { child.place(20, 20) }
                        }
                    }
                } }
            } }
            compose.waitForIdle()
            val originalView = nativeView()
            fun pixels(): Pair<Int, Int> {
                val capture = compose.onNodeWithTag("figure-image-policy").captureToImage()
                val colors = capture.toPixelMap()
                var red = 0; var blue = 0
                for (y in 0 until capture.height) for (x in 0 until capture.width) {
                    val color = colors[x, y]
                    if (color.red > .95f && color.green < .05f && color.blue < .05f) red++
                    if (color.blue > .95f && color.red < .05f && color.green < .05f) blue++
                }
                retainEvidence("phase=$phase capture red=$red blue=$blue")
                return red to blue
            }
            fun isFocused(id: Int): Boolean {
                val info = checkNotNull(originalView.accessibilityNodeProvider.createAccessibilityNodeInfo(id))
                return try { info.isFocused } finally { info.recycle() }
            }
            fun assertRect(expected: RectF, actual: RectF) {
                assertEquals(expected.left, actual.left, .02f); assertEquals(expected.top, actual.top, .02f)
                assertEquals(expected.right, actual.right, .02f); assertEquals(expected.bottom, actual.bottom, .02f)
            }
            fun assertSourceOutlineDisjoint(content: RectF, anchors: List<RectF>) {
                assertEquals(StyleLengthUnit.Px, sourceOutline.width.unit)
                assertEquals(0f, sourceOutline.radius.value, 0f)
                assertEquals(0f, sourceOutline.offset.value, 0f)
                val width = sourceOutline.width.value // Fixture density and fontScale are both 1.
                for (anchor in anchors) {
                    // Conservative exterior bands include the rounded corners; no tested focus bounds are used.
                    val bands = listOf(
                        RectF(anchor.left - width, anchor.top - width, anchor.right + width, anchor.top),
                        RectF(anchor.left - width, anchor.bottom, anchor.right + width, anchor.bottom + width),
                        RectF(anchor.left - width, anchor.top, anchor.left, anchor.bottom),
                        RectF(anchor.right, anchor.top, anchor.right + width, anchor.bottom))
                    assertTrue("Authored focus ink must remain outside the unchanged bitmap: content=$content, anchor=$anchor",
                        bands.none { RectF.intersects(content, it) })
                }
            }
            fun unfocusedBaseline(view: NativeFloatTextView) {
                var transferred = false
                compose.runOnIdle {
                    recordFocus("baseline-before", view)
                    val node = checkNotNull(view.currentMeasuredGeometry).nodes.single { it.kind == FloatInteractionKind.IMAGE }
                    val provider = view.accessibilityNodeProvider
                    val info = provider.createAccessibilityNodeInfo(node.id)
                    val held = try { info?.isFocused == true } finally { info?.recycle() }
                    if (held) assertTrue(provider.performAction(node.id, AccessibilityNodeInfo.ACTION_CLEAR_FOCUS, null))
                    view.clearFocus()
                    // Native clearFocus may refocus the host outside touch mode; use only our nonpainting destination.
                    if (view.hasFocus()) {
                        val accepted = rasterFocus.requestFocus(androidx.compose.ui.focus.FocusDirection.Enter)
                        recordFocus("owned-transfer accepted=$accepted", view)
                        assertTrue("The owned Figure raster host accepts focus", accepted)
                        transferred = true
                    }
                    recordFocus("baseline-after", view)
                    assertFalse("The raster baseline excludes native host focus", view.hasFocus())
                    val input = provider.findFocus(AccessibilityNodeInfo.FOCUS_INPUT)
                    try { assertNull("The raster baseline excludes virtual input focus", input) }
                    finally { input?.recycle() }
                }
                if (transferred) compose.onNodeWithTag("figure-image-policy").assertIsFocused()
            }
            var calls = 0
            for (responsive in listOf(false, true)) for (case in cases) {
                val current = Scene(case, responsive)
                phase = "loop responsive=$responsive case=$case geometry"
                compose.runOnIdle { scene.value = current }
                compose.waitForIdle()
                assertSame(originalView, nativeView())
                compose.runOnIdle {
                    recordFocus("case-ready", originalView)
                    val flow = checkNotNull(geometry)
                    assertEquals("", flow.text.toString())
                    assertEquals(1, flow.nodes.count { it.kind == FloatInteractionKind.IMAGE })
                    assertTrue(flow.nodes.none { it.kind == FloatInteractionKind.LINK })
                    val placed = flow.figures.single()
                    val expected = checkNotNull(expectedFrame)
                    assertEquals(current, expected.scene)
                    assertEquals(expected.source, placed.anchor.event.figure)
                    val frame = expected.metrics
                    assertEquals(frame.width, placed.measured.geometry.width)
                    assertEquals(frame.height(0), placed.measured.geometry.height)
                    assertEquals(frame.width.toFloat(), placed.bounds.width(), .02f)
                    assertEquals(frame.height(0).toFloat(), placed.bounds.height(), .02f)
                    val allocated = checkNotNull(frame.tableCaption)
                    assertEquals(if (responsive) 32f else 64f, allocated.prepared.layout.media.strut.fontScale, 0f)
                    fun moved(rect: RectF) = RectF(rect).apply { offset(placed.bounds.left, placed.bounds.top) }
                    val imageBox = moved(RectF(frame.imageLeft, frame.imageTop,
                        frame.imageLeft + frame.image.width, frame.imageTop + frame.image.height).apply {
                        inset(-frame.imageBorder, -frame.imageBorder)
                    })
                    val anchor = moved(allocated.anchor.let { RectF(it.left, it.top, it.right, it.bottom) })
                    val after = allocated.after?.let { moved(RectF(it.left, it.top, it.right, it.bottom)) }
                    val contentBox = moved(RectF(frame.imageLeft, frame.imageTop,
                        frame.imageLeft + frame.image.width, frame.imageTop + frame.image.height))
                    assertEquals(3f, frame.imageBorder, 0f)
                    val sourceOutlineAnchors = when {
                        case.imagePolicy && case.outline -> listOfNotNull(imageBox, after)
                        case.mediaOutline -> listOf(anchor)
                        else -> emptyList()
                    }
                    assertSourceOutlineDisjoint(contentBox, sourceOutlineAnchors)
                    if (case.imagePolicy && case.outline && case.after) {
                        val sourceAfter = checkNotNull(after)
                        val outlineWidth = sourceOutline.width.value
                        assertEquals(anchor.bottom, sourceAfter.top, .02f)
                        assertEquals(anchor.bottom, imageBox.bottom, .02f)
                        assertEquals(1f, sourceAfter.top - outlineWidth - contentBox.bottom, .02f)
                        // The old 1px border really allowed this authored overlay; keep that source contrast.
                        val oldSource = expected.source.copy(
                            imageBorder = FigureBorder.Solid(px(1f), FigureColor.Rgb("#000000")))
                        val oldNatural = figureBoxMetrics(oldSource,
                            figureImagePixels(oldSource, 100L, 40L, 1f), 1f, expected.bodyStyle.fontSize.value)
                        val oldFrame = FigureTableCaptionMetrics(allocated.prepared.layout, oldNatural, 1f,
                            expected.bodyStyle.fontSize.value, allocated.prepared.rtl, checkNotNull(expected.mediaFont))
                            .resolve(current.width - 40, captionMinimum = 0)
                        val oldAllocated = checkNotNull(oldFrame.tableCaption)
                        val oldAfter = checkNotNull(oldAllocated.after)
                        val oldContent = RectF(oldFrame.imageLeft, oldFrame.imageTop,
                            oldFrame.imageLeft + oldFrame.image.width, oldFrame.imageTop + oldFrame.image.height)
                        val oldStraightTopBand = RectF(oldAfter.left, oldAfter.top - outlineWidth,
                            oldAfter.right, oldAfter.top)
                        val overlap = RectF(oldContent)
                        assertTrue("The original 1px border permits authored after-outline overlap", overlap.intersect(oldStraightTopBand))
                        assertEquals(oldAfter.width, overlap.width(), .02f)
                        assertEquals(1f, overlap.height(), .02f) // Geometric overlap, not a claimed raster pixel count.
                    }
                    assertTrue("Fixture strut must be taller than the image: scale=${allocated.prepared.layout.media.strut.fontScale}, " +
                        "fontPixels=${expected.fontPixels}, primary=${expected.mediaFont?.primary}, xHeight=${expected.mediaFont?.xHeight}, " +
                        "lineHeight=${anchor.height()}, imageHeight=${imageBox.height()}, bodyStyle=${expected.bodyStyle}, typeface=${expected.typeface}",
                        anchor.height() > imageBox.height()) // Keep the original tall-strut premise; no invented line-height.
                    val node = flow.nodes.single { it.kind == FloatInteractionKind.IMAGE }
                    assertNull(node.missingLinkPaint)
                    assertEquals(case.imagePolicy, node.sourceFocusVisible)
                    assertEquals(if (case.after) 2 else 1, node.bounds.size)
                    assertRect(anchor, node.bounds.first()) // Existing activation/AX anchor is preserved.
                    if (case.after) assertRect(checkNotNull(after), node.bounds.last())
                    when {
                        case.imagePolicy && case.outline -> {
                            val outlines = (node.focusPaint as NativeNodeFocusPaint.Fragments).outlines
                            assertEquals(if (case.after) 2 else 1, outlines.size)
                            assertRect(imageBox, outlines.first().bounds)
                            if (case.after) assertRect(checkNotNull(after), outlines.last().bounds)
                            outlines.forEach { assertEquals(2f, it.width, 0f); assertEquals(0xffff0000.toInt(), it.color) }
                        }
                        case.mediaOutline -> assertRect(anchor, (node.focusPaint as NativeNodeFocusPaint.Outline).bounds)
                        else -> assertSame(NativeNodeFocusPaint.None, node.focusPaint)
                    }
                    val live = checkNotNull(originalView.currentMeasuredGeometry).nodes.single { it.kind == FloatInteractionKind.IMAGE }
                    val provider = originalView.accessibilityNodeProvider
                    if (isFocused(live.id))
                        assertTrue(provider.performAction(live.id, AccessibilityNodeInfo.ACTION_CLEAR_FOCUS, null))
                }
                phase = "loop responsive=$responsive case=$case unfocused"
                unfocusedBaseline(originalView)
                val unfocused = pixels()
                assertTrue(unfocused.second > 0)
                assertEquals(0, unfocused.first)
                phase = "loop responsive=$responsive case=$case focused"
                compose.runOnIdle {
                    val node = checkNotNull(originalView.currentMeasuredGeometry).nodes.single { it.kind == FloatInteractionKind.IMAGE }
                    val provider = originalView.accessibilityNodeProvider
                    assertTrue(provider.performAction(node.id, AccessibilityNodeInfo.ACTION_FOCUS, null))
                    recordFocus("image-focus", originalView)
                    assertTrue(isFocused(node.id))
                    assertTrue(originalView.dispatchKeyEvent(KeyEvent(KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_ENTER)))
                    calls++
                    assertEquals(calls, sourceUris.size) // IMAGE keeps activation on key down.
                    originalView.dispatchKeyEvent(KeyEvent(KeyEvent.ACTION_UP, KeyEvent.KEYCODE_ENTER))
                    assertEquals(calls, sourceUris.size)
                }
                compose.waitForIdle()
                val focused = pixels()
                if (case.outline || case.mediaOutline) assertTrue(focused.first > 0) else assertEquals(0, focused.first)
                assertEquals(unfocused.second, focused.second) // Foreground/underline policy leaves the bitmap unchanged.
                if (case.imagePolicy && case.outline && !case.after) {
                    phase = "loop responsive=$responsive case=$case resize"
                    val held = compose.runOnIdle {
                        checkNotNull(originalView.currentMeasuredGeometry).nodes.single { it.kind == FloatInteractionKind.IMAGE }
                    }
                    compose.runOnIdle { scene.value = current.copy(width = 360) }
                    compose.waitForIdle()
                    assertSame(originalView, nativeView())
                    compose.runOnIdle {
                        val resized = checkNotNull(originalView.currentMeasuredGeometry).nodes.single { it.kind == FloatInteractionKind.IMAGE }
                        assertSame(held.onClick, resized.onClick); assertSame(held.onLongClick, resized.onLongClick)
                        assertTrue(isFocused(resized.id))
                        assertEquals(1, checkNotNull(geometry).nodes.count { it.kind == FloatInteractionKind.IMAGE })
                    }
                }
            }
            // A plain Figure keeps its content-image action region; its border belongs to focus ink.
            phase = "plain geometry"
            compose.runOnIdle { scene.value = Scene(Case(true, true, false), false, tableCaption = false) }
            compose.waitForIdle()
            assertSame(originalView, nativeView())
            compose.runOnIdle {
                val flow = checkNotNull(geometry)
                val placed = flow.figures.single()
                val expected = checkNotNull(expectedFrame)
                assertEquals(scene.value, expected.scene)
                assertEquals(expected.source, placed.anchor.event.figure)
                val frame = expected.metrics
                assertEquals(frame.width, placed.measured.geometry.width)
                assertEquals(frame.height(0), placed.measured.geometry.height)
                assertEquals(frame.width.toFloat(), placed.bounds.width(), .02f)
                assertEquals(frame.height(0).toFloat(), placed.bounds.height(), .02f)
                assertNull(frame.tableCaption)
                val contentBox = RectF(frame.imageLeft, frame.imageTop,
                    frame.imageLeft + frame.image.width, frame.imageTop + frame.image.height).apply {
                    offset(placed.bounds.left, placed.bounds.top)
                }
                val outerBox = RectF(contentBox).apply { inset(-frame.imageBorder, -frame.imageBorder) }
                assertEquals(3f, frame.imageBorder, 0f)
                assertSourceOutlineDisjoint(contentBox, listOf(outerBox))
                val node = flow.nodes.single { it.kind == FloatInteractionKind.IMAGE }
                assertTrue(flow.nodes.none { it.kind == FloatInteractionKind.LINK })
                assertTrue(node.sourceFocusVisible); assertNull(node.missingLinkPaint)
                assertRect(contentBox, node.bounds.single())
                assertRect(outerBox, (node.focusPaint as NativeNodeFocusPaint.Fragments).outlines.single().bounds)
                assertTrue(outerBox.width() > contentBox.width())
            }
            phase = "plain unfocused"
            unfocusedBaseline(originalView)
            val plainUnfocused = pixels()
            assertEquals(0, plainUnfocused.first); assertTrue(plainUnfocused.second > 0)
            phase = "plain focused"
            compose.runOnIdle {
                val node = checkNotNull(originalView.currentMeasuredGeometry).nodes.single { it.kind == FloatInteractionKind.IMAGE }
                assertTrue(originalView.accessibilityNodeProvider.performAction(node.id, AccessibilityNodeInfo.ACTION_FOCUS, null))
                recordFocus("image-focus", originalView)
                assertTrue(isFocused(node.id))
                assertTrue(originalView.dispatchKeyEvent(KeyEvent(KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_ENTER)))
                calls++
                assertEquals(calls, sourceUris.size)
                originalView.dispatchKeyEvent(KeyEvent(KeyEvent.ACTION_UP, KeyEvent.KEYCODE_ENTER))
                assertEquals(calls, sourceUris.size)
            }
            compose.waitForIdle()
            val plainFocused = pixels()
            assertTrue(plainFocused.first > 0); assertEquals(plainUnfocused.second, plainFocused.second)
            val retainedSource = compose.runOnIdle { checkNotNull(renderedSource) }
            phase = "unavailable edition"
            compose.runOnIdle { actionEdition.value = "" }
            compose.waitForIdle()
            compose.onAllNodesWithText("Unable to display this layout.")[0].assertIsDisplayed()
            assertTrue(pixels().second > 0) // The unsupported owner still exposes the retained image.
            compose.runOnIdle {
                assertEquals(retainedSource, renderedSource)
                assertEquals(calls, sourceUris.size)
                fun noPublishedPolicy(view: View) {
                    if (view is NativeFloatTextView && view.isShown) {
                        val provider = view.accessibilityNodeProvider
                        view.currentMeasuredGeometry?.nodes.orEmpty().filter { it.sourceFocusVisible }.forEach { node ->
                            val info = provider?.createAccessibilityNodeInfo(node.id)
                            try { assertFalse(info?.isVisibleToUser == true) } finally { info?.recycle() }
                        }
                    }
                    if (view is android.view.ViewGroup) for (index in 0 until view.childCount)
                        noPublishedPolicy(view.getChildAt(index))
                }
                noPublishedPolicy(compose.activity.window.decorView)
                actionEdition.value = edition
            }
            phase = "valid edition recovery"
            compose.waitForIdle()
            compose.onAllNodesWithText("Unable to display this layout.").assertCountEquals(0)
            val recoveredView = nativeView()
            compose.runOnIdle {
                assertEquals(retainedSource, renderedSource)
                val nodes = checkNotNull(recoveredView.currentMeasuredGeometry).nodes
                val node = nodes.single { it.kind == FloatInteractionKind.IMAGE }
                assertTrue(nodes.none { it.kind == FloatInteractionKind.LINK })
                assertTrue(node.sourceFocusVisible); assertNull(node.missingLinkPaint)
                assertTrue(node.focusPaint is NativeNodeFocusPaint.Fragments)
                assertTrue(recoveredView.accessibilityNodeProvider.performAction(node.id, AccessibilityNodeInfo.ACTION_FOCUS, null))
                recordFocus("recovered-image-focus", recoveredView)
                assertTrue(recoveredView.dispatchKeyEvent(KeyEvent(KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_ENTER)))
                calls++
                assertEquals(calls, sourceUris.size)
                recoveredView.dispatchKeyEvent(KeyEvent(KeyEvent.ACTION_UP, KeyEvent.KEYCODE_ENTER))
                assertEquals(calls, sourceUris.size)
            }
            assertEquals(List(calls) { "https://mg.wiktionary.org/wiki/File%3AFigure-control.png" }, sourceUris)
        } catch (failure: Throwable) {
            primary = failure
            try {
                val report = "OWNED_FIGURE_FOCUS_FAILURE phase=$phase fixtureDensity=1\n" + focusHistory.joinToString("\n")
                check(report.toByteArray(Charsets.UTF_8).size <= 8192)
                failure.addSuppressed(AssertionError(report))
            } catch (observation: Throwable) {
                if (observation !== failure) failure.addSuppressed(observation)
            }
            throw failure
        } finally {
            var cleanup: Throwable? = null
            fun clean(action: () -> Unit) {
                try { action() } catch (failure: Throwable) {
                    val previous = cleanup
                    if (previous == null) cleanup = failure else if (previous !== failure) previous.addSuppressed(failure)
                }
            }
            clean { compose.activityRule.scenario.onActivity { it.setContent {} } }
            clean { compose.waitForIdle() }
            clean { bitmap.recycle() }
            cleanup?.let { failure ->
                val original = primary
                if (original == null) throw failure else if (original !== failure) original.addSuppressed(failure)
            }
        }
    }
}
