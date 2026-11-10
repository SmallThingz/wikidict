package app.smallthingz.dict

import org.junit.Assert.*
import org.junit.Test

class InlineTableWidthDesignTest {
    private fun cell(span: Int = 1) = Cell(emptyList(), false, span, 1)
    private fun three() = TableGrid(listOf(PlacedCell(cell(), 0, 0, 1),
        PlacedCell(cell(), 0, 1, 1), PlacedCell(cell(), 0, 2, 1)), 1, 3)

    @Test fun unequalContentShrinksToPreferredWidthsWithoutStretchingAcrossViewport() {
        assertEquals(listOf(180, 48, 40), inlineTableColumnWidths(three(),
            intArrayOf(80, 48, 26), intArrayOf(180, 48, 40), 0, 8, 500))
    }

    @Test fun constrainedWidthPreservesControlMinimumAndEveryResidualPixel() {
        assertEquals(listOf(96, 48, 28), inlineTableColumnWidths(three(),
            intArrayOf(80, 48, 26), intArrayOf(180, 48, 40), 0, 8, 180))
        // Too-small viewport keeps intrinsic content available to the existing scroll surface.
        assertEquals(listOf(80, 48, 26), inlineTableColumnWidths(three(),
            intArrayOf(80, 48, 26), intArrayOf(180, 48, 40), 0, 8, 100))
    }

    @Test fun spanningCellConstraintsComposeWithIndividualColumns() {
        val grid = TableGrid(listOf(PlacedCell(cell(2), 0, 0, 2), PlacedCell(cell(), 0, 2, 1),
            PlacedCell(cell(), 1, 0, 1), PlacedCell(cell(), 1, 1, 1)), 2, 3)
        assertEquals(listOf(95, 105, 40), inlineTableColumnWidths(grid,
            intArrayOf(100, 20, 30, 50), intArrayOf(200, 40, 80, 90), 0, 0, 500))
    }

    @Test fun variableColumnsKeepRtlPaintAndHitCellGeometryTogether() {
        val grid = TableGrid(listOf(PlacedCell(cell(), 0, 0, 1), PlacedCell(cell(), 0, 1, 1)), 1, 2)
        val pixels = checkNotNull(tablePixelLayout(grid, 1, 10, intArrayOf(15, 20),
            cellSpacing = 2, borderWidth = 1, tablePadding = TablePixelInsets(0, 5, 0, 3),
            columnWidths = listOf(40, 60)))
        assertEquals(116, pixels.width)
        assertEquals(6, pixels.cellLeft(0))
        assertEquals(48, pixels.cellLeft(1))
        assertEquals(68, pixels.physicalCellLeft(0, 1, true))
        assertEquals(6, pixels.physicalCellLeft(1, 1, true))
        assertEquals(102, pixels.cellWidth(2))
    }

    @Test fun unavailableOrContradictoryIntrinsicMeasurementDoesNotInventFixedColumns() {
        assertNull(inlineTableColumnWidths(three(), intArrayOf(80, 48, 26), intArrayOf(79, 48, 40), 0, 0, 300))
        assertNull(inlineTableColumnWidths(three(), intArrayOf(80, 48, 26), intArrayOf(Int.MAX_VALUE, 48, 40), 0, 0, 300))
        assertNull(inlineTableColumnWidths(three(), intArrayOf(20000, 20000, 26), intArrayOf(20000, 20000, 40), 0, 0, 300))
        assertNull(tablePixelLayout(three(), 1, 10, intArrayOf(10, 10, 10), columnWidths = listOf(30, 40)))
    }
}

class InlineTableDomainDesignTest {
    private fun table(spans: List<Span> = listOf(Span("text", "Label"))) = Table(emptyList(),
        listOf(listOf(Cell(spans, false, 1, 1))), style = TableStyle(display = TableDisplay.InlineBlock,
            verticalAlign = InlineBoxVerticalAlign.Middle, lineHeight = ComputedLineHeight(1f)))
    private fun block(table: Table) = Block("list_item", 1, emptyList(), listPath = "*", table = table)
    private fun entry(table: Table, media: List<Media> = emptyList(), references: List<Reference> = emptyList()) =
        Entry("table", emptyList(), "article", "English", "en", listOf(Section(1, "Body", listOf(block(table)))),
            references, media = media)

    @Test fun audioOwnershipMatchesCatalogAndLeavesTextStyleAndActionIntact() {
        val span = Span("link", "Listen", "File:Sound file.ogg", classes = "wikidict-media",
            fontScale = .8f, fontScaleBasis = FontScaleBasis.NormalBody)
        val value = table(listOf(span))
        assertEquals(span, entry(value, listOf(Media("Sound file.ogg", "audio", "Listen")))
            .sections.single().blocks.single().table!!.rows.single().single().spans.single())
        assertThrows(IllegalArgumentException::class.java) { entry(value) }
        assertThrows(IllegalArgumentException::class.java) { entry(value, listOf(Media("Sound file.ogg", "image", "Listen"))) }
        assertThrows(IllegalArgumentException::class.java) { entry(value,
            listOf(Media("Sound file.ogg", "audio", "A"), Media("Sound file.ogg", "audio", "B"))) }
        val unknownMarker = span.copy(classes = "wikidict-media wikidict-media-file-00")
        assertThrows(IllegalArgumentException::class.java) { entry(table(listOf(unknownMarker)), listOf(Media("Sound file.ogg", "audio", "Listen"))) }
    }

    @Test fun nativeSubtreesAndNonSectionContextsAreRejectedBeforeIntrinsicQueries() {
        val nested = Table(emptyList(), listOf(listOf(Cell(emptyList(), false, 1, 1, nestedTable = table()))))
        assertThrows(IllegalArgumentException::class.java) { entry(nested) }
        assertThrows(IllegalArgumentException::class.java) { table().copy(captionBlocks = emptyList()) }
        assertThrows(IllegalArgumentException::class.java) { table().copy(rows = emptyList()) }
        assertThrows(IllegalArgumentException::class.java) { table().copy(rows = listOf(listOf(Cell(emptyList(), false, 1, 1,
            blocks = listOf(Block("paragraph", 0, listOf(Span("text", "Body")))))))) }
        val note = Reference(1, 1, "", emptyList(), blocks = listOf(block(table())))
        assertThrows(IllegalArgumentException::class.java) { entry(Table(emptyList(), emptyList()), references = listOf(note)) }
        assertThrows(IllegalArgumentException::class.java) { block(table()).copy(spans = listOf(Span("text", "outside"))) }
        assertThrows(IllegalArgumentException::class.java) { block(table()).copy(feature = Feature("color", "", "", "", "")) }
        assertThrows(IllegalArgumentException::class.java) { block(table()).copy(kind = "paragraph") }
    }

    @Test fun egyptianBoundaryFollowsActualNativeRunPredicateWithoutLanguageWhitelist() {
        val sign = String(Character.toChars(0x13000))
        val shaped = Span("text", sign, classes = "Egyp")
        assertThrows(IllegalArgumentException::class.java) { table(listOf(shaped)) }
        assertNotNull(entry(table(listOf(shaped.copy(code = true)))))
        assertNotNull(entry(table(listOf(shaped.copy(fontScale = 0f)))))
        assertNotNull(entry(table(listOf(shaped.copy(kind = "line_break")))))
        assertNotNull(entry(table(listOf(shaped.copy(text = "ordinary", trail = sign)))))
        assertNotNull(entry(table(listOf(Span("text", "เสียง (สหรัฐอเมริกา):")))))
    }
}

class InlineTableAtomicPlacementTest {
    private fun place(usedWidth: Float, minimum: Float, free: Float): Pair<NativeFloatBlockPlacement, Int> {
        var calls = 0
        val result = placeNativeFloatBlock(360f, 0f,
            listOf(NativeFloatExclusion(TableFloatSide.Left, NativeFloatBounds(0f, 0f, 360f - free, 100f))),
            NativeBlockWidth.FixedPx(usedWidth), pixelAligned = true) {
            calls++
            NativeBlockMeasure(usedWidth, minimum, 30f)
        }
        return result to calls
    }

    @Test fun actualShrinkFitBoxFitsBesideFloatWithoutFillingItsWholeContainingBlock() {
        val (placed, calls) = place(180f, 100f, 240f)
        assertEquals(NativeFloatBounds(120f, 0f, 300f, 30f), placed.bounds)
        assertEquals(1, calls)
    }

    @Test fun atomicBoxMovesBelowFloatRatherThanReshrinkingToTheShortenedLine() {
        val (placed, calls) = place(280f, 180f, 240f)
        assertEquals(NativeFloatBounds(0f, 100f, 280f, 130f), placed.bounds)
        assertEquals(1, calls)
    }

    @Test fun overwideScrollableViewportUsesOriginalWidthAndOneStateOwner() {
        val (placed, calls) = place(360f, 360f, 240f)
        assertEquals(NativeFloatBounds(0f, 100f, 360f, 130f), placed.bounds)
        assertEquals(1, calls)
    }

    @Test fun zeroWidthColumnIsNotAnInventedOnePixelMinimum() {
        val grid = TableGrid(listOf(PlacedCell(Cell(emptyList(), false, 1, 1), 0, 0, 1),
            PlacedCell(Cell(emptyList(), false, 1, 1), 0, 1, 1)), 1, 2)
        assertEquals(listOf(0, 12), inlineTableColumnWidths(grid, intArrayOf(0, 12), intArrayOf(0, 12), 0, 0, 100))
        val pixels = checkNotNull(tablePixelLayout(grid, 1, 10, intArrayOf(10, 10), columnWidths = listOf(0, 12)))
        assertEquals(0, pixels.cellWidth(1, 0))
        assertEquals(0, pixels.cellLeft(1))
        assertEquals(12, pixels.width)
    }

    @Test fun spanningRowsRetainTheirFullHeightWithUnequalRtlColumns() {
        val grid = TableGrid(listOf(
            PlacedCell(Cell(emptyList(), false, 1, 2), 0, 0, 1),
            PlacedCell(Cell(emptyList(), false, 1, 1), 0, 1, 1),
            PlacedCell(Cell(emptyList(), false, 1, 1), 1, 1, 1)), 2, 2)
        val pixels = checkNotNull(tablePixelLayout(grid, 1, 10, intArrayOf(50, 10, 10),
            cellSpacing = 2, columnWidths = listOf(40, 70)))
        assertEquals(50, pixels.cellBottom(0, 2) - pixels.cellTop(0))
        assertEquals(74, pixels.physicalCellLeft(0, 1, true))
        assertEquals(2, pixels.physicalCellLeft(1, 1, true))
        assertEquals(54, pixels.height)
    }
}

class NativeFallbackBoundsTest {
    @Test fun finiteParentBoundsAndMinimumAreRespected() {
        val bounds = androidx.compose.ui.unit.Constraints(minWidth = 300, maxWidth = 300, minHeight = 12, maxHeight = 100)
        assertEquals(12, nativeFallbackHeight(bounds, 5L))
        assertEquals(100, nativeFallbackHeight(bounds, 500L))
    }

    @Test fun overIntContentCannotWrapOrExceedPackedComposeHeight() {
        val bounds = androidx.compose.ui.unit.Constraints(maxWidth = 20000)
        val height = nativeFallbackHeight(bounds, 2L * Int.MAX_VALUE)
        assertTrue(height > 0 && height < Int.MAX_VALUE)
        assertNotNull(androidx.compose.ui.unit.Constraints.fixed(20000, height))
        assertEquals(height, nativeFallbackHeight(bounds, Long.MAX_VALUE))
    }
}
