package app.smallthingz.dict

import android.graphics.Paint
import android.graphics.Typeface
import android.text.TextPaint
import android.view.KeyEvent
import android.view.View
import android.view.accessibility.AccessibilityNodeInfo
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.width
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Typography
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.layout.AlignmentLine
import androidx.compose.ui.layout.FirstBaseline
import androidx.compose.ui.layout.LastBaseline
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalLayoutDirection
import androidx.compose.ui.test.*
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import kotlin.math.roundToInt

class CellLineHeightDeviceTest {
    @get:Rule val compose = createPhysicalComposeRule()
    private val body = TextStyle(fontSize = 20.sp, fontFamily = FontFamily.Serif, letterSpacing = 0.sp)
    private fun px(n: Float) = StyleLength(StyleLengthUnit.Px, n)
    private val zeroEdges = StyleEdges(px(0f), px(0f), px(0f), px(0f))
    private fun fixed(n: Float, basis: FontScaleBasis = FontScaleBasis.NormalBody) =
        CellLineHeightValue.Length(CellFixedLineHeight(n, basis))
    private fun policy(n: Float = .7f) = CellLineHeight(fixed(n), CellTextStrut(n, FontScaleBasis.NormalBody))
    private fun table(rows: List<List<Cell>>, height: ComputedLineHeight? = null, caption: List<Span> = emptyList()) =
        Table(caption, rows, TableGeometry(border = 0, cellSpacing = 0, cellPadding = 0),
            style = TableStyle(border = StyleBorder.None, lineHeight = height))
    private fun entry(table: Table) = Entry("Cell control", emptyList(), "language", "English", "en",
        listOf(Section(2, "", listOf(Block("table", 0, emptyList(), table = table)))), emptyList())
    private fun views(): List<NativeFloatTextView> {
        val result = mutableListOf<NativeFloatTextView>()
        compose.activityRule.scenario.onActivity { activity ->
            fun visit(v: View) {
                if (v is NativeFloatTextView) result += v
                if (v is android.view.ViewGroup) for (i in 0 until v.childCount) visit(v.getChildAt(i))
            }
            visit(activity.window.decorView)
        }
        return result
    }
    private fun owner(label: String) = views().single { view ->
        view.currentMeasuredGeometry?.nodes?.count { it.label?.toString() == label } == 1
    }
    private fun node(view: NativeFloatTextView, label: String) = checkNotNull(view.currentMeasuredGeometry)
        .nodes.single { it.label?.toString() == label }
    private fun used(view: NativeFloatTextView): FloatTextGeometry {
        var g = checkNotNull(view.currentMeasuredGeometry)
        while (g is NativeSurfaceGeometry) g = g.content
        return g
    }
    private fun paint(size: Float, family: Typeface = Typeface.SERIF, weight: Int = 400, italic: Boolean = false) =
        TextPaint(Paint.ANTI_ALIAS_FLAG).apply { textSize = size; typeface = Typeface.create(family, weight, italic) }
    private fun width(view: NativeFloatTextView, label: String, expected: TextPaint) {
        val n = node(view, label)
        assertEquals(expected.measureText(label), n.bounds.sumOf { it.width().toDouble() }.toFloat(), 2f)
    }
    private fun selectAndActivate(view: NativeFloatTextView, label: String, actions: MutableList<EntryLink>) {
        val point = compose.runOnIdle {
            val g = checkNotNull(view.currentMeasuredGeometry); val n = node(view, label)
            assertEquals(label, g.text.subSequence(n.start, n.end).toString())
            val ax = checkNotNull(view.accessibilityNodeProvider.createAccessibilityNodeInfo(n.id))
            assertTrue(ax.isClickable); assertEquals(label, ax.text?.toString())
            view.setSelection(n.start, n.end); assertEquals(label, view.selectedTextForCopy())
            view.dispatchKeyEvent(KeyEvent(KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_ESCAPE))
            val box = n.bounds.first { !it.isEmpty }; val location = IntArray(2); view.getLocationOnScreen(location)
            Offset(location[0] + box.centerX() + view.paddingLeft, location[1] + box.centerY() + view.paddingTop)
        }
        val root = compose.onRoot().fetchSemanticsNode().positionOnScreen
        val before = actions.size
        compose.onRoot().performTouchInput { click(point - root) }
        compose.runOnIdle { assertEquals(before + 1, actions.size); assertEquals(EntryLink(label), actions.last()) }
    }

    @Test fun actualCellStrutAndComputedTraitsKeepFixedHeightBaselineActionsAndSelectionAcrossReflow() {
        val availableWidth = mutableStateOf(320); val direction = mutableStateOf(LayoutDirection.Ltr)
        val multiplier = mutableStateOf(false); val actions = mutableListOf<EntryLink>()
        val spans = listOf(Span("link", "MMMM", "MMMM", bold = true, italic = true, code = true,
            fontScale = 2f, fontScaleBasis = FontScaleBasis.NormalBody), Span("text", " "),
            Span("link", "reset", "reset"))
        try {
            compose.activityRule.scenario.onActivity { it.setContent {
                CompositionLocalProvider(LocalDensity provides Density(1f), LocalLayoutDirection provides direction.value) {
                    MaterialTheme(typography = Typography(bodyLarge = body)) {
                        val height = if (multiplier.value) CellLineHeightValue.Multiplier(1f) else fixed(.7f)
                        val cell = Cell(spans, true, 1, 1, style = CellStyle(padding = StyleEdges(px(3f), px(3f), px(3f), px(3f)),
                            border = StyleBorder.None, lineHeight = CellLineHeight(height, CellTextStrut(.7f, FontScaleBasis.NormalBody))))
                        Box(Modifier.width(availableWidth.value.dp)) { EntryView(entry(table(listOf(listOf(cell)))), false, {}, onLink = { actions += it },
                            settings = AppSettings(allowImages = false, allowAudio = false, collapseOtherSections = false, collapseDetails = false)) }
                    }
                }
            } }
            compose.waitForIdle(); val original = owner("MMMM")
            for (useNumber in listOf(false, true)) for (rtl in listOf(false, true)) {
                compose.runOnIdle { multiplier.value = useNumber; direction.value = if (rtl) LayoutDirection.Rtl else LayoutDirection.Ltr; availableWidth.value = if (rtl) 280 else 320 }
                compose.waitForIdle(); assertSame(original, owner("MMMM")); assertSame(original, owner("reset"))
                compose.runOnIdle {
                    val g = used(original)
                    assertEquals("MMMM reset", g.text.toString())
                    val paints = listOf(paint(14f, weight = 700), paint(40f, Typeface.MONOSPACE, 700, true), paint(14f))
                    val bounds = paints.map { p ->
                        val fm = p.fontMetrics; val h = if (useNumber) p.textSize else 14f
                        val half = (h - (fm.descent - fm.ascent)) / 2f
                        fm.ascent - half to fm.descent + half
                    }
                    val top = bounds.minOf { it.first }; val bottom = bounds.maxOf { it.second }
                    assertEquals(bottom - top, g.extents.usedHeight, .01f)
                    val baselines = checkNotNull(g.textBaselines)
                    assertEquals(-top, checkNotNull(baselines.first), .01f); assertEquals(checkNotNull(baselines.first), checkNotNull(baselines.last), 0f)
                    width(original, "MMMM", paints[1]); width(original, "reset", paints[2])
                }
                val cell = compose.onNodeWithTag("compiled-table-cell-root-0", useUnmergedTree = true).fetchSemanticsNode()
                val grid = compose.onNodeWithTag("compiled-table-grid", useUnmergedTree = true).fetchSemanticsNode()
                val expected = compose.runOnIdle { checkNotNull(checkNotNull(used(original).textBaselines).first).roundToInt() + 3 }
                assertEquals(expected, cell.getAlignmentLinePosition(FirstBaseline))
                assertEquals(expected, cell.getAlignmentLinePosition(LastBaseline))
                assertEquals(expected + (cell.boundsInRoot.top - grid.boundsInRoot.top).roundToInt(), grid.getAlignmentLinePosition(FirstBaseline))
                selectAndActivate(original, "reset", actions)
            }
        } finally { compose.activityRule.scenario.onActivity { it.setContent {} }; compose.waitForIdle() }
    }

    @Test fun nestedTableAndContainerUseNearestHeightWithoutLosingCssPixelOwnerOrBodyOrigin() {
        val zoom = mutableStateOf(1f); val ownTableHeight = mutableStateOf(true)
        val actions = mutableListOf<EntryLink>(); var density: Density? = null
        fun link(s: String) = listOf(Span("link", s, s))
        try {
            compose.activityRule.scenario.onActivity { it.setContent {
                CompositionLocalProvider(LocalDensity provides Density(1f, 2f), LocalCssPixelTextZoom provides zoom.value) {
                    MaterialTheme(typography = Typography(bodyLarge = body)) {
                        density = LocalDensity.current
                        val nested = table(listOf(listOf(Cell(link("Nested"), false, 1, 1))),
                            if (ownTableHeight.value) ComputedLineHeight(2f, FontScaleBasis.NormalBody) else null, link("Caption"))
                        val blocks = listOf(Block("paragraph", 0, link("Before")),
                            Block("container", 0, emptyList(), container = Container(listOf(Block("paragraph", 0, link("Inside"))),
                                ContainerStyle(ownerFontScale = 2f))), Block("table", 0, emptyList(), table = nested))
                        val parent = Cell(emptyList(), false, 1, 1, blocks = blocks, style = CellStyle(border = StyleBorder.None,
                            padding = zeroEdges, lineHeight = CellLineHeight(fixed(12f, FontScaleBasis.CssPx), CellTextStrut(24f, FontScaleBasis.CssPx))))
                        Box(Modifier.width(340.dp)) { EntryView(entry(table(listOf(listOf(parent)))), false, {}, onLink = { actions += it },
                            settings = AppSettings(allowImages = false, allowAudio = false, collapseOtherSections = false, collapseDetails = false)) }
                    }
                }
            } }
            compose.waitForIdle()
            for (z in listOf(1f, 1.5f)) for (nearer in listOf(true, false)) {
                compose.runOnIdle { zoom.value = z; ownTableHeight.value = nearer }; compose.waitForIdle()
                val before = owner("Before"); val inside = owner("Inside"); val nested = owner("Nested"); val caption = owner("Caption")
                assertSame(before, inside)
                compose.runOnIdle {
                    val d = checkNotNull(density)
                    val ownerPixels = with(d) { (24f * z).sp.toPx() }
                    width(before, "Before", paint(ownerPixels)); width(inside, "Inside", paint(with(d) { 40.sp.toPx() }))
                    width(nested, "Nested", paint(ownerPixels)); width(caption, "Caption", paint(ownerPixels))
                    val height = if (nearer) with(d) { 20.sp.toPx() } * 2f else with(d) { (12f * z).sp.toPx() }
                    assertEquals(height, used(nested).extents.usedHeight, .01f)
                    assertEquals(height, used(caption).extents.usedHeight, .01f)
                    assertNotEquals(24f * z * d.density * d.fontScale, ownerPixels, .001f)
                }
                selectAndActivate(nested, "Nested", actions)
            }
        } finally { compose.activityRule.scenario.onActivity { it.setContent {} }; compose.waitForIdle() }
    }

    @Test fun trueEmptyCellHasNoBaselineWhileNbspAndExplicitZeroFontKeepTheirRealLines() {
        val actions = mutableListOf<EntryLink>()
        val empty = Cell(emptyList(), false, 1, 1, style = CellStyle(border = StyleBorder.None, padding = zeroEdges, lineHeight = policy()))
        val nbsp = empty.copy(spans = listOf(Span("text", "\u00a0")))
        val zero = empty.copy(spans = listOf(Span("link", "Zero", "Zero")), style = empty.style!!.copy(
            lineHeight = CellLineHeight(fixed(0f), CellTextStrut(0f, FontScaleBasis.NormalBody))))
        try {
            compose.activityRule.scenario.onActivity { it.setContent {
                CompositionLocalProvider(LocalDensity provides Density(1f)) {
                    MaterialTheme(typography = Typography(bodyLarge = body)) {
                        Box(Modifier.width(300.dp)) { EntryView(entry(table(listOf(listOf(empty, nbsp, zero)))), false, {}, onLink = { actions += it },
                            settings = AppSettings(allowImages = false, allowAudio = false, collapseOtherSections = false, collapseDetails = false)) }
                    }
                }
            } }
            compose.waitForIdle()
            val emptyNode = compose.onNodeWithTag("compiled-table-cell-root-0", useUnmergedTree = true).fetchSemanticsNode()
            val nbspNode = compose.onNodeWithTag("compiled-table-cell-root-1", useUnmergedTree = true).fetchSemanticsNode()
            val zeroNode = compose.onNodeWithTag("compiled-table-cell-root-2", useUnmergedTree = true).fetchSemanticsNode()
            assertEquals(AlignmentLine.Unspecified, emptyNode.getAlignmentLinePosition(FirstBaseline))
            assertNotEquals(AlignmentLine.Unspecified, nbspNode.getAlignmentLinePosition(FirstBaseline))
            assertEquals(0, zeroNode.getAlignmentLinePosition(FirstBaseline))
            val zeroView = owner("Zero")
            compose.runOnIdle {
                val g = used(zeroView); assertEquals("Zero", g.text.toString()); assertEquals(0f, g.extents.usedHeight, 0f)
                assertEquals(NativeTextBaselines(0f, 0f), g.textBaselines)
                val n = node(zeroView, "Zero"); assertTrue(n.bounds.all { it.isEmpty })
                zeroView.setSelection(n.start, n.end); assertEquals("Zero", zeroView.selectedTextForCopy())
                val ax = checkNotNull(zeroView.accessibilityNodeProvider.createAccessibilityNodeInfo(n.id)); assertTrue(ax.isClickable)
                assertTrue(zeroView.accessibilityNodeProvider.performAction(n.id, AccessibilityNodeInfo.ACTION_CLICK, null))
                assertEquals(listOf(EntryLink("Zero")), actions)
            }
            val nbspView = views().single { it.logicalText.toString() == "\u00a0" }
            compose.runOnIdle { assertEquals(14f, used(nbspView).extents.usedHeight, .01f); assertNotNull(used(nbspView).textBaselines) }
        } finally { compose.activityRule.scenario.onActivity { it.setContent {} }; compose.waitForIdle() }
    }

    @Test fun figureCaptionTableKeepsItsCellPolicyAndOneOriginalActionOwner() {
        val actions = mutableListOf<EntryLink>()
        val direction = mutableStateOf(LayoutDirection.Ltr)
        val cell = Cell(listOf(Span("link", "Inner", "Inner")), false, 1, 1,
            style = CellStyle(border = StyleBorder.None, padding = zeroEdges,
                lineHeight = CellLineHeight(fixed(.5f), CellTextStrut(.7f, FontScaleBasis.NormalBody))))
        val taller = cell.copy(spans = listOf(Span("link", "Taller", "Taller")),
            style = cell.style!!.copy(lineHeight = policy(2f)))
        val nested = table(listOf(listOf(cell, taller)))
        val containing = Cell(emptyList(), false, 1, 1, nestedTable = nested,
            style = CellStyle(border = StyleBorder.None, padding = zeroEdges))
        val captionTable = table(listOf(listOf(containing)), ComputedLineHeight(1f, FontScaleBasis.NormalBody),
            listOf(Span("link", "TableCaption", "TableCaption")))
        val figure = Figure(FigureContent.Missing(Span("text", "media"), px(120f), px(20f)),
            FigureFormat.Framed, FigurePlacement.None, FigureClear.None, zeroEdges, zeroEdges, zeroEdges,
            1f, px(26f), FigureColor.Transparent, FigureBorder.None, FigureColor.Transparent, FigureBorder.None,
            FigureColor.NativeTheme, FigureColor.Transparent,
            captionBlocks = listOf(Block("table", 0, emptyList(), table = captionTable)))
        val outer = Cell(emptyList(), false, 1, 1,
            blocks = listOf(Block("paragraph", 0, emptyList(), figure = figure)),
            style = CellStyle(border = StyleBorder.None, padding = zeroEdges, lineHeight = policy(4f)))
        try {
            compose.activityRule.scenario.onActivity { it.setContent {
                CompositionLocalProvider(LocalDensity provides Density(1f), LocalLayoutDirection provides direction.value) {
                    MaterialTheme(typography = Typography(bodyLarge = body)) {
                        Box(Modifier.width(300.dp)) { EntryView(entry(table(listOf(listOf(outer)))), false, {}, onLink = { actions += it },
                            settings = AppSettings(allowImages = false, allowAudio = false, collapseOtherSections = false, collapseDetails = false)) }
                    }
                }
            } }
            compose.waitForIdle(); val original = owner("Inner")
            for (rtl in listOf(false, true)) {
                compose.runOnIdle { direction.value = if (rtl) LayoutDirection.Rtl else LayoutDirection.Ltr }; compose.waitForIdle()
                assertSame(original, owner("Inner")); assertSame(original, owner("TableCaption")); assertSame(original, owner("Taller"))
                compose.runOnIdle {
                    width(original, "Inner", paint(14f)); width(original, "TableCaption", paint(20f)); width(original, "Taller", paint(40f))
                    assertTrue(original.logicalText.toString().contains("media"))
                    assertTrue(original.logicalText.toString().contains("TableCaption"))
                    assertEquals(1, checkNotNull(original.currentMeasuredGeometry).nodes.count { it.label?.toString() == "Inner" })
                }
                val firstCells = compose.onAllNodesWithTag("compiled-table-cell-figure-caption-0", useUnmergedTree = true).fetchSemanticsNodes()
                val grids = compose.onAllNodesWithTag("compiled-table-grid-figure-caption", useUnmergedTree = true).fetchSemanticsNodes()
                val tallCell = compose.onNodeWithTag("compiled-table-cell-figure-caption-1", useUnmergedTree = true).fetchSemanticsNode()
                val fm = paint(14f).fontMetrics
                val baseline = -(fm.ascent - (10f - (fm.descent - fm.ascent)) / 2f)
                val tallMetrics = paint(40f).fontMetrics
                val tallBaseline = -(tallMetrics.ascent - (40f - (tallMetrics.descent - tallMetrics.ascent)) / 2f)
                assertTrue(tallBaseline > baseline)
                assertEquals(2, firstCells.size); assertEquals(2, grids.size)
                assertEquals(setOf(baseline.roundToInt(), tallBaseline.roundToInt()),
                    firstCells.map { it.getAlignmentLinePosition(FirstBaseline) }.toSet())
                assertEquals(tallBaseline.roundToInt(), tallCell.getAlignmentLinePosition(FirstBaseline))
                grids.forEach { grid ->
                    assertEquals(tallBaseline.roundToInt(), grid.getAlignmentLinePosition(FirstBaseline))
                    assertEquals(tallBaseline.roundToInt(), grid.getAlignmentLinePosition(LastBaseline))
                }
                selectAndActivate(original, "Inner", actions)
            }
        } finally { compose.activityRule.scenario.onActivity { it.setContent {} }; compose.waitForIdle() }
    }
}
