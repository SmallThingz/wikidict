package app.smallthingz.dict

import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.width
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.layout.IntrinsicMeasurable
import androidx.compose.ui.layout.IntrinsicMeasureScope
import androidx.compose.ui.layout.Layout
import androidx.compose.ui.layout.Measurable
import androidx.compose.ui.layout.MeasurePolicy
import androidx.compose.ui.layout.MeasureResult
import androidx.compose.ui.layout.MeasureScope
import androidx.compose.ui.layout.boundsInRoot
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertTextEquals
import androidx.compose.ui.test.click
import androidx.compose.ui.test.hasAnyAncestor
import androidx.compose.ui.test.hasClickAction
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performSemanticsAction
import androidx.compose.ui.test.performTouchInput
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/** The native refusal must leave the one real Compose fallback measured and interactive. */
@RunWith(AndroidJUnit4::class)
class NativeFallbackMeasurementDeviceTest {
    @get:Rule val compose = createPhysicalComposeRule()

    private fun retainedLinkText(tag: String, label: String, target: String):
        Pair<androidx.compose.ui.test.SemanticsNodeInteraction, androidx.compose.ui.geometry.Offset> {
        // StyledText tags its SelectionContainer. Inspect its one actual Text/link child.
        compose.onAllNodesWithTag(tag).assertCountEquals(1)
        val scopedText = hasText(label) and hasAnyAncestor(hasTestTag(tag))
        compose.onAllNodes(scopedText, useUnmergedTree = true).assertCountEquals(1)
        val text = compose.onNode(scopedText, useUnmergedTree = true).assertIsDisplayed().assertTextEquals(label)
        val layouts = mutableListOf<androidx.compose.ui.text.TextLayoutResult>()
        text.performSemanticsAction(androidx.compose.ui.semantics.SemanticsActions.GetTextLayoutResult) { it(layouts) }
        val layout = layouts.single()
        assertEquals(label, layout.layoutInput.text.text)
        val link = layout.layoutInput.text.getLinkAnnotations(0, label.length).single()
        assertEquals(0, link.start)
        assertEquals(label.length, link.end)
        assertEquals(target, (link.item as androidx.compose.ui.text.LinkAnnotation.Clickable).tag)
        val clickable = compose.onAllNodes(hasClickAction() and hasAnyAncestor(scopedText), useUnmergedTree = true)
        clickable.assertCountEquals(1)
        clickable[0].assertIsDisplayed()
        val textBounds = text.fetchSemanticsNode().boundsInRoot
        val linkBounds = clickable[0].fetchSemanticsNode().boundsInRoot
        assertFalse(textBounds.isEmpty)
        assertFalse(linkBounds.isEmpty)
        val glyph = layout.getBoundingBox(link.start + 1).center
        assertTrue(linkBounds.contains(textBounds.topLeft + glyph))
        return text to glyph
    }

    @Test fun unboundFlowKeepsItsRealFallbackAndRejectsPriorGeometryUntilRebound() {
        val native = mutableStateOf(true)
        val width = mutableStateOf(260)
        val actions = mutableListOf<EntryLink>()
        val failures = mutableListOf<String>()
        var input: NativeFlowMeasureInput? = null
        var owner: Any? = null
        var created = 0
        var disposed = 0
        var fallbackBounds = Rect.Zero
        var tailBounds = Rect.Zero
        val link = Span("link", "Retained flow link", "fallback-target")
        val block = Block("paragraph", 0, emptyList(), flow = listOf(FlowPart.Inline(listOf(link))))
        try {
            compose.activityRule.scenario.onActivity { activity -> activity.setContent {
                MaterialTheme {
                    CompositionLocalProvider(LocalDensity provides Density(1f, 1f),
                        LocalNativeFloatContextFailureObserver provides { failures += it }) {
                        NativeFloatContextLayout(listOf(
                            NativeFloatContextSpec.Flow(1, 0f, null, null, false) { carried, sink ->
                                val stable = remember { Any() }
                                val current = checkNotNull(LocalNativeFlowMeasureInput.current)
                                DisposableEffect(stable) { created++; onDispose { disposed++ } }
                                SideEffect { input = current; owner = stable }
                                if (native.value) {
                                    AnonymousBlockView(block, Modifier, { actions += it }, emptyList(),
                                        AppSettings(allowImages = false, allowAudio = false), "",
                                        interactionOwner = false, carriedExclusions = carried, onFlowGeometry = sink)
                                } else {
                                    // Like FigureAdapter's delegated refusal, this is real content
                                    // which deliberately supplies no native preparation or publication.
                                    Column(Modifier.onGloballyPositioned { fallbackBounds = it.boundsInRoot() }) {
                                        StyledText(listOf(link), Modifier.testTag("retained-flow-link").height(24.dp),
                                            style = TextStyle(fontSize = 16.sp, lineHeight = 24.sp), onLink = { actions += it })
                                        Text("Second retained line", Modifier.testTag("retained-flow-second").height(24.dp))
                                    }
                                }
                            }, NativeFloatContextSpec.Child(2, { it }, 0f)),
                            Modifier.width(width.value.dp), MaterialTheme.colorScheme.primary) { _, _ ->
                            Text("Following child", Modifier.testTag("flow-tail").height(20.dp)
                                .onGloballyPositioned { tailBounds = it.boundsInRoot() })
                        }
                    }
                }
            } }
            compose.waitForIdle()
            lateinit var originalInput: NativeFlowMeasureInput
            lateinit var originalRequest: NativeFlowMeasureRequest
            var originalOwner: Any? = null
            compose.runOnIdle {
                originalInput = checkNotNull(input)
                originalRequest = checkNotNull(originalInput.measurement.value)
                assertNotNull(originalInput.ready(originalRequest))
                originalOwner = owner
                assertEquals(1, created)
                native.value = false
            }
            compose.waitForIdle()
            for (available in listOf(260, 190)) {
                compose.runOnIdle { width.value = available }
                compose.waitForIdle()
                val (text, glyph) = retainedLinkText("retained-flow-link", link.text, "fallback-target")
                compose.onNodeWithTag("retained-flow-second").assertTextEquals("Second retained line")
                compose.runOnIdle {
                    assertSame(originalInput, input)
                    assertSame(originalOwner, owner)
                    assertNull(originalInput.measurement.value)
                    assertNull(originalInput.geometry)
                    assertNull(originalInput.ready(originalRequest))
                    assertTrue(failures.any { it == "Anonymous child preparation is not ready" })
                    assertEquals(48f, fallbackBounds.height, .01f)
                    assertEquals(fallbackBounds.bottom, tailBounds.top, .01f)
                    assertEquals(1, created)
                    assertEquals(0, disposed)
                }
                text.performTouchInput { click(glyph) }
            }
            compose.runOnIdle {
                assertEquals(listOf("fallback-target", "fallback-target"), actions.map { it.target })
                native.value = true
            }
            compose.waitForIdle()
            compose.runOnIdle {
                assertSame(originalInput, input)
                assertSame(originalOwner, owner)
                val recovered = checkNotNull(originalInput.measurement.value)
                assertNotSame(originalRequest.binding, recovered.binding)
                assertNotNull(originalInput.ready(recovered))
                assertNull(originalInput.ready(originalRequest))
                assertEquals(1, created)
                assertEquals(0, disposed)
                assertEquals(2, actions.size)
            }
            compose.onAllNodesWithTag("retained-flow-link").assertCountEquals(0)
        } finally {
            compose.activityRule.scenario.onActivity { it.setContent {} }
            compose.waitForIdle()
        }
        assertEquals(1, disposed)
    }

    @Test fun conditionalTextFallbackAcceptsZeroOneAndMultipleEmittersInDocumentOrder() {
        val count = mutableStateOf(0)
        val boxes = mutableMapOf<Int, Rect>()
        var tail = Rect.Zero
        var fallbackCreated = 0
        var fallbackDisposed = 0
        val failures = mutableListOf<String>()
        try {
            compose.activityRule.scenario.onActivity { activity -> activity.setContent {
                MaterialTheme {
                    CompositionLocalProvider(LocalDensity provides Density(1f, 1f),
                        LocalNativeFloatContextFailureObserver provides { failures += it }) {
                        val size = count.value
                        val prepared = PreparedNativeFloatText((0 until size).joinToString("\n") { "Fallback $it" },
                            null, size, geometry = { _, _, _ -> throw UnsupportedFloatLayout("Controlled text preparation refusal") },
                            menu = {}, fallback = {
                                DisposableEffect(Unit) { fallbackCreated++; onDispose { fallbackDisposed++ } }
                                repeat(size) { index ->
                                    Text("Fallback $index", Modifier.testTag("fallback-$index").height(24.dp)
                                        .onGloballyPositioned { boxes[index] = it.boundsInRoot() })
                                }
                            })
                        NativeFloatContextLayout(listOf(NativeFloatContextSpec.Text(prepared, 0f),
                            NativeFloatContextSpec.Child(1, { it }, 0f)), Modifier.width(240.dp),
                            MaterialTheme.colorScheme.primary) { _, _ ->
                            Text("After fallback", Modifier.testTag("text-fallback-tail").height(20.dp)
                                .onGloballyPositioned { tail = it.boundsInRoot() })
                        }
                    }
                }
            } }
            compose.waitForIdle()
            var emptyTop = 0f
            compose.runOnIdle {
                emptyTop = tail.top
                assertTrue(emptyTop > 0f) // The real failure message precedes even an empty body.
                assertEquals(1, fallbackCreated)
            }
            for (size in listOf(2, 1, 0, 2)) {
                compose.runOnIdle { boxes.clear(); count.value = size }
                compose.waitForIdle()
                for (index in 0..1) {
                    compose.onAllNodesWithTag("fallback-$index").assertCountEquals(if (index < size) 1 else 0)
                    if (index < size) compose.onNodeWithTag("fallback-$index").assertTextEquals("Fallback $index")
                }
                compose.runOnIdle {
                    assertEquals(emptyTop + size * 24f, tail.top, .01f)
                    repeat(size) { index ->
                        assertEquals(emptyTop + index * 24f, boxes.getValue(index).top, .01f)
                        assertEquals(24f, boxes.getValue(index).height, .01f)
                    }
                    assertTrue(failures.contains("Controlled text preparation refusal"))
                    assertEquals(1, fallbackCreated)
                    assertEquals(0, fallbackDisposed)
                }
            }
        } finally {
            compose.activityRule.scenario.onActivity { it.setContent {} }
            compose.waitForIdle()
        }
        assertEquals(1, fallbackDisposed)
    }

    @Test fun refusedIntrinsicWidthStillMeasuresTheExistingChildAtTheAvailableFallbackWidth() {
        var measures = 0
        var measuredWidth = -1
        var childBounds = Rect.Zero
        var tailBounds = Rect.Zero
        val actions = mutableListOf<EntryLink>()
        try {
            compose.activityRule.scenario.onActivity { activity -> activity.setContent {
                MaterialTheme {
                    CompositionLocalProvider(LocalDensity provides Density(1f, 1f),
                        LocalNativeContainerScrollport provides true) {
                        NativeFloatContextLayout(listOf(
                            NativeFloatContextSpec.Child(1, { it }, 0f, widthFromContent = true),
                            NativeFloatContextSpec.Child(2, { it }, 0f)), Modifier.width(240.dp),
                            MaterialTheme.colorScheme.primary) { id, _ ->
                            if (id == 1) Layout(content = {
                                StyledText(listOf(Span("link", "Intrinsic fallback link", "intrinsic-target")),
                                    Modifier.testTag("intrinsic-fallback-link").height(24.dp),
                                    style = TextStyle(fontSize = 16.sp), onLink = { actions += it })
                            }, modifier = Modifier.onGloballyPositioned { childBounds = it.boundsInRoot() },
                                measurePolicy = object : MeasurePolicy {
                                    override fun IntrinsicMeasureScope.minIntrinsicWidth(measurables: List<IntrinsicMeasurable>, height: Int): Int =
                                        throw UnsupportedFloatLayout("Controlled intrinsic refusal")
                                    override fun MeasureScope.measure(measurables: List<Measurable>, constraints: Constraints): MeasureResult {
                                        measures++
                                        measuredWidth = constraints.maxWidth
                                        val child = measurables.single().measure(constraints)
                                        return layout(child.width, child.height) { child.place(0, 0) }
                                    }
                                })
                            else Text("After intrinsic fallback", Modifier.height(20.dp)
                                .onGloballyPositioned { tailBounds = it.boundsInRoot() })
                        }
                    }
                }
            } }
            compose.waitForIdle()
            val (text, glyph) = retainedLinkText("intrinsic-fallback-link", "Intrinsic fallback link", "intrinsic-target")
            compose.runOnIdle {
                assertTrue(measures > 0)
                assertEquals(240, measuredWidth)
                assertEquals(24f, childBounds.height, .01f)
                assertEquals(childBounds.bottom, tailBounds.top, .01f)
            }
            text.performTouchInput { click(glyph) }
            compose.runOnIdle { assertEquals("intrinsic-target", actions.single().target) }
        } finally {
            compose.activityRule.scenario.onActivity { it.setContent {} }
            compose.waitForIdle()
        }
    }
}
