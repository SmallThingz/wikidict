package app.smallthingz.dict

import android.graphics.Bitmap
import android.graphics.RectF
import android.view.View
import android.view.ViewGroup
import android.view.accessibility.AccessibilityNodeInfo
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.requiredWidth
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ProvideTextStyle
import androidx.compose.material3.Surface
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalLayoutDirection
import androidx.compose.ui.platform.ViewRootForTest
import androidx.compose.ui.test.*
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import kotlin.math.ceil
import kotlin.math.floor
import kotlin.math.roundToInt

/** Actual Compose paint and original semantic owners; no direct painter replay. */
class NativeTableResolvedBorderDeviceTest {
    @get:Rule val compose = createPhysicalComposeRule()
    private var activityRoot: View? = null
    private fun px(value: Float) = StyleLength(unit = StyleLengthUnit.Px, value = value)
    private fun uniform(edge: ResolvedStyleBorderEdge) = StyleBorder.ResolvedEdges(edge, edge, edge, edge)
    private fun grid(path: String = "root") = compose.onNodeWithTag(
        if (path == "root") "compiled-table-grid" else "compiled-table-grid-$path", useUnmergedTree = true)
    private fun cell(index: Int, path: String = "root") = compose.onNodeWithTag(
        "compiled-table-cell-$path-$index", useUnmergedTree = true)
    private fun bounds(node: SemanticsNodeInteraction) = node.fetchSemanticsNode().boundsInRoot

    private fun owner(value: String): NativeFloatTextView {
        val found = mutableListOf<NativeFloatTextView>()
        fun visit(view: View) {
            if (view is NativeFloatTextView && view.isShown &&
                view.currentMeasuredGeometry?.text?.toString() == value) found += view
            if (view is ViewGroup) repeat(view.childCount) { visit(view.getChildAt(it)) }
        }
        visit(checkNotNull(activityRoot))
        return found.single()
    }

    private data class Raster(val bitmap: Bitmap, val rootBounds: Rect, val screenLeft: Int, val screenTop: Int) {
        fun pixel(x: Float, y: Float): Int {
            val ix = floor((x - rootBounds.left).toDouble()).toInt()
            val iy = floor((y - rootBounds.top).toDouble()).toInt()
            assertTrue("Measured sample must be in the actual Compose capture", ix in 0 until bitmap.width && iy in 0 until bitmap.height)
            return bitmap.getPixel(ix, iy)
        }
    }
    private fun capture(): Raster {
        val root = compose.onRoot(useUnmergedTree = true)
        val node = root.fetchSemanticsNode()
        val rectangle = node.boundsInRoot
        val view = (checkNotNull(node.root) as ViewRootForTest).view
        val bitmap = root.captureToImage().asAndroidBitmap()
        try {
            val screen = IntArray(2)
            compose.runOnIdle { view.getLocationOnScreen(screen) }
            assertEquals(rectangle.right.roundToInt() - rectangle.left.roundToInt(), bitmap.width)
            assertEquals(rectangle.bottom.roundToInt() - rectangle.top.roundToInt(), bitmap.height)
            assertEquals(android.graphics.ColorSpace.get(android.graphics.ColorSpace.Named.SRGB), bitmap.colorSpace)
            return Raster(bitmap, rectangle, screen[0] + rectangle.left.roundToInt(), screen[1] + rectangle.top.roundToInt())
        } catch (error: Throwable) { bitmap.recycle(); throw error }
    }
    private fun assertSolidSides(raster: Raster, box: Rect, width: Float, expected: Int) {
        assertEquals(expected, raster.pixel(box.center.x, box.top + width / 2f))
        assertEquals(expected, raster.pixel(box.right - width / 2f, box.center.y))
        assertEquals(expected, raster.pixel(box.center.x, box.bottom - width / 2f))
        assertEquals(expected, raster.pixel(box.left + width / 2f, box.center.y))
    }
    private fun assertInk(raster: Raster, value: String, start: Int, length: Int, expected: Int) {
        val rectangles = mutableListOf<RectF>()
        compose.runOnIdle {
            val view = owner(value)
            val geometry = checkNotNull(view.currentMeasuredGeometry)
            val screen = IntArray(2); view.getLocationOnScreen(screen)
            val source = geometry.characterRects(start, length)
            assertEquals(length, source.size)
            rectangles += source.map { RectF(checkNotNull(it)).apply {
                offset((screen[0] + view.paddingLeft - raster.screenLeft).toFloat(),
                    (screen[1] + view.paddingTop - raster.screenTop).toFloat())
            } }
            assertEquals(value, view.logicalText.toString())
        }
        var exact = 0
        for (rect in rectangles) {
            val left = floor(rect.left.toDouble()).toInt()
            val top = floor(rect.top.toDouble()).toInt()
            val right = ceil(rect.right.toDouble()).toInt()
            val bottom = ceil(rect.bottom.toDouble()).toInt()
            assertTrue(left >= 0 && top >= 0 && right <= raster.bitmap.width && bottom <= raster.bitmap.height)
            for (y in top until bottom) for (x in left until right)
                if (raster.bitmap.getPixel(x, y) == expected) exact++
        }
        assertTrue("Actual glyph pixels for $value[$start,${start + length})", exact >= 4)
    }
    private fun controlled(block: () -> Unit) {
        var failure: Throwable? = null
        try { block() } catch (error: Throwable) { failure = error; throw error }
        finally {
            try { compose.activityRule.scenario.onActivity { it.setContent {} } }
            catch (cleanup: Throwable) {
                val primary = failure
                if (primary == null) throw cleanup
                if (primary !== cleanup) primary.addSuppressed(cleanup)
            }
            activityRoot = null
        }
    }

    @Test fun semanticOwnerInkPrecedesDescendantContrastLinksAndNestedTablesAndRecovers() = controlled {
        // Synthetic colors and typography distinguish source owner ink from plain
        // text readability, a preceding explicit span, the caption, links and outline.
        fun text(value: String, foreground: String? = null) = Span("text", value,
            foreground = foreground, bold = true, fontScale = 18f,
            fontScaleBasis = FontScaleBasis.CssPx, fontFamily = ContainerFontFamily.SansSerif)
        val red = text("RGB ", "#ff0000")
        val plain = text("TXT ")
        val link = text("LINK").copy(kind = "link", target = "original-border-link",
            targetFragment = "original-fragment", background = "#000000")
        val caption = text("CAPTION", "#ff00ff")
        val nestedText = text("NEST")
        val literalRgb = 0xff1234ab.toInt()
        fun source(border: StyleBorder?, marked: Boolean, contrastFree: Boolean = false): Table {
            val nested = Table(emptyList(), listOf(listOf(Cell(listOf(nestedText), false, 1, 1,
                background = "#a0a0a0", style = border?.let { CellStyle(border = it) }))),
                TableGeometry(border = 4, cellSpacing = 6, cellPadding = 8,
                    width = TableWidth(TableWidthUnit.Percent, 100)),
                style = TableStyle(background = "#ffffff", border = border))
            return Table(listOf(caption), listOf(
                listOf(Cell(listOf(red, plain, link), false, 1, 1, background = if (contrastFree) null else "#000000",
                    style = if (border != null || marked) CellStyle(border = border,
                        foreground = if (marked) CellForeground.Inherit else null) else null)),
                listOf(Cell(emptyList(), false, 1, 1, background = "#000000", nestedTable = nested,
                    style = border?.let { CellStyle(border = it) }))),
                TableGeometry(border = 4, cellSpacing = 6, cellPadding = 8,
                    width = TableWidth(TableWidthUnit.Percent, 100)),
                style = TableStyle(background = if (contrastFree) null else "#ffffff", border = border))
        }
        val inherited = uniform(ResolvedStyleBorderEdge.Solid(px(4f), StyleBorderPaint.OwnerCurrentColor))
        val original = source(inherited, false)
        val marked = source(inherited, true)
        val contrastFree = source(inherited, false, contrastFree = true)
        val rgb = source(uniform(ResolvedStyleBorderEdge.Solid(px(4f), StyleBorderPaint.Rgb("#1234ab"))), false)
        val legacy = source(null, false)
        fun freshOwners(value: Table): Table = value.copy(rows = value.rows.map { row -> row.map { cell ->
            cell.copy(nestedTable = cell.nestedTable?.let { freshOwners(it) })
        } })
        fun assertFreshOwners(before: Table, after: Table) {
            assertEquals(before, after); assertNotSame(before, after)
            before.rows.flatten().zip(after.rows.flatten()).forEach { (oldCell, newCell) ->
                assertEquals(oldCell, newCell); assertNotSame(oldCell, newCell)
                assertSame(oldCell.spans, newCell.spans)
                oldCell.nestedTable?.let { assertFreshOwners(it, checkNotNull(newCell.nestedTable)) }
            }
        }
        val replaced = freshOwners(original).also { assertFreshOwners(original, it) }
        // An old-border ancestor still owns caches for its resolved descendant.
        val legacyAncestor = legacy.copy(rows = listOf(legacy.rows[0], listOf(
            legacy.rows[1].single().copy(nestedTable = original.rows[1].single().nestedTable))))
        val replacedAncestor = freshOwners(legacyAncestor).also { assertFreshOwners(legacyAncestor, it) }
        assertNull(legacyAncestor.style!!.border)
        assertTrue(legacyAncestor.rows.flatten().all { it.style?.border == null })
        assertTrue(legacyAncestor.rows[1].single().nestedTable!!.style!!.border is StyleBorder.ResolvedEdges)
        data class Phase(val table: Table, val ink: Int, val width: Int, val direction: LayoutDirection,
            val marked: Boolean = false, val rgb: Boolean = false, val legacy: Boolean = false,
            val contrastFree: Boolean = false, val nativeTheme: Boolean = false, val theme: String = "light",
            val legacyAncestor: Boolean = false)
        val green = 0xff00c040.toInt(); val purple = 0xffa000c0.toInt()
        val phases = listOf(
            Phase(original, green, 320, LayoutDirection.Ltr),
            Phase(original, purple, 320, LayoutDirection.Ltr),
            Phase(replaced, purple, 320, LayoutDirection.Ltr),
            Phase(original, purple, 280, LayoutDirection.Rtl),
            Phase(marked, green, 280, LayoutDirection.Rtl, marked = true),
            Phase(contrastFree, green, 320, LayoutDirection.Ltr, contrastFree = true),
            Phase(contrastFree, purple, 320, LayoutDirection.Ltr, contrastFree = true),
            Phase(contrastFree, green, 320, LayoutDirection.Ltr, contrastFree = true, nativeTheme = true),
            Phase(contrastFree, green, 320, LayoutDirection.Ltr, contrastFree = true, nativeTheme = true, theme = "dark"),
            Phase(rgb, purple, 320, LayoutDirection.Ltr, rgb = true),
            Phase(legacy, green, 320, LayoutDirection.Ltr, legacy = true),
            Phase(legacyAncestor, green, 320, LayoutDirection.Ltr, legacyAncestor = true),
            Phase(replacedAncestor, green, 320, LayoutDirection.Ltr, legacyAncestor = true),
            Phase(original, green, 320, LayoutDirection.Ltr))
        // An equal-valued new source is still a real source replacement event.
        val phase = mutableStateOf(phases.first(), androidx.compose.runtime.referentialEqualityPolicy())
        val actions = mutableListOf<EntryLink>()
        var outline = 0
        var resolvedRootInk = 0
        val measuredThemeInks = mutableListOf<Int>()
        compose.activityRule.scenario.onActivity { activity ->
            activityRoot = activity.window.decorView
            activity.setContent {
                CompositionLocalProvider(LocalDensity provides Density(1f, 1f),
                    LocalLayoutDirection provides phase.value.direction) {
                    DictTheme(phase.value.theme) {
                        outline = MaterialTheme.colorScheme.outline.toArgb()
                        val ink = if (phase.value.nativeTheme) MaterialTheme.colorScheme.onSurface else Color(phase.value.ink)
                        resolvedRootInk = ink.toArgb()
                        Surface(Modifier.fillMaxSize(), color = Color(0xffe0e0e0), contentColor = ink) {
                            ProvideTextStyle(MaterialTheme.typography.bodyLarge.copy(color = ink)) {
                                Box(Modifier.requiredWidth(phase.value.width.dp)) {
                                    CompiledTableView(phase.value.table, null) { actions += it }
                                }
                            }
                        }
                    }
                }
            }
        }
        var originalBounds: List<Rect>? = null
        for ((index, current) in phases.withIndex()) {
            compose.runOnIdle { phase.value = current }
            compose.waitForIdle()
            compose.onAllNodesWithText("unavailable", substring = true, ignoreCase = true).assertCountEquals(0)
            compose.onAllNodesWithText("Table is too large to display.").assertCountEquals(0)
            val expectedRoot = compose.runOnIdle { resolvedRootInk }
            if (current.nativeTheme) measuredThemeInks += expectedRoot
            val measured = listOf(bounds(grid()), bounds(cell(0)), bounds(cell(1)),
                bounds(grid("root/1")), bounds(cell(0, "root/1")))
            assertEquals(current.width.toFloat(), measured.first().width, .01f)
            if (index == 0) originalBounds = measured
            if (index == 1 || current.table === replaced || index == phases.lastIndex)
                assertEquals(originalBounds, measured)
            // Table inherits enclosing normal ink. An unmarked Cell's own
            // effective background determines its normal readability; the marked
            // Cell keeps pre-cell enclosing ink. Nested Table inherits that Cell.
            val expectedBorders = when {
                current.rgb -> List(5) { literalRgb }
                current.legacy -> List(5) { outline }
                current.legacyAncestor -> listOf(outline, outline, outline,
                    android.graphics.Color.WHITE, android.graphics.Color.BLACK)
                else -> listOf(expectedRoot,
                    if (current.marked || current.contrastFree) expectedRoot else android.graphics.Color.WHITE,
                    android.graphics.Color.WHITE, android.graphics.Color.WHITE, android.graphics.Color.BLACK)
            }
            assertNotEquals(expectedRoot, outline)
            val raster = capture()
            try {
                measured.zip(expectedBorders).forEach { (box, ink) -> assertSolidSides(raster, box, 4f, ink) }
                assertInk(raster, "RGB TXT LINK", 0, 3, android.graphics.Color.RED)
                assertInk(raster, "RGB TXT LINK", 4, 3,
                    if (current.marked || current.contrastFree) expectedRoot else android.graphics.Color.WHITE)
                assertInk(raster, "RGB TXT LINK", 8, 4, android.graphics.Color.WHITE)
                assertInk(raster, "NEST", 0, 4, android.graphics.Color.BLACK)
                assertInk(raster, "CAPTION", 0, 7, android.graphics.Color.MAGENTA)
            } finally { raster.bitmap.recycle() }
            compose.runOnIdle {
                assertSame(caption, current.table.caption.single())
                assertSame(red, current.table.rows[0].single().spans[0])
                assertSame(plain, current.table.rows[0].single().spans[1])
                assertSame(link, current.table.rows[0].single().spans[2])
                assertSame(nestedText, current.table.rows[1].single().nestedTable!!.rows.single().single().spans.single())
                val view = owner("RGB TXT LINK")
                val geometry = checkNotNull(view.currentMeasuredGeometry)
                assertEquals("RGB TXT LINK", geometry.text.toString())
                assertEquals(12, geometry.characterRects(0, 12).size)
                val node = geometry.nodes.single { it.kind == FloatInteractionKind.LINK }
                assertEquals("LINK", node.label.toString())
                assertEquals(8, node.start); assertEquals(12, node.end)
                val provider = view.accessibilityNodeProvider
                val ax = checkNotNull(provider.createAccessibilityNodeInfo(node.id))
                try { assertEquals("LINK", ax.text.toString()); assertTrue(ax.isClickable && ax.isVisibleToUser) }
                finally { ax.recycle() }
                view.setSelection(0, 12)
                assertEquals("RGB TXT LINK", view.selectedTextForCopy())
                assertTrue(view.performAccessibilityAction(AccessibilityNodeInfo.ACTION_SET_SELECTION, null))
                assertTrue(provider.performAction(node.id, AccessibilityNodeInfo.ACTION_CLICK, null))
                assertEquals(index + 1, actions.size)
                assertEquals(link.entryLink(), actions.last())
            }
        }
        assertEquals(2, measuredThemeInks.size)
        assertNotEquals("Actual light/dark normal theme ink must differ", measuredThemeInks[0], measuredThemeInks[1])
    }

    @Test fun separatePhysicalSidesUseNormalBodyEmAndRealDottedGapsWithoutFillingNoneHiddenOrZero() = controlled {
        val red = StyleBorderPaint.Rgb("#ff0000")
        val green = StyleBorderPaint.Rgb("#00ff00")
        val blue = StyleBorderPaint.Rgb("#0000ff")
        val yellow = StyleBorderPaint.Rgb("#ffff00")
        val purple = StyleBorderPaint.Rgb("#aa00cc")
        val original = Span("text", "A", fontScale = 48f, fontScaleBasis = FontScaleBasis.CssPx,
            fontFamily = ContainerFontFamily.SansSerif)
        val outer = StyleBorder.ResolvedEdges(
            ResolvedStyleBorderEdge.Solid(px(8f), red), ResolvedStyleBorderEdge.Solid(px(6f), green),
            ResolvedStyleBorderEdge.Solid(px(4f), blue),
            ResolvedStyleBorderEdge.Solid(StyleLength(unit = StyleLengthUnit.Em, value = .25f), yellow))
        val inner = StyleBorder.ResolvedEdges(ResolvedStyleBorderEdge.Dotted(px(4f), purple),
            ResolvedStyleBorderEdge.None, ResolvedStyleBorderEdge.Solid(px(0f), blue), ResolvedStyleBorderEdge.Hidden)
        val table = Table(emptyList(), listOf(listOf(Cell(listOf(original), false, 1, 1,
            background = "#ffffff", style = CellStyle(border = inner, textAlign = CellTextAlign.Center)))),
            TableGeometry(border = 0, cellSpacing = 8, cellPadding = 10,
                width = TableWidth(TableWidthUnit.Percent, 100)),
            style = TableStyle(background = "#808080", border = outer, collapse = TableCollapse.Separate))
        data class Phase(val zoom: Float, val direction: LayoutDirection, val width: Int)
        val phases = listOf(Phase(1f, LayoutDirection.Ltr, 300), Phase(1.5f, LayoutDirection.Rtl, 260),
            Phase(1f, LayoutDirection.Rtl, 300), Phase(1f, LayoutDirection.Ltr, 300))
        val phase = mutableStateOf(phases.first())
        compose.activityRule.scenario.onActivity { activity ->
            activityRoot = activity.window.decorView
            activity.setContent {
                CompositionLocalProvider(LocalDensity provides Density(1f, phase.value.zoom),
                    LocalLayoutDirection provides phase.value.direction) {
                    DictTheme("light") {
                        MaterialTheme(typography = MaterialTheme.typography.copy(
                            bodyLarge = MaterialTheme.typography.bodyLarge.copy(fontSize = 16.sp))) {
                            Surface(Modifier.fillMaxSize(), color = Color(0xffe0e0e0)) {
                                Box(Modifier.requiredWidth(phase.value.width.dp)) { CompiledTableView(table, null) {} }
                            }
                        }
                    }
                }
            }
        }
        var first: List<Rect>? = null
        for ((index, current) in phases.withIndex()) {
            compose.runOnIdle { phase.value = current }
            compose.waitForIdle()
            compose.onAllNodesWithText("unavailable", substring = true, ignoreCase = true).assertCountEquals(0)
            val outerBox = bounds(grid()); val innerBox = bounds(cell(0))
            if (index == 0) first = listOf(outerBox, innerBox)
            if (index == phases.lastIndex) assertEquals(first, listOf(outerBox, innerBox))
            // Independently specified normal-body16sp; the real child is48CssPx.
            val leftWidth = 16f * current.zoom * .25f
            val raster = capture()
            try {
                assertEquals(android.graphics.Color.RED, raster.pixel(outerBox.center.x, outerBox.top + 3.5f))
                assertEquals(android.graphics.Color.GREEN, raster.pixel(outerBox.right - 2.5f, outerBox.center.y))
                assertEquals(android.graphics.Color.BLUE, raster.pixel(outerBox.center.x, outerBox.bottom - 1.5f))
                assertEquals(android.graphics.Color.YELLOW, raster.pixel(outerBox.left + leftWidth / 2f, outerBox.center.y))
                assertEquals(0xff808080.toInt(), raster.pixel(outerBox.left + leftWidth + 1.5f, outerBox.center.y))
                // Unequal corner partitions must meet along their actual diagonals.
                assertEquals(android.graphics.Color.RED, raster.pixel(outerBox.left + leftWidth - .5f, outerBox.top + 1.5f))
                assertEquals(android.graphics.Color.YELLOW, raster.pixel(outerBox.left + .5f, outerBox.top + 6.5f))
                assertEquals(android.graphics.Color.GREEN, raster.pixel(outerBox.right - 1.5f, outerBox.bottom - 3.5f))
                assertEquals(android.graphics.Color.BLUE, raster.pixel(outerBox.right - 5.5f, outerBox.bottom - .5f))
                var dots = 0; var gaps = 0
                for (x in ceil(innerBox.left + 8f).toInt() until floor(innerBox.right - 8f).toInt()) {
                    when (raster.pixel(x + .5f, innerBox.top + 2f)) {
                        0xffaa00cc.toInt() -> dots++
                        android.graphics.Color.WHITE -> gaps++
                    }
                }
                assertTrue("Actual dotted cell edge paints distinct dots", dots > 4)
                assertTrue("Actual dotted gaps expose the cell backdrop", gaps > 4)
                assertEquals(android.graphics.Color.WHITE, raster.pixel(innerBox.left + .5f, innerBox.center.y))
                assertEquals(android.graphics.Color.WHITE, raster.pixel(innerBox.right - .5f, innerBox.center.y))
                assertEquals(android.graphics.Color.WHITE, raster.pixel(innerBox.center.x, innerBox.bottom - .5f))
            } finally { raster.bitmap.recycle() }
            compose.runOnIdle {
                assertSame(original, table.rows.single().single().spans.single())
                val view = owner("A")
                assertEquals("A", view.logicalText.toString())
                view.setSelection(0, 1); assertEquals("A", view.selectedTextForCopy())
                assertTrue(view.performAccessibilityAction(AccessibilityNodeInfo.ACTION_SET_SELECTION, null))
            }
        }
    }

    @Test fun retainedAnRowsKeepDeclaredBordersAndDistinctCollapsedBevelPaintInBothDirections() = controlled {
        // Retained Reader current-2.stdout52338be2, entries[0].sections[2].blocks[0]
        // .container.blocks[1].table: all15 original labels/header/font flags/widths.
        // Only the selected new border fields are added. The root ink, density and
        // typography are controlled inputs, not new producer/page-render acceptance.
        val labels = listOf(listOf("Caso", "Singular", "Plural"),
            listOf("Nominatibo", "σημαία", "σημαίες"), listOf("Chenitibo", "σημαίας", "σημαιών"),
            listOf("Acusatibo", "σημαία", "σημαίες"), listOf("Bocatibo", "σημαία", "σημαίες"))
        val spans = labels.mapIndexed { r, row -> row.mapIndexed { c, value ->
            Span("text", value, bold = c == 1 && r in listOf(1, 3, 4))
        } }
        val inset = uniform(ResolvedStyleBorderEdge.Inset(px(1f), StyleBorderPaint.OwnerCurrentColor))
        val rows = spans.mapIndexed { r, row -> row.mapIndexed { c, span ->
            Cell(listOf(span), r == 0 || c == 0, 1, 1,
                background = if (r == 0) "#dffffe" else if (c == 0) "#eef9ff" else null,
                style = CellStyle(border = inset, textAlign = CellTextAlign.Center,
                    width = if (r == 0 || c == 0) StyleWidth(StyleWidthUnit.Percent, 5f) else null))
        } }
        val outer = uniform(ResolvedStyleBorderEdge.Outset(px(1f), StyleBorderPaint.Rgb("#dddddd")))
        val source = Table(emptyList(), rows, TableGeometry(border = 1),
            style = TableStyle(border = outer, collapse = TableCollapse.Collapse))
        // Separate mode is an explicit synthetic contrast; source mode remains Collapse.
        val separate = source.copy(style = source.style!!.copy(collapse = TableCollapse.Separate))
        data class Phase(val table: Table, val direction: LayoutDirection, val collapse: Boolean)
        val phases = listOf(Phase(source, LayoutDirection.Ltr, true), Phase(source, LayoutDirection.Rtl, true),
            Phase(separate, LayoutDirection.Ltr, false), Phase(separate, LayoutDirection.Rtl, false),
            Phase(source, LayoutDirection.Ltr, true))
        val phase = mutableStateOf(phases.first())
        compose.activityRule.scenario.onActivity { activity ->
            activityRoot = activity.window.decorView
            activity.setContent {
                CompositionLocalProvider(LocalDensity provides Density(2f, 1f),
                    LocalLayoutDirection provides phase.value.direction) {
                    DictTheme("light") {
                        MaterialTheme(typography = MaterialTheme.typography.copy(
                            bodyLarge = MaterialTheme.typography.bodyLarge.copy(fontSize = 10.sp))) {
                            Surface(Modifier.fillMaxSize(), color = Color.White, contentColor = Color(0xff404040)) {
                                ProvideTextStyle(MaterialTheme.typography.bodyLarge.copy(color = Color(0xff404040))) {
                                    Box(Modifier.requiredWidth(170.dp)) { CompiledTableView(phase.value.table, null) {} }
                                }
                            }
                        }
                    }
                }
            }
        }
        var first: List<Rect>? = null
        for ((index, current) in phases.withIndex()) {
            compose.runOnIdle { phase.value = current }
            compose.waitForIdle()
            compose.onAllNodesWithText("unavailable", substring = true, ignoreCase = true).assertCountEquals(0)
            compose.onAllNodesWithText("Table is too large to display.").assertCountEquals(0)
            val actualGrid = grid().fetchSemanticsNode()
            val collection = actualGrid.config[androidx.compose.ui.semantics.SemanticsProperties.CollectionInfo]
            assertEquals(5, collection.rowCount); assertEquals(3, collection.columnCount)
            val tableBox = actualGrid.boundsInRoot
            val cells = List(15) { bounds(cell(it)) }
            if (index == 0) first = listOf(tableBox) + cells
            if (index == phases.lastIndex) assertEquals(first, listOf(tableBox) + cells)
            labels.flatten().groupingBy { it }.eachCount().forEach { (value, count) ->
                compose.onAllNodesWithText(value, useUnmergedTree = true).assertCountEquals(count)
            }
            assertTrue(tableBox.width <= 340f)
            // Authored1px at density2 is exactly2 physical pixels. Maintained Qt
            // lighter150 vectors are independently fixed:#404040→#606060,#ddd→#fff.
            val base = 0xff404040.toInt(); val light = 0xff606060.toInt()
            val tableBase = 0xffdddddd.toInt(); val tableLight = android.graphics.Color.WHITE
            val raster = capture()
            try {
                if (current.collapse) {
                    // Raw Outset beats Inset before collapse maps it to Groove.
                    assertEquals(tableBase, raster.pixel(tableBox.center.x, tableBox.top + .5f))
                    assertEquals(tableLight, raster.pixel(tableBox.center.x, tableBox.top + 1.5f))
                    assertEquals(tableBase, raster.pixel(tableBox.left + .5f, tableBox.center.y))
                    assertEquals(tableLight, raster.pixel(tableBox.left + 1.5f, tableBox.center.y))
                    assertEquals(tableLight, raster.pixel(tableBox.right - .5f, tableBox.center.y))
                    assertEquals(tableBase, raster.pixel(tableBox.right - 1.5f, tableBox.center.y))
                    assertEquals(tableLight, raster.pixel(tableBox.center.x, tableBox.bottom - .5f))
                    assertEquals(tableBase, raster.pixel(tableBox.center.x, tableBox.bottom - 1.5f))
                    // Internal Inset wins from a real cell and paints Ridge. It must
                    // not acquire the Table's independent#ddd paint or old outline.
                    val firstRow = cells.take(3).sortedBy { it.left }
                    for (right in firstRow.drop(1)) {
                        // Light header backgrounds own black readability; the
                        // maintained Qt lighter150 policy leaves black unchanged.
                        assertEquals(android.graphics.Color.BLACK, raster.pixel(right.left - .5f, right.center.y))
                        assertEquals(android.graphics.Color.BLACK, raster.pixel(right.left + .5f, right.center.y))
                    }
                    for (column in 0..1) {
                        val winner = cells[3 + column]
                        val x = if (current.direction == LayoutDirection.Ltr) winner.right else winner.left
                        val normal = if (column == 0) android.graphics.Color.BLACK else base
                        val lighter = if (column == 0) android.graphics.Color.BLACK else light
                        assertEquals(lighter, raster.pixel(x - .5f, winner.center.y))
                        assertEquals(normal, raster.pixel(x + .5f, winner.center.y))
                    }
                    for (column in 0..2) {
                        val below = cells[6 + column]
                        val normal = if (column == 0) android.graphics.Color.BLACK else base
                        val lighter = if (column == 0) android.graphics.Color.BLACK else light
                        assertEquals(lighter, raster.pixel(below.center.x, below.top - .5f))
                        assertEquals(normal, raster.pixel(below.center.x, below.top + .5f))
                    }
                } else {
                    assertEquals(tableLight, raster.pixel(tableBox.center.x, tableBox.top + .5f))
                    assertEquals(tableLight, raster.pixel(tableBox.left + .5f, tableBox.center.y))
                    assertEquals(tableBase, raster.pixel(tableBox.right - .5f, tableBox.center.y))
                    assertEquals(tableBase, raster.pixel(tableBox.center.x, tableBox.bottom - .5f))
                    for ((at, box) in cells.withIndex()) {
                        val hasOwnBackground = at < 3 || at % 3 == 0
                        val normal = if (hasOwnBackground) android.graphics.Color.BLACK else base
                        val lighter = if (hasOwnBackground) android.graphics.Color.BLACK else light
                        assertEquals(normal, raster.pixel(box.center.x, box.top + .5f))
                        assertEquals(normal, raster.pixel(box.left + .5f, box.center.y))
                        assertEquals(lighter, raster.pixel(box.right - .5f, box.center.y))
                        assertEquals(lighter, raster.pixel(box.center.x, box.bottom - .5f))
                    }
                }
            } finally { raster.bitmap.recycle() }
            for (r in 0..4) for (c in 0..2) {
                val original = spans[r][c]; val actual = current.table.rows[r][c]
                assertSame(original, actual.spans.single())
                assertEquals(labels[r][c], original.text)
                assertEquals(r == 0 || c == 0, actual.header)
                assertEquals(c == 1 && r in listOf(1, 3, 4), original.bold)
                assertEquals(if (r == 0 || c == 0) StyleWidth(StyleWidthUnit.Percent, 5f) else null, actual.style!!.width)
                assertEquals(CellTextAlign.Center, actual.style.textAlign)
                assertEquals(1, actual.colspan); assertEquals(1, actual.rowspan)
                assertEquals("text", original.kind); assertEquals("", original.target)
            }
            assertSame(rows, current.table.rows)
            assertEquals(TableGeometry(border = 1), current.table.geometry)
            assertTrue(current.table.caption.isEmpty())
        }
    }

    @Test fun collapsedSourceOrderAndPhysicalJunctionWedgesRemainDistinctThroughRtlAndResize() = controlled {
        val rgb = listOf("#ff0000", "#00ff00", "#0000ff", "#ffff00")
        val originals = List(4) { Span("text", "Cell$it") }
        val rows = List(2) { row -> List(2) { column ->
            val at = row * 2 + column
            Cell(listOf(originals[at]), false, 1, 1, background = "#ffffff",
                style = CellStyle(border = uniform(ResolvedStyleBorderEdge.Solid(px(8f), StyleBorderPaint.Rgb(rgb[at])))))
        } }
        val table = Table(emptyList(), rows, TableGeometry(border = 0, cellSpacing = 0, cellPadding = 16,
            width = TableWidth(TableWidthUnit.Percent, 100)),
            style = TableStyle(background = "#808080", border = StyleBorder.None, collapse = TableCollapse.Collapse))
        data class Phase(val direction: LayoutDirection, val width: Int)
        val phases = listOf(Phase(LayoutDirection.Ltr, 300), Phase(LayoutDirection.Rtl, 260),
            Phase(LayoutDirection.Rtl, 300), Phase(LayoutDirection.Ltr, 300))
        val phase = mutableStateOf(phases.first())
        compose.activityRule.scenario.onActivity { activity ->
            activityRoot = activity.window.decorView
            activity.setContent {
                CompositionLocalProvider(LocalDensity provides Density(1f, 1f), LocalLayoutDirection provides phase.value.direction) {
                    DictTheme("light") {
                        Surface(Modifier.fillMaxSize(), color = Color(0xffe0e0e0)) {
                            Box(Modifier.requiredWidth(phase.value.width.dp)) { CompiledTableView(table, null) {} }
                        }
                    }
                }
            }
        }
        var first: List<Rect>? = null
        for ((index, current) in phases.withIndex()) {
            compose.runOnIdle { phase.value = current }
            compose.waitForIdle()
            compose.onAllNodesWithText("unavailable", substring = true, ignoreCase = true).assertCountEquals(0)
            val tableBox = bounds(grid()); val cells = List(4) { bounds(cell(it)) }
            assertEquals(current.width.toFloat(), tableBox.width, .01f)
            if (index == 0) first = listOf(tableBox) + cells
            if (index == phases.lastIndex) assertEquals(first, listOf(tableBox) + cells)
            val leftTop = cells.take(2).minBy { it.left }
            val rightTop = cells.take(2).maxBy { it.left }
            assertEquals(leftTop.right, rightTop.left, .01f)
            assertEquals(cells[0].bottom, cells[2].top, .01f)
            val x = rightTop.left; val y = cells[2].top
            val leftWinner = if (current.direction == LayoutDirection.Ltr) android.graphics.Color.RED else android.graphics.Color.GREEN
            val rightWinner = if (current.direction == LayoutDirection.Ltr) android.graphics.Color.GREEN else android.graphics.Color.RED
            val raster = capture()
            try {
                // Exact equal-stroke ties keep the original first source cell in each row.
                assertEquals(android.graphics.Color.RED, raster.pixel(x, leftTop.center.y))
                assertEquals(android.graphics.Color.BLUE, raster.pixel(x, cells[2].center.y))
                assertEquals(leftWinner, raster.pixel(leftTop.center.x, y))
                assertEquals(rightWinner, raster.pixel(rightTop.center.x, y))
                // Samples are away from each diagonal. A last-drawn rectangular
                // segment would overwrite at least one of these real incident wedges.
                assertEquals(android.graphics.Color.RED, raster.pixel(x - 1f, y - 3f))
                assertEquals(android.graphics.Color.RED, raster.pixel(x + 1f, y - 3f))
                assertEquals(leftWinner, raster.pixel(x - 3f, y - 1f))
                assertEquals(rightWinner, raster.pixel(x + 3f, y - 1f))
                assertEquals(leftWinner, raster.pixel(x - 3f, y + 1f))
                assertEquals(rightWinner, raster.pixel(x + 3f, y + 1f))
                assertEquals(android.graphics.Color.BLUE, raster.pixel(x - 1f, y + 3f))
                assertEquals(android.graphics.Color.BLUE, raster.pixel(x + 1f, y + 3f))
            } finally { raster.bitmap.recycle() }
            for (at in 0..3) {
                assertSame(originals[at], table.rows[at / 2][at % 2].spans.single())
                compose.onNodeWithText(originals[at].text, useUnmergedTree = true).assertIsDisplayed()
            }
        }
    }
}
