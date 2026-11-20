package app.smallthingz.dict

import org.junit.Assert.*
import org.junit.Test

class NativeTableResolvedBorderTest {
    private fun px(value: Float) = StyleLength(StyleLengthUnit.Px, value)
    private fun em(value: Float) = StyleLength(StyleLengthUnit.Em, value)
    private fun rgb(value: String) = StyleBorderPaint.Rgb(value)
    private fun all(edge: ResolvedStyleBorderEdge) = StyleBorder.ResolvedEdges(edge, edge, edge, edge)
    private val none = ResolvedStyleBorderEdge.None
    private val black = 0xff000000.toInt()
    private val white = 0xffffffff.toInt()
    private val red = 0xffff0000.toInt()
    private val green = 0xff00c040.toInt()
    private val blue = 0xff0000ff.toInt()
    private fun cell(border: StyleBorder?, text: List<Span> = emptyList()) =
        Cell(text, false, 1, 1, style = border?.let { CellStyle(border = it) })
    private fun table(cells: List<Cell>, collapse: Boolean = false, border: StyleBorder? = StyleBorder.None) =
        Table(emptyList(), listOf(cells), style = TableStyle(border = border,
            collapse = if (collapse) TableCollapse.Collapse else TableCollapse.Separate))
    private fun ink(owner: Any, color: Int) =
        NativeSemanticBorderInk(color, owner, NativeSemanticBorderInkOrigin.ReaderRoot)
    private fun resolved(table: Table, rtl: Boolean = false) =
        resolveTableStyle(table, tableGrid(table), 1f, 20f, 0, 0, rtl = rtl)
    private fun pixels(table: Table, widths: List<Int> = List(tableGrid(table).columns) { 40 }): TablePixelLayout {
        val grid = tableGrid(table)
        return TablePixelLayout(40, IntArray(grid.rows + 1) { it * 30 }, widths.sum(), columnWidths = widths)
    }
    private fun plan(table: Table, style: TableResolvedStyle = resolved(table),
        tableInk: NativeSemanticBorderInk? = null,
        cellInks: List<NativeSemanticBorderInk?> = List(tableGrid(table).cells.size) { null },
        widths: List<Int> = List(tableGrid(table).columns) { 40 }) =
        nativeTableResolvedBorderPlan(table, tableGrid(table), pixels(table, widths), style,
            tableInk, cellInks, 0xff123456.toInt())
    private fun rejects(block: () -> Unit) {
        try { block(); fail("Expected unavailable native geometry") }
        catch (_: IllegalArgumentException) { }
        catch (_: IllegalStateException) { }
    }
    private fun points(polygon: NativeTableBorderPolygon) =
        listOf(polygon.outerStart, polygon.outerEnd, polygon.innerEnd, polygon.innerStart)
    private fun area(points: List<NativeTableBorderPoint>): Double = kotlin.math.abs(points.indices.sumOf { i ->
        val a = points[i]; val b = points[(i + 1) % points.size]
        a.x.toDouble() * b.y - a.y.toDouble() * b.x
    }) / 2.0

    @Test fun resolvedWidthsUseStoredNormalBodyUnitsOnceAndKeepCompleteZeroKinds() {
        val source = Span("text", "Original body", fontScale = 500f)
        val border = StyleBorder.ResolvedEdges(
            ResolvedStyleBorderEdge.Inset(em(.5f), rgb("#102030")),
            ResolvedStyleBorderEdge.Dotted(px(1.25f), rgb("#405060")),
            ResolvedStyleBorderEdge.Solid(px(0f), rgb("#708090")), ResolvedStyleBorderEdge.Hidden)
        val originalCell = cell(border, listOf(source))
        val value = table(listOf(originalCell), border = all(none))
        val grid = tableGrid(value)
        val actual = resolveTableStyle(value, grid, 2f, 20f, 0, 7, decorationScale = .25)
        val edges = actual.cellEdges.single()
        // The producer's .25em at owner scale 2 is already .5 stored em.
        assertEquals(10f, edges.top.width, 0f)
        assertEquals(2.5f, edges.right.width, 0f)
        assertEquals(0f, edges.bottom.width, 0f)
        assertEquals(TableStroke.Solid, edges.bottom.stroke)
        assertEquals(TableStroke.Hidden, edges.left.stroke)
        assertEquals(TablePixelInsets(10, 3, 0, 0), actual.cellInsets.single())
        assertTrue(actual.outerEdges.hasResolvedTableBorder())
        assertEquals(TableStroke.None, actual.outerEdges.top.stroke)
        assertTrue(tableHasComputedCellStyle(value))
        assertSame(originalCell, edges.top.sourceOwner!!.source)
        assertSame(value, edges.top.sourceOwner!!.table)
        assertSame(source, value.rows.single().single().spans.single())
        assertEquals(500f, source.fontScale)
        val largerBody = resolveTableStyle(value, grid, 2f, 40f, 0, 7)
        assertEquals(20f, largerBody.cellEdges.single().top.width, 0f)
        assertEquals(edges.right.width, largerBody.cellEdges.single().right.width, 0f)
        // Old scalar decoration projection and legacy fallback remain distinct.
        val old = table(listOf(cell(StyleBorder.Solid(px(2f), "#112233"))))
        assertEquals(1f, resolveTableStyle(old, tableGrid(old), 2f, 20f, 0, 7,
            decorationScale = .25).cellEdges.single().top.width, 0f)
        val legacy = Table(emptyList(), listOf(listOf(cell(null))))
        assertEquals(1.75f, resolveTableStyle(legacy, tableGrid(legacy), 2f, 20f, 0, 7,
            decorationScale = .25).cellEdges.single().top.width, 0f)
    }

    @Test fun collapsedConflictsUseRawStyleWidthAndOwnerBeforeShadedAppearance() {
        fun pair(right: ResolvedStyleBorderEdge, left: StyleBorder): Table = table(listOf(
            cell(StyleBorder.ResolvedEdges(none, right, none, none)), cell(left)), collapse = true)
        fun left(edge: ResolvedStyleBorderEdge) = StyleBorder.ResolvedEdges(none, none, none, edge)
        fun shared(value: Table) = plan(value).collapsed!!.single { it.line.x1 == it.line.x2 && it.polygon.first().x == 40f }
        val inset = ResolvedStyleBorderEdge.Inset(px(2f), rgb("#ff0000"))
        val outset = ResolvedStyleBorderEdge.Outset(px(2f), rgb("#0000ff"))
        val competing = pair(inset, left(outset))
        assertEquals(TableStroke.Outset, shared(competing).stroke)
        assertEquals(blue, shared(competing).argb)
        assertEquals(NativeTableBorderSide.Left, shared(competing).side)
        assertEquals(1, shared(competing).owner!!.cellIndex)
        assertTrue(shared(competing).collapsed) // paint maps Outset to Groove only after this winner.
        val wider = pair(ResolvedStyleBorderEdge.Inset(px(3f), rgb("#ff0000")), left(outset))
        assertEquals(TableStroke.Inset, shared(wider).stroke)
        val solid = pair(inset, StyleBorder.Solid(px(2f), "#0000ff"))
        assertEquals(TableStroke.Solid, shared(solid).stroke)
        val doubleCell = Cell(emptyList(), false, 1, 1, style = CellStyle(
            borderEdges = CellBorderEdges(left = CellBorder.Double(px(2f), "#0000ff"))))
        val mixed = table(listOf(competing.rows[0][0], doubleCell), collapse = true)
        assertEquals(TableStroke.Double, shared(mixed).stroke)
        val bands = tableBorderBands(shared(mixed).line)
        assertEquals(2, bands.size)
        assertEquals(2f / 3f, bands.first().width, 0f)
        val hidden = pair(inset, left(ResolvedStyleBorderEdge.Hidden))
        assertTrue(plan(hidden).collapsed!!.none { it.line.x1 == it.line.x2 && it.polygon.first().x == 40f })
        val absent = pair(inset, left(none))
        assertEquals(red, shared(absent).argb)
        val equal = table(listOf(cell(all(ResolvedStyleBorderEdge.Solid(px(2f), rgb("#0000ff"))))),
            collapse = true, border = all(ResolvedStyleBorderEdge.Solid(px(2f), rgb("#ff0000"))))
        assertTrue(plan(equal).collapsed!!.all { it.argb == blue && it.owner!!.origin == NativeTableBorderOrigin.Cell })
    }

    @Test fun physicalLeftAndRightSurviveRtlAllocationAndUnequalColumnWidths() {
        fun sides(leftWidth: Float, leftColor: String, rightWidth: Float, rightColor: String) =
            StyleBorder.ResolvedEdges(none, ResolvedStyleBorderEdge.Solid(px(rightWidth), rgb(rightColor)),
                none, ResolvedStyleBorderEdge.Solid(px(leftWidth), rgb(leftColor)))
        val first = cell(sides(6f, "#ff0000", 2f, "#0000ff"))
        val second = cell(sides(3f, "#00ff00", 4f, "#ffff00"))
        val value = table(listOf(first, second), collapse = true)
        for (rtl in listOf(false, true, false)) {
            val style = resolved(value, rtl)
            val regions = plan(value, style, widths = listOf(40, 60)).collapsed!!
            val byNode = regions.associateBy { it.polygon.first().x }
            assertEquals(setOf(0f, if (rtl) 60f else 40f, 100f), byNode.keys)
            if (rtl) {
                assertEquals(0xff00ff00.toInt(), byNode.getValue(0f).argb)
                assertEquals(NativeTableBorderSide.Left, byNode.getValue(0f).side)
                assertSame(second, byNode.getValue(0f).owner!!.source)
                assertEquals(red, byNode.getValue(60f).argb)
                assertSame(first, byNode.getValue(60f).owner!!.source)
                assertEquals(blue, byNode.getValue(100f).argb)
                assertEquals(NativeTableBorderSide.Right, byNode.getValue(100f).side)
                assertEquals(TablePixelInsets(0, 1, 0, 3), style.cellInsets[0])
                assertEquals(TablePixelInsets(0, 3, 0, 2), style.cellInsets[1])
            } else {
                assertEquals(red, byNode.getValue(0f).argb)
                assertEquals(0xff00ff00.toInt(), byNode.getValue(40f).argb)
                assertEquals(0xffffff00.toInt(), byNode.getValue(100f).argb)
            }
        }
        val separate = value.copy(style = value.style!!.copy(collapse = TableCollapse.Separate))
        val separatePlan = plan(separate, resolved(separate, true), widths = listOf(40, 60))
        assertEquals(60f, separatePlan.cells.getValue(0).left, 0f)
        assertEquals(0f, separatePlan.cells.getValue(1).left, 0f)
        assertEquals(red, separatePlan.cells.getValue(0).regions.single { it.side == NativeTableBorderSide.Left }.argb)
    }

    @Test fun junctionsPartitionActualCornersAndRefuseLostPositiveNativeExtents() {
        fun p(x: Float, y: Float) = NativeTableBorderPoint(x, y)
        val box = NativeTableBorderRectangle(10f, 20f, 110f, 80f)
        val widths = NativeTableBorderWidths(4f, 6f, 8f, 10f)
        val sides = NativeTableBorderSide.entries.map { checkNotNull(nativeTableBorderSideBand(box, widths, it)) }
        assertEquals(listOf(p(10f,20f), p(110f,20f), p(104f,24f), p(20f,24f)), points(sides[0]))
        assertEquals(6000.0 - 84.0 * 48.0, sides.sumOf { area(points(it)) }, 0.0)
        val half = checkNotNull(nativeTableBorderSideBand(box, widths, NativeTableBorderSide.Top, 0f, .5f))
        assertEquals(p(107f,22f), half.innerEnd); assertEquals(p(15f,22f), half.innerStart)
        val horizontal = nativeTableCollapsedBorderPolygon(p(0f,20f), p(100f,20f), false, 2f, 3f,
            NativeTableBorderJunctionInsets(5f,7f,11f,13f))
        assertEquals(listOf(p(0f,20f),p(5f,18f),p(89f,18f),p(100f,20f),p(87f,23f),p(7f,23f)), horizontal)
        val upperArm = nativeTableCollapsedBorderPolygon(p(0f,0f),p(0f,20f), true, 4f,5f,
            NativeTableBorderJunctionInsets(0f,0f,2f,2f))
        assertEquals(horizontal[0], upperArm[3]); assertEquals(horizontal[1], upperArm[4])
        rejects { nativeTableCollapsedBorderPolygon(p(0f,0f),p(7f,0f),false,1f,1f,
            NativeTableBorderJunctionInsets(4f,0f,4f,0f)) }
        rejects { nativeTableBorderSideBand(NativeTableBorderRectangle(0f,0f,3f,4f),
            NativeTableBorderWidths(1f,2f,1f,2f), NativeTableBorderSide.Top) }
        rejects { nativeTableBorderSideBand(NativeTableBorderRectangle(30000f,30000f,30020f,30020f),
            NativeTableBorderWidths(.0001f,.0001f,.0001f,.0001f), NativeTableBorderSide.Top) }
        rejects { nativeTableCollapsedBorderPolygon(p(0f,30000f),p(20f,30000f),false,.0001f,.0001f,
            NativeTableBorderJunctionInsets(0f,0f,0f,0f)) }
        // A whole one-ULP band can survive while its midpoint/half-width cannot.
        val oneUlp = .001953125f
        rejects { nativeTableBorderStrokePreflight(30000f + oneUlp / 2f, oneUlp, 30000f, 30000f + oneUlp) }
        nativeTableBorderStrokePreflight(30000.25f, .5f, 30000f, 30000.5f)
        assertNotNull(nativeTableBorderSideBand(NativeTableBorderRectangle(30000f,30000f,30020f,30020f),
            NativeTableBorderWidths(.5f,.75f,1f,1.25f), NativeTableBorderSide.Top))
    }

    @Test fun qtLighterUsesSelectedHsvPolicyAndPreservesBaseAlphaAndRawPaint() {
        val vectors = listOf(0xffdddddd.toInt() to white, black to black,
            0xff808080.toInt() to 0xffc0c0c0.toInt(), 0xff404040.toInt() to 0xff606060.toInt(),
            red to 0xffff7f7f.toInt(), 0xff00ff00.toInt() to 0xff7fff7f.toInt(), blue to 0xff7f7fff.toInt())
        vectors.forEach { (base, light) ->
            assertEquals(light, nativeResolvedTableLighter150(base))
            assertEquals((light and 0x00ffffff) or 0x80000000.toInt(),
                nativeResolvedTableLighter150((base and 0x00ffffff) or 0x80000000.toInt()))
        }
        val original = ResolvedStyleBorderEdge.Inset(px(2f), rgb("#808080"))
        val value = table(listOf(cell(all(original))), collapse = true)
        assertTrue(plan(value).collapsed!!.all { it.argb == 0xff808080.toInt() && it.stroke == TableStroke.Inset })
        assertEquals("#808080", (original.paint as StyleBorderPaint.Rgb).value)
        rejects { tableBorderBands(TableBorderSegment(0f,0f,10f,0f,2f,null,TableStroke.Inset)) }
    }

    @Test fun originalOwnerInkSeparatesReadabilityAuthorshipFallbackAndOccurrence() {
        val source = cell(null)
        val root = ink(Any(), green)
        fun owner(context: NativeCellForegroundContext?, background: String?, inherited: NativeSemanticBorderInk? = root) =
            nativeBorderNormalOwnerInk(inherited, source, NativeSemanticBorderInkOrigin.Cell, context, background)
        assertEquals(white, owner(null,"#000000")!!.argb)
        val marked = nativeCellForegroundContext(CellForeground.Inherit, green, "#000000", null)
        assertEquals(green, owner(marked,"#000000")!!.argb)
        val authored = NativeSemanticBorderInk(green, root.declaringOwner, root.origin, green, root.declaringOwner)
        assertEquals(green, owner(null,"#000000",authored)!!.argb)
        assertEquals(black, owner(null,"#ffffff")!!.argb)
        assertEquals(green, owner(null,null)!!.argb)
        // Unavailable outer cells with retainCellPaint=false install the ambient
        // background, not their discarded black backdrop. Nested borders inherit
        // this same fallback normal ink without changing the retained text paint.
        val fallback = owner(null, null)
        val retainedPaint = owner(null, "#000000")
        assertEquals(green, fallback!!.argb); assertEquals(white, retainedPaint!!.argb)
        assertEquals(white, nativeCellLinkForeground(null,null,null,"#000000","#000000",false))
        assertEquals(green, fallback.argb) // descendant link contrast never mutates owner.
        assertNull(owner(null,"#000000",null))
        val computedWhite = ink(Any(),white)
        val authoredWhite = NativeSemanticBorderInk(white, computedWhite.declaringOwner, computedWhite.origin,
            white,computedWhite.declaringOwner)
        assertEquals(black, owner(null,"#ffffff",computedWhite)!!.argb)
        assertEquals(white, owner(null,"#ffffff",authoredWhite)!!.argb)
        val twice = table(listOf(source, source))
        val first = NativeTableBorderOwner(twice,source,NativeTableBorderOrigin.Cell,0)
        val second = NativeTableBorderOwner(twice,source,NativeTableBorderOrigin.Cell,1)
        assertNotEquals(first,second)
        assertEquals(green,nativeTableOwnerCurrentColor(first,NativeTableBorderOwnerInk(first,root)))
        rejects { nativeTableOwnerCurrentColor(first,NativeTableBorderOwnerInk(second,root)) }
        rejects { nativeTableOwnerCurrentColor(first,NativeTableBorderOwnerInk(first,null)) }
    }

    @Test fun replacementSourceCachesRefreshNestedOwnersAndOpacityKeepsTheSameCellPlan() {
        val plain = Span("text","Original plain body")
        val link = Span("link","Original action","Target")
        val edge = all(ResolvedStyleBorderEdge.Solid(px(2f),StyleBorderPaint.OwnerCurrentColor))
        val translucent = cell(edge,listOf(plain)).let { it.copy(style = it.style!!.copy(opacity=.5f)) }
        val actionCell = cell(StyleBorder.None,listOf(link))
        val original = table(listOf(translucent,actionCell))
        val replacement = original.copy(rows=original.rows.map { row -> row.map { it.copy() } })
        assertEquals(original,replacement); assertNotSame(original,replacement)
        assertNotSame(original.rows[0][0],replacement.rows[0][0])
        assertSame(plain,replacement.rows[0][0].spans.single()); assertSame(link,replacement.rows[0][1].spans.single())
        assertNotEquals(nativeTableBorderSourceKey(original),nativeTableBorderSourceKey(replacement))
        val outer = Table(emptyList(),listOf(listOf(Cell(emptyList(),false,1,1,nestedTable=original))))
        val outerNew = outer.copy(rows=listOf(listOf(outer.rows[0][0].copy(nestedTable=replacement))))
        assertFalse(nativeTableUsesResolvedBorders(outer)); assertTrue(nativeHasResolvedTableBorders(outer))
        assertNotEquals(nativeTableBorderSourceKey(outer),nativeTableBorderSourceKey(outerNew))
        val old = Table(emptyList(),listOf(listOf(cell(StyleBorder.Solid(px(1f),"#112233")))))
        assertEquals(nativeTableBorderSourceKey(old),nativeTableBorderSourceKey(old.copy()))
        val naturalCache = mutableMapOf<Any,TableResolvedStyle>()
        val oldStyle = naturalCache.getOrPut(nativeTableBorderSourceKey(original)) { resolved(original) }
        val newStyle = naturalCache.getOrPut(nativeTableBorderSourceKey(replacement)) { resolved(replacement) }
        assertSame(replacement,newStyle.cellEdges[0].top.sourceOwner!!.table)
        assertSame(replacement.rows[0][0],newStyle.cellEdges[0].top.sourceOwner!!.source)
        val inks = listOf(ink(replacement.rows[0][0],white),null)
        rejects { plan(replacement,oldStyle,cellInks=inks) }
        val current = plan(replacement,newStyle,cellInks=inks)
        assertEquals(1,current.cells.size)
        assertEquals(setOf(white),current.cells.getValue(0).regions.map { it.argb }.toSet())
        assertEquals(0f,current.cells.getValue(0).left,0f)
        assertNull(current.collapsed)
        assertTrue(nativeCellOpacityTableShape(replacement))
        assertEquals(.5f,replacement.rows[0][0].style!!.opacity)
        assertSame(link,replacement.rows[0][1].spans.single())
        // Even a zero-width/losing currentColor declaration requires its own receipt.
        val zero = table(listOf(cell(all(ResolvedStyleBorderEdge.Solid(px(0f),StyleBorderPaint.OwnerCurrentColor)))))
        rejects { plan(zero) }
        assertTrue(plan(zero,cellInks=listOf(ink(zero.rows[0][0],green))).cells.getValue(0).regions.isEmpty())
        val independentRgb = table(listOf(cell(all(ResolvedStyleBorderEdge.Solid(px(2f),rgb("#123456"))))))
        assertTrue(plan(independentRgb).cells.getValue(0).regions.all { it.argb == 0xff123456.toInt() })
    }
}
