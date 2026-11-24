package app.smallthingz.dict

import android.graphics.Bitmap
import android.graphics.RectF
import androidx.activity.compose.setContent
import androidx.compose.material3.Surface
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.SideEffect
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.Density
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

class IntrinsicThumbnailStateDeviceTest {
    @get:Rule val compose = createPhysicalContentRule()

    @Test fun storedRasterAxesKeepTheSameCaptionAndActionAcrossMediaStates() {
        val zero = StyleLength(StyleLengthUnit.Px, 0f)
        val edges = StyleEdges(zero, zero, zero, zero)
        val image = InlineImage("Controlled dimensions.png", widthPx = 250, alt = "")
        val action = Span("link", "", "File:Controlled dimensions.png", image = image)
        val source = Figure(FigureContent.Image(action, FigureSizingPolicy.RequestedFit), FigureFormat.Thumbnail,
            FigurePlacement.FloatRight, FigureClear.Right, edges, edges, edges, 1f,
            StyleLength(StyleLengthUnit.Px, 24f), FigureColor.Transparent, FigureBorder.None,
            FigureColor.Transparent, FigureBorder.None, FigureColor.NativeTheme, FigureColor.Transparent,
            caption = listOf(Span("text", "caption")), intrinsicSize = FigureIntrinsicSize(1408, 1120))
        val block = Block("paragraph", 0, emptyList(), figure = source)
        val media = listOf(Media(image.file, "image", ""))
        val settings = AppSettings(allowImages = false, allowAudio = false)
        var owner: InlineImageViewOwner? = null
        var measured: NativeAnonymousFlowGeometry? = null
        val controlBitmap = Bitmap.createBitmap(1, 1, Bitmap.Config.ARGB_8888).apply { eraseColor(android.graphics.Color.BLUE) }
        data class Geometry(val image: RectF, val caption: List<RectF>, val float: RectF)
        try {
            compose.activityRule.scenario.onActivity { activity -> activity.setContent {
                DictTheme("light") { Surface { CompositionLocalProvider(LocalDensity provides Density(1f, 1f)) {
                    val active = rememberInlineImageViewOwner(listOf(image), media, settings, "viwiktionary-20261001")
                    SideEffect { owner = active }
                    CompositionLocalProvider(LocalInlineImageOwner provides active) {
                        val flow = NativeFloatContextSpec.Flow(0, 0f, null, null, false) { carried, sink ->
                            AnonymousBlockView(block, Modifier, {}, media, settings, "viwiktionary-20261001",
                                interactionOwner = false, carriedExclusions = carried,
                                onFlowGeometry = { measured = it; sink(it) })
                        }
                        NativeFloatContextLayout(listOf(flow), Modifier, Color.Blue, containAtEnd = true,
                            documentSurface = true) { _, _ -> error("Original figure is a paragraph") }
                    }
                } } }
            } }
            compose.waitForIdle()
            fun read(status: String): Geometry = compose.runOnIdle {
                val flow = checkNotNull(measured)
                val placed = flow.figures.single()
                val geometry = placed.measured.geometry
                assertEquals("caption", geometry.text.toString())
                val node = geometry.nodes.single()
                assertEquals(FloatInteractionKind.IMAGE, node.kind)
                assertNotNull(node.onClick)
                assertEquals(status, node.stateDescription.toString())
                val content = RectF(node.bounds.single())
                assertEquals(250f, content.width(), 0f)
                assertEquals(199f, content.height(), 0f)
                val caption = geometry.rectsForRange(0, geometry.text.length)
                assertTrue(caption.isNotEmpty() && caption.all { it.top >= content.bottom })
                Geometry(content, caption.map(::RectF), RectF(placed.bounds))
            }
            val first = read("Images disabled")
            val ready = InlineImageAssetState.Ready(DecodedMediaBitmap(controlBitmap, 1, 1), 1408L, 1120L,
                "image/png", "Controlled one-pixel image", "")
            for ((state, status) in listOf(InlineImageAssetState.Loading to "Loading image",
                InlineImageAssetState.Failed to "Image unavailable", ready to "")) {
                compose.runOnIdle { checkNotNull(owner).states[inlineImageAssetKey(image)] = state }
                compose.waitForIdle()
                assertEquals(first, read(status))
            }
            assertThrows(IllegalArgumentException::class.java) { source.copy(intrinsicSize = FigureIntrinsicSize(200, 1120)) }
            assertThrows(IllegalArgumentException::class.java) { FigureIntrinsicSize(0, 1120) }
            assertThrows(IllegalArgumentException::class.java) { FigureIntrinsicSize(1408, Int.MAX_VALUE.toLong() + 1) }
            assertThrows(IllegalArgumentException::class.java) {
                source.copy(content = FigureContent.Image(action.copy(image = image.copy(file = "Control.svg")), FigureSizingPolicy.RequestedFit))
            }
        } finally {
            compose.runOnIdle { compose.activity.setContent {} }
            compose.waitForIdle()
            controlBitmap.recycle()
        }
    }
}
