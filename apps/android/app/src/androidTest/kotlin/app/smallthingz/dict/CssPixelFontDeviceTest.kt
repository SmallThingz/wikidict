package app.smallthingz.dict

import androidx.activity.compose.setContent
import androidx.compose.foundation.background
import androidx.compose.foundation.text.contextmenu.data.TextContextMenuItem
import androidx.compose.foundation.text.contextmenu.data.TextContextMenuKeys
import androidx.compose.foundation.text.contextmenu.data.TextContextMenuSession
import androidx.compose.foundation.text.contextmenu.provider.LocalTextContextMenuToolbarProvider
import androidx.compose.foundation.text.contextmenu.provider.TextContextMenuDataProvider
import androidx.compose.foundation.text.contextmenu.provider.TextContextMenuProvider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Typography
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.toPixelMap
import androidx.compose.ui.layout.Layout
import androidx.compose.ui.layout.LayoutCoordinates
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.platform.ClipEntry
import androidx.compose.ui.platform.Clipboard
import androidx.compose.ui.platform.LocalClipboard
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.captureToImage
import androidx.compose.ui.test.click
import androidx.compose.ui.test.hasAnyAncestor
import androidx.compose.ui.test.hasClickAction
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.longClick
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performSemanticsAction
import androidx.compose.ui.test.performTouchInput
import androidx.compose.ui.text.LinkAnnotation
import androidx.compose.ui.text.TextLayoutResult
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.sp
import androidx.test.ext.junit.runners.AndroidJUnit4
import kotlinx.coroutines.CompletableDeferred
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import java.util.concurrent.atomic.AtomicReference

@RunWith(AndroidJUnit4::class)
class CssPixelFontDeviceTest {
    @get:Rule val compose = createPhysicalComposeRule()

    @Test fun actualAndroidConverterUsesNominalZoomAndLegacyReductionBeforeNonlinearScaling() {
        val density = Density(2f, 2f)
        val span = Span("link", "kept text", "kept-target", fontScale = 40f,
            fontScaleBasis = FontScaleBasis.CssPx, small = true, superscript = true, code = true)
        val expected = with(density) { 48.sp.toPx() }
        assertNotEquals(48f * density.density * density.fontScale, expected, .001f)
        assertNotEquals(with(density) { 60.sp.toPx() } * .8f, expected, .001f)
        for ((parent, body) in listOf(20.sp to 20.sp, 72.sp to 32.sp)) {
            val resolved = renderedSpanFontSize(span, parent, body, density, 1.5f)
            assertEquals(expected, with(density) { resolved.toPx() }, .01f)
        }
        assertEquals("kept-target", span.target)
        assertEquals("kept text", span.text)
        assertTrue(span.small && span.superscript && span.code)
        for (amount in listOf(0f, 1f, 12.375f)) for (zoom in listOf(.75f, 1f, 1.5f)) {
            val normal = span.copy(fontScale = amount, small = false, superscript = false, code = false)
            assertEquals(with(density) { (amount * zoom).sp.toPx() },
                with(density) { renderedSpanFontSize(normal, 20.sp, 32.sp, density, zoom).toPx() }, .01f)
        }
    }

    private data class Scene(val fontScale: Float, val zoom: Float, val width: Int,
        val parent: Float, val body: Float, val label: String, val target: String)

    @Test fun realTextPaintHitAndSelectionKeepOneOwnerAcrossZoomResizeAndRebind() {
        val scenes = listOf(
            Scene(1f, 1f, 320, 20f, 20f, "Font link", "font-first"),
            Scene(1f, 1.5f, 190, 20f, 32f, "Font link", "font-first"),
            Scene(2f, 1.5f, 320, 24f, 32f, "Rebound link", "font-second"))
        val current = mutableStateOf(scenes.first())
        val actions = mutableListOf<String>()
        val copied = AtomicReference<String?>(null)
        val clipboard = object : Clipboard {
            override val nativeClipboard: android.content.ClipboardManager
                get() = error("Only the test-local clipboard sink is permitted")
            override suspend fun getClipEntry(): ClipEntry? = null
            override suspend fun setClipEntry(clipEntry: ClipEntry?) {
                val clip = checkNotNull(clipEntry).clipData
                assertEquals(1, clip.itemCount)
                copied.set(checkNotNull(clip.getItemAt(0).text).toString())
            }
        }
        var coordinates: LayoutCoordinates? = null
        var shown: Pair<TextContextMenuDataProvider, TextContextMenuSession>? = null
        var menuShows = 0
        val toolbar = object : TextContextMenuProvider {
            override suspend fun showTextContextMenu(dataProvider: TextContextMenuDataProvider) {
                val closed = CompletableDeferred<Unit>()
                val session = object : TextContextMenuSession {
                    override fun close() { closed.complete(Unit) }
                }
                val owner = dataProvider to session
                shown = owner
                menuShows++
                try { closed.await() } finally { if (shown === owner) shown = null }
            }
        }
        fun item(key: Any) = shown?.first?.data()?.components
            ?.filterIsInstance<TextContextMenuItem>()?.singleOrNull { it.key == key }
        fun invoke(key: Any) {
            val owner = checkNotNull(shown)
            val root = checkNotNull(coordinates)
            assertTrue(root.isAttached)
            assertFalse(owner.first.contentBounds(root).isEmpty)
            checkNotNull(item(key)).onClick.invoke(owner.second)
        }
        try {
            compose.activityRule.scenario.onActivity { activity -> activity.setContent {
                val scene = current.value
                val density = Density(1f, scene.fontScale)
                MaterialTheme(typography = Typography(bodyLarge = TextStyle(fontSize = scene.body.sp))) {
                    CompositionLocalProvider(LocalDensity provides density,
                        LocalCssPixelTextZoom provides scene.zoom, LocalClipboard provides clipboard,
                        LocalTextContextMenuToolbarProvider provides toolbar) {
                        Layout(modifier = Modifier.background(Color.White).onGloballyPositioned { coordinates = it }, content = {
                            StyledText(listOf(
                                Span("link", scene.label, scene.target, fontScale = 12.375f,
                                    fontScaleBasis = FontScaleBasis.CssPx, bold = true, italic = true),
                                Span("text", " "),
                                Span("text", "zero", fontScale = 0f, fontScaleBasis = FontScaleBasis.CssPx),
                                Span("text", " tail", fontScale = 1.25f)),
                                style = TextStyle(fontSize = scene.parent.sp, lineHeight = 30.sp, color = Color.Black),
                                onLink = { actions += it.target })
                        }) { children, _ ->
                            val child = children.single().measure(Constraints.fixedWidth(scene.width))
                            layout(scene.width, child.height) { child.place(0, 0) }
                        }
                    }
                }
            } }
            scenes.forEachIndexed { index, scene ->
                compose.runOnIdle { current.value = scene; copied.set(null) }
                compose.waitForIdle()
                val full = scene.label + " zero tail"
                compose.onAllNodesWithText(full, useUnmergedTree = true).assertCountEquals(1)
                val node = compose.onNodeWithText(full, useUnmergedTree = true).assertIsDisplayed()
                val layouts = mutableListOf<TextLayoutResult>()
                node.performSemanticsAction(SemanticsActions.GetTextLayoutResult) { it(layouts) }
                val layout = layouts.single()
                assertEquals(full, layout.layoutInput.text.text)
                assertEquals(30.sp, layout.layoutInput.style.lineHeight)
                assertFalse(layout.hasVisualOverflow)
                val annotation = layout.layoutInput.text
                val link = annotation.getLinkAnnotations(0, full.length).single()
                assertEquals(scene.target, (link.item as LinkAnnotation.Clickable).tag)
                assertEquals(0, link.start); assertEquals(scene.label.length, link.end)
                val style = annotation.spanStyles.single { it.start == 0 && it.end == scene.label.length && it.item.fontSize.isSp }.item
                val density = Density(1f, scene.fontScale)
                assertEquals(with(density) { (12.375f * scene.zoom).sp.toPx() },
                    with(density) { style.fontSize.toPx() }, .01f)
                assertEquals(FontWeight.Bold, style.fontWeight); assertEquals(FontStyle.Italic, style.fontStyle)
                val zeroStart = scene.label.length + 1
                assertEquals(0.sp, annotation.spanStyles.single { it.start == zeroStart && it.end == zeroStart + 4 }.item.fontSize)
                val links = compose.onAllNodes(hasClickAction() and hasAnyAncestor(hasText(full)), useUnmergedTree = true)
                links.assertCountEquals(1); links[0].assertIsDisplayed()
                val glyph = layout.getBoundingBox(2).center
                assertTrue(links[0].fetchSemanticsNode().boundsInRoot.contains(node.fetchSemanticsNode().boundsInRoot.topLeft + glyph))
                val pixels = node.captureToImage().toPixelMap()
                var ink = 0
                for (y in 0 until pixels.height) for (x in 0 until pixels.width) {
                    val color = pixels[x, y]
                    if (color.alpha > .5f && minOf(color.red, color.green, color.blue) < .7f) ink++
                }
                assertTrue("Real text must paint after font/width changes", ink > 10)
                node.performTouchInput { click(glyph) }
                compose.runOnIdle { assertEquals(scenes.take(index + 1).map { it.target }, actions) }
                val shows = compose.runOnIdle { assertNull(shown); menuShows }
                node.performTouchInput { longClick(layout.getBoundingBox(full.length - 2).center) }
                compose.waitUntil(5000) { compose.runOnIdle {
                    menuShows > shows && item(TextContextMenuKeys.SelectAllKey) != null && item(TextContextMenuKeys.CopyKey) != null
                } }
                compose.runOnIdle { invoke(TextContextMenuKeys.SelectAllKey) }
                compose.waitForIdle()
                compose.waitUntil(5000) { compose.runOnIdle { item(TextContextMenuKeys.CopyKey) != null } }
                compose.runOnIdle { invoke(TextContextMenuKeys.CopyKey) }
                compose.waitUntil(5000) { copied.get() != null }
                assertEquals(full, copied.get())
                compose.waitUntil(5000) { compose.runOnIdle { shown == null } }
                compose.runOnIdle { assertEquals(scenes.take(index + 1).map { it.target }, actions) }
            }
        } finally {
            compose.activityRule.scenario.onActivity { it.setContent {} }
            compose.waitForIdle()
            compose.runOnIdle { assertNull(shown) }
        }
    }
}
