package app.smallthingz.dict

import android.graphics.Bitmap
import android.graphics.Canvas
import android.os.SystemClock
import android.text.Spanned
import android.text.TextPaint
import android.text.style.MetricAffectingSpan
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.PointerIcon
import android.view.View
import android.view.accessibility.AccessibilityNodeInfo
import androidx.activity.compose.setContent
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.layout.Layout
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.sp
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/** Actual prepared caption sources and the existing native Figure interaction owner; no media acquisition. */
@RunWith(AndroidJUnit4::class)
class FigureInlineStyleDeviceTest {
    @get:Rule val compose = createPhysicalComposeRule()
    private fun px(value: Float) = StyleLength(StyleLengthUnit.Px, value)
    private val settings = AppSettings(allowImages = false, allowAudio = false)
    private val textStyle = TextStyle(fontSize = 20.sp, fontFamily = FontFamily.Monospace)
    private val edges = FigureBorderEdges(FigureBorderEdge.None, FigureBorderEdge.None,
        FigureBorderEdge.None, FigureBorderEdge.None)
    private fun linkPolicy(): FigureLinkPaint = FigureLinkPaint(
        FigureLinkState("#3366cc", false), FigureLinkState("#3056a9", true), FigureLinkState("#233566", false),
        FigureLinkState("#6a60b0", false), FigureLinkState("#534fa3", true), FigureLinkState("#353262", false),
        underlineOnFocus = true, focusOutline = null)
    private fun figure(caption: List<Span>): Figure {
        val zero = StyleEdges(px(0f), px(0f), px(0f), px(0f))
        val zeroMargin = ContainerMargin.Length(SignedContainerMargin(StyleLengthUnit.Px, 0f))
        return Figure(FigureContent.Missing(Span("text", "media"), px(190f), px(20f)),
            FigureFormat.Framed, FigurePlacement.None, FigureClear.None, zero, zero, zero,
            1f, px(26f), FigureColor.Transparent, FigureBorder.None, FigureColor.Transparent, FigureBorder.None,
            FigureColor.NativeTheme, FigureColor.Transparent, caption = caption,
            tableCaptionLayout = TableCaptionLayout(TableCollapse.Collapse,
                ContainerStyle(marginValues = ContainerMargins(zeroMargin, ContainerMargin.Auto, zeroMargin, ContainerMargin.Auto)),
                edges, edges, FigureMediaLayout(FigureMediaStrut(1f, direction = BidiResolvedDirection.Ltr),
                    InlineBoxVerticalAlign.Baseline), captionLinkPaint = linkPolicy()))
    }
    private fun nativeView(): NativeFloatTextView {
        val found = mutableListOf<NativeFloatTextView>()
        compose.activityRule.scenario.onActivity { activity ->
            fun visit(view: View) {
                if (view is NativeFloatTextView) found += view
                if (view is android.view.ViewGroup) for (index in 0 until view.childCount) visit(view.getChildAt(index))
            }
            visit(activity.window.decorView)
        }
        return found.single()
    }
    private fun nodeLabels(geometry: FloatTextGeometry): List<List<String>> = geometry.nodes.map {
        listOf(it.kind.name, it.start.toString(), it.end.toString(), it.label?.toString().orEmpty())
    }
    private fun accessibleLabels(view: NativeFloatTextView, geometry: FloatTextGeometry): List<String?> =
        geometry.nodes.map { accessibleText(view, it.id) }
    private fun accessibleText(view: NativeFloatTextView, id: Int): String? {
        val info = view.accessibilityNodeProvider.createAccessibilityNodeInfo(id) ?: return null
        try { return info.text?.toString() } finally { info.recycle() }
    }
    private fun accessibleChildCount(view: NativeFloatTextView): Int {
        val info = checkNotNull(view.accessibilityNodeProvider.createAccessibilityNodeInfo(View.NO_ID))
        try { return info.childCount } finally { info.recycle() }
    }
    private fun touch(view: NativeFloatTextView, node: FloatInteractionNode, action: Int, down: Long) {
        val box = node.bounds.first { !it.isEmpty }
        val event = MotionEvent.obtain(down, SystemClock.uptimeMillis(), action,
            box.centerX() + view.paddingLeft, box.centerY() + view.paddingTop, 0)
        try { assertTrue(view.dispatchTouchEvent(event)) } finally { event.recycle() }
    }
    private fun hover(view: NativeFloatTextView, node: FloatInteractionNode, action: Int) {
        val box = node.bounds.first { !it.isEmpty }
        val now = SystemClock.uptimeMillis()
        val event = MotionEvent.obtain(now, now, action,
            box.centerX() + view.paddingLeft, box.centerY() + view.paddingTop, 0)
        event.source = android.view.InputDevice.SOURCE_MOUSE
        try { view.dispatchGenericMotionEvent(event) } finally { event.recycle() }
    }
    private fun colorMask(view: NativeFloatTextView, color: Int): BooleanArray {
        val bitmap = Bitmap.createBitmap(view.width, view.height, Bitmap.Config.ARGB_8888)
        try {
            bitmap.eraseColor(android.graphics.Color.WHITE)
            view.draw(Canvas(bitmap))
            val pixels = IntArray(bitmap.width * bitmap.height)
            bitmap.getPixels(pixels, 0, bitmap.width, 0, 0, bitmap.width, bitmap.height)
            return BooleanArray(pixels.size) { pixels[it] == color }
        } finally { bitmap.recycle() }
    }
    private fun hasSeparatedDots(mask: BooleanArray, width: Int): Boolean =
        (0 until mask.size / width).any { row ->
            var previous = false
            var starts = 0
            for (column in 0 until width) {
                val painted = mask[row * width + column]
                if (painted && !previous) starts++
                previous = painted
            }
            starts >= 3
        }

    @Test fun sevenEmptySupOwnersRetainRealCaptionMetricsWithoutAddingCopyActionsOrAccessibilityText() {
        val owners = List(7) { Span("text", "", superscript = true,
            inlineStyle = InlineTextStyle(lineHeight = InlineLineHeight.FontRelative(4f,
                InlineFontSnapshot(superscript = true)))) }
        val link = Span("link", "caption action", "Original")
        val phase = mutableStateOf(0)
        val clicks = mutableListOf<EntryLink>()
        var prepared: PreparedNativeFloatText? = null
        var geometry: FloatTextGeometry? = null
        try {
            compose.activityRule.scenario.onActivity { activity -> activity.setContent {
                MaterialTheme { CompositionLocalProvider(LocalDensity provides Density(1f, 1f)) {
                    val annotated = styledTextAnnotation(owners, null, textStyle) { clicks += it }
                    val actual = prepareNativeFloatText(owners, annotated, emptyList(), textStyle,
                        MaterialTheme.colorScheme.primary, emptyList(), settings, "th", { clicks += it })
                    SideEffect { prepared = actual }
                    val caption = when (phase.value) {
                        0 -> emptyList()
                        1 -> owners
                        2 -> owners + link
                        4 -> emptyList()
                        else -> listOf(link)
                    }
                    val selected = figure(caption).let { value -> if (phase.value == 4)
                        value.copy(captionBlocks = listOf(Block("paragraph", 0, owners + link))) else value }
                    Layout(content = {
                        AnonymousBlockView(Block("paragraph", 0, emptyList(), figure = selected), Modifier,
                            { clicks += it }, emptyList(), settings, "th", style = textStyle,
                            onGeometry = { geometry = it })
                    }) { children, _ ->
                        val child = children.single().measure(Constraints.fixedWidth(190))
                        layout(190, child.height) { child.place(0, 0) }
                    }
                } }
            } }
            compose.waitForIdle()
            val view = nativeView()
            var emptyText = ""
            var emptyHeight = 0
            var emptyLabels = emptyList<List<String>>()
            var emptyAccessible = emptyList<String?>()
            var emptyAxChildren = 0
            compose.runOnIdle {
                val source = checkNotNull(checkNotNull(prepared).native).source(190)
                assertEquals("", source.toString())
                val metrics = source.getSpans(0, 0, NativeAuthoredInlineMetrics::class.java)
                assertEquals(7, metrics.size)
                assertTrue(metrics.indices.all { first -> (first + 1 until metrics.size).all { metrics[first] !== metrics[it] } })
                assertTrue(metrics.all { source.getSpanStart(it) == 0 && source.getSpanEnd(it) == 0 })
                val actual = checkNotNull(geometry)
                emptyText = actual.text.toString(); emptyHeight = actual.height
                emptyLabels = nodeLabels(actual); emptyAccessible = accessibleLabels(view, actual)
                emptyAxChildren = accessibleChildCount(view)
                phase.value = 1
            }
            compose.waitForIdle()
            assertSame(view, nativeView())
            compose.runOnIdle {
                val actual = checkNotNull(geometry)
                assertEquals(emptyText, actual.text.toString())
                assertEquals(emptyText, view.logicalText.toString())
                assertEquals(emptyLabels, nodeLabels(actual))
                assertEquals(emptyAccessible, accessibleLabels(view, actual))
                assertEquals(emptyAxChildren, accessibleChildCount(view))
                assertTrue("The nonempty metric-owner list must produce a real caption line", actual.height > emptyHeight)
                assertTrue(clicks.isEmpty())
                phase.value = 2
            }
            compose.waitForIdle()
            var linkedText = ""
            var linkedRange = 0 to 0
            var linkedHeight = 0
            var plainLinkedHeight = 0
            var linkedAxChildren = 0
            compose.runOnIdle {
                val actual = checkNotNull(geometry)
                val action = actual.nodes.single { it.onClick != null }
                linkedText = actual.text.toString(); linkedRange = action.start to action.end; linkedHeight = actual.height
                linkedAxChildren = accessibleChildCount(view)
                assertEquals(link.text, linkedText.substring(action.start, action.end))
                assertEquals(link.text, accessibleText(view, action.id))
                assertTrue(view.accessibilityNodeProvider.performAction(action.id, AccessibilityNodeInfo.ACTION_CLICK, null))
                assertEquals(listOf(EntryLink("Original")), clicks)
                view.setSelection(action.start, action.end)
                assertEquals(link.text, view.logicalText.subSequence(view.selectionStart, view.selectionEnd).toString())
                phase.value = 3
            }
            compose.waitForIdle()
            compose.runOnIdle {
                val actual = checkNotNull(geometry)
                val action = actual.nodes.single { it.onClick != null }
                assertEquals(linkedText, actual.text.toString())
                assertEquals(linkedText, view.logicalText.toString())
                assertEquals(linkedRange, action.start to action.end)
                assertEquals(linkedAxChildren, accessibleChildCount(view))
                assertTrue("Removing only metric owners must remove their line contribution", actual.height < linkedHeight)
                plainLinkedHeight = actual.height
                assertEquals(listOf(EntryLink("Original")), clicks)
                phase.value = 4
            }
            compose.waitForIdle()
            compose.runOnIdle {
                val actual = checkNotNull(geometry)
                val action = actual.nodes.single { it.onClick != null }
                assertEquals(linkedText, actual.text.toString()); assertEquals(linkedText, view.logicalText.toString())
                assertEquals(linkedRange, action.start to action.end)
                assertEquals(linkedAxChildren, accessibleChildCount(view))
                assertTrue("Rich caption paragraphs must retain the same metric owners", actual.height > plainLinkedHeight)
                assertEquals(listOf(EntryLink("Original")), clicks)
                phase.value = 0
            }
            compose.waitForIdle()
            assertSame(view, nativeView())
            compose.runOnIdle {
                val actual = checkNotNull(geometry)
                assertEquals(emptyText, actual.text.toString()); assertEquals(emptyHeight, actual.height)
                assertEquals(emptyLabels, nodeLabels(actual)); assertEquals(emptyAccessible, accessibleLabels(view, actual))
                assertEquals(listOf(EntryLink("Original")), clicks)
            }
        } finally { compose.activityRule.scenario.onActivity { it.setContent {} }; compose.waitForIdle() }
    }

    @Test fun sourceDottedUnderlineSurvivesInheritedCaptionActionStatesAndResize() {
        val decorationColor = 0xffff00ff.toInt()
        val caption = Span("link", "Alpha beta gamma delta epsilon zeta caption", "Original",
            inlineStyle = InlineTextStyle(decoration = InlineUnderline(InlineUnderlineStyle.Dotted, "#ff00ff", px(2f)),
                cursor = InlineCursor.Help))
        val width = mutableStateOf(190)
        val source = figure(listOf(caption))
        val clicks = mutableListOf<EntryLink>()
        val visits = MissingLinkVisits()
        var geometry: FloatTextGeometry? = null
        fun assertCaptionCursor(view: NativeFloatTextView, actual: FloatTextGeometry, node: FloatInteractionNode) {
            val help = PointerIcon.getSystemIcon(view.context, PointerIcon.TYPE_HELP)
            fun iconAt(x: Float, y: Float): PointerIcon? {
                val now = SystemClock.uptimeMillis()
                val event = MotionEvent.obtain(now, now, MotionEvent.ACTION_HOVER_MOVE,
                    x + view.paddingLeft, y + view.paddingTop, 0)
                event.source = android.view.InputDevice.SOURCE_MOUSE
                try { return view.onResolvePointerIcon(event, 0) } finally { event.recycle() }
            }
            val captionHit = node.bounds.first { !it.isEmpty }
            assertEquals(help, checkNotNull(iconAt(captionHit.centerX(), captionHit.centerY())))
            // This fixture's real Missing label precedes its caption in the semantic group.
            // Its measured character rectangle supplies the outside point; no image position is guessed.
            val label = (source.content as FigureContent.Missing).span.text
            assertTrue(actual.text.toString().startsWith(label))
            assertTrue(node.start >= label.length)
            val bodyHit = actual.characterRects(0, label.length).first { it != null && !it.isEmpty }!!
            assertFalse(node.contains(bodyHit.centerX(), bodyHit.centerY()))
            assertTrue(iconAt(bodyHit.centerX(), bodyHit.centerY()) != help)
        }
        try {
            compose.activityRule.scenario.onActivity { activity -> activity.setContent {
                MaterialTheme { CompositionLocalProvider(LocalDensity provides Density(1f, 1f),
                    LocalMissingLinkVisits provides visits, LocalMissingLinkDocument provides "Inline-caption") {
                    Layout(content = {
                        AnonymousBlockView(Block("paragraph", 0, emptyList(), figure = source), Modifier,
                            { clicks += it }, emptyList(), settings, "th", style = textStyle,
                            onGeometry = { geometry = it })
                    }) { children, _ ->
                        val child = children.single().measure(Constraints.fixedWidth(width.value))
                        layout(width.value, child.height) { child.place(0, 0) }
                    }
                } }
            } }
            compose.waitForIdle()
            val view = nativeView()
            var mask = booleanArrayOf()
            var text = ""
            var range = 0 to 0
            var childCount = 0
            compose.runOnIdle {
                val actual = checkNotNull(geometry)
                val node = actual.nodes.single { it.onClick != null }
                val paint = checkNotNull(node.missingLinkPaint)
                text = actual.text.toString(); range = node.start to node.end
                childCount = accessibleChildCount(view)
                assertTrue(node.bounds.size > 1)
                assertCaptionCursor(view, actual, node)
                assertFalse(paint.appearance().underline)
                mask = colorMask(view, decorationColor)
                assertTrue(mask.any { it }); assertTrue(hasSeparatedDots(mask, view.width))
                hover(view, node, MotionEvent.ACTION_HOVER_ENTER)
                assertEquals(0xff3056a9.toInt(), paint.appearance().color); assertTrue(paint.appearance().underline)
                assertTrue(mask.contentEquals(colorMask(view, decorationColor)))
                val down = SystemClock.uptimeMillis()
                touch(view, node, MotionEvent.ACTION_DOWN, down)
                assertEquals(0xff233566.toInt(), paint.appearance().color); assertFalse(paint.appearance().underline)
                assertTrue(mask.contentEquals(colorMask(view, decorationColor)))
                touch(view, node, MotionEvent.ACTION_CANCEL, down)
                hover(view, node, MotionEvent.ACTION_HOVER_EXIT)
                assertTrue(view.accessibilityNodeProvider.performAction(node.id, AccessibilityNodeInfo.ACTION_FOCUS, null))
                assertTrue(paint.appearance().underline)
                assertTrue(mask.contentEquals(colorMask(view, decorationColor)))
                view.dispatchKeyEvent(KeyEvent(KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_ENTER))
                assertTrue(clicks.isEmpty())
                view.dispatchKeyEvent(KeyEvent(KeyEvent.ACTION_UP, KeyEvent.KEYCODE_ENTER))
                assertEquals(listOf(EntryLink("Original")), clicks)
            }
            compose.waitForIdle()
            compose.runOnIdle {
                val actual = checkNotNull(geometry)
                val node = actual.nodes.single { it.onClick != null }
                assertTrue(checkNotNull(node.missingLinkPaint).visited)
                assertEquals(0xff6a60b0.toInt(), node.missingLinkPaint!!.appearance().color)
                assertTrue(mask.contentEquals(colorMask(view, decorationColor)))
                assertEquals(text, actual.text.toString()); assertEquals(range, node.start to node.end)
                width.value = 280
            }
            compose.waitForIdle()
            assertSame(view, nativeView())
            compose.runOnIdle {
                val actual = checkNotNull(geometry)
                val node = actual.nodes.single { it.onClick != null }
                assertEquals(text, actual.text.toString()); assertEquals(text, view.logicalText.toString())
                assertEquals(range, node.start to node.end)
                assertEquals(childCount, accessibleChildCount(view))
                assertEquals(caption.text, accessibleText(view, node.id))
                assertCaptionCursor(view, actual, node)
                val resized = colorMask(view, decorationColor)
                assertTrue(resized.any { it }); assertTrue(hasSeparatedDots(resized, view.width))
                view.setSelection(node.start, node.end)
                assertEquals(caption.text, view.logicalText.subSequence(view.selectionStart, view.selectionEnd).toString())
                assertEquals(listOf(EntryLink("Original")), clicks)
            }
        } finally { compose.activityRule.scenario.onActivity { it.setContent {} }; compose.waitForIdle() }
    }

    @Test fun inheritedStackRetainsCaptionWhitespaceActionsAndRealLinesWithoutInventingEmptyStruts() {
        val stack = ContainerFontFamily.Stack(emptyList(), GenericFontFamily.Serif)
        val family = mutableStateOf<ContainerFontFamily?>(stack)
        val mode = mutableStateOf(0)
        val action = Span("link", "Alpha", "RetainedCaption", trail = "  ", targetFragment = "part")
        val runs = listOf(Span("text", "  "), action, Span("text", "\u00a0 "))
        val spaces = listOf(Span("text", "  "), Span("text", "", trail = "  "))
        val emptyFamily = listOf(Span("text", "", fontFamily = stack))
        val fallbackRuns = listOf(Span("text", "  iW  ", language = "en"),
            Span("link", "iW", "FallbackCaption", trail = "\u00a0 ", language = "en", targetFragment = "part", fontFamily = stack))
        val fallbackBlock = Block("preformatted", 0, fallbackRuns)
        val fallbackReason = "Retained preformatted caption fallback"
        val zero = StyleEdges(px(0f), px(0f), px(0f), px(0f))
        val margins = StyleEdges(px(5f), px(0f), px(7f), px(0f))
        val rule = Block("rule", 0, emptyList(), ruleStyle = RuleStyle(px(1f), ContainerColor.Transparent, zero))
        val paragraphs = listOf(
            listOf(Block("paragraph", 0, runs)),
            listOf(Block("paragraph", 0, spaces)),
            listOf(Block("paragraph", 0, emptyFamily)),
            listOf(Block("paragraph", 0, emptyList())),
            listOf(rule, Block("paragraph", 0, spaces, style = BlockStyle(margins = margins))),
            listOf(rule, Block("paragraph", 0, runs, style = BlockStyle(margins = margins))),
            listOf(rule),
        )
        val clicks = mutableListOf<EntryLink>()
        var geometry: FloatTextGeometry? = null
        var flow: NativeAnonymousFlowGeometry? = null
        lateinit var view: NativeFloatTextView
        fun change(nextMode: Int, nextFamily: ContainerFontFamily?) {
            compose.runOnIdle { geometry = null; flow = null; mode.value = nextMode; family.value = nextFamily }
            compose.waitForIdle()
            assertSame(view, nativeView())
        }
        fun verify(text: String, actionRange: IntRange? = null): Int {
            var frameHeight = -1
            compose.runOnIdle {
                val actual = checkNotNull(geometry)
                assertEquals(text, actual.text.toString()); assertEquals(text, view.logicalText.toString())
                frameHeight = checkNotNull(flow).figures.single().measured.geometry.height
                val links = actual.nodes.filter { it.kind == FloatInteractionKind.LINK }
                if (actionRange == null) assertTrue(links.isEmpty()) else {
                    val link = links.single()
                    assertEquals(actionRange.first, link.start); assertEquals(actionRange.last + 1, link.end)
                    assertEquals(text.substring(link.start, link.end), accessibleText(view, link.id))
                    assertTrue(link.bounds.any { !it.isEmpty })
                }
                if (text.isNotEmpty()) {
                    view.setSelection(0, text.length)
                    assertEquals(text, view.logicalText.subSequence(view.selectionStart, view.selectionEnd).toString())
                }
                assertSame(action, paragraphs[0].single().spans[1])
                assertEquals("  ", action.trail); assertEquals("\u00a0 ", runs.last().text)
            }
            return frameHeight
        }
        try {
            compose.activityRule.scenario.onActivity { activity -> activity.setContent {
                MaterialTheme { CompositionLocalProvider(LocalDensity provides Density(1f, 1f),
                    LocalNativeContainerTextContext provides ContainerTextContext(fontFamily = family.value)) {
                    Layout(content = {
                        if (mode.value == 7) {
                            UnavailableAnonymousContent(fallbackBlock, Modifier, fallbackReason, textStyle,
                                FigureReaderContext(emptyList(), settings, "th", { clicks += it }, fallbackBlock), reasonVisible = true)
                        } else {
                            val selected = figure(emptyList()).copy(captionBlocks = paragraphs[mode.value])
                            AnonymousBlockView(Block("paragraph", 0, emptyList(), figure = selected), Modifier,
                                { clicks += it }, emptyList(), settings, "th", style = textStyle,
                                onGeometry = { geometry = it }, onFlowGeometry = { flow = it })
                        }
                    }) { children, _ ->
                        val child = children.single().measure(Constraints.fixedWidth(190))
                        layout(190, child.height) { child.place(0, 0) }
                    }
                } }
            } }
            compose.waitForIdle(); view = nativeView()
            val raw = "  Alpha  \u00a0 "
            verify(raw, 2..8)
            compose.runOnIdle {
                assertTrue(colorMask(view, 0xff3366cc.toInt()).any { it })
                val link = checkNotNull(geometry).nodes.single { it.kind == FloatInteractionKind.LINK }
                assertTrue(view.accessibilityNodeProvider.performAction(link.id, AccessibilityNodeInfo.ACTION_CLICK, null))
                assertEquals(listOf(EntryLink("RetainedCaption", "part")), clicks)
            }
            change(0, ContainerFontFamily.SansSerif)
            verify(" Alpha \u00a0 ", 1..6)
            change(0, null)
            verify(" Alpha \u00a0 ", 1..6)
            change(0, stack)
            verify(raw, 2..8)

            change(3, stack)
            val emptyHeight = verify("")
            change(2, stack)
            assertEquals("A family field alone must not synthesize a caption line", emptyHeight, verify(""))
            change(1, stack)
            assertTrue("Actual inherited-family whitespace occupies its real line", verify("    ") > emptyHeight)
            compose.runOnIdle { assertTrue(checkNotNull(geometry).caretRect(0).height() > 0f) }
            change(1, ContainerFontFamily.SansSerif)
            assertEquals("Legacy Sans keeps its old empty-owner behavior", emptyHeight, verify(" "))
            change(1, null)
            assertEquals("Legacy null keeps its old empty-owner behavior", emptyHeight, verify(" "))

            change(6, stack)
            val ruleOnlyHeight = verify("")
            change(4, ContainerFontFamily.SansSerif)
            val collapsedHeight = verify("")
            assertEquals("An empty adjoining paragraph collapses its 5/7 margins to seven", ruleOnlyHeight + 7, collapsedHeight)
            change(4, stack)
            val occupiedHeight = verify("    ")
            assertTrue(occupiedHeight > collapsedHeight)
            change(4, null)
            assertEquals(collapsedHeight, verify(""))
            change(4, stack)
            assertEquals("Inherited family changes must refresh the adjoining profile", occupiedHeight, verify("    "))
            change(5, stack)
            verify(raw, 2..8)
            change(5, ContainerFontFamily.SansSerif)
            verify("Alpha \u00a0 ", 0..5)
            change(5, stack)
            verify(raw, 2..8)
            compose.runOnIdle { assertEquals(listOf(EntryLink("RetainedCaption", "part")), clicks) }

            // This remains the existing visible refusal, with its original preformatted run provenance.
            compose.runOnIdle { geometry = null; flow = null; mode.value = 7 }
            compose.waitForIdle()
            compose.onNodeWithText(fallbackReason).assertIsDisplayed()
            val fallbackView = nativeView()
            compose.runOnIdle {
                val actual = checkNotNull(fallbackView.currentMeasuredGeometry) as NativeSurfaceGeometry
                val context = actual.content as NativeFloatContextGeometry
                val leaf = context.inputLeaves().single()
                assertEquals(0, leaf.offset)
                val source = (leaf.geometry as NativeFloatGeometry).text as Spanned
                val expected = "  iW  iW\u00a0 "
                assertEquals(expected, source.toString()); assertEquals(expected, fallbackView.logicalText.toString())
                fun paintAt(index: Int): TextPaint {
                    val spans = source.getSpans(index, index + 1, MetricAffectingSpan::class.java)
                    assertTrue(spans.isNotEmpty())
                    return TextPaint().also { paint -> spans.forEach { it.updateMeasureState(paint) } }
                }
                val mono = paintAt(2)
                assertTrue(mono.measureText("iiii") > 0f)
                assertEquals("The null-family preformatted run retains Monospace", mono.measureText("iiii"), mono.measureText("WWWW"), .01f)
                val explicit = paintAt(6)
                assertTrue("An explicit terminal-serif request still wins over the preformatted owner",
                    kotlin.math.abs(explicit.measureText("iiii") - explicit.measureText("WWWW")) > 1f)
                val link = actual.nodes.single { it.kind == FloatInteractionKind.LINK }
                assertEquals(6, link.start); assertEquals(10, link.end)
                assertEquals("iW\u00a0 ", accessibleText(fallbackView, link.id))
                fallbackView.setSelection(0, expected.length)
                assertEquals(expected, fallbackView.logicalText.subSequence(fallbackView.selectionStart, fallbackView.selectionEnd).toString())
                assertTrue(fallbackView.accessibilityNodeProvider.performAction(link.id, AccessibilityNodeInfo.ACTION_CLICK, null))
                assertEquals(listOf(EntryLink("RetainedCaption", "part"), EntryLink("FallbackCaption", "part")), clicks)
                assertSame(fallbackRuns, fallbackBlock.spans); assertNull(fallbackRuns[0].fontFamily)
                assertSame(stack, fallbackRuns[1].fontFamily)
            }
        } finally { compose.activityRule.scenario.onActivity { it.setContent {} }; compose.waitForIdle() }
    }
}
