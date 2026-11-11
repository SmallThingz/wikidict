package app.smallthingz.dict

import androidx.activity.compose.setContent
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.width
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
import androidx.compose.ui.layout.Layout
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.captureToImage
import androidx.compose.ui.test.click
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performTouchInput
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.unit.constrainHeight
import androidx.compose.ui.unit.constrainWidth
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.dp
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.sp
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/** Actual Compose cache/invalidation behavior; no alternate child, corpus, cache or media request. */
@RunWith(AndroidJUnit4::class)
class NativeFlowMeasurementDeviceTest {
    @get:Rule val compose = createPhysicalComposeRule()

    @Test fun sameSizeCaptionReplacementInvalidatesTheOuterGeometryWithoutReplacingItsChild() {
        val revision = mutableStateOf(false)
        val clicks = mutableListOf<EntryLink>()
        val zero = StyleLength(StyleLengthUnit.Px, 0f)
        val edges = StyleEdges(zero, zero, zero, zero)
        val figure = Figure(FigureContent.Missing(Span("text", "Frame"), StyleLength(StyleLengthUnit.Px, 120f),
            StyleLength(StyleLengthUnit.Px, 20f)), FigureFormat.Framed, FigurePlacement.None, FigureClear.None,
            edges, edges, edges, 1f, StyleLength(StyleLengthUnit.Px, 20f),
            FigureColor.Transparent, FigureBorder.None, FigureColor.Transparent, FigureBorder.None,
            FigureColor.NativeTheme, FigureColor.Transparent)
        val context = AnonymousFlowContext(BidiResolvedDirection.Ltr, null, null)
        val content = anonymousFlowContent(Block("paragraph", 0, emptyList(), figure = figure), context)
        val metricEdges = FigurePixelEdges(0f, 0f, 0f, 0f)
        val metrics = FigureBoxMetrics(FigurePixels(120f, 10f), metricEdges, metricEdges, metricEdges, 0f, 0f)
        var input: NativeFlowMeasureInput? = null
        var frameOwner: Any? = null
        var framesCreated = 0
        var framesDisposed = 0
        var outerPreparations = 0
        try {
            compose.activityRule.scenario.onActivity { activity -> activity.setContent {
                MaterialTheme {
                    CompositionLocalProvider(LocalDensity provides Density(1f, 1f)) {
                        NativeFloatContextLayout(listOf(NativeFloatContextSpec.Flow(0, 0f, null, null, false) { carried, sink ->
                            val current = checkNotNull(LocalNativeFlowMeasureInput.current)
                            val environment = NativeFlowEnvironment(1f, 1f, androidx.compose.ui.unit.LayoutDirection.Ltr,
                                androidx.compose.ui.platform.LocalWindowInfo.current.containerSize)
                            val prepared = remember(environment) { NativeFlowBinding(environment, NativeTextInsets(), 0f) }
                            val semantic = remember { arrayOfNulls<FloatTextGeometry>(1) }
                            SideEffect { input = current; current.bind(prepared); outerPreparations++ }
                            DisposableEffect(current, prepared) { onDispose { current.unbind(prepared) } }
                            AnonymousFlowLayout(content, android.text.TextPaint().apply { textSize = 16f },
                                current.measurement.modifier, MaterialTheme.colorScheme.primary,
                                inline = { _, _ -> android.text.SpannableString("") },
                                figureSpec = { _, _ -> AnonymousFigureMeasureSpec(120, FloatMargins(0f, 0f, 0f, 0f)) },
                                inlineNodes = { emptyList() }, semanticGeometry = { _, _, _ -> semantic[0] },
                                interactionOwner = false, carriedExclusions = carried, onFlowGeometry = sink,
                                measureInput = current, preparedBinding = prepared) { _, _ ->
                                val owner = remember { Any() }
                                DisposableEffect(owner) { framesCreated++; onDispose { framesDisposed++ } }
                                SideEffect { frameOwner = owner }
                                FigureChildLayout(metrics, { semantic[0] = it }, caption = { captionSink ->
                                    SelectionColumn(listOf({ childSink ->
                                        val changed = revision.value // Only this real descendant observes the change.
                                        AnonymousBlockView(Block("paragraph", 0, listOf(Span("link", if (changed) "BBBB" else "AAAA",
                                            if (changed) "new-caption" else "old-caption"))), Modifier,
                                            { clicks += it }, emptyList(), AppSettings(allowImages = false, allowAudio = false), "",
                                            style = TextStyle(fontSize = 16.sp, lineHeight = 24.sp, fontFamily = FontFamily.Monospace,
                                                fontWeight = if (changed) FontWeight.Bold else FontWeight.Normal),
                                            onGeometry = childSink, interactionOwner = false)
                                    }), BidiResolvedDirection.Ltr, captionSink)
                                }, build = { caption -> NativeSemanticGroup(metrics.width, metrics.height(caption.height), listOf(
                                    PositionedSemanticChild(NoPaintGeometry(caption), 0f, metrics.captionTop, BidiResolvedDirection.Ltr))) })
                            }
                        }), Modifier.width(240.dp), MaterialTheme.colorScheme.primary) { _, _ -> }
                    }
                }
            } }
            compose.waitForIdle()
            lateinit var original: NativeAnonymousFlowGeometry
            lateinit var binding: NativeFlowBinding
            var owner: Any? = null
            var preparations = 0
            compose.runOnIdle {
                original = checkNotNull(input?.geometry)
                assertTrue(original.text.contains("AAAA"))
                binding = checkNotNull(input?.measurement?.value).binding
                owner = frameOwner
                preparations = outerPreparations
                assertEquals(1, framesCreated)
                revision.value = true
            }
            compose.waitForIdle()
            compose.runOnIdle {
                val replaced = checkNotNull(input?.geometry)
                assertNotSame(original, replaced)
                assertEquals(original.width, replaced.width)
                assertEquals(original.height, replaced.height)
                assertTrue(replaced.text.contains("BBBB"))
                assertFalse(replaced.text.contains("AAAA"))
                assertSame(binding, checkNotNull(input?.measurement?.value).binding)
                assertEquals(preparations, outerPreparations)
                assertSame(owner, frameOwner)
                assertEquals(1, framesCreated)
                assertEquals(0, framesDisposed)
                replaced.nodes.single { it.onClick != null }.onClick!!()
                assertEquals("new-caption", clicks.single().target)
            }
        } finally {
            compose.activityRule.scenario.onActivity { it.setContent {} }
            compose.waitForIdle()
        }
        assertEquals(1, framesDisposed)
    }

    @Test fun sameComposedFlowReusesOnlyItsExactInputsAndClearsFailureAndDetach() {
        val floatHeight = NativeLayoutInput(24)
        val tailHeight = NativeLayoutInput(8)
        val localFailure = mutableStateOf(false)
        val fontScale = mutableStateOf(1f)
        val content = mutableStateOf("Original link with enough words to wrap beside the float")
        val visible = mutableStateOf(true)
        val actions = mutableListOf<EntryLink>()
        var input: NativeFlowMeasureInput? = null
        var flowOwner: Any? = null
        var created = 0
        var disposed = 0
        var completed = 0
        try {
            compose.activityRule.scenario.onActivity { activity -> activity.setContent {
                MaterialTheme {
                    CompositionLocalProvider(LocalDensity provides Density(1f, fontScale.value)) {
                        if (visible.value) {
                            val block = Block("paragraph", 0, emptyList(), flow = listOf(FlowPart.Inline(
                                listOf(Span("link", content.value, "same-target")))))
                            NativeFloatContextLayout(listOf(
                                NativeFloatContextSpec.Child(0, { 48 }, 0f, floatSide = TableFloatSide.Left),
                                NativeFloatContextSpec.Flow(1, 0f, null, null, false) { carried, sink ->
                                    val owner = remember { Any() }
                                    val measureInput = LocalNativeFlowMeasureInput.current
                                    DisposableEffect(owner) { created++; onDispose { disposed++ } }
                                    SideEffect { input = measureInput; flowOwner = owner }
                                    AnonymousBlockView(block, if (localFailure.value) Modifier.height(1.dp) else Modifier,
                                        { actions += it }, emptyList(), AppSettings(allowImages = false, allowAudio = false), "",
                                        interactionOwner = false, carriedExclusions = carried,
                                        onFlowGeometry = { completed++; sink(it) })
                                },
                                NativeFloatContextSpec.Child(2, { 8 }, 0f)), Modifier.width(300.dp), MaterialTheme.colorScheme.primary) { id, _ ->
                                val height = if (id == 0) floatHeight else tailHeight
                                Layout(content = {}, modifier = height.modifier) { _, constraints ->
                                    layout(constraints.maxWidth, height.value) { }
                                }
                            }
                        }
                    }
                }
            } }
            compose.waitForIdle()
            lateinit var first: NativeAnonymousFlowGeometry
            lateinit var firstRequest: NativeFlowMeasureRequest
            var firstCount = 0
            var stableOwner: Any? = null
            compose.runOnIdle {
                first = checkNotNull(input?.geometry)
                firstRequest = checkNotNull(input?.measurement?.value)
                assertTrue(firstRequest.exclusions.isNotEmpty())
                stableOwner = flowOwner
                firstCount = completed
                assertEquals(1, created)
                assertEquals(0, disposed)
                tailHeight.update(13) // Parent remeasure, same actual Flow constraints and exclusions.
            }
            compose.waitForIdle()
            compose.runOnIdle {
                assertEquals(firstCount, completed)
                assertSame(first, input?.geometry)
                assertEquals(firstRequest, input?.measurement?.value)
                assertSame(stableOwner, flowOwner)
                first.nodes.single { it.onClick != null }.onClick!!()
                assertEquals("same-target", actions.single().target)
                floatHeight.update(60) // Real earlier float changes the exclusion snapshot.
            }
            compose.waitForIdle()
            compose.runOnIdle {
                val current = checkNotNull(input?.measurement?.value)
                assertNotEquals(firstRequest.exclusions, current.exclusions)
                assertNotSame(first, input?.geometry)
                assertTrue(completed > firstCount)
                assertSame(stableOwner, flowOwner)
                assertNull(input?.ready(firstRequest))
                localFailure.value = true
            }
            compose.waitForIdle()
            compose.runOnIdle {
                assertNull(input?.geometry)
                assertSame(stableOwner, flowOwner)
                assertEquals(0, disposed)
                localFailure.value = false
                fontScale.value = 1.5f
                content.value = "Replacement link with enough words to wrap beside the float"
            }
            compose.waitForIdle()
            lateinit var detached: NativeFlowMeasureInput
            compose.runOnIdle {
                detached = checkNotNull(input)
                val recovered = checkNotNull(detached.geometry)
                assertTrue(recovered.text.startsWith("Replacement link"))
                assertEquals(1.5f, checkNotNull(detached.measurement.value).binding.environment.fontScale, 0f)
                assertSame(stableOwner, flowOwner)
                assertEquals(1, created)
                assertEquals(0, disposed)
                assertNull(detached.ready(firstRequest))
                visible.value = false
            }
            compose.waitForIdle()
            compose.runOnIdle {
                assertNull(detached.geometry)
                assertEquals(1, disposed)
                assertEquals(1, actions.size)
            }
        } finally {
            compose.activityRule.scenario.onActivity { it.setContent {} }
            compose.waitForIdle()
        }
    }

    @Test fun nestedContextsKeepZeroUsedBoxesAndReplaceSameSizeDescendantActionsOnTheSameChild() {
        val revision = mutableStateOf(false)
        val actions = mutableListOf<String>()
        var input: NativeContextMeasureInput? = null
        var owner: Any? = null
        var created = 0
        var disposed = 0
        var usedWidth = -1
        var usedHeight = -1
        val origin = Offset(112f, 88f)
        try {
            compose.activityRule.scenario.onActivity { activity -> activity.setContent {
                MaterialTheme {
                    CompositionLocalProvider(LocalDensity provides Density(1f, 1f)) {
                        Layout(modifier = Modifier.testTag("nested-context-root").background(Color.White), content = {
                            val outer = NativeFloatContextSpec.Container(10, { _, _ -> 0 },
                                intrinsicWidth = { _, _ -> 0 },
                                margins = { FloatMargins(top = 0f, right = 0f, bottom = 0f, left = .375f) }) {
                                val stable = remember { Any() }
                                DisposableEffect(stable) { created++; onDispose { disposed++ } }
                                val current = checkNotNull(LocalNativeContextMeasureInput.current)
                                SideEffect { owner = stable; input = current }
                                val inner = NativeFloatContextSpec.Container(20, { _, _ -> 0 },
                                    intrinsicWidth = { _, _ -> 0 }) {
                                    val changed = revision.value
                                    val label = if (changed) "new" else "old"
                                    val paint = android.text.TextPaint(android.graphics.Paint.ANTI_ALIAS_FLAG).apply {
                                        textSize = 32f
                                        color = if (changed) android.graphics.Color.BLUE else android.graphics.Color.RED
                                    }
                                    fun source() = android.text.SpannableString(label).apply {
                                        setSpan(NativeRunLineMetrics(NativePrimaryFontMetrics.from(paint),
                                            NativeLineHeightPolicy.Pixels(0f), strut = true), 0, length,
                                            android.text.Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
                                    }
                                    val nodes: (FloatTextGeometry) -> List<FloatInteractionNode> = { geometry ->
                                        listOf(FloatInteractionNode(0, FloatInteractionKind.LINK, 0, label.length,
                                            geometry.rectsForRange(0, label.length), label, null, { actions += label }))
                                    }
                                    val prepared = PreparedNativeFloatText(label, null, Any(),
                                        geometry = { width, carried, _ -> NativeFloatGeometry.build(source(), paint,
                                            width, emptyList(), carriedExclusions = carried, nodeFactory = nodes) },
                                        menu = {}, native = NativePreparedText(paint, { source() }, nodes,
                                            android.text.TextDirectionHeuristics.LTR),
                                        fallback = { error("Nested native text must remain supported") })
                                    NativeFloatContextLayout(listOf(NativeFloatContextSpec.Text(prepared, 0f)),
                                        Modifier, Color.Magenta) { _, _ -> error("No atomic child") }
                                }
                                NativeFloatContextLayout(listOf(inner), Modifier, Color.Magenta) { _, _ ->
                                    error("No atomic child")
                                }
                            }
                            NativeFloatContextLayout(listOf(outer), Modifier, Color.Magenta) { _, _ -> error("No atomic child") }
                        }) { measurables, constraints ->
                            val child = measurables.single().measure(Constraints(maxWidth = 0, maxHeight = 200))
                            usedWidth = child.width; usedHeight = child.height
                            layout(constraints.constrainWidth(288), constraints.constrainHeight(192)) {
                                child.place(origin.x.toInt(), origin.y.toInt())
                            }
                        }
                    }
                }
            } }
            compose.waitForIdle()
            lateinit var original: NativeFloatContextGeometry
            lateinit var binding: NativeFlowBinding
            var stableOwner: Any? = null
            fun verify(label: String) {
                lateinit var bounds: android.graphics.RectF
                compose.runOnIdle {
                    val geometry = checkNotNull(input?.geometry)
                    assertEquals(label, geometry.text)
                    assertEquals(0, usedWidth); assertEquals(0, usedHeight)
                    assertEquals(0, geometry.width); assertEquals(0, geometry.height)
                    assertTrue(geometry.extents.ink!!.width > 0f)
                    bounds = android.graphics.RectF(geometry.nodes.single().bounds.first()).apply {
                        offset(origin.x + .375f, origin.y)
                    }
                    assertEquals(1, created); assertEquals(0, disposed)
                }
                val pixels = compose.onNodeWithTag("nested-context-root").captureToImage().toPixelMap()
                var ink = 0
                for (y in 0 until pixels.height) for (x in 0 until pixels.width) {
                    val color = pixels[x, y]
                    if (label == "old" && color.red > .95f && color.green < .05f && color.blue < .05f ||
                        label == "new" && color.blue > .95f && color.green < .05f && color.red < .05f) ink++
                }
                assertTrue("Nested overflow ink must remain painted", ink > 20)
                compose.onNodeWithTag("nested-context-root").performTouchInput {
                    click(Offset(bounds.centerX(), bounds.centerY()))
                }
                compose.waitForIdle()
                compose.runOnIdle { assertEquals(label, actions.last()) }
            }
            verify("old")
            compose.runOnIdle {
                original = checkNotNull(input?.geometry)
                binding = checkNotNull(input?.measurement?.value).binding
                stableOwner = owner
                revision.value = true
            }
            compose.waitForIdle()
            verify("new")
            compose.runOnIdle {
                assertNotSame(original, input?.geometry)
                assertSame(binding, checkNotNull(input?.measurement?.value).binding)
                assertSame(stableOwner, owner)
                assertEquals(listOf("old", "new"), actions)
            }
        } finally {
            compose.activityRule.scenario.onActivity { it.setContent {} }
            compose.waitForIdle()
        }
        assertEquals(1, disposed)
        assertNull(input?.geometry)
    }

    @Test fun aRealPaddingBarrierChangesTheSameChildMarginRequestPaintAndActionCoordinates() {
        val barrier = mutableStateOf(false)
        var input: NativeContextMeasureInput? = null
        var owner: Any? = null
        var created = 0
        var disposed = 0
        var actions = 0
        try {
            compose.activityRule.scenario.onActivity { activity -> activity.setContent {
                MaterialTheme {
                    CompositionLocalProvider(LocalDensity provides Density(1f, 1f)) {
                        Layout(modifier = Modifier.testTag("adjoining-root").background(Color.White), content = {
                            val currentPadding = if (barrier.value) 1f else 0f
                            val part = NativeFloatContextSpec.Container(10, { _, _ -> 200 }, { _, _ -> 200 },
                                margins = { FloatMargins(10f, 0f, 0f, 0f) },
                                padding = { FloatMargins(currentPadding, 0f, 0f, 0f) },
                                innerMargins = NativeAdjoiningMargins(20f, 0f, false)) {
                                val stable = remember { Any() }
                                DisposableEffect(stable) { created++; onDispose { disposed++ } }
                                val current = checkNotNull(LocalNativeContextMeasureInput.current)
                                SideEffect { input = current; owner = stable }
                                val paint = android.text.TextPaint(android.graphics.Paint.ANTI_ALIAS_FLAG).apply {
                                    textSize = 28f; color = android.graphics.Color.BLACK
                                }
                                val label = "Margin"
                                val nodes: (FloatTextGeometry) -> List<FloatInteractionNode> = { geometry -> listOf(
                                    FloatInteractionNode(0, FloatInteractionKind.LINK, 0, label.length,
                                        geometry.rectsForRange(0, label.length), label, null, { actions++ })) }
                                val prepared = PreparedNativeFloatText(label, null, Any(),
                                    geometry = { width, carried, _ -> NativeFloatGeometry.build(android.text.SpannableString(label),
                                        paint, width, emptyList(), carriedExclusions = carried, nodeFactory = nodes) },
                                    menu = {}, native = NativePreparedText(paint, { android.text.SpannableString(label) }, nodes,
                                        android.text.TextDirectionHeuristics.LTR), fallback = { error("Real margin text must remain supported") })
                                val box = ParagraphBox(ParagraphEdges(top = 20f), ParagraphEdges(), 20f, 0f)
                                NativeFloatContextLayout(listOf(NativeFloatContextSpec.Text(prepared, 0f, box = box)),
                                    Modifier, Color.Magenta) { _, _ -> error("No atomic child") }
                            }
                            NativeFloatContextLayout(listOf(part), Modifier, Color.Magenta, adjoining = true) { _, _ -> error("No atomic child") }
                        }) { measurables, constraints ->
                            val child = measurables.single().measure(Constraints(minWidth = 300, maxWidth = 300))
                            layout(constraints.constrainWidth(300), constraints.constrainHeight(200)) { child.place(0, 0) }
                        }
                    }
                }
            } }
            compose.waitForIdle()
            lateinit var firstRequest: NativeFlowMeasureRequest
            lateinit var firstBounds: android.graphics.RectF
            var firstOwner: Any? = null
            fun assertPaintAndClick(originY: Float) {
                val image = compose.onNodeWithTag("adjoining-root").captureToImage().toPixelMap()
                var ink = 0
                for (y in 0 until image.height) for (x in 0 until image.width) {
                    val color = image[x, y]
                    if (color.red < .2f && color.green < .2f && color.blue < .2f) ink++
                }
                assertTrue("Actual native glyphs remain on the composed surface", ink > 20)
                lateinit var rect: android.graphics.RectF
                compose.runOnIdle { rect = android.graphics.RectF(checkNotNull(input?.geometry).nodes.single().bounds.first()) }
                compose.onNodeWithTag("adjoining-root").performTouchInput { click(Offset(rect.centerX(), rect.centerY() + originY)) }
                compose.waitForIdle()
            }
            compose.runOnIdle {
                firstRequest = checkNotNull(input?.measurement?.value)
                assertEquals(NativeMarginCollapse(true, true), firstRequest.policy.marginCollapse)
                firstBounds = android.graphics.RectF(checkNotNull(input?.geometry).nodes.single().bounds.first())
                firstOwner = owner
                assertEquals(1, created)
            }
            assertPaintAndClick(20f)
            compose.runOnIdle { assertEquals(1, actions); barrier.value = true }
            compose.waitForIdle()
            compose.runOnIdle {
                val request = checkNotNull(input?.measurement?.value)
                assertEquals(NativeMarginCollapse(false, true), request.policy.marginCollapse)
                assertNull(input?.ready(firstRequest))
                val bounds = checkNotNull(input?.geometry).nodes.single().bounds.first()
                assertEquals(firstBounds.top + 20f, bounds.top, .01f)
                assertSame(firstOwner, owner)
                assertEquals(1, created)
                assertEquals(0, disposed)
            }
            assertPaintAndClick(11f)
            compose.runOnIdle { assertEquals(2, actions) }
        } finally {
            compose.activityRule.scenario.onActivity { it.setContent {} }
            compose.waitForIdle()
        }
        assertEquals(1, disposed)
    }
    @Test fun preparedOrdinaryClearanceKeepsTheActualFloatOwnerAndMeasuresTextAtFinalOrigins() {
        val clearing = mutableStateOf(false)
        val input = NativeContextMeasureInput()
        var created = 0
        var disposed = 0
        var owner: Any? = null
        var actions = 0
        try {
            compose.activityRule.scenario.onActivity { activity -> activity.setContent {
                MaterialTheme {
                    CompositionLocalProvider(LocalDensity provides Density(1f, 1f)) {
                        val direction = androidx.compose.ui.platform.LocalLayoutDirection.current
                        val window = androidx.compose.ui.platform.LocalWindowInfo.current.containerSize
                        val environment = NativeFlowEnvironment(1f, 1f, direction, window)
                        val policyOwner = remember { Any() }
                        Layout(modifier = Modifier.testTag("prepared-ordinary-root").background(Color.White), content = {
                            CompositionLocalProvider(LocalNativeContextMeasureInput provides input) {
                                val paint = android.text.TextPaint(android.graphics.Paint.ANTI_ALIAS_FLAG).apply {
                                    textSize = 28f; color = android.graphics.Color.RED
                                }
                                val label = "Body"
                                fun source() = android.text.SpannableString(label).apply {
                                    setSpan(NativeRunLineMetrics(NativePrimaryFontMetrics.from(paint),
                                        NativeLineHeightPolicy.Pixels(10f), strut = true), 0, length,
                                        android.text.Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
                                }
                                val nodes: (FloatTextGeometry) -> List<FloatInteractionNode> = { geometry -> listOf(
                                    FloatInteractionNode(0, FloatInteractionKind.LINK, 0, label.length,
                                        geometry.rectsForRange(0, label.length), label, null, { actions++ })) }
                                val prepared = PreparedNativeFloatText(label, null, Any(),
                                    geometry = { width, carried, _ -> NativeFloatGeometry.build(source(), paint,
                                        width, emptyList(), carriedExclusions = carried, nodeFactory = nodes) },
                                    menu = {}, native = NativePreparedText(paint, { source() }, nodes,
                                        android.text.TextDirectionHeuristics.LTR), fallback = { error("Prepared body unavailable") })
                                val body = NativeFloatContextSpec.Container(12, { _, _ -> 200 }, { w, _ -> w },
                                    margins = { FloatMargins(20f, 0f, 0f, 0f) },
                                    clear = if (clearing.value) FigureClear.Left else FigureClear.None,
                                    preparedParts = listOf(NativeFloatContextSpec.Text(prepared, 0f))) {
                                    error("Prepared body must retain its existing leaf slots")
                                }
                                val parent = NativeFloatContextSpec.Container(10, { _, _ -> 200 }, { w, _ -> w },
                                    margins = { FloatMargins(10f, 0f, 0f, 0f) }, preparedParts = listOf(
                                        NativeFloatContextSpec.Child(11, { 20 }, 0f, floatSide = TableFloatSide.Left), body)) {
                                    error("Ordinary grouping must not compose an alternate subtree")
                                }
                                NativeFloatContextLayout(listOf(parent), Modifier, Color.Magenta, adjoining = true) { id, _ ->
                                    assertEquals(11, id)
                                    val stable = remember { Any() }
                                    DisposableEffect(stable) { created++; onDispose { disposed++ } }
                                    SideEffect { owner = stable }
                                    Layout(modifier = Modifier.background(Color.Blue), content = {}) { _, constraints ->
                                        layout(constraints.constrainWidth(20), constraints.constrainHeight(50)) { }
                                    }
                                }
                            }
                        }) { measurables, constraints ->
                            val childConstraints = Constraints(minWidth = 200, maxWidth = 200)
                            input.request(constraints, childConstraints, environment,
                                NativeFlowParentPolicy(policyOwner, true, null, 0f, NativeMarginCollapse(false, false)), emptyList())
                            val child = measurables.single().measure(childConstraints)
                            layout(constraints.constrainWidth(240), constraints.constrainHeight(140)) { child.place(0, 0) }
                        }
                    }
                }
            } }
            compose.waitForIdle()
            var stable: Any? = null
            var previous: NativeFloatContextGeometry? = null
            for (cleared in listOf(false, true)) {
                if (cleared) {
                    compose.runOnIdle { clearing.value = true }
                    compose.waitForIdle()
                }
                lateinit var action: android.graphics.RectF
                compose.runOnIdle {
                    val geometry = checkNotNull(input.geometry)
                    assertEquals(if (cleared) 10f else 20f, geometry.ordinaryBounds.getValue(10).top, 0f)
                    assertEquals(if (cleared) 60f else 10f, geometry.ordinaryBounds.getValue(10).height(), 0f)
                    assertEquals(if (cleared) 10f else 20f, geometry.ownExclusions.single().outer.top, 0f)
                    assertEquals(if (cleared) 60f else 70f, geometry.ownExclusions.single().outer.bottom, 0f)
                    assertEquals(if (cleared) 60f else 20f, geometry.ordinaryBounds.getValue(12).top, 0f)
                    if (cleared) {
                        assertEquals(30f, geometry.clearanceById.getValue(12), 0f)
                        assertSame(stable, owner)
                        assertNotSame(previous, geometry)
                    } else { stable = owner; previous = geometry }
                    assertEquals(1, created); assertEquals(0, disposed)
                    action = android.graphics.RectF(geometry.nodes.single().bounds.first())
                }
                val pixels = compose.onNodeWithTag("prepared-ordinary-root").captureToImage().toPixelMap()
                var red = 0
                var blue = 0
                for (y in 0 until pixels.height) for (x in 0 until pixels.width) {
                    val color = pixels[x, y]
                    if (color.red > .95f && color.green < .05f && color.blue < .05f) red++
                    if (color.blue > .95f && color.green < .05f && color.red < .05f) blue++
                }
                assertTrue("Real text remains painted", red > 20)
                assertTrue("The same real float remains painted", blue > 400)
                compose.onNodeWithTag("prepared-ordinary-root").performTouchInput {
                    click(Offset(action.centerX(), action.centerY()))
                }
                compose.waitForIdle()
                compose.runOnIdle { assertEquals(if (cleared) 2 else 1, actions) }
            }
        } finally {
            compose.activityRule.scenario.onActivity { it.setContent {} }
            compose.waitForIdle()
        }
        assertEquals(1, disposed)
        assertNull(input.geometry)
    }

    @Test fun responsiveFormattingKeepsRealRichAndFloatOwnersWhileChangingIsolationRequests() {
        val state = mutableStateOf(0)
        val parentInput = NativeContextMeasureInput()
        var flowInput: NativeFlowMeasureInput? = null
        var flowOwner: Any? = null
        var floatOwner: Any? = null
        var created = 0
        var disposed = 0
        val actions = mutableListOf<EntryLink>()
        try {
            compose.activityRule.scenario.onActivity { activity -> activity.setContent {
                MaterialTheme(colorScheme = androidx.compose.material3.lightColorScheme(primary = Color.Red)) {
                    CompositionLocalProvider(LocalDensity provides Density(1f, 1f)) {
                        val environment = NativeFlowEnvironment(1f, 1f,
                            androidx.compose.ui.platform.LocalLayoutDirection.current,
                            androidx.compose.ui.platform.LocalWindowInfo.current.containerSize)
                        val policyOwner = remember { Any() }
                        Layout(modifier = Modifier.testTag("prepared-formatting-root").background(Color.White), content = {
                            CompositionLocalProvider(LocalNativeContextMeasureInput provides parentInput) {
                                val block = Block("paragraph", 0, emptyList(), flow = listOf(FlowPart.Inline(
                                    listOf(Span("link", "Link", "same-action")))))
                                val flow = NativeFloatContextSpec.Flow(12, 0f, null, null, false) { carried, sink ->
                                    val stable = remember { Any() }
                                    val input = checkNotNull(LocalNativeFlowMeasureInput.current)
                                    DisposableEffect(stable) { created++; onDispose { disposed++ } }
                                    SideEffect { flowOwner = stable; flowInput = input }
                                    AnonymousBlockView(block, Modifier, { actions += it }, emptyList(),
                                        AppSettings(allowImages = false, allowAudio = false), "",
                                        style = TextStyle(fontSize = 28.sp), interactionOwner = false,
                                        carriedExclusions = carried, onFlowGeometry = sink)
                                }
                                val group = NativeFloatContextSpec.Container(10, { _, _ -> 160 }, { _, _ -> 160 },
                                    floatSide = if (state.value == 1) TableFloatSide.Left else null,
                                    isolatesFloats = state.value == 2,
                                    preparedParts = listOf(NativeFloatContextSpec.Child(11, { 24 }, 0f,
                                        floatSide = TableFloatSide.Left), flow)) {
                                    error("Responsive formatting must not replace its prepared child subtree")
                                }
                                NativeFloatContextLayout(listOf(NativeFloatContextSpec.Child(1, { 40 }, 0f,
                                    floatSide = TableFloatSide.Right), group), Modifier, Color.Red, adjoining = true) { id, _ ->
                                    if (id == 11) {
                                        val stable = remember { Any() }
                                        DisposableEffect(stable) { created++; onDispose { disposed++ } }
                                        SideEffect { floatOwner = stable }
                                    }
                                    Layout(modifier = Modifier.background(if (id == 11) Color.Blue else Color.Gray), content = {}) { _, constraints ->
                                        layout(constraints.maxWidth, if (id == 11) 80 else 100) { }
                                    }
                                }
                            }
                        }) { measurables, constraints ->
                            val actual = Constraints(minWidth = 240, maxWidth = 240)
                            parentInput.request(constraints, actual, environment,
                                NativeFlowParentPolicy(policyOwner, true, null, 0f, NativeMarginCollapse(false, false)), emptyList())
                            val child = measurables.single().measure(actual)
                            layout(constraints.constrainWidth(280), constraints.constrainHeight(160)) { child.place(0, 0) }
                        }
                    }
                }
            } }
            var oldRequest: NativeFlowMeasureRequest? = null
            var originalFlow: Any? = null
            var originalFloat: Any? = null
            for ((iteration, mode) in listOf(0, 1, 2, 0).withIndex()) {
                compose.runOnIdle { state.value = mode }
                compose.waitForIdle()
                lateinit var action: android.graphics.RectF
                compose.runOnIdle {
                    val input = checkNotNull(flowInput)
                    val current = checkNotNull(input.measurement.value)
                    val boundary = current.policy.owners.single()
                    assertEquals(10, boundary.id)
                    assertEquals(160, boundary.contentWidth)
                    assertEquals(if (mode == 1) TableFloatSide.Left else null, boundary.floatSide)
                    assertEquals(mode == 2, boundary.isolatesFloats)
                    assertEquals(mode != 0, current.policy.containAtEnd)
                    assertEquals(if (mode == 0) 2 else 1, current.exclusions.size)
                    if (iteration == 0) { originalFlow = flowOwner; originalFloat = floatOwner }
                    else {
                        assertSame(originalFlow, flowOwner)
                        assertSame(originalFloat, floatOwner)
                        assertNull(input.ready(checkNotNull(oldRequest)))
                    }
                    assertEquals(2, created); assertEquals(0, disposed)
                    oldRequest = current
                    val geometry = checkNotNull(parentInput.geometry)
                    assertEquals(if (mode == 2) 1 else 2, geometry.ownExclusions.size)
                    assertTrue(geometry.flowChildren.any { it.id == 12 })
                    assertFalse(geometry.flowChildren.any { it.id == 10 })
                    action = android.graphics.RectF(geometry.nodes.single { it.onClick != null }.bounds.first())
                }
                val pixels = compose.onNodeWithTag("prepared-formatting-root").captureToImage().toPixelMap()
                var red = 0
                var blue = 0
                for (y in 0 until pixels.height) for (x in 0 until pixels.width) {
                    val color = pixels[x, y]
                    if (color.red > .95f && color.green < .05f && color.blue < .05f) red++
                    if (color.blue > .95f && color.green < .05f && color.red < .05f) blue++
                }
                assertTrue("The real rich child's native text remains painted", red > 20)
                assertTrue("The same actual float remains painted", blue > 400)
                compose.onNodeWithTag("prepared-formatting-root").performTouchInput {
                    click(Offset(action.centerX(), action.centerY()))
                }
                compose.waitForIdle()
                compose.runOnIdle {
                    assertEquals(iteration + 1, actions.size)
                    assertEquals("same-action", actions.last().target)
                }
            }
        } finally {
            compose.activityRule.scenario.onActivity { it.setContent {} }
            compose.waitForIdle()
        }
        assertEquals(2, disposed)
        assertNull(parentInput.geometry)
        assertNull(flowInput?.geometry)
    }

    @Test fun realPreparedFlexItemsUseResolvedWidthsAndKeepTheirOwnersWhenReturningToFlow() {
        val available = mutableStateOf(140)
        val row = mutableStateOf(true)
        val parentInput = NativeContextMeasureInput()
        val inputs = mutableMapOf<Int, NativeFlowMeasureInput>()
        val owners = mutableMapOf<Int, Any>()
        val actions = mutableListOf<EntryLink>()
        var created = 0
        var disposed = 0
        try {
            compose.activityRule.scenario.onActivity { activity -> activity.setContent {
                MaterialTheme(colorScheme = androidx.compose.material3.lightColorScheme(primary = Color.Red)) {
                    CompositionLocalProvider(LocalDensity provides Density(1f, 1f)) {
                        val environment = NativeFlowEnvironment(1f, 1f,
                            androidx.compose.ui.platform.LocalLayoutDirection.current,
                            androidx.compose.ui.platform.LocalWindowInfo.current.containerSize)
                        val policyOwner = remember { Any() }
                        Layout(modifier = Modifier.testTag("prepared-flex-root").background(Color.White), content = {
                            CompositionLocalProvider(LocalNativeContextMeasureInput provides parentInput) {
                                fun item(id: Int, label: String, width: Float, font: Float): NativeFloatContextSpec.Container {
                                    val fixed = StyleLength(StyleLengthUnit.Px, 5f)
                                    val zero = StyleLength(StyleLengthUnit.Px, 0f)
                                    val style = ContainerStyle(width = ContainerWidth.Length(StyleWidth(StyleWidthUnit.Px, width)),
                                        margins = StyleEdges(zero, fixed, zero, fixed)).atViewport(240f)
                                    val block = Block("paragraph", 0, emptyList(), flow = listOf(FlowPart.Inline(
                                        listOf(Span("link", label, label)))))
                                    val flow = NativeFloatContextSpec.Flow(id + 1, 0f, null, null, false) { carried, sink ->
                                        val owner = remember { Any() }
                                        val input = checkNotNull(LocalNativeFlowMeasureInput.current)
                                        DisposableEffect(owner) { created++; onDispose { disposed++ } }
                                        SideEffect { inputs[id] = input; owners[id] = owner }
                                        AnonymousBlockView(block, Modifier, { actions += it }, emptyList(),
                                            AppSettings(allowImages = false, allowAudio = false), "",
                                            style = TextStyle(fontSize = font.sp), interactionOwner = false,
                                            carriedExclusions = carried, onFlowGeometry = sink)
                                    }
                                    return NativeFloatContextSpec.Container(id,
                                        { containing, intrinsic -> containerBoxWidth(style, containing.toFloat(), intrinsic, 1f, 16f).content.toInt() },
                                        { childWidth, maximum -> kotlin.math.ceil(containerFlexIntrinsicContribution(style,
                                            ContainerWidths(childWidth.toFloat(), childWidth.toFloat()), 1f, 16f, maximum)).toInt() },
                                        margins = { FloatMargins(0f, 5f, 0f, 5f) },
                                        floatSide = if (row.value && id == 20) TableFloatSide.Right else null,
                                        clear = if (row.value && id == 20) FigureClear.Both else null,
                                        preparedParts = listOf(flow),
                                        horizontal = { containing, intrinsic -> NativeContainerHorizontal.from(
                                            containerBoxWidth(style, containing.toFloat(), intrinsic, 1f, 16f), 0f, 5f, 5f) },
                                        flex = NativeFlexItemSpec(
                                            { containing, intrinsic -> containerFlexMeasure(style, containing.toFloat(), intrinsic, 1f, 16f) },
                                            { intrinsic, maximum -> containerFlexIntrinsicContribution(style, intrinsic, 1f, 16f, maximum) })) {
                                        error("A flex item must keep its real prepared leaf")
                                    }
                                }
                                val group = NativeFloatContextSpec.Container(100, { containing, _ -> containing }, { w, _ -> w },
                                    preparedParts = listOf(item(10, "One", 80f, 24f), item(20, "Two", 120f, 32f)),
                                    row = if (row.value) NativeFlexRowPolicy(ContainerAlignItems.Center) else null) {
                                    error("The row must not compose a replacement subtree")
                                }
                                NativeFloatContextLayout(listOf(group), Modifier, Color.Red, adjoining = true) { _, _ ->
                                    error("No atomic child")
                                }
                            }
                        }) { measurables, constraints ->
                            val actual = Constraints(minWidth = available.value, maxWidth = available.value)
                            parentInput.request(constraints, actual, environment,
                                NativeFlowParentPolicy(policyOwner, true, null, 0f, NativeMarginCollapse(false, false)), emptyList())
                            val child = measurables.single().measure(actual)
                            layout(constraints.constrainWidth(260), constraints.constrainHeight(180)) { child.place(0, 0) }
                        }
                    }
                }
            } }
            val stableOwners = mutableMapOf<Int, Any>()
            val oldRequests = mutableMapOf<Int, NativeFlowMeasureRequest>()
            for ((iteration, setting) in listOf(140 to true, 220 to true, 140 to false, 140 to true).withIndex()) {
                compose.runOnIdle { available.value = setting.first; row.value = setting.second }
                compose.waitForIdle()
                lateinit var bounds: List<android.graphics.RectF>
                compose.runOnIdle {
                    val geometry = checkNotNull(parentInput.geometry)
                    val first = geometry.ordinaryBounds.getValue(10)
                    val second = geometry.ordinaryBounds.getValue(20)
                    if (setting.second) {
                        assertEquals(if (setting.first == 140) 48f else 80f, first.width(), .01f)
                        assertEquals(if (setting.first == 140) 72f else 120f, second.width(), .01f)
                        assertEquals(5f, first.left, .01f)
                        assertEquals(first.right + 10f, second.left, .01f)
                        assertTrue("Smaller real line box is vertically centered", first.top > second.top)
                    } else {
                        assertEquals(80f, first.width(), .01f)
                        assertEquals(120f, second.width(), .01f)
                        assertEquals(5f, first.left, .01f); assertEquals(5f, second.left, .01f)
                        assertTrue(second.top >= first.bottom)
                    }
                    assertTrue("Flex-item float/clear do not escape into the row", geometry.ownExclusions.isEmpty())
                    for (id in listOf(10, 20)) {
                        val input = inputs.getValue(id)
                        val request = checkNotNull(input.measurement.value)
                        assertEquals(listOf(100, id), request.policy.owners.map { it.id })
                        assertEquals(setting.second, request.policy.owners.last().isolatesFloats)
                        assertNull(request.policy.owners.last().floatSide)
                        assertEquals(setting.second, request.policy.owners.first().row != null)
                        if (iteration == 0) stableOwners[id] = owners.getValue(id)
                        else { assertSame(stableOwners[id], owners[id]); assertNull(input.ready(oldRequests.getValue(id))) }
                        oldRequests[id] = request
                    }
                    assertEquals(2, created); assertEquals(0, disposed)
                    bounds = geometry.nodes.filter { it.onClick != null }.map { android.graphics.RectF(it.bounds.first()) }
                    assertEquals(2, bounds.size)
                }
                val pixels = compose.onNodeWithTag("prepared-flex-root").captureToImage().toPixelMap()
                var ink = 0
                for (y in 0 until pixels.height) for (x in 0 until pixels.width) {
                    val color = pixels[x, y]
                    if (color.red > .95f && color.green < .05f && color.blue < .05f) ink++
                }
                assertTrue("Both existing native rich children remain painted", ink > 40)
                for (rect in bounds) {
                    compose.onNodeWithTag("prepared-flex-root").performTouchInput { click(Offset(rect.centerX(), rect.centerY())) }
                    compose.waitForIdle()
                }
                compose.runOnIdle {
                    assertEquals((iteration + 1) * 2, actions.size)
                    assertEquals(listOf("One", "Two"), actions.takeLast(2).map { it.target })
                }
            }
        } finally {
            compose.activityRule.scenario.onActivity { it.setContent {} }
            compose.waitForIdle()
        }
        assertEquals(2, disposed)
        assertNull(parentInput.geometry)
        assertTrue(inputs.values.all { it.geometry == null })
    }
}
