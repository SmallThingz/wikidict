package app.smallthingz.dict

import android.graphics.Rect
import android.graphics.RectF
import android.os.SystemClock
import android.view.MotionEvent
import android.view.View
import android.view.accessibility.AccessibilityNodeInfo
import androidx.activity.compose.setContent
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.width
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Typography
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.toPixelMap
import androidx.compose.ui.layout.Layout
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalLayoutDirection
import androidx.compose.ui.platform.LocalWindowInfo
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.*
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.constrainHeight
import androidx.compose.ui.unit.constrainWidth
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.view.accessibility.AccessibilityNodeInfoCompat
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import kotlin.math.ceil
import kotlin.math.floor

/** Synthetic Rule.clear constructors through actual native owners; no TH source/rendering grant. */
class RuleClearDeviceTest {
    @get:Rule val compose = createPhysicalComposeRule()
    private val origin = Offset(24f, 24f)
    private fun px(value: Float) = StyleLength(StyleLengthUnit.Px, value)
    private fun edges(top: Float = 0f, right: Float = 0f, bottom: Float = 0f, left: Float = 0f) =
        StyleEdges(px(top), px(right), px(bottom), px(left))
    private fun link(label: String) = Span("link", label, label, targetFragment = "source",
        foreground = "#000000", fontScale = 12f, fontScaleBasis = FontScaleBasis.CssPx)
    private fun paragraph(span: Span, top: Float = 0f, bottom: Float = 0f) = Block("paragraph", 0, listOf(span),
        style = BlockStyle(margins = edges(top = top, bottom = bottom)))
    private fun float(span: Span, side: TableFloatSide, width: Float, height: Float, margins: StyleEdges) =
        Block("container", 0, emptyList(), container = Container(listOf(paragraph(span)), ContainerStyle(
            width = ContainerWidth.Length(StyleWidth(StyleWidthUnit.Px, width)), height = px(height),
            floatSide = side, margins = margins, background = ContainerColor.Rgb("#eeeeee"))))
    private fun rule(clear: FigureClear?, height: Float = 1.25f,
        margins: StyleEdges = edges(5.25f, 70f, 11.5f, 60f)) = Block("rule", 0, emptyList(),
        ruleStyle = RuleStyle(px(height), ContainerColor.Rgb("#008000"), margins, clear = clear))

    @Composable private fun Theme(direction: LayoutDirection, content: @Composable () -> Unit) {
        CompositionLocalProvider(LocalDensity provides Density(1f, 1f), LocalLayoutDirection provides direction) {
            MaterialTheme(typography = Typography(bodyLarge = TextStyle(fontSize = 20.sp, lineHeight = 20.sp,
                fontFamily = FontFamily.Monospace, letterSpacing = 0.sp)), content = content)
        }
    }
    @Composable private fun Scene(blocks: List<Block>, width: Int, actions: MutableList<EntryLink>,
        failures: MutableList<String>, publish: (NativeFloatContextGeometry?) -> Unit) {
        val parent = remember { NativeLayoutInput(Unit) }
        val input = remember { NativeContextMeasureInput(invalidateParent = parent::invalidate) }
        val density = LocalDensity.current
        val environment = NativeFlowEnvironment(density.density, density.fontScale,
            LocalLayoutDirection.current, LocalWindowInfo.current.containerSize)
        val preparation = Any()
        Layout(modifier = Modifier.testTag("rule-clear-root").background(Color.White).then(parent.modifier), content = {
            CompositionLocalProvider(LocalNativeContextMeasureInput provides input,
                LocalNativeFloatContextFailureObserver provides { failures += it }) {
                NativeFloatBlockContext(blocks, { actions += it }, "rule-clear-control", Modifier,
                    inCell = false, gridPath = "rule-clear-control", gapDp = 0f, trailingGap = false,
                    fixedHeightReachable = true)
            }
        }) { children, constraints ->
            val childConstraints = Constraints(maxWidth = width, maxHeight = 320)
            val request = input.request(constraints, childConstraints, environment,
                NativeFlowParentPolicy(preparation, true, null, 0f), emptyList())
            val child = children.single().measure(childConstraints)
            publish(input.ready(request))
            layout(constraints.constrainWidth(320), constraints.constrainHeight(350)) {
                child.place(origin.x.toInt(), origin.y.toInt())
            }
        }
    }
    private fun control(content: @Composable () -> Unit, assertions: () -> Unit) {
        var primary: Throwable? = null
        try {
            compose.activityRule.scenario.onActivity { it.setContent(content = content) }
            compose.waitForIdle(); assertions()
        } catch (failure: Throwable) { primary = failure; throw failure }
        finally {
            try { compose.activityRule.scenario.onActivity { it.setContent {} }; compose.waitForIdle() }
            catch (cleanup: Throwable) {
                val failure = primary
                if (failure == null) throw cleanup
                if (failure !== cleanup) failure.addSuppressed(cleanup)
            }
        }
    }
    // All calls inspecting a live View or published native geometry execute on the UI owner.
    private fun views(): List<NativeFloatTextView> {
        val result = mutableListOf<NativeFloatTextView>()
        fun visit(view: View) {
            if (view is NativeFloatTextView && view.isShown) result += view
            if (view is android.view.ViewGroup) repeat(view.childCount) { visit(view.getChildAt(it)) }
        }
        visit(compose.activity.window.decorView); return result
    }
    private fun rootView(text: String) = views().single { it.logicalText.toString() == text }
    private fun assertBody(current: NativeFloatContextGeometry, spans: List<Span>, separators: Int,
        actions: MutableList<EntryLink>): NativeFloatTextView {
        val text = spans.joinToString("\n") { it.text }
        assertEquals(text, current.text.toString())
        assertFalse(current.text.contains('\uFFFC'))
        val view = rootView(text)
        val geometry = checkNotNull(view.currentMeasuredGeometry)
        assertEquals(separators, geometry.nodes.count { it.kind == FloatInteractionKind.SEPARATOR })
        assertEquals(spans.size, geometry.nodes.count { it.onClick != null })
        view.setSelection(0, text.length); assertEquals(text, view.selectedTextForCopy())
        assertTrue(view.performAccessibilityAction(AccessibilityNodeInfo.ACTION_SET_SELECTION, null))
        for (span in spans) {
            val node = geometry.nodes.single { it.kind == FloatInteractionKind.LINK && it.label.toString() == span.text }
            assertEquals(span.text, geometry.text.subSequence(node.start, node.end).toString())
            assertTrue(geometry.characterRects(node.start, node.end - node.start).all { it != null })
            val info = checkNotNull(view.accessibilityNodeProvider.createAccessibilityNodeInfo(node.id))
            try {
                assertEquals(span.text, info.text.toString()); assertTrue(info.isClickable); assertTrue(info.isVisibleToUser)
                val count = actions.size
                assertTrue(view.accessibilityNodeProvider.performAction(node.id, AccessibilityNodeInfo.ACTION_CLICK, null))
                assertEquals(count + 1, actions.size)
                assertEquals(EntryLink(span.target, targetFragment = "source"), actions.last())
            } finally { info.recycle() }
        }
        for (node in geometry.nodes.filter { it.kind == FloatInteractionKind.SEPARATOR }) {
            assertEquals(node.start, node.end); assertNull(node.onClick); assertNull(node.onLongClick); assertNull(node.label)
            val info = checkNotNull(view.accessibilityNodeProvider.createAccessibilityNodeInfo(node.id))
            try {
                assertEquals(NativeRuleAccessibilityLabel, AccessibilityNodeInfoCompat.wrap(info).roleDescription.toString())
                assertTrue(info.text.isNullOrEmpty()); assertFalse(info.isClickable); assertFalse(info.isLongClickable)
                assertFalse(view.accessibilityNodeProvider.performAction(node.id, AccessibilityNodeInfo.ACTION_CLICK, null))
                val at = IntArray(2).also(view::getLocationOnScreen)
                val expected = RectF(node.bounds.single()).apply { offset(at[0].toFloat() + view.paddingLeft, at[1].toFloat() + view.paddingTop) }
                val rounded = Rect(); expected.roundOut(rounded)
                val actual = Rect(); info.getBoundsInScreen(actual); assertEquals(rounded, actual)
            } finally { info.recycle() }
        }
        return view
    }
    private fun tap(view: NativeFloatTextView, span: Span, actions: MutableList<EntryLink>) {
        compose.runOnIdle {
            assertPhysicalActivity(compose.activity); check(compose.activity.hasWindowFocus())
            val node = checkNotNull(view.currentMeasuredGeometry).nodes.single { it.label.toString() == span.text && it.onClick != null }
            val rect = node.bounds.first(); val now = SystemClock.uptimeMillis(); val count = actions.size
            val down = MotionEvent.obtain(now, now, MotionEvent.ACTION_DOWN,
                rect.centerX() + view.paddingLeft, rect.centerY() + view.paddingTop, 0)
            val up = MotionEvent.obtain(now, now + 10, MotionEvent.ACTION_UP,
                rect.centerX() + view.paddingLeft, rect.centerY() + view.paddingTop, 0)
            try { assertTrue(view.dispatchTouchEvent(down)); assertTrue(view.dispatchTouchEvent(up)) }
            finally { down.recycle(); up.recycle() }
            assertEquals(count + 1, actions.size); assertEquals(EntryLink(span.target, targetFragment = "source"), actions.last())
        }
        compose.waitForIdle()
    }
    private fun painted(bounds: RectF) {
        val pixels = compose.onNodeWithTag("rule-clear-root").captureToImage().toPixelMap()
        val area = RectF(bounds).apply { offset(origin.x, origin.y) }
        var green = 0
        for (y in maxOf(0, floor(area.top).toInt()) until minOf(pixels.height, ceil(area.bottom).toInt()))
            for (x in maxOf(0, floor(area.left).toInt()) until minOf(pixels.width, ceil(area.right).toInt())) {
                val color = pixels[x, y]
                if (color.green - color.red > .2f && color.green - color.blue > .2f) green++
            }
        assertTrue("The actual native separator paints its original source fill at the exported bounds", green > 0)
    }
    private fun nodeBounds(current: NativeFloatContextGeometry, label: String) =
        RectF(current.nodes.single { it.label.toString() == label && it.onClick != null }.bounds.single())

    @Test fun physicalClearUsesOnlySelectedFloatOuterBottomsAndKeepsMarginsBodyAndSeparator() {
        val before = link("Before"); val left = link("L"); val right = link("R"); val after = link("After")
        val spans = listOf(before, left, right, after)
        val leftMargin = edges(2.5f, 5f, 7.75f, 3f)
        val rightMargin = edges(1.25f, 2f, 4.5f, 6f)
        val first = paragraph(before, bottom = 9f)
        val leftFloat = float(left, TableFloatSide.Left, 40f, 40.25f, leftMargin)
        val rightFloat = float(right, TableFloatSide.Right, 50f, 70.5f, rightMargin)
        val last = paragraph(after, top = 7.25f)
        val clear = mutableStateOf<FigureClear?>(null)
        val direction = mutableStateOf(LayoutDirection.Ltr); val width = mutableStateOf(260)
        val actions = mutableListOf<EntryLink>(); val failures = mutableListOf<String>()
        var published: NativeFloatContextGeometry? = null
        control({ Theme(direction.value) {
            Scene(listOf(first, leftFloat, rightFloat, rule(clear.value), last), width.value, actions, failures) { published = it }
        } }) {
            val original = compose.runOnIdle { rootView(spans.joinToString("\n") { it.text }) }
            var originalIds: List<Int>? = null
            for (dir in listOf(LayoutDirection.Ltr, LayoutDirection.Rtl)) for (available in listOf(260, 220)) {
                compose.runOnIdle { direction.value = dir; width.value = available; clear.value = null }
                compose.waitForIdle()
                val baseline = compose.runOnIdle { checkNotNull(published) }
                val baseRule = baseline.nodes.single { it.kind == FloatInteractionKind.SEPARATOR }.bounds.single()
                val baseAfter = nodeBounds(baseline, after.text)
                val floats = baseline.ownExclusions.associateBy { it.side }
                assertEquals(setOf(TableFloatSide.Left, TableFloatSide.Right), floats.keys)
                val leftOuter = floats.getValue(TableFloatSide.Left).outer
                val rightOuter = floats.getValue(TableFloatSide.Right).outer
                assertEquals(50.5f, leftOuter.height, .001f); assertEquals(76.25f, rightOuter.height, .001f)
                val leftBorder = baseline.ordinaryBounds.values.single { it.width() == 40f && it.height() == 40.25f }
                val rightBorder = baseline.ordinaryBounds.values.single { it.width() == 50f && it.height() == 70.5f }
                assertEquals(leftBorder.bottom + 7.75f, leftOuter.bottom, .001f)
                assertEquals(rightBorder.bottom + 4.5f, rightOuter.bottom, .001f)
                assertTrue(baseRule.left >= leftOuter.right && baseRule.right <= rightOuter.left)
                assertTrue(leftOuter.bottom > baseRule.bottom && rightOuter.bottom > leftOuter.bottom)
                val referenceImage = compose.onNodeWithTag("rule-clear-root").captureToImage()
                for (mode in listOf(null, FigureClear.None, FigureClear.Left, FigureClear.Right, FigureClear.Both)) {
                    compose.runOnIdle { clear.value = mode }; compose.waitForIdle()
                    val current = compose.runOnIdle { checkNotNull(published) }
                    val separator = current.nodes.single { it.kind == FloatInteractionKind.SEPARATOR }
                    val bounds = separator.bounds.single()
                    val selectedBottom = when (mode) {
                        FigureClear.Left -> leftOuter.bottom
                        FigureClear.Right, FigureClear.Both -> rightOuter.bottom
                        else -> baseRule.top
                    }
                    assertEquals(maxOf(baseRule.top, selectedBottom), bounds.top, .001f)
                    assertEquals(60f, bounds.left, .001f); assertEquals(available - 70f, bounds.right, .001f)
                    assertEquals(1.25f, bounds.height(), .001f)
                    assertEquals(baseline.ownExclusions, current.ownExclusions)
                    // Same following typography: only the Rule's actual clearance may move its origin.
                    assertEquals(bounds.top - baseRule.top, nodeBounds(current, after.text).top - baseAfter.top, .001f)
                    val paintedRule = current.inputLeaves().single { it.geometry is NativeRuleGeometry }
                    assertEquals(bounds.top, paintedRule.y, .001f); assertEquals(bounds.left, paintedRule.x, .001f)
                    assertEquals(mode, (paintedRule.geometry as NativeRuleGeometry).metrics.clear)
                    compose.runOnIdle {
                        assertTrue(failures.toString(), failures.isEmpty())
                        assertSame(original, assertBody(current, spans, 1, actions))
                        val ids = current.nodes.map { it.id }
                        if (originalIds == null) originalIds = ids else assertEquals(originalIds, ids)
                    }
                    painted(bounds)
                    if (mode == FigureClear.None) {
                        assertEquals(baseRule, bounds); assertEquals(baseline.usedHeight, current.usedHeight, .001f)
                        val beforePixels = referenceImage.toPixelMap()
                        val actualPixels = compose.onNodeWithTag("rule-clear-root").captureToImage().toPixelMap()
                        assertEquals(beforePixels.width, actualPixels.width); assertEquals(beforePixels.height, actualPixels.height)
                        for (y in 0 until beforePixels.height) for (x in 0 until beforePixels.width)
                            assertEquals("Explicit none preserves old-null paint", beforePixels[x, y], actualPixels[x, y])
                    }
                    tap(original, after, actions)
                }
            }
        }
    }

    @Test fun nestedFloatContextIsIsolatedAndStandaloneClearRefusesWithoutDroppingAdjacentActions() {
        val before = link("Before"); val outer = link("Outer"); val innerBefore = link("Inner-before")
        val innerFloat = link("I"); val innerAfter = link("Inner-after"); val after = link("After")
        val spans = listOf(before, outer, innerBefore, innerFloat, innerAfter, after)
        val outerRight = float(outer, TableFloatSide.Right, 50f, 140f, edges(1f, 2f, 4f, 6f))
        val localRight = float(innerFloat, TableFloatSide.Right, 30f, 20.25f, edges(1.5f, 3f, 3.5f, 2f))
        val clear = mutableStateOf<FigureClear?>(FigureClear.Right)
        val direction = mutableStateOf(LayoutDirection.Rtl); val width = mutableStateOf(260)
        val standalone = mutableStateOf(false)
        val actions = mutableListOf<EntryLink>(); val failures = mutableListOf<String>()
        var published: NativeFloatContextGeometry? = null
        var surface: FloatTextGeometry? = null
        val standBefore = link("Surface-before"); val standAfter = link("Surface-after")
        control({ Theme(direction.value) {
            if (standalone.value) Column(Modifier.width(220.dp).background(Color.White).testTag("rule-clear-surface")) {
                StyledText(listOf(standBefore), onLink = { actions += it })
                AuthoredRuleSurface(resolveAuthoredRuleMetrics(checkNotNull(rule(clear.value,
                    margins = edges(top = 5.25f, bottom = 11.5f)).ruleStyle), 1f, 20f, false), sink = { surface = it })
                StyledText(listOf(standAfter), onLink = { actions += it })
            } else {
                val nested = Block("container", 0, emptyList(), container = Container(listOf(
                    paragraph(innerBefore, bottom = 5f), localRight,
                    rule(clear.value, margins = edges(top = 4f, right = 40f, bottom = 5f)), paragraph(innerAfter, top = 3f)),
                    ContainerStyle(width = ContainerWidth.Length(StyleWidth(StyleWidthUnit.Px, 140f)),
                        padding = edges(3f, 3f, 3f, 3f), margins = edges(top = 2f, right = 6f, bottom = 7f, left = 4f),
                        floatSide = TableFloatSide.Left)))
                Scene(listOf(paragraph(before, bottom = 9f), outerRight, nested,
                    rule(FigureClear.Both, 2.25f, edges(top = 5f, bottom = 6f)), paragraph(after, top = 4f)),
                    width.value, actions, failures) { published = it }
            }
        } }) {
            for (available in listOf(260, 220)) for (dir in listOf(LayoutDirection.Rtl, LayoutDirection.Ltr)) {
                compose.runOnIdle { width.value = available; direction.value = dir; clear.value = FigureClear.None }
                compose.waitForIdle()
                val none = compose.runOnIdle { checkNotNull(published) }
                val noneInner = none.nodes.single { it.kind == FloatInteractionKind.SEPARATOR && it.bounds.single().height() == 1.25f }.bounds.single()
                val noneOuter = none.nodes.single { it.kind == FloatInteractionKind.SEPARATOR && it.bounds.single().height() == 2.25f }.bounds.single()
                val rightOuter = none.ownExclusions.single { it.side == TableFloatSide.Right }.outer
                val localBorder = none.ordinaryBounds.values.single { it.width() == 30f && it.height() == 20.25f }
                val nestedBorder = none.ordinaryBounds.values.single { it.width() == 146f }
                val localBottom = localBorder.bottom + 3.5f
                assertTrue(noneInner.top < localBottom)
                assertTrue(noneInner.right <= localBorder.left - 2f)
                assertEquals(nestedBorder.left + 3f, noneInner.left, .001f)
                compose.runOnIdle { assertBody(none, spans, 2, actions) }
                compose.runOnIdle { clear.value = FigureClear.Right }; compose.waitForIdle()
                val current = compose.runOnIdle { checkNotNull(published) }
                val inner = current.nodes.single { it.kind == FloatInteractionKind.SEPARATOR && it.bounds.single().height() == 1.25f }.bounds.single()
                val outerRule = current.nodes.single { it.kind == FloatInteractionKind.SEPARATOR && it.bounds.single().height() == 2.25f }.bounds.single()
                val currentLocal = current.ordinaryBounds.values.single { it.width() == 30f && it.height() == 20.25f }
                assertEquals(localBorder, currentLocal)
                assertEquals(localBottom, inner.top, .001f)
                assertTrue("Nested clear sees its local float, not the tall enclosing-context float", inner.bottom < rightOuter.bottom)
                assertEquals(rightOuter.bottom, outerRule.top, .001f)
                assertEquals(noneOuter, outerRule)
                assertEquals(inner.top - noneInner.top,
                    nodeBounds(current, innerAfter.text).top - nodeBounds(none, innerAfter.text).top, .001f)
                // Only the two enclosing floats belong to the outer context; the local right float stays isolated.
                assertEquals(2, current.ownExclusions.size)
                assertEquals(rightOuter, current.ownExclusions.single { it.side == TableFloatSide.Right }.outer)
                val actualView = compose.runOnIdle {
                    assertTrue(failures.toString(), failures.isEmpty()); assertBody(current, spans, 2, actions)
                }
                painted(inner); painted(outerRule); tap(actualView, innerAfter, actions); tap(actualView, after, actions)
            }
            // This existing surface has no shared active-float owner. It must retain the
            // adjacent source links while refusing non-none clear, rather than silently ignoring it.
            compose.runOnIdle { standalone.value = true; clear.value = null }; compose.waitForIdle()
            val recovered = compose.runOnIdle {
                checkNotNull(surface).also {
                    assertEquals("", it.text.toString()); assertNull(it.textBaselines)
                    assertEquals(1, it.nodes.count { node -> node.kind == FloatInteractionKind.SEPARATOR })
                    assertEquals(1.25f, it.nodes.single().bounds.single().height(), .001f)
                }
            }
            for (mode in listOf(FigureClear.Right, FigureClear.None, FigureClear.Left, null)) {
                compose.runOnIdle { clear.value = mode }; compose.waitForIdle()
                if (mode == FigureClear.Right || mode == FigureClear.Left) {
                    compose.onNodeWithText("Unable to display this layout.").assertIsDisplayed()
                    compose.runOnIdle { assertNull(surface) }
                } else {
                    compose.onAllNodesWithText("Unable to display this layout.").assertCountEquals(0)
                    compose.runOnIdle {
                        val actual = checkNotNull(surface)
                        assertEquals(recovered.width, actual.width); assertEquals(recovered.height, actual.height)
                        assertEquals(recovered.nodes.single().bounds, actual.nodes.single().bounds)
                        assertEquals("", actual.text.toString()); assertNull(actual.nodes.single().onClick)
                    }
                }
                for (span in listOf(standBefore, standAfter)) {
                    val retained = compose.onNodeWithText(span.text, useUnmergedTree = true).assertIsDisplayed()
                    val layouts = mutableListOf<androidx.compose.ui.text.TextLayoutResult>()
                    retained.performSemanticsAction(androidx.compose.ui.semantics.SemanticsActions.GetTextLayoutResult) { it(layouts) }
                    assertEquals(span.text, layouts.single().layoutInput.text.text)
                    val count = compose.runOnIdle { actions.size }
                    retained.performTouchInput { click(layouts.single().getBoundingBox(0).center) }
                    compose.runOnIdle {
                        assertEquals(count + 1, actions.size); assertEquals(EntryLink(span.target, targetFragment = "source"), actions.last())
                    }
                }
            }
        }
    }
}
