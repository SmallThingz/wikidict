package app.smallthingz.dict

import android.graphics.Bitmap
import android.os.Bundle
import android.view.KeyEvent
import android.view.View
import android.view.accessibility.AccessibilityNodeInfo
import androidx.activity.compose.setContent
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.toPixelMap
import androidx.compose.ui.layout.Layout
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.positionInWindow
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.platform.UriHandler
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.captureToImage
import androidx.compose.ui.test.click
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.performTouchInput
import androidx.compose.ui.test.swipe
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.unit.dp
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/** Typed shape follows the two genuine Mai TABLE/TD/paragraph.figure owners. These
 * controlled pixels/URLs are marked fixtures, not a claim that a new Writer page ran. */
@RunWith(AndroidJUnit4::class)
class NativeDelegatedTableDeviceTest {
    @get:Rule val compose = createPhysicalComposeRule()
    private var decorView: View? = null
    private val images = listOf(
        InlineImage("Delegated-Mai-PNG.png", widthPx = 190L, heightPx = 248L, alt = ""),
        InlineImage("Delegated-Mai-JPEG.jpg", widthPx = 190L, heightPx = 296L, alt = ""),
    )
    private val axes = listOf(460 to 600, 2420 to 3775)
    private val captions = listOf("First retained caption", "Second retained caption")
    private val urls = listOf("https://example.invalid/figure/first", "https://example.invalid/figure/second")
    private fun px(value: Float) = StyleLength(StyleLengthUnit.Px, value)
    private fun edges(value: Float) = StyleEdges(px(value), px(value), px(value), px(value))
    private val noEdges = FigureBorderEdges(FigureBorderEdge.None, FigureBorderEdge.None,
        FigureBorderEdge.None, FigureBorderEdge.None)
    private fun captionPolicy(): FigureLinkPaint {
        val states = listOf("#3366cc", "#3056a9", "#233566", "#6a60b0", "#534fa3", "#353262")
            .mapIndexed { index, rgb -> FigureLinkState(rgb, index % 3 != 0) }
        return FigureLinkPaint(states[0], states[1], states[2], states[3], states[4], states[5], true,
            FigureFocusOutline(px(2f), FigureColor.Rgb("#ff0000"), px(2f),
                SignedContainerMargin(StyleLengthUnit.Px, -2f)))
    }

    private fun figure(index: Int, label: String): Figure {
        val media = FigureMediaLayout(FigureMediaStrut(1f, direction = BidiResolvedDirection.Ltr),
            InlineBoxVerticalAlign.Middle, positioning = ContainerPositioning.RelativeAuto,
            after = FigureMediaAfter(px(15f), px(11f), TableFloatSide.Right, px(6f),
                SignedContainerMargin(StyleLengthUnit.Px, -11f),
                FigureGraphicPaint(FigureMediaGraphic.MagnifyClipLtrV1)),
            focusOutline = FigureFocusOutline(px(2f), FigureColor.Rgb("#ff0000"), px(2f),
                SignedContainerMargin(StyleLengthUnit.Px, 0f)))
        val before = ContainerStyle(width = ContainerWidth.Length(StyleWidth(StyleWidthUnit.Px, 15f)), height = px(11f),
            floatSide = TableFloatSide.Right, margins = StyleEdges(px(0f), px(0f), px(0f), px(3f)))
        return Figure(FigureContent.Image(Span("external_link", "", urls[index], image = images[index]),
            FigureSizingPolicy.RequestedFit), FigureFormat.Thumbnail, FigurePlacement.None, FigureClear.None,
            edges(0f), edges(3f), edges(6f), 1f, px(24f), FigureColor.Transparent, FigureBorder.None,
            FigureColor.Transparent, FigureBorder.None, FigureColor.NativeTheme, FigureColor.Rgb("#ffffff"),
            caption = listOf(Span("link", label, "caption-$index")),
            tableCaptionLayout = TableCaptionLayout(TableCollapse.Collapse, ContainerStyle(), noEdges, noEdges,
                media, captionBefore = before, captionLinkPaint = captionPolicy()))
    }

    private fun table(labels: List<String> = captions) = Table(emptyList(), images.indices.map { index ->
        listOf(Cell(emptyList(), false, 10, 1, blocks = listOf(
            Block("paragraph", 0, emptyList(), figure = figure(index, labels[index]))),
            style = CellStyle(padding = edges(0f))))
    }, style = TableStyle(floatSide = TableFloatSide.Right, clear = FigureClear.Right,
        margins = StyleEdges(px(0f), px(0f), px(16f), px(16f))))

    private class Holder {
        var owner: InlineImageViewOwner? = null
        var origin = Offset.Zero
        var created = 0
        var disposed = 0
        var density = 1f
        var appliedPulse = -1
    }

    @Composable
    private fun Fixture(table: Table, width: Int, bitmap: Bitmap, holder: Holder,
        actions: MutableList<String>, opened: MutableList<String>, opaqueSibling: Boolean = false,
        enabled: Boolean = true, recomposeToken: Int = 0) {
        val settings = AppSettings(allowImages = false, allowAudio = false)
        val media = images.map { Media(it.file, "image", "") }
        MaterialTheme { CompositionLocalProvider(
            LocalUriHandler provides remember { object : UriHandler {
                override fun openUri(uri: String) { opened += uri }
            } }) {
            val owner = rememberInlineImageViewOwner(images, media, settings, "enwiktionary-20261001")
            remember(owner) {
                images.forEachIndexed { index, image ->
                    owner.states[image.file] = InlineImageAssetState.Ready(DecodedMediaBitmap(bitmap, 46, 60),
                        axes[index].first.toLong(), axes[index].second.toLong(), "image/png", "controlled delegated pixels", "")
                }
                true
            }
            DisposableEffect(owner) { holder.created++; onDispose { holder.disposed++ } }
            val density = LocalDensity.current
            val widthPixels = with(density) { width.dp.roundToPx() }
            SideEffect { holder.owner = owner; holder.density = density.density; holder.appliedPulse = recomposeToken }
            CompositionLocalProvider(LocalInlineImageOwner provides owner) {
                Box(Modifier.testTag("delegated-host").background(Color.White)
                    .onGloballyPositioned { holder.origin = it.positionInWindow() }) {
                Layout(modifier = Modifier.verticalScroll(rememberScrollState()), content = {
                    if (enabled) {
                        val blocks = listOf(Block("paragraph", 0, emptyList(), table = table)) +
                            if (opaqueSibling) listOf(Block("paragraph", 0, emptyList(), table = Table(emptyList(),
                                listOf(listOf(Cell(listOf(Span("text", "Opaque sibling")), false, 1, 1)))))) else emptyList()
                        NativeFloatBlockContext(blocks, { actions += it.target }, "delegated-fixture", Modifier,
                            false, "delegated-grid", 0f, false)
                    }
                }) { children, _ ->
                    val child = children.singleOrNull()?.measure(Constraints.fixedWidth(widthPixels))
                    layout(widthPixels + 40, (child?.height ?: 0) + 40) { child?.place(20, 20) }
                }
                }
            }
        } }
    }

    private fun nativeViews(): List<NativeFloatTextView> {
        val result = mutableListOf<NativeFloatTextView>()
        fun visit(view: View) {
            if (view is NativeFloatTextView) result += view
            if (view is android.view.ViewGroup) repeat(view.childCount) { visit(view.getChildAt(it)) }
        }
        visit(checkNotNull(decorView))
        return result
    }

    private fun admittedViews(): List<NativeFloatTextView> = nativeViews().filter {
        it.delegatedCellOwner?.permits(it) == true
    }.sortedBy { it.delegatedCellOwner!!.index }

    private fun point(view: NativeFloatTextView, rect: android.graphics.RectF, holder: Holder): Offset {
        val location = IntArray(2); view.getLocationInWindow(location)
        return Offset(location[0] + rect.centerX() - holder.origin.x,
            location[1] + rect.centerY() - holder.origin.y)
    }

    private fun tap(view: NativeFloatTextView, kind: FloatInteractionKind, holder: Holder, after: Boolean = false) {
        val at = compose.runOnIdle {
            val node = checkNotNull(view.currentMeasuredGeometry).nodes.single { it.kind == kind }
            point(view, if (after) node.bounds.last() else node.bounds.first(), holder)
        }
        compose.onNodeWithTag("delegated-host").performTouchInput { click(at) }
        compose.waitForIdle()
    }

    @Test fun actualTableCellsRetainOriginalPaintInputAccessibilityAndSelectionOwnersAcrossReflow() {
        val width = mutableStateOf(260)
        val source = table()
        val holder = Holder()
        val actions = mutableListOf<String>(); val opened = mutableListOf<String>()
        val bitmap = Bitmap.createBitmap(46, 60, Bitmap.Config.ARGB_8888).apply { eraseColor(android.graphics.Color.BLUE) }
        try {
            compose.activityRule.scenario.onActivity { decorView = it.window.decorView; it.setContent {
                Fixture(source, width.value, bitmap, holder, actions, opened)
            } }
            compose.waitForIdle()
            val originals = compose.runOnIdle { admittedViews().also { assertEquals(2, it.size) } }
            compose.runOnIdle {
                assertEquals(1, holder.created); assertEquals(0, holder.disposed)
                originals.forEachIndexed { index, view ->
                    val g = checkNotNull(view.currentMeasuredGeometry)
                    assertEquals(captions[index], g.text.toString())
                    assertEquals(2, g.nodes.size)
                    val provider = view.accessibilityNodeProvider
                    g.nodes.forEach { node ->
                        val info = checkNotNull(provider.createAccessibilityNodeInfo(node.id))
                        assertTrue(info.isClickable)
                    }
                    assertEquals(190f * holder.density,
                        g.nodes.single { it.kind == FloatInteractionKind.IMAGE }.bounds.first().width(), .01f)
                }
                val counts = originals.map { it.delegatedCellOwner!!.envelopeBuildCount }
                val canvasBitmap = Bitmap.createBitmap(1, 1, Bitmap.Config.ARGB_8888)
                try {
                    val canvas = android.graphics.Canvas(canvasBitmap)
                    repeat(50) {
                        originals.forEach { view ->
                            assertTrue(view.delegatedCellOwner!!.permits(view))
                            view.draw(canvas)
                            checkNotNull(view.currentMeasuredGeometry).nodes.forEach { node ->
                                assertNotNull(view.accessibilityNodeProvider.createAccessibilityNodeInfo(node.id))
                            }
                        }
                    }
                    assertEquals("Repeated paint/input eligibility/AX queries cannot rebuild text envelopes",
                        counts, originals.map { it.delegatedCellOwner!!.envelopeBuildCount })
                } finally { canvasBitmap.recycle() }
            }
            tap(originals[0], FloatInteractionKind.IMAGE, holder, after = true)
            assertEquals(listOf(urls[0]), opened)
            tap(originals[0], FloatInteractionKind.LINK, holder)
            assertEquals(listOf("caption-0"), actions)
            // Actual source paint remains present; the original view still draws the media
            // group and owns focus. No root duplicate renderer is substituted.
            val imagePoint = compose.runOnIdle {
                point(originals[0], checkNotNull(originals[0].currentMeasuredGeometry).nodes
                    .single { it.kind == FloatInteractionKind.IMAGE }.bounds.first(), holder)
            }
            val pixels = compose.onNodeWithTag("delegated-host").captureToImage().toPixelMap()
            assertEquals(Color.Blue, pixels[imagePoint.x.toInt(), imagePoint.y.toInt()])
            val rootOwner = compose.runOnIdle {
                nativeViews().single { it.delegatedCellOwner == null && '\uFFFC' in it.logicalText }.also {
                    it.setSelection(0, it.logicalText.length)
                    assertEquals("\uFFFC", it.selectedTextForCopy())
                }
            }
            val rootSelected = compose.onNodeWithTag("delegated-host").captureToImage().toPixelMap()
            assertNotEquals("Root selection must remain above the relative media phase", Color.Blue,
                rootSelected[imagePoint.x.toInt(), imagePoint.y.toInt()])
            compose.runOnIdle { rootOwner.setSelection(0, 0) }
            compose.runOnIdle {
                val view = originals[0]
                assertTrue(view.requestFocus())
                view.dispatchKeyEvent(KeyEvent(KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_TAB))
                view.dispatchKeyEvent(KeyEvent(KeyEvent.ACTION_UP, KeyEvent.KEYCODE_TAB))
                assertTrue(view.hasFocus())
            }
            val focused = compose.onNodeWithTag("delegated-host").captureToImage().toPixelMap()
            var red = 0
            for (y in 0 until focused.height) for (x in 0 until focused.width) {
                val p = focused[x, y]; if (p.red > .9f && p.green < .1f && p.blue < .1f) red++
            }
            assertTrue("The original native keyboard owner must paint its outline", red > 0)
            compose.runOnIdle {
                originals[0].dispatchKeyEvent(KeyEvent(KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_TAB))
                originals[0].dispatchKeyEvent(KeyEvent(KeyEvent.ACTION_UP, KeyEvent.KEYCODE_TAB))
                originals[0].dispatchKeyEvent(KeyEvent(KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_ENTER))
                assertEquals(listOf("caption-0"), actions)
                width.value = 230
            }
            compose.waitForIdle()
            compose.runOnIdle {
                assertSame(originals[0], admittedViews()[0])
                assertTrue(originals[0].hasFocus())
                originals[0].dispatchKeyEvent(KeyEvent(KeyEvent.ACTION_UP, KeyEvent.KEYCODE_ENTER))
                assertEquals(listOf("caption-0", "caption-0"), actions)
                assertEquals(listOf(urls[0]), opened)
            }
            compose.runOnIdle {
                val view = originals[0]
                val selection = Bundle().apply {
                    putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_START_INT, 0)
                    putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_END_INT, view.logicalText.length)
                }
                assertTrue(view.performAccessibilityAction(AccessibilityNodeInfo.ACTION_SET_SELECTION, selection))
                assertEquals(captions[0], view.selectedTextForCopy())
                assertTrue(view.revealLogicalOffset(0))
                width.value = 260
            }
            compose.waitForIdle()
            compose.runOnIdle {
                val resized = admittedViews(); assertEquals(2, resized.size)
                resized.indices.forEach { assertSame(originals[it], resized[it]) }
                assertEquals(captions[0], resized[0].selectedTextForCopy())
                assertEquals(1, holder.created); assertEquals(0, holder.disposed)
                assertTrue(resized[1].revealLogicalOffset(0))
            }
            compose.waitForIdle()
            tap(originals[1], FloatInteractionKind.LINK, holder)
            assertEquals(listOf("caption-0", "caption-0", "caption-1"), actions)
        } finally {
            compose.activityRule.scenario.onActivity { it.setContent {} }; compose.waitForIdle()
            assertEquals(1, holder.disposed); bitmap.recycle()
        }
    }

    @Test fun realHorizontalAncestorClipsAndScrollsWithoutReassigningTheNativeOwner() {
        val width = mutableStateOf(260)
        val source = table(); val holder = Holder()
        val actions = mutableListOf<String>(); val opened = mutableListOf<String>()
        val bitmap = Bitmap.createBitmap(46, 60, Bitmap.Config.ARGB_8888).apply { eraseColor(android.graphics.Color.BLUE) }
        try {
            compose.activityRule.scenario.onActivity { decorView = it.window.decorView; it.setContent {
                Fixture(source, width.value, bitmap, holder, actions, opened)
            } }
            compose.waitForIdle()
            val originals = compose.runOnIdle { admittedViews().also { assertEquals(2, it.size) } }
            compose.runOnIdle { width.value = 150 }
            compose.waitForIdle()
            val before = compose.runOnIdle {
                assertEquals(originals, admittedViews())
                IntArray(2).also(originals[0]::getLocationInWindow)
            }
            // Swipe through the visible first image, on the actual Compose scroll chain.
            compose.onNodeWithTag("delegated-host").performTouchInput {
                swipe(Offset(20f + 145f * holder.density, 20f + 100f * holder.density),
                    Offset(20f + 35f * holder.density, 20f + 100f * holder.density))
            }
            compose.waitForIdle()
            compose.runOnIdle {
                val after = IntArray(2).also(originals[0]::getLocationInWindow)
                assertTrue("The real table scroll ancestor must consume the horizontal drag", after[0] < before[0])
                assertEquals(originals, admittedViews())
                assertTrue(actions.isEmpty()); assertTrue(opened.isEmpty())
                assertTrue(originals[0].revealLogicalOffset(0))
            }
            compose.waitForIdle()
            compose.runOnIdle { width.value = 260 }
            compose.waitForIdle()
            tap(originals[0], FloatInteractionKind.IMAGE, holder, after = true)
            assertEquals(listOf(urls[0]), opened)
        } finally {
            compose.activityRule.scenario.onActivity { it.setContent {} }; compose.waitForIdle()
            assertEquals(1, holder.disposed); bitmap.recycle()
        }
    }

    @Test fun opaqueSiblingAndDetachedGenerationKeepFallbackBodyAndNeverReviveOldVirtualActions() {
        val opaque = mutableStateOf(false); val enabled = mutableStateOf(true)
        val pulse = mutableStateOf(0)
        val source = table(); val holder = Holder()
        val actions = mutableListOf<String>(); val opened = mutableListOf<String>()
        val bitmap = Bitmap.createBitmap(46, 60, Bitmap.Config.ARGB_8888).apply { eraseColor(android.graphics.Color.BLUE) }
        try {
            compose.activityRule.scenario.onActivity { decorView = it.window.decorView; it.setContent {
                Fixture(source, 260, bitmap, holder, actions, opened, opaque.value, enabled.value, pulse.value)
            } }
            compose.waitForIdle()
            val originals = compose.runOnIdle { admittedViews().also { assertEquals(2, it.size) } }
            val oldNodes = compose.runOnIdle { originals.map { checkNotNull(it.currentMeasuredGeometry).nodes.toList() } }
            compose.runOnIdle {
                originals[0].requestFocus()
                originals[0].dispatchKeyEvent(KeyEvent(KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_TAB))
                originals[0].dispatchKeyEvent(KeyEvent(KeyEvent.ACTION_UP, KeyEvent.KEYCODE_TAB))
                originals[0].dispatchKeyEvent(KeyEvent(KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_TAB))
                originals[0].dispatchKeyEvent(KeyEvent(KeyEvent.ACTION_UP, KeyEvent.KEYCODE_TAB))
                originals[0].dispatchKeyEvent(KeyEvent(KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_ENTER))
                opaque.value = true
            }
            compose.waitForIdle()
            assertTrue(compose.onAllNodesWithText("Unable to display this layout.", substring = true)
                .fetchSemanticsNodes().isNotEmpty())
            captions.forEach { compose.onNodeWithText(it).assertExists() }
            // Ordinary recomposition must not retry a permanently refused geometry.
            repeat(5) { next ->
                compose.runOnIdle { pulse.value = next + 1 }
                compose.waitForIdle()
                compose.runOnIdle {
                    assertEquals(next + 1, holder.appliedPulse)
                    assertTrue(admittedViews().isEmpty())
                    assertEquals(1, holder.created); assertEquals(0, holder.disposed)
                }
                captions.forEach { compose.onNodeWithText(it).assertExists() }
            }
            compose.runOnIdle {
                originals[0].dispatchKeyEvent(KeyEvent(KeyEvent.ACTION_UP, KeyEvent.KEYCODE_ENTER))
                assertTrue(admittedViews().isEmpty())
                originals.forEachIndexed { index, view -> oldNodes[index].forEach { node ->
                    assertNull(view.accessibilityNodeProvider.createAccessibilityNodeInfo(node.id))
                    assertFalse(view.accessibilityNodeProvider.performAction(node.id, AccessibilityNodeInfo.ACTION_CLICK, null))
                } }
                assertTrue(actions.isEmpty()); assertTrue(opened.isEmpty())
                opaque.value = false
            }
            compose.waitForIdle()
            val restored = compose.runOnIdle { admittedViews().also { assertEquals(2, it.size) } }
            tap(restored[0], FloatInteractionKind.LINK, holder)
            assertEquals(listOf("caption-0"), actions)
            compose.runOnIdle { enabled.value = false }
            compose.waitForIdle()
            compose.runOnIdle {
                assertTrue(admittedViews().isEmpty())
                restored.forEach { view ->
                    assertFalse(view.isAttachedToWindow)
                    assertFalse(view.revealLogicalOffset(0))
                }
                assertEquals(1, holder.created); assertEquals(0, holder.disposed)
            }
        } finally {
            compose.activityRule.scenario.onActivity { it.setContent {} }; compose.waitForIdle()
            assertEquals(1, holder.disposed); bitmap.recycle()
        }
    }

    @Test fun readyLoadingReadyKeepsOneResourceOwnerAndCancelsTheHeldNativeSequence() {
        val source = table(); val holder = Holder()
        val actions = mutableListOf<String>(); val opened = mutableListOf<String>()
        val bitmap = Bitmap.createBitmap(46, 60, Bitmap.Config.ARGB_8888).apply { eraseColor(android.graphics.Color.BLUE) }
        try {
            compose.activityRule.scenario.onActivity { decorView = it.window.decorView; it.setContent {
                Fixture(source, 260, bitmap, holder, actions, opened)
            } }
            compose.waitForIdle()
            val originals = compose.runOnIdle { admittedViews().also { assertEquals(2, it.size) } }
            val resource = checkNotNull(holder.owner)
            val ready = compose.runOnIdle { checkNotNull(resource.states[images[0].file]) }
            val downAt = compose.runOnIdle {
                point(originals[0], checkNotNull(originals[0].currentMeasuredGeometry).nodes
                    .single { it.kind == FloatInteractionKind.IMAGE }.bounds.first(), holder)
            }
            compose.onNodeWithTag("delegated-host").performTouchInput { down(downAt) }
            compose.runOnIdle { resource.states[images[0].file] = InlineImageAssetState.Loading }
            compose.waitForIdle()
            // GestureDetector uses the real Android clock, independently of Compose's clock.
            Thread.sleep(android.view.ViewConfiguration.getLongPressTimeout().toLong() + 120L)
            compose.runOnIdle {
                assertSame(resource, holder.owner)
                assertEquals(1, holder.created); assertEquals(0, holder.disposed)
                assertTrue(actions.isEmpty()); assertTrue(opened.isEmpty())
                resource.states[images[0].file] = ready
            }
            compose.waitForIdle()
            compose.onNodeWithTag("delegated-host").performTouchInput { up() }
            compose.waitForIdle()
            val current = compose.runOnIdle {
                assertTrue(actions.isEmpty()); assertTrue(opened.isEmpty())
                assertSame(resource, holder.owner)
                admittedViews().also { views ->
                    assertEquals(2, views.size)
                    views.forEachIndexed { index, view -> assertEquals(captions[index], view.logicalText.toString()) }
                }
            }
            tap(current[0], FloatInteractionKind.IMAGE, holder, after = true)
            assertEquals(listOf(urls[0]), opened)
        } finally {
            compose.activityRule.scenario.onActivity { it.setContent {} }; compose.waitForIdle()
            assertEquals(1, holder.disposed); bitmap.recycle()
        }
    }
}
