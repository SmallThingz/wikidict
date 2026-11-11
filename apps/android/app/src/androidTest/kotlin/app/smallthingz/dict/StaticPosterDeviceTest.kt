package app.smallthingz.dict

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.RectF
import android.graphics.Typeface
import androidx.activity.compose.setContent
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Column
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.layout.Layout
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalWindowInfo
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.platform.UriHandler
import androidx.compose.ui.platform.WindowInfo
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.captureToImage
import androidx.compose.ui.test.click
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.performTouchInput
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.sp
import androidx.test.platform.app.InstrumentationRegistry
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.File
import java.net.URI
import java.util.UUID
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

class StaticPosterDeviceTest {
    @get:Rule val compose = createPhysicalComposeRule()
    private val poster = StaticPoster(StaticPosterPolicy.ThreeDStlV1, "3D", "a".repeat(40), "2026-01-02T03:04:05Z")
    private val image = InlineImage("Controlled.stl", 250, 188, alt = "Original alternative", staticPoster = poster)
    private fun png(width: Int = 250, height: Int = 188): ByteArray {
        val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
        return try { bitmap.eraseColor(0xff00aa44.toInt()); ByteArrayOutputStream().also {
            bitmap.compress(Bitmap.CompressFormat.PNG, 100, it)
        }.toByteArray() } finally { bitmap.recycle() }
    }
    private fun response(sha1: String = poster.fileSha1, timestamp: String = poster.fileTimestamp,
        width: Int = 250, height: Int = 188, thumb: Boolean = true): String =
        """{"query":{"pages":[{"imageinfo":[{"canonicaltitle":"File:Controlled.stl","sha1":"$sha1","timestamp":"$timestamp","width":5120,"height":2880,"mime":"application/sla","mediatype":"3D","url":"https://upload.wikimedia.org/wikipedia/commons/a/aa/Controlled.stl",${if (thumb) "\"thumburl\":\"https://upload.wikimedia.org/wikipedia/commons/thumb/a/aa/Controlled.stl/${width}px-Controlled.stl.png\",\"thumbmime\":\"image/png\",\"thumbwidth\":$width,\"thumbheight\":$height," else ""}"descriptionurl":"https://commons.wikimedia.org/wiki/File:Controlled.stl"}]}]}}"""

    @Test fun controlledCacheUsesPinnedPngAndRejectsChangedIdentityAndWrongDownloadedAxes() = runBlocking {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val directory = File(context.cacheDir, "stl-resource-" + UUID.randomUUID()).apply { check(mkdir()) }
        val urls = mutableListOf<String>(); var current = response(); var bytes = png()
        val cache = MediaCache(context, metadata = { url ->
            assertTrue(url.contains("sha1%7Ctimestamp%7Cmediatype%7Ccanonicaltitle"))
            assertTrue(url.contains("iiurlwidth=250")); current.toByteArray()
        }, openMedia = { url -> urls += url; ByteArrayInputStream(bytes) }, directory = directory)
        val request = StaticPosterRequest(1f, listOf(RasterImageOccurrence(image)))
        suspend fun load(refresh: Boolean = false): DecodedMediaBitmap = cache.withFile(Media(image.file, "image", ""), 2,
            forceRefresh = refresh, canonicalFile = true, posterRequest = request) {
            decodeMediaBitmap(it.file, 1600, it.requiredRasterWidth, it.requiredRasterHeight, it.exactRasterWidth, it.exactRasterHeight)
        }
        try {
            load().also { assertEquals(250, it.width); assertEquals(188, it.height); it.bitmap.recycle() }
            load().bitmap.recycle(); assertEquals(1, urls.size)
            assertTrue(urls.single().endsWith(".png"))
            for (bad in listOf(response(sha1 = "b".repeat(40)), response(timestamp = "2026-01-02T03:04:06Z"), response(thumb = false), response(height = 141))) {
                current = bad
                var refused = false
                try { load(true).bitmap.recycle() } catch (_: Exception) { refused = true }
                assertTrue(refused); assertEquals(1, urls.size)
            }
            current = response(); bytes = png(250, 141)
            var refused = false
            try { load(true).bitmap.recycle() } catch (_: Exception) { refused = true }
            assertTrue(refused); assertEquals(2, urls.size)
        } finally { cache.clear(); check(directory.deleteRecursively()) }
    }

    @Test fun badgeUsesSourceSansNativeLinesGroupOpacityAndWrapperClipIncludingEmptyLabel() {
        val wrapper = RectF(4f, 3f, 90f, 70f)
        val badge = NativeStaticPosterBadge(poster.copy(label = "  A\u0301\u0323  \u05d0\u05d1  "), 1f)
        assertEquals(Typeface.create("sans-serif", Typeface.BOLD), badge.paint.typeface)
        assertEquals("A\u0301\u0323 \u05d0\u05d1", badge.text)
        val bitmap = Bitmap.createBitmap(100, 80, Bitmap.Config.ARGB_8888)
        try {
            badge.draw(Canvas(bitmap), wrapper)
            var glyphs = 0; var background = 0
            for (y in 0 until bitmap.height) for (x in 0 until bitmap.width) {
                val pixel = bitmap.getPixel(x, y)
                if (!wrapper.contains(x + .5f, y + .5f)) assertEquals(0, pixel)
                assertTrue((pixel ushr 24) <= 204)
                if (pixel == 0xccf8f9fa.toInt()) background++
                if (pixel ushr 24 != 0 && pixel and 0xffffff != 0xf8f9fa) glyphs++
            }
            assertTrue(background > 20); assertTrue(glyphs > 10)
            val empty = NativeStaticPosterBadge(poster.copy(label = " \t\n"), 1f).box(wrapper)
            assertNull(empty.layout); assertEquals(10f, empty.bounds.width(), 0f); assertEquals(4f, empty.bounds.height(), 0f)
            assertEquals(poster.copy(label = " \t\n"), NativeStaticPosterBadge(poster.copy(label = " \t\n"), 1f).identity)
        } finally { bitmap.recycle() }
    }

    @Test fun unsupportedInlineAndCaptionTableKeepVisibleReasonBodyAndOriginalActions() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val directory = File(context.cacheDir, "stl-unsupported-" + UUID.randomUUID()).apply { check(mkdir()) }
        var requests = 0
        val cache = MediaCache(context, metadata = { requests++; error("Unsupported inline must not request a raster") },
            openMedia = { error("Unsupported inline must not open a raster") }, directory = directory)
        val span = Span("link", "", target = "local-image-action", image = image)
        val actions = mutableListOf<EntryLink>(); var geometry: NativeAnonymousFlowGeometry? = null
        try {
            compose.activityRule.scenario.onActivity { it.setContent { MaterialTheme {
                CompositionLocalProvider(LocalInlineImageCache provides cache) {
                    Column(Modifier.testTag("stl-scene").background(Color.White)) {
                        StyledText(listOf(span), onLink = { actions += it })
                        AnonymousBlockView(Block("paragraph", 0, listOf(span)), Modifier.testTag("native-inline"),
                            { actions += it }, listOf(Media(image.file, "image", "")), AppSettings(allowImages = true), "it",
                            onFlowGeometry = { geometry = it })
                    }
                }
            } } }
            compose.waitUntil(10000) { geometry?.nodes?.any { it.kind == FloatInteractionKind.IMAGE } == true }
            retain("stl-unsupported-inline.png", geometry)
            compose.onNodeWithText("Image layout unavailable. Original alternative 3D").assertIsDisplayed()
            val node = checkNotNull(geometry).nodes.single { it.kind == FloatInteractionKind.IMAGE }
            assertEquals("Image layout unavailable", node.stateDescription.toString())
            assertEquals("Original alternative, 3D", node.label.toString())
            val bounds = node.bounds.single()
            compose.onNodeWithTag("native-inline").performTouchInput { click(Offset(bounds.centerX(), bounds.centerY())) }
            compose.runOnIdle { assertEquals("local-image-action", actions.single().target); assertEquals(0, requests) }
            val table = Table(emptyList(), listOf(listOf(Cell(listOf(Span("link", "Cell body", target = "cell-action")), false, 1, 1))))
            val unsupported = figure(false).copy(captionBlocks = listOf(Block("table", 0, emptyList(), table = table)))
            compose.activityRule.scenario.onActivity { it.setContent { MaterialTheme {
                val original = LocalWindowInfo.current
                val window = object : WindowInfo by original { override val containerSize = IntSize(1920, 1080) }
                CompositionLocalProvider(LocalWindowInfo provides window, LocalDensity provides Density(1f), LocalInlineImageCache provides cache) {
                    AnonymousBlockView(Block("paragraph", 0, emptyList(), figure = unsupported), Modifier,
                        { actions += it }, listOf(Media(image.file, "image", "")), AppSettings(allowImages = false), "it")
                }
            } } }
            compose.waitForIdle()
            compose.onNodeWithText("Unable to display this layout.").assertIsDisplayed()
            compose.onNodeWithText("Cell body").assertIsDisplayed().performTouchInput { click() }
            compose.runOnIdle { assertEquals("cell-action", actions.last().target) }
        } finally {
            compose.activityRule.scenario.onActivity { it.setContent {} }; compose.waitForIdle()
            runBlocking { cache.clear() }; check(directory.deleteRecursively())
        }
    }

    private fun px(value: Float) = StyleLength(StyleLengthUnit.Px, value)
    private fun figure(empty: Boolean): Figure {
        val zero = px(0f); val three = px(3f)
        val caption = if (empty) emptyList() else listOf(Span("link", "caption first line second line", target = "caption", foreground = "#000000", bold = true))
        return Figure(FigureContent.Image(Span("link", "", target = "File:Controlled.stl", image = image), FigureSizingPolicy.RequestedFit),
            FigureFormat.Thumbnail, FigurePlacement.FloatRight, FigureClear.Both, StyleEdges(three, zero, three, three),
            StyleEdges(three, three, three, three), StyleEdges(zero, px(6f), px(6f), px(6f)), 1f, px(14f),
            FigureColor.Transparent, FigureBorder.None, FigureColor.Transparent, FigureBorder.Solid(px(1f), FigureColor.Rgb("#000000")),
            FigureColor.Rgb("#000000"), FigureColor.Transparent, captionBlocks = if (empty) null else listOf(Block("paragraph", 0, caption)))
    }
    private fun retain(name: String, geometry: NativeAnonymousFlowGeometry?) {
        val node = compose.onNodeWithTag("stl-scene"); val bitmap = node.captureToImage().asAndroidBitmap()
        val text = renderedLayoutFailureEvidence(name, null, null, node, name, bitmap) +
            "\nfigures=${geometry?.figures?.map { it.bounds }}; text=${geometry?.text}; nodes=${geometry?.nodes?.map { it.label to it.bounds }}"
        check(text.toByteArray().size <= 128 * 1024 && "OWNED_PNG_BEGIN $name " in text)
        InstrumentationRegistry.getInstrumentation().sendStatus(0, android.os.Bundle().apply {
            putString(android.app.Instrumentation.REPORT_KEY_STREAMRESULT, "\n$text\n")
        })
    }

    private fun nativeOwner(): NativeFloatTextView {
        val views = mutableListOf<NativeFloatTextView>()
        compose.activityRule.scenario.onActivity { activity ->
            fun visit(view: android.view.View) {
                if (view is NativeFloatTextView) views += view
                if (view is android.view.ViewGroup) for (index in 0 until view.childCount) visit(view.getChildAt(index))
            }
            visit(activity.window.decorView)
        }
        return views.single()
    }

    @Test fun sameFigureRetainsRichCaptionActionsAndResponsiveFloatAtRootViewportBoundaries() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val directory = File(context.cacheDir, "stl-figure-" + UUID.randomUUID()).apply { check(mkdir()) }
        val cache = MediaCache(context, metadata = { url ->
            val requested = Regex("iiurlwidth=([0-9]+)").find(url)!!.groupValues[1].toInt()
            response(width = requested, height = (requested * 3 + 2) / 4).toByteArray()
        }, openMedia = { url ->
            val requested = URI(url).path.substringAfterLast('/').substringBefore("px-").toInt()
            ByteArrayInputStream(png(requested, (requested * 3 + 2) / 4))
        }, directory = directory)
        val viewport = mutableStateOf(640.0); val width = mutableStateOf(140); val empty = mutableStateOf(false)
        val actions = mutableListOf<EntryLink>(); val urls = mutableListOf<String>()
        val uri = object : UriHandler { override fun openUri(uri: String) { urls += uri } }
        var geometry: NativeAnonymousFlowGeometry? = null
        try {
            compose.activityRule.scenario.onActivity { activity -> activity.setContent {
                val originalWindow = LocalWindowInfo.current
                val density = 2f // 639.5 CSS pixels is an exact physical1279px root width.
                val window = object : WindowInfo by originalWindow { override val containerSize = IntSize((viewport.value * density).toInt(), 1800) }
                MaterialTheme(typography = MaterialTheme.typography.copy(bodyLarge = MaterialTheme.typography.bodyLarge.copy(fontFamily = FontFamily.Serif, fontSize = 8.sp, lineHeight = 10.sp))) {
                    CompositionLocalProvider(LocalDensity provides Density(density, 1f), LocalWindowInfo provides window,
                        LocalInlineImageCache provides cache, LocalUriHandler provides uri) {
                        Layout(modifier = Modifier.testTag("stl-scene").background(Color.White), content = {
                            AnonymousBlockView(Block("paragraph", 0, emptyList(), figure = figure(empty.value)), Modifier,
                                { actions += it }, listOf(Media(image.file, "image", "")), AppSettings(allowImages = true), "it",
                                onFlowGeometry = { geometry = it })
                        }) { children, constraints ->
                            val child = children.single().measure(Constraints.fixedWidth(width.value))
                            layout(320, minOf(constraints.maxHeight, 500)) { child.place(0, 0) }
                        }
                    }
                }
            } }
            compose.waitUntil(10000) { (geometry?.figures?.singleOrNull()?.measured?.geometry as? NativeFigureGeometry)?.metrics?.image?.sourceWidth == 250.0 }
            val owner = nativeOwner()
            var wideFirstEnd = -1
            for ((index, css) in listOf(640.0, 639.0, 639.5, 640.0).withIndex()) {
                compose.runOnIdle { viewport.value = css }; compose.waitForIdle()
                val flow = checkNotNull(geometry); val placed = flow.figures.single(); val frame = placed.measured.geometry as NativeFigureGeometry
                retain("stl-responsive-$index.png", flow)
                assertEquals(if (css <= 639) FigurePlacement.Center else FigurePlacement.FloatRight, placed.anchor.event.figure.placement)
                assertEquals(FigureClear.Both, placed.anchor.event.figure.clear)
                assertTrue(frame.metrics.image.width <= 124f)
                assertEquals("caption first line second line", flow.text.toString())
                assertSame(owner, nativeOwner())
                val firstEnd = frame.lineRange(0).second
                if (css > 639) { if (wideFirstEnd < 0) wideFirstEnd = firstEnd else assertEquals(wideFirstEnd, firstEnd) }
                else assertTrue(firstEnd > wideFirstEnd)
                val imageNode = flow.nodes.single { it.label?.toString()?.contains("Original alternative") == true }
                assertTrue(imageNode.label.toString().contains("3D"))
                val bounds = imageNode.bounds.single()
                compose.onNodeWithTag("stl-scene").performTouchInput { click(Offset(bounds.centerX(), bounds.centerY())) }
                compose.runOnIdle { assertEquals(inlineImageLinkUrl(figure(false).content.span, "it"), urls.last()) }
                val caption = flow.nodes.first { it.label?.toString() == "caption first line second line" }
                val target = caption.bounds.first()
                compose.onNodeWithTag("stl-scene").performTouchInput { click(Offset(target.centerX(), target.centerY())) }
                compose.runOnIdle { assertEquals("caption", actions.last().target) }
            }
            compose.runOnIdle { width.value = 280 }; compose.waitForIdle()
            assertEquals(FigurePlacement.FloatRight, checkNotNull(geometry).figures.single().anchor.event.figure.placement)
            compose.runOnIdle { empty.value = true }; compose.waitForIdle()
            var frame = checkNotNull(geometry).figures.single().measured.geometry as NativeFigureGeometry
            assertEquals(frame.metrics.height(22), frame.height) // wide table-caption encloses11 CSSpx float
            compose.runOnIdle { viewport.value = 639.0 }; compose.waitForIdle()
            frame = checkNotNull(geometry).figures.single().measured.geometry as NativeFigureGeometry
            assertEquals(frame.metrics.height(0), frame.height)
            assertEquals(6f, frame.metrics.captionPadding.bottom, 0f)
        } finally {
            compose.activityRule.scenario.onActivity { it.setContent {} }; compose.waitForIdle()
            runBlocking { cache.clear() }; check(directory.deleteRecursively())
        }
    }
}
