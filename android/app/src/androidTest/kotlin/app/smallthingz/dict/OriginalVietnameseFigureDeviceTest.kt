package app.smallthingz.dict

import android.graphics.Rect
import android.graphics.RectF
import android.view.View
import android.view.ViewGroup
import android.view.accessibility.AccessibilityNodeInfo
import androidx.activity.compose.setContent
import androidx.compose.material3.Surface
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.captureToImage
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.platform.UriHandler
import androidx.test.platform.app.InstrumentationRegistry
import java.nio.file.Files
import java.security.MessageDigest
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

class OriginalVietnameseFigureDeviceTest {
    @get:Rule val compose = createPhysicalContentRule()

    @Test fun originalDictionaryParagraphFloatsItsOfflineThumbnailAndOpensItsSource() =
        verifyOriginal("original.wikblb.xz", 43, 35976,
            "3a4fa0667a9c0cd986637c6e7d607d633e9892c175f8e91c72973a5176d3da63", null)

    @Test fun originalIntrinsicThumbnailReservesItsSourceAspectRatioOffline() =
        verifyOriginal("intrinsic.wikblb.xz", 43, 35984,
            "ffacc5aa2773ac39a31f17e5160c9df68e04d0ecba433c66218fc5e9af91e2c7", FigureIntrinsicSize(1408, 1120))

    @Suppress("DEPRECATION")
    private fun verifyOriginal(asset: String, offset: Long, length: Int, recordSha: String, size: FigureIntrinsicSize?) {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val temp = Files.createTempDirectory(instrumentation.targetContext.cacheDir.toPath(), "vi-figure-").toFile()
        val shard = temp.resolve(asset)
        val opened = mutableListOf<String>()
        val navigation = mutableListOf<EntryLink>()
        try {
            instrumentation.context.assets.open("vi1034/$asset").use { input ->
                shard.outputStream().use { input.copyTo(it) }
            }
            val data = BlobSource(shard).use { blob ->
                check(blob.compressed && blob.length == offset + length)
                blob.read(offset, length)
            }
            assertEquals(recordSha,
                MessageDigest.getInstance("SHA-256").digest(data).joinToString("") { "%02x".format(it) })
            val entry = BlobDecoder.decode(data, "từ điển", "language", "Tiếng Việt", "vi")
            val section = entry.sections.single { it.title == "Tiếng Việt" }
            val paragraph = section.blocks[2]
            assertEquals("paragraph", paragraph.kind)
            val figure = checkNotNull(paragraph.figure)
            assertEquals(size, figure.intrinsicSize)
            val image = figure.content as FigureContent.Image
            assertEquals(FigureFormat.Thumbnail, figure.format)
            assertEquals(FigureSizingPolicy.RequestedFit, image.sizing)
            assertEquals(FigurePlacement.FloatRight, figure.placement)
            assertEquals(FigureClear.Right, figure.clear)
            assertEquals(CellTextAlign.Left, figure.captionTextAlign)
            assertEquals("từ điển", figure.caption.joinToString("") { it.text })
            assertEquals("link", image.span.kind)
            assertEquals("File:Latin dictionary.jpg", image.span.target)
            assertEquals(250L, checkNotNull(image.span.image).widthPx)
            val uri = object : UriHandler { override fun openUri(uri: String) { opened += uri } }
            // Keep the paragraph, media state, native paint and public interaction owner together.
            var measured: NativeAnonymousFlowGeometry? = null
            val settings = AppSettings(allowImages = false, allowAudio = false)
            compose.activityRule.scenario.onActivity { activity -> activity.setContent {
                CompositionLocalProvider(LocalUriHandler provides uri) {
                    DictTheme("light") { Surface {
                        val flow = NativeFloatContextSpec.Flow(0, 0f, null, null, false) { carried, sink ->
                            AnonymousBlockView(paragraph, Modifier, { navigation += it }, entry.media,
                                settings, "viwiktionary-20261001", interactionOwner = false,
                                carriedExclusions = carried, onFlowGeometry = { measured = it; sink(it) })
                        }
                        NativeFloatContextLayout(listOf(flow), Modifier.testTag("vi-source-paragraph"), androidx.compose.ui.graphics.Color.Transparent,
                            containAtEnd = true, documentSurface = true) { _, _ -> error("Original paragraph has no delegated child") }
                    } }
                }
            } }
            compose.waitForIdle()
            lateinit var imageWindow: RectF
            lateinit var captionWindow: RectF
            compose.runOnIdle {
                assertPhysicalActivity(compose.activity)
                check(compose.activity.hasWindowFocus())
                val owners = mutableListOf<NativeFloatTextView>()
                fun visit(view: View) {
                    if (view is NativeFloatTextView && view.isShown &&
                        view.currentMeasuredGeometry?.nodes?.any { it.kind == FloatInteractionKind.IMAGE } == true) owners += view
                    if (view is ViewGroup) repeat(view.childCount) { visit(view.getChildAt(it)) }
                }
                visit(compose.activity.window.decorView)
                val view = owners.single()
                val flow = checkNotNull(measured)
                val placed = flow.figures.single()
                // The placed child exposes selection and actions while Compose paints its own pixels.
                val frame = placed.measured.geometry
                assertEquals("từ điển", frame.text.toString())
                val exclusion = flow.ownExclusions.single()
                assertEquals(TableFloatSide.Right, exclusion.side)
                assertEquals(flow.width.toFloat(), exclusion.outer.right, 1f)
                assertTrue(placed.bounds.left > 0f)
                assertEquals(placed.bounds.right, exclusion.outer.right, 1f)
                val density = view.resources.displayMetrics.density
                val imageNode = frame.nodes.single { it.kind == FloatInteractionKind.IMAGE }
                val bounds = imageNode.bounds.single()
                assertEquals(250f * density, bounds.width(), 1f)
                val one = StyleLength(StyleLengthUnit.Px, 1f)
                val three = StyleLength(StyleLengthUnit.Px, 3f)
                assertEquals(StyleEdges(three, three, three, three), figure.imageInsets)
                assertEquals(FigureBorder.Solid(one, FigureColor.NativeTheme), figure.frameBorder)
                assertEquals(FigureBorder.Solid(one, FigureColor.NativeTheme), figure.imageBorder)
                // The frame border, image inset and image border each retain their own width.
                assertEquals(5f * density, bounds.left, .01f)
                assertEquals(5f * density, bounds.top, .01f)
                assertEquals(5f * density, frame.width - bounds.right, 1f)
                if (size != null) assertEquals(199f * density, bounds.height(), 1f)
                else assertTrue(bounds.height() > 0f)
                assertEquals("Images disabled", imageNode.stateDescription?.toString())
                val caption = frame.rectsForRange(0, frame.text.length)
                assertTrue(caption.isNotEmpty() && caption.all { it.width() > 0f && it.top >= bounds.bottom - 1f })
                val local = flow.nodes.single { it.kind == FloatInteractionKind.IMAGE }
                val shifted = RectF(bounds).apply { offset(placed.bounds.left, placed.bounds.top) }
                assertEquals(shifted, local.bounds.single())
                assertEquals(local.id, flow.interactionNodeAt(shifted.centerX(), shifted.centerY())?.id)
                val node = checkNotNull(view.currentMeasuredGeometry).nodes.single { it.kind == FloatInteractionKind.IMAGE }
                assertTrue(node.stateDescription?.toString().orEmpty().contains("disabled", ignoreCase = true))
                val window = IntArray(2).also(view::getLocationInWindow)
                val liveBounds = node.bounds.single()
                val frameX = window[0] + view.paddingLeft + liveBounds.left - bounds.left
                val frameY = window[1] + view.paddingTop + liveBounds.top - bounds.top
                imageWindow = RectF(bounds).apply { offset(frameX, frameY) }
                captionWindow = RectF(caption.first()).apply {
                    caption.drop(1).forEach { union(it) }
                    offset(frameX, frameY)
                }
                val provider = view.accessibilityNodeProvider
                val info = checkNotNull(provider.createAccessibilityNodeInfo(node.id))
                try {
                    val screen = Rect().also(info::getBoundsInScreen)
                    assertFalse(screen.isEmpty)
                    assertTrue(info.isVisibleToUser && info.isEnabled && info.isClickable)
                    assertTrue(provider.performAction(node.id, AccessibilityNodeInfo.ACTION_CLICK, null))
                } finally { info.recycle() }
                assertEquals(listOf("https://vi.wiktionary.org/wiki/File%3ALatin%20dictionary.jpg"), opened)
                assertTrue(navigation.isEmpty())
            }
            val viewport = compose.onNodeWithTag("vi-source-paragraph", useUnmergedTree = true)
            val origin = viewport.fetchSemanticsNode().boundsInWindow
            val bitmap = viewport.captureToImage().asAndroidBitmap()
            try {
                for (area in listOf(imageWindow, captionWindow)) {
                    val left = kotlin.math.ceil(area.left - origin.left).toInt() + 1
                    val right = kotlin.math.floor(area.right - origin.left).toInt() - 1
                    val top = kotlin.math.ceil(area.top - origin.top).toInt() + 1
                    val bottom = kotlin.math.floor(area.bottom - origin.top).toInt() - 1
                    assertTrue("Original caption and offline image status must be visible: $area",
                        left in 0 until right && right <= bitmap.width && top in 0 until bottom && bottom <= bitmap.height)
                    var darkest = 255
                    var lightest = 0
                    for (y in top until bottom) for (x in left until right) {
                        val pixel = bitmap.getPixel(x, y)
                        val luminance = (android.graphics.Color.red(pixel) * 3 + android.graphics.Color.green(pixel) * 6 +
                            android.graphics.Color.blue(pixel)) / 10
                        darkest = minOf(darkest, luminance)
                        lightest = maxOf(lightest, luminance)
                    }
                    assertTrue("Expected actual text ink inside original source area $area", lightest - darkest > 48)
                }
            } finally { bitmap.recycle() }
        } finally {
            compose.runOnIdle { compose.activity.setContent {} }
            compose.waitForIdle()
            check(temp.deleteRecursively())
        }
    }
}
