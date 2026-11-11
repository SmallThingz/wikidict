package app.smallthingz.dict

import android.graphics.Paint
import android.graphics.Rect
import android.graphics.RectF
import android.text.SpannableString
import android.text.Spanned
import android.text.TextPaint
import android.view.View
import android.view.ViewGroup
import androidx.activity.compose.setContent
import androidx.compose.foundation.background
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.toPixelMap
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.layout.Layout
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.captureToImage
import androidx.compose.ui.test.click
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performTouchInput
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.constrainHeight
import androidx.compose.ui.unit.constrainWidth
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/** Real Compose hit traversal and native virtual children; no direct View event injection. */
@RunWith(AndroidJUnit4::class)
class NativeAncestorSurfaceDeviceTest {
    @get:Rule val compose = createPhysicalComposeRule()

    @Test fun zeroUsedAncestorKeepsOverflowPixelsTouchAndVirtualBoundsOnTheSameChild() {
        val revision = mutableStateOf(false)
        val actions = mutableListOf<String>()
        var prepared: FloatTextGeometry? = null
        var created = 0
        var disposed = 0
        var logicalWidth = -1
        var logicalHeight = -1
        var originalView: NativeFloatTextView? = null
        val origin = Offset(128f, 96f)
        try {
            compose.activityRule.scenario.onActivity { activity -> activity.setContent {
                MaterialTheme {
                    CompositionLocalProvider(LocalDensity provides Density(1f, 1f)) {
                        val text = if (revision.value) "M" else "W"
                        val action = if (revision.value) "new" else "old"
                        val owner = remember { Any() }
                        DisposableEffect(owner) { created++; onDispose { disposed++ } }
                        val paint = TextPaint(Paint.ANTI_ALIAS_FLAG).apply { textSize = 40f; color = android.graphics.Color.BLACK }
                        val block = Block("paragraph", 0, listOf(Span("text", text)))
                        val content = anonymousFlowContent(block, AnonymousFlowContext(BidiResolvedDirection.Ltr, null, null))
                        Layout(modifier = Modifier.testTag("overflow-root").background(Color.White), content = {
                            // Two plain used-size ancestors deliberately occupy no area.
                            Layout(content = {
                                AnonymousFlowLayout(content, paint, Modifier, Color.Blue,
                                    inline = { _, _ -> SpannableString(text).apply {
                                        setSpan(NativeRunLineMetrics(NativePrimaryFontMetrics.from(paint),
                                            NativeLineHeightPolicy.Pixels(0f), strut = true), 0, length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
                                    } }, figureSpec = { _, _ -> error("No figure owner in this control") },
                                    inlineNodes = { geometry -> listOf(FloatInteractionNode(0, FloatInteractionKind.LINK,
                                        0, text.length, geometry.rectsForRange(0, text.length), text, null, { actions += action })) },
                                    semanticGeometry = { _, _, _ -> error("No figure measurement") },
                                    onGeometry = { prepared = it }) { _, _ -> error("No figure child") }
                            }) { measurables, _ ->
                                val child = measurables.single().measure(Constraints(maxWidth = 0, maxHeight = 200))
                                logicalWidth = child.width; logicalHeight = child.height
                                layout(0, 0) { child.place(0, 0) }
                            }
                        }) { measurables, constraints ->
                            val child = measurables.single().measure(Constraints(maxWidth = 0, maxHeight = 200))
                            layout(constraints.constrainWidth(320), constraints.constrainHeight(240)) {
                                child.place(origin.x.toInt(), origin.y.toInt())
                            }
                        }
                    }
                }
            } }
            compose.waitForIdle()
            fun nativeView(): NativeFloatTextView {
                var found: NativeFloatTextView? = null
                compose.activityRule.scenario.onActivity { activity ->
                    fun visit(view: View) {
                        if (view is NativeFloatTextView) { check(found == null); found = view }
                        if (view is ViewGroup) for (index in 0 until view.childCount) visit(view.getChildAt(index))
                    }
                    visit(activity.window.decorView)
                }
                return checkNotNull(found)
            }
            fun verifyAndClick(expected: String) {
                val viewport = compose.onNodeWithTag("overflow-root")
                fun state() = "used=${logicalWidth}x${logicalHeight}; geometry=${prepared?.width}x${prepared?.height}; " +
                    "nodes=${prepared?.nodes?.map { it.bounds }}; created=$created; disposed=$disposed; actions=$actions"
                val beforeCapture = compose.runOnIdle { state() }
                val captured = viewport.captureToImage()
                val afterCapture = compose.runOnIdle { state() }
                val imageName = "native-zero-ancestor-$expected.png"
                val report = renderedLayoutFailureEvidence(imageName, null, null, viewport,
                    imageName, captured.asAndroidBitmap()) + "\nbeforeCapture=$beforeCapture\nafterCapture=$afterCapture"
                check(report.toByteArray(Charsets.UTF_8).size <= 128 * 1024)
                InstrumentationRegistry.getInstrumentation().sendStatus(0, android.os.Bundle().apply {
                    putString(android.app.Instrumentation.REPORT_KEY_STREAMRESULT, "\n$report\n")
                })
                check("OWNED_PNG_BEGIN $imageName " in report) { "Native foundation frame was not retained: $report" }
                lateinit var hit: RectF
                compose.runOnIdle {
                    assertEquals(0, logicalWidth); assertEquals(0, logicalHeight)
                    val geometry = checkNotNull(prepared)
                    assertEquals(0, geometry.width); assertEquals(0, geometry.height)
                    hit = RectF(geometry.nodes.single().bounds.single()).apply { offset(origin.x, origin.y) }
                    assertTrue(hit.top < origin.y && hit.width() > 0f && hit.height() > 0f)
                }
                val pixels = captured.toPixelMap()
                var ink = 0
                for (y in (origin.y - 48).toInt() until (origin.y + 48).toInt())
                    for (x in (origin.x - 16).toInt() until (origin.x + 64).toInt())
                        if (pixels[x, y].red < .2f && pixels[x, y].green < .2f && pixels[x, y].blue < .2f) ink++
                assertTrue("Native glyphs must survive the zero-size ancestors", ink > 20)
                compose.onNodeWithTag("overflow-root").performTouchInput { click(Offset(hit.centerX(), hit.centerY())) }
                compose.waitForIdle()
                compose.runOnIdle { assertEquals(expected, actions.last()); assertEquals(1, created); assertEquals(0, disposed) }
                val view = nativeView()
                compose.runOnIdle {
                    val info = checkNotNull(view.accessibilityNodeProvider.createAccessibilityNodeInfo(0))
                    val bounds = Rect(); info.getBoundsInScreen(bounds)
                    assertTrue(info.isVisibleToUser); assertTrue(bounds.width() > 0 && bounds.height() > 0)
                    assertEquals(checkNotNull(prepared).text.toString(), info.text.toString())
                }
            }
            originalView = nativeView()
            verifyAndClick("old")
            compose.runOnIdle { revision.value = true }
            compose.waitForIdle()
            assertSame(originalView, nativeView())
            verifyAndClick("new")
            assertEquals(listOf("old", "new"), actions)
        } finally { compose.activityRule.scenario.onActivity { it.setContent {} } }
        compose.waitForIdle()
        assertEquals(1, created); assertEquals(1, disposed)
    }
}
