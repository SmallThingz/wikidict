package app.smallthingz.dict

import android.graphics.Rect
import android.graphics.RectF
import android.os.Bundle
import android.os.SystemClock
import android.view.MotionEvent
import android.view.View
import android.view.accessibility.AccessibilityNodeInfo
import androidx.activity.compose.setContent
import androidx.compose.foundation.background
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.PixelMap
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.graphics.toPixelMap
import androidx.compose.ui.layout.Layout
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalLayoutDirection
import androidx.compose.ui.platform.LocalWindowInfo
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.captureToImage
import androidx.compose.ui.test.click
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onFirst
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performTouchInput
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.constrainHeight
import androidx.compose.ui.unit.constrainWidth
import androidx.compose.ui.unit.sp
import androidx.core.view.accessibility.AccessibilityNodeInfoCompat
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/** Typed synthetic source controls; no actual SR or other edition rendering grant. */
@RunWith(AndroidJUnit4::class)
class AuthoredRuleDeviceTest {
    @get:Rule val compose = createPhysicalComposeRule()
    private val origin = Offset(24f, 24f)
    private fun px(value: Float) = StyleLength(StyleLengthUnit.Px, value)
    private fun em(value: Float) = StyleLength(StyleLengthUnit.Em, value)
    private fun edges(value: StyleLength = px(0f)) = StyleEdges(value, value, value, value)
    private fun paragraph(label: String, margins: StyleEdges? = edges()) = Block("paragraph", 0,
        listOf(Span("link", label, target = label, foreground = "#000000")),
        style = margins?.let { BlockStyle(margins = it) })
    private fun rule(height: Float = 1f, margins: StyleEdges = edges(em(.2f))) = Block("rule", 0, emptyList(),
        ruleStyle = RuleStyle(px(height), ContainerColor.LightDark("#00aa00", "#0000cc"), margins))
    private fun padded(blocks: List<Block>) = listOf(Block("container", 0, emptyList(),
        container = Container(blocks, ContainerStyle(padding = edges(px(2f))))))

    @Composable private fun Theme(dark: Boolean = false, content: @Composable () -> Unit) {
        MaterialTheme(typography = MaterialTheme.typography.copy(bodyLarge =
            MaterialTheme.typography.bodyLarge.copy(fontSize = 19.sp, lineHeight = 19.sp, letterSpacing = 0.sp))) {
            CompositionLocalProvider(LocalDensity provides Density(1.25f, 1.1f),
                LocalReaderDarkTheme provides dark, content = content)
        }
    }

    @Composable private fun Scene(blocks: List<Block>, actions: MutableList<EntryLink>, gap: Float = 0f,
        publish: (NativeFloatContextGeometry?) -> Unit) {
        val parent = remember { NativeLayoutInput(Unit) }
        val input = remember { NativeContextMeasureInput(invalidateParent = parent::invalidate) }
        val density = LocalDensity.current
        val environment = NativeFlowEnvironment(density.density, density.fontScale,
            LocalLayoutDirection.current, LocalWindowInfo.current.containerSize)
        val preparation = Any()
        Layout(modifier = Modifier.testTag("authored-rule-root").background(Color.White).then(parent.modifier), content = {
            CompositionLocalProvider(LocalNativeContextMeasureInput provides input) {
                NativeFloatBlockContext(blocks, { actions += it }, "authored-rule-device", Modifier,
                    inCell = false, gridPath = "authored-rule-device", gapDp = gap, trailingGap = false)
            }
        }) { children, constraints ->
            val childConstraints = Constraints(maxWidth = 220, maxHeight = 320)
            val request = input.request(constraints, childConstraints, environment,
                NativeFlowParentPolicy(preparation, true, null, 0f), emptyList())
            val child = children.single().measure(childConstraints)
            publish(input.ready(request))
            layout(constraints.constrainWidth(280), constraints.constrainHeight(240)) {
                child.place(origin.x.toInt(), origin.y.toInt())
            }
        }
    }

    private fun views(): List<NativeFloatTextView> {
        val result = mutableListOf<NativeFloatTextView>()
        compose.activityRule.scenario.onActivity { activity ->
            fun visit(view: View) {
                if (view is NativeFloatTextView) result += view
                if (view is android.view.ViewGroup) for (i in 0 until view.childCount) visit(view.getChildAt(i))
            }
            visit(activity.window.decorView)
        }
        return result
    }

    private fun sourcePixels(pixels: PixelMap, bounds: RectF, dark: Boolean): Int {
        var found = 0
        for (y in maxOf(0, kotlin.math.floor(bounds.top).toInt()) until minOf(pixels.height, kotlin.math.ceil(bounds.bottom).toInt()))
            for (x in maxOf(0, kotlin.math.floor(bounds.left).toInt()) until minOf(pixels.width, kotlin.math.ceil(bounds.right).toInt())) {
                val color = pixels[x, y]
                if (if (dark) color.blue - color.red > .25f && color.blue - color.green > .25f
                    else color.green - color.red > .25f && color.green - color.blue > .25f) found++
            }
        return found
    }

    private fun tap(geometry: NativeFloatContextGeometry, label: String) {
        val bounds = geometry.nodes.single { it.label == label }.bounds.single()
        compose.onNodeWithTag("authored-rule-root").performTouchInput {
            click(Offset(origin.x + bounds.centerX(), origin.y + bounds.centerY()))
        }
        compose.waitForIdle()
    }

    /** Refusal can retain native paragraph owners or the existing Compose text fallback. */
    private fun tapRetained(label: String) {
        val candidates = views()
        var tapped = false
        compose.runOnIdle {
            for (view in candidates) {
                val info = view.accessibilityNodeProvider.findAccessibilityNodeInfosByText(label, View.NO_ID)
                    ?.firstOrNull { it.text?.toString() == label && it.isVisibleToUser } ?: continue
                val bounds = Rect().also(info::getBoundsInParent)
                if (bounds.isEmpty) continue
                val now = SystemClock.uptimeMillis()
                val down = MotionEvent.obtain(now, now, MotionEvent.ACTION_DOWN, bounds.exactCenterX(), bounds.exactCenterY(), 0)
                val up = MotionEvent.obtain(now, now + 1, MotionEvent.ACTION_UP, bounds.exactCenterX(), bounds.exactCenterY(), 0)
                try { view.dispatchTouchEvent(down); view.dispatchTouchEvent(up) }
                finally { down.recycle(); up.recycle() }
                tapped = true
                break
            }
        }
        if (!tapped) compose.onNodeWithText(label).assertIsDisplayed().performTouchInput { click() }
        compose.waitForIdle()
    }

    private fun runControl(name: String, body: () -> Unit) {
        try { body() }
        catch (failure: Throwable) {
            runCatching {
                val viewport = compose.onNodeWithTag("authored-rule-root")
                val image = viewport.captureToImage()
                val report = renderedLayoutFailureEvidence(name, null, null, viewport, name, image.asAndroidBitmap())
                InstrumentationRegistry.getInstrumentation().sendStatus(0, Bundle().apply {
                    putString(android.app.Instrumentation.REPORT_KEY_STREAMRESULT, "\n$report\n")
                })
            }
            throw failure
        } finally {
            compose.activityRule.scenario.onActivity { it.setContent {} }
            compose.waitForIdle()
        }
    }

    @Test fun fractionalRulePaintAndNativeSeparatorShareRootSelectionAndActions() = runControl("authored-rule-root.png") {
        val dark = mutableStateOf(false)
        val actions = mutableListOf<EntryLink>()
        var geometry: NativeFloatContextGeometry? = null
        compose.activityRule.scenario.onActivity { activity -> activity.setContent { Theme(dark.value) {
            Scene(padded(listOf(paragraph("before"), rule(), paragraph("after"))), actions) { geometry = it }
        } } }
        compose.waitForIdle()
        val original = views().single()
        for (mode in listOf(false, true)) {
            compose.runOnIdle { dark.value = mode }
            compose.waitForIdle()
            val current = checkNotNull(geometry)
            assertSame(original, views().single())
            assertEquals("before\nafter", current.text.toString())
            val separator = current.nodes.single { it.kind == FloatInteractionKind.SEPARATOR }
            val bounds = separator.bounds.single()
            assertEquals(7.725f, bounds.left, .001f) // 2px padding + .2em of the 26.125px normal body.
            assertEquals(212.275f, bounds.right, .001f)
            assertEquals(1.25f, bounds.height(), .001f)
            assertEquals(6, separator.start)
            assertEquals(separator.start, separator.end)
            assertNull(separator.onClick); assertNull(separator.onLongClick); assertNull(separator.label)
            compose.runOnIdle {
                val info = checkNotNull(original.accessibilityNodeProvider.createAccessibilityNodeInfo(separator.id))
                assertEquals("android.view.View", info.className.toString())
                assertEquals(NativeRuleAccessibilityLabel, AccessibilityNodeInfoCompat.wrap(info).roleDescription.toString())
                assertTrue(info.text.isNullOrEmpty())
                assertFalse(info.isClickable); assertFalse(info.isLongClickable)
                assertFalse(original.accessibilityNodeProvider.performAction(separator.id, AccessibilityNodeInfo.ACTION_CLICK, null))
                val selection = Bundle().apply {
                    putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_START_INT, 0)
                    putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_END_INT, current.text.length)
                }
                assertTrue(original.performAccessibilityAction(AccessibilityNodeInfo.ACTION_SET_SELECTION, selection))
                assertEquals("before\nafter", original.selectedTextForCopy())
                assertEquals(0, original.selectionStart); assertEquals(current.text.length, original.selectionEnd)
                assertTrue(current.rectsForRange(0, current.text.length).all { it.bottom <= bounds.top || it.top >= bounds.bottom })
                assertTrue(current.caretRect(7).top >= bounds.bottom)
                assertTrue(original.performAccessibilityAction(AccessibilityNodeInfo.ACTION_SET_SELECTION, null))
            }
            val painted = RectF(bounds).apply { offset(origin.x, origin.y) }
            val pixels = compose.onNodeWithTag("authored-rule-root").captureToImage().toPixelMap()
            assertTrue("The source fill must paint the exact fractional rule", sourcePixels(pixels, painted, mode) > 80)
            assertEquals(0, sourcePixels(pixels, RectF(origin.x + 2.5f, painted.top, painted.left - 1f, painted.bottom), mode))
            tap(current, "before"); tap(current, "after")
        }
        assertEquals(listOf("before", "after", "before", "after"), actions.map { it.target })
    }

    @Test fun zeroRuleAdjoinsThroughWhilePositiveFractionalHeightSeparatesSiblingMargins() = runControl("authored-rule-collapse.png") {
        val height = mutableStateOf(0f)
        val actions = mutableListOf<EntryLink>()
        var geometry: NativeFloatContextGeometry? = null
        compose.activityRule.scenario.onActivity { activity -> activity.setContent { Theme {
            val before = paragraph("before", StyleEdges(px(0f), px(0f), px(12f), px(0f)))
            val after = paragraph("after", StyleEdges(px(8f), px(0f), px(0f), px(0f)))
            Scene(padded(listOf(before, rule(height.value, StyleEdges(px(4f), px(0f), px(20f), px(0f))), after)), actions) { geometry = it }
        } } }
        compose.waitForIdle()
        val zero = checkNotNull(geometry)
        val zeroAfter = zero.nodes.single { it.label == "after" }.bounds.single().top
        assertEquals(0f, zero.nodes.single { it.kind == FloatInteractionKind.SEPARATOR }.bounds.single().height(), 0f)
        compose.runOnIdle { height.value = .5f }
        compose.waitForIdle()
        val positive = checkNotNull(geometry)
        assertEquals("before\nafter", positive.text.toString())
        assertEquals(.625f, positive.nodes.single { it.kind == FloatInteractionKind.SEPARATOR }.bounds.single().height(), .001f)
        assertEquals(15.625f, positive.usedHeight - zero.usedHeight, .01f)
        assertEquals(15.625f, positive.nodes.single { it.label == "after" }.bounds.single().top - zeroAfter, .01f)
        tap(positive, "after")
        compose.runOnIdle { height.value = 0f }
        compose.waitForIdle()
        val recovered = checkNotNull(geometry)
        assertEquals(zero.usedHeight, recovered.usedHeight, .01f)
        assertEquals(zeroAfter, recovered.nodes.single { it.label == "after" }.bounds.single().top, .01f)
        tap(recovered, "before")
        assertEquals(listOf("after", "before"), actions.map { it.target })
    }

    @Test fun implicitGapAndDirectFlexRefusalsRetainBodyActionsAndRecoverToOrdinaryRule() = runControl("authored-rule-recovery.png") {
        val mode = mutableStateOf(0)
        val actions = mutableListOf<EntryLink>()
        var geometry: NativeFloatContextGeometry? = null
        compose.activityRule.scenario.onActivity { activity -> activity.setContent { Theme {
            val blocks = when (mode.value) {
                0 -> listOf(paragraph("before", null), rule(), paragraph("after", null))
                1 -> listOf(Block("container", 0, emptyList(), container = Container(
                    listOf(paragraph("before"), rule(), paragraph("after")), ContainerStyle(layout = ContainerLayout.FlexRow))))
                else -> padded(listOf(paragraph("before"), rule(), paragraph("after")))
            }
            Scene(blocks, actions, gap = if (mode.value == 0) 8f else 0f) { geometry = it }
        } } }
        compose.waitForIdle()
        for (state in listOf(0, 1)) {
            compose.runOnIdle { mode.value = state }
            compose.waitForIdle()
            assertNull("Refused roots must not reuse successful geometry", geometry)
            compose.onAllNodesWithText("Unable to display this layout.").onFirst().assertIsDisplayed()
            tapRetained("before"); tapRetained("after")
        }
        compose.runOnIdle { mode.value = 2 }
        compose.waitForIdle()
        val current = checkNotNull(geometry)
        assertEquals("before\nafter", current.text.toString())
        assertEquals(1, current.nodes.count { it.kind == FloatInteractionKind.SEPARATOR })
        assertTrue(compose.onAllNodesWithText("Unable to display this layout.").fetchSemanticsNodes().isEmpty())
        tap(current, "after")
        assertEquals(listOf("before", "after", "before", "after", "after"), actions.map { it.target })
    }

    @Test fun nullLegacyDividerRetainsItsOriginalChildRouteAcrossAuthoredZeroRule() = runControl("authored-rule-legacy.png") {
        val authored = mutableStateOf(false)
        val actions = mutableListOf<EntryLink>()
        var geometry: NativeFloatContextGeometry? = null
        val legacy = Block("rule", 0, emptyList())
        assertFalse(legacy.needsNativeBlockContext())
        compose.activityRule.scenario.onActivity { activity -> activity.setContent { Theme {
            Scene(padded(listOf(paragraph("before"), if (authored.value) rule(0f, edges()) else legacy,
                paragraph("after"))), actions) { geometry = it }
        } } }
        compose.waitForIdle()
        val original = checkNotNull(geometry)
        val legacyHeight = original.children.single().bounds.height()
        assertTrue(legacyHeight > 0f)
        assertTrue(original.nodes.none { it.kind == FloatInteractionKind.SEPARATOR })
        compose.runOnIdle { authored.value = true }
        compose.waitForIdle()
        val zero = checkNotNull(geometry)
        assertEquals("before\nafter", zero.text.toString())
        assertTrue(zero.children.isEmpty())
        assertEquals(0f, zero.nodes.single { it.kind == FloatInteractionKind.SEPARATOR }.bounds.single().height(), 0f)
        assertEquals(legacyHeight, original.usedHeight - zero.usedHeight, .01f)
        compose.runOnIdle { authored.value = false }
        compose.waitForIdle()
        val restored = checkNotNull(geometry)
        assertEquals(original.usedHeight, restored.usedHeight, .01f)
        assertEquals(legacyHeight, restored.children.single().bounds.height(), .01f)
        assertEquals(original.text.toString(), restored.text.toString())
        assertTrue(restored.nodes.none { it.kind == FloatInteractionKind.SEPARATOR })
        tap(restored, "after")
        assertEquals(listOf("after"), actions.map { it.target })
    }
}
