package app.smallthingz.dict

import android.graphics.Rect
import android.graphics.RectF
import android.os.SystemClock
import android.view.MotionEvent
import android.view.View
import androidx.activity.compose.setContent
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.size
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.graphics.toPixelMap
import androidx.compose.ui.layout.Layout
import androidx.compose.ui.layout.boundsInWindow
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalLayoutDirection
import androidx.compose.ui.platform.LocalWindowInfo
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.captureToImage
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.click
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onFirst
import androidx.compose.ui.test.performScrollToIndex
import androidx.compose.ui.test.performSemanticsAction
import androidx.compose.ui.test.performTouchInput
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.constrainHeight
import androidx.compose.ui.unit.constrainWidth
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class NativeContainerHeightDeviceTest {
    @get:Rule val compose = createPhysicalComposeRule()
    private fun px(value: Float) = StyleLength(StyleLengthUnit.Px, value)
    private fun edges(value: Float) = StyleEdges(px(value), px(value), px(value), px(value))
    private fun box(blocks: List<Block>, style: ContainerStyle) =
        Block("container", 0, emptyList(), container = Container(blocks, style))
    private fun link(label: String, scale: Float = 1f) = Block("paragraph", 0, listOf(
        Span("link", label, target = label, foreground = "#000000", fontScale = scale,
            fontScaleBasis = FontScaleBasis.NormalBody)))

    @Composable private fun Theme(content: @Composable () -> Unit) {
        MaterialTheme(typography = MaterialTheme.typography.copy(bodyLarge =
            MaterialTheme.typography.bodyLarge.copy(fontSize = 20.sp, lineHeight = 20.sp, letterSpacing = 0.sp))) {
            CompositionLocalProvider(LocalDensity provides Density(1f, 1f), content = content)
        }
    }

    @Composable private fun Scene(blocks: List<Block>, actions: MutableList<EntryLink>,
        publish: (NativeFloatContextGeometry?) -> Unit) {
        val parent = remember { NativeLayoutInput(Unit) }
        val input = remember { NativeContextMeasureInput(invalidateParent = parent::invalidate) }
        val density = LocalDensity.current
        val environment = NativeFlowEnvironment(density.density, density.fontScale,
            LocalLayoutDirection.current, LocalWindowInfo.current.containerSize)
        val preparation = Any()
        Layout(modifier = Modifier.testTag("height-root").background(Color.White).then(parent.modifier), content = {
            CompositionLocalProvider(LocalNativeContextMeasureInput provides input) {
                NativeFloatBlockContext(blocks, { actions += it }, "height", Modifier,
                    inCell = false, gridPath = "height", gapDp = 0f, trailingGap = false,
                    fixedHeightReachable = true)
            }
        }) { children, constraints ->
            val childConstraints = Constraints(maxWidth = 220, maxHeight = 320)
            val request = input.request(constraints, childConstraints, environment,
                NativeFlowParentPolicy(preparation, true, null, 0f), emptyList())
            val child = children.single().measure(childConstraints)
            publish(input.ready(request))
            layout(constraints.constrainWidth(288), constraints.constrainHeight(240)) { child.place(48, 64) }
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

    private fun retain(name: String, detail: String): ImageBitmap {
        val viewport = compose.onNodeWithTag("height-root")
        val image = viewport.captureToImage()
        val report = renderedLayoutFailureEvidence(name, null, null, viewport, name, image.asAndroidBitmap()) + "\n$detail"
        check(report.toByteArray(Charsets.UTF_8).size <= 128 * 1024)
        InstrumentationRegistry.getInstrumentation().sendStatus(0, android.os.Bundle().apply {
            putString(android.app.Instrumentation.REPORT_KEY_STREAMRESULT, "\n$report\n")
        })
        check("OWNED_PNG_BEGIN $name " in report)
        return image
    }

    private fun blackPixels(image: ImageBitmap, area: RectF): Int {
        val pixels = image.toPixelMap()
        var count = 0
        for (y in maxOf(0, kotlin.math.floor(area.top).toInt()) until minOf(image.height, kotlin.math.ceil(area.bottom).toInt()))
            for (x in maxOf(0, kotlin.math.floor(area.left).toInt()) until minOf(image.width, kotlin.math.ceil(area.right).toInt())) {
                val color = pixels[x, y]
                if (color.red < .08f && color.green < .08f && color.blue < .08f) count++
            }
        return count
    }

    @Test fun definiteHeightChangesFlowWithoutClippingOrReplacingPositiveChildFontAndActions() {
        val mode = mutableStateOf(0)
        val actions = mutableListOf<EntryLink>()
        var geometry: NativeFloatContextGeometry? = null
        fun style() = ContainerStyle(width = ContainerWidth.Length(StyleWidth(StyleWidthUnit.Px, 180f)),
            ownerFontScale = if (mode.value == 1) 0f else .9f,
            lineHeight = ContainerLineHeight.Multiplier(1f),
            height = when (mode.value) { 0 -> null; 2 -> StyleLength(StyleLengthUnit.Em, 1.44f); else -> px(0f) },
            padding = if (mode.value == 3) edges(3f) else null,
            boxSizing = if (mode.value == 3) ContainerBoxSizing.BorderBox else null)
        try {
            compose.activityRule.scenario.onActivity { activity -> activity.setContent { Theme {
                Scene(listOf(box(listOf(link("first", 2f), link("last", 2f)), style()), link("sibling")), actions) { geometry = it }
            } } }
            compose.waitForIdle()
            val original = views().single()
            var lastWidth = 0f
            for ((state, expected) in listOf(0 to 100f, 1 to 20f, 2 to 48.8f, 3 to 26f)) {
                compose.runOnIdle { mode.value = state }
                compose.waitForIdle()
                val current = checkNotNull(geometry)
                val image = retain("native-height-flow-$state.png",
                    "used=${current.usedHeight}; boxes=${current.ordinaryBounds}; ink=${current.extents.ink}; nodes=${current.nodes}")
                assertSame(original, views().single())
                assertEquals("first\nlast\nsibling", current.text.toString())
                assertEquals(expected, current.usedHeight, .01f)
                val border = current.ordinaryBounds.values.single()
                val expectedBorder = when (state) { 0 -> 80f; 1 -> 0f; 2 -> 28.8f; else -> 6f }
                assertEquals(expectedBorder, border.height(), .01f)
                val last = current.nodes.single { it.label == "last" }.bounds.single()
                if (state == 0) lastWidth = last.width() else assertEquals(lastWidth, last.width(), .01f)
                if (state != 0) assertTrue("Positive descendant is outside the short used box", last.bottom > border.bottom + 5f)
                val painted = RectF(last).apply { offset(48f, 64f) }
                assertTrue("Original descendant glyphs remain painted", blackPixels(image, painted) > 10)
                compose.runOnIdle {
                    val info = checkNotNull(original.accessibilityNodeProvider.findAccessibilityNodeInfosByText("last", View.NO_ID)).single()
                    assertTrue(info.isVisibleToUser)
                    val bounds = Rect().also(info::getBoundsInParent)
                    assertTrue(bounds.width() > 0 && bounds.height() > 0)
                }
                compose.onNodeWithTag("height-root").performTouchInput { click(Offset(painted.centerX(), painted.centerY())) }
                compose.waitForIdle()
                assertEquals(EntryLink("last"), actions.last())
            }
            assertEquals(List(4) { EntryLink("last") }, actions)
        } finally { compose.activityRule.scenario.onActivity { it.setContent {} } }
        compose.waitForIdle()
    }

    @Test fun fixedFloatAndFlexCrossBoxesKeepTheirNaturalOverflowAndSignedPositions() {
        val row = mutableStateOf(false)
        val alignment = mutableStateOf(ContainerAlignItems.Center)
        val actions = mutableListOf<EntryLink>()
        var geometry: NativeFloatContextGeometry? = null
        fun tree(): List<Block> {
            val width = ContainerWidth.Length(StyleWidth(StyleWidthUnit.Px, 100f))
            return if (!row.value) listOf(
                box(listOf(link("overflow", 1f), link("second", 1f)), ContainerStyle(width = width,
                    height = px(10f), floatSide = TableFloatSide.Left, lineHeight = ContainerLineHeight.Multiplier(1f))),
                box(listOf(link("cleared")), ContainerStyle(clear = FigureClear.Left,
                    lineHeight = ContainerLineHeight.Multiplier(1f))))
            else listOf(box(listOf(box(listOf(link("overflow", 1f), link("second", 1f)),
                ContainerStyle(width = width, height = px(30f), lineHeight = ContainerLineHeight.Multiplier(1f)))),
                ContainerStyle(layout = ContainerLayout.FlexRow, height = px(10f), alignItems = alignment.value)))
        }
        try {
            compose.activityRule.scenario.onActivity { activity -> activity.setContent { Theme {
                Scene(tree(), actions) { geometry = it }
            } } }
            compose.waitForIdle()
            val floated = checkNotNull(geometry)
            val floatImage = retain("native-height-float.png", "used=${floated.usedHeight}; boxes=${floated.ordinaryBounds}; exclusions=${floated.ownExclusions}")
            assertEquals(30f, floated.usedHeight, .01f)
            assertEquals(10f, floated.ownExclusions.single().outer.height, .01f)
            val last = floated.nodes.single { it.label == "second" }.bounds.single()
            assertTrue(last.bottom > 10f)
            assertTrue(blackPixels(floatImage, RectF(last).apply { offset(48f, 64f) }) > 10)
            for ((align, top) in listOf(ContainerAlignItems.Center to -10f, ContainerAlignItems.End to -20f,
                ContainerAlignItems.Stretch to 0f)) {
                compose.runOnIdle { row.value = true; alignment.value = align }
                compose.waitForIdle()
                val current = checkNotNull(geometry)
                val image = retain("native-height-flex-${align.name}.png", "used=${current.usedHeight}; boxes=${current.ordinaryBounds}; ink=${current.extents.ink}")
                assertEquals(10f, current.usedHeight, .01f)
                val item = current.ordinaryBounds.values.single { kotlin.math.abs(it.height() - 30f) < .01f }
                assertEquals(top, item.top, .01f)
                val node = current.nodes.single { it.label == "second" }.bounds.single()
                val painted = RectF(node).apply { offset(48f, 64f) }
                assertTrue(blackPixels(image, painted) > 10)
                compose.onNodeWithTag("height-root").performTouchInput { click(Offset(painted.centerX(), painted.centerY())) }
                compose.waitForIdle()
                assertEquals(EntryLink("second"), actions.last())
            }
            assertEquals(List(3) { EntryLink("second") }, actions)
        } finally { compose.activityRule.scenario.onActivity { it.setContent {} } }
        compose.waitForIdle()
    }

    @Test fun separateTableAndFigureCaptionOwnersRefuseHeightWithoutDroppingTheirBodyActions() {
        val mode = mutableStateOf(0)
        val actions = mutableListOf<EntryLink>()
        val content = box(listOf(link("atomic-body")), ContainerStyle(height = px(0f)))
        val empty = Cell(emptyList(), false, 1, 1)
        fun tree(): Block = when (mode.value) {
            0 -> Block("table", 0, emptyList(), table = Table(emptyList(), listOf(listOf(empty)),
                TableGeometry(border = 0, cellPadding = 0, cellSpacing = 0), captionBlocks = listOf(content)))
            1 -> Block("table", 0, emptyList(), table = Table(emptyList(), listOf(listOf(
                empty.copy(blocks = listOf(content)))), TableGeometry(border = 0, cellPadding = 0, cellSpacing = 0)))
            else -> Block("paragraph", 0, emptyList(), figure = Figure(
                FigureContent.Missing(Span("link", "figure-body", target = "figure-body"), px(100f), px(20f)),
                FigureFormat.Thumbnail, FigurePlacement.None, FigureClear.None, edges(0f), edges(0f), edges(0f),
                1f, px(20f), FigureColor.Transparent, FigureBorder.None, FigureColor.Transparent, FigureBorder.None,
                FigureColor.Rgb("#000000"), FigureColor.Transparent, captionBlocks = listOf(content)))
        }
        try {
            compose.activityRule.scenario.onActivity { activity -> activity.setContent { Theme {
                Scene(listOf(tree()), actions) { }
            } } }
            for (state in 0..2) {
                compose.runOnIdle { mode.value = state }
                compose.waitForIdle()
                retain("native-height-atomic-refusal-$state.png", "separate-owner=$state; body/action must remain")
                compose.onAllNodesWithText("Unable to display this layout.").onFirst().assertIsDisplayed()
                val node = compose.onNodeWithText("atomic-body", useUnmergedTree = true).assertIsDisplayed()
                val layouts = mutableListOf<androidx.compose.ui.text.TextLayoutResult>()
                node.performSemanticsAction(SemanticsActions.GetTextLayoutResult) { it(layouts) }
                val point = layouts.single().getBoundingBox(2).center
                node.performTouchInput { click(point) }
                compose.waitForIdle()
                assertEquals(EntryLink("atomic-body"), actions.last())
                if (state == 2) compose.onNodeWithText("figure-body", useUnmergedTree = true).assertIsDisplayed()
            }
            assertEquals(List(3) { EntryLink("atomic-body") }, actions)
        } finally { compose.activityRule.scenario.onActivity { it.setContent {} } }
        compose.waitForIdle()
    }

    @Test fun actualEntryLazyOwnerScrollsToLastZeroHeightOverflowAndKeepsNegativeTopReachable() {
        val actions = mutableListOf<EntryLink>()
        val reading = EntryReadingState()
        var viewportWindow = androidx.compose.ui.geometry.Rect.Zero
        val zeroLine = box(listOf(link("negative-top", 2f)), ContainerStyle(lineHeight = ContainerLineHeight.Multiplier(0f)))
        val body = listOf(zeroLine) + List(25) { link("line-$it") } + link("tail-action")
        val entry = Entry("Height control", emptyList(), "language", "English", "en", listOf(
            Section(3, "Body", listOf(box(body, ContainerStyle(height = px(0f),
                lineHeight = ContainerLineHeight.Multiplier(1f))), link("following")))), emptyList())
        val bodyIndex = entryReadingStartIndex(entry, emptySet()) +
            visibleEntryReadingRows(entry, emptySet()).indexOfFirst { it.block != null }
        fun viewportScreen(): RectF {
            val decor = compose.activity.window.decorView
            val screen = IntArray(2).also(decor::getLocationOnScreen)
            val window = IntArray(2).also(decor::getLocationInWindow)
            return RectF(viewportWindow.left + screen[0] - window[0], viewportWindow.top + screen[1] - window[1],
                viewportWindow.right + screen[0] - window[0], viewportWindow.bottom + screen[1] - window[1])
        }
        fun bounds(view: NativeFloatTextView, label: String): Rect {
            val info = checkNotNull(view.accessibilityNodeProvider.findAccessibilityNodeInfosByText(label, View.NO_ID)).single()
            return Rect().also(info::getBoundsInScreen)
        }
        try {
            compose.activityRule.scenario.onActivity { activity -> activity.setContent { Theme {
                Box(Modifier.size(300.dp, 240.dp).testTag("height-root").background(Color.White)
                    .onGloballyPositioned { viewportWindow = it.boundsInWindow() }) {
                    EntryView(entry, false, {}, onLink = { actions += it }, readingState = reading,
                        settings = AppSettings(allowImages = false, allowAudio = false,
                            collapseOtherSections = false, collapseDetails = true))
                }
            } } }
            compose.waitForIdle()
            compose.onNodeWithTag("entry-scroll").performScrollToIndex(bodyIndex)
            compose.waitForIdle()
            val stable = views().single { "tail-action" in it.logicalText.toString() }
            val initial = retain("native-height-document-top.png", "items=${reading.scroll.layoutInfo.visibleItemsInfo.map { it.index to it.size }}")
            compose.runOnIdle {
                val item = reading.scroll.layoutInfo.visibleItemsInfo.single { it.index == bodyIndex }
                assertTrue("Only document allocation, not CSS used flow, gives this item its scroll extent", item.size > 500)
                val top = bounds(stable, "negative-top")
                val viewport = viewportScreen()
                assertTrue("Negative overflow must be translated into the reachable document", top.top >= viewport.top - 1f)
                assertTrue(top.bottom < viewport.bottom)
                assertTrue(blackPixels(initial, RectF(top).apply { offset(-viewport.left, -viewport.top) }) > 10)
            }
            var distance = 0f
            compose.runOnIdle {
                val tail = bounds(stable, "tail-action")
                val viewport = viewportScreen()
                distance = tail.exactCenterY() - viewport.centerY()
                assertTrue(distance > 200f)
            }
            compose.onNodeWithTag("entry-scroll").performSemanticsAction(SemanticsActions.ScrollBy) { it(0f, distance) }
            compose.waitForIdle()
            val image = retain("native-height-document-tail.png", "index=${reading.scroll.firstVisibleItemIndex}; offset=${reading.scroll.firstVisibleItemScrollOffset}")
            assertSame(stable, views().single { "tail-action" in it.logicalText.toString() })
            var target = Offset.Zero
            compose.runOnIdle {
                val tail = bounds(stable, "tail-action")
                val viewport = viewportScreen()
                assertTrue(RectF(tail).top >= viewport.top && RectF(tail).bottom <= viewport.bottom)
                assertTrue(blackPixels(image, RectF(tail).apply { offset(-viewport.left, -viewport.top) }) > 10)
                assertTrue(reading.scroll.firstVisibleItemIndex == bodyIndex && reading.scroll.firstVisibleItemScrollOffset > 200)
                assertPhysicalActivity(compose.activity)
                target = Offset(tail.exactCenterX(), tail.exactCenterY())
            }
            val down = SystemClock.uptimeMillis()
            for (action in listOf(MotionEvent.ACTION_DOWN, MotionEvent.ACTION_UP)) {
                val event = MotionEvent.obtain(down, SystemClock.uptimeMillis(), action, target.x, target.y, 0)
                    .apply { source = android.view.InputDevice.SOURCE_TOUCHSCREEN }
                try { InstrumentationRegistry.getInstrumentation().sendPointerSync(event) } finally { event.recycle() }
            }
            compose.waitForIdle()
            assertEquals(listOf(EntryLink("tail-action")), actions)
        } finally { compose.activityRule.scenario.onActivity { it.setContent {} } }
        compose.waitForIdle()
    }

    @Test fun actualEntryLazyOwnerExportsSignedMarginOverflowWithoutAnyFixedHeight() {
        val actions = mutableListOf<EntryLink>()
        val reading = EntryReadingState()
        var viewportWindow = androidx.compose.ui.geometry.Rect.Zero
        val zeroLine = link("negative-top", 2f)
        val body = listOf(zeroLine) + List(25) { link("line-$it") } + link("tail-action")
        val entry = Entry("Signed margin control", emptyList(), "language", "English", "en", listOf(
            Section(3, "Body", listOf(box(body, ContainerStyle(margins = SignedContainerEdges(
                SignedContainerMargin(StyleLengthUnit.Px, -40f), px(0f),
                SignedContainerMargin(StyleLengthUnit.Px, -100f), px(0f)),
                lineHeight = ContainerLineHeight.Multiplier(1f))), link("following")))), emptyList())
        val bodyIndex = entryReadingStartIndex(entry, emptySet()) +
            visibleEntryReadingRows(entry, emptySet()).indexOfFirst { it.block != null }
        fun viewportScreen(): RectF {
            val decor = compose.activity.window.decorView
            val screen = IntArray(2).also(decor::getLocationOnScreen)
            val window = IntArray(2).also(decor::getLocationInWindow)
            return RectF(viewportWindow.left + screen[0] - window[0], viewportWindow.top + screen[1] - window[1],
                viewportWindow.right + screen[0] - window[0], viewportWindow.bottom + screen[1] - window[1])
        }
        fun bounds(view: NativeFloatTextView, label: String): Rect {
            val info = checkNotNull(view.accessibilityNodeProvider.findAccessibilityNodeInfosByText(label, View.NO_ID)).single()
            return Rect().also(info::getBoundsInScreen)
        }
        try {
            compose.activityRule.scenario.onActivity { activity -> activity.setContent { Theme {
                Box(Modifier.size(300.dp, 240.dp).testTag("height-root").background(Color.White)
                    .onGloballyPositioned { viewportWindow = it.boundsInWindow() }) {
                    EntryView(entry, false, {}, onLink = { actions += it }, readingState = reading,
                        settings = AppSettings(allowImages = false, allowAudio = false,
                            collapseOtherSections = false, collapseDetails = true))
                }
            } } }
            compose.waitForIdle()
            compose.onNodeWithTag("entry-scroll").performScrollToIndex(bodyIndex)
            compose.waitForIdle()
            val stable = views().single { "tail-action" in it.logicalText.toString() }
            val initial = retain("native-signed-document-top.png", "items=${reading.scroll.layoutInfo.visibleItemsInfo.map { it.index to it.size }}")
            compose.runOnIdle {
                val item = reading.scroll.layoutInfo.visibleItemsInfo.single { it.index == bodyIndex }
                assertTrue("Only document allocation, not CSS used flow, gives this item its scroll extent", item.size > 500)
                val top = bounds(stable, "negative-top")
                val viewport = viewportScreen()
                assertTrue("Negative overflow must be translated into the reachable document", top.top >= viewport.top - 1f)
                assertTrue(top.bottom < viewport.bottom)
                assertTrue(blackPixels(initial, RectF(top).apply { offset(-viewport.left, -viewport.top) }) > 10)
            }
            var distance = 0f
            compose.runOnIdle {
                val tail = bounds(stable, "tail-action")
                val viewport = viewportScreen()
                distance = tail.exactCenterY() - viewport.centerY()
                assertTrue(distance > 200f)
            }
            compose.onNodeWithTag("entry-scroll").performSemanticsAction(SemanticsActions.ScrollBy) { it(0f, distance) }
            compose.waitForIdle()
            val image = retain("native-signed-document-tail.png", "index=${reading.scroll.firstVisibleItemIndex}; offset=${reading.scroll.firstVisibleItemScrollOffset}")
            assertSame(stable, views().single { "tail-action" in it.logicalText.toString() })
            var target = Offset.Zero
            compose.runOnIdle {
                val tail = bounds(stable, "tail-action")
                val viewport = viewportScreen()
                assertTrue(RectF(tail).top >= viewport.top && RectF(tail).bottom <= viewport.bottom)
                assertTrue(blackPixels(image, RectF(tail).apply { offset(-viewport.left, -viewport.top) }) > 10)
                assertTrue(reading.scroll.firstVisibleItemIndex == bodyIndex && reading.scroll.firstVisibleItemScrollOffset > 200)
                assertPhysicalActivity(compose.activity)
                target = Offset(tail.exactCenterX(), tail.exactCenterY())
            }
            val down = SystemClock.uptimeMillis()
            for (action in listOf(MotionEvent.ACTION_DOWN, MotionEvent.ACTION_UP)) {
                val event = MotionEvent.obtain(down, SystemClock.uptimeMillis(), action, target.x, target.y, 0)
                    .apply { source = android.view.InputDevice.SOURCE_TOUCHSCREEN }
                try { InstrumentationRegistry.getInstrumentation().sendPointerSync(event) } finally { event.recycle() }
            }
            compose.waitForIdle()
            assertEquals(listOf(EntryLink("tail-action")), actions)
        } finally { compose.activityRule.scenario.onActivity { it.setContent {} } }
        compose.waitForIdle()
    }

    @Test fun minimumAndSignedAdjoiningMarginsKeepSameChildPaintAndActions() {
        val minimum = mutableStateOf<Float?>(null)
        val actions = mutableListOf<EntryLink>()
        var geometry: NativeFloatContextGeometry? = null
        fun margin(value: Float) = SignedContainerMargin(StyleLengthUnit.Px, value)
        fun tree() = listOf(
            box(listOf(link("retained")), ContainerStyle(height = px(0f), minHeight = minimum.value?.let(::px),
                ownerFontScale = .9f, lineHeight = ContainerLineHeight.Multiplier(1f),
                width = ContainerWidth.Length(StyleWidth(StyleWidthUnit.Px, 180f)),
                margins = SignedContainerEdges(margin(0f), margin(0f), margin(-8f), margin(-5f)),
                padding = StyleEdges(px(1f), px(0f), px(1f), px(5f)),
                border = ContainerBorder.Edges(ContainerBorderEdge.Dotted(px(1f), ContainerColor.Rgb("#0000ff")),
                    ContainerBorderEdge.Hidden, ContainerBorderEdge.Dotted(px(1f), ContainerColor.Rgb("#0000ff")),
                    ContainerBorderEdge.None))),
            box(listOf(link("sibling")), ContainerStyle(margins = StyleEdges(px(20f), px(0f), px(0f), px(0f)),
                lineHeight = ContainerLineHeight.Multiplier(1f))))
        try {
            compose.activityRule.scenario.onActivity { activity -> activity.setContent { Theme {
                Scene(tree(), actions) { geometry = it }
            } } }
            compose.waitForIdle()
            val original = views().single()
            for (floor in listOf<Float?>(null, 20f, 50f)) {
                compose.runOnIdle { minimum.value = floor }
                compose.waitForIdle()
                val current = checkNotNull(geometry)
                val image = retain("native-minimum-signed-${floor ?: "auto"}.png",
                    "used=${current.usedHeight}; boxes=${current.ordinaryBounds}; nodes=${current.nodes}; ink=${current.extents.ink}")
                assertSame(original, views().single())
                assertEquals("retained\nsibling", current.text.toString())
                assertEquals(36f + (floor ?: 0f), current.usedHeight, .01f)
                val first = current.ordinaryBounds.values.single { it.left < 0f }
                assertEquals(-5f, first.left, .01f)
                assertEquals(4f + (floor ?: 0f), first.height(), .01f)
                val sibling = current.ordinaryBounds.values.single { it.left == 0f }
                assertEquals(first.bottom + 12f, sibling.top, .01f)
                val node = current.nodes.single { it.label == "retained" }.bounds.single()
                if (floor == null) assertTrue(node.bottom > first.bottom)
                val painted = RectF(node).apply { offset(48f, 64f) }
                assertTrue(blackPixels(image, painted) > 10)
                compose.runOnIdle {
                    val info = checkNotNull(original.accessibilityNodeProvider.findAccessibilityNodeInfosByText("retained", View.NO_ID)).single()
                    assertTrue(info.isVisibleToUser)
                    val bounds = Rect().also(info::getBoundsInParent)
                    assertTrue(bounds.width() > 0 && bounds.height() > 0)
                }
                val pixels = image.toPixelMap()
                val band = (55 until 210).map { pixels[it, 64] }
                assertTrue("Dotted border has real blue ink", band.count { it.blue > .8f && it.red < .8f } > 5)
                assertTrue("Dotted border has unpainted gaps", band.count { it.red > .95f && it.green > .95f } > 5)
                compose.onNodeWithTag("height-root").performTouchInput { click(Offset(painted.centerX(), painted.centerY())) }
                compose.waitForIdle()
                assertEquals(EntryLink("retained"), actions.last())
            }
            assertEquals(List(3) { EntryLink("retained") }, actions)
        } finally { compose.activityRule.scenario.onActivity { it.setContent {} } }
        compose.waitForIdle()
    }

    @Test fun nativeDottedAndHiddenEdgesPaintTheirActualPhysicalBands() {
        val bitmap = android.graphics.Bitmap.createBitmap(80, 40, android.graphics.Bitmap.Config.ARGB_8888)
        bitmap.eraseColor(android.graphics.Color.WHITE)
        val canvas = android.graphics.Canvas(bitmap)
        NativeContainerDecoration(null, null, 0f, listOf(
            NativeContainerPaintEdge(2f, android.graphics.Color.BLUE, true),
            NativeContainerPaintEdge(0f, null),
            NativeContainerPaintEdge(3f, android.graphics.Color.RED),
            NativeContainerPaintEdge(5f, android.graphics.Color.BLACK))).paint(canvas, RectF(10f, 5f, 70f, 35f))
        val top = (18 until 64).map { bitmap.getPixel(it, 6) }
        assertTrue(top.any { android.graphics.Color.blue(it) > 200 && android.graphics.Color.red(it) < 100 })
        assertTrue(top.any { it == android.graphics.Color.WHITE })
        assertEquals(android.graphics.Color.WHITE, bitmap.getPixel(69, 20))
        assertEquals(android.graphics.Color.BLACK, bitmap.getPixel(12, 20))
        assertEquals(android.graphics.Color.RED, bitmap.getPixel(30, 33))
        assertEquals(android.graphics.Color.WHITE, bitmap.getPixel(9, 20))
        assertEquals(android.graphics.Color.WHITE, bitmap.getPixel(30, 20))
        bitmap.recycle()
    }

}
