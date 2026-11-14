package app.smallthingz.dict

import android.graphics.Bitmap
import android.graphics.Rect
import android.graphics.RectF
import android.view.View
import android.view.accessibility.AccessibilityNodeInfo
import androidx.activity.compose.setContent
import androidx.compose.foundation.background
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Typography
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.toPixelMap
import androidx.compose.ui.layout.Layout
import androidx.compose.ui.layout.LayoutCoordinates
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalLayoutDirection
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.platform.LocalWindowInfo
import androidx.compose.ui.platform.UriHandler
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.captureToImage
import androidx.compose.ui.test.click
import androidx.compose.ui.test.longClick
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTouchInput
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.intl.LocaleList
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.sp
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.File
import java.security.MessageDigest
import java.util.Collections
import java.util.UUID
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference
import kotlin.math.ceil
import kotlin.math.floor

/** Synthetic consumer controls only; these PNGs are not the retained VI source renditions. */
@RunWith(AndroidJUnit4::class)
class FigureBlockMediaDeviceTest {
    @get:Rule val compose = createPhysicalComposeRule()
    private fun px(value: Float) = StyleLength(StyleLengthUnit.Px, value)
    private fun zero() = StyleEdges(px(0f), px(0f), px(0f), px(0f))
    private val image = InlineImage("Block-control.svg", widthPx = 44L, heightPx = 40L, alt = "")
    private val media = listOf(Media(image.file, "image", ""))
    private val settings = AppSettings(allowImages = true, allowAudio = false, mediaCacheMb = 1)
    private val url1 = "https://example.test/controlled-1x.png"
    private val url2 = "https://example.test/controlled-2x.png"

    private fun png(width: Int, height: Int): ByteArray {
        val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
        return try {
            bitmap.eraseColor(android.graphics.Color.BLUE)
            ByteArrayOutputStream().use { out ->
                check(bitmap.compress(Bitmap.CompressFormat.PNG, 100, out)); out.toByteArray()
            }
        } finally { bitmap.recycle() }
    }
    private fun sha(bytes: ByteArray) = MessageDigest.getInstance("SHA-256").digest(bytes)
        .joinToString("") { "%02x".format(it.toInt() and 255) }
    private fun wrapper(align: CellTextAlign = CellTextAlign.Center, scale: Float = 1f,
        lineHeight: Float = 48f, left: Float = 5.25f, right: Float = 7.5f,
        top: Float = 0f, bottom: Float = 0f) = ContainerStyle(
        width = ContainerWidth.Auto, margins = SignedContainerEdges(
            SignedContainerMargin(StyleLengthUnit.Px, top), SignedContainerMargin(StyleLengthUnit.Px, right),
            SignedContainerMargin(StyleLengthUnit.Px, bottom), SignedContainerMargin(StyleLengthUnit.Px, left)),
        lineHeight = ContainerLineHeight.Length(px(lineHeight)), textAlign = align, ownerFontScale = scale)
    private fun mediaLayout(scale: Float = 1f, language: String = "vi", cap: Boolean = true) = FigureMediaLayout(
        FigureMediaStrut(scale, language = language, direction = BidiResolvedDirection.Rtl),
        InlineBoxVerticalAlign.Middle, maxWidth = if (cap) AvailableWidthLimit(100f, px(0f)) else null)
    private fun policy(one: ByteArray, two: ByteArray, responsive: Boolean = false) = FigureBlockMediaLayout(
        wrapper(), mediaLayout(), preferredWidthPx = 44, naturalWidth = 80, naturalHeight = 50,
        rendition1x = FigureBlockMediaRendition(url1, sha(one)), rendition2x = FigureBlockMediaRendition(url2, sha(two)),
        viewportStates = if (responsive) listOf(FigureBlockMediaState(639,
            wrapper(CellTextAlign.Right, left = 3.25f, right = 9.5f), mediaLayout())) else emptyList())
    private fun figure(policy: FigureBlockMediaLayout) = Figure(
        FigureContent.Image(Span("text", "", image = image), FigureSizingPolicy.RequestedFit),
        FigureFormat.Thumbnail, FigurePlacement.None, FigureClear.None, zero(), zero(), zero(),
        1f, px(24f), FigureColor.Transparent, FigureBorder.None, FigureColor.Transparent, FigureBorder.None,
        FigureColor.NativeTheme, FigureColor.Transparent, blockMediaLayout = policy)

    private class Observation {
        var owner: InlineImageViewOwner? = null
        var flow: NativeAnonymousFlowGeometry? = null
        var flowPolicy: FigureBlockMediaLayout? = null
        var followingText: String = ""
        var coordinates: LayoutCoordinates? = null
        val links = mutableListOf<String>()
        val uris = mutableListOf<String>()
    }
    @Composable
    private fun Scene(policy: FigureBlockMediaLayout, cache: MediaCache, seen: Observation,
        width: Int = 100, viewport: Double = 639.5, density: Float = 1f, tail: Boolean = false) {
        CompositionLocalProvider(LocalDensity provides Density(density, 1f),
            LocalLayoutDirection provides LayoutDirection.Ltr, LocalTableDocumentViewportCssWidth provides viewport,
            LocalInlineImageCache provides cache, LocalUriHandler provides object : UriHandler {
                override fun openUri(uri: String) { seen.uris += uri }
            }) {
            MaterialTheme(typography = Typography(bodyLarge = TextStyle(fontSize = 20.sp, localeList = LocaleList("tr")))) {
                val owner = rememberInlineImageViewOwner(listOf(image), media, settings, "jawiktionary-20261001",
                    blockMediaLayout = policy)
                SideEffect { seen.owner = owner; seen.followingText = if (tail) "tail" else "" }
                val block = if (tail) Block("paragraph", 0, emptyList(), flow = listOf(
                    FlowPart.ImageFigure(figure(policy)), FlowPart.Inline(listOf(Span("link", "tail", "after")))))
                else Block("paragraph", 0, emptyList(), figure = figure(policy))
                CompositionLocalProvider(LocalInlineImageOwner provides owner) {
                    Layout(modifier = Modifier.testTag("block-media").background(Color.White)
                        .onGloballyPositioned { seen.coordinates = it }, content = {
                        val flow = NativeFloatContextSpec.Flow(1, 0f, null, null, false) { carried, sink ->
                            AnonymousBlockView(block, Modifier, { seen.links += it.target }, media, settings,
                                "jawiktionary-20261001", interactionOwner = false, carriedExclusions = carried,
                                onFlowGeometry = { seen.flow = it; seen.flowPolicy = policy; sink(it) })
                        }
                        NativeFloatContextLayout(listOf(flow), Modifier, Color.Magenta,
                            documentSurface = true) { _, _ -> error("No delegated child") }
                    }) { children, _ ->
                        val child = children.single().measure(Constraints.fixedWidth(width))
                        layout(maxOf(160, width + 40), child.height + 40) { child.place(20, 20) }
                    }
                }
            }
        }
    }
    private fun withScene(content: @Composable () -> Unit, assertions: () -> Unit) {
        try {
            compose.activityRule.scenario.onActivity { it.setContent(content = content) }
            compose.waitForIdle(); assertions()
        } finally {
            compose.activityRule.scenario.onActivity { it.setContent {} }; compose.waitForIdle()
        }
    }
    private fun awaitReady(seen: Observation, expected: FigureBlockMediaLayout, density: Float = 1f) {
        awaitAuthenticatedAsset(seen, expected, density)
        compose.waitUntil(5000) { seen.flowPolicy == expected &&
            seen.flow?.nodes?.singleOrNull { it.kind == FloatInteractionKind.IMAGE }?.stateDescription == "" }
        compose.waitForIdle()
        compose.onAllNodesWithText("unavailable", substring = true, ignoreCase = true).assertCountEquals(0)
        compose.onAllNodesWithText("Unable to display this layout.").assertCountEquals(0)
    }
    private fun awaitAuthenticatedAsset(seen: Observation, expected: FigureBlockMediaLayout, density: Float = 1f) {
        compose.waitForIdle()
        compose.waitUntil(5000) { seen.owner?.blockMediaLayout == expected &&
            seen.owner?.states?.get(inlineImageAssetKey(image)) is InlineImageAssetState.Ready }
        compose.waitForIdle()
        compose.runOnIdle {
            val ready = checkNotNull(seen.owner).states[inlineImageAssetKey(image)] as InlineImageAssetState.Ready
            val selected = if (density <= 1f) expected.rendition1x else expected.rendition2x
            val multiplier = if (density <= 1f) 1 else 2
            val width = expected.naturalWidth.toInt() * multiplier
            val height = expected.naturalHeight.toInt() * multiplier
            assertEquals(FigureBlockMediaIdentity(selected.url, selected.sha256, width, height), ready.blockMediaIdentity)
            assertEquals(width, ready.decoded.width); assertEquals(height, ready.decoded.height)
            assertEquals(width, ready.decoded.bitmap.width); assertEquals(height, ready.decoded.bitmap.height)
        }
    }
    private fun awaitFailed(seen: Observation) {
        compose.waitForIdle()
        compose.waitUntil(5000) { seen.owner?.states?.get(inlineImageAssetKey(image)) == InlineImageAssetState.Failed }
        compose.waitForIdle()
        compose.onNodeWithText("Unable to display this layout.").assertIsDisplayed()
        assertNoRasterPaint()
    }
    private fun assertNoRasterPaint() {
        val pixels = compose.onNodeWithTag("block-media").captureToImage().toPixelMap()
        var blue = 0
        for (y in 0 until pixels.height) for (x in 0 until pixels.width)
            if (pixels[x, y] == Color.Blue) blue++
        assertEquals("Refused raster pixels must not remain painted", 0, blue)
    }
    private fun imageBounds(seen: Observation): RectF = compose.runOnIdle {
        val flow = checkNotNull(seen.flow)
        assertEquals(seen.followingText, flow.text.toString())
        val placed = flow.figures.single()
        val native = placed.measured.geometry
        assertEquals(0, native.text.length)
        assertTrue(native.rectsForRange(0, 0).isEmpty())
        val expected = RectF(native.nodes.single().bounds.single()).apply { offset(placed.bounds.left, placed.bounds.top) }
        val node = flow.nodes.single { it.kind == FloatInteractionKind.IMAGE }
        assertEquals(FloatInteractionKind.IMAGE, node.kind)
        assertEquals(expected, node.bounds.single())
        assertNull(node.onClick); assertNotNull(node.onLongClick)
        expected
    }
    private fun nativeView(): NativeFloatTextView {
        val result = mutableListOf<NativeFloatTextView>()
        compose.activityRule.scenario.onActivity { activity ->
            fun visit(view: View) {
                if (view is NativeFloatTextView && view.isShown) result += view
                if (view is android.view.ViewGroup) repeat(view.childCount) { visit(view.getChildAt(it)) }
            }
            visit(activity.window.decorView)
        }
        return result.single()
    }
    private fun verifyPaintAndAccessibility(seen: Observation, bounds: RectF) {
        val pixels = compose.onNodeWithTag("block-media").captureToImage().toPixelMap()
        assertEquals(Color.Blue, pixels[(bounds.centerX() + 20).toInt(), (bounds.centerY() + 20).toInt()])
        assertEquals(Color.White, pixels[(bounds.left + 18).toInt(), (bounds.centerY() + 20).toInt()])
        val view = nativeView()
        compose.runOnIdle {
            assertPhysicalActivity(compose.activity); check(compose.activity.hasWindowFocus())
            val flow = checkNotNull(seen.flow)
            val hit = flow.interactionNodeAt(bounds.centerX(), bounds.centerY())
            assertEquals(FloatInteractionKind.IMAGE, checkNotNull(hit).kind)
            val actual = checkNotNull(view.currentMeasuredGeometry).nodes.single { it.kind == FloatInteractionKind.IMAGE }
            val provider = view.accessibilityNodeProvider
            val info = checkNotNull(provider.createAccessibilityNodeInfo(actual.id))
            val origin = checkNotNull(seen.coordinates).localToScreen(Offset(20f, 20f))
            val expected = Rect(floor(bounds.left + origin.x).toInt(), floor(bounds.top + origin.y).toInt(),
                ceil(bounds.right + origin.x).toInt(), ceil(bounds.bottom + origin.y).toInt())
            val screen = Rect(); info.getBoundsInScreen(screen)
            assertEquals(expected, screen)
            assertTrue(info.isVisibleToUser); assertFalse(info.isClickable); assertTrue(info.isLongClickable)
            assertFalse(provider.performAction(actual.id, AccessibilityNodeInfo.ACTION_CLICK, null))
            assertTrue(seen.links.isEmpty()); assertTrue(seen.uris.isEmpty())
        }
        compose.onNodeWithTag("block-media").performTouchInput {
            click(Offset(bounds.centerX() + 20f, bounds.centerY() + 20f))
        }
        compose.runOnIdle { assertTrue(seen.links.isEmpty()); assertTrue(seen.uris.isEmpty()) }
    }
    private fun directory() = File(compose.activity.cacheDir, "figure-block-" + UUID.randomUUID()).apply { mkdirs() }

    @Test fun rootFractionalStateAndContainingCapShareActualPaintHitAndAccessibility() {
        val one = png(80, 50); val two = png(160, 100)
        val original = policy(one, two, responsive = true)
        val value = mutableStateOf(original)
        val width = mutableStateOf(100); val viewport = mutableStateOf(639.5)
        val requests = Collections.synchronizedList(mutableListOf<String>())
        val metadata = AtomicInteger(); val directory = directory(); val seen = Observation()
        val cache = MediaCache(compose.activity, directory = directory,
            metadata = { metadata.incrementAndGet(); error("A source-pinned image must not query imageinfo") },
            openMedia = { url -> requests += url; check(url == url1); ByteArrayInputStream(one) })
        try { withScene({ Scene(value.value, cache, seen, width.value, viewport.value, tail = true) }) {
            awaitReady(seen, original)
            val owner = seen.owner
            val wide = imageBounds(seen)
            assertEquals(26.875f, wide.left, .001f)
            assertEquals(44f, wide.width(), .001f)
            assertEquals(27.5f, wide.height(), .001f)
            compose.runOnIdle {
                val actual = checkNotNull(seen.flow).figures.single().measured.geometry
                assertEquals(88, actual.width)
                assertTrue(actual.height >= 48)
                viewport.value = 639.0
            }
            compose.waitForIdle()
            val narrowState = imageBounds(seen)
            assertEquals(46.5f, narrowState.left, .001f)
            assertEquals(wide.width(), narrowState.width(), .001f)
            verifyPaintAndAccessibility(seen, narrowState)
            compose.onNodeWithTag("block-media").performTouchInput {
                longClick(Offset(narrowState.centerX() + 20f, narrowState.centerY() + 20f))
            }
            compose.onNodeWithText("Source and licence").assertIsDisplayed()
            compose.onNodeWithTag("block-media").performTouchInput { click(Offset(2f, 2f)) }
            compose.runOnIdle { width.value = 24 }
            compose.waitForIdle()
            val capped = imageBounds(seen)
            assertEquals(11.25f, capped.width(), .001f); assertEquals(7.03125f, capped.height(), .001f)
            compose.runOnIdle { width.value = 100; viewport.value = 639.5 }
            compose.waitForIdle()
            assertEquals(wide, imageBounds(seen)); assertSame(owner, seen.owner)
            assertEquals(listOf(url1), requests.toList()); assertEquals(0, metadata.get())
            assertTrue(seen.links.isEmpty()); assertTrue(seen.uris.isEmpty())
            compose.runOnIdle {
                width.value = 20
                value.value = original.copy(wrapper = wrapper(CellTextAlign.Left, left = 0f, right = 0f),
                    media = mediaLayout(cap = false), viewportStates = emptyList())
            }
            awaitReady(seen, value.value)
            val overflow = imageBounds(seen)
            assertEquals(0f, overflow.left, .001f)
            assertEquals(44f, overflow.width(), .001f); assertEquals(27.5f, overflow.height(), .001f)
            compose.runOnIdle {
                val flow = checkNotNull(seen.flow)
                assertEquals(20, flow.figures.single().measured.geometry.width)
                assertTrue(flow.scrollableBounds.right >= 44f)
                assertEquals(FloatInteractionKind.IMAGE,
                    checkNotNull(flow.interactionNodeAt(43f, overflow.centerY())).kind)
            }
            verifyPaintAndAccessibility(seen, overflow)
            val overflowPaint = compose.onNodeWithTag("block-media").captureToImage().toPixelMap()
            assertEquals(Color.Blue, overflowPaint[62, (overflow.centerY() + 20f).toInt()])
            compose.runOnIdle { value.value = value.value.copy(media = mediaLayout()) }
            awaitReady(seen, value.value)
            val recapped = imageBounds(seen)
            assertEquals(20f, recapped.width(), .001f); assertEquals(12.5f, recapped.height(), .001f)
            compose.runOnIdle { width.value = 100; value.value = original }
            awaitReady(seen, original)
            val before = compose.runOnIdle {
                RectF(checkNotNull(seen.flow).nodes.single { it.kind == FloatInteractionKind.LINK }.bounds.single())
            }
            compose.runOnIdle {
                value.value = original.copy(wrapper = original.wrapper.copy(lineHeight = ContainerLineHeight.Length(px(48.25f))),
                    viewportStates = original.viewportStates.map { state -> state.copy(
                        wrapper = state.wrapper.copy(lineHeight = ContainerLineHeight.Length(px(48.25f)))) })
            }
            awaitReady(seen, value.value)
            val after = compose.runOnIdle {
                assertEquals(49, checkNotNull(seen.flow).figures.single().measured.geometry.height)
                RectF(checkNotNull(seen.flow).nodes.single { it.kind == FloatInteractionKind.LINK }.bounds.single())
            }
            assertEquals(.25f, after.top - before.top, .001f)
            assertEquals(.25f, after.bottom - before.bottom, .001f)
            verifyPaintAndAccessibility(seen, imageBounds(seen))
            val paint = compose.onNodeWithTag("block-media").captureToImage().toPixelMap()
            var tailInk = 0
            for (y in ceil(after.top + 20f).toInt() until floor(after.bottom + 20f).toInt())
                for (x in ceil(after.left + 20f).toInt() until floor(after.right + 20f).toInt())
                    if (paint[x, y] != Color.White) tailInk++
            assertTrue("The following native body must paint in its solved bounds", tailInk > 0)
            val view = nativeView()
            compose.runOnIdle {
                val link = checkNotNull(view.currentMeasuredGeometry).nodes.single { it.kind == FloatInteractionKind.LINK }
                val info = checkNotNull(view.accessibilityNodeProvider.createAccessibilityNodeInfo(link.id))
                val origin = checkNotNull(seen.coordinates).localToScreen(Offset(20f, 20f))
                val actual = Rect(); info.getBoundsInScreen(actual)
                assertEquals(Rect(floor(after.left + origin.x).toInt(), floor(after.top + origin.y).toInt(),
                    ceil(after.right + origin.x).toInt(), ceil(after.bottom + origin.y).toInt()), actual)
                assertTrue(info.isClickable)
            }
            compose.onNodeWithTag("block-media").performTouchInput { click(Offset(after.centerX() + 20f, after.centerY() + 20f)) }
            compose.runOnIdle { assertEquals(listOf("after"), seen.links); assertTrue(seen.uris.isEmpty()) }
            assertEquals(listOf(url1), requests.toList()); assertEquals(0, metadata.get())
        } } finally { directory.deleteRecursively() }
    }

    @Test fun densitySelectsOnlyExactAuthenticatedRenditionWithoutChangingLogicalRatio() {
        val one = png(80, 50); val two = png(160, 100); val value = policy(one, two)
        val density = mutableStateOf(1f); val seen = Observation(); val directory = directory()
        val requests = Collections.synchronizedList(mutableListOf<String>())
        val metadata = AtomicInteger()
        val cache = MediaCache(compose.activity, directory = directory,
            metadata = { metadata.incrementAndGet(); error("No source-pinned imageinfo request") }, openMedia = { url ->
                requests += url; ByteArrayInputStream(when (url) { url1 -> one; url2 -> two; else -> error("Unrepresented raster URL") })
            })
        try { withScene({ Scene(value, cache, seen, density = density.value) }) {
            awaitReady(seen, value)
            val first = imageBounds(seen)
            compose.runOnIdle { density.value = 1.25f }
            awaitReady(seen, value, density.value)
            val second = imageBounds(seen)
            assertEquals(44f * 1.25f, second.width(), .001f)
            assertEquals(27.5f * 1.25f, second.height(), .001f)
            assertEquals(first.width() / first.height(), second.width() / second.height(), .0001f)
            compose.runOnIdle {
                val ready = checkNotNull(seen.owner).states[inlineImageAssetKey(image)] as InlineImageAssetState.Ready
                assertEquals(160, ready.decoded.width); assertEquals(100, ready.decoded.height)
            }
            verifyPaintAndAccessibility(seen, second)
            assertEquals(listOf(url1, url2), requests.toList())
            assertEquals(0, metadata.get())
        } } finally { directory.deleteRecursively() }
    }

    @Test fun digestAndDecodedAxesRefuseThenRecoverThroughTheRealOwnerAndCache() {
        val one = png(80, 50); val two = png(160, 100); val good = policy(one, two)
        val wrong = png(79, 50)
        val reply = AtomicReference(wrong); val value = mutableStateOf(good)
        val seen = Observation(); val directory = directory()
        val requests = Collections.synchronizedList(mutableListOf<String>())
        val metadata = AtomicInteger()
        val cache = MediaCache(compose.activity, directory = directory,
            metadata = { metadata.incrementAndGet(); error("No fallback imageinfo request") }, openMedia = { url ->
                requests += url; check(url == url1); ByteArrayInputStream(reply.get())
            })
        try { withScene({ Scene(value.value, cache, seen) }) {
            awaitFailed(seen)
            assertEquals(0, metadata.get()); assertEquals(listOf(url1), requests.toList())
            val firstOwner = checkNotNull(seen.owner)
            compose.runOnIdle { reply.set(one) }
            compose.onNodeWithText("Retry image").assertIsDisplayed().performClick()
            awaitReady(seen, good)
            compose.onAllNodesWithText("Retry image").assertCountEquals(0)
            assertSame(firstOwner, seen.owner)
            assertEquals(27.5f, imageBounds(seen).height(), .001f)
            assertEquals(listOf(url1, url1), requests.toList())
            // The same digest-correct PNG is invalid for a different authenticated natural width.
            compose.runOnIdle { value.value = good.copy(naturalWidth = 81) }
            awaitFailed(seen)
            compose.onNodeWithText("Retry image").assertIsDisplayed()
            assertEquals(0, metadata.get()); assertTrue(requests.all { it == url1 })
            compose.runOnIdle { value.value = good }
            awaitReady(seen, good)
            compose.onAllNodesWithText("Retry image").assertCountEquals(0)
            val recovered = imageBounds(seen)
            assertEquals(44f, recovered.width(), .001f); assertEquals(27.5f, recovered.height(), .001f)
            verifyPaintAndAccessibility(seen, recovered)
            assertEquals(0, metadata.get()); assertTrue(requests.all { it == url1 })
            assertTrue(seen.links.isEmpty()); assertTrue(seen.uris.isEmpty())
        } } finally { directory.deleteRecursively() }
    }

    @Test fun zeroCapRetainsStrutAndUnsupportedOwnersRecoverWithoutCaptionOrLink() {
        val one = png(80, 50); val two = png(160, 100)
        val base = policy(one, two).copy(wrapper = wrapper(left = 0f, right = 0f))
        val value = mutableStateOf(base); val width = mutableStateOf(0)
        val seen = Observation(); val directory = directory()
        val requests = Collections.synchronizedList(mutableListOf<String>())
        val metadata = AtomicInteger()
        val cache = MediaCache(compose.activity, directory = directory,
            metadata = { metadata.incrementAndGet(); error("No source-pinned imageinfo request") }, openMedia = { url ->
                requests += url; check(url == url1); ByteArrayInputStream(one)
            })
        try { withScene({ Scene(value.value, cache, seen, width = width.value) }) {
            awaitReady(seen, value.value)
            compose.runOnIdle {
                val flow = checkNotNull(seen.flow)
                val native = flow.figures.single().measured.geometry
                val image = native.nodes.single().bounds.single()
                assertEquals(0f, image.width(), 0f); assertEquals(0f, image.height(), 0f)
                assertEquals(0, native.width); assertTrue(native.height >= 48)
                assertEquals("", flow.text.toString())
                value.value = base.copy(wrapper = wrapper(scale = 0f, lineHeight = 0f, left = 0f, right = 0f),
                    media = mediaLayout(scale = 0f))
            }
            awaitReady(seen, value.value)
            compose.runOnIdle {
                val native = checkNotNull(seen.flow).figures.single().measured.geometry
                assertEquals(0, native.height)
                width.value = 100
                value.value = base.copy(media = mediaLayout(language = "zh-cmn"))
            }
            awaitAuthenticatedAsset(seen, value.value)
            compose.onNodeWithText("Unable to display this layout.").assertIsDisplayed()
            assertNoRasterPaint()
            assertEquals(0, metadata.get()); assertTrue(requests.all { it == url1 })
            compose.runOnIdle {
                assertEquals("zh-cmn", value.value.media.strut.language)
                assertEquals(BidiResolvedDirection.Rtl, value.value.media.strut.direction)
                value.value = base
            }
            awaitReady(seen, base)
            val recovered = imageBounds(seen)
            assertEquals(44f, recovered.width(), .001f); assertEquals(27.5f, recovered.height(), .001f)
            verifyPaintAndAccessibility(seen, recovered)
            compose.runOnIdle {
                value.value = base.copy(wrapper = wrapper(left = 0f, right = 0f, top = .25f, bottom = .5f))
            }
            awaitAuthenticatedAsset(seen, value.value)
            compose.onNodeWithText("Unable to display this layout.").assertIsDisplayed()
            assertNoRasterPaint()
            compose.runOnIdle {
                value.value = base.copy(wrapper = wrapper(CellTextAlign.Left, left = 0f, right = 0f).copy(
                    margins = null, marginValues = ContainerMargins(ContainerMargin.Length(px(0f)),
                        ContainerMargin.Auto, ContainerMargin.Length(px(0f)), ContainerMargin.Auto)))
            }
            awaitReady(seen, value.value)
            val autoMargins = imageBounds(seen)
            assertEquals(0f, autoMargins.left, .001f)
            assertEquals(44f, autoMargins.width(), .001f)
            compose.runOnIdle { assertEquals(100, checkNotNull(seen.flow).figures.single().measured.geometry.width) }
            verifyPaintAndAccessibility(seen, autoMargins)
            assertEquals("vi", base.media.strut.language)
            assertEquals(BidiResolvedDirection.Rtl, base.media.strut.direction)
            assertEquals(0, metadata.get()); assertTrue(requests.all { it == url1 })
            assertTrue(seen.links.isEmpty()); assertTrue(seen.uris.isEmpty())
        } } finally { directory.deleteRecursively() }
    }

    @Composable
    private fun ParentScene(blocks: List<Block>, policy: FigureBlockMediaLayout, cache: MediaCache,
        seen: Observation, viewport: Double, published: (Double, NativeFloatContextGeometry?) -> Unit) {
        CompositionLocalProvider(LocalDensity provides Density(1f, 1f),
            LocalLayoutDirection provides LayoutDirection.Ltr, LocalTableDocumentViewportCssWidth provides viewport,
            LocalInlineImageCache provides cache, LocalUriHandler provides object : UriHandler {
                override fun openUri(uri: String) { seen.uris += uri }
            }) {
            MaterialTheme(typography = Typography(bodyLarge = TextStyle(fontSize = 20.sp, localeList = LocaleList("tr")))) {
                val owner = rememberInlineImageViewOwner(listOf(image), media, settings, "vi-parent-control",
                    blockMediaLayout = policy)
                SideEffect { seen.owner = owner }
                val parent = remember { NativeLayoutInput(Unit) }
                val input = remember { NativeContextMeasureInput(invalidateParent = parent::invalidate) }
                val environment = NativeFlowEnvironment(1f, 1f, LayoutDirection.Ltr, LocalWindowInfo.current.containerSize)
                val preparation = Any()
                Layout(modifier = Modifier.testTag("block-media-parent").background(Color.White)
                    .onGloballyPositioned { seen.coordinates = it }.then(parent.modifier), content = {
                    CompositionLocalProvider(LocalInlineImageOwner provides owner, LocalNativeContextMeasureInput provides input) {
                        NativeFloatBlockContext(blocks, { seen.links += it.target }, "parent-bands", Modifier,
                            inCell = false, gridPath = "parent-bands", gapDp = 0f, trailingGap = false,
                            documentSurface = true)
                    }
                }) { children, constraints ->
                    val childConstraints = Constraints(maxWidth = 400, maxHeight = 600)
                    val request = input.request(constraints, childConstraints, environment,
                        NativeFlowParentPolicy(preparation, true, null, 0f), emptyList())
                    val child = children.single().measure(childConstraints)
                    published(viewport, input.ready(request))
                    layout(440, child.height + 40) { child.place(20, 20) }
                }
            }
        }
    }

    @Test fun conditionalParentRulesKeepThreeBandFramesAndIntrinsicFlexChildrenOnOneImageOwner() {
        val one = png(80, 50); val two = png(160, 100)
        val childPolicy = policy(one, two).copy(wrapper = wrapper(left = 0f, right = 0f))
        fun em(value: Float) = StyleLength(StyleLengthUnit.Em, value)
        fun box(children: List<Block>, style: ContainerStyle) =
            Block("container", 0, emptyList(), container = Container(children, style))
        val body = "alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu " +
            "alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu"
        // Conditional typed premises, not an issued VI tuple: the parent shape and rule
        // cascade are source-backed; these colours and the child strut are explicit controls.
        // Retained declaration evidence: container-responsive-bands01/source-evidence01.json (adf875).
        // At a proved .9 owner scale, normalized .5em/.55em are .45em/.495em of body20.
        val parentStyle = ContainerStyle(
            margins = StyleEdges(px(0f), px(0f), em(.45f), em(.45f)), padding = StyleEdges(px(4f), px(4f), px(4f), px(4f)),
            width = ContainerWidth.Length(StyleWidth(StyleWidthUnit.Px, 250f)),
            floatSide = TableFloatSide.Right, clear = FigureClear.Right,
            layout = ContainerLayout.FlexRow, alignItems = ContainerAlignItems.Center,
            ownerFontScale = .9f, textAlign = CellTextAlign.Left,
            border = ContainerBorder.Solid(px(1f), ContainerColor.Rgb("#ff0000")),
            background = ContainerColor.Rgb("#ffff00"),
            screenMaxWidth = ContainerScreenMaxWidth(719,
                width = ContainerWidth.Length(StyleWidth(StyleWidthUnit.Percent, 100f)),
                maxWidth = ContainerMaxWidth.Length(StyleWidth(StyleWidthUnit.Percent, 100f)),
                boxSizing = ContainerBoxSizing.BorderBox, lineHeight = ContainerLineHeight.Multiplier(1.5f),
                followingRules = listOf(ContainerScreenMaxWidth(639, floatSide = ContainerFloatOverride.None,
                    clear = FigureClear.Both))))
        val tree = listOf(box(listOf(
            box(listOf(Block("paragraph", 0, emptyList(), figure = figure(childPolicy))),
                ContainerStyle(flexItem = ContainerFlexItem.None)),
            box(listOf(Block("paragraph", 0, listOf(Span("link", body, "parent-body", foreground = "#000000")))),
                ContainerStyle(margins = StyleEdges(px(0f), px(0f), px(0f), em(.495f))))
        ), parentStyle), Block("paragraph", 0, listOf(Span("link", "following", "following", foreground = "#000000"))))
        val viewport = mutableStateOf(719.5)
        val seen = Observation(); val directory = directory()
        val requests = Collections.synchronizedList(mutableListOf<String>())
        val metadata = AtomicInteger()
        val cache = MediaCache(compose.activity, directory = directory,
            metadata = { metadata.incrementAndGet(); error("Parent rules must not query imageinfo") },
            openMedia = { url -> requests += url; check(url == url1); ByteArrayInputStream(one) })
        var publishedViewport = Double.NaN
        var current: NativeFloatContextGeometry? = null
        try { withScene({ ParentScene(tree, childPolicy, cache, seen, viewport.value) { width, geometry ->
            publishedViewport = width; current = geometry
        } }) {
            awaitAuthenticatedAsset(seen, childPolicy)
            val owner = seen.owner
            var wideImage: RectF? = null
            var wideParent: RectF? = null
            var middleImage: RectF? = null
            var middleParent: RectF? = null
            var wideTextWidth = 0f
            for (rootWidth in listOf(719.5, 719.0, 639.5, 639.0, 719.5)) {
                compose.runOnIdle { viewport.value = rootWidth }
                compose.waitForIdle()
                compose.waitUntil(5000) { publishedViewport == rootWidth && current != null }
                compose.waitForIdle()
                compose.onAllNodesWithText("Unable to display this layout.").assertCountEquals(0)
                compose.onAllNodesWithText("unavailable", substring = true, ignoreCase = true).assertCountEquals(0)
                val geometry = compose.runOnIdle { checkNotNull(current) }
                // The real source-id walk visits each leaf before its enclosing Container.
                assertEquals(setOf(1, 3, 4), geometry.ordinaryBounds.keys)
                val logo = RectF(geometry.ordinaryBounds.getValue(1))
                val text = RectF(geometry.ordinaryBounds.getValue(3))
                val parent = RectF(geometry.ordinaryBounds.getValue(4))
                val wide = rootWidth > 719.0
                val narrow = rootWidth <= 639.0
                assertEquals(if (wide) 260f else 400f, parent.width(), .001f)
                assertEquals(if (wide) 140f else if (narrow) 9f else 0f, parent.left, .001f)
                assertEquals(if (narrow) 409f else 400f, parent.right, .001f)
                assertEquals(44f, logo.width(), .001f)
                assertEquals(parent.left + 5f, logo.left, .001f)
                assertEquals(9.9f, text.left - logo.right, .001f)
                assertEquals(logo.centerY(), text.centerY(), .001f)
                assertTrue(text.width() > 0f && text.right <= parent.right - 5f + .001f)
                if (wide) {
                    if (wideTextWidth == 0f) wideTextWidth = text.width()
                    else assertEquals(wideTextWidth, text.width(), .001f)
                } else assertTrue(text.width() > wideTextWidth)
                val flowLeaf = geometry.inputLeaves().single { it.geometry is NativeAnonymousFlowGeometry }
                val flow = flowLeaf.geometry as NativeAnonymousFlowGeometry
                val placed = flow.figures.single()
                val used = checkNotNull(placed.measured.usedBox)
                assertEquals(44f, used.width, .001f)
                assertEquals(44, placed.measured.geometry.width)
                assertEquals("", placed.measured.geometry.text.toString())
                assertEquals(logo.left, flowLeaf.x + placed.bounds.left, .001f)
                val imageNode = geometry.nodes.single { it.kind == FloatInteractionKind.IMAGE }
                val imageBox = RectF(imageNode.bounds.single())
                val localImage = placed.measured.geometry.nodes.single().bounds.single()
                assertEquals(localImage.left + placed.bounds.left + flowLeaf.x, imageBox.left, .001f)
                assertEquals(localImage.top + placed.bounds.top + flowLeaf.y, imageBox.top, .001f)
                assertEquals(44f, imageBox.width(), .001f); assertEquals(27.5f, imageBox.height(), .001f)
                assertNull(imageNode.onClick); assertNotNull(imageNode.onLongClick)
                val bodyNode = geometry.nodes.single { it.label?.toString() == body }
                val followingNode = geometry.nodes.single { it.label?.toString() == "following" }
                assertTrue(bodyNode.bounds.size > 1)
                assertTrue(bodyNode.bounds.all { it.left >= text.left - .001f && it.right <= text.right + .001f })
                if (!wide) bodyNode.bounds.zipWithNext().forEach { (a, b) -> assertEquals(27f, b.top - a.top, .001f) }
                if (narrow) {
                    assertTrue(geometry.ownExclusions.isEmpty())
                    assertTrue(followingNode.bounds.first().top >= parent.bottom + 9f - .001f)
                } else {
                    val exclusion = geometry.ownExclusions.single()
                    assertEquals(TableFloatSide.Right, exclusion.side)
                    assertEquals(parent.bottom + 9f, exclusion.outer.bottom, .001f)
                    if (wide) {
                        assertTrue(followingNode.bounds.first().top < parent.bottom)
                        assertTrue(followingNode.bounds.first().right <= parent.left - 9f + .001f)
                    } else assertTrue(followingNode.bounds.first().top >= parent.bottom + 9f - .001f)
                }
                if (wide) {
                    if (wideParent == null) { wideParent = RectF(parent); wideImage = RectF(imageBox) }
                    else { assertEquals(wideParent, parent); assertEquals(wideImage, imageBox) }
                } else if (!narrow) {
                    if (middleParent == null) { middleParent = RectF(parent); middleImage = RectF(imageBox) }
                    else { assertEquals(middleParent, parent); assertEquals(middleImage, imageBox) }
                }
                val pixels = compose.onNodeWithTag("block-media-parent").captureToImage().toPixelMap()
                assertEquals(Color.Red, pixels[(parent.left + 20f).toInt(), (parent.centerY() + 20f).toInt()])
                assertEquals(Color.Yellow, pixels[(parent.left + 22f).toInt(), (parent.centerY() + 20f).toInt()])
                assertEquals(Color.Blue, pixels[(imageBox.centerX() + 20f).toInt(), (imageBox.centerY() + 20f).toInt()])
                assertEquals(Color.White, pixels[(parent.left + 18f).toInt(), (parent.centerY() + 20f).toInt()])
                if (narrow) assertEquals(Color.Red,
                    pixels[(parent.right + 19f).toInt(), (parent.centerY() + 20f).toInt()])
                for (line in listOf(bodyNode.bounds.first(), followingNode.bounds.first())) {
                    var ink = 0
                    for (y in ceil(line.top + 20f).toInt() until floor(line.bottom + 20f).toInt())
                        for (x in ceil(line.left + 20f).toInt() until floor(line.right + 20f).toInt()) {
                            val pixel = pixels[x, y]
                            if (pixel.red < .2f && pixel.green < .2f && pixel.blue < .2f) ink++
                        }
                    assertTrue("The measured ordinary body must paint inside its real bounds", ink > 0)
                }
                val view = nativeView()
                compose.runOnIdle {
                    assertPhysicalActivity(compose.activity); check(compose.activity.hasWindowFocus())
                    assertEquals(FloatInteractionKind.IMAGE,
                        checkNotNull(geometry.interactionNodeAt(imageBox.centerX(), imageBox.centerY())).kind)
                    val sourceOrigin = checkNotNull(seen.coordinates).localToScreen(Offset(20f, 20f))
                    val actualNodes = checkNotNull(view.currentMeasuredGeometry).nodes
                    listOf(imageNode, bodyNode, followingNode).forEach { node ->
                        val actual = actualNodes.single { it.kind == node.kind && it.label?.toString() == node.label?.toString() }
                        val info = checkNotNull(view.accessibilityNodeProvider.createAccessibilityNodeInfo(actual.id))
                        val all = RectF(node.bounds.first()).apply { node.bounds.drop(1).forEach(::union) }
                        val expected = Rect(floor(all.left + sourceOrigin.x).toInt(), floor(all.top + sourceOrigin.y).toInt(),
                            ceil(all.right + sourceOrigin.x).toInt(), ceil(all.bottom + sourceOrigin.y).toInt())
                        val screen = Rect(); info.getBoundsInScreen(screen)
                        assertEquals(expected, screen); assertTrue(info.isVisibleToUser)
                        assertEquals(node.kind != FloatInteractionKind.IMAGE, info.isClickable)
                    }
                }
                val before = seen.links.size
                compose.onNodeWithTag("block-media-parent").performTouchInput {
                    click(Offset(imageBox.centerX() + 20f, imageBox.centerY() + 20f))
                }
                compose.runOnIdle { assertEquals(before, seen.links.size) }
                val bodyPoint = bodyNode.bounds.first()
                compose.onNodeWithTag("block-media-parent").performTouchInput {
                    click(Offset(bodyPoint.centerX() + 20f, bodyPoint.centerY() + 20f))
                }
                val followingPoint = followingNode.bounds.first()
                compose.onNodeWithTag("block-media-parent").performTouchInput {
                    click(Offset(followingPoint.centerX() + 20f, followingPoint.centerY() + 20f))
                }
                compose.runOnIdle {
                    assertEquals(listOf("parent-body", "following"), seen.links.drop(before))
                    assertTrue(seen.uris.isEmpty()); assertSame(owner, seen.owner)
                }
                assertEquals(listOf(url1), requests.toList()); assertEquals(0, metadata.get())
            }
        } } finally { directory.deleteRecursively() }
    }
}
