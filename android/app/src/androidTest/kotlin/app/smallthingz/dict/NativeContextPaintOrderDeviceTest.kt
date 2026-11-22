package app.smallthingz.dict

import android.graphics.Paint
import android.graphics.RectF
import android.text.SpannableString
import android.text.Spanned
import android.text.TextPaint
import androidx.activity.compose.setContent
import androidx.compose.foundation.background
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.toPixelMap
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.layout.Layout
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalLayoutDirection
import androidx.compose.ui.platform.LocalWindowInfo
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

@RunWith(AndroidJUnit4::class)
class NativeContextPaintOrderDeviceTest {
    @get:Rule val compose = createPhysicalComposeRule()

    @Test fun coincidentTextAndRichFlowFollowSourcePaintAndHitOrderWithoutReplacingTheRichChild() {
        val flowLast = mutableStateOf(true)
        val actions = mutableListOf<String>()
        var flowGeometry: NativeAnonymousFlowGeometry? = null
        var created = 0
        var disposed = 0
        var owner: Any? = null
        var logicalWidth = -1
        var logicalHeight = -1
        val origin = Offset(112f, 88f)
        val fractionalLeft = .375f
        val box = ParagraphBox(ParagraphEdges(left = fractionalLeft), ParagraphEdges(), 0f, 0f)
        fun source(paint: TextPaint) = SpannableString("W").apply {
            setSpan(NativeRunLineMetrics(NativePrimaryFontMetrics.from(paint),
                NativeLineHeightPolicy.Pixels(0f), strut = true), 0, 1, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        }
        try {
            compose.activityRule.scenario.onActivity { activity -> activity.setContent {
                MaterialTheme {
                    CompositionLocalProvider(LocalDensity provides Density(1f, 1f)) {
                        val red = TextPaint(Paint.ANTI_ALIAS_FLAG).apply { textSize = 40f; color = android.graphics.Color.RED }
                        val blue = TextPaint(red).apply { color = android.graphics.Color.BLUE }
                        val text = NativeFloatContextSpec.Text(PreparedNativeFloatText("W", null, Any(),
                            geometry = { width, carried, _ -> NativeFloatGeometry.build(source(red), red, width, emptyList(),
                                carriedExclusions = carried, nodeFactory = { geometry -> listOf(FloatInteractionNode(
                                    0, FloatInteractionKind.LINK, 0, 1, geometry.rectsForRange(0, 1), "Text", null,
                                     { actions += "text" })) }) }, menu = {}, fallback = { error("Text must remain supported") }), 0f, box = box)
                        val content = anonymousFlowContent(Block("paragraph", 0, listOf(Span("text", "W"))),
                            AnonymousFlowContext(BidiResolvedDirection.Ltr, null, null))
                        val flow = NativeFloatContextSpec.Flow(1, 0f, null, box, false) { carried, sink ->
                            val stable = remember { Any() }
                            DisposableEffect(stable) { created++; onDispose { disposed++ } }
                            SideEffect { owner = stable }
                            val input = checkNotNull(LocalNativeFlowMeasureInput.current)
                            val density = LocalDensity.current
                            val environment = NativeFlowEnvironment(density.density, density.fontScale,
                                LocalLayoutDirection.current, LocalWindowInfo.current.containerSize)
                            val binding = NativeFlowBinding(environment, NativeTextInsets(), 0f)
                            SideEffect { input.bind(binding) }
                            DisposableEffect(input, binding) { onDispose { input.unbind(binding) } }
                            AnonymousFlowLayout(content, blue, input.measurement.modifier, Color.Magenta,
                                inline = { _, _ -> source(blue) },
                                figureSpec = { _, _ -> error("No Figure") },
                                inlineNodes = { geometry -> listOf(FloatInteractionNode(0, FloatInteractionKind.LINK,
                                    0, 1, geometry.rectsForRange(0, 1), "Flow", null, { actions += "flow" })) },
                                semanticGeometry = { _, _, _ -> error("No Figure") },
                                interactionOwner = false, carriedExclusions = carried,
                                onFlowGeometry = { flowGeometry = it; sink(it) }, measureInput = input,
                                preparedBinding = binding) { _ -> error("No Figure child") }
                        }
                        Layout(modifier = Modifier.testTag("order-root").background(Color.White), content = {
                            NativeFloatContextLayout(if (flowLast.value) listOf(text, flow) else listOf(flow, text),
                                Modifier, Color.Magenta) { _, _ -> error("No delegated atomic child") }
                        }) { measurables, constraints ->
                            val child = measurables.single().measure(Constraints(maxWidth = 0, maxHeight = 200))
                            logicalWidth = child.width; logicalHeight = child.height
                            layout(constraints.constrainWidth(288), constraints.constrainHeight(192)) {
                                child.place(origin.x.toInt(), origin.y.toInt())
                            }
                        }
                    }
                }
            } }
            compose.waitForIdle()
            val stable = owner
            fun nativeView(): NativeFloatTextView {
                var found: NativeFloatTextView? = null
                compose.activityRule.scenario.onActivity { activity ->
                    fun visit(view: android.view.View) {
                        if (view is NativeFloatTextView) { check(found == null); found = view }
                        if (view is android.view.ViewGroup) for (index in 0 until view.childCount) visit(view.getChildAt(index))
                    }
                    visit(activity.window.decorView)
                }
                return checkNotNull(found)
            }
            fun verify(expected: String) {
                val viewport = compose.onNodeWithTag("order-root")
                fun state() = "used=${logicalWidth}x${logicalHeight}; geometry=${flowGeometry?.width}x${flowGeometry?.height}; " +
                    "nodes=${flowGeometry?.nodes?.map { it.bounds }}; created=$created; disposed=$disposed; actions=$actions"
                val beforeCapture = compose.runOnIdle { state() }
                val captured = viewport.captureToImage()
                val afterCapture = compose.runOnIdle { state() }
                val imageName = "native-source-order-$expected.png"
                val report = renderedLayoutFailureEvidence(imageName, null, null, viewport,
                    imageName, captured.asAndroidBitmap()) + "\nbeforeCapture=$beforeCapture\nafterCapture=$afterCapture"
                check(report.toByteArray(Charsets.UTF_8).size <= 128 * 1024)
                InstrumentationRegistry.getInstrumentation().sendStatus(0, android.os.Bundle().apply {
                    putString(android.app.Instrumentation.REPORT_KEY_STREAMRESULT, "\n$report\n")
                })
                check("OWNED_PNG_BEGIN $imageName " in report) { "Native foundation frame was not retained: $report" }
                lateinit var bounds: RectF
                compose.runOnIdle {
                    assertEquals(0, logicalWidth); assertEquals(0, logicalHeight)
                    bounds = RectF(checkNotNull(flowGeometry).nodes.single().bounds.single()).apply {
                        offset(origin.x + fractionalLeft, origin.y)
                    }
                    assertEquals(1, created); assertEquals(0, disposed); assertSame(stable, owner)
                }
                val pixels = captured.toPixelMap()
                var red = 0
                var blue = 0
                for (y in 32 until 136) for (x in 80 until 184) {
                    val color = pixels[x, y]
                    if (color.red > .95f && color.green < .05f && color.blue < .05f) red++
                    if (color.blue > .95f && color.green < .05f && color.red < .05f) blue++
                }
                if (expected == "flow") { assertTrue(blue > 20); assertEquals(0, red) }
                else { assertTrue(red > 20); assertEquals(0, blue) }
                val view = nativeView()
                compose.runOnIdle {
                    val info = checkNotNull(view.accessibilityNodeProvider.findAccessibilityNodeInfosByText("Flow", android.view.View.NO_ID)).single()
                    val virtual = android.graphics.Rect(); info.getBoundsInParent(virtual)
                    assertTrue(info.isVisibleToUser)
                    assertEquals(kotlin.math.ceil(bounds.right).toInt() - kotlin.math.floor(bounds.left).toInt(), virtual.width())
                    assertEquals(kotlin.math.ceil(bounds.bottom).toInt() - kotlin.math.floor(bounds.top).toInt(), virtual.height())
                }
                compose.onNodeWithTag("order-root").performTouchInput {
                    click(Offset(bounds.centerX(), bounds.centerY()))
                }
                compose.waitForIdle()
                compose.runOnIdle { assertEquals(expected, actions.last()) }
            }
            verify("flow")
            compose.runOnIdle { flowLast.value = false }
            compose.waitForIdle()
            verify("text")
            assertEquals(listOf("flow", "text"), actions)
        } finally { compose.activityRule.scenario.onActivity { it.setContent {} } }
        compose.waitForIdle()
        assertEquals(1, created); assertEquals(1, disposed)
    }
}
