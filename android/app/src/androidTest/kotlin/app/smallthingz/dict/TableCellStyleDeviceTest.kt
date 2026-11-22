package app.smallthingz.dict

import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.width
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalLayoutDirection
import androidx.compose.ui.test.*
import androidx.compose.ui.text.TextLayoutResult
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.dp
import androidx.test.platform.app.InstrumentationRegistry
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

class TableCellStyleDeviceTest {
    @get:Rule val compose = createPhysicalComposeRule()

    @Test fun doubleCellBorderAndInheritedTrackingSurviveThemeFontScaleAndChildFontChanges() {
        val fontScale = mutableStateOf(1f)
        val dark = mutableStateOf(false)
        val px = { value: Float -> StyleLength(StyleLengthUnit.Px, value) }
        val tracking = StyleLength(StyleLengthUnit.Em, .3f)
        val zero = px(0f)
        val reset = Table(emptyList(), listOf(listOf(Cell(listOf(Span("text", "Zero reset")), false, 1, 1,
            style = CellStyle(letterSpacing = zero)))))
        val table = Table(emptyList(), listOf(
            listOf(Cell(listOf(Span("text", "Tracked heading")), true, 2, 1, background = "#ffffff",
                style = CellStyle(padding = StyleEdges(px(3f), px(3f), px(4f), px(3f)),
                    borderEdges = CellBorderEdges(bottom = CellBorder.Double(px(6f), "#0000ff")), letterSpacing = tracking))),
            listOf(Cell(listOf(Span("text", "Small child", fontScale = .8f, fontScaleBasis = FontScaleBasis.NormalBody)), false, 1, 1,
                style = CellStyle(letterSpacing = tracking)), Cell(emptyList(), false, 1, 1, nestedTable = reset,
                style = CellStyle(letterSpacing = tracking))),
        ), style = TableStyle(collapse = TableCollapse.Separate))
        val entry = Entry("Cell style", emptyList(), "language", "English", "en",
            listOf(Section(2, "", listOf(Block("table", 0, emptyList(), table = table)))), emptyList())
        var expectedTrackingSp = 0f
        try {
            compose.activityRule.scenario.onActivity { activity -> activity.setContent {
                CompositionLocalProvider(LocalDensity provides Density(1f, fontScale.value)) {
                    DictTheme(if (dark.value) "dark" else "light") {
                        expectedTrackingSp = MaterialTheme.typography.bodyLarge.fontSize.value * .3f
                        Surface(Modifier.fillMaxSize()) {
                            Box(Modifier.fillMaxSize(), contentAlignment = Alignment.TopStart) {
                                Box(Modifier.width(400.dp).height(750.dp)) {
                                    EntryView(entry, false, {}, settings = AppSettings(allowImages = false, allowAudio = false,
                                        collapseOtherSections = false, collapseDetails = false))
                                }
                            }
                        }
                    }
                }
            } }
            fun layout(text: String): TextLayoutResult {
                val results = mutableListOf<TextLayoutResult>()
                compose.onNodeWithText(text, useUnmergedTree = true).assertIsDisplayed()
                    .performSemanticsAction(androidx.compose.ui.semantics.SemanticsActions.GetTextLayoutResult) { it(results) }
                return results.single()
            }
            for (scale in listOf(1f, 1.6f)) for (night in listOf(false, true)) {
                compose.runOnIdle { fontScale.value = scale; dark.value = night }
                compose.waitForIdle()
                compose.onNodeWithText("Table is too large to display.").assertDoesNotExist()
                assertEquals(expectedTrackingSp, layout("Tracked heading").layoutInput.style.letterSpacing.value, .001f)
                val child = layout("Small child")
                assertEquals(expectedTrackingSp, child.layoutInput.style.letterSpacing.value, .001f)
                assertTrue(child.layoutInput.text.spanStyles.any { kotlin.math.abs(it.item.fontSize.value - child.layoutInput.style.fontSize.value * .8f) < .01f })
                assertEquals(0f, layout("Zero reset").layoutInput.style.letterSpacing.value, 0f)
                val grid = compose.onNodeWithTag("compiled-table-grid", useUnmergedTree = true)
                val gridBounds = grid.fetchSemanticsNode().boundsInRoot
                val header = compose.onNodeWithTag("compiled-table-cell-root-0", useUnmergedTree = true).fetchSemanticsNode().boundsInRoot
                val bitmap = grid.captureToImage().asAndroidBitmap()
                try {
                    val x = ((header.left + header.right) / 2 - gridBounds.left).toInt()
                    val bottom = (header.bottom - gridBounds.top).toInt()
                    fun blue(y: Int) = bitmap.getPixel(x, y) and 0xffffff == 0x0000ff
                    assertTrue("Outer double band", blue(bottom - 1))
                    assertFalse("Unpainted double gap", blue(bottom - 3))
                    assertTrue("Inner double band", blue(bottom - 5))
                } finally { bitmap.recycle() }
            }
        } finally { compose.activityRule.scenario.onActivity { it.setContent {} } }
    }

    @Test fun nestedTranslationCellsUseTableRelativePercentagesAndTheirRealTextWidths() {
        val direction = mutableStateOf(LayoutDirection.Ltr)
        val fontScale = mutableStateOf(1f)
        val zero = StyleLength(StyleLengthUnit.Px, 0f)
        val padding = StyleEdges(zero, zero, zero, zero)
        fun cell(text: String) = Cell(listOf(Span("text", text)), false, 1, 1,
            style = CellStyle(border = StyleBorder.None, padding = padding))
        val nested = Table(emptyList(), listOf(listOf(cell("Nested left"), cell("Nested right"))),
            style = TableStyle(width = StyleWidth(StyleWidthUnit.Percent, 100f)))
        val body = listOf(Block("list_item", 1, listOf(Span("text", "First kept term"))),
            Block("list_item", 1, listOf(Span("text", "Second kept term"))))
        val table = Table(emptyList(), listOf(listOf(
            Cell(emptyList(), false, 1, 1, nestedTable = nested,
                style = CellStyle(border = StyleBorder.None, padding = padding, width = StyleWidth(StyleWidthUnit.Percent, 48f))),
            Cell(emptyList(), false, 1, 1,
                style = CellStyle(border = StyleBorder.None, padding = padding, width = StyleWidth(StyleWidthUnit.Percent, 1f))),
            Cell(emptyList(), false, 1, 1, blocks = body,
                style = CellStyle(border = StyleBorder.None, padding = padding, width = StyleWidth(StyleWidthUnit.Percent, 48f))),
        )), style = TableStyle(width = StyleWidth(StyleWidthUnit.Px, 300f), border = StyleBorder.None))
        val entry = Entry("Translation widths", emptyList(), "language", "English", "en",
            listOf(Section(2, "", listOf(Block("table", 0, emptyList(), table = table)))), emptyList())
        try {
            compose.activityRule.scenario.onActivity { activity -> activity.setContent {
                CompositionLocalProvider(LocalDensity provides Density(1f, fontScale.value),
                    LocalLayoutDirection provides direction.value) {
                    DictTheme("light") {
                        Surface(Modifier.fillMaxSize()) {
                            Box(Modifier.fillMaxSize(), contentAlignment = Alignment.TopStart) {
                                Box(Modifier.width(500.dp).height(850.dp)) {
                                    EntryView(entry, false, {}, settings = AppSettings(allowImages = false,
                                        allowAudio = false, collapseOtherSections = false, collapseDetails = false))
                                }
                            }
                        }
                    }
                }
            } }
            for (scale in listOf(1f, 1.4f)) for (rtl in listOf(LayoutDirection.Ltr, LayoutDirection.Rtl)) {
                compose.runOnIdle { fontScale.value = scale; direction.value = rtl }
                compose.waitForIdle()
                compose.onNodeWithText("Table is too large to display.").assertDoesNotExist()
                for (text in listOf("Nested left", "Nested right", "First kept term", "Second kept term"))
                    compose.onNodeWithText(text, useUnmergedTree = true).assertIsDisplayed()
                val grid = compose.onNodeWithTag("compiled-table-grid", useUnmergedTree = true).fetchSemanticsNode().boundsInRoot
                val left = compose.onNodeWithTag("compiled-table-cell-root-0", useUnmergedTree = true).fetchSemanticsNode().boundsInRoot
                val spacer = compose.onNodeWithTag("compiled-table-cell-root-1", useUnmergedTree = true).fetchSemanticsNode().boundsInRoot
                val right = compose.onNodeWithTag("compiled-table-cell-root-2", useUnmergedTree = true).fetchSemanticsNode().boundsInRoot
                val child = compose.onNodeWithTag("compiled-table-grid-root/0", useUnmergedTree = true).fetchSemanticsNode().boundsInRoot
                assertEquals("Authored table width, independent of the 500px viewport", 300f, grid.width, 1f)
                assertTrue("48% uses this table's assigned width", left.width in 144f..155f)
                assertTrue("Other 48% cell", right.width in 144f..155f)
                assertTrue("One-percent spacer remains distinct", spacer.width in 3f..12f)
                assertEquals("Nested 100% uses its real containing cell", left.width, child.width, 1f)
                if (rtl == LayoutDirection.Ltr) assertTrue(left.left < right.left) else assertTrue(left.left > right.left)
            }
        } finally { compose.activityRule.scenario.onActivity { it.setContent {} } }
    }

    @Test fun floatedInflectionTableAndFollowingFigureKeepTheirOrderInsideARichCell() {
        val width = mutableStateOf(900)
        val direction = mutableStateOf(LayoutDirection.Ltr)
        val zero = StyleLength(StyleLengthUnit.Px, 0f)
        val edges = StyleEdges(zero, zero, zero, zero)
        fun px(value: Float) = StyleLength(StyleLengthUnit.Px, value)
        val rules = StyleBorder.Solid(px(1f), "#000000")
        fun cell(text: String, header: Boolean = false, columns: Int = 1, width: Float? = null) =
            Cell(listOf(Span("text", text)), header, columns, 1, style = CellStyle(border = rules,
                padding = StyleEdges(px(3f), px(3f), px(3f), px(3f)),
                width = width?.let { StyleWidth(StyleWidthUnit.Px, it) }))
        val inflection = Table(emptyList(), listOf(
            listOf(cell("шведска именица", true, 5).copy(background = "#f4f4f4",
                style = CellStyle(border = rules, padding = StyleEdges(px(3f), px(3f), px(4f), px(3f)),
                    letterSpacing = StyleLength(StyleLengthUnit.Em, .3f),
                    borderEdges = CellBorderEdges(bottom = CellBorder.Double(px(4f), "#0000ff"))))),
            listOf(cell("Падеж", true, width = 65f), cell("Једнина", true), cell("Одређено", true),
                cell("Множина", true), cell("Одређено", true)),
            listOf(cell("Номинатив"), cell("en tallrik"), cell("tallriken"), cell("tallrikar"), cell("tallrikarna"))),
            style = TableStyle(floatSide = TableFloatSide.Right, collapse = TableCollapse.Collapse,
                border = StyleBorder.Solid(px(1f), "#aaaaaa"),
                margins = StyleEdges(zero, zero, StyleLength(StyleLengthUnit.Em, .5f), StyleLength(StyleLengthUnit.Em, .5f))))
        val caption = "Порцелански тањир."
        val figure = Figure(FigureContent.Image(Span("link", "", "File:Controlled plate.tif",
            image = InlineImage("Controlled plate.tif", widthPx = 250)), FigureSizingPolicy.RequestedFit),
            FigureFormat.Thumbnail, FigurePlacement.FloatRight, FigureClear.None, edges, edges, edges,
            .884f, StyleLength(StyleLengthUnit.Em, 1.2376f), FigureColor.NativeTheme, FigureBorder.None,
            FigureColor.Transparent, FigureBorder.None, FigureColor.NativeTheme, FigureColor.Transparent,
            caption = listOf(Span("text", caption)))
        val blocks = listOf(Block("table", 0, emptyList(), table = inflection),
            Block("paragraph", 0, emptyList(), figure = figure), Block("paragraph", 0,
                listOf(Span("text", "Body stays in the shared float context."))))
        val outer = Table(emptyList(), listOf(listOf(Cell(emptyList(), false, 1, 1, blocks = blocks,
            style = CellStyle(padding = edges, border = StyleBorder.None,
                width = StyleWidth(StyleWidthUnit.Percent, 100f))))),
            style = TableStyle(width = StyleWidth(StyleWidthUnit.Percent, 100f), border = StyleBorder.None))
        val entry = Entry("Nested float widths", emptyList(), "language", "English", "en",
            listOf(Section(2, "", listOf(Block("table", 0, emptyList(), table = outer)))), emptyList(),
            media = listOf(Media("Controlled plate.tif", "image", "")))
        val failures = java.util.concurrent.CopyOnWriteArrayList<String>()
        val geometryField = NativeFloatTextView::class.java.getDeclaredField("geometry").apply { isAccessible = true }
        fun geometry(): NativeFloatContextGeometry {
            val owners = mutableListOf<NativeFloatTextView>()
            fun visit(view: android.view.View) {
                if (view is NativeFloatTextView && view.isShown && view.logicalText.contains(caption)) owners += view
                if (view is android.view.ViewGroup) for (i in 0 until view.childCount) visit(view.getChildAt(i))
            }
            compose.activityRule.scenario.onActivity { visit(it.window.decorView) }
            return geometryField.get(owners.single()) as NativeFloatContextGeometry
        }
        try {
            compose.activityRule.scenario.onActivity { activity -> activity.setContent {
                CompositionLocalProvider(LocalDensity provides Density(1f, 1f), LocalLayoutDirection provides direction.value,
                    LocalNativeFloatContextFailureObserver provides { failures += it }) {
                    DictTheme("light") { Surface(Modifier.fillMaxSize()) {
                        Box(Modifier.fillMaxSize(), contentAlignment = Alignment.TopStart) {
                            Box(Modifier.width(width.value.dp).height(900.dp)) {
                                EntryView(entry, false, {}, settings = AppSettings(allowImages = false, allowAudio = false,
                                    collapseOtherSections = false, collapseDetails = false))
                            }
                        }
                    } }
                }
            } }
            for (rtl in listOf(LayoutDirection.Ltr, LayoutDirection.Rtl)) for (available in listOf(900, 650, 420, 900)) {
                compose.runOnIdle { direction.value = rtl; width.value = available }
                compose.waitForIdle()
                compose.onNodeWithText("Table layout is unavailable at this size.").assertDoesNotExist()
                compose.onNodeWithText("Unable to display this layout.").assertDoesNotExist()
                compose.runOnIdle {
                    val current = geometry()
                    val table = current.children.single { it.id == 0 }.bounds
                    val image = current.nodes.single { it.kind == FloatInteractionKind.IMAGE }.bounds.single()
                    assertFalse("Following right float must not overlap the table", android.graphics.RectF.intersects(table, image))
                    assertTrue("Source order forbids an earlier top", image.top >= table.top - 1f)
                    assertTrue("A real intrinsic table is wider than its single authored 65px cell", table.width() > 65f)
                    val start = current.text.indexOf(caption)
                    assertTrue(start >= 0)
                    assertTrue(current.rectsForRange(start, start + caption.length).isNotEmpty())
                    assertTrue(current.text.contains("Body stays in the shared float context."))
                    assertTrue(failures.toString(), failures.isEmpty())
                }
                val nominal = compose.onNodeWithTag("compiled-table-cell-root/0/block-0-1", useUnmergedTree = true)
                    .fetchSemanticsNode().boundsInRoot
                assertTrue("65px is a content preference plus padding/border, not a clipping width", nominal.width >= 73f)
            }
        } finally { compose.activityRule.scenario.onActivity { it.setContent {} } }
    }

    @Test fun inheritedEgyptianTrackingMovesWholeShapedClustersAndKeepsTheirInternalGeometry() = runBlocking {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        // Separate signs and a joined quadrat exercise different cluster structures.
        for (text in listOf("\uD80C\uDC00\uD80C\uDC01", "\uD80C\uDC00\uD80D\uDC30\uD80C\uDC01\uD80C\uDC02")) {
            val original = EgyptianShaper.shape(context, text, 32f)
            val tracked = original.withTracking(text, 6f)
            assertArrayEquals(original.glyphIds, tracked.glyphIds)
            assertArrayEquals(original.clusters, tracked.clusters)
            assertTrue(tracked.advance >= original.advance)
            assertSame(original, original.withTracking(text, 0f))
            for (i in original.clusters.indices) for (j in i + 1 until original.clusters.size) {
                if (original.clusters[i] == original.clusters[j]) {
                    assertEquals(original.getGlyphX(j) - original.getGlyphX(i), tracked.getGlyphX(j) - tracked.getGlyphX(i), .001f)
                    assertEquals(original.getGlyphY(j) - original.getGlyphY(i), tracked.getGlyphY(j) - tracked.getGlyphY(i), .001f)
                }
            }
            if (text == "\uD80C\uDC00\uD80C\uDC01") assertEquals(original.advance + 6f, tracked.advance, .001f)
        }
    }
}
