package app.smallthingz.dict

import android.graphics.RectF
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
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.graphics.toPixelMap
import androidx.compose.ui.layout.Layout
import androidx.compose.ui.platform.LocalLayoutDirection
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalWindowInfo
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.captureToImage
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.click
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performSemanticsAction
import androidx.compose.ui.test.performTouchInput
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.constrainHeight
import androidx.compose.ui.unit.constrainWidth
import androidx.compose.ui.unit.sp
import androidx.compose.ui.semantics.SemanticsActions
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class NativeContainerAdapterDeviceTest {
    @get:Rule val compose = createPhysicalComposeRule()
    private fun px(value: Float) = StyleLength(StyleLengthUnit.Px, value)
    private fun edges(value: Float) = StyleEdges(px(value), px(value), px(value), px(value))
    private fun box(children: List<Block>, style: ContainerStyle) =
        Block("container", 0, emptyList(), container = Container(children, style))
    private fun link(label: String, absolute: Boolean = false) = Block("paragraph", 0, listOf(
        Span("link", label, target = label, foreground = "#000000",
            fontScale = if (absolute) 1f else null,
            fontScaleBasis = if (absolute) FontScaleBasis.NormalBody else FontScaleBasis.Context)))

    @Composable
    private fun Scene(blocks: List<Block>, width: Int, actions: MutableList<EntryLink>,
        published: (NativeFloatContextGeometry?) -> Unit) {
        val parent = remember { NativeLayoutInput(Unit) }
        val input = remember { NativeContextMeasureInput(invalidateParent = parent::invalidate) }
        val density = LocalDensity.current
        val environment = NativeFlowEnvironment(density.density, density.fontScale,
            LocalLayoutDirection.current, LocalWindowInfo.current.containerSize)
        val preparation = Any()
        Layout(modifier = Modifier.testTag("container-root").background(Color.White).then(parent.modifier), content = {
            CompositionLocalProvider(LocalNativeContextMeasureInput provides input) {
                NativeFloatBlockContext(blocks, { actions += it }, "adapter", Modifier,
                    inCell = false, gridPath = "adapter", gapDp = 99f, trailingGap = false)
            }
        }) { children, constraints ->
            val childConstraints = Constraints(maxWidth = width, maxHeight = 320)
            val request = input.request(constraints, childConstraints, environment,
                NativeFlowParentPolicy(preparation, true, null, 0f), emptyList())
            val child = children.single().measure(childConstraints)
            published(input.ready(request))
            layout(constraints.constrainWidth(288), constraints.constrainHeight(240)) { child.place(48, 64) }
        }
    }

    private fun nativeViews(): List<NativeFloatTextView> {
        val found = mutableListOf<NativeFloatTextView>()
        compose.activityRule.scenario.onActivity { activity ->
            fun visit(view: android.view.View) {
                if (view is NativeFloatTextView) found += view
                if (view is android.view.ViewGroup) for (index in 0 until view.childCount) visit(view.getChildAt(index))
            }
            visit(activity.window.decorView)
        }
        return found
    }

    private fun nativeView(): NativeFloatTextView = nativeViews().single()

    private fun retain(name: String, geometry: NativeFloatContextGeometry?): androidx.compose.ui.graphics.ImageBitmap {
        val viewport = compose.onNodeWithTag("container-root")
        val image = viewport.captureToImage()
        val report = renderedLayoutFailureEvidence(name, null, null, viewport, name, image.asAndroidBitmap()) +
            "\nused=${geometry?.width}x${geometry?.usedHeight}; boxes=${geometry?.ordinaryBounds}; " +
            "ink=${geometry?.extents?.ink}; nodes=${geometry?.nodes?.map { it.label to it.bounds }}"
        check(report.toByteArray(Charsets.UTF_8).size <= 128 * 1024)
        InstrumentationRegistry.getInstrumentation().sendStatus(0, android.os.Bundle().apply {
            putString(android.app.Instrumentation.REPORT_KEY_STREAMRESULT, "\n$report\n")
        })
        check("OWNED_PNG_BEGIN $name " in report)
        return image
    }

    @Test fun realRecursiveEntryOwnerUsesInheritedStrutsAbsoluteOverridesAndBorderPaint() {
        val scale = mutableStateOf(.5f)
        val actions = mutableListOf<EntryLink>()
        var geometry: NativeFloatContextGeometry? = null
        fun tree() = listOf(box(listOf(
            box(emptyList(), ContainerStyle(ownerFontScale = 1f)),
            link("owner"),
            box(listOf(link("reset")), ContainerStyle(ownerFontScale = 1f,
                background = ContainerColor.Rgb("#00ffff"))),
            box(listOf(link("fixed", absolute = true)), ContainerStyle(ownerFontScale = 0f))
        ), ContainerStyle(width = ContainerWidth.Length(StyleWidth(StyleWidthUnit.Px, 180f)),
            ownerFontScale = scale.value, lineHeight = ContainerLineHeight.Multiplier(1.5f),
            padding = edges(2f), background = ContainerColor.Rgb("#ffff00"),
            border = ContainerBorder.Solid(px(1f), ContainerColor.Rgb("#ff0000")))))
        try {
            compose.activityRule.scenario.onActivity { activity -> activity.setContent {
                MaterialTheme(typography = MaterialTheme.typography.copy(
                    bodyLarge = MaterialTheme.typography.bodyLarge.copy(fontSize = 20.sp, lineHeight = 30.sp, letterSpacing = 0.sp))) {
                    CompositionLocalProvider(LocalDensity provides Density(1f, 1f)) {
                        Scene(tree(), 220, actions) { geometry = it }
                    }
                }
            } }
            compose.waitForIdle()
            val stable = nativeView()
            var firstOwnerWidth = 0f
            var fixedWidth = 0f
            fun verify(expectedHeight: Float, name: String) {
                val current = checkNotNull(geometry)
                val image = retain(name, current).toPixelMap()
                assertSame(stable, nativeView())
                compose.runOnIdle {
                    assertEquals("owner\nreset\nfixed", current.text.toString())
                    assertEquals(expectedHeight, current.usedHeight, .01f)
                    assertEquals(3, current.nodes.size)
                    val owner = current.nodes.single { it.label == "owner" }.bounds.single()
                    val fixed = current.nodes.single { it.label == "fixed" }.bounds.single()
                    assertTrue(owner.width() > 0f); assertTrue(fixed.width() > 0f)
                    if (firstOwnerWidth == 0f) { firstOwnerWidth = owner.width(); fixedWidth = fixed.width() }
                    else { assertEquals(firstOwnerWidth * 2f, owner.width(), .25f); assertEquals(fixedWidth, fixed.width(), .01f) }
                }
                var red = 0; var yellow = 0; var cyan = 0; var black = 0
                for (y in 48 until 208) for (x in 40 until 248) {
                    val c = image[x, y]
                    if (c.red > .95f && c.green < .05f && c.blue < .05f) red++
                    if (c.red > .95f && c.green > .95f && c.blue < .05f) yellow++
                    if (c.red < .05f && c.green > .95f && c.blue > .95f) cyan++
                    if (c.red < .05f && c.green < .05f && c.blue < .05f) black++
                }
                assertTrue(red > 100); assertTrue(yellow > 100); assertTrue(cyan > 100); assertTrue(black > 20)
                val bounds = RectF(current.nodes.single { it.label == "fixed" }.bounds.single()).apply { offset(48f, 64f) }
                compose.onNodeWithTag("container-root").performTouchInput { click(Offset(bounds.centerX(), bounds.centerY())) }
                compose.waitForIdle()
                assertEquals(EntryLink("fixed"), actions.last())
            }
            verify(81f, "native-container-owner-half.png")
            compose.runOnIdle { scale.value = 1f }
            compose.waitForIdle()
            verify(96f, "native-container-owner-reset.png")
            assertEquals(listOf(EntryLink("fixed"), EntryLink("fixed")), actions)
        } finally { compose.activityRule.scenario.onActivity { it.setContent {} } }
        compose.waitForIdle()
    }

    @Test fun actualZeroUsedContainerRetainsSignedInkAndItsOriginalLinkOwner() {
        val actions = mutableListOf<EntryLink>()
        var geometry: NativeFloatContextGeometry? = null
        val blocks = listOf(box(listOf(box(listOf(link("W", absolute = true)), ContainerStyle(
            ownerFontScale = 0f, lineHeight = ContainerLineHeight.Multiplier(0f)))), ContainerStyle(
            width = ContainerWidth.Length(StyleWidth(StyleWidthUnit.Px, 0f)),
            lineHeight = ContainerLineHeight.Multiplier(0f))))
        try {
            compose.activityRule.scenario.onActivity { activity -> activity.setContent {
                MaterialTheme(typography = MaterialTheme.typography.copy(
                    bodyLarge = MaterialTheme.typography.bodyLarge.copy(fontSize = 32.sp, letterSpacing = 0.sp))) {
                    CompositionLocalProvider(LocalDensity provides Density(1f, 1f)) {
                        Scene(blocks, 0, actions) { geometry = it }
                    }
                }
            } }
            compose.waitForIdle()
            val current = checkNotNull(geometry)
            val image = retain("native-container-zero.png", current).toPixelMap()
            val stable = nativeView()
            compose.runOnIdle {
                assertEquals(0, current.width); assertEquals(0f, current.usedHeight, 0f)
                assertEquals("W", current.text.toString())
                assertTrue(checkNotNull(current.extents.ink).top < 0f)
                assertTrue(current.nodes.single().bounds.single().width() > 0f)
                assertTrue(checkNotNull(stable.accessibilityNodeProvider.findAccessibilityNodeInfosByText("W", android.view.View.NO_ID))
                    .single().isVisibleToUser)
            }
            var ink = 0
            for (y in 16 until 112) for (x in 32 until 128) {
                val c = image[x, y]
                if (c.red < .05f && c.green < .05f && c.blue < .05f) ink++
            }
            assertTrue("Authored zero keeps real overflowing glyphs", ink > 20)
            val bounds = RectF(current.nodes.single().bounds.single()).apply { offset(48f, 64f) }
            compose.onNodeWithTag("container-root").performTouchInput { click(Offset(bounds.centerX(), bounds.centerY())) }
            compose.waitForIdle()
            assertSame(stable, nativeView())
            assertEquals(listOf(EntryLink("W")), actions)
        } finally { compose.activityRule.scenario.onActivity { it.setContent {} } }
        compose.waitForIdle()
    }

    @Test fun delegatedTableAndPreformattedLeavesKeepTheResolvedOwnerTypographyAndActions() {
        val scale = mutableStateOf(.5f)
        val actions = mutableListOf<EntryLink>()
        var geometry: NativeFloatContextGeometry? = null
        val cell = Cell(listOf(Span("link", "cell", target = "cell", foreground = "#000000")), false, 1, 1)
        val table = Block("table", 0, emptyList(), table = Table(emptyList(), listOf(listOf(cell)),
            TableGeometry(border = 0, cellPadding = 0, cellSpacing = 0)))
        val pre = Block("preformatted", 0, listOf(Span("link", "pre", target = "pre", foreground = "#000000")))
        try {
            compose.activityRule.scenario.onActivity { activity -> activity.setContent {
                MaterialTheme(typography = MaterialTheme.typography.copy(
                    bodyLarge = MaterialTheme.typography.bodyLarge.copy(fontSize = 20.sp, lineHeight = 30.sp, letterSpacing = 0.sp))) {
                    CompositionLocalProvider(LocalDensity provides Density(1f, 1f)) {
                        Scene(listOf(box(listOf(table, pre), ContainerStyle(ownerFontScale = scale.value,
                            lineHeight = ContainerLineHeight.Multiplier(1.5f)))), 220, actions) { geometry = it }
                    }
                }
            } }
            compose.waitForIdle()
            val originals = nativeViews().filter { it.logicalText.toString() in setOf("cell", "pre") }
                .associateBy { it.logicalText.toString() }
            assertEquals(setOf("cell", "pre"), originals.keys)
            val widths = mutableMapOf<String, Int>()
            fun verify(name: String, doubled: Boolean) {
                val image = retain(name, checkNotNull(geometry)).toPixelMap()
                val current = nativeViews().filter { it.logicalText.toString() in originals.keys }
                    .associateBy { it.logicalText.toString() }
                assertEquals(originals.keys, current.keys)
                compose.runOnIdle {
                    for ((label, view) in current) {
                        assertSame(originals.getValue(label), view)
                        val info = checkNotNull(view.accessibilityNodeProvider.findAccessibilityNodeInfosByText(label, android.view.View.NO_ID)).single()
                        val bounds = android.graphics.Rect(); info.getBoundsInParent(bounds)
                        assertTrue(info.isVisibleToUser); assertTrue(bounds.width() > 0)
                        if (!doubled) widths[label] = bounds.width()
                        else assertEquals(widths.getValue(label) * 2f, bounds.width().toFloat(), 2f)
                        assertTrue(view.accessibilityNodeProvider.performAction(0,
                            android.view.accessibility.AccessibilityNodeInfo.ACTION_CLICK, null))
                    }
                }
                var black = 0
                for (y in 64 until 224) for (x in 48 until 268) {
                    val color = image[x, y]
                    if (color.red < .05f && color.green < .05f && color.blue < .05f) black++
                }
                assertTrue("Real delegated native glyphs must be painted", black > 20)
            }
            verify("native-container-delegated-half.png", false)
            compose.runOnIdle { scale.value = 1f }
            compose.waitForIdle()
            verify("native-container-delegated-reset.png", true)
            assertEquals(2, actions.count { it == EntryLink("cell") })
            assertEquals(2, actions.count { it == EntryLink("pre") })
        } finally { compose.activityRule.scenario.onActivity { it.setContent {} } }
        compose.waitForIdle()
    }

    @Test fun outOfRangeParagraphEdgesKeepVisibleRefusalAndTheActualBodyAction() {
        val wrapped = mutableStateOf(false)
        val actions = mutableListOf<EntryLink>()
        var geometry: NativeFloatContextGeometry? = null
        val paragraph = link("overflow-body").copy(style = BlockStyle(padding =
            StyleEdges(px(0f), px(0f), px(0f), px(Float.MAX_VALUE))))
        try {
            compose.activityRule.scenario.onActivity { activity -> activity.setContent {
                MaterialTheme {
                    CompositionLocalProvider(LocalDensity provides Density(1f, 1f)) {
                        Scene(if (wrapped.value) listOf(box(listOf(paragraph), ContainerStyle())) else listOf(paragraph),
                            220, actions) { geometry = it }
                    }
                }
            } }
            for (nested in listOf(false, true)) {
                compose.runOnIdle { wrapped.value = nested }
                compose.waitForIdle()
                retain("native-container-edge-refusal-$nested.png", geometry)
                assertNull("Failed geometry must not be published ready", geometry)
                compose.onNodeWithText("Paragraph edge exceeds native coordinate range", substring = true).assertIsDisplayed()
                val node = compose.onNodeWithText("overflow-body", useUnmergedTree = true).assertIsDisplayed()
                val layouts = mutableListOf<androidx.compose.ui.text.TextLayoutResult>()
                node.performSemanticsAction(SemanticsActions.GetTextLayoutResult) { it(layouts) }
                val glyph = layouts.single().getBoundingBox(1).center
                node.performTouchInput { click(glyph) }
                compose.waitForIdle()
                assertEquals(EntryLink("overflow-body"), actions.last())
            }
            assertEquals(2, actions.size)
        } finally { compose.activityRule.scenario.onActivity { it.setContent {} } }
        compose.waitForIdle()
    }

    @Test fun delegatedTableAcceptsZeroContainingWidthWithoutReplacingItsRealChild() {
        val width = mutableStateOf(0)
        val actions = mutableListOf<EntryLink>()
        var geometry: NativeFloatContextGeometry? = null
        val table = Block("table", 0, emptyList(), table = Table(emptyList(), listOf(listOf(
            Cell(listOf(Span("link", "cell", target = "cell", foreground = "#000000")), false, 1, 1))),
            TableGeometry(border = 0, cellPadding = 0, cellSpacing = 0)))
        try {
            compose.activityRule.scenario.onActivity { activity -> activity.setContent {
                MaterialTheme {
                    CompositionLocalProvider(LocalDensity provides Density(1f, 1f)) {
                        Scene(listOf(box(listOf(table), ContainerStyle())), width.value, actions) { geometry = it }
                    }
                }
            } }
            compose.waitForIdle()
            val initial = checkNotNull(geometry)
            retain("native-container-table-zero.png", initial)
            assertEquals(0, initial.width)
            assertTrue(initial.ordinaryBounds.values.any { it.width() == 0f })
            val original = nativeViews().single { it.logicalText.toString() == "cell" }
            compose.runOnIdle { width.value = 220 }
            compose.waitForIdle()
            val current = checkNotNull(geometry)
            val image = retain("native-container-table-open.png", current).toPixelMap()
            assertEquals(220, current.width)
            val child = nativeViews().single { it.logicalText.toString() == "cell" }
            assertSame(original, child)
            compose.runOnIdle {
                assertTrue(checkNotNull(child.accessibilityNodeProvider.findAccessibilityNodeInfosByText("cell", android.view.View.NO_ID))
                    .single().isVisibleToUser)
                assertTrue(child.accessibilityNodeProvider.performAction(0,
                    android.view.accessibility.AccessibilityNodeInfo.ACTION_CLICK, null))
            }
            assertEquals(listOf(EntryLink("cell")), actions)
            var black = 0
            for (y in 64 until 160) for (x in 48 until 268) {
                val color = image[x, y]
                if (color.red < .05f && color.green < .05f && color.blue < .05f) black++
            }
            assertTrue(black > 20)
        } finally { compose.activityRule.scenario.onActivity { it.setContent {} } }
        compose.waitForIdle()
    }
}
