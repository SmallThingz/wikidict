package app.smallthingz.dict

import android.graphics.Rect
import android.graphics.RectF
import android.graphics.Typeface
import android.text.TextPaint
import android.text.style.MetricAffectingSpan
import android.view.KeyEvent
import android.view.View
import android.view.accessibility.AccessibilityNodeInfo
import androidx.activity.compose.setContent
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.width
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Typography
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.toPixelMap
import androidx.compose.ui.layout.AlignmentLine
import androidx.compose.ui.layout.FirstBaseline
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalFontFamilyResolver
import androidx.compose.ui.platform.LocalLayoutDirection
import androidx.compose.ui.test.*
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import kotlin.math.ceil
import kotlin.math.floor

/** Synthetic source controls through the real cell/Container/native input owners; no corpus claim. */
class CellOwnerFontDeviceTest {
    @get:Rule val compose = createPhysicalComposeRule()
    private val body = TextStyle(fontSize = 20.sp, fontFamily = FontFamily.Serif, letterSpacing = 0.sp)
    private val zero = StyleLength(StyleLengthUnit.Px, 0f)
    private val edges = StyleEdges(zero, zero, zero, zero)
    private val actions = mutableListOf<EntryLink>()
    private val failures = mutableListOf<String>()
    private var prepared: PreparedNativeFloatText? = null
    private var ownerTypeface: Typeface? = null
    private var childTypeface: Typeface? = null
    private lateinit var activity: MainActivity
    private fun font(size: Float = .5f, family: ContainerFontFamily = ContainerFontFamily.SansSerif,
        language: String = "th") = InlineFontSnapshot(fontScale = size, fontScaleBasis = FontScaleBasis.NormalBody,
        language = language, fontFeatures = FontFeaturePolicy.SevenOn, fontFamily = family)
    private fun height(font: InlineFontSnapshot, value: CellLineHeightValue = CellLineHeightValue.Normal) =
        CellLineHeight(value, CellTextStrut(font.fontScale!!, font.fontScaleBasis, font))
    private fun cell(spans: List<Span>, font: InlineFontSnapshot = font(), header: Boolean = false,
        value: CellLineHeightValue = CellLineHeightValue.Normal, blocks: List<Block>? = null) =
        Cell(spans, header, 1, 1, blocks = blocks,
            style = CellStyle(border = StyleBorder.None, padding = edges, lineHeight = height(font, value)))
    private fun table(rows: List<List<Cell>>) = Table(emptyList(), rows,
        TableGeometry(border = 0, cellSpacing = 0, cellPadding = 0),
        style = TableStyle(border = StyleBorder.None, background = "#ffffff",
            width = StyleWidth(StyleWidthUnit.Percent, 100f)))
    private fun entry(table: Table) = Entry("Cell owner control", emptyList(), "language", "Japanese", "ja",
        listOf(Section(2, "", listOf(Block("table", 0, emptyList(), table = table)))), emptyList())
    private fun link(label: String, size: Float = 12f) = Span("link", label, label,
        fontScale = size, fontScaleBasis = FontScaleBasis.CssPx, language = "en",
        fontFeatures = FontFeaturePolicy.Normal)

    @Composable private fun Host(table: Table, width: Int = 280, direction: LayoutDirection = LayoutDirection.Ltr,
        probe: NativeNamedFontProbe? = null, extra: @Composable () -> Unit = {}) {
        CompositionLocalProvider(LocalDensity provides Density(1f), LocalLayoutDirection provides direction,
            LocalNativeFloatContextFailureObserver provides { failures += it }) {
            MaterialTheme(typography = Typography(bodyLarge = body), colorScheme = lightColorScheme(
                primary = Color.Black, onSurface = Color.Black, onSurfaceVariant = Color.Black,
                surface = Color.White, background = Color.White)) {
                val content: @Composable () -> Unit = {
                    extra()
                    Box(Modifier.width(width.dp).background(Color.White)) {
                        EntryView(entry(table), false, {}, onLink = { actions += it }, settings = AppSettings(
                            allowImages = false, allowAudio = false, collapseOtherSections = false, collapseDetails = false))
                    }
                }
                if (probe == null) content() else CompositionLocalProvider(LocalNativeNamedFontProbe provides probe) { content() }
            }
        }
    }
    private fun control(block: () -> Unit) {
        var primary: Throwable? = null
        try { block() } catch (failure: Throwable) { primary = failure; throw failure }
        finally {
            try { compose.activityRule.scenario.onActivity { it.setContent {} }; compose.waitForIdle() }
            catch (failure: Throwable) {
                val original = primary
                if (original == null) throw failure
                if (original !== failure) original.addSuppressed(failure)
            }
        }
    }
    private fun views(): List<NativeFloatTextView> {
        val result = mutableListOf<NativeFloatTextView>()
        fun visit(view: View) {
            if (view is NativeFloatTextView && view.isShown) result += view
            if (view is android.view.ViewGroup) repeat(view.childCount) { visit(view.getChildAt(it)) }
        }
        visit(activity.window.decorView)
        return result
    }
    private fun owner(label: String) = views().single { view ->
        view.currentMeasuredGeometry?.nodes?.count { it.label?.toString() == label } == 1
    }
    private fun node(view: NativeFloatTextView, label: String) = checkNotNull(view.currentMeasuredGeometry)
        .nodes.single { it.label?.toString() == label }
    private fun ready() {
        compose.onAllNodesWithText("Unable to display this layout.").assertCountEquals(0)
        compose.onAllNodesWithText("unavailable", substring = true, ignoreCase = true).assertCountEquals(0)
    }
    private fun nativeAction(label: String, inspectInk: Boolean = false) {
        val view = compose.runOnIdle { owner(label) }
        val boxes = compose.runOnIdle {
            val geometry = checkNotNull(view.currentMeasuredGeometry)
            val target = node(view, label)
            assertEquals(label, geometry.text.subSequence(target.start, target.end).toString())
            view.setSelection(target.start, target.end)
            assertEquals(label, view.selectedTextForCopy())
            assertEquals(geometry.rectsForRange(target.start, target.end), target.bounds)
            view.dispatchKeyEvent(KeyEvent(KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_ESCAPE))
            val ax = checkNotNull(view.accessibilityNodeProvider.createAccessibilityNodeInfo(target.id))
            assertTrue(ax.isClickable); assertEquals(label, ax.text?.toString()); assertTrue(ax.isVisibleToUser)
            val location = IntArray(2); view.getLocationOnScreen(location)
            val origin = Offset(location[0].toFloat() + view.paddingLeft, location[1].toFloat() + view.paddingTop)
            val rects = target.bounds.filterNot { it.isEmpty }.map { RectF(it).apply { offset(origin.x, origin.y) } }
            val expected = RectF(rects.first()).apply { rects.drop(1).forEach(::union) }
            val expectedScreen = Rect(); expected.roundOut(expectedScreen)
            val screen = Rect(); ax.getBoundsInScreen(screen)
            assertEquals(expectedScreen, screen)
            assertEquals(target.id, geometry.interactionNodeAt(target.bounds.first().centerX(), target.bounds.first().centerY())?.id)
            rects
        }
        val root = compose.onRoot().fetchSemanticsNode().positionOnScreen
        if (inspectInk) {
            val pixels = compose.onRoot().captureToImage().toPixelMap()
            val box = boxes.first()
            var ink = false
            for (y in floor(box.top - root.y).toInt().coerceAtLeast(0) until ceil(box.bottom - root.y).toInt().coerceAtMost(pixels.height))
                for (x in floor(box.left - root.x).toInt().coerceAtLeast(0) until ceil(box.right - root.x).toInt().coerceAtMost(pixels.width)) {
                    val color = pixels[x, y]
                    if (color.red < .4f && color.green < .4f && color.blue < .4f && color.alpha > .8f) ink = true
                }
            assertTrue("Actual cell glyph ink must be present at the native hit/AX rectangle", ink)
        }
        val before = actions.size
        compose.onRoot().performTouchInput { click(Offset(boxes.first().centerX(), boxes.first().centerY()) - root) }
        compose.runOnIdle { assertEquals(before + 1, actions.size); assertEquals(EntryLink(label), actions.last()) }
    }
    private fun retainedAction(label: String) {
        compose.onNodeWithText("Unable to display this layout.").assertExists()
        val node = compose.onNodeWithText(label, useUnmergedTree = true).assertIsDisplayed()
        val layouts = mutableListOf<androidx.compose.ui.text.TextLayoutResult>()
        node.performSemanticsAction(androidx.compose.ui.semantics.SemanticsActions.GetTextLayoutResult) { it(layouts) }
        val before = actions.size
        node.performTouchInput { click(layouts.single().getBoundingBox(0).center) }
        compose.runOnIdle { assertEquals(before + 1, actions.size); assertEquals(EntryLink(label), actions.last()) }
    }

    @Test fun actualHeaderCellKeepsIndependentOwnerAndChildPaintThroughWrappedLayoutCopyHitAndAx() = control {
        val size = mutableStateOf(.5f); val width = mutableStateOf(260); val rtl = mutableStateOf(false)
        val longLabel = "alpha beta gamma delta epsilon"
        val source = listOf(link("tiny", 4f), Span("text", " ", fontScale = 4f, fontScaleBasis = FontScaleBasis.CssPx),
            link(longLabel).copy(code = true, bold = true, italic = true))
        compose.activityRule.scenario.onActivity { activity -> this.activity = activity; activity.setContent {
            val selected = cell(source, font(size.value), header = true)
            Host(table(listOf(listOf(selected))), width.value, if (rtl.value) LayoutDirection.Rtl else LayoutDirection.Ltr) {
                // This is the real lowerer with the same cell state and an unrelated larger UI
                // default. It exposes public prepared paints, without a renderer debug hook.
                val inherited = body.copy(fontSize = 72.sp, fontWeight = FontWeight.Black, fontStyle = FontStyle.Italic)
                val resolver = LocalFontFamilyResolver.current
                val ownerFace = resolver.resolve(FontFamily.SansSerif, FontWeight.Normal, FontStyle.Normal).value as Typeface
                val childFace = resolver.resolve(FontFamily.Serif, FontWeight.Normal, FontStyle.Normal).value as Typeface
                val state = nativeCellTextContext(selected, null, inherited, body.fontSize, LocalDensity.current, 1f, null)
                CompositionLocalProvider(LocalNativeContainerTextContext provides state, LocalCellWeight provides FontWeight.Bold) {
                    val result = prepareNativeFloatText(source, styledTextAnnotation(source, null, inherited) {},
                        egyptianTextRuns(source), inherited, Color.Black, emptyList(), AppSettings(), "", {},
                        nativeLineHeight = NativeLineHeightPolicy.Normal)
                    SideEffect { prepared = result; ownerTypeface = ownerFace; childTypeface = childFace }
                }
            }
        } }
        compose.waitForIdle()
        var wideLines = 0
        var smallHeight = 0f
        for ((ownerScale, available, direction) in listOf(Triple(.5f, 260, false), Triple(.5f, 80, true),
            Triple(2.4f, 80, true), Triple(.5f, 260, false))) {
            compose.runOnIdle { size.value = ownerScale; width.value = available; rtl.value = direction }
            compose.waitForIdle(); ready()
            compose.runOnIdle {
                val p = checkNotNull(prepared); val native = checkNotNull(p.native)
                assertEquals(ownerScale * 20f, native.paint.textSize, .001f)
                assertEquals("th", native.paint.textLocale.toLanguageTag())
                assertFalse(native.paint.typeface.isBold); assertFalse(native.paint.typeface.isItalic)
                assertEquals(ownerTypeface, native.paint.typeface)
                assertEquals(FontFeaturePolicy.SevenOn.nativeSettings, native.paint.fontFeatureSettings)
                val text = native.source(available)
                assertEquals("tiny $longLabel", text.toString())
                val root = text.getSpans(0, text.length, NativeRunLineMetrics::class.java).single { it.strut }
                assertTrue(root.includePrimaryInNormal)
                assertEquals(ownerScale * 20f, root.primary.fontSize, .001f)
                val child = TextPaint(native.paint)
                text.getSpans(0, 1, MetricAffectingSpan::class.java).forEach { it.updateMeasureState(child) }
                assertEquals(4f, child.textSize, .001f)
                assertFalse(child.typeface.isBold); assertFalse(child.typeface.isItalic)
                assertEquals(childTypeface, child.typeface)
                val geometry = checkNotNull(p.geometry)(available, emptyList(), false)
                assertTrue(geometry.extents.usedHeight < 72f || available == 80)
                val widget = owner(longLabel)
                val target = node(widget, longLabel)
                val lines = target.bounds.map { it.top }.distinct().size
                if (available == 260) { if (wideLines == 0) wideLines = lines else assertEquals(wideLines, lines) }
                else assertTrue("The real cell must wrap at its new width", lines > wideLines)
                val actualHeight = checkNotNull(widget.currentMeasuredGeometry).extents.usedHeight
                if (available == 80 && ownerScale == .5f) smallHeight = actualHeight
                if (ownerScale == 2.4f) assertTrue(actualHeight > smallHeight)
            }
            nativeAction(longLabel, inspectInk = true)
        }
    }

    @Test fun lineHeightOnlyKeepsTheOwnerFontChangesRefuseAndNewNestedCellsResetIndependently() = control {
        val mode = mutableStateOf(0)
        val sourceFont = font(.7f)
        compose.activityRule.scenario.onActivity { activity -> this.activity = activity; activity.setContent {
            val style = when (mode.value) {
                1, 3 -> ContainerStyle(ownerFontScale = 2f)
                2 -> ContainerStyle(ownerFontScale = .7f, fontFamily = ContainerFontFamily.SansSerif,
                    lineHeight = ContainerLineHeight.Multiplier(1.1f))
                else -> ContainerStyle(lineHeight = ContainerLineHeight.Multiplier(1.1f))
            }
            val descendants = if (mode.value == 3) {
                val fresh = cell(listOf(link("Fresh")), font(.6f, language = "ru"))
                val legacy = Cell(listOf(link("Legacy reset")), false, 1, 1,
                    style = CellStyle(border = StyleBorder.None, padding = edges))
                listOf(Block("table", 0, emptyList(), table = table(listOf(listOf(fresh, legacy)))))
            } else listOf(Block("paragraph", 0, listOf(link("Retained"))))
            val block = Block("container", 0, emptyList(), container = Container(descendants, style))
            Host(table(listOf(listOf(cell(emptyList(), sourceFont, blocks = listOf(block))))))
        } }
        compose.waitForIdle(); ready(); nativeAction("Retained")
        val initial = compose.runOnIdle { checkNotNull(owner("Retained").currentMeasuredGeometry).extents.usedHeight }
        compose.runOnIdle { failures.clear(); mode.value = 1 }; compose.waitForIdle()
        compose.runOnIdle { assertTrue(failures.contains(NativeCellOwnerFontChanged)) }
        retainedAction("Retained")
        compose.runOnIdle { failures.clear(); mode.value = 2 }; compose.waitForIdle(); ready()
        compose.runOnIdle {
            assertTrue(failures.isEmpty())
            assertEquals(initial, checkNotNull(owner("Retained").currentMeasuredGeometry).extents.usedHeight, .001f)
        }
        nativeAction("Retained")
        compose.runOnIdle { failures.clear(); mode.value = 3 }; compose.waitForIdle(); ready()
        compose.runOnIdle { assertTrue(failures.isEmpty()) }
        nativeAction("Fresh"); nativeAction("Legacy reset")
    }

    @Test fun strictLanguageAndNamedFamilyFailuresKeepTheSourceActionAndRecoverWithoutBorrowedHeaderTraits() = control {
        val mode = mutableStateOf(0)
        val requests = mutableListOf<Triple<String, FontWeight, FontStyle>>()
        compose.activityRule.scenario.onActivity { activity -> this.activity = activity; activity.setContent {
            val probe = remember(mode.value) { NativeNamedFontProbe { _, name, weight, style ->
                requests += Triple(name, weight, style)
                when (mode.value) { 2 -> Typeface.SERIF; 4 -> throw IllegalStateException("controlled font failure"); else -> null }
            } }
            val selected = if (mode.value == 0) font(language = "i-klingon") else if (mode.value in 2..4)
                font(family = ContainerFontFamily.Stack(listOf("Controlled Cell"), GenericFontFamily.Serif)) else font()
            Host(table(listOf(listOf(cell(listOf(link("Original")), selected, header = true)))), probe = probe)
        } }
        compose.waitForIdle()
        compose.runOnIdle { assertTrue(failures.contains(NativeCellOwnerFontUnavailable)) }
        retainedAction("Original")
        for (next in listOf(1, 2, 3, 4, 1)) {
            compose.runOnIdle { failures.clear(); requests.clear(); mode.value = next }; compose.waitForIdle()
            if (next == 2 || next == 4) {
                compose.runOnIdle { assertTrue(failures.contains(if (next == 2) NativeNamedFamilyUnavailable else NativeNamedFamilyProbeUnavailable)) }
                retainedAction("Original")
            } else { ready(); nativeAction("Original") }
            if (next in 2..4) compose.runOnIdle {
                assertTrue(requests.any { it.first == "Controlled Cell" })
                assertTrue(requests.filter { it.first == "Controlled Cell" }.all {
                    it.second == FontWeight.Normal && it.third == FontStyle.Normal })
            }
        }
    }

    @Test fun trueEmptyNbspAndSemanticZeroKeepTheirExistingLineAndActionPresence() = control {
        val zeroFont = mutableStateOf(true)
        compose.activityRule.scenario.onActivity { activity -> this.activity = activity; activity.setContent {
            val empty = cell(emptyList(), font(.7f), value = CellLineHeightValue.Multiplier(1f))
            val nbsp = empty.copy(spans = listOf(Span("text", "\u00a0")))
            val action = cell(listOf(Span("link", "Zero", "Zero")), font(if (zeroFont.value) 0f else .7f),
                value = CellLineHeightValue.Multiplier(if (zeroFont.value) 0f else 1f))
            Host(table(listOf(listOf(empty, nbsp, action))))
        } }
        compose.waitForIdle(); ready()
        val empty = compose.onNodeWithTag("compiled-table-cell-root-0", useUnmergedTree = true).fetchSemanticsNode()
        val nbsp = compose.onNodeWithTag("compiled-table-cell-root-1", useUnmergedTree = true).fetchSemanticsNode()
        assertEquals(AlignmentLine.Unspecified, empty.getAlignmentLinePosition(FirstBaseline))
        assertNotEquals(AlignmentLine.Unspecified, nbsp.getAlignmentLinePosition(FirstBaseline))
        compose.runOnIdle {
            val view = owner("Zero"); val geometry = checkNotNull(view.currentMeasuredGeometry); val target = node(view, "Zero")
            assertEquals("Zero", geometry.text.toString())
            assertEquals(0f, geometry.extents.usedHeight, 0f)
            assertEquals(NativeTextBaselines(0f, 0f), geometry.textBaselines)
            assertTrue(target.bounds.all { it.isEmpty })
            view.setSelection(target.start, target.end); assertEquals("Zero", view.selectedTextForCopy())
            val provider = view.accessibilityNodeProvider
            assertTrue(checkNotNull(provider.createAccessibilityNodeInfo(target.id)).isClickable)
            assertTrue(provider.performAction(target.id, AccessibilityNodeInfo.ACTION_CLICK, null))
            assertEquals(EntryLink("Zero"), actions.last())
        }
        compose.runOnIdle { zeroFont.value = false }; compose.waitForIdle(); ready(); nativeAction("Zero", inspectInk = true)
    }
}
