package app.smallthingz.dict

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Paint
import android.os.SystemClock
import android.text.TextPaint
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.view.accessibility.AccessibilityNodeInfo
import androidx.activity.compose.setContent
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.width
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Typography
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.toPixelMap
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.assert
import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.captureToImage
import androidx.compose.ui.test.click
import androidx.compose.ui.test.hasAnyAncestor
import androidx.compose.ui.test.hasClickAction
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performSemanticsAction
import androidx.compose.ui.test.performTouchInput
import androidx.compose.ui.text.LinkAnnotation
import androidx.compose.ui.text.TextLayoutResult
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.test.ext.junit.runners.AndroidJUnit4
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/** Real platform shaping contrasts; no system clipboard or external media is used. */
@RunWith(AndroidJUnit4::class)
class FontFeaturePolicyDeviceTest {
    @get:Rule val compose = createPhysicalComposeRule()
    private val disabled = "'liga' 0, 'clig' 0, 'kern' 0, 'dlig' 1, 'ss01' 1"

    @Test fun composeExplicitFeatureReplacementReachesShapingAfterTrackingAndRetainsLinkOwner() {
        val policy = mutableStateOf<FontFeaturePolicy?>(null)
        val actions = mutableListOf<EntryLink>()
        var density: Density? = null
        val images = mutableListOf<List<Color>>()
        val advances = mutableListOf<Pair<Float, Float>>()
        try {
            compose.activityRule.scenario.onActivity { activity -> activity.setContent {
                MaterialTheme {
                    density = LocalDensity.current
                    StyledText(listOf(Span("link", "office", "Feature target", fontFeatures = policy.value)),
                        Modifier.width(300.dp).background(Color.White),
                        style = TextStyle(fontFamily = Editorial, fontSize = 40.sp, color = Color.Black,
                            letterSpacing = 2.sp, fontFeatureSettings = disabled), onLink = { actions += it })
                }
            } }
            val states = listOf(null, FontFeaturePolicy.SevenOn, FontFeaturePolicy.Normal, null)
            states.forEachIndexed { index, selected ->
                compose.runOnIdle { policy.value = selected }; compose.waitForIdle()
                val node = compose.onNodeWithText("office", useUnmergedTree = true).assertIsDisplayed()
                val layouts = mutableListOf<TextLayoutResult>()
                node.performSemanticsAction(SemanticsActions.GetTextLayoutResult) { it(layouts) }
                val actual = layouts.single()
                assertFalse(actual.hasVisualOverflow)
                val annotated = actual.layoutInput.text
                val link = annotated.getLinkAnnotations(0, annotated.length).single()
                assertEquals("Feature target", (link.item as LinkAnnotation.Clickable).tag)
                val effective = annotated.spanStyles.filter { it.start == 0 && it.end == 6 }
                    .fold(actual.layoutInput.style.toSpanStyle()) { value, range -> value.merge(range.item) }
                val settings = selected?.nativeSettings ?: disabled
                assertEquals(settings, effective.fontFeatureSettings)
                assertEquals(2.sp, effective.letterSpacing)
                var expectedWidth = 0f
                compose.activityRule.scenario.onActivity { activity ->
                    val d = checkNotNull(density)
                    val paint = TextPaint(Paint.ANTI_ALIAS_FLAG).apply {
                        typeface = activity.resources.getFont(R.font.newsreader)
                        textSize = with(d) { 40.sp.toPx() }
                        letterSpacing = with(d) { 2.sp.toPx() } / textSize
                        fontFeatureSettings = settings
                    }
                    expectedWidth = paint.measureText("office")
                }
                advances += expectedWidth to (actual.getLineRight(0) - actual.getLineLeft(0))
                val pixels = node.captureToImage().toPixelMap()
                images.add(buildList<Color> { for (y in 0 until pixels.height) for (x in 0 until pixels.width) add(pixels[x,y]) })
                val links = compose.onAllNodes(hasClickAction() and hasAnyAncestor(hasText("office")), useUnmergedTree = true)
                links.assertCountEquals(1)
                node.performTouchInput { click(actual.getBoundingBox(1).center) }
                compose.runOnIdle { assertEquals(List(index + 1) { EntryLink("Feature target") }, actions) }
            }
            // Paragraph edge tracking differs from Paint.measureText; the fixed edge contribution
            // cancels when comparing feature changes on the same text, size and tracking.
            advances.drop(1).forEach { (expected, actual) ->
                assertEquals(expected - advances.first().first, actual - advances.first().second, 2f)
            }
            assertNotEquals("The bundled Newsreader liga contrast must reach actual Compose paint", images[0], images[1])
            assertEquals("Null restores the original explicit parent list", images[0], images[3])
        } finally {
            compose.activityRule.scenario.onActivity { it.setContent {} }; compose.waitForIdle()
        }
    }

    private fun px(n: Float) = StyleLength(StyleLengthUnit.Px, n)
    private val edges = FigureBorderEdges(FigureBorderEdge.None, FigureBorderEdge.None, FigureBorderEdge.None, FigureBorderEdge.None)
    private data class Scene(val strut: FontFeaturePolicy?, val span: FontFeaturePolicy?)
    private fun figure(scene: Scene): Figure {
        val zero = StyleEdges(px(0f), px(0f), px(0f), px(0f))
        return Figure(FigureContent.Missing(Span("link", "office", "Missing target", fontFeatures = scene.span), px(220f), px(45f)),
            FigureFormat.Framed, FigurePlacement.None, FigureClear.None, zero, zero, zero,
            1f, px(45f), FigureColor.Transparent, FigureBorder.None, FigureColor.Transparent, FigureBorder.None,
            FigureColor.NativeTheme, FigureColor.Transparent,
            caption = listOf(Span("link", "office", "Caption target", fontFeatures = FontFeaturePolicy.SevenOn)),
            tableCaptionLayout = TableCaptionLayout(TableCollapse.Collapse, ContainerStyle(), edges, edges,
                FigureMediaLayout(FigureMediaStrut(1f, direction = BidiResolvedDirection.Ltr,
                    fontFeatures = scene.strut), InlineBoxVerticalAlign.Baseline)))
    }
    private fun view(): NativeFloatTextView {
        val found = mutableListOf<NativeFloatTextView>()
        compose.activityRule.scenario.onActivity { activity ->
            fun visit(v: View) {
                if (v is NativeFloatTextView) found += v
                if (v is ViewGroup) repeat(v.childCount) { visit(v.getChildAt(it)) }
            }
            visit(activity.window.decorView)
        }
        return found.single()
    }
    private fun pixels(view: NativeFloatTextView, bounds: android.graphics.RectF): List<Int> {
        val bitmap = Bitmap.createBitmap(view.width, view.height, Bitmap.Config.ARGB_8888)
        try {
            bitmap.eraseColor(android.graphics.Color.WHITE); view.draw(Canvas(bitmap))
            val left = bounds.left.toInt().coerceAtLeast(0); val top = bounds.top.toInt().coerceAtLeast(0)
            val right = kotlin.math.ceil(bounds.right).toInt().coerceAtMost(bitmap.width)
            val bottom = kotlin.math.ceil(bounds.bottom).toInt().coerceAtMost(bitmap.height)
            assertTrue(right > left && bottom > top)
            return buildList { for (y in top until bottom) for (x in left until right) add(bitmap.getPixel(x,y)) }
        } finally { bitmap.recycle() }
    }
    private fun tap(view: NativeFloatTextView, node: FloatInteractionNode) {
        val rect = node.bounds.first { !it.isEmpty }; val now = SystemClock.uptimeMillis()
        for (action in listOf(MotionEvent.ACTION_DOWN, MotionEvent.ACTION_UP)) {
            val event = MotionEvent.obtain(now, SystemClock.uptimeMillis(), action, rect.centerX(), rect.centerY(), 0)
            try { assertTrue(view.dispatchTouchEvent(event)) } finally { event.recycle() }
        }
    }

    @Test fun nativeMissingStrutAndCaptionShapeOneOwnerWithExplicitResetAcrossRebind() {
        val states = listOf(Scene(null,null), Scene(FontFeaturePolicy.SevenOn,null),
            Scene(FontFeaturePolicy.Normal,null), Scene(FontFeaturePolicy.SevenOn,FontFeaturePolicy.Normal), Scene(null,null))
        val scene = mutableStateOf(states.first())
        val actions = mutableListOf<EntryLink>()
        val images = mutableListOf<List<Int>>()
        var geometry: FloatTextGeometry? = null
        try {
            compose.activityRule.scenario.onActivity { activity -> activity.setContent {
                MaterialTheme(typography = Typography(bodyLarge = TextStyle(fontFamily = Editorial, fontSize = 24.sp,
                    fontFeatureSettings = disabled, color = Color.Black))) {
                    AnonymousBlockView(Block("paragraph",0,emptyList(),figure=figure(scene.value)), Modifier,
                        { actions += it }, emptyList(), AppSettings(allowImages=false,allowAudio=false), "en", onGeometry={geometry=it})
                }
            } }
            compose.waitForIdle(); val originalView = view()
            states.forEachIndexed { index, selected ->
                compose.runOnIdle { scene.value = selected }; compose.waitForIdle(); assertSame(originalView, view())
                compose.runOnIdle {
                    val g = checkNotNull(geometry)
                    val nodes = g.nodes.filter { it.label.toString() == "office" }
                    assertEquals(2, nodes.size)
                    val missing = nodes.first(); val caption = nodes.last()
                    assertEquals(2, checkNotNull(originalView.accessibilityNodeProvider.createAccessibilityNodeInfo(View.NO_ID)).childCount)
                    nodes.forEach { node ->
                        val ax = checkNotNull(originalView.accessibilityNodeProvider.createAccessibilityNodeInfo(node.id))
                        assertTrue(ax.isClickable); assertEquals("office", (ax.text ?: ax.contentDescription).toString())
                    }
                    originalView.setSelection(caption.start,caption.end)
                    assertEquals("office", originalView.selectedTextForCopy())
                    originalView.dispatchKeyEvent(KeyEvent(KeyEvent.ACTION_DOWN,KeyEvent.KEYCODE_ESCAPE))
                    images += pixels(originalView, missing.bounds.first())
                    assertTrue(pixels(originalView, caption.bounds.first()).any { it != android.graphics.Color.WHITE })
                    tap(originalView,missing); tap(originalView,caption)
                    assertEquals(List(index + 1) { listOf(EntryLink("Missing target"),EntryLink("Caption target")) }.flatten(), actions)
                }
            }
            assertNotEquals("Missing label must use the source strut's explicit features",images[0],images[1])
            assertEquals("An explicit span normal resets the inherited seven-on strut",images[2],images[3])
            assertEquals("Removing source policy restores legacy parent features",images[0],images[4])
        } finally { compose.activityRule.scenario.onActivity { it.setContent {} }; compose.waitForIdle() }
    }

    @Test
    fun unsupportedExplicitEgyptianFeaturesKeepOriginalTextAndActionWithVisibleRefusal() {
        val policy = mutableStateOf(FontFeaturePolicy.SevenOn)
        val actions = mutableListOf<EntryLink>()
        try {
            compose.activityRule.scenario.onActivity { activity -> activity.setContent {
                MaterialTheme {
                    StyledText(listOf(Span("link","\uD80C\uDC00","Glyph target",classes="Egyp",fontFeatures=policy.value)),
                        onLink={actions+=it})
                }
            } }
            for (value in FontFeaturePolicy.entries) {
                compose.runOnIdle { policy.value=value }; compose.waitForIdle()
                val node = compose.onNodeWithText("\uD80C\uDC00", substring=true, useUnmergedTree=true).assertIsDisplayed()
                node.assert(SemanticsMatcher.expectValue(SemanticsProperties.StateDescription, "Egyptian glyph layout unavailable"))
                node.assert(SemanticsMatcher.expectValue(EgyptianShapedRunCount, 0))
                val layouts = mutableListOf<TextLayoutResult>()
                node.performSemanticsAction(SemanticsActions.GetTextLayoutResult) { it(layouts) }
                val layout = layouts.single()
                val link = layout.layoutInput.text.getLinkAnnotations(0,layout.layoutInput.text.length).single()
                assertEquals("Glyph target", (link.item as LinkAnnotation.Clickable).tag)
                val pixels = node.captureToImage().toPixelMap()
                assertTrue((0 until pixels.height).any { y -> (0 until pixels.width).any { x ->
                    val c = pixels[x,y]; c.alpha > .5f && minOf(c.red,c.green,c.blue) < .7f
                } })
                node.performTouchInput { click(checkNotNull(layout.placeholderRects.single()).center) }
                compose.runOnIdle { assertEquals(value.ordinal + 1, actions.size); assertEquals(EntryLink("Glyph target"),actions.last()) }
                compose.activityRule.scenario.onActivity { activity ->
                    val native = runBlocking { prepareNativeEgyptianSpan(activity, EgyptianTextRun(0,2,"\uD80C\uDC00",true,fontFeatures=value),
                        TextPaint(Paint.ANTI_ALIAS_FLAG).apply { textSize=32f },0f,false,false,android.graphics.Color.BLACK,null) }
                    assertFalse(native.available)
                    assertEquals("Explicit font features are unavailable for Egyptian glyph layout", checkNotNull(native.error).message)
                }
            }
        } finally { compose.activityRule.scenario.onActivity { it.setContent {} }; compose.waitForIdle() }
    }
}
