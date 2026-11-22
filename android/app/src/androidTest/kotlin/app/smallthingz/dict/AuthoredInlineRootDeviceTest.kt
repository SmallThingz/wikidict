package app.smallthingz.dict

import android.os.Bundle
import android.os.SystemClock
import android.graphics.RectF
import android.text.SpannableString
import android.text.Spanned
import android.text.TextPaint
import android.view.InputDevice
import android.view.MotionEvent
import android.view.PointerIcon
import android.view.View
import android.view.accessibility.AccessibilityNodeInfo
import androidx.activity.compose.setContent
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.layout.Layout
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalLayoutDirection
import androidx.compose.ui.platform.LocalWindowInfo
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.click
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performTouchInput
import androidx.compose.ui.test.performSemanticsAction
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.TextLayoutResult
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.constrainHeight
import androidx.compose.ui.unit.constrainWidth
import androidx.compose.ui.unit.sp
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/** The ordinary StyledText root, without a Container or caption forcing native enrollment. */
@RunWith(AndroidJUnit4::class)
class AuthoredInlineRootDeviceTest {
    @get:Rule val compose = createPhysicalComposeRule()
    private val density = Density(1.25f, 1.2f)
    private val style = TextStyle(fontSize = 20.sp, lineHeight = 20.sp, fontFamily = FontFamily.Monospace)
    private var reported: NativeFloatContextGeometry? = null
    private fun computed(value: Float, basis: FontScaleBasis = FontScaleBasis.CssPx) =
        InlineLineHeight.Computed(InlineComputedLength(value, basis))

    @Composable private fun Root(spans: List<Span>, actions: MutableList<EntryLink>, textZoom: Float = 1f,
        headingActions: List<NativeHeadingAction> = emptyList(), lineHeightPolicy: NativeLineHeightPolicy? = null) {
        MaterialTheme(typography = MaterialTheme.typography.copy(bodyLarge = style)) {
            CompositionLocalProvider(LocalDensity provides density, LocalCssPixelTextZoom provides textZoom) {
                val parent = remember { NativeLayoutInput(Unit) }
                val input = remember { NativeContextMeasureInput(invalidateParent = parent::invalidate) }
                val environment = NativeFlowEnvironment(density.density, density.fontScale,
                    LocalLayoutDirection.current, LocalWindowInfo.current.containerSize)
                val preparation = Any()
                Layout(modifier = Modifier.testTag("authored-inline-root").then(parent.modifier), content = {
                    CompositionLocalProvider(LocalNativeContextMeasureInput provides input) {
                        if (headingActions.isEmpty() && lineHeightPolicy == null) StyledText(spans, style = style, onLink = { actions += it })
                        else {
                            val prepared = prepareNativeFloatText(spans,
                                styledTextAnnotation(spans, null, style) { actions += it }, egyptianTextRuns(spans),
                                style, MaterialTheme.colorScheme.primary, emptyList(), AppSettings(),
                                "", { actions += it }, heading = headingActions.isNotEmpty(),
                                headingActions = headingActions, nativeLineHeight = lineHeightPolicy)
                            NativeFloatContextLayout(listOf(NativeFloatContextSpec.Text(prepared, 0f)),
                                Modifier, MaterialTheme.colorScheme.primary) { _, _ -> error("No delegated heading child") }
                        }
                    }
                }) { children, constraints ->
                    val childConstraints = Constraints(maxWidth = 190, maxHeight = 620)
                    val request = input.request(constraints, childConstraints, environment,
                        NativeFlowParentPolicy(preparation, true, null, 0f), emptyList())
                    val child = children.single().measure(childConstraints)
                    reported = input.ready(request)
                    layout(constraints.constrainWidth(230), constraints.constrainHeight(child.height + 24)) {
                        child.place(12, 12)
                    }
                }
            }
        }
    }

    private fun views(): List<NativeFloatTextView> {
        val result = mutableListOf<NativeFloatTextView>()
        compose.activityRule.scenario.onActivity { activity ->
            fun collect(view: View) {
                if (view is NativeFloatTextView) result += view
                if (view is android.view.ViewGroup) for (index in 0 until view.childCount) collect(view.getChildAt(index))
            }
            collect(activity.window.decorView)
        }
        return result
    }
    private fun rootGeometry(): FloatTextGeometry = checkNotNull(views().single().currentMeasuredGeometry)
    private fun paragraph(): NativeFloatGeometry =
        checkNotNull(reported).inputLeaves().single().geometry as NativeFloatGeometry
    private fun source(): Spanned = paragraph().text as Spanned
    private fun metricRanges(): List<NativeInlineRange<NativeAuthoredInlineMetrics>> =
        nativeInlineRanges(source(), NativeAuthoredInlineMetrics::class.java)
    private fun signature(geometry: FloatTextGeometry): List<List<String>> = geometry.nodes.map {
        listOf(it.kind.name, it.start.toString(), it.end.toString(), it.label?.toString().orEmpty(),
            (it.onClick != null).toString())
    }
    private fun tap(label: String) {
        val view = views().single()
        compose.runOnIdle {
            val node = checkNotNull(view.currentMeasuredGeometry).nodes.single { it.label == label && it.onClick != null }
            val bounds = node.bounds.first { !it.isEmpty }
            val now = SystemClock.uptimeMillis()
            val down = MotionEvent.obtain(now, now, MotionEvent.ACTION_DOWN,
                bounds.centerX() + view.paddingLeft, bounds.centerY() + view.paddingTop, 0)
            val up = MotionEvent.obtain(now, now + 1, MotionEvent.ACTION_UP,
                bounds.centerX() + view.paddingLeft, bounds.centerY() + view.paddingTop, 0)
            try { assertTrue(view.dispatchTouchEvent(down)); assertTrue(view.dispatchTouchEvent(up)) }
            finally { down.recycle(); up.recycle() }
        }
        compose.waitForIdle()
    }
    private fun assertCopy(expected: String) {
        val view = views().single()
        compose.runOnIdle {
            val selection = Bundle().apply {
                putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_START_INT, 0)
                putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_END_INT, expected.length)
            }
            assertTrue(view.performAccessibilityAction(AccessibilityNodeInfo.ACTION_SET_SELECTION, selection))
            assertEquals(expected, view.selectedTextForCopy())
            assertTrue(view.performAccessibilityAction(AccessibilityNodeInfo.ACTION_SET_SELECTION, null))
        }
    }
    private fun control(body: () -> Unit) {
        try { body() }
        finally { compose.activityRule.scenario.onActivity { it.setContent {} }; compose.waitForIdle() }
    }

    @Test fun declaringSnapshotUsesOriginalBodyFontAndParticipatesOnEveryWrappedLine() = control {
        val text = "alpha beta gamma delta epsilon zeta"
        val snapshot = InlineFontSnapshot(fontScale = 1.75f, fontScaleBasis = FontScaleBasis.NormalBody,
            language = "th", fontFeatures = FontFeaturePolicy.Normal)
        val child = Span("link", text, target = "wrapped-target", small = true, superscript = true,
            bold = true, italic = true, language = "en", fontFeatures = FontFeaturePolicy.SevenOn,
            inlineStyle = InlineTextStyle(lineHeight = InlineLineHeight.FontRelative(1.4f, snapshot)))
        val actions = mutableListOf<EntryLink>()
        compose.activityRule.scenario.onActivity { it.setContent { Root(listOf(child), actions) } }
        compose.waitForIdle()
        val paragraph = paragraph()
        assertEquals(text, paragraph.text.toString())
        assertTrue(paragraph.shapedLineCount > 1)
        val ranges = metricRanges()
        assertEquals(1, ranges.size)
        assertEquals(0, ranges.single().start); assertEquals(text.length, ranges.single().end)
        val metric = ranges.single().value
        val declaring = checkNotNull(metric.declaringPrimary)
        val originalBodyPixels = with(density) { 20.sp.toPx() }
        assertEquals(originalBodyPixels * 1.75f, declaring.fontSize, .01f)
        assertEquals(originalBodyPixels * .8f, metric.primary.fontSize, .01f)
        assertEquals(0f, declaring.baselineShift, 0f)
        assertTrue(metric.primary.baselineShift < 0f)
        val wantedHeight = originalBodyPixels * 1.75f * 1.4f
        assertEquals(wantedHeight, (metric.policy as NativeLineHeightPolicy.Pixels).value, .01f)
        for (line in 0 until paragraph.shapedLineCount)
            assertTrue("Declaring owner must participate on wrapped line $line", paragraph.usedLineHeight(line) >= wantedHeight - .01f)
        assertCopy(text)
        tap(text)
        assertEquals(listOf("wrapped-target"), actions.map { it.target })
        // Compare with an ordinary source run using the declaring tuple, independently of the child.
        val owner = Span("text", "owner", fontScale = 1.75f, fontScaleBasis = FontScaleBasis.NormalBody,
            language = "th", fontFeatures = FontFeaturePolicy.Normal,
            inlineStyle = InlineTextStyle(lineHeight = computed(20f)))
        compose.activityRule.scenario.onActivity { it.setContent { Root(listOf(owner), actions) } }
        compose.waitForIdle()
        assertEquals(declaring, metricRanges().single().value.primary)
        // A zero authored line height must still retain the existing 48dp heading control.
        val heading = Span("text", "heading", inlineStyle = InlineTextStyle(lineHeight = computed(0f)))
        compose.activityRule.scenario.onActivity { it.setContent {
            Root(listOf(heading), actions, headingActions = listOf(NativeHeadingAction("fold", false) {}))
        } }
        compose.waitForIdle()
        assertEquals(0f, (metricRanges().single().value.policy as NativeLineHeightPolicy.Pixels).value, 0f)
        assertTrue(paragraph().usedLineHeight(0) >= 48f * density.density)
        assertEquals(1, rootGeometry().nodes.count { it.kind == FloatInteractionKind.CONTROL && it.label == "fold" })
    }

    @Test fun sevenEmptySupOwnersHaveNoCharactersNodesOrActionOffsetButKeepTheStrut() = control {
        val owners = (1..7).map { Span("text", "", direction = "rtl", superscript = true,
            inlineStyle = InlineTextStyle(lineHeight = computed(it * 8f))) }
        val link = Span("link", "open", target = "open-target", inlineStyle = InlineTextStyle(lineHeight = computed(20f)))
        val state = mutableStateOf(owners)
        val actions = mutableListOf<EntryLink>()
        compose.activityRule.scenario.onActivity { it.setContent { Root(state.value, actions) } }
        compose.waitForIdle()
        assertEquals("", rootGeometry().text.toString())
        assertTrue(rootGeometry().nodes.isEmpty())
        assertEquals(7, metricRanges().size)
        assertTrue(metricRanges().all { it.start == 0 && it.end == 0 })
        assertTrue(paragraph().height > 0)
        assertEquals(1, paragraph().shapedLineCount)
        compose.runOnIdle { state.value = owners + link }
        compose.waitForIdle()
        val withOwners = rootGeometry()
        assertEquals("open", withOwners.text.toString())
        assertEquals(7, metricRanges().count { it.start == 0 && it.end == 0 })
        assertEquals(listOf(0 to 4), nativeCaptionLinkRanges(owners + link).map { it.start to it.end })
        val nodeSignature = signature(withOwners)
        assertCopy("open")
        tap("open")
        compose.runOnIdle { state.value = listOf(link) }
        compose.waitForIdle()
        assertEquals(nodeSignature, signature(rootGeometry()))
        assertEquals("open", rootGeometry().text.toString())
        assertTrue(withOwners.height > rootGeometry().height)
        assertCopy("open")
        tap("open")
        assertEquals(listOf("open-target", "open-target"), actions.map { it.target })
    }

    @Test fun normalizedCssAndNormalBodyLengthsUseTheirOwnBasisExactlyOnce() = control {
        val zoom = mutableStateOf(1.1f)
        val css = Span("text", "css ", small = true, superscript = true,
            fontScale = 16f, fontScaleBasis = FontScaleBasis.CssPx,
            inlineStyle = InlineTextStyle(lineHeight = computed(32f),
                baselineShift = InlineComputedLength(2.25f, FontScaleBasis.CssPx), fontNormalized = true))
        val body = Span("link", "body", target = "body-target", subscript = true,
            fontScale = 1f, fontScaleBasis = FontScaleBasis.NormalBody,
            inlineStyle = InlineTextStyle(lineHeight = computed(.9f, FontScaleBasis.NormalBody),
                baselineShift = InlineComputedLength(0f, FontScaleBasis.NormalBody), fontNormalized = true))
        val actions = mutableListOf<EntryLink>()
        compose.activityRule.scenario.onActivity { it.setContent { Root(listOf(css, body), actions, zoom.value) } }
        for (value in listOf(1.1f, 1.35f)) {
            compose.runOnIdle { zoom.value = value }; compose.waitForIdle()
            val ranges = metricRanges().sortedBy { it.start }
            assertEquals(2, ranges.size)
            val first = ranges[0].value
            val second = ranges[1].value
            assertEquals(with(density) { (16f * value).sp.toPx() }, first.primary.fontSize, .01f)
            assertEquals(with(density) { (32f * value).sp.toPx() }, (first.policy as NativeLineHeightPolicy.Pixels).value, .01f)
            assertEquals(-with(density) { (2.25f * value).sp.toPx() }, first.primary.baselineShift, .01f)
            val bodyPixels = with(density) { 20.sp.toPx() }
            assertEquals(bodyPixels, second.primary.fontSize, .01f)
            assertEquals(bodyPixels * .9f, (second.policy as NativeLineHeightPolicy.Pixels).value, .01f)
            assertEquals(0f, second.primary.baselineShift, 0f)
            assertEquals("css body", rootGeometry().text.toString())
            assertCopy("css body")
        }
        tap("body")
        assertEquals(listOf("body-target"), actions.map { it.target })
    }

    @Test fun unsupportedStyledWhitespaceRetainsTheOriginalActionAndRecoversWithoutNativeRecursion() = control {
        val valid = Span("link", "action-endpoint", target = "retained-target", inlineStyle = InlineTextStyle(lineHeight = computed(28f)))
        val unsupported = Span("link", " \t", target = "whitespace-target", inlineStyle = InlineTextStyle(lineHeight = computed(20f)))
        val cursor = Span("text", " \t", trail = "!", inlineStyle = InlineTextStyle(lineHeight = computed(20f), cursor = InlineCursor.Help))
        val failing = mutableStateOf(0)
        val actions = mutableListOf<EntryLink>()
        fun tapFallbackAction() {
            val body = compose.onNodeWithText("action-endpoint", substring = true).assertIsDisplayed()
            val layouts = mutableListOf<TextLayoutResult>()
            body.performSemanticsAction(SemanticsActions.GetTextLayoutResult) { assertTrue(it(layouts)) }
            val layout = layouts.single()
            val actionStart = layout.layoutInput.text.text.indexOf("action-endpoint")
            assertTrue(actionStart >= 0)
            body.performTouchInput { click(layout.getBoundingBox(actionStart + 3).center) }
            compose.waitForIdle()
        }
        compose.activityRule.scenario.onActivity { it.setContent {
            Root(when (failing.value) {
                1 -> listOf(Span("text", "prefix "), unsupported, valid)
                2 -> listOf(Span("text", "prefix "), cursor, valid)
                else -> listOf(valid)
            }, actions)
        } }
        compose.waitForIdle(); tap("action-endpoint")
        for (kind in listOf(1, 2)) {
            compose.runOnIdle { failing.value = kind }; compose.waitForIdle()
            compose.onNodeWithText("Authored inline whitespace effects require a retained collapsed source owner", substring = true).assertIsDisplayed()
            tapFallbackAction()
            compose.runOnIdle { failing.value = 0 }; compose.waitForIdle()
            assertEquals("action-endpoint", rootGeometry().text.toString())
            assertCopy("action-endpoint"); tap("action-endpoint")
        }
        assertEquals("whitespace-target", unsupported.target)
        assertEquals(" \t", unsupported.text)
        assertEquals(" \t", cursor.text)
        assertEquals("!", cursor.trail)
        assertEquals(List(5) { "retained-target" }, actions.map { it.target })
        val inherited = mutableStateOf<NativeLineHeightPolicy>(NativeLineHeightPolicy.Normal)
        compose.activityRule.scenario.onActivity { it.setContent {
            Root(listOf(Span("text", "normal "), valid), actions, lineHeightPolicy = inherited.value)
        } }
        compose.waitForIdle()
        compose.onNodeWithText("Authored inline height with mixed native normal owners is unavailable", substring = true).assertIsDisplayed()
        tapFallbackAction()
        compose.runOnIdle { inherited.value = NativeLineHeightPolicy.Pixels(with(density) { 20.sp.toPx() }) }
        compose.waitForIdle()
        assertEquals("normal action-endpoint", rootGeometry().text.toString())
        assertCopy("normal action-endpoint"); tap("action-endpoint")
        assertEquals(List(7) { "retained-target" }, actions.map { it.target })
    }

    @Test fun helpCursorUsesActualMouseAndStylusRangeWithoutChangingTouchOrAccessibilityOwners() = control {
        val enabled = mutableStateOf(true)
        val actions = mutableListOf<EntryLink>()
        compose.activityRule.scenario.onActivity { it.setContent {
            val first = Span("text", "help ", inlineStyle = InlineTextStyle(lineHeight = computed(24f),
                cursor = InlineCursor.Help.takeIf { enabled.value }))
            Root(listOf(first, Span("link", "open", target = "pointer-target")), actions)
        } }
        compose.waitForIdle()
        val view = views().single()
        val geometry = rootGeometry()
        val bounds = checkNotNull(geometry.characterRects(0, 1).single())
        val pointX = bounds.centerX() + view.paddingLeft
        val pointY = bounds.centerY() + view.paddingTop
        val signature = signature(geometry)
        val help = PointerIcon.getSystemIcon(view.context, PointerIcon.TYPE_HELP)
        fun query(x: Float, y: Float, tool: Int, eventSource: Int): PointerIcon? {
            val properties = MotionEvent.PointerProperties().apply { id = 0; toolType = tool }
            val coordinates = MotionEvent.PointerCoords().apply { this.x = x; this.y = y }
            val now = SystemClock.uptimeMillis()
            val event = MotionEvent.obtain(now, now, MotionEvent.ACTION_HOVER_MOVE, 1, arrayOf(properties),
                arrayOf(coordinates), 0, 0, 1f, 1f, 0, 0, eventSource, 0)
            return try { view.onResolvePointerIcon(event, 0) } finally { event.recycle() }
        }
        compose.runOnIdle {
            assertEquals(help, query(pointX, pointY, MotionEvent.TOOL_TYPE_MOUSE, InputDevice.SOURCE_MOUSE))
            assertEquals(help, query(pointX, pointY, MotionEvent.TOOL_TYPE_STYLUS, InputDevice.SOURCE_STYLUS))
            assertNotEquals(help, query(pointX, pointY, MotionEvent.TOOL_TYPE_FINGER, InputDevice.SOURCE_TOUCHSCREEN))
            assertNotEquals(help, query(view.width - 1f, pointY, MotionEvent.TOOL_TYPE_MOUSE, InputDevice.SOURCE_MOUSE))
            assertEquals(1, geometry.nodes.count { it.onClick != null })
            val host = checkNotNull(view.accessibilityNodeProvider.createAccessibilityNodeInfo(View.NO_ID))
            try { assertEquals(geometry.nodes.size, host.childCount) } finally { host.recycle() }
        }
        assertCopy("help open"); tap("open")
        compose.runOnIdle { enabled.value = false }; compose.waitForIdle()
        assertEquals(signature, signature(rootGeometry()))
        compose.runOnIdle {
            assertNotEquals(help, query(pointX, pointY, MotionEvent.TOOL_TYPE_MOUSE, InputDevice.SOURCE_MOUSE))
        }
        assertEquals(listOf("pointer-target"), actions.map { it.target })
    }

    @Test fun cursorTranslationClippingAndCoveringOwnerRemainBoundToTheActualNativeRange() {
        val paint = TextPaint().apply { textSize = 20f }
        val spanned = SpannableString("help").apply {
            setSpan(NativeAuthoredCursor(InlineCursor.Help), 0, length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        }
        val text = NativeFloatGeometry.build(spanned, paint, 120, emptyList())
        val point = checkNotNull(text.characterRects(0, 1).single())
        val x = point.centerX(); val y = point.centerY()
        assertEquals(InlineCursor.Help, text.cursorAt(x, y))
        assertNull(text.cursorAt(119f, y))
        assertEquals(InlineCursor.Help, NoPaintGeometry(text).cursorAt(x, y))
        val edges = FigurePixelEdges(0f, 0f, 0f, 0f)
        val metrics = FigureBoxMetrics(FigurePixels(120f, 12f), edges, edges, edges, 0f, 0f)
        val figure = NativeFigureGeometry(metrics, text, FigurePaints(0, 0, 0, 0, 0), { _, _ -> }, { emptyList() })
        assertEquals(InlineCursor.Help, figure.cursorAt(x, y + metrics.captionTop))
        assertNull(figure.cursorAt(x, 5f))
        val group = NativeSemanticGroup(140, text.height + 30,
            listOf(PositionedSemanticChild(figure, -3f, 4f, BidiResolvedDirection.Ltr)))
        assertEquals(InlineCursor.Help, group.cursorAt(x - 3f, y + metrics.captionTop + 4f))
        val surface = NativeSurfaceGeometry(group)
        assertEquals(InlineCursor.Help, surface.cursorAt(x - 3f - surface.surface.left,
            y + metrics.captionTop + 4f - surface.surface.top))
        val plain = NativeFloatGeometry.build(SpannableString("plain"), paint, 120, emptyList())
        val covered = NativeSemanticGroup(120, text.height, listOf(
            PositionedSemanticChild(text, 0f, 0f, BidiResolvedDirection.Ltr),
            PositionedSemanticChild(plain, 0f, 0f, BidiResolvedDirection.Ltr)))
        assertNull(covered.cursorAt(x, y))
        val placement = NativeTableBlockPlacement(RectF(0f, 0f, 80f, 80f), RectF(5f, 7f, 60f, 70f),
            5f, 7f, -1f, text.width, text.height, 0, 0, 0f, 0f, 80, 80, null, { _, done -> done() })
        val viewport = NativeTableViewportGeometry(text, placement)
        assertEquals(InlineCursor.Help, viewport.cursorAt(x + 4f, y + 7f))
        assertNull(viewport.cursorAt(4.99f, y + 7f))
        assertNull(viewport.cursorAt(60f, y + 7f))
        assertEquals(text.text.toString(), viewport.text.toString())
        assertTrue(viewport.nodes.isEmpty())
        val blankPlacement = placement.copy(borderBox = RectF(0f, 0f, 120f, text.height.toFloat()),
            contentClip = RectF(0f, 0f, 120f, text.height.toFloat()), contentX = 0f, contentY = 0f,
            physicalScrollX = 0f, gridWidth = 0, gridHeight = 0, ownerWidth = 120, ownerHeight = text.height)
        val blankViewport = NativeTableViewportGeometry(EmptyCaptionGeometry(0), blankPlacement)
        assertTrue(blankViewport.containsInput(x, y))
        assertFalse(blankViewport.containsInteraction(x, y))
        val blankCover = NativeSemanticGroup(120, text.height, listOf(
            PositionedSemanticChild(text, 0f, 0f, BidiResolvedDirection.Ltr),
            PositionedSemanticChild(blankViewport, 0f, 0f, BidiResolvedDirection.Ltr)))
        assertNull(blankCover.cursorAt(x, y))
        val overlappingSource = SpannableString("helphelp\nx").apply {
            setSpan(NativeRunLineMetrics(NativePrimaryFontMetrics.from(paint), NativeLineHeightPolicy.Pixels(0f),
                strut = true), 0, length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
            setSpan(NativeAuthoredCursor(InlineCursor.Help), 0, 8, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        }
        val overlapping = NativeFloatGeometry.build(overlappingSource, paint, 200, emptyList())
        assertEquals(2, overlapping.shapedLineCount)
        val firstLine = overlapping.rectsForRange(0, 8).single()
        val laterLine = overlapping.rectsForRange(9, 10).single()
        val intersection = RectF(firstLine)
        assertTrue(intersection.intersect(laterLine))
        assertNull(overlapping.cursorAt(intersection.centerX(), intersection.centerY()))
        assertTrue(firstLine.right > laterLine.right + 2f)
        assertEquals(InlineCursor.Help, overlapping.cursorAt(laterLine.right + 2f, firstLine.centerY()))
    }

    @Test fun typedWrapKeepsExactTextRangesTrailsActionsAndRootGeometryThroughRecovery() = control {
        val normalText = "MMMMMMMMMMMMMMMMMMMM"
        val actionText = "WWWWWWWWWWWWWWWWWWWWWWWW"
        val normal = Span("text", normalText, inlineStyle = InlineTextStyle(wrap = TextWrap.Normal))
        val link = Span("link", actionText, "wrap-target", trail = "!", targetFragment = "part",
            inlineStyle = InlineTextStyle(wrap = TextWrap.BreakWord))
        val inputSpans = mutableStateOf(listOf(normal, Span("text", " before "), link, Span("text", " after")))
        val actions = mutableListOf<EntryLink>()
        compose.activityRule.scenario.onActivity { it.setContent { Root(inputSpans.value, actions) } }
        compose.waitForIdle()
        fun actionLabel(): String = inputSpans.value.single { it.target == "wrap-target" }.let {
            (if (it.direction == "rtl") "\u2067" else "") + it.text + it.trail +
                (if (it.direction == "rtl") "\u2069" else "")
        }
        fun checkRanges() {
            val geometry = paragraph()
            val raw = geometry.text.toString()
            val retained = nativeInlineRanges(source(), NativeAuthoredTextWrap::class.java)
            assertEquals(2, retained.size)
            for ((text, policy) in listOf(normalText to TextWrap.Normal, actionText to TextWrap.BreakWord)) {
                val marker = retained.single { it.value.wrap == policy }
                assertEquals(raw.indexOf(text), marker.start)
                assertEquals(marker.start + text.length, marker.end)
                assertEquals(text, raw.substring(marker.start, marker.end))
            }
            val a = raw.indexOf(normalText); val b = raw.indexOf(actionText)
            assertEquals(1, (a until a + normalText.length).map(geometry::baselineForOffset).distinct().size)
            assertTrue((b until b + actionText.length).map(geometry::baselineForOffset).distinct().size > 1)
            assertTrue(geometry.rectsForRange(a, a + normalText.length).single().width() > 190f)
            val node = rootGeometry().nodes.single { it.kind == FloatInteractionKind.LINK }
            assertEquals(actionLabel(), node.label?.toString())
            assertEquals(actionLabel(), rootGeometry().text.subSequence(node.start, node.end).toString())
            assertEquals(rootGeometry().text.toString().indexOf(actionLabel()), node.start)
            val view = views().single()
            compose.runOnIdle {
                val info = checkNotNull(view.accessibilityNodeProvider.createAccessibilityNodeInfo(node.id))
                try { assertEquals(actionLabel(), info.text.toString()); assertTrue(info.isClickable) }
                finally { info.recycle() }
            }
            assertCopy(raw)
        }
        checkRanges()
        tap(actionLabel())
        assertEquals(listOf(EntryLink("wrap-target", "part")), actions)
        // Reader direction controls and the external trail remain outside the authored text range.
        compose.runOnIdle { inputSpans.value = inputSpans.value.map { if (it === link) it.copy(direction = "rtl") else it } }
        compose.waitForIdle(); checkRanges()
        assertTrue(paragraph().text.toString().contains("!"))
        val beforeFailure = inputSpans.value
        compose.runOnIdle {
            inputSpans.value = listOf(Span("text", "MM"), normal.copy(text = "MMMM"), Span("text", "MM before "), link)
        }
        compose.waitForIdle()
        compose.onNodeWithText("Mixed normal wrap inside one unbreakable word is unavailable").assertIsDisplayed()
        compose.runOnIdle { inputSpans.value = beforeFailure }
        compose.waitForIdle(); checkRanges()
        tap(actionLabel())
        assertEquals(listOf(EntryLink("wrap-target", "part"), EntryLink("wrap-target", "part")), actions)
    }
}
