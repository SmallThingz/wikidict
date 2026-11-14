package app.smallthingz.dict

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Rect
import android.graphics.RectF
import android.os.Build
import android.os.SystemClock
import android.text.TextPaint
import android.text.style.MetricAffectingSpan
import android.text.style.ReplacementSpan
import android.view.InputDevice
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.View
import android.view.accessibility.AccessibilityNodeInfo
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.width
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Typography
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.platform.UriHandler
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.test.*
import androidx.compose.ui.text.TextLayoutResult
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test
import kotlin.math.ceil
import kotlin.math.floor
import kotlin.math.max

/** Ordinary LinkPaint API02 integration obligations. Private source only; all methods are unrun. */
class OrdinaryLinkPaintDeviceTest {
    @get:Rule val compose = createPhysicalComposeRule()
    private fun px(value: Float) = StyleLength(StyleLengthUnit.Px, value)
    private fun zero() = StyleEdges(px(0f), px(0f), px(0f), px(0f))
    private val colors = listOf("#3366cc", "#228844", "#cc5500", "#aa22cc", "#6a60b0", "#008080", "#993333", "#667700")
    private val underlines = listOf(true, false, false, true, false, true, true, false)
    private fun policy(): LinkPaint {
        // Both combined states differ from active alone; static normal underline is not an override.
        val states = colors.mapIndexed { index, color -> FigureLinkState(color, underlines[index]) }
        return LinkPaint(normal = states[0], hover = states[1], active = states[2], hoverActive = states[3],
            visited = states[4], visitedHover = states[5], visitedActive = states[6], visitedHoverActive = states[7],
            underlineOnFocus = true, focusOutline = FigureFocusOutline(StyleLength(StyleLengthUnit.Em, .125f), FigureColor.Rgb("#ff0000"),
                StyleLength(StyleLengthUnit.Em, .125f), SignedContainerMargin(StyleLengthUnit.Em, -.125f)))
    }
    private fun link(text: String, target: String, kind: String = "link", fragment: String? = null,
        value: LinkPaint = policy()) = Span(kind, text, target, targetFragment = fragment,
            foreground = value.normal.foreground, underline = value.normal.underline, linkPaint = value)
    private fun argb(index: Int) = 0xff000000.toInt() or colors[index].substring(1).toInt(16)
    private fun withScene(content: @Composable () -> Unit, assertions: () -> Unit) {
        try {
            compose.activityRule.scenario.onActivity { it.setContent(content = content) }
            compose.waitForIdle()
            assertions()
        } finally { compose.activityRule.scenario.onActivity { it.setContent {} } }
    }
    @Composable
    private fun Scene(visits: MissingLinkVisits, owner: Any, width: Int = 190, uri: UriHandler? = null,
        content: @Composable () -> Unit) {
        val handler = uri ?: object : UriHandler { override fun openUri(uri: String) { error("Unexpected URI action: $uri") } }
        CompositionLocalProvider(LocalDensity provides Density(1f, 1f), LocalEntryEdition provides "de",
            LocalMissingLinkVisits provides visits, LocalMissingLinkOwner provides owner,
            LocalMissingLinkDocument provides "Document", LocalUriHandler provides handler) {
            DictTheme("light") {
                MaterialTheme(typography = Typography(bodyLarge = TextStyle(fontSize = 24.sp, lineHeight = 30.sp,
                    fontFamily = FontFamily.Monospace))) {
                    Box(Modifier.width(width.dp).testTag("ordinary-link-surface")) { content() }
                }
            }
        }
    }
    private fun views(): List<NativeFloatTextView> {
        val result = mutableListOf<NativeFloatTextView>()
        fun visit(view: View) {
            if (view is NativeFloatTextView && view.isShown) result += view
            if (view is android.view.ViewGroup) repeat(view.childCount) { visit(view.getChildAt(it)) }
        }
        visit(compose.activity.window.decorView)
        return result
    }
    private fun paintNodes(view: NativeFloatTextView) = checkNotNull(view.currentMeasuredGeometry).nodes
        .filter { it.missingLinkPaint?.ordinaryPolicy != null }.sortedBy { it.start }
    private fun viewFor(label: String): NativeFloatTextView = views().single { view ->
        paintNodes(view).any { it.label?.toString() == label }
    }
    private fun inputGuard() {
        assertPhysicalActivity(compose.activity)
        check(compose.activity.hasWindowFocus())
    }
    private fun pointer(view: NativeFloatTextView, node: FloatInteractionNode, action: Int,
        down: Long = SystemClock.uptimeMillis()) {
        inputGuard()
        val rectangle = node.bounds.first { !it.isEmpty }
        val event = MotionEvent.obtain(down, SystemClock.uptimeMillis(), action,
            rectangle.centerX() + view.paddingLeft, rectangle.centerY() + view.paddingTop, 0)
        try { assertTrue(view.dispatchTouchEvent(event)) } finally { event.recycle() }
    }
    private fun hover(view: NativeFloatTextView, node: FloatInteractionNode, action: Int) {
        inputGuard()
        val rectangle = node.bounds.first { !it.isEmpty }
        val now = SystemClock.uptimeMillis()
        val event = MotionEvent.obtain(now, now, action,
            rectangle.centerX() + view.paddingLeft, rectangle.centerY() + view.paddingTop, 0)
        event.source = InputDevice.SOURCE_MOUSE
        try { view.dispatchGenericMotionEvent(event) } finally { event.recycle() }
    }
    private fun click(view: NativeFloatTextView, node: FloatInteractionNode) {
        val now = SystemClock.uptimeMillis()
        pointer(view, node, MotionEvent.ACTION_DOWN, now)
        pointer(view, node, MotionEvent.ACTION_UP, now)
    }
    private fun assertInk(color: Int) {
        // NativeFloatContextLayout paints glyphs in its Compose canvas; the interaction View is NoPaintGeometry.
        val bitmap = compose.onRoot().captureToImage().asAndroidBitmap()
        try {
            val pixels = IntArray(bitmap.width * bitmap.height)
            bitmap.getPixels(pixels, 0, bitmap.width, 0, 0, bitmap.width, bitmap.height)
            assertTrue("Actual rendered ink must include ${color.toUInt().toString(16)}", pixels.any { it == color })
        } finally { bitmap.recycle() }
    }
    private fun assertNoInk(color: Int) {
        val bitmap = compose.onRoot().captureToImage().asAndroidBitmap()
        try {
            val pixels = IntArray(bitmap.width * bitmap.height)
            bitmap.getPixels(pixels, 0, bitmap.width, 0, 0, bitmap.width, bitmap.height)
            assertFalse("Actual rendered ink must exclude ${color.toUInt().toString(16)}", pixels.any { it == color })
        } finally { bitmap.recycle() }
    }
    private fun assertNoRefusal() {
        compose.onAllNodesWithText("unavailable", substring = true, ignoreCase = true).assertCountEquals(0)
        compose.onAllNodesWithText("Unable to display this layout.").assertCountEquals(0)
    }
    private fun assertAppearance(view: NativeFloatTextView, index: Int, state: Int, focused: Boolean = false) {
        val paint = paintNodes(view)[index].missingLinkPaint!!
        assertEquals(argb(state), paint.appearance().color)
        assertEquals(underlines[state] || focused, paint.appearance().underline)
    }

    @Test fun ordinaryTwoOccurrenceLinksPaintAllEightStatesAndKeepFocusSelectionAndIdentityAcrossReflow() {
        val first = link("Alpha beta gamma delta epsilon zeta", "Same").copy(direction = "rtl", italic = true, trail = "!",
            fontScale = 1.5f, fontScaleBasis = FontScaleBasis.NormalBody)
        val second = link("Second", "Same")
        val source = listOf(first, Span("text", " / "), second)
        val visits = MissingLinkVisits()
        val owner = Any()
        val width = mutableStateOf(190)
        val opened = mutableListOf<EntryLink>()
        var originalView: NativeFloatTextView? = null
        var identities = emptyList<MissingLinkActionIdentity?>()
        var originalText = ""
        var originalBounds = emptyList<RectF>()
        withScene({ Scene(visits, owner, width.value) { StyledText(source, onLink = { opened += it }) } }) {
            assertNoRefusal()
            compose.runOnIdle {
                val view = views().single { paintNodes(it).size == 2 }
                originalView = view
                val nodes = paintNodes(view)
                originalText = view.logicalText.toString()
                identities = nodes.map { it.missingLinkPaint!!.actionIdentity }
                originalBounds = nodes[0].bounds.map(::RectF)
                assertTrue(nodes[0].bounds.size > 1)
                assertNotEquals(identities[0], identities[1])
                assertEquals(identities[0]!!.target, identities[1]!!.target)
                assertAppearance(view, 0, 0); assertAppearance(view, 1, 0)
            }
            assertInk(argb(0))
            compose.runOnIdle {
                val view = checkNotNull(originalView)
                hover(view, paintNodes(view)[0], MotionEvent.ACTION_HOVER_ENTER)
                assertAppearance(view, 0, 1); assertAppearance(view, 1, 0)
            }
            compose.waitForIdle(); assertInk(argb(1))
            compose.runOnIdle {
                val view = checkNotNull(originalView)
                val node = paintNodes(view)[0]
                hover(view, node, MotionEvent.ACTION_HOVER_EXIT)
                pointer(view, node, MotionEvent.ACTION_DOWN)
                assertAppearance(view, 0, 2); assertAppearance(view, 1, 0)
            }
            compose.waitForIdle(); assertInk(argb(2))
            compose.runOnIdle {
                val view = checkNotNull(originalView)
                hover(view, paintNodes(view)[0], MotionEvent.ACTION_HOVER_ENTER)
                assertAppearance(view, 0, 3); assertAppearance(view, 1, 0)
                assertTrue(opened.isEmpty())
            }
            compose.waitForIdle(); assertInk(argb(3))
            compose.runOnIdle {
                val view = checkNotNull(originalView)
                pointer(view, paintNodes(view)[0], MotionEvent.ACTION_CANCEL)
                hover(view, paintNodes(view)[0], MotionEvent.ACTION_HOVER_EXIT)
                assertTrue(opened.isEmpty())
                click(view, paintNodes(view)[0])
                assertEquals(listOf(EntryLink("Same")), opened)
            }
            compose.waitForIdle()
            compose.runOnIdle {
                val view = checkNotNull(originalView)
                assertEquals(identities, paintNodes(view).map { it.missingLinkPaint!!.actionIdentity })
                assertTrue(paintNodes(view).all { it.missingLinkPaint!!.visited })
                assertAppearance(view, 0, 4); assertAppearance(view, 1, 4)
            }
            assertInk(argb(4))
            compose.runOnIdle {
                val view = checkNotNull(originalView)
                hover(view, paintNodes(view)[0], MotionEvent.ACTION_HOVER_ENTER)
                assertAppearance(view, 0, 5); assertAppearance(view, 1, 4)
            }
            compose.waitForIdle(); assertInk(argb(5))
            compose.runOnIdle {
                val view = checkNotNull(originalView)
                hover(view, paintNodes(view)[0], MotionEvent.ACTION_HOVER_EXIT)
                pointer(view, paintNodes(view)[0], MotionEvent.ACTION_DOWN)
                assertAppearance(view, 0, 6); assertAppearance(view, 1, 4)
            }
            compose.waitForIdle(); assertInk(argb(6))
            compose.runOnIdle {
                val view = checkNotNull(originalView)
                hover(view, paintNodes(view)[0], MotionEvent.ACTION_HOVER_ENTER)
                assertAppearance(view, 0, 7); assertAppearance(view, 1, 4)
                assertEquals(1, opened.size)
            }
            compose.waitForIdle(); assertInk(argb(7))
            compose.runOnIdle {
                val view = checkNotNull(originalView)
                pointer(view, paintNodes(view)[0], MotionEvent.ACTION_CANCEL)
                hover(view, paintNodes(view)[0], MotionEvent.ACTION_HOVER_EXIT)
                val node = paintNodes(view)[0]
                val provider = view.accessibilityNodeProvider
                assertTrue(provider.performAction(node.id, AccessibilityNodeInfo.ACTION_ACCESSIBILITY_FOCUS, null))
                assertFalse(node.missingLinkPaint!!.focused)
                assertTrue(provider.performAction(node.id, AccessibilityNodeInfo.ACTION_FOCUS, null))
                assertTrue(node.missingLinkPaint!!.focused)
                assertAppearance(view, 0, 4, focused = true)
                assertAppearance(view, 1, 4)
                val focused = node.focusPaint as NativeNodeFocusPaint.Fragments
                assertEquals(node.bounds, focused.outlines.map { it.bounds })
                focused.outlines.forEach {
                    assertEquals(3f, it.width, .001f)
                    assertEquals(3f, it.radius, .001f)
                    assertEquals(-3f, it.offset, .001f)
                }
                inputGuard()
                view.dispatchKeyEvent(KeyEvent(KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_ENTER))
                assertEquals(1, opened.size)
                assertAppearance(view, 0, 6, focused = true)
                view.dispatchKeyEvent(KeyEvent(KeyEvent.ACTION_UP, KeyEvent.KEYCODE_ENTER))
                assertEquals(List(2) { EntryLink("Same") }, opened)
            }
            compose.waitForIdle(); assertInk(android.graphics.Color.RED)
            compose.runOnIdle {
                val view = checkNotNull(originalView)
                pointer(view, paintNodes(view)[0], MotionEvent.ACTION_DOWN)
                assertTrue(paintNodes(view)[0].missingLinkPaint!!.focused)
                assertAppearance(view, 0, 6, focused = true)
                assertEquals(2, opened.size)
            }
            compose.waitForIdle(); assertNoInk(android.graphics.Color.RED)
            compose.runOnIdle {
                val view = checkNotNull(originalView)
                pointer(view, paintNodes(view)[0], MotionEvent.ACTION_CANCEL)
                assertTrue(paintNodes(view)[0].missingLinkPaint!!.focused)
                assertAppearance(view, 0, 4, focused = true)
                assertEquals(2, opened.size)
            }
            compose.waitForIdle(); assertNoInk(android.graphics.Color.RED)
            compose.runOnIdle {
                val view = checkNotNull(originalView)
                assertTrue(view.accessibilityNodeProvider.performAction(paintNodes(view)[0].id,
                    AccessibilityNodeInfo.ACTION_FOCUS, null))
                assertAppearance(view, 0, 4, focused = true)
                assertEquals(2, opened.size)
            }
            compose.waitForIdle(); assertInk(android.graphics.Color.RED)
            compose.runOnIdle { width.value = 280 }
            compose.waitForIdle()
            compose.runOnIdle {
                val view = views().single { paintNodes(it).size == 2 }
                assertSame(originalView, view)
                val nodes = paintNodes(view)
                assertEquals(originalText, view.logicalText.toString())
                assertEquals(identities, nodes.map { it.missingLinkPaint!!.actionIdentity })
                assertNotEquals(originalBounds, nodes[0].bounds)
                view.setSelection(nodes[0].start, nodes[1].end)
                assertEquals(originalText.substring(nodes[0].start, nodes[1].end), view.selectedTextForCopy())
                assertTrue(checkNotNull(view.currentMeasuredGeometry).rectsForRange(nodes[0].start, nodes[1].end).isNotEmpty())
                val info = checkNotNull(view.accessibilityNodeProvider.createAccessibilityNodeInfo(nodes[0].id))
                try {
                    assertTrue(info.isClickable)
                    assertFalse(Rect().also(info::getBoundsInScreen).isEmpty)
                } finally { info.recycle() }
                width.value = 190
            }
            compose.waitForIdle()
            compose.runOnIdle {
                val view = checkNotNull(originalView)
                val nodes = paintNodes(view)
                assertEquals(originalText, view.logicalText.toString())
                assertEquals(identities, nodes.map { it.missingLinkPaint!!.actionIdentity })
                inputGuard()
                view.dispatchKeyEvent(KeyEvent(KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_ESCAPE))
                assertTrue(view.accessibilityNodeProvider.performAction(nodes[0].id, AccessibilityNodeInfo.ACTION_CLEAR_FOCUS, null))
                click(view, nodes[1])
                assertEquals(List(3) { EntryLink("Same") }, opened)
            }
        }
    }

    @Test fun ordinaryFragmentAndExternalActionsKeepSeparateHistoryKeysAndOriginalCallbacks() {
        val one = link("One", "Same", fragment = "first")
        val two = link("Two", "Same", fragment = "second")
        val local = link("Local", "#Local")
        val external = link("Web", "https://example.invalid/Same#first", kind = "external_link")
        val source = listOf(one, Span("text", " / "), two, Span("text", " / "), local, Span("text", " / "), external)
        val visits = MissingLinkVisits()
        val opened = mutableListOf<EntryLink>()
        val urls = mutableListOf<String>()
        val uri = object : UriHandler { override fun openUri(uri: String) { urls += uri } }
        val owner = Any()
        withScene({ Scene(visits, owner, 300, uri) { StyledText(source, onLink = { opened += it }) } }) {
            assertNoRefusal()
            compose.runOnIdle {
                val view = views().single { paintNodes(it).size == 4 }
                val targets = paintNodes(view).map { it.missingLinkPaint!!.actionIdentity!!.target }
                assertEquals(4, targets.distinct().size)
                assertEquals(MissingLinkTarget("de", "link", "Same", "first"), targets[0])
                assertEquals(MissingLinkTarget("de", "link", "Same", "second"), targets[1])
                assertEquals(MissingLinkTarget("de", "link", "Document", "Local"), targets[2])
                assertEquals(MissingLinkTarget("", "external_link", external.target, null), targets[3])
                assertTrue(targets.none(visits::contains))
                click(view, paintNodes(view)[0])
                assertEquals(listOf(EntryLink("Same", "first")), opened)
                assertTrue(urls.isEmpty())
            }
            compose.waitForIdle()
            compose.runOnIdle {
                val view = views().single { paintNodes(it).size == 4 }
                assertEquals(listOf(true, false, false, false), paintNodes(view).map { it.missingLinkPaint!!.visited })
                click(view, paintNodes(view)[3])
                assertEquals(listOf(external.target), urls)
                assertEquals(1, opened.size)
            }
            compose.waitForIdle()
            compose.runOnIdle {
                val view = views().single { paintNodes(it).size == 4 }
                assertEquals(listOf(true, false, false, true), paintNodes(view).map { it.missingLinkPaint!!.visited })
                click(view, paintNodes(view)[2])
                assertEquals(listOf(EntryLink("Same", "first"), EntryLink("#Local")), opened)
                assertEquals(listOf(external.target), urls)
            }
            compose.waitForIdle()
            compose.runOnIdle {
                val view = views().single { paintNodes(it).size == 4 }
                assertEquals(listOf(true, false, true, true), paintNodes(view).map { it.missingLinkPaint!!.visited })
                val text = view.logicalText.toString()
                val nodes = paintNodes(view)
                view.setSelection(nodes.first().start, nodes.last().end)
                assertEquals(text.substring(nodes.first().start, nodes.last().end), view.selectedTextForCopy())
            }
        }
    }

    @Test fun realTableCaptionAndCellPaintPreventTheColorSwatchFeatureFromReplacingTheirActions() {
        val caption = link("Caption", "Caption-target")
        val cell = link("Cell", "Cell-target")
        val mode = mutableStateOf(0)
        val visits = MissingLinkVisits()
        val owner = Any()
        val opened = mutableListOf<EntryLink>()
        val feature = Feature("color_swatch", "", "#123456", "none", "")
        fun plain(span: Span) = span.copy(linkPaint = null)
        val tables = listOf(
            Table(listOf(plain(caption)), listOf(listOf(Cell(listOf(cell), false, 1, 1,
                style = CellStyle(border = StyleBorder.None, padding = zero(), minWidth = px(140f))))),
                style = TableStyle(border = StyleBorder.None, collapse = TableCollapse.Collapse)),
            Table(listOf(caption), listOf(listOf(Cell(listOf(plain(cell)), false, 1, 1,
                style = CellStyle(border = StyleBorder.None, padding = zero(), minWidth = px(140f))))),
                style = TableStyle(border = StyleBorder.None, collapse = TableCollapse.Collapse)),
        )
        withScene({ Scene(visits, owner, 280) { CompiledTableView(tables[mode.value], feature) { opened += it } } }) {
            for ((index, label) in listOf("Cell", "Caption").withIndex()) {
                compose.runOnIdle { mode.value = index }
                compose.waitForIdle()
                assertNoRefusal()
                compose.onNodeWithTag("compiled-table-grid", useUnmergedTree = true).assertExists()
                compose.onAllNodesWithText("Color sample #123456").assertCountEquals(0)
                compose.runOnIdle {
                    val view = viewFor(label)
                    val node = paintNodes(view).single { it.label?.toString() == label }
                    assertEquals(policy(), node.missingLinkPaint!!.ordinaryPolicy)
                    hover(view, node, MotionEvent.ACTION_HOVER_ENTER)
                    assertEquals(argb(1), node.missingLinkPaint!!.appearance().color)
                    assertFalse(node.missingLinkPaint!!.appearance().underline)
                }
                compose.waitForIdle(); assertInk(argb(1))
                compose.runOnIdle {
                    val view = viewFor(label)
                    val node = paintNodes(view).single { it.label?.toString() == label }
                    hover(view, node, MotionEvent.ACTION_HOVER_EXIT)
                    val geometry = checkNotNull(view.currentMeasuredGeometry)
                    view.setSelection(node.start, node.end)
                    assertEquals(label, view.selectedTextForCopy())
                    assertTrue(geometry.rectsForRange(node.start, node.end).isNotEmpty())
                    inputGuard()
                    view.dispatchKeyEvent(KeyEvent(KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_ESCAPE))
                    click(view, node)
                    assertEquals(index + 1, opened.size)
                    assertEquals("$label-target", opened.last().target)
                }
                compose.waitForIdle()
            }
            compose.runOnIdle { assertEquals(listOf(EntryLink("Cell-target"), EntryLink("Caption-target")), opened) }
        }
    }

    @Test fun unsupportedExternalPolicyShowsOneRetainedNormalProjectionWithoutRecursingOrGuessingVisits() {
        val unsupported = link("Mail", "mailto:reader@example.invalid", kind = "external_link")
        val retained = link("Keep", "Retained-target")
        val source = listOf(unsupported, Span("text", " / "), retained)
        val visits = MissingLinkVisits()
        val owner = Any()
        val opened = mutableListOf<EntryLink>()
        val urls = mutableListOf<String>()
        val uri = object : UriHandler { override fun openUri(uri: String) { urls += uri } }
        withScene({ Scene(visits, owner, 280, uri) { StyledText(source, onLink = { opened += it }) } }) {
            compose.onAllNodesWithText(NativeOrdinaryLinkPaintUnavailable, useUnmergedTree = true).assertCountEquals(1)
            compose.onNodeWithText(NativeOrdinaryLinkPaintUnavailable, useUnmergedTree = true).assertIsDisplayed()
            val body = compose.onNodeWithText("Mail / Keep", useUnmergedTree = true).assertIsDisplayed()
            val layouts = mutableListOf<TextLayoutResult>()
            body.performSemanticsAction(SemanticsActions.GetTextLayoutResult) { it(layouts) }
            val layout = layouts.single()
            assertEquals("Mail / Keep", layout.layoutInput.text.text)
            assertTrue(layout.layoutInput.text.spanStyles.any { it.start == 0 && it.end >= 4 &&
                TextDecoration.Underline in (it.item.textDecoration ?: TextDecoration.None) })
            assertInk(argb(0))
            compose.runOnIdle {
                assertEquals(policy(), unsupported.linkPaint)
                assertEquals(policy(), retained.linkPaint)
                assertFalse(visits.contains(missingLinkTarget(unsupported, "de", "Document")))
                assertTrue(views().none { paintNodes(it).isNotEmpty() })
                assertTrue(opened.isEmpty()); assertTrue(urls.isEmpty())
                inputGuard()
            }
            val keep = layout.layoutInput.text.text.indexOf("Keep")
            body.performTouchInput { click(layout.getBoundingBox(keep).center) }
            compose.runOnIdle {
                assertEquals(listOf(EntryLink("Retained-target")), opened)
                assertTrue(urls.isEmpty())
                assertFalse(visits.contains(missingLinkTarget(unsupported, "de", "Document")))
            }
            compose.waitForIdle()
            compose.onAllNodesWithText(NativeOrdinaryLinkPaintUnavailable, useUnmergedTree = true).assertCountEquals(1)
            compose.onAllNodesWithText("Mail / Keep", useUnmergedTree = true).assertCountEquals(1)
            assertInk(argb(0))
        }
    }

    @Test fun api31ActualPreparedEgyptianLinksRemoveDynamicUnderlineWithoutLosingGlyphStrikeCopyOrFocus() {
        assumeTrue(Build.VERSION.SDK_INT >= 31)
        val glyph = "\uD80C\uDC00"
        val value = policy()
        val struck = link(glyph, "Egyptian-struck", value = value).copy(classes = "Egyp", strike = true)
        val plain = link(glyph, "Egyptian-plain", value = value).copy(classes = "Egyp")
        val source = listOf(struck, Span("text", " "), plain)
        val visits = MissingLinkVisits()
        val owner = Any()
        val opened = mutableListOf<EntryLink>()
        var latest: PreparedNativeFloatText? = null
        withScene({
            Scene(visits, owner, 280) {
                val style = MaterialTheme.typography.bodyLarge.copy(fontSize = 64.sp, lineHeight = 80.sp)
                val annotated = styledTextAnnotation(source, null, style) { opened += it }
                val prepared = prepareNativeFloatText(source, annotated, egyptianTextRuns(source), style,
                    MaterialTheme.colorScheme.primary, emptyList(), AppSettings(allowImages = false, allowAudio = false),
                    "de", { opened += it })
                SideEffect { latest = prepared }
                NativeFloatContextLayout(listOf(NativeFloatContextSpec.Text(prepared, 0f)), Modifier,
                    MaterialTheme.colorScheme.primary) { _, _ -> error("Ordinary glyph text has no delegated child") }
            }
        }) {
            compose.waitUntil(20_000) {
                var settled = false
                compose.runOnIdle { settled = latest?.stateDescription != "Loading Egyptian glyph layout" && latest != null }
                settled
            }
            assertNoRefusal()
            compose.onAllNodesWithText("Egyptian glyph layout unavailable").assertCountEquals(0)
            lateinit var view: NativeFloatTextView
            lateinit var native: NativePreparedText
            lateinit var text: android.text.Spanned
            lateinit var replacements: List<ReplacementSpan>
            lateinit var paint: TextPaint
            var bitmapWidth = 0
            val bitmapHeight = 256
            val baseline = 128
            var underlineTop = 0
            var underlineBottom = 0
            var strikeTop = 0
            var strikeBottom = 0
            fun alpha(index: Int): IntArray {
                val span = replacements[index]
                val bitmap = Bitmap.createBitmap(bitmapWidth, bitmapHeight, Bitmap.Config.ARGB_8888)
                return try {
                    span.draw(Canvas(bitmap), text, text.getSpanStart(span), text.getSpanEnd(span),
                        16f, 0, baseline, bitmapHeight, paint)
                    IntArray(bitmapWidth * bitmapHeight).also {
                        bitmap.getPixels(it, 0, bitmapWidth, 0, 0, bitmapWidth, bitmapHeight)
                        for (at in it.indices) it[at] = it[at] ushr 24
                    }
                } finally { bitmap.recycle() }
            }
            lateinit var normal: IntArray
            lateinit var hovered: IntArray
            compose.runOnIdle {
                assertNull(checkNotNull(latest).stateDescription)
                view = views().single { paintNodes(it).size == 2 }
                native = checkNotNull(checkNotNull(latest).native)
                text = native.source(280)
                replacements = text.getSpans(0, text.length, ReplacementSpan::class.java).sortedBy(text::getSpanStart)
                assertEquals(2, replacements.size)
                paint = TextPaint(native.paint)
                val start = text.getSpanStart(replacements[0])
                val end = text.getSpanEnd(replacements[0])
                text.getSpans(start, end, MetricAffectingSpan::class.java).filterNot { it is ReplacementSpan }
                    .forEach { it.updateMeasureState(paint) }
                val widths = replacements.map { it.getSize(paint, text, text.getSpanStart(it), text.getSpanEnd(it), null) }
                assertEquals(widths[0], widths[1])
                assertTrue(widths[0] in 1..240)
                bitmapWidth = widths[0] + 32
                val underlineHalf = max(1f, paint.underlineThickness) / 2f
                underlineTop = floor(baseline + paint.underlinePosition - underlineHalf).toInt() - 1
                underlineBottom = ceil(baseline + paint.underlinePosition + underlineHalf).toInt() + 1
                val strikeHalf = max(1f, paint.strikeThruThickness) / 2f
                strikeTop = floor(baseline + paint.strikeThruPosition - strikeHalf).toInt() - 1
                strikeBottom = ceil(baseline + paint.strikeThruPosition + strikeHalf).toInt() + 1
                assertTrue(strikeBottom < underlineTop)
                assertTrue(strikeTop >= 0 && underlineBottom < bitmapHeight)
                normal = alpha(0)
                val withoutStrike = alpha(1)
                assertTrue("Actual authored strike must add ink to the otherwise identical prepared glyph", normal.indices.any {
                    it / bitmapWidth in strikeTop..strikeBottom && normal[it] > withoutStrike[it]
                })
                hover(view, paintNodes(view)[0], MotionEvent.ACTION_HOVER_ENTER)
                assertFalse(paintNodes(view)[0].missingLinkPaint!!.appearance().underline)
                hovered = alpha(0)
                assertTrue("The true normal underline must disappear in hover", normal.indices.any {
                    it / bitmapWidth in underlineTop..underlineBottom && normal[it] > hovered[it]
                })
                normal.indices.filter { it / bitmapWidth !in underlineTop..underlineBottom }.forEach {
                    assertEquals("Glyph and authored strike mask must survive the state change at pixel $it", normal[it], hovered[it])
                }
                assertEquals(2, text.getSpans(0, text.length, ReplacementSpan::class.java).size)
            }
            compose.waitForIdle(); assertInk(argb(1))
            compose.runOnIdle {
                hover(view, paintNodes(view)[0], MotionEvent.ACTION_HOVER_EXIT)
                pointer(view, paintNodes(view)[0], MotionEvent.ACTION_DOWN)
                assertEquals(argb(2), paintNodes(view)[0].missingLinkPaint!!.appearance().color)
                assertFalse(paintNodes(view)[0].missingLinkPaint!!.appearance().underline)
                assertArrayEquals("Active alone must not restore a baked underline", hovered, alpha(0))
            }
            compose.waitForIdle(); assertInk(argb(2))
            compose.runOnIdle {
                hover(view, paintNodes(view)[0], MotionEvent.ACTION_HOVER_ENTER)
                assertEquals(argb(3), paintNodes(view)[0].missingLinkPaint!!.appearance().color)
                assertTrue(paintNodes(view)[0].missingLinkPaint!!.appearance().underline)
                assertArrayEquals("Combined hover and active must select its own underline", normal, alpha(0))
            }
            compose.waitForIdle(); assertInk(argb(3))
            compose.runOnIdle {
                pointer(view, paintNodes(view)[0], MotionEvent.ACTION_CANCEL)
                assertTrue(view.accessibilityNodeProvider.performAction(paintNodes(view)[0].id, AccessibilityNodeInfo.ACTION_FOCUS, null))
                assertTrue(paintNodes(view)[0].missingLinkPaint!!.appearance().underline)
                assertArrayEquals("Focus underline overlays hover without reshaping the glyph", normal, alpha(0))
                assertEquals(argb(1), paintNodes(view)[0].missingLinkPaint!!.appearance().color)
            }
            compose.waitForIdle(); assertInk(android.graphics.Color.RED)
            compose.runOnIdle {
                val node = paintNodes(view)[0]
                view.setSelection(node.start, node.end)
                assertEquals(glyph, view.selectedTextForCopy())
                inputGuard()
                view.dispatchKeyEvent(KeyEvent(KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_ESCAPE))
                assertTrue(view.accessibilityNodeProvider.performAction(node.id, AccessibilityNodeInfo.ACTION_CLEAR_FOCUS, null))
                hover(view, node, MotionEvent.ACTION_HOVER_EXIT)
                click(view, node)
                assertEquals(listOf(EntryLink("Egyptian-struck")), opened)
                assertEquals(glyph + " " + glyph, view.logicalText.toString())
            }
        }
    }

    @Test fun nestedTableScrollportsKeepAuthoredLinkFocusSeparateFromReaderHostFocus() {
        // Synthetic constructor-policy composition, not an issued genuine RU source graph.
        val visits = MissingLinkVisits()
        val owner = Any()
        val opened = mutableListOf<EntryLink>()
        val left = link("Left source action", "RU-left", fragment = "section-left")
        val right = link("Right source action", "RU-right", fragment = "section-right")
        val fixedZero = ContainerMargin.Length(px(0f))
        val table = Table(emptyList(), listOf(listOf(left, right).map { span ->
            Cell(listOf(span), false, 1, 1, style = CellStyle(border = StyleBorder.None,
                padding = zero(), minWidth = px(300f), textAlign = CellTextAlign.Center))
        }), style = TableStyle(border = StyleBorder.None, padding = zero(), margins = zero(),
            collapse = TableCollapse.Collapse), blockViewport = TableBlockViewport(639,
            TableStyle(width = StyleWidth(StyleWidthUnit.Percent, 70f),
                marginValues = ContainerMargins(fixedZero, ContainerMargin.Auto, fixedZero, ContainerMargin.Auto),
                containingDirection = TableContainingDirection.Ltr), ContainerBoxSizing.ContentBox,
            StyleWidth(StyleWidthUnit.Percent, 100f), TableStyle(collapse = TableCollapse.Collapse),
            TableContainingDirection.Ltr, language = "ru"))
        val inner = Block("container", 0, emptyList(), container = Container(
            listOf(Block("table", 0, emptyList(), table = table)),
            ContainerStyle(width = ContainerWidth.Length(StyleWidth(StyleWidthUnit.Px, 400f)))))
        val outer = Block("container", 0, emptyList(), container = Container(listOf(inner),
            ContainerStyle(overflow = ContainerOverflow.Auto)))
        val horizontal = SemanticsMatcher("an actual horizontal scroll owner") {
            it.config.getOrNull(SemanticsProperties.HorizontalScrollAxisRange) != null
        }
        val innerScroll = compose.onNodeWithTag("compiled-table-block-content", useUnmergedTree = true)
        val outerScroll = compose.onNode(horizontal and !hasTestTag("compiled-table-block-content"), useUnmergedTree = true)
        fun windowBox(node: SemanticsNodeInteraction): RectF {
            val semantic = node.fetchSemanticsNode()
            val origin = semantic.positionInWindow
            return RectF(origin.x, origin.y, origin.x + semantic.size.width, origin.y + semantic.size.height)
        }
        fun axis(node: SemanticsNodeInteraction) = node.fetchSemanticsNode().config[SemanticsProperties.HorizontalScrollAxisRange]
        fun rejectClippedGlyph(view: NativeFloatTextView, node: FloatInteractionNode,
            inside: RectF, outside: RectF, intrinsicHit: Boolean) {
            val geometry = checkNotNull(view.currentMeasuredGeometry)
            val origin = IntArray(2); view.getLocationInWindow(origin)
            assertEquals(0, view.scrollX); assertEquals(0, view.scrollY)
            // This source fixture is horizontal LTR monospace. Adjacent logical carets retain
            // the real advance even when the viewport has clipped its character rectangle.
            val point = (node.start until node.end).mapNotNull { index ->
                if (view.logicalText[index].isWhitespace()) null else {
                    val first = geometry.caretRect(index)
                    val last = geometry.caretRect(index + 1)
                    if (kotlin.math.abs(first.top - last.top) > .01f || last.centerX() <= first.centerX()) null else {
                        val x = (first.centerX() + last.centerX()) / 2f
                        val y = (first.centerY() + last.centerY()) / 2f
                        val windowX = origin[0] + view.paddingLeft + x
                        val windowY = origin[1] + view.paddingTop + y
                        if (inside.contains(windowX, windowY) && !outside.contains(windowX, windowY)) x to y else null
                    }
                }
            }.firstOrNull()
            assertNotNull("A real source glyph must cross this independent clip", point)
            val (x, y) = checkNotNull(point)
            if (intrinsicHit) assertEquals(node.id, geometry.interactionNodeAt(x, y)?.id)
            inputGuard()
            val now = SystemClock.uptimeMillis()
            val event = MotionEvent.obtain(now, now, MotionEvent.ACTION_DOWN,
                x + view.paddingLeft, y + view.paddingTop, 0)
            try { assertFalse("The real View must reject an out-of-clip source glyph", view.dispatchTouchEvent(event)) }
            finally { event.recycle() }
            assertTrue(opened.isEmpty())
            assertFalse(node.missingLinkPaint!!.active)
        }
        fun assertNativeClipBounds(view: NativeFloatTextView, node: FloatInteractionNode, visibleWindow: RectF) {
            val info = checkNotNull(view.accessibilityNodeProvider.createAccessibilityNodeInfo(node.id))
            try {
                assertEquals(right.text, info.text.toString())
                assertTrue(info.isClickable)
                assertTrue(info.isVisibleToUser)
                val screenOrigin = IntArray(2); view.getLocationOnScreen(screenOrigin)
                val windowOrigin = IntArray(2); view.getLocationInWindow(windowOrigin)
                val sourceBounds = RectF()
                node.bounds.forEach { sourceBounds.union(it) }
                val screenBounds = RectF(sourceBounds).apply {
                    offset(screenOrigin[0] + view.paddingLeft.toFloat() - view.scrollX,
                        screenOrigin[1] + view.paddingTop.toFloat() - view.scrollY)
                }
                val screenClip = RectF(visibleWindow).apply {
                    offset((screenOrigin[0] - windowOrigin[0]).toFloat(), (screenOrigin[1] - windowOrigin[1]).toFloat())
                }
                assertTrue(screenBounds.intersect(screenClip))
                val expected = Rect(); screenBounds.roundOut(expected)
                val actual = Rect(); info.getBoundsInScreen(actual)
                assertEquals("Native AX must retain both independent screen clips", expected, actual)
                val local = Rect(); sourceBounds.roundOut(local); local.offset(view.paddingLeft, view.paddingTop)
                val localClip = RectF(visibleWindow).apply { offset(-windowOrigin[0].toFloat(), -windowOrigin[1].toFloat()) }
                val roundedClip = Rect(); localClip.roundOut(roundedClip)
                assertTrue(local.intersect(roundedClip))
                val parent = Rect(); info.getBoundsInParent(parent)
                assertEquals("Native AX must retain both independent local clips", local, parent)
            } finally { info.recycle() }
        }
        fun scroll(node: SemanticsNodeInteraction, amount: Float) {
            node.performSemanticsAction(SemanticsActions.ScrollBy) { assertTrue(it(amount, 0f)) }
            compose.waitForIdle()
        }
        fun assertPaintInsideBothClips() {
            val clip = windowBox(innerScroll)
            assertTrue(clip.intersect(windowBox(outerScroll)))
            val root = compose.onRoot().fetchSemanticsNode().positionInWindow
            val bitmap = compose.onRoot().captureToImage().asAndroidBitmap()
            try {
                val authoredColors = colors.indices.map(::argb).toSet() + android.graphics.Color.RED
                var count = 0
                for (y in 0 until bitmap.height) for (x in 0 until bitmap.width) {
                    if (bitmap.getPixel(x, y) in authoredColors) {
                        count++
                        assertTrue("Authored ink escaped the composed scroll clips", clip.contains(root.x + x + .5f, root.y + y + .5f))
                    }
                }
                assertTrue("The actual clipped source action must remain painted", count > 0)
            } finally { bitmap.recycle() }
        }
        withScene({ Scene(visits, owner, 260) {
            CompositionLocalProvider(LocalTableDocumentViewportCssWidth provides 639.0) {
                NativeFloatBlockContext(listOf(outer), { opened += it }, "nested-source-actions", Modifier,
                    inCell = false, gridPath = "root", gapDp = 0f, trailingGap = false)
            }
        } }) {
            assertNoRefusal()
            compose.onAllNodes(horizontal, useUnmergedTree = true).assertCountEquals(2)
            assertTrue(axis(innerScroll).maxValue() > 0f)
            assertTrue(axis(outerScroll).maxValue() > 0f)
            val identities = mutableMapOf<String, MissingLinkActionIdentity>()
            val ranges = mutableMapOf<String, Pair<Int, Int>>()
            compose.runOnIdle {
                for (label in listOf(left.text, right.text)) {
                    val view = viewFor(label)
                    val node = paintNodes(view).single { it.label.toString() == label }
                    identities[label] = checkNotNull(node.missingLinkPaint!!.actionIdentity)
                    ranges[label] = node.start to node.end
                    assertEquals(label, view.logicalText.subSequence(node.start, node.end).toString())
                    assertEquals(FloatInteractionKind.LINK, node.kind)
                    assertFalse(node.missingLinkPaint!!.focused)
                    assertEquals(argb(0), node.missingLinkPaint!!.appearance().color)
                }
                val view = viewFor(left.text)
                inputGuard()
                assertTrue(view.requestFocus()) // Reader host focus is not a source A focus owner.
                paintNodes(view).forEach { assertFalse(it.missingLinkPaint!!.focused) }
                assertTrue(opened.isEmpty())
            }
            scroll(innerScroll, axis(innerScroll).maxValue() / 2f)
            val firstInner = windowBox(innerScroll)
            val firstOuter = windowBox(outerScroll)
            compose.runOnIdle {
                val view = viewFor(right.text)
                val node = paintNodes(view).single { it.label.toString() == right.text }
                rejectClippedGlyph(view, node, firstInner, firstOuter, intrinsicHit = true)
            }
            scroll(outerScroll, 10000f)
            val intermediateClip = windowBox(innerScroll)
            assertTrue(intermediateClip.intersect(windowBox(outerScroll)))
            val intermediateInner = windowBox(innerScroll)
            val intermediateOuter = windowBox(outerScroll)
            compose.runOnIdle {
                val view = viewFor(right.text)
                val node = paintNodes(view).single { it.label.toString() == right.text }
                assertNativeClipBounds(view, node, intermediateClip)
                rejectClippedGlyph(view, node, intermediateOuter, intermediateInner, intrinsicHit = false)
                assertFalse(node.missingLinkPaint!!.focused)
                assertEquals(argb(0), node.missingLinkPaint!!.appearance().color)
                assertTrue(opened.isEmpty())
            }
            assertPaintInsideBothClips()
            scroll(innerScroll, 10000f)
            assertEquals(axis(innerScroll).maxValue(), axis(innerScroll).value(), .01f)
            assertEquals(axis(outerScroll).maxValue(), axis(outerScroll).value(), .01f)
            assertNoRefusal()
            val visibleWindow = windowBox(innerScroll)
            assertTrue(visibleWindow.intersect(windowBox(outerScroll)))
            compose.runOnIdle {
                val view = viewFor(right.text)
                val geometry = checkNotNull(view.currentMeasuredGeometry)
                val node = paintNodes(view).single { it.label.toString() == right.text }
                assertTrue(geometry.nodes.all { it.kind == FloatInteractionKind.LINK })
                assertEquals(identities[right.text], node.missingLinkPaint!!.actionIdentity)
                assertEquals(ranges[right.text], node.start to node.end)
                assertFalse(node.missingLinkPaint!!.focused)
                assertEquals(argb(0), node.missingLinkPaint!!.appearance().color)
                val hit = node.bounds.first { !it.isEmpty }
                assertEquals(node.id, geometry.interactionNodeAt(hit.centerX(), hit.centerY())!!.id)
                assertNativeClipBounds(view, node, visibleWindow)
                val hiddenView = viewFor(left.text)
                val hidden = paintNodes(hiddenView).single { it.label.toString() == left.text }
                val hiddenInfo = checkNotNull(hiddenView.accessibilityNodeProvider.createAccessibilityNodeInfo(hidden.id))
                try {
                    val hiddenBounds = Rect(); hiddenInfo.getBoundsInScreen(hiddenBounds)
                    assertEquals(left.text, hiddenInfo.text.toString())
                    assertTrue(hiddenBounds.isEmpty)
                    assertFalse(hiddenInfo.isVisibleToUser)
                    assertEquals(identities[left.text], hidden.missingLinkPaint!!.actionIdentity)
                } finally { hiddenInfo.recycle() }
                view.setSelection(node.start, node.end)
                assertEquals(right.text, view.selectedTextForCopy())
                inputGuard()
                view.dispatchKeyEvent(KeyEvent(KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_ESCAPE))
                assertTrue(view.accessibilityNodeProvider.performAction(node.id, AccessibilityNodeInfo.ACTION_ACCESSIBILITY_FOCUS, null))
                assertFalse(node.missingLinkPaint!!.focused)
                assertTrue(view.accessibilityNodeProvider.performAction(node.id, AccessibilityNodeInfo.ACTION_FOCUS, null))
                assertTrue(node.missingLinkPaint!!.focused)
                assertTrue(node.missingLinkPaint!!.appearance().underline)
                assertTrue(opened.isEmpty())
            }
            compose.waitForIdle()
            assertInk(android.graphics.Color.RED)
            assertPaintInsideBothClips()
            compose.runOnIdle {
                val view = viewFor(right.text)
                val node = paintNodes(view).single { it.label.toString() == right.text }
                assertTrue(view.accessibilityNodeProvider.performAction(node.id, AccessibilityNodeInfo.ACTION_CLEAR_FOCUS, null))
                click(view, node)
                assertEquals(listOf(EntryLink("RU-right", targetFragment = "section-right")), opened)
            }
            compose.waitForIdle()
            compose.runOnIdle {
                val view = viewFor(right.text)
                val node = paintNodes(view).single { it.label.toString() == right.text }
                assertEquals(identities[right.text], node.missingLinkPaint!!.actionIdentity)
                assertEquals(ranges[right.text], node.start to node.end)
                assertTrue(node.missingLinkPaint!!.visited)
                assertEquals(argb(4), node.missingLinkPaint!!.appearance().color)
                assertFalse(node.missingLinkPaint!!.focused)
                assertTrue(view.requestFocus())
                assertFalse(node.missingLinkPaint!!.focused)
                assertTrue(view.accessibilityNodeProvider.performAction(node.id, AccessibilityNodeInfo.ACTION_FOCUS, null))
                assertTrue(node.missingLinkPaint!!.visited)
                assertTrue(node.missingLinkPaint!!.focused)
                assertEquals(argb(4), node.missingLinkPaint!!.appearance().color)
                assertTrue(node.missingLinkPaint!!.appearance().underline)
                assertEquals(identities[right.text], node.missingLinkPaint!!.actionIdentity)
                assertEquals(ranges[right.text], node.start to node.end)
            }
            compose.waitForIdle()
            assertInk(android.graphics.Color.RED)
            assertPaintInsideBothClips()
            val visitedClip = windowBox(innerScroll)
            assertTrue(visitedClip.intersect(windowBox(outerScroll)))
            compose.runOnIdle {
                val view = viewFor(right.text)
                val node = paintNodes(view).single { it.label.toString() == right.text }
                assertNativeClipBounds(view, node, visitedClip)
                assertTrue(view.accessibilityNodeProvider.performAction(node.id, AccessibilityNodeInfo.ACTION_CLEAR_FOCUS, null))
                assertFalse(node.missingLinkPaint!!.focused)
                assertTrue(node.missingLinkPaint!!.visited)
                assertEquals(argb(4), node.missingLinkPaint!!.appearance().color)
            }
            scroll(outerScroll, -10000f)
            scroll(innerScroll, -10000f)
            compose.runOnIdle {
                val view = viewFor(left.text)
                val node = paintNodes(view).single { it.label.toString() == left.text }
                assertEquals(identities[left.text], node.missingLinkPaint!!.actionIdentity)
                assertEquals(ranges[left.text], node.start to node.end)
                assertFalse(node.missingLinkPaint!!.visited)
                assertFalse(node.missingLinkPaint!!.focused)
                click(view, node)
                assertEquals(listOf(EntryLink("RU-right", targetFragment = "section-right"),
                    EntryLink("RU-left", targetFragment = "section-left")), opened)
            }
        }
    }
}
